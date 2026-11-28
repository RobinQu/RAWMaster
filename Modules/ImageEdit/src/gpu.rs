pub mod ap1_scene;
#[cfg(all(target_os = "macos", feature = "metal-surface"))]
pub mod metal_surface;

use crate::graph::{
    BASIC_V3, BLEND, COLOR_GRADING_V2, CURVES_LEVELS_V3, EXPOSURE, MASK, MASKED_EXPOSURE,
    MASK_TONE_V3, MATRIX, PHOTO_FILTER, SOURCE,
};
use crate::{check_output, Frame, Pixel, Plan};
use std::fmt::Write;
use std::sync::{mpsc, Arc};
use wgpu::{util::DeviceExt, Buffer, BufferUsages};

#[derive(Clone, Copy)]
pub enum Mode {
    Fused,
    Staged,
}

pub struct Gpu {
    identity: Arc<()>,
    device: wgpu::Device,
    queue: wgpu::Queue,
    layout: wgpu::BindGroupLayout,
    software_vulkan: bool,
    pub adapter: String,
}
struct Pass {
    pipeline: wgpu::ComputePipeline,
    left: usize,
    right: usize,
    out: usize,
}
struct ProgramInputs {
    version: u32,
    mask_ids: Vec<String>,
    topology: Vec<[u32; 4]>,
    atlas_digests: Vec<String>,
}
impl ProgramInputs {
    fn new(plan: &Plan) -> Self {
        Self {
            version: plan.recipe_version(),
            mask_ids: plan.mask_ids().to_vec(),
            topology: plan.topology(),
            atlas_digests: plan.assets.digests.clone(),
        }
    }

    fn accepts(&self, plan: &Plan) -> bool {
        self.version == plan.recipe_version()
            && (self.version == 1 || self.mask_ids == plan.mask_ids())
            && self.topology == plan.topology()
            && self.atlas_digests == plan.assets.digests
    }
}

pub struct Program {
    device_identity: Arc<()>,
    atlas: Buffer,
    inputs: ProgramInputs,
    passes: Vec<Pass>,
    slots: usize,
}
impl Program {
    // Explicit storage for source/intermediates, coverage and one readback.
    // Driver allocations and the host-owned input/output have separate budgets.
    pub fn bytes_per_pixel_with_readback(&self) -> u64 {
        // Keep the v1 no-mask budget conservative (the actual binding is a four-byte dummy).
        self.slots as u64 * 16 + 4 * self.inputs.mask_ids.len().max(1) as u64 + 16
    }
}

impl Gpu {
    pub fn render_bounded(
        &self,
        program: &Program,
        plan: &Plan,
        frame: &Frame,
        budget: u64,
    ) -> Result<(Vec<Pixel>, usize), String> {
        let masks = self.resolve_frame(program, plan, frame)?;
        let limits = self.device.limits();
        let width = u64::from(frame.width);
        let max_binding =
            u64::from(limits.max_storage_buffer_binding_size).min(limits.max_buffer_size);
        let constants = parameter_size(plan) as u64 + program.atlas.size();
        let plane_count = masks.len().max(1) as u64;
        if frame.width.div_ceil(16) > limits.max_compute_workgroups_per_dimension {
            return Err("image row exceeds GPU dispatch limit".into());
        }
        let rows = (budget.saturating_sub(constants)
            / (width * program.bytes_per_pixel_with_readback()))
        .min(max_binding / (width * 16))
        .min(max_binding / (width * plane_count * 4))
        .min((u64::from(u32::MAX) + 1) / (width * plane_count))
        .min(u64::from(limits.max_compute_workgroups_per_dimension) * 16)
        .min(u64::from(frame.height)) as usize;
        if rows == 0 {
            return Err("one full image row exceeds GPU budget".into());
        }
        let tile_pixels = rows * frame.width as usize;
        let mut result = if rows < frame.height as usize {
            Vec::with_capacity(frame.pixels.len())
        } else {
            Vec::new()
        };
        let mut tiles = 0;
        for (index, pixels) in frame.pixels.chunks(tile_pixels).enumerate() {
            let start = index * tile_pixels;
            let tile_masks: Vec<_> = masks
                .iter()
                .map(|plane| &plane[start..start + pixels.len()])
                .collect();
            // All current operators are pointwise. Each plane starts at this tile's absolute row.
            let height = (pixels.len() / frame.width as usize) as u32;
            let resident =
                self.bind_resolved(program, plan, frame.width, height, pixels, &tile_masks)?;
            resident.submit();
            let mut out = resident.read()?;
            if pixels.len() == frame.pixels.len() {
                return Ok((out, 1));
            }
            result.append(&mut out);
            tiles += 1;
        }
        Ok((result, tiles))
    }
    pub fn open() -> Result<Self, String> {
        pollster::block_on(Self::initialize())
    }

