'use strict';

const serverJobKinds = { proxy: '生成显示代理', sdr: '渲染兼容 SDR 候选', flux: 'FLUX 生成候选' };

function serverPanel() {
  const location = packageLocation();
  const server = location.server;
  if (!server) return `<section class="settings-box"><h3>当前资料库仅保存在本机</h3>
    <p>可以连接 Server，再新建或同步一份资料库到本机。</p>
    ${btn('连接 RAWMaster Server…', 'package-server', '', {cls:'primary'})}</section>`;
  const photo = activeBrowser().focus;
  const archived = location.archived.includes(photo);
  return `<div class="tool-columns">
    <section><h3>连接与资料库</h3>${factList([
      ['当前资料库', packageLabel(Studio.data)], ['服务器', server.address], ['状态', server.online ? '在线' : '离线'],
      ['计算能力', server.image ? '显示代理、兼容 SDR、FLUX' : '资料库归档与取回'],
    ])}
    ${btn('查看制作任务', 'goto', 'jobs')}
    <details class="settings-advanced"><summary>走查连接与能力</summary>
      ${check('Server 在线', 'serverOnline', server.online)}${check('图像节点就绪', 'serverImage', server.image)}
    </details></section>
    <section><h3>处理当前照片</h3>
      ${factList([['当前照片', photo ? Studio.asset(photo).name : '尚未选片'], ['Server 原件', archived ? '已核验' : '无已核验归档']])}
      <p class="muted">${!archived ? '选择一张已归档的照片，再提交远端处理。' : '核对照片、版本和执行位置后提交。'}</p>
      ${btn('准备远端处理…', 'server-job-review', photo, {cls:'primary', disabled: !archived})}
      <details class="settings-advanced"><summary>归档与恢复走查</summary>
        ${btn('查看五文件归档清单', 'server-example', 'archive')}${btn('查看连接中断与恢复', 'server-example', 'restore')}
      </details>
    </section></div>`;
}

for (const [input, field] of [['serverOnline', 'online'], ['serverImage', 'image']]) {
  changes[input] = (event) => {
    packageLocation().server[field] = event.checked;
    const expanded = event.closest('details')?.open;
    Studio.save();
    render();
    const control = $(`[name=${input}]`);
    control.closest('details').open = expanded;
    control.focus({preventScroll:true});
  };
}

actions['server-example'] = (scenario) => {
  const archive = scenario === 'archive';
  reviewDialog(archive ? '五文件归档清单' : '断线与恢复',
    archive ? factList([
      ['纳入', 'A.JPG'], ['仅序列纳入', 'B.RAW'], ['仅历史', 'A.RAW、C.RAW（排除）'], ['失败', 'D.RAW（核验失败）'],
      ['提交后', 'Direct 上传中断时，Relay 续传缺失分片，验证整对象后登记引用'],
    ]) : factList([
      ['断线', '继续本机浏览和选片'],
      ['重连', '按原修订和提交收据补差'],
      ['隔离恢复', '核对快照、对象和当前写授权后恢复写入'],
    ]), btn('完成', 'close'));
};

actions['server-job-review'] = (photo) => {
  const {server, archived} = packageLocation();
  if (!server || !archived.includes(photo)) return;
  const edit = Studio.edit(photo);
  reviewDialog('提交到 RAWMaster Server',
    factList([['照片', Studio.asset(photo).name], ['冻结版本', edit.versions.find((v) => v.id === edit.adopted)?.name || '原始版本'],
      ['执行位置', server.address]])
    + select('处理方式', 'remoteKind', Object.entries(serverJobKinds), 'sdr')
    + `<div data-remote-prompt hidden><p>Server 将处理已归档的整张照片和这条指令。</p>${field('生成指令', 'remotePrompt')}</div>`
    + '<p>生成候选需在编辑中查看，成片写盘及回执继续通过导出工作台。</p>'
    + (!server.image ? '<p role="status">此 Server 的图像节点未就绪。可返回使用本机编辑或导出。</p>' : '')
    + (!server.online ? '<p role="status">Server 离线。提交意图留在本机，联网后可继续。</p>' : '')
    + `<details class="settings-advanced"><summary>走查提交回执</summary>${check('模拟提交回执丢失', 'remoteLostAck')}</details><p class="review-error" role="alert"></p>`,
    btn('取消', 'close') + btn(server.online ? '提交' : '联网后提交', 'server-job-submit', photo, {cls:'primary', disabled: !server.image}));
};
changes.remoteKind = (input) => { sheet.querySelector('[data-remote-prompt]').hidden = input.value !== 'flux'; };

actions['server-job-submit'] = (photo) => {
  const {server} = packageLocation();
  const kind = value('remoteKind');
  if (!server?.image || !Object.hasOwn(serverJobKinds, kind)) return;
  const edit = Studio.edit(photo);
  const prompt = kind === 'flux' ? value('remotePrompt').trim() : '';
  if (kind === 'flux' && edit.conversation?.strict) return reviewError('严格纪实作品禁止提交生成式改写。');
  if (kind === 'flux' && !prompt) return reviewError('填写生成指令后再提交。');
  const version = edit.adopted;
  const recipe = structuredClone(edit.recipe);
  const ongoing = Studio.data.jobs.find((job) => job.photo === photo && job.remote?.kind === kind && job.remote.version === version
    && job.remote.prompt === prompt && !['done', 'failed', 'cancelled'].includes(job.state)
    && JSON.stringify(job.recipe) === JSON.stringify(recipe));
  if (!ongoing) {
    const online = server.online;
    const job = {
      id: Studio.uid(), photo, kind: serverJobKinds[kind], recipe,
      state: !online ? 'waiting' : checked('remoteLostAck') ? 'unknown' : 'queued',
      remote: { kind, prompt, status: online ? 'queued' : 'local', version,
        versionName: edit.versions.find((v) => v.id === version)?.name || '原始版本', attempt: Number(online) },
    };
    Studio.data.jobs.unshift(job);
    Studio.save();
  }
  closeSheet();
  go('jobs');
};

