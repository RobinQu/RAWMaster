"""Synthetic focus-audit contracts. No original files, ExifTool, Swift or classifier calls."""
import copy
import decimal
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/audit-sequence-focus-metadata.py'
SPEC = importlib.util.spec_from_file_location('focus_audit_under_test', SCRIPT)
focus = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(focus)


def field(kind='tuple', count=4, name='FocusLocation'):
    result = dict(fieldID='sony.' + name, selector='Sony:' + name, kind=kind)
    if kind == 'tuple':
        result['tupleCount'] = count
    return result


def code(value):
    return focus.NumberText(str(value))


class FocusMetadataValueTests(unittest.TestCase):
    def test_all_four_tuple_shapes_preserve_order_transport_and_lexemes(self):
        for name, count in [('FocusLocation', 4), ('FocusLocation2', 4),
                            ('FocusFrameSize', 3), ('FlexibleSpotPosition', 2)]:
            with self.subTest(name=name):
                lexemes = ['0001', '2', '3', '4'][:count]
                raw = '  ' + '  '.join(lexemes) + '  '
                result = focus.normalize_value(raw, field(count=count, name=name))
                self.assertEqual(result['status'], 'present')
                self.assertEqual(result['transportKind'], 'string')
                self.assertEqual(result['rawScalarText'], raw)
                self.assertEqual([x['rawLexeme'] for x in result['rawComponents']], lexemes)
                self.assertEqual(result['tupleCanonical'], [str(i) for i in range(1, count + 1)])
                values = [code('1e0'), '0002', code('3.0'), code('4')][:count]
                array = focus.normalize_value(values, field(count=count, name=name))
                self.assertEqual(array['status'], 'present')
                self.assertEqual(array['transportKind'], 'array')
                self.assertEqual([x['transportKind'] for x in array['rawComponents']],
                                 ['number', 'string', 'number', 'number'][:count])
                self.assertEqual([x['rawLexeme'] for x in array['rawComponents']],
                                 ['1e0', '0002', '3.0', '4'][:count])
                self.assertEqual(array['tupleCanonical'], result['tupleCanonical'])

    def test_tuple_uint16_boundaries_and_focus_frame_validity_are_not_interpreted(self):
        bounds = focus.normalize_value('0 65535 0 65535', field())
        self.assertEqual(bounds['tupleCanonical'], ['0', '65535', '0', '65535'])
        for marker in ('0', '1', '257', '65535'):
            with self.subTest(marker=marker):
                value = focus.normalize_value('100 80 ' + marker, field(count=3, name='FocusFrameSize'))
                self.assertEqual(value['status'], 'present')
                self.assertEqual(value['tupleCanonical'], ['100', '80', marker])
        # Zero and image-centre coordinates remain exact facts, never a subject assertion.
        self.assertEqual(focus.normalize_value('6000 4000 3000 2000', field())['tupleCanonical'],
                         ['6000', '4000', '3000', '2000'])

    def test_malformed_tuple_is_invalid_without_flattening_padding_or_scalar_coercion(self):
        invalid = ['', '1 2 3', '1 2 3 4 5', '1 2 -1 4', '1 2 65536 4',
                   '1 2 3.5 4', '1,2,3,4', '1 2 NaN 4', '1 2 inf 4',
                   [code(1), [code(2)], code(3), code(4)],
                   [code(1), {'x': code(2)}, code(3), code(4)],
                   [code(1), True, code(3), code(4)],
                   [code(1), None, code(3), code(4)],
                   code(1234), True, None, {'x': 1}]
        for raw in invalid:
            with self.subTest(raw=repr(raw)):
                value = focus.normalize_value(raw, field())
                self.assertEqual(value['status'], 'invalid')
                self.assertTrue(value.get('invalidReason'))
                self.assertIsNone(value.get('tupleCanonical'))

    def test_vector_component_and_scalar_budgets_fail_hard(self):
        for raw in (['0'] * 17, ' '.join(['0'] * 17), '1' * 257,
                    ['0', '0', '0', '1' * 257]):
            with self.subTest(raw_type=type(raw).__name__):
                with self.assertRaises(focus.AuditError):
                    focus.normalize_value(raw, field())
        with self.assertRaises(focus.AuditError):
            focus.normalize_value('1' * 257, field(kind='code', name='AFTracking'))

    def test_af_codes_are_exact_unsigned32_and_unknown_values_are_raw_facts(self):
        for token, canonical in [('0', '0'), ('3', '3'), ('4.0', '4'),
                                 ('1e2', '100'), ('4294967295', '4294967295')]:
            with self.subTest(token=token):
                value = focus.normalize_value(code(token), field(kind='code', name='AFTracking'))
                self.assertEqual(value['status'], 'present')
                self.assertEqual(value['numericCanonical'], canonical)
                self.assertEqual(value['rawScalarText'], token)
                self.assertEqual(value['transportKind'], 'number')
        for raw in ('-1', '4294967296', '1.1', 'NaN', 'inf', 'AF-C',
                    True, None, [code(3)], {'value': 3}):
            with self.subTest(raw=repr(raw)):
                self.assertEqual(focus.normalize_value(raw, field(kind='code', name='FocusMode'))['status'], 'invalid')
        exact = focus.normalize_value('0003', field(kind='code', name='FocusMode'))
        self.assertEqual(exact['transportKind'], 'string')
        self.assertEqual(exact['rawScalarText'], '0003')
        self.assertEqual(exact['numericCanonical'], '3')

    def test_subject_distance_keeps_zero_infinity_and_undefined_distinct(self):
        distance = dict(fieldID='exif.SubjectDistance', selector='EXIF:SubjectDistance', kind='distance')
        expected = [('0', 'zero'), ('0.0', 'zero'), ('0.123456789123456789', 'finite'),
                    ('inf', 'infinite'), ('infinity', 'infinite'),
                    ('undef', 'undefined'), ('undefined', 'undefined')]
        for raw, category in expected:
            with self.subTest(raw=raw):
                value = focus.normalize_value(raw, distance)
                self.assertEqual(value['status'], 'present')
                self.assertEqual(value['distanceKind'], category)
                self.assertEqual(value['rawScalarText'], raw)
                if category in ('infinite', 'undefined'):
                    self.assertIsNone(value.get('numericCanonical'))
                else:
                    self.assertEqual(decimal.Decimal(value['numericCanonical']), decimal.Decimal(raw))
        for token in ('1e1000', '1e-1000'):
            with self.subTest(exact_finite=token):
                value = focus.normalize_value(code(token), distance)
                self.assertEqual(value['status'], 'present')
                self.assertEqual(value['distanceKind'], 'finite')
                self.assertEqual(value['rawScalarText'], token)
                self.assertEqual(decimal.Decimal(value['numericCanonical']), decimal.Decimal(token))
                self.assertNotEqual(decimal.Decimal(value['numericCanonical']), 0)
        for raw in ('-1', '-inf', 'NaN', 'not measured', True, None, [], {}):
            with self.subTest(invalid=repr(raw)):
                self.assertEqual(focus.normalize_value(raw, distance)['status'], 'invalid')


