"""Fixed-manifest acquisition or strictly read-only verification; no credentials or solver."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import threading
import time
import urllib.parse
import urllib.request
import uuid


def digest(path):
    # Inspect the actual opened regular file, not a path that may be rebound during hashing.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('Model must be a regular file')
        result = hashlib.file_digest(source, 'sha256').hexdigest()
        after = os.fstat(source.fileno())
        fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        if any(getattr(before, k) != getattr(after, k) for k in fields):
            raise ValueError('Model changed during verification')
    current = path.stat()
    if any(getattr(after, k) != getattr(current, k) for k in fields):
        raise ValueError('Model path changed during verification')
    return result


def emit(phase, completed, total, message, reused=None):
    value = {'phase': phase, 'completedBytes': completed, 'totalBytes': total, 'message': message}
    if reused is not None:
        value['reusedBytes'] = reused
    print(json.dumps(value), flush=True)


def permitted_url(url, allow_test_http=False):
    value = urllib.parse.urlsplit(url)
    if value.username or value.password or value.fragment:
        return False
    if allow_test_http and value.scheme == 'http' and value.hostname == '127.0.0.1':
        return True
    host = value.hostname or ''
    return value.scheme == 'https' and (host == 'huggingface.co' or host.endswith('.huggingface.co') or host.endswith('.hf.co'))


class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, allow_test_http):
        self.allow_test_http = allow_test_http
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if not permitted_url(newurl, self.allow_test_http):
            raise ValueError('Model redirect outside fixed provider HTTPS destinations')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def write_receipt(path, value):
    if not path.parent.is_dir():
        raise ValueError('Receipt parent must be an existing owned directory')
    temporary = path.with_name('.'+path.name+'.'+uuid.uuid4().hex)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as sink:
        json.dump(value, sink, indent=2)
        sink.flush()
        os.fsync(sink.fileno())
    os.replace(temporary, path)
    parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(parent)
    finally:
        os.close(parent)


def partial_info(path):
    if not path.exists() and not path.is_symlink():
        return None
    value = path.lstat()
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise ValueError('Partial download must be an independent regular file')
    return value


def prepare(manifest_path, root, texture_fix, read_only=False, receipt_path=None, allow_test_http=False):
    manifest = json.loads(manifest_path.read_text())
    items = manifest['files'] + ([manifest['textureFix']] if texture_fix else [])
    if read_only:
        if not root.is_dir() or receipt_path is None:
            raise ValueError('Read-only verification requires existing models and an owned receipt destination')
    else:
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root = root.resolve()
    if read_only and receipt_path.resolve().is_relative_to(root):
        raise ValueError('Read-only model root cannot contain receipt writes')
    total = sum(item['size'] for item in items)
    completed = reused = needed = 0
    missing = []
    for item in items:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Model path escapes selected directory')
        target = (root/relative).resolve()
        if not target.is_relative_to(root):
            raise ValueError('Model path escapes selected directory')
        if target.exists():
            emit('verifyingModels', completed, total, item['path'], reused)
            if not target.is_file() or target.stat().st_size != item['size'] or digest(target) != item['sha256']:
                raise ValueError('Existing model differs from pinned identity: '+item['path'])
            completed += item['size']
            reused += item['size']
        else:
            missing.append(item)
    if read_only and missing:
        raise ValueError('Required model missing; borrowed directory was not modified')
    lock = None
    if not read_only:
        lock = os.open(root/'.rawmaster-prepare.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            value = os.fstat(lock)
            if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
                raise ValueError('Model preparation lock is not independently owned')
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(lock)
            raise
    try:
        # No creation, chmod, lock file, receipt or staging writes in a borrowed root.
        if not read_only:
            staging = root/'.rawmaster-downloads'
            staging.mkdir(exist_ok=True, mode=0o700)
            if staging.is_symlink() or not staging.resolve().is_relative_to(root):
                raise ValueError('Download staging escapes selected directory')
            for item in missing:
                part = staging/(item['sha256']+'.part')
                prior = partial_info(part)
                needed += max(0, item['size'] - (prior.st_size if prior else 0))
            if shutil.disk_usage(root).free < needed + 512*1024**2:
                raise OSError('Insufficient space for missing model bytes and safety margin')
            opener = urllib.request.build_opener(RestrictedRedirect(allow_test_http))
            for item in missing:
                target = (root/item['path']).resolve()
                if not target.is_relative_to(root):
                    raise ValueError('Model path escapes selected directory')
                target.parent.mkdir(parents=True, exist_ok=True)
                part = staging/(item['sha256']+'.part')
                prior = partial_info(part)
                offset = prior.st_size if prior else 0
                if offset > item['size']:
                    raise ValueError('Partial download larger than pinned model')
                if offset < item['size']:
                    if not permitted_url(item['url'], allow_test_http):
                        raise ValueError('Model URL outside fixed provider HTTPS destinations')
                    request = urllib.request.Request(item['url'], headers={'Range': f'bytes={offset}-'} if offset else {})
                    with opener.open(request, timeout=60) as response:
                        if offset and response.status == 206:
                            if not response.headers.get('Content-Range', '').startswith(f'bytes {offset}-'):
                                raise ValueError('Invalid server range response')
                        elif response.status == 200:
                            offset = 0
                        else:
                            raise ValueError('Model download HTTP status '+str(response.status))
                        flags = os.O_RDWR | os.O_NOFOLLOW | (0 if prior else os.O_CREAT | os.O_EXCL)
                        descriptor = os.open(part, flags, 0o600)
                        with os.fdopen(descriptor, 'r+b') as sink:
                            current = os.fstat(sink.fileno())
                            if not stat.S_ISREG(current.st_mode) or current.st_nlink != 1:
                                raise ValueError('Partial descriptor not independently owned')
                            if prior and any(getattr(prior, k) != getattr(current, k) for k in ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')):
                                raise ValueError('Partial path changed before writing')
                            if offset:
                                sink.seek(offset)
                            else:
                                sink.truncate(0)
                            count = offset
                            while True:
                                chunk = response.read(4*1024*1024)
                                if not chunk:
                                    break
                                count += len(chunk)
                                if count > item['size']:
                                    raise ValueError('Model response exceeds pinned size')
                                sink.write(chunk)
                                emit('downloadingModels', completed+count, total, item['path'], reused)
                            sink.flush()
                            os.fsync(sink.fileno())
                emit('verifyingModels', completed, total, item['path'], reused)
                if part.stat().st_size != item['size'] or digest(part) != item['sha256']:
                    part.rename(staging/('rejected-'+uuid.uuid4().hex))
                    raise ValueError('Downloaded model hash/size mismatch')
                os.link(part, target) # Exclusive publication, never clobber a competing file.
                part.unlink()
                parent = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
                try:
                    os.fsync(parent)
                finally:
                    os.close(parent)
                completed += item['size']
                emit('downloaded', completed, total, item['path'], reused)
        receipt = {'model': manifest['model'], 'revision': manifest['revision'], 'licenseScope': 'research-evaluation',
                   'identitySHA256': digest(manifest_path.resolve()), 'textureFix': texture_fix, 'verified': True,
                   'readOnly': read_only, 'modelRoot': str(root), 'reusedBytes': reused}
        write_receipt(receipt_path or root/'.rawmaster-model-receipt.json', receipt)
        emit('modelsVerified', total, total, 'Pinned model bytes verified; no inference performed', reused)
    finally:
        if lock is not None:
            os.close(lock)


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError('Download cancelled; verified files and partial bytes retained')))
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--model-root', type=Path, required=True)
    parser.add_argument('--texture-fix', action='store_true')
    parser.add_argument('--read-only', action='store_true')
    parser.add_argument('--receipt', type=Path)
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
    prepare(args.manifest, args.model_root, args.texture_fix, args.read_only, args.receipt)
