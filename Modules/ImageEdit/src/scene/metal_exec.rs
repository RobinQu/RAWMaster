//! Metal implementation of the bounded scene graph executor.
//!
//! All image surfaces are AP1 premultiplied F32; coverage surfaces are R32F. One command buffer
//! carries every node dispatch and is completed once before the result is handed back.

use super::*;
use foreign_types::{ForeignType, ForeignTypeRef};
use metal::{
    MTLCommandBufferStatus, MTLOrigin, MTLPixelFormat, MTLResourceOptions, MTLSize, MTLStorageMode,
    MTLTextureUsage,
};
use std::collections::{HashMap, HashSet, VecDeque};
use std::ffi::c_void;
use std::sync::{Arc, Mutex};
use std::time::Instant;

#[repr(C)]
#[derive(Clone, Copy)]
struct Params {
    scalars: [f32; 4],
    geometry: [u32; 4],
    kind: u32,
    parameter: u32,
}

/// Tracks every surface owned by this program so the Rust backend obeys the same memory cap as
/// the Swift executor rather than trusting graph node limits alone.
struct SurfaceBudget<'a> {
    maximum: usize,
    used: usize,
    peak: &'a mut usize,
    cache_results: bool,
}

impl<'a> SurfaceBudget<'a> {
    fn new(maximum: usize, cache_results: bool, peak: &'a mut usize) -> Self {
        Self {
            maximum,
            used: 0,
            peak,
            cache_results,
        }
    }

    fn reserve(&mut self, bytes: usize) -> Result<(), SceneError> {
        if bytes > self.maximum.saturating_sub(self.used) {
            return Err(SceneError::Budget(
                "scene graph exceeded the surface budget".into(),
            ));
        }
        self.used += bytes;
        *self.peak = (*self.peak).max(self.used);
        Ok(())
    }

    fn release(&mut self, bytes: usize) {
        self.used = self.used.saturating_sub(bytes);
    }
}

/// Completion receipt for one render. Kept as a C-compatible value so the Swift adapter can log
/// exactly what the backend did without a second GPU query.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Receipt {
    pub abi: u32,
    pub tiles: u32,
    pub nodes: u32,
    pub dispatches: u32,
    pub coverage_hits: u32,
    pub node_hits: u32,
    pub reserved: u32,
    pub peak_bytes: u64,
    pub budget_bytes: u64,
    pub cpu_ms: f64,
}

pub const RECEIPT_ABI: u32 = 1;

/// LRU texture cache used for analytic coverage and source-revision-keyed intermediate nodes.
/// Every retained texture stays charged to the render budget until eviction.
struct TextureCache {
    entries: HashMap<String, (Arc<metal::Texture>, usize)>,
    order: VecDeque<String>,
    bytes: usize,
    budget: usize,
    max_entries: usize,
    max_entry_bytes: usize,
}

impl TextureCache {
    fn new(budget: usize, max_entries: usize, max_entry_bytes: usize) -> Self {
        Self {
            entries: HashMap::new(),
            order: VecDeque::new(),
            bytes: 0,
            budget,
            max_entries,
            max_entry_bytes,
        }
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
        self.bytes = 0;
    }

    fn get(&mut self, key: &str) -> Option<Arc<metal::Texture>> {
        let texture = self.entries.get(key)?.0.clone();
        if let Some(index) = self.order.iter().position(|item| item == key) {
            self.order.remove(index);
        }
        self.order.push_back(key.to_string());
        Some(texture)
    }

    fn put(
        &mut self,
        key: String,
        texture: Arc<metal::Texture>,
        bytes: usize,
        budget: &mut SurfaceBudget,
    ) {
        if !budget.cache_results || bytes > self.max_entry_bytes || bytes > self.budget {
            return;
        }
        if let Some((old, old_bytes)) = self.entries.remove(&key) {
            self.bytes = self.bytes.saturating_sub(old_bytes);
            if let Ok(texture) = Arc::try_unwrap(old) {
                budget.release(texture.allocated_size() as usize);
            }
        }
        while self.bytes + bytes > self.budget || self.entries.len() >= self.max_entries {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if let Some((old, old_bytes)) = self.entries.remove(&oldest) {
                self.bytes = self.bytes.saturating_sub(old_bytes);
                if let Ok(texture) = Arc::try_unwrap(old) {
                    budget.release(texture.allocated_size() as usize);
                }
            }
        }
        self.bytes += bytes;
        self.entries.insert(key.clone(), (texture, bytes));
        self.order.push_back(key);
    }
}

struct ExecutionState {
    graph: Scope,
    coverage: TextureCache,
    nodes: TextureCache,
    receipt: Receipt,
}

impl ExecutionState {
    fn new(graph: Scope) -> Self {
        Self {
            graph,
            // Analytic masks are small relative to color surfaces and survive panning/editing.
            coverage: TextureCache::new(512 * 1024 * 1024, 128, 256 * 1024 * 1024),
            // General intermediates are keyed by the caller's source revision. The cap keeps a
            // 60MP edit from pinning several full-resolution color frames.
            nodes: TextureCache::new(768 * 1024 * 1024, 64, 256 * 1024 * 1024),
            receipt: Receipt {
                abi: RECEIPT_ABI,
                ..Receipt::default()
            },
        }
    }
}

/// Recycles transient image/coverage surfaces as soon as their last reader has been encoded.
struct SurfacePool {
    textures: Vec<(u32, u32, MTLPixelFormat, metal::Texture)>,
    bytes: usize,
}

impl SurfacePool {
    const BUDGET: usize = 256 * 1024 * 1024;

    fn new() -> Self {
        Self {
            textures: Vec::new(),
            bytes: 0,
        }
    }

    fn take(&mut self, width: u32, height: u32, format: MTLPixelFormat) -> Option<metal::Texture> {
        let index = self
            .textures
            .iter()
            .position(|(w, h, f, _)| *w == width && *h == height && *f == format)?;
        let (_, _, _, texture) = self.textures.remove(index);
        self.bytes = self.bytes.saturating_sub(texture.allocated_size() as usize);
        Some(texture)
    }

    fn give(&mut self, texture: metal::Texture, budget: &mut SurfaceBudget) {
        let bytes = texture.allocated_size() as usize;
        if self.bytes + bytes <= Self::BUDGET {
            self.bytes += bytes;
            self.textures.push((
                texture.width() as u32,
                texture.height() as u32,
                texture.pixel_format(),
                texture,
            ));
        } else {
            budget.release(bytes);
        }
    }

