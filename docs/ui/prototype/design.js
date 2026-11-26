'use strict';

// 界面规范画廊。页面只复用工作台的外观变量，控件标本按原生 AppDesign 令牌绘制，
// 不参与资料库、编辑或导出数据。规范与迁移清单见 specs/039-design-system/spec.md。
const dsTones = [
  ['主墨色', '--ds-ink', '0.15 / 0.91'],
  ['次级', '--ds-ink-2', '主墨色 72%'],
  ['三级', '--ds-ink-3', '主墨色 50%'],
  ['强调', 'var(--accent)', 'AppPalette.accent'],
];

function dsSlider({ title, id, min, max, step, digits, value, disabled = false }) {
  return `<div class="ds-slider${disabled ? ' is-disabled' : ''}" data-ds-slider data-min="${min}" data-max="${max}"
      data-step="${step}" data-digits="${digits}" data-value="${value}">
    <input class="ds-range" type="range" min="${min}" max="${max}" step="${step}" value="${value}"
      aria-label="${h(title)}" id="${h(id)}">
    <span class="ds-slider-title" aria-hidden="true">${h(title)}</span>
    <input class="ds-number" type="text" inputmode="decimal" value="${value}"
      aria-label="${h(title)}精确数值" aria-describedby="ds-number-help"${disabled ? ' disabled' : ''}>
    <div class="ds-ticks" aria-hidden="true"></div>
    <div class="ds-marker" aria-hidden="true"></div>
  </div>`;
}

