'use strict';

// Timers belong to the previous document. A new workbench may inspect its frozen
// batch immediately, but publishing more files requires an explicit continuation.
for (const job of Studio.data.jobs) {
  if (job.photoReceipt && job.state === 'running') {
    job.state = 'unknown';
    job.deliveryStatus = '交付已中断';
  }
}

function handoffDelivery(ids, source, { version, mode = 'render', companions = false } = {}) {
  const items = [];
  for (const id of ids) {
    const item = Studio.exportItem(id, id === Studio.data.work ? version : undefined);
    items.push(item);
    if (companions && Studio.asset(id).pair) {
      items.push({
        ...item,
        id: id + '@jpeg',
        name: item.name.replace(/\.[^.]+$/, '.JPG'),
        versions: item.versions.filter((v) => v.id === 'original'),
      });
    }
  }
  if (!items.length) return;
  S.delivery = { source: Studio.scopeInfo(S.scope).title + ' / ' + source, mode, items };
  try {
    sessionStorage.setItem('rawmaster.ui.delivery', JSON.stringify(S.delivery));
  } catch {}
  go('export');
}
function showExport(preferred = null) {
  if (S.page === 'edit' && S.dagConnectionDraft) return notify('先完成或取消当前连接草稿');
  const editing = S.page === 'edit',
    focus = Studio.data.work,
    set = new Set(activeIDs());
  const visible = Studio.visible(S.scope).filter(validWork);
  const selected = visible.filter((id) => set.has(id));
  const ids = editing && !selected.includes(focus) ? [focus] : selected;
  if (!ids.length) {
    const b = activeBrowser(),
      filtered = Object.entries(filterDefaults).some(([key, v]) => b[key] !== v);
    const title = filtered ? '当前筛选结果' : '当前浏览范围';
    dialog(
      '选择导出范围',
      `<p>${h(Studio.scopeInfo(S.scope).title)} · ${title} ${visible.length} 张</p>`,
      btn('取消', 'close') +
        btn('导出' + title + ' ' + visible.length + ' 张', 'export-visible', '', {
          cls: 'primary',
          disabled: !visible.length,
        }),
    );
    return;
  }
  if (editing && Studio.dirty(focus) && preferred === null) {
    dialog(
      '导出哪个版本？',
      '<p>当前照片有未保存的初修调整。</p>',
      btn('取消', 'close') +
        btn('导出采用版本', 'export-choice', 'adopted') +
        btn('保存新版本并导出', 'export-choice', 'draft', { cls: 'primary' }),
    );
    return;
  }
  handoffDelivery(ids, editing ? '编辑所选' : '资料库所选', { version: preferred });
}
actions['export-visible'] = () => {
  const ids = Studio.visible(S.scope).filter(validWork);
  closeSheet();
  handoffDelivery(ids, '当前浏览范围');
};
actions['version-export'] = (id) => handoffDelivery([Studio.data.work], '作品版本', { version: id });
actions['original-review'] = (kind) => {
  const selected = new Set(activeIDs());
  const ids = Studio.visible(S.scope).filter(
    (id) =>
      validWork(id) &&
      (kind === 'picks'
        ? Studio.asset(id).decision === 'keep' && Studio.asset(id).triage !== 'sequence'
        : selected.has(id)),
  );
  S.copyIDs = ids;
  const pairs = ids.filter((id) => Studio.asset(id).pair).length;
  dialog(
    kind === 'picks' ? '交付当前范围内的精选' : '复制所选原文件',
    `<p>${ids.length} 次拍摄 · ${pairs} 对已确认的 RAW + JPEG</p>` +
      (pairs ? check('包含已确认的 JPEG 伴随文件', 'copyPairs', true) : ''),
    btn('取消', 'close') + btn('进入原件交付', 'copy-handoff', kind, { disabled: !ids.length }),
  );
};
actions['copy-handoff'] = (kind) => {
  const companions = checked('copyPairs');
  closeSheet();
  handoffDelivery(S.copyIDs, kind === 'picks' ? '交付精选' : '所选原文件', { mode: 'original', companions });
};

