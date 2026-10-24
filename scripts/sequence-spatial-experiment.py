#!/usr/bin/env python3
"""Frozen offline spatial experiment. No builds, downloads, source edits or golden updates."""
import argparse
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import plistlib
import resource
import signal
import selectors
import subprocess
import sys
import time
import uuid

CASES = {'burst123':123, 'burst14-context38':38, 'burst48-context72':72,
         'interval427-context439':439, 'burst193-context217':217, 'dji187-context376':376}
VARIANTS = ('baseline', 'bridgeVetoOnly', 'localRescueAndBridgeVeto')
UNIT_SECONDS, BATCH_SECONDS, GRACE_SECONDS = 60, 1800, 2
SELECTOR = 'RAWMasterImagingTests.SequenceSpatialExperimentTests/testOfflineUnit'
ACTIVE = None
DEADLINE = float("inf")


def digest_file(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        while chunk := handle.read(1024 * 1024):
            if time.monotonic() >= DEADLINE: raise TimeoutError("Batch1800s watchdog expired while hashing")
            value.update(chunk)
    return value.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()


def safe_output(path, repository, bundle):
    if not str(path).strip():
        raise ValueError('Empty output path')
    target = Path(path).resolve(strict=False)
    protected = [repository / 'Tests/RAWMasterImagingTests/Fixtures', repository / 'Tests/Fixtures/SequenceGroupingInputs']
    protected += [resource / 'Fixtures' for resource in bundle.parent.glob('*RAWMasterImagingTests*.bundle')]
    protected += [bundle]
    for root in protected:
        root = root.resolve(strict=False)
        if target == root or root in target.parents:
            raise ValueError('Output aliases protected fixture/truth/test bundle: ' + str(target))
    return target


def write_json(path, value, repository, bundle):
    path = safe_output(path, repository, bundle)
    path.parent.mkdir(parents=True, exist_ok=True)
    if safe_output(path, repository, bundle) != path:
        raise ValueError('Output destination changed')
    temporary = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    try:
        with temporary.open('xb') as handle:
            handle.write(json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False, allow_nan=False).encode())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def snapshot(repository, runner):
    # Include actual support bytes (CSQLite module map/shim, resources), not only Swift or HEAD.
    files = [path for path in (repository / 'Sources').rglob('*') if path.is_file() and path.name != '.DS_Store']
    files += [path for path in (repository / 'Tests').rglob('*') if path.is_file() and path.suffix in ('.swift', '.py', '.h', '.c', '.modulemap')]
    files += [repository / 'Package.swift', runner]
    entries = [{'path':str(path.relative_to(repository)), 'sha256':digest_file(path)} for path in sorted(set(files))]
    return {'version':'source-snapshot-v1', 'files':entries, 'sha256':hashlib.sha256(canonical(entries)).hexdigest()}


def fixture_snapshot(repository):
    root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'
    index_path = root / 'index.json'
    index = json.loads(index_path.read_text())
    if index['assetCount'] != 1265 or {c['id']:c['assetCount'] for c in index['cases']} != CASES or len(index['cases']) != 6:
        raise ValueError('Fixture inventory changed')
    entries = [{'path':'index.json', 'sha256':digest_file(index_path)}]
    for case in index['cases']:
        for kind in ('manifest', 'metadata', 'truth'):
            relative = case[kind + 'Path']
            path = (root / relative).resolve()
            if root.resolve() not in path.parents or digest_file(path) != case[kind + 'SHA256']:
                raise ValueError('Fixture sidecar identity mismatch')
            entries.append({'path':relative, 'sha256':case[kind + 'SHA256']})
        manifest = json.loads((root / case['manifestPath']).read_text())
        for file in manifest['files']:
            path = ((root / case['manifestPath']).parent / file['relativePath']).resolve()
            if root.resolve() not in path.parents or digest_file(path) != file['jpegSHA256']:
                raise ValueError('JPEG integrity mismatch: ' + file['assetID'])
        # JPEG bytes are independently checked by every native unit; preserve full declared inventory here.
        entries += [{'path':str(Path(case['manifestPath']).parent / f['relativePath']), 'sha256':f['jpegSHA256']} for f in manifest['files']]
    golden = root / 'baselines/behavior-v1.json'
    entries.append({'path':'baselines/behavior-v1.json', 'sha256':digest_file(golden)})
    return {'indexSHA256':digest_file(index_path), 'goldenSHA256':digest_file(golden),
            'sha256':hashlib.sha256(canonical(sorted(entries, key=lambda row:row['path']))).hexdigest(), 'files':entries}


