#!/usr/bin/env python3
"""Fixed008B/009 x strict/assumed x6cases. No builds/originals/model/import or golden rewrites."""
import argparse
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

spec = importlib.util.spec_from_file_location('focus_experiment_metadata_dependency', Path(__file__).with_name('sequence-metadata-experiment.py'))
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)
watch = metadata.watch
VARIANTS = ('008B-strict', '008B-assumed', '009-strict', '009-assumed')
SELECTOR = 'RAWMasterImagingTests.SequenceFocusExperimentTests/testOfflineUnit'
FOCUS_SEAL = 'b3ad33d4409ddf885d4ccff21da57e30d3c688d9087332ff2ceb3fabce48bec3'


def schedule():
    return [(case, variant) for case in watch.CASES for variant in VARIANTS]


def source_snapshot(repository):
    value = metadata.source_snapshot(repository)
    files = value['files'] + [{'path': str(path.relative_to(repository)), 'sha256': watch.digest_file(path)} for path in (repository / 'scripts').glob('*.py')]
    files.append(dict(path='scripts/sequence-focus-fields-v1.json', sha256=watch.digest_file(repository / 'scripts/sequence-focus-fields-v1.json')))
    files = sorted({row['path']: row for row in files}.values(), key=lambda row: row['path'])
    return dict(files=files, sha256=metadata.fingerprint(files))


def focus_snapshot(repository):
    root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingFocus/v1'
    index = json.loads((root / 'index.json').read_text())
    if (index['schemaVersion'] != 1 or index['focusAuditSeal'] != FOCUS_SEAL or index['assetCount'] != 1265
            or index['auditedAssetCount'] != 450 or index['outsideAuditedCohortCount'] != 815 or len(index['cases']) != 6
            or {case['id']: case['assetCount'] for case in index['cases']} != watch.CASES):
        raise ValueError('Focus fixture scope changed')
    files = [dict(path='index.json', sha256=watch.digest_file(root / 'index.json'))]
    for case in index['cases']:
        path = (root / case['path']).resolve()
        if root.resolve() not in path.parents or watch.digest_file(path) != case['sha256']:
            raise ValueError('Focus case bytes changed')
        files.append(dict(path=case['path'], sha256=case['sha256']))
    files.append(dict(path='README.md', sha256=watch.digest_file(root / 'README.md')))
    # Later observed behavior remains a separate additive control, never overwrites008.
    files += [dict(path=str(path.relative_to(root)), sha256=watch.digest_file(path)) for path in sorted((root / 'baselines').glob('*.json'))]
    return dict(files=files, indexSHA256=files[0]['sha256'], sha256=metadata.fingerprint(files), focusAuditSeal=FOCUS_SEAL,
                caseSHA256s={case['id']: case['sha256'] for case in index['cases']})


def verify_focus(repository, frozen):
    root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingFocus/v1'
    if any(watch.digest_file(root / row['path']) != row['sha256'] for row in frozen['files']):
        raise RuntimeError('Frozen focus bytes changed')


