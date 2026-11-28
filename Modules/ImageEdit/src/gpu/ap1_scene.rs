//! Strict, standalone wgpu execution of the first AP1 plan. Production still uses 039.

use super::Gpu;
use crate::scene::ap1::{Coverage, Plan, Prepared, Region, Step};
use crate::Pixel;
use serde::{Deserialize, Serialize};
use std::fmt::{Arguments, Write};
use std::sync::{mpsc, Arc};
use std::time::Instant;
use wgpu::{BufferUsages, ComputePipeline, DeviceType};

#[cfg(all(target_os = "macos", feature = "metal-surface"))]
pub(crate) mod metal_texture;

const GROUP_EDGE: u32 = 16;
const LAYER_BLEND_NUMERIC_FLAG: u32 = 0x8;
pub const DEFAULT_BUDGET_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Backend {
    Metal,
    Vulkan,
}

impl Backend {
    pub fn name(self) -> &'static str {
        match self {
            Self::Metal => "metal",
            Self::Vulkan => "vulkan",
        }
    }

    fn wgpu(self) -> (wgpu::Backends, wgpu::Backend) {
        match self {
            Self::Metal => (wgpu::Backends::METAL, wgpu::Backend::Metal),
            Self::Vulkan => (wgpu::Backends::VULKAN, wgpu::Backend::Vulkan),
        }
    }

    fn supported_host(self) -> bool {
        match self {
            Self::Metal => cfg!(target_os = "macos"),
            Self::Vulkan => cfg!(target_os = "linux"),
        }
    }
}

pub struct SceneDevice {
    gpu: Gpu,
    backend: Backend,
    adapter: wgpu::AdapterInfo,
}

pub struct Program {
    owner: Arc<()>,
    pipeline: ComputePipeline,
    plan: Plan,
    shader: String,
}

