'use strict';

const providers = ['GPT Image', 'Seedream / 中国方舟', 'Nano Banana'];
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
    <h3>原型样本</h3><p>本机浏览器保存示例选片、版本和设置。可以恢复到初始拍摄项目。</p>${btn('重置示例工作台…', 'reset-demo')}</section>`;
  if (key === 'storage')
    return `<section class="settings-box">${factList([
      ['当前资料库', Studio.catalog().packageName || '本机资料库'],
      ['示例调整归档', Object.values(d.edits).reduce((n, e) => n + e.versions.length, 0) + ' 个候选'],
      ['模型目录', p.modelDir || '受管目录'],
    ])}${btn('打开备份与还原', 'goto', 'tools/package')}</section>`;
  if (key === 'editing')
    return `<section class="settings-box"><h3>编辑预览</h3>${select('暗房背景', 'ground', ['深灰', '中灰', '浅灰', '纯黑'], p.ground)}${factList(
      [
        ['当前预览', '仓库 JPEG 衍生图'],
        ['实际像素复核', '在原生工作区验证'],
      ],
    )}${btn('查看图像性能监控', 'monitor')}</section>`;
  if (key === 'runtime')
    return `<section class="settings-box"><h3>本机 AI 环境</h3>${factList([
      ['状态', p.runtime],
      ['模型来源', p.modelDir || '受管目录'],
    ])}${select('模型目录', 'modelDir', ['受管目录', '已有目录（只读复用）'], p.modelDir)}
    ${check('已阅读示例模型使用条款', 'licenseAck')}<div class="row wrap">${btn(p.runtime === '就绪' ? '校验并修复' : '准备示例环境', 'prepare-runtime', '', { cls: 'primary' })}${back}</div></section>`;
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
changes.modelDir = (el) => {
  Studio.data.prefs.modelDir = el.value;
  Studio.save();
  render();
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
  S.versionView = j.result;
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
            (k === 'edit' && !(page === 'library' ? validWork(activeBrowser().focus) : validWork(work))) ||
            (k === 'export' && page === 'library' && isTriage()),
        }),
      )
      .join('')}</nav>
    <div class="chrome-actions">${btn('制作任务', 'goto', 'jobs', { icon: 'pulse', only: true, cls: 'icon-btn', pressed: page === 'jobs' })}${btn('设置', 'goto', 'settings/general', { icon: 'settings', only: true, cls: 'icon-btn', pressed: page === 'settings' })}</div>`;
}
function render() {
  const previous = document.activeElement;
  const root = $('#workspace'),
    exp = S.page === 'export',
    p = Studio.data.prefs;
  document.documentElement.dataset.theme = p.theme;
  $('#chrome').innerHTML = chrome();
  root.hidden = exp;
  $('#delivery').hidden = !exp;
  if (exp) {
    renderDelivery(root);
    return;
  }
  const left = root.querySelector('.photos-scroll')?.scrollTop ?? 0,
    side = root.querySelector('.inspector,.inspector-content')?.scrollTop ?? 0,
    toolsLeft = root.querySelector('.edit-left')?.scrollTop ?? 0,
    darkroom = root.querySelector('.edit-body')?.scrollTop ?? 0,
    pan =
      root.querySelector('.edit-page')?.dataset.photo === Studio.data.work
        ? $$('.canvas-fit').map((fit) => [fit.scrollLeft, fit.scrollTop])
        : [];
  root.innerHTML =
    S.page === 'library'
      ? libraryView()
      : S.page === 'edit'
        ? editorView()
        : S.page === 'jobs'
          ? jobsView()
          : toolView();
  if (S.renderRoute === location.hash) {
    const scroll = root.querySelector('.photos-scroll'),
      ins = root.querySelector('.inspector,.inspector-content');
    if (scroll) scroll.scrollTop = left;
    if (ins) ins.scrollTop = side;
  }
  if (S.page === 'edit' && S.renderRoute?.startsWith('#edit/')) {
    root.querySelector('.edit-left').scrollTop = toolsLeft;
    root.querySelector('.edit-body').scrollTop = darkroom;
    $$('.canvas-fit').forEach((fit, i) => {
      if (pan[i]) [fit.scrollLeft, fit.scrollTop] = pan[i];
    });
    const log = root.querySelector('.chat-log');
    if (log) log.scrollTop = log.scrollHeight;
  }
  if (S.renderRoute === location.hash && previous && !previous.isConnected && !sheet.open) {
    const next = previous.name
      ? Array.from(root.querySelectorAll('[name]')).find(
          (el) => el.name === previous.name && el.dataset.key === previous.dataset.key,
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
      actions['save-version']();
    }
    if (cmd && key === 'z') {
      event.preventDefault();
      actions['edit-step'](event.shiftKey ? 'redo' : 'undo');
    }
    if (cmd && key === 'enter') {
      event.preventDefault();
      actions['save-version']();
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
      actions['edit-zoom'](key === 'z' ? 'pixels' : key === '-' ? 'out' : 'in');
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
