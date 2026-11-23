'use strict';

const editTools = {
  basic: [
    '基础',
    [
      ['ev', '曝光', -3, 3, 0.05],
      ['contrast', '对比度'],
      ['high', '高光'],
      ['shadow', '阴影'],
      ['white', '白色色阶'],
      ['black', '黑色色阶'],
      ['warmth', '白平衡'],
      ['tint', '色调'],
      ['sat', '饱和度'],
      ['vibrance', '自然饱和度'],
      ['definition', '清晰度'],
    ],
  ],
  tones: [
    '曲线',
    [
      ['curveLow', '阴影控制点'],
      ['curveHigh', '高光控制点'],
      ['levels', '中间调色阶'],
    ],
  ],
  color: [
    '混色',
    [
      ['hue', '点颜色 · 色相'],
      ['luminance', '选色明度'],
    ],
  ],
  detail: [
    '细节',
    [
      ['sharp', '锐化', 0, 100],
      ['noise', '降噪', 0, 100],
      ['texture', '纹理'],
    ],
  ],
  optics: [
    '光学',
    [
      ['distort', '畸变校正'],
      ['fringe', '去边', 0, 100],
      ['vertical', '垂直透视'],
    ],
  ],
  effects: [
    '效果',
    [
      ['dehaze', '去雾'],
      ['clarity', '清晰度'],
      ['vignette', '暗角', 0, 100],
      ['blur', '镜头模糊', 0, 100],
    ],
  ],
  grading: [
    '分级',
    [
      ['warmHighlights', '高光暖色'],
      ['coolShadows', '阴影冷色'],
      ['balance', '平衡'],
    ],
  ],
  smart: ['智能编辑', []],
  masks: ['蒙版', []],
  repair: ['修复', []],
};
const panelIcons = {
  smart: 'spark',
  basic: 'sliders',
  tones: 'curve',
  color: 'mix',
  detail: 'detail',
  optics: 'lens',
  effects: 'effects',
  grading: 'grading',
  masks: 'mask',
  repair: 'repair',
};
const currentEdit = () => Studio.edit(Studio.data.work);
const toneBands = [
  ['black', '黑色色阶', -100, 100, 1],
  ['shadow', '阴影', -100, 100, 1],
  ['ev', '曝光', -3, 3, 0.05],
  ['high', '高光', -100, 100, 1],
  ['white', '白色色阶', -100, 100, 1],
];
function toneCurve(r) {
  const low = 67 - (r.curveLow || 0) * 0.21,
    high = 25 - (r.curveHigh || 0) * 0.21;
  return `<figure class="curve-chart" aria-label="影调曲线示意"><svg viewBox="0 0 160 90" role="img" aria-label="阴影和高光控制点"><path d="M0 45h160M80 0v90M0 90 160 0" fill="none" stroke="var(--line)"/><path d="M0 89 Q32 ${low} 40 ${low} T120 ${high} Q139 ${high} 160 1" fill="none" stroke="var(--accent)" stroke-width="2"/><g fill="var(--accent)"><circle cx="40" cy="${low}" r="3"/><circle cx="120" cy="${high}" r="3"/></g></svg></figure>`;
}
function adjustments(key, fields) {
  Studio.patchRecipe(Studio.data.work, key, fields);
  render();
}
function rangeRow(key, label, low = -100, high = 100, step = 1, v = 0, unavailable = false) {
  const bounds = `min="${low}" max="${high}" step="${step}" value="${v}"${unavailable ? ' disabled' : ''}`;
  return `<div class="range"><div class="range-readout"><label for="value-${key}">${h(label)}</label>
    <input id="value-${key}" aria-label="${h(label)}数值" type="number" name="adjustNumber"
      data-adjustment="${key}" data-label="${h(label)}" ${bounds}></div>
    <input aria-label="${h(label)}" type="range" name="adjust" data-key="${key}" data-label="${h(label)}" ${bounds}></div>`;
}
const adaptivePresets = [
  { name: '主体柔光', value: 'subject', group: 'Subject', target: '主体', values: { ev: 0.22, contrast: -8 } },
  { name: '日出天空', value: 'sky', group: 'Sky', target: '天空', values: { ev: -0.18, warmth: 36 } },
];
function presetRow(action, key, name, favoriteID, active = false) {
  return `<div class="preset-item">${btn(name, action, key, { icon: 'sliders', cls: active ? 'sidebar-row current' : 'sidebar-row', pressed: active })}
    ${btn('收藏 ' + name, 'favorite', favoriteID, { icon: 'star', only: true, pressed: Studio.data.favorites.includes(favoriteID), cls: 'icon-btn' })}</div>`;
}
function presetFolder(id, label, count, content, expanded = false) {
  const term = (S.presetQuery || '').trim();
  const open = (term ? S.presetSearchFolders : S.presetFolders)?.get(id) ?? (term ? true : expanded);
  return `<details class="preset-folder" data-folder="${h(id)}"${open ? ' open' : ''}><summary>
    ${icon('chevron', 12)}${icon('folder', 13)}<span>${h(label)}</span><small>${count}</small></summary>
    <div class="preset-children">${content}</div></details>`;
}
document.addEventListener('click', (event) => {
  const el = event.target.closest('.preset-folder > summary')?.parentElement;
  if (!el) return;
  event.preventDefault();
  el.open = !el.open;
  const folders = (S.presetQuery || '').trim() ? (S.presetSearchFolders ??= new Map()) : (S.presetFolders ??= new Map());
  folders.set(el.dataset.folder, el.open);
  if (!el.open && el.contains(previewChoice)) endEditPreview();
});
function filterDirectory(recipe) {
  const term = (S.presetQuery || '').trim().toLowerCase();
  const show = (favorite, ...terms) => (!S.favoriteOnly || Studio.data.favorites.includes(favorite)) &&
    terms.some((value) => value.toLowerCase().includes(term));
  const adaptive = adaptivePresets.filter((p) => show(p.name, p.name, p.group, 'Adaptive'));
  const film = Object.entries(RMPhotos.filmStocks)
    .filter(([key, p]) => show('film.' + key, p.name, '胶片模拟 Film'));
  const basic = Studio.data.presets.filter((p) => p.group === 'Classic Filters' && show(p.name, p.name, '基础滤镜'));
  const imported = Studio.data.presets.filter((p) => p.group !== 'Classic Filters' && show(p.name, p.name, p.group, 'Imported'));
  const renderAdaptive = (p) => presetRow('adaptive-preset', p.value, p.name, p.name);
  const renderPreset = (p) => presetRow('apply-preset', p.name, p.name, p.name, recipe.preset === p.name);
  const children = (prefix, entries, row) => Object.entries(Object.groupBy(entries, (p) => p.group))
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([group, list]) => presetFolder(prefix + group, group, list.length, list.map(row).join(''), true)).join('');
  const folders = [
    adaptive.length && presetFolder('adaptive', 'Adaptive', adaptive.length, children('adaptive.', adaptive, renderAdaptive), true),
    film.length && presetFolder('film', '胶片模拟', film.length, film.map(([key, p]) =>
      presetRow('film-stock', key, p.name, 'film.' + key, recipe.filmStock === key)).join(''), true),
    (imported.length || !term && !S.favoriteOnly) && presetFolder('imported', 'Imported', imported.length,
      children('imported.', imported, renderPreset) || '<p class="muted">尚无导入预设</p>'),
    basic.length && presetFolder('basic', '基础滤镜', basic.length, basic.map(renderPreset).join('')),
  ].filter(Boolean);
  return `<div class="preset-directory">${folders.join('') || '<p class="muted">没有匹配的预设</p>'}</div>`;
}
function presetList() {
  const e = currentEdit();
  const recipe = e.recipe;
  const filmAmountEnabled = !!recipe.filmStock;
  return `<aside class="edit-left" aria-label="照片工具"${S.tool === 'versions' ? ' inert' : ''}>
    <section aria-labelledby="preset-heading"><h2 id="preset-heading">滤镜</h2>
      <div class="preset-search"><label class="search-box">${icon('search')}<input aria-label="查找预设" name="presetQuery" placeholder="查找预设" value="${h(S.presetQuery)}"></label>
      ${btn('仅显示收藏', 'favorite-only', '', { icon: 'star', only: true, pressed: !!S.favoriteOnly, cls: 'icon-btn' })}</div>
      <div class="filter-actions">
        ${btn('导入预设…', 'preset-import', '', { icon: 'plus' })}
        ${btn('预设管理', 'preset-manage', '', { only: true, icon: 'menu', cls: 'icon-btn' })}
      </div>
      <div class="film-strength">${rangeRow('filmAmount', '滤镜强度', 0, 100, 1, recipe.filmAmount ?? 100, !filmAmountEnabled)}
        ${filmAmountEnabled ? btn('移除胶片模拟', 'remove-film', '', { cls: 'link' }) : '<small>采用支持强度的滤镜后可调整</small>'}</div>
      ${filterDirectory(recipe)}</section>
    <section aria-labelledby="snapshot-heading"><div class="row between"><h2 id="snapshot-heading">快照</h2>${btn('存储快照', 'snapshot', '', { icon: 'plus', only: true, cls: 'icon-btn' })}</div>
      <div class="snapshot-list">${e.snapshots.map((x, i) => `<div class="preset-item">
        ${btn(x.name, 'restore-snap', i, { icon: 'photo', cls: 'sidebar-row' })}
        <details class="snapshot-menu"><summary aria-label="管理快照 ${h(x.name)}">${icon('menu', 14)}</summary><div>
        ${btn('重命名…', 'rename-snap', i)}${btn('删除', 'delete-snap', i)}</div></details></div>`).join('') || '<p class="muted">尚无快照</p>'}</div></section>
    <section aria-labelledby="history-heading"><div class="row between"><h2 id="history-heading">历史</h2><div class="row">
      ${btn('撤销', 'edit-step', 'undo', { icon: 'undo', only: true, cls: 'icon-btn', disabled: !e.past.length })}${btn('重做', 'edit-step', 'redo', { icon: 'undo', only: true, cls: 'icon-btn redo', disabled: !e.future.length })}</div></div>
      <ol class="edit-history">${e.past.map((p) => '<li>' + h(p.label) + '</li>').join('')}<li>初始状态</li></ol></section></aside>`;
}
function activeLayer(r) {
  return r.masks[Math.min(S.selectedLayer, r.masks.length - 1)];
}
const adjustmentSections = {
  basic: [
    ['whiteBalance', '白平衡', ['warmth', 'tint']],
    ['light', '光效', ['ev', 'contrast', 'high', 'shadow', 'white', 'black']],
    ['color', '颜色', ['sat', 'vibrance']],
    ['definition', '清晰度', ['definition']],
  ],
  tones: [['curves', '曲线', ['curveLow', 'curveHigh']], ['levels', '色阶', ['levels']]],
  color: [['mix', '混色', ['hue', 'luminance']]],
  detail: [['detail', '细节调整', ['sharp', 'noise', 'texture']]],
  optics: [['optics', '光学校正', ['distort', 'fringe', 'vertical']]],
  effects: [
    ['clarity', '清晰度和纹理', ['clarity']],
    ['dehaze', '去雾', ['dehaze']],
    ['vignette', '暗角', ['vignette']],
    ['blur', '镜头模糊', ['blur']],
  ],
  grading: [['grading', '色彩分级', ['warmHighlights', 'coolShadows', 'balance']], ['lut', '查找表', ['lut']]],
  repair: [['repair', '修复', []]],
};
function adjustmentSection(id, title, contents, first, recipe) {
  const photoPanel = Studio.data.work + ':' + S.tool;
  const open = S.adjustmentDisclosure?.get(photoPanel)?.get(id) ?? first;
  const enabled = recipe.sectionEnabled?.[id] !== false;
  return `<div class="adjustment-section"><details data-adjustment-section="${id}" data-photo-panel="${h(photoPanel)}"${open ? ' open' : ''}>
    <summary>${icon('chevron', 12)}<strong>${h(title)}</strong></summary>
    <fieldset${enabled ? '' : ' disabled'}>${contents}</fieldset></details>
    <input type="checkbox" role="switch" aria-label="启用${h(title)}" name="adjustmentEnabled"
      data-key="${id}" data-title="${h(title)}"${enabled ? ' checked' : ''}></div>`;
}
document.addEventListener('click', (event) => {
  const el = event.target.closest('[data-adjustment-section] > summary')?.parentElement;
  if (!el) return;
  event.preventDefault();
  el.open = !el.open;
  const panels = (S.adjustmentDisclosure ??= new Map()), panel = el.dataset.photoPanel;
  if (!panels.has(panel)) panels.set(panel, new Map());
  panels.get(panel).set(el.dataset.adjustmentSection, el.open);
});
changes.adjustmentEnabled = (el) => adjustments('启停' + el.dataset.title, {
  sectionEnabled: { ...currentEdit().recipe.sectionEnabled, [el.dataset.key]: el.checked },
});
function toolFields(r) {
  if (S.tool === 'masks') {
    const m = activeLayer(r);
    return (
      select(
        '新建类型',
        'maskKind',
        ['线性渐变', '径向渐变', '亮度范围', '画笔', 'AI 主体', 'AI 天空'],
        '线性渐变',
      ) +
      btn('添加蒙版', 'add-mask', '', { icon: 'plus' }) +
      r.masks
        .map(
          (m, i) =>
            `<div class="list-row">${btn(m.kind + ' ' + (i + 1), 'choose-mask', i, { pressed: activeLayer(r) === m })}${btn(m.on ? '停用' : '启用', 'toggle-mask', i, { cls: 'link' })}</div>`,
        )
        .join('') +
      (m
        ? `<p class="muted">点画面定位选区中心。</p>${select('组合方式', 'maskBlend', ['添加', '减去', '交集'], m.blend)}${rangeRow('opacity', '蒙版不透明度', 0, 100, 1, m.opacity)}${rangeRow('feather', '羽化', 0, 100, 1, m.feather)}${rangeRow('localEV', '局部曝光', -3, 3, 0.1, m.localEV)}
      <div class="row wrap">${btn('反转', 'mask-op', 'invert', { pressed: !!m.invert })}${btn('上移', 'mask-op', 'up', { disabled: r.masks[0] === m })}${btn('删除图层', 'mask-op', 'delete')}</div>`
        : '<p class="muted">为一个局部区域单独调整曝光。</p>')
    );
  }
  if (S.tool === 'repair')
    return adjustmentSection('repair', '修复',
      select('修复工具', 'repairKind', ['移除', '修复', '仿制'], S.repairKind || '修复') +
      '<p class="muted">在画面点选目标位置。仿制需再点一次取样位置。</p>' +
      btn('在中心标记', 'center-repair') +
      r.repairs
        .map(
          (p, i) =>
            `<div class="list-row"><span>${h(p.kind)} ${i + 1}${p.kind === '仿制' && !p.source ? ' · 待取样' : ''}</span>${btn('移除标记', 'remove-repair', i, { cls: 'link' })}</div>`,
        )
        .join(''), true, r
    );
  const controls = editTools[S.tool][1];
  return adjustmentSections[S.tool].map(([id, title, fields], i) => {
    const content = id === 'lut'
      ? select('查找表', 'lut', ['无', '柔和胶片', '冷调'], r.lut || '无')
      : (id === 'curves' ? toneCurve(r) : '') + fields.map((key) => {
        const [k, n, lo = -100, hi = 100, step = 1] = controls.find(([k]) => k === key);
        return rangeRow(k, n, lo, hi, step, r[k] ?? 0);
      }).join('');
    return adjustmentSection(id, title, content, i === 0, r);
  }).join('') + (S.tool === 'detail' ? btn('增强细节…', 'enhance') : '');
}
function developInspector(r) {
  return `<div class="row between"><h2>${editTools[S.tool][0]}</h2>${btn('颜色示波器', 'scopes', '', { icon: 'pulse', only: true, cls: 'icon-btn' })}</div>
    <div class="tone-control" title="左右拖动色调区域调整亮度">${histogram(Studio.data.work)}</div>${toolFields(r)}
    <div class="ins-block">${btn('复位当前照片…', 'reset-recipe', '', { cls: 'link' })}</div>`;
}
const cards = {
  人像: ['逆光人物提亮', '明暗黑白人像'],
  风光: ['天空压高光', '暮色冷暖'],
  纪实: ['中性还原', '克制黑白', '同组参考配平'],
};
const cardNotes = {
  逆光人物提亮: '提亮人物，保留背景光比',
  明暗黑白人像: '以黑白层次塑造轮廓',
  天空压高光: '保留云层亮部的层次',
  暮色冷暖: '分开调整高光与阴影色温',
  中性还原: '还原现场的光线与色彩',
  克制黑白: '用明暗关系保留现场质感',
  同组参考配平: '以参考张统一组照曝光',
};
function smartInspector() {
  const scene = S.scene || '风光',
    card = S.sceneCard || cards[scene][0];
  return `<h2>智能编辑</h2><section class="smart-panel" aria-labelledby="smart-heading">
    <h3 id="smart-heading">智能预设</h3>${select('拍摄场景', 'scene', Object.keys(cards), scene)}
    <div class="intent-list" role="group" aria-label="调整意图">${cards[scene].map((name) => `<button data-act="scene-card" data-val="${name}" aria-pressed="${card === name}"><span><b>${name}</b><small>${cardNotes[name]}</small></span>${icon(card === name ? 'check' : 'chevron', 14)}</button>`).join('')}</div>
    ${btn('查看范围与配方…', 'scene-preview', '', { cls: 'primary wide' })}</section>
    <div class="creative-entry">${btn('交互式创作', 'edit-tool', 'agent', { icon: 'chat', cls: 'wide' })}</div>`;
}
const agentPlans = {
  局部清理: '先标出要清理的干扰物，再生成局部修补候选，供你与原片核对。',
  人物换光: '以人物为调整范围，保留面部特征，生成光线候选供你比较。',
  风光参考风格: '沿用当前构图与裁切，按你的描述生成风光色调候选。',
};
function conversation() {
  return (currentEdit().conversation ??= {
    turns: [],
    draft: '',
    intent: '局部清理',
    provider: '本机 AI',
    strict: false,
  });
}
function agentInspector() {
  const chat = conversation(),
    last = chat.turns.at(-1);
  return `<h2>智能编辑</h2><section class="agent-panel" aria-labelledby="agent-heading">
    ${btn('返回智能预设', 'edit-tool', 'smart', { icon: 'previous', cls: 'link' })}
    <div class="row between"><h3 id="agent-heading">Agent 对话</h3><small>本地模拟</small></div>
    <div class="chat-log" role="log" aria-label="本张照片的创作对话">${chat.turns.map((t) => `<div class="chat-turn"><small>你</small><p>${h(t.request)}</p></div><div class="chat-turn reply"><small>Agent · ${h(t.intent)}</small><p>${h(agentPlans[t.intent])}</p></div>`).join('')}</div>
    ${select('创作方向', 'aiIntent', Object.keys(agentPlans), chat.intent)}
    <label class="field"><span>编辑要求</span><textarea name="aiPrompt" placeholder="描述想改变或保留的内容" maxlength="2000">${h(chat.draft)}</textarea></label>
    ${btn('发送要求', 'agent-send', '', { icon: 'chat', cls: 'wide', disabled: !chat.draft.trim() })}
    ${
      last
        ? `<div class="ins-block"><h3>生成候选</h3>${select('处理方式', 'aiProvider', ['本机 AI', '云服务'], chat.provider)}${check('严格纪实（保护画面内容）', 'strict', chat.strict)}
    ${btn('核对生成输入…', 'ai-review', '', { cls: 'primary wide', disabled: !!chat.draft.trim(), title: chat.draft.trim() ? '先发送修改后的要求' : '核对生成输入…' })}</div>`
        : ''
    }
    ${btn('制作任务', 'goto', 'jobs', { cls: 'link' })}</section>`;
}
function inspectorRail() {
  const active = S.tool === 'agent' ? 'smart' : S.tool;
  return `<div class="inspector-rail" role="toolbar" aria-label="调整面板" aria-orientation="vertical">${Object.entries(
    panelIcons,
  )
    .map(([key, symbol]) =>
      btn(editTools[key][0], 'edit-tool', key, {
        icon: symbol,
        only: true,
        cls: 'rail-tool',
        controls: 'adjustment-panel',
        pressed: active === key,
      }),
    )
    .join('')}</div>`;
}
function versionsInspector() {
  const e = currentEdit(),
    rows = [{ id: 'original', name: '原始版本', recipe: Studio.freshRecipe() }, ...e.versions].reverse();
  return `<h2>作品版本</h2>${btn('返回调整', 'return-adjustments', '', { icon: 'previous', cls: 'link' })}<p class="muted">选择候选查看效果，采用后用于交付。</p>${rows
    .map((v) => {
      const issue = v.quickPrompt ? quickAdoptionIssue(quickJobForVersion(v.id)) : '';
      const adopt = v.id !== e.adopted && !v.discarded ? btn('采用', 'adopt', v.id, { disabled: !!issue, title: issue || '采用' }) : '';
      return `<div class="version-row"><strong>${h(v.name)}</strong><small>${v.id === e.adopted ? '当前采用' : v.discarded ? '已放弃' : v.retained ? '已保留' : '候选'}</small><div class="row wrap">
      ${btn('查看', 'inspect-version', v.id, { pressed: (S.versionView || e.adopted) === v.id })}${adopt}${v.quickPrompt ? '' : btn('从此继续', 'continue-version', v.id)}${btn('导出此版本…', 'version-export', v.id, { disabled: !!v.discarded || (v.quickPrompt && e.conversation?.strict) })}
      ${v.id !== 'original' && v.id !== e.adopted ? btn(v.discarded ? '恢复' : '放弃', 'discard-version', v.id, { cls: 'link' }) + (!v.retained ? btn('保留', 'retain-version', v.id, { cls: 'link' }) : '') : ''}</div>
      ${issue ? '<small>' + h(issue) + '</small>' : ''}</div>`;
    })
    .join('')}
    ${btn('关联外部编辑副本…', 'external', '', { cls: 'wide' })}`;
}
function versionRecipe(id) {
  return currentEdit().versions.find((v) => v.id === id)?.recipe ?? Studio.freshRecipe();
}
const narrowEditor = matchMedia('(max-width:860px)');
narrowEditor.addEventListener('change', () => {
  if (S.page === 'edit') render();
});
function editorView() {
  const id = Studio.data.work,
    e = currentEdit(),
    versions = S.tool === 'versions';
  const r = versions ? versionRecipe(S.versionView || e.adopted) : e.recipe;
  const inspector = versions
    ? versionsInspector()
    : S.tool === 'agent'
      ? agentInspector()
      : S.tool === 'smart'
        ? smartInspector()
        : developInspector(r);
  const left = presetList();
  const strip = filmstrip(Studio.visible(S.scope).filter(validWork), id, 'edit-photo');
  const canvas = `<div class="edit-center">${canvasContent(r, id)}${strip}</div>`;
  const right =
    '<aside class="edit-inspector" aria-label="调整工具">' +
    inspectorRail() +
    '<div class="inspector-content" id="adjustment-panel" tabindex="-1">' +
    inspector +
    '</div></aside>';
  return `<div class="edit-page" data-photo="${h(id)}"><header class="edit-head"><div class="edit-identity">${btn('返回资料库', 'goto', 'library/' + S.scope, { icon: 'previous', only: true, cls: 'icon-btn' })}
      <strong>${h(Studio.asset(id).name)}</strong><span class="muted">${versions ? '查看版本' : Studio.dirty(id) ? '草稿有调整' : '当前照片'}</span></div>
      <div class="row">${btn('作品版本', 'open-versions', '', { icon: 'layers', pressed: versions })}${btn('保存候选', 'save-version', '', { cls: 'primary', disabled: versions || !Studio.dirty(id) })}</div></header>
    <div class="edit-body" style="--ground:${grounds[Studio.data.prefs.ground] ?? grounds.深灰}">${narrowEditor.matches ? canvas + right + left : left + canvas + right}</div></div>`;
}
function editPanel(path, focus) {
  S.editFocus = focus;
  go(path);
  if (S.renderRoute === location.hash) focusEditDestination();
}
function focusEditDestination() {
  if (!S.editFocus) return;
  const el = $(S.editFocus);
  if (el) {
    el.focus({ preventScroll: true });
    S.editFocus = '';
  }
}
actions['edit-tool'] = (key, event, el) => {
  const focus = el?.closest('.inspector-rail')
    ? '.inspector-rail [data-val="' + key + '"]'
    : '#adjustment-panel';
  editPanel('edit/' + key, focus);
};
actions['open-versions'] = () => {
  if (S.tool === 'versions') return actions['return-adjustments']();
  S.beforeVersions = S.editReturn;
  editPanel('edit/versions', '#adjustment-panel');
};
actions['return-adjustments'] = () =>
  editPanel(S.beforeVersions || 'edit/development', '[data-act="open-versions"]');
