'use strict';
// In-memory DOM interaction tests. No browser, file URL, image decode or network access.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(require.resolve('jsdom',{paths:[process.env.RAWMASTER_REVIEW_NODE_MODULES||path.join(__dirname,'node_modules')]}));
const repo=path.resolve(__dirname,'../..'),M=require(path.join(repo,'scripts/sequence-review-report/review.js'));
const C=JSON.parse(fs.readFileSync(process.argv[2],'utf8'));
const second=structuredClone(C.cases[0]);second.id='second';second.assets.forEach(a=>a.caseID='second');C.cases.push(second);
C.binding.truthSHA256ByCase.second=second.truthSHA256;
C.binding.assetBindings=C.cases.flatMap(c=>c.assets.map(a=>Object.fromEntries(['caseID','assetID','ordinal','jpegSHA256','originalSHA256'].map(k=>[k,a[k]]))));
C.visualReview={reviews:[{id:'a',caseID:'example',ordinals:[0,1]},{id:'b',caseID:'example',ordinals:[1,2]},{id:'c',caseID:'second',ordinals:[4,5]}].map(r=>({...r,confidence:'high',labelAssessment:'retain',observations:'observed',attribution:'rule',recommendation:'review'})),limitations:[]};
C.assetCount=12;
const template=fs.readFileSync(path.join(repo,'scripts/sequence-review-report/index.html'),'utf8');
const script=fs.readFileSync(path.join(repo,'scripts/sequence-review-report/review.js'),'utf8');
const key='RAWMaster-sequence-review:'+C.indexSHA256+':'+C.cases.map(c=>c.truthSHA256).join(':');
function setup(seed={},unavailable=false){
 const dom=new JSDOM(template.replace('__CATALOG_JSON__',JSON.stringify(C)),{url:'https://annotation.test.invalid/',runScripts:'outside-only'}),w=dom.window;
 w.HTMLElement.prototype.scrollIntoView=function(){};w.confirm=()=>true;
 w.URL.createObjectURL=()=> 'blob:local-test';w.URL.revokeObjectURL=()=>{};w.HTMLAnchorElement.prototype.click=function(){};
 for(const[k,v]of Object.entries(seed))w.localStorage.setItem(k,v);
 if(unavailable)Object.defineProperty(w,'localStorage',{value:{getItem:k=>seed[k]||null,setItem:()=>{throw new Error('storage unavailable');}}});
 w.eval(script);const $=id=>w.document.getElementById(id);
 return{dom,w,$,click:id=>{assert.equal($(id).disabled,false,id+' must be enabled');$(id).click();},input:(id,value)=>{$(id).value=value;$(id).dispatchEvent(new w.Event('input',{bubbles:true}));},select:(id,value)=>{$(id).value=value;$(id).dispatchEvent(new w.Event('change',{bubbles:true}));},state:()=>JSON.parse(w.localStorage.getItem(key+':workspace-v2')),draft:()=>JSON.parse(w.localStorage.getItem(key)),snapshot:()=>Object.fromEntries(Object.keys(w.localStorage).map(k=>[k,w.localStorage.getItem(k)]))};
}
const original=M.empty(C);M.caseEdit(original,'example').edgeEdits.push({leftAssetID:'f0',rightAssetID:'f1',relation:'separate',note:'existing annotation'});M.validate(original,C);
let a=setup({[key]:JSON.stringify(original)});
a.w.document.querySelector('[data-view="browse"]').click();
assert.deepEqual(a.draft(),original,'opening/navigation must preserve the schema1 draft byte meanings');
a.click('queue-next');assert.equal(a.state().selected,1);assert.equal(a.$('browse-view').hidden,false);
a.input('group-last','2');a.click('queue-next');assert.equal(a.$('pending-range').hidden,false);assert.equal(a.state().caseID,'example');
a.click('pending-stay');assert.equal(a.$('group-last').value,'2');
a.click('queue-next');a.click('pending-save');assert.equal(a.state().caseID,'second');assert.equal(a.state().selected,4);
assert.equal(a.draft().caseEdits[0].groupEdits[0].lastOrdinal,2);assert.equal(a.draft().caseEdits[0].edgeEdits[0].note,'existing annotation');
a.click('queue-previous');assert.equal(a.state().caseID,'example');assert.equal(a.state().selected,1);
a.$('auto-advance').checked=true;a.$('auto-advance').dispatchEvent(new a.w.Event('change'));
a.w.document.querySelector('[data-relation="same"]').click();assert.equal(a.state().selected,2);assert.equal(a.draft().caseEdits[0].edgeEdits.length,2);
a.$('search').value='F2';a.$('search').dispatchEvent(new a.w.Event('input'));assert.equal(a.$('search').value,'F2');
const seed=a.snapshot(),expected=a.draft();a.dom.window.close();a=setup(seed);
assert.equal(a.$('browse-view').hidden,false);assert.equal(a.state().selected,2);assert.equal(a.$('auto-advance').checked,true);assert.equal(a.$('search').value,'F2');assert.deepEqual(a.draft(),expected);
// Dirty forms survive refresh and a rejected invalid save does not navigate or alter labels.
a.input('group-last','0');a.click('queue-next');a.click('pending-save');assert.equal(a.state().caseID,'example');assert.equal(a.$('pending-range').hidden,false);assert.deepEqual(a.draft(),expected);
const dirty=a.snapshot();a.dom.window.close();a=setup(dirty);assert.equal(a.$('group-last').value,'0');assert.equal(a.state().rangeForm.last,'0');
a.click('queue-next');a.click('pending-discard');assert.equal(a.state().caseID,'second');assert.equal(a.state().selected,4);
a.w.document.querySelector('[data-relation="same"]').click();assert.equal(a.state().selected,4,'last pair cannot advance beyond final pair');assert.equal(a.$('edge-next').disabled,true);
// Complete-and-next is separate from labeling, never promotes an unknown edge to truth.
const labels=a.draft();a.click('complete-next');assert.equal(a.state().completed.length,1);assert.deepEqual(a.draft(),labels);
a.select('queue-mode','cases');a.click('queue-previous');assert.equal(a.state().caseID,'example');a.click('queue-next');assert.equal(a.state().caseID,'second');
a.select('queue-mode','groups');assert.ok(a.$('queue-item').options.length>0);assert.match(a.$('queue-position').textContent,/算法|F/);
a.select('queue-mode','errors');assert.ok(a.$('queue-item').options.length>0);
// Keyboard navigation ignores editing controls.
const selected=a.state().selected;a.$('group-first').dispatchEvent(new a.w.KeyboardEvent('keydown',{key:'ArrowRight',bubbles:true}));assert.equal(a.state().selected,selected);
// Undo/import/export remain available with the unchanged schema and bindings.
a.click('undo');M.validate(a.draft(),C,true);a.dom.window.close();
const b=setup({[key]:JSON.stringify(original)},true);b.w.document.querySelector('[data-view="browse"]').click();b.w.document.querySelector('[data-relation="same"]').click();assert.match(b.$('edge-info').textContent,/草稿：同组/);assert.equal(b.$('export').disabled,false);b.click('export');assert.match(b.$('status').textContent,/已导出/);b.dom.window.close();
// Explicit splitting modifies only the draft, preserves other annotations, and is undoable.
const split=setup({[key]:JSON.stringify(original)});split.w.document.querySelector('[data-view="browse"]').click();split.click('queue-next');
split.click('split-here');assert.equal(split.$('export').disabled,false);const splitDraft=split.draft();M.validate(splitDraft,C);
assert.equal(splitDraft.caseEdits[0].edgeEdits.find(e=>e.leftAssetID==='f1').relation,'separate');
assert.deepEqual(M.groups(C.cases[0],splitDraft).map(g=>[g.firstOrdinal,g.lastOrdinal]),[[2,3]]);
assert.equal(splitDraft.caseEdits[0].edgeEdits.find(e=>e.leftAssetID==='f0').note,'existing annotation');
split.click('undo');assert.deepEqual(split.draft(),original);split.dom.window.close();
// Saving a manually bounded group continues at the following file, not the next dataset/review card.
const fresh=M.empty(C);M.caseEdit(fresh,'example').removedGroupIDs=['truth'];const seq=setup({[key]:JSON.stringify(fresh)});
seq.w.document.querySelector('[data-view="browse"]').click();seq.click('save-group-next');assert.equal(seq.state().caseID,'example');assert.equal(seq.state().selected,2);
seq.click('save-group-next');assert.equal(seq.state().caseID,'example');assert.equal(seq.state().selected,4);
assert.deepEqual(M.groups(C.cases[0],seq.draft()).map(g=>[g.firstOrdinal,g.lastOrdinal]),[[0,1],[2,3]]);M.validate(seq.draft(),C);seq.dom.window.close();
const originalBefore=JSON.stringify(original), longCase=structuredClone(C.cases[0]);longCase.truth.groups[0].assetIDs=longCase.assets.map(a=>a.assetID);longCase.truth.negativePairs=[];
const two=M.splitGroup(longCase,M.empty(C),2,'new-right');assert.deepEqual(M.groups(longCase,two).map(g=>[g.firstOrdinal,g.lastOrdinal]),[[0,2],[3,5]]);M.validate(two,{...C,cases:[longCase,second]});
assert.equal(JSON.stringify(original),originalBefore);assert.throws(()=>M.splitGroup(C.cases[0],original,4,'outside'));
console.log('continuous DOM interactions passed: queues, dirty-form save/discard/reload, schema1 preservation, auto-advance, completion, keyboard, unavailable storage, explicit split/undo and successive ranges');
