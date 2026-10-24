#!/usr/bin/env python3
"""Read-only focus/AF availability for all 450 frozen A1M2 originals. No labels, pixels or classifier."""
import argparse
import collections
import decimal
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sys
import time
import uuid

_HELPER = Path(__file__).with_name('audit-sequence-metadata.py')
_spec = importlib.util.spec_from_file_location('sequence_focus_old_audit_helpers', _HELPER)
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)
AuditError, NumberText, parse_json = base.AuditError, base.NumberText, base.parse_json
VERSION = 'sequence-focus-metadata-audit-v1'
NORMALIZER = 'qualified-focus-facts-v1'
HELPER_SHA = 'dc3e68496081614eb846d22ad542cd2989bc7ed6ad1bcc5665004ab4af284b00'
METADATA_INDEX_SHA = 'ec832150d7cf51675f29a3851206e314722fe0d39d2bc0df40cf1761c85b0e36'
REGISTRY_SHA = '98ff3bd7b9fe7d6468a6ecaeb195fbefc291c6ad33d9a11c2243763a1631d399'
AUDIT_SEAL = 'ba663312eec6cfd0aabfcc2837bd39e75fa45f64d4585c63a60c20c4497c3f17'
DEV4_GOLDEN_SHA = '0e945e7cf7178793edb91870f5e75af34f8c44e4505c972cb3f5f58acb02f6f3'
OBSERVED_008_SHA = '0b3d5c6d09a35bc655633c5e1633def18bad2fee6eb5cf1b4f253e2991de2dbc'
CASES = {'burst123': 123, 'burst14-context38': 38, 'burst48-context72': 72, 'burst193-context217': 217}
LIMITS = dict(base.LIMITS, tupleComponents=16)
CANCELLED = False


def check(deadline=float('inf')):
    if CANCELLED:
        raise AuditError('cancelled')
    base.check(deadline)


def hash_file(path, deadline=float('inf')):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        while True:
            check(deadline)
            chunk = stream.read(base.CHUNK)
            if not chunk:
                break
            result.update(chunk)
    check(deadline)
    return result.hexdigest()


def scalar(raw):
    if isinstance(raw, NumberText):
        kind, text = 'number', str(raw)
    elif isinstance(raw, str):
        kind, text = 'string', raw
    else:
        return 'unsupported', None
    # Bound code points before encoding, then bound actual UTF-8 bytes.
    if len(text) > 256 or len(text.encode('utf-8')) > 256:
        raise AuditError('scalarBudget')
    return kind, text


def exact_decimal(text):
    if not isinstance(text, str) or re.fullmatch(r'[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?', text) is None:
        return None
    try:
        value = decimal.Decimal(text)
        return value if value.is_finite() else None
    except decimal.InvalidOperation:
        return None


def canonical_decimal(value):
    # Never Decimal.normalize(): its ambient context can round a long exact fact.
    sign, digits, exponent = value.as_tuple()
    text = ''.join(str(digit) for digit in digits).lstrip('0')
    if not text:
        return '0'
    trimmed = len(text) - len(text.rstrip('0'))
    if trimmed:
        text = text[:-trimmed]
    return ('-' if sign else '') + text + 'e' + str(exponent + trimmed)


