//! GPU and Core Image must agree on the underlying surface, every pixel, orientation, and completion.
#![cfg(all(target_os = "macos", feature = "surface-fence-probe"))]
use foreign_types::ForeignType;
use rawmaster_image::{gpu::Gpu, render_cpu, Frame, Pixel, Plan};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{env, error::Error, ffi::c_void, fs, path::Path};
extern "C" {
    fn rm_replay_create(
        device: *mut c_void,
        w: u32,
        h: u32,
        rgba: *const f32,
        mask: *const f32,
    ) -> *mut c_void;
    fn rm_replay_texture(owner: *mut c_void, i: u32) -> *mut c_void;
    fn rm_replay_id(owner: *mut c_void, i: u32) -> u32;
    fn rm_replay_stride(owner: *mut c_void, i: u32) -> usize;
    fn rm_replay_registry(owner: *mut c_void, i: u32) -> u64;
    fn rm_replay_read(owner: *mut c_void, rgba: *mut f32, ci: bool) -> bool;
    fn rm_replay_release(owner: *mut c_void);
    fn rm_replay_drop_host_textures(owner: *mut c_void);
}
struct Owner(*mut c_void);
impl Drop for Owner {
    fn drop(&mut self) {
        unsafe { rm_replay_release(self.0) }
    }
}
fn hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
fn graph(amount: f64) -> String {
    json!({
    "version":1,"working":"extended-linear-srgb-premul-f32","output":"result","nodes":[
        {"id":"src","op":"source"},{"id":"sky","op":"mask"},{"id":"global","op":"exposure","image":"src","ev":0.25},
        {"id":"local","op":"masked_exposure","image":"global","mask":"sky","ev":-1.25},
        {"id":"look","op":"photo_filter","image":"local","look":"vivid","amount":amount},
        {"id":"result","op":"blend","base":"global","layer":"look","mask":"sky"}]}).to_string()
}
fn maxerr(a: &[Pixel], b: &[Pixel]) -> f32 {
    assert_eq!(a.len(), b.len());
    a.iter()
        .flatten()
        .zip(b.iter().flatten())
        .fold(0.0f32, |m, (a, b)| m.max((a - b).abs()))
}
#[test]
#[ignore = "uses Metal hardware and the prepared photographic fixture; run tests/metal_surface/check.sh"]
fn real_surface_dag_replay() -> Result<(), Box<dyn Error>> {
    let dir = env::var_os("RAWMASTER_METAL_INPUTS")
        .ok_or("set RAWMASTER_METAL_INPUTS to a prepared replay_mask.py fixture")?;
    let dir = Path::new(&dir);
    let default_filters = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Sources/RAWMasterImaging/Resources/PhotoFilters");
    let filters = env::var_os("RAWMASTER_TEST_FILTERS")
        .map(std::path::PathBuf::from)
        .unwrap_or(default_filters);
    let filters = filters.as_path();
    let manifest: Value = serde_json::from_slice(&fs::read(dir.join("prepared.json"))?)?;
    let w = manifest["size"][0].as_u64().unwrap() as u32;
    let h = manifest["size"][1].as_u64().unwrap() as u32;
    let image = fs::read(dir.join("source.rgba32fle"))?;
    let coverage = fs::read(dir.join("mask.r32fle"))?;
    assert_eq!(hash(&image), manifest["sourceF32SHA256"]);
    assert_eq!(hash(&coverage), manifest["maskF32SHA256"]);
    let pixels: Vec<Pixel> = image
        .as_chunks::<16>()
        .0
        .iter()
        .copied()
        .map(bytemuck::cast)
        .collect();
    let mask: Vec<f32> = coverage
        .as_chunks::<4>()
        .0
        .iter()
        .copied()
        .map(f32::from_le_bytes)
        .collect();
    let plans = [
        Plan::parse_with_resources(&graph(37.5), Some(filters))?,
        Plan::parse_with_resources(&graph(43.75), Some(filters))?,
    ];
    let frame = Frame::new(w, h, &pixels, &mask)?;
    let expected = [
        render_cpu(&plans[0], &frame)?,
        render_cpu(&plans[1], &frame)?,
    ];
    let gpu = std::sync::Arc::new(Gpu::open()?);
    let device = gpu.metal_device()?;
    let native = unsafe {
        rm_replay_create(
            device.as_ptr().cast(),
            w,
            h,
            pixels.as_ptr().cast(),
            mask.as_ptr(),
        )
    };
    if native.is_null() {
        return Err("native resource creation failed".into());
    }
    let owner = Owner(native);
    let program = std::sync::Arc::new(gpu.compile_metal_surfaces(&plans[0])?);
    let textures: [metal::Texture; 3] =
        [0, 1, 2].map(|i| unsafe { metal::Texture::from_ptr(rm_replay_texture(native, i).cast()) });
    let native_ids = [0, 1, 2].map(|i| unsafe { rm_replay_id(native, i) });
    let device_ids = [0, 1, 2].map(|i| unsafe { rm_replay_registry(native, i) });
    assert!(device_ids.iter().all(|&id| id == device.registry_id()));
    assert!(unsafe {
        gpu.bind_metal_surfaces(
            &program,
            &plans[0],
            [&textures[0], &textures[1], &textures[0]],
        )
    }
    .is_err());
    let mut external = unsafe {
        gpu.bind_metal_surfaces(
            &program,
            &plans[0],
            [&textures[0], &textures[1], &textures[2]],
        )
    }?;
    assert_eq!(native_ids, external.surface_ids);
    assert_eq!(external.borrowed_backings(), 3);
    // Host texture references may go out of scope; the imported texture retains the same native object and IOSurface.
    drop(textures);
    unsafe {
        rm_replay_drop_host_textures(owner.0);
    }
    let mut rows = Vec::new();
    for (state, cancel) in [(0, false), (1, false), (0, true)] {
        external.update(&plans[state])?;
        let result = external.submit_join(|| {
            if cancel {
                Err("obsolete render revision after submit".into())
            } else {
                Ok(())
            }
        });
        if cancel {
            assert_eq!(result, Err("obsolete render revision after submit".into()))
        } else {
            result?;
        }
        let mut surface = vec![[0.0; 4]; pixels.len()];
        let mut native_ci = vec![[0.0; 4]; pixels.len()];
        assert!(unsafe { rm_replay_read(owner.0, surface.as_mut_ptr().cast(), false) });
        assert!(unsafe { rm_replay_read(owner.0, native_ci.as_mut_ptr().cast(), true) });
        let error = maxerr(&surface, &expected[state]);
        let ci_error = maxerr(&native_ci, &surface);
        let flip_error = surface
            .chunks_exact(w as usize)
            .rev()
            .zip(native_ci.chunks_exact(w as usize))
            .map(|(a, b)| maxerr(a, b))
            .fold(0.0, f32::max);
        if error > 2e-4 || ci_error > 2e-5 || flip_error < 0.05 {
            return Err(format!(
                "native output differs: cpu={error} ci={ci_error} flipped={flip_error}"
            )
            .into());
        }
        rows.push(json!({"state":state,"afterSubmitCancellation":cancel,"published":!cancel,"nativeTerminalFence":true,
            "maxAbsVsCPU":error,"maxAbsCoreImageVsSurface":ci_error,"maxAbsVerticallyReversedVsCoreImage":flip_error,
            "surfaceSHA256":hash(bytemuck::cast_slice(&surface)),"coreImageSHA256":hash(bytemuck::cast_slice(&native_ci)),
            "topRowF32SHA256":hash(bytemuck::cast_slice(&surface[..w as usize])),
            "bottomRowF32SHA256":hash(bytemuck::cast_slice(&surface[surface.len()-w as usize..]))}));
    }
    external.update(&plans[1])?;
    external.probe_timeout_and_drain()?;
    let mut after_timeout = vec![[0.0; 4]; pixels.len()];
    assert!(unsafe { rm_replay_read(owner.0, after_timeout.as_mut_ptr().cast(), false) });
    let timeout_after_fence_error = maxerr(&after_timeout, &expected[1]);
    assert!(timeout_after_fence_error < 2e-4);
    let strides = [0, 1, 2].map(|i| unsafe { rm_replay_stride(native, i) });
    let out = json!({"scope":"production crate, opt-in external Metal texture ports through the fused DAG compiler",
        "sourceSHA256":manifest["binding"]["sourceSHA256"],"maskSHA256":manifest["binding"]["maskSHA256"],
        "sourceF32SHA256":manifest["sourceF32SHA256"],"maskF32SHA256":manifest["maskF32SHA256"],
        "adapter":gpu.adapter,"registryID":device.registry_id(),"registryIDFromNativeTextures":device_ids,
        "size":[w,h],"nativeIOSurfaceIDs":native_ids,"wrappedIOSurfaceIDs":external.surface_ids,
        "strides":strides,
        "formats":["RGBA32Float","R32Float","RGBA32Float"],"actualWgpuPollTimeout":true,"timeoutNativeFenceJoined":true,"maxAbsRecoveredUnpublishedVsCPU":timeout_after_fence_error,"timedOutFramePublished":false,"aliasRejection":true,"identicalMTLTextureHandles":3,"hostTextureReferencesDroppedBeforeSubmit":true,
        "fixturePreparation":"host fills native input and mask once; output preinitialized. Existing app GPU surfaces can enter at this boundary",
        "nativeConsumer":"CVPixelBuffer backed by output IOSurface -> CIImage in extended linear sRGB -> test CIRenderDestination RGBAf flipped=true",
        "wgpuFrameUploads":0,"wgpuFrameReadbacks":0,"dispatchesPerUpdate":1,
        "inspection":"test reads native CPU rows and explicitly asks Core Image to render into a test bitmap after the native GPU completion fence",
        "states":rows});
    let report = serde_json::to_string_pretty(&out)?;
    if let Some(path) = env::var_os("RAWMASTER_METAL_REPORT") {
        fs::write(path, format!("{report}\n"))?;
    }
    println!("{report}");
    Ok(())
}