    async fn initialize() -> Result<Self, String> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                ..Default::default()
            })
            .await
            .map_err(|e| e.to_string())?;
        Self::from_adapter(adapter).await
    }

    async fn from_adapter(adapter: wgpu::Adapter) -> Result<Self, String> {
        Self::from_adapter_with_features(adapter, wgpu::Features::empty()).await
    }

    async fn from_adapter_with_features(
        adapter: wgpu::Adapter,
        features: wgpu::Features,
    ) -> Result<Self, String> {
        let info = adapter.get_info();
        if adapter.limits().max_storage_buffers_per_shader_stage < 6 {
            return Err("adapter has insufficient compute storage bindings".into());
        }
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("RAWMaster image processor"),
                required_limits: adapter.limits(),
                required_features: features,
                ..Default::default()
            })
            .await
            .map_err(|e| e.to_string())?;
        let entries: Vec<_> = (0..6)
            .map(|binding| wgpu::BindGroupLayoutEntry {
                binding,
                visibility: wgpu::ShaderStages::COMPUTE,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage {
                        read_only: binding != 3,
                    },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            })
            .collect();
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &entries,
        });
        Ok(Self {
            identity: Arc::new(()),
            device,
            queue,
            layout,
            software_vulkan: info.backend == wgpu::Backend::Vulkan
                && info.device_type == wgpu::DeviceType::Cpu,
            adapter: format!(
                "{} / {:?} / {:?}",
                info.name, info.backend, info.device_type
            ),
        })
    }

    fn pipeline(&self, plan: &Plan, only: Option<usize>) -> Result<wgpu::ComputePipeline, String> {
        self.pipeline_with_ports(plan, only, &self.layout, ShaderPorts::Buffers)
    }

    fn pipeline_with_ports(
        &self,
        plan: &Plan,
        only: Option<usize>,
        bindings: &wgpu::BindGroupLayout,
        ports: ShaderPorts,
    ) -> Result<wgpu::ComputePipeline, String> {
        let device = &self.device;
        device.push_error_scope(wgpu::ErrorFilter::Validation);
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("typed point operators"),
            source: wgpu::ShaderSource::Wgsl(shader(plan, only, ports).into()),
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[bindings],
            push_constant_ranges: &[],
        });
        let mut constants = Vec::new();
        if self.software_vulkan {
            if plan.steps.iter().any(|step| step.op == MASK_TONE_V3) {
                constants.push(("refine_software_vulkan_hue", 1.0));
            }
            if uses_basic_color(plan) {
                constants.push(("refine_software_vulkan_srgb", 1.0));
            }
        }
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: None,
            layout: Some(&layout),
            module: &shader,
            entry_point: Some("run"),
            compilation_options: wgpu::PipelineCompilationOptions {
                constants: &constants,
                ..Default::default()
            },
            cache: None,
        });
        match pollster::block_on(device.pop_error_scope()) {
            Some(error) => Err(error.to_string()),
            None => Ok(pipeline),
        }
    }

    fn atlas_buffer(&self, plan: &Plan) -> Result<wgpu::Buffer, String> {
        let limits = self.device.limits();
        if std::mem::size_of_val(plan.assets.pixels.as_slice()) as u64
            > u64::from(limits.max_storage_buffer_binding_size).min(limits.max_buffer_size)
        {
            return Err("selected atlases exceed this adapter’s per-buffer limit".into());
        }
        Ok(self.initial(
            if plan.assets.pixels.is_empty() {
                &[0; 16]
            } else {
                bytemuck::cast_slice(&plan.assets.pixels)
            },
            BufferUsages::STORAGE,
        ))
    }

    pub fn compile(&self, plan: &Plan, mode: Mode) -> Result<Program, String> {
        self.check_parameter_binding(plan)?;
        let atlas = self.atlas_buffer(plan)?;
        let inputs = ProgramInputs::new(plan);
        if matches!(mode, Mode::Fused) || plan.steps.len() == 1 {
            let pass = Pass {
                pipeline: self.pipeline(plan, None)?,
                left: 0,
                right: 0,
                out: 1,
            };
            return Ok(Program {
                device_identity: self.identity.clone(),
                atlas,
                inputs,
                passes: vec![pass],
                slots: 2,
            });
        }
        let mut last_use = vec![0; plan.steps.len()];
        for (index, step) in plan.steps.iter().enumerate() {
            match step.op {
                SOURCE | MASK => {}
                BLEND => {
                    last_use[step.a as usize] = index;
                    last_use[step.b as usize] = index;
                }
                // Every other image operator consumes its primary image input.
                _ => last_use[step.a as usize] = index,
            }
        }
        let mut slot_of = vec![0; plan.steps.len()];
        let mut occupied_through = vec![usize::MAX]; // Slot zero retains the original across slider updates.
        let mut passes = Vec::new();
        for (i, step) in plan.steps.iter().enumerate() {
            if matches!(step.op, SOURCE | MASK) {
                continue;
            }
            // An output must not alias either input within this pass.
            let out = occupied_through
                .iter()
                .position(|&last| last < i)
                .unwrap_or(occupied_through.len());
            if out == occupied_through.len() {
                occupied_through.push(0);
            }
            occupied_through[out] = last_use[i];
            slot_of[i] = out;
            passes.push(Pass {
                pipeline: self.pipeline(plan, Some(i))?,
                left: slot_of[step.a as usize],
                right: if step.op == BLEND {
                    slot_of[step.b as usize]
                } else {
                    0
                },
                out,
            });
        }
        Ok(Program {
            device_identity: self.identity.clone(),
            atlas,
            inputs,
            passes,
            slots: occupied_through.len(),
        })
    }

    fn check_parameter_binding(&self, plan: &Plan) -> Result<(), String> {
        let limits = self.device.limits();
        let maximum = u64::from(limits.max_storage_buffer_binding_size).min(limits.max_buffer_size);
        if parameter_size(plan) as u64 > maximum {
            return Err("operator parameters exceed this adapter's storage buffer limit".into());
        }
        Ok(())
    }

    pub fn bind<'a>(
        &'a self,
        program: &'a Program,
        plan: &Plan,
        frame: &Frame,
    ) -> Result<Resident<'a>, String> {
        let masks = self.resolve_frame(program, plan, frame)?;
        self.bind_resolved(
            program,
            plan,
            frame.width,
            frame.height,
            frame.pixels,
            &masks,
        )
    }

    fn resolve_frame<'f>(
        &self,
        program: &Program,
        plan: &Plan,
        frame: &Frame<'f>,
    ) -> Result<Vec<&'f [f32]>, String> {
        if !Arc::ptr_eq(&self.identity, &program.device_identity) || !program.inputs.accepts(plan) {
            return Err("incompatible device, graph, mask identities or atlas".into());
        }
        plan.resolve_masks(frame)
    }

    fn bind_resolved<'a>(
        &'a self,
        program: &'a Program,
        plan: &Plan,
        width: u32,
        height: u32,
        pixels: &[Pixel],
        masks: &[&[f32]],
    ) -> Result<Resident<'a>, String> {
        let size = std::mem::size_of_val(pixels) as u64;
        let limits = self.device.limits();
        let max_binding =
            u64::from(limits.max_storage_buffer_binding_size).min(limits.max_buffer_size);
        let plane_bytes = pixels.len() as u64 * 4;
        let mask_bytes = plane_bytes * masks.len() as u64;
        if size > max_binding
            || mask_bytes > max_binding
            || mask_bytes / 4 > u64::from(u32::MAX) + 1
            || width.div_ceil(16).max(height.div_ceil(16))
                > limits.max_compute_workgroups_per_dimension
        {
            return Err("frame exceeds device limits; supply a smaller tile".into());
        }
        let params = self.initial(
            &parameter_bytes(plan, width, height),
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let mask = match masks {
            [] => self.initial(&[0; 4], BufferUsages::STORAGE),
            [one] => self.initial(bytemuck::cast_slice(one), BufferUsages::STORAGE),
            _ => {
                // Upload into the actual mapped binding. Never assemble a second full host tensor.
                let buffer = self.device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("plane-major coverage"),
                    size: mask_bytes,
                    usage: BufferUsages::STORAGE,
                    mapped_at_creation: true,
                });
                {
                    let mut mapped = buffer.slice(..).get_mapped_range_mut();
                    for (dst, src) in mapped.chunks_exact_mut(plane_bytes as usize).zip(masks) {
                        dst.copy_from_slice(bytemuck::cast_slice(src));
                    }
                }
                buffer.unmap();
                buffer
            }
        };
        let mut slots = vec![self.initial(bytemuck::cast_slice(pixels), BufferUsages::STORAGE)];
        for _ in 1..program.slots {
            slots.push(self.buffer(size, BufferUsages::STORAGE | BufferUsages::COPY_SRC));
        }
        let bindings = program
            .passes
            .iter()
            .map(|pass| {
                let buffers = [
                    &slots[pass.left],
                    &slots[pass.right],
                    &mask,
                    &slots[pass.out],
                    &params,
                    &program.atlas,
                ];
                let entries: Vec<_> = buffers
                    .iter()
                    .enumerate()
                    .map(|(i, buf)| wgpu::BindGroupEntry {
                        binding: i as u32,
                        resource: buf.as_entire_binding(),
                    })
                    .collect();
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: &self.layout,
                    entries: &entries,
                })
            })
            .collect();
        let output = slots[program.passes.last().unwrap().out].clone();
        Ok(Resident {
            gpu: self,
            program,
            bindings,
            params,
            output,
            size,
            width,
            height,
        })
    }
    fn initial(&self, data: &[u8], usage: BufferUsages) -> Buffer {
        self.device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: None,
                contents: data,
                usage,
            })
    }
    fn buffer(&self, size: u64, usage: BufferUsages) -> Buffer {
        self.device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size,
            usage,
            mapped_at_creation: false,
        })
    }
    pub fn wait(&self) -> Result<(), String> {
        self.device
            .poll(wgpu::PollType::wait_indefinitely())
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}