    fn recycle(&mut self, retired: &mut Vec<Arc<metal::Texture>>, budget: &mut SurfaceBudget) {
        for texture in retired.drain(..) {
            if let Ok(texture) = Arc::try_unwrap(texture) {
                self.give(texture, budget);
            }
        }
    }
}

fn node_key(
    source_revision: u64,
    id: &str,
    operation_key: &str,
    width: u32,
    height: u32,
    origin: [i64; 2],
    geometry: (u32, u32),
    input_key: &str,
    dependency_keys: &[String],
) -> String {
    format!(
        "rev{source_revision}|src{input_key}|{id}|{operation_key}|{width}x{height}|{},{},{}x{}|{}",
        origin[0],
        origin[1],
        geometry.0,
        geometry.1,
        dependency_keys.join("|")
    )
}

fn tile_ranges(width: u32, height: u32, edge: u32) -> Vec<(u32, u32, u32, u32)> {
    let edge = if edge == 0 { u32::MAX } else { edge.max(64) };
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

/// A group monitor takes each enclosing group's input through its own child graph at
/// full strength. The stored final output and the enclosing groups' bypass flags stay intact.
fn monitor_graph<'a>(
    root: &'a Scope,
    view: &ViewSpec,
) -> Result<(std::borrow::Cow<'a, Scope>, Endpoint), SceneError> {
    fn endpoint(scope: &Scope, view: &ViewSpec) -> Result<Endpoint, SceneError> {
        match view.target.as_str() {
            "final" | "" => Ok(scope.output.clone()),
            "bypass" => Ok(Endpoint::Input),
            "node" => {
                let id = view
                    .id
                    .as_ref()
                    .ok_or_else(|| SceneError::Invalid("node view has no id".into()))?;
                let node = scope
                    .nodes
                    .iter()
                    .find(|n| &n.id == id)
                    .ok_or_else(|| SceneError::Invalid(format!("unknown scene node {id}")))?;
                if node.operation.is_coverage() {
                    return Err(SceneError::Invalid(format!(
                        "coverage node {id} is not previewable"
                    )));
                }
                Ok(Endpoint::Node(id.clone()))
            }
            other => Err(SceneError::Invalid(format!(
                "unknown scene view target {other}"
            ))),
        }
    }
    if view.group_path.is_empty() {
        return Ok((std::borrow::Cow::Borrowed(root), endpoint(root, view)?));
    }
    let mut projected = root.clone();
    let mut scope = &mut projected;
    for id in &view.group_path {
        let node = scope.nodes.iter_mut().find(|n| &n.id == id);
        let Some(Operation::Group {
            graph,
            enabled,
            strength,
            ..
        }) = node.map(|n| &mut n.operation)
        else {
            return Err(SceneError::Invalid(format!("unknown scene group {id}")));
        };
        scope.output = Endpoint::Node(id.clone());
        *enabled = true;
        *strength = 1.0;
        scope = graph;
    }
    scope.output = endpoint(scope, view)?;
    let output = projected.output.clone();
    Ok((std::borrow::Cow::Owned(projected), output))
}

pub struct SceneProgram {
    device: metal::Device,
    queue: metal::CommandQueue,
    color: metal::ComputePipelineState,
    coverage: metal::ComputePipelineState,
    frozen_delivery: bool,
    state: Mutex<ExecutionState>,
}

impl SceneProgram {
    pub fn open(device_pointer: *mut c_void, document: &[u8]) -> Result<Self, SceneError> {
        Self::open_with_policy(device_pointer, document, false, None)
    }

    pub fn open_frozen_delivery(
        device_pointer: *mut c_void,
        document: &[u8],
        library_api_calls: &mut u32,
    ) -> Result<Self, SceneError> {
        Self::open_with_policy(device_pointer, document, true, Some(library_api_calls))
    }

    fn open_with_policy(
        device_pointer: *mut c_void,
        document: &[u8],
        frozen_delivery: bool,
        library_api_calls: Option<&mut u32>,
    ) -> Result<Self, SceneError> {
        if device_pointer.is_null() {
            return Err(SceneError::Invalid("null Metal device".into()));
        }
        let (_, graph) = parse(document)?;
        let wanted = unsafe { metal::DeviceRef::from_ptr(device_pointer.cast()) };
        let device = wanted.to_owned();
        let options = metal::CompileOptions::new();
        options.set_fast_math_enabled(false);
        if let Some(calls) = library_api_calls {
            *calls += 1;
        }
        let library = device
            .new_library_with_source(SHADER, &options)
            .map_err(|error| SceneError::Backend(format!("scene shader: {error}")))?;
        let color_function = library
            .get_function("rmDagColorV1", None)
            .map_err(|error| SceneError::Backend(format!("scene color function: {error}")))?;
        let coverage_function = library
            .get_function("rmDagCoverageV1", None)
            .map_err(|error| SceneError::Backend(format!("scene coverage function: {error}")))?;
        let color = device
            .new_compute_pipeline_state_with_function(&color_function)
            .map_err(|error| SceneError::Backend(format!("scene color pipeline: {error}")))?;
        let coverage = device
            .new_compute_pipeline_state_with_function(&coverage_function)
            .map_err(|error| SceneError::Backend(format!("scene coverage pipeline: {error}")))?;
        let queue = device.new_command_queue();
        Ok(Self {
            device,
            queue,
            color,
            coverage,
            frozen_delivery,
            state: Mutex::new(ExecutionState::new(graph)),
        })
    }

    pub fn graph(&self) -> Option<Scope> {
        self.state.lock().ok().map(|state| state.graph.clone())
    }