actions['edit-step'] = (v) => {
  if (S.tool === 'versions') return;
  Studio.stepEdit(Studio.data.work, v === 'redo');
  render();
};
actions['save-version'] = () => {
  if (S.tool !== 'versions' && Studio.dirty(Studio.data.work)) {
    const v = Studio.candidate(Studio.data.work, '初修');
    render();
    notify('已保存候选 · ' + v.name);
  }
};
actions['inspect-version'] = (id) => {
  S.versionView = id;
  render();
};
actions.adopt = (id) => {
  if (currentEdit().versions.find((v) => v.id === id)?.quickPrompt) {
    if (!applyQuickVersion(id)) return;
  } else currentEdit().adopted = id;
  S.versionView = id;
  Studio.save();
  render();
  notify('已采用此版本');
};
actions['discard-version'] = (id) => {
  const v = currentEdit().versions.find((x) => x.id === id);
  v.discarded = !v.discarded;
  Studio.save();
  render();
};
actions['retain-version'] = (id) => {
  currentEdit().versions.find((x) => x.id === id).retained = true;
  Studio.save();
  render();
};
actions['continue-version'] = (id) => {
  const e = currentEdit();
  Studio.setRecipe(Studio.data.work, '从版本继续', versionRecipe(id));
  e.base = id;
  e.saved = JSON.stringify(e.recipe);
  Studio.save();
  actions['return-adjustments']();
};
actions.external = () =>
  dialog(
    '外部编辑副本',
    `<p>为 ${h(Studio.asset(Studio.data.work).name)} 建立独立 TIFF 副本。返回的结果登记为候选。</p>${select('外部编辑器', 'externalApp', ['Photoshop', '其他编辑器'], 'Photoshop')}`,
    btn('取消', 'close') + btn('模拟关联返回的副本', 'external-result', '', { cls: 'primary' }),
  );
