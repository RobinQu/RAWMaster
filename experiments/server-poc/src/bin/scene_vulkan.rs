//! Headless wgpu/Vulkan feasibility harness for the 039 scene graph.
//!
//! This is a PoC, not the production Linux executor. It parses the same bounded scene JSON,
//! evaluates analytic coverage and the color graph over bounded tiles, retains a prefix cache,
//! emits a completion receipt, and can compare every pixel with a macOS Metal reference dump.

use bytemuck::{Pod, Zeroable};
use memmap2::{Mmap, MmapMut};
use rawmaster_server_poc::scene::{self, Blend, CoverageCombine, Operation, Scope};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::error::Error;
use std::fs::{File, OpenOptions};
use std::hash::{Hash, Hasher};
use std::num::NonZeroU64;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use wgpu::util::DeviceExt;

const WGSL: &str = include_str!("../scene_vulkan.wgsl");
const IMAGE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba32Float;
const COVERAGE_FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::R32Float;

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Params {
    scalars: [f32; 4],
    geometry: [u32; 4],
    kind: u32,
    parameter: u32,
    _pad: [u32; 2],
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Domain {
    Image,
    Coverage,
}

struct BudgetState {
    maximum: u64,
    live: AtomicU64,
    peak: AtomicU64,
}

impl BudgetState {
    fn new(maximum: u64) -> Arc<Self> {
        Arc::new(Self {
            maximum,
            live: AtomicU64::new(0),
            peak: AtomicU64::new(0),
        })
    }

    fn reserve(&self, bytes: u64) -> Result<(), String> {
        let mut current = self.live.load(Ordering::Relaxed);
        loop {
            let next = current.saturating_add(bytes);
            if next > self.maximum {
                return Err(format!(
                    "scene surface budget exceeded: {} + {} > {}",
                    current, bytes, self.maximum
                ));
            }
            match self.live.compare_exchange_weak(
                current,
                next,
                Ordering::Relaxed,
                Ordering::Relaxed,
            ) {
                Ok(_) => {
                    self.peak.fetch_max(next, Ordering::Relaxed);
                    return Ok(());
                }
                Err(actual) => current = actual,
            }
        }
    }

    fn release(&self, bytes: u64) {
        self.live.fetch_sub(bytes, Ordering::Relaxed);
    }

    fn reset_peak(&self) {
        self.peak
            .store(self.live.load(Ordering::Relaxed), Ordering::Relaxed);
    }

    fn peak(&self) -> u64 {
        self.peak.load(Ordering::Relaxed)
    }
}

struct SurfaceInner {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    width: u32,
    height: u32,
    bytes: u64,
    budget: Arc<BudgetState>,
}

impl Drop for SurfaceInner {
    fn drop(&mut self) {
        self.budget.release(self.bytes);
    }
}

#[derive(Clone)]
struct Surface {
    inner: Arc<SurfaceInner>,
}

impl Surface {
    fn new(
        device: &wgpu::Device,
        budget: Arc<BudgetState>,
        width: u32,
        height: u32,
        domain: Domain,
        label: &str,
    ) -> Result<Self, String> {
        let format = match domain {
            Domain::Image => IMAGE_FORMAT,
            Domain::Coverage => COVERAGE_FORMAT,
        };
        let bytes =
            u64::from(width) * u64::from(height) * if domain == Domain::Image { 16 } else { 4 };
        budget.reserve(bytes)?;
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some(label),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::STORAGE_BINDING
                | wgpu::TextureUsages::COPY_SRC
                | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let view = texture.create_view(&wgpu::TextureViewDescriptor::default());
        Ok(Self {
            inner: Arc::new(SurfaceInner {
                texture,
                view,
                width,
                height,
                bytes,
                budget,
            }),
        })
    }

    fn texture(&self) -> &wgpu::Texture {
        &self.inner.texture
    }

    fn view(&self) -> &wgpu::TextureView {
        &self.inner.view
    }

    fn width(&self) -> u32 {
        self.inner.width
    }

    fn height(&self) -> u32 {
        self.inner.height
    }

    fn bytes(&self) -> u64 {
        self.inner.bytes
    }
}

struct CacheEntry {
    surface: Surface,
    last: u64,
    coverage: bool,
}

struct Cache {
    entries: HashMap<u64, CacheEntry>,
    bytes: u64,
    budget: u64,
    tick: u64,
}

impl Cache {
    fn new(budget: u64) -> Self {
        Self {
            entries: HashMap::new(),
            bytes: 0,
            budget,
            tick: 0,
        }
    }

    fn get(&mut self, key: u64, stats: &mut Stats) -> Option<Surface> {
        self.tick = self.tick.wrapping_add(1);
        let tick = self.tick;
        let entry = self.entries.get_mut(&key)?;
        entry.last = tick;
        let surface = entry.surface.clone();
        if entry.coverage {
            stats.coverage_hits += 1;
        } else {
            stats.node_hits += 1;
        }
        Some(surface)
    }

    fn put(&mut self, key: u64, surface: Surface, coverage: bool) {
        let bytes = surface.bytes();
        if bytes > self.budget {
            return;
        }
        if let Some(old) = self.entries.remove(&key) {
            self.bytes = self.bytes.saturating_sub(old.surface.bytes());
        }
        while self.bytes.saturating_add(bytes) > self.budget && !self.entries.is_empty() {
            let Some(oldest) = self
                .entries
                .iter()
                .min_by_key(|(_, entry)| entry.last)
                .map(|(key, _)| *key)
            else {
                break;
            };
            if let Some(removed) = self.entries.remove(&oldest) {
                self.bytes = self.bytes.saturating_sub(removed.surface.bytes());
            }
        }
        self.bytes = self.bytes.saturating_add(bytes);
        self.tick = self.tick.wrapping_add(1);
        self.entries.insert(
            key,
            CacheEntry {
                surface,
                last: self.tick,
                coverage,
            },
        );
    }
}

#[derive(Default)]
struct Stats {
    tiles: u32,
    nodes: u32,
    dispatches: u32,
    coverage_hits: u32,
    node_hits: u32,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Receipt {
    tiles: u32,
    nodes: u32,
    dispatches: u32,
    coverage_cache_hits: u32,
    node_cache_hits: u32,
    peak_bytes: u64,
    budget_bytes: u64,
    cpu_ms: f64,
}

#[derive(Serialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
struct Comparison {
    samples: u64,
    max_abs: f32,
    max_relative: f32,
    mean_abs: f64,
    over_1e_5: u64,
    over_1e_4: u64,
    over_1e_3: u64,
    nonfinite: u64,
    max_channel_abs: [f32; 4],
    #[serde(skip)]
    sum_abs: f64,
}

struct Pipelines {
    color_corrector: wgpu::ComputePipeline,
    color_mix: wgpu::ComputePipeline,
    coverage_linear: wgpu::ComputePipeline,
    coverage_radial: wgpu::ComputePipeline,
    coverage_combine: wgpu::ComputePipeline,
    coverage_adjust: wgpu::ComputePipeline,
}

struct Bgls {
    color_corrector: wgpu::BindGroupLayout,
    color_mix: wgpu::BindGroupLayout,
    coverage_linear: wgpu::BindGroupLayout,
    coverage_radial: wgpu::BindGroupLayout,
    coverage_combine: wgpu::BindGroupLayout,
    coverage_adjust: wgpu::BindGroupLayout,
}

struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    adapter: wgpu::AdapterInfo,
    pipelines: Pipelines,
    bgls: Bgls,
    dummy_mask: Surface,
    full_input: Surface,
    full_output: Surface,
    width: u32,
    height: u32,
    budget: Arc<BudgetState>,
}

fn texture_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: false },
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    }
}