    /// Replaces the graph for an existing topology. The parameter caches remain keyed by node
    /// content, so unchanged prefixes still hit while edited nodes miss.
    pub fn update(&self, document: &[u8]) -> Result<(), SceneError> {
        if self.frozen_delivery {
            return Err(SceneError::Invalid(
                "a frozen scene delivery program cannot be updated".into(),
            ));
        }
        let (_, graph) = parse(document)?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| SceneError::Render("scene execution state poisoned".into()))?;
        state.graph = graph;
        Ok(())
    }

    pub fn receipt(&self) -> Receipt {
        self.state
            .lock()
            .map(|state| state.receipt)
            .unwrap_or_default()
    }

    pub fn render(
        &self,
        input: &metal::TextureRef,
        output: Option<&metal::TextureRef>,
        view: &ViewSpec,
        external_coverages: &HashMap<String, Arc<metal::Texture>>,
        current: impl Fn() -> bool,
    ) -> Result<Arc<metal::Texture>, SceneError> {
        let started = Instant::now();
        let mut peak = 0;
        let mut state = self
            .state
            .lock()
            .map_err(|_| SceneError::Render("scene execution state poisoned".into()))?;
        let mut result = self.render_attempt(
            input,
            output,
            view,
            external_coverages,
            &current,
            &mut state,
            !self.frozen_delivery,
            &mut peak,
        );
        if let Err(error) = &result {
            // A failed command buffer cannot publish its partially encoded textures. When retained
            // previews used the working budget, run once without caches before reporting exhaustion.
            let cached = !state.nodes.entries.is_empty() || !state.coverage.entries.is_empty();
            state.nodes.clear();
            state.coverage.clear();
            if matches!(error, SceneError::Budget(_)) && cached && current() {
                result = self.render_attempt(
                    input,
                    output,
                    view,
                    external_coverages,
                    &current,
                    &mut state,
                    false,
                    &mut peak,
                );
            }
        }
        state.receipt.peak_bytes = peak as u64;
        state.receipt.cpu_ms = started.elapsed().as_secs_f64() * 1000.0;
        result
    }

    fn render_attempt(
        &self,
        input: &metal::TextureRef,
        output: Option<&metal::TextureRef>,
        view: &ViewSpec,
        external_coverages: &HashMap<String, Arc<metal::Texture>>,
        current: &impl Fn() -> bool,
        state: &mut ExecutionState,
        cache_results: bool,
        peak: &mut usize,
    ) -> Result<Arc<metal::Texture>, SceneError> {
        if !current() {
            return Err(SceneError::Render("stale scene frame".into()));
        }
        let width = input.width() as u32;
        let height = input.height() as u32;
        if width == 0
            || height == 0
            || input.pixel_format() != MTLPixelFormat::RGBA32Float
            || output.is_some_and(|output| {
                output.pixel_format() != MTLPixelFormat::RGBA32Float
                    || input.width() != output.width()
                    || input.height() != output.height()
                    || !output.usage().contains(MTLTextureUsage::ShaderWrite)
            })
        {
            return Err(SceneError::Invalid(
                "scene surfaces must be matching RGBA32F textures".into(),
            ));
        }
        let input = Arc::new(input.to_owned());
        let flag = self
            .device
            .new_buffer(4, MTLResourceOptions::StorageModeShared);
        unsafe {
            *(flag.contents().cast::<u32>()) = 0;
        }
        let origin = view.origin.unwrap_or([0, 0]);
        let geometry = view
            .geometry
            .map(|size| (size[0], size[1]))
            .unwrap_or((width, height));
        if origin[0] < 0 || origin[1] < 0 {
            return Err(SceneError::Invalid(
                "scene origin must be non-negative".into(),
            ));
        }
        for (id, mask) in external_coverages {
            if mask.pixel_format() != MTLPixelFormat::R32Float
                || mask.width() != geometry.0 as u64
                || mask.height() != geometry.1 as u64
            {
                return Err(SceneError::Invalid(format!(
                    "external coverage {id} must be full-frame R32F"
                )));
            }
        }

        state.receipt = Receipt {
            abi: RECEIPT_ABI,
            ..Receipt::default()
        };
        let mut pool = SurfacePool::new();
        let maximum = view.surface_budget.unwrap_or(1_536 * 1024 * 1024) as usize;
        let mut budget = SurfaceBudget::new(maximum, cache_results, peak);
        budget.reserve(input.allocated_size() as usize)?;
        budget.reserve(state.nodes.bytes + state.coverage.bytes)?;
        let mut mask_ids = HashSet::new();
        for mask in external_coverages.values() {
            if mask_ids.insert(mask.as_ptr()) {
                budget.reserve(mask.allocated_size() as usize)?;
            }
        }
        state.receipt.budget_bytes = maximum as u64;
        let tile_edge = view.tile_edge.unwrap_or(0);
        let tiles = tile_ranges(width, height, tile_edge);
        state.receipt.tiles = tiles.len() as u32;
        // A single tile can return the evaluated surface itself, including a reference to the
        // original input. Only a caller-supplied destination or tiled assembly requires a copy.
        let mut destination = match output {
            Some(output) => {
                budget.reserve(output.allocated_size() as usize)?;
                Some(Arc::new(output.to_owned()))
            }
            None if tiles.len() > 1 => Some(Arc::new(self.make_texture(
                &mut pool,
                &mut budget,
                width,
                height,
                MTLPixelFormat::RGBA32Float,
            )?)),
            None => None,
        };
        let ExecutionState {
            graph,
            coverage,
            nodes,
            receipt,
        } = &mut *state;
        let (graph, endpoint) = monitor_graph(graph, view)?;
        let source_revision = view.source_revision.unwrap_or(0);
        let input_key = format!("source:{source_revision}");
        let command = self.queue.new_command_buffer();

        for (x, y, tile_width, tile_height) in tiles {
            if !current() {
                return Err(SceneError::Render("stale scene frame".into()));
            }
            let mut retired: Vec<Arc<metal::Texture>> = Vec::new();
            let (tile_input, owned_input) = if tile_width == width && tile_height == height {
                (input.clone(), None)
            } else {
                let texture = Arc::new(self.make_texture(
                    &mut pool,
                    &mut budget,
                    tile_width,
                    tile_height,
                    MTLPixelFormat::RGBA32Float,
                )?);
                let blit = command.new_blit_command_encoder();
                blit.copy_from_texture(
                    input.as_ref(),
                    0,
                    0,
                    MTLOrigin {
                        x: x as u64,
                        y: y as u64,
                        z: 0,
                    },
                    MTLSize::new(tile_width as u64, tile_height as u64, 1),
                    texture.as_ref(),
                    0,
                    0,
                    MTLOrigin { x: 0, y: 0, z: 0 },
                );
                blit.end_encoding();
                (texture.clone(), Some(texture))
            };
            let (tile_masks, owned_masks) = self.crop_coverages(
                external_coverages,
                origin,
                x,
                y,
                tile_width,
                tile_height,
                &command,
                &mut pool,
                &mut budget,
            )?;
            let tile_origin = [origin[0] + x as i64, origin[1] + y as i64];
            let encoder = command.new_compute_command_encoder();
            let rendered = self.evaluate(
                &graph,
                tile_input,
                &endpoint,
                encoder,
                &flag,
                tile_width,
                tile_height,
                tile_origin,
                geometry,
                coverage,
                nodes,
                receipt,
                &mut pool,
                &mut budget,
                source_revision,
                &input_key,
                &tile_masks,
            );
            encoder.end_encoding();
            let rendered = rendered?;
            if let Some(input) = owned_input {
                retired.push(input);
            }
            drop(tile_masks);
            retired.extend(owned_masks);
            if let Some(output_surface) = &destination {
                if rendered.as_ptr() != output_surface.as_ptr() {
                    let blit = command.new_blit_command_encoder();
                    blit.copy_from_texture(
                        rendered.as_ref(),
                        0,
                        0,
                        MTLOrigin { x: 0, y: 0, z: 0 },
                        MTLSize::new(tile_width as u64, tile_height as u64, 1),
                        output_surface.as_ref(),
                        0,
                        0,
                        MTLOrigin {
                            x: x as u64,
                            y: y as u64,
                            z: 0,
                        },
                    );
                    blit.end_encoding();
                }
                retired.push(rendered);
            } else {
                destination = Some(rendered);
            }
            pool.recycle(&mut retired, &mut budget);
        }
        command.commit();
        command.wait_until_completed();
        if command.status() != MTLCommandBufferStatus::Completed {
            return Err(SceneError::Render("scene command buffer failed".into()));
        }
        let invalid = unsafe { *(flag.contents().cast::<u32>()) };
        if invalid != 0 {
            return Err(SceneError::Render(
                "scene graph produced non-finite or invalid pixels".into(),
            ));
        }
        if !current() {
            return Err(SceneError::Render("stale scene frame".into()));
        }
        destination.ok_or_else(|| SceneError::Render("scene produced no image".into()))
    }

    fn crop_coverages(
        &self,
        coverages: &HashMap<String, Arc<metal::Texture>>,
        origin: [i64; 2],
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        command: &metal::CommandBufferRef,
        pool: &mut SurfacePool,
        budget: &mut SurfaceBudget,
    ) -> Result<
        (
            HashMap<String, Arc<metal::Texture>>,
            Vec<Arc<metal::Texture>>,
        ),
        SceneError,
    > {
        let mut result = HashMap::new();
        let mut owned = Vec::new();
        for (id, mask) in coverages {
            if mask.width() == width as u64 && mask.height() == height as u64 {
                result.insert(id.clone(), mask.clone());
                continue;
            }
            let texture = Arc::new(self.make_texture(
                pool,
                budget,
                width,
                height,
                MTLPixelFormat::R32Float,
            )?);
            let blit = command.new_blit_command_encoder();
            blit.copy_from_texture(
                mask.as_ref(),
                0,
                0,
                MTLOrigin {
                    x: (origin[0] + x as i64) as u64,
                    y: (origin[1] + y as i64) as u64,
                    z: 0,
                },
                MTLSize::new(width as u64, height as u64, 1),
                texture.as_ref(),
                0,
                0,
                MTLOrigin { x: 0, y: 0, z: 0 },
            );
            blit.end_encoding();
            result.insert(id.clone(), texture.clone());
            owned.push(texture);
        }
        Ok((result, owned))
    }

    #[allow(clippy::too_many_arguments)]
    fn evaluate(
        &self,
        scope: &Scope,
        input: Arc<metal::Texture>,
        endpoint: &Endpoint,
        encoder: &metal::ComputeCommandEncoderRef,
        flag: &metal::Buffer,
        width: u32,
        height: u32,
        origin: [i64; 2],
        geometry: (u32, u32),
        coverage_cache: &mut TextureCache,
        node_cache: &mut TextureCache,
        receipt: &mut Receipt,
        pool: &mut SurfacePool,
        budget: &mut SurfaceBudget,
        source_revision: u64,
        input_key: &str,
        external_coverages: &HashMap<String, Arc<metal::Texture>>,
    ) -> Result<Arc<metal::Texture>, SceneError> {
        if *endpoint == Endpoint::Input {
            return Ok(input);
        }
        let operations: HashMap<&str, &Operation> = scope
            .nodes
            .iter()
            .map(|node| (node.id.as_str(), &node.operation))
            .collect();
        let mut uses: HashMap<String, usize> = HashMap::new();
        let mut dependencies: HashMap<String, Vec<Endpoint>> = HashMap::new();
        let mut steps: Vec<String> = Vec::new();
        fn visit(
            id: &str,
            operations: &HashMap<&str, &Operation>,
            uses: &mut HashMap<String, usize>,
            dependencies: &mut HashMap<String, Vec<Endpoint>>,
            steps: &mut Vec<String>,
        ) -> Result<(), SceneError> {
            if dependencies.contains_key(id) {
                return Ok(());
            }
            let operation = operations
                .get(id)
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("scene node {id} vanished")))?;
            let inputs = operation.active_inputs();
            dependencies.insert(id.to_string(), inputs.clone());
            for endpoint in inputs {
                if let Endpoint::Node(parent) = endpoint {
                    *uses.entry(parent.clone()).or_insert(0) += 1;
                    visit(&parent, operations, uses, dependencies, steps)?;
                }
            }
            steps.push(id.to_string());
            Ok(())
        }
        if let Endpoint::Node(id) = endpoint {
            *uses.entry(id.clone()).or_insert(0) += 1;
            visit(id, &operations, &mut uses, &mut dependencies, &mut steps)?;
        } else {
            return Ok(input);
        }

        // Coverage fingerprints never include the source revision: analytic masks survive source
        // changes, but combine/adjust keys include their dependencies so a parameter edit cannot
        // reuse an old result. External provider masks are never cached and their identity is part
        // of every dependent key.
        let mut coverage_keys: HashMap<String, String> = HashMap::new();
        let mut cacheable_coverage: HashSet<String> = HashSet::new();
        for id in &steps {
            let operation = operations
                .get(id.as_str())
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("scene node {id} vanished")))?;
            if !operation.is_coverage() {
                continue;
            }
            let mut dependency_keys = Vec::new();
            let mut cacheable = !matches!(operation, Operation::ExternalCoverage { .. });
            for dependency in operation.coverages() {
                let key = coverage_keys
                    .get(dependency)
                    .cloned()
                    .unwrap_or_else(|| format!("external:{dependency}"));
                if !cacheable_coverage.contains(dependency) {
                    cacheable = false;
                }
                dependency_keys.push(key);
            }
            let operation_key = match operation {
                Operation::ExternalCoverage { id } => format!(
                    "external:{id}:{:p}",
                    external_coverages
                        .get(id)
                        .map(|texture| texture.as_ptr())
                        .unwrap_or(std::ptr::null_mut())
                ),
                _ => format!("{operation:?}"),
            };
            coverage_keys.insert(
                id.clone(),
                format!(
                    "cov|{id}|{operation_key}|{width}x{height}|{},{},{}x{}|{}",
                    origin[0],
                    origin[1],
                    geometry.0,
                    geometry.1,
                    dependency_keys.join("|")
                ),
            );
            if cacheable {
                cacheable_coverage.insert(id.clone());
            }
        }

        // Image fingerprints include the caller's source revision and dependency keys, so a
        // parameter edit invalidates only the affected suffix while unchanged prefixes reuse.
        let mut keys: HashMap<String, String> = HashMap::new();
        for id in &steps {
            let operation = operations
                .get(id.as_str())
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("scene node {id} vanished")))?;
            let operation_key = match operation {
                Operation::ExternalCoverage { id } => format!(
                    "external:{id}:{:p}",
                    external_coverages
                        .get(id)
                        .map(|texture| texture.as_ptr())
                        .unwrap_or(std::ptr::null_mut())
                ),
                _ => format!("{operation:?}"),
            };
            let dependency_keys = dependencies
                .get(id)
                .into_iter()
                .flatten()
                .map(|endpoint| match endpoint {
                    Endpoint::Input => input_key.to_string(),
                    Endpoint::Node(parent) => {
                        if operations
                            .get(parent.as_str())
                            .is_some_and(|operation| operation.is_coverage())
                        {
                            coverage_keys.get(parent).cloned().unwrap_or_default()
                        } else {
                            keys.get(parent).cloned().unwrap_or_default()
                        }
                    }
                })
                .collect::<Vec<_>>();
            keys.insert(
                id.clone(),
                node_key(
                    source_revision,
                    id,
                    &operation_key,
                    width,
                    height,
                    origin,
                    geometry,
                    input_key,
                    &dependency_keys,
                ),
            );
        }

        // Prune cached prefixes: if a node hits, its ancestors do not need to run for this frame
        // unless another needed branch also consumes them.
        let mut needed: HashSet<String> = HashSet::new();
        let mut node_hits: HashMap<String, Arc<metal::Texture>> = HashMap::new();
        let mut coverage_hits: HashMap<String, Arc<metal::Texture>> = HashMap::new();
        #[allow(clippy::too_many_arguments)]
        fn mark_needed(
            id: &str,
            operations: &HashMap<&str, &Operation>,
            dependencies: &HashMap<String, Vec<Endpoint>>,
            keys: &HashMap<String, String>,
            coverage_keys: &HashMap<String, String>,
            cacheable_coverage: &HashSet<String>,
            coverage_cache: &mut TextureCache,
            node_cache: &mut TextureCache,
            receipt: &mut Receipt,
            source_revision: u64,
            needed: &mut HashSet<String>,
            node_hits: &mut HashMap<String, Arc<metal::Texture>>,
            coverage_hits: &mut HashMap<String, Arc<metal::Texture>>,
        ) -> Result<(), SceneError> {
            if !needed.insert(id.to_string()) {
                return Ok(());
            }
            let operation = operations
                .get(id)
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("scene node {id} vanished")))?;
            if cacheable_coverage.contains(id) {
                if let Some(key) = coverage_keys.get(id) {
                    if let Some(texture) = coverage_cache.get(key) {
                        receipt.coverage_hits += 1;
                        coverage_hits.insert(id.to_string(), texture);
                        return Ok(());
                    }
                }
            } else if source_revision != 0 && !operation.is_coverage() {
                if let Some(key) = keys.get(id) {
                    if let Some(texture) = node_cache.get(key) {
                        receipt.node_hits += 1;
                        node_hits.insert(id.to_string(), texture);
                        return Ok(());
                    }
                }
            }
            for endpoint in dependencies.get(id).into_iter().flatten() {
                if let Endpoint::Node(parent) = endpoint {
                    mark_needed(
                        parent,
                        operations,
                        dependencies,
                        keys,
                        coverage_keys,
                        cacheable_coverage,
                        coverage_cache,
                        node_cache,
                        receipt,
                        source_revision,
                        needed,
                        node_hits,
                        coverage_hits,
                    )?;
                }
            }
            Ok(())
        }
        if let Endpoint::Node(id) = endpoint {
            mark_needed(
                id,
                &operations,
                &dependencies,
                &keys,
                &coverage_keys,
                &cacheable_coverage,
                coverage_cache,
                node_cache,
                receipt,
                source_revision,
                &mut needed,
                &mut node_hits,
                &mut coverage_hits,
            )?;
        }

        let mut values: HashMap<String, Arc<metal::Texture>> = HashMap::new();
        let mut retired: Vec<Arc<metal::Texture>> = Vec::new();
        for id in steps {
            if !needed.contains(&id) {
                continue;
            }
            pool.recycle(&mut retired, budget);
            let operation = operations
                .get(id.as_str())
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("scene node {id} vanished")))?;
            if let Some(texture) = node_hits.get(&id) {
                values.insert(id, texture.clone());
                continue;
            }
            if let Some(texture) = coverage_hits.get(&id) {
                values.insert(id, texture.clone());
                continue;
            }
            receipt.nodes += 1;
            let base = match operation {
                Operation::Corrector { image, .. }
                | Operation::Group { image, .. }
                | Operation::Parallel { base: image, .. }
                | Operation::Layer { base: image, .. } => self.value(&values, image, &input)?,
                Operation::LinearCoverage { .. } | Operation::RadialCoverage { .. } => {
                    input.clone()
                }
                Operation::CombineCoverage { .. }
                | Operation::AdjustCoverage { .. }
                | Operation::ExternalCoverage { .. } => input.clone(),
            };
            let result: Arc<metal::Texture> = match operation {
                Operation::Corrector {
                    mask,
                    exposure_ev,
                    curve,
                    strength,
                    enabled,
                    ..
                } => {
                    let neutral = *exposure_ev == 0.0 && curve.iter().all(|p| p[0] == p[1]);
                    if !enabled || *strength == 0.0 || neutral {
                        base.clone()
                    } else {
                        let coverage = match mask {
                            Some(id) => {
                                Some(self.value(&values, &Endpoint::Node(id.clone()), &input)?)
                            }
                            None => None,
                        };
                        let output = self.make_texture(
                            pool,
                            budget,
                            width,
                            height,
                            MTLPixelFormat::RGBA32Float,
                        )?;
                        self.dispatch_color(
                            encoder,
                            flag,
                            receipt,
                            0,
                            base.as_ref(),
                            coverage.as_deref().unwrap_or(base.as_ref()),
                            base.as_ref(),
                            output.as_ref(),
                            [
                                2f32.powf(*exposure_ev),
                                *strength,
                                curve.len() as f32,
                                coverage.is_some() as u32 as f32,
                            ],
                            0,
                            curve,
                            origin,
                            geometry,
                        )?;
                        Arc::new(output)
                    }
                }
                Operation::Parallel {
                    layers, enabled, ..
                } => {
                    let mut current = base.clone();
                    if *enabled {
                        for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                            let branch = self.value(&values, &layer.image, &input)?;
                            if Arc::ptr_eq(&branch, &base) {
                                continue;
                            }
                            if layer.weight == 1.0 && layer.mode == Blend::Normal {
                                current = branch;
                                continue;
                            }
                            let output = self.make_texture(
                                pool,
                                budget,
                                width,
                                height,
                                MTLPixelFormat::RGBA32Float,
                            )?;
                            self.dispatch_color(
                                encoder,
                                flag,
                                receipt,
                                2,
                                current.as_ref(),
                                branch.as_ref(),
                                base.as_ref(),
                                output.as_ref(),
                                [layer.weight, 0.0, 0.0, 0.0],
                                0,
                                &[],
                                origin,
                                geometry,
                            )?;
                            current = Arc::new(output);
                        }
                    }
                    current
                }
                Operation::Layer {
                    layers, enabled, ..
                } => {
                    let mut current = base.clone();
                    if *enabled {
                        for layer in layers.iter().filter(|layer| layer.weight > 0.0) {
                            let branch = self.value(&values, &layer.image, &input)?;
                            if Arc::ptr_eq(&branch, &current) && layer.mode == Blend::Normal {
                                continue;
                            }
                            if layer.weight == 1.0 && layer.mode == Blend::Normal {
                                current = branch;
                                continue;
                            }
                            let output = self.make_texture(
                                pool,
                                budget,
                                width,
                                height,
                                MTLPixelFormat::RGBA32Float,
                            )?;
                            self.dispatch_color(
                                encoder,
                                flag,
                                receipt,
                                1,
                                current.as_ref(),
                                branch.as_ref(),
                                base.as_ref(),
                                output.as_ref(),
                                [layer.weight, layer.mode.code() as f32, 0.0, 0.0],
                                0,
                                &[],
                                origin,
                                geometry,
                            )?;
                            current = Arc::new(output);
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
                    if !enabled || *strength == 0.0 {
                        base.clone()
                    } else {
                        let child_input_key = match image {
                            Endpoint::Input => input_key.to_string(),
                            Endpoint::Node(parent) => keys.get(parent).cloned().unwrap_or_default(),
                        };
                        let child = self.evaluate(
                            graph,
                            base.clone(),
                            &graph.output,
                            encoder,
                            flag,
                            width,
                            height,
                            origin,
                            geometry,
                            coverage_cache,
                            node_cache,
                            receipt,
                            pool,
                            budget,
                            source_revision,
                            &child_input_key,
                            external_coverages,
                        )?;
                        if *strength == 1.0 || Arc::ptr_eq(&child, &base) {
                            child
                        } else {
                            let output = self.make_texture(
                                pool,
                                budget,
                                width,
                                height,
                                MTLPixelFormat::RGBA32Float,
                            )?;
                            self.dispatch_color(
                                encoder,
                                flag,
                                receipt,
                                1,
                                base.as_ref(),
                                child.as_ref(),
                                base.as_ref(),
                                output.as_ref(),
                                [*strength, 0.0, 0.0, 0.0],
                                0,
                                &[],
                                origin,
                                geometry,
                            )?;
                            Arc::new(output)
                        }
                    }
                }
                Operation::ExternalCoverage { id } => {
                    let mask = external_coverages.get(id).cloned().ok_or_else(|| {
                        SceneError::Invalid(format!("external coverage {id} is not bound"))
                    })?;
                    if mask.pixel_format() != MTLPixelFormat::R32Float
                        || mask.width() != width as u64
                        || mask.height() != height as u64
                    {
                        return Err(SceneError::Invalid(format!(
                            "external coverage {id} must match the execution tile"
                        )));
                    }
                    mask
                }
                Operation::LinearCoverage { start, end } => {
                    let output =
                        self.make_texture(pool, budget, width, height, MTLPixelFormat::R32Float)?;
                    self.dispatch_coverage(
                        encoder,
                        flag,
                        receipt,
                        0,
                        base.as_ref(),
                        base.as_ref(),
                        output.as_ref(),
                        [start[0], start[1], end[0], end[1]],
                        0,
                        origin,
                        geometry,
                    )?;
                    Arc::new(output)
                }
                Operation::RadialCoverage {
                    center,
                    radii,
                    feather,
                } => {
                    let output =
                        self.make_texture(pool, budget, width, height, MTLPixelFormat::R32Float)?;
                    self.dispatch_coverage(
                        encoder,
                        flag,
                        receipt,
                        1,
                        base.as_ref(),
                        base.as_ref(),
                        output.as_ref(),
                        [center[0], center[1], radii[0], radii[1]],
                        feather.to_bits(),
                        origin,
                        geometry,
                    )?;
                    Arc::new(output)
                }
                Operation::CombineCoverage {
                    base: a,
                    other: b,
                    mode,
                } => {
                    let a = self.value(&values, &Endpoint::Node(a.clone()), &input)?;
                    let b = self.value(&values, &Endpoint::Node(b.clone()), &input)?;
                    let output =
                        self.make_texture(pool, budget, width, height, MTLPixelFormat::R32Float)?;
                    self.dispatch_coverage(
                        encoder,
                        flag,
                        receipt,
                        2,
                        a.as_ref(),
                        b.as_ref(),
                        output.as_ref(),
                        [
                            match mode {
                                CoverageCombine::Add => 0.0,
                                CoverageCombine::Subtract => 1.0,
                                CoverageCombine::Intersect => 2.0,
                            },
                            0.0,
                            0.0,
                            0.0,
                        ],
                        0,
                        origin,
                        geometry,
                    )?;
                    Arc::new(output)
                }
                Operation::AdjustCoverage {
                    mask,
                    strength,
                    inverted,
                } => {
                    let mask = self.value(&values, &Endpoint::Node(mask.clone()), &input)?;
                    let output =
                        self.make_texture(pool, budget, width, height, MTLPixelFormat::R32Float)?;
                    self.dispatch_coverage(
                        encoder,
                        flag,
                        receipt,
                        3,
                        mask.as_ref(),
                        mask.as_ref(),
                        output.as_ref(),
                        [*strength, *inverted as u32 as f32, 0.0, 0.0],
                        0,
                        origin,
                        geometry,
                    )?;
                    Arc::new(output)
                }
            };
            if cacheable_coverage.contains(&id) {
                if let Some(key) = coverage_keys.get(&id) {
                    coverage_cache.put(
                        key.clone(),
                        result.clone(),
                        result.allocated_size() as usize,
                        budget,
                    );
                }
            } else if source_revision != 0
                && !operation.is_coverage()
                && !matches!(operation, Operation::Group { .. })
                && !Arc::ptr_eq(&result, &base)
            {
                if let Some(key) = keys.get(&id) {
                    node_cache.put(
                        key.clone(),
                        result.clone(),
                        result.allocated_size() as usize,
                        budget,
                    );
                }
            }
            values.insert(id.clone(), result);
            for endpoint in dependencies.get(&id).into_iter().flatten() {
                if let Endpoint::Node(parent) = endpoint {
                    if let Some(count) = uses.get_mut(parent) {
                        *count = count.saturating_sub(1);
                        if *count == 0 {
                            if let Some(texture) = values.remove(parent) {
                                retired.push(texture);
                            }
                        }
                    }
                }
            }
        }
        pool.recycle(&mut retired, budget);
        match endpoint {
            Endpoint::Input => Ok(input),
            Endpoint::Node(id) => values
                .remove(id)
                .ok_or_else(|| SceneError::Render(format!("scene output {id} did not render"))),
        }
    }

    fn value(
        &self,
        values: &HashMap<String, Arc<metal::Texture>>,
        endpoint: &Endpoint,
        input: &Arc<metal::Texture>,
    ) -> Result<Arc<metal::Texture>, SceneError> {
        match endpoint {
            Endpoint::Input => Ok(input.clone()),
            Endpoint::Node(id) => values
                .get(id)
                .cloned()
                .ok_or_else(|| SceneError::Render(format!("scene node {id} missing"))),
        }
    }

    fn make_texture(
        &self,
        pool: &mut SurfacePool,
        budget: &mut SurfaceBudget,
        width: u32,
        height: u32,
        format: MTLPixelFormat,
    ) -> Result<metal::Texture, SceneError> {
        if let Some(texture) = pool.take(width, height, format) {
            return Ok(texture);
        }
        let descriptor = metal::TextureDescriptor::new();
        descriptor.set_texture_type(metal::MTLTextureType::D2);
        descriptor.set_pixel_format(format);
        descriptor.set_width(width as u64);
        descriptor.set_height(height as u64);
        descriptor.set_storage_mode(MTLStorageMode::Private);
        descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        let estimate = self.device.heap_texture_size_and_align(&descriptor).size as usize;
        budget.reserve(estimate)?;
        let texture = self.device.new_texture(&descriptor);
        let actual = texture.allocated_size() as usize;
        if actual > estimate {
            budget.reserve(actual - estimate)?;
        } else {
            budget.release(estimate - actual);
        }
        if texture.width() != width as u64 || texture.height() != height as u64 {
            return Err(SceneError::Backend(
                "scene texture allocation failed".into(),
            ));
        }
        Ok(texture)
    }

    fn dispatch_color(
        &self,
        encoder: &metal::ComputeCommandEncoderRef,
        flag: &metal::Buffer,
        receipt: &mut Receipt,
        kind: u32,
        input: &metal::TextureRef,
        other: &metal::TextureRef,
        original: &metal::TextureRef,
        output: &metal::TextureRef,
        scalars: [f32; 4],
        parameter: u32,
        curve: &[[f32; 2]],
        origin: [i64; 2],
        geometry: (u32, u32),
    ) -> Result<(), SceneError> {
        let params = Params {
            scalars,
            geometry: [
                origin[0].max(0) as u32,
                origin[1].max(0) as u32,
                geometry.0,
                geometry.1,
            ],
            kind,
            parameter,
        };
        encoder.set_compute_pipeline_state(&self.color);
        encoder.set_texture(0, Some(input));
        encoder.set_texture(1, Some(other));
        encoder.set_texture(2, Some(original));
        encoder.set_texture(3, Some(output));
        encoder.set_bytes(
            0,
            std::mem::size_of::<Params>() as u64,
            (&params as *const Params).cast(),
        );
        encoder.set_buffer(1, Some(flag), 0);
        let dummy = [[0.0f32, 0.0]];
        let points = if curve.is_empty() { &dummy } else { curve };
        encoder.set_bytes(
            2,
            std::mem::size_of_val(points) as u64,
            points.as_ptr().cast(),
        );
        receipt.dispatches += 1;
        let lanes = self.color.thread_execution_width();
        let threads = MTLSize::new(output.width(), output.height(), 1);
        let group = MTLSize::new(
            lanes,
            (self.color.max_total_threads_per_threadgroup() / lanes).min(8),
            1,
        );
        encoder.dispatch_threads(threads, group);
        Ok(())
    }

    fn dispatch_coverage(
        &self,
        encoder: &metal::ComputeCommandEncoderRef,
        flag: &metal::Buffer,
        receipt: &mut Receipt,
        kind: u32,
        input: &metal::TextureRef,
        other: &metal::TextureRef,
        output: &metal::TextureRef,
        scalars: [f32; 4],
        parameter: u32,
        origin: [i64; 2],
        geometry: (u32, u32),
    ) -> Result<(), SceneError> {
        let params = Params {
            scalars,
            geometry: [
                origin[0].max(0) as u32,
                origin[1].max(0) as u32,
                geometry.0,
                geometry.1,
            ],
            kind,
            parameter,
        };
        encoder.set_compute_pipeline_state(&self.coverage);
        encoder.set_texture(0, Some(input));
        encoder.set_texture(1, Some(other));
        encoder.set_texture(2, Some(output));
        encoder.set_bytes(
            0,
            std::mem::size_of::<Params>() as u64,
            (&params as *const Params).cast(),
        );
        encoder.set_buffer(1, Some(flag), 0);
        receipt.dispatches += 1;
        let lanes = self.coverage.thread_execution_width();
        let threads = MTLSize::new(output.width(), output.height(), 1);
        let group = MTLSize::new(
            lanes,
            (self.coverage.max_total_threads_per_threadgroup() / lanes).min(8),
            1,
        );
        encoder.dispatch_threads(threads, group);
        Ok(())
    }
}

