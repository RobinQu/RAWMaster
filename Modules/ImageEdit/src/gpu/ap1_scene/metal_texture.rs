//! Same-device AP1 texture execution for the strict macOS product adapter.

use super::{
    parameter_rows, write_additional_operators, write_steps, GROUP_EDGE, LAYER_BLEND_NUMERIC_FLAG,
};
use crate::gpu::Gpu;
use crate::scene::ap1::{Plan, Prepared, Region};
use crate::scene::{SceneError, ViewSpec};
use foreign_types::{ForeignType, ForeignTypeRef};
use metal::{MTLPixelFormat, MTLResourceOptions, MTLStorageMode, MTLTextureType, MTLTextureUsage};
use std::collections::VecDeque;
use std::ffi::c_void;
use std::fmt::Write;
use std::sync::Arc;
use std::time::{Duration, Instant};
use wgpu::{BindGroupLayoutEntry, BindingType, BufferUsages, TextureUsages};

type Metal = wgpu::hal::api::Metal;
const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba32Float;
const CACHE_ENTRIES: usize = 4;
const DEFAULT_SURFACE_BUDGET: u64 = 1_536 * 1024 * 1024;

extern "C" {
    fn rm_is_private_half_root(texture: *mut c_void) -> bool;
    fn rm_new_half_shared_buffer(device: *mut c_void, length: u64) -> *mut c_void;
}

/// A joined result from one native render. The counters describe the work done by this call.
#[repr(C)]
#[derive(Default)]
pub struct MetalReceipt {
    pub nodes: u32,
    pub dispatches: u32,
    pub submissions: u32,
    pub host_waits: u32,
    pub pipeline_builds: u32,
    pub reserved: u32,
    pub peak_bytes: u64,
    pub budget_bytes: u64,
    pub frame_copy_bytes: u64,
    pub validation_bytes: u64,
    pub submit_wait_ns: u64,
    pub cpu_ms: f64,
}

struct GraphEntry {
    document: Vec<u8>,
    group_path: Vec<String>,
    target: String,
    id: Option<String>,
    prepared: Arc<Prepared>,
}

impl GraphEntry {
    fn new(document: &[u8], view: &ViewSpec) -> Result<Self, SceneError> {
        let prepared = Arc::new(Prepared::from_039_view(document, view)?);
        Ok(Self {
            document: document.to_vec(),
            group_path: view.group_path.clone(),
            target: view.target.clone(),
            id: view.id.clone(),
            prepared,
        })
    }

    fn matches(&self, document: &[u8], view: &ViewSpec) -> bool {
        self.document == document
            && self.group_path == view.group_path
            && self.target == view.target
            && self.id == view.id
    }
}

struct PipelineEntry {
    plan: Plan,
    pipeline: wgpu::ComputePipeline,
}

/// C callers serialize access. The caches own no image, texture view, or frame parameter buffer.
pub struct MetalProgram {
    gpu: Gpu,
    native: metal::Device,
    low_latency_join: bool,
    layout: wgpu::BindGroupLayout,
    pipeline_layout: wgpu::PipelineLayout,
    graphs: VecDeque<GraphEntry>,
    pipelines: VecDeque<PipelineEntry>,
}

