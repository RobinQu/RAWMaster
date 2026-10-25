import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('sequence_accepted_regression', REPO / 'scripts/sequence-accepted-regression.py')
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


@unittest.skipUnless(shutil.which('node'), 'Node required for canonical annotation scoring')
class AcceptedRegressionTests(unittest.TestCase):
    def node(self, program):
        completed = subprocess.run(['node', '-e', program, str(REPO)], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def testCanonicalScorerPreservesUnknownAndDoesNotInventEndBoundary(self):
        self.node(r'''
const assert=require('node:assert/strict'),path=require('node:path'),root=process.argv[1];
const {score}=require(path.join(root,'scripts/sequence-accepted-score.cjs'));
const M=require(path.join(root,'scripts/sequence-review-report/review.js'));
const hash='a'.repeat(64),assets=Array.from({length:5},(_,ordinal)=>({caseID:'case',assetID:'a'+ordinal,ordinal,sourceOrdinal:2*ordinal+1,jpegSHA256:hash,originalSHA256:hash,filename:'J'+ordinal+'.JPG'}));
const C={assetCount:5,indexSHA256:hash,cases:[{id:'case',assets,truthSHA256:hash,truth:{groups:[{id:'group',kind:'interval',assetIDs:['a0','a1','a2']}],negativePairs:[]},completeGroupTruth:false}]};
C.binding={indexSHA256:hash,truthSHA256ByCase:{case:hash},assetBindings:assets.map(a=>Object.fromEntries(['caseID','assetID','ordinal','jpegSHA256','originalSHA256'].map(k=>[k,a[k]])))};
const candidate='focus-reset-and-cohort-separation-v2',proofs=Array.from({length:10},()=>null);assets.forEach(a=>proofs[a.sourceOrdinal]={assetID:a.assetID,beforeSHA256:hash,afterSHA256:hash,before:{size:1},after:{size:1},errors:[]});
const variants=['legacy','candidate'].flatMap(variant=>['strict','assumeCorroborated'].map(associationPolicy=>({variant,associationPolicy,configuration:{metadataExperiment:{associationPolicy},pauseBridgeExperiment:{policy:variant==='legacy'?'focus-rect-and-cohort-separation-v1':candidate}},eventCount:5,eventMapFingerprint:hash,associationHypothesisAssumed:false,engineSeconds:[.01],result:{coverage:[{range:{first:0,last:4},state:'classified'}],ranges:[{range:{first:0,last:variant==='legacy'?2:3},kind:'interval'}]}})));
const P={schemaVersion:1,kind:'accepted-annotation-predictions',labelsRead:false,assetCount:5,engineRepeats:1,candidatePolicy:candidate,cases:[{id:'case',assetCount:5,bindings:assets,sourceProofs:proofs,sourcesUnchanged:true,variants}]};
const draft=M.empty(C),s=score(C,draft,P);assert.equal(s.rows[2].counts.unknown,2);assert.equal(s.rows[2].counts.FP,0);assert.equal(s.deltas[0].changedUnknown.length,1);assert.equal(s.rows[2].groups[0].completeGroupTruth,false);assert.equal(s.qualityPassed,false,'extending beyond labeled observed group is not exact membership');
const changed=structuredClone(P);changed.cases[0].bindings[1].sourceOrdinal=0;assert.throws(()=>score(C,draft,changed));
const lost=structuredClone(P);lost.cases[0].variants[2].result.ranges=[];assert.equal(score(C,draft,lost).deltas[0].lostKnownPositive.length,2);
const coverage=structuredClone(P);coverage.cases[0].variants[2].result.coverage=[];assert.throws(()=>score(C,draft,coverage));
const association=structuredClone(P);association.cases[0].variants[2].eventMapFingerprint='b'.repeat(64);assert.throws(()=>score(C,draft,association));
const count=structuredClone(P);count.cases[0].variants[2].eventCount=4;assert.throws(()=>score(C,draft,count));
const duplicate=structuredClone(P);duplicate.cases[0].variants[3]=duplicate.cases[0].variants[2];assert.throws(()=>score(C,draft,duplicate));
''')

    def testFullAcceptedBindingAndCanonicalGroups(self):
        fixture = REPO / 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1'
        catalog = runner.review.jpeg_annotation_projection(runner.review.build_catalog(fixture, runner.review.default_sources(REPO), sources_base=REPO), ['dji187-context376'])
        # Serialize in memory to avoid rewriting any frozen fixture or browser state.
        program = r'''
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs'),root=process.argv[1],C=JSON.parse(fs.readFileSync(0,'utf8'));
const M=require(path.join(root,'scripts/sequence-review-report/review.js')),G=require(path.join(root,'scripts/sequence-review-report/guided-review.js'));
const draft=M.validate(JSON.parse(fs.readFileSync(path.join(root,'Tests/Fixtures/SequenceGroupingAnnotations/v1/accepted-revision.json'))),C);
const all=C.cases.flatMap(c=>G.relations(c,draft));assert.equal(all.filter(v=>v==='same').length,996);assert.equal(all.filter(v=>v==='separate').length,10);assert.equal(all.filter(v=>v==='unknown').length,65);
const dji=C.cases.find(c=>c.id==='dji187-context376');assert.equal(dji.assets.length,188);assert.equal(dji.completeGroupTruth,false);assert.deepEqual(dji.assets.map(a=>a.sourceOrdinal),Array.from({length:188},(_,i)=>2*i+1));assert.equal(M.groups(dji,draft)[0].lastOrdinal,187);
'''
        completed = subprocess.run(['node', '-e', program, str(REPO)], input=json.dumps(catalog, separators=(',', ':')), capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)

    def testPerTargetXCTestExecutablePath(self):
        self.assertEqual(runner.executable_path(Path('/tmp/RAWMasterImagingTests.xctest')), Path('/tmp/RAWMasterImagingTests.xctest/Contents/MacOS/RAWMasterImagingTests'))
        with self.assertRaises(ValueError):
            runner.executable_path(Path('/tmp/not-a-test.app'))

    def testScoringMirrorDetectsChanges(self):
        row = {'caseID': 'case', 'variant': 'candidate', 'associationPolicy': 'strict', 'counts': {'FP': 0}, 'groups': [], 'errors': []}
        runner.validate_mirror({'score': {'rows': [row]}}, {'rows': [row]})
        changed = dict(row, counts={'FP': 1})
        with self.assertRaises(ValueError):
            runner.validate_mirror({'score': {'rows': [row]}}, {'rows': [changed]})

    def testPerformanceRejectsNonfiniteSamples(self):
        with self.assertRaises(ValueError):
            runner.timings({'cases': [{'variants': [{'engineSeconds': [float('nan')]}]}]})


if __name__ == '__main__':
    unittest.main()