fn storage_entry(binding: u32, format: wgpu::TextureFormat) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::StorageTexture {
            access: wgpu::StorageTextureAccess::WriteOnly,
            format,
            view_dimension: wgpu::TextureViewDimension::D2,
        },
        count: None,
    }
}

fn uniform_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: NonZeroU64::new(std::mem::size_of::<Params>() as u64),
        },
        count: None,
    }
}

fn curve_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only: true },
            has_dynamic_offset: false,
            min_binding_size: NonZeroU64::new(8),
        },
        count: None,
    }
}

fn bgl(
    device: &wgpu::Device,
    label: &str,
    entries: &[wgpu::BindGroupLayoutEntry],
) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some(label),
        entries,
    })
}

fn pipeline(
    device: &wgpu::Device,
    label: &str,
    bgl: &wgpu::BindGroupLayout,
    module: &wgpu::ShaderModule,
    entry: &str,
) -> wgpu::ComputePipeline {
    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
        label: Some(label),
        bind_group_layouts: &[bgl],
        push_constant_ranges: &[],
    });
    device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some(label),
        layout: Some(&layout),
        module,
        entry_point: Some(entry),
        compilation_options: wgpu::PipelineCompilationOptions::default(),
        cache: None,
    })
}

impl Gpu {
    fn new(
        width: u32,
        height: u32,
        budget_bytes: u64,
        input_bytes: &[u8],
    ) -> Result<Self, Box<dyn Error>> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::VULKAN,
            ..Default::default()
        });
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .ok_or("no Vulkan adapter")?;
        let info = adapter.get_info();
        let limits = adapter.limits();
        if limits.max_texture_dimension_2d < width.max(height) {
            return Err(format!(
                "adapter max texture edge {} is below {}x{}",
                limits.max_texture_dimension_2d, width, height
            )
            .into());
        }
        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("rawmaster-scene-poc"),
                required_features: wgpu::Features::empty(),
                required_limits: limits,
                memory_hints: wgpu::MemoryHints::Performance,
            },
            None,
        ))?;
        let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("scene-vulkan"),
            source: wgpu::ShaderSource::Wgsl(WGSL.into()),
        });
        let bgls = Bgls {
            color_corrector: bgl(
                &device,
                "color-corrector",
                &[
                    uniform_entry(0),
                    curve_entry(1),
                    texture_entry(2),
                    texture_entry(3),
                    storage_entry(4, IMAGE_FORMAT),
                ],
            ),
            color_mix: bgl(
                &device,
                "color-mix",
                &[
                    uniform_entry(0),
                    curve_entry(1),
                    texture_entry(2),
                    texture_entry(3),
                    texture_entry(4),
                    storage_entry(5, IMAGE_FORMAT),
                ],
            ),
            coverage_linear: bgl(
                &device,
                "coverage-linear",
                &[uniform_entry(0), storage_entry(1, COVERAGE_FORMAT)],
            ),
            coverage_radial: bgl(
                &device,
                "coverage-radial",
                &[uniform_entry(0), storage_entry(1, COVERAGE_FORMAT)],
            ),
            coverage_combine: bgl(
                &device,
                "coverage-combine",
                &[
                    uniform_entry(0),
                    texture_entry(1),
                    texture_entry(2),
                    storage_entry(3, COVERAGE_FORMAT),
                ],
            ),
            coverage_adjust: bgl(
                &device,
                "coverage-adjust",
                &[
                    uniform_entry(0),
                    texture_entry(1),
                    storage_entry(2, COVERAGE_FORMAT),
                ],
            ),
        };
        let pipelines = Pipelines {
            color_corrector: pipeline(
                &device,
                "color-corrector",
                &bgls.color_corrector,
                &module,
                "color_corrector",
            ),
            color_mix: pipeline(&device, "color-mix", &bgls.color_mix, &module, "color_mix"),
            coverage_linear: pipeline(
                &device,
                "coverage-linear",
                &bgls.coverage_linear,
                &module,
                "coverage_linear",
            ),
            coverage_radial: pipeline(
                &device,
                "coverage-radial",
                &bgls.coverage_radial,
                &module,
                "coverage_radial",
            ),
            coverage_combine: pipeline(
                &device,
                "coverage-combine",
                &bgls.coverage_combine,
                &module,
                "coverage_combine",
            ),
            coverage_adjust: pipeline(
                &device,
                "coverage-adjust",
                &bgls.coverage_adjust,
                &module,
                "coverage_adjust",
            ),
        };
        let budget = BudgetState::new(budget_bytes);
        let dummy_mask = Surface::new(
            &device,
            budget.clone(),
            1,
            1,
            Domain::Coverage,
            "dummy-mask",
        )?;
        let full_input = Surface::new(
            &device,
            budget.clone(),
            width,
            height,
            Domain::Image,
            "full-input",
        )?;
        let full_output = Surface::new(
            &device,
            budget.clone(),
            width,
            height,
            Domain::Image,
            "full-output",
        )?;
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: full_input.texture(),
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            input_bytes,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(width * 16),
                rows_per_image: Some(height),
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        Ok(Self {
            device,
            queue,
            adapter: info,
            pipelines,
            bgls,
            dummy_mask,
            full_input,
            full_output,
            width,
            height,
            budget,
        })
    }
}