class FocusMetadataToolContracts(unittest.TestCase):
    source = '/synthetic-approved-source/input.arw'

    def registry(self):
        value = json.loads((ROOT / 'scripts/sequence-focus-fields-v1.json').read_text())
        return value['fields']

    def normalized(self, values, fields=None):
        payload = json.dumps([dict(SourceFile=self.source, **values)]).encode()
        return focus.normalize_tool(payload, fields or self.registry(), b'k' * 32, self.source)

    def test_equivalent_instances_resolve_but_conflict_and_invalid_copies_never_do(self):
        first = 'MakerNotes:Sony:FocusLocation'
        second = 'MakerNotes:Sony:Copy1:FocusLocation'
        same = self.normalized({first: '0001 2 3 4', second: [1, 2, 3, 4]})
        fid = 'sony.FocusLocation'
        self.assertEqual(same['fieldStates'][fid], 'present')
        self.assertEqual(same['resolved'][fid]['tupleCanonical'], ['1', '2', '3', '4'])
        facts = [x for x in same['fields'] if x['fieldID'] == fid]
        self.assertEqual(len(facts), 2)
        self.assertEqual({x['qualifiedKey'] for x in facts}, {first, second})
        conflict = self.normalized({first: '1 2 3 4', second: '1 2 4 3'})
        self.assertEqual(conflict['fieldStates'][fid], 'conflicting')
        self.assertNotIn(fid, conflict['resolved'])
        invalid = self.normalized({first: '1 2 3 4', second: '1 2 3'})
        self.assertEqual(invalid['fieldStates'][fid], 'invalid')
        self.assertNotIn(fid, invalid['resolved'])
        self.assertEqual(len([x for x in invalid['fields'] if x['fieldID'] == fid]), 2)

    def test_tool_parser_preserves_actual_numeric_token_and_all_absences(self):
        payload = ('[{"SourceFile":"' + self.source + '",'
                   '"MakerNotes:Sony:FocusMode":3.0,'
                   '"MakerNotes:Sony:FocusLocation":[1e0,2,3,4]}]').encode()
        value = focus.normalize_tool(payload, self.registry(), b'k' * 32, self.source)
        mode = next(x for x in value['fields'] if x['fieldID'] == 'sony.FocusMode')
        location = next(x for x in value['fields'] if x['fieldID'] == 'sony.FocusLocation')
        self.assertEqual(mode['rawScalarText'], '3.0')
        self.assertEqual(location['rawComponents'][0]['rawLexeme'], '1e0')
        self.assertEqual(value['fieldStates']['sony.FocusLocation2'], 'absent')
        self.assertNotIn('sony.FocusLocation2', value['resolved'])
        self.assertNotIn('exif.SubjectDistance', value['resolved'])
        absent = self.normalized({})
        self.assertEqual(set(absent['fieldStates'].values()), {'absent'})
        self.assertEqual(absent['resolved'], {})

    def test_unknown_qualified_fields_wrong_namespace_and_errors_fail_closed(self):
        for values in ({'EXIF:GPS:GPSLatitude': 1}, {'MakerNotes:Sony:InternalSerialNumber': 'UNREQUESTED'},
                       {'APP7:Sony:FocusMode': 3}, {'MakerNotes:Other:FocusMode': 3},
                       {'EXIF:GPS:SubjectDistance': 1},
                       {'MakerNotes:Sony:Unexpected:FocusMode': 3},
                       {'XMP:XMP-exif:SubjectDistance': 1}, {'MakerNotes:Sony:UnknownField': 1},
                       {'MakerNotes:Sony:Error': 'UNTRUSTED-DIAGNOSTIC'},
                       {'ExifTool:Error': 'UNTRUSTED-DIAGNOSTIC'}):
            with self.subTest(keys=list(values)):
                with self.assertRaises(focus.AuditError) as error:
                    self.normalized(values)
                self.assertNotIn('UNTRUSTED-DIAGNOSTIC', str(error.exception))
        with self.assertRaises(focus.AuditError):
            focus.normalize_tool(b'[{"SourceFile":"/wrong.arw"}]', self.registry(), b'k' * 32, self.source)
        with self.assertRaises(focus.AuditError):
            focus.normalize_tool(b'[{"SourceFile":"/a","SourceFile":"/b"}]', self.registry(), b'k' * 32, self.source)

    def test_warning_text_is_never_persisted_and_hmac_domain_and_key_are_bound(self):
        private = 'PRIVATE-SOURCE-PATH-OR-WARNING-19238'
        values = {'ExifTool:Warning': private, 'MakerNotes:Sony:FocusMode': 3}
        value = self.normalized(values)
        self.assertNotIn(private, json.dumps(value))
        self.assertEqual(value['fieldStates']['sony.FocusMode'], 'present')
        self.assertEqual(len(value['warnings']), 1)
        digest = value['warnings'][0]['opaqueDigest']
        self.assertEqual(len(digest), 64)
        payload = json.dumps([dict(SourceFile=self.source, **values)]).encode()
        changed = focus.normalize_tool(payload, self.registry(), b'x' * 32, self.source)
        self.assertNotEqual(digest, changed['warnings'][0]['opaqueDigest'])
        self.assertNotEqual(digest, self.normalized({'ExifTool:Warning': private + 'x'})['warnings'][0]['opaqueDigest'])

    def test_registry_remains_twelve_named_capture_selectors_without_private_or_blob_fields(self):
        fields = self.registry()
        expected = {'Sony:' + name for name in ('FocusLocation', 'FocusLocation2', 'FocusFrameSize',
                    'FocusMode', 'AFAreaModeSetting', 'AFAreaMode', 'FlexibleSpotPosition',
                    'AFPointSelected', 'AFTracking', 'FocusPosition2', 'CameraOrientation')}
        expected.add('EXIF:SubjectDistance')
        self.assertEqual(len(fields), 12)
        self.assertEqual({x['selector'] for x in fields}, expected)
        self.assertEqual(len({x['fieldID'] for x in fields}), 12)
        tuple_fields = {x['selector']: x['tupleCount'] for x in fields if x['kind'] == 'tuple'}
        self.assertEqual(tuple_fields, {'Sony:FocusLocation': 4, 'Sony:FocusLocation2': 4,
                                       'Sony:FocusFrameSize': 3, 'Sony:FlexibleSpotPosition': 2})


