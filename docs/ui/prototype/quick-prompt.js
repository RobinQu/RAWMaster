'use strict';

const promptModels = {
  flux: 'FLUX.3 Image Klein · 本机',
  seedream: 'Seedream 5.5 · 云端',
};
const promptTemplates = {
  remove: ['移除干扰', '移除［干扰物］，按相邻光线与纹理自然补齐，保留周围对象的边缘。'],
  background: ['替换背景', '将背景改成［新背景］，保留主体的形状、发丝边缘和原有构图。'],
  light: ['调整光向', '使用来自［方向］的柔光，保持人物五官、表情和服装细节。'],
  color: ['统一色调', '将整体色彩统一为［色调］，保留构图、高光层次和原有明暗关系。'],
};
const promptPhrases = {
  face: '保留五官与发丝。',
  signage: '保留标识和原有文字。',
  structure: '保持主要结构与透视。',
  shadow: '延续原图阴影方向。',
  water: '保留水面倒影。',
  seam: '让补区纹理与邻域平顺衔接。',
};
const quickDrafts = new Map();
const promptLimit = 2000;
let quickApproval, quickPointer;

function quickPromptVisible() {
  return S.page === 'edit' && S.tool !== 'versions' && S.quickOpen;
}
function quickBase(id) {
  const e = Studio.edit(id);
  const adopted = e.versions.find((v) => v.id === e.adopted && v.quickPrompt);
  return adopted?.id ?? e.base ?? e.adopted;
}
function quickLibrary() {
  return Studio.catalog().packageName || '本机资料库';
}
function quickSubject(id = Studio.data.work) {
  return JSON.stringify([quickLibrary(), id]);
}
function quickBasis(id) {
  return JSON.stringify([quickSubject(id), quickBase(id), Studio.edit(id).recipe, Studio.asset(id).online]);
}
function quickDraft(id = Studio.data.work) {
  const basis = quickBasis(id);
  const key = quickSubject(id);
  if (!quickDrafts.has(key))
    quickDrafts.set(key, { basis, text: '', model: 'flux', scope: null, drawing: false, before: false });
  const draft = quickDrafts.get(key);
  if (draft.basis !== basis) {
    if (draft.scope) draft.notice = '当前编辑已变化，已清除原选区。';
    Object.assign(draft, { basis, scope: null, drawing: false, before: false });
  }
  return draft;
}
function quickTask(id = Studio.data.work) {
  return Studio.data.jobs.find((j) => j.quickPrompt?.library === quickLibrary() && j.photo === id && !j.quickPrompt.reviewed);
}
function quickAdoptionIssue(job, id = Studio.data.work) {
  if (Studio.edit(id).conversation?.strict) return '严格纪实作品无法采用生成候选。';
  if (!job || job.photo !== id || job.quickPrompt.library !== quickLibrary() || job.quickPrompt.basis !== quickBasis(id))
    return '当前编辑与提交时不同。请核对原候选或重新生成。';
  return '';
}
function quickJobForVersion(id) {
  return id && Studio.data.jobs.find((job) => job.quickPrompt && job.result === id);
}
function quickStatus(draft, job = quickTask()) {
  const id = Studio.data.work;
  const strict = !!Studio.edit(id).conversation?.strict;
  if (strict) return { text: '此照片使用严格纪实保护。请用原生调整编辑。', blocked: true };
  if (job?.state === 'unknown')
    return { text: '结果待核对。云端是否完成及计费尚未确认。', blocked: true };
  const e = Studio.edit(id);
  if (!Studio.asset(id).online && !e.versions.some((v) => v.id === quickBase(id) && v.quickPrompt))
    return { text: '原片离线。请接回原片后再生成。', blocked: true };
  const local = draft.model === 'flux';
  if (!local && !navigator.onLine) return { text: '当前离线。可选择已就绪的本机模型。', blocked: true };
  const p = Studio.data.prefs;
  if (local && p.runtime !== '就绪') return { text: '本机模型待准备。', blocked: true, setup: 'runtime' };
  if (!local && (p.cloud !== '已配置' || p.cloudName !== 'Seedream / 中国方舟'))
    return { text: '请先配置北京方舟服务。', blocked: true, setup: 'cloud' };
  if (draft.drawing) return { text: draft.notice || '在照片上拖出要修改的范围。', blocked: true };
  if (!draft.text.trim()) return { text: draft.notice || '输入想修改的内容。', blocked: true };
  if (/［[^］]*］/.test(draft.text)) return { text: '请填写提示词中的方括号内容。', blocked: true };
  if (job && ['failed', 'cancelled'].includes(job.state))
    return { text: job.state === 'failed' ? '这次生成失败。可编辑 Prompt 或重新生成。' : '已停止。可继续修改 Prompt。' };
  return { text: draft.notice || (local ? '只在本机处理。' : '提交前核对实际发送的图片。') };
}
function quickScopeTitle(scope) {
  return scope ? scope.name ? '蒙版 · ' + scope.name : '矩形选区' : '整张照片';
}
function quickEntry() {
  const job = quickTask();
  const note = job?.state === 'done' ? '，有待审候选' : job?.state === 'running' ? '，生成中' : '';
  const label = S.cropOpen ? '请先完成裁切与拉直' : '快速 Prompt' + note;
  return `<button type="button" class="prompt-entry" data-act="quick-open" aria-label="${label}"
    title="${label}" ${S.cropOpen || S.tool === 'versions' ? 'disabled' : ''} aria-expanded="false">
    ${icon('spark', 16)}<span class="prompt-entry-label">Prompt</span>${note ? '<i></i>' : ''}</button>`;
}
function promptDock() {
  const d = quickDraft(), job = quickTask();
  const ready = job?.state === 'done' && !!job.result;
  const title = `<header class="quick-head" tabindex="-1"><strong>${icon('spark', 17)} 快速 Prompt</strong>
    <span class="quick-scope" id="quick-scope">${h(quickScopeTitle(ready ? job.quickPrompt.scope : d.scope))}</span>
    ${btn('收起快速 Prompt', 'quick-close', '', { icon: 'close', only: true, cls: 'quick-close' })}</header>`;
  const more = (menu, label, content) => `<details class="quick-menu" data-menu="${menu}"><summary>${label}</summary><div>${content}</div></details>`;
  let body;
  if (job?.state === 'running') {
    body = `<div class="quick-result"><p role="status"><span class="quick-spinner"></span>${job.quickPrompt.reconciling ? '正在核对原任务' : '正在生成候选'} · ${promptModels[job.quickPrompt.model]}</p>
      <div class="quick-buttons">${btn('停止', 'quick-job', 'cancel')}${btn('制作任务', 'goto', 'jobs')}</div></div>`;
  } else if (job?.state === 'unknown') {
    body = `<div class="quick-result"><p role="status">结果待核对。云端是否完成及计费尚未确认。</p>
      <div class="quick-buttons">${btn('核对原任务结果', 'quick-job', 'reconcile')}${btn('制作任务', 'goto', 'jobs')}</div></div>`;
  } else if (ready) {
    const stale = job.quickPrompt.basis !== quickBasis(Studio.data.work);
    const issue = quickAdoptionIssue(job);
    const version = Studio.edit(Studio.data.work).versions.find((v) => v.id === job.result);
    const dimensions = version ? ' · ' + version.w + ' × ' + version.h : '';
    body = `<div class="quick-result"><p role="status">${h(issue || ('候选已就绪' + dimensions + '。请核对效果和边缘。'))}</p>
    <div class="quick-buttons">${btn('生成前', 'quick-compare', 'before', { pressed: d.before, disabled: stale })}
    ${btn('候选', 'quick-compare', 'after', { pressed: !d.before, disabled: stale })}${btn('100%', 'quick-inspect', '', { disabled: stale, pressed: !!S.quickInspect })}
    ${stale ? btn('在作品版本查看', 'quick-inspect-version') : ''}${btn('放弃候选', 'quick-discard')}
    ${btn('应用到照片', 'quick-apply', '', { cls: 'quick-primary', disabled: !!issue })}</div></div>`;
  } else {
    const status = quickStatus(d, job);
    const ranges = more('scope', '范围工具', [
      btn('输入坐标…', 'quick-coordinates'), btn('使用现有蒙版…', 'quick-mask'),
      btn('使用整张照片', 'quick-whole'),
    ].join(''));
    const phraseGroup = (keys) => keys.map((id) => btn(promptPhrases[id], 'quick-template', id)).join('');
    const helpers = more('phrases', '更多短句', `<b>保护对象</b>${phraseGroup(['face', 'signage', 'structure'])}<b>光色与衔接</b>${phraseGroup(['shadow', 'water', 'seam'])}`);
    body = `<textarea aria-label="编辑提示词" aria-describedby="quick-scope quick-status" name="quickPrompt" maxlength="${promptLimit}" rows="2"
      placeholder="描述想改变的内容，例如：移除岸边路牌，保留倒影">${h(d.text)}</textarea>
      <div class="quick-templates"><div class="quick-chips" role="group" aria-label="快捷 Prompt 模板">${Object.entries(promptTemplates)
        .map(([id, [label]]) => btn(label, 'quick-template', id)).join('')}</div>${helpers}</div>
      <div class="quick-footer">
        <div class="quick-buttons">${btn(d.drawing ? '正在圈选' : '圈选', 'quick-draw', '', { icon: 'crop', pressed: d.drawing })}
          ${ranges}</div>
        <div class="quick-model-action">
          <select name="quickModel" aria-label="选择生成模型">${Object.entries(promptModels)
            .map(([id, label]) => `<option value="${id}" ${d.model === id ? 'selected' : ''}>${label}</option>`).join('')}</select>
          ${btn(d.model === 'flux' ? '生成候选' : '核对并生成…', 'quick-submit', '', { cls: 'quick-primary', disabled: status.blocked })}
        </div>
      </div>
      <div class="quick-feedback"><span id="quick-status" role="status">${h(status.text)}</span>
        ${status.setup ? btn(status.setup === 'runtime' ? '准备本机模型' : '配置方舟', 'quick-setup', status.setup, { cls: 'quick-link' }) : ''}</div>`;
  }
  return `<section id="quick-prompt" class="canvas-dock quick-dock" aria-label="快速 Prompt">
    <div class="quick-inner">${title}${body}</div></section>`;
}
function quickToggle(open) {
  const bar = $('.canvas-dock');
  const bounds = bar?.getBoundingClientRect(), radius = bar && getComputedStyle(bar).borderRadius;
  if (!open) {
    quickExitCanvas();
    S.quickResume = null;
  }
  S.quickOpen = open;
  render();
  const next = $('.canvas-dock'), end = next?.getBoundingClientRect();
  if (bounds && end && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    next.classList.add('quick-morphing');
    const transition = next.animate([
      { width: bounds.width + 'px', height: bounds.height + 'px', borderRadius: radius },
      { width: end.width + 'px', height: end.height + 'px', borderRadius: getComputedStyle(next).borderRadius },
    ], { duration: 250, easing: 'cubic-bezier(.22,.75,.22,1)' });
    transition.onfinish = () => next.classList.remove('quick-morphing');
  }
  if (!open) quickRestorePan();
  (open ? $('[name=quickPrompt]') || $('.quick-head') : $('[data-act=quick-open]'))?.focus({ preventScroll: true });
}
function quickExitCanvas() {
  if (!S.quickOpen) return;
  quickDraft().drawing = false;
  quickPointer = null;
  quickApproval = null;
  if (S.quickView) S.editZoom = S.quickView.zoom;
  S.quickInspect = false;
  S.quickOpen = false;
}
function quickRestorePan() {
  const fit = $('.canvas-fit');
  if (fit && S.quickView && Studio.data.work === S.quickView.photo) {
    [fit.scrollLeft, fit.scrollTop] = S.quickView.pan;
  }
  S.quickView = null;
}
function quickBegin() {
  if (S.cropOpen || S.tool === 'versions') return;
  const fit = $('.canvas-fit');
  S.canvasMenu = '';
  S.quickView = { photo: Studio.data.work, zoom: S.editZoom, pan: [fit.scrollLeft, fit.scrollTop] };
  quickToggle(true);
}
function quickEscape() {
  if (!quickPromptVisible()) return false;
  const menu = $('#quick-prompt details[open]');
  if (menu) {
    menu.open = false;
    menu.querySelector('summary').focus({ preventScroll: true });
  } else if (quickDraft().drawing) {
    quickPointer = null;
    quickDraft().drawing = false;
    render();
    $('[data-act=quick-draw]')?.focus({ preventScroll: true });
  } else quickToggle(false);
  return true;
}
actions['quick-open'] = quickBegin;
actions['quick-close'] = () => quickToggle(false);
actions['quick-draw'] = () => {
  const d = quickDraft();
  d.drawing = !d.drawing;
  d.notice = '';
  render();
};
actions['quick-whole'] = () => {
  Object.assign(quickDraft(), { drawing: false, scope: null, notice: '' });
  render();
  $('[data-act=quick-draw]')?.focus({ preventScroll: true });
};
function quickUpdateField(el) {
  const d = quickDraft(), status = quickStatus(d);
  $('#quick-status').textContent = status.text;
  $('[data-act=quick-submit]').disabled = !!status.blocked;
  d.selectionStart = el.selectionStart;
  d.selectionEnd = el.selectionEnd;
}
inputs.quickPrompt = (el) => {
  quickDraft().text = el.value;
  quickUpdateField(el);
};
changes.quickModel = (el) => {
  quickDraft().model = el.value;
  render();
};
actions['quick-template'] = (key) => {
  const d = quickDraft(), field = $('[name=quickPrompt]');
  const phrase = promptTemplates[key]?.[1] ?? promptPhrases[key];
  if (!field || !phrase) return;
  const start = d.selectionStart ?? field.selectionStart, end = d.selectionEnd ?? field.selectionEnd;
  const insert = (start > 0 && !/\s/.test(d.text[start - 1]) ? '\n' : '') + phrase
    + (end < d.text.length && !/\s/.test(d.text[end]) ? '\n' : '');
  if (d.text.length + insert.length - (end - start) > promptLimit) {
    notify('提示词已到字数上限。请缩短后再插入。');
    return;
  }
  field.setRangeText(insert, start, end, 'end');
  const placeholder = insert.match(/［[^］]+］/);
  $('#quick-prompt details[open]')?.removeAttribute('open');
  field.focus({ preventScroll: true });
  if (placeholder) field.setSelectionRange(start + placeholder.index, start + placeholder.index + placeholder[0].length);
  inputs.quickPrompt(field);
};
document.addEventListener('selectionchange', () => {
  const field = document.activeElement;
  if (quickPromptVisible() && field?.name === 'quickPrompt') {
    quickDraft().selectionStart = field.selectionStart;
    quickDraft().selectionEnd = field.selectionEnd;
  }
});