function designSystemPanel() {
  const rows = [
    ['参数行 / 滑杆', '26 + 6', '轨道 26，刻度带 6，悬浮或聚焦才显示刻度'],
    ['密排行', '22', '图层、预设、折叠分组'],
    ['分组头', '32', '13pt 半粗标题，带展开箭头与复位'],
    ['分段标签', '24', '11pt，选中 2pt 强调色下划线；暗房色彩模式复用此规格'],
    ['图标按钮', '26', '只有图标时仍保留 26×26 命中区'],
    ['数字输入', '21', '集成在参数行右端，宽度 66/70'],
  ];
  const spacing = [
    ['行间隔', '4', '同一分组内参数行之间'],
    ['行内', '7', '标签与数值、图标与文字'],
    ['分组', '12', '参数分组之间'],
    ['分节', '16', '面板分节、弹窗内容'],
    ['检查器内边距', '12', '左右同宽'],
    ['弹窗内边距', '14', '设置与旧版检查器'],
  ];
  const type = [
    ['分组标题', '13 semibold'],
    ['参数标题', '12'],
    ['控件标签', '11 medium'],
    ['说明', '10'],
    ['读数 / 徽标', '9 · 仅限示波器'],
  ];
  return `<section class="ds-page">
    <p class="ds-lede">这份画廊是 <strong>039 界面规范</strong>的可操作部分：左侧是照片工作区的自绘控件，系统框架（菜单、工具栏、设置表单、弹窗）保持 macOS 原生。评审时先在这里核对行高、字级、四态和版式，再到原生应用复验。</p>
    <div class="ds-principles">
      <article><h3>照片是判读中心</h3><p>控件只用中性色与单一强调色，不用渐变、阴影或彩色底占据画面。颜色只表达状态。</p></article>
      <article><h3>密集但可读</h3><p>参数行固定 26 点，标题、轨道与精确数值共用一行；说明完整换行，不压缩行距。</p></article>
      <article><h3>原生优先</h3><p>菜单、工具栏、设置、弹窗和表格直接使用系统控件，让 Liquid Glass 与辅助功能由系统负责。</p></article>
    </div>

    <section class="ds-block" aria-labelledby="ds-controls">
      <div class="ds-block-head"><h2 id="ds-controls">控件标本</h2><p>常态、悬停、聚焦、按下与禁用。悬停或聚焦滑杆时下方刻度出现，行位置不变。</p></div>
      <div class="ds-stage">
        <div class="ds-stage-label">参数行 · 26 + 6</div>
        ${dsSlider({ title: '曝光 EV', id: 'ds-exposure', min: -5, max: 5, step: 0.05, digits: 2, value: 0.35 })}
        ${dsSlider({ title: '色温 K', id: 'ds-temperature', min: 2000, max: 50000, step: 10, digits: 0, value: 6500 })}
        ${dsSlider({ title: '停用', id: 'ds-disabled', min: 0, max: 100, step: 1, digits: 0, value: 12, disabled: true })}
        <p class="ds-help" id="ds-number-help">输入范围：曝光 −5 至 5，色温 2000 至 50000。回车或离开输入框应用，Escape 恢复。非法值保留红框与说明，不写入。</p>
      </div>

      <div class="ds-grid">
        <div class="ds-stage">
          <div class="ds-stage-label">勾选 · 14 方框 / 26 行高</div>
          <button class="ds-check" role="checkbox" aria-checked="true" data-ds-check>
            <span class="ds-check-box" aria-hidden="true"></span><span>使用拍摄白平衡</span>
          </button>
          <button class="ds-check" role="checkbox" aria-checked="false" data-ds-check>
            <span class="ds-check-box" aria-hidden="true"></span><span>未勾选</span>
          </button>
          <button class="ds-check is-disabled" role="checkbox" aria-checked="false" disabled>
            <span class="ds-check-box" aria-hidden="true"></span><span>停用</span>
          </button>
        </div>

        <div class="ds-stage">
          <div class="ds-stage-label">按钮 · 26 高 / 11 medium</div>
          <div class="ds-row">
            <button class="ds-btn">标准</button>
            <button class="ds-btn">加宽按钮</button>
            <button class="ds-btn is-selected">选中</button>
            <button class="ds-btn" disabled>停用</button>
          </div>
          <div class="ds-row">
            <button class="ds-icon-btn" aria-label="复位" title="复位">${icon('undo', 13)}</button>
            <button class="ds-icon-btn is-selected" aria-label="显示叠层" title="显示叠层">${icon('eye', 13)}</button>
            <button class="ds-icon-btn" aria-label="新建" title="新建" disabled>${icon('plus', 13)}</button>
            <button class="ds-icon-btn" aria-label="删除" title="删除">${icon('trash', 13)}</button>
          </div>
        </div>

        <div class="ds-stage">
          <div class="ds-stage-label">分段标签 · 24 高</div>
          <div class="ds-tabs" role="tablist" aria-label="示波器">
            <button role="tab" aria-selected="true">直方图</button>
            <button role="tab" aria-selected="false">波形</button>
            <button role="tab" aria-selected="false">矢量</button>
          </div>
          <div class="ds-stage-label">菜单 · 26 高 / 12 medium</div>
          <label class="ds-field"><span>白平衡</span>
            <select class="ds-select"><option>自动</option><option>拍摄</option><option>自定义</option></select>
          </label>
        </div>
      </div>

      <div class="ds-stage" data-ds-section>
        <div class="ds-section-head">
          <button class="ds-section-toggle" aria-expanded="true">
            <span class="ds-chevron" aria-hidden="true">${icon('chevron', 12)}</span><span>光效</span>
          </button>
          <span class="ds-section-trail">自动</span>
          <button class="ds-icon-btn" aria-label="复位光效" title="复位光效" data-ds-reset-section>${icon('undo', 13)}</button>
        </div>
        <div class="ds-section-body">
          <button class="ds-check" role="checkbox" aria-checked="true" data-ds-check>
            <span class="ds-check-box" aria-hidden="true"></span><span>启用光效</span>
          </button>
          <p class="ds-hint">停用后保留已设置的数值；复位只在该组被修改后可点。</p>
        </div>
      </div>
    </section>

    <section class="ds-block" aria-labelledby="ds-tokens">
      <div class="ds-block-head"><h2 id="ds-tokens">令牌</h2><p>可见数值只允许取自 <code>AppDesign</code>。以下表格与 <code>Sources/RAWMaster/DesignLanguage.swift</code> 一一对应。</p></div>
      <div class="ds-token-grid">
        <div><h3>尺寸</h3><table class="ds-table">${rows.map(([n, v, d]) => `<tr><th>${h(n)}</th><td><code>${h(v)}</code></td><td>${h(d)}</td></tr>`).join('')}</table></div>
        <div><h3>间距</h3><table class="ds-table">${spacing.map(([n, v, d]) => `<tr><th>${h(n)}</th><td><code>${h(v)}</code></td><td>${h(d)}</td></tr>`).join('')}</table></div>
        <div><h3>字级</h3><table class="ds-table">${type.map(([n, v]) => `<tr><th>${h(n)}</th><td><code>${h(v)}</code></td><td class="ds-type-sample">${h(n)}</td></tr>`).join('')}</table></div>
        <div><h3>圆角</h3><div class="ds-radius-row">${[['图形', 2], ['控件', 5], ['容器', 7], ['输入区', 9]].map(([n, v]) => `<span class="ds-radius" style="border-radius:${v}px">${v}</span><small>${n}</small>`).join('')}</div>
          <h3>墨色</h3><div class="ds-swatch-row">${dsTones.map(([n, v, d]) => `<span class="ds-swatch" style="background:${v}"></span><small>${n}<br>${d}</small>`).join('')}</div></div>
      </div>
    </section>

    <section class="ds-block" aria-labelledby="ds-layout">
      <div class="ds-block-head"><h2 id="ds-layout">检查器版式</h2><p>宽度变化时先压缩数值宽度，再换行说明；标签、轨道与数值始终同一行。左右内边距同宽。</p></div>
      <div class="ds-anatomy">
        <div class="ds-anatomy-inset"><span>12</span>
          <div class="ds-anatomy-group"><span>分组 12</span>
            <div class="ds-anatomy-row">标题 12 · 控件 26 · 数值 66</div>
            <div class="ds-anatomy-row is-muted">行间隔 4</div>
          </div>
        </div>
        <p class="ds-hint">深色、浅色和 390pt 窄窗都要保留完整数值与可聚焦控件；系统控件的 Liquid Glass 外观随 macOS 26 及更高版本自动更新。</p>
      </div>
    </section>

    <section class="ds-block" aria-labelledby="ds-migration">
      <div class="ds-block-head"><h2 id="ds-migration">迁移状态</h2><p>规范先行，旧面板按批次替换。未完成前不要在新代码里另起一套控件。</p></div>
      <table class="ds-table ds-wide">
        <thead><tr><th>范围</th><th>现状</th><th>目标</th></tr></thead>
        <tbody>
          <tr><td>参数行、滑杆</td><td>检查器已统一；旧初修面板仍用 SwiftUI Slider</td><td>全部改用 <code>PhotosSliderRow</code> / <code>AppSliderRow</code></td></tr>
          <tr><td>数字输入</td><td>检查器有校验；导出仍用 <code>TextField.roundedBorder</code></td><td>全部改用 <code>DevelopmentNumberField</code></td></tr>
          <tr><td>勾选</td><td>三种：14pt 自绘、系统 checkbox、系统 switch</td><td>编辑面用自绘；设置与弹窗保留系统</td></tr>
          <tr><td>分段</td><td>下划线、系统 segmented、胶囊三种</td><td>编辑面下划线；系统容器用 segmented</td></tr>
          <tr><td>图标按钮</td><td>24–32pt 五种尺寸，悬停态不一致</td><td>26pt <code>AppIconButton</code></td></tr>
          <tr><td>分组头</td><td>照片检查器 32pt；蒙版 22pt 折叠头</td><td>主分组 32pt，密排折叠 22pt</td></tr>
        </tbody>
      </table>
    </section>

    <section class="ds-block" aria-labelledby="ds-review">
      <div class="ds-block-head"><h2 id="ds-review">评审清单</h2><p>提交界面变更前逐项核对；缺项写进特性验证记录。</p></div>
      <ul class="ds-checklist">
        <li>行高只允许 26 / 22 / 32 / 24；字号只允许 13 / 12 / 11 / 10 / 9。</li>
        <li>控件颜色来自 <code>AppDesign.Ink</code>，没有新的 <code>Color(white:)</code> 或临时透明度。</li>
        <li>悬停只作补充；键盘 Tab 能到达，焦点环可见，方向键与步进符合规范。</li>
        <li>禁用保留数值与说明，并给出原因；不复用空占位。</li>
        <li>数字输入校验范围、不允许千位分隔、回车提交、Escape 取消、输入法组合期不提交。</li>
        <li>浅色、深色、390pt 窄窗与系统“降低透明度/减少动态效果”各走查一次。</li>
      </ul>
    </section>
  </section>`;
}