class FocusMetadataScopeContracts(unittest.TestCase):
    def inventory(self):
        records, metadata = [], {}
        for case_id, count in focus.base.CASES.items():
            files = []
            for ordinal in range(count):
                is_dji = case_id == 'dji187-context376'
                format_name = ('DNG' if ordinal % 2 == 0 else 'JPG') if is_dji else 'ARW'
                source_format = {'ARW': 'arw', 'DNG': 'dng', 'JPG': 'jpeg'}[format_name]
                asset = f'asset{ordinal:04d}'
                original = focus.base.digest(f'original/{case_id}/{ordinal}'.encode())
                current = focus.base.digest(f'current/{case_id}/{ordinal}'.encode())
                records.append(dict(caseID=case_id, assetID=asset, ordinal=ordinal,
                    expectedHash=original, fixtureHash=current, format=format_name,
                    sourceRelativePath=f'synthetic/{case_id}/{ordinal}.{format_name}'))
                model = 'FC9313' if is_dji else ('ILCE-7RM5' if case_id == 'interval427-context439' else 'ILCE-1M2')
                files.append(dict(assetID=asset, ordinal=ordinal, originalSHA256=original,
                    currentSHA256=current, originalFormat=source_format,
                    capture=dict(cameraMake='DJI' if is_dji else 'SONY', cameraModel=model)))
            metadata[case_id] = dict(caseID=case_id, files=files)
        return records, metadata

    def test_selects_all_450_original_a1m2_context_files_without_label_or_path_selection(self):
        records, metadata = self.inventory()
        before = copy.deepcopy(records)
        selected = focus.select_scope(records, metadata)
        self.assertEqual(records, before)
        self.assertEqual(len(selected), 450)
        self.assertEqual({case_id: sum(x['caseID'] == case_id for x in selected)
                          for case_id in ('burst123', 'burst14-context38', 'burst48-context72', 'burst193-context217')},
                         {'burst123': 123, 'burst14-context38': 38, 'burst48-context72': 72, 'burst193-context217': 217})
        self.assertEqual([(x['caseID'], x['ordinal']) for x in selected],
                         [(x['caseID'], x['ordinal']) for x in records if x['format'] == 'ARW'
                          and x['caseID'] != 'interval427-context439'])
        for record in records:
            record['label'] = 'exclude this entire record'
            record['sourceRelativePath'] = 'unrelated-name-not-a-selection-feature.ARW'
        again = focus.select_scope(records, metadata)
        self.assertEqual([(x['caseID'], x['assetID'], x['ordinal']) for x in selected],
                         [(x['caseID'], x['assetID'], x['ordinal']) for x in again])

    def test_missing_extra_duplicate_or_reordered_scope_is_rejected(self):
        for change in ('missing', 'extra', 'duplicate', 'reordered', 'missing-case'):
            with self.subTest(change=change):
                records, metadata = self.inventory()
                if change == 'missing':
                    records.pop()
                elif change == 'extra':
                    records.append(copy.deepcopy(records[-1]))
                elif change == 'duplicate':
                    records[0] = copy.deepcopy(records[1])
                elif change == 'reordered':
                    records[0], records[1] = records[1], records[0]
                else:
                    metadata.pop('interval427-context439')
                with self.assertRaises(focus.AuditError):
                    focus.select_scope(records, metadata)

    def test_each_original_current_identity_camera_and_native_format_is_bound(self):
        changes = [('originalSHA256', '0' * 64), ('currentSHA256', '0' * 64),
                   ('assetID', 'different'), ('ordinal', 1), ('originalFormat', 'jpeg')]
        for key, replacement in changes:
            with self.subTest(binding=key):
                records, metadata = self.inventory()
                metadata['burst123']['files'][0][key] = replacement
                with self.assertRaises(focus.AuditError):
                    focus.select_scope(records, metadata)
        for case_id, camera in [('burst123', dict(cameraMake='SONY', cameraModel='ILCE-7RM5')),
                                ('burst123', dict(cameraMake='OTHER', cameraModel='ILCE-1M2')),
                                ('interval427-context439', dict(cameraMake='SONY', cameraModel='ILCE-1M2'))]:
            with self.subTest(camera_case=case_id, camera=camera):
                records, metadata = self.inventory()
                metadata[case_id]['files'][0]['capture'] = camera
                with self.assertRaises(focus.AuditError):
                    focus.select_scope(records, metadata)

    def complete_records(self):
        records, metadata = self.inventory()
        selected = focus.select_scope(records, metadata)
        for index, record in enumerate(selected):
            record.update(before=[1, index + 1, 10, 100, 200], after=[1, index + 1, 10, 100, 200],
                          beforeHash=record['expectedHash'], afterHash=record['expectedHash'])
        return selected

    def test_publication_requires_every_proof_and_all_450_metadata_rows(self):
        records = self.complete_records()
        self.assertTrue(focus.publish_ready(records, 450, None))
        self.assertFalse(focus.publish_ready(records, 449, None))
        self.assertFalse(focus.publish_ready(records, 451, None))
        self.assertFalse(focus.publish_ready(records[:-1], 450, None))
        self.assertFalse(focus.publish_ready(records, 450, 'cancelled'))
        self.assertFalse(focus.publish_ready(records, 450, ''))
        for key, value in [('before', None), ('after', None), ('beforeHash', None),
                           ('afterHash', None), ('beforeHash', '0' * 64), ('afterHash', '0' * 64),
                           ('after', [1, 1, 10, 100, 201])]:
            with self.subTest(proof=key, value=value):
                changed = copy.deepcopy(records)
                changed[0][key] = value
                self.assertFalse(focus.publish_ready(changed, 450, None))
        duplicate = copy.deepcopy(records)
        duplicate[0] = copy.deepcopy(duplicate[1])
        self.assertFalse(focus.publish_ready(duplicate, 450, None))