actions['external-result'] = () => {
  const v = Studio.candidate(Studio.data.work, '外部编辑');
  S.versionView = v.id;
  closeSheet();
  render();
  notify('已关联为独立候选');
};
function adjusted(el) {
  const r = structuredClone(currentEdit().recipe),
    k = el.dataset.key;
  if (['opacity', 'feather', 'localEV'].includes(k)) {
    const m = activeLayer(r);
    if (m) m[k] = Number(el.value);
  } else r[k] = Number(el.value);
  return r;
}
inputs.adjust = (el) => {
  const r = adjusted(el);
  el.closest('.range').querySelector('[name=adjustNumber]').value = el.value;
  paintEditPreview(r);
};
changes.adjust = (el) => {
  Studio.setRecipe(Studio.data.work, el.dataset.label, adjusted(el));
  render();
};
changes.adjustNumber = (el) => {
  const slider = el.closest('.range').querySelector('[name=adjust]');
  if (el.value !== '' && Number.isFinite(el.valueAsNumber)) {
    const number = Math.max(Number(el.min), Math.min(Number(el.max), el.valueAsNumber));
    Studio.setRecipe(Studio.data.work, slider.dataset.label, adjusted({
      dataset: slider.dataset, value: number,
    }));
  }
  render();
};
document.addEventListener('keydown', (event) => {
  if (event.target.name === 'adjustNumber' && event.key === 'Enter' && !event.isComposing)
    event.target.blur();
});
document.addEventListener('pointerdown', (event) => {
  const chart = event.target.closest('.tone-control svg');
  if (!chart || event.button !== 0) return;
  const box = chart.getBoundingClientRect(),
    start = event.clientX,
    id = Studio.data.work;
  const [key, label, min, max, step] =
    toneBands[Math.min(4, Math.max(0, Math.floor((5 * (start - box.left)) / box.width)))];
  const initial = currentEdit().recipe,
    caption = chart.closest('figure').querySelector('small');
  let amount = initial[key] || 0;
  chart.setPointerCapture(event.pointerId);
  function move(e) {
    const delta = ((e.clientX - start) * (max - min)) / box.width;
    amount = Number(
      Math.max(min, Math.min(max, Math.round(((initial[key] || 0) + delta) / step) * step)).toFixed(2),
    );
    caption.textContent = label + ' ' + amount;
    const img = $('.developed');
    if (img) img.style.filter = RMPhotos.filter(RMPhotos.displayLook({ ...initial, [key]: amount }));
  }
  function finish(e) {
    chart.removeEventListener('pointermove', move);
    chart.removeEventListener('pointerup', finish);
    chart.removeEventListener('pointercancel', finish);
    if (e.type === 'pointerup' && chart.isConnected && Studio.data.work === id)
      Studio.patchRecipe(id, '直方图 · ' + label, { [key]: amount });
    render();
  }
  chart.addEventListener('pointermove', move);
  chart.addEventListener('pointerup', finish);
  chart.addEventListener('pointercancel', finish);
});
changes.crop = (el) => adjustments('裁切比例', { crop: el.value });
changes.lut = (el) => adjustments('分级 LUT', { lut: el.value });
actions['crop-reset'] = () => adjustments('复位裁切', { crop: '原始', angle: 0 });
changes.ground = (el) => {
  Studio.data.prefs.ground = el.value;
  Studio.save();
  render();
};
actions['reset-recipe'] = () =>
  dialog(
    '复位当前照片？',
    '<p>恢复初始参数。已保存的版本可在作品版本中查看。</p>',
    btn('取消', 'close') + btn('复位调整', 'confirm-reset'),
  );