struct Renderer<'a> {
    gpu: &'a Gpu,
    tile_width: u32,
    tile_height: u32,
    tile_origin: (u32, u32),
    geometry: (u32, u32),
    cache: Cache,
    fingerprints: HashMap<(String, u64), u64>,
    stats: Stats,
}

impl<'a> Renderer<'a> {
    fn new(gpu: &'a Gpu, tile_width: u32, tile_height: u32, cache_bytes: u64) -> Self {
        Self {
            gpu,
            tile_width,
            tile_height,
            tile_origin: (0, 0),
            geometry: (gpu.width, gpu.height),
            cache: Cache::new(cache_bytes),
            fingerprints: HashMap::new(),
            stats: Stats::default(),
        }
    }

    fn begin_pass(&mut self) {
        self.stats = Stats::default();
        self.fingerprints.clear();
        self.gpu.budget.reset_peak();
    }

    fn receipt(&self, cpu_ms: f64) -> Receipt {
        Receipt {
            tiles: self.stats.tiles,
            nodes: self.stats.nodes,
            dispatches: self.stats.dispatches,
            coverage_cache_hits: self.stats.coverage_hits,
            node_cache_hits: self.stats.node_hits,
            peak_bytes: self.gpu.budget.peak(),
            budget_bytes: self.gpu.budget.maximum,
            cpu_ms,
        }
    }

    fn fingerprint(&mut self, scope: &Scope, id: &str, input_hash: u64) -> Result<u64, String> {
        let key = (id.to_string(), input_hash);
        if let Some(value) = self.fingerprints.get(&key) {
            return Ok(*value);
        }
        let node = scope
            .nodes
            .iter()
            .find(|node| node.id == id)
            .ok_or_else(|| format!("missing node {id}"))?;
        let mut dependencies = Vec::new();
        for image in node.operation.images() {
            let hash = if image.0 == "$input" {
                input_hash
            } else {
                self.fingerprint(scope, &image.0, input_hash)?
            };
            dependencies.extend_from_slice(&hash.to_le_bytes());
        }
        for coverage in node.operation.coverages() {
            let hash = self.fingerprint(scope, coverage, input_hash)?;
            dependencies.extend_from_slice(&hash.to_le_bytes());
        }
        let operation = serde_json::to_vec(&node.operation).map_err(|error| error.to_string())?;
        let mut hasher = std::collections::hash_map::DefaultHasher::new();
        operation.hash(&mut hasher);
        dependencies.hash(&mut hasher);
        self.tile_origin.hash(&mut hasher);
        self.tile_width.hash(&mut hasher);
        self.tile_height.hash(&mut hasher);
        let value = hasher.finish();
        self.fingerprints.insert(key, value);
        Ok(value)
    }

    fn value(
        memo: &HashMap<String, Surface>,
        input: &Surface,
        endpoint: &str,
    ) -> Result<Surface, String> {
        if endpoint == "$input" {
            Ok(input.clone())
        } else {
            memo.get(endpoint)
                .cloned()
                .ok_or_else(|| format!("missing evaluated node {endpoint}"))
        }
    }

    fn output_image(&self, label: &str) -> Result<Surface, String> {
        Surface::new(
            &self.gpu.device,
            self.gpu.budget.clone(),
            self.tile_width,
            self.tile_height,
            Domain::Image,
            label,
        )
    }

