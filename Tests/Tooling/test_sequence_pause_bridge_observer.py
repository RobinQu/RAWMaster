"""Pure observer guards. No Swift, original media, fixture pixels or classifier execution."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pause_observer_driver_test', ROOT / 'scripts/sequence-pause-bridge-observer.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


def matrix_row():
    def pair(a, b):
        return dict(fromOrdinal=a, toOrdinal=b, distance=dict(histogram=0.1, luminance=0.1, hash=0.1), issues=[],
                    luminanceGeometryUnavailableReason=None,
                    luminanceGeometry=dict(count=4, rawDot=0.0, firstNormSquared=2.0, secondNormSquared=2.0,
                        firstMean=0.0, secondMean=0.0, centeredDot=0.0, firstCenteredNormSquared=2.0, secondCenteredNormSquared=2.0,
                        cosine=0.0, pearson=0.0, cosineUnavailableReason=None, pearsonUnavailableReason=None))
    return dict(leftOrdinal=2, rightOrdinal=3, gapSeconds=4.8, supportComplete=True,
                leftSlots=[dict(ordinal=i, issues=[]) for i in range(3)], rightSlots=[dict(ordinal=i, issues=[]) for i in range(3, 6)],
                crossNine=[pair(a, b) for a in range(3) for b in range(3, 6)],
                leftIntraThree=[pair(0, 1), pair(0, 2), pair(1, 2)], rightIntraThree=[pair(3, 4), pair(3, 5), pair(4, 5)])


class PauseBridgeObserverDriverTests(unittest.TestCase):
    def test_all_matrix_pairs_and_missing_support_are_explicit(self):
        row = matrix_row()
        observer.validate_matrices(row)
        for key in ('crossNine', 'leftIntraThree', 'rightIntraThree'):
            changed = copy.deepcopy(row)
            changed[key].pop()
            with self.assertRaisesRegex(ValueError, 'omitted/reordered'):
                observer.validate_matrices(changed)
        changed = copy.deepcopy(row)
        changed['crossNine'][0]['distance'] = None
        changed['crossNine'][0]['luminanceGeometry'] = None
        changed['crossNine'][0]['luminanceGeometryUnavailableReason'] = 'pair-support-unavailable'
        with self.assertRaisesRegex(ValueError, 'explicit reason'):
            observer.validate_matrices(changed)
        changed['crossNine'][0]['issues'] = ['feature-unavailable']
        observer.validate_matrices(changed)
        changed['leftSlots'][0]['issues'] = ['outside-input-scope']
        with self.assertRaisesRegex(ValueError, 'availability'):
            observer.validate_matrices(changed)
        changed['supportComplete'] = False
        observer.validate_matrices(changed)
        changed['rightSlots'][0]['ordinal'] = 4
        with self.assertRaisesRegex(ValueError, 'slots'):
            observer.validate_matrices(changed)

    def test_geometry_requires_finite_values_and_explicit_degenerate_coefficients(self):
        pair = matrix_row()['crossNine'][0]
        observer.validate_geometry(pair)
        pair['luminanceGeometry']['cosine'] = None
        with self.assertRaisesRegex(ValueError, 'requires reason'):
            observer.validate_geometry(pair)
        pair['luminanceGeometry']['cosineUnavailableReason'] = 'zero-or-degenerate-energy'
        observer.validate_geometry(pair)
        pair['luminanceGeometry']['rawDot'] = float('nan')
        with self.assertRaisesRegex(ValueError, 'Nonfinite'):
            observer.validate_geometry(pair)

    def test_metadata_enumeration_is_fullscope_precise_and_label_free(self):
        def file(ordinal, second, fraction):
            return dict(ordinal=ordinal, capture=dict(dateTimeOriginalRaw='2026:10:02 12:12:' + second, subsecTimeOriginalRaw=fraction),
                        fieldStates={'sony.ReleaseMode': 'present'}, resolvedNumbers={'sony.ReleaseMode': '2'})
        case = dict(files=[file(0, '00', '000'), file(1, '00', '100'), file(2, '00', '200'), file(3, '05', '000'), file(4, '05', '100')])
        config = dict(denseGapSeconds=0.6, maximumBridgeSeconds=12)
        self.assertEqual(observer.expected_edges(case, config), [(2, 3)])
        case['files'][3]['fieldStates']['sony.ReleaseMode'] = 'conflicting'
        self.assertEqual(observer.expected_edges(case, config), [])
        case['files'][3]['fieldStates']['sony.ReleaseMode'] = 'present'
        case['files'][3]['capture']['subsecTimeOriginalRaw'] = None
        self.assertEqual(observer.expected_edges(case, config), [])
        case['files'][3]['capture']['subsecTimeOriginalRaw'] = '٠٠٠'
        self.assertEqual(observer.expected_edges(case, config), [])

    def test_source_freeze_binds_observer_and_output_cannot_alias_protected_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            script = root / 'scripts/sequence-pause-bridge-observer.py'
            script.parent.mkdir();script.write_text('#first')
            with mock.patch.object(observer.metadata, 'source_snapshot', return_value={'files': []}), mock.patch.object(observer, '__file__', str(script)):
                before = observer.source_snapshot(root)
                script.write_text('#changed')
                self.assertNotEqual(before['sha256'], observer.source_snapshot(root)['sha256'])
            bundle = root / 'test.xctest';bundle.mkdir()
            for path in [root / 'Tests/RAWMasterImagingTests/Fixtures/file.json', root / 'elsewhere/file.json']:
                with self.assertRaises(ValueError):
                    observer.safe_output(path, root, bundle)
            fixtures = root / 'Tests/RAWMasterImagingTests/Fixtures'
            fixtures.mkdir(parents=True)
            output = root / 'output';output.mkdir()
            (output / 'alias').symlink_to(fixtures, target_is_directory=True)
            with self.assertRaises(ValueError):
                observer.safe_output(output / 'alias/missing/report.json', root, bundle)

    def test_report_requires_real_seal_complete_source_and_no_quality_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'report.diagnostic.json'
            identity = dict(caseID='synthetic')
            files = []
            for ordinal, ms in enumerate([0, 100, 200, 5000, 5100, 5200]):
                files.append(dict(ordinal=ordinal, capture=dict(dateTimeOriginalRaw=f'2026:10:02 00:00:{ms // 1000:02d}', subsecTimeOriginalRaw=f'{ms % 1000:03d}'),
                    fieldStates={'sony.ReleaseMode': 'present'}, resolvedNumbers={'sony.ReleaseMode': '2'}))
            frozen = dict(caseSHA256s={'synthetic': 'a'*64}, auditSeal='b'*64)
            diagnostic = dict(schemaVersion=1, kind='pause-bridge-observation', identity=identity, labelsRead=False,
                matricesComplete=True, assetCount=6, metadataSnapshotSHA256='a'*64, auditSeal='b'*64,
                sources=[dict(ordinal=i, sourceUnchanged=True, beforeSHA256='c'*64, afterSHA256='c'*64, currentSHA256='c'*64) for i in range(6)],
                pauseWindows=[matrix_row()], configuration=dict(denseGapSeconds=0.6, maximumBridgeSeconds=12),
                emittedTraceSubset=[], emittedTraceSubsetCount=0, traceBoundary='absence is not causal evidence; summary is unavailable',
                defaultResultSHA256='d'*64, strict008BResultSHA256='e'*64)
            data = json.dumps(diagnostic).encode();path.write_bytes(data)
            report = dict(schemaVersion=1, kind='pause-bridge-observer-report', identity=identity, sourceIntegrityValidated=True,
                defaultParity=True, strict008BParity=True, diagnosticSealedBeforeBaselineRead=True, labelsRead=False, qualityAccepted=False,
                assetCount=6, diagnosticPath=str(path), diagnosticSHA256=hashlib.sha256(data).hexdigest(), metadataSnapshotSHA256='a'*64,
                auditSeal='b'*64, pauseWindowCount=1, defaultResultSHA256='d'*64, strict008BResultSHA256='e'*64, wholeUnitSeconds=1)
            observer.validate_report(report, identity, 6, path, dict(files=files), frozen)
            changed = dict(report, qualityAccepted=True)
            with self.assertRaisesRegex(ValueError, 'quality'):
                observer.validate_report(changed, identity, 6, path, dict(files=files), frozen)
            changed = dict(report, diagnosticPath=str(path.parent / 'wrong.json'))
            with self.assertRaisesRegex(ValueError, 'path'):
                observer.validate_report(changed, identity, 6, path, dict(files=files), frozen)
            path.write_bytes(data + b' ')
            with self.assertRaisesRegex(ValueError, 'seal'):
                observer.validate_report(report, identity, 6, path, dict(files=files), frozen)


if __name__ == '__main__':
    unittest.main()