def validate_unit(value, identity, expected_count, expected_path, focus):
    if value.get('schemaVersion') != 1 or value.get('identity') != identity:
        raise ValueError('Focus unit identity mismatch')
    if identity['phase'] == 'bootstrap':
        if value.get('kind') != 'focus-experiment-descriptor' or value.get('labelsRead') is not False or value.get('focusSnapshotSHA256') != focus['caseSHA256s'][identity['caseID']]:
            raise ValueError('Focus descriptor invalid')
        return
    if value.get('kind') != 'focus-quality-unit' or not all(value.get(k) is True for k in ('integrityValidated', 'strictValidated', 'analysisSealedBeforeLabels')):
        raise ValueError('Focus integrity/strict/seal failed')
    behavior = value['behavior']
    if behavior['id'] != identity['caseID'] or behavior['assetCount'] != expected_count or behavior['policyFingerprint'] != identity['expectedPolicyFingerprint']:
        raise ValueError('Focus behavior identity changed')
    enabled = identity['variant'].startswith('009-')
    if value['focusConsumed'] != enabled or value['pairPrecision'] is not None:
        raise ValueError('Focus/pair evidence meaning invalid')
    if enabled:
        if value['focusSnapshotSHA256'] != focus['caseSHA256s'][identity['caseID']] or value['focusAuditSeal'] != FOCUS_SEAL or value['configuration'].get('pauseBridgeExperiment') is None:
            raise ValueError('Focus actual recipe missing')
    elif value['configuration'].get('pauseBridgeExperiment') is not None or value['focusSnapshotSHA256'] is not None or value['pauseBridgeStatistics'] is not None:
        raise ValueError('008B control silently consumes focus')
    if value['associationHypothesisAssumed'] and (value['topQualityAccepted'] or value['metricsMeaning'] != 'conditionalGroupingMetrics'):
        raise ValueError('Assumed association cannot claim top/native quality')
    if identity['variant'].endswith('-strict') and value['associationHypothesisAssumed']:
        raise ValueError('Strict association silently assumed a pair')
    path = Path(value['analysisPath'])
    if path.is_symlink() or path.resolve() != Path(expected_path).resolve():
        raise ValueError('Focus sealed path changed')
    with path.open('rb') as stream:
        data = stream.read(16 * 1024 * 1024 + 1)
    if len(data) > 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != value['analysisSealSHA256']:
        raise ValueError('Focus seal/byte budget failed')
    sealed = json.loads(data)
    if (sealed['analysis']['result'] != behavior['result'] or sealed['configuration'] != value['configuration']
            or sealed['eventMap'] != value['eventMap'] or sealed['pauseBridgeStatistics'] != value['pauseBridgeStatistics']):
        raise ValueError('Focus report diverges from pre-label seal')
    if not math.isfinite(value['wholeUnitSeconds']) or value['wholeUnitSeconds'] < 0:
        raise ValueError('Focus elapsed measurement invalid')


def edge_deltas(quality, repository):
    """Post-run comparison only: all24 predictions have already been sealed and evaluated."""
    root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'
    index = json.loads((root / 'index.json').read_text())
    by_id = {case['id']: case for case in index['cases']}
    records = []
    def joined(result, left, right):
        return any(part['range']['first'] <= left and right <= part['range']['last'] for part in result['ranges'])
    def coverage(result):
        return {ordinal: part['state'] for part in result['coverage'] for ordinal in range(part['range']['first'], part['range']['last'] + 1)}
    for case in watch.CASES:
        item = by_id[case]
        manifest = json.loads((root / item['manifestPath']).read_text())
        labels = json.loads((root / item['truthPath']).read_text())
        ordinals = {file['assetID']: file['ordinal'] for file in manifest['files']}
        for association in ('strict', 'assumed'):
            before = next(v for v in quality if v['identity']['caseID'] == case and v['identity']['variant'] == '008B-' + association)
            after = next(v for v in quality if v['identity']['caseID'] == case and v['identity']['variant'] == '009-' + association)
            old_result, new_result = before['behavior']['result'], after['behavior']['result']
            lost, restored, changed_negative = [], [], []
            for group in labels['groups']:
                members = {ordinals[asset] for asset in group['assetIDs']}
                for left in sorted(members):
                    if left + 1 not in members:
                        continue
                    old, new = joined(old_result, left, left+1), joined(new_result, left, left+1)
                    if old and not new: lost.append([left, left+1])
                    if new and not old: restored.append([left, left+1])
            for pair in labels['negativePairs']:
                left, right = ordinals[pair['from']], ordinals[pair['to']]
                old, new = joined(old_result, left, right), joined(new_result, left, right)
                if old != new: changed_negative.append(dict(ordinals=[left, right], beforeMerged=old, afterMerged=new))
            old_e, new_e = before['behavior']['evaluation'], after['behavior']['evaluation']
            exact_losses = [group['id'] for group in old_e['groups'] if group['exactMembershipAndType'] and not any(g['id'] == group['id'] and g['exactMembershipAndType'] for g in new_e['groups'])]
            old_coverage, new_coverage = coverage(old_result), coverage(new_result)
            new_failed = [ordinal for ordinal, state in new_coverage.items() if state in ('unreadable', 'incomplete') and old_coverage.get(ordinal) != state]
            no_regression = (not lost and not exact_losses and not new_failed and set(old_coverage) == set(new_coverage)
                and new_e['unknownCount'] <= old_e['unknownCount'] and new_e['unknownPositivePairs'] <= old_e['unknownPositivePairs']
                and new_e['unknownNegativePairs'] <= old_e['unknownNegativePairs'] and not any(not p['beforeMerged'] and p['afterMerged'] for p in changed_negative))
            records.append(dict(caseID=case, association=association, lostPreviouslyJoinedKnownPositiveEdges=lost,
                restoredKnownPositiveEdges=restored, changedKnownNegativeEdges=changed_negative, lostPreviouslyExactTypedGroups=exact_losses,
                newUnreadableOrIncompleteOrdinals=new_failed, fullFileCoveragePreserved=set(old_coverage) == set(new_coverage),
                noAddedFalseSplitsOrHiddenCoverageFailure=no_regression))
    return dict(schemaVersion=1, meaning='Seen-data strict per-file edge comparison; no independent quality or association proof', comparisons=records,
                noAddedFalseSplits=all(row['noAddedFalseSplitsOrHiddenCoverageFailure'] for row in records))


