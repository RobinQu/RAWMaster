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
    screen: ['超屏幕余量', '点阵 · 当前屏幕看不全'], bands: ['可视化 HDR', '目标亮度 · 每档 1 EV'],
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
  const reason = () => Studio.asset(id()).online ? RMSceneOutput.fixtureReason(Studio.fixtureID(id())) : '原片已离线；可查看现存预览，接回原片后才可重算 HDR。';
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
  const bands = [
    ['0–1 EV','#3878cc'], ['1–2 EV','#52ae77'], ['2–3 EV','#dfaa42'], ['3+ EV','#d85d56']
  ];
  function appearanceInfo() {
    const c = config(), v = view();
    if (!c) return `<div class="appearance-info" aria-label="色彩与输出"><span>${h(Studio.asset(id()).name)}</span><span>${mode()==='bw' ? '黑白混合' : '彩色显影'} · sRGB</span></div>`;
    const screen = v.screen === 'unknown' ? '未知' : v.screen === 'hdr' ? '4×（+2 EV）' : '1×（SDR）';
    const display = v.preview === 'sdr' ? 'SDR 派生预览' : v.screen === 'hdr' ? 'HDR 目标预览' : 'SDR 派生回退';
    return `<div class="appearance-info" aria-label="色彩与输出"><span>${h(Studio.asset(id()).name)}</span><span>场景线性 AP1 · ACES 2</span>
      <span>HDR · Rec.2020 PQ · 1000 nits</span><span>SDR · sRGB · 100 nits</span>
      <span>${display} · 屏幕余量 ${screen}</span>${reason() ? `<span>${h(reason())}</span>` : ''}</div>`;
  }
  function modeBar() {
    const current = mode(), c = config(), v = view();
    const details = {sdr:['SDR 彩色','sdrColor'],hdr:['HDR','hdrSun'],bw:['B&W 黑白','invert']};
    const why = blocked() || reason();
    const pair = flatTabs('派生预览','scene-view',[['sdr','预览 SDR 派生'],['target','预览 HDR 派生']],v.preview);
    const attached = c ? `<div class="scene-limit"><label for="scene-limit">HDR 高光限制</label><output for="scene-limit">+${c.limitEV.toFixed(2)} EV</output>
      <input id="scene-limit" aria-label="HDR 高光限制" name="sceneLimit" type="range" min="0" max="3.32" step="0.01" value="${c.limitEV}" ${why ? 'disabled':''}></div>
      <div class="scene-previews">${pair}</div>${rendition()}${appearanceInfo()}` : appearanceInfo();
    return `<section class="scene-mode-bar" aria-labelledby="appearance-title"><div class="appearance-heading">${icon('palette',16)}<h3 id="appearance-title">色彩外观</h3></div>
      <div class="scene-modes button-group button-group--stretch" role="group" aria-label="色彩外观">${Object.entries(details).map(([key,[label,symbol]]) =>
        btn(label,'scene-mode',key,{icon:symbol,pressed:current === key})).join('')}</div>${attached}
      ${c && v.failed ? btn('重试 HDR 预览','scene-review-retry'):''}</section>`;
  }
  function visualizeControl() {
    if (!hdr()) return '';
    const on = view().overlays.has('bands');
    return `<div class="visualize-hdr"><label><input type="checkbox" name="visualizeHDR"${on ? ' checked' : ''}${reason() ? ' disabled' : ''}>可视化 HDR</label>
      ${on ? '<div class="hdr-bands-key" aria-label="目标亮度分档">' + [['≤100 nits','#989898'],...bands].map(([label,color])=>'<span><i style="background:'+color+'"></i>'+label+'</span>').join('') + '</div>' : ''}</div>`;
  }
  const warn = text => notifyEditor(text, 'error');
  function chart(cfg, v) {
    const screen = v.screen === 'hdr' ? 2 : 0, screenX = 104 + screen * 30;
    const limitX = 104 + cfg.limitEV * 30;
    const label = `扩展直方图（模拟）：SDR 与 HDR，以 100 nits 为界，每格 1 EV；${v.screen === 'unknown' ? '屏幕余量未知' : '屏幕可显示 +'+screen+' EV'}，编辑限制 +${cfg.limitEV.toFixed(1)} EV`;
    return `<svg class="scene-chart" viewBox="0 0 208 67" role="img" aria-label="${h(label)}">
      <path class="scene-chart-grid" d="M134 7v40 M164 7v40 M194 7v40"/>
      <path class="scene-chart-hist" d="M4 46 12 42 20 32 27 37 35 19 43 14 52 31 61 27 71 34 81 21 90 15 100 23 110 21 119 31 129 24 139 32 148 35 157 30 168 40 179 42 187 45 201 46Z"/>
      <path class="scene-chart-white" d="M104 6v43"/><path class="scene-chart-limit" d="M${limitX} 7v42"/>
      <path class="scene-chart-ok" d="M4 50H${screenX}"/><path class="scene-chart-over" d="M${screenX} 50H203"/>
      <text x="5" y="63">SDR</text><text x="103" y="63" text-anchor="end">100 nits</text>
      <text x="134" y="63" text-anchor="middle">+1</text><text x="164" y="63" text-anchor="middle">+2</text><text x="194" y="63" text-anchor="middle">+3</text></svg>`;
  }
  function rgbPlot() {
    const c = config(), v = view(), derivative = v.preview === 'sdr';
    const white = 144, evWidth = 28;
    const limit = white + c.limitEV * evWidth, screen = white + (v.screen === 'hdr' ? 2 : 0) * evWidth;
    const levels = RMHistogram[Studio.fixtureID(id())] || [];
    function area(values, color) {
      const stops = c.bandEV, exposure = Number(shown().ev) || 0;
      const points=values.map((count,index)=>{
        const input = 255*index/(values.length-1);
        const ev=(input-152)/27+exposure;
        const band=Math.min(3,Math.floor(ev));
        const target=ev>0 ? Math.min(c.limitEV,ev+stops[band]) : ev;
        const x=derivative ? white*index/(values.length-1) : target>0 ? white+evWidth*target : Math.max(0,white*(1+target*27/152));
        return x.toFixed(2)+','+(96-count*1.9).toFixed(2);
      });
      const end=derivative ? white : limit;
      return '<path d="M0 96 L'+points.join(' L')+' L'+end+' 96Z" fill="'+color+'" fill-opacity=".68"/>';
    }
    const name = derivative ? 'SDR 派生' : 'HDR 目标';
    return '<figure class="histogram scene-rgb"><svg viewBox="0 0 256 96" preserveAspectRatio="none" role="img" aria-label="' +
      name + '扩展 RGB 直方图（模拟），SDR 白点 100 nits，每档 1 EV"><g style="mix-blend-mode:screen">' +
      levels.map((values, i) => area(values, ['#ed786b', '#70c481', '#799eec'][i])).join('') +
      '</g><path class="scope-white-mark" aria-label="SDR 白点 100 nits" d="M144 0v96" stroke="white"/>' +
      '<path d="M172 0v96 M200 0v96 M228 0v96" stroke="#78828b" stroke-dasharray="2 3"/>' +
      (derivative ? '' : '<path d="M' + screen + ' 0v96" stroke="#e0ae6b" stroke-dasharray="4 3"/><path d="M' + limit + ' 0v96" stroke="#77d2d4"/>') +
      '</svg><figcaption><span>' + name + ' · RGB</span><span>100 nits　+1　+2　+3 EV</span></figcaption></figure>';
  }
  function controls() {
    const why = reason();
    const missing = scopesReview && view().screen === 'unknown';
    return `<div class="row scene-diagnostics">${Object.entries(diagnostics).filter(([k])=>k !== 'bands').map(([k,[t]]) => btn(t,'scene-overlay',k,{pressed:view().overlays.has(k),disabled:!!why || k === 'screen' && missing})).join('')}</div>${missing ? '<p class="small">当前屏幕色彩空间不可线性化 · 超屏幕余量不可用，不是零。</p>' : ''}${why ? `<p class="small">诊断不可用：${h(why)}</p>` : ''}`;
  }
  function reportRuntime() {
    if (!hdr()) return;
    const v = view();
    if (nativeReview && missingRuntime && !reason() && !v.runtimeNotified) {
      const photo = id(); v.runtimeNotified = true;
      queueMicrotask(() => notifyEditor(runtimeMessage, 'error', photo));
    }
  }
  document.addEventListener('toggle', event => {
    if (event.target.matches('.scope-native-review') && event.target.isConnected) view().scopeOpen = event.target.open;
  }, true);
  function scope(docked) {
    const why = reason(), v = view(), [label, axes, reading] = scopes[v.scope];
    return `<section class="editing-scopes scene-scopes${docked ? ' docked' : ''}" aria-label="HDR 示波器（模拟）">
      <div class="row">${flatTabs('统计阶段', 'scene-scope', Object.entries(scopes).map(([key, [name]]) => [key, name]), v.scope)}${docked ? btn('在独立窗口显示示波器','scopes','',{icon:'pulse',only:true,cls:'icon-btn'}) : ''}</div>
      ${v.scope === 'output' ? chart(config(), v) : `<div class="scene-axis" role="img" aria-label="${h(label + '：' + axes)}"><span>${h(axes)}</span></div>`}
      <small class="scene-display-key">模拟屏幕余量：${v.screen === 'unknown' ? '未知' : v.screen === 'sdr' ? '0 EV' : '+2 EV'} · 实线可显示／虚线超余量</small>
      <div class="row">${btn(v.sample ? '解除样点' : '锁定中心样点','scene-sample','',{pressed:v.sample,disabled:!!why})}${scopesReview ? btn('在主图取样','scene-pick','',{pressed:!!v.picking,disabled:!!why}) : ''}</div>
      <p role="status" class="small">${why ? '源数据不可用，尚无采样值。' : (v.sample ? `锁定样点（${Math.round((v.point?.x ?? .5)*100)}%，${Math.round((v.point?.y ?? .5)*100)}%）：` : '中心预读：') + '阶段示例 · '+h(reading)} 未提供 HDR Lab 或 HDR 矢量图。</p>
      ${controls()}${reviewDisplay()}</section>`;
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
      ${trimFields(config(), blocked() || reason() ? 'disabled' : '')}</div></details>`;
  }
  document.addEventListener('toggle', event => {
    if (event.target.matches('.scene-rendition') && event.target.isConnected) view().rendition = event.target.open;
  }, true);
  let entrySelector;
  function reviewDisplay() {
    const v=view();
    return `<details class="scene-lab"${v.lab ? ' open' : ''}><summary>模拟显示与故障</summary>
      <div class="row">${btn('模拟 SDR 屏','scene-screen','sdr',{pressed:v.screen==='sdr'})}
      ${btn('模拟 HDR 屏','scene-screen','hdr',{pressed:v.screen==='hdr'})}
      ${scopesReview ? btn('模拟未知屏幕','scene-screen','unknown',{pressed:v.screen==='unknown'}) : ''}</div>
      ${nativeReview ? btn('模拟 HDR 预览失败','scene-review-fail') : ''}</details>`;
  }
  document.addEventListener('toggle',event=>{
    if (event.target.matches('.scene-lab') && event.target.isConnected) view().lab=event.target.open;
  },true);
  function commit(label, sceneOutput, base = edit().recipe) {
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
    if (sheet.open) closeSheet();
    render();
    ($(entrySelector || '.scene-modes [aria-pressed=true]') || $('.scene-modes [aria-pressed=true]'))?.focus({preventScroll:true});
  }
  function focusMode(key) {
    entrySelector = `[data-act="scene-mode"][data-val="${key}"]`;
    $(entrySelector)?.focus({preventScroll:true});
  }
  actions['scene-mode'] = key => {
    if (!Object.hasOwn(modes,key) || key === mode()) return;
    focusMode(key);
    const issue = blocked() || (key === 'hdr' ? reason() || (missingRuntime ? runtimeMessage : '') : '');
    if (issue) return warn(issue);
    const e = edit(), before = e.recipe, branches = e.appearanceDrafts ??= {};
    if (key === 'hdr') {
      branches.sdr = structuredClone(before);
      const initial = branches.hdr ?? Studio.freshRecipe();
      view().failed = false;
      commit('切换到 HDR', RMSceneOutput.clean(initial.sceneOutput || {intent:'hdr'}), {...initial,colorMode:'hdr'});
    } else {
      if (hdr()) branches.hdr = structuredClone(before);
      const sdr = hdr() ? branches.sdr ?? Studio.freshRecipe() : before;
      commit(key === 'bw' ? '切换到 SDR 黑白' : '切换到 SDR 彩色', undefined, {...sdr,colorMode:key,mono:key === 'bw'});
    }
    Activity.log('色彩外观','切换到 ' + modes[key]);
    notifyEditor('已切换到 ' + modes[key] + '。');
  };
  actions['scene-review-fail'] = () => {
    if (!nativeReview || !hdr()) return;
    view().failed = true; resolveEditorRetry('scene-review-retry');
    if (sheet.open) closeSheet();
    render();
    notifyEditor('HDR 预览失败，已保留上次画面。', 'error', id(), 'scene-review-retry');
  };
  actions['scene-review-retry'] = () => {
    if (!view().failed) return;
    view().failed = false; resolveEditorRetry('scene-review-retry'); render(); notifyEditor('已重新生成 HDR 预览。');
    $('.scene-modes [aria-pressed=true]')?.focus({preventScroll:true});
  };
  inputs.sceneLimit = el => { el.closest('.scene-limit').querySelector('output').value = `+${el.valueAsNumber.toFixed(2)} EV`; };
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
    const inRendition = $('.scene-rendition');
    if (inRendition && action === 'scene-view' && !view().overlays.has('bands')) {
      view().rendition = inRendition.open;
      const badge = $('.scene-badge'), info = $('.appearance-info'), plot = $('.scene-rgb');
      if (badge) badge.textContent = badgeText();
      if (info) info.outerHTML = appearanceInfo();
      if (plot) plot.outerHTML = rgbPlot();
      document.querySelectorAll('.scene-previews [data-act=scene-view]').forEach(el => el.setAttribute('aria-pressed',String(el.dataset.val===value)));
      refreshCanvasLook();
      return;
    }
    const docked = $('.inspector-content .scene-scopes');
    if ($('.scope-native-review')) view().scopeOpen = $('.scope-native-review').open;
    if (!inSheet) {
      const rendition = $('.scene-rendition');
      if (rendition) view().rendition = rendition.open;
      render();
    }
    else {
      const badge = $('.scene-badge');
      if (badge) badge.textContent = badgeText();
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
    PhotographicScopes.drawImagePreview();
    refreshSamplerPanel();
    const monitor = $('.dag-monitor img');
    if (monitor) monitor.style.filter = dagPhotoFilter();
  }
  actions['scene-screen'] = (s, _, el) => { view().screen = s; if (s === 'unknown') view().overlays.delete('screen'); updateView('scene-screen',s,el); };
  actions['scene-view'] = (s, _, el) => {
    const v=view(), wasVisualized=v.overlays.delete('bands'); v.preview=s;
    if (wasVisualized) { render(); $('.scene-previews [data-val="'+s+'"]')?.focus({preventScroll:true}); }
    else updateView('scene-view',s,el);
  };
  changes.visualizeHDR = el => {
    const v=view();
    if (el.checked) v.overlays.add('bands'); else v.overlays.delete('bands');
    render(); $('[name=visualizeHDR]')?.focus({preventScroll:true});
  };
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
    ($(`[data-act="scene-overlay"][data-val="${last}"]`) || $('[name=visualizeHDR]') || $('.scene-modes [aria-pressed=true]'))?.focus({preventScroll:true});
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
  function samplerFrame() {
    const v = view();
    if (v.overlays.has('bands')) return {status:'退出亮度诊断后可读数'};
    if (v.failed || reason() || S.cropOpen || S.compare || S.dagConnectionDraft || (dagEnabled() && (dagView().target || dagPreviewState().bypass || dagPreviewState().solo))) return {status:'等待读数'};
    return {name:!fallback() ? 'HDR 目标 · Rec.2020' : v.preview==='sdr' ? 'SDR 派生 · Rec.709' : 'SDR 显示回退 · Rec.709'};
  }
  const preview = r => !hdr() || fallback() ? RMSceneOutput.sdrPreview(r, config(r)) : r;
  const overlayMarkup = () => !hdr() ? (mode()==='bw' ? '<canvas class="bw-range-preview" hidden aria-hidden="true"></canvas>' : '') : reason() ? '' : `<div class="scene-marks" aria-hidden="true">${[...view().overlays].filter(k=>k!=='bands').map(k=>`<i class="${k}"></i>`).join('')}<canvas class="hdr-range-preview" data-visualize="${view().overlays.has('bands')}" hidden></canvas></div>`;
  return { modeBar, badge, reportRuntime, unavailable: () => blocked() || reason(), scope, rgbPlot, film, preview, config, hdr, overlayMarkup, rendition, nativeReview, visualizeControl, bands, scopesReview, scopePick, samplerFrame, scopeOpen: () => view().scopeOpen };
})();
