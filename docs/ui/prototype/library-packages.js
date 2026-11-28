'use strict';

const libraryFields = [
  'catalog', 'edits', 'history', 'browse', 'jobs', 'backupSnapshot', 'dagBatches', 'dagTemplates',
  'colorSamplers', 'packageInfo', 'work', 'lastScope',
];
const packageSuffix = '.rawmasterlibrary';
let packageSwitchRequest;
let packageSwitchTimer;

function packageLocation(snapshot = Studio.data) {
  const name = packageLabel(snapshot);
  return snapshot.packageInfo ?? { id: name, libraryID: name, path: packagePath(name, '~/Pictures') };
}

function availablePackages() {
  return [Studio.data, ...Object.values(Studio.data.libraries ?? {})];
}

function findPackage(id) {
  return availablePackages().find((snapshot) => packageLocation(snapshot).id === id);
}

function packageLabel(snapshot) {
  return snapshot.catalog.packageName || '本机资料库';
}

function packageWindowTitle() {
  const name = packageLabel(Studio.data);
  return `<button class="library-window-title" type="button" data-act="package-title-path" aria-haspopup="dialog"
    title="${h(name + ' · 查看资料库路径')}">${h(name)}</button>`;
}

function libraryFolderIcon() {
  return '<img class="library-folder-icon" src="../../../Sources/RAWMaster/Resources/LibraryFolder.png" width="16" height="16" alt="">';
}

function librarySnapshot() {
  return Object.fromEntries(libraryFields.map((key) => [key, Studio.data[key]]));
}

function reviewDialog(title, content, footer) {
  dialog(title, content, footer);
  (sheet.querySelector('.dialog-body input, .dialog-body select, .dialog-body button:not(:disabled)')
    || sheet.querySelector('.dialog-foot button:not(:disabled)'))?.focus();
}

function reviewError(message) {
  const error = sheet.querySelector('.review-error');
  if (error) error.textContent = message;
}

function welcomeView() {
  const recovery = S.sub === 'recover';
  return `<section class="library-welcome"><div class="settings-box">
    <h1>${recovery ? '找不到上次打开的资料库' : '打开 RAWMaster 资料库'}</h1>
    <p>${recovery ? '上次位置：' + h(packageLocation().path) + '。请接回原卷或重新选择库包。' : '选择本机位置，保存照片目录、版本和编辑资源。'}</p>
    <div class="menu-list">
      ${recovery ? btn('重新定位资料库…', 'package-switch', '', {cls:'primary', icon:'folder'}) : ''}
      ${btn('新建资料库…', 'package-new', '', {icon:'plus', cls: recovery ? '' : 'primary'})}
      ${btn('打开已有资料库…', 'package-switch', '', {icon:'folder'})}
      ${serverReview ? btn('连接 RAWMaster Server', 'package-server', '', {icon:'layers'}) : ''}
    </div>
  </div></section>`;
}

actions['library-menu'] = (_, __, opener) => {
  opener?.focus({preventScroll:true});
  reviewDialog('资料库菜单',
    `<div class="menu-list">
      ${btn('新建资料库…', 'package-new', '', {icon:'plus'})}
      ${btn('打开资料库包…', 'package-switch', '', {icon:'folder'})}
      ${serverReview ? btn('连接 RAWMaster Server…', 'package-server', '', {icon:'layers'}) : ''}
      ${btn('资料库与备份', 'goto-close', 'tools/package', {icon:'disk'})}
    </div>
    <h3 class="recent-heading">最近打开</h3>
    ${availablePackages().filter((snapshot) => {
      const location = packageLocation(snapshot);
      return location.recent !== false && !location.copyOf;
    }).map((snapshot) => {
      const location = packageLocation(snapshot);
      return rowCard(packageLabel(snapshot), location.path, snapshot === Studio.data ? '<small>当前资料库</small>' :
        btn('打开', 'package-recent', location.id, {title: '打开 ' + location.path}));
    }).join('')}`,
    btn('完成', 'close'));
};

