use crate::{Error, Image, Point, face};
use libloading::{Library, Symbol};
use ort::environment::Environment;
use ort::session::{RunOptions, Session};
use ort::value::{Tensor, TensorElementType};
use sha2::{Digest, Sha256};
use std::ffi::CStr;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, TryLockError};

pub(crate) const EMBEDDING_LENGTH: usize = 256;
const ORT_FILE: &str = "libonnxruntime.1.27.0.dylib";
const MODEL_RELATIVE: &str = "Resources/CoreModels/v1/face/face-reidentification-retail-0095.onnx";
const MODEL_BYTES: u64 = 4_466_624;
const MODEL_SHA256: &str = "53349972f8899c86d7afe7f585f3be76f2303f458893679ae42baafc59be6373";
const INPUT_SHAPE: [i64; 4] = [1, 3, 128, 128];
const OUTPUT_SHAPE: [i64; 4] = [1, EMBEDDING_LENGTH as i64, 1, 1];
static ENGINE_OWNED: AtomicBool = AtomicBool::new(false);
static ENVIRONMENT: Mutex<Option<(PathBuf, Environment)>> = Mutex::new(None);

struct EngineLease;

impl EngineLease {
    fn acquire() -> Result<Self, Error> {
        ENGINE_OWNED
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| Error::Busy)?;
        Ok(Self)
    }
}

impl Drop for EngineLease {
    fn drop(&mut self) {
        ENGINE_OWNED.store(false, Ordering::Release);
    }
}

pub(crate) struct Engine {
    session: Mutex<Option<Session>>,
    environment: Environment,
    model: PathBuf,
    _lease: EngineLease,
}

impl Engine {
    pub(crate) fn open(contents: &Path) -> Result<Self, Error> {
        if !contents.is_absolute()
            || contents.file_name().and_then(|s| s.to_str()) != Some("Contents")
        {
            return Err(Error::InvalidArgument);
        }
        let lease = EngineLease::acquire()?;
        let contents = fs::canonicalize(contents).map_err(|_| Error::IncompatibleRuntime)?;
        let support = contents.join("Frameworks").join(ORT_FILE);
        require_regular_path(&support).map_err(|_| Error::IncompatibleRuntime)?;
        let mut current = ENVIRONMENT.lock().map_err(|_| Error::Internal)?;
        let environment = match &*current {
            Some((path, environment)) if *path == support => environment.clone(),
            Some(_) => return Err(Error::IncompatibleRuntime),
            None => {
                verify_runtime_version(&support)?;
                let environment = ort::init_from(&support)
                    .map_err(|_| Error::IncompatibleRuntime)?
                    .with_name("RAWMaster CoreAI")
                    .with_telemetry(false)
                    .build()
                    .map_err(|_| Error::IncompatibleRuntime)?;
                *current = Some((support, environment.clone()));
                environment
            }
        };
        Ok(Self {
            session: Mutex::new(None),
            environment,
            model: contents.join(MODEL_RELATIVE),
            _lease: lease,
        })
    }

    fn load_session(&self, cancel: &Cancellation) -> Result<Session, Error> {
        require_regular_path(&self.model).map_err(|_| Error::ModelRejected)?;
        let file = File::open(&self.model).map_err(|_| Error::ModelRejected)?;
        if file.metadata().map_err(|_| Error::ModelRejected)?.len() != MODEL_BYTES {
            return Err(Error::ModelRejected);
        }
        let mut bytes = Vec::with_capacity(MODEL_BYTES as usize);
        file.take(MODEL_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::ModelRejected)?;
        if bytes.len() as u64 != MODEL_BYTES
            || format!("{:x}", Sha256::digest(&bytes)) != MODEL_SHA256
        {
            return Err(Error::ModelRejected);
        }
        cancel.check()?;
        let builder = Session::builder(&self.environment).map_err(|_| Error::InferenceFailed)?;
        let mut builder = builder
            .with_intra_threads(1)
            .and_then(|builder| builder.with_inter_threads(1))
            .and_then(|builder| builder.with_parallel_execution(false))
            .map_err(|_| Error::InferenceFailed)?;
        let session = builder
            .commit_from_memory(&bytes)
            .map_err(|_| Error::ModelRejected)?;
        cancel.check()?;
        if !matches_model(&session) {
            return Err(Error::ModelRejected);
        }
        Ok(session)
    }