def normalize_value(raw, field):
    kind = field['kind']
    transport, text = scalar(raw) if not isinstance(raw, list) else ('array', None)
    result = dict(status='present', transportKind=transport)
    if text is not None:
        result['rawScalarText'] = text
    def invalid(reason):
        result.update(status='invalid', invalidReason=reason)
        return result
    if kind == 'tuple':
        if isinstance(raw, list):
            if len(raw) > 16:
                raise AuditError('tupleComponentBudget')
            components = raw
        elif text is not None:
            components = []
            for match in re.finditer(r'[^ \t\r\n]+', text):
                if len(components) >= 16:
                    raise AuditError('tupleComponentBudget')
                components.append(match.group())
        else:
            return invalid('unsupportedTupleTransport')
        lexemes = []
        numbers = []
        failed = False
        for component in components:
            ckind, ctext = scalar(component)
            lexemes.append(dict(transportKind=ckind, rawLexeme=ctext))
            value = exact_decimal(ctext)
            if value is None or value < 0 or value > 65535 or value != value.to_integral_value():
                failed = True
            else:
                numbers.append(str(int(value)))
        result['rawComponents'] = lexemes
        if len(components) != field['tupleCount']:
            return invalid('tupleCountMismatch')
        if failed:
            return invalid('invalidUnsigned16Component')
        result['tupleCanonical'] = numbers
        return result
    if text is None:
        return invalid('unsupportedScalarTransport')
    if kind == 'code':
        value = exact_decimal(text)
        if value is None or value < 0 or value > 4294967295 or value != value.to_integral_value():
            return invalid('invalidUnsigned32Code')
        result['numericCanonical'] = str(int(value))
        return result
    if kind == 'distance':
        special = text.lower()
        if transport == 'string' and special in ('inf', '+inf', 'infinity', '+infinity', 'undef', 'undefined'):
            result['distanceKind'] = 'undefined' if special in ('undef', 'undefined') else 'infinite'
            return result
        value = exact_decimal(text)
        if value is None or value < 0:
            return invalid('invalidSubjectDistance')
        result['distanceKind'] = 'zero' if value == 0 else 'finite'
        result['numericCanonical'] = canonical_decimal(value)
        return result
    raise AuditError('unsupportedRegistryKind')


def matches(qualified, field):
    parts = qualified.split(':')
    group, tag = field['selector'].split(':', 1)
    wanted = ('MakerNotes', 'Sony') if group == 'Sony' else ('EXIF', 'ExifIFD') if group == 'EXIF' else None
    return wanted is not None and tuple(parts[:2]) == wanted and parts[-1] == tag and (
        len(parts) == 3 or (len(parts) == 4 and re.fullmatch(r'Copy[0-9]+', parts[2]) is not None))


def diagnostic_tag(qualified):
    parts = qualified.split(':')
    if len(parts) < 2 or parts[0] != 'ExifTool' or parts[-1] not in ('Warning', 'Error'):
        return None
    middle = parts[1:-1]
    if middle and middle[0] == 'ExifTool':
        middle = middle[1:]
    return parts[-1] if len(middle) <= 1 and all(re.fullmatch(r'Copy[0-9]+', part) for part in middle) else None


def semantic(value, kind):
    if kind == 'tuple':
        return dict(kind=kind, tupleCanonical=value['tupleCanonical'])
    if kind == 'code':
        return dict(kind=kind, numericCanonical=value['numericCanonical'])
    result = dict(kind=kind, distanceKind=value['distanceKind'])
    if 'numericCanonical' in value:
        result['numericCanonical'] = value['numericCanonical']
    return result


def normalize_tool(data, fields, key, expected_source):
    decoded = parse_json(data)
    if not isinstance(decoded, list) or len(decoded) != 1 or not isinstance(decoded[0], dict):
        raise AuditError('invalidToolShape')
    obj = decoded[0]
    source = obj.pop('SourceFile', None)
    if not isinstance(source, str) or Path(source).resolve() != Path(expected_source).resolve():
        raise AuditError('toolSourceMismatch')
    observed = collections.defaultdict(list)
    warnings = []
    for qualified, raw in obj.items():
        diagnostic = diagnostic_tag(qualified)
        if diagnostic:
            transport, text = base.scalar(raw)
            if diagnostic == 'Error' and text:
                raise AuditError('toolReportedError')
            if diagnostic == 'Warning' and text:
                warnings.append(dict(code='toolWarning', opaqueDigest=base.opaque(key, 'focus-tool-warning', transport, text)))
            continue
        selected = [field for field in fields if matches(qualified, field)]
        if len(selected) != 1:
            raise AuditError('unrequestedToolField')
        observed[selected[0]['fieldID']].append((qualified, raw))
    facts, states, resolved = [], {}, {}
    for field in fields:
        fid = field['fieldID']
        instances = observed[fid]
        if not instances:
            states[fid] = 'absent'
            continue
        unique = {}
        failed = False
        for qualified, raw in instances:
            value = normalize_value(raw, field)
            fact = dict(fieldID=fid, selector=field['selector'], qualifiedKey=qualified,
                possibleDefinitions=[field.get('catalogDefinition', 'unresolved')], runtimeTableResolution='unresolved', **value)
            facts.append(fact)
            if value['status'] != 'present':
                failed = True
            else:
                equivalent = semantic(value, field['kind'])
                unique[base.canonical(equivalent)] = equivalent
        states[fid] = 'invalid' if failed else 'conflicting' if len(unique) != 1 else 'present'
        if states[fid] == 'present':
            # A unique semantic aggregate has no chosen raw transport or authoritative Copy.
            resolved[fid] = next(iter(unique.values()))
    return dict(fields=facts, fieldStates=states, resolved=resolved, warnings=warnings)