actions['confirm-reset'] = () => {
  closeSheet();
  Studio.setRecipe(Studio.data.work, '复位调整', Studio.freshRecipe());
  render();
};
actions.scopes = () =>
  dialog('颜色示波器', histogram(Studio.data.work) + '<p>数据取自当前示例 JPEG。</p>', btn('完成', 'close'));
actions.enhance = () =>
  dialog(
    '增强细节',
    select('处理', 'enhancement', ['RAW 细节', 'AI 降噪', '超级分辨率'], 'RAW 细节') +
      '<p>处理结果登记为独立的示例候选。</p>',
    btn('取消', 'close') + btn('生成候选', 'enhance-run'),
  );
actions['enhance-run'] = () => {
  const kind = value('enhancement');
  closeSheet();
  startJob(kind, Studio.data.work);
};
function alterMasks(label, fn) {
  const masks = structuredClone(currentEdit().recipe.masks);
  fn(masks);
  adjustments(label, { masks });
}
actions['add-mask'] = () => {
  const kind = value('maskKind', $('#workspace'));
  alterMasks('添加' + kind, (ms) => {
    S.selectedLayer = ms.length;
    ms.push({ kind, on: true, blend: '添加', opacity: 75, feather: 45, localEV: 0, x: 50, y: 50 });
  });
};
actions['choose-mask'] = (i) => {
  S.selectedLayer = Number(i);
  render();
};
actions['toggle-mask'] = (i) => alterMasks('切换蒙版', (ms) => (ms[i].on = !ms[i].on));
actions['mask-op'] = (op) =>
  alterMasks('编辑蒙版', (ms) => {
    const i = Math.min(S.selectedLayer, ms.length - 1);
    if (i < 0) return;
    if (op === 'delete') {
      ms.splice(i, 1);
      S.selectedLayer = Math.max(0, i - 1);
    } else if (op === 'up' && i > 0) {
      [ms[i - 1], ms[i]] = [ms[i], ms[i - 1]];
      S.selectedLayer = i - 1;
    } else ms[i].invert = !ms[i].invert;
  });
