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
use std::collections::{HashMap, VecDeque};
use std::ffi::c_void;
use std::sync::{Arc, Mutex};

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
struct SurfaceBudget {
    maximum: usize,
    used: usize,
}

impl SurfaceBudget {
    fn new(maximum: usize, input: usize) -> Self {
        Self {
            maximum,
            used: input.min(maximum),
        }
    }

    fn reserve(&mut self, bytes: usize) -> Result<(), SceneError> {
        if bytes > self.maximum.saturating_sub(self.used) {
            return Err(SceneError::Budget(
                "scene graph exceeded the surface budget".into(),
            ));
        }
        self.used += bytes;
        Ok(())
    }

    fn release(&mut self, bytes: usize) {
        self.used = self.used.saturating_sub(bytes);
    }
}

/// Source-independent coverage prefixes (ramps, ellipses, combines) survive across frames.
/// Their key includes the node, all parameters, the surface size, and frame geometry.
struct CoverageCache {
    entries: HashMap<String, (Arc<metal::Texture>, usize)>,
    order: VecDeque<String>,
    bytes: usize,
}

impl CoverageCache {
    const BUDGET: usize = 512 * 1024 * 1024;
    const ENTRIES: usize = 64;

    fn new() -> Self {
        Self {
            entries: HashMap::new(),
            order: VecDeque::new(),
            bytes: 0,
        }
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
        if bytes > Self::BUDGET {
            return;
        }
        if let Some((old, old_bytes)) = self.entries.remove(&key) {
            self.bytes = self.bytes.saturating_sub(old_bytes);
            if let Ok(texture) = Arc::try_unwrap(old) {
                budget.release(texture_bytes(
                    texture.width() as u32,
                    texture.height() as u32,
                    texture.pixel_format(),
                ));
            }
        }
        while self.bytes + bytes > Self::BUDGET || self.entries.len() >= Self::ENTRIES {
            let Some(oldest) = self.order.pop_front() else {
                break;
            };
            if let Some((old, old_bytes)) = self.entries.remove(&oldest) {
                self.bytes = self.bytes.saturating_sub(old_bytes);
                if let Ok(texture) = Arc::try_unwrap(old) {
                    budget.release(texture_bytes(
                        texture.width() as u32,
                        texture.height() as u32,
                        texture.pixel_format(),
                    ));
                }
            }
        }
        self.bytes += bytes;
        self.entries.insert(key.clone(), (texture, bytes));
        self.order.push_back(key);
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
        self.bytes = self
            .bytes
            .saturating_sub(texture_bytes(width, height, format));
        Some(texture)
    }

    fn give(&mut self, texture: metal::Texture, budget: &mut SurfaceBudget) {
        let bytes = texture_bytes(
            texture.width() as u32,
            texture.height() as u32,
            texture.pixel_format(),
        );
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

fn texture_bytes(width: u32, height: u32, format: MTLPixelFormat) -> usize {
    let pixel = if format == MTLPixelFormat::R32Float {
        4
    } else {
        16
    };
    width as usize * height as usize * pixel
}

fn coverage_key(
    id: &str,
    operation: &Operation,
    width: u32,
    height: u32,
    origin: [i64; 2],
    geometry: (u32, u32),
) -> String {
    format!(
        "{id}|{operation:?}|{width}x{height}|{},{},{}x{}",
        origin[0], origin[1], geometry.0, geometry.1
    )
}

#[derive(Clone, Copy)]
enum Target {
    Final,
    Node,
    Bypass,
}

pub struct SceneProgram {
    device: metal::Device,
    queue: metal::CommandQueue,
    color: metal::ComputePipelineState,
    coverage: metal::ComputePipelineState,
    graph: Scope,
    cache: Mutex<CoverageCache>,
}

impl SceneProgram {
    pub fn open(device_pointer: *mut c_void, document: &[u8]) -> Result<Self, SceneError> {
        if device_pointer.is_null() {
            return Err(SceneError::Invalid("null Metal device".into()));
        }
        let (_, graph) = parse(document)?;
        let wanted = unsafe { metal::DeviceRef::from_ptr(device_pointer.cast()) };
        let device = wanted.to_owned();
        let options = metal::CompileOptions::new();
        options.set_fast_math_enabled(false);
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
            graph,
            cache: Mutex::new(CoverageCache::new()),
        })
    }