actions['package-switch'] = () => {
  const choices = availablePackages().map((snapshot) => [packageLocation(snapshot).id, packageLocation(snapshot).path]);
  reviewDialog('打开资料库包', select('资料库包', 'demoPackage', choices) + '<p class="review-error" role="alert"></p>',
    btn('取消', 'close') + btn('打开', 'package-open', '', {cls:'primary'}));
};

actions['package-open'] = () => openKnownPackage(value('demoPackage'));
actions['package-recent'] = openKnownPackage;

function runningPackageJobs() {
  return Studio.data.jobs.filter(job => !job.remote && job.state === 'running' && job.kind !== '准备本机 AI 环境');
}

function packageSwitchTasks() {
  const workflows = (Studio.data.dagBatches ?? []).filter(batch => batch.running).map(() => '批量工作流');
  return [...new Set([...runningPackageJobs().map(job => job.kind), ...workflows])];
}

function askPackageSwitch(name, path, open) {
  clearPackageSwitch();
  if (S.page === 'welcome') return open();
  const tasks = packageSwitchTasks();
  packageSwitchRequest = {name, path, open};
  reviewDialog('切换资料库？',
    factList([['当前资料库', packageLabel(Studio.data)], ['打开', name], ['位置', path]])
    + (tasks.length
      ? `<p class="library-switch-note">正在处理 ${h(tasks.join('、'))}。你可以等待任务完成，或保存进度后切换。</p>`
      : '<p class="library-switch-note">切换时会先关闭当前资料库。</p>'),
    (tasks.length
      ? btn('等待任务完成后切换', 'package-switch-confirm', 'wait', {cls:'primary'})
        + btn('暂停任务并切换', 'package-switch-confirm', 'pause')
      : btn('切换资料库', 'package-switch-confirm', 'pause', {cls:'primary'}))
    + btn('取消切换', 'close'));
}

function clearPackageSwitch() {
  clearInterval(packageSwitchTimer);
  packageSwitchRequest = undefined;
}

actions['package-switch-confirm'] = (choice) => {
  const request = packageSwitchRequest;
  if (!request) return;
  if (choice === 'wait' && packageSwitchTasks().length) {
    reviewDialog('正在等待当前资料库任务',
      factList([['切换到', request.name]]) + `<p class="library-switch-tasks" role="status">${h(packageSwitchTasks().join('、'))}</p>`
      + '<p class="library-switch-note">任务结束后将关闭当前资料库。你可以取消切换，任务会继续执行。</p>',
      btn('取消切换', 'close'));
    packageSwitchTimer = setInterval(() => {
      if (!sheet.open) { clearPackageSwitch(); return; }
      const active = packageSwitchTasks();
      if (!active.length) { clearPackageSwitch(); request.open(); return; }
      const message = active.join('、');
      const status = sheet.querySelector('.library-switch-tasks');
      if (status && status.textContent !== message) status.textContent = message;
    }, 80);
    return;
  }
  clearPackageSwitch();
  for (const job of runningPackageJobs()) {
    job.state = job.delivery || job.quickPrompt ? 'unknown' : 'paused';
    if (job.delivery) job.deliveryStatus = '交付已中断，可核对后继续';
  }
  request.open();
};
sheet.addEventListener('close', () => { if (!sheet.open) clearPackageSwitch(); });

