use crate::graph::{BLEND, EXPOSURE, MASK, MATRIX, SOURCE};
use crate::{check_output, Frame, Pixel, Plan};
use std::fmt::Write;
use std::sync::mpsc;
use wgpu::{util::DeviceExt, Buffer, BufferUsages};

#[derive(Clone, Copy)]
pub enum Mode {
    Fused,
    Staged,
}

pub struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    layout: wgpu::BindGroupLayout,
    pub adapter: String,
}
struct Pass {
    pipeline: wgpu::ComputePipeline,
    left: usize,
    right: usize,
    out: usize,
}
pub struct Program {
    topology: Vec<[u32; 4]>,
    passes: Vec<Pass>,
    slots: usize,
}
impl Program {
    // Explicit storage for source/intermediates, coverage and one readback.
    // Driver allocations and the host-owned input/output have separate budgets.
    pub fn bytes_per_pixel_with_readback(&self) -> u64 {
        self.slots as u64 * 16 + 4 + 16
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
        let limits = self.device.limits();
        let width = u64::from(frame.width);
        let max_binding =
            u64::from(limits.max_storage_buffer_binding_size).min(limits.max_buffer_size);
        let constants = 16 + plan.steps.len() as u64 * 48;
        let rows = (budget.saturating_sub(constants)
            / (width * program.bytes_per_pixel_with_readback()))
        .min(max_binding / (width * 16))
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
        for (pixels, mask) in frame
            .pixels
            .chunks(tile_pixels)
            .zip(frame.mask.chunks(tile_pixels))
        {
            // All current operators are pointwise. A spatial or reduction node needs its own tiling rule.
            let tile = Frame {
                width: frame.width,
                height: (pixels.len() / frame.width as usize) as u32,
                pixels,
                mask,
            };
            let resident = self.bind(program, plan, &tile)?;
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
        let info = adapter.get_info();
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("RAWMaster image probe"),
                required_limits: adapter.limits(),
                ..Default::default()
            })
            .await
            .map_err(|e| e.to_string())?;
        let entries: Vec<_> = (0..5)
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
            device,
            queue,
            layout,
            adapter: format!(
                "{} / {:?} / {:?}",
                info.name, info.backend, info.device_type
            ),
        })
    }

    fn pipeline(&self, plan: &Plan, only: Option<usize>) -> Result<wgpu::ComputePipeline, String> {
        let device = &self.device;
        device.push_error_scope(wgpu::ErrorFilter::Validation);
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("typed point operators"),
            source: wgpu::ShaderSource::Wgsl(shader(plan, only).into()),
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[&self.layout],
            push_constant_ranges: &[],
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: None,
            layout: Some(&layout),
            module: &shader,
            entry_point: Some("run"),
            compilation_options: Default::default(),
            cache: None,
        });
        match pollster::block_on(device.pop_error_scope()) {
            Some(error) => Err(error.to_string()),
            None => Ok(pipeline),
        }
    }

    pub fn compile(&self, plan: &Plan, mode: Mode) -> Result<Program, String> {
        let topology = plan.topology();
        if matches!(mode, Mode::Fused) || plan.steps.len() == 1 {
            let pass = Pass {
                pipeline: self.pipeline(plan, None)?,
                left: 0,
                right: 0,
                out: 1,
            };
            return Ok(Program {
                topology,
                passes: vec![pass],
                slots: 2,
            });
        }
        let mut last_use = vec![0; plan.steps.len()];
        for (index, step) in plan.steps.iter().enumerate() {
            match step.op {
                EXPOSURE | MATRIX => last_use[step.a as usize] = index,
                BLEND => {
                    last_use[step.a as usize] = index;
                    last_use[step.b as usize] = index;
                }
                _ => {}
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
            topology,
            passes,
            slots: occupied_through.len(),
        })
    }

    pub fn bind<'a>(
        &'a self,
        program: &'a Program,
        plan: &Plan,
        frame: &Frame,
    ) -> Result<Resident<'a>, String> {
        if plan.topology() != program.topology {
            return Err("plan topology changed".into());
        }
        let size = std::mem::size_of_val(frame.pixels) as u64;
        let limits = self.device.limits();
        if size > u64::from(limits.max_storage_buffer_binding_size)
            || size > limits.max_buffer_size
            || frame.width.div_ceil(16).max(frame.height.div_ceil(16))
                > limits.max_compute_workgroups_per_dimension
        {
            return Err("frame exceeds device limits; supply a smaller tile".into());
        }
        let params = self.initial(
            &parameter_bytes(plan, frame.width, frame.height),
            BufferUsages::STORAGE | BufferUsages::COPY_DST,
        );
        let mask = self.initial(bytemuck::cast_slice(frame.mask), BufferUsages::STORAGE);
        let mut slots =
            vec![self.initial(bytemuck::cast_slice(frame.pixels), BufferUsages::STORAGE)];
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
            width: frame.width,
            height: frame.height,
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

fn parameter_bytes(plan: &Plan, width: u32, height: u32) -> Vec<u8> {
    let mut data = bytemuck::bytes_of(&[width, height, 0u32, 0]).to_vec();
    for step in &plan.steps {
        data.extend(bytemuck::bytes_of(&step.rows));
    }
    data
}

// Generate only from validated operator tags and integer slots. Parameters
// remain in a separate buffer, so a slider update does not recompile WGSL.
fn shader(plan: &Plan, only: Option<usize>) -> String {
    let mut code = include_str!("kernels.wgsl").to_owned();
    for (i, step) in plan.steps.iter().enumerate() {
        if only.is_some_and(|node| node != i) || step.op == MASK {
            continue;
        }
        let a = only.map_or_else(|| format!("p{}", step.a), |_| "left[i]".into());
        let b = only.map_or_else(|| format!("p{}", step.b), |_| "right[i]".into());
        let row = i * 3;
        let expr = match step.op {
            SOURCE => "left[i]".to_owned(),
            EXPOSURE => format!("vec4<f32>({a}.rgb * params.rows[{row}].x, {a}.a)"),
            MATRIX => format!("vec4<f32>(dot({a}.rgb, params.rows[{row}].xyz), dot({a}.rgb, params.rows[{}].xyz), dot({a}.rgb, params.rows[{}].xyz), {a}.a)", row+1, row+2),
            BLEND => format!("blend({a}, {b}, coverage[i])"),
            _ => unreachable!(),
        };
        writeln!(code, "    let p{i} = {expr};").unwrap();
    }
    writeln!(
        code,
        "    target_pixels[i] = p{};\n}}",
        only.unwrap_or(plan.steps.len() - 1)
    )
    .unwrap();
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
        if plan.topology() != self.program.topology {
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