function rectStyle(scope) {
  return `left:${scope.x * 100}%;top:${scope.y * 100}%;width:${scope.w * 100}%;height:${scope.h * 100}%`;
}
function quickCanvasControls(id) {
  if (!quickPromptVisible()) return '';
  const d = quickDraft(id), job = quickTask(id);
  const ready = job?.state === 'done' && job.quickPrompt.basis === quickBasis(id);
  const scope = ready ? job.quickPrompt.scope : d.scope;
  return `<div class="quick-outline" style="${scope ? rectStyle(scope) : ''}" ${scope ? '' : 'hidden'} aria-hidden="true"></div>
    ${d.drawing ? '<div class="quick-gesture" aria-hidden="true"></div>' : ''}`;
}
function quickCanvasEffect(id, r, versionID) {
  const e = Studio.edit(id);
  let effect = e.versions.find((v) => v.id === (versionID || e.adopted) && !v.discarded)?.quickPrompt;
  if (!versionID && quickPromptVisible()) {
    const j = quickTask(id);
    if (j?.state === 'done' && j.quickPrompt.basis === quickBasis(id) && !quickDraft(id).before) effect = j.quickPrompt;
  }
  if (!effect) return '';
  const m = effect.scope;
  const clip = m ? `clip-path:inset(${m.y * 100}% ${(1-m.x-m.w)*100}% ${(1-m.y-m.h)*100}% ${m.x*100}%);` : '';
  const filter = RMPhotos.filter(RMPhotos.displayLook(r));
  return pic(id, 'quick-effect', `aria-hidden="true" style="${clip}filter:${filter} sepia(.15) brightness(1.12) saturate(1.26);transform:rotate(${r.angle || 0}deg)"`);
}
function quickPoint(event, rect) {
  const clamp = (v) => Math.max(0, Math.min(1, v));
  return { x: clamp((event.clientX - rect.left) / rect.width), y: clamp((event.clientY - rect.top) / rect.height) };
}
function quickPointerRange(event) {
  const { start, rect } = quickPointer, end = quickPoint(event, rect);
  return { x: Math.min(start.x, end.x), y: Math.min(start.y, end.y), w: Math.abs(start.x - end.x), h: Math.abs(start.y - end.y) };
}
document.addEventListener('pointerdown', (event) => {
  if (!event.target.matches('.quick-gesture') || event.button !== 0) return;
  const rect = event.target.getBoundingClientRect();
  quickPointer = { start: quickPoint(event, rect), rect, id: event.pointerId };
  event.target.setPointerCapture(event.pointerId);
  event.preventDefault();
});
document.addEventListener('pointermove', (event) => {
  if (quickPointer?.id !== event.pointerId) return;
  const outline = $('.quick-outline');
  outline.hidden = false;
  outline.style.cssText = rectStyle(quickPointerRange(event));
});
document.addEventListener('pointerup', (event) => {
  if (quickPointer?.id !== event.pointerId) return;
  const range = quickPointerRange(event);
  quickPointer = null;
  const d = quickDraft();
  if (range.w < .01 || range.h < .01) d.notice = '范围太小。请重新拖动，或选择整张照片。';
  else Object.assign(d, { scope: range, drawing: false, notice: '' });
  render();
});
document.addEventListener('pointercancel', (event) => {
  if (quickPointer?.id !== event.pointerId) return;
  quickPointer = null;
  render();
});
actions['quick-coordinates'] = () => {
  const r = quickDraft().scope || { x: .25, y: .25, w: .5, h: .5 };
  const fields = [['x','左侧'],['y','上方'],['w','宽度'],['h','高度']];
  dialog('输入圈选坐标',
    '<p>以照片可见画幅的左上为起点，输入百分比。</p>' + fields
      .map(([id,label]) => field(label + ' %', id, Math.round(r[id] * 1000) / 10, 'number')).join('') +
    '<p class="muted" id="quick-coord-error" role="status"></p>',
    btn('取消', 'close') + btn('确认选区', 'quick-set-coordinates', '', { cls: 'primary' }));
};
actions['quick-set-coordinates'] = () => {
  const [x, y, w, h] = ['x','y','w','h'].map((name) => Number(value(name)) / 100);
  if (![x,y,w,h].every(Number.isFinite) || x < 0 || y < 0 || w < .01 || h < .01 || x + w > 1 || y + h > 1 ||
      ['x','y','w','h'].some((name) => value(name) === '')) {
    $('#quick-coord-error').textContent = '请填写有效坐标，宽和高至少为 1%，范围必须在照片内。';
    return;
  }
  Object.assign(quickDraft(), { scope: {x,y,w,h}, drawing: false, notice: '' });
  closeSheet();
  render();
  $('[data-act=quick-draw]')?.focus({ preventScroll: true });
};
actions['quick-mask'] = () => {
  const masks = currentEdit().recipe.masks.flatMap((m, i) => m.on && m.opacity > 0 ? [[i, m.kind + ' ' + (i+1)]] : []);
  dialog('使用已有蒙版', masks.length
    ? select('选用范围', 'promptMask', masks, masks[0][0])
    : '<p>当前照片还没有已启用的蒙版。可以回到输入并直接圈选。</p>',
  btn('返回', 'close') + (masks.length ? btn('使用此范围', 'quick-use-mask', '', { cls: 'primary' }) : ''));
};
actions['quick-use-mask'] = () => {
  const i = Number(value('promptMask')), m = currentEdit().recipe.masks[i];
  if (!m?.on || !m.opacity) return;
  const p = { x: Math.max(0, Math.min(.68, m.x/100 - .16)), y: Math.max(0, Math.min(.72, m.y/100 - .14)),
    w: .32, h: .28, name: m.kind + ' ' + (i+1) };
  Object.assign(quickDraft(), { scope: p, drawing: false, notice: '' });
  closeSheet();
  render();
};

