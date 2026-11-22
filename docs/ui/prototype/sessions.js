'use strict';

actions.import = () => {
  const projects = Studio.catalog().projects;
  dialog(
    '接入素材',
    `<p>选择示例来源，先在导入会话中完成初筛。</p>${select(
      '来源',
      'importSource',
      [
        ['river', '航拍卡 / DCIM'],
        ['mirror', '镜湖卡 / DCIM'],
      ],
      'river',
    )}
    ${select('接入方式', 'importMode', ['原地引用', '复制接入'], '原地引用')}${select('目标项目', 'importProject', [...projects.map((p) => [p.id, p.name]), ['new', '新建项目…']], projects[0].id)}
    <div id="new-project" hidden>${field('项目名称', 'projectName', '新拍摄项目')}</div>`,
    btn('取消', 'close') + btn('开始接入', 'begin-import', '', { cls: 'primary' }),
  );
};
changes.importProject = (el) => ($('#new-project').hidden = el.value !== 'new');
actions['begin-import'] = () => {
  const river = value('importSource') === 'river',
    ids = river ? ['n1', 'n2', 'n3'] : ['i1', 'i2', 'i3'];
  const c = Studio.catalog(),
    existing = c.sessions.find((s) => s.ids.includes(ids[0]));
  if (existing) {
    closeSheet();
    go('library/' + (existing.state === 'sealed' ? 'history/' : 'triage/') + existing.id);
    notify('该来源已有导入记录');
    return;
  }
  const id = Studio.uid(),
    mode = value('importMode'),
    name = river ? '河谷航拍卡' : '镜湖卡';
  let project = value('importProject');
  const projectName = value('projectName').trim();
  if (project === 'new' && !projectName) {
    sheet.querySelector('[name=projectName]').focus();
    return;
  }
  Studio.change('接入 ' + name, (c) => {
    if (project === 'new') {
      project = Studio.uid();
      c.projects.push({ id: project, name: projectName, ids: [] });
    }
    c.sessions.unshift({ id, project, name, ids, mode, state: 'open', scan: false, risks: false });
  });
  closeSheet();
  go('library/triage/' + id);
};
actions['triage-menu'] = () => {
  const s = Studio.scopeInfo(S.scope).session;
  dialog(
    '批次操作',
    `<dl>${fact('来源', s.name)}${fact('方式', s.mode)}${fact('接入状态', s.state === 'paused' ? '已中断' : '登记完成')}${fact('自动分组', s.scan ? '已发现 1 个待复核组' : '尚未复扫')}${fact('预览风险', s.risks ? '已检查，1 张待人工复核' : '尚未分析')}</dl>
    <div class="menu-list">${btn(s.state === 'paused' ? '继续接入' : '模拟接入中断', 'session-action', 'pause')}${btn('重新扫描来源目录', 'session-action', 'source', { disabled: s.state === 'paused' })}${btn('重新扫描分组', 'session-action', 'groups', { disabled: s.state === 'paused' })}${btn('检查预览风险', 'session-action', 'risk', { disabled: s.state === 'paused' })}${s.scan ? btn('复核建议组…', 'session-group') : ''}${btn('操作记录与撤销…', 'library-log')}</div>`,
    btn('完成', 'close'),
  );
};
actions['session-action'] = (op) => {
  const id = Studio.scopeInfo(S.scope).session.id;
  const label = {
    pause: '更新接入状态',
    source: '核验来源目录',
    groups: '扫描自动分组',
    risk: '检查预览风险',
  }[op];
  Studio.change(label, () => {
    const s = Studio.session(id);
    if (op === 'pause') s.state = s.state === 'paused' ? 'open' : 'paused';
    if (op === 'groups') s.scan = true;
    if (op === 'risk') s.risks = true;
    if (op === 'source') s.verified = true;
  });
  actions['triage-menu']();
  render();
  if (op === 'source') notify('已核验 ' + Studio.session(id).ids.length + ' 个文件，无新增');
};
actions['session-group'] = () => {
  const s = Studio.scopeInfo(S.scope).session;
  dialog(
    '复核自动分组',
    `<p>${s.ids.length} 次拍摄 · 时间连续</p>${field('组名', 'groupName', s.groupName || s.name + ' 连拍')}${select('用途', 'groupKind', ['连拍', '间隔拍摄', '延时', '未分类'], s.groupKind || '连拍')}`,
    btn('返回', 'triage-menu') + btn('确认并保护结构', 'protect-session-group'),
  );
};
actions['protect-session-group'] = () => {
  const s = Studio.scopeInfo(S.scope).session,
    name = value('groupName').trim(),
    kind = value('groupKind');
  if (!name) return;
  Studio.change('确认自动组', () => Object.assign(s, { groupName: name, groupKind: kind }));
  closeSheet();
  render();
};
actions.seal = () => {
  const s = Studio.scopeInfo(S.scope).session;
  if (s.state === 'paused') {
    dialog('请先继续接入', '<p>批次尚未完整登记。恢复后再核对整批清单。</p>', btn('批次操作', 'triage-menu'));
    return;
  }
  const count = (state) => s.ids.filter((id) => Studio.asset(id).triage === state).length;
  dialog(
    '完成整批初筛',
    `<p>${h(s.name)} → ${h(Studio.project(s.project).name)}</p><dl>${fact('本批拍摄', s.ids.length)}${fact('将纳入项目', s.ids.length - count('reject'))}${fact('排除', count('reject'))}${fact('仅用于序列', count('sequence'))}${fact('尚待人工复核', count('pending'))}${fact('预览风险', s.risks ? '已分析，有待复核项' : '未分析')}</dl>
    ${check('已核对整批纳入与排除结果', 'sealAck')}`,
    btn('返回复核', 'close') + btn('封存并纳入项目', 'confirm-seal', '', { cls: 'primary', disabled: true }),
  );
};
changes.sealAck = (el) => (sheet.querySelector('[data-act=confirm-seal]').disabled = !el.checked);
actions['confirm-seal'] = () => {
  if (!checked('sealAck')) return;
  const s = Studio.scopeInfo(S.scope).session;
  Studio.change('封存 ' + s.name, (c) => {
    s.excluded = s.ids.filter((id) => Studio.asset(id).triage === 'reject');
    s.included = s.ids.filter((id) => !s.excluded.includes(id));
    s.state = 'sealed';
    const project = Studio.project(s.project);
    project.ids = [...new Set([...project.ids, ...s.included])];
    if (s.scan && s.included.length > 1)
      c.groups.push({
        id: Studio.uid(),
        name: s.groupName || s.name + ' 连拍',
        kind: s.groupKind || '连拍',
        ids: [...s.included],
        protected: !!s.groupName,
      });
  });
  closeSheet();
  go('library/project/' + s.project);
  notify('已封存 · 纳入 ' + s.included.length + ' 次拍摄');
};
actions['history-detail'] = (id) => {
  const s = Studio.session(id),
    excluded = s.excluded || [];
  dialog(
    '封存清单',
    `<p>${h(s.name)} · ${h(Studio.project(s.project).name)}</p><dl>${fact('完成时纳入', (s.included ?? s.ids).length)}${fact('完成时排除', excluded.length)}${fact('接入方式', s.mode)}</dl>
    ${excluded.map((id) => `<div class="list-row">${h(Studio.asset(id).name)}${btn(Studio.admitted().includes(id) ? '已恢复' : '恢复纳入', 'restore-file', s.id + '/' + id, { disabled: Studio.admitted().includes(id) })}</div>`).join('')}`,
    btn('完成', 'close'),
  );
};
actions['restore-file'] = (v) => {
  const [sid, id] = v.split('/'),
    s = Studio.session(sid);
  if (!Studio.asset(id).online) {
    actions.relink(id);
    return;
  }
  Studio.change('恢复纳入 ' + Studio.asset(id).name, () => {
    const p = Studio.project(s.project);
    if (!p.ids.includes(id)) p.ids.push(id);
  });
  actions['history-detail'](sid);
  render();
};
actions['new-group'] = () => {
  const ids = activeIDs();
  dialog(
    '创建拍摄组',
    field('名称', 'groupName', '新拍摄组') + `<p>${ids.length} 次所选拍摄</p>`,
    btn('取消', 'close') + btn('创建', 'create-group', '', { disabled: !ids.length }),
  );
};
actions['create-group'] = () => {
  const id = Studio.uid(),
    name = value('groupName').trim(),
    ids = activeIDs();
  if (!name || !ids.length) return;
  Studio.change('新建拍摄组', (c) => c.groups.push({ id, name, kind: '未分类', ids, protected: true }));
  closeSheet();
  go('library/group/' + id);
};
actions['manage-group'] = (id) => {
  const g = Studio.group(id);
  dialog(
    '组属性与成员',
    field('组名', 'groupName', g.name) +
      select('用途', 'groupKind', ['未分类', '连拍', '间隔拍摄', '延时', 'HDR', '全景', '星轨'], g.kind) +
      check('保护人工结构', 'protected', g.protected) +
      `<div class="ins-block"><h4>参与序列 · 手工顺序</h4>${g.ids.map((k, i) => `<div class="list-row">${check(Studio.asset(k).name, 'member-' + k, !(g.excluded || []).includes(k))}${btn('前移', 'group-up', g.id + '/' + k, { disabled: i === 0, cls: 'link' })}</div>`).join('')}</div>`,
    btn('取消', 'close') +
      btn('结构操作…', 'group-structure', id) +
      btn('保存属性', 'save-group', id, { cls: 'primary' }),
  );
};
function readGroup(g) {
  return {
    name: value('groupName').trim() || g.name,
    kind: value('groupKind'),
    protected: checked('protected'),
    excluded: g.ids.filter((k) => !checked('member-' + k)),
  };
}
actions['group-up'] = (v) => {
  const [id, k] = v.split('/'),
    g = Studio.group(id),
    draft = readGroup(g),
    i = g.ids.indexOf(k);
  if (i <= 0) return;
  Studio.change('调整组顺序', () => {
    Object.assign(g, draft);
    [g.ids[i - 1], g.ids[i]] = [g.ids[i], g.ids[i - 1]];
  });
  actions['manage-group'](id);
  render();
};
actions['save-group'] = (id) => {
  const g = Studio.group(id),
    draft = readGroup(g);
  closeSheet();
  mutate('保存组属性', () => Object.assign(g, draft));
};
actions['group-structure'] = (id) => {
  const g = Studio.group(id),
    others = Studio.catalog().groups.filter((x) => x !== g),
    available = Studio.admitted().filter((k) => !g.ids.includes(k));
  dialog(
    '调整拍摄组结构',
    select(
      '成员',
      'operateMember',
      g.ids.map((k) => [k, Studio.asset(k).name]),
    ) +
      select(
        '可加入的照片',
        'newMember',
        available.map((k) => [k, Studio.asset(k).name]),
      ) +
      select(
        '合并目标',
        'mergeGroup',
        others.map((k) => [k.id, k.name]),
      ) +
      `<div class="menu-list">${btn('加入照片', 'structure', 'add/' + id, { disabled: !available.length })}${btn('移出成员', 'structure', 'remove/' + id, { disabled: g.ids.length < 2 })}${btn('从此成员拆分', 'structure', 'split/' + id, { disabled: g.ids.length < 2 })}${btn('合并到目标组', 'structure', 'merge/' + id, { disabled: !others.length })}</div>`,
    btn('返回属性', 'manage-group', id),
  );
};
actions.structure = (v) => {
  const [op, id] = v.split('/'),
    g = Studio.group(id),
    member = value('operateMember'),
    target = Studio.group(value('mergeGroup')),
    newMember = value('newMember');
  if (op === 'split' && g.ids.indexOf(member) < 1) {
    notify('请从第二个或之后的成员拆分');
    return;
  }
  Studio.change('调整组结构', (c) => {
    g.protected = true;
    if (op === 'add' && !g.ids.includes(newMember)) g.ids.push(newMember);
    if (op === 'remove') g.ids = g.ids.filter((k) => k !== member);
    if (op === 'split') {
      const ids = g.ids.splice(g.ids.indexOf(member));
      c.groups.push({
        ...g,
        id: Studio.uid(),
        name: g.name + ' · 2',
        ids,
        excluded: (g.excluded || []).filter((k) => ids.includes(k)),
      });
    }
    if (op === 'merge') {
      target.ids = [...new Set([...target.ids, ...g.ids])];
      target.protected = true;
      c.groups = c.groups.filter((x) => x !== g);
    }
  });
  closeSheet();
  go('library/group/' + (op === 'merge' ? target.id : g.id));
  notify('组结构已更新');
};
const recipes = {
  延时视频: ['帧率', ['24 fps', '25 fps', '30 fps']],
  星轨: ['前景', ['参考帧前景', '整幅叠加']],
  HDR: ['运动处理', ['去鬼影', '保留运动']],
  全景: ['投影裁切', ['有效矩形', '保留边界']],
};
let playback;
function processMembers(g) {
  return g.ids.filter((k) => !(g.excluded || []).includes(k));
}
actions.process = (id) => {
  S.processID = id;
  S.processType = { HDR: 'HDR', 全景: '全景', 星轨: '星轨' }[Studio.group(id).kind] || '延时视频';
  S.processAdvanced = false;
  S.processFrame = 0;
  S.processStale = false;
  S.processOptions = {};
  go('tools/process');
};
function processPanel() {
  const g = Studio.group(S.processID) ?? Studio.catalog().groups[0];
  if (!g) return empty('暂无拍摄组', '先从资料库中的选片创建拍摄组。');
  const ids = processMembers(g),
    type = S.processType || '延时视频',
    [label, options] = recipes[type],
    focus = ids[Math.min(S.processFrame || 0, ids.length - 1)];
  const cfg = (S.processOptions ??= {});
  const advanced =
    type === '延时视频'
      ? select('光照', 'deflicker', ['自然渐变', '去闪烁'], cfg.deflicker) +
        select('对齐', 'stabilize', ['关闭', '平移稳定', '主体锚定'], cfg.stabilize) +
        field('曝光关键帧 EV', 'keyEV', cfg.keyEV || '0', 'number') +
        select('输出', 'videoCodec', ['1080p · H.264', '4K · HEVC'], cfg.videoCodec)
      : '';
  return `<div class="tool-columns"><div>${focus ? `<div class="frame-preview">${pic(focus)}</div>` : empty('没有参与帧', '在组属性中勾选参与序列的照片。')}
    <div class="row wrap">${btn('播放预览', 'play-group', '', { icon: 'play', disabled: !ids.length || S.processStale })}<span id="frame-number">${focus ? ids.indexOf(focus) + 1 : 0} / ${ids.length}</span>${btn('重新生成预览', 'refresh-preview', '', { disabled: !ids.length })}</div>
    <h4>输入顺序</h4>${ids.map((k, i) => `<div class="list-row"><span>${i + 1} · ${h(Studio.asset(k).name)}</span><small>${Studio.asset(k).online ? '就绪' : '待接回'}</small></div>`).join('')}</div>
    <div>${select(
      '拍摄组',
      'processGroup',
      Studio.catalog().groups.map((g) => [g.id, g.name]),
      g.id,
    )}${select('制作方式', 'processType', Object.keys(recipes), type)}${select(label, 'groupOption', options, cfg.groupOption || options.at(-1))}
    ${type === '延时视频' ? select('播放速度', 'videoSpeed', ['1×', '2×', '4×'], cfg.videoSpeed) + select('画幅', 'videoAspect', ['原始', '16:9', '9:16'], cfg.videoAspect) + btn('高级设置', 'process-advanced', '', { pressed: !!S.processAdvanced }) + (S.processAdvanced ? advanced : '') : ''}
    <div class="ins-block"><p>${S.processStale ? '设置已更改，请更新预览。' : h(g.name) + ' · ' + ids.length + ' 次参与拍摄'}</p>${btn('冻结输入并制作', 'group-run', g.id, { cls: 'primary', disabled: !ids.length || S.processStale })}</div></div></div>`;
}
changes.processGroup = (el) => {
  actions.process(el.value);
  render();
};
changes.processType = (el) => {
  S.processType = el.value;
  S.processOptions = {};
  S.processStale = true;
  render();
};
for (const k of ['groupOption', 'deflicker', 'stabilize', 'keyEV', 'videoCodec', 'videoSpeed', 'videoAspect'])
  changes[k] = (el) => {
    S.processOptions[k] = el.value;
    S.processStale = true;
    render();
  };
actions['process-advanced'] = () => {
  S.processAdvanced = !S.processAdvanced;
  render();
};
actions['refresh-preview'] = () => {
  S.processStale = false;
  S.processFrame = 0;
  render();
  notify('已按当前设置生成示例预览');
};
actions['play-group'] = () => {
  const g = Studio.group(S.processID) ?? Studio.catalog().groups[0],
    ids = processMembers(g);
  clearInterval(playback);
  let step = 0;
  playback = setInterval(() => {
    const img = $('.frame-preview img');
    if (!img || step >= ids.length) {
      clearInterval(playback);
      return;
    }
    const id = ids[step];
    img.src = RMPhotos.url(Studio.photo(id));
    img.alt = Studio.photo(id).scene;
    $('#frame-number').textContent = ++step + ' / ' + ids.length;
  }, 350);
};
actions['group-run'] = (id) => {
  const g = Studio.group(id),
    ids = processMembers(g),
    missing = ids.find((k) => !Studio.asset(k).online);
  if (missing) {
    actions.relink(missing);
    return;
  }
  startJob(S.processType || '延时视频', ids[0], {
    group: g.name,
    ids: [...ids],
    settings: { ...S.processOptions },
  });
};
