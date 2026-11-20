#!/usr/bin/env python3
"""Build unsigned, pinned arm64 evaluation runtime. Run under the intended Python 3.12 arm64.
No model weights, cached virtual environments or photographs are packaged.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import urllib.request

from packaging.tags import sys_tags
from packaging.utils import canonicalize_name, parse_wheel_filename


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(8*1024*1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def locked_requirements(path):
    current = None
    requirements = []
    for line in path.read_text().splitlines():
        match = re.match(r'^([A-Za-z0-9_.-]+)==([^ ;\\]+)', line)
        if match:
            current = {'name': match.group(1), 'version': match.group(2), 'hashes': set()}
            requirements.append(current)
        if current:
            current['hashes'].update(re.findall(r'--hash=sha256:([0-9a-f]{64})', line))
    if not requirements or any(not requirement['hashes'] for requirement in requirements):
        raise ValueError('Every requirement must be exact-version and SHA256 locked')
    return requirements


def fetch_wheels(lock, reuse, destination):
    compatible = set(sys_tags())
    destination.mkdir()
    existing = list(reuse.glob('*.whl'))
    for requirement in locked_requirements(lock):
        selected = None
        for candidate in existing:
            name, version, _, tags = parse_wheel_filename(candidate.name)
            if canonicalize_name(requirement['name']) == name and str(version) == requirement['version'] and tags & compatible and sha(candidate) in requirement['hashes']:
                selected = candidate
                break
        if selected:
            shutil.copy2(selected, destination/selected.name)
            continue
        url = f"https://pypi.org/pypi/{requirement['name']}/{requirement['version']}/json"
        with urllib.request.urlopen(url, timeout=90) as response:
            release = json.load(response)
        choices = []
        for file in release['urls']:
            if not file['filename'].endswith('.whl') or file['digests']['sha256'] not in requirement['hashes']:
                continue
            _, _, _, tags = parse_wheel_filename(file['filename'])
            if tags & compatible:
                choices.append(file)
        if not choices:
            raise ValueError('No hash-locked binary wheel for '+requirement['name'])
        selected = sorted(choices, key=lambda f: f['filename'])[0]
        print('Fetching exact wheel '+selected['filename'], flush=True)
        target = destination/selected['filename']
        with urllib.request.urlopen(selected['url'], timeout=180) as source, target.open('xb') as sink:
            shutil.copyfileobj(source, sink, 8*1024*1024)
        if sha(target) not in requirement['hashes']:
            raise ValueError('Downloaded wheel hash mismatch')


def build(base, mlx_lock, output, identifier):
    if sys.version_info[:2] != (3, 12) or os.uname().machine != 'arm64':
        raise ValueError('Use arm64 CPython3.12 for exact platform wheel selection')
    base = base.resolve(); output = output.resolve()
    original = json.loads((base/'manifest.json').read_text())
    for item in original['files']:
        path = (base/item['path']).resolve()
        if not path.is_relative_to(base) or not path.is_file() or sha(path) != item['sha256']:
            raise ValueError('Pinned base package integrity failure: '+item['path'])
    output.mkdir(parents=True, exist_ok=False)
    for name in ('python', 'ComfyUI', 'wheelhouse'):
        shutil.copytree(base/name, output/name, symlinks=True)
    for name in ('uv', 'requirements.lock.txt'):
        shutil.copy2(base/name, output/name)
    if (base/'licenses').is_dir():
        shutil.copytree(base/'licenses', output/'licenses')
    resources = Path(__file__).resolve().parents[1]/'Sources/RAWMasterAI/Resources'
    shutil.copytree(resources, output/'resources', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    shutil.copy2(mlx_lock, output/'requirements-mlx.lock.txt')
    fetch_wheels(mlx_lock, base/'wheelhouse', output/'mlx-wheelhouse')
    (output/'README.txt').write_text('UNSIGNED LOCAL RESEARCH/EVALUATION PACK. No model weights or photographs.\n'
        'Contains pinned ComfyUI source (GPL-3.0), CPython, uv and binary dependency wheels with their license notices.\n'
        'Install with RAWMaster native settings. Model license, commercial distribution review, Developer ID signing/notarization and clean-Mac acceptance remain external gates.\n'
        'Qwen2.1 research-only weights are user-configured separately; package does not confer commercial use rights.\n')
    files = []
    for path in sorted(output.rglob('*')):
        if path.is_symlink():
            if not path.resolve().is_relative_to(output):
                raise ValueError('Package symlink escape: '+str(path))
            files.append({'path': str(path.relative_to(output)), 'type': 'symlink', 'target': os.readlink(path)})
        elif path.is_file():
            files.append({'path': str(path.relative_to(output)), 'size': path.stat().st_size, 'sha256': sha(path)})
    (output/'manifest.json').write_text(json.dumps({'id': identifier, 'productionSigned': False, 'modelsIncluded': False,
        'baseIdentity': original['id'], 'protocol': 'rawmaster-comfy-mlx-v1', 'files': files}, indent=2))
    print(str(output), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base-pack', type=Path, required=True)
    parser.add_argument('--mlx-lock', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--id', default='rawmaster-comfymlx-v4-arm64-py312')
    args = parser.parse_args()
    build(args.base_pack, args.mlx_lock, args.output, args.id)
