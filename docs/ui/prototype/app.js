'use strict';

const providers = ['GPT Image', 'Seedream / 中国方舟', 'Nano Banana'];
const fluxFiles = [
  'q8/manifest.json',
  'q8/transformer/conditioning.safetensors',
  'q8/transformer/single_blocks.00.safetensors',
  'q8/transformer/single_blocks.14.safetensors',
  'q8/transformer/single_blocks.27.safetensors',
  'q8/text_encoder/layer-00.safetensors',
  'q8/text_encoder/layer-16.safetensors',
  'q8/text_encoder/layer-31.safetensors',
  'q8/image_conditioning/conditioning.safetensors',
  'vae-fp32/vae.safetensors',
  'assets/tokenizer.json',
];
let fluxTimer = null;
function fluxBytes(value) {
  if (value >= 1073741824) return (value / 1073741824).toFixed(2) + ' GiB';
  return Math.max(0, Math.round(value / 1048576)) + ' MiB';
}
function fluxFileFor(progress) {
  return fluxFiles[Math.min(fluxFiles.length - 1, Math.floor(progress * fluxFiles.length))];
}
function fluxTick() {
  clearInterval(fluxTimer);
  fluxTimer = setInterval(() => {
    const f = Studio.data.prefs.flux;
    if (f.status !== '下载中') {
      clearInterval(fluxTimer);
      return;
    }
    f.completed = Math.min(f.total, f.completed + Math.max(12 * 1048576, Math.round(f.total / 36)));
    f.progress = f.completed / f.total;
    f.file = fluxFileFor(f.progress);
    if (f.completed >= f.total) {
      f.progress = 1;
      f.status = '校验中';
      f.file = '正在逐文件校验 SHA-256';
      clearInterval(fluxTimer);
      setTimeout(() => {
        const current = Studio.data.prefs.flux;
        if (current.status !== '校验中') return;
        current.status = '就绪';
        current.file = '';
        Studio.save();
        if (S.page === 'settings' && S.sub === 'runtime') render();
        notify('FLUX.3 Klein 已就绪');
      }, 900);
    }
    Studio.save();
    if (S.page === 'settings' && S.sub === 'runtime') render();
  }, 520);
}
function firstRunDialog() {
  const f = Studio.data.prefs.flux;
  dialog(
    '开始本机 AI 修图？',
    `<p>RAWMaster 可以在本机运行 FLUX.3 Image Klein，清理局部干扰、补全背景或调整光色。照片不会上传。</p>
     ${factList([
       ['下载', '约 9.58 GiB · 102 个文件'],
       ['运行', 'Apple Silicon · Metal'],
       ['许可', 'FLUX Kommunity License'],
       ['稍后', '可随时从“设置 → 本机 AI”下载'],
     ])}
     ${check('我已阅读并接受 FLUX Kommunity License', 'fluxFirstLicense', f.license)}
     <p class="muted">下载会逐文件校验，支持暂停和继续。首次下载完成前，本机 Quick Prompt 保持不可用。</p>`,
    btn('稍后', 'flux-first-later') + btn('下载模型', 'flux-first-download', '', { cls: 'primary' }),
  );
}
function settingsPanel(key) {
  const d = Studio.data,
    p = d.prefs,
    back = btn('返回当前照片', 'goto', S.editReturn, { disabled: !Studio.admitted().length });
  if (key === 'general')
    return `<section class="settings-box"><h3>外观</h3>${select(
      '界面外观',
      'theme',
      [
        ['system', '跟随系统'],
        ['light', '浅色'],
        ['dark', '深色'],
      ],
      p.theme,
    )}
    <h3>照片编辑</h3><p>色彩外观随照片的调整保存。AI 与外部编辑结果可从「快照 → 更多 → 已有编辑结果」查看和采用。</p>
    <h3>原型样本</h3><p>本机浏览器保存示例选片、版本和设置。可以恢复到初始拍摄项目。</p>${btn('重置示例工作台…', 'reset-demo')}</section>`;
  if (key === 'storage')
    return `<section class="settings-box">${factList([
      ['当前资料库', Studio.catalog().packageName || '本机资料库'],
      ['示例调整归档', Object.values(d.edits).reduce((n, e) => n + e.versions.length, 0) + ' 个候选'],
      ['模型目录', p.modelDir || '受管目录'],
    ])}${btn('打开备份与还原', 'goto', 'tools/package')}</section>`;
  if (key === 'editing')
    return `<section class="settings-box"><h3>编辑预览</h3>${select('暗房背景', 'ground', ['深灰', '中灰', '浅灰', '纯黑'], p.ground)}${select(
      '渲染速度',
      'performance',
      ['均衡', '极速'],
      p.performance || '均衡',
    )}<p>${
      (p.performance || '均衡') === '极速'
        ? '极速：缩放中可暂用低分辨率预览；停止后按当前倍率从原图取样，不改变倍率。'
        : '均衡：缩放中按当前倍率请求原图细节；停止后的画质与极速相同。'
    }</p>${factList(
      [
        ['当前预览', '仓库 JPEG 衍生图'],
        ['实际像素复核', '在原生工作区验证'],
      ],
    )}${btn('查看图像性能监控', 'monitor')}</section>`;
  if (key === 'runtime') {
    const f = p.flux,
      percent = Math.round(f.progress * 100),
      ready = f.status === '就绪',
      busy = f.status === '下载中' || f.status === '校验中',
      paused = f.status === '已暂停';
    const main = ready
      ? btn('校验模型文件', 'flux-verify')
      : busy
        ? btn(f.status === '校验中' ? '正在校验…' : '暂停下载', 'flux-pause', '', { disabled: f.status === '校验中' })
        : paused
          ? btn('继续下载', 'flux-resume', '', { cls: 'primary' })
          : f.status === '失败'
            ? btn('重新下载', 'flux-start', '', { cls: 'primary', disabled: !f.license })
            : btn('下载模型（9.58 GiB）', 'flux-start', '', { cls: 'primary', disabled: !f.license });
    return `<section class="settings-box">
      <h3>FLUX.3 Image Klein · 本机</h3>
      <div class="flux-status"><span class="flux-dot ${ready ? 'ready' : busy ? 'busy' : f.status === '失败' ? 'error' : ''}"></span><strong>${h(f.status)}</strong><span class="muted">${ready ? '可离线修图' : f.status === '失败' ? '可重试，已下载文件会保留' : '模型权重 + 分词器 + VAE，共约 9.58 GiB'}</span></div>
      ${factList([
        ['模型', 'FLUX.3 Image Klein · Q8 · 16 步'],
        ['下载位置', p.fluxDir || '应用管理目录 / Flux3Klein'],
        ['许可', 'FLUX Kommunity License'],
      ])}
      ${
        busy || paused || f.completed > 0
          ? `<div class="flux-progress"><i style="width:${percent}%"></i></div>
             <div class="flux-progress-line"><span>${fluxBytes(f.completed)} / ${fluxBytes(f.total)} · ${percent}%</span><span>${h(f.file || '等待选择文件')}</span></div>
             <p class="muted">${busy ? '关闭设置后下载仍在后台继续；暂停时已完成文件和当前断点都保留。' : paused ? '已暂停。继续时从当前文件断点续传，已下载字节不会重复。' : ready ? '已完成逐文件 SHA-256 校验。' : '上次中断，可从断点继续。'}</p>`
          : ''
      }
      ${f.error ? `<p class="flux-error">${h(f.error)}</p>` : ''}
      <div class="row wrap">${main}${ready ? btn('删除模型', 'flux-delete') : paused ? btn('取消并删除', 'flux-delete') : ''}${btn('在 Finder 中显示', 'flux-reveal', '', { disabled: !ready })}</div>
      <div class="flux-license">${check('我已阅读并接受 FLUX Kommunity License', 'fluxLicense', f.license)}${btn('阅读许可…', 'flux-license')}</div>
      <p class="muted">首次下载前必须核对许可。模型只在本机运行，不会上传照片。8 步或 FP16 速度模式在“编辑与预览”中另行评估。</p>
      <details class="settings-advanced"><summary>实验：Qwen2.1 / ComfyUI 运行时</summary>
        ${factList([
          ['状态', p.runtime],
          ['模型来源', p.modelDir || '受管目录'],
        ])}
        ${select('模型目录', 'modelDir', ['受管目录', '已有目录（只读复用）'], p.modelDir)}
        ${check('已阅读示例模型使用条款', 'licenseAck')}
        <div class="row wrap">${btn(p.runtime === '就绪' ? '校验并修复' : '准备示例环境', 'prepare-runtime')}</div>
        <p class="muted">保留旧实验链路；普通修图不再需要 Python、ComfyUI 或手动选择运行时目录。</p>
      </details>
      <h3>首次启动提示</h3>
      <p class="muted">没有模型时，应用首次启动会提供“下载 9.58 GiB / 稍后”。稍后仍可从本页下载。</p>
      ${btn('预览首次启动提示', 'flux-first-run')}
      ${back}
    </section>`;
  }
  if (key === 'cloud')
    return `<section class="settings-box"><h3>生成服务</h3>${select('服务', 'cloudName', providers, p.cloudName || providers[0])}${factList(
      [
        ['配置', p.cloud],
        ['输入', '示例凭证'],
      ],
    )}
    <div class="row wrap">${btn('保存示例配置', 'cloud-save', '', { cls: 'primary' })}${btn('停用', 'cloud-stop', '', { disabled: p.cloud !== '已配置' })}${back}</div></section>`;
  return `<section class="settings-box"><h3>诊断</h3>${factList([
    ['图像性能', '示例会话'],
    ['任务数', d.jobs.length],
    ['编辑候选', Object.values(d.edits).reduce((n, e) => n + e.versions.length, 0)],
  ])}
    ${btn('打开性能监控', 'monitor', '', { icon: 'pulse' })}${btn('导出诊断摘要', 'diagnostic-export')}</section>`;
}
changes.theme = (el) => {
  Studio.data.prefs.theme = el.value;
  Studio.save();
  render();
};
changes.performance = (el) => {
  Studio.data.prefs.performance = el.value;
  Studio.save();
  render();
  $('[name=performance]')?.focus({ preventScroll: true });
};
changes.modelDir = (el) => {
  Studio.data.prefs.modelDir = el.value;
  Studio.save();
  render();
};
changes.fluxLicense = (el) => {
  Studio.data.prefs.flux.license = el.checked;
  Studio.save();
  render();
};
changes.fluxFirstLicense = (el) => {
  Studio.data.prefs.flux.license = el.checked;
  Studio.save();
};
changes.cloudName = (el) => {
  Studio.data.prefs.cloudName = el.value;
  Studio.data.prefs.cloud = '未配置';
  Studio.save();
  render();
};
actions['cloud-save'] = () => {
  Studio.data.prefs.cloud = '已配置';
  Studio.save();
  render();
  notify('示例配置已保存');
};
actions['cloud-stop'] = () => {
  Studio.data.prefs.cloud = '未配置';
  Studio.save();
  render();
};
actions['prepare-runtime'] = () => {
  if (!checked('licenseAck', $('#workspace'))) {
    notify('请先核对示例模型条款');
    return;
  }
  startJob('准备本机 AI 环境', null);
};
actions['flux-start'] = () => {
  const f = Studio.data.prefs.flux;
  if (!checked('fluxLicense', $('#workspace')) && !f.license) {
    notify('请先核对 FLUX Kommunity License');
    return;
  }
  f.license = true;
  if (!navigator.onLine) {
    f.status = '失败';
    f.error = '当前离线。已下载的模型仍可离线使用；恢复网络后可续传。';
    Studio.save();
    render();
    return;
  }
  f.error = '';
  f.paused = false;
  f.status = '下载中';
  f.file = fluxFileFor(f.progress || 0);
  Studio.save();
  render();
  fluxTick();
};
actions['flux-pause'] = () => {
  const f = Studio.data.prefs.flux;
  if (f.status !== '下载中') return;
  clearInterval(fluxTimer);
  f.status = '已暂停';
  f.paused = true;
  Studio.save();
  render();
};
actions['flux-resume'] = () => {
  const f = Studio.data.prefs.flux;
  if (f.status !== '已暂停') return;
  f.status = '下载中';
  f.paused = false;
  Studio.save();
  render();
  fluxTick();
};
actions['flux-verify'] = () => {
  const f = Studio.data.prefs.flux;
  if (f.status !== '就绪') return;
  f.status = '校验中';
  f.file = '正在逐文件校验 SHA-256';
  Studio.save();
  render();
  setTimeout(() => {
    const current = Studio.data.prefs.flux;
    current.status = '就绪';
    current.file = '';
    Studio.save();
    if (S.page === 'settings' && S.sub === 'runtime') render();
    notify('模型文件校验通过');
  }, 900);
};
actions['flux-delete'] = () => {
  const f = Studio.data.prefs.flux;
  if (f.status !== '就绪' && f.status !== '已暂停') return;
  dialog('删除本机模型？',
    '<p>删除后 Quick Prompt 的本机模型将不可用；已采用的候选和作品版本不受影响。下次可在设置中重新下载。</p>',
    btn('取消', 'close') + btn('删除模型', 'flux-delete-confirm', '', { cls: 'danger' }));
};
actions['flux-delete-confirm'] = () => {
  clearInterval(fluxTimer);
  Object.assign(Studio.data.prefs.flux, defaultFlux(), { firstRunShown: Studio.data.prefs.flux.firstRunShown });
  Studio.save();
  closeSheet();
  render();
  notify('本机模型已删除');
};
actions['flux-license'] = () => dialog(
  'FLUX Kommunity License',
  `<p>此示例页面用于核对下载前的许可与用途提示。正式应用会展示随模型包固定版本的许可文本和链接。</p>
   <p class="muted">FLUX.3 Klein 权重不是 Apache-2.0。商业使用、分发权重或生成内容需按许可条款单独确认。</p>`,
  btn('完成', 'close'),
);
actions['flux-reveal'] = () => {
  if (Studio.data.prefs.flux.status !== '就绪') return;
  notify('已在 Finder 中显示模型目录');
};
actions['flux-first-run'] = () => firstRunDialog();
actions['flux-first-download'] = () => {
  const f = Studio.data.prefs.flux;
  if (!checked('fluxFirstLicense') && !f.license) {
    notify('请先勾选并接受 FLUX Kommunity License');
    return;
  }
  f.license = true;
  f.firstRunShown = true;
  f.status = '下载中';
  f.file = fluxFileFor(f.progress || 0);
  f.error = '';
  Studio.save();
  closeSheet();
  go('settings/runtime');
  fluxTick();
};
actions['flux-first-later'] = () => {
  Studio.data.prefs.flux.firstRunShown = true;
  Studio.save();
  closeSheet();
  notify('稍后可从“设置 → 本机 AI”下载模型');
};
actions.monitor = () =>
  dialog(
    '图像性能监控',
    `<p>示例监控窗口</p>${factList([
      ['预览来源', 'JPEG 示例'],
      ['处理中', Studio.data.jobs.filter((j) => j.state === 'running').length + ' 项'],
      ['真实 GPU 与呈现耗时', '需在原生诊断窗口采集'],
    ])}`,
    btn('完成', 'close'),
  );
