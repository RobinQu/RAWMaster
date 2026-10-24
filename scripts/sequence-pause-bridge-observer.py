#!/usr/bin/env python3
"""Six frozen observer units. No new classifier, labels, original reads, builds or baseline rewrites."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import signal
import sys
import time
import uuid

spec = importlib.util.spec_from_file_location('pause_observer_metadata_dependency', Path(__file__).with_name('sequence-metadata-experiment.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
watch = metadata.watch
SELECTOR = 'RAWMasterImagingTests.SequencePauseBridgeObserverTests/testOfflineObserverUnit'
MAX_BYTES = 16 * 1024 * 1024


def source_snapshot(repository):
    value = metadata.source_snapshot(repository)
    files = value['files'] + [{'path': 'scripts/sequence-pause-bridge-observer.py', 'sha256': watch.digest_file(Path(__file__).resolve())}]
    files = sorted({row['path']: row for row in files}.values(), key=lambda row: row['path'])
    return {'files': files, 'sha256': metadata.fingerprint(files)}


def safe_output(path, repository, bundle):
    target = watch.safe_output(path, repository, bundle)
    if (repository / 'output').resolve() not in target.parents:
        raise ValueError('Pause observer output must be under ignored output')
    return target


def original_nanos(file):
    capture = file['capture']
    fraction = capture.get('subsecTimeOriginalRaw')
    if not isinstance(fraction, str) or not all('0' <= ch <= '9' for ch in fraction) or not 1 <= len(fraction) <= 9:
        return None
    date = datetime.datetime.strptime(capture['dateTimeOriginalRaw'], '%Y:%m:%d %H:%M:%S')
    # A timezone-free civil axis for differences, never a UTC assertion.
    seconds = date.toordinal() * 86400 + date.hour * 3600 + date.minute * 60 + date.second
    return seconds * 1_000_000_000 + int(fraction.ljust(9, '0'))


def expected_edges(case, configuration):
    files = case['files']
    rows = []
    for left, right in zip(files, files[1:]):
        if any(f['fieldStates'].get('sony.ReleaseMode') != 'present' or f['resolvedNumbers'].get('sony.ReleaseMode') != '2' for f in (left, right)):
            continue
        a, b = original_nanos(left), original_nanos(right)
        if a is not None and b is not None and configuration['denseGapSeconds'] < (b-a)/1_000_000_000 <= configuration['maximumBridgeSeconds']:
            rows.append((left['ordinal'], right['ordinal']))
    return rows


def validate_geometry(pair):
    geometry = pair.get('luminanceGeometry')
    if pair['distance'] is None:
        if geometry is not None or not pair.get('luminanceGeometryUnavailableReason'):
            raise ValueError('Unavailable geometry must be explicit')
        return
    if not isinstance(geometry, dict) or pair.get('luminanceGeometryUnavailableReason') is not None:
        raise ValueError('Available pair is missing luminance geometry')
    finite_fields = ('rawDot', 'firstNormSquared', 'secondNormSquared', 'firstMean', 'secondMean',
                     'centeredDot', 'firstCenteredNormSquared', 'secondCenteredNormSquared')
    if not isinstance(geometry.get('count'), int) or not 1 <= geometry['count'] <= 1024:
        raise ValueError('Luminance geometry vector count invalid')
    if not all(isinstance(geometry.get(key), (int, float)) and math.isfinite(geometry[key]) for key in finite_fields):
        raise ValueError('Nonfinite luminance geometry')
    for coefficient in ('cosine', 'pearson'):
        value, reason = geometry.get(coefficient), geometry.get(coefficient + 'UnavailableReason')
        if value is None:
            if not reason:
                raise ValueError('Degenerate coefficient requires reason')
        elif reason is not None or not isinstance(value, (int, float)) or not math.isfinite(value) or not -1 <= value <= 1:
            raise ValueError('Luminance coefficient invalid')


def validate_matrices(row):
    left, right = row['leftOrdinal'], row['rightOrdinal']
    if right != left + 1:
        raise ValueError('Observer edge is not adjacent')
    if [s['ordinal'] for s in row['leftSlots']] != list(range(right-3, right)) or [s['ordinal'] for s in row['rightSlots']] != list(range(right, right+3)):
        raise ValueError('Observer support slots were omitted or selected')
    expected = {'crossNine': [(a, b) for a in range(right-3, right) for b in range(right, right+3)],
                'leftIntraThree': [(left-2, left-1), (left-2, left), (left-1, left)],
                'rightIntraThree': [(right, right+1), (right, right+2), (right+1, right+2)]}
    for name, pairs in expected.items():
        actual = row[name]
        if [(p['fromOrdinal'], p['toOrdinal']) for p in actual] != pairs:
            raise ValueError('Observer matrix omitted/reordered pairs')
        for pair in actual:
            distance = pair['distance']
            validate_geometry(pair)
            if distance is None:
                if not pair['issues']:
                    raise ValueError('Missing observer distance has no explicit reason')
            elif pair['issues'] or set(distance) != {'histogram', 'luminance', 'hash'} or not all(isinstance(v, (int, float)) and math.isfinite(v) and v >= 0 for v in distance.values()):
                raise ValueError('Observer distance is invalid')
    if row['supportComplete'] != all(not slot['issues'] for slot in row['leftSlots'] + row['rightSlots']):
        raise ValueError('Observer support availability was concealed')


def validate_report(value, identity, expected_count, diagnostic_path, case, metadata_frozen):
    if value.get('schemaVersion') != 1 or value.get('kind') != 'pause-bridge-observer-report' or value.get('identity') != identity:
        raise ValueError('Observer native identity mismatch')
    if not all(value.get(k) is True for k in ('sourceIntegrityValidated', 'defaultParity', 'strict008BParity', 'diagnosticSealedBeforeBaselineRead')):
        raise ValueError('Observer source/parity/seal failed')
    if value.get('labelsRead') is not False or value.get('qualityAccepted') is not False or value.get('assetCount') != expected_count:
        raise ValueError('Observer scope/labels/quality assertion invalid')
    path = Path(value['diagnosticPath'])
    if path.is_symlink() or path.resolve() != Path(diagnostic_path).resolve():
        raise ValueError('Observer diagnostic path changed')
    with path.open('rb') as stream:
        data = stream.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES or hashlib.sha256(data).hexdigest() != value['diagnosticSHA256']:
        raise ValueError('Observer diagnostic byte budget/seal failed')
    diagnostic = json.loads(data)
    if diagnostic.get('identity') != identity or diagnostic.get('kind') != 'pause-bridge-observation' or diagnostic.get('labelsRead') is not False:
        raise ValueError('Observer sealed diagnostic identity mismatch')
    if not diagnostic.get('matricesComplete') or diagnostic.get('assetCount') != expected_count:
        raise ValueError('Observer matrix enumeration incomplete')
    sources = diagnostic['sources']
    if len(sources) != expected_count or [s['ordinal'] for s in sources] != list(range(expected_count)) or not all(s['sourceUnchanged'] and s['beforeSHA256'] == s['afterSHA256'] == s['currentSHA256'] for s in sources):
        raise ValueError('Observer complete native source proof failed')
    for key, expected in [('metadataSnapshotSHA256', metadata_frozen['caseSHA256s'][identity['caseID']]), ('auditSeal', metadata_frozen['auditSeal'])]:
        if value.get(key) != expected or diagnostic.get(key) != expected:
            raise ValueError('Observer metadata identity changed')
    rows = diagnostic['pauseWindows']
    if len(rows) > 4096 or len(rows) != value['pauseWindowCount'] or [(r['leftOrdinal'], r['rightOrdinal']) for r in rows] != expected_edges(case, diagnostic['configuration']):
        raise ValueError('Observer did not enumerate every eligible original edge')
    for row in rows:
        validate_matrices(row)
    trace = diagnostic['emittedTraceSubset']
    if len(trace) > 4096 or diagnostic['emittedTraceSubsetCount'] != len(trace) or 'absence is not causal evidence' not in diagnostic['traceBoundary'] or 'summary is unavailable' not in diagnostic['traceBoundary']:
        raise ValueError('Observer trace cap/completeness claim invalid')
    for key in ('defaultResultSHA256', 'strict008BResultSHA256'):
        if value[key] != diagnostic[key]:
            raise ValueError('Observer result identities diverge')
    if not math.isfinite(value['wholeUnitSeconds']) or value['wholeUnitSeconds'] < 0:
        raise ValueError('Observer elapsed measurement invalid')


def main():
    deadline = time.monotonic() + 1800
    watch.DEADLINE = deadline
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test-bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    bundle = args.test_bundle.resolve(strict=True)
    output = safe_output(args.output, repository, bundle)
    if output.exists() and any(output.iterdir()):
        raise ValueError('Fresh observer output required')
    output.mkdir(parents=True, exist_ok=True)
    plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    binary = bundle / 'Contents/MacOS' / plist['CFBundleExecutable']
    executable = watch.digest_file(binary)
    sources, v1, v2 = source_snapshot(repository), watch.fixture_snapshot(repository), metadata.metadata_snapshot(repository)
    baseline_sha = next(row['sha256'] for row in v2['files'] if row['path'] == 'baselines/behavior-v1.json')
    run_id = str(uuid.uuid4())
    command = ['/usr/bin/xcrun', 'xctest', '-XCTest', SELECTOR, str(bundle)]
    watch.execute(['/usr/bin/xcrun', 'swift', '--version'], os.environ.copy(), output / 'toolchain.log', deadline)
    toolchain = (output / 'toolchain.log').read_text().strip()
    freeze = {'schemaVersion': 1, 'runID': run_id, 'sourceSnapshot': sources, 'fixtures': v1, 'metadata': v2,
              'observedBaselineSHA256': baseline_sha, 'executableSHA256': executable, 'swift': toolchain, 'command': command,
              'schedule': {'observerUnits': 6, 'qualityUnits': 0, 'benchmarkUnits': 0, 'unitSeconds': 60, 'batchSeconds': 1800, 'terminationGraceSeconds': 2},
              'meaning': 'Bounded observation of unchanged dev4/008B, no label reads or new classifier. Completion is not quality acceptance.'}
    watch.write_json(output / 'freeze.json', freeze, repository, bundle)
    completed = []

    def verify():
        if time.monotonic() >= deadline or source_snapshot(repository) != sources or watch.digest_file(binary) != executable:
            raise RuntimeError('Observer frozen source/binary changed or batch budget expired')
        watch.verify_fixture_controls(repository, v1)
        metadata.verify_metadata(repository, v2)

    try:
        root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'
        index = json.loads((root / 'index.json').read_text())
        for case_id, count in watch.CASES.items():
            verify()
            identity = {'schemaVersion': 1, 'runID': run_id, 'unitID': str(uuid.uuid4()), 'caseID': case_id,
                        'fixtureIndexSHA256': v1['indexSHA256'], 'metadataIndexSHA256': v2['indexSHA256'],
                        'observedBaselineSHA256': baseline_sha, 'sourceSnapshotSHA256': sources['sha256'], 'executableSHA256': executable}
            prefix = output / identity['unitID']
            control, report = prefix.with_suffix('.control.json'), prefix.with_suffix('.report.json')
            watch.write_json(control, identity, repository, bundle)
            env = os.environ.copy()
            for key in list(env):
                if key.startswith(('RAWMASTER_SEQUENCE_FIXTURE_', 'RAWMASTER_SPATIAL_EXPERIMENT_', 'RAWMASTER_METADATA_EXPERIMENT_', 'RAWMASTER_PAUSE_OBSERVER_')):
                    env.pop(key)
            env.update(RAWMASTER_PAUSE_OBSERVER_UNIT=str(control), RAWMASTER_PAUSE_OBSERVER_REPORT=str(report), RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION=toolchain)
            wall = watch.execute(command, env, prefix.with_suffix('.log'), deadline)
            value = json.loads(report.read_text())
            case = next(c for c in index['cases'] if c['id'] == case_id)
            case_data = json.loads((root / case['path']).read_text())
            validate_report(value, identity, count, str(report) + '.diagnostic.json', case_data, v2)
            value['processWallSeconds'] = wall
            verify()
            completed.append(value)
            watch.write_json(output / 'progress.json', {'runID': run_id, 'completedObserverUnits': len(completed), 'expectedObserverUnits': 6}, repository, bundle)
        verify()
        if watch.fixture_snapshot(repository) != v1 or metadata.metadata_snapshot(repository) != v2:
            raise RuntimeError('Observer frozen dataset bytes changed')
        watch.write_json(output / 'observations.json', completed, repository, bundle)
        watch.write_json(output / 'complete.json', {'schemaVersion': 1, 'runID': run_id, 'complete': True, 'observerUnits': 6,
            'qualityAccepted': False, 'labelsRead': False, 'pauseWindowCount': sum(v['pauseWindowCount'] for v in completed),
            'sourceSnapshotSHA256': sources['sha256'], 'metadataSnapshotSHA256': v2['sha256']}, repository, bundle)
        print('Pause observer complete:6 units; no new classifier or quality acceptance')
    except BaseException as error:
        watch.write_json(output / 'failure.json', {'schemaVersion': 1, 'runID': run_id, 'complete': False,
            'completedObserverUnits': len(completed), 'error': str(error)}, repository, bundle)
        raise


def interrupted(signum, _frame):
    raise KeyboardInterrupt('Signal ' + str(signum))


if __name__ == '__main__':
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        main()
    except SystemExit:
        raise
    except BaseException as error:
        if watch.ACTIVE is not None:
            watch.stop_group(watch.ACTIVE)
        print('Pause observer hard error:', str(error), file=sys.stderr)
        sys.exit(1)