actions['package-title-path'] = (_, __, opener) => {
  if (S.page === 'welcome') return;
  opener?.focus({preventScroll:true});
  const {path} = packageLocation();
  const locations = [];
  for (let segment = path; segment; segment = segment.slice(0, segment.lastIndexOf('/'))) {
    locations.push(segment);
    if (!segment.includes('/')) break;
  }
  reviewDialog('资料库路径', `<p class="library-package-path" tabindex="0">${h(path)}</p><ol class="library-path-parents">${locations
    .map((location, index) => `<li>${index ? icon('folder', 16) : libraryFolderIcon()}<span>${h(index ? location.split('/').at(-1) : packageLabel(Studio.data))}</span></li>`).join('')}</ol>`,
    btn('拷贝资料库路径', 'package-path-copy') + btn('在 Finder 中显示', 'package-finder') + btn('完成', 'close'));
};
actions['package-path-copy'] = async () => {
  try {
    await navigator.clipboard.writeText(packageLocation().path);
    closeSheet();
    notify('已拷贝资料库路径');
  } catch {
    const path = $('.library-package-path');
    if (!path) return;
    const range = document.createRange();
    range.selectNodeContents(path);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
    path.focus();
  }
};
$('#chrome').addEventListener('contextmenu', (event) => {
  const title = event.target.closest('[data-act=package-title-path]');
  if (!title) return;
  event.preventDefault();
  actions['package-title-path']('', event, title);
});

function openKnownPackage(id) {
  const target = findPackage(id);
  if (!target) return;
  const location = packageLocation(target);
  if (target === Studio.data && S.page !== 'welcome') return closeSheet();
  if (location.unavailable) {
    reviewDialog('资料库包不可用', `<p>${h(location.path)} 所在的示例卷离线。接回原卷后可以重试。</p>`,
      btn('返回', 'close') + btn('模拟接回原卷', 'package-reconnect', id));
    return;
  }
  if (location.copyOf) {
    reviewDialog('作为独立本地库打开？',
      `<p>${h(location.path)}</p><p>副本保留目录、照片和版本，并使用新的资料库身份。原库的待处理任务留在原库。</p>`,
      btn('取消', 'close') + btn('作为独立本地库打开', 'package-fork', id, {cls:'primary'}));
    return;
  }
  askPackageSwitch(packageLabel(target), location.path, () => activatePackage(target));
}

function activatePackage(target) {
  const current = Studio.data;
  const nextLocation = packageLocation(target);
  nextLocation.recent = true;
  current.libraries ??= {};
  if (target !== current) {
    quickExitCanvas();
    dagLeavePhoto();
    for (const batch of current.dagBatches ?? []) {
      if (batch.running) {
        batch.running = false;
        batch.paused = true;
      }
    }
    const previous = librarySnapshot();
    previous.packageInfo = packageLocation(current);
    current.libraries[previous.packageInfo.id] = previous;
    delete current.libraries[nextLocation.id];
    for (const field of libraryFields) current[field] = target[field];
    current.packageInfo = nextLocation;
  }
  clearDelivery();
  Activity.leavePhoto();
  Activity.log('工作台', '已打开资料库');
  failedDagPhotos.clear();
  S.graphOpen = null;
  S.versionView = null;
  S.quickResume = null;
  S.jobsReturn = '';
  S.inspectIDs = S.processID = null;
  S.filters = S.search = false;
  S.scope = current.lastScope || 'project/' + current.catalog.projects[0].id;
  current.work = Studio.admitted().includes(current.work) ? current.work : Studio.admitted()[0] ?? 'r1';
  current.lastScope = S.scope;
  closeSheet();
  Studio.save();
  go('library/' + S.scope);
}

function newPackage(name, path, server = null, sync = false) {
  const id = Studio.uid();
  const records = Studio.emptyRecords();
  const ids = sync ? ['r1', 'r2', 'b1', 'w1'] : [];
  const catalog = {
    records, projects: [{ id: 'new', name: sync ? '湖岸拍摄' : '新项目', ids }],
    groups: [], sessions: [], collections: [], folders: [], packageName: name,
  };
  if (sync) ids.slice(1).forEach((id) => { records[id].online = false; });
  return {
    catalog, edits: {}, history: [], browse: {}, jobs: [],
    packageInfo: { id, libraryID: sync ? 'server-lakeside' : id, path, server, archived: ids },
  };
}

