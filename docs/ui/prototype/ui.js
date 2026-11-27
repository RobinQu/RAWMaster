'use strict';

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));
const h = (value) =>
  String(value ?? '').replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const glyphs = {
  info: 'M12 22a10 10 0 1 0 0-20 10 10 0 1 0 0 20M12 11v6m0-10v.4',
  warning: 'M12 3 1.6 20h20.8L12 3zM12 9v5m0 3v.5',
  move: 'M12 2v20M2 12h20M9 5l3-3 3 3m-6 14 3 3 3-3M5 9l-3 3 3 3m14-6 3 3-3 3',
  aperture: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20z M14 3l5 9m2 2H10m6 7-6-10m-6 7 6-10M2 10h11M8 3l6 10',
  library: 'M3 5h4v15H3z M10 5h3v15h-3z M15 6l3-1 4 14-3 1z',
  photo: 'M3 4h18v16H3z M3 16l5-5 4 4 3-3 6 6 M16 7v1',
  grid: 'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
  single: 'M3 5h18v14H3z',
  compare: 'M2 5h8v14H2z M14 5h8v14h-8z',
  folder: 'M3 6h7l2 2h9v11H3z',
  stack: 'M12 3 2 8l10 5 10-5z M2 12l10 5 10-5 M2 16l10 5 10-5',
  star: 'm12 3 2.8 5.8 6.4.9-4.6 4.5 1.1 6.3-5.7-3-5.7 3 1.1-6.3-4.6-4.5 6.4-.9z',
  flag: 'M5 21V4m0 1c5-4 9 4 15 0v9c-6 4-10-4-15 0',
  clock: 'M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z M12 7v5l3 2',
  tray: 'M3 14 6 5h12l3 9v5H3z M3 14h5l2 2h4l2-2h5',
  import: 'M12 3v11m-4-4 4 4 4-4 M4 14v6h16v-6',
  edit: 'M4 17 15 6l3 3L7 20H4z M14 7l3-3 3 3-3 3',
  sliders: 'M3 6h7m4 0h7M3 12h12m4 0h2M3 18h3m4 0h11 M10 3v6m5 0v6M7 15v6',
  export: 'M12 15V3m-4 4 4-4 4 4M4 13v7h16v-7',
  settings: 'M9 3h6l1 3 3 1 2 5-2 5-3 1-1 3H9l-1-3-3-1-2-5 2-5 3-1z M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
  pulse: 'M2 12h5l3-7 4 14 3-7h5',
  search: 'M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14z M15.2 15.2 21 21',
  side: 'M2 4h20v16H2z M15 4v16',
  sidebar: 'M2 4h20v16H2z M9 4v16',
  chevron: 'm9 5 7 7-7 7',
  down: 'm5 9 7 7 7-7',
  close: 'm5 5 14 14m0-14L5 19',
  sampler: 'm15 3 6 6-3 3-6-6Zm-2 5L4 17l-1 4 4-1 9-9M11 6l7 7',
  tag: 'M3 3h8l10 10-8 8L3 11z M7 7h.5',
  pin: 'M12 22s8-8 8-14a8 8 0 0 0-16 0c0 6 8 14 8 14z M12 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z',
  layers: 'M4 4h13v12H4z M8 20h13V8',
  bypass: 'M8 8h8v8H8z M2 12h6m8 0h6 M3 7V4h18v3m-3-3 3 3 3-3',
  plus: 'M12 4v16M4 12h16',
  undo: 'M8 5 3 10l5 5m-4-5h10a6 6 0 0 1 0 12',
  check: 'm4 12 5 5L20 6',
  tools: 'M3 5h18v14H3z M3 9h18 M8 9v10',
  play: 'm7 4 13 8-13 8z',
  film: 'M3 4h18v16H3z M7 4v16m10-16v16M3 8h4m-4 7h4m10-7h4m-4 7h4',
  camera: 'M3 7h4l2-3h6l2 3h4v13H3z M12 10a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z',
  menu: 'M3 6h18M3 12h18M3 18h18',
  ellipsis: 'M5 11a1 1 0 1 0 0 2a1 1 0 1 0 0-2 M12 11a1 1 0 1 0 0 2a1 1 0 1 0 0-2 M19 11a1 1 0 1 0 0 2a1 1 0 1 0 0-2',
  disk: 'M5 5h14l3 11v3H2v-3z M3 15h18 M16 17h2',
  book: 'M3 4h7l2 2 2-2h7v15h-7l-2 2-2-2H3z M12 6v15',
  minus: 'M5 12h14',
  previous: 'm15 5-7 7 7 7',
  spark: 'm13 3 2.2 6.8L22 12l-6.8 2.2L13 21l-2.2-6.8L4 12l6.8-2.2z M4 2v5M1.5 4.5h5',
  chat: 'M3 5h18v12H9l-5 4v-4H3z M7 9h10M7 13h6',
  curve: 'M3 3v17h18 M6 17c7 0 3-12 12-12',
  mix: 'M8 4a4 4 0 1 0 0 8 4 4 0 1 0 0-8z M16 5a4 4 0 1 1-1 8 M10 14a4 4 0 1 0 7 3',
  detail: 'm3 19 7-14 3 7 2-4 6 11z',
  lens: 'M3 5h18v14H3z M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10z',
  effects: 'm3 18 9-13 9 13H3z M9 15l3-5 2 5',
  grading: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M12 3v9l8 4M12 12l-8 4',
  mask: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M7 12l3-3m-3 7 9-9m-4 10 6-6',
  repair: 'm4 14 10-10a4 4 0 0 1 6 6L10 20a4 4 0 0 1-6-6z M8 10l6 6m-3-9 6 6',
  crop: 'M6 2v15h16M2 6h15v16M9 14l11-11',
  background: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10z',
  zoomIn: 'M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14z M15 15l6 6M7 10h6m-3-3v6',
  zoomOut: 'M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14z M15 15l6 6M7 10h6',
  eye: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
  eyeOff: 'M3 3l18 18 M9 5c6-2 13 7 13 7l-3 4 M6 6l-4 6s6 9 14 6 M10 10l4 4',
  subject: 'M12 4a3 3 0 1 0 0 6 3 3 0 0 0 0-6z M6 21v-4a6 6 0 0 1 12 0v4 M3 3v4m-2-2h4',
  maskBackground: 'M3 3h18v18H3z M12 6a2 2 0 1 0 0 4 2 2 0 0 0 0-4z M8 19v-4a4 4 0 0 1 8 0v4 M3 9l4-4m-4 9 4-4m10 0 4-4m-4 12 4-4',
  instance: 'M3 8V3h5m8 0h5v5m0 8v5h-5m-8 0H3v-5 M8 8h8v8H8z M11 5h8v8',
  brush: 'M9 14 18 3l3 3-11 10 M9 14c-5-2-5 5-7 6 7 1 10-2 7-6z',
  linearMask: 'M3 3h18v18H3z M3 9h18m-18 6h18 M7 3v6m5-6v6m5-6v6 M7 9v6m10-6v6',
  radialMask: 'M12 4a10 8 0 1 0 0 16 10 8 0 1 0 0-16z M12 8a5 4 0 1 0 0 8 5 4 0 1 0 0-8z M12 11v2m-1-1h2',
  rangeMask: 'M3 7h18v10H3z M7 7v10m4-10v10m4-10v10m4-10v10 M5 3v4m14-4v4M5 17v4m14-4v4',
  overlay: 'M3 3h14v14H3z M7 21h14V7 M3 9l6-6m-6 12L15 3m-6 14 8-8',
  invert: 'M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z M12 3v18 M12 7l4-3m-4 8 7-4m-7 9 8-4',
  trash: 'M3 6h18 M9 6V3h6v3 M6 6v15h12V6 M10 10v7m4-7v7',
  arrowUp: 'M12 20V4m-6 6 6-6 6 6',
  arrowDown: 'M12 4v16m-6-6 6 6 6-6',
};
function icon(name, size = 17) {
  return `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${glyphs[name] || glyphs.photo}"/></svg>`;
}
function btn(label, act, val = '', opts = {}) {
  const expanded = opts.expanded == null ? '' : ' aria-expanded="' + opts.expanded + '"';
  const controls = opts.controls ? ' aria-controls="' + h(opts.controls) + '"' : '';
  return `<button type="button" data-act="${h(act)}" data-val="${h(val)}" class="${h(opts.cls || '')}"${opts.disabled ? ' disabled' : ''}${opts.pressed != null ? ` aria-pressed="${opts.pressed}"` : ''}${expanded}${controls} aria-label="${h(opts.title || label)}" title="${h(opts.title || label)}">${opts.icon ? icon(opts.icon) : ''}${opts.only ? '' : h(label)}</button>`;
}
function select(label, name, items, current) {
  return `<label class="field"><span>${h(label)}</span><select name="${h(name)}">${items
    .map((item) => {
      const [value, text] = Array.isArray(item) ? item : [item, item];
      return `<option value="${h(value)}"${String(value) === String(current) ? ' selected' : ''}>${h(text)}</option>`;
    })
    .join('')}</select></label>`;
}
function field(label, name, value = '', type = 'text') {
  return `<label class="field"><span>${h(label)}</span><input name="${h(name)}" type="${type}" value="${h(value)}" autocomplete="off"></label>`;
}
function check(label, name, checked = false, opts = {}) {
  return `<label class="check"><input type="checkbox" name="${h(name)}" ${checked ? 'checked' : ''}${opts.disabled ? ' disabled' : ''}${opts.key ? ` data-key="${h(opts.key)}"` : ''}>${h(label)}</label>`;
}
function fact(label, value) {
  return `<div class="fact"><dt>${h(label)}</dt><dd>${h(value)}</dd></div>`;
}
function pic(id, cls = '', extra = '') {
  const p = Studio.photo(id);
  return `<img src="${RMPhotos.url(p)}" alt="${h(p.scene)}" class="${cls}" draggable="false" ${extra}>`;
}
function empty(title, detail, action = '') {
  return `<div class="empty">${icon('photo', 30)}<h3>${h(title)}</h3><p>${h(detail)}</p>${action}</div>`;
}
const actions = {},
  inputs = {},
  changes = {};