def select_scope(records, metadata_cases):
    if len(records) != 1265 or set(metadata_cases) != set(base.CASES):
        raise AuditError('populationChanged')
    by_case = collections.defaultdict(list)
    selected = []
    identities = set()
    for record in records:
        cid, ordinal = record['caseID'], record['ordinal']
        if cid not in base.CASES or (cid, record['assetID']) in identities:
            raise AuditError('sourceMappingMismatch')
        identities.add((cid, record['assetID']))
        by_case[cid].append(record)
        case = metadata_cases[cid]
        if case.get('caseID') != cid or len(case['files']) != base.CASES[cid] or not 0 <= ordinal < len(case['files']):
            raise AuditError('metadataScopeMismatch')
        file = case['files'][ordinal]
        expected_format = {'ARW': 'arw', 'DNG': 'dng', 'JPG': 'jpeg', 'JPEG': 'jpeg'}.get(record['format'])
        if (file['ordinal'] != ordinal or file['assetID'] != record['assetID'] or file['originalSHA256'] != record['expectedHash']
                or file['currentSHA256'] != record['fixtureHash'] or file['originalFormat'] != expected_format):
            raise AuditError('metadataSourceBindingMismatch')
        capture = file['capture']
        if file['originalFormat'] == 'arw' and capture['cameraMake'] == 'SONY' and capture['cameraModel'] == 'ILCE-1M2':
            selected.append(dict(record))
    if ({cid: len(rows) for cid, rows in by_case.items()} != base.CASES
            or [(r['caseID'], r['ordinal']) for r in records] != [(cid, ordinal) for cid, count in base.CASES.items() for ordinal in range(count)]):
        raise AuditError('populationChanged')
    if len(selected) != 450 or dict(collections.Counter(r['caseID'] for r in selected)) != CASES:
        raise AuditError('focusPopulationChanged')
    return selected


def source_verified(record):
    return (record.get('after') is not None and record.get('before') is not None
        and record.get('before') == record.get('after')
        and record.get('beforeHash') == record.get('afterHash') == record['expectedHash'])


def publish_ready(records, metadata_count, failure):
    if (failure is not None or len(records) != 450 or metadata_count != 450
            or dict(collections.Counter(r['caseID'] for r in records)) != CASES
            or len({(r['caseID'], r['assetID']) for r in records}) != 450
            or len({(r['caseID'], r['assetID'], r['ordinal']) for r in records}) != 450
            or [(r['caseID'], r['ordinal']) for r in records] != [(cid, ordinal) for cid, count in CASES.items() for ordinal in range(count)]):
        return False
    by_case = collections.defaultdict(list)
    for record in records:
        by_case[record['caseID']].append(record['ordinal'])
    return all(ordinals == list(range(CASES[cid])) for cid, ordinals in by_case.items()) and all(source_verified(r) for r in records)