function packagePath(name, folder) {
  const filename = name.toLowerCase().endsWith(packageSuffix) ? name : name + packageSuffix;
  return folder.replace(/\/+$/, '') + '/' + filename;
}

function packageDestination(name, folder, except = null) {
  if (!name || name === '.' || name === '..' || /[/\\:]/.test(name) || !/^(~\/|\/)/.test(folder)) {
    reviewError('填写库名称和有效的本机目录，例如 ~/Pictures。');
    return null;
  }
  if (folder === '/Volumes/只读照片盘' || folder.startsWith('/Volumes/只读照片盘/')) {
    reviewError('所选保存目录不可写。请选择另一目录。');
    return null;
  }
  const path = packagePath(name, folder);
  if (availablePackages().some((snapshot) => snapshot !== except && packageLocation(snapshot).path === path)) {
    reviewError('这个位置已有资料库包。请选择其他名称或位置。');
    return null;
  }
  return path;
}

function packageForm(server = false) {
  const sync = server && S.serverSetup.mode === 'sync';
  const title = sync ? '同步已有库' : server ? '新建 Server 资料库' : '新建资料库';
  reviewDialog(title,
    (sync ? factList([['Server 资料库', '湖岸资料库'], ['快照', '修订 24 · 已验证'], ['访问', '本机所有者 · 可写']]) : '')
    + field('资料库名称', 'packageName', sync ? '湖岸资料库' : '旅行资料库') + field('所选保存目录', 'packageFolder', '~/Pictures')
    + (sync ? '<p>先下载目录与必要编辑资源。代理可随后加载，原片按需取回。</p>' : '')
    + '<p class="review-error" role="alert"></p>',
    btn('取消', 'close') + (server ? btn('上一步', 'package-server-choice') : '')
    + btn(sync ? '同步并打开' : '创建并打开', 'package-create', server ? 'server' : '', {cls:'primary'}));
}

actions['package-new'] = () => packageForm();
actions['package-create'] = (mode) => {
  const name = value('packageName').trim();
  const path = packageDestination(name, value('packageFolder').trim());
  if (!path) return;
  const sync = mode === 'server' && S.serverSetup.mode === 'sync';
  if (sync && availablePackages().some((snapshot) => {
    const location = packageLocation(snapshot);
    return !location.copyOf && location.libraryID === 'server-lakeside';
  })) {
    reviewError('已有这份 Server 库的本机副本。请从最近打开中接续。');
    return;
  }
  const server = mode === 'server' ? { address: S.serverSetup.address, online: true, image: false } : null;
  askPackageSwitch(name, path, () => activatePackage(newPackage(name, path, server, sync)));
};

actions['package-server'] = () => {
  reviewDialog('连接 RAWMaster Server', '<p>工作台使用示例 Server。可填 https://offline.test 走查连接失败。</p>'
    + field('服务器地址', 'serverAddress', S.serverSetup?.address || 'https://rawmaster.local:7443')
    + '<p class="review-error" role="alert"></p>',
    btn('取消', 'close') + btn('测试连接', 'package-server-test', '', {cls:'primary'}));
};
actions['package-server-test'] = () => {
  const address = value('serverAddress').trim();
  let host;
  try { host = new URL(address); } catch {}
  if (host?.protocol !== 'https:') return reviewError('请输入 HTTPS 服务器地址。');
  if (host.hostname === 'offline.test') return reviewError('无法连接服务器。检查地址后重试，也可返回新建资料库。');
  S.serverSetup = { address, mode: 'sync' };
  reviewDialog('核对服务器身份',
    factList([['服务器', address], ['SPKI 示例指纹', '8E:73:4C:19:AD:2C:0E:6B']])
    + '<p>请核对管理员提供的指纹。确认后工作台会模拟设备登记。</p>',
    btn('取消', 'close') + btn('确认指纹并继续', 'package-server-choice', '', {cls:'primary'}));
};
actions['package-server-choice'] = () => {
  reviewDialog('选择 Server 资料库',
    '<div class="menu-list">' + btn('新建 Server 资料库', 'package-server-path', 'new')
      + btn('同步已有库', 'package-server-path', 'sync') + '</div>'
      + rowCard('湖岸资料库', '示例已有库 · 修订 24 · 本机可登记为所有者'),
    btn('取消', 'close'));
};
actions['package-server-path'] = (mode) => {
  S.serverSetup.mode = mode;
  packageForm(true);
};