    fn output_coverage(&self, label: &str) -> Result<Surface, String> {
        Surface::new(
            &self.gpu.device,
            self.gpu.budget.clone(),
            self.tile_width,
            self.tile_height,
            Domain::Coverage,
            label,
        )
    }

    fn params(&self, scalars: [f32; 4], kind: u32, parameter: u32, origin: (u32, u32)) -> Params {
        Params {
            scalars,
            geometry: [origin.0, origin.1, self.geometry.0, self.geometry.1],
            kind,
            parameter,
            _pad: [0, 0],
        }
    }

    fn encode_dispatch(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        pipeline: &wgpu::ComputePipeline,
        bind_group: &wgpu::BindGroup,
        width: u32,
        height: u32,
    ) {
        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
            label: Some("scene-node"),
            timestamp_writes: None,
        });
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, bind_group, &[]);
        pass.dispatch_workgroups((width + 7) / 8, (height + 7) / 8, 1);
        drop(pass);
        self.stats.dispatches += 1;
    }

    fn dispatch_corrector(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        input: &Surface,
        mask: Option<&Surface>,
        output: &Surface,
        params: Params,
        curve: &[[f32; 2]],
        origin: (u32, u32),
    ) -> Result<(), String> {
        let _ = origin;
        let uniform = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("corrector-params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let curve_values: Vec<[f32; 2]> = if curve.is_empty() {
            vec![[0.0, 0.0]]
        } else {
            curve.to_vec()
        };
        let curve_buffer = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("corrector-curve"),
                contents: bytemuck::cast_slice(&curve_values),
                usage: wgpu::BufferUsages::STORAGE,
            });
        let mask = mask.unwrap_or(&self.gpu.dummy_mask);
        let bind_group = self
            .gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("corrector"),
                layout: &self.gpu.bgls.color_corrector,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: uniform.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: curve_buffer.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::TextureView(input.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 3,
                        resource: wgpu::BindingResource::TextureView(mask.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 4,
                        resource: wgpu::BindingResource::TextureView(output.view()),
                    },
                ],
            });
        self.encode_dispatch(
            encoder,
            &self.gpu.pipelines.color_corrector,
            &bind_group,
            output.width(),
            output.height(),
        );
        Ok(())
    }

    fn dispatch_mix(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        input: &Surface,
        other: &Surface,
        base: &Surface,
        output: &Surface,
        params: Params,
    ) -> Result<(), String> {
        let uniform = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("mix-params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let curve_buffer = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("mix-curve"),
                contents: bytemuck::cast_slice(&[[0.0f32, 0.0f32]]),
                usage: wgpu::BufferUsages::STORAGE,
            });
        let bind_group = self
            .gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("mix"),
                layout: &self.gpu.bgls.color_mix,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: uniform.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: curve_buffer.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::TextureView(input.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 3,
                        resource: wgpu::BindingResource::TextureView(other.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 4,
                        resource: wgpu::BindingResource::TextureView(base.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 5,
                        resource: wgpu::BindingResource::TextureView(output.view()),
                    },
                ],
            });
        self.encode_dispatch(
            encoder,
            &self.gpu.pipelines.color_mix,
            &bind_group,
            output.width(),
            output.height(),
        );
        Ok(())
    }

    fn dispatch_coverage_simple(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        output: &Surface,
        params: Params,
        radial: bool,
    ) -> Result<(), String> {
        let uniform = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("coverage-params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let (layout, pipeline) = if radial {
            (
                &self.gpu.bgls.coverage_radial,
                &self.gpu.pipelines.coverage_radial,
            )
        } else {
            (
                &self.gpu.bgls.coverage_linear,
                &self.gpu.pipelines.coverage_linear,
            )
        };
        let bind_group = self
            .gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("coverage-simple"),
                layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: uniform.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(output.view()),
                    },
                ],
            });
        self.encode_dispatch(
            encoder,
            pipeline,
            &bind_group,
            output.width(),
            output.height(),
        );
        Ok(())
    }

    fn dispatch_coverage_combine(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        input: &Surface,
        other: &Surface,
        output: &Surface,
        params: Params,
    ) -> Result<(), String> {
        let uniform = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("coverage-combine-params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind_group = self
            .gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("coverage-combine"),
                layout: &self.gpu.bgls.coverage_combine,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: uniform.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(input.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::TextureView(other.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 3,
                        resource: wgpu::BindingResource::TextureView(output.view()),
                    },
                ],
            });
        self.encode_dispatch(
            encoder,
            &self.gpu.pipelines.coverage_combine,
            &bind_group,
            output.width(),
            output.height(),
        );
        Ok(())
    }

    fn dispatch_coverage_adjust(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        input: &Surface,
        output: &Surface,
        params: Params,
    ) -> Result<(), String> {
        let uniform = self
            .gpu
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("coverage-adjust-params"),
                contents: bytemuck::bytes_of(&params),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind_group = self
            .gpu
            .device
            .create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("coverage-adjust"),
                layout: &self.gpu.bgls.coverage_adjust,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: uniform.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(input.view()),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::TextureView(output.view()),
                    },
                ],
            });
        self.encode_dispatch(
            encoder,
            &self.gpu.pipelines.coverage_adjust,
            &bind_group,
            output.width(),
            output.height(),
        );
        Ok(())
    }

    fn render_scope(
        &mut self,
        encoder: &mut wgpu::CommandEncoder,
        scope: &Scope,
        input: &Surface,
        input_hash: u64,
        origin: (u32, u32),
    ) -> Result<Surface, String> {
        if scope.output.0 == "$input" {
            return Ok(input.clone());
        }
        let mut by_id: HashMap<&str, &scene::Node> = HashMap::new();
        for node in &scope.nodes {
            by_id.insert(&node.id, node);
        }
        let mut active = std::collections::HashSet::new();
        let mut resolved = std::collections::HashSet::new();
        let mut steps = Vec::new();
        fn visit<'b>(
            id: &'b str,
            by_id: &HashMap<&str, &'b scene::Node>,
            active: &mut std::collections::HashSet<String>,
            resolved: &mut std::collections::HashSet<String>,
            steps: &mut Vec<String>,
        ) -> Result<(), String> {
            if resolved.contains(id) {
                return Ok(());
            }
            if !active.insert(id.to_string()) {
                return Err(format!("scene graph cycle at {id}"));
            }
            let node = by_id.get(id).ok_or_else(|| format!("missing node {id}"))?;
            for image in node.operation.images() {
                if image.0 != "$input" {
                    visit(&image.0, by_id, active, resolved, steps)?;
                }
            }
            for coverage in node.operation.coverages() {
                visit(coverage, by_id, active, resolved, steps)?;
            }
            active.remove(id);
            resolved.insert(id.to_string());
            steps.push(id.to_string());
            Ok(())
        }
        visit(
            &scope.output.0,
            &by_id,
            &mut active,
            &mut resolved,
            &mut steps,
        )?;

        let mut memo: HashMap<String, Surface> = HashMap::new();
        for id in steps {
            let node = by_id
                .get(id.as_str())
                .ok_or_else(|| format!("missing node {id}"))?;
            self.stats.nodes += 1;
            let fingerprint = self.fingerprint(scope, &id, input_hash)?;
            if let Some(hit) = self.cache.get(fingerprint, &mut self.stats) {
                memo.insert(id, hit);
                continue;
            }
            let op = &node.operation;
            let surface = match op {
                Operation::Corrector {
                    image,
                    mask,
                    exposure_ev,
                    curve,
                    strength,
                    enabled,
                } => {
                    let base = Self::value(&memo, input, &image.0)?;
                    let neutral =
                        *exposure_ev == 0.0 && curve.iter().all(|point| point[0] == point[1]);
                    if !*enabled || *strength == 0.0 || neutral {
                        base
                    } else {
                        let mask_surface = match mask {
                            Some(mask) => Some(Self::value(&memo, input, mask)?),
                            None => None,
                        };
                        let output = self.output_image("corrector")?;
                        let params = self.params(
                            [
                                2.0f32.powf(*exposure_ev),
                                *strength,
                                curve.len() as f32,
                                if mask.is_some() { 1.0 } else { 0.0 },
                            ],
                            0,
                            0,
                            origin,
                        );
                        self.dispatch_corrector(
                            encoder,
                            &base,
                            mask_surface.as_ref(),
                            &output,
                            params,
                            curve,
                            origin,
                        )?;
                        output
                    }
                }
                Operation::Parallel {
                    base,
                    layers,
                    enabled,
                }
                | Operation::Layer {
                    base,
                    layers,
                    enabled,
                } => {
                    let parallel = matches!(op, Operation::Parallel { .. });
                    let base_surface = Self::value(&memo, input, &base.0)?;
                    let mut current = base_surface.clone();
                    if *enabled {
                        for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                            let branch = Self::value(&memo, input, &layer.image.0)?;
                            if parallel && Arc::ptr_eq(&branch.inner, &base_surface.inner) {
                                continue;
                            }
                            if !parallel && layer.mode == Blend::Normal && layer.weight == 1.0 {
                                current = branch;
                                continue;
                            }
                            let output = self.output_image("mix")?;
                            let mode = blend_code(layer.mode);
                            let params = self.params(
                                [layer.weight, mode as f32, 0.0, 0.0],
                                if parallel { 2 } else { 1 },
                                0,
                                origin,
                            );
                            self.dispatch_mix(
                                encoder,
                                &current,
                                &branch,
                                &base_surface,
                                &output,
                                params,
                            )?;
                            current = output;
                        }
                    }
                    current
                }
                Operation::Group {
                    image,
                    graph,
                    strength,
                    enabled,
                } => {
                    let base_surface = Self::value(&memo, input, &image.0)?;
                    if !*enabled || *strength == 0.0 {
                        base_surface
                    } else {
                        let child_input_hash = if image.0 == "$input" {
                            input_hash
                        } else {
                            self.fingerprint(scope, &image.0, input_hash)?
                        };
                        let rendered = self.render_scope(
                            encoder,
                            graph,
                            &base_surface,
                            child_input_hash,
                            origin,
                        )?;
                        if *strength == 1.0 || Arc::ptr_eq(&rendered.inner, &base_surface.inner) {
                            rendered
                        } else {
                            let output = self.output_image("group")?;
                            let params = self.params([*strength, 0.0, 0.0, 0.0], 1, 0, origin);
                            self.dispatch_mix(
                                encoder,
                                &base_surface,
                                &rendered,
                                &base_surface,
                                &output,
                                params,
                            )?;
                            output
                        }
                    }
                }
                Operation::LinearCoverage { start, end } => {
                    let output = self.output_coverage("linear")?;
                    let params = self.params([start[0], start[1], end[0], end[1]], 0, 0, origin);
                    self.dispatch_coverage_simple(encoder, &output, params, false)?;
                    output
                }
                Operation::RadialCoverage {
                    center,
                    radii,
                    feather,
                } => {
                    let output = self.output_coverage("radial")?;
                    let params = self.params(
                        [center[0], center[1], radii[0], radii[1]],
                        1,
                        feather.to_bits(),
                        origin,
                    );
                    self.dispatch_coverage_simple(encoder, &output, params, true)?;
                    output
                }
                Operation::CombineCoverage { base, other, mode } => {
                    let base_surface = Self::value(&memo, input, base)?;
                    let other_surface = Self::value(&memo, input, other)?;
                    let output = self.output_coverage("combine")?;
                    let mode = match mode {
                        CoverageCombine::Add => 0.0,
                        CoverageCombine::Subtract => 1.0,
                        CoverageCombine::Intersect => 2.0,
                    };
                    let params = self.params([mode, 0.0, 0.0, 0.0], 2, 0, origin);
                    self.dispatch_coverage_combine(
                        encoder,
                        &base_surface,
                        &other_surface,
                        &output,
                        params,
                    )?;
                    output
                }
                Operation::AdjustCoverage {
                    mask,
                    strength,
                    inverted,
                } => {
                    let mask_surface = Self::value(&memo, input, mask)?;
                    let output = self.output_coverage("adjust")?;
                    let params = self.params(
                        [*strength, if *inverted { 1.0 } else { 0.0 }, 0.0, 0.0],
                        3,
                        0,
                        origin,
                    );
                    self.dispatch_coverage_adjust(encoder, &mask_surface, &output, params)?;
                    output
                }
                Operation::ExternalCoverage { id } => {
                    return Err(format!(
                        "external coverage {id} is not available in the Linux PoC"
                    ));
                }
            };
            self.cache
                .put(fingerprint, surface.clone(), op.is_coverage());
            memo.insert(id, surface);
        }
        Self::value(&memo, input, &scope.output.0)
    }
}

