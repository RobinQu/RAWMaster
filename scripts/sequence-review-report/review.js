'use strict';
const ReviewModel = (() => {
  const clone = value => JSON.parse(JSON.stringify(value));
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  function parseStrictJSON(text) {
    assert(text.length <= 10 * 1024 * 1024, '修订文件过大'); let i = 0;
    const ws = () => { while (/\s/.test(text[i] || '') && i < text.length) i++; };
    function string() { const start = i++; while (i < text.length) { if (text[i] === '\\') { i += 2; continue; } if (text[i++] === '"') return JSON.parse(text.slice(start, i)); } throw new Error('无效 JSON 字符串'); }
    function value(depth = 0) {
      assert(depth < 30, 'JSON 层级过深'); ws(); const c = text[i];
      if (c === '"') return string();
      if (c === '{') { i++; const result = Object.create(null); ws(); if (text[i] === '}') { i++; return result; } while (true) { ws(); assert(text[i] === '"', '无效 JSON 字段'); const key = string(); assert(!Object.hasOwn(result, key) && key !== '__proto__', 'JSON 有重复或无效字段'); ws(); assert(text[i++] === ':', '无效 JSON 分隔'); result[key] = value(depth + 1); ws(); const next = text[i++]; if (next === '}') return result; assert(next === ',', '无效 JSON 对象'); } }
      if (c === '[') { i++; const result = []; ws(); if (text[i] === ']') { i++; return result; } while (true) { result.push(value(depth + 1)); ws(); const next = text[i++]; if (next === ']') return result; assert(next === ',', '无效 JSON 数组'); } }
      const match = text.slice(i).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/); assert(match, '无效 JSON 值'); i += match[0].length; const result = JSON.parse(match[0]); assert(typeof result !== 'number' || Number.isFinite(result), '数字超出范围'); return result;
    }
    const result = value(); ws(); assert(i === text.length, 'JSON 有多余内容'); return result;
  }
  function empty(catalog) { return {kind: 'RAWMaster-sequence-label-revision', schemaVersion: 1, ...clone(catalog.binding), caseEdits: [], reviewer: '人工复核', note: ''}; }
  function caseEdit(draft, id) { let edit = draft.caseEdits.find(c => c.caseID === id); if (!edit) { edit = {caseID: id, edgeEdits: [], groupEdits: [], removedGroupIDs: []}; draft.caseEdits.push(edit); } return edit; }
  function groups(c, draft) {
    const edit = draft.caseEdits.find(e => e.caseID === c.id), map = new Map(c.truth.groups.map(g => [g.id, {id: g.id, firstOrdinal: Math.min(...g.assetIDs.map(id => c.assets.find(a => a.assetID === id).ordinal)), lastOrdinal: Math.max(...g.assetIDs.map(id => c.assets.find(a => a.assetID === id).ordinal)), kind: g.kind}]));
    if (edit) { edit.removedGroupIDs.forEach(id => map.delete(id)); edit.groupEdits.forEach(g => map.set(g.id, g)); } return [...map.values()].sort((a, b) => a.firstOrdinal - b.firstOrdinal);
  }
  function truthRelation(c, first) {
    const a = c.assets[first]?.assetID, b = c.assets[first + 1]?.assetID;
    if (c.truth.groups.some(g => g.assetIDs.includes(a) && g.assetIDs.includes(b))) return 'same';
    if (c.truth.negativePairs.some(p => (p.from === a && p.to === b) || (p.from === b && p.to === a))) return 'separate';
    return 'unknown';
  }
  function conflicts(catalog, draft) {
    const found = [];
    for (const c of catalog.cases) {
      const gs = groups(c, draft), edit = draft.caseEdits.find(e => e.caseID === c.id);
      for (let i = 1; i < gs.length; i++) if (gs[i].firstOrdinal <= gs[i - 1].lastOrdinal) found.push(c.id + '：组范围重叠');
      for (const edge of edit?.edgeEdits || []) {
        const first = c.assets.find(a => a.assetID === edge.leftAssetID).ordinal;
        if (edge.relation !== 'same' && gs.some(g => first >= g.firstOrdinal && first + 1 <= g.lastOrdinal)) found.push(c.id + ' #' + first + '：边界关系与草稿组范围冲突，请调整范围或恢复关系');
        const leftGroup = gs.find(g => first >= g.firstOrdinal && first <= g.lastOrdinal), rightGroup = gs.find(g => first + 1 >= g.firstOrdinal && first + 1 <= g.lastOrdinal);
        if (edge.relation === 'same' && leftGroup && rightGroup && leftGroup.id !== rightGroup.id) found.push(c.id + ' #' + first + '：同组关系连接了两个不同的草稿组，请合并范围或恢复关系');
      }
    } return found;
  }
  function validate(draft, catalog, allowConflicts = false) {
    const keys = (o, allowed) => assert(o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).every(k => allowed.includes(k)), '修订含未知字段');
    keys(draft, ['kind', 'schemaVersion', 'indexSHA256', 'truthSHA256ByCase', 'assetBindings', 'caseEdits', 'reviewer', 'note']);
    assert(draft.kind === 'RAWMaster-sequence-label-revision' && draft.schemaVersion === 1, '修订格式不支持');
    assert(draft.indexSHA256 === catalog.binding.indexSHA256, '数据集版本不一致');
    assert(Object.keys(draft.truthSHA256ByCase).length === catalog.cases.length && catalog.cases.every(c => draft.truthSHA256ByCase[c.id] === c.truthSHA256), '旧标签版本不一致');
    assert(Array.isArray(draft.assetBindings) && draft.assetBindings.length === catalog.binding.assetBindings.length, '文件绑定数量不一致');
    draft.assetBindings.forEach((a, i) => { keys(a, ['caseID', 'assetID', 'ordinal', 'jpegSHA256', 'originalSHA256']); assert(Object.keys(a).length === 5 && Object.keys(catalog.binding.assetBindings[i]).every(k => a[k] === catalog.binding.assetBindings[i][k]), '文件身份或哈希不一致'); });
    assert(typeof draft.reviewer === 'string' && draft.reviewer.length <= 500 && typeof draft.note === 'string' && draft.note.length <= 10000, '修订说明无效');
    assert(Array.isArray(draft.caseEdits) && draft.caseEdits.length <= catalog.cases.length, '案例修订无效'); const seen = new Set();
    for (const edit of draft.caseEdits) {
      keys(edit, ['caseID', 'edgeEdits', 'groupEdits', 'removedGroupIDs']); const c = catalog.cases.find(c => c.id === edit.caseID);
      assert(c && !seen.has(c.id), '案例重复或不存在'); seen.add(c.id); const edgeIDs = new Set(), groupIDs = new Set();
      assert(Array.isArray(edit.edgeEdits) && edit.edgeEdits.length <= c.assets.length - 1, '边界数量无效');
      for (const edge of edit.edgeEdits) { keys(edge, ['leftAssetID', 'rightAssetID', 'relation', 'note']); const first = c.assets.findIndex(a => a.assetID === edge.leftAssetID); assert(first >= 0 && c.assets[first + 1]?.assetID === edge.rightAssetID && !edgeIDs.has(first), '必须是相邻且唯一的照片边界'); edgeIDs.add(first); assert(['same', 'separate', 'unknown'].includes(edge.relation) && typeof edge.note === 'string' && edge.note.length <= 2000, '边界修订无效'); }
      assert(Array.isArray(edit.groupEdits) && edit.groupEdits.length <= c.assets.length, '组数量无效');
      for (const group of edit.groupEdits) { keys(group, ['id', 'firstOrdinal', 'lastOrdinal', 'kind']); assert(typeof group.id === 'string' && group.id.length > 0 && group.id.length <= 128 && !groupIDs.has(group.id), '组 ID 无效或重复'); groupIDs.add(group.id); assert(Number.isInteger(group.firstOrdinal) && Number.isInteger(group.lastOrdinal) && group.firstOrdinal >= 0 && group.lastOrdinal > group.firstOrdinal && group.lastOrdinal < c.assets.length && ['burst', 'interval', 'sequence'].includes(group.kind), '组范围或类型无效'); }
      assert(Array.isArray(edit.removedGroupIDs) && new Set(edit.removedGroupIDs).size === edit.removedGroupIDs.length && edit.removedGroupIDs.every(id => c.truth.groups.some(g => g.id === id) && !groupIDs.has(id)), '移除的组无效或同时被编辑');
    }
    const problems = conflicts(catalog, draft); assert(allowConflicts || problems.length === 0, problems.join('；')); return clone(draft);
  }
  function importDraft(draft, catalog, allowConflicts = false) {
    if (draft.indexSHA256 === catalog.binding.indexSHA256) return validate(draft, catalog, allowConflicts);
    const projection = catalog.annotationProjection;
    assert(projection, '数据集版本不一致');
    const old = validate(draft, projection.legacyCatalog, allowConflicts);
    const changed = new Set(projection.descriptor.cases.map(c => c.caseID));
    assert(!old.caseEdits.some(e => changed.has(e.caseID) && (e.edgeEdits.length || e.groupEdits.length || e.removedGroupIDs.length)),
      '旧 DJI 修订涉及 DNG/JPEG 文件编号，不能自动转换；旧草稿未改写，请保留旧导出并在 JPEG 序列重新标注');
    const next = empty(catalog);
    next.caseEdits = clone(old.caseEdits.filter(e => !changed.has(e.caseID)));
    next.reviewer = old.reviewer; next.note = old.note;
    return validate(next, catalog, allowConflicts);
  }
  function storageKey(catalog) { return 'RAWMaster-sequence-review:'+catalog.indexSHA256+':'+catalog.cases.map(c=>c.truthSHA256).join(':'); }
  function validateWorkspace(w, catalog) {
    const c=catalog.cases.find(c=>c.id===w?.caseID);
    assert(w && w.version===1 && c && Number.isInteger(w.selected) && w.selected>=0 && w.selected<c.assets.length, '备份浏览位置无效');
    assert(Number.isInteger(w.page) && w.page>=0 && w.page<=Math.ceil(c.assets.length/60), '备份页码无效');
    assert(catalog.algorithms.some(a=>a.id===w.algorithmID) && ['reviews','cases','groups','errors'].includes(w.mode) && ['review','browse'].includes(w.view), '备份队列无效');
    for(const k of ['itemKey','groupID','search']) assert(typeof w[k]==='string' && w[k].length<=1000, '备份表单无效');
    assert(typeof w.autoAdvance==='boolean' && Array.isArray(w.completed) && w.completed.length<=100000 && w.completed.every(k=>typeof k==='string' && k.length<=1000), '备份进度无效');
    if(w.rangeForm!==null) { const f=w.rangeForm;assert(f && typeof f.groupID==='string' && f.groupID.length<=128 && typeof f.first==='string' && f.first.length<=20 && typeof f.last==='string' && f.last.length<=20 && ['burst','interval','sequence'].includes(f.kind), '备份范围表单无效'); }
    return clone(w);
  }
  function exportBundle(draft, catalog, workspace) {
    validate(draft,catalog,true);validateWorkspace(workspace,catalog);
    if(conflicts(catalog,draft).length || workspace.rangeForm) return {kind:'RAWMaster-sequence-review-backup',schemaVersion:1,draft:clone(draft),workspace:clone(workspace)};
    return validate(draft,catalog);
  }
  function readImport(value, catalog) {
    if(value?.kind!=='RAWMaster-sequence-review-backup') return {draft:importDraft(value,catalog,true),workspace:null};
    assert(value.schemaVersion===1 && Object.keys(value).every(k=>['kind','schemaVersion','draft','workspace'].includes(k)), '草稿备份格式不支持');
    const draft=importDraft(value.draft,catalog,true);
    return {draft,workspace:value.draft.indexSHA256===catalog.indexSHA256?validateWorkspace(value.workspace,catalog):null};
  }
  function splitGroup(c, draft, first, newID, relation = 'separate') {
    const next=clone(draft), group=groups(c,next).find(g=>first>=g.firstOrdinal && first+1<=g.lastOrdinal);
    assert(group, '当前两张照片不在同一个草稿组内');
    const edit=caseEdit(next,c.id), parts=[[group.firstOrdinal,first],[first+1,group.lastOrdinal]].filter(([a,b])=>b>a);
    edit.groupEdits=edit.groupEdits.filter(g=>g.id!==group.id);
    edit.removedGroupIDs=edit.removedGroupIDs.filter(id=>id!==group.id);
    if(!parts.length && c.truth.groups.some(g=>g.id===group.id)) edit.removedGroupIDs.push(group.id);
    parts.forEach(([a,b],i)=>edit.groupEdits.push({id:i===0?group.id:newID,firstOrdinal:a,lastOrdinal:b,kind:group.kind}));
    const left=c.assets[first],right=c.assets[first+1];
    const note=edit.edgeEdits.find(e=>e.leftAssetID===left.assetID)?.note||'';
    edit.edgeEdits=edit.edgeEdits.filter(e=>e.leftAssetID!==left.assetID);
    edit.edgeEdits.push({leftAssetID:left.assetID,rightAssetID:right.assetID,relation,note});
    return next;
  }
  function reconcileEdgeSplits(catalog, draft) {
    let next=clone(draft),counter=0;
    for(const c of catalog.cases) for(const edge of draft.caseEdits.find(e=>e.caseID===c.id)?.edgeEdits||[]) {
      if(edge.relation==='same')continue;
      const first=c.assets.findIndex(a=>a.assetID===edge.leftAssetID);
      while(groups(c,next).some(g=>first>=g.firstOrdinal && first+1<=g.lastOrdinal)) {
        let id;do{id='edge-split-'+first+'-'+counter++;}while(groups(c,next).some(g=>g.id===id));
        next=splitGroup(c,next,first,id,edge.relation);
      }
    }
    return next;
  }
  function queue(catalog, mode, algorithmID) {
    const items = [];
    for (const c of catalog.cases) {
      const add = (key, first, last, title) => items.push({key, caseID:c.id, first, last, title});
      if (mode === 'cases') add('case:'+c.id, 0, c.assets.length-1, c.id);
      if (mode === 'groups') for (const [i,g] of (c.algorithms.find(a=>a.id===algorithmID)?.ranges || []).entries()) add('group:'+algorithmID+':'+c.id+':'+i,g.range.first,g.range.last,c.id+' · 算法组 '+(i+1));
      if (mode === 'errors') for (const e of catalog.errors.filter(e=>e.caseID===c.id).sort((a,b)=>a.firstOrdinal-b.firstOrdinal)) add('error:'+e.id,e.firstOrdinal,e.firstOrdinal+1,c.id+' · 历史边界');
    }
    if (mode === 'reviews') for (const r of catalog.visualReview.reviews) items.push({key:'review:'+r.id,caseID:r.caseID,first:Math.min(...r.ordinals),last:Math.max(...r.ordinals),title:r.caseID+' · 复核片段'});
    if (mode === 'reviews') for (const c of catalog.cases.filter(c=>c.annotationOnly)) items.push({key:'annotation:'+c.id,caseID:c.id,first:0,last:c.assets.length-1,title:c.id+' · JPEG 序列标注'});
    return items;
  }
  function position(items, caseID, ordinal, preferredKey) {
    const exact=items.findIndex(i=>i.key===preferredKey && i.caseID===caseID && ordinal>=i.first && ordinal<=i.last);
    return exact>=0 ? exact : items.findIndex(i=>i.caseID===caseID && ordinal>=i.first && ordinal<=i.last);
  }
  return {clone, empty, caseEdit, groups, truthRelation, conflicts, validate, parseStrictJSON, queue, position, splitGroup, importDraft, storageKey, validateWorkspace, exportBundle, readImport, reconcileEdgeSplits};
})();
if (typeof module !== 'undefined') module.exports = ReviewModel;
if (typeof document !== 'undefined') (() => {
  const C=JSON.parse(document.getElementById('catalog-data').textContent), M=ReviewModel;
  const $=id=>document.getElementById(id), el=(tag,text,cls)=>{const n=document.createElement(tag);if(text!=null)n.textContent=text;if(cls)n.className=cls;return n;};
  const storageKey=M.storageKey(C);
  const workspaceKey=storageKey+':workspace-v2';
  const subscribers=new Set();let guidedWorkspace=()=>null,guidedRestore=null;
  let draft=M.empty(C),history=[],caseID=C.cases[0].id,algorithmID=C.algorithms.find(a=>a.id==='009:009-strict')?.id||C.algorithms.at(-1)?.id,page=0,selected=0,errorLimit=50;
  let mode='reviews',itemKey='',view='review',completed=new Set(),rangeDirty=false,rangeGroupID='',pendingMove=null,workspaceWarning=false;
  const typeName={burst:'连拍',interval:'间隔',sequence:'序列'},relationName={same:'同组',separate:'分开',unknown:'未知'};
  function status(text,bad=false){$('status').textContent=text;$('status').className=bad?'warning':'';}
  function persist(){try{localStorage.setItem(storageKey,JSON.stringify(draft));status('已保存到此浏览器。完成后点击“导出标注”。');}catch(_){status('浏览器未允许本地保存，草稿仍可编辑，请导出 JSON 留存。',true);}}
  try{const old=localStorage.getItem(storageKey);if(old)draft=M.validate(M.parseStrictJSON(old),C,true);
    else if(C.annotationProjection){const legacy=localStorage.getItem(M.storageKey(C.annotationProjection.legacyCatalog));if(legacy){draft=M.importDraft(M.parseStrictJSON(legacy),C,true);status('已兼容读取旧版其他数据集标注；新版使用独立存储，旧草稿保持不变。请导出新版修订留存。');}}
  }catch(e){status('本地草稿未载入；原存储未改写。'+e.message,true);}
  let restored=null;
  try{const text=localStorage.getItem(workspaceKey);if(text){const w=M.parseStrictJSON(text),c=C.cases.find(c=>c.id===w.caseID);if(w.version===1 && c && Number.isInteger(w.selected)&&w.selected>=0&&w.selected<c.assets.length){restored=w;caseID=c.id;selected=w.selected;page=Number.isInteger(w.page)&&w.page>=0?w.page:Math.floor(selected/60);if(C.algorithms.some(a=>a.id===w.algorithmID))algorithmID=w.algorithmID;if(['reviews','cases','groups','errors'].includes(w.mode))mode=w.mode;itemKey=typeof w.itemKey==='string'?w.itemKey:'';rangeGroupID=typeof w.groupID==='string'&&M.groups(c,draft).some(g=>g.id===w.groupID)?w.groupID:'';view=w.view==='browse'?'browse':'review';const keys=new Set(['reviews','cases','errors'].flatMap(m=>M.queue(C,m,algorithmID).map(i=>i.key)));for(const a of C.algorithms)for(const i of M.queue(C,'groups',a.id))keys.add(i.key);completed=new Set((Array.isArray(w.completed)?w.completed:[]).filter(k=>keys.has(k)));}}}catch(_){status('上次浏览位置无法恢复；标注草稿不受影响。',true);}
  function snapshotWorkspace(){return {version:1,caseID,selected,page,algorithmID,mode,itemKey,groupID:rangeGroupID,view,completed:[...completed],autoAdvance:$('auto-advance').checked,search:$('search').value,rangeForm:rangeDirty?{groupID:rangeGroupID,first:$('group-first').value,last:$('group-last').value,kind:$('group-kind').value}:null,guided:guidedWorkspace()};}
  function persistWorkspace(){try{localStorage.setItem(workspaceKey,JSON.stringify(snapshotWorkspace()));}catch(_){if(!workspaceWarning){status('浏览器无法保存浏览位置；请导出标注后再关闭。',true);workspaceWarning=true;}}}
  function restoreBackupWorkspace(w){guidedRestore=w.guided||null;caseID=w.caseID;selected=w.selected;page=w.page;algorithmID=w.algorithmID;mode=w.mode;itemKey=w.itemKey;rangeGroupID=w.groupID;view=w.view;completed=new Set(w.completed);$('auto-advance').checked=w.autoAdvance;$('search').value=w.search;rangeDirty=!!w.rangeForm;if(w.rangeForm){rangeGroupID=w.rangeForm.groupID;$('group-first').value=w.rangeForm.first;$('group-last').value=w.rangeForm.last;$('group-kind').value=w.rangeForm.kind;}}

  function change(fn,onCommit){const next=M.clone(draft);try{fn(next);M.validate(next,C,true);history.push(M.clone(draft));if(history.length>100)history.shift();draft=next;if(onCommit)onCommit();persist();renderDraft();renderBrowse();return true;}catch(e){status(e.message,true);return false;}}
  function option(value,title){const n=el('option',title);n.value=value;return n;}
  function requestMove(fn){if(rangeDirty){if($('advanced-tools'))$('advanced-tools').open=true;pendingMove=fn;$('pending-range').hidden=false;status('当前范围尚未保存，请先选择如何处理。',true);return false;}fn();return true;}
  function resetRange(){rangeDirty=false;rangeGroupID='';$('group-first').value='';$('pending-range').hidden=true;pendingMove=null;}
  function currentCase(){return C.cases.find(c=>c.id===caseID);}
  function currentUnit(c){return c.algorithms.find(a=>a.id===algorithmID);}
  function groupAt(gs,n){return gs.find(g=>n>=g.firstOrdinal&&n<=g.lastOrdinal);}
  function jump(id,ordinal,queueMode,preferred){return requestMove(()=>{resetRange();caseID=id;selected=ordinal;page=Math.floor(ordinal/60);if(queueMode)mode=queueMode;itemKey=preferred||'';$('search').value='';rangeGroupID=groupAt(M.groups(currentCase(),draft),selected)?.id||'';setView('browse');renderBrowse();$('annotation-nav').scrollIntoView({block:'start'});});}
  function navigate(delta,mark=false){requestMove(()=>{const items=M.queue(C,mode,algorithmID),i=M.position(items,caseID,selected,itemKey);if(mark){if(i<0)return;const problems=M.conflicts(C,draft).filter(x=>x.startsWith(caseID+' ' )||x.startsWith(caseID+'：'));if(problems.length){status('本数据集还有范围冲突，请解决后再标为完成。',true);return;}completed.add(items[i].key);}const next=i<0?(delta>0?0:items.length-1):i+delta;if(next>=0&&next<items.length){const x=items[next];jump(x.caseID,x.first,mode,x.key);}else{renderNavigation();persistWorkspace();if(mark)status('已完成当前队列最后一段；请导出标注。');}});}
  function selectOrdinal(n){if(n>=0&&n<currentCase().assets.length)requestMove(()=>{resetRange();selected=n;page=Math.floor(n/60);$('search').value='';rangeGroupID=groupAt(M.groups(currentCase(),draft),n)?.id||'';renderBrowse();});}
  function renderNavigation(){const items=M.queue(C,mode,algorithmID),i=M.position(items,caseID,selected,itemKey);if(i>=0)itemKey=items[i].key;$('queue-mode').value=mode;$('queue-item').replaceChildren(...items.map((x,n)=>option(x.key,(completed.has(x.key)?'✓ ':'')+(n+1)+'. '+x.title+' · #'+x.first+'–'+x.last)));$('queue-item').value=i>=0?items[i].key:'';$('queue-item').disabled=!items.length;$('queue-previous').disabled=!items.length||i===0;$('queue-next').disabled=!items.length||i===items.length-1;$('complete-next').disabled=i<0;const x=items[i],c=x?C.cases.find(c=>c.id===x.caseID):null;$('queue-position').textContent=(i>=0?(i+1):'—')+' / '+items.length+' · 已完成 '+items.filter(x=>completed.has(x.key)).length+(x?' · '+c.assets[x.first].filename+' → '+c.assets[x.last].filename:' · 当前照片不在此队列，选择一段继续');}
  function thumbnail(a,cb){const b=el('button');b.type='button';const img=document.createElement('img');img.src=a.thumbnail;img.alt=a.filename+' / '+a.assetID;img.loading='lazy';b.append(img);b.onclick=cb;return b;}
  function addFact(card,title,text){const p=el('div',null,'fact');p.append(el('b',title),el('p',Array.isArray(text)?text.join(' '):text));card.append(p);}
  function renderIntro(){const id=C.algorithms.find(a=>a.id==='009:009-strict')?.id||algorithmID,sony=C.cases.filter(c=>!c.id.startsWith('dji')).map(c=>c.algorithms.find(a=>a.id===id)).filter(Boolean);$('summary').append(el('h2','封存结果 · 依据旧标签'),el('p','草稿新边界尚未计入这些指标；旧的整组命中率不能证明能区分后来补标的内部连拍段。','warning'));const stats=el('div',null,'stats');for(const [k,t]of [['truePositive','正确连接'],['falsePositive','错误合并'],['falseNegative','错误拆分'],['trueNegative','已标负边分开']]){const n=el('div',null,'stat');n.append(el('strong',sony.reduce((s,u)=>s+(u.metrics[k]||0),0)),el('span',t));stats.append(n);}$('summary').append(stats,el('p',C.annotationProjection?'DJI 仅保留 JPEG 拍摄序列供标注；历史 DNG/JPEG 文件级评分不适用于此标注集，尚未重新运行 JPEG 序列评测。':'DJI 严格模式与假设配对结果分开保留；假设改善不代表配对精度已证实。','muted'));$('unknown').textContent='仍未知：'+C.cases.flatMap(c=>c.assets.filter(a=>c.unknownAssetIDs.includes(a.assetID))).map(a=>a.filename).join(' / ')+'。不自动赋予新真值。';$('unknown').className='warning';$('provenance').append(el('p',C.assetCount+' 个文件 / '+C.cases.length+' 个数据集 · '+C.indexSHA256));for(const a of C.artifacts)$('provenance').append(el('p',a.id+' · SHA256 '+a.sha256));for(const t of C.visualReview.limitations||[])$('provenance').append(el('p',t));$('binding').textContent=C.datasetID+' · '+C.indexSHA256.slice(0,12);}
  function renderReviews(){const target=$('review-cards');target.replaceChildren();for(const r of C.visualReview.reviews){const c=C.cases.find(c=>c.id===r.caseID),card=el('article',null,'card'),images=el('div',null,'images');card.append(el('span',r.caseID+' · '+r.confidence,'eyebrow'),el('h3',({retain:'建议保留旧标签','human-review':'需要你判断拍摄意图',unknown:'保持未知'})[r.labelAssessment]));const ord=r.ordinals.length<=4?r.ordinals:[r.ordinals[0],r.ordinals[Math.floor(r.ordinals.length/2)],r.ordinals.at(-1)];const open=()=>jump(c.id,r.ordinals[0],'reviews','review:'+r.id);for(const n of ord)images.append(thumbnail(c.assets[n],open));card.append(images);addFact(card,'实际看到',r.observations);addFact(card,'算法归因',r.attribution);addFact(card,'人工复核建议',r.recommendation);if(r.ordinals.length>4){const d=el('details');d.append(el('summary','实际查看 '+r.ordinals.length+' 张 · 展开文件清单'),el('small',r.ordinals.map(i=>c.assets[i].filename).join(' / ')));card.append(d);}else card.append(el('small','已看：'+r.ordinals.map(i=>c.assets[i].filename).join(' / ')));const b=el('button','查看这段并连续标注','jump');b.onclick=open;card.append(b);target.append(card);}for(const c of C.cases.filter(c=>c.annotationOnly)){const card=el('article',null,'card'),images=el('div',null,'images'),open=()=>jump(c.id,0,'reviews','annotation:'+c.id);card.append(el('span',c.id,'eyebrow'),el('h3','JPEG 序列标注'),el('p',c.annotationNote));for(const n of [...new Set([0,Math.floor(c.assets.length/2),c.assets.length-2,c.assets.length-1])])images.append(thumbnail(c.assets[n],open));card.append(images,el('p','缩图仅作导航；本卡片不新增视觉复核结论。','muted'));const b=el('button','标注这段 JPEG 序列','jump');b.onclick=open;card.append(b);target.append(card);}if(!C.visualReview.reviews.length)target.append(el('p','未提供实际视觉复核。','warning'));$('error-title').textContent='完整历史错误清单 · '+C.errors.length+' 个边界（含已修复错误）';renderErrors();}
  function renderErrors(){const q=$('error-search').value.toLowerCase(),cs=$('error-case').value,alg=$('error-algorithm').value,errors=C.errors.filter(e=>(!cs||e.caseID===cs)&&(!alg||e.occurrences.some(o=>o.algorithmID===alg))&&(!q||(e.caseID+' '+e.occurrences.map(o=>o.outcome+' '+o.algorithmID).join(' ')+' '+C.cases.find(c=>c.id===e.caseID).assets.slice(e.firstOrdinal,e.firstOrdinal+2).map(a=>a.filename+' '+a.assetID).join(' ')).toLowerCase().includes(q)));const table=el('table'),head=el('tr');['数据集 / 边界','旧标签','历史失败版本','操作'].forEach(t=>head.append(el('th',t)));table.append(head);for(const e of errors.slice(0,errorLimit)){const c=C.cases.find(c=>c.id===e.caseID),row=el('tr'),td=el('td'),b=el('button','查看 / 连续标注');row.append(el('td',c.id+' #'+e.firstOrdinal+' → #'+(e.firstOrdinal+1)+'\n'+c.assets[e.firstOrdinal].filename+' / '+c.assets[e.firstOrdinal+1].filename),el('td',relationName[e.expected]),el('td',e.occurrences.map(o=>o.algorithmID+':'+o.outcome).join(' / ')));b.onclick=()=>jump(c.id,e.firstOrdinal,'errors','error:'+e.id);td.append(b);row.append(td);table.append(row);}$('error-list').replaceChildren(el('p','当前 '+errors.length+' 个边界；显示 '+Math.min(errors.length,errorLimit)),table);$('more-errors').disabled=errorLimit>=errors.length;}
  function renderDraft(){const n=draft.caseEdits.reduce((s,c)=>s+c.edgeEdits.length+c.groupEdits.length+c.removedGroupIDs.length,0);$('draft-count').textContent=n+' 项草稿修改';$('undo').disabled=!history.length;const problems=M.conflicts(C,draft);$('conflicts').textContent=problems.join('；');$('export').disabled=false;$('export').title=problems.length||rangeDirty?'导出可恢复草稿备份，包含冲突和未保存表单':'导出已保存的修订';
    $('export-state').hidden=!problems.length&&!rangeDirty;$('export-message').textContent=(problems.length?problems.length+' 处标注冲突。':'')+(rangeDirty?'有尚未保存的范围。':'')+'此时点击“导出标注”会保存可恢复的草稿备份；解决后再导出正式修订。';
    $('repair-edge-splits').hidden=!C.cases.some(c=>(draft.caseEdits.find(e=>e.caseID===c.id)?.edgeEdits||[]).some(e=>e.relation!=='same'&&M.groups(c,draft).some(g=>{const n=c.assets.findIndex(a=>a.assetID===e.leftAssetID);return n>=g.firstOrdinal&&n+1<=g.lastOrdinal;})));
    $('export-conflicts').replaceChildren(...problems.map(text=>{const row=el('div'),c=C.cases.find(c=>text.startsWith(c.id+' ')||text.startsWith(c.id+'：')),b=el('button','定位');b.onclick=()=>{if(c)jump(c.id,Number(text.match(/#(\d+)：/)?.[1]||0),'cases','case:'+c.id);};row.append(b,el('span',text));return row;}));
  }
  function renderBrowse(){const c=currentCase(),u=currentUnit(c),gs=M.groups(c,draft);$('case').value=c.id;$('algorithm').value=algorithmID;const q=$('search').value.toLowerCase(),assets=c.assets.filter(a=>!q||(a.filename+' '+a.assetID+' '+a.ordinal).toLowerCase().includes(q));page=Math.max(0,Math.min(page,Math.ceil(assets.length/60)-1));$('page').textContent=(assets.length?page+1:0)+' / '+Math.ceil(assets.length/60);$('previous').disabled=page===0;$('next').disabled=(page+1)*60>=assets.length;$('case-info').textContent=(c.annotationOnly?c.annotationNote+' ':c.assets.length+' 个文件全部保留。')+'数据集包含上下文，不等于一个连拍组；蓝色编号区分算法预测组，绿色编号区分草稿组。'+(c.unknownAssetIDs.length?' 0188 仍为未知。':'');const table=el('table'),tr=el('tr');['版本','TP / FP / FN / TN（旧标签）','Precision / Recall','整组 exact'].forEach(t=>tr.append(el('th',t)));table.append(tr);if(u){const m=u.metrics,row=el('tr'),pct=x=>x==null?'未定义':(x*100).toFixed(1)+'%';row.append(el('td',u.title+(u.associationAssumed?' · 假设配对':'')),el('td',['truePositive','falsePositive','falseNegative','trueNegative'].map(k=>m[k]??'—').join(' / ')),el('td',pct(m.precision)+' / '+pct(m.recall)),el('td',pct(m.exactGroupFraction)));table.append(row);}else if(c.annotationOnly){const row=el('tr'),td=el('td','JPEG 标注集尚未重新评测；旧文件级指标不在此展示。');td.colSpan=4;row.append(td);table.append(row);}$('metrics').replaceChildren(table);const grid=$('grid');grid.replaceChildren();for(const a of assets.slice(page*60,(page+1)*60)){const card=el('button',null,'photo'+(a.ordinal===selected?' selected':'')+(c.unknownAssetIDs.includes(a.assetID)?' unknown':'')),img=document.createElement('img');img.src=a.thumbnail;img.alt=a.filename;img.loading='lazy';card.append(img,el('span',a.filename,'filename'),el('span','#'+a.ordinal+' · '+a.assetID,'ordinal'));const bars=el('div',null,'bars'),truth=c.truth.groups.find(g=>g.assetIDs.includes(a.assetID)),pred=u?.ranges.find(g=>a.ordinal>=g.range.first&&a.ordinal<=g.range.last),dg=groupAt(gs,a.ordinal);bars.append(el('span',c.unknownAssetIDs.includes(a.assetID)?'旧：未知':truth?'旧：'+typeName[truth.kind]:'旧：未标'));if(pred)bars.append(el('span','算法组 #'+pred.range.first,'pred'));if(dg)bars.append(el('span','草稿组 #'+dg.firstOrdinal,'draft'));card.append(bars);card.onclick=()=>selectOrdinal(a.ordinal);grid.append(card);}renderEditor();renderDraft();renderNavigation();persistWorkspace();for(const fn of subscribers)fn();}
  function renderEditor(){const c=currentCase(),a=c.assets[selected];$('selection').replaceChildren(el('b',a.filename),el('p','#'+selected+' / '+a.assetID));$('edge-editor').hidden=selected>=c.assets.length-1;$('edge-previous').disabled=selected===0;$('edge-next').disabled=selected>=c.assets.length-2;$('split-here').disabled=!M.groups(c,draft).some(g=>selected>=g.firstOrdinal&&selected+1<=g.lastOrdinal);if(selected<c.assets.length-1){const b=c.assets[selected+1];$('edge-images').replaceChildren(...[a,b].map(v=>{const n=document.createElement('img');n.src=v.thumbnail;n.alt=v.filename;return n;}));const edit=draft.caseEdits.find(e=>e.caseID===c.id)?.edgeEdits.find(e=>e.leftAssetID===a.assetID);$('edge-info').textContent=a.filename+' → '+b.filename+'；旧：'+relationName[M.truthRelation(c,selected)]+'；草稿：'+(edit?relationName[edit.relation]:'沿用旧标签');document.querySelectorAll('[data-relation]').forEach(b=>b.classList.toggle('active',b.dataset.relation===edit?.relation));}$('group').replaceChildren(option('','新建范围…'));for(const g of M.groups(c,draft))$('group').append(option(g.id,typeName[g.kind]+' · #'+g.firstOrdinal+'–'+g.lastOrdinal));$('group').value=[...$('group').options].some(o=>o.value===rangeGroupID)?rangeGroupID:'';if(!rangeDirty)loadGroup(false);else groupPreview();}
  function loadGroup(reset=true){const g=M.groups(currentCase(),draft).find(g=>g.id===rangeGroupID);if(g){$('group-first').value=g.firstOrdinal;$('group-last').value=g.lastOrdinal;$('group-kind').value=g.kind;}else if(reset||!$('group-first').value){$('group-first').value=selected;$('group-last').value=Math.min(selected+1,currentCase().assets.length-1);}groupPreview();}
  function groupPreview(){const c=currentCase(),f=Number($('group-first').value),l=Number($('group-last').value);$('group-preview').textContent=Number.isInteger(f)&&Number.isInteger(l)&&c.assets[f]&&c.assets[l]&&f<l?c.assets[f].filename+' → '+c.assets[l].filename+' · '+(l-f+1)+' 个文件':'请选择至少两张连续照片。';}
  function saveRange(){const id=rangeGroupID||'human-'+Date.now(),first=Number($('group-first').value),last=Number($('group-last').value),kind=$('group-kind').value;return change(d=>{const e=M.caseEdit(d,caseID);e.groupEdits=e.groupEdits.filter(g=>g.id!==id);e.removedGroupIDs=e.removedGroupIDs.filter(g=>g!==id);e.groupEdits.push({id,firstOrdinal:first,lastOrdinal:last,kind});},()=>{rangeDirty=false;rangeGroupID=id;});}
  function setView(v){view=v;$('review-view').hidden=v!=='review';$('browse-view').hidden=v!=='browse';document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===v));persistWorkspace();}
  for(const c of C.cases){$('case').append(option(c.id,c.id+' · '+c.assets.length));$('error-case').append(option(c.id,c.id));}for(const a of C.algorithms){$('algorithm').append(option(a.id,a.title));$('error-algorithm').append(option(a.id,a.title));}
  document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>setView(b.dataset.view));
  $('queue-mode').onchange=()=>{const value=$('queue-mode').value;$('queue-mode').value=mode;requestMove(()=>{mode=value;itemKey='';renderNavigation();const items=M.queue(C,mode,algorithmID),i=M.position(items,caseID,selected,'');if(i<0&&items.length)jump(items[0].caseID,items[0].first,mode,items[0].key);else{persistWorkspace();}});};
  $('queue-item').onchange=()=>{const key=$('queue-item').value,x=M.queue(C,mode,algorithmID).find(i=>i.key===key);renderNavigation();if(x)jump(x.caseID,x.first,mode,x.key);};$('queue-previous').onclick=()=>navigate(-1);$('queue-next').onclick=()=>navigate(1);$('complete-next').onclick=()=>navigate(1,true);
  $('case').onchange=()=>{const id=$('case').value;$('case').value=caseID;jump(id,0,'cases','case:'+id);};$('algorithm').onchange=()=>{const id=$('algorithm').value;$('algorithm').value=algorithmID;requestMove(()=>{algorithmID=id;itemKey='';renderBrowse();});};$('search').oninput=()=>{page=0;renderBrowse();};$('previous').onclick=()=>{page--;renderBrowse();};$('next').onclick=()=>{page++;renderBrowse();};
  for(const id of ['error-case','error-algorithm','error-search'])$(id).oninput=()=>{errorLimit=50;renderErrors();};$('more-errors').onclick=()=>{errorLimit+=100;renderErrors();};
  $('edge-previous').onclick=()=>selectOrdinal(selected-1);$('edge-next').onclick=()=>selectOrdinal(selected+1);$('auto-advance').onchange=persistWorkspace;
  document.querySelectorAll('[data-relation]').forEach(b=>b.onclick=()=>{if(change(d=>{const c=currentCase(),e=M.caseEdit(d,c.id),a=c.assets[selected],z=c.assets[selected+1];e.edgeEdits=e.edgeEdits.filter(x=>x.leftAssetID!==a.assetID);e.edgeEdits.push({leftAssetID:a.assetID,rightAssetID:z.assetID,relation:b.dataset.relation,note:''});})&&$('auto-advance').checked&&selected<currentCase().assets.length-2)selectOrdinal(selected+1);});
  $('remove-edge').onclick=()=>change(d=>{const e=M.caseEdit(d,caseID);e.edgeEdits=e.edgeEdits.filter(x=>x.leftAssetID!==currentCase().assets[selected].assetID);});
  $('group').onchange=()=>{const id=$('group').value;$('group').value=rangeGroupID;requestMove(()=>{rangeGroupID=id;rangeDirty=false;loadGroup();persistWorkspace();});};for(const id of ['group-first','group-last','group-kind'])$(id).oninput=()=>{rangeDirty=true;groupPreview();persistWorkspace();renderDraft();};
  $('save-group').onclick=saveRange;$('save-group-next').onclick=()=>{const last=Number($('group-last').value);if(!saveRange())return;if(last+1<currentCase().assets.length-1){resetRange();selected=last+1;page=Math.floor(selected/60);$('search').value='';renderBrowse();status('范围已保存，继续标注同一数据集的下一组。');}else navigate(1);};
  $('split-here').onclick=()=>requestMove(()=>{change(d=>{Object.assign(d,M.splitGroup(currentCase(),d,selected,'human-split-'+Date.now()+'-'+selected));},resetRange);});$('remove-group').onclick=()=>{if(!rangeGroupID)return;const id=rangeGroupID;change(d=>{const e=M.caseEdit(d,caseID);e.groupEdits=e.groupEdits.filter(g=>g.id!==id);if(currentCase().truth.groups.some(g=>g.id===id)&&!e.removedGroupIDs.includes(id))e.removedGroupIDs.push(id);},resetRange);};
  $('pending-save').onclick=()=>{const fn=pendingMove;if(saveRange()){pendingMove=null;$('pending-range').hidden=true;if(fn)fn();}};$('pending-discard').onclick=()=>{const fn=pendingMove;resetRange();if(fn)fn();};$('pending-stay').onclick=()=>{pendingMove=null;$('pending-range').hidden=true;};
  $('undo').onclick=()=>requestMove(()=>{if(history.length){draft=history.pop();resetRange();persist();renderBrowse();}});$('reset').onclick=()=>requestMove(()=>{if(confirm('清空当前修订草稿？旧标签不变，可用撤销恢复。'))change(d=>{d.caseEdits=[];},resetRange);});
  $('repair-edge-splits').onclick=()=>requestMove(()=>change(d=>Object.assign(d,M.reconcileEdgeSplits(C,d)),resetRange));
  $('export').onclick=()=>{try{const value=M.exportBundle(draft,C,snapshotWorkspace()),backup=value.kind==='RAWMaster-sequence-review-backup',blob=new Blob([JSON.stringify(value,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),a=el('a');a.href=url;a.download='RAWMaster-'+(backup?'sequence-review-backup-':'label-revision-')+C.indexSHA256.slice(0,12)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);status(backup?'已导出可恢复草稿备份，包含冲突和未保存范围；可用“导入标注”恢复，尚不能用于评测。':'修订已导出；源标签未改变。',backup);}catch(e){status(e.message,true);}};
  $('import').onchange=async event=>{const file=event.target.files[0];if(!file)return;try{const imported=M.readImport(M.parseStrictJSON(await file.text()),C);requestMove(()=>{history.push(M.clone(draft));if(history.length>100)history.shift();draft=imported.draft;resetRange();if(imported.workspace)restoreBackupWorkspace(imported.workspace);persist();renderBrowse();setView(view);status(imported.workspace?'草稿备份已恢复，包含标注、浏览位置和未保存范围；冲突可继续处理。':'修订已导入为草稿；源标签未改变。');});}catch(e){status('导入被拒绝：'+e.message,true);}event.target.value='';};
  document.addEventListener('keydown',event=>{if((!$('advanced-tools')?.open)||view!=='browse'||event.altKey||event.metaKey||event.ctrlKey||event.target?.closest?.('input,select,textarea,[contenteditable="true"]'))return;if(event.key==='['||event.key===']'){event.preventDefault();navigate(event.key==='['?-1:1);}else if(event.key==='ArrowLeft'||event.key==='ArrowRight'){event.preventDefault();selectOrdinal(selected+(event.key==='ArrowLeft'?-1:1));}});
  window.addEventListener('beforeunload',event=>{if(rangeDirty){event.preventDefault();event.returnValue='';}});
  if(restored){$('auto-advance').checked=restored.autoAdvance===true;if(typeof restored.search==='string'&&restored.search.length<=200)$('search').value=restored.search;const f=restored.rangeForm;if(f&&typeof f.first==='string'&&typeof f.last==='string'&&f.first.length<=20&&f.last.length<=20&&['burst','interval','sequence'].includes(f.kind)){rangeGroupID=typeof f.groupID==='string'?f.groupID:'';$('group-first').value=f.first;$('group-last').value=f.last;$('group-kind').value=f.kind;rangeDirty=true;}}
  window.RawMasterReview={catalog:C,model:M,getDraft:()=>M.clone(draft),subscribe:fn=>subscribers.add(fn),
    navigate:requestMove,commit:fn=>{let applied=false;requestMove(()=>{applied=change(fn,resetRange);});return applied;},
    setGuidedWorkspace:fn=>{guidedWorkspace=fn;},takeGuidedRestore:()=>{const value=guidedRestore;guidedRestore=null;return value;}};
  renderIntro();renderReviews();renderBrowse();setView(view);if(view==='browse')$('annotation-nav').scrollIntoView({block:'start'});
})();
