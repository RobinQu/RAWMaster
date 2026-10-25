'use strict';
// Both UI controllers run in an isolated in-memory DOM; no browser or network.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require(require.resolve('jsdom',{paths:[process.env.RAWMASTER_REVIEW_NODE_MODULES||path.join(__dirname,'node_modules')]}));
const repo=path.resolve(__dirname,'../..'),M=require(path.join(repo,'scripts/sequence-review-report/review.js')),G=require(path.join(repo,'scripts/sequence-review-report/guided-review.js'));
const C=JSON.parse(fs.readFileSync(process.argv[2],'utf8')),c=C.cases[0],key=M.storageKey(C),original=M.empty(C);
M.caseEdit(original,c.id).edgeEdits.push({leftAssetID:'f0',rightAssetID:'f1',relation:'separate',note:'retain user note'});
C.guidance={tasks:[1,2].map((n,i)=>({id:'task-'+i,caseID:c.id,firstOrdinal:n,scope:{first:1,last:3},title:'Question '+i,question:'Separate here?',reason:'Evidence, not a label',suggestion:'Human decides',visualObservation:'Observed in test'})),settled:[{text:'Already confirmed; no duplicate question'}]};
const truth=JSON.stringify(c.truth),raw=JSON.stringify(original,null,2);
let d=G.choose(c,original,1,'separate');M.validate(d,C);assert.equal(G.relation(c,d,1),'separate');assert.equal(G.relation(c,d,2),'same');
d=G.choose(c,d,2,'unknown');M.validate(d,C);assert.equal(G.relation(c,d,2),'unknown');
d=G.choose(c,d,1,'same');M.validate(d,C);assert.equal(G.relation(c,d,1),'same');assert.equal(G.relation(c,d,2),'unknown');
assert.equal(d.caseEdits[0].edgeEdits.find(e=>e.leftAssetID==='f0').note,'retain user note');assert.equal(JSON.stringify(c.truth),truth);
assert.equal(G.relation(c,d,4),'unknown','unlabeled context is never promoted to a negative');
const conflict=M.clone(original);M.caseEdit(conflict,c.id).edgeEdits.push({leftAssetID:'f1',rightAssetID:'f2',relation:'separate',note:'old conflict note'});
const fixed=G.choose(c,conflict,2,'unknown');M.validate(fixed,C);assert.equal(fixed.caseEdits[0].edgeEdits.find(e=>e.leftAssetID==='f1').note,'old conflict note');
const overlap=M.clone(original);overlap.caseEdits[0].groupEdits=[{id:'extra',firstOrdinal:0,lastOrdinal:2,kind:'burst'}];assert.throws(()=>G.choose(c,overlap,1,'separate'),/重叠/);
function setup(seed){
 const dom=new JSDOM(fs.readFileSync(path.join(repo,'scripts/sequence-review-report/index.html'),'utf8').replace('__CATALOG_JSON__',JSON.stringify(C)),{url:'https://annotation.test.invalid/',runScripts:'outside-only'}),w=dom.window;
 let blob;w.HTMLElement.prototype.scrollIntoView=function(){};w.Blob=Blob;w.URL.createObjectURL=x=>(blob=x,'blob:memory');w.URL.revokeObjectURL=()=>{};w.HTMLAnchorElement.prototype.click=function(){};
 for(const [k,v] of Object.entries(seed))w.localStorage.setItem(k,v);
 for(const file of ['review.js','guided-review.js'])w.eval(fs.readFileSync(path.join(repo,'scripts/sequence-review-report',file),'utf8'));
 return{dom,w,$:id=>w.document.getElementById(id),choose:value=>w.document.querySelector('[data-guide-relation="'+value+'"]').click(),snapshot:()=>Object.fromEntries(Object.keys(w.localStorage).map(k=>[k,w.localStorage.getItem(k)])),exported:async()=>JSON.parse(await blob.text())};
}
(async()=>{
 let a=setup({[key]:raw});assert.equal(a.$('advanced-tools').open,false);assert.equal(a.w.localStorage.getItem(key),raw);assert.equal(a.$('guide-list').children.length,2);
 assert.match(a.$('guide-position').textContent,/1 \/ 2/);assert.match(a.$('guide-progress').textContent,/2 \/ 2/);
 a.choose('separate');M.validate(JSON.parse(a.w.localStorage.getItem(key)),C);assert.equal(a.$('export-state').hidden,true);assert.match(a.$('guide-progress').textContent,/1 \/ 2/);
 a.$('guide-next').click();a.choose('unknown');assert.match(a.$('guide-current').textContent,/暂不确定/);assert.match(a.$('guide-progress').textContent,/1 \/ 2/);
 a.$('export').click();const exported=await a.exported();assert.equal(exported.kind,'RAWMaster-sequence-label-revision');M.validate(exported,C);
 const saved=a.snapshot();a.dom.window.close();a=setup(saved);assert.match(a.$('guide-position').textContent,/2 \/ 2/);assert.match(a.$('guide-current').textContent,/暂不确定/);
 a.$('guide-auto-next').checked=true;a.$('guide-auto-next').dispatchEvent(new a.w.Event('change'));a.$('guide-prev').click();a.choose('same');assert.match(a.$('guide-position').textContent,/2 \/ 2/);
 a.$('undo').click();assert.equal(G.relation(c,JSON.parse(a.w.localStorage.getItem(key)),1),'separate');
 a.$('guide-all').click();assert.equal(a.$('guide-context').querySelectorAll('button').length,6);assert.equal(a.$('advanced-tools').open,false);
 a.$('guide-context').querySelectorAll('button')[4].click();assert.match(a.$('guide-position').textContent,/5、6/);assert.match(a.$('guide-current').textContent,/暂不确定/);
 a.w.document.dispatchEvent(new a.w.KeyboardEvent('keydown',{key:'1',bubbles:true}));M.validate(JSON.parse(a.w.localStorage.getItem(key)),C);assert.equal(G.relation(c,JSON.parse(a.w.localStorage.getItem(key)),4),'same');
 a.dom.window.close();
 // An existing conflicted v4 draft is read as-is; only a new explicit choice reconciles it.
 const old=JSON.stringify(conflict),b=setup({[key]:old});assert.equal(b.w.localStorage.getItem(key),old);assert.match(b.$('guide-position').textContent,/2 \/ 2/,'start at the first question not already answered');b.choose('separate');M.validate(JSON.parse(b.w.localStorage.getItem(key)),C);assert.equal(b.$('export-state').hidden,true);b.$('undo').click();assert.deepEqual(JSON.parse(b.w.localStorage.getItem(key)),conflict);b.dom.window.close();
 console.log('Guided workflow passed: explicit answers, automatic split/merge, unknown preservation, notes, legacy draft/undo, five-step-style navigation, refresh and keyboard, no silent recommendation adoption.');
})().catch(e=>{console.error(e);process.exitCode=1;});