actions['package-finder'] = () => {
  reviewDialog('Finder 示例', '<p>双击库包，或用键盘聚焦并按 Return 打开。关闭的库包可在示例卷之间移动或拷贝。</p>'
    + availablePackages().map((snapshot) => {
      const location = packageLocation(snapshot);
      const current = snapshot === Studio.data;
      const row = rowCard(packageLabel(snapshot), location.path + (location.unavailable ? ' · 卷离线' : ''),
        btn('打开库包', 'package-finder-open', location.id, {title: '打开库包 ' + packageLabel(snapshot)})
        + (current ? '' : btn('移动…', 'package-file', 'move/' + location.id) + btn('拷贝…', 'package-file', 'copy/' + location.id)
          + btn(location.unavailable ? '接回示例卷' : '弹出示例卷', 'package-volume', location.id)));
      return `<div class="library-finder-row">${libraryFolderIcon()}${row}</div>`;
    }).join(''), btn('完成', 'close'));
};
actions['package-finder-open'] = (id, event) => {
  if (event.detail === 0) openKnownPackage(id);
};
sheet.addEventListener('dblclick', (event) => {
  const button = event.target.closest('[data-act=package-finder-open]');
  if (button) openKnownPackage(button.dataset.val);
});
actions['package-volume'] = (id) => {
  const snapshot = findPackage(id);
  const location = packageLocation(snapshot);
  snapshot.packageInfo = { ...location, unavailable: !location.unavailable };
  Studio.save();
  actions['package-finder']();
};
actions['package-reconnect'] = (id) => {
  const snapshot = findPackage(id);
  snapshot.packageInfo = { ...packageLocation(snapshot), unavailable: false };
  Studio.save();
  openKnownPackage(id);
};
actions['package-file'] = (request) => {
  const [operation, id] = request.split('/');
  const snapshot = findPackage(id);
  reviewDialog(operation === 'move' ? '移动库包' : '拷贝库包',
    factList([['来源', packageLocation(snapshot).path]]) + field('目标目录', 'finderFolder', '/Volumes/照片盘')
    + '<p class="review-error" role="alert"></p>',
    btn('返回 Finder 示例', 'package-finder') + btn(operation === 'move' ? '移动' : '拷贝', 'package-file-apply', request, {cls:'primary'}));
};
actions['package-file-apply'] = (request) => {
  const [operation, id] = request.split('/');
  const snapshot = findPackage(id);
  const location = packageLocation(snapshot);
  const path = packageDestination(packageLabel(snapshot), value('finderFolder').trim(), operation === 'move' ? snapshot : null);
  if (!path) return;
  if (operation === 'move') snapshot.packageInfo = { ...location, path, unavailable: false };
  else {
    const copy = structuredClone(snapshot);
    copy.packageInfo = { ...location, id: Studio.uid(), path, copyOf: id, unavailable: false };
    Studio.data.libraries[copy.packageInfo.id] = copy;
  }
  Studio.save();
  actions['package-finder']();
};
actions['package-fork'] = (id) => {
  const snapshot = findPackage(id);
  const {path} = packageLocation(snapshot);
  askPackageSwitch(packageLabel(snapshot), path, () => {
    snapshot.packageInfo = { id, libraryID: id, path };
    snapshot.jobs = [];
    snapshot.dagBatches = [];
    snapshot.history = [];
    snapshot.backupSnapshot = null;
    activatePackage(snapshot);
  });
};
