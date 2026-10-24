"""Synthetic tooling checks; no Swift, fixture pixels, external media or network."""
import importlib.util
import json
import subprocess
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/sequence-spatial-experiment.py'
spec = importlib.util.spec_from_file_location('spatial_runner', SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SpatialRunnerTests(unittest.TestCase):
    def test_nonexistent_suffix_through_symlink_cannot_write_fixture_truth(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            root = repo / 'Tests/RAWMasterImagingTests/Fixtures'
            root.mkdir(parents=True)
            alias = repo / 'alias'
            alias.symlink_to(root, target_is_directory=True)
            bundle = repo / 'fake.xctest'
            with self.assertRaises(ValueError):
                runner.safe_output(alias / 'new-parent/not-yet-present.json', repo, bundle)
            self.assertEqual(runner.safe_output(repo / 'output/report.json', repo, bundle), (repo / 'output/report.json').resolve())

    def test_snapshot_binds_sqlite_shim_module_map_and_native_test_support(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / 'Sources/CSQLite').mkdir(parents=True)
            (repo / 'Tests').mkdir()
            (repo / 'Sources/CSQLite/shim.h').write_text('#include <sqlite3.h>')
            (repo / 'Sources/CSQLite/module.modulemap').write_text('module CSQLite {}')
            (repo / 'Tests/helper.swift').write_text('import Foundation')
            (repo / 'Package.swift').write_text('// package')
            script = repo / 'runner.py'
            script.write_text('# runner')
            before = runner.snapshot(repo, script)
            (repo / 'Sources/CSQLite/shim.h').write_text('#include <sqlite3.h>\n// changed')
            after = runner.snapshot(repo, script)
            self.assertNotEqual(before['sha256'], after['sha256'])
            self.assertIn('Sources/CSQLite/module.modulemap', {entry['path'] for entry in before['files']})

    def test_schedule_is_264_fresh_units_with_counterbalanced_pairs(self):
        schedule = list(runner.benchmark_schedule())
        self.assertEqual(len(schedule), 264)
        self.assertEqual(sum(item[2] == 'warmup' for item in schedule), 24)
        self.assertEqual(sum(item[2] == 'measured' for item in schedule), 240)
        for pair_id in {item[4] for item in schedule}:
            pair = [item for item in schedule if item[4] == pair_id]
            self.assertEqual(len(pair), 2)
            self.assertIn('baseline', [item[1] for item in pair])
            self.assertEqual(pair[0][1] == 'baseline', pair[0][3] % 2 == 0)

    def test_nearest_rank_quantiles_keep_all_samples(self):
        self.assertEqual(runner.distribution([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), {'count':10, 'p50':5, 'p95':10, 'max':10})
        self.assertIsNone(runner.percentile([], .95))

    def test_input_only_trace_does_not_explain_a_changed_edge(self):
        events = [{'ordinal':2,'referenceOrdinal':1,'stage':'input','reason':'observed','accepted':True},
                  {'ordinal':2,'stage':'output','reason':'emitted','accepted':True}]
        evidence = runner.edge_evidence(events, 1, 2, False)
        self.assertEqual(evidence['evidenceStatus'], 'missing')
        self.assertTrue(evidence['evidenceMissing'])
        self.assertEqual(evidence['decisionEvidence'], [])

    def test_truncated_trace_never_claims_complete_target_explanation(self):
        event = {'ordinal':2,'referenceOrdinal':1,'stage':'dense','reason':'passed','accepted':True}
        complete = runner.edge_evidence([event], 1, 2, False)
        self.assertEqual(complete['evidenceStatus'], 'target-decision-observed')
        partial = runner.edge_evidence([event], 1, 2, True)
        self.assertEqual(partial['evidenceStatus'], 'partial')
        self.assertTrue(partial['evidenceMissing'])
        self.assertEqual(partial['decisionEvidence'], [event])

    def test_bridge_gate_without_final_bridge_decision_is_only_context(self):
        gate = {'ordinal':4,'referenceOrdinal':1,'stage':'bridge','reason':'passed','accepted':True}
        nearby = {'ordinal':2,'referenceOrdinal':0,'stage':'local','reason':'passed','accepted':True}
        evidence = runner.edge_evidence([gate, nearby], 1, 2, False)
        self.assertEqual(evidence['evidenceStatus'], 'partial')
        self.assertTrue(evidence['evidenceMissing'])
        self.assertEqual(evidence['decisionEvidence'], [])
        self.assertTrue(evidence['nearbyDiagnosticEvents'])
        final = dict(gate, spatialPurpose='burstPauseBridge', reason='spatialRejected', accepted=False,
                     spatialSupportedPairs=3, spatialRowsSupported=2, spatialColumnsSupported=1)
        direct = runner.edge_evidence([gate, nearby, final], 1, 2, False)
        self.assertEqual(direct['evidenceStatus'], 'target-decision-observed')
        self.assertEqual(direct['decisionEvidence'], [final])

    def test_watchdog_terminates_parent_and_same_group_grandchild(self):
        with tempfile.TemporaryDirectory() as temporary:
            previous = runner.UNIT_SECONDS, runner.GRACE_SECONDS
            runner.UNIT_SECONDS, runner.GRACE_SECONDS = .5, .2
            log = Path(temporary) / 'child.log'
            code = ("import subprocess,sys,time,json,os; "
                    "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(10)']); "
                    "print(json.dumps({'parent':os.getpid(),'grandchild':child.pid}),flush=True); time.sleep(10)")
            try:
                with self.assertRaises(TimeoutError):
                    runner.execute([sys.executable, '-c', code], os.environ.copy(), log, time.monotonic() + 5)
                self.assertIsNone(runner.ACTIVE)
                identities = json.loads(log.read_text().splitlines()[0])
                for pid in identities.values():
                    # macOS signal-0 EPERM is not a reliable liveness query. ps distinguishes
                    # an exited/zombie process (not running) from a surviving sleep descendant.
                    until = time.monotonic() + 2
                    while True:
                        state = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
                        if not state or state.startswith('Z'): break
                        if time.monotonic() >= until: self.fail(f'watchdog left running process {pid}: {state}')
                        time.sleep(.025)
            finally:
                runner.UNIT_SECONDS, runner.GRACE_SECONDS = previous


if __name__ == '__main__':
    unittest.main()
