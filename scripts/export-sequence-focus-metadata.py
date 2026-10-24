#!/usr/bin/env python3
"""Additive full-file focus supplement from sealed audit/v1/v2 JSON. No originals, pixels or labels."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import uuid

_spec = importlib.util.spec_from_file_location('focus_export_old_helpers', Path(__file__).with_name('export-sequence-metadata.py'))
old = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(old)
VERSION = 'sequence-focus-export-v1'
RECIPE = 'focus-audit-to-current-jpeg-v1'
FOCUS_SEAL = 'b3ad33d4409ddf885d4ccff21da57e30d3c688d9087332ff2ceb3fabce48bec3'
FOCUS_ROWS = '1c2880c6a3e61e032b695843fae7f2ee0b25b9a5c3135b6ca46166e01c198719'
FOCUS_REGISTRY = '98ff3bd7b9fe7d6468a6ecaeb195fbefc291c6ad33d9a11c2243763a1631d399'
FOCUS_NORMALIZER = 'qualified-focus-facts-v1'
METADATA_INDEX = 'ec832150d7cf51675f29a3851206e314722fe0d39d2bc0df40cf1761c85b0e36'
AUDITED_CASES = {'burst123': 123, 'burst14-context38': 38, 'burst48-context72': 72, 'burst193-context217': 217}
TUPLES = {'sony.FocusLocation': 4, 'sony.FocusLocation2': 4, 'sony.FocusFrameSize': 3, 'sony.FlexibleSpotPosition': 2}
CODES = {'sony.FocusMode', 'sony.AFAreaModeSetting', 'sony.AFAreaMode', 'sony.AFPointSelected', 'sony.AFTracking', 'sony.FocusPosition2', 'sony.CameraOrientation'}
FIELDS = set(TUPLES) | CODES | {'exif.SubjectDistance'}


def read(path, maximum=8 * 1024 * 1024):
    return old.read(path, maximum)


def uint(value, maximum):
    if not isinstance(value, str) or not value.isascii() or not value.isdigit() or len(value) > 10:
        raise ValueError('Noncanonical unsigned focus fact')
    number = int(value)
    if number > maximum or str(number) != value:
        raise ValueError('Unsigned focus fact out of range')
    return number


def curate(row, source, ordinal):
    capture = source['capture']
    audited = source['originalFormat'] == 'arw' and capture['cameraMake'] == 'SONY' and capture['cameraModel'] == 'ILCE-1M2'
    result = dict(assetID=source['assetID'], ordinal=ordinal, currentSHA256=source['currentSHA256'], originalSHA256=source['originalSHA256'],
        state='audited' if audited else 'outsideAuditedCohort', fieldStates={}, resolvedCodes={}, resolvedTuples={}, qualifiedFieldSources={}, auditWarningCount=None)
    if not audited:
        if row is not None:
            raise ValueError('Unaudited file cannot carry focus facts')
        return result
    if row is None or row['assetID'] != source['assetID'] or row['ordinal'] != ordinal or row['status'] != 'complete':
        raise ValueError('Focus audit row identity/status')
    proof = row['sourceIntegrity']
    if not proof['credentialUnchanged'] or not proof['matchesFixtureProvenance'] or proof['beforeSHA256'] != proof['afterSHA256'] or proof['beforeSHA256'] != source['originalSHA256']:
        raise ValueError('Incomplete focus original proof')
    if row['sourceIdentity']['sha256'] != source['originalSHA256'] or row['fixtureIdentity']['sha256'] != source['currentSHA256']:
        raise ValueError('Focus original/current content binding')
    states, resolved = row['fieldStates'], row['resolved']
    if set(states) != FIELDS or any(state not in ('present', 'absent', 'invalid', 'conflicting') for state in states.values()):
        raise ValueError('Unexpected focus field schema')
    if set(resolved) != {field for field, state in states.items() if state == 'present'} or states['exif.SubjectDistance'] != 'absent':
        raise ValueError('Unsupported distance or unusable focus aggregate promoted')
    qualified = {field: [] for field in FIELDS}
    for fact in row['fields']:
        if fact['fieldID'] not in FIELDS:
            raise ValueError('Unexpected focus instance')
        qualified[fact['fieldID']].append(fact['qualifiedKey'])
    for field, state in states.items():
        if (state == 'absent') != (not qualified[field]):
            raise ValueError('Focus field availability/source mismatch')
        if state != 'present':
            continue
        value = resolved[field]
        if field in CODES and value.get('kind') == 'code':
            result['resolvedCodes'][field] = uint(value['numericCanonical'], 4294967295)
        elif field in TUPLES and value.get('kind') == 'tuple':
            vector = value['tupleCanonical']
            if not isinstance(vector, list) or len(vector) != TUPLES[field]:
                raise ValueError('Focus tuple shape')
            result['resolvedTuples'][field] = [uint(component, 65535) for component in vector]
        else:
            raise ValueError('Focus aggregate kind mismatch')
    result.update(fieldStates=states, qualifiedFieldSources={field: sorted(values) for field, values in qualified.items()}, auditWarningCount=len(row['warnings']))
    return result


def verify_audit(audit, repository):
    receipt, _ = read(audit / 'receipt.json')
    claimed = receipt.pop('factsSealSHA256')
    if (claimed != FOCUS_SEAL or old.digest(old.canonical(receipt)) != claimed or receipt['status'] != 'complete'
            or receipt['analysisReady'] is not True or [receipt[k] for k in ('requested', 'metadataRows', 'sourceVerified')] != [450] * 3
            or receipt['normalizerVersion'] != FOCUS_NORMALIZER or receipt['registrySHA256'] != FOCUS_REGISTRY
            or receipt['historicalAuditSeal'] != old.AUDIT_SEAL or receipt['rowsSHA256'] != FOCUS_ROWS):
        raise ValueError('Complete accepted focus audit required')
    if old.sha(audit / 'assets.jsonl') != FOCUS_ROWS or old.sha(audit / 'availability.json') != receipt['availabilitySHA256']:
        raise ValueError('Focus audit artifacts changed')
    for relative, expected in [('scripts/audit-sequence-focus-metadata.py', receipt['scriptSHA256']),
                               ('scripts/sequence-focus-fields-v1.json', FOCUS_REGISTRY),
                               ('scripts/audit-sequence-metadata.py', receipt['oldAuditHelperSHA256'])]:
        if old.sha(repository / relative) != expected:
            raise ValueError('Focus audit definition changed')
    return receipt


def run(args):
    repository = Path(__file__).resolve().parent.parent
    audit, v1, v2, output = [Path(value).resolve() for value in (args.audit, args.v1, args.v2, args.output)]
    protected = (audit, v1, v2, repository / 'Tests/Fixtures/SequenceGroupingInputs')
    if any(old.overlap(output, root) for root in protected) or output.exists():
        raise ValueError('Focus export must be additive and separate from frozen inputs')
    receipt = verify_audit(audit, repository)
    controls = {row['role']: row['sha256'] for row in receipt['controls']}
    index, index_sha = read(v1 / 'index.json')
    metadata, metadata_sha = read(v2 / 'index.json')
    if (index_sha != controls['fixtureIndex'] or metadata_sha != METADATA_INDEX or metadata_sha != controls['metadataIndex']
            or metadata['auditSeal'] != old.AUDIT_SEAL or metadata['v1IndexSHA256'] != index_sha
            or len(index['cases']) != 6 or {case['id']: case['assetCount'] for case in index['cases']} != old.CASES
            or len(metadata['cases']) != 6 or {case['id']: case['assetCount'] for case in metadata['cases']} != old.CASES):
        raise ValueError('Frozen v1/v2 scope changed')
    by_id = {case['id']: case for case in metadata['cases']}
    stage = repository / 'output' / ('.focus-export-' + uuid.uuid4().hex)
    stage.mkdir(parents=True, mode=0o700)
    (stage / 'cases').mkdir()
    output_cases = []
    used = set()
    audited_counts = {}
    before = [(v1 / 'index.json', index_sha), (v2 / 'index.json', metadata_sha)]
    with (audit / 'assets.jsonl').open('rb') as rows:
        for item in index['cases']:
            cid = item['id']
            v2item = by_id[cid]
            manifest_path = old.relative(v1, item['manifestPath'])
            manifest, manifest_sha = read(manifest_path)
            historic_path = old.relative(v2, v2item['path'])
            historic, historic_sha = read(historic_path)
            before.extend([(manifest_path, manifest_sha), (historic_path, historic_sha)])
            if (manifest_sha != item['manifestSHA256'] or manifest_sha != controls[cid + 'Manifest']
                    or historic_sha != v2item['sha256'] or historic_sha != controls[cid + 'HistoricalMetadata']
                    or historic['caseManifestSHA256'] != manifest_sha or historic['auditSeal'] != old.AUDIT_SEAL
                    or len(manifest['files']) != item['assetCount'] or len(historic['files']) != item['assetCount']):
                raise ValueError('Frozen case lineage changed')
            files = []
            audited_count = 0
            for ordinal, (source, declared) in enumerate(zip(historic['files'], manifest['files'])):
                if (source['assetID'] != declared['assetID'] or source['ordinal'] != ordinal or declared['ordinal'] != ordinal
                        or source['originalSHA256'] != declared['sourceCapture']['sha256'] or source['currentSHA256'] != declared['jpegSHA256']):
                    raise ValueError('Full-file source binding changed')
                is_audited = (source['originalFormat'] == 'arw' and source['capture']['cameraMake'] == 'SONY'
                    and source['capture']['cameraModel'] == 'ILCE-1M2')
                row = None
                if is_audited:
                    line = rows.readline(65537)
                    if not line or len(line) > 65536:
                        raise ValueError('Focus audit row coverage/budget')
                    row = json.loads(line)
                    key = (cid, source['assetID'])
                    if key in used or (row['caseID'], row['assetID']) != key:
                        raise ValueError('Focus original order/identity changed')
                    used.add(key)
                    audited_count += 1
                files.append(curate(row, source, ordinal))
            if audited_count:
                audited_counts[cid] = audited_count
            case = dict(schemaVersion=1, recipeVersion=RECIPE, caseID=cid, focusAuditSeal=FOCUS_SEAL,
                focusRowsSHA256=FOCUS_ROWS, focusRegistrySHA256=FOCUS_REGISTRY, normalizerVersion=FOCUS_NORMALIZER,
                metadataV2IndexSHA256=metadata_sha, metadataSnapshotFingerprint=historic_sha, v1IndexSHA256=index_sha,
                caseManifestSHA256=manifest_sha, files=files)
            relative = 'cases/' + cid + '.json'
            case_sha = old.write(stage / relative, case)
            output_cases.append(dict(id=cid, assetCount=len(files), auditedAssetCount=audited_count, path=relative,
                sha256=case_sha, metadataSnapshotFingerprint=historic_sha, caseManifestSHA256=manifest_sha))
        if rows.read(1) or len(used) != 450 or audited_counts != AUDITED_CASES:
            raise ValueError('Incomplete/extra focus cohort')
    output_index = dict(schemaVersion=1, datasetID='sequence-focus-metadata-v1', recipeVersion=RECIPE,
        exporterVersion=VERSION, exporterSHA256=old.sha(Path(__file__)), focusAuditSeal=FOCUS_SEAL,
        focusRowsSHA256=FOCUS_ROWS, focusRegistrySHA256=FOCUS_REGISTRY, normalizerVersion=FOCUS_NORMALIZER,
        metadataV2IndexSHA256=metadata_sha, v1IndexSHA256=index_sha, assetCount=1265, auditedAssetCount=450,
        outsideAuditedCohortCount=815, cases=output_cases)
    old.write(stage / 'index.json', output_index)
    (stage / 'README.md').write_text('''# Focus metadata research supplement v1

All 1,265 file identities and original order are retained. Exactly 450 A1M2 originals were audited with the separate sealed focus audit; 815 other files are explicitly outsideAuditedCohort with no requested field states, values or new verification claim. This is historical original metadata bound to current JPEG content, not repaired JPEG EXIF or an exposure/subject identity proof.

Audited rows retain all requested aggregate field states and all qualified instance sources. Only usable canonical uint codes/tuples are exported; conflicting/invalid facts are never resolved by picking a copy. SubjectDistance is absent throughout this fixed audit. The original audit retains transport lexemes. Focus-frame availability, reference agreement and tracking codes do not establish subject identity or coordinate units. Image-centre fallback remains unknown. No warnings, private identifiers, original paths, labels, pixels or learned features are exported.

The case fingerprint is its exact exported byte SHA. Runtime consumers additionally bind the actual full focus/v2/manifest values. Existing v1/v2/dev4/007/008 data and behavioral baselines are unchanged. All samples are seen development data; this fixture and regression equality do not approve production quality or automatic import.
''')
    if verify_audit(audit, repository) != receipt or any(old.sha(path) != expected for path, expected in before):
        raise ValueError('Focus export inputs changed')
    output.parent.mkdir(parents=True, exist_ok=True)
    old.publish(stage, output)
    print('Published1265 bound focus rows:450audited,815outside; old fixtures unchanged')


def main():
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--audit', required=True)
    parser.add_argument('--v1', default=str(repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'))
    parser.add_argument('--v2', default=str(repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'))
    parser.add_argument('--output', default=str(repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingFocus/v1'))
    try:
        run(parser.parse_args())
        return 0
    except Exception as error:
        print('Focus export failed:', type(error).__name__, '; no successful publication', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
