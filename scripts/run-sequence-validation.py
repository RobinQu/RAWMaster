#!/usr/bin/env python3
"""Launch exactly one frozen SequenceProbe snapshot, or refuse before any source media IO."""
import argparse
import hashlib
import json
import math
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOTS = ('Sources/RAWMasterCore', 'Sources/RAWMasterImaging', 'Sources/RAWMasterSequenceProbe')
REQUIRED = {'Package.swift', 'Sources/CSQLite/module.modulemap', 'Sources/CSQLite/shim.h', 'scripts/run-sequence-validation.py'}
WATCHDOG_GRACE_SECONDS = 1.0
FLAGS = ('--source-root', '--manifest', '--policy', '--labels', '--report')


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON key: ' + key)
        result[key] = value
    return result


def read_json(path):
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def read_frozen(path):
    # Parse and receipt-hash exactly the same immutable bytes, even if the path is replaced.
    raw = path.read_bytes()
    return json.loads(raw.decode('utf-8'), object_pairs_hook=unique_object), hashlib.sha256(raw).hexdigest()


def source_path(repo, name):
    relative = pathlib.PurePosixPath(name)
    if relative.is_absolute() or any(p in ('', '.', '..') for p in relative.parts):
        raise ValueError('Unsafe source inventory path: ' + name)
    candidate = repo / name
    if candidate.is_symlink() or not candidate.resolve().is_relative_to(repo):
        raise ValueError('Escaping/symlink source inventory path: ' + name)
    return candidate