function renderDelivery(root) {
  if (!S.delivery) {
    const ids = activeIDs().filter(validWork);
    if (!ids.length) {
      $('#delivery').hidden = true;
      root.hidden = false;
      root.innerHTML = empty(
        '尚未指定导出范围',
        '可核对当前筛选结果，或返回资料库选片。',
        btn('选择导出范围…', 'export') + btn('返回资料库', 'goto', 'library/' + S.scope),
      );
      return;
    }
    S.delivery = {
      source: Studio.scopeInfo(S.scope).title + ' / 资料库所选',
      items: ids.map((id) => Studio.exportItem(id)),
    };
  }
  const requested = S.openPhotoReceipt;
  S.openPhotoReceipt = null;
  const current = $('#export-frame');
  if (!requested && current.delivery === S.delivery && current.dataset.batch === S.exportKey) return;
  const frames = $$('#delivery iframe');
  const live = requested ? frames.find(f => f.dataset.receipt === requested) : null;
  const pending = !requested && S.delivery.mode !== 'original' && Studio.data.jobs.find(j => j.photoReceipt
    && ['unknown','failed'].includes(j.state) && !frames.some(f => f.dataset.receipt === j.photoReceipt));
  const fragment = new URLSearchParams({ selection: JSON.stringify(S.delivery) });
  if (requested || pending) fragment.set('receipt', requested || pending.photoReceipt);
  if (requested) fragment.set('details','1');
  const review = new URLSearchParams(location.search).has('pqReview') ? '?pqReview=1' : '';
  const src = live?.dataset.batch || '../../../specs/032-export-workspace/prototype.html' + review + '#' + fragment;
  const openLiveReceipt = () => live?.contentWindow.postMessage({type:'rawmaster.delivery.open',id:requested}, location.protocol === 'file:' ? '*' : location.origin);
  if (S.exportKey === src) { openLiveReceipt(); return; }
  let next = live || frames.find((frame) => frame.dataset.batch === src);
  if (!next) {
    if (!current.dataset.batch) next = current;
    else {
      next = document.createElement('iframe');
      next.title = current.title;
      $('#delivery').append(next);
    }
  }
  if (current !== next) {
    current.removeAttribute('id');
    if (current.dataset.running === 'true') current.hidden = true;
    else current.remove();
  }
  next.hidden = false;
  next.id = 'export-frame';
  if (next.dataset.batch !== src) {
    next.dataset.batch = src;
    next.delivery = S.delivery;
    next.src = src;
  } else { openLiveReceipt(); }
  S.exportKey = src;
}
function clearDelivery() {
  S.delivery = null;
  S.exportKey = '';
  try {
    sessionStorage.removeItem('rawmaster.ui.delivery');
  } catch {}
  const blank = document.createElement('iframe');
  blank.id = 'export-frame';
  blank.title = '导出选片、预览与交付设置';
  $('#delivery').replaceChildren(blank);
}
window.addEventListener('message', (event) => {
  const m = event.data;
  if (m?.type !== 'rawmaster.delivery.receipt') return;
  const frame = $$('#delivery iframe').find((f) => f.contentWindow === event.source);
  if (!frame || !frame.delivery || typeof m.id !== 'string' || !Array.isArray(m.rows)) return;
  const id = 'delivery-' + m.id,
    jobs = Studio.data.jobs;
  let j = jobs.find((x) => x.id === id);
  if (!j) {
    j = { id, delivery: frame.delivery };
    jobs.unshift(j);
  }
  Object.assign(j, {
    kind: m.kind,
    state: m.photoReceipt && ['running','done','unknown','failed','cancelled'].includes(m.state) ? m.state
      : m.running ? 'running' : m.rows.some((r) => r.state === '已取消') ? 'cancelled' : 'done',
    rows: m.rows,
    folder: m.folder,
  });
  if (m.photoReceipt) {
    j.photoReceipt = m.id; j.deliveryStatus = m.status; j.deliverySummary = m.summary;
    frame.dataset.receipt = m.id;
  } else { delete frame.dataset.receipt; }
  frame.dataset.running = String(m.running);
  Studio.save();
  if (frame.hidden && !m.running) frame.remove();
  if (S.page === 'jobs') {
    render();
    if (sheet.open && sheet.dataset.job === id) deliveryReceipt(j);
  }
});
function deliveryReceipt(j) {
  dialog(
    j.kind,
    factList([
      ['来源', j.delivery.source],
      ['目的地', j.folder],
      ['状态', j.deliveryStatus || jobNames[j.state]],
      ...(j.deliverySummary ? [['进度',j.deliverySummary]] : []),
    ]) + `<h4>逐项结果</h4>${j.rows.map((r) => rowCard(r.name, r.state)).join('')}`,
    btn('完成', 'close') + btn(j.photoReceipt ? '查看本批交付' : '打开本批选片', 'reopen-delivery', j.id),
  );
  sheet.dataset.job = j.id;
}
actions['reopen-delivery'] = (id) => {
  const job = Studio.data.jobs.find((j) => j.id === id);
  S.delivery = job.delivery;
  S.openPhotoReceipt = job.photoReceipt;
  closeSheet();
  go('export');
};