changes.maskBlend = (el) =>
  alterMasks('蒙版组合', (ms) => {
    activeLayer({ masks: ms }).blend = el.value;
  });
changes.repairKind = (el) => {
  S.repairKind = el.value;
};
function point(x, y) {
  if (S.tool === 'repair' && currentEdit().recipe.sectionEnabled?.repair === false) return;
  if (S.cropOpen || S.compare) return;
  if (S.tool === 'masks' && activeLayer(currentEdit().recipe))
    alterMasks('定位选区', (ms) => Object.assign(activeLayer({ masks: ms }), { x, y }));
  if (S.tool === 'repair') {
    const repairs = structuredClone(currentEdit().recipe.repairs),
      last = repairs.at(-1);
    if (last?.kind === '仿制' && !last.source) last.source = { x, y };
    else repairs.push({ kind: S.repairKind || '修复', x, y });
    adjustments('修复取样', { repairs });
  }
}
actions['canvas-point'] = (_, event, el) => {
  const box = el.getBoundingClientRect();
  point(
    Math.round(((event.clientX - box.left) * 100) / box.width),
    Math.round(((event.clientY - box.top) * 100) / box.height),
  );
};
actions['center-repair'] = () => point(50, 50);
actions['remove-repair'] = (i) =>
  adjustments('移除修复点', { repairs: currentEdit().recipe.repairs.filter((_, n) => n !== Number(i)) });