fn blend_code(blend: Blend) -> u32 {
    match blend {
        Blend::Normal => 0,
        Blend::Add => 1,
        Blend::Subtract => 2,
        Blend::Multiply => 3,
        Blend::Screen => 4,
        Blend::Overlay => 5,
        Blend::SoftLight => 6,
        Blend::HardLight => 7,
        Blend::Lighten => 8,
        Blend::Darken => 9,
        Blend::Difference => 10,
        Blend::Color => 11,
        Blend::Luminosity => 12,
    }
}

fn tile_ranges(width: u32, height: u32, edge: u32) -> Vec<(u32, u32, u32, u32)> {
    let mut tiles = Vec::new();
    let mut y = 0;
    while y < height {
        let tile_height = edge.min(height - y);
        let mut x = 0;
        while x < width {
            let tile_width = edge.min(width - x);
            tiles.push((x, y, tile_width, tile_height));
            x += tile_width;
        }
        y += tile_height;
    }
    tiles
}

fn tile_hash(source_revision: u64, x: u32, y: u32, width: u32, height: u32) -> u64 {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    source_revision.hash(&mut hasher);
    x.hash(&mut hasher);
    y.hash(&mut hasher);
    width.hash(&mut hasher);
    height.hash(&mut hasher);
    hasher.finish()
}

