// The prototype keeps the submitted photo batch and its simulated filesystem separately.
// Reloading checks an existing publication against its own ticket before continuing.
const PhotoDelivery = (() => {
  const prefix = 'rawmaster.export.delivery.v1.';
  const domain = window.parent === window ? 'sample' : 'studio';
  const uid = () => globalThis.crypto?.randomUUID?.() ?? Date.now() + '-' + Math.random().toString(36).slice(2);
  // These two fixture folders keep their existing persisted files. A new device
  // number changes the simulated mount, while the volume and directory IDs survive.
  const targets = {
    pictures:{volumeID:'demo-home',directoryID:'pictures-exports',device:17},
    client:{volumeID:'demo-client',directoryID:'client-delivery',device:24}
  };
  function targetIssue(expected, offered) {
    if (!expected?.volumeID || !expected.directoryID || !offered?.volumeID || !offered.directoryID) return '无法核对所选目录，请重新接回原目标目录。';
    if (expected.volumeID !== offered.volumeID) return '所选位置位于另一卷。请接回提交时的原卷和目录。';
    if (expected.directoryID !== offered.directoryID) return '所选位置与提交时的目录不符。请接回原目标目录。';
    return '';
  }
  const fileKey = (batch, name) => prefix + domain + '.file.' + batch.folder + '/' + name;
  const read = key => { try { return JSON.parse(localStorage.getItem(key)); } catch { return null; } };
  const inMemoryFiles = new Map();
  const fileAt = (batch, name) => batch.volumeOnline === false ? undefined : read(fileKey(batch, name)) ?? inMemoryFiles.get(fileKey(batch, name));
  const assetKey = photo => photo.id || 'sample/' + photo.name;
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const key = localStorage.key(i);
      for (const folder of Object.keys(demoFiles)) {
        const start = fileKey({folder},'');
        if (key?.startsWith(start)) demoFiles[folder].add(key.slice(start.length));
      }
    }
  } catch {}

  function persist(batch) {
    try {
      localStorage.setItem(prefix + 'batch.' + batch.id, JSON.stringify(batch));
      if (domain === 'sample') localStorage.setItem(prefix + 'sample.last', JSON.stringify(batch.id));
      batch.storageIssue = false;
    } catch { batch.storageIssue = true; }
  }
  function putFile(batch, name, file) {
    const key = fileKey(batch, name);
    inMemoryFiles.set(key, file);
    try { localStorage.setItem(key, JSON.stringify(file)); } catch { batch.storageIssue = true; }
    demoFiles[batch.folder].add(name);
  }
  function freeze(batch) {
    batch.photoReceipt = 1;
    batch.phase = 'running';
    batch.volumeOnline = true;
    batch.target = {...targets[batch.folder]};
    batch.offeredTarget = {...batch.target};
    batch.source = byId('selection-origin').textContent;
    for (const [i, row] of batch.items.entries()) {
      const photo = photos[row.index];
      row.asset = assetKey(photo);
      row.version = structuredClone(row.version);
      row.sourceName = photo.name;
      row.physicalID = photo.physicalID || row.asset;
      row.presentationID = row.asset;
      if (photo.copyName) row.copyName = photo.copyName;
      row.versionID = row.version.id ?? String(photo.choice);
      row.ordinal = i + 1;
      row.online = photo.online;
      row.plannedName = row.name;
    }
    persist(batch);
  }
  function load(id) {
    const key = id || (domain === 'sample' ? read(prefix + 'sample.last') : null);
    if (typeof key !== 'string') return null;
    const batch = read(prefix + 'batch.' + key);
    if (batch?.photoReceipt !== 1 || batch.id !== key || !Array.isArray(batch.items) || !Object.hasOwn(folderNames,batch.folder)) return null;
    // Receipts from the earlier sample refer to the same two original fixture
    // folders. Recover their identity independently of the next grant offered.
    batch.target ??= {...targets[batch.folder]};
    batch.offeredTarget ??= {...batch.target};
    if (targetIssue(batch.target,batch.offeredTarget)) batch.volumeOnline = false;
    if (batch.running) { batch.running = false; batch.phase = 'interrupted'; }
    verify(batch);
    persist(batch);
    return batch;
  }
  function available(row) { return row.target !== 'unavailable' && (row.online || !row.requiresSource && row.version.archive === true); }
  function canRun(batch, row) {
    return batch.volumeOnline && !batch.running && batch.phase !== 'cancelled' && available(row)
      && ['待继续','待执行','写入失败','待找回'].includes(row.state);
  }
  function matches(row, file) {
    return !!(row.ticket && file && row.ticket.fileID === file.fileID && row.ticket.content === file.content);
  }
  function checkRow(batch, row) {
    if (row.target === 'unavailable' || ['已取消','按重名策略跳过'].includes(row.state)) return;
    if (!batch.volumeOnline) return;
    const file = fileAt(batch,row.name);
    if (file) demoFiles[batch.folder].add(row.name);
    if (matches(row,file)) { row.acknowledged = true; row.state = '已核验'; return; }
    if (row.ticket && file) { row.state = '同名文件待核对'; return; }
    if (row.acknowledged) { row.state = '已交付文件缺失'; return; }
    if (batch.phase === 'cancelled') { row.state = '已取消'; return; }
    if (!available(row)) { row.state = '待找回'; return; }
    if (row.state !== '写入失败') row.state = '待继续';
  }
  function verify(batch) {
    batch.items.forEach(row => checkRow(batch,row));
    if (batch.phase !== 'cancelled' && batch.volumeOnline) {
      if (batch.items.every(row => ['已核验','按重名策略跳过','无 HDR 母版'].includes(row.state))) batch.phase = 'done';
      else if (batch.phase === 'done') batch.phase = 'waiting';
    }
  }
  function summary(batch) {
    const counts = new Map();
    for (const row of batch.items) counts.set(row.state, (counts.get(row.state) || 0) + 1);
    const verified = counts.get('已核验') || 0;
    const parts = ['已核验 ' + verified + ' / ' + batch.items.length + ' 项'];
    const pending = ['待继续','待执行','处理中','待核验'].reduce((n, key) => n + (counts.get(key) || 0), 0);
    if (pending) parts.push('待完成 ' + pending + ' 项');
    for (const key of ['待找回','无 HDR 母版','写入失败','同名文件待核对','已交付文件缺失','已取消','按重名策略跳过']) {
      if (counts.has(key)) parts.push(key + ' ' + counts.get(key) + ' 项');
    }
    return parts.join(' · ');
  }
  function state(batch) {
    if (batch.running) return ['running','正在模拟交付'];
    if (batch.phase === 'cancelled') return ['cancelled','已取消本批交付'];
    if (!batch.volumeOnline) return ['unknown','目标目录离线'];
    if (batch.phase === 'done') return ['done','本批交付结果'];
    if (batch.items.some(r => ['同名文件待核对','已交付文件缺失'].includes(r.state))) return ['unknown','交付文件待核对'];
    if (batch.phase === 'interrupted') return ['unknown','交付已中断'];
    if (batch.items.some(r => r.state === '写入失败')) return ['failed','部分文件写入失败'];
    return ['unknown','本批有待完成项'];
  }
  function prepare(batch, row) {
    if (row.ticket) return;
    // An untouched item may still use the submitted collision policy. Once ticketed its path is fixed.
    if (fileAt(batch,row.name) || demoFiles[batch.folder].has(row.name)) {
      if (batch.settings.collision === 'skip') { row.state = '按重名策略跳过'; return; }
      const dot = row.baseName.lastIndexOf('.');
      const reserved = new Set(batch.items.filter(other => other !== row).map(other => other.name));
      let n = 2, candidate;
      do { candidate = row.baseName.slice(0,dot) + '-' + n++ + row.baseName.slice(dot); }
      while (reserved.has(candidate) || demoFiles[batch.folder].has(candidate) || fileAt(batch,candidate));
      row.name = candidate;
    }
    row.ticket = {fileID:uid(), content:uid()};
  }
  function update() { persist(job); showJob(); refresh(); publishJob(); }
  function run(batch) {
    const row = batch.items.find(item => item.state === '待执行');
    if (!row) { batch.running = false; batch.phase = 'waiting'; verify(batch); update(); return; }
    prepare(batch,row);
    if (!row.ticket) { run(batch); return; }
    row.state = '处理中'; update();
    timer = setTimeout(() => {
      if (job !== batch || !batch.running) return;
      if (batch.failNext) {
        batch.failNext = false; row.state = '写入失败'; run(batch); return;
      }
      const existing = fileAt(batch,row.name);
      if (existing && !matches(row,existing)) { row.state = '同名文件待核对'; run(batch); return; }
      if (!existing) putFile(batch,row.name,{...row.ticket});
      row.state = '待核验'; update();
      timer = setTimeout(() => {
        if (job !== batch || !batch.running) return;
        checkRow(batch,row); run(batch);
      },320);
    },630);
  }
  function resume(batch) {
    if (batch.running || batch.phase === 'cancelled') return;
    verify(batch);
    const ready = batch.items.filter(r => canRun(batch,r));
    if (!ready.length) { update(); return; }
    ready.forEach(row => { row.state = '待执行'; });
    batch.phase = 'running'; batch.running = true; run(batch);
  }
  function stop(batch, reason) {
    clearTimeout(timer);
    batch.running = false;
    if (reason === 'cancelled') {
      verify(batch);
      batch.phase = reason;
      for (const row of batch.items) {
        if (!row.acknowledged && !['同名文件待核对','按重名策略跳过'].includes(row.state)) {
          row.state = row.ticket && !batch.volumeOnline ? '待核验' : '已取消';
        }
      }
    } else {
      batch.phase = 'interrupted';
      for (const row of batch.items) {
        if (['待执行','处理中'].includes(row.state)) row.state = '待继续';
      }
      if (reason === 'offline') { batch.volumeOnline = false; batch.reconnectIssue = ''; }
      verify(batch);
    }
    update();
  }
  function offerMount(batch, original) {
    if (batch.volumeOnline) return;
    const originalTarget = targets[batch.folder];
    batch.offeredTarget = original
      ? {...originalTarget,device:originalTarget.device + 80}
      : {...originalTarget,volumeID:'demo-substitute'};
    batch.reconnectIssue = '';
    update();
  }
  function reconnectVolume(batch) {
    batch.reconnectIssue = targetIssue(batch.target,batch.offeredTarget);
    batch.volumeOnline = !batch.reconnectIssue;
    if (batch.volumeOnline) verify(batch);
    update();
    return batch.volumeOnline;
  }
  function reconnectInput(batch,row) {
    for (const item of batch.items) if (item.asset === row.asset) item.online = true;
    const photo = photos.find(p => assetKey(p) === row.asset);
    if (photo) photo.online = true;
    selection.changed(); verify(batch); update();
  }
  function collide(batch) {
    const row = batch.items.find(row => row.ticket && !row.acknowledged && !fileAt(batch,row.name));
    if (!row) return;
    // Same simulated bytes, different file identity. A prepared delivery must reject it.
    putFile(batch,row.name,{fileID:uid(), content:row.ticket.content, fixture:true});
    stop(batch,'interrupted');
  }
  function restoreForeign(batch) {
    for (const row of batch.items) {
      const file = fileAt(batch,row.name);
      if (row.state !== '同名文件待核对' || !file?.fixture) continue;
      const key = fileKey(batch,row.name);
      inMemoryFiles.delete(key);
      try { localStorage.removeItem(key); } catch {}
      demoFiles[batch.folder].delete(row.name);
    }
    verify(batch); update();
  }
  // The current view is per tab and independent of the saved job. Opening an old receipt
  // cannot change the setting, version or selection for another workbench handoff.
  const viewKey = prefix + 'view.' + (new URLSearchParams(location.hash.slice(1)).get('selection') || 'sample');
  window.addEventListener('pagehide', () => {
    try {
      sessionStorage.setItem(viewKey,JSON.stringify({size:selection.total, checked:[...included], focus,
        search:selection.search.value, filter:selection.filter.value, preset:byId('preset').value,
        folder:byId('folder').value, settings:currentSettings(), photos:photos.slice(0,selection.total).map(p => [p.choice,p.online])}));
    } catch {}
  });
  function restoreView() {
    let saved;
    try { saved = JSON.parse(sessionStorage.getItem(viewKey)); } catch {}
    if (!saved?.settings || !Array.isArray(saved.checked) || !Array.isArray(saved.photos)) return;
    if (!handoff && [3,201,1200].includes(saved.size)) {
      byId('sample-size').value = String(saved.size); selection.useSample(saved.size);
    }
    if (saved.size !== selection.total) return;
    for (const [i, values] of saved.photos.entries()) {
      if (photos[i]?.versions[values[0]]) photos[i].choice = values[0];
      if (values[1] === true && photos[i]) photos[i].online = true;
    }
    included.clear(); saved.checked.filter(i => i >= 0 && i < selection.total).forEach(i => included.add(i));
    focus = Number.isInteger(saved.focus) && photos[saved.focus] ? saved.focus : 0;
    selection.search.value = saved.search; selection.filter.value = saved.filter;
    const settings = saved.settings;
    mode = settings.mode; reusableFields.forEach(field => { byId(field).value = settings[field]; });
    byId('copy-mode').value = settings.copyMode; byId('original-format').value = settings.originalFormat;
    byId('gps').checked = settings.gps; byId('preset').value = saved.preset; byId('folder').value = saved.folder;
    setLayout(settings.layout); selection.changed();
  }
  return {freeze, load, run, resume, stop, verify, update, summary, state, canRun, fileAt,
    reconnectInput, offerMount, reconnectVolume, targetIssue, collide, restoreForeign, assetKey, restoreView};
})();
