'use strict';

const toolPages = {
  groups: '拍摄组',
  history: '导入历史',
  organization: '文件夹、集合与作品',
  discovery: '智能检索',
  inspection: '照片检查器',
  package: '资料库与备份',
  files: '受管文件',
  migration: '迁入 Lightroom',
  process: '分组制作',
  design: '界面规范',
  ...(serverReview ? {server: 'RAWMaster Server'} : {}),
};
const settingsPages = {
  general: '通用',
  storage: '存储',
  editing: '编辑与预览',
  runtime: '本机 AI',
  cloud: '云服务',
  diagnostics: '诊断',
};
function demoDownload(name, data) {
  const u = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' })),
    a = document.createElement('a');
  a.href = u;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(u), 1000);
}
function rowCard(title, sub, action = '') {
  return `<div class="record"><div><strong>${h(title)}</strong><small>${h(sub)}</small></div>${action}</div>`;
}
function toolView() {
  const settings = S.page === 'settings',
    pages = settings ? settingsPages : toolPages,
    key = Object.hasOwn(pages, S.sub) ? S.sub : settings ? 'general' : 'package';
  const label = settings ? '设置' : '资料库工具',
    prefix = settings ? 'settings/' : 'tools/';
  return `<div class="utility-shell"><aside class="utility-nav">${btn('返回资料库', 'goto', 'library/' + S.scope, { icon: 'library', cls: 'plain' })}<div class="rail-caption">${label}</div>
    ${Object.entries(pages)
      .map(([k, t]) =>
        navItem(
          t,
          {
            groups: 'stack',
            history: 'clock',
            organization: 'folder',
            discovery: 'search',
            inspection: 'eye',
            package: 'disk',
            files: 'tray',
            migration: 'import',
            process: 'film',
            design: 'grid',
            server: 'layers',
          }[k] || 'sliders',
          prefix + k,
        ),
      )
      .join('')}</aside>
    <section class="utility-main"><div class="crumb">RAWMaster <span>/</span> ${label}</div><h1>${pages[key]}</h1>${settings ? settingsPanel(key) : catalogPanel(key)}</section></div>`;
}
function catalogPanel(key) {
  const c = Studio.catalog(),
    ids = activeIDs();
  switch (key) {
    case 'groups':
      return `<div class="row wrap">${btn('从所选照片建组…', 'new-group', '', { icon: 'plus', disabled: !ids.length })}${btn('操作记录', 'library-log')}</div><div class="group-grid">${c.groups.map((g) => `<article>${pic(g.ids[0])}<h3>${h(g.name)}</h3><p>${h(g.kind)} · ${g.ids.length} 次拍摄${g.protected ? ' · 已保护' : ''}</p><div class="row wrap">${btn('浏览', 'goto', 'library/group/' + g.id)}${btn('属性', 'manage-group', g.id)}${btn('制作…', 'process', g.id)}</div></article>`).join('')}</div>`;
    case 'history':
      return (
        c.sessions
          .filter((s) => s.state === 'sealed')
          .map((s) =>
            rowCard(
              s.name,
              s.ids.length + ' 次拍摄 · ' + s.mode,
              btn('查看清单', 'history-detail', s.id) + btn('浏览照片', 'goto', 'library/history/' + s.id),
            ),
          )
          .join('') || empty('没有导入记录', '完成第一批初筛后可以在这里恢复排除项。')
      );
    case 'organization':
      return `<div class="tool-columns"><section><h3>文件夹</h3>${c.folders.map((f) => rowCard(f, '本地卷')).join('')}${btn('新建文件夹…', 'organize', 'folder')}
      <h3>集合</h3>${c.collections.map((col) => rowCard(col.name, col.smart ? '智能集合 · ≥ ' + col.rating + ' 星' : col.ids.length + ' 张作品', btn('打开', 'goto', 'library/collection/' + col.id))).join('')}
      <div class="row wrap">${btn('新建集合…', 'organize', 'collection')}${btn('保存为智能集合…', 'organize', 'smart')}</div></section>
      <section><h3>所选作品</h3>${ids.map((id) => rowCard(Studio.asset(id).name, Studio.photo(id).scene)).join('') || '<p>请先在资料库中选片。</p>'}
      <div class="row wrap">${btn('加入集合…', 'organize', 'add', { disabled: !ids.length })}${btn('重命名作品…', 'organize', 'rename', { disabled: ids.length !== 1 })}${btn('堆叠所选作品…', 'new-group', '', { disabled: ids.length < 2 })}</div></section></div>`;
    case 'package':
      return `<div class="tool-columns"><section><h3>本地资料库</h3>${rowCard(packageLabel(Studio.data), packageLocation().path)}
        <div class="row wrap">${btn('新建资料库…', 'package-new')}${btn('打开资料库包…', 'package-switch')}${btn('重新定位整卷…', 'volume-review')}${btn('校验与重建索引', 'index-review')}</div>
        <details class="settings-advanced"><summary>走查库包打开、移动与拷贝</summary>
          <div class="row wrap">${btn('Finder 示例…', 'package-finder')}${btn('预览首次打开', 'goto', 'welcome')}${btn('预览上次地址失效', 'goto', 'welcome/recover')}</div>
        </details></section>
      <section><h3>备份与还原</h3>${select('备份内容', 'backupMode', ['目录与预览', '包含可用原件与归档', '增量备份'], '包含可用原件与归档')}${btn('预览备份范围…', 'backup-plan', '', { cls: 'primary' })}
      ${c.backup ? rowCard(c.backup, '可校验的示例备份', btn('还原到新资料库…', 'restore-backup') + btn('校验 / 修复', 'backup-verify')) : ''}</section></div>`;
    case 'migration':
      return `<h3>Lightroom Classic 目录</h3>${rowCard('River Valley.lrcat', '示例源目录 · 单向迁入', btn('预检目录…', 'migration-plan'))}
      ${c.migration ? rowCard('最近迁入', c.migration, btn('核对缺项', 'migration-missing')) : ''}`;
    case 'discovery':
      return discoveryPanel();
    case 'inspection':
      return inspectionPanel();
    case 'files':
      return `<h3>移动或改名</h3><p>先核对受管副本的目标与名称。</p>${ids.map((id) => rowCard(Studio.asset(id).name, Studio.asset(id).location || '示例原卷 / DCIM')).join('') || empty('尚未选择文件', '从资料库选中照片后进入受管文件。')}
      ${field('目标文件夹', 'moveTarget', '作品盘 / 河谷')}${field('新文件名前缀（可留空）', 'movePrefix')}${btn('预演移动…', 'move-plan', '', { cls: 'primary', disabled: !ids.length })}`;
    case 'process':
      return processPanel();
    case 'design':
      return designSystemPanel();
    case 'server':
      return serverPanel();
  }
}
function factList(rows) {
  return '<dl>' + rows.map(([a, b]) => fact(a, b)).join('') + '</dl>';
}
actions.organize = (op) => {
  const labels = {
    folder: '新建文件夹',
    collection: '新建集合',
    smart: '新建智能集合',
    add: '加入集合',
    rename: '重命名作品',
  };
  const ids = activeIDs(),
    c = Studio.catalog();
  dialog(
    labels[op],
    op === 'add'
      ? select(
          '集合',
          'collectionID',
          c.collections.filter((x) => !x.smart).map((x) => [x.id, x.name]),
        )
      : field(
          '名称',
          'entityName',
          op === 'rename' ? Studio.asset(ids[0]).name : '',
        ) +
          (op === 'smart' ? select('最低星级', 'smartStars', [1, 2, 3, 4, 5], 4) : '') +
          `<p>${ids.length} 张所选作品</p>`,
    btn('取消', 'close') + btn('保存', 'organize-save', op, { cls: 'primary' }),
  );
};
actions['organize-save'] = (op) => {
  const name = value('entityName').trim(),
    ids = activeIDs(),
    rating = Number(value('smartStars')),
    col = value('collectionID');
  if (op !== 'add' && !name) {
    sheet.querySelector('[name=entityName]').focus();
    return;
  }
  Studio.change('更新资料库组织', (c) => {
    if (op === 'folder' && !c.folders.includes(name)) c.folders.push(name);
    if (op === 'collection' || op === 'smart')
      c.collections.push({ id: Studio.uid(), name, ids: [...ids], smart: op === 'smart', rating });
    if (op === 'add') {
      const dest = c.collections.find((x) => x.id === col);
      if (dest) dest.ids = [...new Set([...dest.ids, ...ids])];
    }
    if (op === 'rename') Studio.asset(ids[0]).name = name;

  });
  closeSheet();
  render();
  notify('已保存');
};
actions['volume-review'] = () => {
  const missing = Studio.admitted().filter((k) => !Studio.asset(k).online);
  dialog(
    '重新定位整卷',
    `<p>示例卷按身份匹配 ${missing.length} 个待找回原件。</p>`,
    btn('取消', 'close') + btn('核验并接回', 'volume-link', '', { disabled: !missing.length }),
  );
};
actions['volume-link'] = () => {
  closeSheet();
  mutate('已重新定位示例卷', () => Studio.admitted().forEach((k) => (Studio.asset(k).online = true)));
};
actions['index-review'] = () =>
  dialog(
    '目录索引',
    `<p>${Studio.catalog().indexes ? '已重建索引。' : '已完成示例索引校验。'}</p>`,
    btn('完成', 'close') + btn('重建索引', 'index-build'),
  );
