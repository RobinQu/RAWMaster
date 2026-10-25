'use strict';
// In-memory DOM regression; no browser, media decoding or network.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(require.resolve('jsdom',{paths:[process.env.RAWMASTER_REVIEW_NODE_MODULES||path.join(__dirname,'node_modules')]}));
const repo=path.resolve(__dirname,'../..'),M=require(path.join(repo,'scripts/sequence-review-report/review.js'));
const C=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),key=M.storageKey(C);
const draft=M.empty(C),edit=M.caseEdit(draft,'example');
edit.edgeEdits=[{leftAssetID:'f1',rightAssetID:'f2',relation:'separate',note:'first boundary'},{leftAssetID:'f2',rightAssetID:'f3',relation:'unknown',note:'keep uncertain'}];
const raw=JSON.stringify(draft,null,2);assert.equal(M.conflicts(C,draft).length,2);
function setup(seed){
 const dom=new JSDOM(fs.readFileSync(path.join(repo,'scripts/sequence-review-report/index.html'),'utf8').replace('__CATALOG_JSON__',JSON.stringify(C)),{url:'https://annotation.test.invalid/',runScripts:'outside-only'}),w=dom.window;
 let captured,filename;w.HTMLElement.prototype.scrollIntoView=function(){};w.Blob=Blob;w.URL.createObjectURL=blob=>{captured=blob;return 'blob:in-memory';};w.URL.revokeObjectURL=()=>{};w.HTMLAnchorElement.prototype.click=function(){filename=this.download;};
 if(seed)w.localStorage.setItem(key,seed);w.eval(fs.readFileSync(path.join(repo,'scripts/sequence-review-report/review.js'),'utf8'));
 return{dom,w,$:id=>w.document.getElementById(id),exported:async()=>({value:JSON.parse(await captured.text()),filename})};
}
(async()=>{
 const a=setup(raw);
 assert.equal(a.$('browse-view').hidden,true);assert.equal(a.$('export').disabled,false);
 assert.equal(a.$('export-state').hidden,false);assert.match(a.$('export-message').textContent,/2 处标注冲突/);
 assert.equal(a.$('export-conflicts').querySelectorAll('button').length,2);
 a.$('export').click();let bundle=await a.exported();assert.match(bundle.filename,/sequence-review-backup/);
 assert.equal(bundle.value.kind,'RAWMaster-sequence-review-backup');assert.deepEqual(bundle.value.draft,draft);
 assert.throws(()=>M.validate(bundle.value,C));assert.deepEqual(M.readImport(bundle.value,C).draft,draft);
 assert.equal(a.w.localStorage.getItem(key),raw,'export must never rewrite original annotations');
 // Conflict localization works while the details view was previously hidden.
 a.$('export-conflicts').querySelector('button').click();assert.equal(a.$('browse-view').hidden,false);assert.match(a.$('selection').textContent,/F1.ARW/);
 a.$('group-first').value='-1';a.$('group-first').dispatchEvent(new a.w.Event('input'));
 a.$('export').click();bundle=await a.exported();assert.equal(bundle.value.workspace.rangeForm.first,'-1');assert.deepEqual(bundle.value.draft,draft);
 const b=setup();Object.defineProperty(b.$('import'),'files',{configurable:true,value:[{text:async()=>JSON.stringify(bundle.value)}]});
 await b.$('import').onchange({target:b.$('import')});
 assert.equal(b.$('browse-view').hidden,false);assert.equal(b.$('group-first').value,'-1');
 assert.deepEqual(JSON.parse(b.w.localStorage.getItem(key)),draft);assert.equal(b.$('export').disabled,false);
 assert.match(b.$('status').textContent,/备份已恢复/);
 const bad=M.clone(bundle.value);bad.draft.assetBindings[0].jpegSHA256='tampered';assert.throws(()=>M.readImport(bad,C));
 const invalid=M.clone(bundle.value);invalid.workspace.selected=999;assert.throws(()=>M.readImport(invalid,C));
 b.dom.window.close();a.dom.window.close();
 const repaired=setup(raw);repaired.$('repair-edge-splits').click();
 const saved=JSON.parse(repaired.w.localStorage.getItem(key));M.validate(saved,C);assert.equal(M.conflicts(C,saved).length,0);
 assert.deepEqual(saved.caseEdits[0].edgeEdits.slice().sort((a,b)=>a.leftAssetID.localeCompare(b.leftAssetID)),edit.edgeEdits);
 repaired.$('export').click();const clean=await repaired.exported();assert.equal(clean.value.kind,'RAWMaster-sequence-label-revision');assert.match(clean.filename,/label-revision/);M.validate(clean.value,C);
 repaired.$('undo').click();assert.deepEqual(JSON.parse(repaired.w.localStorage.getItem(key)),draft);assert.equal(repaired.$('export-state').hidden,false);repaired.dom.window.close();
 // Overlapping ranges and explicit cross-group "same" labels stay unresolved and exportable as backups.
 for(const overlap of [true,false]){
  const d=M.empty(C),e=M.caseEdit(d,'example');e.removedGroupIDs=['truth'];
  e.groupEdits=[{id:'left',firstOrdinal:0,lastOrdinal:overlap?2:1,kind:'burst'},{id:'right',firstOrdinal:2,lastOrdinal:3,kind:'burst'}];
  if(!overlap)e.edgeEdits=[{leftAssetID:'f1',rightAssetID:'f2',relation:'same',note:'manual merge pending'}];
  const before=JSON.stringify(d),s=setup(before);assert.equal(s.$('export').disabled,false);s.$('export').click();const backup=await s.exported();assert.deepEqual(backup.value.draft,d);assert.equal(backup.value.kind,'RAWMaster-sequence-review-backup');assert.equal(JSON.stringify(M.reconcileEdgeSplits(C,d)),before);s.dom.window.close();
 }
 console.log('Export recovery passed: visible global conflicts, always-clickable backup export, unfinished-form restoration, safe repair/undo, strict clean export, overlapping/cross-group conflicts preserved.');
})().catch(e=>{console.error(e);process.exitCode=1;});