impl Program {
    pub fn shader(&self) -> &str {
        &self.shader
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    executor: &'static str,
    #[serde(rename = "graphicsAPI")]
    graphics_api: Backend,
    fallback_count: u32,
    region: Region,
    nodes: usize,
    dispatches: u32,
    input_bytes: u64,
    output_bytes: u64,
    validation_bytes: u64,
    parameter_bytes: u64,
    intermediate_buffer_bytes: u64,
    readback_bytes: u64,
    accounted_peak_bytes: u64,
    budget_bytes: u64,
    mapped_buffer_init_ns: u128,
    submit_and_host_join_ns: u128,
    copy_map_readback_ns: u128,
    gpu_timestamp_ns: Option<u64>,
}

impl SceneDevice {
    pub fn open(backend: Backend, exact_name: Option<&str>) -> Result<Self, String> {
        if !backend.supported_host() {
            return Err(format!(
                "strict {} is unavailable on this host",
                backend.name()
            ));
        }
        let (backends, expected) = backend.wgpu();
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends,
            ..Default::default()
        });
        let adapters = instance.enumerate_adapters(backends);
        let mut observed = Vec::new();
        for adapter in adapters {
            let info = adapter.get_info();
            observed.push(format!(
                "{} ({:?}, {:?})",
                info.name, info.backend, info.device_type
            ));
            let physical = matches!(
                info.device_type,
                DeviceType::IntegratedGpu | DeviceType::DiscreteGpu
            );
            let driver_label =
                format!("{} {} {}", info.name, info.driver, info.driver_info).to_ascii_lowercase();
            let software = ["llvmpipe", "lavapipe", "swiftshader", "software rasterizer"]
                .iter()
                .any(|&name| driver_label.contains(name));
            if info.backend == expected
                && physical
                && !software
                && exact_name.is_none_or(|name| info.name == name)
            {
                let gpu = pollster::block_on(Gpu::from_adapter(adapter))?;
                return Ok(Self {
                    gpu,
                    backend,
                    adapter: info,
                });
            }
        }
        Err(format!(
            "no matching physical {} adapter; observed: {:?}",
            backend.name(),
            observed
        ))
    }

    pub fn adapter(&self) -> &wgpu::AdapterInfo {
        &self.adapter
    }

    pub fn limits(&self) -> wgpu::Limits {
        self.gpu.device.limits()
    }

    pub fn compile(&mut self, plan: &Plan) -> Result<Program, String> {
        let limits = self.limits();
        if limits.max_compute_workgroup_size_x < GROUP_EDGE
            || limits.max_compute_workgroup_size_y < GROUP_EDGE
            || limits.max_compute_invocations_per_workgroup < GROUP_EDGE * GROUP_EDGE
        {
            return Err("device cannot admit the AP1 workgroup".into());
        }
        let shader = wgsl(plan);
        let device = &self.gpu.device;
        device.push_error_scope(wgpu::ErrorFilter::Validation);
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("portable AP1 scene"),
            source: wgpu::ShaderSource::Wgsl(shader.as_str().into()),
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("portable AP1 scene"),
            layout: None,
            module: &module,
            entry_point: Some("run_ap1"),
            compilation_options: Default::default(),
            cache: None,
        });
        if let Some(error) = pollster::block_on(device.pop_error_scope()) {
            return Err(error.to_string());
        }
        Ok(Program {
            owner: self.gpu.identity.clone(),
            pipeline,
            plan: plan.clone(),
            shader,
        })
    }

    pub fn render(
        &mut self,
        program: &Program,
        prepared: &Prepared,
        region: Region,
        pixels: &[Pixel],
        budget_bytes: u64,
    ) -> Result<(Vec<Pixel>, Receipt), String> {
        if !Arc::ptr_eq(&program.owner, &self.gpu.identity) || &program.plan != prepared.plan() {
            return Err("AP1 program belongs to another device or plan".into());
        }
        region
            .validate_pixels(pixels)
            .map_err(|error| error.to_string())?;
        let rows = parameter_rows(prepared, region);
        let size = std::mem::size_of_val(pixels) as u64;
        let parameter_bytes = std::mem::size_of_val(rows.as_slice()) as u64;
        let readback_bytes = size + 4;
        let total = 2 * size + parameter_bytes + 4 + readback_bytes;
        let extent = region.extent();
        let groups = extent.map(|edge| edge.div_ceil(GROUP_EDGE));
        let limits = self.limits();
        if total > budget_bytes
            || readback_bytes > limits.max_buffer_size
            || size.max(parameter_bytes) > u64::from(limits.max_storage_buffer_binding_size)
            || groups
                .iter()
                .any(|&edge| edge > limits.max_compute_workgroups_per_dimension)
        {
            return Err(
                "AP1 scene frame exceeds its buffer, dispatch or working-set budget".into(),
            );
        }
        let started = Instant::now();
        let input = self
            .gpu
            .initial(bytemuck::cast_slice(pixels), BufferUsages::STORAGE);
        let output = self
            .gpu
            .buffer(size, BufferUsages::STORAGE | BufferUsages::COPY_SRC);
        let params = self
            .gpu
            .initial(bytemuck::cast_slice(&rows), BufferUsages::STORAGE);
        let validation = self.gpu.initial(
            bytemuck::bytes_of(&0u32),
            BufferUsages::STORAGE | BufferUsages::COPY_SRC,
        );
        let bindings = self
            .gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("AP1 scene ROI"),
                layout: &program.pipeline.get_bind_group_layout(0),
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: input.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: output.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: params.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 3,
                        resource: validation.as_entire_binding(),
                    },
                ],
            });
        let mapped_buffer_init_ns = started.elapsed().as_nanos();

        let started = Instant::now();
        let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_compute_pass(&Default::default());
            pass.set_pipeline(&program.pipeline);
            pass.set_bind_group(0, &bindings, &[]);
            pass.dispatch_workgroups(groups[0], groups[1], 1);
        }
        self.gpu.queue.submit([encoder.finish()]);
        self.gpu.wait()?;
        let submit_and_host_join_ns = started.elapsed().as_nanos();

        let started = Instant::now();
        let staging = self.gpu.buffer(
            readback_bytes,
            BufferUsages::COPY_DST | BufferUsages::MAP_READ,
        );
        let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
        encoder.copy_buffer_to_buffer(&output, 0, &staging, 0, size);
        encoder.copy_buffer_to_buffer(&validation, 0, &staging, size, 4);
        self.gpu.queue.submit([encoder.finish()]);
        let slice = staging.slice(..);
        let (tx, rx) = mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = tx.send(result);
        });
        self.gpu.wait()?;
        rx.recv()
            .map_err(|error| error.to_string())?
            .map_err(|error| error.to_string())?;
        let mapped = slice.get_mapped_range();
        let validation_bits = bytemuck::pod_read_unaligned::<u32>(&mapped[size as usize..]);
        if validation_bits != 0 {
            drop(mapped);
            staging.unmap();
            let meanings = if validation_bits & LAYER_BLEND_NUMERIC_FLAG != 0 {
                "input 0x1, coverage 0x2, image 0x4, unsupported layer blend numeric domain 0x8"
            } else {
                "input 0x1, coverage 0x2, image 0x4"
            };
            return Err(format!(
                "WGSL AP1 validation status {validation_bits:#x} ({meanings})"
            ));
        }
        let result: Vec<Pixel> = bytemuck::cast_slice(&mapped[..size as usize]).to_vec();
        drop(mapped);
        staging.unmap();
        region
            .validate_pixels(&result)
            .map_err(|error| error.to_string())?;
        let copy_map_readback_ns = started.elapsed().as_nanos();
        Ok((
            result,
            Receipt {
                executor: "wgpu",
                graphics_api: self.backend,
                fallback_count: 0,
                region,
                nodes: prepared.plan().step_count(),
                dispatches: 1,
                input_bytes: size,
                output_bytes: size,
                validation_bytes: 4,
                parameter_bytes,
                intermediate_buffer_bytes: 0,
                readback_bytes,
                accounted_peak_bytes: total,
                budget_bytes,
                mapped_buffer_init_ns,
                submit_and_host_join_ns,
                copy_map_readback_ns,
                gpu_timestamp_ns: None,
            },
        ))
    }
}

