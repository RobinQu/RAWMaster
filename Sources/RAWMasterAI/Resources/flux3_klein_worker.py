"""Run one offline FLUX.3 Klein edit. The supervisor owns and joins the MLX/noise process group."""
import fcntl
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time

RUNTIME_DIGEST = "62efa10d8371d5a6de5ff1a253cfb3e74aaaa3322db5e70a3d5337323f0cef49"
MODEL_MANIFEST = "f577d9a994c8e2ceded109959b0ab24982574f0231274459d566a2f5b072e72d"
UPSTREAM = "1755314e2216b2a2c5cc0dd899d4e49ee3404d2c"
Q8 = "d9790a1ceaba200e8b773fb236f7c9fa754283a7"
RUNTIME = "a8a400745949770d4de3b18c31684169da4b0af5"
METADATA = ("model_index.json", "presets.json", "assets/manifest.json", "assets/source-manifest.json",
            "q8/manifest.json", "vae-fp32/manifest.json")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(runtime, model):
    package = runtime / "flux_klein_mlx"
    identity = hashlib.sha256()
    for source in sorted(package.glob("*.py")):
        identity.update(source.name.encode() + b"\x00" + hashlib.sha256(source.read_bytes()).digest())
    manifest = model / "release-manifest.json"
    if identity.hexdigest() != RUNTIME_DIGEST or digest(manifest) != MODEL_MANIFEST:
        raise ValueError("unrecognized runtime or weights")
    release = json.loads(manifest.read_bytes())["files"]
    for name in METADATA:
        if digest(model / name) != release[name]["sha256"]:
            raise ValueError("unrecognized model metadata")
    # The verified runtime checks every selected tensor and tokenizer against these signed-off manifests.
    # Its transformer loader globs shards; reject any extra shards outside the frozen release as well.
    for directory in ("q8/transformer", "q8/image_conditioning", "q8/text_encoder", "vae-fp32"):
        expected = {n for n in release if n.startswith(directory + "/") and n.endswith(".safetensors")}
        if {str(p.relative_to(model)) for p in (model / directory).glob("*.safetensors")} != expected:
            raise ValueError("unexpected tensor set")
    if platform.system() != "Darwin" or platform.machine() != "arm64" or importlib.metadata.version("mlx") != "0.32.4":
        raise ValueError("Apple Silicon and MLX 0.32.4 required")


def generate():
    job = Path.cwd()
    config = json.loads((job / "request.json").read_text())
    runtime, model = map(Path, (config["runtimeDirectory"], config["weightsDirectory"]))
    verify(runtime, model)
    sys.pycache_prefix = str(job / "pycache")
    os.environ["PYTHONPYCACHEPREFIX"] = sys.pycache_prefix
    os.environ["FLUX_MLX_MODEL_ROOT"] = str(model)
    os.environ["MLX_ENABLE_TF32"] = "0"
    # The upstream CPU RNG helper re-execs Python. Explicitly use the same pinned source for both processes.
    os.environ["PYTHONPATH"] = str(runtime)
    sys.path.insert(0, str(runtime))
    from flux_klein_mlx.pipeline import generate as infer
    from PIL import Image
    request = dict(prompt=config["prompt"], width=config["width"], height=config["height"], seed=config["seed"],
                   steps=16, guidance=None, alpha=6.93, references=[str(job / "input.png")],
                   profile="q8-16", transformer="q8", text_encoder="q8")
    start = time.monotonic()
    output = job / "candidate.png"
    metrics = infer(request, output, vae_dtype="float16", cache_mb=512, kernel_mode="fast",
                    dit_dtype="float32", precision="scaled")
    with Image.open(output) as photo:
        photo.load()
        if photo.format != "PNG" or photo.mode != "RGB" or photo.size != (request["width"], request["height"]):
            raise ValueError("invalid output")
    receipt = dict(runtimeRevision=RUNTIME, weightsRevision=Q8, modelRevision=UPSTREAM, mlxVersion=metrics["mlx_version"],
                   preset="q8-16", steps=16, seed=request["seed"], elapsedSeconds=time.monotonic()-start,
                   pipelineSeconds=metrics["wall_seconds"], peakMLXBytes=metrics["peak_mlx_active_bytes"], outputSHA256=digest(output))
    (job / "worker-receipt.json").write_text(json.dumps(receipt))


def terminate_group(child):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()
    # A terminated noise worker may have outlived its parent. Wait until launchd has reaped that group.
    while True:
        try:
            os.killpg(child.pid, 0)
        except ProcessLookupError:
            return
        time.sleep(.05)


def supervise(expected_parent):
    cancelled = False

    def stop(signum, _frame):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    worker_lock = open("worker.lock", "ab")
    fcntl.flock(worker_lock.fileno(), fcntl.LOCK_EX)
    if cancelled or Path.cwd().with_suffix(".cancel").exists() or os.getppid() != expected_parent:
        return 130
    lane = open(Path(os.environ["FLUX_MLX_CACHE_DIR"]) / "local-metal.lock", "ab")
    try:
        fcntl.flock(lane.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return 75
    child = subprocess.Popen([sys.executable, "-I", "-B", str(Path(__file__).resolve()), "--generate"],
                             start_new_session=True, close_fds=True)
    try:
        while True:
            if cancelled or Path.cwd().with_suffix('.cancel').exists() or os.getppid() != expected_parent:
                return 130
            status = child.poll()
            if status is not None:
                return status if status >= 0 else 128 - status
            time.sleep(.1)
    finally:
        terminate_group(child)


if __name__ == "__main__":
    try:
        if sys.argv[1:2] == ["--generate"]:
            generate()
        else:
            sys.exit(supervise(int(sys.argv[1])))
    except Exception:
        # The caller reports the stage and fixed revisions. Never echo source paths, prompts or Python exceptions.
        sys.exit(65)