const compactLibraryNavigation = matchMedia('(max-width:740px)');
const S = {
  page: 'library',
  sub: '',
  scope: 'project/river',
  inspector: true,
  filters: false,
  drawer: false,
  librarySidebar: true,
  zoom: false,
  tool: 'basic',
  editZoom: 1,
  editReturn: 'edit/development',
  compareMode: 'wipeHorizontal',
  comparePosition: 50,
  exportKey: '',
  preferred: null,
  returnScope: 'project/river',
  selectedLayer: 0,
  compare: false,
};
function editorNoticeRow(notice) {
  const error = notice.kind === 'error';
  return `<div class="editor-toast ${error ? 'error' : 'info'}" data-notice-id="${notice.id}">${icon(error ? 'warning' : 'info', 16)}
    <span role="${error ? 'alert' : 'status'}">${h(notice.message)}</span>
    ${notice.retry ? btn('重试', notice.retry) : ''}${btn('关闭' + (error ? '错误' : '消息'), 'editor-notice-dismiss', notice.id, {icon:'close', only:true})}</div>`;
}
function editorNotices(photo) {
  const notice = Activity.toast(photo);
  return `<section class="editor-notices" aria-label="当前照片的处理通知">${notice ? editorNoticeRow(notice) : ''}</section>`;
}
function notifyEditor(message, kind = 'info', photo = Studio.data.work, retry = '') {
  Activity.post(message,kind,photo,retry);
}
function resolveEditorRetry(action, photo = Studio.data.work) {
  Activity.resolve(action,photo);
}
actions['editor-notice-dismiss'] = (id, _, button) => {
  const focused = button?.closest('[data-notice-id]')?.contains(document.activeElement);
  Activity.dismiss(id);
  if (focused) ($('.scene-modes [aria-pressed=true]') || $('.edit-page [data-act=goto]'))?.focus({preventScroll:true});
};
window.addEventListener('blur', () => { document.documentElement.dataset.windowActive = 'false'; });
window.addEventListener('focus', () => { document.documentElement.dataset.windowActive = 'true'; });
let toastTimer;
function notify(message, kind = 'info') {
  if (S.page === 'edit') return notifyEditor(message, kind);
  Activity.post(message,kind);
  const n = $('#notice');
  n.textContent = message;
  n.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => n.classList.remove('show'), 2900);
}
const sheet = $('#sheet');
let sheetOpener;
function dialog(title, body, footer = '') {
  delete sheet.dataset.savedResults;
  delete sheet.dataset.job;
  delete sheet.dataset.dagBatch;
  if (!sheet.open) sheetOpener = document.activeElement;
  $('#sheet-content').innerHTML =
    `<div class="dialog-head"><h2 id="sheet-title">${h(title)}</h2>${btn('关闭', 'close', '', { icon: 'close', only: true, cls: 'icon-btn' })}</div><div class="dialog-body">${body}</div>${footer ? `<div class="dialog-foot">${footer}</div>` : ''}`;
  if (!sheet.open) sheet.showModal();
}
function closeSheet() {
  delete sheet.dataset.job;
  sheet.close();
}
sheet.addEventListener('close', () => {
  if (sheetOpener?.isConnected) sheetOpener.focus({ preventScroll: true });
  else if (sheet.dataset.savedResults) $(S.beforeResultsFocus || '.results-menu summary')?.focus({preventScroll:true});
});
function value(name, root = sheet) {
  return root.querySelector(`[name="${name}"]`)?.value ?? '';
}
function checked(name, root = sheet) {
  return Boolean(root.querySelector(`[name="${name}"]`)?.checked);
}
function go(path) {
  if (location.hash === '#' + path) render();
  else location.hash = path;
}
function activeBrowser() {
  return Studio.reconcile(S.scope);
}
function activeIDs() {
  return [...activeBrowser().selected];
}
function mutate(label, fn) {
  Studio.change(label, fn);
  render();
  notify(label);
}
function withPhoto(id) {
  if (id === Studio.data.work) return;
  Activity.leavePhoto();
  dagLeavePhoto();
  quickExitCanvas();
  S.quickView = null;
  S.quickResume = null;
  Studio.data.work = id;
  Studio.save();
  S.zoom = false;
  S.compare = false;
  S.selectedLayer = 0;
  S.canvasSelection = null;
  S.wbMode = null;
  S.versionView = null;
  S.reference = 'original';
  S.editZoom = 1;
  S.cropOpen = false;
  S.canvasMenu = '';
}
function validWork(id) {
  return Studio.admitted().includes(id);
}
function canEditPhoto(id) {
  if (!validWork(id)) return false;
  if (Studio.asset(id).online || Studio.edit(id).versions.length) return true;
  dialog(
    '原片待找回',
    `<p>${h(Studio.asset(id).name)} 仅有资料库预览。接回原件后可以继续编辑。</p>`,
    btn('返回', 'close') + btn('重新定位…', 'relink', id, { cls: 'primary' }),
  );
  return false;
}
function openEditor(id) {
  if (!canEditPhoto(id)) return;
  withPhoto(id);
  go('edit/development');
}
function route() {
  if (S.canvasTool) { S.canvasTool = null; S.cropOpen = false; S.canvasSelection = null; notify('已取消未提交的画布草案'); }
  quickExitCanvas();
  S.quickView = null;
  const raw = decodeURI(location.hash.slice(1)) || 'library/project/river';
  document.body.dataset.route = raw;
  const [page, ...rest] = raw.split('/');
  if (S.page === 'edit' && page !== 'edit') Activity.leavePhoto();
  S.page = ['library', 'edit', 'export', 'tools', 'settings', 'jobs'].includes(page) ? page : 'library';
  S.sub = rest.join('/');
  if (S.page === 'library') {
    S.scope = S.sub || 'project/river';
    Studio.data.lastScope = S.scope;
    Studio.save();
  }
  if (S.page === 'edit') {
    S.tool = S.sub === 'dag' ? 'basic' : Object.hasOwn(editTools, S.sub) || S.sub === 'agent' ? S.sub : 'basic';
    if (S.sub === 'versions') queueMicrotask(() => { actions['open-versions'](S.pendingResult); S.pendingResult=null; });
    if (S.sub === 'dag' && !compatibilityGraphMode) { S.graphOpen = true; dagEnsure(); dagView().mode = 'graph'; }
    if (['masks','repair'].includes(S.tool)) { S.canvasRouteTool = S.tool === 'masks' ? 'mask' : 'remove'; S.tool = 'basic'; }
    S.editReturn = 'edit/' + (S.sub || 'development');
    S.canvasMenu = '';
    if (S.tool === 'versions') S.cropOpen = false;
  }
  if (!validWork(Studio.data.work)) Studio.data.work = Studio.admitted()[0] || 'r1';
  if (S.page === 'edit' && !Studio.admitted().length) {
    S.page = 'library';
    S.scope = 'all';
  }
  S.drawer = false;
  S.mobileInspector = false;
  S.multi = false;
}
actions.close = closeSheet;
actions.goto = go;
actions.workflow = (page) => {
  if (page === 'edit') openEditor(S.page === 'library' ? activeBrowser().focus : Studio.data.work);
  else if (page === 'export') {
    if (S.page !== 'export') showExport();
  } else go('library/' + S.scope);
};

actions.drawer = () => {
  if (compactLibraryNavigation.matches) S.drawer = !S.drawer;
  else S.librarySidebar = !S.librarySidebar;
  render();
};
actions.inspector = () => {
  if (matchMedia('(max-width:1050px)').matches) S.mobileInspector = !S.mobileInspector;
  else S.inspector = !S.inspector;
  render();
};
actions.edit = () => openEditor(activeBrowser().focus);
actions.export = () => showExport();
document.addEventListener('click', (event) => {
  const el = event.target.closest('[data-act]');
  if (el && !el.disabled) {
    actions[el.dataset.act]?.(el.dataset.val, event, el);
  }
});
document.addEventListener('input', (event) => inputs[event.target.name]?.(event.target));
document.addEventListener('change', (event) => changes[event.target.name]?.(event.target));