actions['apply-preset'] = (name) => {
  const p = Studio.data.presets.find((p) => p.name === name);
  adjustments('套用 ' + name, { ...p.values, preset: name });
};
actions['adaptive-preset'] = (key) => {
  const p = adaptivePresets.find((item) => item.value === key);
  dialog(p.name, `<p>在当前照片上生成${p.target}蒙版。确认覆盖范围后再采用。</p>`,
    btn('取消', 'close') + btn('生成预览', 'adaptive-mask-preview', key, { cls: 'primary' }));
};
actions['adaptive-mask-preview'] = (key) => {
  const p = adaptivePresets.find((item) => item.value === key);
  dialog(p.name, `<figure class="adaptive-mask-proof">${pic(Studio.data.work, '')}<span aria-hidden="true" class="${key}"></span></figure><p>已重建${p.target}蒙版 · ${p.name}</p>`,
    btn('取消', 'close') + btn('采用蒙版', 'adaptive-mask-apply', key, { cls: 'primary' }));
};
actions['adaptive-mask-apply'] = (key) => {
  const p = adaptivePresets.find((item) => item.value === key);
  const masks = currentEdit().recipe.masks;
  closeSheet();
  adjustments('套用 ' + p.name, { masks: [...masks, { name: p.target, kind: p.target, values: p.values }] });
};
actions['film-stock'] = (key) => {
  if (!Object.hasOwn(RMPhotos.filmStocks, key) || currentEdit().recipe.filmStock === key) return;
  adjustments('胶片模拟 · ' + RMPhotos.filmStocks[key].name, { filmStock: key, filmAmount: 100 });
};
actions['remove-film'] = () => {
  const { filmStock, filmAmount, ...recipe } = currentEdit().recipe;
  Studio.setRecipe(Studio.data.work, '移除胶片模拟', recipe);
  render();
};
actions.favorite = (name) => {
  const f = Studio.data.favorites;
  Studio.data.favorites = f.includes(name) ? f.filter((x) => x !== name) : [...f, name];
  Studio.save();
  render();
};
actions['favorite-only'] = () => {
  S.favoriteOnly = !S.favoriteOnly;
  render();
};
inputs.presetQuery = (el) => {
  S.presetQuery = el.value;
  S.presetSearchFolders = new Map();
  const selection = [el.selectionStart, el.selectionEnd];
  render();
  $('[name=presetQuery]').setSelectionRange(...selection);
};
const previewSelector = '[data-act="apply-preset"],[data-act="adaptive-preset"],[data-act="film-stock"],[data-act="restore-snap"]';
let previewChoice;
function paintEditPreview(recipe) {
  const img = $('.developed');
  if (!img) return;
  img.style.filter = RMPhotos.filter(RMPhotos.displayLook(recipe));
  img.style.transform = 'rotate(' + (recipe.angle || 0) + 'deg)';
  $('.dark-canvas').style.setProperty('--ratio', editImageRatio(recipe, Studio.data.work));
}
function endEditPreview() {
  if (!previewChoice) return;
  const connected = previewChoice.isConnected;
  previewChoice = null;
  if (connected) {
    paintEditPreview(currentEdit().recipe);
    $('.look-preview').hidden = true;
  }
}
function rowPreview(el) {
  const recipe = currentEdit().recipe;
  const key = el.dataset.val;
  switch (el.dataset.act) {
    case 'film-stock':
      return { ...recipe, filmStock: key, filmAmount: recipe.filmStock === key ? (recipe.filmAmount ?? 100) : 100 };
    case 'apply-preset':
      return { ...recipe, ...Studio.data.presets.find((p) => p.name === key)?.values };
    case 'adaptive-preset':
      return { ...recipe, ...adaptivePresets.find((p) => p.value === key)?.values };
    case 'restore-snap':
      return currentEdit().snapshots[key]?.recipe;
  }
}
for (const type of ['pointerover', 'focusin', 'pointerout', 'focusout']) {
  document.addEventListener(type, (event) => {
    const el = event.target.closest(previewSelector);
    if (!el || el.contains(event.relatedTarget) || S.page !== 'edit' || S.tool === 'versions' ||
      S.compare || S.cropOpen || quickPromptVisible() || sheet.open) return;
    if (type === 'pointerout' || type === 'focusout') {
      if (previewChoice === el) endEditPreview();
      return;
    }
    const recipe = rowPreview(el);
    if (!recipe) return;
    previewChoice = el;
    paintEditPreview(recipe);
    const note = $('.look-preview');
    note.textContent = '临时预览 · ' + el.getAttribute('aria-label');
    note.hidden = false;
  });
}
window.addEventListener('blur', endEditPreview);
document.addEventListener('keydown', (event) => {
  if (S.page !== 'edit' || sheet.open) return;
  if (event.key === 'Escape' && previewChoice?.isConnected) {
    endEditPreview();
    event.preventDefault();
    return;
  }
  const el = event.target.closest(previewSelector);
  if (!el || event.metaKey || event.ctrlKey || event.altKey) return;
  const keys = ['ArrowUp', 'ArrowDown'];
  if (!keys.includes(event.key)) return;
  event.preventDefault();
  const rows = [...el.closest('.preset-children,.snapshot-list').querySelectorAll(previewSelector)].filter((row) => row.getClientRects().length),
    step = event.key === keys[0] ? -1 : 1;
  rows[Math.max(0, Math.min(rows.length - 1, rows.indexOf(el) + step))].focus();
});
actions['preset-import'] = () => {
  actions['preset-manage']('import');
};
actions['preset-manage'] = (operation) =>
  dialog(
    '预设管理',
    field('预设名称', 'presetName', '我的调整') +
      select(
        '操作',
        'presetOperation',
        ['保存当前调整', '导入 Lightroom / Camera Raw 预设', '导出原生预设'],
        operation === 'import' ? '导入 Lightroom / Camera Raw 预设' : '保存当前调整',
      ) +
      (operation === 'import'
        ? '<p id="preset-detail" class="muted">示例导入。为预设命名，再从 Imported 查看。</p>'
        : '<p id="preset-detail" class="muted">保存可跨片复用的调整字段。</p>'),
    btn('取消', 'close') + btn('执行', 'preset-command'),
  );