impl MetalProgram {
    pub fn open(wanted: &metal::DeviceRef) -> Result<Self, SceneError> {
        let gpu = Gpu::open_for_native_device(wanted).map_err(SceneError::Backend)?;
        let native = gpu.metal_device().map_err(SceneError::Backend)?;
        let limits = gpu.device.limits();
        if limits.max_bindings_per_bind_group < 4
            || limits.max_sampled_textures_per_shader_stage < 1
            || limits.max_storage_textures_per_shader_stage < 1
            || limits.max_storage_buffers_per_shader_stage < 2
            || limits.max_compute_workgroup_size_x < GROUP_EDGE
            || limits.max_compute_workgroup_size_y < GROUP_EDGE
            || limits.max_compute_invocations_per_workgroup < GROUP_EDGE * GROUP_EDGE
        {
            return Err(SceneError::Backend(
                "device cannot admit the AP1 texture pipeline".into(),
            ));
        }
        let layout = gpu
            .device
            .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("AP1 Metal texture ports"),
                entries: &[
                    entry(
                        0,
                        BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: false },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                    ),
                    entry(
                        1,
                        BindingType::StorageTexture {
                            access: wgpu::StorageTextureAccess::WriteOnly,
                            format: FORMAT,
                            view_dimension: wgpu::TextureViewDimension::D2,
                        },
                    ),
                    entry(2, storage(true)),
                    entry(3, storage(false)),
                ],
            });
        let pipeline_layout = gpu
            .device
            .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("AP1 Metal texture pipeline layout"),
                bind_group_layouts: &[&layout],
                push_constant_ranges: &[],
            });
        Ok(Self {
            gpu,
            native,
            low_latency_join: std::env::var_os("RAWMASTER_AP1_METAL_LOW_LATENCY_JOIN")
                .is_some_and(|value| value == "1"),
            layout,
            pipeline_layout,
            graphs: VecDeque::new(),
            pipelines: VecDeque::new(),
        })
    }

    fn prepared(&mut self, document: &[u8], view: &ViewSpec) -> Result<Arc<Prepared>, SceneError> {
        if let Some(index) = self
            .graphs
            .iter()
            .position(|entry| entry.matches(document, view))
        {
            let hit = self.graphs.remove(index).unwrap();
            let prepared = hit.prepared.clone();
            self.graphs.push_front(hit);
            return Ok(prepared);
        }
        let entry = GraphEntry::new(document, view)?;
        let prepared = entry.prepared.clone();
        if self.graphs.len() == CACHE_ENTRIES {
            self.graphs.pop_back();
        }
        self.graphs.push_front(entry);
        Ok(prepared)
    }

    fn pipeline(&mut self, plan: &Plan) -> Result<(wgpu::ComputePipeline, u32), SceneError> {
        if let Some(index) = self.pipelines.iter().position(|entry| &entry.plan == plan) {
            let hit = self.pipelines.remove(index).unwrap();
            let pipeline = hit.pipeline.clone();
            self.pipelines.push_front(hit);
            return Ok((pipeline, 0));
        }
        let code = texture_wgsl(plan);
        let device = &self.gpu.device;
        device.push_error_scope(wgpu::ErrorFilter::Validation);
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("native AP1 scene"),
            source: wgpu::ShaderSource::Wgsl(code.into()),
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: Some("native AP1 scene"),
            layout: Some(&self.pipeline_layout),
            module: &module,
            entry_point: Some("run_ap1_texture"),
            compilation_options: Default::default(),
            cache: None,
        });
        if let Some(error) = pollster::block_on(device.pop_error_scope()) {
            return Err(SceneError::Backend(error.to_string()));
        }
        if self.pipelines.len() == CACHE_ENTRIES {
            self.pipelines.pop_back();
        }
        self.pipelines.push_front(PipelineEntry {
            plan: plan.clone(),
            pipeline: pipeline.clone(),
        });
        Ok((pipeline, 1))
    }

    /// # Safety
    /// The source must pass `admits_source` and remain initialized and immutable through completion.
    pub unsafe fn render(
        &mut self,
        document: &[u8],
        view: &ViewSpec,
        input: &metal::TextureRef,
    ) -> Result<(metal::Texture, MetalReceipt), SceneError> {
        validate_view(view)?;
        let input_device = input.device();
        if input_device.as_ptr() != self.native.as_ptr()
            || input_device.registry_id() != self.native.registry_id()
            || input.texture_type() != MTLTextureType::D2
            || input.pixel_format() != MTLPixelFormat::RGBA32Float
            || input.array_length() != 1
            || input.mipmap_level_count() != 1
            || input.sample_count() != 1
            || !input.usage().contains(MTLTextureUsage::ShaderRead)
        {
            return Err(SceneError::Invalid(
                "AP1 source descriptor or device mismatch".into(),
            ));
        }
        let extent = [
            u32::try_from(input.width()).unwrap_or(0),
            u32::try_from(input.height()).unwrap_or(0),
        ];
        let origin = view
            .origin
            .unwrap_or_default()
            .map(|value| u32::try_from(value).unwrap_or(u32::MAX));
        let region = Region::native(view.geometry.unwrap_or(extent), origin, extent)?;
        let groups = extent.map(|edge| edge.div_ceil(GROUP_EDGE));
        let limits = self.gpu.device.limits();
        if extent
            .iter()
            .any(|&edge| edge > limits.max_texture_dimension_2d)
            || groups
                .iter()
                .any(|&edge| edge > limits.max_compute_workgroups_per_dimension)
        {
            return Err(SceneError::Backend(
                "AP1 source exceeds the Metal device extent limit".into(),
            ));
        }

        let prepared = self.prepared(document, view)?;
        let rows = parameter_rows(&prepared, region);
        let parameters = bytemuck::cast_slice(&rows);
        let minimum_texture = region.pixel_count() as u64 * 16;
        let input_bytes = input.allocated_size().max(minimum_texture);
        let budget = view.surface_budget.unwrap_or(DEFAULT_SURFACE_BUDGET);
        let output_description = metal::TextureDescriptor::new();
        output_description.set_texture_type(MTLTextureType::D2);
        output_description.set_pixel_format(MTLPixelFormat::RGBA32Float);
        output_description.set_width(u64::from(extent[0]));
        output_description.set_height(u64::from(extent[1]));
        output_description.set_storage_mode(MTLStorageMode::Private);
        // wgpu initializes its renderable RGBA32F storage textures through a render pass.
        output_description.set_usage(
            MTLTextureUsage::ShaderRead
                | MTLTextureUsage::ShaderWrite
                | MTLTextureUsage::RenderTarget,
        );
        let output_estimate = self
            .native
            .heap_texture_size_and_align(&output_description)
            .size
            .max(minimum_texture);
        let shared_estimate = |bytes| {
            self.native
                .heap_buffer_size_and_align(bytes, MTLResourceOptions::StorageModeShared)
                .size
                .max(bytes)
        };
        let parameter_bytes = parameters.len() as u64;
        if parameter_bytes > u64::from(limits.max_storage_buffer_binding_size) {
            return Err(SceneError::Budget(
                "AP1 scene parameters exceed the device binding limit".into(),
            ));
        }
        charge(
            budget,
            [
                input_bytes,
                output_estimate,
                shared_estimate(parameter_bytes),
                shared_estimate(4),
            ],
        )?;
        let (pipeline, pipeline_builds) = self.pipeline(prepared.plan())?;
        let (output, peak_bytes, submit_wait_ns) = self.run_texture(
            input,
            extent,
            groups,
            &pipeline,
            parameters,
            input_bytes,
            budget,
        )?;
        Ok((
            output,
            MetalReceipt {
                nodes: prepared.plan().step_count() as u32,
                dispatches: 1,
                submissions: 1,
                host_waits: 1,
                pipeline_builds,
                peak_bytes,
                budget_bytes: budget,
                frame_copy_bytes: 0,
                validation_bytes: 4,
                submit_wait_ns,
                ..MetalReceipt::default()
            },
        ))
    }

    #[allow(clippy::too_many_arguments)]
    fn run_texture(
        &self,
        input: &metal::TextureRef,
        extent: [u32; 2],
        groups: [u32; 2],
        pipeline: &wgpu::ComputePipeline,
        parameters: &[u8],
        input_bytes: u64,
        budget: u64,
    ) -> Result<(metal::Texture, u64, u64), SceneError> {
        let device = &self.gpu.device;
        let size = wgpu::Extent3d {
            width: extent[0],
            height: extent[1],
            depth_or_array_layers: 1,
        };
        let input_description = wgpu::TextureDescriptor {
            label: Some("producer-joined AP1 input"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: FORMAT,
            usage: TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        };
        // The caller's lease and source validation ensure the exact backing stays initialized.
        let source = unsafe {
            let raw = wgpu::hal::metal::Device::texture_from_raw(
                input.to_owned(),
                FORMAT,
                MTLTextureType::D2,
                1,
                1,
                size.into(),
            );
            device.create_texture_from_hal::<Metal>(raw, &input_description)
        };
        if unsafe {
            source
                .as_hal::<Metal>()
                .ok_or_else(surface_unavailable)?
                .raw_handle()
                .as_ptr()
        } != input.as_ptr()
        {
            return Err(surface_unavailable());
        }
        // A fresh output stays under wgpu's normal resource-initialization rules.
        let output = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("AP1 native output"),
            usage: TextureUsages::TEXTURE_BINDING | TextureUsages::STORAGE_BINDING,
            ..input_description
        });
        let output_native_bytes = unsafe {
            let handle = output.as_hal::<Metal>().ok_or_else(surface_unavailable)?;
            let raw = handle.raw_handle();
            if raw.as_ptr() == input.as_ptr()
                || !raw.usage().contains(MTLTextureUsage::ShaderRead)
                || raw.pixel_format() != MTLPixelFormat::RGBA32Float
            {
                return Err(surface_unavailable());
            }
            raw.allocated_size()
                .max(u64::from(extent[0]) * u64::from(extent[1]) * 16)
        };
        let params = self.shared_buffer(parameters)?;
        let validation = self.shared_buffer(&[0; 4])?;
        let peak = charge(
            budget,
            [
                input_bytes,
                output_native_bytes,
                params.raw.allocated_size().max(parameters.len() as u64),
                validation.raw.allocated_size().max(4),
            ],
        )?;
        let source_view = source.create_view(&Default::default());
        let output_view = output.create_view(&Default::default());
        let bindings = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("AP1 native texture bindings"),
            layout: &self.layout,
            entries: &[
                binding(0, wgpu::BindingResource::TextureView(&source_view)),
                binding(1, wgpu::BindingResource::TextureView(&output_view)),
                binding(2, params.bound.as_entire_binding()),
                binding(3, validation.bound.as_entire_binding()),
            ],
        });
        let mut encoder = device.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_compute_pass(&Default::default());
            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &bindings, &[]);
            pass.dispatch_workgroups(groups[0], groups[1], 1);
        }
        let started = Instant::now();
        let submission_index = self.gpu.queue.submit([encoder.finish()]);
        // The Metal buffer exposed before finish can precede wgpu's recorded compute pass.
        // Join the actual submission before exposing either its validation word or texture.
        join_submission(device, submission_index, self.low_latency_join)
            .map_err(|error| SceneError::Render(error.to_string()))?;
        let submit_wait_ns = started.elapsed().as_nanos() as u64;
        let invalid = unsafe { validation.raw.contents().cast::<u32>().read_volatile() };
        validate_shader_result(invalid)?;
        let retained = unsafe {
            output
                .as_hal::<Metal>()
                .ok_or_else(surface_unavailable)?
                .raw_handle()
                .clone()
        };
        Ok((retained, peak, submit_wait_ns))
    }

    fn shared_buffer(&self, bytes: &[u8]) -> Result<SharedBuffer, SceneError> {
        let length = bytes.len() as u64;
        let pointer = unsafe { rm_new_half_shared_buffer(self.native.as_ptr().cast(), length) };
        if pointer.is_null() {
            return Err(SceneError::Budget(
                "AP1 shared buffer allocation failed".into(),
            ));
        }
        // The Objective-C helper returns +1 and verifies that the CPU can initialize the buffer.
        let raw = unsafe { metal::Buffer::from_ptr(pointer.cast()) };
        let bound = unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), raw.contents().cast(), bytes.len());
            let buffer = wgpu::hal::metal::Device::buffer_from_raw(raw.clone(), length);
            self.gpu.device.create_buffer_from_hal::<Metal>(
                buffer,
                &wgpu::BufferDescriptor {
                    label: Some("AP1 shared parameters or validation word"),
                    size: length,
                    usage: BufferUsages::STORAGE,
                    mapped_at_creation: false,
                },
            )
        };
        Ok(SharedBuffer { raw, bound })
    }
}

