#!/usr/bin/env python3
"""Turn a fully verified offline runtime tree into an app data archive.

No runtime executable is run. The catalog must be pinned by the native client
and included with the archive in the signed application resources.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import stat
import zipfile


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def package(root, output, expected_manifest):
    root = root.resolve(strict=True)
    manifest_path = root / 'manifest.json'
    if digest(manifest_path) != expected_manifest:
        raise ValueError('Manifest does not match the selected fixed runtime')
    manifest = json.loads(manifest_path.read_text())
    entries = manifest['files']
    expected = {'manifest.json'}
    unpacked_bytes = 0
    for entry in entries:
        name = entry['path']
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or str(relative) != name or name in expected:
            raise ValueError('Unsafe or duplicate runtime member: ' + name)
        expected.add(name)
        path = root / name
        # No member may be reached through a symlink directory.
        if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
            raise ValueError('Symlink ancestor: ' + name)
        mode = path.lstat().st_mode
        if entry.get('type') == 'symlink':
            if not stat.S_ISLNK(mode) or os.readlink(path) != entry['target']:
                raise ValueError('Symlink identity mismatch: ' + name)
            if not path.resolve(strict=True).is_relative_to(root) or os.path.isabs(entry['target']):
                raise ValueError('Symlink escape: ' + name)
        else:
            if not stat.S_ISREG(mode) or path.stat().st_size != entry['size'] or digest(path) != entry['sha256']:
                raise ValueError('Runtime member integrity failure: ' + name)
            unpacked_bytes += entry['size']
    actual = {p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_symlink() or not p.is_dir()}
    if actual != expected:
        raise ValueError('Runtime inventory differs from manifest: ' + repr(sorted(actual ^ expected)))
    output.mkdir(parents=True, exist_ok=False)
    archive = output / (manifest['id'] + '.zip')
    with zipfile.ZipFile(archive, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as zipped:
        for name in sorted(expected):
            path = root / name
            info = zipfile.ZipInfo(name, date_time=(2026, 10, 30, 0, 0, 0))
            info.create_system = 3
            info.external_attr = path.lstat().st_mode << 16
            if path.is_symlink():
                info.compress_type = zipfile.ZIP_STORED
                zipped.writestr(info, os.readlink(path).encode('utf-8'))
            else:
                info.compress_type = zipfile.ZIP_DEFLATED
                with path.open('rb') as source, zipped.open(info, 'w', force_zip64=True) as sink:
                    while chunk := source.read(8 * 1024 * 1024):
                        sink.write(chunk)
    catalog = {'schemaVersion': 1, 'artifacts': [{
        'id': manifest['id'], 'platform': 'macos-arm64', 'minimumMacOS': '15.0',
        'archivePath': archive.name, 'archiveByteCount': archive.stat().st_size,
        'archiveSHA256': digest(archive), 'innerManifestSHA256': expected_manifest,
        'manifestEntryCount': len(entries), 'unpackedByteCount': unpacked_bytes,
    }]}
    catalog_path = output / 'catalog.json'
    catalog_path.write_text(json.dumps(catalog, indent=2) + '\n')
    print(json.dumps({'catalog': str(catalog_path), 'catalogSHA256': digest(catalog_path), **catalog}, indent=2), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime-pack', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--expected-manifest-sha256', required=True)
    args = parser.parse_args()
    package(args.runtime_pack, args.output, args.expected_manifest_sha256)