fn read_surface(gpu: &Gpu, surface: &Surface) -> Result<Vec<u8>, String> {
    let row_bytes = surface.width() * 16;
    let padded_row = ((row_bytes + 255) / 256) * 256;
    let size = u64::from(padded_row) * u64::from(surface.height());
    let buffer = gpu.device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("tile-readback"),
        size,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut encoder = gpu
        .device
        .create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("tile-readback"),
        });
    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo {
            texture: surface.texture(),
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::TexelCopyBufferInfo {
            buffer: &buffer,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(padded_row),
                rows_per_image: Some(surface.height()),
            },
        },
        wgpu::Extent3d {
            width: surface.width(),
            height: surface.height(),
            depth_or_array_layers: 1,
        },
    );
    gpu.queue.submit(Some(encoder.finish()));
    gpu.device.poll(wgpu::Maintain::Wait);
    let slice = buffer.slice(..);
    let (sender, receiver) = std::sync::mpsc::channel();
    slice.map_async(wgpu::MapMode::Read, move |result| {
        let _ = sender.send(result);
    });
    gpu.device.poll(wgpu::Maintain::Wait);
    match receiver.recv() {
        Ok(Ok(())) => {}
        Ok(Err(error)) => return Err(format!("readback map failed: {error}")),
        Err(error) => return Err(format!("readback callback disappeared: {error}")),
    }
    let data = slice.get_mapped_range();
    let mut output = Vec::with_capacity((row_bytes * surface.height()) as usize);
    for row in 0..surface.height() as usize {
        let start = row * padded_row as usize;
        output.extend_from_slice(&data[start..start + row_bytes as usize]);
    }
    drop(data);
    buffer.unmap();
    Ok(output)
}

