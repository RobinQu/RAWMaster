'use strict';

function navItem(label, ic, path, count) {
  const active = (S.page === 'library' ? 'library/' + S.scope : S.page + '/' + S.sub) === path;
  return `<button data-act="goto" data-val="${h(path)}" class="nav-item ${active ? 'current' : ''}" ${active ? 'aria-current="page"' : ''}>${icon(ic)}<span>${h(label)}</span>${count != null ? `<small>${count}</small>` : ''}</button>`;
}
function navList() {
  const c = Studio.catalog(),
    all = Studio.admitted(),
    open = c.sessions.filter((s) => s.state !== 'sealed');
  return `<aside class="rail ${S.drawer ? 'revealed' : ''}" aria-label="资料库导航"><div class="rail-scroll">
    <div class="rail-caption">资料库</div>${navItem('全部素材', 'library', 'library/all', all.length)}${navItem('精选照片', 'flag', 'library/picks', all.filter((id) => Studio.asset(id).decision === 'keep').length)}
    ${navItem('拍摄组', 'stack', 'tools/groups', c.groups.length)}${navItem('导入历史', 'clock', 'tools/history', c.sessions.filter((s) => s.state === 'sealed').length)}
    <div class="rail-caption">项目</div>${c.projects.map((p) => navItem(p.name, 'folder', 'library/project/' + p.id, p.ids.length)).join('')}
    <div class="rail-caption">集合</div>${c.collections.map((col) => navItem(col.name, 'layers', 'library/collection/' + col.id)).join('')}
    <div class="rail-caption">导入与初筛</div>${open.map((s) => navItem(s.name, 'tray', 'library/triage/' + s.id, s.ids.length)).join('') || '<p class="rail-empty">没有待初筛的批次</p>'}
    ${isTriage() || isHistory() || Studio.scopeInfo(S.scope).group ? btn('接入素材', 'import', '', { icon: 'plus', cls: 'rail-import' }) : ''}</div>
    <div class="rail-bottom">${navItem('资料库工具', 'tools', 'tools/package')}${navItem('智能检索', 'search', 'tools/discovery')}
    <div class="volume">${icon('disk', 17)}<div><strong>本机资料库</strong><small>示例资料 · 本机保存</small></div><i></i></div></div></aside>`;
}
const isTriage = () => {
  const s = Studio.scopeInfo(S.scope).session;
  return Boolean(s && s.state !== 'sealed');
};
const isHistory = () => Studio.scopeInfo(S.scope).session?.state === 'sealed';
function selectPhoto(id, event = {}) {
  const b = activeBrowser(),
    ids = Studio.visible(S.scope);
  if (event.shiftKey) {
    const start = ids.indexOf(b.anchor ?? b.focus),
      end = ids.indexOf(id);
    b.selected = ids.slice(Math.max(0, Math.min(start, end)), Math.max(start, end) + 1);
  } else if (event.metaKey || event.ctrlKey || S.multi) {
    b.selected = b.selected.includes(id) ? b.selected.filter((x) => x !== id) : [...b.selected, id];
    b.anchor = id;
  } else {
    b.selected = [id];
    b.anchor = id;
  }
  b.focus = id;
  Studio.save();
  if (b.view !== 'grid' || !$('.contact-grid')) {
    render();
    return;
  }
  for (const card of $$('.photo-card[data-act=photo]')) {
    const selected = b.selected.includes(card.dataset.val);
    card.classList.toggle('selected', selected);
    card.setAttribute('aria-pressed', String(selected));
    const tick = card.querySelector('.tick');
    if (tick && !selected) tick.remove();
    if (!tick && selected)
      card
        .querySelector('.thumb')
        .insertAdjacentHTML('beforeend', `<span class="tick">${icon('check', 12)}</span>`);
  }
  $('#chrome').innerHTML = chrome();
  $('.actionbar').outerHTML = actionbar(b, Studio.scopeInfo(S.scope));
  if (!S.filters) $('.inspector').innerHTML = inspector(id);
}
function changeMode(mode) {
  const b = activeBrowser();
  if (mode === 'compare' && (b.selected.length < 2 || b.selected.length > 4)) {
    dialog(
      '比较照片',
      `<p>选择 2–4 张照片并排查看。</p><div class="choice-grid">${Studio.visible(S.scope)
        .map((id) => check(Studio.asset(id).name, 'cmp-' + id, b.selected.includes(id)))
        .join('')}</div><p id="compare-error" role="status"></p>`,
      btn('取消', 'close') + btn('开始比较', 'compare-chosen', '', { cls: 'primary' }),
    );
    return;
  }
  b.view = mode;
  S.zoom = false;
  Studio.save();
  render();
}
function histogram(id) {
  const channels = RMHistogram[Studio.asset(id).source || id];
  if (!channels) return '';
  return `<figure class="histogram" aria-label="示例 JPEG 的 RGB 直方图"><figcaption>直方图 <small>RGB</small></figcaption><svg viewBox="0 0 160 49" preserveAspectRatio="none" role="img" aria-label="红绿蓝三通道分布"><path d="M40 2v45m40-45v45m40-45v45" stroke="#455057" stroke-dasharray="2 3"/>${channels.map((points, i) => `<path d="M0 48 ${points.map((n, j) => `L${(j * 160) / (points.length - 1)} ${47 - n}`).join(' ')} L160 48Z" fill="${['#e68c7f', '#81bc98', '#79aeea'][i]}" opacity=".62" style="mix-blend-mode:screen"/>`).join('')}</svg></figure>`;
}
function filmstrip(ids, focus, act = 'photo') {
  return `<div class="filmstrip" aria-label="胶片带">${ids.map((id) => `<button data-act="${act}" data-val="${id}" class="${id === focus ? 'chosen' : ''}" aria-label="${h(Studio.asset(id).name)}" aria-pressed="${id === focus}">${pic(id)}</button>`).join('')}</div>`;
}
function card(id, b) {
  const a = Studio.asset(id),
    p = Studio.photo(id),
    selected = b.selected.includes(id),
    decision = isTriage() ? a.triage : a.decision;
  return `<button class="photo-card ${selected ? 'selected' : ''}" data-act="photo" data-val="${id}" aria-pressed="${selected}" aria-label="${h(a.name + '，' + p.scene)}">
    <span class="thumb">${pic(id, p.w < p.h || (p.series === 'woods' && p.frame === 5) ? 'portrait' : '')}<span class="format">${a.pair ? 'RAW + JPEG' : a.name.toUpperCase().endsWith('.JPG') ? 'JPEG' : 'RAW'}</span>
    ${!a.online ? '<span class="offline">离线</span>' : ''}${selected ? `<span class="tick">${icon('check', 12)}</span>` : ''}</span>
    <span class="card-line"><b>${h(a.name)}</b>${decision === 'keep' ? icon('flag', 13) : decision === 'reject' ? '<span class="reject">×</span>' : ''}</span>
    <span class="card-line meta"><span>${h(p.exif.focal)} · ${h(p.clock.slice(0, 5))}</span><span class="stars">${a.stars ? '★'.repeat(a.stars) : ''}</span></span></button>`;
}
function filterForm(b) {
  const fields =
    select('最低星级', 'minStars', [[0, '全部'], ...[1, 2, 3, 4, 5].map((n) => [n, n + ' 星'])], b.minStars) +
    select(
      '决定',
      'decision',
      [
        ['all', '全部'],
        ['keep', '保留'],
        ['reject', '排除'],
        ['none', '未决定'],
      ],
      b.decision,
    );
  return `<div class="filter-panel"><div class="row between"><h3>筛选</h3>${btn('清除条件', 'clear-filters', '', { cls: 'link' })}</div>${isTriage() ? '' : fields}
    ${select(
      '原片状态',
      'availability',
      [
        ['all', '全部'],
        ['online', '在线'],
        ['offline', '离线'],
      ],
      b.availability,
    )}
    ${select('机型', 'camera', [['all', '全部'], 'DJI Mavic 3', 'Sony α7 IV'], b.camera)}
    ${field('拍摄日期', 'date', b.date, 'date')}${field('标签', 'tag', b.tag)}
    ${
      !isTriage()
        ? select(
            '审阅',
            'review',
            [
              ['all', '全部'],
              ['reviewed', '已审'],
              ['new', '未审'],
            ],
            b.review,
          )
        : ''
    }</div>`;
}
function inspector(id) {
  if (!id) return empty('没有选片', '选择一张照片查看拍摄信息。');
  const p = Studio.photo(id),
    a = Studio.asset(id),
    stage = isTriage(),
    history = isHistory();
  const editRating = Array.from({ length: 5 }, (_, i) =>
    btn(i + 1 + ' 星', 'rate', i + 1, {
      icon: 'star',
      only: true,
      cls: 'rating ' + (i < a.stars ? 'lit' : ''),
    }),
  ).join('');
  const groups = Studio.catalog().groups.filter((g) => g.ids.includes(id));
  return `<div class="inspector-title"><h2>照片信息</h2>${btn('收起照片信息', 'inspector', '', { only: true, icon: 'side', cls: 'icon-btn' })}</div>
    ${histogram(id)}<h3 class="filename">${h(a.name)}</h3><p class="muted">${h(p.scene)} · ${a.online ? '原片在线' : '原片离线'}</p>
    <div class="ins-block"><h4>拍摄参数</h4><div class="four-readouts"><strong>${h(p.exif.aperture)}</strong><strong>${h(p.exif.shutter)}</strong><strong>${h(p.exif.iso)}</strong><strong>${h(p.exif.focal)}</strong></div>
    <dl>${fact('相机', p.exif.camera)}${fact('拍摄日期', p.date)}${fact('原片尺寸', p.w + ' × ' + p.h)}</dl></div>
    <div class="ins-block"><h4>${stage ? '初筛处置' : '审阅'}</h4><dl>${fact('决定', { none: '未决定', pending: '待初筛', keep: stage ? '通过' : '保留', reject: '排除', sequence: '仅序列' }[stage ? a.triage : a.decision])}</dl>
    ${
      !stage && !history
        ? `<div class="rate-row">${editRating}${btn('清除星级', 'rate', 0, { cls: 'link' })}</div>${select('颜色标签', 'colorLabel', ['无', '红色', '黄色', '绿色', '青色', '紫色'], a.label)}
    <div class="row wrap">${a.tags.map((t) => `<span class="tag">${h(t)}</span>`).join('')}${btn('编辑标签', 'tags', '', { cls: 'link', icon: 'tag' })}</div>`
        : ''
    }</div>
    <div class="ins-block"><h4>文件与关联</h4><dl>${fact('文件组合', a.pair ? 'RAW + JPEG' : '单文件')}${fact('拍摄组', groups.map((g) => g.name).join('、') || '—')}</dl>
    <div class="row wrap">${btn('查看文件', 'files', id, { cls: 'link' })}${!a.online ? btn('重新定位…', 'relink', id, { cls: 'link' }) : ''}${validWork(id) ? btn('检查器', 'inspection', id, { cls: 'link' }) : ''}</div></div>`;
}
function gridCards(ids, b, info) {
  if (!b.fold || info.group || info.session) return ids.map((id) => card(id, b)).join('');
  const displayed = new Set(),
    groups = Studio.catalog().groups;
  return ids
    .map((id) => {
      if (displayed.has(id)) return '';
      const g = groups.find((g) => g.ids.includes(id) && g.ids.filter((k) => ids.includes(k)).length > 1);
      if (!g) return card(id, b);
      const members = g.ids.filter((k) => ids.includes(k));
      members.forEach((k) => displayed.add(k));
      return `<button class="photo-card" data-act="goto" data-val="library/group/${g.id}"><span class="thumb">${pic(id)}<span class="format">${members.length} 次拍摄</span></span><span class="card-line"><b>${h(g.name)}</b>${icon('stack', 14)}</span><span class="card-line meta">${h(g.kind)}</span></button>`;
    })
    .join('');
}
function actionbar(b, info) {
  const selected = b.selected.length,
    stage = isTriage(),
    history = isHistory(),
    focus = b.focus;
  return `<footer class="actionbar"><strong>已选 ${selected} 张</strong><div class="row wrap">${
    history
      ? btn('查看封存记录', 'history-detail', info.session.id)
      : btn(stage ? '通过' : '保留', 'decide', 'keep', { icon: 'flag', disabled: !selected }) +
        btn('排除', 'decide', 'reject', { disabled: !selected }) +
        btn('更多…', 'selection-menu', '', { disabled: !selected })
  }</div>
      <div class="row end">${btn('编辑照片', 'edit', '', { disabled: !validWork(focus), icon: 'edit' })}${btn('导出', 'export', '', { cls: 'primary', icon: 'export', disabled: !b.selected.some(validWork) })}</div></footer>`;
}
function libraryView() {
  const info = Studio.scopeInfo(S.scope),
    b = activeBrowser(),
    ids = Studio.visible(S.scope),
    focus = b.focus;
  const fileCount = info.ids.reduce((n, id) => n + (Studio.asset(id).pair ? 2 : 1), 0);
  const filters = ['query', 'minStars', 'availability', 'decision', 'camera', 'date', 'tag', 'review'].filter(
    (k) => b[k] && b[k] !== 'all',
  );
  const viewing =
    b.view === 'compare' && b.selected.length >= 2 && b.selected.length <= 4
      ? 'compare'
      : b.view === 'single'
        ? 'single'
        : 'grid';
  let content = '';
  if (!ids.length)
    content = empty(
      '没有符合条件的照片',
      '可以调整筛选条件，或从左侧接入一批素材。',
      btn('清除条件', 'clear-filters'),
    );
  else if (viewing === 'grid') content = `<div class="contact-grid">${gridCards(ids, b, info)}</div>`;
  else if (viewing === 'single')
    content = `<div class="loupe ${S.zoom ? 'zoomed' : ''}">${pic(focus)}${btn(S.zoom ? '适合窗口' : '100% · Z', 'zoom', '', { cls: 'canvas-zoom' })}</div>${filmstrip(ids, focus)}`;
  else
    content = `<div class="comparison">${b.selected.map((id) => `<figure>${pic(id)}<figcaption><strong>${h(Studio.asset(id).name)}</strong><small>${h(Studio.photo(id).exif.shutter)} · ${h(Studio.photo(id).exif.iso)}</small></figcaption></figure>`).join('')}</div>`;
  const stage = isTriage(),
    history = isHistory(),
    g = info.group;
  return `<div class="library-layout ${S.inspector ? '' : 'no-inspector'} ${S.librarySidebar ? '' : 'no-sidebar'}">${navList()}<section class="library-main">
    <div class="view-heading"><div class="crumb">本机资料库 <span>/</span> ${h(info.section)}</div>
      <div class="row between wrap"><h1>${h(info.title)}</h1>${stage ? btn('完成整批初筛…', 'seal', '', { cls: 'primary' }) : g ? btn('分组制作…', 'process', g.id, { icon: 'film' }) : btn('接入素材', 'import', '', { icon: 'import', cls: 'import-top' })}</div>
      <p>${info.ids.length} 次拍摄 <span>·</span> ${fileCount} 个文件 <span>·</span> ${stage ? '待人工初筛' : history ? '已封存' : g ? h(g.kind) : '2026 年 10 月'}</p></div>
    <div class="library-tools"><div class="row"><div class="switch compact" aria-label="浏览方式">${[
      ['grid', '网格', 'grid'],
      ['single', '单张', 'single'],
      ['compare', '比较', 'compare'],
    ]
      .map(([v, n, ic]) =>
        btn(n, 'mode', v, {
          icon: ic,
          only: true,
          pressed: viewing === v,
          title: n + ' · ' + { grid: 'G', single: 'E', compare: 'C' }[v],
        }),
      )
      .join('')}</div>
      ${btn('显示选项', 'sort', '', { cls: 'plain sort', title: '显示与排序 · ' + b.sort, icon: 'down' })}</div><div class="row">
      ${btn('多选', 'multi', '', { cls: 'plain', pressed: !!S.multi })}
      ${btn('搜索照片', 'search-toggle', '', { icon: 'search', only: true, cls: 'icon-btn', pressed: !!(S.search || b.query) })}${btn('筛选', 'filters', '', { icon: 'sliders', pressed: S.filters })}${btn('照片信息', 'inspector', '', { icon: 'side', only: true, cls: 'icon-btn' })}</div></div>
    ${S.search || b.query ? `<label class="search-box">${icon('search')}<input type="search" name="query" value="${h(b.query)}" placeholder="搜索文件名、场景或标签" aria-label="搜索照片"></label>` : ''}
    ${filters.length ? `<div class="chips">${filters.map((k) => btn(String(b[k]) + ' ×', 'remove-filter', k, { cls: 'chip' })).join('')}<small>${ids.length} 张匹配</small></div>` : ''}
    ${stage || g || history ? `<div class="context-row">${stage ? btn('初筛操作…', 'triage-menu') + `<small>${info.session.scan ? '已扫描拍摄组' : '待复核拍摄组'}</small>` : g ? btn('组属性与成员…', 'manage-group', g.id) + `<small>${g.protected ? '结构已保护' : '手工顺序'}</small>` : btn('查看封存清单…', 'history-detail', info.session.id)}</div>` : ''}
    <div class="photos-scroll">${content}</div>
    ${actionbar(b, info)}</section>
    <aside class="inspector ${S.mobileInspector ? 'revealed' : ''}" aria-label="照片信息与筛选">${S.filters ? filterForm(b) + btn('收起筛选', 'filters', '', { cls: 'link' }) : inspector(focus)}</aside></div>`;
}
actions.photo = selectPhoto;
document.addEventListener('dblclick', (event) => {
  if (!S.multi && event.target.closest('.photo-card[data-act=photo]')) changeMode('single');
});
actions.mode = changeMode;
actions['compare-chosen'] = () => {
  const ids = Studio.visible(S.scope).filter((id) => checked('cmp-' + id));
  if (ids.length < 2 || ids.length > 4) {
    $('#compare-error').textContent = '需要选择 2–4 张照片。';
    return;
  }
  const b = activeBrowser();
  b.selected = ids;
  b.focus = ids[0];
  closeSheet();
  changeMode('compare');
};
actions.zoom = () => {
  S.zoom = !S.zoom;
  render();
};
actions.filters = () => {
  S.filters = !S.filters;
  S.inspector = true;
  S.mobileInspector = S.filters;
  render();
};
actions['search-toggle'] = () => {
  S.search = !S.search;
  render();
  $('[name=query]')?.focus();
};
actions.sort = () =>
  dialog(
    '显示与排序',
    select('排序方式', 'setSort', ['拍摄顺序', '文件名', '星级优先'], activeBrowser().sort) +
      check('在网格中折叠拍摄组', 'fold', activeBrowser().fold),
    btn('完成', 'close'),
  );
