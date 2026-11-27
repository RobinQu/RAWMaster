'use strict';
const nativeBatchReview = new URLSearchParams(location.search).get('batchNativeReview') === '1';
const failedDagPhotos = new Set();
const nativeGraphReview = new URLSearchParams(location.search).get('graphNativeReview') === '1';

// Recipe graphs own edit state; viewport and selection remain outside pixel history.
const dagKinds = { source: 'RAW 显影', grade: '调色', mix: '混合', group: '组', geometry: '几何', output: '输出' };
const dagGradeTools = ['basic', 'tones', 'color', 'detail', 'effects', 'grading'];
const dagScalarKeys = [...new Set(dagGradeTools.flatMap(key => editTools[key][1].map(([field]) => field)))];
const dagID = () => 'n-' + Studio.uid();
function dagSeed(recipe = currentEdit().recipe) {
  const params = structuredClone(recipe);
  delete params.dag;
  delete params.crop;
  delete params.angle;
  delete params.repairs;
  delete params.masks;
  delete params.sceneOutput;
  delete params.colorMode;
  const photographic = recipe.sceneOutput ? structuredClone(params) : undefined;
  return { schema: 1, photographic, base: structuredClone({ ...recipe, dag: undefined }), nodes: [
    { id: 'source', kind: 'source', name: '原片显影', enabled: true, params: {} },
    { id: 'grade', kind: 'grade', name: '基础调色', enabled: true, params:photographic ? {} : params },
    { id: 'geometry', kind: 'geometry', name: '裁切与几何', enabled: true, params: { crop: recipe.crop, angle: recipe.angle } },
    { id: 'output', kind: 'output', name: '最终输出', enabled: true, params: {} },
  ], edges: [{ from: 'source', to: 'grade', slot: 'image' }, { from: 'grade', to: 'geometry', slot: 'image' }, { from: 'geometry', to: 'output', slot: 'image' }] };
}
function dagEnabled() { return Boolean(currentEdit().recipe.dag); }
function dagView() {
  const e = currentEdit();
  const v = e.dagView ??= { mode: 'photo', path: [], active: 'grade', selection: ['grade'], target: null, views: {}, monitor: true };
  if (S.graphOpen != null) v.mode = S.graphOpen ? 'graph' : 'photo';
  else S.graphOpen = v.mode === 'graph';
  let graph = e.recipe.dag;
  const validPath = [];
  for (const id of v.path) {
    const node = graph?.nodes.find(n => n.id === id && n.kind === 'group');
    if (!node) break;
    validPath.push(id); graph = node.graph;
  }
  v.path = validPath;
  if (graph) {
    v.selection = v.selection.filter(id => graph.nodes.some(n => n.id === id));
    if (v.target && !graph.nodes.some(n => n.id === v.target)) v.target = null;
    if (!graph.nodes.some(n => n.id === v.active)) v.active = graph.nodes.find(n => n.kind === 'grade')?.id ?? graph.nodes[0]?.id;
  }
  return v;
}
function dagCurrent(root = currentEdit().recipe.dag) {
  let g = root;
  for (const id of dagView().path) g = g.nodes.find(n => n.id === id).graph;
  return g;
}
function dagNode(g = dagCurrent()) { return g?.nodes.find(n => n.id === dagView().active); }
function dagEnsure() {
  if (!dagEnabled()) {
    const e = currentEdit(), unchanged = !Studio.dirty(Studio.data.work), root = dagSeed();
    e.recipe.dag = root;
    if (unchanged) e.saved = JSON.stringify(e.recipe);
    Studio.save();
  }
  return dagCurrent();
}
function dagAllNodes(g, prefix = '') {
  return g.nodes.flatMap(n => [{ node: n, path: prefix }, ...(n.graph ? dagAllNodes(n.graph, prefix + n.name + ' › ') : [])]);
}
function dagModelGeometryConflict(recipe) {
  const graph=recipe.dag;
  if (!graph || !recipe.sceneOutput) return false;
  const b=recipe.cropBox;
  const warped=recipe.crop && recipe.crop!=='原始' || recipe.angle || recipe.quarterTurns || recipe.flipH || recipe.flipV ||
    recipe.distort || recipe.vertical || (b && (b.x!==0 || b.y!==0 || b.width!==100 || b.height!==100));
  if (!warped) return false;
  function readsModel(scope) {
    const visited=new Set();
    function visit(id) {
      if(visited.has(id))return false;
      visited.add(id);
      const n=scope.nodes.find(node=>node.id===id);
      if (!n) return false;
      const p=n.params, enabled=n.enabled!==false && (p.nodeAmount??100)>0;
      const mask=n.mask, effective=p.ev || p.curveLow || p.curveHigh || p.curveMid || (Array.isArray(p.curve) && p.curve.some(point=>point.x!==point.y));
      if (enabled && n.kind==='grade' && effective && mask?.enabled!==false && (mask?.opacity??100)>0) {
        const semantic=part=>['主体','背景','天空','人物部位','前景实例'].includes(part?.kind) && part.enabled!==false && (part.opacity??100)>0;
        if (semantic(mask) || mask?.components?.some(semantic)) return true;
      }
      if (n.kind==='group' && enabled && readsModel(n.graph)) return true;
      return scope.edges.filter(edge=>edge.to===id).some(edge=>{
        if (n.kind==='mix' && edge.slot!=='base') {
          const amount=edge.slot==='layer' ? p.amount : p['weight:'+edge.slot];
          if (n.enabled===false || !(amount>0)) return false;
        }
        return visit(edge.from);
      });
    }
    return visit(scope.nodes.find(node=>node.kind==='output')?.id);
  }
  return readsModel(graph);
}
function admitModelGeometry(recipe) {
  if (!dagModelGeometryConflict(recipe)) return true;
  notifyEditor('当前调色使用模型蒙版。请先断开它，再裁切、旋转或校正镜头畸变。','error');
  return false;
}
function dagError(g, depth = 0) {
  if (depth > 8 || g.nodes.length > 128) return '节点或嵌套超出原型预算';
  const ids = new Set(g.nodes.map(n => n.id));
  if (ids.size !== g.nodes.length) return '节点身份重复';
  for (const e of g.edges) {
    if (!ids.has(e.from) || !ids.has(e.to)) return '连线存在缺失端点';
    if (e.from === e.to) return '节点不能连接自身';
    const a = g.nodes.find(n => n.id === e.from), b = g.nodes.find(n => n.id === e.to);
    if (a.kind === 'output' || b.kind === 'source') return '输入／输出端点方向错误';
    if (b.kind !== 'mix' && e.slot !== 'image' || b.kind === 'mix' && !/^(base|layer\d*)$/.test(e.slot)) return '端口类型不兼容';
    if (g.edges.filter(x => x.to === e.to && x.slot === e.slot).length > 1) return '同一输入端口不能重复连接';
  }
  const maskEdges = g.nodes.flatMap(n => {
    const refs = [...(n.mask?.components || []).filter(c=>c.kind==='来自节点').map(c=>c.reference),...(n.mask?.kind==='来自节点'?[n.mask.reference]:[])];
    return refs.map(from=>({from,to:n.id}));
  });
  if (maskEdges.some(e=>!ids.has(e.from)||e.from===e.to)) return '蒙版节点引用缺失或引用自身';
  const dependencies = [...g.edges,...maskEdges];
  const visiting = new Set(), done = new Set();
  const cycle = id => {
    if (visiting.has(id)) return true;
    if (done.has(id)) return false;
    visiting.add(id);
    if (dependencies.filter(e => e.from === id).some(e => cycle(e.to))) return true;
    visiting.delete(id); done.add(id); return false;
  };
  if (g.nodes.some(n => cycle(n.id))) return '此连接会形成回路';
  const reach = new Set();
  const ancestors = id => { if (reach.has(id)) return; reach.add(id); g.edges.filter(e => e.to === id).forEach(e => ancestors(e.from)); };
  const out = g.nodes.find(n => n.kind === 'output');
  if (!out) return '缺少最终输出';
  ancestors(out.id);
  for (const n of g.nodes.filter(n => reach.has(n.id) && n.kind !== 'source')) {
    const inputs = g.edges.filter(e => e.to === n.id);
    if (n.kind === 'mix' ? !['base', 'layer'].every(s => inputs.some(e => e.slot === s)) : inputs.length !== 1) return n.name + ' 的输入未接齐';
  }
  if (!g.nodes.some(n => n.kind === 'source' && reach.has(n.id))) return '最终输出尚未连接到输入';
  for (const n of g.nodes) if (n.graph) { const error = dagError(n.graph, depth + 1); if (error) return n.name + '：' + error; }
  return '';
}
const dagEditable = n => n && ['grade','mix','group'].includes(n.kind);
const dagPreviewOverrides = new WeakMap();
function dagPreviewState() {
  const view = dagView();
  if (!dagPreviewOverrides.has(view)) dagPreviewOverrides.set(view, {solo:null, bypass:false});
  return dagPreviewOverrides.get(view);
}
function dagClearPreview() {
  const v = dagView();
  v.target = null; dagPreviewOverrides.delete(v);
}
function dagEvaluate(g, target, initial = {}, memo = new Map(), preview = null) {
  const id = target ?? g.nodes.find(n => n.kind === 'output')?.id;
  if (memo.has(id)) return memo.get(id);
  const n = g.nodes.find(n => n.id === id);
  if (!n) return initial;
  const input = slot => {
    const edge = g.edges.find(e => e.to === id && e.slot === slot);
    return edge ? dagEvaluate(g, edge.from, initial, memo, preview) : initial;
  };
  let result;
  if (n.kind === 'source') result = { ...initial, ...n.params };
  else if (n.kind === 'mix') {
    const base = input('base'), layer = input('layer'), amount = n.enabled === false ? 0 : (n.params.amount ?? 0) / 100;
    result = { ...base };
    dagScalarKeys.forEach(k => result[k] = (base[k] ?? 0) * (1 - amount) + (layer[k] ?? 0) * amount);
    if (amount >= 0.5) result.lut = layer.lut;
    for (const edge of g.edges.filter(e => e.to === id && /^layer\d+$/.test(e.slot))) {
      const weight = (n.params['weight:'+edge.slot] ?? 0) / 100, extra = input(edge.slot);
      if (n.enabled !== false) dagScalarKeys.forEach(k => result[k] = (result[k] ?? 0) * (1-weight) + (extra[k] ?? 0) * weight);
    }
  } else {
    result = { ...input('image') };
    if (n.enabled !== false && n.kind === 'group') { const base = result, grouped = dagEvaluate(n.graph, null, base, new Map(), preview), amount = (n.params.nodeAmount ?? 100) / 100; result = {...base,...grouped}; dagScalarKeys.forEach(k=>result[k]=(base[k]??0)*(1-amount)+(grouped[k]??0)*amount); }
    if (n.enabled !== false && n.kind === 'grade' && !preview?.bypass && (!preview?.solo || preview.solo === n.id)) {
      const coverage = (!n.mask ? 1 : n.mask.enabled === false ? 0 : (n.mask.opacity ?? 100) / 100 * (n.mask.invert ? 0.55 : 0.45)) * (n.params.nodeAmount ?? 100) / 100;
      dagScalarKeys.forEach(k => result[k] = (result[k] ?? 0) + (n.params[k] ?? 0) * coverage);
      for (const [key,value] of Object.entries(n.params)) if (typeof value === 'number' && key.includes(':') && !key.startsWith('choice:')) { const field = key.split(':')[0]; if (dagScalarKeys.includes(field)) result[field] = (result[field] ?? 0) + value * coverage; }
      result.ev += ['hdrBlack','hdrDark','hdrShadow','hdrLight','hdrHighlight','hdrSpecular'].reduce((sum,key)=>sum+(n.params[key] || 0),0) / 6 * coverage;
      result.sat += ((n.params.sliceSaturation || 0) + (n.params.warperSaturation || 0)) * coverage;
      result.hue = (result.hue || 0) + ((n.params.sliceHue || 0) + (n.params.warperHue || 0)) * coverage;
      if (n.params.mono) result.mono = true;
      if (n.params.filmStock && coverage) Object.assign(result, { filmStock: n.params.filmStock, filmAmount: n.params.filmAmount ?? 100 });
      if (n.params.lut && coverage) result.lut = n.params.lut;
    }
    if (n.kind === 'geometry') Object.assign(result, n.params);
  }
  memo.set(id, result); return result;
}
function dagProject(root, preview = null) {
  const neutral = { ...root.base, ...Studio.freshRecipe(), masks: root.base.masks ?? [], repairs: root.base.repairs ?? [], ...Object.fromEntries(dagScalarKeys.map(k => [k, 0])), filmStock: null, lut: '无' };
  return { ...neutral, ...dagEvaluate(root, null, root.photographic || {}, new Map(), preview), sceneOutput: root.base.sceneOutput, colorMode: root.base.colorMode, dag: root };
}
function dagPatch(label, fields) {
  return dagCommit(label, (g, root) => {
    const n = dagNode(g);
    if ('crop' in fields || 'angle' in fields) {
      const geometry = root.nodes.find(n => n.kind === 'geometry');
      if (geometry) Object.assign(geometry.params, fields);
    } else if (n && ['grade', 'source'].includes(n.kind)) {
      if ('masks' in fields) {
        const m = fields.masks.at(-1);
        if (m) n.mask = { kind: m.kind, x: 50, y: 50, width: 35, height: 55, enabled: true, opacity: 100, feather: 45 };
      } else Object.assign(n.params, fields);
    }
  });
}
function dagCommit(label, mutate, refresh = true) {
  dagEnsure();
  if (S.canvasTool) return notify('请先完成或取消画布工具草案');
  if (S.dagConnectionDraft) return notify('请先应用或取消连接草稿');
  const root = structuredClone(currentEdit().recipe.dag), graph = dagCurrent(root);
  mutate(graph, root);
  const error = dagError(root);
  if (error) { notify(error, 'error'); return false; }
  const result=dagProject(root);
  if (!admitModelGeometry(result)) return false;
  Studio.setRecipe(Studio.data.work, label, result);
  dagView(); if (refresh) render(); return true;
}
function dagRenderFocus(selector = '[name=dagNode]') { render(); $(selector)?.focus({ preventScroll: true }); }
function dagSelect(id, multiple = false, focus = '[data-dag-node="' + id + '"]') {
  if (S.canvasTool || S.dagMaskSession || S.dagCropSession) { notify('请先完成或取消当前照片工具'); render(); return; }
  const g = dagEnsure(), v = dagView();
  if (!g.nodes.some(n => n.id === id)) return;
  v.active = id; v.mask = false; v.edge = null;
  v.selection = multiple ? (v.selection.includes(id) ? v.selection.filter(x => x !== id) : [...v.selection, id]) : [id];
  S.canvasSelection = null; S.dagMaskSession = null;
  dagRenderFocus(focus);
}
function dagLeavePhoto() {
  if (dagEnabled()) dagClearPreview();
  S.canvasTool = null;
  S.dagConnectionDraft = null; S.dagWireFrom = null; S.dagMaskSession = null;
  S.dagCropSession = null; S.dagRenderFailed = failedDagPhotos.has(Studio.data.work); dagPointer = null;
}
function dagBlocked(n) { return !n || dagView().selection.length !== 1 || S.dagConnectionDraft; }
function dagStateText(n) {
  if (!n) return '请选择节点';
  if (n.enabled === false) return '已忽略该节点 · 保留参数，不影响最终结果';
  if (n.mask?.missing) return '蒙版素材缺失 · 请重新构建';
  if (!dagReachable().has(n.id)) return '未接入 · 不影响最终结果';
  return n.mask ? (n.mask.enabled === false ? '蒙版已停用 · 零覆盖' : n.mask.kind + ' · 局部作用域') : '全局作用域';
}
function dagReachable(g = dagCurrent()) {
  const ids = new Set();
  function walk(id) { if (ids.has(id)) return; ids.add(id); g.edges.filter(e => e.to === id).forEach(e => walk(e.from)); }
  walk(g.nodes.find(n => n.kind === 'output')?.id); return ids;
}
function dagIgnoreReason(n) {
  if (!dagEnabled()) return '请先开启节点工作流';
  if (S.canvasTool) return '请先完成或取消画布工具';
  if (S.dagConnectionDraft) return '请先应用或取消连接草稿';
  if (dagView().selection.length !== 1) return '请选择单个节点';
  if (!n || ['source','geometry','output'].includes(n.kind)) return '固定照片阶段不能忽略';
  return '';
}
function dagToolbar() {
  const v = dagView(), graph = dagEnabled() ? dagCurrent() : dagSeed(), n = graph.nodes.find(n => n.id === v.active), reason = dagIgnoreReason(n);
  const pickerLabel = v.selection.length > 1 ? '已选 ' + v.selection.length + ' 个节点' : dagEnabled() && !v.selection.length ? '请选择节点' : n?.kind === 'source' ? '基础校正' : n?.name || '基础调色';
  const nodes = graph.nodes.filter(dagEditable);
  return `<section class="dag-scope-head" aria-label="节点作用域"><span class="dag-picker-label">当前节点</span><div class="dag-picker-row">
    <button type="button" name="dagNode" data-act="dag-picker" aria-label="当前节点" aria-expanded="false" aria-controls="dag-node-picker"${S.canvasTool ? ' disabled title="请先完成或取消画布工具"' : ''}><span>${h(pickerLabel)}</span>${icon('down',12)}</button>
    ${btn('忽略该节点','dag-toggle-current',n?.id || '',{icon:'bypass',only:true,cls:'icon-btn',pressed:v.selection.length===1&&n?.enabled===false,disabled:!!reason,title:reason ? '忽略该节点：'+reason : n?.enabled===false ? '恢复该节点（已忽略）' : '忽略该节点'}).replace('<button ','<button data-photo="'+h(Studio.data.work)+'" ')}
    ${btn('Graph 窗口','dag-view-toggle','',{icon:'layers',only:true,cls:'icon-btn',pressed:v.mode==='graph',expanded:v.mode==='graph',controls:'dag-floating-window'})}</div>
    <div id="dag-node-picker" class="dag-picker-popover" popover="auto" role="dialog" aria-label="选择节点与常用图操作">${v.path.length ? '' : `<div class="dag-picker-base">${btn('基础校正','dag-picker-command','base',{icon:'sliders',pressed:n?.kind==='source'})}</div>`}<h3>${v.path.length ? '组内可编辑节点' : '可编辑节点'}</h3><div class="dag-picker-list">${nodes.map(node=>btn(node.name+(node.enabled===false?' · 已忽略':''),'dag-picker-select',node.id,{pressed:v.selection.length===1&&v.active===node.id,icon:node.kind==='group'?'folder':node.kind==='mix'?'mix':'sliders'})).join('') || '<p class="small">暂无可编辑节点</p>'}</div><div class="dag-picker-commands">${btn('添加节点…','dag-picker-command','add',{icon:'plus'})}${btn('自动整理','dag-picker-command','layout',{disabled:!dagEnabled()})}${btn('更多节点操作…','dag-picker-command','more',{icon:'menu'})}</div></div>
    <small>${h(dagEnabled() ? n ? dagKinds[n.kind] + ' · ' + n.name : '工作流' : SceneEditor.hdr() ? '场景调色 · HDR 摄影调整' : '兼容显影节点 · 输入与基础调整')}</small>
    ${!['smart', 'agent'].includes(S.tool) && dagEnabled() ? '<small role="status">' + h(v.selection.length===1 ? dagStateText(n) : v.selection.length ? '多选仅管理，不广播参数' : '请选择节点编辑参数') + '</small>' : '<small>智能预设与版本操作作用于整张照片</small>'}</section>`;
}
function dagPickerClose() {
  const picker = $('#dag-node-picker');
  if (picker?.matches(':popover-open')) picker.hidePopover();
  $('[name=dagNode]')?.setAttribute('aria-expanded','false');
}
actions['dag-picker'] = () => {
  const picker = $('#dag-node-picker'), opener = $('[name=dagNode]');
  if (S.canvasTool || !picker || !opener) return;
  if (picker.matches(':popover-open')) { dagPickerClose(); return; }
  picker.showPopover();
  const rect = opener.getBoundingClientRect(), width = Math.min(320,innerWidth-24);
  picker.style.width = width+'px';
  picker.style.left = Math.max(12,Math.min(rect.left,innerWidth-width-12))+'px';
  picker.style.top = Math.max(12,Math.min(rect.bottom+5,innerHeight-picker.offsetHeight-12))+'px';
  opener.setAttribute('aria-expanded','true');
  (picker.querySelector('[aria-pressed=true]') || picker.querySelector('button'))?.focus({preventScroll:true});
};
actions['dag-picker-select'] = id => { dagPickerClose(); dagSelect(id,false,'[name=dagNode]'); };
actions['dag-picker-command'] = command => {
  dagPickerClose(); $('[name=dagNode]')?.focus({preventScroll:true});
  if (command==='base') dagSelect(dagEnsure().nodes.find(n=>n.kind==='source')?.id, false, '[name=dagNode]');
  else if (command==='add') actions['dag-add-menu']();
  else if (command==='layout') { actions['dag-layout'](); $('[name=dagNode]')?.focus({preventScroll:true}); }
  else if (command==='more') actions['dag-menu']();
};
actions['dag-toggle-current'] = (id,event,element) => {
  if(element && element.dataset.photo!==Studio.data.work)return notify('照片已改变，请重新操作');
  const node = dagNode();
  if (id!==node?.id || dagIgnoreReason(node)) return notify(dagIgnoreReason(node) || '节点已改变，请重新操作');
  actions['dag-toggle'](); $('[data-act=dag-toggle-current]')?.focus({preventScroll:true});
};
actions['dag-view-toggle'] = () => actions['dag-view'](dagView().mode==='graph'?'photo':'graph');
document.addEventListener('toggle',event=>{
  if(event.target.id==='dag-node-picker') $('[name=dagNode]')?.setAttribute('aria-expanded',String(event.newState==='open'));
},true);
document.addEventListener('keydown',event=>{
  const picker=event.target.closest('#dag-node-picker');
  if(!picker?.matches(':popover-open'))return;
  if(event.key==='Escape'){event.preventDefault();dagPickerClose();$('[name=dagNode]')?.focus({preventScroll:true});}
  else if(['ArrowUp','ArrowDown','Home','End'].includes(event.key)){
    event.preventDefault();const buttons=[...picker.querySelectorAll('button:not(:disabled)')],index=buttons.indexOf(event.target);
    buttons[event.key==='Home'?0:event.key==='End'?buttons.length-1:(index+(event.key==='ArrowUp'?-1:1)+buttons.length)%buttons.length]?.focus({preventScroll:true});
  }
},true);
function dagRange(k, label, min, max, step, v, disabled = false) {
  return `<label class="dag-param"><span>${h(label)}</span><input type="range" name="dagParameter" data-node="${h(dagView().active)}" data-photo="${h(Studio.data.work)}" data-key="${k}" min="${min}" max="${max}" step="${step}" value="${v}"${disabled ? ' disabled' : ''}><input type="number" aria-label="${h(label)}数值" name="dagNumber" data-node="${h(dagView().active)}" data-photo="${h(Studio.data.work)}" data-key="${k}" min="${min}" max="${max}" step="${step}" value="${v}"${disabled ? ' disabled' : ''}></label>`;
}
function dagInspector() {
  const n = dagNode(), v = dagView();
  if (v.selection.length !== 1 || !n) return `<h2>${v.selection.length ? '已选 ' + v.selection.length + ' 个节点' : '工作流摘要'}</h2><p>请选择单个节点编辑参数。多选仅执行管理操作，不广播数值。</p>${btn('添加调色节点', 'dag-add', 'serial')}${btn('选中当前节点', 'dag-select', v.active)}`;
  if (S.dagConnectionDraft) return '<h2>连接草稿</h2><p>右侧数值暂停编辑。应用有效连接或取消，照片保持上一有效结果。</p>' + btn('检查连接草稿', 'dag-connect-menu');
  const p = n.params;
  if (v.mask && n.mask) return dagMaskInspector(n);
  const head = `<h2>${h(n.name)}</h2><p class="dag-hint">${h(dagKinds[n.kind])}节点 · ${h(dagStateText(n))}</p>`;
  if (n.kind === 'group') return head + dagRange('nodeAmount','组强度',0,100,1,p.nodeAmount ?? 100) + btn('进入组', 'dag-enter', n.id, { cls: 'primary wide' }) + btn('保存组工作流…', 'dag-template-save', 'group') + '<p>组只提供管理与忽略；进入组后编辑具体节点。</p>';
  if (n.kind === 'output') return head + '<p>最终输出固定连接，交付始终冻结此输出，不受查看的节点影响。</p>' + btn('打开导出工作台', 'export') + btn('模拟渲染失败', 'dag-failure');
  if (n.kind === 'geometry') return head + '<p>固定照片几何阶段。请使用照片底部 Crop 工具；此处只显示阶段，不提供节点裁切参数。</p>' + fact('比例',p.crop || '原始');
  if (n.kind === 'source') return head + '<p>原片解码和白平衡是输入阶段。预览不代表真实 RAW 运算。</p>' + dagRange('warmth', '原生白平衡（示意）', -100, 100, 1, p.warmth || 0) + check('原片离线（模拟）', 'dagOffline', !Studio.asset(Studio.data.work).online) + '<p>离线仍能编辑已保存图结构；素材重建和精确输出需要原件。</p>';
  if (n.kind === 'mix') return head + select('Mixer 类型','dagMixMode',[['parallel','Parallel Mixer'],['layer','Layer Mixer']],p.mode || 'parallel') + '<h3>有序输入</h3>' + dagCurrent().edges.filter(e => e.to === n.id).sort((a,b)=>dagSlotRank(a.slot)-dagSlotRank(b.slot)).map((e,i) => `<div class="dag-input-row"><p><b>${e.slot === 'base' ? '基底 base' : '图层 '+e.slot}</b>：${h(dagCurrent().nodes.find(x => x.id === e.from)?.name)}</p>${p.mode === 'layer' && i ? select('混合方式','dagBlend',dagBlendModes,p['blend:'+e.slot] || 'normal').replace('<select ','<select data-slot="'+h(e.slot)+'" ') : ''}${i>1 ? dagRange('weight:'+e.slot,'输入权重',0,100,1,p['weight:'+e.slot] ?? 0) : ''}${btn('上移输入','dag-input-move',e.slot+':-1',{disabled:i===0})}${btn('下移输入','dag-input-move',e.slot+':1',{disabled:i===dagCurrent().edges.filter(x=>x.to===n.id).length-1})}</div>`).join('') + dagRange('amount', '混合强度', 0, 100, 1, p.amount ?? 0) + btn('交换输入顺序', 'dag-swap') + btn('添加输入支路','dag-add-input') + '<p>忽略返回基底；Parallel 权重与 Layer 有序混合分开。13 种混合方式仅演示选择与顺序，不声称 CSS 是真实混合公式。</p>';
  if (SceneEditor.hdr() && photoControls()) return head + dagRange('ev','节点曝光（EV）',-12,12,.05,p.ev ?? 0) +
    dagRange('curveHigh','节点高光曲线',-100,100,1,p.curveHigh ?? 0) + dagRange('nodeAmount','节点强度',0,100,1,p.nodeAmount ?? 100);
  const cat = Object.hasOwn(editTools, S.tool) ? S.tool : 'basic';
  const fields = dagPanels.includes(cat) ? dagFields(cat,p) : null;
  if (cat === 'masks') return dagMaskInspector(n);
  if (!fields) return head + '<p>此节点不拥有原片光学、解码或修复操作。请切换到固定照片阶段。</p>' + btn('切到原片显影', 'dag-select', 'source');
  return head + dagCategoryOptions(cat,p) + (cat === 'tones' ? toneCurve(p) : '') + fields.map(([k, label, lo, hi, step]) => dagRange(k, label, lo, hi, step, p[k] ?? dagDefaults[k.split(':')[0]] ?? 0)).join('') + (cat === 'effects' ? select('本节点 LUT', 'dagLut', ['无', '柔和胶片', '冷调'], p.lut || '无') : '') + dagRange('nodeAmount','节点强度',0,100,1,p.nodeAmount ?? 100);
}
function dagMaskInspector(n) {
  const m = n.mask;
  return `<h2>${h(n.name)}／蒙版</h2>${m ? `<p>${h(m.kind)} · ${m.missing ? '素材缺失' : '示例覆盖已就绪'}</p>${check('启用蒙版', 'dagMaskEnabled', m.enabled !== false)}${btn('反转覆盖', 'dag-mask-invert', '', { pressed: !!m.invert })}${dagRange('maskOpacity', '蒙版不透明度', 0, 100, 1, m.opacity ?? 100)}${dagRange('feather', '羽化', 0, 100, 1, m.feather ?? 45)}${btn('在照片上编辑', 'dag-mask-edit', '', { cls: 'primary wide', disabled: !Studio.asset(Studio.data.work).online })}${btn('重新构建素材', 'dag-mask-rebuild', '', { disabled: !Studio.asset(Studio.data.work).online })}${btn('模拟素材缺失', 'dag-mask-missing')}${btn('删除蒙版', 'dag-mask-delete')}` : '<p>空蒙版表示全局作用域。</p>'}${btn('新建蒙版…', 'dag-mask-menu', '', { disabled: !Studio.asset(Studio.data.work).online })}<p class="dag-hint">几何与 AI 覆盖都是模拟，不测量模型或像素质量。</p>`;
}
function dagPosition(n, index) {
  const v = dagView(), key = v.path.join('/');
  const positions = currentEdit().dagLayout ??= {};
  return positions[key + ':' + n.id] ?? { x: 40 + index * 235, y: n.kind === 'mix' ? 100 : 75 };
}
function dagTransform() { return dagView().views[dagView().path.join('/')] ??= { x: 0, y: 0, scale: 1, framing: 'readable' }; }
function dagZoomLabel(scale) { return '可读居中 · ' + Math.round(scale * 100) + '%'; }
function dagPaintTransform(tr) {
  const stage=$('.dag-stage');
  if (!stage) return;
  stage.style.transform=`translate(${tr.x}px,${tr.y}px) scale(${tr.scale})`;
  for(const label of $$('.dag-floating [data-act=dag-readable]')) {
    label.textContent=Math.round(tr.scale*100)+'%';
    label.setAttribute('aria-label',dagZoomLabel(tr.scale));label.title=dagZoomLabel(tr.scale);
  }
}
function dagCanvas() {
  const v = dagView(), g = S.dagConnectionDraft ?? dagCurrent(), tr = dagTransform(), error = S.dagConnectionDraft ? dagError(g) : '', reached = dagReachable(g);
  const positions = new Map(g.nodes.map((n, i) => [n.id, dagPosition(n, i)]));
  const wires = g.edges.map(e => {
    const a = positions.get(e.from), b = positions.get(e.to);
    if (!a || !b) return '';
    const x1 = a.x + 176, y1 = a.y + 45, x2 = b.x, y2 = b.y + 45 + (e.slot === 'image' ? 0 : dagSlotRank(e.slot) * 24);
    const label = `${g.nodes.find(n => n.id === e.from).name} → ${g.nodes.find(n => n.id === e.to).name} (${e.slot})`;
    return `<path class="dag-wire${v.edge === e.to + ':' + e.slot ? ' selected' : ''}" role="button" tabindex="0" aria-label="${h(label)}" data-act="dag-edge" data-val="${h(e.to + ':' + e.slot)}" d="M${x1} ${y1} C${x1 + 70} ${y1},${x2 - 70} ${y2},${x2} ${y2}"/>`;
  }).join('');
  const cards = g.nodes.map((n, i) => {
    const p = positions.get(n.id), selected = v.selection.includes(n.id);
    const inputs = n.kind === 'mix' ? [...new Set(['base','layer',...g.edges.filter(e=>e.to===n.id).map(e=>e.slot)])].sort((a,b)=>dagSlotRank(a)-dagSlotRank(b)) : n.kind === 'source' ? [] : ['image'];
    const preview = dagPreviewState(), muted = n.kind === 'grade' && (preview.bypass || preview.solo && preview.solo !== n.id);
    return `<div class="dag-card${selected ? ' selected' : ''}${v.active === n.id ? ' active' : ''}${n.enabled === false ? ' bypass' : ''}${muted ? ' view-muted' : ''}" style="left:${p.x}px;top:${p.y}px;min-height:${n.kind === 'mix' ? Math.max(95,inputs.length*24+30) : 95}px" data-dag-card="${h(n.id)}">
      <button class="dag-node-title" data-dag-node="${h(n.id)}" data-act="dag-node" data-val="${h(n.id)}" aria-label="${h(n.name)}，${dagKinds[n.kind]}节点" aria-pressed="${selected}">${icon(n.kind === 'group' ? 'folder' : n.kind === 'mix' ? 'mix' : 'sliders', 15)}<b>${h(n.name)}</b></button>
      <small>${dagKinds[n.kind]} · ${n.enabled === false ? '忽略' : !reached.has(n.id) ? '未接入' : n.mask ? '局部' : '全局'}</small>
      ${n.kind === 'group' ? btn('进入组', 'dag-enter', n.id) : ''}
      ${inputs.map((s, k) => `<button class="dag-port input-port slot-${k}" style="top:${35+k*24}px" data-act="dag-port" data-val="${h(n.id + ':' + s)}" aria-label="连接到 ${h(n.name)} ${s} 输入" title="${s}">●<span>${s}</span></button>`).join('')}
      ${n.kind !== 'output' ? `<button class="dag-port output-port" data-act="dag-port" data-val="${h(n.id + ':out')}" aria-label="从 ${h(n.name)} 输出连接">●</button>` : ''}
      ${n.mask ? `<button class="dag-mask-chip" data-act="dag-mask-select" data-val="${h(n.id)}">${icon('mask', 12)}${h(n.mask.kind)}${n.mask.missing ? ' · 缺失' : n.mask.enabled === false ? ' · 停用' : ''}</button>` : ''}</div>`;
  }).join('');
  const crumbs = [btn('照片工作流', 'dag-path', '0'), ...v.path.map((id, i) => btn('› ' + dagAllNodes(currentEdit().recipe.dag).find(x => x.node.id === id)?.node.name, 'dag-path', i + 1))].join('');
  return `<section class="dag-workspace" aria-label="节点 Graph"><div class="dag-topline">${v.path.length ? `<div class="dag-breadcrumb">${crumbs}</div>` : ''}${dagToolbarCommands(v, g, tr)}</div>
    <div class="dag-viewport" tabindex="0" aria-label="Graph 画布" data-dag-viewport><div class="dag-stage" style="transform:translate(${tr.x}px,${tr.y}px) scale(${tr.scale})"><svg class="dag-wires" width="5000" height="3000">${wires}</svg>${cards}</div><div class="dag-marquee" hidden></div>
      ${v.monitor ? `<div class="dag-monitor">${pic(Studio.data.work, '', 'style="filter:' + dagPhotoFilter() + '"')}<small>${h(dagPreviewState().solo ? 'Solo · 不用于导出' : dagPreviewState().bypass ? '调色旁路 · 不用于导出' : v.target ? '中间结果 · 不用于导出' : '最终结果（示意）')}</small></div>` : ''}</div>
    <div class="dag-status" ${S.dagWireFrom || S.dagConnectionDraft || v.edge || v.selection.length > 1 ? '' : 'hidden'} role="status" title="${h(S.dagConnectionDraft ? '连接草稿：'+(error || '有效，应用后进入历史') : '拖节点移动位置；空白拖动平移；Shift 拖动框选；捏合或 Ctrl+滚轮缩放')}">${S.dagWireFrom ? '连接中：请选择输入端口；Escape 取消' : S.dagConnectionDraft ? error ? '连接草稿无效：' + h(error) : '连接草稿有效 · 应用后进入历史' : v.edge ? '已选连线 · 添加将插入此边' : v.selection.length > 1 ? '已选 ' + v.selection.length + ' 个节点 · 数值不广播' : '拖节点移动位置；空白拖动平移；Shift 拖动框选；捏合或 Ctrl+滚轮缩放'}</div>
    ${S.dagConnectionDraft ? `<div class="dag-draft-actions">${btn('应用连接', 'dag-connect-apply', '', { cls: 'primary', disabled: !!error })}${btn('取消连接草稿', 'dag-connect-cancel')}</div>` : ''}
    <div class="dag-zoom-controls" aria-label="Graph 缩放"${nativeGraphReview || SceneEditor.hdr() ? ' hidden' : ''}>${btn('−', 'dag-zoom', 'out')}${btn(Math.round(tr.scale * 100) + '%', 'dag-readable', '', {title:dagZoomLabel(tr.scale)})}${btn('＋', 'dag-zoom', 'in')}</div></section>`;
}
function dagToolbarCommands(v, graph) {
  const preview = dagPreviewState(), node = graph.nodes.find(n => n.id === v.active);
  const disabled = !!S.dagConnectionDraft;
  if (nativeGraphReview || SceneEditor.hdr()) return `<div class="dag-commandbar graph-text-tools" role="toolbar" aria-label="Graph 节点操作">
    ${btn('添加','dag-add-menu','',{disabled})}${btn('更多','dag-menu')}
    ${btn(Math.round(dagTransform().scale*100)+'%','dag-readable','',{title:'按 100% 可读居中'})}${btn('适合全图','dag-fit')}</div>`;
  const tool = (name, action, glyph, opts = {}, val = '') => btn(name,action,val,{icon:glyph,only:true,...opts});
  return `<div class="dag-commandbar" role="toolbar" aria-label="Graph 节点操作">
    <div class="dag-tools-group" role="group" aria-label="添加节点">${tool('添加串行调色','dag-add','arrowRight',{disabled},'serial')}${tool('添加并行调色','dag-add','linearMask',{disabled},'parallel')}${tool('添加 Layer 混合','dag-add','layers',{disabled},'layer')}</div>
    <div class="dag-tools-group" role="group" aria-label="临时查看">${tool('Solo 调色节点','dag-solo','eye',{pressed:!!preview.solo,disabled:!preview.solo && (disabled || !dagSoloCandidate(node))})}${tool('旁路全部调色（仅查看）','dag-preview-bypass','bypass',{pressed:preview.bypass,disabled:disabled && !preview.bypass})}</div>
    <div class="dag-tools-group" role="group" aria-label="图视图">${tool('自动整理','dag-layout','grid')}${tool('适合全图','dag-fit','single')}${tool('结果监看','dag-monitor','photo',{pressed:v.monitor})}${tool('更多节点或工作流操作','dag-menu','menu')}</div></div>`;
}
function dagSoloCandidate(node) {
  if (node?.kind !== 'grade' || node.enabled === false || dagView().selection.length !== 1) return false;
  let graph = currentEdit().recipe.dag;
  for (const id of dagView().path) {
    const group = graph.nodes.find(n => n.id === id);
    if (!group || group.enabled === false || !dagReachable(graph).has(id)) return false;
    graph = group.graph;
  }
  return dagReachable(graph).has(node.id);
}
function dagViewRecipe(r) {
  const v = dagView(), preview = dagPreviewState();
  if (preview.solo || preview.bypass) return dagProject(r.dag, preview);
  return v.target ? {...r,...dagEvaluate(dagCurrent(),v.target)} : r;
}
function dagPhotoFilter() {
  return RMPhotos.filter(RMPhotos.displayLook(SceneEditor.preview(dagViewRecipe(currentEdit().recipe))));
}
function dagPhotoCanvas(r, id) {
  if (!dagEnabled() || S.tool === 'versions') return canvasContent(r, id);
  const v = dagView(), preview = dagPreviewState(), graph = dagCurrent();
  if (preview.solo && !graph.nodes.some(n => n.id === preview.solo && n.enabled !== false)) preview.solo = null;
  const recipe = dagViewRecipe(r), target = graph.nodes.find(n => n.id === v.target);
  const solo = graph.nodes.find(n => n.id === preview.solo), temporary = !!(solo || preview.bypass || target);
  const hasWorkflow = dagAllNodes(currentEdit().recipe.dag).filter(({node}) => ['grade','mix','group'].includes(node.kind)).length > 1;
  const failed = S.dagRenderFailed;
  const message = failed ? '预览失败 · 保留上次画面（模拟）' : solo ? `Solo：${solo.name} · 不用于导出` : preview.bypass ? '调色已旁路 · 仅查看，不用于导出' : target ? `中间预览：${target.name} · 不用于导出` : '最终结果';
  const prefix = !failed && (temporary || hasWorkflow && v.mode === 'graph') ? `<div class="dag-photo-status${failed ? ' failed' : temporary ? ' intermediate' : ''}">${icon(failed ? 'pulse' : temporary ? 'eye' : 'layers', 14)}<span role="status">${h(message)}</span>${failed ? btn('重试预览','dag-retry') : ''}${temporary ? btn('返回最终结果','dag-preview-final') : ''}</div>` : '';
  let content = canvasContent(recipe, id);
  const s = S.canvasTool, mask = s?.kind === 'mask' && !s.legacy ? s.mask : null;
  if (mask && s.overlay !== false) content = content.replace('</div></div>', `<span class="dag-mask-overlay" style="left:${mask.x}%;top:${mask.y}%;width:${mask.width}%;height:${mask.height}%;opacity:${(mask.opacity ?? 100) / 170}" aria-label="${h(mask.kind)}覆盖示意"></span></div></div>`);
  if (s?.kind === 'remove') content = content.replace('</div></div>', (s.draft.repairs || []).map((m,i) => `<span class="marker repair-mark" style="left:${m.x}%;top:${m.y}%">${i+1}</span>`).join('') + '</div></div>');
  return prefix + content;
}
actions['dag-view'] = mode => {
  if (S.canvasTool?.legacy) return notify('请先完成或取消兼容画布草案');
  dagEnsure(); if (mode !== 'graph') { dagClearPreview(); if (nativeGraphReview) S.dagConnectionDraft = null; }
  S.graphOpen = mode === 'graph'; dagView().mode = mode; S.canvasMenu = ''; S.dagWireFrom = null;
  if (!S.canvasTool && ['smart', 'agent', 'versions'].includes(S.tool)) { go('edit/basic'); }
  dagRenderFocus(mode === 'graph' ? dagWindowFrame().collapsed ? '.graph-window-menu summary' : '[data-dag-viewport]' : '[data-act=dag-view-toggle]');
};
actions['dag-focus-photo'] = () => { const image = $('.edit-image'); if (image) { image.tabIndex = 0; image.focus({preventScroll:true}); } };
changes.dagNode = el => dagSelect(el.value);
actions['dag-select'] = id => dagSelect(id);
actions['dag-node'] = (id, event) => dagSelect(id, event.metaKey || event.ctrlKey || event.shiftKey);
actions['dag-edge'] = key => { dagView().edge = key; dagView().selection = []; dagRenderFocus('[data-dag-viewport]'); };
actions['dag-enter'] = id => { dagClearPreview(); dagView().path.push(id); dagView().selection = []; dagView(); dagView().selection = [dagView().active]; dagRenderFocus('[data-dag-viewport]'); };
actions['dag-path'] = length => { dagClearPreview(); dagView().path = dagView().path.slice(0, Number(length)); dagView(); dagView().selection = [dagView().active]; dagRenderFocus('[data-dag-viewport]'); };
actions['dag-preview'] = () => { if (sheet.open) closeSheet(); dagEnsure(); dagClearPreview(); dagView().target = dagView().active; dagRenderFocus('[data-act=dag-preview-final]'); };
actions['dag-preview-final'] = () => { dagClearPreview(); render(); ($('.dag-commandbar [data-act=dag-menu]') || $('[data-act=dag-view-toggle]'))?.focus({preventScroll:true}); };
actions['dag-solo'] = () => {
  const state = dagPreviewState(), node = dagNode();
  if (state.solo) state.solo = null;
  else if (!S.dagConnectionDraft && dagSoloCandidate(node)) { state.solo = node.id; state.bypass = false; dagView().target = null; }
  else return;
  if(sheet.open)closeSheet();
  dagRenderFocus($('.graph-text-tools') ? '.graph-text-tools [data-act=dag-menu]' : '[data-act=dag-solo]');
};
actions['dag-preview-bypass'] = () => {
  const state = dagPreviewState();
  if (S.dagConnectionDraft && !state.bypass) return;
  state.bypass = !state.bypass; state.solo = null; dagView().target = null;
  if(sheet.open)closeSheet();
  dagRenderFocus($('.graph-text-tools') ? '.graph-text-tools [data-act=dag-menu]' : '[data-act=dag-preview-bypass]');
};
actions['dag-monitor'] = () => { if (sheet.open) closeSheet(); dagView().monitor = !dagView().monitor; dagRenderFocus('.dag-commandbar [data-act=dag-monitor]'); };
function dagContextMenu(event) {
  const area = event.target.closest('[data-dag-viewport]');
  if (!area || S.canvasTool) return;
  event.preventDefault();
  const card = event.target.closest('[data-dag-card]'), wire = event.target.closest('.dag-wire');
  const id = card?.dataset.dagCard, edge = wire?.dataset.val;
  const origin = id ? `[data-dag-node="${CSS.escape(id)}"]` : edge ? `.dag-wire[data-val="${CSS.escape(edge)}"]` : '[data-dag-viewport]';
  const rect = event.target.getBoundingClientRect(), x = event.type === 'contextmenu' ? event.clientX : rect.left, y = event.type === 'contextmenu' ? event.clientY : rect.bottom;
  const graph = dagCurrent(), node = graph.nodes.find(n=>n.id===id), v = dagView();
  if (node && !v.selection.includes(id)) dagSelect(id,false,origin);
  else if (node && v.active !== id) { v.active = id; v.edge = null; render(); }
  if (edge) actions['dag-edge'](edge);
  const allowed = !S.dagConnectionDraft;
  const one = v.selection.length === 1;
  const line = (label, action, value = '') => btn(label,'dag-context-run',action+':'+value);
  const heading = node ? node.name : edge ? '连线' : '工作流画布';
  let choices;
  if (edge) choices = (allowed ? line('插入串行调色','dag-add','serial') : '') + line('编辑连接…','dag-connect-menu');
  else if (!node) choices = (allowed ? line('添加节点…','dag-add-menu') + (S.dagClipboard ? line('粘贴节点','dag-paste') : '') : '') + line('自动整理','dag-layout') + line('适合全图','dag-fit');
  else if (!dagEditable(node)) choices = line('自动整理','dag-layout') + line('适合全图','dag-fit');
  else choices = (allowed && one && dagSoloCandidate(node) ? line('Solo 调色节点','dag-solo') : '') +
    (one ? line('查看此节点输出','dag-preview') : '') + (allowed ? line('复制节点','dag-copy') +
    (one && node.kind==='grade' ? line('复位本节点','dag-reset') : '') + line('删除…','dag-delete') : '') + line('更多节点操作…','dag-menu');
  $('#dag-context')?.hidePopover();
  $('#dag-context')?.remove();
  const context = document.createElement('div');
  context.id = 'dag-context'; context.className = 'dag-picker-popover'; context.popover = 'auto';
  context.setAttribute('role','dialog'); context.setAttribute('aria-label',heading+'操作');
  context.innerHTML = `<h3>${h(heading)}</h3>${choices}`;
  context.addEventListener('toggle', e => { if (e.newState === 'closed') context.remove(); });
  context.addEventListener('keydown', e => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); context.hidePopover(); $(origin)?.focus({preventScroll:true}); }
    else if (['ArrowUp','ArrowDown'].includes(e.key)) {
      e.preventDefault(); const buttons = [...context.querySelectorAll('button')], i = buttons.indexOf(e.target);
      buttons[(i + (e.key === 'ArrowUp' ? -1 : 1) + buttons.length) % buttons.length]?.focus();
    }
  });
  context.dataset.origin = origin;
  $('.dag-workspace').append(context); context.showPopover();
  context.style.width = Math.min(224, innerWidth-24)+'px';
  context.style.left = Math.max(12,Math.min(x,innerWidth-context.offsetWidth-12))+'px';
  context.style.top = Math.max(12,Math.min(y,innerHeight-context.offsetHeight-12))+'px';
  context.querySelector('button')?.focus({preventScroll:true});
}
document.addEventListener('contextmenu', dagContextMenu);
document.addEventListener('keydown', event => {
  if (event.key === 'ContextMenu' || event.shiftKey && event.key === 'F10') dagContextMenu(event);
});
actions['dag-context-run'] = (value, event, button) => {
  const menu = button.closest('#dag-context'), [action, arg] = value.split(':');
  menu.hidePopover(); $(menu.dataset.origin)?.focus({preventScroll:true});
  actions[action]?.(arg);
};
actions['dag-menu'] = () => {
  dagEnsure(); const n = dagNode(), v = dagView(), many = v.selection.length > 1, single = v.selection.length === 1, fixed = !n || ['source','geometry','output'].includes(n.kind), editable = v.selection.some(id=>dagCurrent().nodes.some(node=>node.id===id&&!['source','geometry','output'].includes(node.kind)));
  dialog(many ? '管理 ' + v.selection.length + ' 个节点' : '节点操作 · ' + (n?.name || '工作流'), `<div class="dag-menu-grid">${btn('重命名…','dag-rename','',{disabled:!single||fixed})}${btn('复制并插入','dag-duplicate','',{disabled:!single||n?.kind!=='grade'})}${btn('粘贴参数','dag-paste-attributes','',{disabled:!single||n?.kind!=='grade'||!S.dagClipboard?.nodes.some(node=>node.kind==='grade')})}${btn('复位本节点','dag-reset','',{disabled:!single||n?.kind!=='grade'})}${btn('查看此节点输出','dag-preview','',{disabled:!single||!n})}${btn('删除','dag-delete','',{disabled:!editable})}</div><details class="dag-menu-advanced"><summary>高级图操作</summary><div class="dag-menu-grid">${btn('Solo 调色节点','dag-solo','',{disabled:!dagSoloCandidate(n)})}${btn('旁路全部调色（仅查看）','dag-preview-bypass')}${btn('复制节点','dag-copy','',{disabled:!editable})}${btn('粘贴节点','dag-paste','',{disabled:!S.dagClipboard})}${btn('成组','dag-group','',{disabled:!editable})}${btn('解组','dag-ungroup','',{disabled:!single||n?.kind!=='group'})}${btn('编辑连接…','dag-connect-menu')}${btn(v.monitor?'隐藏结果监看':'显示结果监看','dag-monitor')}${btn('自动整理','dag-layout')}${btn('复位调色参数，保留节点','dag-reset-grades')}${btn('切换忽略全部调色节点','dag-bypass-all')}${btn('保存整个工作流…','dag-template-save','whole')}${btn('应用模板到本张…','dag-template-library','',{disabled:!Studio.data.dagTemplates?.length})}${btn('评审场景与模拟状态','dag-review')}</div></details>`,btn('关闭','close'));
};
actions['dag-add-menu'] = () => {
  dagEnsure(); const node=dagNode(),single=dagView().selection.length===1;
  dialog('添加节点','<p>串行节点为中性。并行支路自动合流，强度 0%，不改变现有结果。</p><div class="dag-menu-grid">'+btn('串行调色节点','dag-add','serial')+btn('并行调色与混合','dag-add','parallel')+btn('Layer 调色与有序混合','dag-add','layer')+btn('局部调整与蒙版','dag-local')+'</div><details class="dag-menu-advanced"><summary>更多插入方式</summary><div class="dag-menu-grid">'+btn('在当前节点前插入','dag-add-before','',{disabled:!single||node?.kind==='source'})+btn('追加到图尾','dag-append')+btn('添加 Outside 调色','dag-outside','',{disabled:!single||node?.kind!=='grade'||!node.mask})+'</div></details>',btn('取消','close'));
};
function dagInsertion(g) {
  const v = dagView();
  if (v.edge) { const [to, slot] = v.edge.split(':'); return g.edges.find(e => e.to === to && e.slot === slot); }
  const outgoing = g.edges.filter(e => e.from === v.active);
  if (outgoing.length === 1) return outgoing[0];
  if (outgoing.length > 1) { notify('当前输出存在分叉，请先选择要插入的连线'); return null; }
  return g.edges.find(e => e.to === g.nodes.find(n => n.kind === 'geometry')?.id) ?? g.edges.find(e => e.to === g.nodes.find(n => n.kind === 'output')?.id);
}
actions['dag-add'] = kind => {
  closeSheet(); dagEnsure(); let added;
  dagCommit(['parallel','layer'].includes(kind) ? '添加 '+kind+' 调色（0%）' : '添加中性调色节点', g => {
    const edge = dagInsertion(g); if (!edge) return;
    added = { id: dagID(), name: kind === 'parallel' ? '并行调色' : '调色 ' + (g.nodes.filter(n => n.kind === 'grade').length + 1), kind: 'grade', enabled: true, params: {} };
    const index = g.nodes.findIndex(n => n.id === edge.to); g.nodes.splice(index, 0, added);
    g.edges = g.edges.filter(e => e !== edge);
    if (['parallel','layer'].includes(kind)) {
      const mix = { id: dagID(), name: kind === 'layer' ? 'Layer Mixer' : 'Parallel Mixer', kind: 'mix', enabled: true, params: { amount: 0, mode:kind } }; g.nodes.splice(index + 1, 0, mix);
      g.edges.push({ from: edge.from, to: added.id, slot: 'image' }, { from: edge.from, to: mix.id, slot: 'base' }, { from: added.id, to: mix.id, slot: 'layer' }, { from: mix.id, to: edge.to, slot: edge.slot });
      const p = dagPosition(g.nodes.find(n => n.id === edge.from), 0), key = dagView().path.join('/');
      currentEdit().dagLayout ??= {}; currentEdit().dagLayout[key + ':' + added.id] = { x: p.x + 235, y: p.y + 165 };
    } else g.edges.push({ from: edge.from, to: added.id, slot: 'image' }, { from: added.id, to: edge.to, slot: edge.slot });
  });
  if (added) { dagView().edge = null; dagSelect(added.id); }
};
actions['dag-toggle'] = () => {
  closeSheet(); const ids = dagView().selection.filter(id=>dagCurrent().nodes.some(n=>n.id===id&&!['source','geometry','output'].includes(n.kind)));
  if (!ids.length) return notify('请选择可忽略的调色、混合或组节点');
  dagCommit('切换忽略所选节点', g => g.nodes.filter(n => ids.includes(n.id)).forEach(n => n.enabled = n.enabled === false));
};
actions['dag-reset'] = () => { closeSheet(); dagCommit('复位 ' + dagNode().name, g => g.nodes.find(n => n.id === dagView().active).params = {}); };
actions['dag-rename'] = () => dialog('重命名节点', field('节点名称', 'dagName', dagNode().name), btn('取消', 'close') + btn('保存名称', 'dag-rename-save', '', { cls: 'primary' }));
actions['dag-rename-save'] = () => { const name = value('dagName').trim().slice(0, 60); if (!name) return notify('请填写节点名称'); closeSheet(); dagCommit('重命名节点', g => g.nodes.find(n => n.id === dagView().active).name = name); };
changes.dagParameter = changes.dagNumber = el => {
  if (!el.validity.valid || el.value === '' || el.dataset.photo !== Studio.data.work || el.dataset.node !== dagView().active) { el.setAttribute('aria-invalid', 'true'); return; }
  const k = el.dataset.key, val = Number(el.value);
  dagCommit(dagNode().name + '：' + k + ' ' + val, g => {
    const n = g.nodes.find(n => n.id === el.dataset.node);
    if (k === 'maskOpacity') n.mask.opacity = val;
    else if (k === 'feather') n.mask.feather = val;
    else n.params[k] = val;
  }, el.name !== 'dagNumber');
  el.removeAttribute('aria-invalid');
  if (el.name === 'dagNumber') {
    el.defaultValue = el.value;
    requestAnimationFrame(() => { if (el.isConnected) render(); });
  }
};
inputs.dagParameter = el => {
  const number = el.parentElement.querySelector('input[type=number]'); if (number) number.value = el.value;
  if (el.dataset.photo !== Studio.data.work || el.dataset.node !== dagView().active) return;
  const root = structuredClone(currentEdit().recipe.dag), n = dagNode(dagCurrent(root)), k = el.dataset.key;
  if (k === 'maskOpacity') n.mask.opacity = Number(el.value);
  else if (k === 'feather') n.mask.feather = Number(el.value);
  else n.params[k] = Number(el.value);
  const filter = RMPhotos.filter(RMPhotos.displayLook(dagProject(root)));
  $$('.developed,.dag-monitor img').forEach(img => img.style.filter = filter);
};
changes.dagLut = el => dagCommit('本节点 LUT：' + el.value, g => g.nodes.find(n => n.id === dagView().active).params.lut = el.value);
changes.dagCrop = el => dagCommit('几何：裁切比例', g => g.nodes.find(n => n.id === dagView().active).params.crop = el.value);
changes.dagOffline = el => { Studio.asset(Studio.data.work).online = !el.checked; Studio.save(); render(); };
actions['dag-swap'] = () => dagCommit('交换混合输入顺序', g => g.edges.filter(e => e.to === dagView().active).forEach(e => e.slot = e.slot === 'base' ? 'layer' : 'base'));
actions['dag-copy'] = () => { closeSheet(); const ids = dagView().selection.length ? dagView().selection : [dagView().active]; const g = dagCurrent(); S.dagClipboard = { nodes: structuredClone(g.nodes.filter(n => ids.includes(n.id) && !['source', 'geometry', 'output'].includes(n.kind))), edges: structuredClone(g.edges.filter(e => ids.includes(e.from) && ids.includes(e.to))) }; notify('已复制节点 · 粘贴将串行插入，可能叠加效果'); };
function dagRemap(graph) {
  const map = new Map(graph.nodes.map(n => [n.id, dagID()]));
  return { ...structuredClone(graph), nodes: graph.nodes.map(n => {
    const copy = { ...structuredClone(n), id:map.get(n.id), ...(n.graph ? {graph:dagRemap(n.graph)} : {}) };
    if(copy.mask?.reference)copy.mask.reference=map.get(copy.mask.reference) ?? copy.mask.reference;
    for(const component of copy.mask?.components || [])if(component.reference)component.reference=map.get(component.reference) ?? component.reference;
    return copy;
  }), edges: graph.edges.map(e => ({ ...e, from: map.get(e.from), to: map.get(e.to) })) };
}
actions['dag-paste'] = () => {
  closeSheet(); if (!S.dagClipboard?.nodes.length) return notify('先复制可编辑节点');
  if (S.dagClipboard.nodes.some(n => n.kind === 'mix')) return notify('含混合的片段请先成组再复制');
  const fragment = dagRemap(S.dagClipboard); let last;
  dagCommit('串行粘贴节点（效果可能叠加）', g => {
    const edge = dagInsertion(g); if (!edge) return;
    g.edges = g.edges.filter(e => e !== edge); let from = edge.from;
    for (const n of fragment.nodes) { g.nodes.splice(g.nodes.findIndex(x => x.id === edge.to), 0, n); g.edges.push({ from, to: n.id, slot: 'image' }); from = n.id; last = n.id; }
    g.edges.push({ from, to: edge.to, slot: edge.slot });
  }); if (last) dagSelect(last);
};
function dagDeleteNodes(ids, keepBase) {
  return dagCommit('删除 ' + ids.length + ' 个节点', g => {
    for (const id of ids) {
      const n = g.nodes.find(n => n.id === id); if (!n || ['source', 'geometry', 'output'].includes(n.kind)) continue;
      const incoming = g.edges.filter(e => e.to === id), outgoing = g.edges.filter(e => e.from === id);
      const prior = incoming.find(e => n.kind === 'mix' ? e.slot === 'base' : e.slot === 'image');
      if (n.kind === 'mix' && !keepBase) throw new Error('删除混合需要明确保留基底');
      if (n.kind === 'mix') {
        const branch = incoming.find(e => e.slot === 'layer')?.from;
        if (branch && g.nodes.find(x => x.id === branch)?.kind === 'grade' && g.edges.filter(e => e.from === branch).length === 1) {
          g.nodes = g.nodes.filter(x => x.id !== branch); g.edges = g.edges.filter(e => e.from !== branch && e.to !== branch);
        }
      }
      g.edges = g.edges.filter(e => e.from !== id && e.to !== id);
      if (prior) outgoing.forEach(e => g.edges.push({ ...e, from: prior.from }));
      g.nodes = g.nodes.filter(x => x.id !== id);
    }
  });
}
actions['dag-delete'] = () => {
  const ids = dagView().selection.length ? dagView().selection : [dagView().active], g = dagCurrent();
  if (ids.some(id => ['source', 'geometry', 'output'].includes(g.nodes.find(n => n.id === id)?.kind))) return notify('固定原片、几何与输出不能删除');
  closeSheet();
  if (ids.some(id => g.nodes.find(n => n.id === id)?.kind === 'mix')) {
    S.dagDeleteIDs = ids;
    dialog('删除混合与支路', '<p>保留基底 base，移除该合流和仅由它消费的图层调色支路。整个操作可撤销。</p>', btn('取消', 'close') + btn('保留基底并删除', 'dag-delete-confirm', '', { cls: 'primary' }));
  } else { dagDeleteNodes(ids, true); dagView().selection = [dagView().active]; render(); }
};
actions['dag-delete-confirm'] = () => { closeSheet(); dagDeleteNodes(S.dagDeleteIDs, true); dagView().selection = [dagView().active]; render(); };
actions['dag-group'] = () => {
  closeSheet(); const ids = dagView().selection.length ? dagView().selection : [dagView().active]; let group;
  const g = dagCurrent(), incoming = g.edges.filter(e => ids.includes(e.to) && !ids.includes(e.from)), outgoing = g.edges.filter(e => ids.includes(e.from) && !ids.includes(e.to));
  if (!ids.length || new Set(incoming.map(e => e.from)).size !== 1 || new Set(outgoing.map(e => e.from)).size !== 1 || ids.some(id => ['source', 'geometry', 'output'].includes(g.nodes.find(n => n.id === id)?.kind))) return notify('请选择单入单出的连续可编辑片段（可含完整支路和合流）');
  dagCommit('选中片段成组', graph => {
    const input = { id: dagID(), kind: 'source', name: '组输入', enabled: true, params: {} }, output = { id: dagID(), kind: 'output', name: '组输出', enabled: true, params: {} };
    group = { id: dagID(), kind: 'group', name: '调色组', enabled: true, params: {}, graph: { nodes: [input, ...graph.nodes.filter(n => ids.includes(n.id)), output], edges: [...graph.edges.filter(e => ids.includes(e.from) && ids.includes(e.to)), ...incoming.map(e => ({ ...e, from: input.id })), { from: outgoing[0].from, to: output.id, slot: 'image' }] } };
    graph.nodes.splice(graph.nodes.findIndex(n => n.id === ids[0]), 0, group); graph.nodes = graph.nodes.filter(n => !ids.includes(n.id));
    graph.edges = [...graph.edges.filter(e => !ids.includes(e.from) && !ids.includes(e.to)), { from: incoming[0].from, to: group.id, slot: 'image' }, ...outgoing.map(e => ({ ...e, from: group.id }))];
  }); if (group) dagSelect(group.id);
};
actions['dag-ungroup'] = () => {
  closeSheet(); const id = dagView().active;
  dagCommit('解组', g => {
    const group = g.nodes.find(n => n.id === id); if (group?.kind !== 'group') return;
    const inner = group.graph, source = inner.nodes.find(n => n.kind === 'source'), out = inner.nodes.find(n => n.kind === 'output');
    const predecessor = g.edges.find(e => e.to === id).from, tail = inner.edges.find(e => e.to === out.id).from, successors = g.edges.filter(e => e.from === id);
    g.nodes = g.nodes.flatMap(n => n.id === id ? inner.nodes.filter(x => ![source.id, out.id].includes(x.id)) : [n]);
    g.edges = [...g.edges.filter(e => e.from !== id && e.to !== id), ...inner.edges.filter(e => e.to !== out.id).map(e => ({ ...e, from: e.from === source.id ? predecessor : e.from })), ...successors.map(e => ({ ...e, from: tail }))];
  }); dagView().selection = [dagView().active]; render();
};
function dagFrameGraph(mode = dagTransform().framing) {
  const tr = dagTransform(); tr.framing = mode || 'readable';
  const viewport = $('[data-dag-viewport]'), cards = $$('.dag-card');
  if (!viewport || !cards.length || tr.framing==='manual') return;
  const width = viewport.clientWidth, height = viewport.clientHeight;
  const boxes = cards.map(card=>({id:card.dataset.dagCard, x:card.offsetLeft, y:card.offsetTop, width:card.offsetWidth, height:card.offsetHeight}));
  const minX = Math.min(...boxes.map(b=>b.x)), maxX = Math.max(...boxes.map(b=>b.x+b.width));
  const minY = Math.min(...boxes.map(b=>b.y)), maxY = Math.max(...boxes.map(b=>b.y+b.height));
  const fit = Math.max(0.01, Math.min((width-40)/(maxX-minX), (height-40)/(maxY-minY)));
  tr.scale = tr.framing==='fit' ? Math.min(1,fit) : 1;
  tr.x = (width-(minX+maxX)*tr.scale)/2;
  tr.y = (height-(minY+maxY)*tr.scale)/2;
  const active = boxes.find(b=>b.id===dagView().active);
  if (tr.framing==='readable' && active) {
    if (maxX-minX>width-40) tr.x = active.width>width-24 ? (width-active.width)/2-active.x : Math.max(12-active.x,Math.min(tr.x,width-12-active.x-active.width));
    if (maxY-minY>height-40) tr.y = active.height>height-24 ? (height-active.height)/2-active.y : Math.max(12-active.y,Math.min(tr.y,height-12-active.y-active.height));
  }
  dagPaintTransform(tr);
}
function dagZoomAt(tr, scale, x, y) {
  tr.x = x-(x-tr.x)*scale/tr.scale; tr.y = y-(y-tr.y)*scale/tr.scale;
  tr.scale = scale; tr.framing = 'manual'; dagPaintTransform(tr);
}
actions['dag-fit'] = () => { dagFrameGraph('fit'); $('[data-dag-viewport]')?.focus({preventScroll:true}); };
actions['dag-readable'] = () => { dagFrameGraph('readable'); $('[data-dag-viewport]')?.focus({preventScroll:true}); };
actions['dag-zoom'] = direction => {
  const viewport = $('[data-dag-viewport]'), tr = dagTransform(); if (!viewport) return;
  dagZoomAt(tr,Math.min(2.5,Math.max(0.01,tr.scale*(direction==='in'?1.2:1/1.2))),viewport.clientWidth/2,viewport.clientHeight/2);
  viewport.focus({preventScroll:true});
};
actions['dag-layout'] = () => {
  closeSheet();
  const g = dagCurrent(), key = dagView().path.join('/'), depths = new Map(), lanes = new Map(), occupied = new Set();
  const depth = id => {
    if (!depths.has(id)) depths.set(id, Math.max(-1, ...g.edges.filter(e => e.to === id).map(e => depth(e.from))) + 1);
    return depths.get(id);
  };
  const branchLane = (id, lane, seen = new Set()) => {
    if (seen.has(id) || g.nodes.find(n => n.id === id)?.kind === 'source' || g.edges.filter(e => e.from === id).length > 1) return;
    seen.add(id); lanes.set(id, lane);
    g.edges.filter(e => e.to === id).forEach(e => branchLane(e.from, lane, seen));
  };
  g.nodes.filter(n => n.kind === 'mix').forEach((n, i) => {
    const layer = g.edges.find(e => e.to === n.id && e.slot === 'layer');
    if (layer) branchLane(layer.from, i + 1);
  });
  currentEdit().dagLayout ??= {};
  g.nodes.forEach(n => {
    const column = depth(n.id); let lane = lanes.get(n.id) ?? 0;
    while (occupied.has(column + ':' + lane)) lane++;
    occupied.add(column + ':' + lane);
    currentEdit().dagLayout[key + ':' + n.id] = { x: 40 + column * 235, y: 75 + lane * 165 };
  });
  dagTransform().framing='readable';
  Studio.save(); dagRenderFocus('[data-dag-viewport]'); notify('已整理分支布局 · 不改变照片或像素历史');
};
actions['dag-connect-menu'] = () => {
  dagEnsure(); const g = S.dagConnectionDraft ?? dagCurrent();
  dialog('编辑连接', '<p>可先断开再重接。只有有效图才能应用；取消保留原图。</p>' + select('从输出节点', 'dagFrom', g.nodes.filter(n => n.kind !== 'output').map(n => [n.id, n.name]), dagView().active) + select('到输入节点', 'dagTo', g.nodes.filter(n => n.kind !== 'source').map(n => [n.id, n.name]), g.nodes.find(n => n.kind === 'output').id) + select('输入插槽', 'dagSlot', ['image', 'base', 'layer'], 'image') + `<div id="dag-connection-error" role="status">${h(S.dagConnectionDraft ? dagError(g) : '')}</div>`, btn('取消', 'close') + btn('断开此输入', 'dag-connect-disconnect') + btn('预览重连', 'dag-connect-propose'));
};
function dagPropose(from, to, slot, disconnect = false) {
  S.dagConnectionDraft ??= structuredClone(dagCurrent());
  const draft = structuredClone(S.dagConnectionDraft); draft.edges = draft.edges.filter(e => !(e.to === to && e.slot === slot));
  if (!disconnect) draft.edges.push({ from, to, slot });
  S.dagConnectionDraft = draft; closeSheet(); dagView().mode = 'graph'; render();
}
actions['dag-connect-propose'] = () => dagPropose(value('dagFrom'), value('dagTo'), value('dagSlot'));
actions['dag-connect-disconnect'] = () => dagPropose(value('dagFrom'), value('dagTo'), value('dagSlot'), true);
actions['dag-connect-apply'] = () => {
  const graph = S.dagConnectionDraft; if (!graph || dagError(graph)) return;
  S.dagConnectionDraft = null; dagCommit('修改节点连接', g => { g.edges = graph.edges; });
};
actions['dag-connect-cancel'] = () => { S.dagConnectionDraft = null; S.dagWireFrom = null; render(); };
actions['dag-port'] = val => {
  const [id, slot] = val.split(':');
  if (slot === 'out') { S.dagWireFrom = id; render(); }
  else if (S.dagWireFrom) { const from = S.dagWireFrom; S.dagWireFrom = null; dagPropose(from, id, slot); }
  else notify('先选择一个输出端口；也可通过“编辑连接”完成');
};
actions['dag-local'] = () => { closeSheet(); actions['dag-add']('serial'); const node = dagNode(); if (node.kind !== 'grade') return; dagCommit('命名局部调整', g => g.nodes.find(n => n.id === node.id).name = '局部调整'); actions['dag-mask-menu'](); };
actions['dag-mask-menu'] = () => {
  dagEnsure(); const n = dagNode(); if (n.kind !== 'grade') return notify('蒙版只添加到调色节点');
  dialog('为 ' + n.name + ' 新建蒙版', '<p>创建覆盖后仍需明确采用；取消不会改变节点。AI 类型为模拟选区。</p><div class="dag-menu-grid">' + ['主体', '天空', '径向渐变', '线性渐变', '画笔'].map(kind => btn(kind, 'dag-mask-start', kind, { disabled: !Studio.asset(Studio.data.work).online })).join('') + '</div>' + (!Studio.asset(Studio.data.work).online ? '<p>原片离线，请先接回。</p>' : ''), btn('取消', 'close'));
};
actions['dag-mask-start'] = kind => {
  closeSheet(); const n = dagNode();
  S.dagMaskSession = { photo: Studio.data.work, node: n.id, returnMode: dagView().mode, draft: { kind, x: 50, y: 50, width: kind === '天空' ? 95 : 34, height: kind === '天空' ? 45 : 55, enabled: true, opacity: 100, feather: 45 } };
  dagView().mode = 'photo'; S.tool = 'masks'; render();
};
actions['dag-mask-edit'] = () => { const n = dagNode(); S.dagMaskSession = { photo: Studio.data.work, node: n.id, returnMode: dagView().mode, draft: structuredClone(n.mask) }; dagView().mode = 'photo'; render(); };
actions['dag-mask-accept'] = () => {
  const session = S.dagMaskSession; if (!session || session.photo !== Studio.data.work || session.node !== dagView().active) return;
  S.dagMaskSession = null; dagView().mode = session.returnMode;
  dagCommit('采用 ' + session.draft.kind + ' 蒙版', g => g.nodes.find(n => n.id === session.node).mask = session.draft);
};
actions['dag-mask-cancel'] = () => { if (S.dagMaskSession) dagView().mode = S.dagMaskSession.returnMode; S.dagMaskSession = null; render(); };
actions['dag-mask-select'] = id => { dagSelect(id); dagView().mask = true; render(); };
changes.dagMaskEnabled = el => dagCommit('启停节点蒙版', g => g.nodes.find(n => n.id === dagView().active).mask.enabled = el.checked);
actions['dag-mask-invert'] = () => dagCommit('反转节点蒙版', g => { const m = g.nodes.find(n => n.id === dagView().active).mask; m.invert = !m.invert; });
actions['dag-mask-delete'] = () => dagCommit('删除节点蒙版', g => delete g.nodes.find(n => n.id === dagView().active).mask);
actions['dag-mask-missing'] = () => dagCommit('模拟素材缺失', g => g.nodes.find(n => n.id === dagView().active).mask.missing = true);
actions['dag-mask-rebuild'] = () => { if (!Studio.asset(Studio.data.work).online) return notify('请先接回原片'); dagCommit('重建示例蒙版', g => g.nodes.find(n => n.id === dagView().active).mask.missing = false); };
actions['dag-crop-start'] = () => { S.dagCropSession = { recipe: structuredClone(currentEdit().recipe), mode: dagView().mode }; dagView().mode = 'photo'; render(); };
actions['dag-crop-finish'] = () => { dagView().mode = S.dagCropSession.mode; S.dagCropSession = null; render(); };
actions['dag-crop-cancel'] = () => { const old = S.dagCropSession; if (!old) return; Studio.setRecipe(Studio.data.work, '取消几何编辑', old.recipe); dagView().mode = old.mode; S.dagCropSession = null; render(); };
actions['dag-failure'] = () => {
  failedDagPhotos.add(Studio.data.work); resolveEditorRetry('dag-retry');
  S.dagRenderFailed = true; dagView().mode = 'photo'; render();
  notifyEditor('工作流预览失败，已保留上次画面。', 'error', Studio.data.work, 'dag-retry');
};
actions['dag-retry'] = () => { if (!failedDagPhotos.delete(Studio.data.work)) return; resolveEditorRetry('dag-retry'); S.dagRenderFailed = false; render(); notify('模拟重试完成'); };
actions['dag-template-save'] = kind => {
  dagEnsure(); if (kind === 'group' && dagNode()?.kind !== 'group') return notify('先将合法片段成组');
  S.dagTemplateKind = kind;
  dialog('保存工作流模板', field('模板名称', 'dagTemplateName', kind === 'group' ? dagNode().name : '我的照片工作流') + '<p>组模板插入当前节点后；整图模板应用时可选择当前或原片底稿。模型像素不跨照片直接复制。</p>', btn('取消', 'close') + btn('保存模板', 'dag-template-save-confirm', '', { cls: 'primary' }));
};
actions['dag-template-save-confirm'] = () => {
  const name = value('dagTemplateName').trim(); if (!name) return notify('请输入模板名称');
  const kind = S.dagTemplateKind, graph = kind === 'group' ? dagNode().graph : currentEdit().recipe.dag;
  const template = { id: Studio.uid(), name, kind, graph: structuredClone(graph) };
  (Studio.data.dagTemplates ??= []).push(template); Studio.save(); closeSheet(); render(); notify('已保存工作流模板');
};
actions['dag-template-library'] = () => dialog('应用模板到本张', `<div class="menu-list">${(Studio.data.dagTemplates || []).map(t=>btn(t.name,'dag-template-open',t.id,{icon:'folder'})).join('')}</div>`,btn('取消','close'));
actions['dag-template-open'] = id => {
  const t = Studio.data.dagTemplates.find(t => t.id === id); S.dagTemplateID = id;
  dialog('应用工作流 · ' + t.name, `<p>${t.kind === 'group' ? '当前草稿：插入所选连线或当前节点的唯一出边，可在组内插入；分叉需先选连线。原片底稿或批量应用：插入目标图的几何节点之前。不会替换整个工作流。' : '使用模板的节点与连接，保留所选底稿的裁切、整图摄影调整、模型与输出。可撤销。'}</p>` + select('底稿', 'dagTemplateBase', [['current', '当前草稿'], ['original', '原片']], 'current'), btn('取消', 'close') + btn('应用到本张', 'dag-template-apply', '', { cls: 'primary' }));
};
function dagApplyTemplate(recipe, t, baseline) {
  const old = structuredClone(recipe), g = baseline === 'original' ? dagSeed(Studio.freshRecipe()) : old.dag ?? dagSeed(old);
  if (t.kind === 'whole') {
    const remapped=dagRemap(t.graph);
    remapped.base=g.base;
    remapped.photographic=g.photographic;
    if (g.models) remapped.models=g.models; else delete remapped.models;
    for (const kind of ['source','geometry','output']) {
      const target=remapped.nodes.find(n=>n.kind===kind), local=g.nodes.find(n=>n.kind===kind);
      if (target && local) target.params=structuredClone(local.params);
    }
    return dagProject(remapped);
  }
  const node = { id: dagID(), kind: 'group', name: t.name, enabled: true, params: {}, graph: dagRemap(t.graph) };
  const edge = g.edges.find(e => e.to === g.nodes.find(n => n.kind === 'geometry')?.id) ?? g.edges.find(e => e.to === g.nodes.find(n => n.kind === 'output')?.id);
  g.nodes.splice(g.nodes.findIndex(n => n.id === edge.to), 0, node); g.edges = g.edges.filter(e => e !== edge); g.edges.push({ from: edge.from, to: node.id, slot: 'image' }, { from: node.id, to: edge.to, slot: edge.slot }); return dagProject(g);
}
actions['dag-template-apply'] = () => {
  const t = Studio.data.dagTemplates.find(t => t.id === S.dagTemplateID), base = value('dagTemplateBase');
  if (t.kind === 'group' && base === 'current') {
    dagEnsure();
    if (!dagInsertion(dagCurrent())) return;
    let added;
    const applied = dagCommit('插入组模板：' + t.name, g => {
      const edge = dagInsertion(g);
      added = { id: dagID(), kind: 'group', name: t.name, enabled: true, params: {}, graph: dagRemap(t.graph) };
      g.nodes.splice(g.nodes.findIndex(n => n.id === edge.to), 0, added);
      g.edges = g.edges.filter(e => e !== edge);
      g.edges.push({ from: edge.from, to: added.id, slot: 'image' }, { from: added.id, to: edge.to, slot: edge.slot });
    });
    if (applied) { closeSheet(); dagView().edge = null; dagSelect(added.id); }
    return;
  }
  const result = dagApplyTemplate(currentEdit().recipe, t, base); if (dagError(result.dag)) return notify(dagError(result.dag), 'error');
  if (!admitModelGeometry(result)) return;
  Studio.setRecipe(Studio.data.work, '应用工作流：' + t.name, result); closeSheet(); dagView(); render();
};
actions['dag-batch-menu'] = () => {
  if (S.page !== 'library' || isTriage()) return notify('请在资料库选中照片后打开批量工作流');
  const b = activeBrowser(), ids = b.selected.filter(validWork), source = ids.includes(b.focus) ? b.focus : ids[0];
  if (ids.length < 2) return notify('请选择源照片与至少一张目标照片');
  const edit = Studio.edit(source), graph = structuredClone(edit.recipe.dag ?? dagSeed(edit.recipe));
  let scope = graph;
  for (const id of edit.dagView?.path ?? []) scope = scope.nodes.find(n=>n.id===id)?.graph ?? scope;
  const node = scope.nodes.find(n=>n.id===edit.dagView?.active && n.kind==='grade') ?? scope.nodes.find(n=>n.kind==='grade') ?? graph.nodes.find(n=>n.kind==='grade');
  const targets = ids.filter(id=>id!==source);
  S.dagBatchSource = { id:source, graph, node };
  S.dagBatchSelection = targets; S.dagBatchIDs = targets; S.dagBatchChosen = [...targets];
  dagBatchForm();
};
function dagBatchForm() {
  const source = S.dagBatchSource, operation = value('dagBatchOperation') || (source.node ? 'sync' : 'template'), baseline = value('dagBatchBase') || 'current', picked = value('dagBatchTemplate');
  dialog('批量工作流预检', `<p>源：${h(Studio.asset(source.id).name)}／当前草稿${source.node ? ' · '+h(source.node.name) : ''}。其余所选照片作为目标，源照片不写入。</p>` + select('操作', 'dagBatchOperation', [...(source.node ? [['sync', nativeBatchReview ? '仅同步节点曝光（保留其他字段）' : '同步源节点曝光与色彩（保留未选字段）']] : []), ['template', '创建工作流分支']], operation) + `<div class="dag-batch-template"${operation==='template'?'':' hidden'}>${select('工作流模板','dagBatchTemplate',[['','源照片工作流'],...(Studio.data.dagTemplates || []).map(t=>[t.id,t.name])],picked)}</div>` + select('目标底稿', 'dagBatchBase', [['current', '每张当前版本'], ['original', '从原片创建分支']], baseline) + `<div class="dag-target-list">${S.dagBatchIDs.map(id => check(Studio.asset(id).name + (Studio.asset(id).online ? '' : ' · 离线，待接回'), 'dagBatchTarget', S.dagBatchChosen.includes(id), { key: id })).join('')}</div><details class="dag-menu-advanced"><summary>原型评审样本</summary><div class="row wrap">${btn('20 张评审样本', 'dag-batch-samples', '20')}${btn('200 张评审样本', 'dag-batch-samples', '200')}${btn('仅当前选片', 'dag-batch-samples', 'selection')}</div></details><p>未选字段保留；从原片分支是显式另一个底稿。覆盖与预览为模拟。</p>`, btn('取消', 'close') + btn('核对将发生的变化', 'dag-batch-preflight', '', { cls: 'primary', disabled: !S.dagBatchChosen.length }));
}
changes.dagBatchOperation = el => { sheet.querySelector('.dag-batch-template').hidden = el.value !== 'template'; };
actions['dag-batch-samples'] = count => {
  if (count === 'selection') { S.dagBatchIDs = [...S.dagBatchSelection]; }
  else {
    const total = Number(count), source = S.dagBatchSource.id; S.dagBatchIDs = [];
    for (let i = 0; i < total; i++) {
      const id = 'dag-review-' + i;
      Studio.data.catalog.records[id] ??= { ...structuredClone(Studio.asset(source)), id, source, name: '评审样本 ' + (i + 1) + '.ARW', online: true };
      S.dagBatchIDs.push(id);
    }
  }
  S.dagBatchChosen = S.dagBatchIDs.slice(); dagBatchForm();
  const samples = sheet.querySelector('.dag-menu-advanced'); samples.open = true; samples.querySelector('summary').focus();
};
changes.dagBatchTarget = el => { S.dagBatchChosen = el.checked ? [...S.dagBatchChosen, el.dataset.key] : S.dagBatchChosen.filter(id => id !== el.dataset.key); sheet.querySelector('[data-act=dag-batch-preflight]').disabled = !S.dagBatchChosen.length; };
actions['dag-batch-preflight'] = () => {
  const operation = value('dagBatchOperation'), baseline = value('dagBatchBase'), source = S.dagBatchSource;
  if (!source || !S.dagBatchChosen.length || (operation==='sync'&&!source.node)) return;
  const template = Studio.data.dagTemplates?.find(t => t.id === value('dagBatchTemplate')) ?? { kind:'whole', name:'源照片工作流', graph:source.graph };
  S.dagBatchPlanSource = source.id;
  S.dagBatchPlan = S.dagBatchChosen.map(id => {
    const before = structuredClone(Studio.edit(id).recipe);
    let next;
    if (operation === 'template') next = dagApplyTemplate(before, template, baseline);
    else {
      const g = baseline === 'original' ? dagSeed(Studio.freshRecipe()) : before.dag ? structuredClone(before.dag) : dagSeed(before);
      const target = g.nodes.find(n => n.kind === 'grade');
      for (const k of nativeBatchReview ? ['ev'] : ['ev', 'contrast', 'warmth', 'sat']) target.params[k] = source.node.params[k] ?? 0;
      next = dagProject(g);
    }
    return { id, before, fingerprint: JSON.stringify(before), next, state: Studio.asset(id).online ? 'pending' : 'offline' };
  });
  dialog('确认批量变更', `<p>${S.dagBatchPlan.length} 张 · ${operation === 'sync' ? nativeBatchReview ? '仅同步曝光' : '仅同步曝光／对比／暖色／饱和度' : '完整工作流分支'} · ${baseline === 'current' ? '每张当前版本' : '原片底稿'}</p><p>可执行 ${S.dagBatchPlan.filter(i => i.state === 'pending').length}，离线 ${S.dagBatchPlan.filter(i => i.state === 'offline').length}。旧版本保留，未选字段不写。取消不提交。${nativeBatchReview ? '只创建候选，不自动采用，也不更改目标草稿。' : ''}</p><div class="dag-batch-preview">${S.dagBatchPlan.slice(0, 3).map(i => `<figure>${pic(i.id, '', 'style="filter:' + RMPhotos.filter(RMPhotos.displayLook(i.next)) + '"')}<figcaption>${h(Studio.asset(i.id).name)} · 变更后示意</figcaption></figure>`).join('')}</div>`, btn('取消', 'close') + btn('确认创建批量版本', 'dag-batch-start', '', { cls: 'primary' }));
};
let dagBatchTimer;
actions['dag-batch-start'] = () => {
  if (Studio.data.dagBatches?.some(b=>b.running)) return notify('已有工作流批次在运行，请先查看结果');
  const batch = { id: Studio.uid(), source: S.dagBatchPlanSource, items: structuredClone(S.dagBatchPlan), running: true };
  (Studio.data.dagBatches ??= []).push(batch); closeSheet(); dagRunBatch(batch); actions['dag-batch-results'](batch.id);
};
function dagRunBatch(batch) {
  clearTimeout(dagBatchTimer);
  const tick = () => {
    if (!batch.running) return;
    const i = batch.items.find(i => i.state === 'pending');
    if (!i) { batch.running = false; Studio.save(); if (sheet.open && sheet.dataset.dagBatch === batch.id) actions['dag-batch-results'](batch.id); return; }
    if (JSON.stringify(Studio.edit(i.id).recipe) !== i.fingerprint) i.state = 'conflict';
    else if (!Studio.asset(i.id).online) i.state = 'offline';
    else {
      if (!nativeBatchReview) Studio.setRecipe(i.id, '批量同步工作流', i.next);
      const live = Studio.edit(i.id), saved = live.saved, last = live.lastSaved;
      const version = Studio.candidate(i.id, '工作流', i.next);
      if (nativeBatchReview) { live.saved = saved; live.lastSaved = last; }
      i.version = version.id; i.after = JSON.stringify(live.recipe); i.state = 'done';
    }
    Studio.save();
    if (sheet.open && sheet.dataset.dagBatch === batch.id) actions['dag-batch-results'](batch.id);
    dagBatchTimer = setTimeout(tick, 85);
  }; tick();
}
actions['dag-batch-results'] = id => {
  const b = Studio.data.dagBatches.find(b => b.id === id); S.dagBatchID = id;
  dialog('批量工作流结果', `<p>${b.running ? '正在处理，可关闭此面板返回编辑' : '本轮已停止'} · ${b.items.filter(i => i.state === 'done').length}/${b.items.length} 成功</p><div class="dag-result-list">${b.items.slice(0, 30).map(i => `<p>${h(Studio.asset(i.id).name)} <b>${h({ pending: '等待', done: '已创建版本', cancelled: '已取消', conflict: '版本冲突', offline: '原片离线', undone: '已撤销' }[i.state])}</b></p>`).join('')}${b.items.length > 30 ? '<p>另有 ' + (b.items.length - 30) + ' 张，以上计数包含整批。</p>' : ''}</div>`, btn('返回选片', 'close') + (nativeBatchReview ? btn('导出成功候选', 'dag-batch-export', id, {disabled:b.running || !b.items.some(i=>i.state==='done')}) : '') + btn('模拟目标修订冲突', 'dag-batch-conflict') + btn('接回离线项', 'dag-batch-relink') + btn('取消待处理项', 'dag-batch-cancel', id, { disabled: !b.running }) + btn('重试离线／取消项', 'dag-batch-retry', id, { disabled: b.running }) + btn('撤销成功项', 'dag-batch-undo', id, { disabled: b.running }));
  sheet.dataset.dagBatch = id;
};
actions['dag-batch-export'] = id => {
  const b = Studio.data.dagBatches.find(b=>b.id===id);
  if (b?.running) return;
  const items = (b?.items || []).filter(i=>i.state==='done').map(i=>Studio.exportItem(i.id,i.version));
  if (!items.length) return;
  closeSheet(); S.delivery = { source:'工作流批次候选', mode:'render', items };
  sessionStorage.setItem('rawmaster.ui.delivery',JSON.stringify(S.delivery)); go('export');
};
actions['dag-batch-cancel'] = id => { const b = Studio.data.dagBatches.find(b => b.id === id); b.running = false; b.items.filter(i => i.state === 'pending').forEach(i => i.state = 'cancelled'); Studio.save(); actions['dag-batch-results'](id); };
actions['dag-batch-relink'] = () => { const b = Studio.data.dagBatches.find(b => b.id === S.dagBatchID); b.items.filter(i => i.state === 'offline').forEach(i => Studio.asset(i.id).online = true); Studio.save(); actions['dag-batch-results'](b.id); };
actions['dag-batch-retry'] = id => { const b = Studio.data.dagBatches.find(b => b.id === id); b.items.filter(i => i.state === 'cancelled' || i.state === 'offline' && Studio.asset(i.id).online).forEach(i => i.state = 'pending'); b.running = true; dagRunBatch(b); actions['dag-batch-results'](id); };
actions['dag-batch-conflict'] = () => { const b = Studio.data.dagBatches.find(b => b.id === S.dagBatchID), i = b.items.find(i => ['pending', 'done'].includes(i.state)); if (i) { Studio.patchRecipe(i.id, '模拟后续编辑', { contrast: 31 }); notify('已模拟目标后续修订，重试或撤销不能覆盖'); } };
actions['dag-batch-undo'] = id => { const b = Studio.data.dagBatches.find(b => b.id === id); b.items.filter(i => i.state === 'done').forEach(i => { if (JSON.stringify(Studio.edit(i.id).recipe) !== i.after) i.state = 'conflict'; else {
  if (nativeBatchReview) { const v=Studio.edit(i.id).versions.find(v=>v.id===i.version); if (v) v.discarded=true; }
  else Studio.setRecipe(i.id, '撤销批量工作流', i.before);
  i.state = 'undone'; } }); Studio.save(); actions['dag-batch-results'](id); render(); };
