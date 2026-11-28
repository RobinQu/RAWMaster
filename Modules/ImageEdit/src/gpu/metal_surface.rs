//! Same-device Metal image ports for host-owned surfaces and private native RAW textures.
mod native_half;

use super::{parameter_bytes, Gpu, ProgramInputs, ShaderPorts};
use crate::Plan;
use foreign_types::{ForeignType, ForeignTypeRef};
use metal::{
    MTLCommandBufferStatus, MTLPixelFormat, MTLStorageMode, MTLTextureType, MTLTextureUsage,
};
use std::{ffi::c_void, sync::Arc};
use wgpu::{BindGroupLayoutEntry as Entry, BindingType, ShaderStages, TextureFormat};
type Metal = wgpu::hal::api::Metal;

extern "C" {
    fn rm_surface_identity(texture: *mut c_void) -> u32;
}

pub struct SurfaceProgram {
    identity: Arc<()>,
    pipeline: wgpu::ComputePipeline,
    layout: wgpu::BindGroupLayout,
    atlas: wgpu::Buffer,
    inputs: ProgramInputs,
}
pub struct SurfaceFrame {
    gpu: Arc<Gpu>,
    program: Arc<SurfaceProgram>,
    group: wgpu::BindGroup,
    params: wgpu::Buffer,
    validation: metal::Buffer,
    textures: Vec<wgpu::Texture>,
    coverage_ids: Vec<u32>,
    width: u32,
    height: u32,
    /// Legacy projection: input, first coverage (input for no mask), output.
    pub surface_ids: [u32; 3],
}

pub(super) struct NativeJoin(pub(super) metal::CommandBuffer);
impl Drop for NativeJoin {
    fn drop(&mut self) {
        match self.0.status() {
            // Metal HAL commits submitted native buffers before Queue::submit returns.
            // A rejected, never-enqueued buffer has no outstanding GPU use.
            MTLCommandBufferStatus::NotEnqueued
            | MTLCommandBufferStatus::Completed
            | MTLCommandBufferStatus::Error => {}
            _ => self.0.wait_until_completed(),
        }
    }
}
impl Gpu {
    pub fn open_for_native_device(wanted: &metal::DeviceRef) -> Result<Self, String> {
        Self::open_for_native_device_with_features(wanted, wgpu::Features::empty())
    }