    pub fn graph(&self) -> &Scope {
        &self.graph
    }

    pub fn render(
        &self,
        input: &metal::TextureRef,
        output: &metal::TextureRef,
        view: &ViewSpec,
        external_coverages: &HashMap<String, Arc<metal::Texture>>,
        current: impl Fn() -> bool,
    ) -> Result<(), SceneError> {
        if !current() {
            return Err(SceneError::Render("stale scene frame".into()));
        }
        let width = input.width() as u32;
        let height = input.height() as u32;
        if width == 0
            || height == 0
            || input.pixel_format() != MTLPixelFormat::RGBA32Float
            || output.pixel_format() != MTLPixelFormat::RGBA32Float
            || input.width() != output.width()
            || input.height() != output.height()
            || output.usage().contains(MTLTextureUsage::ShaderWrite) == false
        {
            return Err(SceneError::Invalid(
                "scene surfaces must be matching RGBA32F textures".into(),
            ));
        }
        let input_owned = input.to_owned();
        let output_owned = output.to_owned();
        let input = Arc::new(input_owned);
        let output_surface = Arc::new(output_owned);
        let flag = self
            .device
            .new_buffer(4, MTLResourceOptions::StorageModeShared);
        unsafe {
            *(flag.contents().cast::<u32>()) = 0;
        }
        let target = match view.target.as_str() {
            "bypass" => Target::Bypass,
            "node" => Target::Node,
            "final" | "" => Target::Final,
            other => {
                return Err(SceneError::Invalid(format!(
                    "unknown scene view target {other}"
                )))
            }
        };
        let selected = match (target, view.id.as_deref()) {
            (Target::Node, Some(id)) => {
                let operation = self
                    .graph
                    .nodes
                    .iter()
                    .find(|node| node.id == id)
                    .map(|node| &node.operation)
                    .ok_or_else(|| SceneError::Invalid(format!("unknown scene node {id}")))?;
                if operation.is_coverage() {
                    return Err(SceneError::Invalid(format!(
                        "coverage node {id} is not previewable"
                    )));
                }
                Some(id.to_string())
            }
            (Target::Node, None) => return Err(SceneError::Invalid("node view has no id".into())),
            _ => None,
        };
        let origin = view.origin.unwrap_or([0, 0]);
        let geometry = view
            .geometry
            .map(|size| (size[0], size[1]))
            .unwrap_or((width, height));
        if !external_coverages.is_empty()
            && (origin != [0, 0] || width != geometry.0 || height != geometry.1)
        {
            return Err(SceneError::Invalid(
                "external coverage requires a full-frame scene render".into(),
            ));
        }
        let mut cache = self
            .cache
            .lock()
            .map_err(|_| SceneError::Render("scene coverage cache poisoned".into()))?;
        let mut pool = SurfacePool::new();
        let maximum = view.surface_budget.unwrap_or(1_536 * 1024 * 1024) as usize;
        let mut budget = SurfaceBudget::new(
            maximum,
            texture_bytes(width, height, MTLPixelFormat::RGBA32Float),
        );
        let command = self.queue.new_command_buffer();
        let encoder = command.new_compute_command_encoder();
        let rendered = self.evaluate(
            &self.graph,
            input.clone(),
            selected.as_deref(),
            target,
            encoder,
            &flag,
            width,
            height,
            origin,
            geometry,
            &mut cache,
            &mut pool,
            &mut budget,
            external_coverages,
        )?;
        encoder.end_encoding();
        let source = rendered.as_ref();
        if source.as_ptr() != output_surface.as_ptr() {
            let blit = command.new_blit_command_encoder();
            blit.copy_from_texture(
                source,
                0,
                0,
                MTLOrigin { x: 0, y: 0, z: 0 },
                MTLSize::new(width as u64, height as u64, 1),
                &output_surface,
                0,
                0,
                MTLOrigin { x: 0, y: 0, z: 0 },
            );
            blit.end_encoding();
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
        Ok(())
    }

    fn evaluate(
        &self,
        scope: &Scope,
        input: Arc<metal::Texture>,
        selected: Option<&str>,
        target: Target,
        encoder: &metal::ComputeCommandEncoderRef,
        flag: &metal::Buffer,
        width: u32,
        height: u32,
        origin: [i64; 2],
        geometry: (u32, u32),
        cache: &mut CoverageCache,
        pool: &mut SurfacePool,
        budget: &mut SurfaceBudget,
        external_coverages: &HashMap<String, Arc<metal::Texture>>,
    ) -> Result<Arc<metal::Texture>, SceneError> {
        if matches!(target, Target::Bypass) {
            return Ok(input);
        }
        let operations: HashMap<&str, &Operation> = scope
            .nodes
            .iter()
            .map(|node| (node.id.as_str(), &node.operation))
            .collect();
        let endpoint = match (target, selected) {
            (Target::Node, Some(id)) => Endpoint::Node(id.to_string()),
            _ => scope.output.clone(),
        };
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
        if let Endpoint::Node(id) = &endpoint {
            *uses.entry(id.clone()).or_insert(0) += 1;
            visit(id, &operations, &mut uses, &mut dependencies, &mut steps)?;
        } else {
            return Ok(input);
        }
        let mut values: HashMap<String, Arc<metal::Texture>> = HashMap::new();
        let mut retired: Vec<Arc<metal::Texture>> = Vec::new();
        for id in steps {
            pool.recycle(&mut retired, budget);
            let operation = operations
                .get(id.as_str())
                .copied()
                .ok_or_else(|| SceneError::Invalid(format!("scene node {id} vanished")))?;
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
            let key = operation
                .is_source_independent_coverage()
                .then(|| coverage_key(&id, operation, width, height, origin, geometry));
            let cached = key.as_deref().and_then(|key| cache.get(key));
            let was_cached = cached.is_some();
            let result: Arc<metal::Texture> = match (cached, operation) {
                (Some(texture), _) => texture,
                (None, operation) => match operation {
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
                            base
                        } else {
                            let coverage = match mask {
                                Some(id) => Some(self.value(
                                    &values,
                                    &Endpoint::Node(id.clone()),
                                    &input,
                                )?),
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
                        graph,
                        strength,
                        enabled,
                        ..
                    } => {
                        if !enabled || *strength == 0.0 {
                            base
                        } else {
                            let child = self.evaluate(
                                graph,
                                base.clone(),
                                None,
                                Target::Final,
                                encoder,
                                flag,
                                width,
                                height,
                                origin,
                                geometry,
                                cache,
                                pool,
                                budget,
                                external_coverages,
                            )?;
                            if *strength == 1.0 {
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
                                "external coverage {id} must be full-frame R32F"
                            )));
                        }
                        mask
                    }
                    Operation::LinearCoverage { start, end } => {
                        let output = self.make_texture(
                            pool,
                            budget,
                            width,
                            height,
                            MTLPixelFormat::R32Float,
                        )?;
                        self.dispatch_coverage(
                            encoder,
                            flag,
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
                        let output = self.make_texture(
                            pool,
                            budget,
                            width,
                            height,
                            MTLPixelFormat::R32Float,
                        )?;
                        self.dispatch_coverage(
                            encoder,
                            flag,
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
                        let output = self.make_texture(
                            pool,
                            budget,
                            width,
                            height,
                            MTLPixelFormat::R32Float,
                        )?;
                        self.dispatch_coverage(
                            encoder,
                            flag,
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
                        let output = self.make_texture(
                            pool,
                            budget,
                            width,
                            height,
                            MTLPixelFormat::R32Float,
                        )?;
                        self.dispatch_coverage(
                            encoder,
                            flag,
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
                },
            };
            if let (Some(key), false) = (key, was_cached) {
                cache.put(
                    key,
                    result.clone(),
                    texture_bytes(width, height, MTLPixelFormat::R32Float),
                    budget,
                );
            }
            values.insert(id.clone(), result);
            for endpoint in dependencies.get(&id).into_iter().flatten() {
                if let Endpoint::Node(parent) = endpoint {
                    if let Some(count) = uses.get_mut(parent) {
                        *count -= 1;
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
                .remove(&id)
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
        budget.reserve(texture_bytes(width, height, format))?;
        let descriptor = metal::TextureDescriptor::new();
        descriptor.set_texture_type(metal::MTLTextureType::D2);
        descriptor.set_pixel_format(format);
        descriptor.set_width(width as u64);
        descriptor.set_height(height as u64);
        descriptor.set_storage_mode(MTLStorageMode::Private);
        descriptor.set_usage(MTLTextureUsage::ShaderRead | MTLTextureUsage::ShaderWrite);
        let texture = self.device.new_texture(&descriptor);
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