    fn session_slot(&self) -> Result<std::sync::MutexGuard<'_, Option<Session>>, Error> {
        self.session.try_lock().map_err(|error| match error {
            TryLockError::WouldBlock => Error::Busy,
            TryLockError::Poisoned(_) => Error::Internal,
        })
    }

    pub(crate) fn evict(&self) -> Result<(), Error> {
        let mut slot = self.session_slot()?;
        *slot = None;
        Ok(())
    }

    pub(crate) fn embed(
        &self,
        image: &Image<'_>,
        points: &[Point; 5],
        cancel: &Cancellation,
    ) -> Result<[f32; EMBEDDING_LENGTH], Error> {
        let mut slot = self.session_slot()?;
        cancel.begin()?;
        let input = face::aligned_input(image, points, || cancel.check())?;
        if slot.is_none() {
            *slot = Some(self.load_session(cancel)?);
        }
        let session = slot.as_mut().ok_or(Error::Internal)?;
        let tensor =
            Tensor::from_array((INPUT_SHAPE, input)).map_err(|_| Error::InferenceFailed)?;
        let run = cancel.attach()?;
        let outputs = session.run_with_options(ort::inputs![tensor], &run.options);
        cancel.check()?;
        let outputs = outputs.map_err(|_| Error::InferenceFailed)?;
        let (shape, raw) = outputs[0]
            .try_extract_tensor::<f32>()
            .map_err(|_| Error::InferenceFailed)?;
        if &**shape != OUTPUT_SHAPE.as_slice() || raw.len() != EMBEDDING_LENGTH {
            return Err(Error::ModelRejected);
        }
        let length = raw
            .iter()
            .map(|value| f64::from(*value).powi(2))
            .sum::<f64>()
            .sqrt();
        if !length.is_finite() || length < 1e-8 {
            return Err(Error::InferenceFailed);
        }
        let mut vector = [0.; EMBEDDING_LENGTH];
        for (destination, value) in vector.iter_mut().zip(raw) {
            *destination = (f64::from(*value) / length) as f32;
        }
        Ok(vector)
    }
}

fn require_regular_path(path: &Path) -> std::io::Result<()> {
    if fs::canonicalize(path)? != path || !fs::symlink_metadata(path)?.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "unexpected file location",
        ));
    }
    Ok(())
}

fn verify_runtime_version(path: &Path) -> Result<(), Error> {
    // The framework is sealed by the host app. Read the actual ORT handshake before
    // allowing ort's process-wide loader to install it as the only environment.
    unsafe {
        let library = Library::new(path).map_err(|_| Error::IncompatibleRuntime)?;
        let get_base: Symbol<unsafe extern "C" fn() -> *const ort::sys::OrtApiBase> = library
            .get(b"OrtGetApiBase")
            .map_err(|_| Error::IncompatibleRuntime)?;
        let base = get_base().as_ref().ok_or(Error::IncompatibleRuntime)?;
        let version = (base.GetVersionString)();
        if version.is_null()
            || CStr::from_ptr(version).to_bytes() != b"1.27.0"
            || (base.GetApi)(27).is_null()
        {
            return Err(Error::IncompatibleRuntime);
        }
        Ok(())
    }
}

fn matches_model(session: &Session) -> bool {
    let [input] = session.inputs() else {
        return false;
    };
    let [output] = session.outputs() else {
        return false;
    };
    let matches_tensor = |outlet: &ort::value::Outlet, name, shape: &[i64]| {
        outlet.name() == name
            && outlet.dtype().tensor_type() == Some(TensorElementType::Float32)
            && outlet
                .dtype()
                .tensor_shape()
                .is_some_and(|value| &**value == shape)
    };
    matches_tensor(input, "0", &INPUT_SHAPE)
        && matches_tensor(output, "658/sink_port_0", &OUTPUT_SHAPE)
}