#[test]
#[ignore = "requires a Metal Mac; forces a real zero-deadline wait on two named surfaces"]
fn named_surface_timeout_drains_before_retry() -> Result<(), Box<dyn Error>> {
    let gpu = std::sync::Arc::new(Gpu::open()?);
    let device = gpu.metal_device()?;
    let (w, h) = (9, 5);
    let n = (w * h) as usize;
    let pixels: Vec<Pixel> = (0..n)
        .map(|i| [(i as f32 - 11.0) / 20.0, 0.5, 1.25, 1.0])
        .collect();
    let sky: Vec<_> = (0..n).map(|i| (i % 9) as f32 / 8.0).collect();
    let subject: Vec<_> = (0..n).map(|i| (i / 9) as f32 / 4.0).collect();
    let native = |coverage: &[f32]| -> Result<Owner, Box<dyn Error>> {
        let pointer = unsafe {
            rm_replay_create(
                device.as_ptr().cast(),
                w,
                h,
                pixels.as_ptr().cast(),
                coverage.as_ptr(),
            )
        };
        if pointer.is_null() {
            return Err("could not create joined IOSurface witness".into());
        }
        Ok(Owner(pointer))
    };
    let first = native(&sky)?;
    let second = native(&subject)?;
    let texture = |owner: &Owner, index| unsafe {
        metal::Texture::from_ptr(rm_replay_texture(owner.0, index).cast())
    };
    let input = texture(&first, 0);
    let sky_texture = texture(&first, 1);
    let subject_texture = texture(&second, 1);
    let output = texture(&first, 2);
    let plan = |ev| {
        Plan::parse(&json!({"version":2,"working":"extended-linear-srgb-premul-f32","output":"published",
       "nodes":[{"id":"raw","op":"source"},{"id":"sky","op":"mask"},{"id":"subject","op":"mask"},
                {"id":"skyLocal","op":"masked_exposure","image":"raw","mask":"sky","ev":ev},
                {"id":"published","op":"masked_exposure","image":"skyLocal","mask":"subject","ev":0.5}]}).to_string())
    };
    let initial = plan(-1.0)?;
    let edited = plan(1.0)?;
    let planes = [
        rawmaster_image::CoveragePlane {
            id: "subject",
            values: &subject,
        },
        rawmaster_image::CoveragePlane {
            id: "sky",
            values: &sky,
        },
    ];
    let frame = Frame::with_named_coverage(w, h, &pixels, &planes, false)?;
    let expected = render_cpu(&initial, &frame)?;
    let retried = render_cpu(&edited, &frame)?;
    assert!(maxerr(&expected, &retried) > 0.5);
    let program = std::sync::Arc::new(gpu.compile_metal_surfaces(&initial)?);
    // Keep the last published output in a separate real IOSurface. A timeout may
    // finish writing the unpublished surface but must leave this previous result intact.
    let protected = texture(&second, 2);
    let previous = unsafe {
        let mut prior = gpu.bind_named_metal_surfaces(
            &program,
            &edited,
            &input,
            &[("subject", &subject_texture), ("sky", &sky_texture)],
            &protected,
        )?;
        prior.submit_join(|| Ok(()))?;
        let mut bytes = vec![[0.0; 4]; n];
        assert!(rm_replay_read(second.0, bytes.as_mut_ptr().cast(), false));
        assert!(bytes.iter().flatten().all(|v: &f32| v.is_finite()));
        assert!(maxerr(&bytes, &retried) < 2e-6);
        bytes
    };
    let mut external = unsafe {
        gpu.bind_named_metal_surfaces(
            &program,
            &initial,
            &input,
            &[("subject", &subject_texture), ("sky", &sky_texture)],
            &output,
        )
    }?;
    assert_eq!(external.borrowed_backings(), 4);
    assert_eq!(external.coverage_surface_ids(), unsafe {
        [rm_replay_id(first.0, 1), rm_replay_id(second.0, 1)]
    });
    let protected_id = unsafe { rm_replay_id(second.0, 2) };
    assert_ne!(protected_id, external.surface_ids[2]);
    drop((
        program,
        input,
        sky_texture,
        subject_texture,
        output,
        protected,
    ));
    unsafe {
        rm_replay_drop_host_textures(first.0);
        rm_replay_drop_host_textures(second.0);
    }
    // Only the real wgpu timeout followed by native completion counts as a successful probe.
    // Read the unpublished scratch immediately after return, before any retry could repair it.
    external.probe_timeout_and_drain()?;
    let mut drained = vec![[0.0; 4]; n];
    assert!(unsafe { rm_replay_read(first.0, drained.as_mut_ptr().cast(), false) });
    assert!(drained.iter().flatten().all(|v: &f32| v.is_finite()));
    let mut still_published = vec![[0.0f32; 4]; n];
    assert!(unsafe { rm_replay_read(second.0, still_published.as_mut_ptr().cast(), false) });
    let published_digest = hash(bytemuck::cast_slice(&previous));
    assert_eq!(
        published_digest,
        hash(bytemuck::cast_slice(&still_published))
    );
    let observed = maxerr(&drained, &expected);
    assert!(observed < 2e-6);
    external.update(&edited)?;
    external.submit_join(|| Ok(()))?;
    let mut native_ci = vec![[0.0; 4]; n];
    assert!(unsafe { rm_replay_read(first.0, native_ci.as_mut_ptr().cast(), true) });
    assert!(native_ci.iter().flatten().all(|v: &f32| v.is_finite()));
    let observed_retry = maxerr(&native_ci, &retried);
    assert!(observed_retry < 2e-6);
    let receipt = json!({"test":"named_surface_timeout_drains_before_retry","nativeDeviceRegistryID":device.registry_id(),
        "shape":[w,h],"coverageSurfaceIDs":external.coverage_surface_ids(),"borrowedBackings":external.borrowed_backings(),
        "realWgpuTimeout":true,"timeoutPublished":false,"publishedSurfaceID":protected_id,"unpublishedSurfaceID":external.surface_ids[2],
        "previousPublishedSHA256BeforeAndAfter":published_digest,"timedOutScratchComparedBeforeRetry":true,"maxAbsVsCPUAfterDrain":observed,
        "maxAbsVsCPUAfterRetryThroughCoreImage":observed_retry,"drainedScratchSHA256":hash(bytemuck::cast_slice(&drained)),
        "retriedCoreImageSHA256":hash(bytemuck::cast_slice(&native_ci))});
    println!("{receipt}");
    if let Some(path) = env::var_os("RAWMASTER_NAMED_METAL_TIMEOUT_REPORT") {
        fs::write(
            path,
            format!("{}\n", serde_json::to_string_pretty(&receipt)?),
        )?;
    }
    Ok(())
}