def load_inputs(args, source):
    fixture_root = Path(args.fixture_root).resolve()
    metadata_root = Path(args.metadata_root).resolve()
    spec, spec_sha = base.read_control(args.input_spec, base.SPEC_SHA)
    index, index_sha = base.read_control(fixture_root / 'index.json', base.INDEX_SHA)
    metadata_index, metadata_sha = base.read_control(metadata_root / 'index.json', METADATA_INDEX_SHA)
    if (len(spec['cases']) != 6 or {case['id']: len(case['files']) for case in spec['cases']} != base.CASES
            or len(index['cases']) != 6 or {case['id']: case['assetCount'] for case in index['cases']} != base.CASES
            or len(metadata_index['cases']) != 6 or metadata_index['auditSeal'] != AUDIT_SEAL
            or metadata_index['v1IndexSHA256'] != index_sha):
        raise AuditError('populationChanged')
    controls = [dict(role='inputSpec', sha256=spec_sha), dict(role='fixtureIndex', sha256=index_sha), dict(role='metadataIndex', sha256=metadata_sha)]
    indexed = {case['id']: case for case in index['cases']}
    metadata_indexed = {case['id']: case for case in metadata_index['cases']}
    records, metadata_cases = [], {}
    for case in spec['cases']:
        cid = case['id']
        declared = indexed[cid]
        manifest, manifest_sha = base.read_control(base.safe_relative(fixture_root, declared['manifestPath']), declared['manifestSHA256'])
        controls.append(dict(role=cid + 'Manifest', sha256=manifest_sha))
        if len(manifest['files']) != len(case['files']):
            raise AuditError('caseCountMismatch')
        item = metadata_indexed[cid]
        historic, historic_sha = base.read_control(base.safe_relative(metadata_root, item['path']), item['sha256'])
        if historic['caseManifestSHA256'] != manifest_sha or historic['auditSeal'] != AUDIT_SEAL:
            raise AuditError('metadataScopeMismatch')
        controls.append(dict(role=cid + 'HistoricalMetadata', sha256=historic_sha))
        # Keep only binding/model facts. Full public field maps need not stay resident.
        metadata_cases[cid] = dict(caseID=cid, files=[{name: file[name] for name in ('assetID', 'ordinal', 'originalSHA256', 'currentSHA256', 'originalFormat', 'capture')} for file in historic['files']])
        del historic
        for position, (entry, file) in enumerate(zip(case['files'], manifest['files'])):
            expected = case['sourceRelativeRoot'] + '/' + entry['relativePath']
            if entry['ordinal'] != position or file['ordinal'] != position or entry['assetID'] != file['assetID'] or file['sourceCapture']['relativePath'] != expected:
                raise AuditError('sourceMappingMismatch')
            records.append(dict(caseID=cid, assetID=entry['assetID'], ordinal=position, sourceRelativePath=expected,
                expectedHash=file['sourceCapture']['sha256'], fixtureHash=file['jpegSHA256'], format=Path(expected).suffix[1:].upper(),
                before=None, beforeHash=None, after=None, afterHash=None))
        # Bind old human-truth bytes without interpreting them as input to this audit.
        truth_sha = hash_file(base.safe_relative(fixture_root, declared['truthPath']))
        if truth_sha != declared['truthSHA256']:
            raise AuditError('frozenTruthBytesChanged')
        controls.append(dict(role=cid + 'TruthBytesOnly', sha256=truth_sha))
    for role, path, expected in [('dev4Golden', fixture_root / 'baselines/behavior-v1.json', DEV4_GOLDEN_SHA),
                                 ('observed008Behavior', metadata_root / 'baselines/behavior-v1.json', OBSERVED_008_SHA)]:
        actual = hash_file(path)
        if actual != expected:
            raise AuditError('frozenBehaviorBytesChanged')
        controls.append(dict(role=role, sha256=actual))
    selected = select_scope(records, metadata_cases)
    for record in selected:
        record['path'] = base.safe_relative(source, record['sourceRelativePath'])
    return selected, controls