changes.fold = (el) => {
  activeBrowser().fold = el.checked;
  Studio.save();
  render();
};
actions.multi = () => {
  S.multi = !S.multi;
  render();
};
changes.setSort = (el) => {
  activeBrowser().sort = el.value;
  Studio.save();
  render();
};
function setFilter(name, v) {
  Studio.browser(S.scope)[name] = v;
  Studio.save();
  render();
}
for (const name of ['minStars', 'availability', 'decision', 'camera', 'date', 'review'])
  changes[name] = (el) => setFilter(name, name === 'minStars' ? Number(el.value) : el.value);
for (const name of ['tag', 'query'])
  inputs[name] = (el) => {
    const pos = el.selectionStart;
    setFilter(name, el.value);
    const next = $(`[name="${name}"]`);
    next?.focus();
    if (next && pos != null) next.setSelectionRange(pos, pos);
  };
const filterDefaults = {
  query: '',
  minStars: 0,
  availability: 'all',
  decision: 'all',
  camera: 'all',
  date: '',
  tag: '',
  review: 'all',
};
actions['clear-filters'] = () => {
  Object.assign(activeBrowser(), filterDefaults);
  Studio.save();
  render();
};
actions['remove-filter'] = (key) => setFilter(key, filterDefaults[key]);
actions.decide = (d) => {
  if (isHistory()) return;
  const ids = activeIDs(),
    stage = isTriage();
  mutate(stage ? '已更新初筛处置' : '已更新项目决定', () =>
    ids.forEach((id) => {
      const a = Studio.asset(id);
      if (stage) a.triage = d === 'none' ? 'pending' : d;
      else {
        a.decision = d;
        a.reviewed = true;
      }
    }),
  );
};
actions.rate = (v) => {
  if (isTriage() || isHistory()) return;
  const ids = activeIDs();
  mutate('已更新星级', () =>
    ids.forEach((id) => {
      Studio.asset(id).stars = Number(v);
      Studio.asset(id).reviewed = true;
    }),
  );
};
changes.colorLabel = (el) => {
  const ids = activeIDs();
  mutate('已更新颜色标签', () =>
    ids.forEach((id) => {
      Studio.asset(id).label = el.value;
    }),
  );
};
actions['selection-menu'] = () =>
  dialog(
    '选片操作',
    `<div class="menu-list">${btn('清除决定', 'menu-decision', 'none')}${isTriage() ? btn('仅用于序列', 'menu-decision', 'sequence') : btn('标记为已审 / 未审', 'review-toggle') + btn('批量编辑标签…', 'tags') + btn('组织所选作品…', 'goto-close', 'tools/organization') + btn('新建拍摄组…', 'new-group') + btn('复制所选原文件…', 'original-review', 'selection') + btn('交付精选…', 'original-review', 'picks')}${btn('操作记录与撤销…', 'library-log')}</div>`,
  );