const SHADER: &str = r#"
#include <metal_stdlib>
using namespace metal;
struct Parameters { float4 scalars; uint4 geometry; uint kind; uint parameter; };
constant float3 ap1Y = float3(0.2722287168f, 0.6740817658f, 0.0536895174f);
float exposureDelta(float ev, constant float2* points, uint count) {
  if (ev <= points[0].x) return points[0].y - points[0].x;
  for (uint i = 1; i < count; ++i) {
    float2 a = points[i-1], b = points[i];
    if (ev <= b.x) return mix(a.y-a.x, b.y-b.x, (ev-a.x)/(b.x-a.x));
  }
  return points[count-1].y - points[count-1].x;
}
float3 soft(float3 b, float3 s) {
  float3 d = select(sqrt(b), ((16.0f*b-12.0f)*b+4.0f)*b, b <= 0.25f);
  return select(b + (2.0f*s-1.0f)*(d-b), b - (1.0f-2.0f*s)*b*(1.0f-b), s <= 0.5f);
}
float3 blend(float3 b, float3 s, uint mode) {
  switch (mode) {
    case 0: return s;
    case 1: return b + s;
    case 2: return b - s;
    case 3: return b * s;
    case 8: return max(b,s);
    case 9: return min(b,s);
    case 10: return abs(b-s);
    case 11: return s + (dot(b,ap1Y)-dot(s,ap1Y));
    case 12: return b + (dot(s,ap1Y)-dot(b,ap1Y));
  }
  float3 x = clamp(b,0.0f,1.0f), y = clamp(s,0.0f,1.0f);
  float3 screen = 1.0f-2.0f*(1.0f-x)*(1.0f-y), multiply = 2.0f*x*y;
  float3 z = mode == 4 ? x+y-x*y : mode == 5 ? select(screen,multiply,x <= 0.5f)
    : mode == 6 ? soft(x,y) : select(screen,multiply,y <= 0.5f);
  return z+(b-x)+(s-y);
}
kernel void rmDagColorV1(texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::read> other [[texture(1)]], texture2d<float,access::read> base [[texture(2)]],
    texture2d<float,access::write> output [[texture(3)]], constant Parameters& p [[buffer(0)]],
    device atomic_uint& invalid [[buffer(1)]], constant float2* curve [[buffer(2)]], uint2 xy [[thread_position_in_grid]]) {
  float4 a = input.read(xy);
  if (!all(isfinite(a)) || a.a < 0 || a.a > 1) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  if (a.a == 0) { output.write(float4(0),xy); return; }
  float3 rgb;
  if (p.kind == 0) {
    float w = p.scalars.y * (p.scalars.w == 0 ? 1.0f : other.read(xy).r);
    float gain = p.scalars.x;
    float luma = dot(a.rgb,ap1Y);
    if (p.scalars.z > 0 && luma > 0) gain *= exp2(exposureDelta(log2(luma)-log2(a.a)+log2(gain),curve,uint(p.scalars.z)));
    rgb = w == 0 ? a.rgb : a.rgb * mix(1.0f,gain,w);
  } else {
    float4 b = other.read(xy);
    if (!all(isfinite(b)) || a.a != b.a) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
    if (p.kind == 2) rgb = a.rgb + p.scalars.x*(b.rgb-base.read(xy).rgb);
    else if (p.scalars.y == 0) rgb = mix(a.rgb,b.rgb,p.scalars.x);
    else rgb = mix(a.rgb,blend(a.rgb/a.a,b.rgb/b.a,uint(p.scalars.y))*a.a,p.scalars.x);
  }
  if (!all(isfinite(rgb))) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  output.write(float4(rgb,a.a),xy);
}
kernel void rmDagCoverageV1(texture2d<float,access::read> input [[texture(0)]],
    texture2d<float,access::read> other [[texture(1)]], texture2d<float,access::write> output [[texture(2)]],
    constant Parameters& p [[buffer(0)]], device atomic_uint& invalid [[buffer(1)]], uint2 xy [[thread_position_in_grid]]) {
  float c;
  float2 q = (float2(p.geometry.xy+xy)+0.5f)/float2(p.geometry.zw);
  if (p.kind == 0) {
    float2 axis=p.scalars.zw-p.scalars.xy;
    c = clamp(dot(q-p.scalars.xy,axis)/dot(axis,axis),0.0f,1.0f);
  } else if (p.kind == 1) {
    float f = as_type<float>(p.parameter), r = length((q-p.scalars.xy)/p.scalars.zw);
    c = f == 0 ? (r<=1.0f ? 1.0f : 0.0f) : 1.0f-smoothstep(1.0f-f,1.0f,r);
  } else if (p.kind == 2) {
    float a=input.read(xy).r, b=other.read(xy).r;
    c = p.scalars.x == 0 ? a+b*(1.0f-a) : p.scalars.x == 1 ? a*(1.0f-b) : a*b;
  } else {
    float a = input.read(xy).r;
    c = (p.scalars.y == 0 ? a : 1.0f-a)*p.scalars.x;
  }
  if (!isfinite(c)) { atomic_store_explicit(&invalid,1,memory_order_relaxed); return; }
  output.write(float4(clamp(c,0.0f,1.0f),0,0,1),xy);
}
"#;