function dsNumberText(value, digits) {
  return Number(value).toFixed(digits).replace(digits > 0 ? /\.?0+$/ : /$^/, '');
}

function dsSync(slider) {
  const min = Number(slider.dataset.min),
    max = Number(slider.dataset.max),
    step = Number(slider.dataset.step),
    value = Number(slider.dataset.value),
    fraction = max > min ? (value - min) / (max - min) : 0,
    neutral = slider.dataset.neutral == null ? (min < 0 ? (0 - min) / (max - min) : 0) : Number(slider.dataset.neutral);
  slider.style.setProperty('--ds-position', (fraction * 100).toFixed(2) + '%');
  slider.style.setProperty('--ds-neutral', (neutral * 100).toFixed(2) + '%');
  slider.style.setProperty('--ds-fill-from', (Math.min(neutral, fraction) * 100).toFixed(2) + '%');
  slider.style.setProperty('--ds-fill-to', (Math.max(neutral, fraction) * 100).toFixed(2) + '%');
  const range = slider.querySelector('.ds-range'),
    number = slider.querySelector('.ds-number');
  range.value = String(value);
  range.setAttribute('aria-valuetext', dsNumberText(value, Number(slider.dataset.digits)));
  if (document.activeElement !== number) number.value = dsNumberText(value, Number(slider.dataset.digits));
  number.setAttribute('aria-invalid', 'false');
  slider.querySelector('.ds-ticks')?.replaceChildren(
    ...Array.from({ length: 21 }, (_, index) => {
      const tick = document.createElement('span');
      tick.className = index % 5 === 0 ? 'major' : '';
      return tick;
    }),
  );
}

