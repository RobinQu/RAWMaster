'use strict';
const GuidedReviewModel = (() => {
  const M = typeof module !== 'undefined' ? require('./review.js') : window.RawMasterReview.model;
  function relations(c, draft) {
    const result=Array(c.assets.length-1).fill('unknown'),index=new Map(c.assets.map(a=>[a.assetID,a.ordinal]));
    for(const p of c.truth.negativePairs){const first=Math.min(index.get(p.from),index.get(p.to));result[first]='separate';}
    for(const g of M.groups(c,draft))for(let i=g.firstOrdinal;i<g.lastOrdinal;i++)result[i]='same';
    for(const e of draft.caseEdits.find(e=>e.caseID===c.id)?.edgeEdits||[])result[index.get(e.leftAssetID)]=e.relation;
    return result;
  }
  function relation(c, draft, first) { return relations(c,draft)[first]; }
  function segments(c, draft) {
    const result = [], edges=relations(c,draft); let first = 0;
    for (let i = 0; i < c.assets.length; i++) {
      if (i === c.assets.length - 1 || edges[i] !== 'same') {
        result.push({first, last:i}); first = i + 1;
      }
    }
    return result;
  }
  function choose(c, draft, first, value) {
    if (!Number.isInteger(first) || first < 0 || first >= c.assets.length - 1 || !['same', 'separate', 'unknown'].includes(value)) throw new Error('请选择一对相邻照片');
    const originalGroups = M.groups(c, draft);
    for (let i = 1; i < originalGroups.length; i++) if (originalGroups[i].firstOrdinal <= originalGroups[i - 1].lastOrdinal) throw new Error('旧版草稿的组范围重叠，请先在高级工具调整，或导出备份。');
    const next = M.clone(draft), edit = M.caseEdit(next, c.id), left = c.assets[first], right = c.assets[first + 1];
    const note = edit.edgeEdits.find(e => e.leftAssetID === left.assetID)?.note || '';
    edit.edgeEdits = edit.edgeEdits.filter(e => e.leftAssetID !== left.assetID);
    edit.edgeEdits.push({leftAssetID:left.assetID, rightAssetID:right.assetID, relation:value, note});
    // One boundary decision determines the affected partition. No second range editor is required.
    const ranges = segments(c, next).filter(g => g.last > g.first), used = new Set(c.truth.groups.map(g => g.id));
    edit.removedGroupIDs = c.truth.groups.map(g => g.id);
    edit.groupEdits = ranges.map(g => {
      const kinds = new Set(originalGroups.filter(old => old.firstOrdinal <= g.last && old.lastOrdinal >= g.first).map(old => old.kind));
      let id = 'review-' + c.assets[g.first].assetID + '-' + c.assets[g.last].assetID;
      while (used.has(id)) id += '-r'; used.add(id);
      return {id, firstOrdinal:g.first, lastOrdinal:g.last, kind:kinds.size === 1 ? [...kinds][0] : 'sequence'};
    });
    return next;
  }
  function answer(c, draft, task) {
    return draft.caseEdits.find(e => e.caseID === c.id)?.edgeEdits.find(e => e.leftAssetID === c.assets[task.firstOrdinal].assetID)?.relation || null;
  }
  return {relation, relations, segments, choose, answer};
})();
if (typeof module !== 'undefined') module.exports = GuidedReviewModel;
if (typeof document !== 'undefined') (() => {
  const app = window.RawMasterReview;
  if (!app || !document.getElementById('guided-review')) return;
  const C = app.catalog, M = app.model, G = GuidedReviewModel;
  const $ = id => document.getElementById(id);
  const node = (tag, text, cls) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (cls) n.className = cls; return n; };
  const tasks = C.guidance?.tasks || [], key = M.storageKey(C) + ':guided-v1';
  let mode = tasks.length ? 'tasks' : 'all', taskID = tasks[0]?.id || '', caseID = tasks[0]?.caseID || C.cases[0].id;
  let first = tasks[0]?.firstOrdinal || 0, autoNext = false, restoredPosition = false;
  const names = {same:'同一组', separate:'分开', unknown:'暂不确定'};
  const caseNames = {'burst123':'人物连拍 · 123 张','burst14-context38':'连拍样本 · 01497–01510','burst48-context72':'岸边鸟 · 01721–01768','burst193-context217':'水鸟 · 00368–00560','interval427-context439':'Sony 间隔拍摄 · 427 张','dji187-context376':'DJI 间隔拍摄 · JPEG'};
  function restore(w) {
    if (!w || w.version !== 1 || !['tasks','all'].includes(w.mode)) return;
    const c = C.cases.find(c => c.id === w.caseID);
    if (!c || !Number.isInteger(w.first) || w.first < 0 || w.first >= c.assets.length - 1) return;
    if (w.mode === 'tasks') {
      const task = tasks.find(t => t.id === w.taskID);
      if (!task || task.caseID !== c.id || task.firstOrdinal !== w.first) return;
    }
    mode = w.mode; taskID = w.taskID; caseID = c.id; first = w.first; autoNext = w.autoNext === true; restoredPosition = true;
  }
  try { restore(M.parseStrictJSON(localStorage.getItem(key) || 'null')); } catch (_) {}
  if (!restoredPosition && tasks.length) {
    const draft=app.getDraft(), next=tasks.find(t=>!['same','separate'].includes(G.answer(C.cases.find(c=>c.id===t.caseID),draft,t)))||tasks.at(-1);
    taskID=next.id;caseID=next.caseID;first=next.firstOrdinal;
  }
  const snapshot = () => ({version:1, mode, taskID, caseID, first, autoNext});
  function persist() { try { localStorage.setItem(key, JSON.stringify(snapshot())); } catch (_) {} }
  app.setGuidedWorkspace(snapshot);
  function current() { return C.cases.find(c => c.id === caseID); }
  function task() { return mode === 'tasks' ? tasks.find(t => t.id === taskID) : null; }
  function taskStatus(t, draft) {
    const value = G.answer(C.cases.find(c => c.id === t.caseID), draft, t);
    return value === null ? '待确认' : value === 'unknown' ? '已看过 · 仍待定' : '已标：' + names[value];
  }
  function openTask(t) { app.navigate(() => { mode = 'tasks'; taskID = t.id; caseID = t.caseID; first = t.firstOrdinal; persist(); render(); $('guide-title').scrollIntoView({block:'start'}); }); }
  function openAll(id = caseID, ordinal = first) { app.navigate(() => { mode = 'all'; caseID = id; first = Math.min(ordinal, current().assets.length - 2); persist(); render(); $('guide-title').scrollIntoView({block:'start'}); }); }
  function advance(delta) {
    if (mode === 'tasks') { const i = tasks.findIndex(t => t.id === taskID), t = tasks[i + delta]; if (t) openTask(t); }
    else if (first + delta >= 0 && first + delta < current().assets.length - 1) openAll(caseID, first + delta);
  }
  function renderList(draft) {
    const list = $('guide-list'); list.replaceChildren();
    for (const item of mode === 'tasks' ? tasks : C.cases) {
      const active = mode === 'tasks' ? item.id === taskID : item.id === caseID;
      const b = node('button', null, 'guide-list-item' + (active ? ' active' : '')); b.type = 'button';
      b.setAttribute('aria-current', active ? 'true' : 'false');
      if (mode === 'tasks') {
        b.append(node('b', item.title.replaceAll('.ARW','')), node('small', taskStatus(item,draft)));
        b.onclick = () => openTask(item);
      } else { b.append(node('b', caseNames[item.id] || item.id), node('small', item.assets.length + ' 张照片（含已有上下文）')); b.onclick = () => openAll(item.id,0); }
      list.append(b);
    }
    const pending = tasks.filter(t => !['same','separate'].includes(G.answer(C.cases.find(c=>c.id===t.caseID),draft,t))).length;
    $('guide-progress').textContent = tasks.length ? `待确认 ${pending} / ${tasks.length} · 选择后自动保存` : '浏览照片并标记分界，选择后自动保存';
    $('guide-tasks').classList.toggle('active',mode==='tasks'); $('guide-all').classList.toggle('active',mode==='all');
    $('guide-tasks').disabled = !tasks.length;
  }
  function imageFigure(a, label) {
    const figure = node('figure'), img = node('img'); img.src = a.thumbnail; img.alt = a.filename;
    figure.append(node('span',label,'eyebrow'), img, node('figcaption',a.filename)); return figure;
  }
  function renderGroups(c,draft,t) {
    const scope=t?.scope || {first:0,last:c.assets.length-1};
    const pieces=G.segments(c,draft).filter(g=>g.last>=scope.first&&g.first<=scope.last).map(g=>({first:Math.max(g.first,scope.first),last:Math.min(g.last,scope.last)}));
    let groupNumber=0;
    $('guide-groups').replaceChildren(...pieces.map(g=>{
      const b=node('button',`${g.last>g.first?'组 '+(++groupNumber):'单张 / 待定'} · ${c.assets[g.first].filename} → ${c.assets[g.last].filename} · ${g.last-g.first+1} 张`);
      b.onclick=()=>openAll(c.id,Math.min(g.first,c.assets.length-2)); return b;
    }));
    $('guide-groups-title').textContent=`当前分组预览 · ${scope.last-scope.first+1} 张（沿用原标签，按你的选择更新）`;
  }
  function render() {
    const draft=app.getDraft(), c=current(), t=task(), left=c.assets[first], right=c.assets[first+1], edges=G.relations(c,draft);
    renderList(draft);
    $('guide-title').textContent=t?t.question:'这两张应归为同一组吗？';
    $('guide-evidence').textContent=t?t.reason:'点击照片可定位相邻两张；标记新组起点即可，不需要输入编号或维护组范围。';
    $('guide-suggestion').textContent=t?t.suggestion:'';
    $('guide-visual').textContent=t?t.visualObservation:'';
    $('guide-visual-details').hidden=!t;
    $('guide-pair').replaceChildren(imageFigure(left,'左图'),imageFigure(right,'右图'));
    const explicit=draft.caseEdits.find(e=>e.caseID===c.id)?.edgeEdits.find(e=>e.leftAssetID===left.assetID), rel=edges[first];
    $('guide-current').textContent=explicit?'已保存：'+names[explicit.relation]:'尚未确认本项 · 当前沿用：'+names[rel];
    document.querySelectorAll('[data-guide-relation]').forEach(b=>{b.classList.toggle('active',b.dataset.guideRelation===explicit?.relation);b.setAttribute('aria-pressed',String(b.dataset.guideRelation===explicit?.relation));});
    const index=tasks.findIndex(x=>x.id===taskID);
    $('guide-prev').disabled=mode==='tasks'?index<=0:first===0;
    $('guide-next').disabled=mode==='tasks'?index>=tasks.length-1:first>=c.assets.length-2;
    $('guide-prev').textContent=mode==='tasks'?'上一项':'上一对'; $('guide-next').textContent=mode==='tasks'?'下一项':'下一对';
    $('guide-finish').hidden=mode!=='tasks'||index<tasks.length-1;
    $('guide-position').textContent=mode==='tasks'?`第 ${index+1} / ${tasks.length} 项`:`第 ${first+1}、${first+2} 张 / 共 ${c.assets.length} 张`;
    $('guide-context-title').textContent=mode==='tasks'?'附近照片（先后顺序）':'照片列表（点击左图，判断它与下一张的关系）';
    $('guide-open-all').hidden=mode!=='tasks'; $('guide-auto-next').checked=autoNext;
    const start=mode==='tasks'?Math.max(0,first-2):Math.floor(first/60)*60, end=mode==='tasks'?Math.min(c.assets.length,first+4):Math.min(c.assets.length,start+60);
    const strip=$('guide-context');strip.replaceChildren();
    for(const a of c.assets.slice(start,end)) {
      const card=node(mode==='all'?'button':'div',null,'guide-thumb'+(a.ordinal===first||a.ordinal===first+1?' selected':''));
      const img=node('img');img.src=a.thumbnail;img.alt=a.filename;img.loading='lazy';card.append(img,node('span',a.filename));
      if(mode==='all') {card.onclick=()=>openAll(c.id,Math.min(a.ordinal,c.assets.length-2)); if(a.ordinal>0&&edges[a.ordinal-1]==='separate')card.append(node('b','新组起点','guide-divider'));}
      strip.append(card);
    }
    $('guide-page-controls').hidden=mode!=='all';$('guide-page-prev').disabled=start===0;$('guide-page-next').disabled=end>=c.assets.length;
    renderGroups(c,draft,t);
  }
  $('guide-tasks').onclick=()=>{const draft=app.getDraft(), t=tasks.find(t=>!['same','separate'].includes(G.answer(C.cases.find(c=>c.id===t.caseID),draft,t)))||tasks.at(-1);if(t)openTask(t);};
  $('guide-all').onclick=()=>openAll();$('guide-open-all').onclick=()=>openAll();
  $('guide-prev').onclick=()=>advance(-1);$('guide-next').onclick=()=>advance(1);
  $('guide-export').onclick=()=>$('export').click();
  $('guide-page-prev').onclick=()=>openAll(caseID,Math.max(0,Math.floor(first/60)*60-60));
  $('guide-page-next').onclick=()=>openAll(caseID,Math.min(current().assets.length-2,Math.floor(first/60)*60+60));
  $('guide-auto-next').onchange=()=>{autoNext=$('guide-auto-next').checked;persist();};
  document.querySelectorAll('[data-guide-relation]').forEach(b=>b.onclick=()=>{
    if(app.commit(d=>Object.assign(d,G.choose(current(),d,first,b.dataset.guideRelation)))) {persist();if(autoNext)advance(1);}
  });
  const settled=$('guide-settled');for(const item of C.guidance?.settled||[])settled.append(node('p',item.text));
  if(!C.guidance)$('guide-settled-details').hidden=true;
  app.subscribe(()=>{const restored=app.takeGuidedRestore();if(restored){restore(restored);persist();}render();});
  document.addEventListener('keydown',e=>{
    if($('advanced-tools').open||e.altKey||e.metaKey||e.ctrlKey||e.target?.closest?.('input,select,textarea,[contenteditable="true"]'))return;
    if(e.key==='ArrowLeft'||e.key==='ArrowRight'){e.preventDefault();advance(e.key==='ArrowLeft'?-1:1);}
    else if(['1','2','3'].includes(e.key)){e.preventDefault();document.querySelectorAll('[data-guide-relation]')[Number(e.key)-1].click();}
  });
  render();
})();