#[derive(Default)]
pub(crate) struct Cancellation {
    cancelled: AtomicBool,
    used: AtomicBool,
    current: Mutex<Option<Arc<RunOptions>>>,
}

impl Cancellation {
    pub(crate) fn cancel(&self) -> Result<(), Error> {
        let options = self.current.lock().map_err(|_| Error::Internal)?;
        self.cancelled.store(true, Ordering::Release);
        if let Some(options) = &*options {
            options.terminate().map_err(|_| Error::InferenceFailed)?;
        }
        Ok(())
    }

    fn begin(&self) -> Result<(), Error> {
        self.check()?;
        if self.used.swap(true, Ordering::AcqRel) {
            return Err(Error::InvalidArgument);
        }
        Ok(())
    }

    fn check(&self) -> Result<(), Error> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(Error::Cancelled);
        }
        Ok(())
    }

    fn attach(&self) -> Result<AttachedRun<'_>, Error> {
        let options = Arc::new(RunOptions::new().map_err(|_| Error::InferenceFailed)?);
        let mut target = self.current.lock().map_err(|_| Error::Internal)?;
        self.check()?;
        *target = Some(Arc::clone(&options));
        Ok(AttachedRun {
            owner: self,
            options,
        })
    }

    pub(crate) fn publish(&self, body: impl FnOnce()) -> Result<(), Error> {
        let _slot = self.current.lock().map_err(|_| Error::Internal)?;
        self.check()?;
        body();
        Ok(())
    }
}

struct AttachedRun<'a> {
    owner: &'a Cancellation,
    options: Arc<RunOptions>,
}

impl Drop for AttachedRun<'_> {
    fn drop(&mut self) {
        // This guard is released after run_with_options has returned and freed its output values.
        self.owner
            .current
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PixelFormat;
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    #[ignore = "requires the qualified 1.27.0 runtime and Intel model in a local app bundle"]
    fn cancels_an_attached_native_run_and_reuses_the_joined_session() {
        let contents = std::env::var_os("RAWMASTER_COREAI_TEST_CONTENTS")
            .expect("set the qualified Contents path");
        let engine =
            Engine::open(Path::new(&contents)).unwrap_or_else(|error| panic!("open: {error:?}"));
        let bytes: Vec<u8> = (0..128 * 128 * 4)
            .map(|index| (index % 239) as u8)
            .collect();
        let image = Image {
            data: &bytes,
            width: 128,
            height: 128,
            stride: 512,
            format: PixelFormat::Rgba8,
        };
        let landmarks = [
            (0.32, 0.44),
            (0.65, 0.46),
            (0.5, 0.64),
            (0.34, 0.8),
            (0.67, 0.81),
        ]
        .map(|(x, y)| Point { x, y });
        let standard = engine
            .embed(&image, &landmarks, &Cancellation::default())
            .expect("warm session");
        let token = Cancellation::default();
        thread::scope(|scope| {
            let worker = scope.spawn(|| engine.embed(&image, &landmarks, &token));
            let timeout = Instant::now() + Duration::from_secs(2);
            loop {
                if token.current.lock().unwrap().is_some() {
                    break;
                }
                assert!(
                    Instant::now() < timeout && !worker.is_finished(),
                    "native run was never attached"
                );
                thread::yield_now();
            }
            assert_eq!(engine.evict(), Err(Error::Busy));
            token.cancel().unwrap();
            assert_eq!(worker.join().unwrap(), Err(Error::Cancelled));
        });
        assert!(token.current.lock().unwrap().is_none());
        assert_eq!(
            standard,
            engine
                .embed(&image, &landmarks, &Cancellation::default())
                .unwrap()
        );
        engine.evict().unwrap();
    }
}
