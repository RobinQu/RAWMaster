'use strict';
const assert = require('node:assert/strict');
const M = require('./sequence-review-report/review.js');
const G = require('./sequence-review-report/guided-review.js');
const names = ['legacy', 'candidate'];
const associations = ['strict', 'assumeCorroborated'];
const zero = () => ({TP:0, FP:0, FN:0, TN:0, unknown:0});

function joinedEdges(result, count) {
  assert(Array.isArray(result.ranges), 'Missing predicted ranges');
  const membership = Array(count).fill(-1); let previous = -1;
  result.ranges.forEach((g, index) => {
    const {first, last} = g.range;
    assert(Number.isInteger(first) && Number.isInteger(last) && first >= 0 && last > first && last < count && first > previous, 'Invalid/overlapping predicted range');
    assert(['burst', 'interval'].includes(g.kind), 'Unknown predicted kind');
    for (let i = first; i <= last; i++) membership[i] = index;
    previous = last;
  });
  return membership.slice(0,-1).map((value,i) => value >= 0 && value === membership[i+1]);
}
function score(catalog, revision, predictions) {
  const draft = M.validate(revision, catalog);
  assert.equal(predictions.schemaVersion, 1);
  assert.equal(predictions.kind, 'accepted-annotation-predictions');
  assert.equal(predictions.labelsRead, false);
  assert.equal(predictions.assetCount, catalog.assetCount);
  assert.equal(predictions.cases.length, catalog.cases.length);
  const rows = [], deltas = [], oldTruthDeltas = [];
  const totals = names.flatMap(variant => associations.map(associationPolicy => ({variant,associationPolicy,counts:zero(),groupsMatched:0,groupsTotal:0})));
  for (const c of catalog.cases) {
    const matching = predictions.cases.filter(p => p.id === c.id); assert.equal(matching.length, 1);
    const p = matching[0]; assert.equal(p.sourcesUnchanged, true); assert.equal(p.assetCount, c.assets.length);
    assert.equal(p.bindings.length, c.assets.length); assert.equal(p.variants.length, 4);
    p.bindings.forEach((b,i) => {
      const a = c.assets[i];
      for (const key of ['caseID','assetID','ordinal','jpegSHA256','originalSHA256']) assert.deepEqual(b[key], a[key], 'Prediction binding mismatch: '+key);
      assert.equal(b.sourceOrdinal, a.sourceOrdinal ?? a.ordinal, 'Source ordinal mismatch');
      const proof = p.sourceProofs[b.sourceOrdinal];
      assert.equal(proof.assetID,b.assetID); assert.equal(proof.beforeSHA256,b.jpegSHA256); assert.equal(proof.afterSHA256,b.jpegSHA256);
      assert.deepEqual(proof.before,proof.after); assert.deepEqual(proof.errors,[]);
    });
    const relations = G.relations(c,draft), oldRelations = G.relations(c,M.empty(catalog));
    const results = new Map();
    for (const variant of names) for (const associationPolicy of associations) {
      const variants = p.variants.filter(v => v.variant === variant && v.associationPolicy === associationPolicy); assert.equal(variants.length,1);
      const v = variants[0], joins = joinedEdges(v.result,c.assets.length), counts = zero(), errors = [];
      assert.equal(v.configuration.metadataExperiment.associationPolicy,associationPolicy);
      assert.equal(v.configuration.pauseBridgeExperiment.policy, variant === 'legacy' ? 'focus-rect-and-cohort-separation-v1' : predictions.candidatePolicy);
      assert.equal(v.eventCount,c.assets.length,'Single-representation projection must have one event per asset');
      assert.match(v.eventMapFingerprint,/^[a-f0-9]{64}$/,'Missing event map identity');
      assert(Array.isArray(v.result.coverage),'Missing coverage');
      assert.equal(v.associationHypothesisAssumed,false,'No RAW/JPEG pairing hypothesis in single-representation evaluation');
      assert(v.engineSeconds.length === predictions.engineRepeats && v.engineSeconds.every(n => Number.isFinite(n) && n >= 0));
      relations.forEach((relation,i) => {
        const outcome = relation === 'unknown' ? 'unknown' : relation === 'same' ? (joins[i] ? 'TP' : 'FN') : (joins[i] ? 'FP' : 'TN');
        counts[outcome]++;
        if (outcome === 'FP' || outcome === 'FN') errors.push({firstOrdinal:i,result:outcome,left:c.assets[i].filename,right:c.assets[i+1].filename});
      });
      const groups = M.groups(c,draft).map(g => {
        const exact = v.result.ranges.find(r=>r.range.first===g.firstOrdinal && r.range.last===g.lastOrdinal);
        return {...g,exactObservedMembershipAndCompatibleKind:!!exact&&(g.kind==='sequence'||exact.kind===g.kind),completeGroupTruth:c.completeGroupTruth};
      });
      const row = {caseID:c.id,variant,associationPolicy,counts,errors,groups}; rows.push(row); results.set(variant+associationPolicy,{v,joins});
      const total = totals.find(t=>t.variant===variant&&t.associationPolicy===associationPolicy);
      for(const key of Object.keys(counts))total.counts[key]+=counts[key];
      total.groupsMatched+=groups.filter(g=>g.exactObservedMembershipAndCompatibleKind).length; total.groupsTotal+=groups.length;
    }
    for(const associationPolicy of associations){
      const before=results.get('legacy'+associationPolicy),after=results.get('candidate'+associationPolicy);
      assert.equal(before.v.eventCount,after.v.eventCount,'Boundary refinement changed capture event count');
      assert.equal(before.v.eventMapFingerprint,after.v.eventMapFingerprint,'Boundary refinement changed event association');
      assert.deepEqual(before.v.result.coverage,after.v.result.coverage,'Boundary refinement changed frame eligibility/coverage');
      const changed=[],lostKnownPositive=[],newFalseMerge=[],changedUnknown=[];
      relations.forEach((truth,i)=>{
        if(before.joins[i]===after.joins[i])return;
        const edge={firstOrdinal:i,left:c.assets[i].filename,right:c.assets[i+1].filename,relation:truth,beforeJoined:before.joins[i],afterJoined:after.joins[i]};changed.push(edge);
        if(truth==='same'&&before.joins[i]&&!after.joins[i])lostKnownPositive.push(edge);
        if(truth==='separate'&&!before.joins[i]&&after.joins[i])newFalseMerge.push(edge);
        if(truth==='unknown')changedUnknown.push(edge);
        if(oldRelations[i]!==truth)oldTruthDeltas.push({...edge,caseID:c.id,associationPolicy,oldRelation:oldRelations[i],acceptedRelation:truth});
      });
      deltas.push({caseID:c.id,associationPolicy,changed,lostKnownPositive,newFalseMerge,changedUnknown});
    }
  }
  return {schemaVersion:1,kind:'accepted-annotation-evaluation',rows,totals,deltas,oldTruthDeltas,
    qualityPassed:totals.filter(t=>t.variant==='candidate').every(t=>t.counts.FP===0&&t.counts.FN===0&&t.groupsMatched===t.groupsTotal)
      &&deltas.every(d=>!d.lostKnownPositive.length&&!d.newFalseMerge.length),
    scope:'Development annotations; unknown edges excluded. sequence labels allow either burst or interval type. DJI observed membership is checked without claiming a verified outside endpoint. Both association policies run on one representation per capture; this is not a RAW/JPEG pairing-precision benchmark.'};
}
module.exports={score,joinedEdges};
if(require.main===module){
  const fs=require('node:fs'); const [catalog,revision,predictions]=process.argv.slice(2).map(p=>JSON.parse(fs.readFileSync(p,'utf8')));
  process.stdout.write(JSON.stringify(score(catalog,revision,predictions))+'\n');
}