actions['goto-close'] = (v) => {
  closeSheet();
  go(v);
};
actions['menu-decision'] = (v) => {
  closeSheet();
  actions.decide(v);
};
actions['review-toggle'] = () => {
  const ids = activeIDs(),
    to = !ids.every((id) => Studio.asset(id).reviewed);
  closeSheet();
  mutate('已更新审阅状态', () => ids.forEach((id) => (Studio.asset(id).reviewed = to)));
};
actions.tags = () => {
  const ids = activeIDs();
  dialog(
    '批量编辑标签',
    `<p>${ids.length} 张照片</p>${select('操作', 'tagOp', ['追加', '移除', '替换'], '追加')}${field('标签（用逗号分隔）', 'tagText')}<div id="tag-review"></div>`,
    btn('取消', 'close') + btn('应用标签', 'apply-tags', '', { cls: 'primary' }),
  );
  previewTags();
};
function rewrittenTags(id) {
  const tags = value('tagText')
      .split(/[,，]/)
      .map((x) => x.trim())
      .filter(Boolean),
    old = Studio.asset(id).tags;
  return value('tagOp') === '替换'
    ? tags
    : value('tagOp') === '移除'
      ? old.filter((t) => !tags.includes(t))
      : [...new Set([...old, ...tags])];
}
function previewTags() {
  const list = activeIDs();
  $('#tag-review').innerHTML =
    `<h4>逐张预览</h4><dl>${list.map((id) => fact(Studio.asset(id).name, (Studio.asset(id).tags.join('、') || '无') + ' → ' + (rewrittenTags(id).join('、') || '无'))).join('')}</dl>`;
}
inputs.tagText = previewTags;
changes.tagOp = previewTags;
actions['apply-tags'] = () => {
  const updates = activeIDs().map((id) => [id, rewrittenTags(id)]);
  closeSheet();
  mutate('已应用标签', () => updates.forEach(([id, tags]) => (Studio.asset(id).tags = tags)));
};
actions['library-log'] = () =>
  dialog(
    '资料库操作记录',
    Studio.data.history.map((x) => `<p class="list-row">${h(x.label)}</p>`).join('') ||
      '<p>尚无操作记录。</p>',
    btn('完成', 'close') + btn('撤销最近操作', 'undo-lib', '', { disabled: !Studio.data.history.length }),
  );