def main():
    deadline = time.monotonic() + 1800;watch.DEADLINE = deadline
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--test-bundle', required=True, type=Path);parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args();repository = Path(__file__).resolve().parent.parent;bundle = args.test_bundle.resolve(strict=True)
    output = watch.safe_output(args.output, repository, bundle)
    if (repository / 'output').resolve() not in output.parents or (output.exists() and any(output.iterdir())):
        raise ValueError('Fresh ignored local output required')
    output.mkdir(parents=True, exist_ok=True)
    plist = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes());binary = bundle / 'Contents/MacOS' / plist['CFBundleExecutable']
    executable = watch.digest_file(binary);sources = source_snapshot(repository)
    v1, v2, focus = watch.fixture_snapshot(repository), metadata.metadata_snapshot(repository), focus_snapshot(repository)
    observed008 = next(row['sha256'] for row in v2['files'] if row['path'] == 'baselines/behavior-v1.json')
    if (v1['goldenSHA256'] != '0e945e7cf7178793edb91870f5e75af34f8c44e4505c972cb3f5f58acb02f6f3'
            or observed008 != '0b3d5c6d09a35bc655633c5e1633def18bad2fee6eb5cf1b4f253e2991de2dbc'):
        raise ValueError('Approved dev4/008 controls changed before freeze')
    run_id = str(uuid.uuid4());command = ['/usr/bin/xcrun', 'xctest', '-XCTest', SELECTOR, str(bundle)]
    watch.execute(['/usr/bin/xcrun', 'swift', '--version'], os.environ.copy(), output / 'toolchain.log', deadline)
    toolchain = (output / 'toolchain.log').read_text().strip()
    freeze = dict(schemaVersion=1, runID=run_id, sourceSnapshot=sources, fixtures=v1, metadata=v2, focus=focus,
        executableSHA256=executable, command=command, testBundle=str(bundle), swift=toolchain, order=schedule(),
        schedule=dict(bootstrapUnits=6, qualityUnits=24, benchmarkUnits=0, unitSeconds=60, batchSeconds=1800, terminationGraceSeconds=2))
    watch.write_json(output / 'freeze.json', freeze, repository, bundle)
    completed, descriptors = [], {}
    def verify():
        if time.monotonic() >= deadline or source_snapshot(repository) != sources or watch.digest_file(binary) != executable:
            raise RuntimeError('Frozen focus source/binary changed or batch budget expired')
        watch.verify_fixture_controls(repository, v1);metadata.verify_metadata(repository, v2);verify_focus(repository, focus)
    def unit(phase, case, variant=None):
        verify()
        identity = dict(schemaVersion=1, runID=run_id, unitID=str(uuid.uuid4()), phase=phase, caseID=case,
            fixtureIndexSHA256=v1['indexSHA256'], metadataIndexSHA256=v2['indexSHA256'], focusIndexSHA256=focus['indexSHA256'],
            sourceSnapshotSHA256=sources['sha256'], executableSHA256=executable)
        if variant:
            identity.update(variant=variant, expectedPolicyFingerprint=descriptors[case][variant])
        prefix = output / identity['unitID'];control, report = prefix.with_suffix('.control.json'), prefix.with_suffix('.report.json')
        watch.write_json(control, identity, repository, bundle);env = os.environ.copy()
        for key in list(env):
            if key.startswith(('RAWMASTER_SEQUENCE_FIXTURE_', 'RAWMASTER_SPATIAL_EXPERIMENT_', 'RAWMASTER_METADATA_EXPERIMENT_', 'RAWMASTER_PAUSE_OBSERVER_', 'RAWMASTER_FOCUS_EXPERIMENT_')):env.pop(key)
        env.update(RAWMASTER_FOCUS_EXPERIMENT_UNIT=str(control), RAWMASTER_FOCUS_EXPERIMENT_REPORT=str(report), RAWMASTER_SEQUENCE_FIXTURE_SWIFT_VERSION=toolchain)
        wall = watch.execute(command, env, prefix.with_suffix('.log'), deadline)
        value = json.loads(report.read_text());validate_unit(value, identity, watch.CASES[case], str(report) + '.analysis.json', focus)
        if value.get('metadataSnapshotSHA256') != v2['caseSHA256s'][case]:raise ValueError('Actual v2 binding changed')
        if phase != 'bootstrap':value['processWallSeconds'] = wall
        verify();return value
    try:
        for case in watch.CASES:
            record = unit('bootstrap', case)
            names = {row['variant']: row['policyFingerprint'] for row in record['variants']}
            if set(names) != set(VARIANTS) or len(set(names.values())) != 4:raise ValueError('Aliased focus policy controls')
            descriptors[case] = names
            watch.write_json(output / (case + '.descriptor.json'), record, repository, bundle)
        for case, variant in schedule():
            completed.append(unit('quality', case, variant))
            watch.write_json(output / 'progress.json', dict(runID=run_id, completedQualityUnits=len(completed), expectedQualityUnits=24), repository, bundle)
        verify()
        deltas = edge_deltas(completed, repository)
        if watch.fixture_snapshot(repository) != v1 or metadata.metadata_snapshot(repository) != v2 or focus_snapshot(repository) != focus:
            raise RuntimeError('Frozen focus dataset bytes changed')
        watch.write_json(output / 'quality.json', completed, repository, bundle)
        watch.write_json(output / 'edge-deltas.json', deltas, repository, bundle)
        watch.write_json(output / 'complete.json', dict(schemaVersion=1, runID=run_id, complete=True, qualityUnits=24, benchmarkUnits=0,
            qualityAccepted=all(v['topQualityAccepted'] for v in completed), noAddedFalseSplits=deltas['noAddedFalseSplits'],
            sourceSnapshotSHA256=sources['sha256'], focusSnapshotSHA256=focus['sha256']), repository, bundle)
        print('Focus experiment complete24units; noAddedFalseSplits=' + str(deltas['noAddedFalseSplits']) + '; production quality not implied')
    except BaseException as error:
        watch.write_json(output / 'failure.json', dict(schemaVersion=1, runID=run_id, complete=False, completedQualityUnits=len(completed), error=str(error)), repository, bundle)
        raise


def interrupted(signum, _frame):raise KeyboardInterrupt('Signal ' + str(signum))
if __name__ == '__main__':
    for sig in (signal.SIGINT, signal.SIGTERM):signal.signal(sig, interrupted)
    try:main()
    except SystemExit:raise
    except BaseException as error:
        if watch.ACTIVE is not None:watch.stop_group(watch.ACTIVE)
        print('Focus experiment hard error:', str(error), file=sys.stderr);sys.exit(1)
