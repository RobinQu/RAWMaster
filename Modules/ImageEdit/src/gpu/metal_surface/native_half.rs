//! Joined physical half-resolution rendering for opaque, producer-complete RAW textures.
use super::{Metal, NativeJoin, SurfaceFrame};
use crate::{
    ffi::ImagePlan,
    gpu::{parameter_bytes, Gpu, ProgramInputs},
    graph::{BASIC_V3, COLOR_GRADING_V2, CURVES_LEVELS_V3, MASK, MASK_TONE_V3, SOURCE},
    Plan,
};
use foreign_types::{ForeignType, ForeignTypeRef};
use metal::{MTLPixelFormat, MTLTextureType, MTLTextureUsage};
use std::{
    ffi::c_void,
    fmt::Write,
    panic::{catch_unwind, AssertUnwindSafe},
    ptr, slice,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};
use wgpu::{BindGroupEntry as Entry, BindingResource as Binding, BufferUsages, TextureUsages};

extern "C" {
    fn rm_is_metal_device(object: *mut c_void) -> bool;
    fn rm_is_private_half_root(object: *mut c_void) -> bool;
    fn rm_new_half_shared_buffer(device: *mut c_void, length: u64) -> *mut c_void;
    #[cfg(feature = "native-half-probe")]
    fn rm_half_probe_gpu_seconds(object: *mut c_void) -> f64;
}

const LIMIT: u64 = 512 * 1024 * 1024;
const SCRATCH_LIMIT: u64 = 48 * 1024 * 1024;
const BAND: u32 = 256;
const STALE: i32 = 5;
type Current = extern "C" fn(*mut c_void, u64) -> u32;

static BUSY: AtomicBool = AtomicBool::new(false);
struct Admission;
impl Drop for Admission {
    fn drop(&mut self) {
        BUSY.store(false, Ordering::Release);
    }
}

pub struct HalfProgram {
    gpu: Gpu,
    inputs: ProgramInputs,
    direct: Option<wgpu::ComputePipeline>,
    band: wgpu::ComputePipeline,
    sample: wgpu::ComputePipeline,
    subgroup: Option<(wgpu::ComputePipeline, wgpu::ComputePipeline)>,
    gpu_failed: Arc<AtomicBool>,
    region_program: bool,
}

struct SharedStorage {
    host: metal::Buffer,
    storage: wgpu::Buffer,
}
struct BandBindings {
    params: wgpu::Buffer,
    producer: Option<wgpu::BindGroup>,
    consumer: wgpu::BindGroup,
}

// The Swift recipe writer preserves an identity basic_v3 for topology-stable rebinding.
// Check its real point-pass enable flags again on each product render.
fn product_recipe(plan: &Plan) -> bool {
    if plan.recipe_version() != 2 {
        return false;
    }
    if let [source, grading] = plan.steps.as_slice() {
        if source.op == SOURCE && grading.op == COLOR_GRADING_V2 && grading.a == 0 {
            return grading.rows[0][1] == 1.0;
        }
    }
    let curves = match plan.steps.as_slice() {
        [source, curves] if source.op == SOURCE && curves.a == 0 => curves,
        [source, basic, curves]
            if source.op == SOURCE
                && basic.op == BASIC_V3
                && basic.a == 0
                && basic.rows[1][3] == 0.0
                && curves.a == 1 =>
        {
            curves
        }
        _ => return false,
    };
    curves.op == CURVES_LEVELS_V3 && curves.rows[0][1] == 1.0
}

fn mask_recipe(plan: &Plan) -> bool {
    let [first, second, tone] = plan.steps.as_slice() else {
        return false;
    };
    plan.recipe_version() == 2
        && plan.mask_ids().len() == 1
        && tone.op == MASK_TONE_V3
        && tone.rows[2][0] == 1.0
        && ((first.op == SOURCE
            && second.op == MASK
            && second.a == 0
            && tone.a == 0
            && tone.mask == 1)
            || (first.op == MASK
                && first.a == 0
                && second.op == SOURCE
                && tone.a == 1
                && tone.mask == 0))
}