class FocusMetadataExecutionGuards(unittest.TestCase):
    def test_fixed_command_requests_only_twelve_fields_and_two_diagnostics(self):
        fields = json.loads((ROOT / 'scripts/sequence-focus-fields-v1.json').read_text())['fields']
        command = focus.tool_command('/usr/bin/perl', '/pinned/tool/exiftool', fields, '/approved/source.ARW')
        self.assertEqual(command[:8], ['/usr/bin/perl', '/pinned/tool/exiftool', '-config', '', '-j', '-n', '-a', '-G0:1:4'])
        self.assertEqual(command[8:-3], ['-' + item['selector'] for item in fields])
        self.assertEqual(command[-3:], ['-ExifTool:Warning', '-ExifTool:Error', '/approved/source.ARW'])
        self.assertFalse(any('=' in argument or argument.lower() in ('-all', '-u', '-ee', '-b') for argument in command))

    def test_helper_and_registry_hashes_are_bound_without_mutating_old_constants(self):
        helper = ROOT / 'scripts/audit-sequence-metadata.py'
        registry = ROOT / 'scripts/sequence-focus-fields-v1.json'
        self.assertEqual(focus.HELPER_SHA, focus.base.digest(helper.read_bytes()))
        self.assertEqual(focus.REGISTRY_SHA, focus.base.digest(registry.read_bytes()))
        self.assertEqual(sum(focus.CASES.values()), 450)
        self.assertEqual(sum(focus.base.CASES.values()), 1265)
        self.assertNotEqual(focus.REGISTRY_SHA, focus.base.REGISTRY_SHA)
        self.assertIsNot(focus.LIMITS, focus.base.LIMITS)
        self.assertNotIn('tupleComponents', focus.base.LIMITS)
        self.assertEqual(focus.LIMITS['tupleComponents'], 16)

    def test_preflight_output_guard_precedes_controls_tool_and_source_reads(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            args = types.SimpleNamespace(source_base=str(root / 'source'), output=str(root / 'unapproved-output'),
                key_file=str(ROOT / 'output/private/focus-unit-key-not-created'), tool_root=str(root / 'tool'),
                perl='/usr/bin/perl', field_registry=str(ROOT / 'scripts/sequence-focus-fields-v1.json'),
                input_spec=str(root / 'spec.json'), fixture_root=str(root / 'fixtures'), metadata_root=str(root / 'metadata'))
            with mock.patch.object(focus, 'load_inputs') as inputs, \
                 mock.patch.object(focus.base, 'read_control') as control, \
                 mock.patch.object(focus.base, 'verify_tool') as tool, \
                 mock.patch.object(focus.base, 'run_child') as child:
                with self.assertRaises(focus.AuditError):
                    focus.run(args)
                inputs.assert_not_called()
                control.assert_not_called()
                tool.assert_not_called()
                child.assert_not_called()
            self.assertFalse((root / 'unapproved-output').exists())

    def test_input_spec_hash_is_required_before_loading_scope(self):
        args = types.SimpleNamespace(input_spec='/synthetic/spec.json', fixture_root='/synthetic/v1', metadata_root='/synthetic/v2')
        with mock.patch.object(focus.base, 'read_control', side_effect=focus.AuditError('controlHashMismatch')) as control:
            with self.assertRaises(focus.AuditError):
                focus.load_inputs(args, Path('/synthetic/originals'))
            control.assert_called_once_with(args.input_spec, focus.base.SPEC_SHA)

    def test_v1_v2_hash_controls_and_historical_audit_identity_are_required(self):
        args = types.SimpleNamespace(input_spec='/synthetic/spec.json', fixture_root='/synthetic/v1', metadata_root='/synthetic/v2')
        spec = dict(cases=[dict(id=case, files=[{}] * count) for case, count in focus.base.CASES.items()])
        index = dict(cases=[dict(id=case, assetCount=count) for case, count in focus.base.CASES.items()])
        metadata = dict(cases=[dict(id=case) for case in focus.base.CASES],
                        auditSeal='0' * 64, v1IndexSHA256=focus.base.INDEX_SHA)
        responses = [(spec, focus.base.SPEC_SHA), (index, focus.base.INDEX_SHA), (metadata, focus.METADATA_INDEX_SHA)]
        with mock.patch.object(focus.base, 'read_control', side_effect=responses) as control:
            with self.assertRaises(focus.AuditError):
                focus.load_inputs(args, Path('/synthetic/originals'))
            self.assertEqual(control.call_args_list, [
                mock.call(args.input_spec, focus.base.SPEC_SHA),
                mock.call(Path(args.fixture_root) / 'index.json', focus.base.INDEX_SHA),
                mock.call(Path(args.metadata_root) / 'index.json', focus.METADATA_INDEX_SHA)])

    def test_partial_rows_retain_all_members_and_never_promote_missing_after_proof(self):
        digest = focus.base.digest(b'synthetic-original')
        records = [dict(caseID='synthetic', assetID=f'asset{index}', ordinal=index,
            expectedHash=digest, fixtureHash='f' * 64, before=[1, index, 3, 4, 5], beforeHash=digest,
            after=[1, index, 3, 4, 5] if index == 0 else None,
            afterHash=digest if index == 0 else None) for index in range(3)]
        provisional = [dict(caseID='synthetic', assetID=f'asset{index}', ordinal=index,
                            fields=[], fieldStates={}, resolved={}, warnings=[]) for index in range(2)]
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            (stage / 'provisional.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in provisional))
            with mock.patch.object(focus.base, 'wrapper_peak_bytes', return_value=16 * 1024 * 1024):
                focus.rows(stage, records, focus.base.ArtifactWriter())
            rows = [json.loads(line) for line in (stage / 'assets.jsonl').read_text().splitlines()]
            self.assertEqual([row['ordinal'] for row in rows], [0, 1, 2])
            self.assertEqual([row['status'] for row in rows], ['complete', 'afterUnverified', 'notRead'])
            self.assertEqual([row['sourceIntegrity']['matchesFixtureProvenance'] for row in rows], [True, False, False])
            self.assertEqual(len((stage / 'local-proof.jsonl').read_text().splitlines()), 3)
            self.assertFalse((stage / 'provisional.jsonl').exists())
            self.assertFalse(focus.publish_ready(records, 2, 'cancelled'))


if __name__ == '__main__':
    unittest.main()