struct SharedBuffer {
    raw: metal::Buffer,
    bound: wgpu::Buffer,
}

fn join_submission(
    device: &wgpu::Device,
    submission_index: wgpu::SubmissionIndex,
    low_latency: bool,
) -> Result<(), wgpu::PollError> {
    if low_latency {
        const WINDOW: Duration = Duration::from_millis(1);
        const INTERVAL: Duration = Duration::from_micros(100);
        let start = Instant::now();
        while start.elapsed() < WINDOW {
            // A zero-time Wait still tests this submission; Metal skips its 1 ms sleep.
            match device.poll(wgpu::PollType::Wait {
                submission_index: Some(submission_index.clone()),
                timeout: Some(Duration::ZERO),
            }) {
                Ok(status) if status.wait_finished() => return Ok(()),
                Ok(_) => break,
                Err(wgpu::PollError::Timeout) => {}
                Err(error) => return Err(error),
            }
            let pause = WINDOW.saturating_sub(start.elapsed()).min(INTERVAL);
            if !pause.is_zero() {
                std::thread::sleep(pause);
            }
        }
    }
    device
        .poll(wgpu::PollType::Wait {
            submission_index: Some(submission_index),
            timeout: None,
        })
        .map(|_| ())
}

pub(crate) unsafe fn admits_source(input: *mut c_void) -> bool {
    !input.is_null() && rm_is_private_half_root(input)
}