fn graph(plan: &Plan, subgroup: bool, region: bool) -> Option<String> {
    let tags: Vec<_> = plan.steps.iter().map(|s| s.op).collect();
    let masked = mask_recipe(plan);
    let grading = tags.as_slice() == [SOURCE, COLOR_GRADING_V2];
    if plan.recipe_version() != 2
        || !masked
            && !grading
            && !matches!(
                tags.as_slice(),
                [SOURCE]
                    | [SOURCE, BASIC_V3]
                    | [SOURCE, CURVES_LEVELS_V3]
                    | [SOURCE, BASIC_V3, CURVES_LEVELS_V3]
            )
    {
        return None;
    }
    let mut code = include_str!("native_half.wgsl").to_owned();
    if subgroup {
        code.push_str(
            "fn accumulate_receipt(lane: u32, count: u32) {
                let total = subgroupAdd(count);
                let first = subgroupBroadcastFirst(lane);
                if lane == first { atomicAdd(&visits, total); }
            }\n",
        );
    } else {
        code.push_str(
            "fn accumulate_receipt(lane: u32, count: u32) { atomicAdd(&visits, count); }\n",
        );
    }
    code.push_str(include_str!("../../point_operators.wgsl"));
    if masked {
        code.push_str(include_str!("../../premultiplied_f32.wgsl"));
        code.push_str(include_str!("../../mask_tone_v3.wgsl"));
        if region {
            code.push_str(include_str!("native_half_mask_region.wgsl"));
        } else {
            code.push_str(include_str!("native_half_mask.wgsl"));
            code.push_str(include_str!("native_half_main.wgsl"));
        }
        return Some(code);
    }
    code.push_str(include_str!("../../basic_v3.wgsl"));
    if grading {
        code.push_str(include_str!("../../premultiplied_f32.wgsl"));
        code.push_str(include_str!("../../color_grading_v2.wgsl"));
    } else {
        code.push_str(include_str!("../../curves_levels_v3.wgsl"));
    }
    code.push_str("fn half_point_graph(src: vec4<f32>, logical_position: vec2<u32>)->vec4<f32> { var p=src;\n");
    for (i, s) in plan.steps.iter().enumerate().skip(1) {
        if s.a as usize != i - 1 {
            return None;
        }
        let k = 3 * i;
        match s.op {
            BASIC_V3 => writeln!(
                code,
                "p=basic_v3(p,params.rows[{k}],params.rows[{}],params.rows[{}]);",
                k + 1,
                k + 2
            )
            .ok()?,
            CURVES_LEVELS_V3 => writeln!(
                code,
                "p=curves_levels_v3(p,{}u+u32(params.rows[{k}].x),params.rows[{k}].y!=0.0);",
                3 * plan.steps.len()
            )
            .ok()?,
            COLOR_GRADING_V2 => writeln!(
                code,
                "p=color_grading_v2(p,{}u+u32(params.rows[{k}].x),params.rows[{k}].y!=0.0);",
                3 * plan.steps.len()
            )
            .ok()?,
            _ => return None,
        }
        code.push_str("if !opaque_finite(p) { return invalid_pixel(); }\n");
    }
    code.push_str("return p; }\n");
    code.push_str(include_str!("native_half_main.wgsl"));
    Some(code)
}

