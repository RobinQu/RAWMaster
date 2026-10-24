"""Pure fixed-runner and edge-level regression guards; no Swift, fixture pixels or original I/O."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('focus_experiment_driver_test', ROOT / 'scripts/sequence-focus-experiment.py')
runner = importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)


class SequenceFocusExperimentTests(unittest.TestCase):
    def test_fixed_twenty_four_units_compare_two_algorithms_and_two_association_policies(self):
        order = runner.schedule()
        self.assertEqual(len(order), 24);self.assertEqual(len(set(order)), 24)
        self.assertEqual({case for case, _ in order}, set(runner.watch.CASES))
        self.assertTrue(all(sum(variant == name for _, variant in order) == 6 for name in runner.VARIANTS))
        self.assertEqual(set(runner.VARIANTS), {'008B-strict', '008B-assumed', '009-strict', '009-assumed'})

    def test_assumed_and_control_evidence_cannot_claim_native_or_unconsumed_focus(self):
        identity = dict(phase='quality', caseID='synthetic', variant='009-assumed', expectedPolicyFingerprint='a'*64)
        focus = dict(caseSHA256s={'synthetic': 'b'*64})
        value = dict(schemaVersion=1, identity=identity, kind='focus-quality-unit', integrityValidated=True, strictValidated=True,
            analysisSealedBeforeLabels=True, behavior=dict(id='synthetic', assetCount=2, policyFingerprint='a'*64),
            focusConsumed=True, pairPrecision=None, focusSnapshotSHA256='b'*64, focusAuditSeal=runner.FOCUS_SEAL,
            configuration=dict(pauseBridgeExperiment={'active': True}), associationHypothesisAssumed=True, topQualityAccepted=True,
            metricsMeaning='conditionalGroupingMetrics')
        with self.assertRaisesRegex(ValueError, 'Assumed association'):
            runner.validate_unit(value, identity, 2, '/unread/path', focus)
        control = copy.deepcopy(value)
        control_identity = dict(identity, variant='008B-strict');control['identity'] = control_identity;control['focusConsumed'] = False
        with self.assertRaisesRegex(ValueError, 'silently consumes focus'):
            runner.validate_unit(control, control_identity, 2, '/unread/path', focus)

    def test_focus_fixture_freeze_catches_byte_changes_without_touching_old_controls(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGroupingFocus/v1'
            (root / 'cases').mkdir(parents=True)
            cases = []
            for name, count in runner.watch.CASES.items():
                path = root / 'cases' / (name + '.json');path.write_text('{}')
                cases.append(dict(id=name, assetCount=count, path='cases/' + name + '.json', sha256=runner.watch.digest_file(path)))
            (root / 'index.json').write_text(json.dumps(dict(schemaVersion=1, focusAuditSeal=runner.FOCUS_SEAL,
                assetCount=1265, auditedAssetCount=450, outsideAuditedCohortCount=815, cases=cases)))
            (root / 'README.md').write_text('synthetic focus supplement')
            (root / 'baselines').mkdir()
            baseline = root / 'baselines/behavior-v1.json';baseline.write_text('{"kind":"observed-only"}')
            frozen = runner.focus_snapshot(repository)
            self.assertIn('baselines/behavior-v1.json', {row['path'] for row in frozen['files']})
            runner.verify_focus(repository, frozen)
            baseline.write_text('{"changed":true}')
            with self.assertRaisesRegex(RuntimeError, 'Frozen focus bytes changed'):
                runner.verify_focus(repository, frozen)
            baseline.write_text('{"kind":"observed-only"}')
            (root / cases[0]['path']).write_text('{"changed":true}')
            with self.assertRaisesRegex(RuntimeError, 'Frozen focus bytes changed'):
                runner.verify_focus(repository, frozen)

    def test_no_added_splits_is_edge_level_and_rejects_hidden_unknown_coverage(self):
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            root = repository / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1';root.mkdir(parents=True)
            cases, quality = [], []
            for case in runner.watch.CASES:
                manifest, truth = case + '.manifest.json', case + '.truth.json'
                cases.append(dict(id=case, manifestPath=manifest, truthPath=truth))
                (root / manifest).write_text(json.dumps(dict(files=[dict(assetID='a'+str(i), ordinal=i) for i in range(4)])))
                (root / truth).write_text(json.dumps(dict(groups=[dict(id='positive', assetIDs=['a0', 'a1'])], negativePairs=[dict(**{'from': 'a1', 'to': 'a2'})])))
                for variant in runner.VARIANTS:
                    ranges = [dict(range=dict(first=0, last=3))] if variant.startswith('008B') else [dict(range=dict(first=0, last=1)), dict(range=dict(first=2, last=3))]
                    evaluation = dict(groups=[dict(id='positive', exactMembershipAndType=variant.startswith('009'))], unknownCount=0,
                        unknownPositivePairs=0, unknownNegativePairs=0)
                    quality.append(dict(identity=dict(caseID=case, variant=variant), behavior=dict(result=dict(ranges=ranges,
                        coverage=[dict(range=dict(first=0, last=3), state='complete')]), evaluation=evaluation)))
            (root / 'index.json').write_text(json.dumps(dict(cases=cases)))
            deltas = runner.edge_deltas(quality, repository)
            self.assertTrue(deltas['noAddedFalseSplits'])
            self.assertTrue(all(row['changedKnownNegativeEdges'] == [dict(ordinals=[1, 2], beforeMerged=True, afterMerged=False)] for row in deltas['comparisons']))
            changed = copy.deepcopy(quality)
            victim = next(v for v in changed if v['identity']['variant'] == '009-strict')
            victim['behavior']['result']['ranges'] = [dict(range=dict(first=0, last=0)), dict(range=dict(first=1, last=1))]
            self.assertFalse(runner.edge_deltas(changed, repository)['noAddedFalseSplits'])
            hidden = copy.deepcopy(quality)
            victim = next(v for v in hidden if v['identity']['variant'] == '009-strict')
            victim['behavior']['evaluation']['unknownCount'] = 1
            self.assertFalse(runner.edge_deltas(hidden, repository)['noAddedFalseSplits'])


if __name__ == '__main__':unittest.main()