def verify_fixture_controls(repository, frozen):
    root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'
    # All sidecar and golden bytes are checked between processes; selected JPEG bytes are checked natively twice.
    for entry in frozen['files']:
        if entry['path'].endswith('.json') and digest_file(root / entry['path']) != entry['sha256']:
            raise ValueError('Frozen fixture controls changed')


def stop_group(process):
    """Bounded TERM/wait/KILL/reap; never use signal 0 as a liveness oracle on macOS."""
    failures = []
    group_absent = False
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        group_absent = True
    except OSError as error:
        failures.append(f'SIGTERM group {process.pid}: {error}')
    try:
        process.wait(timeout=GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    except OSError as error:
        failures.append(f'wait after TERM {process.pid}: {error}')
    # Even when the leader has exited, descendants may still own the group.
    # A final real KILL is attempted; EPERM is a cleanup failure, never proof of death.
    if not group_absent:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as error:
            failures.append(f'SIGKILL group {process.pid}: {error}')
    try:
        process.wait(timeout=GRACE_SECONDS)
    except (subprocess.TimeoutExpired, OSError) as error:
        failures.append(f'final reap {process.pid}: {error}')
    return failures


def execute(command, environment, log, batch_deadline):
    global ACTIVE
    started = time.monotonic()
    failure = None
    cleanup_failures = []
    with log.open('xb') as output:
        ACTIVE = subprocess.Popen(command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        poller = selectors.DefaultSelector()
        os.set_blocking(ACTIVE.stdout.fileno(), False)
        poller.register(ACTIVE.stdout, selectors.EVENT_READ)
        bytes_written = 0
        try:
            while ACTIVE.poll() is None or poller.get_map():
                if time.monotonic() - started >= UNIT_SECONDS or time.monotonic() >= batch_deadline:
                    raise TimeoutError('Unit60s/batch1800s watchdog expired')
                for key, _ in poller.select(timeout=0.025):
                    chunk = os.read(key.fd, 64 * 1024)
                    if not chunk:
                        poller.unregister(key.fileobj)
                        continue
                    remaining = 8 * 1024 * 1024 - bytes_written
                    output.write(chunk[:remaining])
                    bytes_written += min(len(chunk), remaining)
                    if len(chunk) > remaining: raise RuntimeError('Unit log exceeded 8MiB budget')
            status = ACTIVE.wait()
            if status != 0:
                raise RuntimeError('Native unit failed, exit ' + str(status) + '; see ' + str(log))
        except BaseException as error:
            failure = error
        finally:
            poller.close()
            cleanup_failures = stop_group(ACTIVE)
            ACTIVE.stdout.close()
            ACTIVE = None
        if cleanup_failures:
            text = 'Process-group cleanup failed: ' + '; '.join(cleanup_failures)
            print(text, file=sys.stderr)
            # Preserve cleanup diagnostics without allowing them to hide the original timeout/error.
            cleanup_error = RuntimeError(text)
            if failure is not None:
                raise failure from cleanup_error
            raise cleanup_error
        if failure is not None:
            raise failure
    return time.monotonic() - started


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    return values[max(0, math.ceil(len(values) * fraction) - 1)]


def distribution(values):
    return {'count':len(values), 'p50':percentile(values, .5), 'p95':percentile(values, .95), 'max':max(values) if values else None}


def summarize(records):
    groups = []
    for case, variant in itertools.product(CASES, VARIANTS):
        selected = [r for r in records if r['identity']['phase'] == 'measured' and r['identity']['caseID'] == case and r['identity']['variant'] == variant]
        stages = {}
        for stage in ('nativeRead', 'spatialExtraction', 'engineConsume', 'engineFinish', 'spatialPair'):
            samples = [m['durationSeconds'] for r in selected for m in r['measurements'] if m['stage'] == stage]
            stages[stage] = distribution(samples)
        pairs = [m['spatial'] for r in selected for m in r['measurements'] if m.get('spatial') is not None]
        groups.append({'caseID':case, 'variant':variant, 'runs':len(selected), 'wholeCaseSeconds':distribution([r['wholeCaseSeconds'] for r in selected]),
            'stagesSeconds':stages, 'pairRequests':len(pairs), 'pairComputations':sum(not p['cacheHit'] for p in pairs),
            'pairCacheHits':sum(p['cacheHit'] for p in pairs), 'pairVerdicts':{v:sum(p['verdict'] == v for p in pairs) for v in ('supported','rejected','insufficient')},
            'matcherMissSeconds':distribution([p['durationSeconds'] for p in pairs if not p['cacheHit']]),
            'matcherHitSeconds':distribution([p['durationSeconds'] for p in pairs if p['cacheHit']]),
            'processPeakResidentBytes':distribution([r['processPeakResidentBytes'] for r in selected if r.get('processPeakResidentBytes') is not None]),
            'engineManagedPeakEstimateBytes':distribution([r['engineManagedPeakEstimateBytes'] for r in selected])})
    paired = []
    for pair_id in sorted({r['identity'].get('pairID') for r in records if r['identity']['phase'] == 'measured'}):
        pair = [r for r in records if r['identity'].get('pairID') == pair_id]
        baseline = next(r for r in pair if r['identity']['variant'] == 'baseline')
        candidate = next(r for r in pair if r['identity']['variant'] != 'baseline')
        paired.append({'pairID':pair_id, 'caseID':candidate['identity']['caseID'], 'variant':candidate['identity']['variant'],
                       'candidateMinusBaselineSeconds':candidate['wholeCaseSeconds'] - baseline['wholeCaseSeconds']})
    return {'groups':groups, 'pairedRawDeltas':paired, 'quantile':'nearest-rank; nativeRead contains spatialExtraction, engineConsume contains spatialPair; do not add nested stages',
            'cacheBoundary':'Fresh process, not cold OS filesystem cache; no cache flush. Warmups excluded; first-observed quality runs separately preserved.'}


def benchmark_schedule():
    for case in CASES:
        for phase, repetitions in (('warmup', 1), ('measured', 10)):
            for repetition in range(repetitions):
                candidates = VARIANTS[1:] if repetition % 2 == 0 else tuple(reversed(VARIANTS[1:]))
                for candidate in candidates:
                    pair_id = f'{case}/{candidate}/{phase}/{repetition}'
                    order = ('baseline', candidate) if repetition % 2 == 0 else (candidate, 'baseline')
                    for variant in order:
                        yield case, variant, phase, repetition, pair_id


def edge_evidence(events, left, right, trace_incomplete):
    """Report observed target decisions, never infer causality from nearby input/output rows."""
    decisions = [event for event in events if event.get('stage') not in ('input', 'output')
                 and isinstance(event.get('accepted'), bool)]
    nearby = [event for event in decisions if event.get('ordinal') in (left, right)
              or event.get('referenceOrdinal') in (left, right)]
    target = []
    for event in decisions:
        exact_dense = (event.get('stage') == 'dense' and event.get('referenceOrdinal') == left
                       and event.get('ordinal') == right)
        # This final 3x3 CV aggregate explicitly names the left-last and right-last
        # support rows; infer its first-right only from the fixed three-frame window.
        final_bridge = (event.get('stage') == 'bridge' and event.get('spatialPurpose') == 'burstPauseBridge'
                        and event.get('referenceOrdinal') == left and event.get('ordinal') == right + 2
                        and event.get('reason') in ('spatialSupported', 'spatialRejected')
                        and all(key in event for key in ('spatialSupportedPairs', 'spatialRowsSupported', 'spatialColumnsSupported')))
        if exact_dense or final_bridge:
            target.append(event)
    reasons = []
    if trace_incomplete: reasons.append('trace-incomplete; absence cannot establish an unexercised decision')
    if not target: reasons.append('target-final-decision-missing')
    if nearby: reasons.append('nearby-gates-are-context-not-a-causal-explanation')
    status = 'target-decision-observed' if target and not trace_incomplete else 'partial' if target or nearby else 'missing'
    return {'evidenceStatus':status, 'evidenceMissing':status != 'target-decision-observed',
            'evidencePartial':status == 'partial', 'evidenceReasons':reasons,
            'decisionEvidence':target[-8:], 'nearbyDiagnosticEvents':nearby[-8:],
            'interpretation':'Observed decision records only; no claim that proximity proves the causal reason for a whole-range change.'}


def edge_deltas(quality, repository):
    root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'
    index = json.loads((root / 'index.json').read_text())
    output = []
    for case in index['cases']:
        records = {r['identity']['variant']:r for r in quality if r['identity']['caseID'] == case['id']}
        truth = json.loads((root / case['truthPath']).read_text())
        manifest = json.loads((root / case['manifestPath']).read_text())
        ids = [f['assetID'] for f in manifest['files']]
        positives = {frozenset((a,b)) for g in truth['groups'] for a,b in zip(ids,ids[1:]) if a in g['assetIDs'] and b in g['assetIDs']}
        negatives = {frozenset((p['from'],p['to'])) for p in truth['negativePairs']}
        def membership(record):
            result = {}
            for group, span in enumerate(record['behavior']['result']['ranges']):
                for ordinal in range(span['range']['first'], span['range']['last'] + 1): result[ordinal] = (group, span['kind'])
            return result
        baseline = membership(records['baseline'])
        for variant in VARIANTS[1:]:
            candidate = membership(records[variant])
            events = []
            trace = records[variant].get('trace')
            if trace:
                for line in Path(trace['path']).read_text().splitlines():
                    item = json.loads(line)
                    if 'ordinal' in item and 'stage' in item: events.append(item)
            changes = []
            for i in range(len(ids) - 1):
                old = i in baseline and i+1 in baseline and baseline[i][0] == baseline[i+1][0]
                new = i in candidate and i+1 in candidate and candidate[i][0] == candidate[i+1][0]
                old_kind = baseline.get(i, (None,None))[1] if old else None
                new_kind = candidate.get(i, (None,None))[1] if new else None
                if old == new and old_kind == new_kind: continue
                pair = frozenset((ids[i],ids[i+1]))
                label = 'known-positive' if pair in positives else 'known-negative' if pair in negatives else 'unknown' if set(pair) & set(case['unknownAssetIDs']) else 'unlabeled'
                explanation = edge_evidence(events, i, i+1, trace.get('incomplete', True) if trace else True)
                changes.append({'from':ids[i], 'to':ids[i+1], 'leftOrdinal':i, 'rightOrdinal':i+1, 'truth':label,
                    'baselineJoined':old, 'candidateJoined':new, 'baselineKind':old_kind, 'candidateKind':new_kind,
                    **explanation})
            output.append({'caseID':case['id'], 'variant':variant, 'changedEdges':changes,
                'baselineRanges':records['baseline']['behavior']['result']['ranges'], 'candidateRanges':records[variant]['behavior']['result']['ranges'],
                'baselineCoverage':records['baseline']['behavior']['result']['coverage'], 'candidateCoverage':records[variant]['behavior']['result']['coverage'],
                'traceIncomplete':trace.get('incomplete', True) if trace else True, 'traceReference':trace})
    return output


def main():
    global DEADLINE
    DEADLINE = time.monotonic() + BATCH_SECONDS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test-bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    repository = Path(__file__).resolve().parent.parent
    bundle = args.test_bundle.resolve(strict=True)
    output = safe_output(args.output, repository, bundle)
    if output.exists() and any(output.iterdir()): raise ValueError('Output must be a fresh/empty directory')
    output.mkdir(parents=True, exist_ok=True)
    plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    binary = bundle / 'Contents/MacOS' / plist['CFBundleExecutable']
    executable_hash = digest_file(binary)
    frozen = snapshot(repository, Path(__file__).resolve())
    fixtures = fixture_snapshot(repository)
    run_id = str(uuid.uuid4())
    execute(['/usr/bin/xcrun', 'swift', '--version'], os.environ.copy(), output / 'toolchain.log', DEADLINE)
    toolchain = (output / 'toolchain.log').read_text().strip()
    command = ['/usr/bin/xcrun', 'xctest', '-XCTest', SELECTOR, str(bundle)]
    deadline = DEADLINE
    receipt = {'schemaVersion':1, 'runID':run_id, 'sourceSnapshot':frozen, 'fixtures':fixtures,
        'executableSHA256':executable_hash, 'testBundle':str(bundle), 'command':command, 'swift':toolchain,
        'benchmarkOrder':[list(item) for item in benchmark_schedule()], 'schedule':{'qualityUnits':18,'benchmarkUnits':264,'warmupsPerPair':1,'measuredPerPair':10,'unitSeconds':60,'batchSeconds':1800,'terminationGraceSeconds':2,'seed':0}}
    write_json(output / 'freeze.json', receipt, repository, bundle)
    records = []
    descriptor = None
    def unit(phase, case=None, variant=None, repetition=None, pair_id=None):
        if time.monotonic() >= deadline: raise TimeoutError('Batch1800s watchdog expired')
        if snapshot(repository, Path(__file__).resolve()) != frozen or digest_file(binary) != executable_hash: raise RuntimeError('Source/binary changed after freeze')
        verify_fixture_controls(repository, fixtures)
        identity = {k:v for k,v in {'schemaVersion':1,'runID':run_id,'unitID':str(uuid.uuid4()),'phase':phase,
            'caseID':case,'variant':variant,'repetition':repetition,'pairID':pair_id,
            'expectedPolicyFingerprint':descriptor[variant] if descriptor and variant else None,
            'fixtureIndexSHA256':fixtures['indexSHA256'] if phase != 'bootstrap' else None,
            'sourceSnapshotSHA256':frozen['sha256'],'executableSHA256':executable_hash}.items() if v is not None}
        prefix = output / identity['unitID']
        control, report = prefix.with_suffix('.control.json'), prefix.with_suffix('.report.json')
        write_json(control, identity, repository, bundle)
        environment = os.environ.copy()
        # Inherited fixture record/quality switches must never alter this explicit experiment.
        for key in list(environment):
            if key.startswith('RAWMASTER_SEQUENCE_FIXTURE_') or key.startswith('RAWMASTER_SPATIAL_EXPERIMENT_'): environment.pop(key)
        environment.update(RAWMASTER_SPATIAL_EXPERIMENT_UNIT=str(control), RAWMASTER_SPATIAL_EXPERIMENT_REPORT=str(report), RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION=toolchain)
        process_wall = execute(command, environment, prefix.with_suffix('.log'), deadline)
        value = json.loads(report.read_text())
        if value['schemaVersion'] != 1 or value['identity'] != identity: raise RuntimeError('Native report identity mismatch')
        if phase != 'bootstrap':
            if value['kind'] != 'unit' or value['integrityValidated'] is not True or value['strictValidated'] is not True: raise RuntimeError('Native integrity/strict validation failed')
            if value['behavior']['id'] != case or value['behavior']['assetCount'] != CASES[case] or value['behavior']['policyFingerprint'] != descriptor[variant]: raise RuntimeError('Actual case/policy mismatch')
            sealed = Path(value['analysisPath']).read_bytes()
            if hashlib.sha256(sealed).hexdigest() != value['analysisSHA256']: raise RuntimeError('Sealed analysis digest mismatch')
            if json.loads(sealed)['result'] != value['behavior']['result']: raise RuntimeError('Report differs from sealed result')
            if not math.isfinite(value['wholeCaseSeconds']) or value['wholeCaseSeconds'] < 0: raise RuntimeError('Invalid timing')
            value['processWallSeconds'] = process_wall
        if snapshot(repository, Path(__file__).resolve()) != frozen or digest_file(binary) != executable_hash: raise RuntimeError('Frozen source/binary changed during unit')
        verify_fixture_controls(repository, fixtures)
        return value
    try:
        boot = unit('bootstrap')
        if boot['kind'] != 'descriptor' or boot['fixtureIndexSHA256'] != fixtures['indexSHA256'] or boot['goldenSHA256'] != fixtures['goldenSHA256']: raise RuntimeError('Bootstrap fixture mismatch')
        descriptor = {v['variant']:v['policyFingerprint'] for v in boot['variants']}
        if set(descriptor) != set(VARIANTS) or len(set(descriptor.values())) != 3: raise RuntimeError('Variant identities missing/aliased')
        write_json(output / 'descriptor.json', boot, repository, bundle)
        quality = []
        for case in CASES:
            for variant in VARIANTS:
                value = unit('quality', case, variant)
                quality.append(value)
                records.append(value)
        write_json(output / 'quality.json', quality, repository, bundle)
        write_json(output / 'edge-deltas.json', edge_deltas(quality, repository), repository, bundle)
        # Poor candidate quality remains a measured research result, never a reason to omit cost measurements.
        for case, variant, phase, repetition, pair_id in benchmark_schedule():
            records.append(unit(phase, case, variant, repetition, pair_id))
        final_fixtures = fixture_snapshot(repository)
        if final_fixtures != fixtures: raise RuntimeError('Fixture bytes changed during batch')
        write_json(output / 'benchmark.json', {'schemaVersion':1, 'runID':run_id,'units':records,'summary':summarize(records),
            'driverPeakResidentBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if sys.platform == 'darwin' else 1024)}, repository, bundle)
        write_json(output / 'complete.json', {'schemaVersion':1,'runID':run_id,'complete':True,'qualityAccepted':all(r['behavior']['qualityAccepted'] for r in quality),
            'qualityUnits':len(quality),'benchmarkUnits':len(records)-len(quality),'sourceSnapshotSHA256':frozen['sha256'],'fixtureSnapshotSHA256':fixtures['sha256']}, repository, bundle)
    except BaseException as error:
        write_json(output / 'failure.json', {'schemaVersion':1,'runID':run_id,'complete':False,'error':str(error),'completedUnits':len(records)}, repository, bundle)
        raise


def interrupted(signum, frame):
    raise KeyboardInterrupt('Signal ' + str(signum))


if __name__ == '__main__':
    for number in (signal.SIGTERM, signal.SIGINT): signal.signal(number, interrupted)
    try:
        main()
    except SystemExit:
        raise
    except BaseException as error:
        if ACTIVE is not None:
            cleanup = stop_group(ACTIVE)
            if cleanup: print("Process-group cleanup failed: " + "; ".join(cleanup), file=sys.stderr)
        print('Spatial experiment hard error: ' + str(error), file=sys.stderr)
        sys.exit(1)