impl HalfProgram {
    fn new(
        plan: &Plan,
        device: &metal::DeviceRef,
        probe: bool,
        region_program: bool,
    ) -> Result<Self, String> {
        let source = graph(plan, false, region_program).ok_or("unsupported native point graph")?;
        let filter = wgpu::Features::FLOAT32_FILTERABLE;
        let gpu = if probe {
            Gpu::open_for_native_device_with_features(device, filter | wgpu::Features::SUBGROUP)
                .or_else(|_| Gpu::open_for_native_device_with_features(device, filter))?
        } else {
            Gpu::open_for_native_device_with_features(device, filter)?
        };
        let gpu_failed = Arc::new(AtomicBool::new(false));
        let lost = Arc::clone(&gpu_failed);
        gpu.device
            .set_device_lost_callback(move |_, _| lost.store(true, Ordering::Release));
        let failed = Arc::clone(&gpu_failed);
        gpu.device
            .on_uncaptured_error(Arc::new(move |_| failed.store(true, Ordering::Release)));
        gpu.check_parameter_binding(plan)?;
        gpu.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let module = |source: String| {
            gpu.device
                .create_shader_module(wgpu::ShaderModuleDescriptor {
                    label: Some("native half-resolution point graph"),
                    source: wgpu::ShaderSource::Wgsl(source.into()),
                })
        };
        let pipeline = |shader: &wgpu::ShaderModule, entry| {
            gpu.device
                .create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                    label: Some(entry),
                    layout: None,
                    module: shader,
                    entry_point: Some(entry),
                    compilation_options: Default::default(),
                    cache: None,
                })
        };
        let shader = module(source);
        let direct = probe.then(|| pipeline(&shader, "direct_half"));
        let band = pipeline(&shader, "native_band");
        let sample = pipeline(&shader, "sampled_half");
        if let Some(error) = pollster::block_on(gpu.device.pop_error_scope()) {
            return Err(error.to_string());
        }
        let subgroup = if probe && gpu.device.features().contains(wgpu::Features::SUBGROUP) {
            gpu.device.push_error_scope(wgpu::ErrorFilter::Validation);
            let shader =
                module(graph(plan, true, region_program).ok_or("unsupported native point graph")?);
            let pair = (
                pipeline(&shader, "native_band"),
                pipeline(&shader, "sampled_half"),
            );
            // On devices without this optional lowering all pre-existing modes remain usable.
            pollster::block_on(gpu.device.pop_error_scope())
                .is_none()
                .then_some(pair)
        } else {
            None
        };
        Ok(Self {
            gpu,
            inputs: ProgramInputs::new(plan),
            direct,
            band,
            sample,
            subgroup,
            gpu_failed,
            region_program,
        })
    }

    unsafe fn import(
        &self,
        tex: &metal::TextureRef,
        format: wgpu::TextureFormat,
        usage: TextureUsages,
    ) -> Result<wgpu::Texture, i32> {
        let size = wgpu::Extent3d {
            width: tex.width() as u32,
            height: tex.height() as u32,
            depth_or_array_layers: 1,
        };
        let hal = wgpu::hal::metal::Device::texture_from_raw(
            tex.to_owned(),
            format,
            MTLTextureType::D2,
            1,
            1,
            size.into(),
        );
        let texture = self.gpu.device.create_texture_from_hal::<Metal>(
            hal,
            &wgpu::TextureDescriptor {
                label: Some("checked private native root"),
                size,
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage,
                view_formats: &[],
            },
        );
        if texture.as_hal::<Metal>().ok_or(3)?.raw_handle().as_ptr() != tex.as_ptr() {
            return Err(3);
        }
        Ok(texture)
    }

    unsafe fn shared_storage(
        &self,
        device: &metal::DeviceRef,
        length: u64,
        contents: Option<&[u8]>,
        label: &str,
    ) -> Result<SharedStorage, i32> {
        let object = rm_new_half_shared_buffer(device.as_ptr().cast(), length);
        if object.is_null() {
            return Err(2);
        }
        let host = metal::Buffer::from_ptr(object.cast());
        if !(length..=length + 16 * 1024).contains(&host.allocated_size()) {
            return Err(2);
        }
        if let Some(data) = contents {
            if data.len() as u64 != length {
                return Err(1);
            }
            ptr::copy_nonoverlapping(data.as_ptr(), host.contents().cast::<u8>(), data.len());
        }
        let hal = wgpu::hal::metal::Device::buffer_from_raw(host.clone(), length);
        let storage = self.gpu.device.create_buffer_from_hal::<Metal>(
            hal,
            &wgpu::BufferDescriptor {
                label: Some(label),
                size: length,
                usage: BufferUsages::STORAGE,
                mapped_at_creation: false,
            },
        );
        Ok(SharedStorage { host, storage })
    }

    fn bind(
        &self,
        pipeline: &wgpu::ComputePipeline,
        input: &wgpu::TextureView,
        output: &wgpu::TextureView,
        receipts: &wgpu::Buffer,
        params: &wgpu::Buffer,
        sampler: Option<&wgpu::Sampler>,
        coverage: Option<&wgpu::TextureView>,
    ) -> wgpu::BindGroup {
        let mut entries = vec![
            Entry {
                binding: 0,
                resource: Binding::TextureView(input),
            },
            Entry {
                binding: 1,
                resource: Binding::TextureView(output),
            },
            Entry {
                binding: 2,
                resource: receipts.as_entire_binding(),
            },
            Entry {
                binding: 3,
                resource: params.as_entire_binding(),
            },
        ];
        if let Some(mask) = coverage {
            entries.push(Entry {
                binding: 6,
                resource: Binding::TextureView(mask),
            });
        }
        if let Some(sampler) = sampler {
            entries.push(Entry {
                binding: 4,
                resource: Binding::Sampler(sampler),
            });
        }
        self.gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: None,
                layout: &pipeline.get_bind_group_layout(0),
                entries: &entries,
            })
    }

    unsafe fn render(
        &self,
        plan: &Plan,
        input: &metal::TextureRef,
        output: &metal::TextureRef,
        mode: u32,
        coverage: Option<&metal::TextureRef>,
        region: Option<MaskRegion>,
        current: impl Fn() -> bool,
    ) -> Result<(), i32> {
        if !self.inputs.accepts(plan)
            || mode > 6
            || input.as_ptr() == output.as_ptr()
            || self.region_program != region.is_some()
        {
            return Err(1);
        }
        if !current() {
            return Err(STALE);
        }
        if self.gpu_failed.load(Ordering::Acquire) {
            return Err(3);
        }
        let product = self.direct.is_none();
        if product
            && (mode != 6
                || !(if coverage.is_some() {
                    mask_recipe(plan)
                } else {
                    product_recipe(plan)
                })
                || !output.usage().contains(MTLTextureUsage::ShaderRead))
        {
            return Err(1);
        }
        let device = self.gpu.metal_device().map_err(|_| 2)?;
        if let Some(mask) = coverage {
            if mask.pixel_format() != MTLPixelFormat::R32Float
                || !mask.usage().contains(MTLTextureUsage::ShaderRead)
                || mask.width() != region.map_or(input.width(), |area| u64::from(area.width))
                || mask.height() != region.map_or(input.height(), |area| u64::from(area.height))
                || mask.as_ptr() == input.as_ptr()
                || mask.as_ptr() == output.as_ptr()
            {
                return Err(1);
            }
        }
        for tex in [Some(input), Some(output), coverage].into_iter().flatten() {
            if tex.device().as_ptr() != device.as_ptr()
                || tex.texture_type() != MTLTextureType::D2
                || tex.depth() != 1
                || tex.array_length() != 1
                || tex.mipmap_level_count() != 1
                || tex.sample_count() != 1
                || tex.allocated_size() == 0
                || !rm_is_private_half_root(tex.as_ptr().cast())
            {
                return Err(1);
            }
        }
        if input.pixel_format() != MTLPixelFormat::RGBA16Float
            || output.pixel_format() != MTLPixelFormat::RGBA32Float
            || !input.usage().contains(MTLTextureUsage::ShaderRead)
            || !output.usage().contains(MTLTextureUsage::ShaderWrite)
            || !(2..=9600).contains(&input.width())
            || !(2..=6400).contains(&input.height())
            || input.width() % 2 != 0
            || input.height() % 2 != 0
            || output.width() != input.width() / 2
            || output.height() != input.height() / 2
        {
            return Err(1);
        }
        let (width, height) = (input.width() as u32, input.height() as u32);
        let whole = MaskRegion {
            x: 0,
            y: 0,
            width,
            height,
            patch_only: 0,
        };
        let area = region.unwrap_or(whole);
        if !area.valid_for(width, height) {
            return Err(1);
        }
        let active = if area.patch_only == 1 { area } else { whole };
        let first_band = (active.y / BAND) as usize;
        let after_band = (active.y + active.height).div_ceil(BAND) as usize;
        let active_width = active.width;
        if BUSY
            .compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed)
            .is_err()
        {
            return Err(2);
        }
        let _admission = Admission;
        let band_count = after_band - first_band;
        let depth = match mode {
            5 => 2,
            6 => 4,
            _ => 1,
        }
        .min(band_count);
        let immutable_params = mode >= 5;
        let param_count = if immutable_params { band_count } else { 1 };
        #[cfg(feature = "native-half-probe")]
        let mut profile = (!product
            && std::env::var_os("RAWMASTER_PROFILE_HALF_COMMANDS").as_deref()
                == Some(std::ffi::OsStr::new("1")))
        .then(|| (std::time::Instant::now(), 0.0, 0));
        let hardware = mode >= 3;
        let (band_pipeline, sample_pipeline) = if mode == 4 {
            let pair = self.subgroup.as_ref().ok_or(2)?;
            (&pair.0, &pair.1)
        } else {
            (&self.band, &self.sample)
        };
        let consumer = if hardware {
            sample_pipeline
        } else {
            self.direct.as_ref().ok_or(2)?
        };
        let slots = groups(active_width / 2, active.height.min(BAND) / 2)
            + if hardware {
                groups(active_width, active.height.min(BAND))
            } else {
                0
            };
        let flag_bytes = u64::from(slots) * 4;
        let mut parameters = parameter_bytes(plan, width, height);
        parameters[12..16].copy_from_slice(&mode.to_ne_bytes());
        if self.region_program {
            for value in [
                area.x,
                area.y,
                area.width,
                area.height,
                active.x,
                active.width,
                0,
                0,
            ] {
                parameters.extend_from_slice(&(value as f32).to_ne_bytes());
            }
        }
        let scratch_estimate = if hardware {
            u64::from(width) * u64::from(BAND) * 16 + 4 * 1024 * 1024
        } else {
            0
        };
        // Standalone Metal buffers can occupy a full hardware page.
        let extra = (flag_bytes + 16 * 1024) * depth as u64
            + (parameters.len() as u64 + 16 * 1024) * param_count as u64
            + scratch_estimate
            + 64 * 1024;
        if (product && extra > SCRATCH_LIMIT)
            || output
                .allocated_size()
                .saturating_add(coverage.map_or(0, |mask| mask.allocated_size()))
                .saturating_add(extra)
                > LIMIT
            || extra
                > device
                    .recommended_max_working_set_size()
                    .saturating_sub(device.current_allocated_size())
        {
            return Err(2);
        }
        let src = self.import(
            input,
            wgpu::TextureFormat::Rgba16Float,
            TextureUsages::TEXTURE_BINDING,
        )?;
        let dst = self.import(
            output,
            wgpu::TextureFormat::Rgba32Float,
            TextureUsages::STORAGE_BINDING,
        )?;
        let coverage_view = coverage
            .map(|mask| {
                self.import(
                    mask,
                    wgpu::TextureFormat::R32Float,
                    TextureUsages::TEXTURE_BINDING,
                )
            })
            .transpose()?
            .map(|texture| texture.create_view(&Default::default()));
        let (src, dst) = (
            src.create_view(&Default::default()),
            dst.create_view(&Default::default()),
        );
        let mut receipts = Vec::with_capacity(depth);
        for _ in 0..depth {
            receipts.push(self.shared_storage(
                &device,
                flag_bytes,
                None,
                "per-band visited native samples",
            )?);
        }
        let hardware_band = if hardware {
            let tile = self.gpu.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("one reusable 256-row canonical float band"),
                size: wgpu::Extent3d {
                    width,
                    height: BAND,
                    depth_or_array_layers: 1,
                },
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba32Float,
                mip_level_count: 1,
                sample_count: 1,
                usage: TextureUsages::STORAGE_BINDING | TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            if tile
                .as_hal::<Metal>()
                .ok_or(3)?
                .raw_handle()
                .allocated_size()
                > scratch_estimate
            {
                return Err(2);
            }
            let view = tile.create_view(&Default::default());
            let sampler = self.gpu.device.create_sampler(&wgpu::SamplerDescriptor {
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            });
            Some((view, sampler))
        } else {
            None
        };
        let mut bindings = Vec::with_capacity(param_count);
        for band in 0..param_count {
            parameters[8..12].copy_from_slice(&((first_band + band) as u32 * BAND).to_ne_bytes());
            let usage = if immutable_params {
                BufferUsages::STORAGE
            } else {
                BufferUsages::STORAGE | BufferUsages::COPY_DST
            };
            // create_buffer_init(STORAGE) enqueues a deferred staging copy on unmap.
            // A product request revoked before its first submit must leave no pending queue writes.
            let params = if product {
                self.shared_storage(
                    &device,
                    parameters.len() as u64,
                    Some(&parameters),
                    "immutable native band parameters",
                )?
                .storage
            } else {
                self.gpu.initial(&parameters, usage)
            };
            let flag = &receipts[band % depth].storage;
            let (producer, consumer) = if let Some((view, sampler)) = &hardware_band {
                (
                    Some(self.bind(
                        band_pipeline,
                        &src,
                        view,
                        flag,
                        &params,
                        None,
                        coverage_view.as_ref(),
                    )),
                    self.bind(consumer, view, &dst, flag, &params, Some(sampler), None),
                )
            } else {
                (
                    None,
                    self.bind(consumer, &src, &dst, flag, &params, None, None),
                )
            };
            bindings.push(BandBindings {
                params,
                producer,
                consumer,
            });
        }
        for first in (first_band..after_band).step_by(depth) {
            let last = (first + depth).min(after_band);
            let mut encoder = self.gpu.device.create_command_encoder(&Default::default());
            for index in first..last {
                if !current() {
                    return Err(STALE);
                }
                let rows = (height - index as u32 * BAND).min(BAND);
                let used = groups(active_width / 2, rows / 2)
                    + if hardware {
                        groups(active_width, rows)
                    } else {
                        0
                    };
                let slot = &receipts[index - first];
                ptr::write_bytes(slot.host.contents().cast::<u32>(), 0, used as usize);
                let ports = &bindings[if immutable_params {
                    index - first_band
                } else {
                    0
                }];
                if let Some(group) = &ports.producer {
                    dispatch(&mut encoder, band_pipeline, group, active_width, rows);
                }
                // Each native producer is immediately followed by its hardware consumer.
                // The next pass may reuse the one hazard-tracked intermediate after that read.
                dispatch(
                    &mut encoder,
                    consumer,
                    &ports.consumer,
                    active_width / 2,
                    rows / 2,
                );
            }
            let fence = encoder
                .as_hal_mut::<Metal, _, _>(|h| h.and_then(|c| c.raw_command_buffer()).cloned())
                .ok_or(3)?;
            if !current() {
                return Err(STALE);
            }
            let fence = NativeJoin(fence);
            let commands = encoder.finish();
            // Queue writes remain pending until the next submit. A rejected band
            // must leave neither commands nor parameter uploads in the queue.
            if !immutable_params {
                self.gpu.queue.write_buffer(
                    &bindings[0].params,
                    8,
                    &(first as u32 * BAND).to_ne_bytes(),
                );
            }
            let ticket = self.gpu.queue.submit([commands]);
            let admitted = current();
            let poll = self.gpu.device.poll(wgpu::PollType::Wait {
                submission_index: Some(ticket),
                timeout: None,
            });
            SurfaceFrame::drain_native(&fence.0).map_err(|_| 3)?;
            #[cfg(feature = "native-half-probe")]
            if let Some((_, gpu_seconds, command_count)) = profile.as_mut() {
                *gpu_seconds += rm_half_probe_gpu_seconds(fence.0.as_ptr().cast());
                *command_count += 1;
            }
            if !admitted || !current() {
                return Err(STALE);
            }
            poll.map_err(|_| 3)?;
            if self.gpu_failed.load(Ordering::Acquire) {
                return Err(3);
            }
            for index in first..last {
                if index > first && !current() {
                    return Err(STALE);
                }
                let rows = (height - index as u32 * BAND).min(BAND);
                let native_slots = if hardware {
                    groups(active_width, rows) as usize
                } else {
                    0
                };
                let used = native_slots + groups(active_width / 2, rows / 2) as usize;
                let records = slice::from_raw_parts(
                    receipts[index - first].host.contents().cast::<u32>(),
                    used,
                );
                if hardware && !verified_groups(&records[..native_slots], active_width, rows, 1) {
                    return Err(3);
                }
                if !verified_groups(&records[native_slots..], active_width / 2, rows / 2, 4) {
                    return Err(3);
                }
            }
        }
        if current() {
            if self.gpu_failed.load(Ordering::Acquire) {
                return Err(3);
            }
            #[cfg(feature = "native-half-probe")]
            if let Some((profile_start, gpu_seconds, command_count)) = profile {
                eprintln!("half-command-profile mode={mode} native={}x{} submissions={command_count} metal_ms={:.3} rust_wall_ms={:.3}",
                          width, height, gpu_seconds*1000.0, profile_start.elapsed().as_secs_f64()*1000.0);
            }
            Ok(())
        } else {
            Err(STALE)
        }
    }
}