fn wgsl(plan: &Plan) -> String {
    let mut code = include_str!("ap1_scene.wgsl").to_owned();
    write_additional_operators(&mut code, plan);
    code.push_str(
        r#"
@compute @workgroup_size(16, 16)
fn run_ap1(@builtin(global_invocation_id) gid: vec3<u32>) {
    let grid = params[0u];
    if any(gid.xy >= grid.xy) { return; }
    let index = gid.y * grid.x + gid.x;
    let q = (vec2<f32>(grid.zw + gid.xy) + vec2<f32>(0.5)) / vec2<f32>(params[1u].xy);
    let p0 = source[index];
    if !lawful(p0) { atomicOr(&invalid, 1u); return; }
"#,
    );
    write_steps(&mut code, plan);
    writeln!(code, "    target_pixels[index] = p{};\n}}", plan.output.0).unwrap();
    code
}

fn parameter_rows(prepared: &Prepared, region: Region) -> Vec<[u32; 4]> {
    let mut rows = region.header().to_vec();
    rows.extend(
        prepared
            .parameters()
            .rows
            .iter()
            .map(|row| row.map(f32::to_bits)),
    );
    rows
}

fn write_additional_operators(code: &mut String, plan: &Plan) {
    if plan
        .steps
        .iter()
        .any(|step| matches!(step, Step::RadialCoverage { .. }))
    {
        code.push_str(include_str!("ap1_scene_radial.wgsl"));
    }
    if plan
        .steps
        .iter()
        .any(|step| matches!(step, Step::NormalParallel { .. }))
    {
        code.push_str(include_str!("ap1_scene_parallel.wgsl"));
    }
    if plan.has_layer_blend() {
        code.push_str(include_str!("ap1_scene_blend.wgsl"));
    }
}

fn write_checked_coverage(code: &mut String, output: Coverage, expression: Arguments<'_>) {
    let slot = output.0;
    writeln!(code, "    let c{slot}_raw = {expression};").unwrap();
    writeln!(code, "    if (bitcast<u32>(c{slot}_raw) & 0x7fffffffu) >= 0x7f800000u {{ atomicOr(&invalid, 2u); return; }}").unwrap();
    writeln!(code, "    let c{slot} = clamp(c{slot}_raw, 0.0, 1.0);").unwrap();
}

fn write_steps(code: &mut String, plan: &Plan) {
    if plan.has_layer_blend() {
        writeln!(code, "    if blend_alpha_is_subnormal(p0.a) {{ atomicOr(&invalid, {LAYER_BLEND_NUMERIC_FLAG}u); return; }}").unwrap();
    }
    for step in &plan.steps {
        let output = match *step {
            Step::LinearCoverage { output, row } => {
                let slot = output.0;
                writeln!(code, "    let c{slot} = linear_coverage(q, {row}u);").unwrap();
                writeln!(code, "    if !(c{slot} >= 0.0 && c{slot} <= 1.0) {{ atomicOr(&invalid, 2u); return; }}").unwrap();
                continue;
            }
            Step::Corrector {
                input,
                coverage,
                output,
                row,
            } => {
                let mask = coverage.map_or_else(|| "1.0".into(), |slot| format!("c{}", slot.0));
                writeln!(
                    code,
                    "    let p{} = corrector(p{}, {mask}, {row}u);",
                    output.0, input.0
                )
                .unwrap();
                output.0
            }
            Step::NormalLayer {
                bottom,
                top,
                output,
                row,
            } => {
                writeln!(
                    code,
                    "    let p{} = normal_layer(p{}, p{}, {row}u);",
                    output.0, bottom.0, top.0
                )
                .unwrap();
                output.0
            }
            Step::RadialCoverage { output, row } => {
                let slot = output.0;
                writeln!(code, "    let c{slot} = radial_coverage(q, {row}u);").unwrap();
                writeln!(code, "    if !(c{slot} >= 0.0 && c{slot} <= 1.0) {{ atomicOr(&invalid, 2u); return; }}").unwrap();
                continue;
            }
            Step::IntersectCoverage {
                left,
                right,
                output,
            } => {
                let slot = output.0;
                writeln!(code, "    let c{slot} = c{} * c{};", left.0, right.0).unwrap();
                writeln!(code, "    if !(c{slot} >= 0.0 && c{slot} <= 1.0) {{ atomicOr(&invalid, 2u); return; }}").unwrap();
                continue;
            }
            Step::NormalParallel {
                current,
                branch,
                base,
                output,
                row,
            } => {
                writeln!(
                    code,
                    "    let p{} = normal_parallel(p{}, p{}, p{}, {row}u);",
                    output.0, current.0, branch.0, base.0
                )
                .unwrap();
                output.0
            }
            Step::LayerBlend {
                current,
                branch,
                output,
                row,
            } => {
                writeln!(
                    code,
                    "    let blend{} = layer_blend(p{}, p{}, {row}u);",
                    output.0, current.0, branch.0
                )
                .unwrap();
                let slot = output.0;
                writeln!(code, "    if !blend{slot}.supported {{ atomicOr(&invalid, {LAYER_BLEND_NUMERIC_FLAG}u); return; }}").unwrap();
                writeln!(code, "    let p{slot} = blend{slot}.pixel;").unwrap();
                output.0
            }
            Step::AddCoverage {
                left,
                right,
                output,
            } => {
                let (a, b) = (left.0, right.0);
                write_checked_coverage(code, output, format_args!("c{a} + c{b} * (1.0 - c{a})"));
                continue;
            }
            Step::SubtractCoverage {
                left,
                right,
                output,
            } => {
                write_checked_coverage(
                    code,
                    output,
                    format_args!("c{} * (1.0 - c{})", left.0, right.0),
                );
                continue;
            }
            Step::AdjustCoverage { input, output, row } => {
                let slot = input.0;
                write_checked_coverage(
                    code,
                    output,
                    format_args!(
                        "select(c{slot}, 1.0 - c{slot}, row_f32({row}u).y != 0.0) * row_f32({row}u).x"
                    ),
                );
                continue;
            }
        };
        writeln!(
            code,
            "    if !lawful(p{output}) {{ atomicOr(&invalid, 4u); return; }}"
        )
        .unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::scene::ap1::Root;
    use sha2::{Digest, Sha256};

    #[test]
    fn buffer_shader_retains_the_signed_off_component_shape() {
        // The literal values and IDs can vary. This is the active shape of the archived real
        // Metal/Vulkan final and monitor shader hashes in the 043 evidence.
        let document = br#"{"schemaVersion":1,"graph":{"output":"final","nodes":[
          {"id":"m","name":"Coverage","operation":{"kind":"linearCoverage","start":[0.25,0.2],"end":[0.9,0.8]}},
          {"id":"c","name":"Masked","operation":{"kind":"corrector","image":"$input","mask":"m","exposureEV":1,"curve":[],"strength":1,"enabled":true}},
          {"id":"d","name":"Secondary","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":-0.5,"curve":[],"strength":1,"enabled":true}},
          {"id":"final","name":"Mix","operation":{"kind":"layer","base":"$input","enabled":true,"layers":[{"image":"c","weight":0.625,"mode":"normal"},{"image":"d","weight":0.375,"mode":"normal"}]}}
        ]}}"#;
        for (root, pinned) in [
            (
                Root::Final,
                "4095653fc19ec06834f5406c2583d0a6cda45844118531427c44f49fcf6e7107",
            ),
            (
                Root::Monitor("c"),
                "63287f0e7f006afb868384d6d45b9cc787c1ec5ef55391999db3372cc7e0ecb8",
            ),
        ] {
            let prepared = Prepared::from_039(document, root).unwrap();
            assert_eq!(
                format!("{:x}", Sha256::digest(wgsl(prepared.plan()))),
                pinned
            );
        }
    }

    #[test]
    fn buffer_shader_retains_the_six_node_final_and_monitor_shapes() {
        // Same active topology as the 6 MP Metal/Vulkan comparison.
        let document = br#"{"schemaVersion":1,"graph":{"output":"mix","nodes":[
          {"id":"ramp","name":"Ramp","operation":{"kind":"linearCoverage","start":[0.1,0],"end":[0.9,1]}},
          {"id":"ellipse","name":"Ellipse","operation":{"kind":"radialCoverage","center":[0.5,0.5],"radii":[0.4,0.6],"feather":0.2}},
          {"id":"mask","name":"Intersection","operation":{"kind":"combineCoverage","base":"ramp","other":"ellipse","mode":"intersect"}},
          {"id":"light","name":"Light","operation":{"kind":"corrector","image":"$input","mask":"mask","exposureEV":1.2,"curve":[],"strength":0.8,"enabled":true}},
          {"id":"dark","name":"Dark","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":-0.7,"curve":[],"strength":1,"enabled":true}},
          {"id":"mix","name":"Mix","operation":{"kind":"parallel","base":"$input","enabled":true,"layers":[{"image":"light","weight":0.65,"mode":"normal"},{"image":"dark","weight":0.35,"mode":"normal"}]}}
        ]}}"#;
        for (root, pinned) in [
            (
                Root::Final,
                "e18c81bf5d6ae8c02749580ea07cbf24e62ce949c9dca7349e2d9a3817bc48a8",
            ),
            (
                Root::Monitor("light"),
                "7508ec03b8c29052bed6b7279bd2d733ef9cb3aa48802018478cb5cd332f862a",
            ),
        ] {
            let prepared = Prepared::from_039(document, root).unwrap();
            assert_eq!(
                format!("{:x}", Sha256::digest(wgsl(prepared.plan()))),
                pinned
            );
        }
    }
}