def tool_command(perl, tool, fields, source):
    return [str(perl), str(tool), '-config', '', '-j', '-n', '-a', '-G0:1:4'] + ['-' + field['selector'] for field in fields] + ['-' + name for name in base.DIAGNOSTIC_SELECTORS] + [str(source)]


def rows(stage, records, writer):
    provisional = stage / 'provisional.jsonl'
    handle = provisional.open('rb') if provisional.exists() else None
    pending = json.loads(handle.readline()) if handle and provisional.stat().st_size else None
    with (stage / 'assets.jsonl').open('xb') as output, (stage / 'local-proof.jsonl').open('xb') as proof:
        for record in records:
            data = None
            if pending and (pending['caseID'], pending['assetID']) == (record['caseID'], record['assetID']):
                data = pending
                line = handle.readline()
                pending = json.loads(line) if line else None
            verified = source_verified(record)
            row = dict(schemaVersion=1, caseID=record['caseID'], assetID=record['assetID'], ordinal=record['ordinal'],
                status='complete' if data and verified else 'afterUnverified' if data else 'notRead',
                sourceIdentity=dict(sha256=record['expectedHash'], format='ARW', formatBasis='historical-sealed-audit02-v2; no new native-container selector'),
                fixtureIdentity=dict(sha256=record['fixtureHash'], binding='frozen-v1-manifest-and-v2-supplement'),
                sourceIntegrity=dict(beforeSHA256=record['beforeHash'], afterSHA256=record['afterHash'], credentialUnchanged=verified, matchesFixtureProvenance=verified))
            if data:
                row.update(data)
            writer.line(output, row)
            writer.line(proof, dict(caseID=record['caseID'], assetID=record['assetID'], before=record['before'], after=record['after'], beforeSHA256=record['beforeHash'], afterSHA256=record['afterHash']))
    if handle:
        handle.close()
    provisional.unlink(missing_ok=True)