fn compare_tile(
    readback: &[u8],
    reference: &[f32],
    full_width: u32,
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    result: &mut Comparison,
) {
    for row in 0..height {
        for column in 0..width {
            let source = ((row * width + column) * 16) as usize;
            let target = (((y + row) * full_width + (x + column)) * 4) as usize;
            for channel in 0..4 {
                let actual = f32::from_le_bytes([
                    readback[source + channel * 4],
                    readback[source + channel * 4 + 1],
                    readback[source + channel * 4 + 2],
                    readback[source + channel * 4 + 3],
                ]);
                let expected = reference[target + channel];
                result.samples += 1;
                if !actual.is_finite() || !expected.is_finite() {
                    result.nonfinite += 1;
                    continue;
                }
                let difference = (actual - expected).abs();
                let relative = difference / expected.abs().max(1.0);
                result.max_abs = result.max_abs.max(difference);
                result.max_relative = result.max_relative.max(relative);
                result.sum_abs += f64::from(difference);
                result.max_channel_abs[channel] = result.max_channel_abs[channel].max(difference);
                if relative > 1e-3 {
                    result.over_1e_3 += 1;
                } else if relative > 1e-4 {
                    result.over_1e_4 += 1;
                } else if relative > 1e-5 {
                    result.over_1e_5 += 1;
                }
            }
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Run {
    graph_ms: f64,
    readback_ms: f64,
    receipt: Receipt,
    comparison: Option<Comparison>,
}

#[allow(clippy::too_many_arguments)]
fn run_pass(
    gpu: &Gpu,
    renderer: &mut Renderer,
    scope: &Scope,
    source_revision: u64,
    tile_edge: u32,
    reference: Option<&[f32]>,
    mut output: Option<&mut [u8]>,
    readback: bool,
) -> Result<Run, String> {
    renderer.begin_pass();
    let started = Instant::now();
    let mut readback_ns = 0u128;
    let mut comparison: Option<Comparison> = None;
    for (x, y, width, height) in tile_ranges(gpu.width, gpu.height, tile_edge) {
        let tile_input = Surface::new(
            &gpu.device,
            gpu.budget.clone(),
            width,
            height,
            Domain::Image,
            "tile-input",
        )?;
        let mut encoder = gpu
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("scene-tile"),
            });
        encoder.copy_texture_to_texture(
            wgpu::TexelCopyTextureInfo {
                texture: gpu.full_input.texture(),
                mip_level: 0,
                origin: wgpu::Origin3d { x, y, z: 0 },
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyTextureInfo {
                texture: tile_input.texture(),
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        let input_hash = tile_hash(source_revision, x, y, width, height);
        renderer.tile_width = width;
        renderer.tile_height = height;
        renderer.tile_origin = (x, y);
        let rendered =
            renderer.render_scope(&mut encoder, scope, &tile_input, input_hash, (x, y))?;
        encoder.copy_texture_to_texture(
            wgpu::TexelCopyTextureInfo {
                texture: rendered.texture(),
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyTextureInfo {
                texture: gpu.full_output.texture(),
                mip_level: 0,
                origin: wgpu::Origin3d { x, y, z: 0 },
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        gpu.queue.submit(Some(encoder.finish()));
        gpu.device.poll(wgpu::Maintain::Wait);
        renderer.stats.tiles += 1;

        if readback || output.is_some() {
            let readback_started = Instant::now();
            let bytes = read_surface(gpu, &rendered)?;
            if let Some(reference) = reference {
                let comparison = comparison.get_or_insert_with(Comparison::default);
                compare_tile(
                    &bytes, reference, gpu.width, x, y, width, height, comparison,
                );
            }
            if let Some(target) = output.as_deref_mut() {
                for row in 0..height as usize {
                    let source = row * width as usize * 16;
                    let destination =
                        (((y as usize + row) * gpu.width as usize + x as usize) * 16) as usize;
                    target[destination..destination + width as usize * 16]
                        .copy_from_slice(&bytes[source..source + width as usize * 16]);
                }
            }
            readback_ns += readback_started.elapsed().as_nanos();
        }
    }
    let graph_ms = started.elapsed().as_secs_f64() * 1000.0 - readback_ns as f64 / 1e6;
    if let Some(comparison) = comparison.as_mut() {
        if comparison.samples > 0 {
            comparison.mean_abs = comparison.sum_abs / comparison.samples as f64;
        }
    }
    Ok(Run {
        graph_ms,
        readback_ms: readback_ns as f64 / 1e6,
        receipt: renderer.receipt(graph_ms),
        comparison,
    })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Adapter {
    name: String,
    backend: String,
    device_type: String,
    driver: String,
    driver_info: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Report {
    schema: &'static str,
    adapter: Adapter,
    resolution: [u32; 2],
    tile_edge: u32,
    budget_bytes: u64,
    cache_bytes: u64,
    source_revision: u64,
    cold: Run,
    warm: Run,
    edited: Run,
    new_source: Run,
    output_sha256: Option<String>,
    output_path: Option<String>,
}

#[derive(Default)]
struct Args {
    input: Option<PathBuf>,
    graph: Option<PathBuf>,
    graph_v2: Option<PathBuf>,
    reference: Option<PathBuf>,
    output: Option<PathBuf>,
    report: Option<PathBuf>,
    width: Option<u32>,
    height: Option<u32>,
    tile_edge: Option<u32>,
    budget_bytes: Option<u64>,
    cache_bytes: Option<u64>,
    source_revision: Option<u64>,
}

fn parse_args() -> Result<Args, String> {
    let mut args = Args::default();
    let values: Vec<String> = std::env::args().skip(1).collect();
    let mut index = 0;
    while index < values.len() {
        let key = values[index].as_str();
        let value = values
            .get(index + 1)
            .ok_or_else(|| format!("missing value for {key}"))?
            .clone();
        match key {
            "--input" => args.input = Some(value.into()),
            "--graph" => args.graph = Some(value.into()),
            "--graph-v2" => args.graph_v2 = Some(value.into()),
            "--reference" => args.reference = Some(value.into()),
            "--output" => args.output = Some(value.into()),
            "--report" => args.report = Some(value.into()),
            "--width" => args.width = Some(value.parse().map_err(|_| "invalid width")?),
            "--height" => args.height = Some(value.parse().map_err(|_| "invalid height")?),
            "--tile-edge" => args.tile_edge = Some(value.parse().map_err(|_| "invalid tile edge")?),
            "--budget-bytes" => {
                args.budget_bytes = Some(value.parse().map_err(|_| "invalid budget")?)
            }
            "--cache-bytes" => {
                args.cache_bytes = Some(value.parse().map_err(|_| "invalid cache budget")?)
            }
            "--source-revision" => {
                args.source_revision = Some(value.parse().map_err(|_| "invalid revision")?)
            }
            other => return Err(format!("unknown argument {other}")),
        }
        index += 2;
    }
    Ok(args)
}

fn sha256_file(path: &Path) -> Result<String, Box<dyn Error>> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 4 * 1024 * 1024];
    loop {
        use std::io::Read;
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init();
    let args = parse_args()?;
    let input_path = args.input.ok_or("--input is required")?;
    let graph_path = args.graph.ok_or("--graph is required")?;
    let graph_v2_path = args.graph_v2.ok_or("--graph-v2 is required")?;
    let report_path = args.report.ok_or("--report is required")?;
    let width = args.width.ok_or("--width is required")?;
    let height = args.height.ok_or("--height is required")?;
    let tile_edge = args.tile_edge.unwrap_or(2048).max(64);
    let budget_bytes = args.budget_bytes.unwrap_or(12 * 1024 * 1024 * 1024);
    let cache_bytes = args.cache_bytes.unwrap_or(10 * 1024 * 1024 * 1024);
    let source_revision = args.source_revision.unwrap_or(1).max(1);

    let input_bytes = std::fs::read(&input_path)?;
    let expected = width as usize * height as usize * 16;
    if input_bytes.len() != expected {
        return Err(format!(
            "input {} is {} bytes; expected {} for {}x{} RGBA32F",
            input_path.display(),
            input_bytes.len(),
            expected,
            width,
            height
        )
        .into());
    }
    let graph_bytes = std::fs::read(&graph_path)?;
    let graph_v2_bytes = std::fs::read(&graph_v2_path)?;
    let (document, _) = scene::parse(&graph_bytes)?;
    let (document_v2, _) = scene::parse(&graph_v2_bytes)?;

    let gpu = Gpu::new(width, height, budget_bytes, &input_bytes)?;
    let reference = if let Some(path) = &args.reference {
        let file = File::open(path)?;
        let mmap = unsafe { Mmap::map(&file)? };
        if mmap.len() != expected {
            return Err(format!("reference is {} bytes; expected {}", mmap.len(), expected).into());
        }
        Some(mmap)
    } else {
        None
    };
    let reference_slice = reference
        .as_ref()
        .map(|mmap| bytemuck::cast_slice::<u8, f32>(mmap));

    let mut output_mmap = if let Some(path) = &args.output {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        file.set_len(expected as u64)?;
        Some(unsafe { MmapMut::map_mut(&file)? })
    } else {
        None
    };

    let mut renderer = Renderer::new(&gpu, tile_edge, tile_edge, cache_bytes);
    let cold = run_pass(
        &gpu,
        &mut renderer,
        &document.graph,
        source_revision,
        tile_edge,
        reference_slice.as_deref(),
        output_mmap.as_deref_mut(),
        true,
    )?;
    let warm = run_pass(
        &gpu,
        &mut renderer,
        &document.graph,
        source_revision,
        tile_edge,
        None,
        None,
        false,
    )?;
    let edited = run_pass(
        &gpu,
        &mut renderer,
        &document_v2.graph,
        source_revision,
        tile_edge,
        None,
        None,
        false,
    )?;
    let new_source = run_pass(
        &gpu,
        &mut renderer,
        &document_v2.graph,
        source_revision + 1,
        tile_edge,
        None,
        None,
        false,
    )?;

    if let Some(mmap) = output_mmap.as_mut() {
        mmap.flush()?;
    }
    let output_sha256 = args
        .output
        .as_ref()
        .map(|path| sha256_file(path))
        .transpose()?;

    let report = Report {
        schema: "rawmaster-server-poc-linux-vulkan-v1",
        adapter: Adapter {
            name: gpu.adapter.name.clone(),
            backend: format!("{:?}", gpu.adapter.backend),
            device_type: format!("{:?}", gpu.adapter.device_type),
            driver: gpu.adapter.driver.clone(),
            driver_info: gpu.adapter.driver_info.clone(),
        },
        resolution: [width, height],
        tile_edge,
        budget_bytes,
        cache_bytes,
        source_revision,
        cold,
        warm,
        edited,
        new_source,
        output_sha256,
        output_path: args.output.as_ref().map(|path| path.display().to_string()),
    };
    let json = serde_json::to_vec_pretty(&report)?;
    std::fs::write(&report_path, &json)?;
    println!("{}", String::from_utf8_lossy(&json));
    Ok(())
}