actions['dag-review'] = () => dialog('Node DAG 评审场景', '<ol><li>右侧切节点并修改曝光，查看作用域与历史。</li><li>Graph 下串行／并行添加，混合初始为 0%，换输入并撤销。</li><li>Shift 多选成组，进入／退出，保存模板。</li><li>新建蒙版，拖动覆盖，采用／取消返回 Graph。</li><li>编辑连接：制造回路或断开输入，应用禁用，取消恢复。</li><li>模板批量 20／200 张，取消、重试、版本冲突、撤销。</li><li>保存版本、最终导出；中间预览不改变输出。</li></ol><p>原片离线在输入节点模拟；蒙版素材缺失在蒙版面板模拟；渲染失败在输出节点模拟。设置可切换浅／深色。所有像素、模型与批量结果为本地模拟。</p>', btn('关闭', 'close'));

let dagPointer = null, dagSpace = false;
document.addEventListener('pointerdown', event => {
  if (event.button !== 0 && event.button !== 1) return;
  if (event.button === 0 && S.dagMaskSession && event.target.closest('.edit-image')) {
    const image = event.target.closest('.edit-image'); dagPointer = { kind: 'mask', rect: image.getBoundingClientRect(), startX: event.clientX, startY: event.clientY }; image.setPointerCapture(event.pointerId); event.preventDefault(); return;
  }
  const viewport = event.target.closest('[data-dag-viewport]'); if (!viewport || event.target.closest('.dag-monitor')) return;
  if (event.target.closest('.dag-port')) return;
  const node = event.target.closest('[data-dag-card]');
  if (node && event.target.closest('button:not(.dag-node-title)')) return;
  if (!node && event.target.closest('.dag-wire')) return;
  const transform = dagTransform();
  dagPointer = { kind: dagSpace || event.button === 1 || !node && !event.shiftKey ? 'pan' : node ? 'node' : 'marquee', id: node?.dataset.dagCard, startX: event.clientX, startY: event.clientY, origin: { ...transform }, moved: false, viewport, rect: viewport.getBoundingClientRect(), additive: event.shiftKey || event.ctrlKey || event.metaKey };
  if (node) { const n = dagCurrent().nodes.find(n => n.id === dagPointer.id); dagPointer.position = { ...dagPosition(n, dagCurrent().nodes.indexOf(n)) }; }
  viewport.setPointerCapture(event.pointerId); if (dagPointer.kind === 'pan') event.preventDefault();
});
document.addEventListener('pointermove', event => {
  const p = dagPointer; if (!p) return;
  const dx = event.clientX - p.startX, dy = event.clientY - p.startY; if (Math.abs(dx) + Math.abs(dy) > 5) p.moved = true;
  if (p.kind === 'mask') {
    const m = S.dagMaskSession.draft; m.x = Math.max(0, Math.min(100, ((p.startX + dx / 2) - p.rect.left) / p.rect.width * 100)); m.y = Math.max(0, Math.min(100, ((p.startY + dy / 2) - p.rect.top) / p.rect.height * 100)); m.width = Math.max(8, Math.abs(dx) / p.rect.width * 100); m.height = Math.max(8, Math.abs(dy) / p.rect.height * 100);
    const overlay = $('.dag-mask-overlay'); if (overlay) Object.assign(overlay.style, { left: m.x + '%', top: m.y + '%', width: m.width + '%', height: m.height + '%' });
  } else if (p.kind === 'pan') {
    if (!p.moved) return;
    const tr = dagTransform(); tr.x = p.origin.x + dx; tr.y = p.origin.y + dy; tr.framing = 'manual'; dagPaintTransform(tr);
  } else if (p.kind === 'node' && p.moved) {
    const pos = { x: p.position.x + dx / p.origin.scale, y: p.position.y + dy / p.origin.scale }; currentEdit().dagLayout ??= {}; currentEdit().dagLayout[dagView().path.join('/') + ':' + p.id] = pos;
    const card = $('[data-dag-card="' + p.id + '"]'); if (card) Object.assign(card.style, { left: pos.x + 'px', top: pos.y + 'px' });
  } else if (p.kind === 'marquee') {
    const marquee = $('.dag-marquee'); marquee.hidden = false; Object.assign(marquee.style, { left: Math.min(p.startX, event.clientX) - p.rect.left + 'px', top: Math.min(p.startY, event.clientY) - p.rect.top + 'px', width: Math.abs(dx) + 'px', height: Math.abs(dy) + 'px' });
  }
});
document.addEventListener('pointerup', event => {
  const p = dagPointer; if (!p) return; dagPointer = null;
  if (p.kind === 'mask') return;
  if (p.kind === 'marquee') {
    const left = Math.min(p.startX, event.clientX), right = Math.max(p.startX, event.clientX), top = Math.min(p.startY, event.clientY), bottom = Math.max(p.startY, event.clientY);
    const ids = $$('[data-dag-card]').filter(el => { const r = el.getBoundingClientRect(); return r.left < right && r.right > left && r.top < bottom && r.bottom > top; }).map(el => el.dataset.dagCard);
    dagView().selection = p.additive ? [...new Set([...dagView().selection, ...ids])] : ids; if (ids.length === 1) dagView().active = ids[0]; dagRenderFocus('[data-dag-viewport]');
  } else if (p.moved) { Studio.save(); dagRenderFocus('[data-dag-viewport]'); }
  else if (p.kind === 'node') dagSelect(p.id,p.additive);
});
document.addEventListener('pointercancel', () => { if (dagPointer?.kind === 'node') currentEdit().dagLayout[dagView().path.join('/') + ':' + dagPointer.id] = dagPointer.position; dagPointer = null; if (S.page === 'edit' && dagEnabled()) render(); });
document.addEventListener('wheel', event => {
  if (!event.target.closest('[data-dag-viewport]')) return;
  event.preventDefault(); const tr = dagTransform(), rect = $('[data-dag-viewport]').getBoundingClientRect();
  if (event.ctrlKey || event.metaKey) {
    dagZoomAt(tr,Math.max(0.01,Math.min(2.5,tr.scale*Math.exp(-event.deltaY*0.012))),event.clientX-rect.left,event.clientY-rect.top);
  } else { tr.x -= event.deltaX; tr.y -= event.deltaY; tr.framing = 'manual'; dagPaintTransform(tr); }
}, { passive: false });
document.addEventListener('keydown', event => {
  if (S.page !== 'edit' || !dagEnabled() || sheet.open || event.isComposing || event.defaultPrevented) return;
  if (event.target.name === 'dagNumber') {
    if (event.key === 'Escape') { event.target.value = event.target.defaultValue; event.target.removeAttribute('aria-invalid'); event.preventDefault(); }
    else if (event.key === 'Enter') { event.preventDefault(); changes.dagNumber(event.target); }
    return;
  }
  if (event.key === 'Escape') {
    if (S.dagMaskSession) { event.preventDefault(); actions['dag-mask-cancel'](); }
    else if (S.dagWireFrom || S.dagConnectionDraft) { event.preventDefault(); actions['dag-connect-cancel'](); }
    else if (dagView().target) { event.preventDefault(); actions['dag-preview-final'](); }
    else if (dagView().mode === 'graph' && event.target.closest('.dag-floating')) { event.preventDefault(); actions['dag-view']('photo'); }
    return;
  }
  if (event.target.closest('input,textarea,select,[contenteditable=true]') || dagView().mode !== 'graph' || !event.target.closest('[data-dag-viewport],.dag-commandbar')) return;
  const key = event.key.toLowerCase(), cmd = event.metaKey || event.ctrlKey;
  if (key === ' ' && !event.target.closest('button')) { dagSpace = true; event.preventDefault(); }
  else if (cmd && key === 'a') { event.preventDefault(); dagView().selection = dagCurrent().nodes.filter(n => !['source', 'geometry', 'output'].includes(n.kind)).map(n => n.id); dagRenderFocus('[data-dag-viewport]'); }
  else if (cmd && key === 'c') { event.preventDefault(); actions['dag-copy'](); }
  else if (cmd && key === 'v') { event.preventDefault(); actions['dag-paste'](); }
  else if (key === 'delete' || key === 'backspace') { event.preventDefault(); actions['dag-delete'](); }
  else if (key === '0') { event.preventDefault(); actions['dag-fit'](); }
  else if (['+', '=', '-'].includes(key)) { event.preventDefault(); actions['dag-zoom'](key === '-' ? 'out' : 'in'); }
  else if (['arrowleft', 'arrowright', 'arrowup', 'arrowdown'].includes(key)) { event.preventDefault(); const g = dagCurrent(), i = g.nodes.findIndex(n => n.id === dagView().active), n = g.nodes[(i + (key === 'arrowleft' || key === 'arrowup' ? -1 : 1) + g.nodes.length) % g.nodes.length]; dagSelect(n.id); }
});
document.addEventListener('keyup', event => { if (event.key === ' ') dagSpace = false; });
window.addEventListener('blur', () => { dagSpace = false; dagPointer = null; });
for (const name of ['open-versions', 'export']) {
  const original = actions[name];
  actions[name] = (...args) => {
    if (S.dagConnectionDraft || S.dagMaskSession) return notify('先完成或取消当前连接／蒙版草稿');
    if (dagEnabled() && name !== 'open-versions' && dagAllNodes(currentEdit().recipe.dag).some(({ node }) => node.mask?.missing)) return notify('缺少蒙版素材，请重建后再保存或导出。', 'error');
    return original(...args);
  };
}