fn validate_view(view: &ViewSpec) -> Result<(), SceneError> {
    let target = view.target.as_str();
    match target {
        "final" | "bypass" if target == "final" || !view.group_path.is_empty() => {
            if view.id.is_none() {
                Ok(())
            } else {
                Err(SceneError::Invalid(format!(
                    "AP1 {target} root cannot specify a monitor ID"
                )))
            }
        }
        "node" => view
            .id
            .as_deref()
            .filter(|id| !id.is_empty())
            .map(|_| ())
            .ok_or_else(|| SceneError::Invalid("AP1 node monitoring requires a node ID".into())),
        _ => Err(SceneError::Unsupported(
            "unsupported native AP1 scene root".into(),
        )),
    }
}

fn entry(binding: u32, ty: BindingType) -> BindGroupLayoutEntry {
    BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty,
        count: None,
    }
}

fn binding(binding: u32, resource: wgpu::BindingResource<'_>) -> wgpu::BindGroupEntry<'_> {
    wgpu::BindGroupEntry { binding, resource }
}

fn storage(read_only: bool) -> BindingType {
    BindingType::Buffer {
        ty: wgpu::BufferBindingType::Storage { read_only },
        has_dynamic_offset: false,
        min_binding_size: None,
    }
}

fn charge(budget: u64, allocations: [u64; 4]) -> Result<u64, SceneError> {
    allocations
        .into_iter()
        .try_fold(0u64, u64::checked_add)
        .filter(|&total| total <= budget)
        .ok_or_else(|| SceneError::Budget("native AP1 scene exceeds its surface budget".into()))
}

fn surface_unavailable() -> SceneError {
    SceneError::Render("wgpu did not expose the expected Metal texture".into())
}

fn validate_shader_result(flags: u32) -> Result<(), SceneError> {
    match flags {
        0 => Ok(()),
        LAYER_BLEND_NUMERIC_FLAG => Err(SceneError::Unsupported(format!(
            "native AP1 shader validation flags {flags:#x}: unsupported layer blend numeric domain"
        ))),
        _ => Err(SceneError::Render(format!(
            "native AP1 shader validation flags {flags:#x}"
        ))),
    }
}

fn texture_wgsl(plan: &Plan) -> String {
    let source = include_str!("../ap1_scene.wgsl");
    let (_, operators) = source
        .split_once("\n\n")
        .expect("AP1 operator prelude has a binding boundary");
    let mut code = String::from(
        r#"// AP1 scene operator contract v1 over native Metal textures.
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var target_pixels: texture_storage_2d<rgba32float, write>;
@group(0) @binding(2) var<storage, read> params: array<vec4<u32>>;
@group(0) @binding(3) var<storage, read_write> invalid: atomic<u32>;

"#,
    );
    code.push_str(operators);
    write_additional_operators(&mut code, plan);
    code.push_str(
        r#"
@compute @workgroup_size(16, 16)
fn run_ap1_texture(@builtin(global_invocation_id) gid: vec3<u32>) {
    let grid = params[0u];
    if any(gid.xy >= grid.xy) { return; }
    let q = (vec2<f32>(grid.zw + gid.xy) + vec2<f32>(0.5)) / vec2<f32>(params[1u].xy);
    let coord = vec2<i32>(gid.xy);
    let p0 = textureLoad(source, coord, 0);
    if !lawful(p0) { atomicOr(&invalid, 1u); return; }
"#,
    );
    write_steps(&mut code, plan);
    writeln!(
        code,
        "    textureStore(target_pixels, coord, p{});\n}}",
        plan.output.0
    )
    .unwrap();
    code
}

#[cfg(test)]
mod tests {
    use super::*;

    const GROUP_DOCUMENT: &[u8] = br#"{"schemaVersion":1,"graph":{"output":"outer","nodes":[
      {"id":"outer","name":"Outer","operation":{"kind":"group","image":"$input","strength":0.25,"enabled":false,
        "graph":{"output":"inner","nodes":[
          {"id":"inner","name":"Inner","operation":{"kind":"group","image":"$input","strength":0.5,"enabled":true,
            "graph":{"output":"grade","nodes":[
              {"id":"grade","name":"Grade","operation":{"kind":"corrector","image":"$input","mask":null,"exposureEV":1,"curve":[],"strength":1,"enabled":true}}
            ]}}}
        ]}}}
    ]}}"#;

    #[test]
    fn native_geometry_and_root_contract_are_distinct_from_the_probe() {
        let full = [9_504, 6_336];
        assert!(matches!(
            Region::new(full, [0, 0], full),
            Err(SceneError::Budget(_))
        ));
        assert_eq!(
            Region::native(full, [0, 0], full).unwrap().pixel_count(),
            60_217_344
        );
        assert!(Region::native(full, [9_503, 6_335], [2, 1]).is_err());
        let mut view = ViewSpec::default();
        assert!(validate_view(&view).is_ok());
        view.target = "bypass".into();
        assert!(matches!(
            validate_view(&view),
            Err(SceneError::Unsupported(_))
        ));
        view.target = "node".into();
        assert!(matches!(validate_view(&view), Err(SceneError::Invalid(_))));
        view.id = Some("monitor".into());
        assert!(validate_view(&view).is_ok());
        view.group_path.push("group".into());
        assert!(validate_view(&view).is_ok());
        view.target = "bypass".into();
        assert!(matches!(validate_view(&view), Err(SceneError::Invalid(_))));
        view.id = None;
        assert!(validate_view(&view).is_ok());
    }

    #[test]
    fn native_prepared_graph_matches_full_selector_independent_of_region() {
        let document = GROUP_DOCUMENT;
        let mut view = ViewSpec {
            group_path: vec!["outer".into(), "inner".into()],
            target: "node".into(),
            id: Some("grade".into()),
            ..Default::default()
        };
        let entry = GraphEntry::new(document, &view).unwrap();
        view.origin = Some([9, 12]);
        view.geometry = Some([25, 25]);
        view.surface_budget = Some(1_000_000);
        assert!(entry.matches(document, &view));
        assert!(!entry.matches(b"", &view));
        view.group_path.pop();
        assert!(!entry.matches(document, &view));
        view.group_path.push("inner".into());
        view.id = Some("other".into());
        assert!(!entry.matches(document, &view));
        view.id = Some("grade".into());
        view.target = "final".into();
        assert!(!entry.matches(document, &view));
    }

    #[test]
    fn grouped_monitor_generates_valid_texture_and_buffer_wgsl() {
        let view = ViewSpec {
            group_path: vec!["outer".into()],
            ..Default::default()
        };
        let prepared = Prepared::from_039_view(GROUP_DOCUMENT, &view).unwrap();
        let plan = prepared.plan();
        assert_eq!(plan.step_count(), 2);
        assert_valid_wgsl(plan);
    }

    #[test]
    fn layer_blend_and_coverage_generate_valid_texture_and_buffer_wgsl() {
        use crate::scene::ap1::Root;
        let document = br#"{"schemaVersion":1,"graph":{"output":"layer","nodes":[
          {"id":"x","name":"Horizontal","operation":{"kind":"linearCoverage","start":[0,0],"end":[1,0]}},
          {"id":"y","name":"Vertical","operation":{"kind":"linearCoverage","start":[0,0],"end":[0,1]}},
          {"id":"add","name":"Combine","operation":{"kind":"combineCoverage","base":"x","other":"y","mode":"add"}},
          {"id":"subtract","name":"Remove","operation":{"kind":"combineCoverage","base":"add","other":"x","mode":"subtract"}},
          {"id":"adjust","name":"Adjust","operation":{"kind":"adjustCoverage","mask":"subtract","strength":0.5,"inverted":true}},
          {"id":"grade","name":"Grade","operation":{"kind":"corrector","image":"$input","mask":"adjust","exposureEV":1,"curve":[],"strength":1,"enabled":true}},
          {"id":"layer","name":"Blend","operation":{"kind":"layer","base":"$input","enabled":true,
              "layers":[{"image":"grade","weight":1,"mode":"soft-light"}]}}
        ]}}"#;
        let prepared = Prepared::from_039(document, Root::Final).unwrap();
        assert_eq!(prepared.plan().step_count(), 7);
        assert_valid_wgsl(prepared.plan());
    }

    fn assert_valid_wgsl(plan: &Plan) {
        use wgpu::naga::{
            front::wgsl::parse_str,
            valid::{Capabilities, ValidationFlags, Validator},
        };

        for shader in [texture_wgsl(plan), super::super::wgsl(plan)] {
            let module = parse_str(&shader).unwrap();
            Validator::new(ValidationFlags::all(), Capabilities::empty())
                .validate(&module)
                .unwrap();
        }
    }

    #[test]
    fn native_budget_uses_checked_physical_charge() {
        assert_eq!(charge(18, [2, 4, 8, 4]).unwrap(), 18);
        assert!(matches!(
            charge(17, [2, 4, 8, 4]),
            Err(SceneError::Budget(_))
        ));
        assert!(matches!(
            charge(u64::MAX, [u64::MAX, 1, 0, 0]),
            Err(SceneError::Budget(_))
        ));
    }

    #[test]
    fn native_blend_numeric_rejection_preserves_other_frame_errors() {
        assert!(validate_shader_result(0).is_ok());
        assert!(matches!(
            validate_shader_result(LAYER_BLEND_NUMERIC_FLAG),
            Err(SceneError::Unsupported(message)) if message.contains("0x8")
        ));
        for flags in [0x4, 0x4 | LAYER_BLEND_NUMERIC_FLAG] {
            assert!(matches!(
                validate_shader_result(flags),
                Err(SceneError::Render(_))
            ));
        }
    }
}
