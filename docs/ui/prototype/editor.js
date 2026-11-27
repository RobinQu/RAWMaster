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
  smart: ['智能预设', []],
  masks: ['蒙版', []],
  repair: ['修复', []],
};
const panelIcons = {
  basic: 'sliders',
  tones: 'curve',
  color: 'mix',
  detail: 'detail',
  optics: 'lens',
  effects: 'effects',
  grading: 'grading',
  masks: 'mask',
  repair: 'repair',
  smart: 'spark',
};
const currentEdit = () => canvasToolEdit();
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
  if (S.canvasTool) {
    const allowed = S.canvasTool.kind === 'crop' ? ['crop','angle','quarterTurns','flipH','flipV','cropBox'] : S.canvasTool.kind === 'mask' && S.canvasTool.legacy ? ['masks'] : [];
    if (!Object.keys(fields).every(field => allowed.includes(field))) return notify('请先完成或取消画布工具，不能同时采用其他调整');
    return canvasToolPatch(key, fields);
  }
  if (dagEnabled()) return dagPatch(key, fields);
  Studio.patchRecipe(Studio.data.work, key, fields);
  render();
}
function rangeFill(value, low, high) {
  const percent = (n) => 100 * (Math.max(low, Math.min(high, n)) - low) / (high - low);
  const start = percent(low < 0 && high > 0 ? 0 : low), end = percent(value);
  return `--fill-start:${Math.min(start, end)}%;--fill-size:${Math.abs(start - end)}%;--fill-end:${end}%`;
}
function rangeRow(key, label, low = -100, high = 100, step = 1, v = 0, unavailable = false) {
  const bounds = `min="${low}" max="${high}" value="${v}"${unavailable ? ' disabled' : ''}`;
  const reset = key === 'filmAmount' || key === 'opacity' ? 100 : key === 'wbTemperature' && low === 2000 ? 5500 : Math.max(low, Math.min(high, 0));
  return `<div class="range" style="${rangeFill(v, low, high)}"><span class="range-name" aria-hidden="true">${h(label)}</span>
    <input aria-label="${h(label)}" type="range" name="adjust" data-key="${key}" data-label="${h(label)}"
      data-default="${reset}" step="${step}" ${bounds}>
    <input id="value-${key}" aria-label="${h(label)}数值" type="number" name="adjustNumber"
      data-adjustment="${key}" step="any" ${bounds}>
    <span class="range-ticks" aria-hidden="true">${Array.from({ length: 21 }, () => '<i></i>').join('')}</span></div>`;
}
// Representative bundled Lightroom presets. Keys remain stable for preview and adoption.
const adaptivePresets = [
  { id:'adaptive.portrait', name: '增强人像', value: 'portrait', group: '人像', target: '人像', source: 'Enhance Portrait', values: { ev: .12, texture: -12 } },
  { id:'日出天空', name: '日出', value: 'sky', group: '天空', target: '天空', source: 'Sunrise', values: { ev: -.18, warmth: 36 } },
  { id:'主体柔光', name: '柔和', value: 'subject', group: '主体', target: '主体', source: 'Soft', values: { ev: .22, contrast: -8 } },
  { id:'adaptive.warm-light', name: '暖光', value: 'warm-light', group: '主体', target: '主体', source: 'Warm Light', values: { ev: .22, warmth: 12 } },
  { id:'adaptive.landscape', name: '春季 01', value: 'landscape', group: '风景', target: '风景', source: 'Spring01', values: { sat: 12 } },
  { id:'adaptive.background', name: '气泡', value: 'background', group: '模糊背景', target: '背景', source: 'Bubble', values: { blur: 12 } },
];
function presetRow(action, key, name, favoriteID, active = false) {
  const scene = SceneEditor.nativeReview && SceneEditor.hdr();
  return `<div class="preset-item">${btn(name, action, key, { icon: 'sliders', cls: active ? 'sidebar-row current' : 'sidebar-row', pressed: active, disabled:scene, title:scene ? name + ' · 适用于 SDR 编辑' : name })}
    ${btn('收藏 ' + name, 'favorite', favoriteID, { icon: 'star', only: true, disabled:scene, pressed: Studio.data.favorites.includes(favoriteID), cls: 'icon-btn' })}</div>`;
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
  const adaptive = adaptivePresets.filter((p) => show(p.id, p.name, p.group, p.source, '自适应滤镜 Adaptive'));
  const film = Object.entries(RMPhotos.filmStocks)
    .filter(([key, p]) => show('film.' + key, p.name, '胶片模拟 Film'));
  const basic = Studio.data.presets.filter((p) => p.group === 'Classic Filters' && show(p.name, p.name, '基础滤镜'));
  const imported = Studio.data.presets.filter((p) => p.group !== 'Classic Filters' && show(p.name, p.name, p.group, '用户导入滤镜 Imported'));
  const renderAdaptive = (p) => presetRow('adaptive-preset', p.value, p.name, p.id);
  const renderPreset = (p) => presetRow('apply-preset', p.name, p.name, p.name, recipe.preset === p.name);
  const children = (prefix, entries, row) => {
    const groups = Object.entries(Object.groupBy(entries, p => p.group));
    if (prefix === 'imported.') groups.sort(([a], [b]) => a.localeCompare(b, 'zh-CN'));
    return groups.map(([group, list]) => presetFolder(prefix + group, group, list.length, list.map(row).join(''), prefix === 'imported.')).join('');
  };
  const folders = [
    adaptive.length && presetFolder('adaptive', '自适应滤镜', adaptive.length, children('adaptive.', adaptive, renderAdaptive), true),
    basic.length && presetFolder('basic', '基础滤镜', basic.length, basic.map(renderPreset).join('')),
    film.length && presetFolder('film', '胶片模拟', film.length,
      '<p class="muted">Spektrafilm 官方模型 · SDR 色彩外观</p>' + film.map(([key, p]) =>
      presetRow('film-stock', key, p.name, 'film.' + key, recipe.filmStock === key)).join(''), true),
    (imported.length || !term && !S.favoriteOnly) && presetFolder('imported', '用户导入滤镜', imported.length,
      children('imported.', imported, renderPreset) || '<p class="muted">尚无导入预设</p>'),
  ].filter(Boolean);
  return `<div class="preset-directory">${folders.join('') || '<p class="muted">没有匹配的预设</p>'}</div>`;
}
function rawSummary() {
  const photo = Studio.photo(Studio.data.work);
  const {camera, focal, aperture, shutter, iso} = photo.exif;
  return `<details class="raw-summary" ${S.rawSummaryOpen === false ? '' : 'open'}>
    <summary>${icon('chevron', 11)}${icon('photo', 14)}RAW 摘要</summary>
    <p>${h(camera)} · ${h(focal)} · ${photo.w} × ${photo.h}</p>
    <p>${h(aperture)} · ${h(shutter)} · ${h(iso)}</p></details>`;
}
document.addEventListener('toggle', event => {
  if (event.target.matches('.raw-summary') && event.target.isConnected) S.rawSummaryOpen = event.target.open;
}, true);
function presetList() {
  const e = currentEdit();
  const recipe = e.recipe;
  const nativeHDR = SceneEditor.nativeReview && SceneEditor.hdr();
  const filmAmountEnabled = !!recipe.filmStock && !nativeHDR;
  const available = Studio.asset(Studio.data.work).online;
  const enabled = recipe.filmEnabled !== false;
  const expanded = S.filtersExpanded !== false;
  return `<aside class="edit-left" aria-label="照片工具"${S.tool === 'versions' ? ' inert' : ''}>
    ${rawSummary()}<div class="edit-library-panel">
    <section aria-labelledby="preset-heading">
      <div class="filter-panel-heading">
        <button class="filter-disclosure" data-act="filters-panel-toggle" aria-expanded="${expanded}" aria-label="滤镜，${expanded ? '收起' : '展开'}">${icon('chevron', 10)}${icon('photo', 13)}<span id="preset-heading">滤镜</span></button>
        <div class="filter-header-actions">
          ${btn('复位滤镜', 'remove-film', '', { icon: 'undo', only: true, cls: 'icon-btn', disabled: !available || !filmAmountEnabled })}
          <button class="filter-enabled" data-act="filter-enabled" aria-label="启用滤镜" aria-pressed="${enabled && filmAmountEnabled}"${!available || !filmAmountEnabled ? ' disabled' : ''}><span aria-hidden="true"></span></button>
          <details class="filter-options"${!available ? ' inert' : ''}><summary aria-label="滤镜与预设操作">${icon('ellipsis', 14)}</summary><div>
            ${btn('保存当前设置为滤镜…', 'preset-manage', 'save', { icon: 'plus' })}
            ${btn('导入 Lightroom / Camera Raw 预设…', 'preset-import', '', { icon: 'import' })}
            ${btn('导出原生预设…', 'preset-manage', 'export', { icon: 'export' })}
          </div></details>
        </div>
      </div>
      ${expanded ? `<div class="filter-panel-content"><div class="film-strength">${nativeHDR ? '<p class="muted">HDR 草稿可浏览收藏与目录。滤镜强度和外观采用需要 SDR 编辑。</p>' : rangeRow('filmAmount', '滤镜强度', 0, 100, 1, recipe.filmAmount ?? 100, !filmAmountEnabled || !available)}
        ${!nativeHDR && !filmAmountEnabled ? '<p class="muted">采用支持强度的滤镜后可调整</p>' : !enabled ? '<p class="muted">滤镜已关闭，已保留选择与强度。</p>' : ''}</div>
      <div class="preset-search"><label class="search-box">${icon('search')}<input aria-label="查找预设" name="presetQuery" placeholder="查找预设" value="${h(S.presetQuery)}"></label>
      ${btn('仅显示收藏', 'favorite-only', '', { icon: 'star', only: true, pressed: !!S.favoriteOnly, cls: 'icon-btn' })}</div>
      ${filterDirectory(recipe)}</div>` : ''}</section>
    <section aria-labelledby="snapshot-heading"><div class="row between"><h2 id="snapshot-heading">快照</h2><div class="snapshot-actions">${btn('存储快照', 'snapshot', '', { icon: 'plus', only: true, cls: 'icon-btn' })}<details class="snapshot-menu results-menu"><summary aria-label="更多快照操作">${icon('ellipsis',15)}</summary><div>${btn('已有编辑结果…','open-versions')}</div></details></div></div>
      <div class="snapshot-list">${e.snapshots.map((x, i) => snapshotBranch(x) !== (SceneEditor.hdr() ? 'hdr' : 'sdr') ? '' : `<div class="preset-item">
        ${btn(x.name, 'restore-snap', i, { icon: 'photo', cls: 'sidebar-row' })}
        <details class="snapshot-menu"><summary aria-label="管理快照 ${h(x.name)}">${icon('menu', 14)}</summary><div>
        ${btn('重命名…', 'rename-snap', i)}${btn('删除', 'delete-snap', i)}</div></details></div>`).join('') || '<p class="muted">尚无快照</p>'}</div></section>
    <section aria-labelledby="history-heading"><div class="row between"><h2 id="history-heading">历史</h2><div class="row">
      ${btn(S.canvasTool?'撤销草案':'撤销', 'edit-step', 'undo', { icon: 'undo', only: true, cls: 'icon-btn', disabled: !(S.canvasTool ?? e).past.length })}${btn(S.canvasTool?'重做草案':'重做', 'edit-step', 'redo', { icon: 'undo', only: true, cls: 'icon-btn redo', disabled: !(S.canvasTool ?? e).future.length })}</div></div>
      <ol class="edit-history">${e.past.map((p) => '<li>' + h(p.label) + '</li>').join('')}<li>初始状态</li></ol></section></div></aside>`;
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
  const defaults = adjustmentDefaults(id);
  const changed = Object.entries(defaults).some(([key, value]) => JSON.stringify(recipe[key] ?? value) !== JSON.stringify(value));
  const symbol = { light: 'spark', whiteBalance: 'background', color: 'mix', curves: 'curve', levels: 'pulse',
    optics: 'lens', repair: 'repair', grading: 'grading', lut: 'layers' }[id] || panelIcons[S.tool];
  return `<section class="adjustment-section" data-adjustment-section="${id}" data-photo-panel="${h(photoPanel)}">
    <div class="adjustment-header">
      <button type="button" class="adjustment-disclosure" data-act="adjustment-disclosure" data-val="${id}"
        aria-expanded="${open}" aria-controls="adjustment-body-${id}">${icon('chevron', 12)}${icon(symbol, 15)}<span>${h(title)}</span></button>
      ${btn('复位' + title, 'adjustment-reset', id, { icon: 'undo', only: true, cls: 'adjustment-reset', disabled: !changed })}
      <input type="checkbox" role="switch" aria-label="启用${h(title)}" title="启用／停用${h(title)}（保留数值）" name="adjustmentEnabled"
        data-key="${id}" data-title="${h(title)}"${enabled ? ' checked' : ''}>
    </div><fieldset id="adjustment-body-${id}"${open ? '' : ' hidden'}${enabled ? '' : ' disabled'}>${contents}</fieldset></section>`;
}
function adjustmentDefaults(id) {
  if (id === 'whiteBalance') return { warmth: 0, wbTemperature: null, tint: 0, wbApplied: 'original', wbPreset: '' };
  if (id === 'repair') return { repairs: [] };
  if (id === 'lut') return { lut: '无' };
  const section = adjustmentSections[S.tool].find(([key]) => key === id);
  const defaults = Studio.freshRecipe();
  return Object.fromEntries(section[2].map((key) => [key, defaults[key] ?? 0]));
}
actions['adjustment-disclosure'] = (id, _event, button) => {
  const panel = button.closest('[data-adjustment-section]').dataset.photoPanel;
  const open = button.getAttribute('aria-expanded') === 'false';
  const panels = (S.adjustmentDisclosure ??= new Map());
  if (!panels.has(panel)) panels.set(panel, new Map());
  panels.get(panel).set(id, open);
  button.setAttribute('aria-expanded', open);
  $('#adjustment-body-' + id).hidden = !open;
};
actions['adjustment-reset'] = (id, _event, button) => {
  adjustments(button.getAttribute('aria-label'), adjustmentDefaults(id));
  $(`.adjustment-disclosure[data-val="${id}"]`)?.focus({ preventScroll: true });
};
changes.adjustmentEnabled = (el) => adjustments('启停' + el.dataset.title, {
  sectionEnabled: { ...currentEdit().recipe.sectionEnabled, [el.dataset.key]: el.checked },
});
changes.detailOption = (el) => adjustments('启停' + el.closest('label').textContent, {
  detailOptions: { ...currentEdit().recipe.detailOptions, [el.dataset.key]: el.checked },
});
function toolFields(r) {
  if (S.tool === 'masks') return maskPanel(r);
  if (S.tool === 'repair')
    return adjustmentSection('repair', '修复',
      flatTabs('修复方式', 'repair-kind', ['移除','修复','仿制'].map(mode => [mode,mode]), S.repairKind || '修复') +
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
  const available = Studio.asset(Studio.data.work).online;
  const detail = r.detailOptions ?? {};
  const detailOptions = S.tool === 'detail' ? `<section class="detail-options" aria-label="细节处理">
    <div class="inspector-text-group">${check('AI 降噪', 'detailOption', detail.aiDenoise, {key:'aiDenoise', disabled:!available || !!detail.rawDetails})}
      <p class="control-hint">可用于支持的马赛克 RAW 和系统能解码的 RGB 照片。</p></div>
    <div class="inspector-text-group">${check('RAW 细节', 'detailOption', detail.rawDetails, {key:'rawDetails', disabled:!available || !wbIsRaw() || !!detail.aiDenoise})}
      <p class="control-hint">Bayer · AHD · 保持原始分辨率</p></div>
    <div class="inspector-text-group">${check('超分辨率 2×', 'detailOption', detail.superResolution, {key:'superResolution', disabled:!available})}
      <p class="control-hint">示例演示启停与撤销；真实处理能力以原生源与模型状态为准。</p></div></section>` : '';
  return detailOptions + adjustmentSections[S.tool].map(([id, title, fields], i) => {
    const content = id === 'whiteBalance' ? whiteBalancePanel(r) : id === 'lut'
      ? select('查找表', 'lut', ['无', '柔和胶片', '冷调'], r.lut || '无')
      : (id === 'curves' ? toneCurve(r) : '') + fields.map((key) => {
        const [k, n, lo = -100, hi = 100, step = 1] = controls.find(([k]) => k === key);
        return rangeRow(k, n, lo, hi, step, r[k] ?? 0);
      }).join('');
    return adjustmentSection(id, title, content, i === 0, r);
  }).join('') + (S.tool === 'detail' ? btn('增强细节…', 'enhance') : '');
}
const wbModes = [['temperature', '色温与色调'], ['gray', '中性灰'], ['skin', '肤色']];
const wbPresets = [['', '选择 RAW 光源预设…'], ['daylight', '日光'], ['cloudy', '阴天'], ['shade', '阴影'],
  ['tungsten', '白炽灯'], ['fluorescent', '荧光灯'], ['flash', '闪光灯']];
const wbTargets = { daylight: [5500, 10], cloudy: [6500, 10], shade: [7500, 10], tungsten: [2850, 0], fluorescent: [4000, 20], flash: [6000, 0] };
const wbIsRaw = () => /\.(dng|cr[23]|nef|arw|raf|rw2|orf)$/i.test(Studio.asset(Studio.data.work).name);
const wbMode = (r) => S.wbMode?.id === Studio.data.work ? S.wbMode.mode : (!r.wbApplied || r.wbApplied === 'original' ? 'temperature' : r.wbApplied);
const wbModeName = (mode) => wbModes.find(([key]) => key === mode)?.[1];
const maskGroupOpen = (key) => (S.maskGroups?.has(key) ?? (key === 'light')) ? ' open' : '';
function whiteBalancePanel(r) {
  const raw = wbIsRaw(), mode = wbMode(r), available = Studio.asset(Studio.data.work).online;
  const armed = S.canvasSelection?.kind === 'wb' && S.canvasSelection.id === Studio.data.work;
  const applied = r.wbApplied ?? 'original';
  const status = r.sectionEnabled?.whiteBalance === false ? '白平衡调整已关闭，已保留数值' :
    applied === 'original' ? (raw ? '当前：拍摄白平衡' : '当前：原有白平衡') : '当前：' + (wbPresets.find(([key]) => key && key === r.wbPreset)?.[1] ?? wbModeName(applied));
  return `<div class="wb-panel">
    <div class="wb-correction">${select('校正方式', 'wbMode', wbModes, mode)}
    <div class="wb-actions">${btn(mode === 'temperature' ? '自动白平衡' : '自动找' + wbModeName(mode), 'wb-auto', mode, {disabled: !available})}
      ${mode === 'temperature' ? btn('恢复原照', 'wb-original', '', {disabled: applied === 'original'}) : btn(armed ? '取消取样' : '在照片上取样', 'wb-pick', mode, {pressed: armed, disabled: !available})}</div>
    ${raw && mode === 'temperature' ? select('光源预设（近似）', 'wbPreset', wbPresets, r.wbPreset || '') : ''}
    <p class="control-hint" role="status">${status}</p>
    ${armed ? `<p class="control-hint">点选${mode === 'skin' ? '清晰的肤色' : '亮度适中的灰或白色'}，或按 Escape 取消。</p>` : ''}</div>
    <div class="wb-refinement"><h3 class="control-heading">微调</h3><div class="inspector-control-stack">
    ${mode === 'temperature' ? rangeRow('wbTemperature', raw ? '色温 K' : '色温（近似）', raw ? 2000 : -100, raw ? 50000 : 100, 1, r.wbTemperature ?? (raw ? 5500 : 0), !available) + rangeRow('tint', '色调', -150, 150, 1, r.tint ?? 0, !available)
      : applied === mode ? rangeRow('warmth', '暖色', -100, 100, 1, r.warmth ?? 0, !available) : '<p class="control-hint">自动分析或在照片上取样后，即可微调暖色。</p>'}</div></div>
  </div>`;
}
function flatTabs(title, action, options, current, icons = {}) {
  return `<div class="flat-tabs" role="group" aria-label="${h(title)}">${options.map(([value, label]) => btn(label, action, value, {pressed: value === current, icon: icons[value]})).join('')}</div>`;
}
document.addEventListener('keydown', (event) => {
  if (!['ArrowLeft', 'ArrowRight'].includes(event.key) || event.defaultPrevented) return;
  const button = event.target.closest('.flat-tabs button');
  if (!button) return;
  event.preventDefault();
  const tabs = [...button.parentElement.querySelectorAll('button:not(:disabled)')];
  tabs[tabs.indexOf(button) + (event.key === 'ArrowLeft' ? -1 : 1)]?.click();
});
function colorSamplerPoints() {
  return Studio.data.colorSamplers?.[Studio.data.work] ?? [];
}
function samplerRGB(point) {
  const current = $('.developed');
  if (!Studio.asset(Studio.data.work).online || !current) return null;
  if (current.complete && current.naturalWidth) S.samplerImage = {src:current.src, image:current};
  const image = current.complete && current.naturalWidth ? current : S.samplerImage?.src === current.src ? S.samplerImage.image : null;
  if (!image) return null;
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const context = canvas.getContext('2d', {willReadFrequently:true});
  context.filter = RMPhotos.filter(RMPhotos.displayLook(currentEdit().recipe));
  context.drawImage(image, Math.min(image.naturalWidth - 1, Math.floor(point.x * image.naturalWidth / 100)),
    Math.min(image.naturalHeight - 1, Math.floor(point.y * image.naturalHeight / 100)), 1, 1, 0, 0, 1, 1);
  return [...context.getImageData(0, 0, 1, 1).data].slice(0, 3);
}
function colorSamplerPanel() {
  const points = colorSamplerPoints(), available = Studio.asset(Studio.data.work).online;
  const armed = S.canvasSelection?.id === Studio.data.work && S.canvasSelection.kind === 'sampler';
  return `<section class="sampler-panel" aria-label="颜色采样点">
    ${btn('添加颜色采样点', 'sampler-pick', '', {icon:'sampler', disabled:!available || points.length >= 9 || !!S.compare || !!S.cropOpen})}
    ${armed ? '<p class="control-hint" role="status">在照片上点选颜色，或按 Escape 取消。</p>' : ''}
    <ol class="sampler-list">${points.map((point, i) => {
      const rgb = samplerRGB(point);
      return `<li class="sampler-row${rgb ? '' : ' outside'}" data-sampler="${i}">
        <span class="sampler-swatch" aria-hidden="true"${rgb ? ` style="--sample-color:rgb(${rgb.join(',')})"` : ''}></span>
        <span class="sampler-readout"><strong>${i + 1}</strong>　${rgb ? `R ${rgb[0]}　G ${rgb[1]}　B ${rgb[2]}` : '当前画面外'}</span>
        <details class="sampler-manage"><summary aria-label="编辑采样点 ${i + 1}">${icon('menu', 14)}</summary><div>
          ${btn('重新取样', 'sampler-pick', i, {icon:'sampler', disabled:!available || !!S.compare || !!S.cropOpen})}
          ${btn('移除采样点', 'sampler-remove', i, {icon:'trash'})}</div></details></li>`;
    }).join('')}</ol></section>`;
}
function refreshSamplerPanel() {
  const panel = $('.sampler-panel');
  if (panel) panel.outerHTML = colorSamplerPanel();
}
document.addEventListener('load', event => {
  if (event.target.matches?.('.developed')) refreshSamplerPanel();
}, true);
actions['sampler-pick'] = (index) => {
  if (!Studio.asset(Studio.data.work).online || S.compare || S.cropOpen) return;
  if (sheet.open) closeSheet();
  S.canvasSelection = {id:Studio.data.work, kind:'sampler', replacing:index === '' ? null : Number(index)};
  render(); $('[data-act=sampler-pick]')?.focus({preventScroll:true});
};
actions['sampler-remove'] = (index) => {
  (Studio.data.colorSamplers ??= {})[Studio.data.work] = colorSamplerPoints().filter((_, i) => i !== Number(index));
  S.canvasSelection = null; Studio.save(); render(); $('[data-act=sampler-pick]')?.focus({preventScroll:true});
};
function scopesPanel(docked) {
  const mode = S.scopePlot ?? 'histogram';
  const plots = [['histogram', '直方图'], ['vector', '矢量示波器']];
  const vector = `<svg class="vector-plot" viewBox="0 0 120 48" role="img" aria-label="矢量分布示意"><g fill="none" stroke="#52616a"><circle cx="60" cy="24" r="16"/><circle cx="60" cy="24" r="8"/><path d="M44 24h32m-16-16v32"/></g><path fill="#aab8bd" opacity=".6" d="M52 28l7-11 9 3 4 5-10 6z"/><path stroke="#ffbb80" stroke-dasharray="2 2" d="M60 24l11-12"/></svg>`;
  return `<section class="editing-scopes${docked ? ' docked' : ''}"><div class="row">${flatTabs('示波器', 'scope-plot', plots, mode)}${docked ? btn('在独立窗口显示示波器', 'scopes', '', {icon:'pulse', only: true, cls:'icon-btn'}) : ''}</div>
    ${mode === 'vector' ? vector : SceneEditor.hdr() ? SceneEditor.rgbPlot() : `<div${docked ? ' class="tone-control" title="左右拖动色调区域调整亮度"' : ''}>${histogram(Studio.data.work)}</div>`}
    ${colorSamplerPanel()}</section>`;
}
const maskTools = [['主体', '背景', '前景实例', '画笔'], ['线性渐变', '径向渐变', '亮度范围']];
const maskToolIcons = { '主体':'subject', '背景':'maskBackground', '前景实例':'instance', '画笔':'brush', '线性渐变':'linearMask', '径向渐变':'radialMask', '亮度范围':'rangeMask' };
function maskPanel(r) {
  const m = activeLayer(r), i = r.masks.indexOf(m), draft = S.canvasSelection?.id === Studio.data.work ? S.canvasSelection : null;
  const candidate = draft?.kind === 'mask' && draft.candidate;
  const drawing = draft?.kind === 'mask' && !candidate;
  const unavailable = !Studio.asset(Studio.data.work).online;
  const semantic = m && maskTools[0].includes(m.kind);
  return `<section class="mask-panel" aria-label="蒙版">
    <details class="mask-create"><summary>${icon('plus')} 新建蒙版</summary><div class="mask-tools">
      <h3 class="control-heading">自动与画笔</h3><div class="mask-tool-grid">${maskTools[0].map(k => btn(k, 'add-mask', k, {disabled: unavailable, pressed: draft?.type === k, icon: maskToolIcons[k]})).join('')}</div>
      <h3 class="control-heading">几何与范围</h3><div class="mask-tool-grid">${maskTools[1].map(k => btn(k, 'add-mask', k, {disabled: unavailable, pressed: draft?.type === k, icon: maskToolIcons[k]})).join('')}</div>
      <p class="control-hint">可用的 AI 工具随本机模型包而定。</p></div></details>
    ${unavailable ? '<p class="control-hint">原片离线，无法在画布上创建蒙版。</p>' : ''}
    ${drawing ? `<div class="mask-stage" role="status"><p>${draft.type === '前景实例' ? '在照片上点选前景实例。' : '在照片上拖动以确定选取范围。'}</p>${btn('取消', 'cancel-selection', '', {icon:'close'})}</div>` : ''}
    ${candidate ? `<div class="mask-stage"><h3 class="control-heading">${h(draft.type)}选区 · 示例预览</h3><div class="wb-actions">${btn('显示蒙版叠加', 'mask-overlay', '', {pressed: draft.overlay !== false, icon:'overlay'})}</div>
      ${flatTabs('精修画笔', 'mask-brush', [['add', '添加画笔'], ['subtract', '减去画笔']], draft.brush, {add:'plus', subtract:'minus'})}
      <div class="mask-actions">${btn('采用选区', 'mask-adopt', '', {icon:'check', cls:'primary', disabled: draft.review != null && !draft.changed})}${btn('关闭', 'cancel-selection', '', {icon:'close'})}</div></div>` : ''}
    <div class="mask-stack"><h3 class="control-heading">图层 <span>${r.masks.length}</span></h3>
    ${r.masks.map((item, index) => `<div class="mask-layer${m === item ? ' selected' : ''}">${btn((item.name || item.kind) + ' ' + (index + 1), 'choose-mask', index, {icon:maskToolIcons[item.kind] || 'mask', pressed: m === item})}${btn(item.on === false ? '启用图层' : '停用图层', 'toggle-mask', index, {icon:item.on === false ? 'eyeOff' : 'eye', only:true, pressed: item.on !== false})}</div>`).join('') || '<p class="control-hint">还没有蒙版。新建选区后，只调整照片中该区域。</p>'}</div>
    ${m && !drawing && !candidate ? `<div class="mask-adjustments"><div class="row between"><h3>${h(m.name || m.kind)}</h3><details class="mask-manage"><summary aria-label="管理选中蒙版">${icon('menu')}</summary><div>
      ${btn('上移', 'mask-op', 'up', {icon:'arrowUp', disabled: i === 0})}${btn('下移', 'mask-op', 'down', {icon:'arrowDown', disabled: i === r.masks.length - 1})}${btn('删除图层', 'mask-op', 'delete', {icon:'trash'})}</div></details></div>
      ${semantic ? btn('查看与修正选区', 'mask-review', '', {icon:'edit', disabled: unavailable}) : ''}
      <details class="mask-group" data-mask-group="region"${maskGroupOpen('region')}><summary>选区</summary>${btn('反转蒙版', 'mask-op', 'invert', {pressed: !!m.invert, icon:'invert'})}${rangeRow('opacity', '不透明度', 0, 100, 1, m.opacity ?? 100)}${!semantic ? rangeRow('feather', '羽化', 0, 100, 1, m.feather ?? 45) : ''}
      ${m.kind === '亮度范围' ? rangeRow('rangeLower', '范围下限', 0, 99, 1, m.rangeLower ?? 25) + rangeRow('rangeUpper', '范围上限', 1, 100, 1, m.rangeUpper ?? 75) : ''}</details>
      <details class="mask-group" data-mask-group="light"${maskGroupOpen('light')}><summary>光效</summary>${rangeRow('localEV', '曝光', -2, 2, 0.05, m.localEV ?? 0)}${rangeRow('localHighlight', '高光', -100, 100, 1, m.localHighlight ?? 0)}${rangeRow('localShadow', '阴影', -100, 100, 1, m.localShadow ?? 0)}</details>
      <details class="mask-group" data-mask-group="color"${maskGroupOpen('color')}><summary>颜色</summary>${rangeRow('localSat', '饱和度', -100, 100, 1, m.localSat ?? 0)}</details>
      <details class="mask-group" data-mask-group="effects"${maskGroupOpen('effects')}><summary>效果</summary>${rangeRow('localTexture', '纹理', -100, 100, 1, m.localTexture ?? 0)}</details>
      <details class="mask-group" data-mask-group="detail"${maskGroupOpen('detail')}><summary>细节</summary>${rangeRow('localSharp', '锐化', -100, 100, 1, m.localSharp ?? 0)}</details></div>` : ''}
  </section>`;
}
function developInspector(r) {
  return `<div class="row between"><h2>${editTools[S.tool][0]}</h2></div>
    ${toolFields(r)}
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
    .filter(([key]) => dagCapabilities().includes(key) || key === 'smart' && !dagEnabled())
    .map(([key, symbol]) =>
      `<button type="button" class="rail-tool" data-act="edit-tool" data-val="${key}"
        aria-label="${h(editTools[key][0])}"${S.canvasTool ? ' disabled' : ''} aria-controls="adjustment-panel" aria-pressed="${active === key}">${icon(symbol)}</button>`,
    )
    .join('')}</div>`;
}
function showRailTip(button) {
  const tip = $('.rail-tip');
  if (!tip || !button) return;
  tip.textContent = button.getAttribute('aria-label');
  tip.hidden = false;
  tip.classList.remove('rail-tip-stacked');
  const box = button.getBoundingClientRect();
  const width = tip.offsetWidth, height = tip.offsetHeight;
  const fitsLeft = box.left >= width + 15;
  const rail = button.closest('.inspector-rail').getBoundingClientRect();
  tip.classList.toggle('rail-tip-stacked', !fitsLeft);
  const stackedHeight = tip.offsetHeight;
  const above = !fitsLeft && box.top >= stackedHeight + 14;
  tip.dataset.side = fitsLeft ? 'left' : above ? 'above' : 'below';
  tip.style.left = `${fitsLeft ? box.left - width - 10 : rail.left + (rail.width - tip.offsetWidth) / 2}px`;
  const top = fitsLeft ? box.top + (box.height - height) / 2 : above ? box.top - stackedHeight - 10 : box.bottom + 10;
  const y = Math.max(4, Math.min(top, innerHeight - stackedHeight - 4));
  if (box.bottom <= 0 || box.top >= innerHeight || (!fitsLeft && (above ? y + stackedHeight + 6 > box.top : y - 6 < box.bottom))) { tip.hidden = true; return; }
  tip.style.top = `${y}px`;
  tip.style.setProperty('--tip-arrow-y', `${Math.max(5, Math.min(box.top + box.height / 2 - y, stackedHeight - 5))}px`);
}
function hideRailTip() {
  const tip = $('.rail-tip');
  if (tip) tip.hidden = true;
}
document.addEventListener('pointerover', (event) => {
  const button = event.target.closest('.rail-tool');
  if (button && !button.contains(event.relatedTarget)) showRailTip(button);
});
document.addEventListener('pointerout', (event) => {
  const button = event.target.closest('.rail-tool');
  if (button && !button.contains(event.relatedTarget)) hideRailTip();
});
document.addEventListener('focusin', (event) => {
  if (event.target.matches('.rail-tool:focus-visible')) showRailTip(event.target);
});
document.addEventListener('focusout', (event) => {
  if (event.target.matches('.rail-tool')) hideRailTip();
});
document.addEventListener('scroll', hideRailTip, true);
window.addEventListener('resize', hideRailTip);
window.addEventListener('blur', hideRailTip);
function savedResultsSheet() {
  const e = currentEdit(),
    rows = [{ id: 'original', name: '原始版本', recipe: Studio.freshRecipe() }, ...e.versions].reverse();
  const selected = S.versionView || e.adopted, item = rows.find(v=>v.id===selected);
  const preview = pic(Studio.data.work,'',`style="filter:${h(RMPhotos.filter(RMPhotos.displayLook(RMSceneOutput.sdrPreview(item?.recipe || Studio.freshRecipe()))))}"`);
  dialog('已有编辑结果',`<figure class="result-preview"><div>${preview}${quickCanvasEffect(Studio.data.work,item?.recipe || Studio.freshRecipe(),selected)}</div><figcaption>${h(item?.name || '原片')}</figcaption></figure>
    ${e.versions.length ? '' : '<p class="muted">当前照片还没有已保存的编辑结果。</p>'}<div class="results-list">${rows
    .map((v) => {
      const issue = v.quickPrompt ? quickAdoptionIssue(quickJobForVersion(v.id)) : '';
      const adopt = v.id !== e.adopted && !v.discarded ? btn('采用此结果', 'adopt', v.id, { disabled: !!issue, title: issue || '采用此结果' }) : '';
      return `<div class="version-row"><strong>${h(v.name)}</strong><small>${v.id === e.adopted ? '当前采用' : v.discarded ? '已放弃' : v.retained ? '已保留' : '候选'}</small><div class="row wrap">
      ${btn('查看', 'inspect-version', v.id, { pressed: (S.versionView || e.adopted) === v.id })}${adopt}${v.quickPrompt ? '' : btn('从此继续', 'continue-version', v.id)}${btn('导出此版本…', 'version-export', v.id, { disabled: !!v.discarded || (v.quickPrompt && e.conversation?.strict) })}
      ${v.id !== 'original' && v.id !== e.adopted ? btn(v.discarded ? '恢复' : '放弃', 'discard-version', v.id, { cls: 'link' }) + (!v.retained ? btn('保留', 'retain-version', v.id, { cls: 'link' }) : '') : ''}</div>
      ${issue ? '<small>' + h(issue) + '</small>' : ''}</div>`;
    })
    .join('')}
    </div>`,btn('关联外部编辑副本…','external') + btn('返回编辑','return-adjustments','',{cls:'primary'}));
  sheet.dataset.savedResults=Studio.data.work;
}
function versionRecipe(id) {
  return currentEdit().versions.find((v) => v.id === id)?.recipe ?? Studio.freshRecipe();
}
const narrowEditor = matchMedia('(max-width:860px)');
narrowEditor.addEventListener('change', () => {
  if (S.page === 'edit') render();
});
function editorView() {
  if (S.canvasRouteTool) { const tool = S.canvasRouteTool; S.canvasRouteTool = null; queueMicrotask(() => { if (S.page === 'edit' && !S.canvasTool) canvasToolOpen(tool); }); }
  const id = Studio.data.work,
    e = currentEdit(),
    versions = S.tool === 'versions';
  const r = canvasToolPreview(versions ? versionRecipe(S.versionView || e.adopted) : e.recipe);
  if (dagEnabled() && !S.canvasTool && !versions && !['smart','agent'].includes(S.tool) && !dagCapabilities().includes(S.tool)) S.tool = dagCapabilities()[0] || 'basic';
  const sceneReview = SceneEditor.nativeReview && SceneEditor.hdr() && S.tool === 'basic' && !dagEnabled() && !S.canvasTool;
  const inspector = sceneReview ? SceneEditor.reviewInspector() : S.canvasTool ? '<h2>画布工具已展开</h2><p>在照片底部完成或取消草案后，继续编辑当前节点。节点参数不会被工具草案覆盖。</p>' : !versions && dagEnabled() && !['smart', 'agent'].includes(S.tool)
    ? dagInspector()
    : S.tool === 'agent'
      ? agentInspector()
      : S.tool === 'smart'
        ? smartInspector()
        : developInspector(r);
  const left = presetList();
  const sceneTool = SceneEditor.toolNote();
  const canvas = `<div class="edit-center">${dagPhotoCanvas(r, id)}${editorNotices(id)}</div>`;
  const basic = S.tool === 'basic' && !S.canvasTool;
  const sceneControls = basic ? scopesPanel(true) + SceneEditor.modeBar() + (SceneEditor.hdr() ? `<details class="scope-native-review" ${SceneEditor.scopeOpen() ? 'open' : ''}><summary>HDR 示波器与诊断</summary>${SceneEditor.scope(true)}</details>` : '') : '';
  const right = `<div class="edit-right">${versions ? '' : compatibilityGraphMode ? compatibilityGraphToolbar() : dagToolbar()}
    <aside class="edit-inspector" aria-label="调整工具">${inspectorRail()}
    <div class="inspector-content${versions || ['smart', 'agent'].includes(S.tool) ? '' : ' manual-inspector'}" id="adjustment-panel" tabindex="-1">` +
    sceneControls + (sceneTool ? `<p class="control-hint">${h(sceneTool)}</p><fieldset class="scene-tool-controls" disabled>${inspector}</fieldset>` : inspector) +
    '</div></aside></div>';
  return `<div class="edit-page" data-photo="${h(id)}"><header class="edit-head"><div class="edit-identity">${btn('返回资料库', 'goto', 'library/' + S.scope, { icon: 'previous', only: true, cls: 'icon-btn' })}
      <strong>${h(Studio.displayName(id))}</strong>${SceneEditor.badge()}<span class="muted">${versions ? '查看版本' : Studio.dirty(id) ? '草稿有调整' : '当前照片'}</span></div>
</header>
    <div class="edit-body" style="--ground:${grounds[Studio.data.prefs.ground] ?? grounds.深灰}">${narrowEditor.matches ? canvas + right + left : left + canvas + right}</div>${compatibilityGraphMode ? compatibilityGraphWindow() : dagFloatingWindow()}<div class="rail-tip" aria-hidden="true" hidden></div></div>`;
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
actions['open-versions'] = requested => {
  const menu = $('.results-menu');
  S.beforeResultsFocus = quickPromptVisible() && requested ? '[data-act=quick-inspect-version]' : '.results-menu summary';
  if (menu) menu.open=false;
  $(S.beforeResultsFocus)?.focus({preventScroll:true});
  S.versionView = currentEdit().versions.some(v=>v.id===requested) ? requested : currentEdit().adopted;
  savedResultsSheet();
};
actions['return-adjustments'] = () => { closeSheet(); $(S.beforeResultsFocus || '.results-menu summary')?.focus({preventScroll:true}); };
actions['edit-step'] = (v) => {
  if (S.tool === 'versions') return;
  Studio.stepEdit(Studio.data.work, v === 'redo');
  render();
};
actions['inspect-version'] = (id) => {
  S.versionView = id;
  savedResultsSheet();
};
actions.adopt = (id) => {
  if (currentEdit().versions.find((v) => v.id === id)?.quickPrompt) {
    if (!applyQuickVersion(id)) return;
  } else currentEdit().adopted = id;
  S.versionView = id;
  currentEdit().adoptionBaseline = JSON.stringify(currentEdit().recipe);
  Studio.save();
  render();
  savedResultsSheet();
  notify('已采用此结果');
};
actions['discard-version'] = (id) => {
  const v = currentEdit().versions.find((x) => x.id === id);
  v.discarded = !v.discarded;
  Studio.save();
  savedResultsSheet();
};
actions['retain-version'] = (id) => {
  currentEdit().versions.find((x) => x.id === id).retained = true;
  Studio.save();
  savedResultsSheet();
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
  savedResultsSheet();
  notify('已关联为独立候选');
};
function adjusted(el) {
  const r = structuredClone(currentEdit().recipe),
    k = el.dataset.key;
  if (['opacity', 'feather', 'localEV', 'localHighlight', 'localShadow', 'localSat', 'localTexture', 'localSharp', 'rangeLower', 'rangeUpper'].includes(k)) {
    const m = activeLayer(r);
    if (m) {
      m[k] = Number(el.value);
      if (k === 'rangeLower') m[k] = Math.min(m[k], (m.rangeUpper ?? 75) - 1);
      if (k === 'rangeUpper') m[k] = Math.max(m[k], (m.rangeLower ?? 25) + 1);
    }
  } else {
    r[k] = Number(el.value);
    if (k === 'filmAmount' && r.filmStock) r.filmEnabled = true;
    if (['wbTemperature','tint','warmth'].includes(k)) { r.wbApplied = k === 'warmth' ? wbMode(r) : 'temperature'; r.wbPreset = ''; }
  }
  return r;
}
inputs.adjust = (el) => {
  const row = el.closest('.range');
  row.querySelector('[name=adjustNumber]').value = el.value;
  row.style.cssText = rangeFill(Number(el.value), Number(el.min), Number(el.max));
  paintEditPreview(adjusted(el));
};
changes.adjust = (el) => {
  if (S.canvasTool) return canvasToolPatch(el.dataset.label, adjusted(el));
  Studio.setRecipe(Studio.data.work, el.dataset.label, adjusted(el));
  render();
};
let numericPointer = null, deferredNumericRender = null;
document.addEventListener('pointerdown', (event) => {
  const field = document.activeElement;
  if (field.name === 'adjustNumber' && event.target !== field && event.isPrimary)
    numericPointer = event.pointerId;
}, true);
for (const type of ['pointerup', 'pointercancel', 'blur']) {
  window.addEventListener(type, (event) => {
    if (numericPointer == null || (type !== 'blur' && event.pointerId !== numericPointer)) return;
    numericPointer = null;
    if (deferredNumericRender) requestAnimationFrame(deferredNumericRender);
    deferredNumericRender = null;
  });
}
changes.adjustNumber = (el) => {
  if (el.value === '' || !el.validity.valid) {
    el.setAttribute('aria-invalid', 'true');
    return;
  }
  const row = el.closest('.range'), slider = row.querySelector('[name=adjust]'), value = el.valueAsNumber;
  const recipe = adjusted({ dataset: slider.dataset, value });
  if (S.canvasTool) canvasToolPatch(slider.dataset.label, recipe, false);
  else Studio.setRecipe(Studio.data.work, slider.dataset.label, recipe);
  el.defaultValue = el.value;
  el.removeAttribute('aria-invalid');
  slider.value = String(value);
  row.style.cssText = rangeFill(value, Number(slider.min), Number(slider.max));
  paintEditPreview(recipe);
  // Replacing the panel during native blur drops the pending Tab focus or pointer click.
  const refresh = () => { if (el.isConnected) render(); };
  if (numericPointer == null) requestAnimationFrame(refresh);
  else deferredNumericRender = refresh;
};
document.addEventListener('keydown', (event) => {
  const field = event.target;
  if (field.name !== 'adjustNumber' || event.isComposing) return;
  if (event.key === 'Escape') {
    field.value = field.defaultValue;
    field.removeAttribute('aria-invalid');
    event.stopPropagation();
  } else if (event.key === 'Enter') {
    event.preventDefault();
    if (field.value !== '' && field.validity.valid) field.blur();
    else field.setAttribute('aria-invalid', 'true');
  }
});
document.addEventListener('pointerdown', (event) => {
  const slider = event.target.closest('input[name=adjust]');
  if (!slider || slider.matches(':disabled') || event.button !== 0 || !event.isPrimary) return;
  event.preventDefault();
  slider.focus();
  if (!slider.isConnected) return;
  const number = slider.closest('.range').querySelector('[name=adjustNumber]');
  const origin = Number(number.defaultValue), initial = event.clientX, photo = Studio.data.work;
  const low = Number(slider.min), high = Number(slider.max), step = Number(slider.step);
  let moved = false;
  slider.setPointerCapture(event.pointerId);
  function move(e) {
    const delta = e.clientX - initial;
    if (!moved && Math.abs(delta) < 2) return;
    moved = true;
    slider.value = String(Math.max(low, Math.min(high, low + Math.round((origin - low + delta / 200 * (high - low)) / step) * step)));
    if (delta === 0) {
      number.value = String(origin);
      slider.closest('.range').style.cssText = rangeFill(origin, low, high);
      paintEditPreview(currentEdit().recipe);
    } else inputs.adjust(slider);
  }
  function finish(e) {
    slider.removeEventListener('pointermove', move);
    slider.removeEventListener('pointerup', finish);
    slider.removeEventListener('lostpointercapture', finish);
    delete slider.dataset.dragging;
    if (!moved || !slider.isConnected || Studio.data.work !== photo) return;
    if (e.type === 'pointerup' && Number(number.value) !== origin) changes.adjust(slider);
    else render();
  }
  slider.dataset.dragging = 'true';
  slider.addEventListener('pointermove', move);
  slider.addEventListener('pointerup', finish);
  slider.addEventListener('lostpointercapture', finish);
});
document.addEventListener('dblclick', (event) => {
  const slider = event.target.closest('input[name=adjust]');
  if (!slider || slider.matches(':disabled')) return;
  const number = slider.closest('.range').querySelector('[name=adjustNumber]');
  if (Number(number.defaultValue) === Number(slider.dataset.default)) return;
  slider.value = slider.dataset.default;
  changes.adjust(slider);
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
    '<p>恢复初始参数。已保存的版本可在「已有编辑结果」中查看。</p>',
    btn('取消', 'close') + btn('复位调整', 'confirm-reset'),
  );
actions['confirm-reset'] = () => {
  closeSheet();
  Studio.setRecipe(Studio.data.work, '复位调整', Studio.freshRecipe());
  render();
};
actions.scopes = () => dialog('颜色示波器', scopesPanel(false) + (SceneEditor.hdr() ? '' : '<p>直方图取自示例 JPEG；矢量图为示意。</p>'), btn('完成', 'close'));
actions['scope-plot'] = (mode, _event, button) => {
  S.scopePlot = mode;
  const detached = button.closest('dialog');
  if (detached) button.closest('.editing-scopes').outerHTML = scopesPanel(false);
  else render();
  (detached || document).querySelector(`[data-act="scope-plot"][data-val="${mode}"]`)?.focus({ preventScroll: true });
};
changes.wbMode = (el) => {
  S.canvasSelection = null;
  S.wbMode = {id: Studio.data.work, mode: el.value};
  render(); $('[name=wbMode]')?.focus({preventScroll:true});
};
changes.wbPreset = (el) => {
  const target = wbTargets[el.value];
  if (!target) return;
  adjustments('白平衡光源预设', {wbApplied:'temperature', wbPreset:el.value, wbTemperature:target[0], tint:target[1]});
  $('[name=wbPreset]')?.focus({preventScroll:true});
};
actions['wb-original'] = () => adjustments('恢复原照白平衡', adjustmentDefaults('whiteBalance'));
actions['wb-auto'] = (mode) => {
  S.canvasSelection = null;
  adjustments('自动白平衡 · 示例', mode === 'temperature'
    ? {wbApplied:mode, wbPreset:'', wbTemperature:wbIsRaw() ? 5700 : 8, tint:3}
    : {wbApplied:mode, wbPreset:'', warmth:12});
};
actions['wb-pick'] = (mode) => {
  S.canvasSelection = S.canvasSelection?.kind === 'wb' ? null : {id:Studio.data.work,kind:'wb',type:mode};
  render(); $('[data-act=wb-pick]')?.focus({preventScroll:true});
};
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
function makeMask(kind, location = {x:50,y:50}) {
  S.canvasSelection = null;
  alterMasks('新建' + kind, (ms) => {
    S.selectedLayer = ms.length;
    ms.push({ kind, on: true, opacity: 100, feather: 45, localEV: 0, ...location });
  });
  $(`.mask-layer.selected [data-act=choose-mask]`)?.focus({preventScroll:true});
}
actions['add-mask'] = (kind) => {
  if (kind === '亮度范围') return makeMask(kind);
  S.canvasSelection = {id:Studio.data.work, kind:'mask', type:kind, candidate:['主体','背景','画笔'].includes(kind), x:50, y:50, brush:kind === '画笔' ? 'add' : null};
  render(); $('.mask-stage button')?.focus({preventScroll:true});
};
actions['choose-mask'] = (i) => {
  S.canvasSelection = null; S.selectedLayer = Number(i); render();
  $(`.mask-layer.selected [data-act=choose-mask]`)?.focus({preventScroll:true});
};
actions['toggle-mask'] = (i) => {
  S.canvasSelection = null;
  alterMasks('切换蒙版', (ms) => (ms[i].on = ms[i].on === false));
  $(`[data-act=toggle-mask][data-val="${i}"]`)?.focus({preventScroll:true});
};
actions['cancel-selection'] = () => {
  const kind = S.canvasSelection?.kind;
  S.canvasSelection = null; render();
  $(kind === 'wb' ? '[data-act=wb-pick]' : kind === 'sampler' ? '[data-act=sampler-pick]' : '.mask-create > summary')?.focus({preventScroll:true});
};
actions['mask-review'] = () => {
  const m = activeLayer(currentEdit().recipe);
  S.canvasSelection = {id:Studio.data.work,kind:'mask',type:m.kind,candidate:true,review:S.selectedLayer,x:m.x ?? 50,y:m.y ?? 50,strokes:[...(m.strokes || [])]};
  render(); $('.mask-stage button')?.focus({preventScroll:true});
};
actions['mask-overlay'] = () => { S.canvasSelection.overlay = S.canvasSelection.overlay === false; render(); $('[data-act=mask-overlay]')?.focus({preventScroll:true}); };
actions['mask-brush'] = (brush) => { S.canvasSelection.brush = brush; S.canvasSelection.overlay = true; render(); $(`[data-act=mask-brush][data-val="${brush}"]`)?.focus({preventScroll:true}); };
actions['mask-adopt'] = () => {
  const { type, x, y, review, changed, strokes } = S.canvasSelection;
  if (review == null) return makeMask(type, {x,y,strokes});
  if (!changed) return;
  S.canvasSelection = null;
  alterMasks('修正蒙版', (ms) => Object.assign(ms[review], {x,y,strokes}));
};
actions['mask-op'] = (op) => {
  alterMasks(op === 'delete' ? '删除蒙版' : '编辑蒙版', (ms) => {
    const i = ms.indexOf(activeLayer({ masks:ms }));
    if (i < 0) return;
    if (op === 'delete') { ms.splice(i, 1); S.selectedLayer = Math.max(0, i - 1); }
    else if (op === 'invert') ms[i].invert = !ms[i].invert;
    else {
      const next = i + (op === 'up' ? -1 : 1);
      if (ms[next]) { [ms[i], ms[next]] = [ms[next], ms[i]]; S.selectedLayer = next; }
    }
  });
  $(`.mask-layer.selected [data-act=choose-mask]`)?.focus({preventScroll:true});
};
actions['repair-kind'] = (mode) => { S.repairKind = mode; render(); };
function point(x, y) {
  if (S.tool === 'repair' && currentEdit().recipe.sectionEnabled?.repair === false) return;
  if (S.cropOpen || S.compare) return;
  const draft = S.canvasSelection;
  if (draft?.id === Studio.data.work && draft.kind === 'sampler' && S.tool === 'basic') {
    const points = [...colorSamplerPoints()], point = {x:Math.max(0, Math.min(100, x)), y:Math.max(0, Math.min(100, y))};
    if (draft.replacing == null) { if (points.length >= 9) return; points.push(point); }
    else { if (!points[draft.replacing]) return; points[draft.replacing] = point; }
    (Studio.data.colorSamplers ??= {})[Studio.data.work] = points;
    S.canvasSelection = null; Studio.save(); render(); $('[data-act=sampler-pick]')?.focus({preventScroll:true});
    return;
  }
  if (draft?.id === Studio.data.work && draft.kind === 'wb' && S.tool === 'basic') {
    S.canvasSelection = null;
    adjustments('白平衡取样 · 示例', {wbApplied:draft.type, wbPreset:'', warmth:Math.round((x - 50) * 0.4)});
  }
  if (draft?.id === Studio.data.work && draft.kind === 'mask' && S.tool === 'masks' && draft.type === '前景实例' && !draft.candidate) {
    Object.assign(draft, {x,y,candidate:true}); render();
  }
  if (S.tool === 'repair') {
    const repairs = structuredClone(currentEdit().recipe.repairs),
      last = repairs.at(-1);
    if (last?.kind === '仿制' && !last.source) last.source = { x, y };
    else repairs.push({ kind: S.repairKind || '修复', x, y });
    adjustments('修复取样', { repairs });
  }
}
document.addEventListener('pointerdown', (event) => {
  const image = event.target.closest('[data-act=canvas-point]'), draft = S.canvasSelection;
  if (!image || event.button !== 0 || S.tool !== 'masks' || draft?.id !== Studio.data.work || draft.kind !== 'mask') return;
  if (draft.candidate ? !draft.brush : draft.type === '前景实例') return;
  const box = image.getBoundingClientRect();
  const location = (e) => ({x: Math.max(0, Math.min(100, (e.clientX-box.left)*100/box.width)), y: Math.max(0, Math.min(100, (e.clientY-box.top)*100/box.height))});
  const start = location(event);
  image.setPointerCapture(event.pointerId);
  const cancel = () => { image.removeEventListener('pointerup', finish); };
  function finish(e) {
    image.removeEventListener('pointercancel', cancel);
    const end = location(e);
    if (S.canvasSelection !== draft || Math.hypot(event.clientX-e.clientX, event.clientY-e.clientY) < 4) return;
    if (draft.candidate) {
      (draft.strokes ??= []).push({...end, mode:draft.brush}); draft.changed = true; render();
    } else makeMask(draft.type, {...start, end});
  }
  image.addEventListener('pointerup', finish, {once:true});
  image.addEventListener('pointercancel', cancel, {once:true});
});
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape' || event.defaultPrevented || sheet.open || quickPromptVisible() || !S.canvasSelection) return;
  event.preventDefault(); actions['cancel-selection']();
});
actions['canvas-point'] = (_, event, el) => {
  if (SceneEditor.scopePick(event, el)) return;
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
  if (SceneEditor.hdr()) return notify('该预设尚未验证 HDR 母版运算。请使用支持的场景工具，或在单独的 SDR 版本中采用。', 'error');
  const p = Studio.data.presets.find((p) => p.name === name);
  adjustments('套用 ' + name, { ...p.values, preset: name });
};
actions['adaptive-preset'] = (key) => {
  if (SceneEditor.hdr()) return notify('当前版本的自适应预设适用于 SDR 编辑。', 'error');
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
  if (!Object.hasOwn(RMPhotos.filmStocks, key) || S.tool === 'versions' || SceneEditor.film(key) || currentEdit().recipe.filmStock === key) return;
  adjustments('胶片模拟 · ' + RMPhotos.filmStocks[key].name, { filmStock: key, filmAmount: 100, filmEnabled: true });
};
actions['filters-panel-toggle'] = () => { S.filtersExpanded = S.filtersExpanded === false; render(); };
actions['filter-enabled'] = () => {
  if (!Studio.asset(Studio.data.work).online || !currentEdit().recipe.filmStock) return;
  const enable = currentEdit().recipe.filmEnabled === false;
  adjustments(enable ? '启用滤镜' : '停用滤镜', { filmEnabled: enable });
};
actions['remove-film'] = () => {
  const { filmStock, filmAmount, filmEnabled, ...recipe } = currentEdit().recipe;
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
  img.style.filter = RMPhotos.filter(RMPhotos.displayLook(SceneEditor.preview(recipe)));
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
  if (SceneEditor.hdr() && el.dataset.act !== 'restore-snap') return;
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
  const menu = event.target.closest('.filter-options[open]');
  if (event.key === 'Escape' && menu) {
    menu.open = false; menu.querySelector('summary').focus(); event.preventDefault(); return;
  }
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
actions['preset-manage'] = (operation) => {
  const menu = $('.filter-options[open]');
  if (menu) { menu.open = false; menu.querySelector('summary').focus(); }
  dialog(
    '预设管理',
    field('预设名称', 'presetName', '我的调整') +
      select(
        '操作',
        'presetOperation',
        operation === 'import' ? ['导入 Lightroom / Camera Raw 预设'] : operation === 'export' ? ['导出原生预设'] : ['保存当前调整'],
        operation === 'import' ? '导入 Lightroom / Camera Raw 预设' : operation === 'export' ? '导出原生预设' : '保存当前调整',
      ) +
      (operation === 'import'
        ? '<p id="preset-detail" class="muted">为示例预设命名，导入后可在「用户导入滤镜」中查看。</p>'
        : operation === 'export' ? '<p id="preset-detail" class="muted">可查看和下载本次选择的示例参数。</p>' : '<p id="preset-detail" class="muted">保存可跨片复用的调整字段。</p>'),
    btn('取消', 'close') + (operation === 'import' ? btn('模拟读取失败', 'preset-read-failure') : '') + btn('执行', 'preset-command'),
  );
};
changes.presetOperation = (el) => {
  $('#preset-detail').textContent = {
    '导入 Lightroom / Camera Raw 预设': '选择 .xmp 或 .zip 后先查看支持的字段与缺失依赖。',
    导出原生预设: '可查看和下载本次选择的示例参数。',
    保存当前调整: '保存可跨片复用的调整字段。',
  }[el.value];
};
actions['preset-read-failure'] = () => {
  closeSheet();
  notifyEditor('未能读取预设文件，请检查文件后重新导入。', 'error');
};
actions['preset-command'] = () => {
  const op = value('presetOperation'),
    name = value('presetName').trim();
  if (!name) return;
  const { masks, repairs, ...reusable } = currentEdit().recipe;
  if (op === '导出原生预设') {
    demoDownload(name + '.rmpreset.json', { schema: 'rawmaster.ui.example', name, values: reusable });
    closeSheet();
    notifyEditor('已导出「' + name + '」。');
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
function snapshotBranch(snapshot) {
  return snapshot.branch ?? (snapshot.recipe.sceneOutput?.intent === 'hdr' ? 'hdr' : 'sdr');
}
const snapshotBranchCount = () => currentEdit().snapshots.filter(s => snapshotBranch(s) === (SceneEditor.hdr() ? 'hdr' : 'sdr')).length;
const snapshotLimit = '此分支已有 32 个命名快照。删除一个后可以继续保存。';
actions.snapshot = () => {
  if (snapshotBranchCount() >= 32) return notifyEditor(snapshotLimit,'error');
  dialog('存储快照', field('名称','snapshotName','快照 ' + (snapshotBranchCount() + 1)),
    btn('取消','close') + btn('存储','save-snap'));
};
actions['save-snap'] = () => {
  if (snapshotBranchCount() >= 32) {closeSheet(); return notifyEditor(snapshotLimit,'error');}
  const name = value('snapshotName').trim();
  if (!name) return;
  currentEdit().snapshots.push({ id:Studio.uid(), name, branch: SceneEditor.hdr() ? 'hdr' : 'sdr', recipe: structuredClone(currentEdit().recipe) });
  Studio.save();
  closeSheet();
  render();
};
actions['restore-snap'] = (i) => {
  Studio.setRecipe(Studio.data.work, '恢复快照', currentEdit().snapshots[i].recipe);
  render();
};
actions['rename-snap'] = (index) => {
  const snapshot = currentEdit().snapshots[index];
  if (!snapshot) return;
  if (!snapshot.id) { snapshot.id = Studio.uid(); Studio.save(); }
  const form = '<div data-snapshot-rename data-photo="' + h(Studio.data.work) + '" data-branch="' + snapshotBranch(snapshot)
    + '" data-base="' + h(currentEdit().base ?? currentEdit().adopted) + '" data-snapshot="' + h(snapshot.id) + '">' + field('名称','snapshotName',snapshot.name)
    + '<p id="snapshot-name-error" class="form-error" role="alert"></p></div>';
  dialog('重命名快照', form, btn('取消','close') + btn('存储','save-snap-name'));
  const input = sheet.querySelector('[name=snapshotName]');
  input.setAttribute('aria-describedby','snapshot-name-error');
  input.focus();
  input.select();
  input.addEventListener('keydown', event => {
    if (event.isComposing) return;
    if (event.key === 'Enter') { event.preventDefault(); actions['save-snap-name'](); }
    else if (event.key === 'Escape') { event.preventDefault(); closeSheet(); }
  });
};
actions['save-snap-name'] = () => {
  const form = sheet.querySelector('[data-snapshot-rename]');
  if (!sheet.open || !form) return;
  const request = form.dataset;
  const name = value('snapshotName').trim();
  const sameContext = S.page === 'edit' && Studio.data.work === request.photo && (currentEdit().base ?? currentEdit().adopted) === request.base
    && (SceneEditor.hdr() ? 'hdr' : 'sdr') === request.branch;
  const index = sameContext ? currentEdit().snapshots.findIndex(s => s.id === request.snapshot && snapshotBranch(s) === request.branch) : -1;
  const length = [...new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(name)].length;
  const issue = !sameContext ? '当前照片或调色分支已改变。请取消并重新选择快照。'
    : index < 0 ? '这份快照已被删除。请取消并返回快照列表。'
    : length < 1 || length > 60 ? '请输入 1 到 60 个字符的快照名称。' : '';
  const input = form.querySelector('[name=snapshotName]');
  if (issue) {
    form.querySelector('[role=alert]').textContent = issue;
    input.setAttribute('aria-invalid','true');
    input.focus();
    return;
  }
  currentEdit().snapshots[index].name = name;
  Studio.save();
  closeSheet();
  render();
  requestAnimationFrame(() => document.querySelector('[data-act=restore-snap][data-val="' + index + '"]')?.focus({preventScroll:true}));
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
