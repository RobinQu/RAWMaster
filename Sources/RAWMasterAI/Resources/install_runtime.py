"""Install one manifest-pinned offline evaluation runtime; never changes an active version on failure."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import time
import urllib.request
import threading

CURRENT = None
INSTALL_ENV = None


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(8*1024*1024), b''):
            result.update(chunk)
    return result.hexdigest()


def run(command, log, timeout=300):
    global CURRENT
    CURRENT = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True, env=INSTALL_ENV)
    try:
        code = CURRENT.wait(timeout=timeout)
        if code:
            raise RuntimeError('Offline component command failed with status '+str(code))
    finally:
        if CURRENT.poll() is None:
            os.killpg(CURRENT.pid, signal.SIGTERM)
            try:
                CURRENT.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(CURRENT.pid, signal.SIGKILL)
                CURRENT.wait()
        CURRENT = None


def interrupted(signum, frame):
    if CURRENT and CURRENT.poll() is None:
        os.killpg(CURRENT.pid, signal.SIGTERM)
        try:
            CURRENT.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(CURRENT.pid, signal.SIGKILL)
            CURRENT.wait()
    raise RuntimeError('Installation cancelled; previous active runtime retained')


def durable_json(path, value):
    temporary = path.with_name(path.name+'.tmp-'+os.urandom(8).hex())
    with temporary.open('x') as sink:
        os.chmod(temporary, 0o600)
        json.dump(value, sink, indent=2)
        sink.flush()
        os.fsync(sink.fileno())
    os.replace(temporary, path)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)


def install(package, destination, defer_activate=False, candidate_name=None, operation_id=None):
    global INSTALL_ENV
    package = package.resolve()
    destination = destination.resolve()
    manifest = json.loads((package/'manifest.json').read_text())
    version_id = manifest['id']
    if not version_id or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in version_id):
        raise ValueError('Unsafe runtime version identity')
    total = 0
    for item in manifest['files']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Manifest path traversal')
        path = package/relative
        if not path.resolve().is_relative_to(package):
            raise ValueError('Manifest symlink escapes package')
        if item.get('type') == 'symlink':
            if not path.is_symlink() or os.readlink(path) != item['target']:
                raise ValueError('Symlink identity mismatch')
        else:
            if path.is_symlink() or not path.is_file() or path.stat().st_size != item['size'] or sha(path) != item['sha256']:
                raise ValueError('Package integrity failure: '+item['path'])
            total += item['size']
    # All files, including nested code folders named input/output, are in the manifest.
    actual = {str(p.relative_to(package)) for p in package.rglob('*') if p.is_file() or p.is_symlink()}
    expected = {i['path'] for i in manifest['files']} | {'manifest.json'}
    if actual != expected:
        raise ValueError('Unmanifested or missing package files')
    destination.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(destination).free < max(total*3, 3*1024**3):
        raise OSError('Insufficient space for runtime and offline environments')
    if defer_activate:
        if not operation_id or len(operation_id) != 36 or any(c not in '0123456789abcdefABCDEF-' for c in operation_id):
            raise ValueError('Deferred installation requires an operation identity')
        if candidate_name != version_id+'-'+operation_id:
            raise ValueError('Candidate must belong to this operation')
    elif candidate_name or operation_id:
        raise ValueError('Candidate arguments require deferred activation')
    versions = destination/'versions'
    if versions.is_symlink() or not versions.resolve().is_relative_to(destination):
        raise ValueError('Version directory escapes owned runtime root')
    version = versions/(candidate_name if defer_activate else version_id)
    if version.exists():
        if defer_activate:
            raise FileExistsError('Existing candidate is never overwritten')
        active = destination/'active'
        failed = version/'failure.json'
        if active.resolve() == version.resolve() or version.is_symlink() or not failed.is_file() or (version/'receipt.json').exists():
            raise FileExistsError('Existing active, successful or unrecognized version is preserved')
        failure = json.loads(failed.read_text())
        if failure.get('activeUnchanged') is not True:
            raise ValueError('Unrecognized failed-version receipt')
        quarantine = destination/'failed-versions'
        quarantine.mkdir(exist_ok=True)
        version.rename(quarantine/(version_id+'-'+os.urandom(8).hex()))
    version.mkdir(parents=True, exist_ok=False)
    if defer_activate:
        durable_json(version/'preparation-owner.json', {'operationID': operation_id, 'artifactID': version_id})
    INSTALL_ENV = os.environ | {'UV_NO_CACHE': '1', 'UV_CACHE_DIR': str(version/'empty-install-cache'), 'UV_PYTHON_DOWNLOADS': 'never', 'PYTHONDONTWRITEBYTECODE': '1'}
    try:
        for name in ('python', 'ComfyUI', 'wheelhouse', 'mlx-wheelhouse', 'resources'):
            shutil.copytree(package/name, version/name, symlinks=True)
        if (package/'licenses').is_dir():
            shutil.copytree(package/'licenses', version/'licenses', symlinks=True)
        if (package/'README.txt').is_file():
            shutil.copy2(package/'README.txt', version/'README.txt')
        shutil.copy2(package/'manifest.json', version/'installed-package-manifest.json')
        for name in ('uv', 'requirements.lock.txt', 'requirements-mlx.lock.txt'):
            shutil.copy2(package/name, version/name)
        with (version/'install.log').open('w') as log:
            for environment, lock, wheelhouse in (('.venv', 'requirements.lock.txt', 'wheelhouse'), ('.mlx', 'requirements-mlx.lock.txt', 'mlx-wheelhouse')):
                python = version/environment/'bin/python'
                run([str(version/'uv'), 'venv', '--python', str(version/'python/bin/python3.12'), '--no-python-downloads', str(version/environment)], log)
                run([str(version/'uv'), 'pip', 'sync', '--python', str(python), '--offline', '--no-index', '--find-links', str(version/wheelhouse), '--require-hashes', '--only-binary', ':all:', str(version/lock)], log, 600)
                run([str(version/'uv'), 'pip', 'check', '--python', str(python), '--offline'], log)
            run([str(version/'.mlx/bin/python'), '-c', "import mlx.core as mx; from mflux.models.qwen21.variants.edit.qwen_image_21_edit import QwenImage21Edit; assert mx.metal.is_available(); x=mx.ones((8,8)); y=x@x; mx.eval(y); assert y[0,0].item()==8"], log, 120)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        root = version/'health-state'
        root.mkdir()
        for name in ('custom_nodes', 'input', 'output', 'user', 'temp'):
            (root/name).mkdir()
        (root/'paths.yaml').write_text('rawmaster:\n  base_path: '+json.dumps(str(version/'resources'))+'\n  custom_nodes: custom_nodes\n')
        token = os.urandom(32).hex()
        env = os.environ | {'RAWMASTER_RUN_ROOT': str(root), 'RAWMASTER_MODEL_ROOT': str(root/'no-models'),
            'RAWMASTER_OWNERSHIP_TOKEN': token, 'RAWMASTER_OWNER_PID': str(os.getpid()), 'RAWMASTER_WORKER_SCRIPT': str(version/'resources/mlx_worker.py'),
            'RAWMASTER_MLX_PYTHON': str(version/'.mlx/bin/python'), 'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'PYTHONDONTWRITEBYTECODE': '1'}
        with (version/'health.log').open('w') as log:
            server = subprocess.Popen([str(version/'.venv/bin/python'), str(version/'ComfyUI/main.py'), '--listen', '127.0.0.1', '--port', str(port),
                '--base-directory', str(root), '--extra-model-paths-config', str(root/'paths.yaml'), '--disable-all-custom-nodes', '--whitelist-custom-nodes', 'rawmaster_mlx',
                '--offline', '--cpu', '--cache-none', '--disable-auto-launch'], cwd=version/'ComfyUI', env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(120):
                    if server.poll() is not None:
                        raise RuntimeError('Owned Comfy health process exited')
                    try:
                        request = urllib.request.Request(f'http://127.0.0.1:{port}/rawmaster/health', headers={'X-RAWMaster-Token': token})
                        with urllib.request.urlopen(request, timeout=2) as response:
                            health = json.load(response)
                        assert health['pid'] == server.pid and health['protocol'] == 'rawmaster-comfy-mlx-v1'
                        request = urllib.request.Request(f'http://127.0.0.1:{port}/object_info/RAWMasterMLXEdit', headers={'X-RAWMaster-Token': token})
                        with urllib.request.urlopen(request, timeout=2) as response:
                            assert 'RAWMasterMLXEdit' in json.load(response)
                        break
                    except (OSError, AssertionError, ValueError):
                        time.sleep(.5)
                else:
                    raise TimeoutError('Owned Comfy node health failed')
            finally:
                server.terminate()
                try:
                    server.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
        durable_json(version/'receipt.json', {'id': version_id, 'offlineInstall': True, 'nodeHealth': True, 'mlxOperatorHealth': True,
            'productionSigned': False, 'modelsIncluded': False, 'realModelAcceptance': False,
            'deferredActivation': defer_activate, 'operationID': operation_id})
        if defer_activate:
            return # Swift alone commits after required model verification and isolated candidate health join.
        active = destination/'active'
        if active.exists() and not active.is_symlink():
            raise ValueError('Active pointer must be an owned symlink')
        pointer = destination/('active-'+os.urandom(8).hex())
        pointer.symlink_to(Path('versions')/version_id)
        os.replace(pointer, active)
    except BaseException as error:
        durable_json(version/'failure.json', {'error': str(error), 'activeUnchanged': True, 'operationID': operation_id})
        raise


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    parser.add_argument('--defer-activate', action='store_true')
    parser.add_argument('--candidate-name')
    parser.add_argument('--operation-id')
    parser.add_argument('--owner-pid', type=int)
    args = parser.parse_args()
    if args.owner_pid:
        if os.getppid() != args.owner_pid:
            raise RuntimeError('Preparation owner already exited')
        def watch_owner():
            while True:
                if os.getppid() != args.owner_pid:
                    os.kill(os.getpid(), signal.SIGTERM)
                    return
                time.sleep(.25)
        threading.Thread(target=watch_owner, daemon=True).start()
    install(args.package, args.destination, args.defer_activate, args.candidate_name, args.operation_id)