actions['index-build'] = () => {
  closeSheet();
  mutate('索引已重建', (c) => (c.indexes = true));
};
actions['backup-plan'] = () => {
  const c = Studio.catalog(),
    mode = value('backupMode', $('#workspace')),
    ids = Studio.admitted();
  dialog(
    '备份范围',
    factList([
      ['模式', mode],
      ['目录作品', ids.length],
      ['可用原件', ids.filter((k) => Studio.asset(k).online && !Studio.asset(k).source).length],
      ['仍待找回', ids.filter((k) => !Studio.asset(k).online).length],
      ['导入时排除', c.sessions.reduce((a, s) => a + (s.excluded || []).length, 0)],
    ]) + `<p>${mode === '增量备份' && !c.backup ? '需要先创建首代备份。' : '示例备份保留此次目录快照。'}</p>`,
    btn('取消', 'close') +
      btn('创建示例备份', 'backup-create', mode, { disabled: mode === '增量备份' && !c.backup }),
  );
};
actions['backup-create'] = (mode) => {
  const d = Studio.data,
    c = Studio.catalog();
  c.backup = '河谷备份 · ' + mode;
  d.backupSnapshot = structuredClone({ catalog: c, edits: d.edits });
  Studio.save();
  closeSheet();
  render();
  notify('示例备份完成');
};
actions['backup-verify'] = () =>
  dialog(
    '备份校验',
    Studio.data.backupSnapshot
      ? '<p>目录快照可读，备份清单与本机示例匹配。</p>'
      : '<p>缺少备份快照，请重新备份。</p>',
    btn('完成', 'close'),
  );
