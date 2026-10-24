"""Pure typed focus-export guards; no audit execution, originals, pixels or classifier."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('focus_export_guards', ROOT / 'scripts/export-sequence-focus-metadata.py')
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class SequenceFocusExportTests(unittest.TestCase):
    def sample(self):
        original, current = 'a'*64, 'b'*64
        source = dict(assetID='asset0000', originalSHA256=original, currentSHA256=current, originalFormat='arw',
            capture=dict(cameraMake='SONY', cameraModel='ILCE-1M2'))
        states = {field: 'present' for field in exporter.FIELDS};states['exif.SubjectDistance'] = 'absent'
        resolved = {field: dict(kind='code', numericCanonical='4294967295') for field in exporter.CODES}
        resolved.update({field: dict(kind='tuple', tupleCanonical=['1']*count) for field, count in exporter.TUPLES.items()})
        row = dict(assetID='asset0000', ordinal=0, status='complete', sourceIdentity=dict(sha256=original), fixtureIdentity=dict(sha256=current),
            sourceIntegrity=dict(credentialUnchanged=True, matchesFixtureProvenance=True, beforeSHA256=original, afterSHA256=original),
            fieldStates=states, resolved=resolved, fields=[dict(fieldID=field, qualifiedKey='MakerNotes:Sony:'+field.split('.')[1]) for field in exporter.FIELDS if field != 'exif.SubjectDistance'], warnings=[])
        return row, source

    def test_outside_cohort_retains_identity_without_claimed_absence_or_verification(self):
        row, source = self.sample();source['capture']['cameraModel'] = 'ILCE-7RM5'
        value = exporter.curate(None, source, 0)
        self.assertEqual(value['state'], 'outsideAuditedCohort')
        self.assertEqual(value['originalSHA256'], source['originalSHA256'])
        self.assertEqual(value['fieldStates'], {});self.assertEqual(value['resolvedCodes'], {})
        self.assertEqual(value['qualifiedFieldSources'], {});self.assertIsNone(value['auditWarningCount'])
        with self.assertRaises(ValueError):exporter.curate(row, source, 0)

    def test_exact_typed_usable_facts_and_all_conflict_statuses_are_preserved(self):
        row, source = self.sample()
        value = exporter.curate(row, source, 0)
        self.assertEqual(value['resolvedCodes']['sony.FocusMode'], 4294967295)
        self.assertEqual(value['resolvedTuples']['sony.FocusFrameSize'], [1, 1, 1])
        self.assertEqual(value['fieldStates']['exif.SubjectDistance'], 'absent')
        row['fieldStates']['sony.FocusMode'] = 'conflicting';row['resolved'].pop('sony.FocusMode')
        row['fields'].append(dict(fieldID='sony.FocusMode', qualifiedKey='MakerNotes:Sony:Copy1:FocusMode'))
        value = exporter.curate(row, source, 0)
        self.assertEqual(value['fieldStates']['sony.FocusMode'], 'conflicting')
        self.assertNotIn('sony.FocusMode', value['resolvedCodes'])
        self.assertEqual(len(value['qualifiedFieldSources']['sony.FocusMode']), 2)
        row['resolved']['sony.FocusMode'] = dict(kind='code', numericCanonical='3')
        with self.assertRaises(ValueError):exporter.curate(row, source, 0)

    def test_changed_proof_content_kind_and_tuple_shape_are_rejected(self):
        for change in ('proof', 'original', 'current', 'tuple', 'code'):
            row, source = self.sample()
            if change == 'proof':row['sourceIntegrity']['credentialUnchanged'] = False
            elif change == 'original':source['originalSHA256'] = 'c'*64
            elif change == 'current':source['currentSHA256'] = 'c'*64
            elif change == 'tuple':row['resolved']['sony.FocusLocation']['tupleCanonical'] = ['1', '2', '3']
            else:row['resolved']['sony.FocusMode']['numericCanonical'] = '3.0'
            with self.subTest(change=change), self.assertRaises(ValueError):exporter.curate(row, source, 0)
        for value in ('-1', '65536', '1e2', True, 1):
            with self.subTest(component=value), self.assertRaises(ValueError):exporter.uint(value, 65535)


if __name__ == '__main__':unittest.main()
