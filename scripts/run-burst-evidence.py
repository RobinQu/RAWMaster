#!/usr/bin/env python3
"""Verify frozen diagnostics source AND executable before starting a read-only experiment.

A failed integrity check always exits before launching the executable. This guard
checks execution provenance, not the scientific validity or product quality of a run.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import shutil
import tempfile
import sys
from datetime import datetime, timezone


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent)
    parser.add_argument('--freeze', type=pathlib.Path, required=True)
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--receipt', type=pathlib.Path, required=True)
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    receipt = {'schemaVersion': 1, 'checkedAt': datetime.now(timezone.utc).isoformat(),
               'status': 'refused-before-launch', 'launched': False, 'failures': [],
               'boundary': 'Execution provenance only; neither analysis validation nor production acceptance'}
    try:
        frozen = json.loads(args.freeze.read_text())
        hashes = frozen['sourceSHA256']
        if not hashes:
            raise ValueError('Freeze contains no source hashes')
        aggregate = hashlib.sha256()
        checks = {}
        for name, expected in sorted(hashes.items()):
            path = args.repo / name
            actual = digest(path)
            checks[name] = actual == expected
            if actual != expected:
                receipt['failures'].append('Source checksum mismatch: ' + name)
            aggregate.update(name.encode() + b'\0')
            with path.open('rb') as source:
                for block in iter(lambda: source.read(1024 * 1024), b''):
                    aggregate.update(block)
        receipt['sourceHashesMatchFreeze'] = checks
        if aggregate.hexdigest() != frozen['aggregateSourceSHA256']:
            receipt['failures'].append('Aggregate source checksum mismatch')
        # Execute the verified private snapshot, so a concurrent build cannot replace
        # the executable between its checksum check and process launch.
        with tempfile.TemporaryDirectory(prefix='rawmaster-evidence-') as snapshot_directory:
            snapshot = pathlib.Path(snapshot_directory) / 'RAWMasterDiagnostics'
            shutil.copyfile(args.binary, snapshot)
            snapshot.chmod(0o500)
            actual_binary = digest(snapshot)
            receipt['frozenBinarySHA256'] = frozen['binarySHA256']
            receipt['runBinarySHA256'] = actual_binary
            receipt['executedPrivateVerifiedSnapshot'] = False
            if actual_binary != frozen['binarySHA256']:
                receipt['failures'].append('Executable checksum mismatch; possible rebuild/relink. Refusing to launch.')
            if receipt['failures']:
                code = 78
            else:
                forwarded = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
                receipt['launched'] = True
                receipt['executedPrivateVerifiedSnapshot'] = True
                code = subprocess.run([str(snapshot)] + forwarded, check=False).returncode
                receipt['childExitCode'] = code
                receipt['status'] = 'launched-completed' if code == 0 else 'launched-nonzero'

    except (OSError, ValueError, KeyError, TypeError) as error:
        receipt['failures'].append(str(error))
        code = 78
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + '\n')
    if receipt['failures']:
        print('Evidence execution refused: ' + '; '.join(receipt['failures']), file=sys.stderr)
    return code if 0 <= code <= 255 else 1


if __name__ == '__main__':
    raise SystemExit(main())