changes.presetOperation = (el) => {
  $('#preset-detail').textContent = {
    '导入 Lightroom / Camera Raw 预设': '选择 .xmp 或 .zip 后先查看支持的字段与缺失依赖。',
    导出原生预设: '可查看和下载本次选择的示例参数。',
    保存当前调整: '保存可跨片复用的调整字段。',
  }[el.value];
};
actions['preset-command'] = () => {
  const op = value('presetOperation'),
    name = value('presetName').trim();
  if (!name) return;
  const { masks, repairs, ...reusable } = currentEdit().recipe;
  if (op === '导出原生预设') {
    demoDownload(name + '.rmpreset.json', { schema: 'rawmaster.ui.example', name, values: reusable });
    closeSheet();
    return;
  }
  const values = op === '保存当前调整' ? reusable : { ev: 0.3, contrast: 8 };
  let title = name,
    seq = 2;
  while (Studio.data.presets.some((p) => p.name === title)) title = name + ' ' + seq++;
  const group = op === '保存当前调整' ? '我的预设' : '导入组';
  Studio.data.presets.push({ name: title, group, values });
  (S.presetFolders ??= new Map()).set('imported', true);
  S.presetFolders.set('imported.' + group, true);
  Studio.save();
  closeSheet();
  render();
  notify('已加入预设目录');
};
actions.snapshot = () =>
  dialog(
    '存储快照',
    field('名称', 'snapshotName', '快照 ' + (currentEdit().snapshots.length + 1)),
    btn('取消', 'close') + btn('存储', 'save-snap'),
  );
actions['save-snap'] = () => {
  const name = value('snapshotName').trim();
  if (!name) return;
  currentEdit().snapshots.push({ name, recipe: structuredClone(currentEdit().recipe) });
  Studio.save();
  closeSheet();
  render();
};
actions['restore-snap'] = (i) => {
  Studio.setRecipe(Studio.data.work, '恢复快照', currentEdit().snapshots[i].recipe);
  render();
};
actions['rename-snap'] = (i) =>
  dialog('重命名快照', field('名称', 'snapshotName', currentEdit().snapshots[i].name),
    btn('取消', 'close') + btn('存储', 'save-snap-name', i));