    fn open_for_native_device_with_features(
        wanted: &metal::DeviceRef,
        features: wgpu::Features,
    ) -> Result<Self, String> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL,
            ..Default::default()
        });
        for adapter in instance.enumerate_adapters(wgpu::Backends::METAL) {
            if let Ok(gpu) = pollster::block_on(Self::from_adapter_with_features(adapter, features))
            {
                let native = gpu.metal_device()?;
                if native.as_ptr() == wanted.as_ptr()
                    && native.registry_id() == wanted.registry_id()
                {
                    return Ok(gpu);
                }
            }
        }
        Err("wgpu has no matching native MTLDevice".into())
    }

    pub fn metal_device(&self) -> Result<metal::Device, String> {
        let device = unsafe { self.device.as_hal::<Metal>() }.ok_or("expected a Metal adapter")?;
        let raw = device.raw_device().lock().clone();
        Ok(raw)
    }

    pub fn compile_metal_surfaces(&self, plan: &Plan) -> Result<SurfaceProgram, String> {
        self.metal_device()?;
        self.check_parameter_binding(plan)?;
        let mask_bindings = plan.mask_ids().len().max(1) as u32;
        let limits = self.device.limits();
        // Metal's sampled and storage texture arguments use the same per-stage index space.
        if 5 + mask_bindings > limits.max_bindings_per_bind_group
            || 2 + mask_bindings > limits.max_sampled_textures_per_shader_stage
            || limits.max_storage_textures_per_shader_stage < 1
            || limits.max_storage_buffers_per_shader_stage < 3
            || limits.max_compute_workgroup_size_x < 16
            || limits.max_compute_workgroup_size_y < 16
            || limits.max_compute_invocations_per_workgroup < 256
        {
            return Err("named surface graph exceeds this device's compute binding limits".into());
        }
        let sampling = BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: false },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        };
        let output = BindingType::StorageTexture {
            access: wgpu::StorageTextureAccess::WriteOnly,
            format: TextureFormat::Rgba32Float,
            view_dimension: wgpu::TextureViewDimension::D2,
        };
        let storage = BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only: true },
            has_dynamic_offset: false,
            min_binding_size: None,
        };
        let mut entries: Vec<_> = [
            (0, sampling),
            (1, sampling),
            (2, output),
            (
                3,
                BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Storage { read_only: false },
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
            ),
            (4, storage),
            (5, storage),
        ]
        .into_iter()
        .map(|(binding, ty)| Entry {
            binding,
            visibility: ShaderStages::COMPUTE,
            ty,
            count: None,
        })
        .collect();
        for slot in 1..mask_bindings {
            entries.push(Entry {
                binding: 5 + slot,
                visibility: ShaderStages::COMPUTE,
                ty: sampling,
                count: None,
            });
        }
        let layout = self
            .device
            .create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("external RGBA32F and R32F surface views"),
                entries: &entries,
            });
        let pipeline = self.pipeline_with_ports(plan, None, &layout, ShaderPorts::MetalTextures)?;
        Ok(SurfaceProgram {
            identity: self.identity.clone(),
            pipeline,
            layout,
            atlas: self.atlas_buffer(plan)?,
            inputs: ProgramInputs::new(plan),
        })
    }

    /// Bind native textures to this compiled fused DAG.
    ///
    /// # Safety
    /// Inputs must be fully initialized, producer-joined, non-overlapping plane-zero IOSurfaces.
    /// Their exclusive native lease must outlive the GPU command and be held through native presentation.
    pub unsafe fn bind_metal_surfaces(
        self: &Arc<Self>,
        program: &Arc<SurfaceProgram>,
        plan: &Plan,
        native: [&metal::TextureRef; 3],
    ) -> Result<SurfaceFrame, String> {
        if plan.recipe_version() != 1 {
            return Err("positional surfaces require a version 1 recipe".into());
        }
        let masks = if plan.needs_mask() {
            &native[1..2]
        } else {
            if native[1].as_ptr() != native[0].as_ptr() {
                return Err("unused external mask".into());
            }
            &native[0..0]
        };
        self.bind_ordered_surfaces(program, plan, native[0], masks, native[2])
    }

    /// Bind a graph by exact coverage ID. Input order carries no meaning.
    ///
    /// # Safety
    /// The caller owns a producer-joined, immutable, plane-zero IOSurface for each input,
    /// and an exclusive unpublished output. The leases must cover the last GPU/native use.
    pub unsafe fn bind_named_metal_surfaces(
        self: &Arc<Self>,
        program: &Arc<SurfaceProgram>,
        plan: &Plan,
        input: &metal::TextureRef,
        coverage: &[(&str, &metal::TextureRef)],
        output: &metal::TextureRef,
    ) -> Result<SurfaceFrame, String> {
        let ordered = plan.order_masks(coverage.iter().copied())?;
        self.bind_ordered_surfaces(program, plan, input, &ordered, output)
    }

    unsafe fn bind_ordered_surfaces(
        self: &Arc<Self>,
        program: &Arc<SurfaceProgram>,
        plan: &Plan,
        input: &metal::TextureRef,
        coverage: &[&metal::TextureRef],
        output: &metal::TextureRef,
    ) -> Result<SurfaceFrame, String> {
        if !Arc::ptr_eq(&self.identity, &program.identity) || !program.inputs.accepts(plan) {
            return Err("surface plan or device mismatch".into());
        }
        let device = self.metal_device()?;
        if !device.has_unified_memory() {
            return Err("external surface path requires a unified-memory device".into());
        }
        let (width, height) = (
            u32::try_from(input.width()).map_err(|_| "extent overflow")?,
            u32::try_from(input.height()).map_err(|_| "extent overflow")?,
        );
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let limits = self.device.limits();
        if width == 0
            || height == 0
            || width.max(height) > limits.max_texture_dimension_2d
            || width.div_ceil(16).max(height.div_ceil(16))
                > limits.max_compute_workgroups_per_dimension
        {
            return Err("invalid external texture extent".into());
        }
        let native: Vec<_> = [input, output]
            .into_iter()
            .chain(coverage.iter().copied())
            .collect();
        let mut ids = Vec::with_capacity(native.len());
        for texture in &native {
            let id = rm_surface_identity(texture.as_ptr().cast());
            if id == 0 || ids.contains(&id) {
                return Err("missing or aliased IOSurface".into());
            }
            ids.push(id);
        }
        let import = |t: &metal::TextureRef,
                      native_format: MTLPixelFormat,
                      format: TextureFormat,
                      required: MTLTextureUsage,
                      usage: wgpu::TextureUsages|
         -> Result<wgpu::Texture, String> {
            if t.device().as_ptr() != device.as_ptr()
                || t.device().registry_id() != device.registry_id()
                || t.width() != u64::from(width)
                || t.height() != u64::from(height)
                || t.array_length() != 1
                || t.mipmap_level_count() != 1
                || t.sample_count() != 1
                || t.texture_type() != MTLTextureType::D2
                || t.storage_mode() != MTLStorageMode::Shared
                || t.pixel_format() != native_format
                || !t.usage().contains(required)
            {
                return Err("external surface descriptor/device mismatch".into());
            }
            let h = wgpu::hal::metal::Device::texture_from_raw(
                t.to_owned(),
                format,
                MTLTextureType::D2,
                1,
                1,
                size.into(),
            );
            let texture = self.device.create_texture_from_hal::<Metal>(
                h,
                &wgpu::TextureDescriptor {
                    label: None,
                    size,
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format,
                    usage,
                    view_formats: &[],
                },
            );
            if texture
                .as_hal::<Metal>()
                .ok_or("missing Metal texture")?
                .raw_handle()
                .as_ptr()
                != t.as_ptr()
            {
                return Err("external storage was substituted".into());
            }
            Ok(texture)
        };
        let mut textures = Vec::with_capacity(native.len());
        textures.push(import(
            input,
            MTLPixelFormat::RGBA32Float,
            TextureFormat::Rgba32Float,
            MTLTextureUsage::ShaderRead,
            wgpu::TextureUsages::TEXTURE_BINDING,
        )?);
        textures.push(import(
            output,
            MTLPixelFormat::RGBA32Float,
            TextureFormat::Rgba32Float,
            MTLTextureUsage::ShaderWrite,
            wgpu::TextureUsages::STORAGE_BINDING,
        )?);
        for texture in coverage {
            textures.push(import(
                texture,
                MTLPixelFormat::R32Float,
                TextureFormat::R32Float,
                MTLTextureUsage::ShaderRead,
                wgpu::TextureUsages::TEXTURE_BINDING,
            )?);
        }
        let views: Vec<_> = textures
            .iter()
            .map(|t| t.create_view(&Default::default()))
            .collect();
        let validation = device.new_buffer(4, metal::MTLResourceOptions::StorageModeShared);
        validation.contents().cast::<u32>().write_volatile(0);
        let hal_validation = wgpu::hal::metal::Device::buffer_from_raw(validation.clone(), 4);
        let flag = self.device.create_buffer_from_hal::<Metal>(
            hal_validation,
            &wgpu::BufferDescriptor {
                label: Some("single shared validation word"),
                size: 4,
                usage: wgpu::BufferUsages::STORAGE,
                mapped_at_creation: false,
            },
        );
        let params = self.initial(
            &surface_parameters(plan, width, height),
            wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        );
        let mut entries = vec![
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&views[0]),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(views.get(2).unwrap_or(&views[0])),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: wgpu::BindingResource::TextureView(&views[1]),
            },
            wgpu::BindGroupEntry {
                binding: 3,
                resource: flag.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 4,
                resource: params.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 5,
                resource: program.atlas.as_entire_binding(),
            },
        ];
        for (slot, view) in views[2..].iter().enumerate().skip(1) {
            entries.push(wgpu::BindGroupEntry {
                binding: 5 + slot as u32,
                resource: wgpu::BindingResource::TextureView(view),
            });
        }
        let group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &program.layout,
            entries: &entries,
        });
        Ok(SurfaceFrame {
            gpu: self.clone(),
            program: program.clone(),
            group,
            params,
            validation,
            textures,
            width,
            height,
            surface_ids: [ids[0], ids.get(2).copied().unwrap_or(ids[0]), ids[1]],
            coverage_ids: ids[2..].to_vec(),
        })
    }
}
fn surface_parameters(plan: &Plan, width: u32, height: u32) -> Vec<u8> {
    let mut parameters = parameter_bytes(plan, width, height);
    parameters[8..12].copy_from_slice(&(plan.accepts_raw_transport() as u32).to_ne_bytes());
    parameters
}

