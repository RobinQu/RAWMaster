"""Narrow audit contract checks: synthetic JSON/files/processes, never original media or ExifTool."""
import decimal
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/audit-sequence-metadata.py'
SPEC = importlib.util.spec_from_file_location('metadata_audit_under_test', SCRIPT)
audit = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audit)


def field(identifier, selector, kind='number', privacy='public-scalar', role='unvalidated-context'):
    return dict(fieldID=identifier, selector=selector, kind=kind, privacy=privacy,
                candidateRole=role, catalogDefinition='synthetic::table/test-offset')


def measurement():
    return dict(childRSSSamples=0, childPeakRSSBytes=None, metadataSeconds=0.0)


class MetadataAuditTests(unittest.TestCase):
    def setUp(self):
        # Test-runner imports/high-water are not the standalone audit process budget.
        sampled = mock.patch.object(audit, 'wrapper_peak_bytes', return_value=16 * 1024 * 1024)
        sampled.start()
        self.addCleanup(sampled.stop)

    def assertCode(self, expected, function, *args, **kwargs):
        with self.assertRaises(audit.AuditError) as result:
            function(*args, **kwargs)
        self.assertEqual(result.exception.code, expected)
        return result.exception

    def normalized(self, values, fields):
        source = '/synthetic-approved-source/input.arw'
        payload = json.dumps([dict(SourceFile=source, **values)]).encode()
        return audit.normalize_tool(payload, fields, b'k' * 32, source)

    def test_exact_numeric_lexemes_and_explicit_metadata_absence(self):
        raw = b'{"integer":900719925474099312345,"fraction":1.234567890123456789e-12,"text":"00019"}'
        parsed = audit.parse_json(raw)
        self.assertIsInstance(parsed['integer'], audit.NumberText)
        self.assertEqual(parsed['integer'], '900719925474099312345')
        self.assertEqual(parsed['fraction'], '1.234567890123456789e-12')
        self.assertEqual(parsed['text'], '00019')
        fields = [field('sony.counter', 'Sony:SequenceImageNumber'),
                  field('exif.ExposureTime', 'EXIF:ExposureTime'),
                  field('exif.SubSecTimeOriginal', 'EXIF:SubSecTimeOriginal', 'string')]
        source = '/synthetic-approved-source/input.arw'
        payload = ('[{"SourceFile":"' + source + '","MakerNotes:Sony:SequenceImageNumber":900719925474099312345,'
                   '"EXIF:ExifIFD:ExposureTime":1.234567890123456789e-12,"EXIF:ExifIFD:SubSecTimeOriginal":"00019"}]').encode()
        output = audit.normalize_tool(payload, fields, b'k' * 32, source)
        counter = next(row for row in output['fields'] if row['fieldID'] == 'sony.counter')
        exposure = next(row for row in output['fields'] if row['fieldID'] == 'exif.ExposureTime')
        self.assertEqual(counter['rawScalarText'], '900719925474099312345')
        self.assertEqual(counter['numericCanonical'], '900719925474099312345')
        self.assertEqual(exposure['rawScalarText'], '1.234567890123456789e-12')
        self.assertEqual(decimal.Decimal(exposure['numericCanonical']), decimal.Decimal('1.234567890123456789e-12'))
        self.assertEqual(output['capture']['subsecTimeOriginalRaw'], '00019')
        self.assertIsNone(output['capture']['offsetTimeOriginalRaw'])
        self.assertIsNone(output['capture']['dateTimeOriginalRaw'])

    def test_numeric_looking_catalog_string_preserves_transport_lexeme_without_repair(self):
        source = '/synthetic-approved-source/input.arw'
        fields = [field('exif.SubSecTimeOriginal', 'EXIF:SubSecTimeOriginal', 'string')]
        for token, expected, scalar_type in [('123','123','number'), ('0','0','number'),
                                             ('"001"','001','string'), ('1e2','1e2','number')]:
            payload = ('[{"SourceFile":"' + source + '","EXIF:ExifIFD:SubSecTimeOriginal":' + token + '}]').encode()
            result = audit.normalize_tool(payload, fields, b'k' * 32, source)
            fact = result['fields'][0]
            self.assertEqual(fact['scalarType'], scalar_type)
            self.assertEqual(fact['rawScalarText'], expected)
            self.assertIsNone(fact['numericCanonical'])
            self.assertEqual(result['capture']['subsecTimeOriginalRaw'], expected)
            if scalar_type == 'number':
                self.assertIn('exact-lexeme-preserved', fact['transportEncodingNote'])
            if token == '1e2':
                # Preserve the invalid fractional-time text for downstream validation;
                # never repair it into 100 or synthesize a precision/zero padding.
                self.assertFalse(result['capture']['subsecTimeOriginalRaw'].isdigit())
                self.assertNotEqual(result['capture']['subsecTimeOriginalRaw'], '100')
        for malformed in (True, False, [], {}):
            result = self.normalized({'EXIF:ExifIFD:SubSecTimeOriginal':malformed}, fields)
            self.assertEqual(result['fieldStates']['exif.SubSecTimeOriginal'], 'invalid')
            self.assertIsNone(result['capture']['subsecTimeOriginalRaw'])

    def test_sampled_wrapper_rss_gate_uses_bytes_and_preserves_control_precedence(self):
        ceiling = audit.LIMITS['wrapperSampledRSSCeilingBytes']
        self.assertEqual(ceiling, 64 * 1024 * 1024)
        with mock.patch.object(audit, 'CANCELLED', False), mock.patch.object(audit, 'wrapper_peak_bytes', return_value=ceiling):
            self.assertIsNone(audit.gate_failure())
            audit.check()
        with mock.patch.object(audit, 'CANCELLED', False), mock.patch.object(audit, 'wrapper_peak_bytes', return_value=ceiling + 1):
            self.assertEqual(audit.gate_failure(), 'wrapperRSSBudget')
            self.assertCode('wrapperRSSBudget', audit.check)
            self.assertEqual(audit.gate_failure(time.monotonic() - 1), 'jobTimeout')
        with mock.patch.object(audit, 'CANCELLED', True), mock.patch.object(audit, 'wrapper_peak_bytes', return_value=ceiling + 1):
            self.assertEqual(audit.gate_failure(), 'cancelled')

    @unittest.skipUnless(os.environ.get('RAWMASTER_METADATA_AUDIT_EXIFTOOL'),
                         'Root opt-in pinned ExifTool; generated TIFF only, no original media')
    def test_opt_in_pinned_tool_generated_tiff_subsecond_transport_roundtrip(self):
        tool = Path(os.environ['RAWMASTER_METADATA_AUDIT_EXIFTOOL']).resolve()
        perl = os.environ.get('RAWMASTER_METADATA_AUDIT_PERL', '/usr/bin/perl')
        version = audit.run_child([perl, str(tool), '-config', '', '-ver'], time.monotonic()+15, measurement())
        self.assertEqual(version.decode().strip(), audit.TOOL_VERSION)
        def generated_tiff(text):
            # One uncompressed 8-bit grayscale pixel plus an actual ASCII EXIF field.
            # No Imaging/ImageIO/Swift dependency, and ExifTool receives read-only args.
            exif_at = 8 + 2 + 10 * 12 + 4
            date_at = exif_at + 2 + 2 * 12 + 4
            pixel_at = date_at + 20
            tags = [(256,4,1,1), (257,4,1,1), (258,3,1,8), (259,3,1,1), (262,3,1,1),
                    (273,4,1,pixel_at), (277,3,1,1), (278,4,1,1), (279,4,1,1), (34665,4,1,exif_at)]
            output = bytearray(b'II' + struct.pack('<HI',42,8) + struct.pack('<H',len(tags)))
            for tag, kind, count, value in tags: output.extend(struct.pack('<HHII',tag,kind,count,value))
            output.extend(struct.pack('<IH',0,2))
            output.extend(struct.pack('<HHII',0x9003,2,20,date_at))
            output.extend(struct.pack('<HHI',0x9291,2,4) + text.encode('ascii') + bytes(1))
            output.extend(struct.pack('<I',0) + b'2026:10:24 12:34:56' + bytes(1) + bytes([127]))
            return bytes(output)
        fields = [field('exif.SubSecTimeOriginal', 'EXIF:SubSecTimeOriginal', 'string')]
        with tempfile.TemporaryDirectory() as temporary:
            for expected in ('123', '001'):
                source = Path(temporary) / ('synthetic-' + expected + '.tiff')
                source.write_bytes(generated_tiff(expected))
                before = audit.hash_file(source)
                raw = audit.run_child(audit.tool_command(perl, tool, fields, source), time.monotonic()+15, measurement())
                normalized = audit.normalize_tool(raw, fields, b'k' * 32, source)
                self.assertEqual(normalized['capture']['subsecTimeOriginalRaw'], expected)
                fact = normalized['fields'][0]
                self.assertEqual(fact['rawScalarText'], expected)
                self.assertIsNone(fact['numericCanonical'])
                self.assertEqual(fact['scalarType'], 'number' if expected == '123' else 'string')
                self.assertEqual(audit.hash_file(source), before)

    def test_duplicate_json_nonfinite_and_malformed_are_rejected(self):
        self.assertCode('duplicateJSONKey', audit.parse_json, b'{"key":1,"key":2}')
        for value in (b'{"key":NaN}', b'{"key":Infinity}', b'{"key":-Infinity}'):
            self.assertCode('nonfiniteJSON', audit.parse_json, value)
        self.assertCode('invalidJSON', audit.parse_json, b'{unfinished')
        source = '/synthetic-approved-source/input.arw'
        self.assertCode('duplicateJSONKey', audit.normalize_tool,
            ('[{"SourceFile":"' + source + '","SourceFile":"other"}]').encode(), [], b'k' * 32, source)

    def test_qualified_duplicate_instances_survive_and_conflicts_do_not_resolve(self):
        fields = [field('sony.length', 'Sony:SequenceLength')]
        values = {'MakerNotes:Sony:SequenceLength': 0, 'MakerNotes:Sony:Copy1:SequenceLength': 10}
        output = self.normalized(values, fields)
        self.assertEqual(len(output['fields']), 2)
        self.assertEqual({row['qualifiedKey'] for row in output['fields']}, set(values))
        self.assertEqual(output['fieldStates']['sony.length'], 'conflicting')
        self.assertTrue(all(row['runtimeTableResolution'] == 'unresolved' for row in output['fields']))
        same = self.normalized({name:0 for name in values}, fields)
        self.assertEqual(len(same['fields']), 2)
        self.assertEqual(same['fieldStates']['sony.length'], 'present')
        self.assertTrue(all(row['numericCanonical'] == '0' for row in same['fields']))

    def test_missing_and_unsupported_stay_distinct_and_do_not_invent_values(self):
        output = self.normalized({}, [field('exif.OffsetTimeOriginal', 'EXIF:OffsetTimeOriginal', 'string'),
            field('dji.noDefinedCaptureID', None)])
        self.assertEqual(output['fieldStates'], {'exif.OffsetTimeOriginal':'absent', 'dji.noDefinedCaptureID':'unsupportedSelector'})
        self.assertEqual(output['fields'], [])
        self.assertEqual(output['identityCandidates'], [])
        self.assertTrue(all(value is None for value in output['capture'].values()))

    def test_unrequested_private_fields_and_wrong_source_fail_closed(self):
        fields = [field('exif.Model', 'EXIF:Model', 'string')]
        for values in ({'EXIF:GPS:GPSLatitude':25}, {'MakerNotes:Sony:InternalSerialNumber':'PRIVATE-UNREQUESTED'},
                       {'EXIF:ExifIFD:MakerNote':{'secret':'nested'}}, {'XMP:XMP-exif:Model':'wrong namespace'}):
            self.assertCode('unrequestedToolField', self.normalized, values, fields)
        self.assertCode('toolSourceMismatch', audit.normalize_tool, b'[{"SourceFile":"/wrong/file.arw"}]', fields, b'k' * 32, '/expected/file.arw')
        self.assertCode('toolReportedError', self.normalized, {'ExifTool:Error':'RAW-PRIVATE-DIAGNOSTIC'}, fields)

    def test_private_ids_and_warnings_are_opaque_and_scope_bound(self):
        fields = [field('sony.private', 'Sony:InternalSerialNumber', 'string', 'private-opaque', 'unvalidated-device')]
        secret = 'PRIVATE-BODY-739102'
        output = self.normalized({'MakerNotes:Sony:InternalSerialNumber':secret, 'ExifTool:Warning':'private-path ' + secret}, fields)
        encoded = json.dumps(output)
        self.assertNotIn(secret, encoded)
        self.assertNotIn('private-path', encoded)
        value = output['fields'][0]
        self.assertIsNone(value['rawScalarText'])
        self.assertIsNone(value['numericCanonical'])
        self.assertEqual(len(value['opaqueDigest']), 64)
        self.assertEqual(output['identityCandidates'][0]['semanticValidation'], 'unvalidated')
        a = audit.opaque(b'k' * 32, 'Sony:InternalSerialNumber', 'string', secret)
        self.assertEqual(a, value['opaqueDigest'])
        self.assertNotEqual(a, audit.opaque(b'x' * 32, 'Sony:InternalSerialNumber', 'string', secret))
        self.assertNotEqual(a, audit.opaque(b'k' * 32, 'EXIF:SerialNumber', 'string', secret))
        self.assertNotEqual(a, audit.opaque(b'k' * 32, 'Sony:InternalSerialNumber', 'number', secret))
        for placeholder in ('', '   ', '000000000', 'unknown', 'n/a', 'null'):
            invalid = self.normalized({'MakerNotes:Sony:InternalSerialNumber':placeholder}, fields)
            self.assertEqual(invalid['fieldStates']['sony.private'], 'invalid')
            self.assertEqual(invalid['identityCandidates'], [])

    def test_only_app7_dji_sensor_id_alias_is_opaque_and_conflicts_remain_unusable(self):
        fields = [field('dji.SensorID', 'DJI:SensorID', 'string', 'private-opaque', 'unvalidated-sensor')]
        secret = 'SYNTHETIC-PRIVATE-SENSOR-51972'
        for qualified in ('APP7:DJI:SensorID', 'APP7:DJI:Copy1:SensorID', 'MakerNotes:DJI:SensorID'):
            result = self.normalized({qualified:secret}, fields)
            self.assertEqual(result['fieldStates']['dji.SensorID'], 'present')
            self.assertEqual(result['fields'][0]['qualifiedKey'], qualified)
            self.assertEqual(result['fields'][0]['opaqueDigest'], audit.opaque(b'k' * 32, 'DJI:SensorID', 'string', secret))
            self.assertIsNone(result['fields'][0]['rawScalarText'])
            self.assertNotIn(secret, json.dumps(result))
            self.assertEqual(result['identityCandidates'][0]['semanticValidation'], 'unvalidated')
        conflict = self.normalized({'APP7:DJI:SensorID':secret, 'MakerNotes:DJI:SensorID':'DIFFERENT-PRIVATE-SENSOR'}, fields)
        self.assertEqual(conflict['fieldStates']['dji.SensorID'], 'conflicting')
        self.assertEqual(len(conflict['fields']), 2)
        self.assertTrue(all(not candidate['usable'] for candidate in conflict['identityCandidates']))
        self.assertNotIn(secret, json.dumps(conflict))
        self.assertNotIn('DIFFERENT-PRIVATE-SENSOR', json.dumps(conflict))

    def test_app7_alias_does_not_admit_other_app_groups_or_dji_tags(self):
        fields = [field('dji.SensorID', 'DJI:SensorID', 'string', 'private-opaque'),
                  field('dji.SerialNumber', 'DJI:SerialNumber', 'string', 'private-opaque')]
        for qualified in ('APP6:DJI:SensorID', 'APP7:Other:SensorID', 'APP7:DJI:UnknownTag', 'APP7:DJI:SerialNumber'):
            self.assertCode('unrequestedToolField', self.normalized, {qualified:'SYNTHETIC-PRIVATE'}, fields)

    def test_key_file_is_private_stable_and_rejects_alias_or_wrong_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / 'key.bin'
            key, identifier = audit.load_key(path)
            self.assertEqual(len(key), 32)
            self.assertEqual(audit.load_key(path), (key, identifier))
            self.assertNotEqual(identifier, audit.digest(key))
            alias = root / 'alias.bin'
            alias.symlink_to(path)
            self.assertCode('unsafeKeyFile', audit.load_key, alias)
            path.chmod(0o644)
            self.assertCode('unsafeKeyFile', audit.load_key, path)

    def test_paths_reject_tree_overlap_protected_alias_and_source_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo, source, tool = root/'repo', root/'source', root/'tool'
            for path in (repo/'output', source, tool, repo/'Tests'):
                path.mkdir(parents=True)
            output, key = repo/'output/result', repo/'output/keys/key.bin'
            self.assertEqual(audit.guard_paths(source, output, key, repo, tool), (source, output, key))
            for bad in ('../input', '/input', 'a//b', 'a/./b', 'a\\b', ''):
                self.assertCode('unsafeRelativePath', audit.safe_relative, source, bad)
            (source/'real').write_bytes(b'synthetic')
            (source/'alias').symlink_to(source/'real')
            self.assertCode('symlinkInput', audit.safe_relative, source, 'alias')
            self.assertTrue(audit.overlaps(source, source/'child'))
            self.assertTrue(audit.overlaps(source/'child', source))
            self.assertFalse(audit.overlaps(source, root/'source-other'))
            self.assertCode('sourceOutputOverlap', audit.guard_paths, repo/'output', output, key, repo, tool)
            self.assertCode('keyOutputOverlap', audit.guard_paths, source, output, output/'key', repo, tool)
            protected_alias = repo/'output/fixture-alias'
            protected_alias.symlink_to(repo/'Tests', target_is_directory=True)
            with self.assertRaises(audit.AuditError):
                audit.guard_paths(source, protected_alias/'missing-suffix/result', key, repo, tool)
            output.mkdir()
            self.assertCode('outputExists', audit.guard_paths, source, output, key, repo, tool)

    def test_same_size_source_mutation_changes_hash_and_credential(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'standin.bin'
            path.write_bytes(b'AAA')
            before, original = audit.credential(path), audit.hash_file(path)
            path.write_bytes(b'BBB')
            os.utime(path, ns=(path.stat().st_atime_ns, before[3] + 1_000_000_000))
            self.assertEqual(path.stat().st_size, 3)
            self.assertNotEqual(audit.hash_file(path), original)
            self.assertNotEqual(audit.credential(path), before)
            alias = path.with_name('link.bin'); alias.symlink_to(path)
            self.assertCode('nonregularSource', audit.credential, alias)

    def test_partial_rows_keep_all_ordinals_and_never_claim_unverified_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary)
            digest = audit.digest(b'synthetic')
            records = [dict(caseID='synthetic', assetID=f'asset{i}', ordinal=i, expectedHash=digest, fixtureHash=digest,
                format='ARW', before=[1,2,3,4,5], beforeHash=digest,
                after=[1,2,3,4,5] if i==0 else None, afterHash=digest if i==0 else None) for i in range(3)]
            provisional = [dict(caseID='synthetic', assetID=f'asset{i}', ordinal=i, fields=[], fieldStates={}, identityCandidates=[]) for i in range(2)]
            (stage/'provisional.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in provisional))
            audit.build_rows(stage, records, audit.ArtifactWriter())
            rows = [json.loads(line) for line in (stage/'assets.jsonl').read_text().splitlines()]
            self.assertEqual([row['ordinal'] for row in rows], [0,1,2])
            self.assertEqual([row['status'] for row in rows], ['complete','afterUnverified','notRead'])
            self.assertFalse(rows[1]['sourceIntegrity']['matchesFixtureProvenance'])
            self.assertFalse(rows[2]['sourceIntegrity']['credentialUnchanged'])
            self.assertFalse((stage/'provisional.jsonl').exists())
            self.assertEqual(len((stage/'local-proof.jsonl').read_text().splitlines()), 3)

    def test_artifact_budgets_fail_before_writing_and_do_not_overwrite(self):
        writer = audit.ArtifactWriter()
        target = io.BytesIO()
        with mock.patch.dict(audit.LIMITS, rowBytes=8):
            self.assertCode('rowBudget', writer.line, target, {'long':'value'})
        self.assertEqual(target.getvalue(), b'')
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'receipt.json'
            audit.ArtifactWriter().write(path, {'status':'synthetic'})
            with self.assertRaises(FileExistsError):
                audit.ArtifactWriter().write(path, {'status':'changed'})
            self.assertEqual(json.loads(path.read_text()), {'status':'synthetic'})
            self.assertCode('outputExists', audit.atomic_publish, Path(temporary)/'stage', path)

    def test_fixed_command_only_requests_allowlisted_fields_and_disables_user_config(self):
        fields = [field('model','EXIF:Model','string'), field('unsupported', None)]
        command = audit.tool_command('/usr/bin/perl', '/synthetic-tool/exiftool', fields, '/approved/input.arw')
        self.assertEqual(command, ['/usr/bin/perl','/synthetic-tool/exiftool','-config','','-j','-n','-a','-G0:1:4','-EXIF:Model','-ExifTool:Warning','-ExifTool:Error','/approved/input.arw'])
        self.assertFalse(any('all' in part.lower() or '=' in part for part in command))

    def runFake(self, code, **limits):
        state = measurement()
        settings = dict(childSeconds=2, pollSeconds=.01, graceSeconds=.2)
        settings.update(limits)
        with mock.patch.dict(audit.LIMITS, settings), \
             mock.patch.object(audit, 'child_rss', return_value=None):
            result = audit.run_child([sys.executable,'-c',code], time.monotonic()+5, state)
        return result, state

    def test_fake_child_success_and_private_stderr_are_bounded_without_leak(self):
        result, state = self.runFake('print("synthetic-output")')
        self.assertEqual(result, b'synthetic-output\n')
        self.assertGreaterEqual(state['metadataSeconds'], 0)
        error = self.assertCode('toolStderr', self.runFake, 'import sys; sys.stderr.write("PRIVATE-BODY-739102")')
        self.assertNotIn('PRIVATE-BODY', str(error))
        self.assertCode('stdoutBudget', self.runFake, 'import sys; sys.stdout.write("x"*1000)', stdoutBytes=16)
        self.assertCode('toolExitFailure', self.runFake, 'raise SystemExit(7)')

    def test_closed_pipe_child_cannot_escape_timeout_or_cancellation(self):
        with mock.patch.dict(audit.LIMITS, childSeconds=.2, pollSeconds=.01, graceSeconds=.2), mock.patch.object(audit, 'child_rss', return_value=None):
            self.assertCode('childTimeout', audit.run_child,
                [sys.executable,'-c','import os,time; os.close(1); os.close(2); time.sleep(10)'], time.monotonic()+5, measurement())
        with mock.patch.object(audit, 'CANCELLED', True), mock.patch.object(audit.subprocess, 'Popen') as spawn:
            self.assertCode('cancelled', audit.run_child, [sys.executable,'-c','pass'], time.monotonic()+5, measurement())
            spawn.assert_not_called()
        def cancel_after_spawn(_pid):
            audit.CANCELLED = True
            return None
        with mock.patch.object(audit, 'CANCELLED', False), mock.patch.object(audit, 'child_rss', side_effect=cancel_after_spawn):
            self.assertCode('cancelled', audit.run_child, [sys.executable,'-c','import time; time.sleep(10)'], time.monotonic()+5, measurement())

    def test_timeout_terminates_parent_and_same_group_grandchild(self):
        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary)/'fake-processes.json'
            code = ('import subprocess,sys,os,time,json; '
                    'child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(10)"]); '
                    'open(sys.argv[1],"w").write(json.dumps([os.getpid(),child.pid])); time.sleep(10)')
            with mock.patch.dict(audit.LIMITS, childSeconds=.5, pollSeconds=.01, graceSeconds=.2), mock.patch.object(audit,'child_rss',return_value=None):
                self.assertCode('childTimeout', audit.run_child, [sys.executable,'-c',code,str(pid_file)], time.monotonic()+5, measurement())
            for pid in json.loads(pid_file.read_text()):
                until = time.monotonic()+2
                while True:
                    process = subprocess.run(['/bin/ps','-o','stat=','-p',str(pid)], capture_output=True, text=True)
                    self.assertIn(process.returncode, (0,1))
                    status = process.stdout.strip()
                    if not status or status.startswith('Z'): break
                    if time.monotonic()>=until: self.fail(f'Fake process survived cleanup: {pid}/{status}')
                    time.sleep(.025)


if __name__=='__main__':
    unittest.main()