actions['save-snap-name'] = (i) => {
  const name = value('snapshotName').trim();
  if (!name) return;
  currentEdit().snapshots[i].name = name;
  Studio.save();
  closeSheet();
  render();
};
actions['delete-snap'] = (i) => {
  currentEdit().snapshots.splice(Number(i), 1);
  Studio.save();
  render();
};
changes.scene = (el) => {
  S.scene = el.value;
  S.sceneCard = cards[S.scene][0];
  render();
};
actions['scene-card'] = (name) => {
  S.sceneCard = name;
  render();
};
for (const [key, field] of [
  ['aiProvider', 'provider'],
  ['aiIntent', 'intent'],
]) {
  changes[key] = (el) => {
    conversation()[field] = el.value;
    Studio.save();
  };
}
inputs.aiPrompt = (el) => {
  const chat = conversation();
  chat.draft = el.value;
  Studio.save();
  $('[data-act="agent-send"]').disabled = !el.value.trim();
  const review = $('[data-act="ai-review"]');
  if (review) {
    review.disabled = !!el.value.trim();
    review.title = review.disabled ? '先发送修改后的要求' : '核对生成输入…';
    review.setAttribute('aria-label', review.title);
  }
};
changes.strict = (el) => {
  conversation().strict = el.checked;
  Studio.save();
};
actions['agent-send'] = () => {
  const chat = conversation(),
    request = chat.draft.trim();
  if (!request) return;
  chat.turns.push({ request, intent: chat.intent });
  chat.draft = '';
  Studio.save();
  render();
  const log = $('.chat-log');
  log.scrollTop = log.scrollHeight;
  $('[data-act="ai-review"]').focus({ preventScroll: true });
};
function sceneGroup() {
  const current = Studio.data.work,
    visible = Studio.visible(S.scope);
  if (!visible.includes(current)) return [current];
  const selected = activeIDs();
  if (selected.includes(current) && selected.length > 1) return visible.filter((id) => selected.includes(id));
  const group =
    Studio.scopeInfo(S.scope).group ?? Studio.catalog().groups.find((g) => g.ids.includes(current));
  return group ? visible.filter((id) => group.ids.includes(id)) : [current];
}
function reviewSceneGroup(ids, reference) {
  const targets = ids.filter((id) => id !== reference);
  const rows = targets.map((id, i) => {
    const online = Studio.asset(id).online,
      review = i === 2;
    return (
      '<label class="check"><input type="checkbox" name="matchTarget" value="' +
      h(id) +
      '" ' +
      (!online ? 'disabled' : review ? '' : 'checked') +
      '>' +
      h(Studio.asset(id).name) +
      (online ? (review ? ' · 换光待复核' : ' · +0.20 EV') : ' · 原片离线') +
      '</label>'
    );
  });
  const count = targets.filter((id, i) => Studio.asset(id).online && i !== 2).length;
  dialog(
    '同组参考配平',
    select(
      '参考张',
      'matchReference',
      ids.map((id) => [id, Studio.asset(id).name]),
      reference,
    ) +
      '<p>仅调整勾选目标的曝光。</p>' +
      rows.join(''),
    btn('取消', 'close') +
      btn('采用 ' + count + ' 张', 'apply-scene', '', { disabled: !count, cls: 'primary' }),
  );
}
changes.matchReference = (el) => reviewSceneGroup(S.matchGroup, el.value);
changes.matchTarget = () => {
  const count = sheet.querySelectorAll('[name=matchTarget]:checked').length,
    apply = sheet.querySelector('[data-act=apply-scene]');
  apply.disabled = !count;
  apply.textContent = apply.title = '采用 ' + count + ' 张';
  apply.setAttribute('aria-label', apply.title);
};
actions['scene-preview'] = () => {
  const name = S.sceneCard || cards[S.scene || '风光'][0];
  S.reviewCard = name;
  if (name === '同组参考配平') {
    S.matchGroup = sceneGroup();
    if (S.matchGroup.length < 2)
      dialog(name, '<p>在资料库选择至少两张照片，或从拍摄组进入编辑。</p>', btn('返回智能预设', 'close'));
    else reviewSceneGroup(S.matchGroup, Studio.data.work);
    return;
  }
  dialog(
    name,
    `<p>${h(cardNotes[name])}</p>${select('作用范围', 'sceneRange', name.includes('天空') ? ['天空渐变', '手工选区'] : name.includes('人物') ? ['手工人物选区'] : ['全片', '手工选区'], undefined)}`,
    btn('取消', 'close') + btn('采用调整', 'apply-scene', '', { cls: 'primary' }),
  );
};
actions['apply-scene'] = () => {
  const n = S.reviewCard,
    id = Studio.data.work;
  if (n === '同组参考配平') {
    for (const target of sheet.querySelectorAll('[name=matchTarget]:checked:not(:disabled)')) {
      Studio.patchRecipe(target.value, '参考配平', {
        ev: Math.min(3, (Studio.edit(target.value).recipe.ev ?? 0) + 0.2),
      });
    }
  } else if (value('sceneRange') !== '全片')
    Studio.patchRecipe(id, n, {
      masks: [
        ...currentEdit().recipe.masks,
        {
          kind: value('sceneRange'),
          blend: '添加',
          on: true,
          opacity: 80,
          feather: 40,
          localEV: n.includes('天空') ? -0.22 : 0.35,
          x: 50,
          y: 35,
        },
      ],
    });
  else
    Studio.patchRecipe(
      id,
      n,
      n.includes('黑白')
        ? { mono: true, contrast: 8 }
        : n === '暮色冷暖'
          ? { warmHighlights: 32, coolShadows: 18 }
          : { ev: 0.2 },
    );
  closeSheet();
  render();
  notify('已采用 · ' + n);
};
actions['ai-review'] = () => {
  const chat = conversation(),
    turn = chat.turns.at(-1);
  if (!turn || chat.draft.trim()) return;
  const provider = chat.provider,
    id = Studio.data.work,
    req = provider === '本机 AI' ? 'runtime' : 'cloud';
  if (chat.strict) {
    dialog(
      '严格纪实保护',
      '<p>当前生成任务会改写画面内容。返回智能预设可以用可撤销的参数调整。</p>',
      btn('返回对话', 'close') + btn('使用智能预设', 'goto-close', 'edit/smart'),
    );
    return;
  }
  if (Studio.data.prefs[req] !== (req === 'runtime' ? '就绪' : '已配置')) {
    dialog(
      '需要准备服务',
      `<p>${provider} 尚未准备。设置完成后可返回当前照片。</p>`,
      btn('取消', 'close') + btn('打开设置', 'goto-close', 'settings/' + req),
    );
    return;
  }
  dialog(
    '核对生成输入',
    `<dl>${fact('输入', Studio.asset(id).name)}${fact('执行位置', provider)}${fact('任务', turn.intent)}${chat.turns.map((t, i) => fact('要求 ' + (i + 1), t.request)).join('')}</dl><p>本原型仅模拟任务和候选。${provider === '云服务' ? '真实云任务会发送输入并可能计费。' : ''}</p>`,
    btn('取消', 'close') + btn('模拟生成候选', 'run-ai', '', { cls: 'primary' }),
  );
};
actions['run-ai'] = () => {
  closeSheet();
  const chat = conversation(),
    turn = chat.turns.at(-1);
  if (turn && !chat.strict && !chat.draft.trim())
    startJob(turn.intent, Studio.data.work, null, {
      requests: chat.turns.map((t) => t.request),
      provider: chat.provider,
    });
};