impl SurfaceFrame {
    pub fn update(&mut self, plan: &Plan) -> Result<(), String> {
        if !self.program.inputs.accepts(plan) {
            return Err("incompatible graph or atlas".into());
        }
        self.gpu.queue.write_buffer(
            &self.params,
            0,
            &surface_parameters(plan, self.width, self.height),
        );
        Ok(())
    }
    pub fn borrowed_backings(&self) -> usize {
        self.textures.len()
    }

    /// Original IOSurface IDs in the compiled coverage slot order.
    pub fn coverage_surface_ids(&self) -> &[u32] {
        &self.coverage_ids
    }

    fn command(
        &mut self,
        predecessor: Option<&metal::SharedEventRef>,
    ) -> Result<(wgpu::SubmissionIndex, NativeJoin), String> {
        unsafe {
            self.validation.contents().cast::<u32>().write_volatile(0);
        }
        let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
        if let Some(event) = predecessor {
            let installed = unsafe {
                encoder.as_hal_mut::<Metal, _, _>(|h| {
                    h.and_then(|c| c.raw_command_buffer())
                        .map(|c| c.encode_wait_for_event(event, 1))
                        .is_some()
                })
            };
            if !installed {
                return Err("native predecessor fence unavailable".into());
            }
        }
        {
            let mut pass = encoder.begin_compute_pass(&Default::default());
            pass.set_pipeline(&self.program.pipeline);
            pass.set_bind_group(0, &self.group, &[]);
            pass.dispatch_workgroups(self.width.div_ceil(16), self.height.div_ceil(16), 1);
        }
        let fence = unsafe {
            encoder.as_hal_mut::<Metal, _, _>(|h| h.and_then(|c| c.raw_command_buffer()).cloned())
        };
        let fence = fence.ok_or("native completion fence unavailable before submit")?;
        let ticket = self.gpu.queue.submit([encoder.finish()]);
        Ok((ticket, NativeJoin(fence)))
    }