actions['diagnostic-export'] = () =>
  demoDownload('rawmaster-demo-diagnostics.json', {
    prototype: true,
    jobs: Studio.data.jobs.length,
    appearance: Studio.data.prefs.theme,
  });
actions['reset-demo'] = () =>
  dialog(
    '恢复示例工作台？',
    '<p>清除本工作台在当前浏览器中保存的示例照片决定、候选、任务与设置。</p>',
    btn('取消', 'close') + btn('恢复初始样本', 'reset-confirm'),
  );
actions['reset-confirm'] = () => {
  closeSheet();
  Studio.reset();
  clearDelivery();
  S.scope = 'project/river';
  S.filters = false;
  S.search = false;
  S.inspectIDs = null;
  S.processID = null;
  go('library/project/river');
};
function startJob(kind, photo, group = null, agent = null, quickPrompt = null) {
  const job = {
    id: Studio.uid(),
    kind,
    photo,
    group,
    agent,
    ...(quickPrompt ? { quickPrompt } : {}),
    state: 'running',
    due: Date.now() + 1800,
    recipe: photo ? structuredClone(Studio.edit(photo).recipe) : null,
  };
  Studio.data.jobs.unshift(job);
  Activity.log('任务', '已加入队列 · ' + job.kind);
  Studio.save();
  if (!quickPrompt) go('jobs');
  if (quickPrompt || S.page === 'jobs') render();
  if (quickPrompt) $('.quick-head')?.focus({ preventScroll: true });
  return job;
}
const jobNames = {
  running: '处理中',
  done: '已完成',
  cancelled: '已取消',
  unknown: '结果待核对',
  failed: '失败',
};
function settleJobs() {
  let modified = false, quickChanged = false;
  for (const j of Studio.data.jobs) {
    if (j.delivery || j.state !== 'running' || Date.now() < j.due) continue;
    j.state = 'done';
    Activity.log('任务', '已完成 · ' + j.kind);
    modified = true;
    if (j.kind === '准备本机 AI 环境') Studio.data.prefs.runtime = '就绪';
    else if (j.group) j.result = j.group.group + ' · ' + j.kind + (j.kind === '延时视频' ? '.mp4' : '.tiff');
    else if (j.quickPrompt) {
      j.result = quickFinished(j);
      quickChanged ||= j.photo === Studio.data.work;
    } else if (j.photo) {
      const v = Studio.candidate(j.photo, j.kind, j.recipe);
      j.result = v.id;
    }
  }
  if (modified) {
    Studio.save();
    if (S.page === 'jobs' || S.page === 'settings' || (S.page === 'edit' && (S.tool === 'versions' || quickChanged))) render();
    if (sheet.open && sheet.dataset.job) actions['job-detail'](sheet.dataset.job);
  }
}
function jobsView() {
  const jobs = Studio.data.jobs;
  return `<section class="jobs-page"><div class="crumb">RAWMaster <span>/</span> 后台作业</div><h1>制作任务</h1><p class="muted">示例作业保留输入与版本，可在切换照片后继续查看。</p>
    ${jobs.map((j) => rowCard(j.kind, (j.photo ? Studio.asset(j.photo).name + ' · ' : '') + jobNames[j.state], btn('查看详情', 'job-detail', j.id))).join('') || empty('暂无制作任务', '在编辑中生成候选，或从拍摄组制作成片。')}
    <div class="row wrap">${btn('返回资料库', 'goto', 'library/' + S.scope)}${btn('返回当前照片', 'goto', S.editReturn, { disabled: !Studio.admitted().length })}${S.exportKey ? btn('导出面板与交付记录', 'goto', 'export') : ''}</div></section>`;
}
actions['job-detail'] = (id) => {
  const j = Studio.data.jobs.find((x) => x.id === id);
  if (!j) return;
  if (j.delivery) {
    deliveryReceipt(j);
    return;
  }
  dialog(
    j.kind,
    factList([
      ['状态', jobNames[j.state]],
      ['输入', j.photo ? Studio.asset(j.photo).name : '本机环境'],
      ...(j.quickPrompt
        ? [['模型', promptModels[j.quickPrompt.model]], ['范围', quickScopeTitle(j.quickPrompt.scope)], ['Prompt', j.quickPrompt.text]]
        : []),
      ...(j.agent
        ? [
            ...(j.agent.requests ?? [j.agent.request]).map((request, i) => ['要求 ' + (i + 1), request]),
            ['执行位置', j.agent.provider],
          ]
        : []),
      ...(j.group
        ? [
            ['拍摄组', j.group.group],
            ['冻结成员', j.group.ids.map((id) => Studio.asset(id).name).join('、')],
            ['参数', Object.values(j.group.settings).join(' / ') || '默认'],
          ]
        : []),
      ...(j.result
        ? [
            [
              '结果',
              j.group
                ? j.result
                : Studio.edit(j.photo).versions.find((v) => v.id === j.result)?.name || '候选',
            ],
          ]
        : []),
    ]),
    btn('完成', 'close') +
      (j.state === 'running'
        ? btn('取消任务', 'job-change', 'cancel/' + id) +
          btn('模拟中断', 'job-change', 'interrupt/' + id) +
          btn('模拟失败', 'job-change', 'fail/' + id)
        : '') +
      (['cancelled', 'failed'].includes(j.state) ? btn('重试', 'job-change', 'retry/' + id) : '') +
      (j.state === 'unknown' ? btn('核对原任务结果', 'job-change', 'reconcile/' + id) : '') +
      (j.result && !j.group ? btn('查看候选', 'job-version', id) : ''),
  );
  sheet.dataset.job = id;
};
actions['job-change'] = (v) => {
  const [op, id] = v.split('/'),
    j = Studio.data.jobs.find((x) => x.id === id);
  if (!j) return;
  if (j.quickPrompt) return quickJobAction(op, j);
  if (['cancel', 'interrupt', 'fail'].includes(op) && j.state !== 'running') return;
  if (op === 'fail') j.state = 'failed';
  else if (op === 'cancel') j.state = 'cancelled';
  else if (op === 'interrupt') j.state = 'unknown';
  else {
    j.state = 'running';
    j.due = Date.now() + 1500;
  }
  Studio.save();
  closeSheet();
  render();
};
actions['job-version'] = (id) => {
  const j = Studio.data.jobs.find((x) => x.id === id);
  if (j?.quickPrompt && !j.quickPrompt.reviewed) return quickOpenJob(j);
  S.beforeVersions = S.editReturn === 'edit/versions' ? 'edit/development' : S.editReturn;
  withPhoto(j.photo);
  S.pendingResult = j.result;
  closeSheet();
  go('edit/versions');
};
function chrome() {
  const page = S.page,
    part = ['library', 'edit', 'export'].includes(page) ? page : page === 'tools' ? 'library' : '';
  const work = Studio.data.work;
  const sidebarVisible = compactLibraryNavigation.matches ? S.drawer : S.librarySidebar;
  const sidebar = page === 'library' ? btn('资料库导航', 'drawer', '', {
    icon: 'sidebar', only: true, cls: 'icon-btn', pressed: sidebarVisible,
  }) : '';
  return `<div class="chrome-navigation">${sidebar}</div>
    <nav class="workflow-switch" aria-label="工作流">${[
      ['library', '资料库', 'library'],
      ['edit', '编辑', 'sliders'],
      ['export', '导出', 'export'],
    ]
      .map(([k, n, ic]) =>
        btn(n, 'workflow', k, {
          icon: ic,
          pressed: part === k,
          disabled:
            (k === 'edit' && !(page === 'library' ? validWork(libraryEditTarget()) : validWork(work))) ||
            (k === 'export' && page === 'library' && isTriage()),
        }),
      )
      .join('')}</nav>
    <div class="chrome-actions"><details class="window-menu"><summary>窗口</summary><div>${btn('后台信息','activity-window-menu')}</div></details>${btn('后台信息','activity-open','',{icon:'pulse',only:true,cls:'icon-btn'})}${btn('设置', 'goto', 'settings/general', { icon: 'settings', only: true, cls: 'icon-btn', pressed: page === 'settings' })}</div>`;
}
function render() {
  const previous = document.activeElement;
  const details = $$('.mask-group[data-mask-group]');
  if (details.length) S.maskGroups = new Set(details.filter((group) => group.open).map((group) => group.dataset.maskGroup));
  const root = $('#workspace'),
    exp = S.page === 'export',
    p = Studio.data.prefs;
  document.documentElement.dataset.theme = p.theme;
  $('#chrome').innerHTML = chrome();
  Activity.refresh();
  root.hidden = exp;
  $('#delivery').hidden = !exp;
  if (exp) {
    renderDelivery(root);
    return;
  }
  const left = root.querySelector('.photos-scroll')?.scrollTop ?? 0,
    strip = root.querySelector('.filmstrip')?.scrollLeft ?? 0,
    stripFocus = root.querySelector('.filmstrip .chosen')?.dataset.val,
    side = root.querySelector('.inspector,.inspector-content')?.scrollTop ?? 0,
    toolsLeft = root.querySelector('.edit-left')?.scrollTop ?? 0,
    previousDock = root.querySelector('.canvas-tool-dock'),
    toolScroll = previousDock?.querySelector('.canvas-tool-body').scrollTop ?? 0,
    darkroom = root.querySelector('.edit-body')?.scrollTop ?? 0,
    pan =
      root.querySelector('.edit-page')?.dataset.photo === Studio.data.work
        ? $$('.canvas-fit').map((fit) => [fit.scrollLeft, fit.scrollTop])
        : [];
  const noticeHost = S.page === 'edit' && root.querySelector('.edit-page')?.dataset.photo === Studio.data.work
    ? root.querySelector('.editor-notices') : null;
  root.innerHTML =
    S.page === 'library'
      ? libraryView()
      : S.page === 'edit'
        ? editorView()
        : S.page === 'jobs'
          ? jobsView()
          : toolView();
  if (noticeHost) {
    const replacement=root.querySelector('.editor-notices');
    if (replacement && noticeHost.firstElementChild?.dataset.noticeId===replacement.firstElementChild?.dataset.noticeId) replacement.replaceWith(noticeHost);
  }
  if (S.page === 'edit') {PhotographicScopes.drawImagePreview();refreshSamplerPanel();}
  if (S.renderRoute === location.hash) {
    const scroll = root.querySelector('.photos-scroll'),
      ins = root.querySelector('.inspector,.inspector-content');
    if (scroll) scroll.scrollTop = left;
    if (ins) ins.scrollTop = side;
    const film = root.querySelector('.filmstrip');
    if (film) film.scrollLeft = strip;
  }
  const chosen = root.querySelector('.filmstrip .chosen');
  if (chosen && (S.renderRoute !== location.hash || stripFocus !== chosen.dataset.val)) {
    const film = chosen.closest('.filmstrip'), bounds = film.getBoundingClientRect(), card = chosen.getBoundingClientRect();
    film.scrollLeft += card.left < bounds.left ? card.left - bounds.left - 4
      : Math.max(0, card.right - bounds.right + 4);
  }
  if (S.page === 'edit' && S.renderRoute?.startsWith('#edit/')) {
    root.querySelector('.edit-left').scrollTop = toolsLeft;
    root.querySelector('.edit-body').scrollTop = darkroom;
    const dock = root.querySelector('.canvas-tool-dock');
    if (dock && dock.dataset.canvasExpanded === previousDock?.dataset.canvasExpanded) dock.querySelector('.canvas-tool-body').scrollTop = toolScroll;
    $$('.canvas-fit').forEach((fit, i) => {
      if (pan[i]) [fit.scrollLeft, fit.scrollTop] = pan[i];
    });
    const log = root.querySelector('.chat-log');
    if (log) log.scrollTop = log.scrollHeight;
  }
  if (S.renderRoute === location.hash && previous && !previous.isConnected && !sheet.open) {
    const next = previous.name
      ? Array.from(root.querySelectorAll('[name]')).find(
          (el) => el.name === previous.name && (el.dataset.key ?? el.dataset.adjustment) === (previous.dataset.key ?? previous.dataset.adjustment),
        )
      : previous.dataset.act
        ? Array.from(document.querySelectorAll('[data-act]')).find(
            (el) => el.dataset.act === previous.dataset.act && el.dataset.val === previous.dataset.val,
          )
        : null;
    next?.focus({ preventScroll: true });
  }
  S.renderRoute = location.hash;
}
window.addEventListener('hashchange', () => {
  S.canvasSelection = null;
  if (sheet.open) closeSheet();
  route();
  const resumeQuick = S.page === 'edit' && S.tool !== 'versions' && S.quickResume === quickSubject();
  if (resumeQuick) S.quickResume = null;
  render();
  if (resumeQuick) quickBegin();
  else if (S.page === 'edit' && S.editFocus) focusEditDestination();
  else $('#workspace').focus({ preventScroll: true });
});
document.addEventListener('keydown', (event) => {
  if (sheet.open || event.defaultPrevented) return;
  const key = event.key.toLowerCase(),
    cmd = event.metaKey || event.ctrlKey;
  if (quickPromptVisible()) {
    if (event.isComposing || event.keyCode === 229) return;
    if (key === 'escape') {
      event.preventDefault();
      quickEscape();
    } else if (cmd && key === 'enter' && event.target.name === 'quickPrompt') {
      event.preventDefault();
      actions['quick-submit']();
    }
    return;
  }
  if (key === 'escape') {
    if (S.page === 'edit') {
      if (S.canvasMenu) actions['canvas-menu-close']();
      else if (S.cropOpen) actions['canvas-crop']();
      else if (S.tool === 'versions') actions['return-adjustments']();
      else if (S.tool === 'agent' && !event.target.closest('textarea'))
        editPanel('edit/smart', '#adjustment-panel');
      return;
    }
    if (S.filters || S.mobileInspector || S.drawer || S.search) {
      S.filters = S.mobileInspector = S.drawer = S.search = false;
      render();
    }
    return;
  }
  if (event.target.closest('input,textarea,select,iframe,[contenteditable=true]')) return;
  if (cmd && key === ',') {
    event.preventDefault();
    go('settings/general');
    return;
  }
  if (S.page === 'edit') {
    if (cmd && key === 's') {
      event.preventDefault();
      Studio.save();
      notifyEditor('已存储当前编辑。');
    }
    if (cmd && key === 'z') {
      event.preventDefault();
      actions['edit-step'](event.shiftKey ? 'redo' : 'undo');
    }
    if (cmd && key === 'enter') {
      event.preventDefault();
      Studio.save();
      go('library/' + S.scope);
    }
    const rail = event.target.closest('.inspector-rail');
    if (rail && ['arrowup', 'arrowdown', 'home', 'end'].includes(key)) {
      event.preventDefault();
      const tools = Array.from(rail.querySelectorAll('button')),
        index = tools.indexOf(event.target);
      const next =
        key === 'home'
          ? tools[0]
          : key === 'end'
            ? tools.at(-1)
            : tools[(index + (key === 'arrowup' ? -1 : 1) + tools.length) % tools.length];
      next.click();
      return;
    }
    if (key === '0' && !event.altKey) {
      event.preventDefault();
      actions['edit-zoom']('fit');
    }
    if (cmd || event.altKey) return;
    if (['arrowleft', 'arrowright'].includes(key)) {
      event.preventDefault();
      actions['canvas-nav'](key === 'arrowleft' ? 'previous' : 'next');
    } else if (['-', '=', '+', 'z'].includes(key)) {
      event.preventDefault();
      actions['edit-zoom'](key === 'z' ? (S.pixelView ? 'fit' : 'pixels') : key === '-' ? 'out' : 'in');
    } else if (key === 'c') actions['canvas-crop']();
    else if (key === 'v') actions['edit-compare']();
    else if (key === 'b') {
      const colors = Object.keys(grounds);
      actions['canvas-ground'](colors[(colors.indexOf(Studio.data.prefs.ground) + 1) % colors.length]);
    }
    return;
  }
  if (S.page !== 'library') return;
  const b = activeBrowser(),
    ids = Studio.visible(S.scope);
  if (cmd && key === 'f') {
    event.preventDefault();
    S.search = true;
    render();
    $('[name=query]').focus();
    return;
  }
  if (cmd && key === 'z') {
    event.preventDefault();
    actions['undo-lib']();
    return;
  }
  if (cmd && key === 'a') {
    event.preventDefault();
    b.selected = [...ids];
    Studio.save();
    render();
    return;
  }
  if (cmd || event.altKey) return;
  if (['g', 'e', 'c'].includes(key)) changeMode({ g: 'grid', e: 'single', c: 'compare' }[key]);
  else if (key === 'd' || (key === 'enter' && !event.target.closest('button,a'))) actions.edit();
  else if (['p', 'x', 'u'].includes(key) && !isHistory())
    actions.decide({ p: 'keep', x: 'reject', u: 'none' }[key]);
  else if (/^[0-5]$/.test(key)) actions.rate(key);
  else if (key === 'z') {
    if (b.view !== 'single') changeMode('single');
    actions.zoom();
  } else if (key === ' ' && !event.target.closest('button,a') && b.focus) {
    event.preventDefault();
    selectPhoto(b.focus, { ctrlKey: true });
  } else if (['arrowleft', 'arrowright', 'arrowup', 'arrowdown'].includes(key) && ids.length) {
    event.preventDefault();
    const step = ['arrowleft', 'arrowup'].includes(key) ? -1 : 1;
    selectPhoto(ids[Math.max(0, Math.min(ids.length - 1, ids.indexOf(b.focus) + step))], event);
  }
});
compactLibraryNavigation.addEventListener('change', () => {
  S.drawer = false;
  render();
});
matchMedia('(prefers-color-scheme:dark)').addEventListener('change', () => {
  if (Studio.data.prefs.theme === 'system') render();
});
S.scope = Studio.data.lastScope || S.scope;
try {
  const saved = JSON.parse(sessionStorage.getItem('rawmaster.ui.delivery'));
  if (saved?.items?.length && saved.items.every((i) => Studio.asset(i.id.split('@')[0]))) S.delivery = saved;
} catch {}
for (const job of Studio.data.jobs) if (job.delivery && job.state === 'running') job.state = 'unknown';
route();
render();
setInterval(settleJobs, 400);