function serverJobDetail(job) {
  const remote = job.remote;
  const {server} = packageLocation();
  const state = job.state;
  const inFlight = ['waiting', 'queued', 'unknown', 'cancelling'].includes(state);
  const canCancel = inFlight && state !== 'cancelling';
  const canCheck = ['waiting', 'queued', 'unknown', 'cancelling'].includes(state);
  const action = (label, op, options) => btn(label, 'server-job-action', op + '/' + job.id, options);
  const status = [
    !server.online && inFlight ? 'Server 离线' : '',
    state === 'unknown' ? '提交结果待核对。联网后使用原任务 ID 查询。' : '',
    state === 'cancelling' ? '取消意图已保存，等待 Server 回执。' : '',
    state === 'available' ? '结果已在 Server 发布，待本机取回并校验。' : '',
    remote.cancelLost ? '发布先于取消完成，已发布结果保留。' : '',
    remote.issue, remote.stale ? '原编辑已变化，候选仍与提交时的版本关联。' : '',
  ].filter(Boolean);
  const review = [
    remote.status === 'queued' ? action('模拟 Server 发布', 'publish') + action('模拟 Server 失败', 'fail') : '',
    remote.status === 'published' && state !== 'done' ? check('模拟下载校验失败', 'remoteCorrupt') : '',
  ].join('');
  reviewDialog(job.kind, factList([
    ['资料库', packageLabel(Studio.data)], ['照片', Studio.asset(job.photo).name], ['冻结版本', remote.versionName],
    ['位置', 'RAWMaster Server'], ['任务 ID', job.id], ['尝试', remote.attempt], ['状态', jobNames[state]],
    ...(remote.prompt ? [['生成指令', remote.prompt]] : []),
  ]) + status.map((line) => `<p role="status">${h(line)}</p>`).join('')
    + (review ? `<details class="settings-advanced"><summary>走查 Server 回报</summary><div class="row wrap">${review}</div></details>` : ''),
    btn('完成', 'close')
    + (canCancel ? action('取消任务', 'cancel') : '')
    + (canCheck ? action(state === 'unknown' ? '核对原任务' : '更新状态', 'check', {disabled: !server.online}) : '')
    + (['failed', 'cancelled'].includes(state) ? action('重试原任务', 'retry', {disabled: !server.online || !server.image}) : '')
    + (state === 'available' ? action(remote.issue ? '重试取回' : '取回并校验', 'fetch', {disabled: !server.online, cls:'primary'}) : '')
    + (job.result ? btn('查看候选', 'job-version', job.id) : ''));
}

actions['server-job-action'] = (request) => {
  const [op, id] = request.split('/');
  const job = Studio.data.jobs.find((item) => item.id === id);
  if (!job?.remote) return;
  const {server} = packageLocation();
  const remote = job.remote;
  const reconcile = () => {
    if (job.state === 'cancelling') {
      if (remote.status === 'published') remote.cancelLost = true;
      else remote.status = 'cancelled';
    }
    else if (remote.status === 'local' && server.image) {
      remote.status = 'queued';
      remote.attempt++;
    }
    job.state = {local:'waiting', published:'available', queued:'queued', failed:'failed', cancelled:'cancelled'}[remote.status];
  };
  if (op === 'publish' || op === 'fail') {
    remote.status = op === 'publish' ? 'published' : 'failed';
    remote.issue = op === 'fail' ? 'Server 执行失败，原输入与任务 ID 已保留。' : '';
    if (server.online && !['unknown', 'cancelling'].includes(job.state)) reconcile();
  } else if (op === 'cancel') {
    job.state = 'cancelling';
    if (remote.status === 'local' || server.online) reconcile();
  } else if (op === 'check' && server.online) {
    reconcile();
  } else if (op === 'retry' && server.online && server.image) {
    remote.status = job.state = 'queued';
    remote.attempt++;
    remote.issue = '';
  } else if (op === 'fetch' && server.online && job.state === 'available') {
    if (checked('remoteCorrupt')) remote.issue = '校验失败。请重试取回同一结果。';
    else {
      const edit = Studio.edit(job.photo);
      remote.stale = remote.kind !== 'proxy' && (edit.adopted !== remote.version || JSON.stringify(edit.recipe) !== JSON.stringify(job.recipe));
      if (remote.kind === 'proxy') remote.issue = '显示代理已缓存。';
      else {
        const version = Studio.candidate(job.photo, job.kind, job.recipe, remote.version);
        version.serverResult = { jobID: job.id, kind: remote.kind };
        job.result = version.id;
        remote.issue = '候选已保存，可在版本中核对。';
      }
      job.state = 'done';
    }
  }
  Studio.save();
  if (S.page === 'jobs') {
    render();
    sheetOpener = document.querySelector('[data-act=job-detail][data-val="' + CSS.escape(id) + '"]');
  }
  serverJobDetail(job);
};

function serverAdoptionIssue(version, edit) {
  if (!version?.serverResult) return '';
  if (version.serverResult.kind === 'flux' && edit.conversation?.strict) return '严格纪实作品无法采用生成候选。';
  if (version.parent !== edit.adopted || JSON.stringify(version.recipe) !== JSON.stringify(edit.recipe))
    return '当前编辑与提交时不同。可查看原候选。';
  return '';
}