actions['restore-backup'] = () =>
  dialog(
    '还原到新资料库',
    field('新库名称', 'restoredName', '河谷 · 恢复副本'),
    btn('取消', 'close') + btn('建立恢复副本', 'restore-new'),
  );
actions['restore-new'] = () => {
  const name = value('restoredName').trim(),
    d = Studio.data,
    snap = d.backupSnapshot;
  if (!name || !snap) return;
  if (availablePackages().some((snapshot) => packageLabel(snapshot) === name)) {
    notify('已有同名资料库');
    return;
  }
  d.libraries ??= {};
  const catalog = {...structuredClone(snap.catalog), packageName: name};
  const id = Studio.uid();
  d.libraries[id] = { catalog, edits: structuredClone(snap.edits), history: [], jobs: [], browse: {},
    packageInfo: { id, libraryID: id, path: packagePath(name, '~/Pictures'), recent: false } };
  Studio.save();
  closeSheet();
  render();
  notify('已建立恢复副本，可在“打开资料库包”中选择');
};
actions['migration-plan'] = () =>
  dialog(
    '迁入预检',
    factList([
      ['源目录', 'River Valley.lrcat'],
      ['可读样片', '3 张'],
      ['历史外观', '2 个嵌入预览'],
      ['离线原件', '1 张待绑定'],
    ]),
    btn('取消', 'close') + btn('迁入示例目录', 'migrate'),
  );
actions.migrate = () => {
  closeSheet();
  mutate('迁入示例目录', (c) => {
    c.migration = '3 条目录记录 · 1 个原片待绑定';
    if (!c.collections.some((x) => x.id === 'lr'))
      c.collections.push({ id: 'lr', name: 'Lightroom 迁入', ids: Studio.admitted().slice(0, 3) });
  });
};
actions['migration-missing'] = () =>
  dialog(
    '核对迁入缺项',
    select(
      '绑定已纳入原片',
      'bindOriginal',
      Studio.admitted().map((k) => [k, Studio.asset(k).name]),
    ),
    btn('取消', 'close') + btn('核验并绑定', 'migration-bind', '', { disabled: !Studio.admitted().length }),
  );
