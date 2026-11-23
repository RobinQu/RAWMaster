'use strict';

const grounds = { 深灰: '#242628', 中灰: '#484a4c', 浅灰: '#999b9d', 纯黑: '#050505' };
const comparisonModes = {
  off: '关闭对比',
  reference: '仅参考',
  wipeHorizontal: '水平擦除',
  wipeVertical: '垂直擦除',
  mix: '混合',
  difference: '差值',
  checkerboard: '棋盘格',
  sideLeftRight: '左右并排',
  sideTopBottom: '上下并排',
};
function neighbors() {
  const admitted = new Set(Studio.admitted());
  const ids = Studio.visible(S.scope).filter((id) => admitted.has(id));
  const i = ids.indexOf(Studio.data.work);
  return { previous: i > 0 ? ids[i - 1] : null, next: i >= 0 ? ids[i + 1] : null };
}
function navButton(direction, name, glyph, id) {
  return `<span class="nav-target">${btn(name, 'canvas-nav', direction, { icon: glyph, only: true, disabled: !id, title: id ? name : name + '（已到范围边界）' })}
    ${id ? `<span class="neighbor-preview" aria-hidden="true">${pic(id)}<span>${h(Studio.asset(id).name)}</span></span>` : ''}</span>`;
}
function dock() {
  if (quickPromptVisible()) return promptDock();
  const { previous, next } = neighbors();
  const command = (name, act, key, glyph, options = {}) =>
    btn(name, act, key, { icon: glyph, only: !!glyph, ...options });
  return `<div class="canvas-dock" role="toolbar" aria-label="照片查看工具">
    ${navButton('previous', '上一张', 'previous', previous)}${navButton('next', '下一张', 'chevron', next)}
    <span class="dock-divider"></span>
    ${command('缩小 · −', 'edit-zoom', 'out', 'zoomOut', { disabled: S.editZoom <= 0.25 })}
    ${command('放大 · +', 'edit-zoom', 'in', 'zoomIn', { disabled: S.editZoom >= 4 })}
    ${command('FIT', 'edit-zoom', 'fit', null, { title: '适合可用画面 · 0 / ⌘0', cls: 'dock-fit' })}
    ${command('裁切与拉直 · C', 'canvas-crop', '', 'crop', { pressed: !!S.cropOpen, expanded: !!S.cropOpen, disabled: S.tool === 'versions' })}
    <span class="dock-divider"></span>
    ${command('对比模式 · V', 'canvas-menu', 'compare', 'compare', { pressed: S.compare, expanded: S.canvasMenu === 'compare', disabled: S.cropOpen })}
    ${command('暗房背景 · B', 'canvas-menu', 'ground', 'background', { expanded: S.canvasMenu === 'ground' })}
    <span class="dock-divider"></span>${quickEntry()}</div>`;
}
function compareMenu() {
  const refs = [
    ['original', '原片（当前几何）'],
    ...currentEdit()
      .versions.filter((v) => !v.discarded)
      .map((v) => [v.id, v.name]),
  ];
  const mode = S.compare ? S.compareMode : 'off';
  return `<section class="canvas-popover" aria-label="对比模式"><h3>对比模式</h3>
    ${select('显示方式', 'compareMode', Object.entries(comparisonModes), mode)}
    ${select('参考对象', 'compareReference', refs, S.reference || 'original')}
    ${
      ['wipeHorizontal', 'wipeVertical', 'mix'].includes(mode)
        ? `<label class="field"><span>${mode === 'mix' ? '参考占比' : '分割位置'} <output>${S.comparePosition}%</output></span>
      <input type="range" min="0" max="100" name="comparePosition" value="${S.comparePosition}"></label>`
        : ''
    }
    ${btn('交换参考与当前', 'compare-invert', '', { pressed: !!S.inverted, disabled: !S.compare || mode === 'reference' })}
    ${btn('完成', 'canvas-menu-close', '', { cls: 'link' })}</section>`;
}
function groundMenu() {
  return `<section class="canvas-popover ground-menu" aria-label="暗房背景"><h3>暗房背景</h3>${Object.entries(
    grounds,
  )
    .map(
      ([name, color]) =>
        `<button data-act="canvas-ground" data-val="${name}" aria-pressed="${Studio.data.prefs.ground === name}">
      <i style="background:${color}"></i>${name}${Studio.data.prefs.ground === name ? icon('check', 14) : ''}</button>`,
    )
    .join('')}</section>`;
}
function cropPanel(r) {
  return `<section class="crop-panel" aria-labelledby="crop-heading"><div class="row between"><h3 id="crop-heading">裁切与拉直</h3>
    ${btn('完成裁切', 'canvas-crop', '', { icon: 'check', only: true, cls: 'icon-btn' })}</div>
    ${select('画面比例', 'crop', ['原始', '1:1', '4:5', '3:2', '16:9'], r.crop)}${rangeRow('angle', '拉直', -45, 45, 0.1, r.angle)}
    ${btn('复位裁切', 'crop-reset', '', { cls: 'link' })}</section>`;
}
function editingMarks(r) {
  if (S.cropOpen) return '<span class="thirds"></span>';
  const mark = (m, label, kind, style = '') =>
    `<span class="marker ${kind}" style="left:${m.x}%;top:${m.y}%;${style}">${h(label)}</span>`;
  if (S.tool === 'masks')
    return r.masks
      .map((m, i) =>
        m.on
          ? mark(m, i + 1, 'mask-mark' + (m.invert ? ' inverse' : ''), 'opacity:' + (0.2 + 0.007 * m.opacity))
          : '',
      )
      .join('');
  if (S.tool === 'repair' && r.sectionEnabled?.repair !== false)
    return r.repairs
      .map((m, i) => mark(m, i + 1, 'repair-mark') + (m.source ? mark(m.source, '源', 'repair-mark') : ''))
      .join('');
  return '';
}
function editImageRatio(recipe, id) {
  const p = Studio.photo(id);
  return { '1:1': 1, '4:5': 0.8, '3:2': 1.5, '16:9': 16 / 9 }[recipe.crop] ?? p.w / p.h;
}
function canvasContent(r, id) {
  const p = Studio.photo(id), ratio = editImageRatio(r, id);
  const prompt = quickPromptVisible();
  const mode = S.compare && !prompt ? S.compareMode : 'off',
    ref = S.reference || 'original';
  const refs = currentEdit().versions,
    saved = refs.find((v) => v.id === ref && !v.discarded);
  const reference = saved?.recipe ?? Studio.freshRecipe(),
    refName = saved?.name ?? '原片';
  const pane = (side, layer = '', label = '') => {
    const image = (which, cls = '') => {
      const current = which === 'current', recipe = current ? r : reference;
      const filter = RMPhotos.filter(RMPhotos.displayLook(recipe));
      const version = current ? (S.tool === 'versions' ? S.versionView || currentEdit().adopted : null) : ref;
      const original = pic(id, current ? 'developed' : 'reference-image',
        'style="filter:' + filter + ';transform:rotate(' + (recipe.angle || 0) + 'deg)"');
      const result = quickCanvasEffect(id, recipe, version);
      return `<div class="canvas-layer ${cls}">${original}${result}</div>`;
    };
    return `<div class="canvas-fit"><div class="zoom-plane"><div class="edit-image" ${side === 'current' && mode === 'off' && !prompt ? 'data-act="canvas-point"' : ''} role="img" aria-label="${h(p.scene)}，${h(label || '调整预览')}">
      ${image(side)}${layer ? image(layer, 'comparison-layer') : ''}${side === 'current' && mode === 'off' ? (prompt ? quickCanvasControls(id) : editingMarks(r)) : ''}</div></div>${label ? `<small class="pane-label">${h(label)}</small>` : ''}</div>`;
  };
  const base = S.inverted ? 'reference' : 'current',
    overlay = S.inverted ? 'current' : 'reference';
  let contents;
  if (mode === 'off') contents = pane('current');
  else if (mode === 'reference') contents = pane('reference', '', refName);
  else if (mode.startsWith('side'))
    contents =
      pane(overlay, '', S.inverted ? '当前' : refName) + pane(base, '', S.inverted ? refName : '当前');
  else contents = pane(base, overlay, comparisonModes[mode] + ' · ' + refName);
  return `<section class="canvas-panel${prompt ? ' has-quick-prompt' : ''}" aria-label="暗房画布">
    <div class="dark-canvas" data-comparison="${mode}" style="--ratio:${ratio};--view-scale:${S.editZoom};--compare-amount:${S.comparePosition}%">${contents}</div>
    <small class="look-preview pane-label" hidden></small>${S.cropOpen ? cropPanel(r) : ''}${S.canvasMenu === 'compare' ? compareMenu() : S.canvasMenu === 'ground' ? groundMenu() : ''}${dock()}</section>`;
}
actions['canvas-nav'] = (direction) => {
  const id = neighbors()[direction];
  if (id) actions['edit-photo'](id);
};
actions['edit-photo'] = (id) => {
  if (id === Studio.data.work || !canEditPhoto(id)) return;
  const b = activeBrowser();
  if (b.selected.length === 1) b.selected = [id];
  b.focus = id;
  withPhoto(id);
  render();
};
actions['edit-zoom'] = (direction) => {
  const view = $('.edit-image');
  let scale = direction === 'fit' ? 1 : S.editZoom * (direction === 'in' ? 1.25 : 0.8);
  if (direction === 'pixels' && view)
    scale =
      S.editZoom === 1 ? view.querySelector('img').naturalWidth / view.getBoundingClientRect().width : 1;
  S.editZoom = Math.max(0.25, Math.min(4, scale));
  render();
  for (const fit of $$('.canvas-fit')) {
    fit.scrollLeft = (fit.scrollWidth - fit.clientWidth) / 2;
    fit.scrollTop = (fit.scrollHeight - fit.clientHeight) / 2;
  }
  notify(direction === 'fit' ? '适合可用画面' : '相对 FIT · ' + Math.round(S.editZoom * 100) + '%');
};
function dockFocus(act, val = '') {
  document
    .querySelector('.canvas-dock [data-act="' + act + '"][data-val="' + val + '"]')
    ?.focus({ preventScroll: true });
}
actions['canvas-crop'] = () => {
  if (S.tool === 'versions') return;
  S.cropOpen = !S.cropOpen;
  S.canvasMenu = '';
  if (S.cropOpen) S.compare = false;
  render();
  if (S.cropOpen) $('[name=crop]')?.focus({ preventScroll: true });
  else dockFocus('canvas-crop');
};
actions['canvas-menu-close'] = () => {
  const menu = S.canvasMenu;
  S.canvasMenu = '';
  render();
  dockFocus('canvas-menu', menu);
};
actions['canvas-menu'] = (menu) => {
  if (menu === 'compare' && S.cropOpen) return;
  if (S.canvasMenu === menu) return actions['canvas-menu-close']();
  S.canvasMenu = menu;
  render();
  $('.canvas-popover :is(select,button)')?.focus({ preventScroll: true });
};
actions['edit-compare'] = () => {
  if (S.cropOpen) return;
  S.compare = !S.compare;
  S.canvasMenu = '';
  render();
};
actions['compare-invert'] = () => {
  S.inverted = !S.inverted;
  render();
};
changes.compareMode = (el) => {
  S.compare = el.value !== 'off';
  if (S.compare) S.compareMode = el.value;
  render();
};
changes.compareReference = (el) => {
  S.reference = el.value;
  S.compare = true;
  render();
};
inputs.comparePosition = (el) => {
  S.comparePosition = Number(el.value);
  el.closest('label').querySelector('output').value = el.value + '%';
  $('.dark-canvas').style.setProperty('--compare-amount', el.value + '%');
};
actions['canvas-ground'] = (name) => {
  Studio.data.prefs.ground = name;
  Studio.save();
  const menu = S.canvasMenu;
  S.canvasMenu = '';
  render();
  if (menu === 'ground') dockFocus('canvas-menu', 'ground');
};
document.addEventListener(
  'click',
  (event) => {
    if (S.page !== 'edit' || !S.canvasMenu || event.target.closest('.canvas-popover,.canvas-dock')) return;
    const trigger = $('.canvas-dock [data-act="canvas-menu"][data-val="' + S.canvasMenu + '"]');
    trigger?.setAttribute('aria-expanded', 'false');
    $('.canvas-popover')?.remove();
    S.canvasMenu = '';
  },
  true,
);