fn parameter_size(plan: &Plan) -> usize {
    16 + plan.steps.len() * 48 + std::mem::size_of_val(plan.parameter_rows.as_slice())
}

fn parameter_bytes(plan: &Plan, width: u32, height: u32) -> Vec<u8> {
    let mut data = Vec::with_capacity(parameter_size(plan));
    data.extend_from_slice(bytemuck::bytes_of(&[width, height, 0u32, 0]));
    for step in &plan.steps {
        data.extend_from_slice(bytemuck::bytes_of(&step.rows));
    }
    data.extend_from_slice(bytemuck::cast_slice(&plan.parameter_rows));
    data
}

// Generate only from validated operator tags and integer slots. Parameters
// remain in a separate buffer, so a slider update does not recompile WGSL.
#[derive(Clone, Copy)]
enum ShaderPorts {
    Buffers,
    #[cfg(all(target_os = "macos", feature = "metal-surface"))]
    MetalTextures,
}

fn uses_basic_color(plan: &Plan) -> bool {
    plan.steps
        .iter()
        .any(|step| matches!(step.op, BASIC_V3 | CURVES_LEVELS_V3 | COLOR_GRADING_V2))
}

fn shader(plan: &Plan, only: Option<usize>, ports: ShaderPorts) -> String {
    let (bindings, source) = match ports {
        ShaderPorts::Buffers => (include_str!("kernels.wgsl"), "left[i]"),
        #[cfg(all(target_os = "macos", feature = "metal-surface"))]
        ShaderPorts::MetalTextures => (include_str!("metal_bindings.wgsl"), "surface_input"),
    };
    let mut code = bindings.to_owned();
    #[cfg(all(target_os = "macos", feature = "metal-surface"))]
    if matches!(ports, ShaderPorts::MetalTextures) {
        for slot in 1..plan.mask_ids().len() {
            writeln!(
                code,
                "@group(0) @binding({}) var input_mask{slot}: texture_2d<f32>;",
                5 + slot
            )
            .unwrap();
        }
    }
    code.push_str(include_str!("point_operators.wgsl"));
    let has_curves_levels = plan.steps.iter().any(|step| step.op == CURVES_LEVELS_V3);
    let has_grading = plan.steps.iter().any(|step| step.op == COLOR_GRADING_V2);
    let has_mask_tone = plan.steps.iter().any(|step| step.op == MASK_TONE_V3);
    if uses_basic_color(plan) {
        code.push_str(include_str!("basic_v3.wgsl"));
    }
    if has_curves_levels {
        code.push_str(include_str!("curves_levels_v3.wgsl"));
    }
    if has_mask_tone || has_grading {
        code.push_str(include_str!("premultiplied_f32.wgsl"));
    }
    if has_mask_tone {
        code.push_str(include_str!("mask_tone_v3.wgsl"));
    }
    if has_grading {
        code.push_str(include_str!("color_grading_v2.wgsl"));
    }
    code.push_str(include_str!("point_entry.wgsl"));
    #[cfg(all(target_os = "macos", feature = "metal-surface"))]
    if matches!(ports, ShaderPorts::MetalTextures) {
        code.push_str("    let surface_input = textureLoad(input_pixels, gid.xy, 0);\n");
        code.push_str("    if !lawful_pixel(surface_input, params.padding.x == 1u) { atomicOr(&validation, 1u); return; }\n");
        for slot in 0..plan.mask_ids().len() {
            let suffix = if slot == 0 {
                String::new()
            } else {
                slot.to_string()
            };
            writeln!(
                code,
                "    let surface_mask{suffix} = textureLoad(input_mask{suffix}, gid.xy, 0).x;"
            )
            .unwrap();
            writeln!(code, "    if !lawful_coverage(surface_mask{suffix}) {{ atomicOr(&validation, 2u); return; }}").unwrap();
        }
    }
    for (i, step) in plan.steps.iter().enumerate() {
        if only.is_some_and(|node| node != i) || step.op == MASK {
            continue;
        }
        let a = only.map_or_else(|| format!("p{}", step.a), |_| "left[i]".into());
        let b = only.map_or_else(|| format!("p{}", step.b), |_| "right[i]".into());
        let coverage = || {
            let slot = plan.steps[step.mask as usize].a;
            match ports {
                ShaderPorts::Buffers if slot == 0 => "coverage[i]".to_owned(),
                ShaderPorts::Buffers => {
                    format!("coverage[{slot}u * params.size.x * params.size.y + i]")
                }
                #[cfg(all(target_os = "macos", feature = "metal-surface"))]
                ShaderPorts::MetalTextures if slot == 0 => "surface_mask".to_owned(),
                #[cfg(all(target_os = "macos", feature = "metal-surface"))]
                ShaderPorts::MetalTextures => format!("surface_mask{slot}"),
            }
        };
        let row = i * 3;
        let expr = match step.op {
            SOURCE => source.to_owned(),
            EXPOSURE => format!("vec4<f32>({a}.rgb * params.rows[{row}].x, {a}.a)"),
            MATRIX => format!("vec4<f32>(dot({a}.rgb, params.rows[{row}].xyz), dot({a}.rgb, params.rows[{}].xyz), dot({a}.rgb, params.rows[{}].xyz), {a}.a)", row+1, row+2),
            PHOTO_FILTER => format!("photo_filter({a}, params.rows[{row}], params.rows[{}])", row + 1),
            MASKED_EXPOSURE => format!("masked_exposure({a}, {}, params.rows[{row}].x)", coverage()),
            MASK_TONE_V3 => format!("mask_tone_v3({a}, {}, params.rows[{row}], params.rows[{}], params.rows[{}].x)", coverage(), row + 1, row + 2),
            BASIC_V3 => format!("basic_v3({a}, params.rows[{row}], params.rows[{}], params.rows[{}])", row + 1, row + 2),
            CURVES_LEVELS_V3 => format!("curves_levels_v3({a}, {}u + u32(params.rows[{row}].x), params.rows[{row}].y != 0.0)", plan.steps.len() * 3),
            COLOR_GRADING_V2 => format!("color_grading_v2({a}, {}u + u32(params.rows[{row}].x), params.rows[{row}].y != 0.0)", plan.steps.len() * 3),
            BLEND => format!("blend({a}, {b}, {})", coverage()),
            _ => unreachable!(),
        };
        writeln!(code, "    let p{i} = {expr};").unwrap();
    }
    let result = only.unwrap_or(plan.steps.len() - 1);
    match ports {
        ShaderPorts::Buffers => writeln!(code, "    target_pixels[i] = p{result};"),
        #[cfg(all(target_os = "macos", feature = "metal-surface"))]
        ShaderPorts::MetalTextures => {
            writeln!(code, "    if !lawful_pixel(p{result}, false) {{ atomicOr(&validation, 4u); return; }}\n    textureStore(output_pixels, gid.xy, p{result});")
        }
    }
    .unwrap();
    code.push_str("}\n");
    code
}