actions['migration-bind'] = () => {
  const id = value('bindOriginal');
  closeSheet();
  mutate('已核验迁入绑定', (c) => (c.migration = '核对完成 · 已绑定 ' + Studio.asset(id).name));
};
actions['move-plan'] = () => {
  const ids = activeIDs(),
    target = value('moveTarget', $('#workspace')).trim(),
    prefix = value('movePrefix', $('#workspace')).trim();
  if (!target) return;
  S.moveDraft = { ids, target, prefix };
  dialog(
    '核对受管文件计划',
    `<p>先在示例受管位置登记变更。</p>${ids.map((k, i) => rowCard(Studio.asset(k).name, target + ' / ' + (prefix ? prefix + '-' + (i + 1) + '.' + Studio.asset(k).name.split('.').pop() : Studio.asset(k).name))).join('')}`,
    btn('取消', 'close') + btn('执行示例计划', 'move-confirm'),
  );
};
actions['move-confirm'] = () => {
  const { ids, target, prefix } = S.moveDraft;
  closeSheet();
  mutate('完成受管文件计划', () =>
    ids.forEach((id, i) => {
      const a = Studio.asset(id);
      a.location = target;
      if (prefix) a.name = prefix + '-' + (i + 1) + '.' + a.name.split('.').pop();
    }),
  );
};
function discoveryPanel() {
  const c = Studio.catalog(),
    tab = S.discoverTab || '搜索',
    q = S.discoveryQuery || '';
  const tabBar = `<div class="button-group" role="group" aria-label="智能检索栏目" data-select-on-arrow>${['搜索', '地理围栏', '人物复核', '本机索引', '跨库检索'].map((t) => btn(t, 'discovery-tab', t, { pressed: tab === t })).join('')}</div>`;
  if (tab === '地理围栏')
    return (
      tabBar +
      `<h3>地理围栏</h3>${field('围栏名称', 'fenceName', c.fence || '河谷航拍区')}${select('形状', 'fenceShape', ['圆形', '多边形'], c.fenceShape)}${btn('保存示例围栏', 'fence')}${c.fence ? rowCard(c.fence, c.fenceShape + ' · 包含有示例定位的照片', btn('查看匹配', 'fence-query')) : ''}`
    );
  if (tab === '人物复核')
    return (
      tabBar +
      `<h3>待确认的人物簇</h3>${pic('m1', 'face-sample')}${field('人物名称', 'personName', c.person || '')}${btn('确认此人', 'person-save')}${c.person ? rowCard(c.person, '已人工确认', btn('查看作品', 'person-query')) : ''}`
    );
  if (tab === '本机索引')
    return (
      tabBar +
      rowCard(
        '离线检索索引',
        c.indexes ? '示例索引已就绪' : '示例索引待检查',
        btn('校验 / 重建', 'index-review'),
      )
    );
  if (tab === '跨库检索') {
    const libs = Object.values(Studio.data.libraries || {});
    return (
      tabBar +
      `<h3>检索范围</h3>${check(c.packageName || '本机资料库', 'lib-current', true)}${libs.map((l, i) => check(packageLabel(l), 'lib-' + i, true)).join('')}${field('文件名或场景', 'federatedQuery')}${btn('查询勾选的库', 'federated')}<div id="federated-result"></div>`
    );
  }
  const found = Studio.admitted().filter((id) => {
    const a = Studio.asset(id),
      p = Studio.photo(id);
    return (
      (!S.fenced || p.gps) &&
      (!S.personOnly || p.series === 'mirror') &&
      (!q || [a.name, p.scene, ...a.tags].join(' ').toLowerCase().includes(q.toLowerCase()))
    );
  });
  return (
    tabBar +
    `<h3>智能检索</h3>${field('文件名、场景或标签', 'discoveryQuery', q)}<div class="row">${btn('有定位', 'fence-query', '', { pressed: !!S.fenced })}${btn('人物作品', 'person-query', '', { pressed: !!S.personOnly })}</div><p class="muted">${found.length} 张匹配 · 示例场景索引</p><div class="discovery-grid">${found.map((id) => `<button data-act="discovery-inspect" data-val="${id}">${pic(id)}<b>${h(Studio.asset(id).name)}</b></button>`).join('')}</div>`
  );
}
actions['discovery-tab'] = (v) => {
  S.discoverTab = v;
  render();
};
inputs.discoveryQuery = (el) => {
  S.discoveryQuery = el.value;
  render();
  $('[name=discoveryQuery]').focus();
};
actions.fence = () => {
  const n = value('fenceName', $('#workspace')).trim(),
    s = value('fenceShape', $('#workspace'));
  if (n)
    mutate('已保存围栏', (c) => {
      c.fence = n;
      c.fenceShape = s;
    });
};
actions['person-save'] = () => {
  const n = value('personName', $('#workspace')).trim();
  if (n) mutate('已确认人物', (c) => (c.person = n));
};
actions['fence-query'] = () => {
  S.fenced = S.discoverTab === '地理围栏' || !S.fenced;
  S.discoverTab = '搜索';
  render();
};
actions['person-query'] = () => {
  S.personOnly = S.discoverTab === '人物复核' || !S.personOnly;
  S.discoverTab = '搜索';
  render();
};
actions.federated = () => {
  const d = Studio.data,
    root = $('#workspace'),
    q = value('federatedQuery', root).toLowerCase(),
    libs = [
      ...Object.values(d.libraries || {})
        .filter((_, i) => checked('lib-' + i, root))
        .map((snapshot) => [packageLabel(snapshot), snapshot.catalog]),
    ];
  if (checked('lib-current', root)) libs.unshift([d.catalog.packageName || '本机资料库', d.catalog]);
  $('#federated-result').innerHTML =
    libs
      .map(([name, c]) => {
        const ids = [...new Set(c.projects.flatMap((p) => p.ids))].filter((id) =>
          [c.records[id].name, RMPhotos.photos[c.records[id].source || id]?.scene]
            .join(' ')
            .toLowerCase()
            .includes(q),
        );
        return rowCard(name, ids.length + ' 个匹配 · ' + ids.map((id) => c.records[id].name).join('、'));
      })
      .join('') || '<p>请选择资料库。</p>';
};
actions['discovery-inspect'] = (id) => {
  S.inspectIDs = [id];
  go('tools/inspection');
};
function inspectionPanel() {
  const ids = (S.inspectIDs || activeIDs()).filter((id) => Studio.asset(id));
  if (!ids.length) return empty('尚未选择作品', '从资料库选择照片后打开检查器。');
  return `<div class="inspection-grid">${ids.map((id) => `<figure>${pic(id)}<figcaption>${h(Studio.asset(id).name)}</figcaption></figure>`).join('')}</div>
    <h3>检查与证据</h3>${factList([['像素来源', '示例机内 JPEG'], ['对焦复核', S.inspectionEvidence || '尚未比较原图局部'], ['状态', Studio.asset(ids[0]).conclusion || '待人工复核'], ...Object.entries(Studio.asset(ids[0]).metadata || {})])}<div class="row wrap">${btn('比较局部', 'inspect-evidence')}${btn('写入人工结论…', 'inspect-verdict')}${btn('编辑元数据…', 'inspect-meta')}</div>`;
}
actions['inspect-evidence'] = () => {
  S.inspectionEvidence = '已展示示例局部，等待人工判读';
  render();
  dialog(
    '局部复核',
    `<div class="detail-crops">${(S.inspectIDs || activeIDs()).map((id) => `<figure>${pic(id)}<figcaption>${h(Studio.asset(id).name)}</figcaption></figure>`).join('')}</div>`,
    btn('完成', 'close'),
  );
};
actions['inspect-verdict'] = () =>
  dialog(
    '人工结论',
    select('复核结论', 'verdict', ['可用', '需再检查', '失焦', '待人工复核']),
    btn('取消', 'close') + btn('保存', 'write-verdict'),
  );
actions['inspect-meta'] = () =>
  dialog(
    '批量元数据',
    select('字段', 'metaKey', ['版权', '题注', '作者']) + field('值', 'metaValue'),
    btn('取消', 'close') + btn('保存', 'write-meta'),
  );
actions['write-verdict'] = () => {
  const v = value('verdict');
  closeSheet();
  mutate('已保存人工结论', () =>
    (S.inspectIDs || activeIDs()).forEach((id) => (Studio.asset(id).conclusion = v)),
  );
};
actions['write-meta'] = () => {
  const n = value('metaKey'),
    v = value('metaValue');
  closeSheet();
  mutate('已更新' + n, () =>
    (S.inspectIDs || activeIDs()).forEach((id) => {
      const a = Studio.asset(id);
      (a.metadata ??= {})[n] = v;
    }),
  );
};