function quickPreparedInput(id, draft) {
  const photo = Studio.photo(id), scope = draft.scope;
  const bounds = scope ? {
    x: Math.max(0, scope.x - .06), y: Math.max(0, scope.y - .06),
    endX: Math.min(1, scope.x + scope.w + .06), endY: Math.min(1, scope.y + scope.h + .06),
  } : { x: 0, y: 0, endX: 1, endY: 1 };
  const e = Studio.edit(id);
  const ratio = { '1:1': 1, '4:5': .8, '3:2': 1.5, '16:9': 16/9 }[e.recipe.crop] ?? photo.w/photo.h;
  const w = bounds.endX - bounds.x, h = bounds.endY - bounds.y;
  const inputRatio = ratio * w / h;
  const pixels = draft.model === 'seedream'
    ? [Math.round(Math.sqrt(1048576 * inputRatio)), Math.round(Math.sqrt(1048576 / inputRatio))]
    : [Math.round(Math.min(1, inputRatio) * 1024), Math.round(Math.min(1, 1/inputRatio) * 1024)];
  return { bounds, w, h, inputRatio, pixels, scope, library: quickLibrary(), base: quickBase(id), basis: quickBasis(id), text: draft.text.trim(), model: draft.model };
}
actions['quick-submit'] = () => {
  if (!quickPromptVisible()) return;
  const draft = quickDraft(), id = Studio.data.work, job = quickTask(id);
  if (quickStatus(draft).blocked || job?.state === 'running' || job?.state === 'done') return;
  const input = quickPreparedInput(id, draft);
  if (input.model === 'flux') {
    queueQuickPrompt(id, input);
    return;
  }
  quickApproval = { id, input };
  const { w, h: height, bounds, pixels, inputRatio, scope } = input;
  const recipe = currentEdit().recipe, look = RMPhotos.filter(RMPhotos.displayLook(recipe));
  const art = `<div class="quick-upload-image" style="aspect-ratio:${inputRatio}" aria-label="本次发送图预览">
    ${pic(id, '', `style="width:${100/w}%;height:${100/height}%;left:${-100*bounds.x/w}%;top:${-100*bounds.y/height}%;filter:${look}"`)}
    ${scope ? `<div class="quick-upload-outline" style="${rectStyle({x:(scope.x-bounds.x)/w,y:(scope.y-bounds.y)/height,w:scope.w/w,h:scope.h/height})}"></div>` : ''}</div>`;
  dialog('核对发送给火山方舟的内容',
    `<div class="quick-upload"><div>${art}<p class="muted">${scope ? '描边为改动范围，周围用于补全。' : '整张当前构图'}</p></div><div>
    <dl>${fact('照片', Studio.asset(id).name)}${fact('执行', 'Seedream 5.5 · 北京')}${fact('输入', (scope ? '圈选裁片及边缘上下文' : '当前构图') )}${fact('输入尺寸', pixels.join(' × '))}${fact('输出', '1 张候选')}</dl>
    <p>云端生成可能计费。</p></div></div><details class="quick-sent-text" open><summary>本次 Prompt</summary><p>${h(input.text)}</p></details>`,
    btn('返回编辑', 'close') + btn('确认发送并生成', 'quick-cloud-confirm', '', { cls: 'primary' }));
};
actions['quick-cloud-confirm'] = () => {
  const approval = quickApproval;
  quickApproval = null;
  if (!approval || !quickPromptVisible()) return;
  const {id, input} = approval;
  const draft = quickDraft();
  closeSheet();
  if (id !== Studio.data.work || JSON.stringify(quickPreparedInput(id, draft)) !== JSON.stringify(input) ||
      quickStatus(draft).blocked || quickTask()?.state === 'running') {
    notify('发送内容已变化。请重新核对。');
    return;
  }
  queueQuickPrompt(id, input);
};
function queueQuickPrompt(id, input) {
  const previous = quickTask(id);
  if (previous && ['failed','cancelled'].includes(previous.state)) previous.quickPrompt.reviewed = true;
  return startJob('快速 Prompt', id, null, null, input);
}
actions['quick-setup'] = (page) => {
  S.quickResume = quickSubject();
  go('settings/' + page);
};
function quickFinished(job) {
  const v = Studio.candidate(job.photo, job.kind, job.recipe, job.quickPrompt.base);
  v.quickPrompt = { scope: job.quickPrompt.scope };
  if (!v.quickPrompt.scope) [v.w, v.h] = job.quickPrompt.pixels;
  return v.id;
}
function quickJobAction(action, job) {
  if (action === 'retry' && ['failed','cancelled'].includes(job.state)) {
    quickOpenJob(job);
    return;
  }
  if (action === 'reconcile' && job.state === 'unknown') {
    job.quickPrompt.reconciling = true;
    job.state = 'running';
    job.due = Date.now() + 650;
  } else if (job.state === 'running') {
    if (action === 'fail') job.state = 'failed';
    if (action === 'interrupt' || action === 'cancel') job.state = job.quickPrompt.model === 'seedream' ? 'unknown' : 'cancelled';
  }
  Studio.save();
  if (sheet.open) closeSheet();
  render();
}
function quickOpenJob(job) {
  closeSheet();
  if (job.quickPrompt.library !== quickLibrary() || !validWork(job.photo)) {
    notify('请打开此任务所属的资料库。');
    return;
  }
  if (Studio.data.work !== job.photo) withPhoto(job.photo);
  const d = quickDraft(job.photo);
  Object.assign(d, { text: job.quickPrompt.text, model: job.quickPrompt.model,
    scope: job.quickPrompt.basis === quickBasis(job.photo) ? job.quickPrompt.scope : null, before: false });
  S.quickResume = quickSubject(job.photo);
  const path = S.editReturn === 'edit/versions' ? 'edit/development' : S.editReturn;
  if (S.page === 'edit' && location.hash === '#' + path) { S.quickResume = null; quickBegin(); }
  else go(path);
}
actions['quick-job'] = (action) => { const job = quickTask(); if (job) quickJobAction(action, job); };
actions['quick-compare'] = (side) => { quickDraft().before = side === 'before'; render(); };
actions['quick-inspect'] = () => {
  S.quickInspect = !S.quickInspect;
  const image = $('.edit-image');
  const width = image?.querySelector('img')?.naturalWidth ?? 0;
  S.editZoom = S.quickInspect && width
    ? Math.max(1.25, Math.min(4, S.editZoom * width / image.clientWidth)) : S.quickView.zoom;
  render();
  if (S.quickInspect) {
    const fit = $('.canvas-fit'), shown = $('.edit-image'), scope = quickTask()?.quickPrompt.scope;
    const x = scope ? scope.x + scope.w/2 : .5, y = scope ? scope.y + scope.h/2 : .5;
    fit.scrollLeft = shown.offsetLeft + shown.offsetWidth * x - fit.clientWidth/2;
    fit.scrollTop = shown.offsetTop + shown.offsetHeight * y - fit.clientHeight/2;
  }
};
actions['quick-discard'] = () => {
  const j = quickTask();
  if (j?.state !== 'done') return;
  j.quickPrompt.reviewed = true;
  const v = currentEdit().versions.find((v) => v.id === j.result);
  if (v) v.discarded = true;
  Studio.save();
  render();
  $('[name=quickPrompt]')?.focus({ preventScroll: true });
};
actions['quick-inspect-version'] = () => {
  const job = quickTask();
  if (!job?.result) return;
  actions['open-versions']();
  S.versionView = job.result;
};
function applyQuickVersion(version) {
  const j = quickJobForVersion(version), id = Studio.data.work;
  if (j?.state !== 'done' || quickAdoptionIssue(j, id)) return false;
  if (!Studio.adoptPromptVersion(id, version)) return false;
  j.quickPrompt.reviewed = true;
  Studio.save();
  return true;
}
actions['quick-apply'] = () => {
  if (!applyQuickVersion(quickTask()?.result)) return;
  quickToggle(false);
  notify('已采用创作版本。可在编辑历史撤销。');
};
for (const event of ['online', 'offline']) window.addEventListener(event, () => { if (quickPromptVisible()) render(); });