pub struct Resident<'a> {
    gpu: &'a Gpu,
    program: &'a Program,
    bindings: Vec<wgpu::BindGroup>,
    params: Buffer,
    output: Buffer,
    size: u64,
    width: u32,
    height: u32,
}
impl Resident<'_> {
    pub fn dispatches(&self) -> usize {
        self.bindings.len()
    }
    pub fn rgba_slots(&self) -> usize {
        self.program.slots
    }
    pub fn update(&self, plan: &Plan) -> Result<(), String> {
        if !self.program.inputs.accepts(plan) {
            return Err("plan topology changed".into());
        }
        self.gpu.queue.write_buffer(
            &self.params,
            0,
            &parameter_bytes(plan, self.width, self.height),
        );
        Ok(())
    }
    pub fn submit(&self) {
        let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
        for (stage, binding) in self.program.passes.iter().zip(&self.bindings) {
            let mut pass = encoder.begin_compute_pass(&Default::default());
            pass.set_pipeline(&stage.pipeline);
            pass.set_bind_group(0, binding, &[]);
            pass.dispatch_workgroups(self.width.div_ceil(16), self.height.div_ceil(16), 1);
        }
        self.gpu.queue.submit([encoder.finish()]);
    }
    pub fn read(&self) -> Result<Vec<Pixel>, String> {
        let staging = self
            .gpu
            .buffer(self.size, BufferUsages::COPY_DST | BufferUsages::MAP_READ);
        let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
        encoder.copy_buffer_to_buffer(&self.output, 0, &staging, 0, self.size);
        self.gpu.queue.submit([encoder.finish()]);
        let slice = staging.slice(..);
        let (tx, rx) = mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = tx.send(result);
        });
        self.gpu.wait()?;
        rx.recv()
            .map_err(|e| e.to_string())?
            .map_err(|e| e.to_string())?;
        let result = bytemuck::cast_slice(&slice.get_mapped_range()).to_vec();
        staging.unmap();
        check_output(result)
    }
}