fn groups(w: u32, h: u32) -> u32 {
    w.div_ceil(8) * h.div_ceil(8)
}
fn verified_groups(records: &[u32], w: u32, h: u32, visits: u32) -> bool {
    if records.len() < groups(w, h) as usize {
        return false;
    }
    let cols = w.div_ceil(8);
    for y in 0..h.div_ceil(8) {
        for x in 0..cols {
            let expected = (w - 8 * x).min(8) * (h - 8 * y).min(8) * visits;
            if records[(y * cols + x) as usize] != (0xa5000000 | expected) {
                return false;
            }
        }
    }
    true
}
fn dispatch(
    encoder: &mut wgpu::CommandEncoder,
    pipe: &wgpu::ComputePipeline,
    group: &wgpu::BindGroup,
    w: u32,
    h: u32,
) {
    let mut pass = encoder.begin_compute_pass(&Default::default());
    pass.set_pipeline(pipe);
    pass.set_bind_group(0, group, &[]);
    pass.dispatch_workgroups(w.div_ceil(8), h.div_ceil(8), 1);
}

unsafe fn open_program(
    recipe: *const ImagePlan,
    device: *mut c_void,
    out: *mut *mut HalfProgram,
    probe: bool,
    masked: bool,
    region: bool,
) -> i32 {
    if out.is_null() {
        return 1;
    }
    out.write(ptr::null_mut());
    catch_unwind(AssertUnwindSafe(|| {
        let Some(recipe) = recipe.as_ref() else {
            return 1;
        };
        if device.is_null()
            || !rm_is_metal_device(device)
            || (masked && !mask_recipe(&recipe.plan))
            || (!masked && (mask_recipe(&recipe.plan) || (!probe && !product_recipe(&recipe.plan))))
        {
            return 1;
        }
        match HalfProgram::new(
            &recipe.plan,
            metal::DeviceRef::from_ptr(device.cast()),
            probe,
            region,
        ) {
            Ok(program) => {
                out.write(Box::into_raw(Box::new(program)));
                0
            }
            Err(_) => 2,
        }
    }))
    .unwrap_or(4)
}
unsafe fn render_program(
    prog: *const HalfProgram,
    recipe: *const ImagePlan,
    input: *mut c_void,
    output: *mut c_void,
    mode: u32,
    mask: Option<(*const u8, usize, *mut c_void)>,
    region: Option<MaskRegion>,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        let (Some(program), Some(recipe), Some(check)) = (prog.as_ref(), recipe.as_ref(), current)
        else {
            return 1;
        };
        if !rm_is_private_half_root(input) || !rm_is_private_half_root(output) {
            return 1;
        }
        let coverage = if let Some((name, length, texture)) = mask {
            let ids = recipe.plan.mask_ids();
            if name.is_null()
                || !(1..=64).contains(&length)
                || ids.len() != 1
                || !rm_is_private_half_root(texture)
                || ids[0].as_bytes() != slice::from_raw_parts(name, length)
            {
                return 1;
            }
            Some(metal::TextureRef::from_ptr(texture.cast()))
        } else {
            None
        };
        program
            .render(
                &recipe.plan,
                metal::TextureRef::from_ptr(input.cast()),
                metal::TextureRef::from_ptr(output.cast()),
                mode,
                coverage,
                region,
                || check(context, revision) == 1,
            )
            .map_or_else(|code| code, |()| 0)
    }))
    .unwrap_or(4)
}
unsafe fn close_program(program: *mut HalfProgram) {
    if !program.is_null() {
        drop(Box::from_raw(program));
    }
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_half_program_open_v1(
    recipe: *const ImagePlan,
    device: *mut c_void,
    out: *mut *mut HalfProgram,
) -> i32 {
    open_program(recipe, device, out, false, false, false)
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_half_render_v1(
    program: *const HalfProgram,
    parameters: *const ImagePlan,
    input: *mut c_void,
    output: *mut c_void,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    render_program(
        program, parameters, input, output, 6, None, None, revision, current, context,
    )
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_mask_half_program_open_v1(
    recipe: *const ImagePlan,
    device: *mut c_void,
    out: *mut *mut HalfProgram,
) -> i32 {
    open_program(recipe, device, out, false, true, false)
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_mask_half_render_v1(
    program: *const HalfProgram,
    parameters: *const ImagePlan,
    input: *mut c_void,
    name: *const u8,
    length: usize,
    mask: *mut c_void,
    output: *mut c_void,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    render_program(
        program,
        parameters,
        input,
        output,
        6,
        Some((name, length, mask)),
        None,
        revision,
        current,
        context,
    )
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MaskRegion {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    patch_only: u32,
}

impl MaskRegion {
    fn valid_for(self, width: u32, height: u32) -> bool {
        self.patch_only <= 1
            && self.x % 2 == 0
            && self.y % BAND == 0
            && self.width > 0
            && self.width % 2 == 0
            && self.height > 0
            && self.height % 2 == 0
            && self.x <= width
            && self.width <= width - self.x
            && self.y <= height
            && self.height <= height - self.y
            && (self.height % BAND == 0 || self.y + self.height == height)
    }
}

#[cfg(test)]
mod mask_region_tests {
    use super::MaskRegion;

    #[test]
    fn accepts_exact_even_tail_and_rejects_overflow_and_partial_bands() {
        let region = MaskRegion {
            x: 2,
            y: 256,
            width: 18,
            height: 14,
            patch_only: 1,
        };
        assert!(region.valid_for(30, 270));
        assert!(MaskRegion {
            patch_only: 0,
            ..region
        }
        .valid_for(30, 270));
        for bad in [
            MaskRegion { x: 1, ..region },
            MaskRegion { y: 2, ..region },
            MaskRegion {
                width: 17,
                ..region
            },
            MaskRegion { width: 0, ..region },
            MaskRegion {
                height: 12,
                ..region
            },
            MaskRegion {
                height: 0,
                ..region
            },
            MaskRegion {
                patch_only: 2,
                ..region
            },
            MaskRegion {
                x: u32::MAX - 1,
                ..region
            },
            MaskRegion {
                width: u32::MAX - 1,
                ..region
            },
            MaskRegion {
                height: u32::MAX - 1,
                ..region
            },
        ] {
            assert!(!bad.valid_for(30, 270));
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_mask_region_program_open_v1(
    recipe: *const ImagePlan,
    device: *mut c_void,
    out: *mut *mut HalfProgram,
) -> i32 {
    open_program(recipe, device, out, false, true, true)
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_mask_region_render_v1(
    program: *const HalfProgram,
    parameters: *const ImagePlan,
    input: *mut c_void,
    name: *const u8,
    length: usize,
    mask: *mut c_void,
    output: *mut c_void,
    region: *const MaskRegion,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    let Some(region) = region.as_ref() else {
        return 1;
    };
    render_program(
        program,
        parameters,
        input,
        output,
        6,
        Some((name, length, mask)),
        Some(*region),
        revision,
        current,
        context,
    )
}

#[no_mangle]
pub unsafe extern "C" fn rm_image_metal_half_program_close_v1(program: *mut HalfProgram) {
    close_program(program);
}

#[cfg(feature = "native-half-probe")]
#[no_mangle]
pub unsafe extern "C" fn rm_image_half_program_open_probe_v1(
    recipe: *const ImagePlan,
    device: *mut c_void,
    out: *mut *mut HalfProgram,
) -> i32 {
    open_program(recipe, device, out, true, false, false)
}

#[cfg(feature = "native-half-probe")]
#[no_mangle]
pub unsafe extern "C" fn rm_image_half_render_probe_v1(
    program: *const HalfProgram,
    parameters: *const ImagePlan,
    input: *mut c_void,
    output: *mut c_void,
    mode: u32,
    revision: u64,
    current: Option<Current>,
    context: *mut c_void,
) -> i32 {
    render_program(
        program, parameters, input, output, mode, None, None, revision, current, context,
    )
}

#[cfg(feature = "native-half-probe")]
#[no_mangle]
pub unsafe extern "C" fn rm_image_half_program_close_probe_v1(program: *mut HalfProgram) {
    close_program(program);
}