def run(args):
    repository = Path(__file__).resolve().parent.parent
    started = time.monotonic()
    deadline = started + LIMITS['jobSeconds']
    source, output, key_path = base.guard_paths(args.source_base, args.output, args.key_file, repository, args.tool_root)
    if Path(args.perl).resolve() != Path('/usr/bin/perl').resolve():
        raise AuditError('unsupportedPerlInterpreter')
    registry, registry_sha = base.read_control(args.field_registry, REGISTRY_SHA)
    if (registry['schemaVersion'] != 1 or registry.get('diagnosticSelectors') != list(base.DIAGNOSTIC_SELECTORS)
            or registry.get('normalizerVersion') != NORMALIZER or len(registry['fields']) != 12
            or len({field['selector'] for field in registry['fields']}) != 12):
        raise AuditError('registryInvalid')
    records, controls = load_inputs(args, source)
    if not key_path.is_file():
        raise AuditError('existingAuditKeyRequired')
    key_before = base.credential(key_path)
    key, key_id = base.load_key(key_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    base.guard_paths(source, output, key_path, repository, args.tool_root)
    stage = output.with_name('.' + output.name + '.staging-' + uuid.uuid4().hex)
    stage.mkdir(mode=0o700)
    writer = base.ArtifactWriter()
    measurement = dict(childRSSSamples=0, childPeakRSSBytes=None, metadataSeconds=0.0, beforeHashSeconds=0.0, afterHashSeconds=0.0)
    script_sha = hash_file(Path(__file__), deadline)
    helper_sha = hash_file(_HELPER, deadline)
    python_path = Path(sys.executable).resolve()
    python_sha = hash_file(python_path, deadline)
    if helper_sha != HELPER_SHA:
        raise AuditError('oldAuditHelperChanged')
    parser, failure, metadata_count = None, None, 0
    field_stats = collections.defaultdict(collections.Counter)
    try:
        parser = base.verify_tool(Path(args.tool_root).resolve(), Path(args.perl).resolve(), registry, deadline, measurement)
        phase = time.monotonic()
        for record in records:
            check(deadline)
            before = base.credential(record['path'])
            hashed = hash_file(record['path'], deadline)
            if base.credential(record['path']) != before or hashed != record['expectedHash']:
                raise AuditError('sourceBeforeMismatch')
            record.update(before=before, beforeHash=hashed)
        measurement['beforeHashSeconds'] = time.monotonic() - phase
        metadata_started = time.monotonic()
        with (stage / 'provisional.jsonl').open('xb') as provisional:
            for record in records:
                check(deadline)
                if base.credential(record['path']) != record['before']:
                    raise AuditError('sourceBeforeMetadataChanged')
                raw = base.run_child(tool_command(args.perl, Path(args.tool_root) / 'exiftool', registry['fields'], record['path']), deadline, measurement)
                data = normalize_tool(raw, registry['fields'], key, record['path'])
                del raw
                if base.credential(record['path']) != record['before']:
                    raise AuditError('sourceDuringMetadataChanged')
                data.update(caseID=record['caseID'], assetID=record['assetID'], ordinal=record['ordinal'])
                # Leave bounded space for source-proof fields added in the final streamed row.
                if len(base.canonical(data)) > LIMITS['rowBytes'] - 2048:
                    raise AuditError('rowBudget')
                writer.line(provisional, data)
                metadata_count += 1
                for fid, state in data['fieldStates'].items():
                    field_stats[(record['caseID'], fid)][state] += 1
                if metadata_count % 100 == 0:
                    print('Focus metadata rows:', metadata_count, '/ 450', flush=True)
        measurement['metadataPhaseWallSeconds'] = time.monotonic() - metadata_started
        phase = time.monotonic()
        for record in records:
            check(deadline)
            if base.credential(record['path']) != record['before']:
                raise AuditError('sourceBeforeAfterHashChanged')
            hashed = hash_file(record['path'], deadline)
            after = base.credential(record['path'])
            if after != record['before'] or hashed != record['beforeHash']:
                raise AuditError('sourceAfterMismatch')
            record.update(after=after, afterHash=hashed)
        measurement['afterHashSeconds'] = time.monotonic() - phase
        _, controls_after = load_inputs(args, source)
        if (controls != controls_after or hash_file(Path(__file__), deadline) != script_sha
                or hash_file(_HELPER, deadline) != helper_sha or hash_file(args.field_registry, deadline) != registry_sha
                or hash_file(python_path, deadline) != python_sha):
            raise AuditError('auditControlsChanged')
        if base.verify_tool(Path(args.tool_root).resolve(), Path(args.perl).resolve(), registry, deadline, measurement) != parser:
            raise AuditError('parserClosureChanged')
        if base.credential(key_path) != key_before:
            raise AuditError('auditKeyChanged')
        with key_path.open('rb') as key_input:
            if key_input.read(33) != key:
                raise AuditError('auditKeyChanged')
        for record in records:
            if base.credential(record['path']) != record['before']:
                raise AuditError('sourceFinalStatChanged')
        check(deadline)
    except Exception as error:
        failure = error.code if isinstance(error, AuditError) else 'focusAuditExecutionFailure'
    rows(stage, records, writer)
    writer.write(stage / 'availability.json', dict(schemaVersion=1, requested=450, metadataRows=metadata_count,
        caseRequestedCounts=CASES, fields=[dict(caseID=cid, fieldID=fid, counts=dict(counts)) for (cid, fid), counts in sorted(field_stats.items())],
        meaning='Availability only. No coordinate normalization, subject/AF success proof, distance-unit reinterpretation or grouping decision.'))
    if failure is None and not publish_ready(records, metadata_count, failure):
        failure = 'incompleteSourceOrMetadataProof'
    if failure is None:
        failure = base.gate_failure(deadline) or ('cancelled' if CANCELLED else None)
    ready = publish_ready(records, metadata_count, failure)
    measurement['wrapperPeakRSSBytes'] = base.wrapper_peak_bytes()
    receipt = dict(schemaVersion=1, tool=VERSION, normalizerVersion=NORMALIZER, status='complete' if ready else 'partial', analysisReady=ready,
        requested=450, metadataRows=metadata_count, sourceVerified=sum(source_verified(record) for record in records), failureCode=failure,
        controls=controls, registrySHA256=registry_sha, scriptSHA256=script_sha, oldAuditHelperSHA256=helper_sha,
        parser=parser, python=dict(executableSHA256=python_sha, version=sys.version), keyID=key_id, historicalAuditSeal=AUDIT_SEAL,
        limits=LIMITS, measurements=measurement, totalSeconds=time.monotonic() - started,
        rowsSHA256=base.hash_artifact(stage / 'assets.jsonl'), availabilitySHA256=base.hash_artifact(stage / 'availability.json'),
        sourceReads='selected still-image metadata and whole-file integrity hashes only; no preview/render',
        argvTemplate=['perl', 'PINNED_TOOL', '-config', '', '-j', '-n', '-a', '-G0:1:4'] + ['-' + field['selector'] for field in registry['fields']] + ['-' + name for name in base.DIAGNOSTIC_SELECTORS] + ['APPROVED_SOURCE_FILE'],
        labelsRead=False, identityCandidatesRequested=False, nativeDeviceIdentityVerified=False, captureAssociationVerified=False,
        wrapperMemoryBoundary='Sampled wrapper high-water RSS ceiling at checkpoints, not an OS allocator hard cap',
        runtimeTableIdentity='unresolved; group-qualified instances do not prove firmware/internal decoder table',
        fieldMeaning='Bounded parser facts only; unknown enum values retained, coordinate validity/units/AF intent unverified')
    if ready:
        base.guard_paths(source, output, key_path, repository, args.tool_root)
        final_failure = base.gate_failure(deadline) or ('cancelled' if CANCELLED else None)
        if final_failure:
            ready = False
            receipt.update(status='partial', analysisReady=False, failureCode=final_failure)
    receipt['factsSealSHA256'] = base.digest(base.canonical(receipt))
    writer.write(stage / 'receipt.json', receipt)
    if ready:
        final_failure = base.gate_failure(deadline) or ('cancelled' if CANCELLED else None)
        if final_failure:
            ready = False
            receipt.pop('factsSealSHA256')
            receipt.update(status='partial', analysisReady=False, failureCode=final_failure)
            receipt['factsSealSHA256'] = base.digest(base.canonical(receipt))
            (stage / 'receipt.json').unlink()
            writer.write(stage / 'receipt.json', receipt)
    destination = output if ready else output.with_name(output.name + '.partial-' + uuid.uuid4().hex)
    base.guard_paths(source, destination, key_path, repository, args.tool_root)
    base.atomic_publish(stage, destination)
    print('Focus audit complete:450 verified' if ready else 'Focus audit partial; analysisReady=false; code=' + str(receipt['failureCode']))
    return 0 if ready else 2


def main():
    repository = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-spec', default=str(repository / 'Tests/Fixtures/SequenceGroupingInputs/v1/cases.json'))
    parser.add_argument('--fixture-root', default=str(repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'))
    parser.add_argument('--metadata-root', default=str(repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingMetadata/v2'))
    parser.add_argument('--field-registry', default=str(Path(__file__).with_name('sequence-focus-fields-v1.json')))
    parser.add_argument('--source-base', required=True)
    parser.add_argument('--tool-root', required=True)
    parser.add_argument('--perl', default='/usr/bin/perl')
    parser.add_argument('--key-file', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    def interrupted(_signal, _frame):
        global CANCELLED
        if not CANCELLED:
            CANCELLED = True
            # Unwinds old helper child through its existing bounded finally cleanup.
            raise AuditError('cancelled')
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, interrupted)
    try:
        return run(args)
    except Exception as error:
        print('Focus audit failed:', error.code if isinstance(error, AuditError) else 'focusAuditPreflightOrPublicationFailure', '; no analysis-ready publication', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