def arguments(values):
    if len(values) != len(FLAGS) * 2:
        raise ValueError('Only the five complete, single-use frozen CLI options are permitted')
    result = {}
    for index in range(0, len(values), 2):
        flag, value = values[index:index + 2]
        if flag not in FLAGS or flag in result or not value:
            raise ValueError('Unknown, duplicate or empty CLI option')
        if not pathlib.PurePosixPath(value).is_absolute():
            raise ValueError('All five frozen paths must be absolute')
        result[flag] = value
    if set(result) != set(FLAGS):
        raise ValueError('Missing frozen CLI option')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', type=pathlib.Path, required=True)
    parser.add_argument('--freeze', type=pathlib.Path, required=True)
    parser.add_argument('--binary', type=pathlib.Path, required=True)
    parser.add_argument('--receipt', type=pathlib.Path, required=True)
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    receipt = {'schemaVersion': 1, 'checkedAt': datetime.now(timezone.utc).isoformat(),
               'status': 'refused-before-launch', 'launched': False, 'launchAttempted': False, 'failures': [],
               'boundary': 'Execution provenance only; neither scientific acceptance nor proof of native physical-device identity'}
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(args.receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as error:
        print('Refused; receipt already reserved or unavailable: ' + str(error), file=sys.stderr)
        return 78
    code = 78
    with os.fdopen(descriptor, 'w') as receipt_stream:
        try:
            repo = args.repo.resolve(strict=True)
            frozen, freeze_sha256 = read_frozen(args.freeze)
            receipt['freezeSHA256'] = freeze_sha256
            if frozen['schemaVersion'] != 1 or not frozen['experimentID']:
                raise ValueError('Invalid freeze schema or experiment identity')
            receipt['experimentID'] = frozen['experimentID']
            if str(args.receipt.absolute()) != frozen['receiptPath']:
                raise ValueError('Receipt path differs from frozen single-attempt path')
            forwarded = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
            if forwarded != frozen['arguments']:
                raise ValueError('Exact CLI parameters differ from freeze')
            requested = arguments(forwarded)
            hashes = frozen['sourceSHA256']
            inventory = set(REQUIRED)
            for root in ROOTS:
                source_root = repo / root
                candidates = list(source_root.rglob('*'))
                if source_root.is_symlink() or any(p.is_symlink() for p in candidates):
                    raise ValueError('Symlinks are not allowed in the frozen source inventory')
                files = [p for p in candidates if p.is_file()]
                if not files:
                    raise ValueError('Missing required source closure: ' + root)
                inventory.update(p.relative_to(repo).as_posix() for p in files)
            if not inventory.issubset(set(hashes)):
                raise ValueError('Required source inventory changed or is incomplete')
            aggregate = hashlib.sha256()
            checks = {}
            for name, expected in sorted(hashes.items()):
                path = source_path(repo, name)
                actual = sha(path)
                checks[name] = actual == expected
                if actual != expected:
                    raise ValueError('Source checksum mismatch: ' + name)
                aggregate.update(name.encode() + b'\0')
                with path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        aggregate.update(block)
            receipt['sourceHashesMatchFreeze'] = checks
            if aggregate.hexdigest() != frozen['aggregateSourceSHA256']:
                raise ValueError('Aggregate source checksum mismatch')
            # The inventory itself is frozen; new/deleted files cannot hide behind an unchanged digest subset.
            frozen_inventory = {n for n in hashes if n in REQUIRED or any(n.startswith(r + '/') for r in ROOTS)}
            if inventory != frozen_inventory:
                raise ValueError('Exact target source inventory differs from freeze')
            with tempfile.TemporaryDirectory(prefix='rawmaster-sequence-') as temporary:
                private = pathlib.Path(temporary)
                os.chmod(private, 0o700)
                executable = private / 'RAWMasterSequenceProbe'
                shutil.copyfile(args.binary, executable)
                executable.chmod(0o500)
                actual_binary = sha(executable)
                receipt['runBinarySHA256'] = actual_binary
                receipt['frozenBinarySHA256'] = frozen['binarySHA256']
                if actual_binary != frozen['binarySHA256']:
                    raise ValueError('Executable snapshot checksum mismatch')
                rewritten = list(forwarded)
                controls = {}
                private_policy = None
                for key in ('manifest', 'policy', 'labels'):
                    control = frozen['controls'][key]
                    if requested['--' + key] != control['path']:
                        raise ValueError('Control path differs from freeze: ' + key)
                    snapshot = private / (key + '.json')
                    shutil.copyfile(control['path'], snapshot)
                    snapshot.chmod(0o400)
                    actual = sha(snapshot)
                    # Structural duplicate-key rejection does not expose label semantics to the engine.
                    parsed = read_json(snapshot)
                    if key == 'policy':
                        private_policy = parsed
                    if actual != control['sha256']:
                        raise ValueError('Control snapshot checksum mismatch: ' + key)
                    controls[key] = actual
                    rewritten[rewritten.index('--' + key) + 1] = str(snapshot)
                limit = private_policy['maximumDurationSeconds']
                if isinstance(limit, bool) or not isinstance(limit, (int, float)) or not math.isfinite(limit) or not 0 < limit <= 86400:
                    raise ValueError('Frozen policy needs a finite positive maximumDurationSeconds <=86400')
                timeout = limit + WATCHDOG_GRACE_SECONDS
                receipt['watchdogTimeoutSeconds'] = timeout
                if requested['--report'] == str(args.receipt.absolute()):
                    raise ValueError('Report must not overwrite the execution receipt')
                receipt['controlSnapshotSHA256'] = controls
                receipt['executedPrivateVerifiedSnapshot'] = True
                receipt['frozenArguments'] = forwarded
                receipt['executedArguments'] = rewritten
                environment = {k: v for k, v in os.environ.items()
                               if not k.startswith(('DYLD_', 'LD_', 'PYTHON', 'SWIFT_'))}
                environment['RAWMASTER_SEQUENCE_GUARDED'] = '1'
                receipt['launchAttempted'] = True
                receipt['status'] = 'launching'
                receipt['launched'] = True
                receipt['startedAt'] = datetime.now(timezone.utc).isoformat()
                # Persist launch intent before starting; an interrupted parent cannot leave a reusable attempt.
                receipt_stream.write(json.dumps(receipt, indent=2) + '\n'); receipt_stream.flush(); os.fsync(receipt_stream.fileno())
                try:
                    code = subprocess.run([str(executable)] + rewritten, env=environment, check=False, timeout=timeout).returncode
                    receipt['childExitCode'] = code
                    receipt['status'] = 'launched-completed' if code == 0 else 'launched-nonzero'
                except subprocess.TimeoutExpired:
                    # subprocess.run kills and waits for its direct child on timeout; never retry.
                    code = 124
                    receipt['childExitCode'] = None
                    receipt['guardExitCode'] = code
                    receipt['childTimeoutEnforced'] = True
                    receipt['status'] = 'launched-timeout'
                    receipt['failures'].append('Frozen-policy watchdog timed out; direct child killed and joined')
        except (OSError, ValueError, KeyError, TypeError) as error:
            receipt['failures'].append(str(error))
            if receipt['launchAttempted']:
                receipt['launched'] = False
                receipt['status'] = 'launch-failed'
                receipt['guardExitCode'] = 126
                code = 126
            else:
                code = 78
        finally:
            receipt['finishedAt'] = datetime.now(timezone.utc).isoformat()
            receipt_stream.seek(0); receipt_stream.truncate()
            receipt_stream.write(json.dumps(receipt, indent=2) + '\n'); receipt_stream.flush(); os.fsync(receipt_stream.fileno())
    if receipt['failures']:
        print('Sequence execution ' + receipt['status'] + ': ' + '; '.join(receipt['failures']), file=sys.stderr)
    return code if 0 <= code <= 255 else 1


if __name__ == '__main__':
    raise SystemExit(main())