function dsCommit(slider, raw) {
  const min = Number(slider.dataset.min),
    max = Number(slider.dataset.max),
    digits = Number(slider.dataset.digits),
    number = slider.querySelector('.ds-number');
  const valid = /^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(raw.trim()),
    value = valid ? Number(raw) : NaN;
  if (!valid || !Number.isFinite(value) || value < min || value > max) {
    number.classList.add('is-invalid');
    number.setAttribute('aria-invalid', 'true');
    return false;
  }
  number.classList.remove('is-invalid');
  slider.dataset.value = String(value);
  dsSync(slider);
  number.value = dsNumberText(value, digits);
  return true;
}

function dsInit() {
  if (location.hash !== '#tools/design') return;
  document.querySelectorAll('[data-ds-slider]').forEach((slider) => {
    if (slider.dataset.ready) return;
    slider.dataset.ready = '1';
    dsSync(slider);
  });
}

document.addEventListener('input', (event) => {
  const range = event.target.closest?.('.ds-range');
  if (!range) return;
  const slider = range.closest('[data-ds-slider]');
  slider.dataset.value = range.value;
  dsSync(slider);
});

document.addEventListener('change', (event) => {
  const number = event.target.closest?.('.ds-number');
  if (number && !number.closest('[data-ds-slider]')?.classList.contains('is-disabled'))
    dsCommit(number.closest('[data-ds-slider]'), number.value);
  const selected = event.target.closest?.('.ds-select');
  if (selected) notify('菜单已选择：' + selected.value);
});

document.addEventListener('keydown', (event) => {
  const tabItem = event.target.closest?.('.ds-tabs [role=tab]');
  if (tabItem) {
    const tabs = [...tabItem.parentElement.querySelectorAll('[role=tab]')],
      index = tabs.indexOf(tabItem);
    let next = index;
    if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
    else if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === 'Home') next = 0;
    else if (event.key === 'End') next = tabs.length - 1;
    else return;
    event.preventDefault();
    tabs[next].click();
    tabs[next].focus();
    return;
  }
  const number = event.target.closest?.('.ds-number');
  if (!number) return;
  const slider = number.closest('[data-ds-slider]');
  if (event.key === 'Enter') {
    event.preventDefault();
    if (dsCommit(slider, number.value)) number.blur();
    else number.focus();
  } else if (event.key === 'Escape') {
    number.classList.remove('is-invalid');
    number.setAttribute('aria-invalid', 'false');
    number.value = dsNumberText(Number(slider.dataset.value), Number(slider.dataset.digits));
    dsSync(slider);
    number.blur();
  }
});

document.addEventListener('click', (event) => {
  const check = event.target.closest?.('[data-ds-check]');
  if (check && !check.disabled) {
    const next = check.getAttribute('aria-checked') !== 'true';
    check.setAttribute('aria-checked', String(next));
    notify(next ? '已勾选' : '已取消勾选');
  }
  const tab = event.target.closest?.('.ds-tabs [role=tab]');
  if (tab) {
    tab.parentElement.querySelectorAll('[role=tab]').forEach((item) => item.setAttribute('aria-selected', String(item === tab)));
  }
  const toggle = event.target.closest?.('.ds-section-toggle');
  if (toggle) {
    const open = toggle.getAttribute('aria-expanded') !== 'true';
    toggle.setAttribute('aria-expanded', String(open));
    const body = toggle.closest('[data-ds-section]').querySelector('.ds-section-body');
    body.hidden = !open;
  }
  const reset = event.target.closest?.('[data-ds-reset-section]');
  if (reset) {
    const slider = reset.closest('[data-ds-section]').querySelector('[data-ds-slider]');
    if (slider) { slider.dataset.value = '0'; dsSync(slider); notify('该组已复位'); }
    else notify('该组已复位');
  }
});

const dsObserver = new MutationObserver(dsInit);
dsObserver.observe($('#workspace'), { childList: true, subtree: false });
window.addEventListener('hashchange', () => requestAnimationFrame(dsInit));