actions['undo-lib'] = () => {
  const label = Studio.undo();
  if (sheet.open) closeSheet();
  render();
  if (label) notify('已撤销 · ' + label);
};
actions.files = (id) => {
  const a = Studio.asset(id);
  dialog(
    '拍摄与文件',
    `<p>${h(Studio.photo(id).scene)}</p><dl>${fact('原文件', a.name)}${a.pair ? fact('JPEG 伴随文件', a.name.replace(/\.[^.]+$/, '.JPG')) : ''}${fact('预览来源', '机内 JPEG 示例')}</dl>`,
    btn('完成', 'close') +
      btn(a.pair ? '解除双格式关联' : '复核双格式候选', 'pair', id, { disabled: a.name.endsWith('.JPG') }),
  );
};
actions.pair = (id) => {
  const a = Studio.asset(id);
  dialog(
    '复核双格式关联',
    `<p>${h(a.name)} 与 ${h(a.name.replace(/\.[^.]+$/, '.JPG'))}</p>`,
    btn('取消', 'close') + btn(a.pair ? '解除关联' : '确认关联', 'set-pair', id, { cls: 'primary' }),
  );
};
actions['set-pair'] = (id) => {
  closeSheet();
  mutate('已更新文件关联', () => {
    Studio.asset(id).pair = !Studio.asset(id).pair;
  });
};
actions.relink = (id) =>
  dialog(
    '重新定位原件',
    `<p>按原有身份核验示例文件，再恢复访问。</p><dl>${fact('待找回', Studio.asset(id).name)}${fact('示例位置', '旅行照片 / DCIM')}</dl>`,
    btn('取消', 'close') + btn('核验并接回', 'link-file', id, { cls: 'primary' }),
  );
actions['link-file'] = (id) => {
  closeSheet();
  mutate('已核验并接回原片', () => (Studio.asset(id).online = true));
};
actions.inspection = (id) => {
  S.inspectIDs = activeIDs().length ? activeIDs() : [id];
  go('tools/inspection');
};
