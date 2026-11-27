'use strict';

const SceneEditor = (() => {
  const views = new Map();
  const review = new URLSearchParams(location.search);
  const nativeReview = review.get("sceneNativeReview") === "1";
  const scopesReview = review.get("scopesNativeReview") === "1";
  const missingRuntime = nativeReview && review.get("sceneRawRuntime") === "unavailable";
  const runtimeMessage = 'HDR 原片解码运行库不可用。请检查 RAWMaster 安装后重试。';
  const diagnostics = {
    sensor: ['传感器饱和', '斜线 · 源通道饱和'], target: ['超输出目标', '网格 · 峰值或色域超出'],
    screen: ['超屏幕余量', '点阵 · 当前屏幕看不全'], bands: ['HDR 分档', '横线 · 每格 1 EV'],
  };
  const scopes = {
    output: ['目标输出', '参考白 100 nits │ +1 EV │ +2 EV │ +3 EV', 'Y 200 nits · +1 EV（目标输出）'],
    scene: ['场景', '负值 │ 场景锚点 │ 超白值', '线性 AP1 RGB：0.41，0.29，−0.02（场景）'],
    sdr: ['SDR 派生', '0 nits │ 25 │ 50 │ 75 │ 100', 'Y 64 nits（SDR 派生）'],
  };
  const id = () => Studio.data.work;
  const edit = () => Studio.edit(id());
  const versions = () => S.tool === 'versions';
  const shown = () => versions() ? versionRecipe(S.versionView || edit().adopted) : edit().recipe;
  const config = (r = shown()) => RMSceneOutput.clean(r.sceneOutput);
  function view() {
    const key = id() + ':' + (versions() ? S.versionView || edit().adopted : 'draft');
    if (!views.has(key)) views.set(key, { screen: 'sdr', preview: 'target', scope: 'output', overlays: new Set(), sample: false });
    return views.get(key);
  }
  const reason = () => Studio.asset(id()).online ? RMSceneOutput.fixtureReason(Studio.asset(id()).source || id()) : '原片已离线；可查看现存预览，接回原片后才可重算 HDR。';
  const fallback = () => !(view().preview === 'target' && view().screen === 'hdr');
  const appearance = () => fallback() ? 'HDR · SDR 派生预览' : 'HDR · 目标预览（屏幕余量有限）';
  const hdr = () => !!config();
  const modes = { sdr:'SDR', hdr:'HDR', bw:'B&W' };
  const mode = () => hdr() ? 'hdr' : (shown().colorMode ?? (shown().mono ? 'bw' : 'sdr'));
  const badgeText = () => hdr() && fallback() ? 'HDR · SDR 预览' : modes[mode()];
  const badge = () => `<span class="scene-badge">${h(badgeText())}</span>`;
  const blocked = () => versions() ? '已保存版本只读，返回编辑后可切换模式。'
    : S.canvasTool || S.dagConnectionDraft || quickPromptVisible() ? '请先完成或取消当前工具草案。'
    : !Studio.asset(id()).online ? '原片离线；接回原片后可切换模式。' : '';
  function modeBar() {
    const current = mode();
    const details = { sdr:'SDR 彩色', hdr:'HDR 编辑', bw:'B&W · SDR 黑白' };
    return `<section class="scene-mode-bar" aria-label="编辑模式"><div class="scene-mode-row">
      <div class="scene-modes" role="group" aria-label="色彩模式">
        ${Object.entries(modes).map(([key,label]) => btn(label,'scene-mode',key,{title:details[key],pressed:current === key})).join('')}
      </div>${btn('色彩与输出','scene-open','',{icon:'sliders',only:true,cls:'icon-btn scene-entry'})}</div></section>`;
  }
  function warning() {
    const text = S.sceneWarning?.id === id() && S.sceneWarning.text;
    return text ? `<div class="scene-warning" role="alert">${icon('pulse',14)}<span>${h(text)}</span>${btn('关闭色彩提示','scene-dismiss','',{icon:'close',only:true})}</div>` : '';
  }
  function warn(text) {
    S.sceneWarning = {id:id(), text};
    render();
  }
  actions['scene-dismiss'] = () => {
    delete S.sceneWarning; render();
    ($('.scene-modes [aria-pressed=true]') || $('.canvas-panel'))?.focus({preventScroll:true});
  };
  function chart(cfg, v) {
    const screen = v.screen === 'hdr' ? 2 : 0, screenX = 104 + screen * 30;
    const limitX = 104 + cfg.limitEV * 30;
    const label = `扩展直方图（模拟）：SDR 与 HDR，以 100 nits 为界，每格 1 EV；屏幕可显示 +${screen} EV，编辑限制 +${cfg.limitEV.toFixed(1)} EV`;
    return `<svg class="scene-chart" viewBox="0 0 208 67" role="img" aria-label="${h(label)}">
      <path class="scene-chart-grid" d="M134 7v40 M164 7v40 M194 7v40"/>
      <path class="scene-chart-hist" d="M4 46 12 42 20 32 27 37 35 19 43 14 52 31 61 27 71 34 81 21 90 15 100 23 110 21 119 31 129 24 139 32 148 35 157 30 168 40 179 42 187 45 201 46Z"/>
      <path class="scene-chart-white" d="M104 6v43"/><path class="scene-chart-limit" d="M${limitX} 7v42"/>
      <path class="scene-chart-ok" d="M4 50H${screenX}"/><path class="scene-chart-over" d="M${screenX} 50H203"/>
      <text x="5" y="63">SDR</text><text x="103" y="63" text-anchor="end">100 nits</text>
      <text x="134" y="63" text-anchor="middle">+1</text><text x="164" y="63" text-anchor="middle">+2</text><text x="194" y="63" text-anchor="middle">+3</text></svg>`;
  }
  document.addEventListener('keydown', event => {
    const group = event.target.closest('.scene-modes');
    if (!group || !['ArrowLeft','ArrowRight','Home','End'].includes(event.key)) return;
    const buttons = [...group.querySelectorAll('button:not(:disabled)')];
    if (!buttons.length) return;
    const current = buttons.indexOf(event.target), step = event.key === 'ArrowLeft' ? -1 : 1;
    const next = event.key === 'Home' ? 0 : event.key === 'End' ? buttons.length - 1 : (current + step + buttons.length) % buttons.length;
    event.preventDefault(); event.stopPropagation(); buttons[next].focus();
  });
  function controls() {
    const why = reason();
    const missing = scopesReview && view().screen === 'unknown';
    return `<div class="row scene-diagnostics">${Object.entries(diagnostics).map(([k,[t]]) => btn(t,'scene-overlay',k,{pressed:view().overlays.has(k),disabled:!!why || k === 'screen' && missing})).join('')}</div>${missing ? '<p class="small">当前屏幕色彩空间不可线性化 · 超屏幕余量不可用，不是零。</p>' : ''}${why ? `<p class="small">诊断不可用：${h(why)}</p>` : ''}`;
  }
  function hud() {
    if (!hdr()) return '';
    const v = view();
    if (nativeReview && (v.failed || missingRuntime && !reason())) return `<div class="scene-hud" aria-label="HDR 查看状态"><span role="status">${h(missingRuntime ? runtimeMessage : '预览失败')} · 模拟</span><div class="row">${btn('重试 HDR 预览','scene-review-retry')}</div></div>`;
    return `<div class="scene-hud" aria-label="HDR 查看状态"><span role="status">${h(appearance())} · 模拟${v.preview === 'target' && v.screen === 'sdr' ? ' · 屏幕无 HDR 余量' : ''}</span>
      <div class="row">${btn('按 HDR 目标查看','scene-view','target',{pressed:v.preview === 'target'})}${btn('预览 SDR 派生','scene-view','sdr',{pressed:v.preview === 'sdr'})}</div>
      ${reason() ? '' : [...v.overlays].map(k => `<span class="scene-legend ${k}">${h(diagnostics[k][1])}</span>`).join('')}</div>`;
  }
  document.addEventListener('toggle', event => {
    if (scopesReview && event.target.matches('.scope-native-review') && event.target.isConnected) view().scopeOpen = event.target.open;
  }, true);
  function scope(docked) {
    const why = reason(), v = view(), [label, axes, reading] = scopes[v.scope];
    return `<section class="editing-scopes scene-scopes${docked ? ' docked' : ''}" aria-label="HDR 示波器（模拟）">
      <div class="row">${Object.entries(scopes).map(([k,[t]]) => btn(t,'scene-scope',k,{pressed:v.scope === k})).join('')}${docked ? btn('在独立窗口显示示波器','scopes','',{icon:'pulse',only:true,cls:'icon-btn'}) : ''}</div>
      ${v.scope === 'output' ? chart(config(), v) : `<div class="scene-axis" role="img" aria-label="${h(label + '：' + axes)}"><span>${h(axes)}</span></div>`}
      <small class="scene-display-key">模拟屏幕余量：${v.screen === 'sdr' ? '0' : '+2'} EV · 实线可显示／虚线超余量</small>
      ${docked && !scopesReview ? `<div class="scene-limit"><label for="scene-limit">HDR 高光限制</label><output for="scene-limit">+${config().limitEV.toFixed(1)} EV</output><input id="scene-limit" name="sceneLimit" type="range" min="0" max="3.3" step="0.1" value="${config().limitEV}" ${blocked() || why ? 'disabled' : ''}></div>` : ''}
      <div class="row">${btn(v.sample ? '解除样点' : '锁定中心样点','scene-sample','',{pressed:v.sample,disabled:!!why})}${scopesReview ? btn('在主图取样','scene-pick','',{pressed:!!v.picking,disabled:!!why}) : ''}</div>
      <p role="status" class="small">${why ? '源数据不可用，尚无采样值。' : (v.sample ? `锁定样点（${Math.round((v.point?.x ?? .5)*100)}%，${Math.round((v.point?.y ?? .5)*100)}%）：` : '中心预读：') + h(reading)} 未提供 HDR Lab 或 HDR 矢量图。</p>
      ${controls()}</section>`;
  }
  function trimFields(c, disabled) {
    const trim = c.trim;
    return `<div class="scene-form">
        <label>派生曝光（EV）<input name="sceneExposure" type="number" min="-3" max="3" step="0.25" required value="${trim.exposure}" ${disabled}></label>
        <label>亮度映射<select name="sceneMapping" ${nativeReview ? "disabled" : disabled}><option value="balanced">平衡</option><option value="soft" ${trim.mapping === 'soft' ? 'selected' : ''}>柔和</option></select></label>
        <label>高光压缩<input name="sceneCompression" type="number" min="0" max="100" required value="${trim.compression}" ${nativeReview ? "disabled" : disabled}></label></div>
        <p class="small">仅用于 SDR 派生；不改变 HDR 母版。${c.film ? h(RMPhotos.filmStocks[c.film].name) + ' · 仅在派生分支' : ''}</p>
        ${disabled ? '' : `<div class="row">${btn('应用 SDR 派生','scene-trim')}${btn('复位 SDR 派生','scene-trim','reset')}${c.film ? btn('移除派生胶片','scene-film','') : ''}</div>`}`;
  }
  function rendition() {
    const s = view();
    return `<details class="scene-rendition" ${s.rendition ? 'open' : ''}><summary>SDR 派生设置</summary><div class="scene-trim-fields">
      <div class="row">${btn('预览 SDR 派生','scene-view','sdr',{pressed:s.preview === 'sdr'})}${btn('按 HDR 目标查看','scene-view','target',{pressed:s.preview === 'target'})}</div>
      ${trimFields(config(), blocked() || reason() ? 'disabled' : '')}</div></details>`;
  }
  document.addEventListener('toggle', event => {
    if (event.target.matches('.scene-rendition') && event.target.isConnected) view().rendition = event.target.open;
  }, true);
  let entrySelector;
  function open() {
    entrySelector = '.scene-entry';
    const c = config(), why = reason(), readOnly = !!(blocked() || why);
    const disabled = readOnly ? 'disabled' : '';
    dialog('色彩与输出', `<div class="scene-sheet"><p>原型模拟 · ${h(Studio.asset(id()).name)} · ${versions() ? '版本查看' : '当前编辑草稿'}。</p>
      <p>色彩模式：<strong>${h(modes[mode()])}</strong> · ${c ? why ? '当前不可重算 HDR' : '场景参考（样本）' : 'SDR 彩色与黑白共用 SDR 输出'}</p>
      ${why ? `<p class="warn">${h(why)}</p>` : ''}
      ${c ? `<p>标准 ACES 2 · ${h(RMSceneOutput.targets.hdr.signal)}。其他成像路线和目标未放行；屏幕 ICC 不改变成片目标。</p>
        <fieldset class="scene-trim-fields"><legend>SDR 派生</legend>${trimFields(c, disabled)}</fieldset>
        <fieldset><legend>评审用屏幕状态</legend><div class="row">${btn('模拟 SDR 屏','scene-screen','sdr',{pressed:view().screen === 'sdr'})}${btn('模拟 HDR 屏','scene-screen','hdr',{pressed:view().screen === 'hdr'})}${scopesReview ? btn('模拟屏幕色彩空间未知','scene-screen','unknown',{pressed:view().screen === 'unknown'}) : ''}</div></fieldset>
        ${nativeReview && !scopesReview ? `<p>诊断尚未接入此切片。</p>${btn('模拟 HDR 预览失败','scene-review-fail')}` : `<fieldset class="scene-sheet-diagnostics"><legend>查看叠加</legend>${controls()}</fieldset>`}` : ''}</div>`,
      btn('关闭','close'));
  }
  function commit(label, sceneOutput, base = edit().recipe, saveCandidate = false) {
    const next = { ...base };
    if (sceneOutput) next.sceneOutput = sceneOutput;
    else delete next.sceneOutput;
    if (next.dag) {
      const root = structuredClone(next.dag);
      const {sceneOutput, colorMode} = next;
      for (const [key, value] of Object.entries({sceneOutput, colorMode})) {
        if (value !== undefined) root.base[key] = value;
        else delete root.base[key];
      }
      next.dag = root;
    }
    Studio.setRecipe(id(), label, next);
    if (saveCandidate) Studio.candidate(id(), 'HDR 候选', next);
    if (sheet.open) closeSheet();
    render();
    ($(entrySelector || '.scene-entry') || $('.scene-entry'))?.focus({preventScroll:true});
  }
  actions['scene-open'] = open;
  function focusMode(key) {
    entrySelector = `[data-act="scene-mode"][data-val="${key}"]`;
    $(entrySelector)?.focus({preventScroll:true});
  }
  const switchSDR = key => commit(key === 'bw' ? '切换到 SDR 黑白' : '切换到 SDR 彩色', undefined, {...edit().recipe, colorMode:key});
  actions['scene-mode'] = key => {
    if (!Object.hasOwn(modes,key) || key === mode()) return;
    const unavailable = blocked() || (key === 'hdr' ? reason() : '');
    if (unavailable) return warn(unavailable);
    delete S.sceneWarning;
    focusMode(key);
    if (key !== 'hdr') {
      if (!hdr()) return switchSDR(key);
      dialog(`切换到 ${modes[key]}？`, (nativeReview ? `<p><strong>${h(Studio.asset(id()).name)}</strong></p>` : '') +
        '<p>这会退出当前草稿的 HDR 编辑并移除其 SDR 派生设置；已经保存的版本不变。可撤销。若只想检查 SDR 外观，请使用画布的「预览 SDR 派生」。</p>',
        btn('取消','close') + btn('确认切换','scene-confirm-sdr',key,{cls:'primary'}));
      return;
    }
    const r = edit().recipe;
    const conflicts = [r.filmStock && '胶片外观', r.preset && '导入／基础预设', mode() === 'bw' && '黑白外观'].filter(Boolean);
    const graphStyle = r.dag && dagAllNodes(r.dag).some(({node}) => node.params.filmStock || node.params.preset || node.params.lut && node.params.lut !== '无');
    if (r.dag && (graphStyle || r.filmStock || r.preset)) {
      return warn('工作流含未验证的 SDR 胶片、LUT 或预设，未切换到 HDR。节点和参数保持原样。');
    }
    if (nativeReview) {
      dialog('从原片创建 HDR 草稿？', `<p><strong>${h(Studio.asset(id()).name)}</strong></p><p>HDR 从原片的场景数据独立求值。不会把现有 SDR 调整、蒙版或外观转换成 HDR；现有已保存版本不变。可取消或撤销。</p>`,
        btn('取消','close') + btn('创建 HDR 草稿','scene-review-start','',{cls:'primary'}));
      return;
    }
    if (conflicts.length) {
      dialog('在 HDR 候选中继续', `<p>这些调整没有确认的 HDR 等价项：${h(conflicts.join('、'))}。保留原 SDR 编辑；${r.dag ? '新 HDR 候选保留节点与参数，使用 HDR 彩色外观。' : '新 HDR 候选保留曝光、裁切和选区，不携带上述外观。'}</p>`,btn('取消','close') + btn('创建 HDR 候选','scene-new','',{cls:'primary'}));
      return;
    }
    commit('启用 HDR 编辑', RMSceneOutput.clean({intent:'hdr'}), {...r, colorMode:'hdr'});
  };
  actions['scene-confirm-sdr'] = key => {
    if (blocked() || !hdr() || !['sdr','bw'].includes(key)) return;
    if (nativeReview) commit('返回 SDR 编辑', undefined, {...(view().draftBefore ?? Studio.freshRecipe()), colorMode:key});
    else switchSDR(key);
  };
  actions['scene-review-start'] = () => {
    if (!nativeReview || hdr() || blocked() || reason()) return;
    if (missingRuntime) {
      closeSheet();
      warn(runtimeMessage);
      $(entrySelector)?.focus({preventScroll:true});
      return;
    }
    view().draftBefore = structuredClone(edit().recipe);
    view().failed = false;
    commit('创建 HDR 草稿', RMSceneOutput.clean({intent:'hdr'}), {...Studio.freshRecipe(), colorMode:'hdr'});
  };
  actions['scene-review-fail'] = () => { if (nativeReview && hdr()) { view().failed = true; if (sheet.open) closeSheet(); render(); $('.scene-hud button')?.focus(); } };
  actions['scene-review-retry'] = () => { view().failed = false; render(); $('.scene-hud button')?.focus(); };
  actions['scene-review-exposure'] = () => {
    const field = $('[name=sceneGraphExposure]');
    if (!hdr() || blocked() || reason() || !field.reportValidity()) return;
    entrySelector = '[data-act=scene-review-exposure]';
    commit('调整节点曝光', config(), {...edit().recipe, ev:field.valueAsNumber});
  };
  function reviewInspector() {
    return `<p class="small">当前照片 · 基础调色 · 场景线性 AP1</p>
      <label>节点曝光（EV） <input name="sceneGraphExposure" type="number" min="-12" max="12" step="0.25" required value="${edit().recipe.ev || 0}"></label> ${btn('应用曝光','scene-review-exposure')}
      <p class="small">其他 HDR 算子、采样和诊断暂未接入评审切片。</p>`;
  }
  actions['scene-new'] = () => {
    if (reason() || blocked() || hdr()) return;
    const before = edit().recipe;
    const scene = RMSceneOutput.clean({intent:'hdr'});
    const next = before.dag ? {...before, colorMode:'hdr'} : { ...Studio.freshRecipe(), ev:before.ev, colorMode:'hdr', ...Object.fromEntries(
      ['crop','angle','cropRect','cropBox','quarterTurns','flipH','flipV','masks'].filter(k => Object.hasOwn(before,k)).map(k => [k,before[k]])) };
    if (Studio.dirty(id())) Studio.candidate(id(), '保留的 SDR', before);
    commit('在 HDR 候选中继续', scene, next, true);
  };
  inputs.sceneLimit = el => { el.closest('.scene-limit').querySelector('output').value = `+${el.valueAsNumber.toFixed(1)} EV`; };
  changes.sceneLimit = el => {
    const c = config();
    if (!c || blocked() || reason() || !el.validity.valid) return;
    c.limitEV = el.valueAsNumber;
    entrySelector = '#scene-limit';
    commit('调整 HDR 高光限制', RMSceneOutput.clean(c));
  };
  actions['scene-trim'] = (kind, _, button) => {
    const c = config();
    if (!c || blocked() || reason()) return;
    const root = button.closest('.scene-trim-fields');
    if (!button.closest('dialog')) {
      view().rendition = true;
      entrySelector = '.scene-rendition [data-act="scene-trim"][data-val="' + kind + '"]';
    }
    if (kind === 'reset') c.trim = { ...RMSceneOutput.defaults };
    else {
      const fields = ['sceneExposure','sceneCompression'].map(name => root.querySelector(`[name="${name}"]`));
      if (fields.some(f => !f.reportValidity())) return;
      c.trim = { exposure:fields[0].valueAsNumber, compression:fields[1].valueAsNumber, mapping:value('sceneMapping',root) };
    }
    view().preview = 'sdr'; commit(kind === 'reset' ? '复位 SDR 派生' : '调整 SDR 派生', RMSceneOutput.clean(c));
  };
  function updateView(action, value, button) {
    const inSheet = button?.closest('dialog');
    const inRendition = button?.closest('.scene-rendition');
    if (inRendition && action === 'scene-view') {
      view().rendition = true;
      const bar = $('.scene-hud'), badge = $('.scene-badge');
      if (bar) bar.outerHTML = hud();
      if (badge) badge.textContent = badgeText();
      inRendition.querySelectorAll('[data-act=scene-view]').forEach(el => el.setAttribute('aria-pressed', String(el.dataset.val === value)));
      refreshCanvasLook();
      return;
    }
    const docked = $('.inspector-content .scene-scopes');
    if (scopesReview && $('.scope-native-review')) view().scopeOpen = $('.scope-native-review').open;
    if (!inSheet) {
      const rendition = $('.scene-rendition');
      if (rendition) view().rendition = rendition.open;
      render();
    }
    else {
      const badge = $('.scene-badge');
      if (badge) badge.textContent = badgeText();
      const bar = $('.scene-hud');
      if (bar) bar.outerHTML = hud();
      if (docked) docked.outerHTML = scope(true);
      const floating = sheet.querySelector('.scene-scopes');
      if (floating) floating.outerHTML = scope(false);
      sheet.querySelectorAll('[data-act=scene-screen]').forEach(el => el.setAttribute('aria-pressed', String(el.dataset.val === view().screen)));
      sheet.querySelectorAll('[data-act=scene-overlay]').forEach(el => {
        el.setAttribute('aria-pressed', String(view().overlays.has(el.dataset.val)));
        if (scopesReview && el.dataset.val === 'screen') el.disabled = !!reason() || view().screen === 'unknown';
      });
      refreshCanvasLook();
      document.querySelectorAll('.scene-marks').forEach(el => { el.outerHTML = overlayMarkup(); });
    }
    (inSheet || document).querySelector(`[data-act="${action}"][data-val="${value}"]`)?.focus({preventScroll:true});
  }
  function refreshCanvasLook() {
    $('.edit-center')?.querySelectorAll('.canvas-layer img').forEach(el => {
      const r = el.classList.contains('reference-image') ? versionRecipe(S.reference || 'original') : dagEnabled() && !versions() ? dagViewRecipe(shown()) : shown();
      el.style.filter = RMPhotos.filter(RMPhotos.displayLook(preview(r)));
    });
    const monitor = $('.dag-monitor img');
    if (monitor) monitor.style.filter = dagPhotoFilter();
  }
  actions['scene-screen'] = (s, _, el) => { view().screen = s; if (s === 'unknown') view().overlays.delete('screen'); updateView('scene-screen',s,el); };
  actions['scene-view'] = (s, _, el) => { view().preview = s; updateView('scene-view',s,el); };
  actions['scene-scope'] = (s, _, el) => { view().scope = s; updateView('scene-scope',s,el); };
  actions['scene-overlay'] = (k, _, el) => {
    if (!hdr() || reason() || !Object.hasOwn(diagnostics,k)) return;
    const set = view().overlays;
    if (set.has(k)) set.delete(k); else set.add(k);
    updateView('scene-overlay',k,el);
  };
  actions['scene-sample'] = (_, event, el) => { view().sample = !view().sample; view().point = null; updateView('scene-sample','',el); };
  actions['scene-pick'] = () => { view().picking = !view().picking; view().scopeOpen = true; render(); const image = $('.edit-image'); if (image) { image.tabIndex = -1; image.focus({preventScroll:true}); } };
  function scopePick(event, image) {
    if (!scopesReview || !hdr() || !view().picking) return false;
    if (reason()) return true;
    const box = image.getBoundingClientRect();
    view().point = {x:(event.clientX-box.left)/box.width, y:(event.clientY-box.top)/box.height};
    view().sample = true; view().picking = false; render(); $('[data-act=scene-pick]')?.focus({preventScroll:true});
    return true;
  }
  document.addEventListener('keydown', e => {
    if (scopesReview && e.key === 'Escape' && S.page === 'edit' && hdr() && view().picking) { view().picking = false; render(); $('[data-act=scene-pick]')?.focus(); e.preventDefault(); e.stopImmediatePropagation(); return; }
    if (e.key !== 'Escape' || sheet.open || S.page !== 'edit' || S.canvasTool || S.canvasMenu || quickPromptVisible() ||
      e.target.closest('#dag-node-picker, .dag-floating') || !hdr() || !view().overlays.size) return;
    const last = [...view().overlays].at(-1);
    view().overlays.clear(); render();
    ($(`[data-act="scene-overlay"][data-val="${last}"]`) || $('.scene-entry'))?.focus({preventScroll:true});
    e.preventDefault(); e.stopImmediatePropagation();
  }, true);
  function film(key) {
    if (!hdr()) return false;
    entrySelector = '[data-act="film-stock"][data-val="' + CSS.escape(key) + '"]';
    const why = reason();
    const recipe = { ...edit().recipe, filmStock:key, filmEnabled:true, filmAmount:100 };
    const filter = RMPhotos.filter(RMPhotos.displayLook(recipe));
    dialog('仅 SDR 的胶片外观', `<p>${h(RMPhotos.filmStocks[key].name)}仅在 SDR 派生中使用。不会套用到 HDR 母版。</p>${why ? `<p>${h(why)}</p>` : pic(id(), 'scene-film-preview', `style="filter:${h(filter)}"`) + '<p class="small">SDR 派生试看 · 模拟</p>'}`,
      btn('取消','close') + btn('在 SDR 派生中采用','scene-film',key,{disabled:!!why}));
    return true;
  }
  actions['scene-film'] = key => {
    const c = config();
    if (!c || versions() || reason() || key && !Object.hasOwn(RMPhotos.filmStocks,key)) return;
    c.film = key; view().preview = 'sdr'; commit(key ? '在 SDR 派生中采用胶片' : '移除派生胶片', c);
  };
  const preview = r => !hdr() || fallback() ? RMSceneOutput.sdrPreview(r, config(r)) : r;
  const overlayMarkup = () => !hdr() || reason() ? '' : `<div class="scene-marks" aria-hidden="true">${[...view().overlays].map(k => `<i class="${k}"></i>`).join('')}</div>`;
  function toolNote() {
    if (!hdr() || versions() || S.canvasTool || S.tool === 'basic') return '';
    return ['smart','agent','detail','effects','grading','hdr','mixer','slice','warp','lens'].includes(S.tool)
      ? '此工具尚未验证 HDR 母版运算；当前版本不可应用，也不会改用 SDR 代理。' : '';
  }
  return { modeBar, badge, hud, scope, film, preview, config, hdr, overlayMarkup, toolNote, warning, rendition, nativeReview, reviewInspector, scopesReview, scopePick, scopeOpen: () => view().scopeOpen };
})();