    /// A worker retains every lease while the native command drains, including on a failed wgpu poll.
    pub(super) fn drain_native(fence: &metal::CommandBufferRef) -> Result<(), String> {
        if fence.status() == MTLCommandBufferStatus::NotEnqueued {
            return Err("Metal rejected the encoded command before submission".into());
        }
        fence.wait_until_completed();
        match fence.status() {
            MTLCommandBufferStatus::Completed => Ok(()),
            status => Err(format!("Metal completion status {status:?}")),
        }
    }

    pub fn submit_join(
        &mut self,
        after_submit: impl FnOnce() -> Result<(), String>,
    ) -> Result<(), String> {
        let (ticket, fence) = self.command(None)?;
        let admitted = after_submit();
        // A stale submit must release its borrowed textures only after the recorded work drains.
        let poll = self.gpu.device.poll(wgpu::PollType::Wait {
            submission_index: Some(ticket),
            timeout: None,
        });
        Self::drain_native(&fence.0)?;
        poll.map_err(|error| error.to_string())?;
        admitted?;
        let bad = unsafe { self.validation.contents().cast::<u32>().read_volatile() };
        if bad != 0 {
            return Err(format!("invalid surface pixels (flags {bad})"));
        }
        Ok(())
    }

    /// Probe-only predecessor forces an actual timeout on this submission. Native completion
    /// remains observable even after wgpu's zero-deadline wait reports failure.
    #[cfg(feature = "surface-fence-probe")]
    pub fn probe_timeout_and_drain(&mut self) -> Result<(), String> {
        use std::{sync::mpsc, thread, time::Duration};
        let event = self.gpu.metal_device()?.new_shared_event();
        let (ticket, fence) = self.command(Some(&event))?;
        let (tx, rx) = mpsc::channel::<()>();
        let guard = event.clone();
        let watchdog = thread::spawn(move || {
            if rx.recv_timeout(Duration::from_millis(500)).is_err() {
                guard.set_signaled_value(1);
            }
        });
        let poll = self.gpu.device.poll(wgpu::PollType::Wait {
            submission_index: Some(ticket),
            timeout: Some(Duration::ZERO),
        });
        event.set_signaled_value(1);
        let _ = tx.send(());
        let _ = watchdog.join();
        Self::drain_native(&fence.0)?;
        match poll {
            Err(wgpu::PollError::Timeout) => Ok(()),
            other => Err(format!("expected a real wgpu timeout, got {other:?}")),
        }
    }
}
