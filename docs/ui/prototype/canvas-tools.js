'use strict';

const canvasMaskGroups = [
  ['智能选取', ['主体','背景','天空','人物部位','前景实例']],
  ['画笔与渐变', ['画笔','线性渐变','径向渐变']],
  ['范围与引用', ['颜色范围','亮度范围','饱和度范围','色相范围','深度范围','来自节点']],
];
const canvasMaskIcons = {...maskToolIcons, 天空:'maskBackground', 人物部位:'subject', 颜色范围:'rangeMask', 饱和度范围:'rangeMask', 色相范围:'rangeMask', 深度范围:'rangeMask', 来自节点:'layers'};
const canvasMaskOps = [['add','添加','plus'],['subtract','减去','minus'],['intersect','相交','mix']];
const canvasRemoveModes = [['heal','修复','repair'],['clone','仿制','layers'],['remove','移除','brush'],['inpaint','AI 填充','spark']];
const canvasDefaultMask = () => ({kind:'径向渐变', components:[], x:50, y:50, width:35, height:45, opacity:100, feather:45, enabled:true});
function canvasToolEdit() {
  const edit = Studio.edit(Studio.data.work);
  return S.canvasTool?.legacy ? { ...edit, recipe: S.canvasTool.draft } : edit;
}
function canvasToolPreview(recipe) { return S.canvasTool?.photo === Studio.data.work ? S.canvasTool.draft : recipe; }
function canvasToolMorph(change, focus) {
  const bar = $('.canvas-dock'), before = bar?.getBoundingClientRect(), radius = bar && getComputedStyle(bar).borderRadius;
  change(); render();
  const next = $('.canvas-dock'), after = next?.getBoundingClientRect();
  if (before && after && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const transform=getComputedStyle(next).transform;
    next.animate([
      { transform: `translate(${before.x-after.x}px,${before.y-after.y}px) ${transform==='none'?'':transform}`, width: before.width + 'px', height: before.height + 'px', borderRadius: radius, overflow: 'clip' },
      { transform, width: after.width + 'px', height: after.height + 'px', overflow: 'clip' },
    ], { duration: 240, easing: 'cubic-bezier(.2,.8,.2,1)' });
  }
  $(focus)?.focus({ preventScroll: true });
}
function canvasToolOpen(kind) {
  if (S.tool === 'versions') return notify('查看不可变版本时不能修改照片');
  if (S.canvasTool) return notify('请先完成或取消当前画布工具');
  if (S.dagConnectionDraft) return notify('请先应用或取消连接草稿');
  if (quickPromptVisible()) return notify('请先完成或退出 Prompt');
  if (kind === 'remove' && repairEntryReason()) return notify(repairEntryReason());
  const legacy = !dagEnabled(), before = structuredClone(Studio.edit(Studio.data.work).recipe);
  const node = dagEnabled() ? dagNode() : null;
  const owner = node?.kind === 'grade' ? node : null;
  if (kind === 'mask' && !legacy && !owner) {
    const owners=dagCurrent().nodes.filter(n=>n.kind==='grade');
    if(!owners.length)return notify('请先进入组或创建调色节点，当前范围没有可用的蒙版拥有者');
    S.canvasMaskOwnerPhoto=Studio.data.work;
    return dialog('选择 Mask 拥有者','<p>Mask 属于一个调色节点，不会写入 Mixer 或全图。</p>'+owners.map(n=>btn(n.name,'canvas-mask-owner',n.id)).join(''));
  }
  const session = { kind, photo: Studio.data.work, legacy, before, draft: structuredClone(before), previousTool: S.tool, owner: owner?.id, path: [...dagView().path], past: [], future: [], radius: 20, feather: 45, removeKind: 'heal', removeState: 'ready' };
  if (kind === 'crop') session.cropBox=structuredClone(before.cropBox ?? before.dag?.nodes.find(n=>n.kind==='geometry')?.params.cropBox ?? {x:0,y:0,width:100,height:100});
  if (kind === 'mask' && !legacy) session.mask = structuredClone(owner.mask ?? canvasDefaultMask());
  if (kind === 'remove') {
    session.nativeRepair = photoControls();
    session.removeReviewed = new Set((before.repairs || []).map(mark=>mark.id));
    session.sidebarScroll = ['.edit-photo-panel', '#adjustment-panel', '.edit-body'].map(selector => [selector, $(selector)?.scrollTop ?? 0]);
    session.comparing = S.compare;
  }
  canvasToolMorph(() => {
    S.canvasTool = session; S.cropOpen = kind === 'crop'; S.canvasMenu = ''; S.compare = false;
    S.canvasSelection = null;
    if (legacy && kind === 'mask') S.tool = 'masks';
  }, kind==='mask'&&!legacy ? '[data-act=canvas-tool-fold][data-val=mask-types]' : kind==='remove' ? '.canvas-remove-modes button:not(:disabled)' : '.canvas-tool-dock :is(select,input,button)');
}
function canvasToolPatch(label, fields, refresh = true) {
  const s = S.canvasTool; if (!s || s.photo !== Studio.data.work) return false;
  s.past.push(structuredClone(s.draft)); s.future = [];
  if (s.legacy) Object.assign(s.draft, fields);
  else {
    const root = s.draft.dag;
    if (s.kind === 'crop') Object.assign(root.nodes.find(n => n.kind === 'geometry').params, fields);
    else if (s.kind === 'remove') Object.assign(root.base, fields);
    s.draft = dagProject(root);
  }
  s.label = label; if (refresh) render(); return true;
}
function canvasToolCommitMask() {
  const s = S.canvasTool; if (!s || s.kind !== 'mask' || s.legacy) return;
  const g = s.path.reduce((g, id) => g.nodes.find(n => n.id === id).graph, s.draft.dag);
  g.nodes.find(n => n.id === s.owner).mask = structuredClone(s.mask);
  s.draft = dagProject(s.draft.dag);
}
function canvasToolFinish(cancel = false) {
  const s = S.canvasTool; if (!s) return;
  if (!cancel) {
    const invalid = $('.canvas-tool-dock input:invalid, .repair-inspector input:invalid'); if (invalid) { invalid.focus(); return notify('请修正无效数值后再完成', 'error'); }
    if (s.kind === 'crop' && canvasCropError()) return notify(canvasCropError());
    if (s.kind === 'mask' && !s.legacy && s.mask.low != null && s.mask.high != null && s.mask.low > s.mask.high) return notify('范围下限不能大于上限');
    if (s.kind === 'remove' && s.draft.repairs?.some(r => r.kind === '仿制' && !r.source)) return notify('请为仿制选择取样位置');
    if (s.photo !== Studio.data.work || JSON.stringify(Studio.edit(s.photo).recipe) !== JSON.stringify(s.before)) return notify('照片修订已改变，请取消后重新开始；不会覆盖后来编辑');
    if (s.kind === 'remove' && !Studio.asset(s.photo).online) return notify('原片离线，请接回原片或取消');
    if (s.kind === 'remove' && s.removeState !== 'ready') return notify('请先完成填充预览、重试，或取消');
    if (s.kind === 'mask' && !s.legacy) {
      if (s.mask.missing) return notify('蒙版素材缺失，请先重建或取消', 'error');
    }
    if (!admitModelGeometry(s.draft)) return;
    if (s.draft.dag && dagError(s.draft.dag)) return notify(dagError(s.draft.dag), 'error');
    if (JSON.stringify(s.draft) !== JSON.stringify(s.before)) Studio.setRecipe(s.photo, { crop: '完成 Crop', mask: '完成 Mask', remove: '完成修复' }[s.kind], s.draft);
  }
  const kind = s.kind;
  canvasToolMorph(() => {
    S.canvasTool = null; S.cropOpen = false; S.canvasSelection = null; S.tool = s.previousTool;
    if (kind === 'remove') S.compare = s.comparing;
  }, `.canvas-dock [data-canvas-tool="${kind}"] button`);
  for (const [selector, top] of s.sidebarScroll ?? []) { const panel = $(selector); if (panel) panel.scrollTop = top; }
}
function canvasToolNumber(label, name, value, min = 0, max = 100, step = 1) {
  return `<label class="field"><span>${h(label)}</span><input type="number" name="${name}" value="${value}" min="${min}" max="${max}" step="${step}" aria-label="${h(label)}"></label>`;
}
function canvasToolSlider(label,name,value,min=0,max=100) {
  return `<div class="canvas-slider"><label for="${name}-range">${h(label)}</label><input id="${name}-range" type="range" name="canvasToolRange" data-key="${name}" data-canvas-number="${name}" min="${min}" max="${max}" value="${value}"><input type="number" name="${name}" aria-label="${h(label)}数值" min="${min}" max="${max}" value="${value}" required></div>`;
}
function canvasToolFold(s,key,label,glyph,content) {
  return `<div class="canvas-tool-fold">${btn(label,'canvas-tool-fold',key,{icon:glyph,expanded:s.section===key,controls:'canvas-tool-'+key})}<div id="canvas-tool-${key}" class="canvas-tool-reveal"${s.section===key?'':' hidden'}>${content}</div></div>`;
}
function canvasMaskDock(s,available) {
  const m = s.mask, owner = dagCurrent().nodes.find(n=>n.id===s.owner), glyph = canvasMaskIcons[m.kind] || 'mask';
  const ops = canvasMaskOps.map(([key,label,icon])=>btn(label,'canvas-mask-op',key,{icon,pressed:(m.op || 'add')===key})).join('');
  const palette = canvasMaskGroups.map(([label,types])=>`<div class="canvas-mask-family"><b>${label}</b><div class="canvas-tool-chips">${types.map(type=>btn(type,'canvas-mask-type',type,{icon:canvasMaskIcons[type],pressed:m.kind===type,disabled:type==='来自节点'&&!dagCurrent().edges.some(e=>e.to===s.owner)})).join('')}</div></div>`).join('');
  const typePicker = canvasToolFold(s,'mask-types',m.kind,glyph,palette);
  const hasRange = m.kind.endsWith('范围');
  let typeOptions = '';
  if (hasRange) typeOptions = canvasToolSlider('范围下限','canvasMaskLow',m.low ?? 25)+canvasToolSlider('范围上限','canvasMaskHigh',m.high ?? 75);
  if (m.kind==='人物部位') typeOptions = select('人物部位','canvasMaskPerson',['整个人','面部皮肤','身体皮肤','眉毛','眼白','嘴唇','牙齿','头发','衣物'],m.person || '整个人');
  if (m.kind==='来自节点') {
    const g=dagCurrent(), ancestors=new Set();
    const walk=id=>g.edges.filter(e=>e.to===id).forEach(e=>{if(!ancestors.has(e.from)){ancestors.add(e.from);walk(e.from);}}); walk(s.owner);
    typeOptions=select('引用上游输出','canvasMaskReference',g.nodes.filter(n=>ancestors.has(n.id)).map(n=>[n.id,n.name]),m.reference);
  }
  const components=(m.components || []).map((c,i)=>`<li class="canvas-mask-component"><span>${icon(canvasMaskIcons[c.kind] || 'mask',14)}${h(c.kind)} · ${h(canvasMaskOps.find(([key])=>key===c.op)?.[1] || '添加')}</span>${canvasToolNumber('组件 '+(i+1)+' 强度','canvasComponentOpacity',c.opacity ?? 100).replace('<input ','<input data-index="'+i+'" ')}${btn(c.enabled===false?'启用组件 '+(i+1):'停用组件 '+(i+1),'canvas-component-enable',i,{icon:c.enabled===false?'eyeOff':'eye',only:true,pressed:c.enabled!==false})}${btn('反转组件 '+(i+1),'canvas-component-invert',i,{icon:'invert',only:true,pressed:!!c.invert})}${btn('删除组件 '+(i+1),'canvas-mask-component-delete',i,{icon:'trash',only:true})}</li>`).join('');
  const refine = [['expand','扩展边界',-100],['smooth','平滑',0],['edgeRefine','边缘细化',0],['hairRefine','毛发细化',0],['denoise','覆盖去噪',0]].map(([key,label,min])=>canvasToolSlider(label,'canvasRefine'+key,m.refine?.[key] ?? 0,min)).join('');
  const more = btn('删除全部覆盖','canvas-mask-clear','',{icon:'trash'})+btn('模拟素材缺失','canvas-mask-missing','',{icon:'pulse',disabled:m.missing});
  return `<div class="canvas-tool-scope"><span>${icon('layers',14)}拥有者：<strong>${h(owner?.name)}</strong></span><div class="canvas-tool-chips">${btn(m.enabled===false?'启用覆盖':'停用覆盖','canvas-mask-enable','',{icon:m.enabled===false?'eyeOff':'eye',only:true,pressed:m.enabled!==false})}${btn('显示覆盖','canvas-mask-overlay','',{icon:'overlay',only:true,pressed:s.overlay!==false})}${btn('反转覆盖','canvas-mask-invert','',{icon:'invert',only:true,pressed:!!m.invert})}</div></div>
    <div class="canvas-tool-main"><div class="canvas-tool-chips canvas-mask-typebar">${typePicker}</div><div class="canvas-tool-chips" role="group" aria-label="组合运算">${ops}${btn('添加组件','canvas-mask-component','',{icon:'plus',disabled:!available,title:available?'添加组件':'原片离线，不能添加组件'})}</div></div>
    <div class="canvas-slider-grid">${canvasToolSlider('覆盖强度','canvasMaskOpacity',m.opacity ?? 100)}${canvasToolSlider('羽化','canvasMaskFeather',m.feather ?? 45)}${typeOptions}</div>
    ${components?`<ul class="canvas-tool-list" aria-label="覆盖组件">${components}</ul>`:''}
    ${m.missing?`<div class="canvas-tool-state" role="status"><span>蒙版素材缺失</span>${btn('重建素材','canvas-mask-rebuild','',{icon:'undo',disabled:!available})}</div>`:hasRange && m.low!=null && m.high!=null && m.low>m.high?'<p role="status">范围下限不能大于上限。</p>':'<p class="canvas-tool-tip">在照片上拖出覆盖 · 选区为本地示意</p>'}
    <div class="canvas-tool-options">${canvasToolFold(s,'mask-refine','细化','sliders',`<div class="canvas-slider-grid">${refine}</div>`)}${canvasToolFold(s,'mask-more','更多','menu',`<div class="canvas-tool-chips">${more}</div>`)}</div>`;
}
function repairEntryReason() {
  if (S.tool === 'versions') return '请返回当前编辑';
  if (!Studio.asset(Studio.data.work).online) return '原片离线，请先接回原片';
  if (S.dagConnectionDraft) return '请先应用或取消连接草稿';
  if (S.canvasSelection) return '请先完成或取消当前取样或选区';
  return '';
}
function repairControls(s,available,strict) {
  const repairs=s.draft.repairs || [], clonePending=repairs.some(r=>r.kind==='仿制'&&!r.source), enabled=available&&!strict;
  const message = strict ? '严格纪实：不能新增修饰或生成填充。' : !available ? '原片离线，不能标记或生成填充。' :
    clonePending ? '请在照片上再点一次，选择仿制取样位置。' :
    s.removeState==='failed' ? '示例填充失败，可重试或移除标记。' :
    s.removeState==='pending' ? '标记已就绪，生成后查看填充预览。' :
    s.nativeRepair && s.removeKind==='clone' && !s.donor ? '按住 Option 点击照片，选择仿制来源。' :
    '在照片上点击或涂抹。';
  const options = s.nativeRepair ? [canvasRemoveModes[2], ...canvasRemoveModes.slice(0,2), ['redEye','红眼','eye']] : canvasRemoveModes;
  const modes=options.map(([key,label,icon])=>btn(label,'canvas-remove-kind',key,{icon,pressed:s.removeKind===key,disabled:!enabled})).join('');
  const repairList=repairs.map((r,i)=>`<li><span>${icon(canvasRemoveModes.find(([,label])=>label===r.kind)?.[2] || 'repair',14)}${h(r.kind)} ${i+1}${r.kind==='仿制'&&!r.source?' · 待取样':''}</span>${btn('移除标记 '+(i+1),'canvas-remove-delete',i,{icon:'trash',only:true})}</li>`).join('');
  const more=btn('在中心标记','canvas-remove-center','',{icon:'pin',disabled:!enabled})+(s.removeState==='pending'?btn('模拟失败','canvas-remove-fail','',{icon:'pulse',disabled:!enabled}):'');
  return `<div class="button-group button-group--stretch canvas-remove-modes" role="group" aria-label="修复方式" data-select-on-arrow>${modes}</div><div class="canvas-slider-grid">${canvasToolSlider('画笔大小','canvasRadius',s.radius,2)}${s.nativeRepair ? '' : canvasToolSlider('羽化','canvasFeather',s.feather)}</div>
    <div class="canvas-tool-state" role="status"><span>${h(message)}</span>${s.removeState!=='ready'&&!clonePending?btn(s.removeState==='failed'?'重试填充':'生成填充预览','canvas-remove-preview','',{icon:s.removeState==='failed'?'undo':'spark',disabled:!enabled}):''}</div>
    ${repairList?`<ul class="canvas-tool-list canvas-remove-list" aria-label="修饰标记">${repairList}</ul>`:''}
    <div class="canvas-tool-options">${canvasToolFold(s,'remove-more','更多','menu',`<div class="canvas-tool-chips">${more}</div>${['remove','inpaint'].includes(s.removeKind)?'<p>填充仅作本地示意，不调用模型。</p>':''}`)}</div>`;
}
function canvasToolFooter(s, blocked, compact) {
  return `<div class="canvas-tool-footer">${btn('撤销草案','edit-step','undo',{icon:'undo',only:compact,disabled:!s.past.length})}${btn('重做草案','edit-step','redo',{icon:'undo',only:compact,cls:'redo',disabled:!s.future.length})}${btn('取消', 'canvas-tool-cancel')}${btn('完成', 'canvas-tool-done', '', {cls:'primary', disabled:blocked})}</div>`;
}
function repairInspector(s) {
  const available = Studio.asset(s.photo).online, strict = !!Studio.edit(s.photo).conversation?.strict;
  const blocked = !available || s.removeState !== 'ready' || !!s.draft.repairs?.some(r => r.kind === '仿制' && !r.source);
  return `<aside class="edit-inspector repair-inspector" aria-label="修复">
    <div class="edit-inspector-head"><h2>修复</h2><small>${h(Studio.displayName(s.photo))} · 未提交草案</small></div>
    <div class="canvas-tool-body">${repairControls(s,available,strict)}</div>
    ${canvasToolFooter(s, blocked, true)}</aside>`;
}
actions['canvas-tool-fold'] = key => { const s=S.canvasTool; if(!s)return; s.section=s.section===key?null:key; render(); };
function canvasToolDock() {
  const s = S.canvasTool, available = Studio.asset(Studio.data.work).online;
  let body;
  if (s.kind === 'crop') body = `<div class="canvas-tool-grid">${select('画面比例', 'crop', ['原始', '1:1', '4:5', '3:2', '16:9'], s.draft.crop)}${canvasToolNumber('拉直角度', 'canvasAngle', s.draft.angle || 0, -45, 45, 0.1)}${btn('旋转 90°', 'canvas-turn')}${btn('水平翻转', 'canvas-flip', 'horizontal')}${btn('垂直翻转', 'canvas-flip', 'vertical')}${btn('复位裁切', 'canvas-crop-reset')}${[['x','裁切左边'],['y','裁切上边'],['width','裁切宽度'],['height','裁切高度']].map(([axis,label])=>canvasToolNumber(label,'canvasCrop'+axis,s.cropBox[axis],axis==='x'||axis==='y'?0:1,100,.1)).join('')}</div><p>拖出裁切范围，或输入百分比；范围只作交互示意。照片几何阶段 · 比例、方向和裁切框作用于整张照片，不写当前调色节点。</p>`;
  else if (s.kind === 'mask' && s.legacy) body = maskPanel(s.draft);
  else body = canvasMaskDock(s,available);
  const blocked = s.kind === 'crop' && !!canvasCropError() || s.kind === 'mask' && !s.legacy && (s.mask.missing || s.mask.low != null && s.mask.high != null && s.mask.low > s.mask.high);
  const compact = s.kind==='mask'&&!s.legacy;
  return `<section class="canvas-dock canvas-tool-dock${compact?' canvas-compact-tool':''}" aria-label="${s.kind} 详细工具" data-canvas-expanded="${s.kind}"><div class="canvas-tool-head"><strong>${icon(s.kind === 'crop' ? 'crop' : 'mask')}${s.kind === 'crop' ? 'Crop · 裁切' : 'Mask · 覆盖'}</strong><small>${h(Studio.displayName(s.photo))} · 未提交草案</small></div><div class="canvas-tool-body">${body}${s.kind==='crop'&&canvasCropError()?'<p role="status">'+h(canvasCropError())+'</p>':''}${!available ? '<p role="status">原片离线：允许查看草案，覆盖构建不可用。</p>' : ''}</div>${canvasToolFooter(s, !!blocked, compact)}</section>`;
}
function canvasCropError(){const box=S.canvasTool?.cropBox;return box&&(box.x+box.width>100||box.y+box.height>100)?'裁切范围不能超出照片；请调整位置或宽高':'';}
for(const axis of ['x','y','width','height'])changes['canvasCrop'+axis]=el=>{if(el.validity.valid){S.canvasTool.cropBox[axis]=Number(el.value);canvasToolPatch('裁切范围',{cropBox:structuredClone(S.canvasTool.cropBox)});}};
actions['canvas-crop-reset']=()=>{S.canvasTool.cropBox={x:0,y:0,width:100,height:100};canvasToolPatch('复位裁切',{crop:'原始',angle:0,quarterTurns:0,flipH:false,flipV:false,cropBox:structuredClone(S.canvasTool.cropBox)});};
actions['canvas-mask-owner']=id=>{closeSheet();if(S.canvasMaskOwnerPhoto!==Studio.data.work)return notify('照片已改变，请重新选择蒙版拥有者');dagSelect(id);canvasToolOpen('mask');};
actions['canvas-tool'] = canvasToolOpen;
actions['canvas-tool-done'] = () => canvasToolFinish();
actions['canvas-tool-cancel'] = () => canvasToolFinish(true);
changes.canvasAngle = el => { if (el.validity.valid) canvasToolPatch('拉直', { angle: Number(el.value) }); };
actions['canvas-turn'] = () => canvasToolPatch('旋转', { quarterTurns: ((S.canvasTool.draft.quarterTurns || 0) + 1) % 4 });
actions['canvas-flip'] = direction => { const key = direction === 'horizontal' ? 'flipH' : 'flipV'; canvasToolPatch('翻转', { [key]: !S.canvasTool.draft[key] }); };
function canvasMaskPatch(change){const s=S.canvasTool;if(!s||s.kind!=='mask'||s.legacy||s.photo!==Studio.data.work)return;s.past.push(structuredClone(s.draft));s.future=[];change(s.mask);canvasToolCommitMask();render();}
actions['canvas-mask-type']=type=>{
  const s=S.canvasTool;if(s?.kind!=='mask'||s.legacy)return;
  s.section=null;
  if (s.mask.kind===type) render();
  else canvasMaskPatch(mask=>{mask.kind=type;if(type==='来自节点')mask.reference=dagCurrent().edges.find(e=>e.to===s.owner)?.from;});
  $('[data-act=canvas-tool-fold][data-val=mask-types]')?.focus({preventScroll:true});
};
actions['canvas-mask-op']=op=>canvasMaskPatch(mask=>mask.op=op);
inputs.canvasToolRange = el => { const number=$(`[name="${el.dataset.key}"]`); if(number)number.value=el.value; };
changes.canvasToolRange = el => { const number=$(`[name="${el.dataset.key}"]`); if(number){number.value=el.value;changes[number.name]?.(number);} };
for(const name of ['canvasMaskOpacity','canvasMaskFeather','canvasMaskLow','canvasMaskHigh','canvasRefineexpand','canvasRefinesmooth','canvasRefineedgeRefine','canvasRefinehairRefine','canvasRefinedenoise','canvasRadius','canvasFeather'])inputs[name]=el=>{const range=$(`[data-canvas-number="${name}"]`);if(range&&el.validity.valid)range.value=el.value;};
for(const [name,key] of [['canvasMaskOpacity','opacity'],['canvasMaskFeather','feather'],['canvasMaskLow','low'],['canvasMaskHigh','high']])changes[name]=el=>{if(el.validity.valid)canvasMaskPatch(mask=>mask[key]=Number(el.value));};
for(const key of ['expand','smooth','edgeRefine','hairRefine','denoise'])changes['canvasRefine'+key]=el=>{if(el.validity.valid)canvasMaskPatch(mask=>(mask.refine ??= {})[key]=Number(el.value));};
changes.canvasMaskReference=el=>canvasMaskPatch(mask=>mask.reference=el.value);
changes.canvasMaskPerson=el=>canvasMaskPatch(mask=>mask.person=el.value);
actions['canvas-mask-enable']=()=>canvasMaskPatch(mask=>mask.enabled=mask.enabled===false);
actions['canvas-component-enable']=index=>canvasMaskPatch(mask=>{const c=mask.components[Number(index)];c.enabled=c.enabled===false;});
changes.canvasComponentOpacity=el=>{if(el.validity.valid)canvasMaskPatch(mask=>mask.components[Number(el.dataset.index)].opacity=Number(el.value));};
actions['canvas-component-invert']=index=>canvasMaskPatch(mask=>{const component=mask.components[Number(index)];component.invert=!component.invert;});
actions['canvas-mask-component']=()=>canvasMaskPatch(mask=>(mask.components ??= []).push({id:Studio.uid(),kind:mask.kind,op:mask.op || 'add',reference:mask.reference,person:mask.person,enabled:true,opacity:100,invert:false}));
actions['canvas-mask-component-delete']=index=>canvasMaskPatch(mask=>mask.components.splice(Number(index),1));
actions['canvas-mask-invert']=()=>canvasMaskPatch(mask=>mask.invert=!mask.invert);
actions['canvas-mask-overlay']=()=>{S.canvasTool.overlay=S.canvasTool.overlay===false;render();};
actions['canvas-mask-clear']=()=>canvasMaskPatch(mask=>Object.assign(mask,{components:[],enabled:false}));
actions['canvas-mask-missing']=()=>canvasMaskPatch(mask=>mask.missing=true);
actions['canvas-mask-rebuild']=()=>canvasMaskPatch(mask=>mask.missing=false);
function canvasRemoveAvailable(s) { return s?.kind==='remove' && Studio.asset(s.photo).online && !Studio.edit(s.photo).conversation?.strict; }
function canvasRemovePending(s) { return s.nativeRepair ? [] : (s.draft.repairs || []).filter(r=>['移除','AI 填充'].includes(r.kind)&&!s.removeReviewed.has(r.id)); }
function canvasRemoveStatus(s) { s.removeState = !canvasRemovePending(s).length ? 'ready' : s.removeState==='failed' ? 'failed' : 'pending'; }
actions['canvas-remove-kind'] = kind => { if(!canvasRemoveAvailable(S.canvasTool))return; S.canvasTool.removeKind=kind; render(); };
changes.canvasRadius = el => { if (el.validity.valid) S.canvasTool.radius = Number(el.value); };
changes.canvasFeather = el => { if (el.validity.valid) S.canvasTool.feather = Number(el.value); };
function canvasRemoveMark(x, y, option = false) {
  const s = S.canvasTool; if (!s || s.kind !== 'remove' || !Studio.asset(s.photo).online) return;
  if (Studio.edit(s.photo).conversation?.strict) return notify('严格纪实禁止内容替换，请保留原片');
  if (s.nativeRepair && option && s.removeKind !== 'redEye') {
    s.donor = {x,y}; render(); return;
  }
  if (s.nativeRepair && s.removeKind === 'clone' && !s.donor) return notify('请按住 Option 点击照片，选择仿制来源');
  const repairs = structuredClone(s.draft.repairs || []), last = repairs.at(-1);
  if (last?.kind === '仿制' && !last.source) last.source = {x,y};
  else repairs.push({id:Studio.uid(),kind:s.removeKind==='redEye' ? '红眼' : canvasRemoveModes.find(([key])=>key===s.removeKind)[1],
    x,y,radius:s.radius,feather:s.feather,source:s.removeKind==='redEye' ? undefined : s.donor});
  s.donor = null;
  canvasToolPatch('标记修饰', {repairs}, false);
  canvasRemoveStatus(s); render();
}
actions['canvas-remove-center'] = () => canvasRemoveMark(50,50);
actions['canvas-remove-delete'] = index => {
  const s=S.canvasTool,repairs=structuredClone(s.draft.repairs); repairs.splice(Number(index),1);
  canvasToolPatch('删除修饰',{repairs},false); canvasRemoveStatus(s); render();
};
actions['canvas-remove-preview'] = () => {
  const s=S.canvasTool;if(!canvasRemoveAvailable(s)||!canvasRemovePending(s).length||s.draft.repairs.some(r=>r.kind==='仿制'&&!r.source))return;
  canvasRemovePending(s).forEach(r=>s.removeReviewed.add(r.id)); canvasRemoveStatus(s); s.section=null;
  render(); $('[data-act=canvas-tool-done]')?.focus({preventScroll:true}); notify('示例填充就绪 · 未调用模型');
};
actions['canvas-remove-fail'] = () => {
  const s=S.canvasTool;if(!canvasRemoveAvailable(s)||!canvasRemovePending(s).length)return;
  s.removeState='failed';s.section=null;render();$('[data-act=canvas-remove-preview]')?.focus({preventScroll:true});
};
let canvasToolPointer;
document.addEventListener('pointerdown', event => {
  const s = S.canvasTool, image = event.target.closest('.edit-image');
  if (!s || s.kind==='remove' || s.legacy&&s.kind!=='crop' || !image || event.button !== 0 || !Studio.asset(s.photo).online) return;
  canvasToolPointer = {session:s,image,rect:image.getBoundingClientRect(),x:event.clientX,y:event.clientY,before:structuredClone(s.draft),mask:structuredClone(s.mask),box:structuredClone(s.cropBox),moved:false};
  image.setPointerCapture(event.pointerId);event.preventDefault();
});
document.addEventListener('pointermove',event=>{
  const p=canvasToolPointer,s=S.canvasTool;if(!p||p.session!==s||s.photo!==Studio.data.work)return;
  const point=(x,y)=>({x:Math.max(0,Math.min(100,(x-p.rect.left)*100/p.rect.width)),y:Math.max(0,Math.min(100,(y-p.rect.top)*100/p.rect.height))}),a=point(p.x,p.y),b=point(event.clientX,event.clientY);
  p.moved ||= Math.hypot(event.clientX-p.x,event.clientY-p.y)>4;
  if(!p.moved)return;
  const box={x:Math.min(a.x,b.x),y:Math.min(a.y,b.y),width:Math.max(1,Math.abs(a.x-b.x)),height:Math.max(1,Math.abs(a.y-b.y))};
  if(s.kind==='crop'){for(const key of Object.keys(box))box[key]=Math.round(box[key]*10)/10;box.x=Math.round(Math.min(box.x,100-box.width)*10)/10;box.y=Math.round(Math.min(box.y,100-box.height)*10)/10;s.cropBox=box;}else Object.assign(s.mask,{x:box.x+box.width/2,y:box.y+box.height/2,width:box.width,height:box.height});
  const value=s.kind==='crop'?s.cropBox:s.mask,overlay=$(s.kind==='crop'?'.canvas-crop-box':'.dag-mask-overlay');
  if(overlay)Object.assign(overlay.style,{left:value.x+'%',top:value.y+'%',width:value.width+'%',height:value.height+'%'});
});
document.addEventListener('pointerup',()=>{
  const p=canvasToolPointer;canvasToolPointer=null;const s=S.canvasTool;if(!p||p.session!==s||!p.moved)return;
  if(s.kind==='crop')canvasToolPatch('裁切范围',{cropBox:structuredClone(s.cropBox)});
  else{s.past.push(p.before);s.future=[];canvasToolCommitMask();render();}
});
document.addEventListener('pointercancel',()=>{const p=canvasToolPointer;canvasToolPointer=null;if(p?.session===S.canvasTool){S.canvasTool.mask=p.mask;S.canvasTool.cropBox=p.box;render();}});
document.addEventListener('keydown', event => {
  if (!S.canvasTool || sheet.open || event.defaultPrevented || event.isComposing) return;
  if (event.key === 'Escape') { if (S.canvasTool.legacy && S.canvasSelection) return; event.preventDefault(); canvasToolFinish(true); }
  if (S.canvasTool?.kind === 'remove' && event.key === 'Enter' && !event.target.closest('button,input,select,textarea,summary')) {
    event.preventDefault(); canvasToolFinish();
  }
}, true);
actions['canvas-crop'] = () => S.canvasTool?.kind === 'crop' ? canvasToolFinish() : canvasToolOpen('crop');
actions['canvas-repair'] = () => S.canvasTool?.kind === 'remove' ? canvasToolFinish() : canvasToolOpen('remove');
const canvasPreviousTool = actions['edit-tool'];
actions['edit-tool'] = (key,event,el) => {
  if (key === 'masks' || key === 'repair') return canvasToolOpen(key === 'masks' ? 'mask' : 'remove');
  if (S.canvasTool) return notify('请先完成或取消画布工具');
  return canvasPreviousTool(key,event,el);
};
const canvasPreviousStep = actions['edit-step'];
actions['edit-step'] = mode => {
  const s = S.canvasTool; if (!s) return canvasPreviousStep(mode);
  const source = mode === 'redo' ? s.future : s.past, target = mode === 'redo' ? s.past : s.future;
  if (!source.length) return; target.push(structuredClone(s.draft)); s.draft = source.pop();
  if(s.kind==='mask'&&!s.legacy){const graph=s.path.reduce((g,id)=>g.nodes.find(n=>n.id===id).graph,s.draft.dag);s.mask=structuredClone(graph.nodes.find(n=>n.id===s.owner).mask ?? canvasDefaultMask());}
  if(s.kind==='crop')s.cropBox=structuredClone(s.draft.cropBox ?? {x:0,y:0,width:100,height:100});
  if(s.kind==='remove')canvasRemoveStatus(s);
  render();
};
for (const name of ['export','open-versions','snapshot','restore-snap','reset-recipe','confirm-reset','apply-preset','adaptive-preset','film-stock','remove-film']) {
  const command = actions[name]; actions[name] = (...args) => S.canvasTool ? notify('请先完成或取消画布草案') : command(...args);
}
const canvasPreviousPoint = actions['canvas-point'];
actions['canvas-point'] = (value,event,el) => {
  if (S.canvasTool?.kind === 'remove') {
    const box = el.getBoundingClientRect();
    return canvasRemoveMark(Math.round((event.clientX-box.left)*100/box.width), Math.round((event.clientY-box.top)*100/box.height), event.altKey);
  }
  return canvasPreviousPoint(value,event,el);
};
actions['dag-mask-start'] = kind => { closeSheet(); canvasToolOpen('mask'); if (S.canvasTool?.mask) actions['canvas-mask-type'](kind); };
actions['dag-mask-edit'] = () => canvasToolOpen('mask');
actions['dag-mask-accept'] = () => canvasToolFinish();
actions['dag-mask-cancel'] = () => canvasToolFinish(true);
actions['dag-mask-select'] = id => { dagSelect(id); canvasToolOpen('mask'); };
actions['dag-crop-start'] = () => canvasToolOpen('crop');
actions['dag-crop-finish'] = () => canvasToolFinish();
actions['dag-crop-cancel'] = () => canvasToolFinish(true);
