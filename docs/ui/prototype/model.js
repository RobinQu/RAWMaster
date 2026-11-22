'use strict';

const Studio = (() => {
  const key = 'rawmaster.ui.workbench.v1';
  const photo = (id) => RMPhotos.photos[data?.catalog?.records[id]?.source || id];
  const initial = Object.keys(RMPhotos.photos).slice(0, 12);
  const freshRecipe = () => ({
    ev: 0,
    contrast: 0,
    sat: 0,
    warmth: 0,
    mono: false,
    crop: '原始',
    angle: 0,
    masks: [],
    repairs: [],
    preset: '',
  });
  function record(id, index) {
    const f = photo(id);
    return {
      id,
      name: f.name,
      pair: ['r1', 'm1'].includes(id),
      online: id !== 'w1',
      reviewed: index < 6,
      decision: [0, 2, 4].includes(index) ? 'keep' : 'none',
      stars: [4, 0, 5, 3, 4, 0, 0, 2, 0, 0, 0, 0][index] ?? 0,
      tags: index === 0 ? ['风光', '河谷'] : [],
      label: index === 0 ? '青色' : '无',
      triage: 'pending',
      sequence: true,
    };
  }
  function seed() {
    return {
      catalog: {
        records: Object.fromEntries(Object.keys(RMPhotos.photos).map((id, i) => [id, record(id, i)])),
        projects: [{ id: 'river', name: '河谷拍摄', ids: initial.slice() }],
        groups: [
          { id: 'dusk', name: '暮色延时', kind: '延时', ids: ['d1', 'd2', 'd3'], protected: false },
          { id: 'birds', name: '岸边连拍', kind: '连拍', ids: ['b1', 'b2'], protected: false },
        ],
        sessions: [
          {
            id: 'card-b',
            name: '镜湖 · 第二张卡',
            ids: ['i1', 'i2', 'i3'],
            project: 'river',
            mode: '原地引用',
            state: 'open',
            scan: false,
            risks: false,
          },
          {
            id: 'card-a',
            name: '河谷 · 第一张卡',
            ids: initial.slice(),
            project: 'river',
            mode: '复制接入',
            state: 'sealed',
            excluded: [],
          },
        ],
        collections: [{ id: 'portfolio', name: '秋日作品集', ids: ['r1', 'b1', 'm1', 'p1'] }],
        folders: ['河谷 / DCIM'],
        backup: '',
        migration: '',
        indexes: false,
      },
      history: [],
      edits: {},
      jobs: [],
      prefs: { theme: 'system', ground: '深灰', runtime: '待准备', cloud: '未配置' },
      presets: [
        { name: '河谷暖调', group: 'Classic Filters', values: { warmth: 48, contrast: 12, sat: 14 } },
        { name: '克制黑白', group: 'Classic Filters', values: { mono: true, contrast: 20 } },
        { name: '清透日光', group: 'Classic Filters', values: { ev: 0.25, warmth: 8, sat: -10 } },
      ],
      favorites: [],
      browse: {},
      work: 'r1',
    };
  }
  let data;
  try {
    data = JSON.parse(localStorage.getItem(key));
  } catch {}
  if (!data?.catalog?.projects?.length || !data.prefs || !data.browse) data = seed();
  function save() {
    try {
      localStorage.setItem(key, JSON.stringify(data));
    } catch {}
  }
  const catalog = () => data.catalog;
  const asset = (id) => catalog().records[id];
  const project = (id) => catalog().projects.find((p) => p.id === id);
  const group = (id) => catalog().groups.find((g) => g.id === id);
  const session = (id) => catalog().sessions.find((g) => g.id === id);
  const admitted = () => [...new Set(catalog().projects.flatMap((p) => p.ids))];
  function change(label, fn) {
    const before = JSON.stringify(catalog());
    fn(catalog());
    if (before === JSON.stringify(catalog())) return;
    data.history.unshift({ label, before });
    data.history.length = Math.min(24, data.history.length);
    save();
  }
  function undo() {
    const entry = data.history.shift();
    if (entry) {
      data.catalog = JSON.parse(entry.before);
      save();
    }
    return entry?.label;
  }
  function edit(id) {
    return (data.edits[id] ??= {
      recipe: freshRecipe(),
      past: [],
      future: [],
      versions: [],
      adopted: 'original',
      snapshots: [],
      saved: JSON.stringify(freshRecipe()),
    });
  }
  function setRecipe(id, label, next) {
    const e = edit(id);
    if (JSON.stringify(e.recipe) === JSON.stringify(next)) return;
    e.past.unshift({ label, value: structuredClone(e.recipe) });
    e.past.length = Math.min(40, e.past.length);
    e.future = [];
    e.recipe = structuredClone(next);
    save();
  }
  function patchRecipe(id, label, fields) {
    setRecipe(id, label, { ...edit(id).recipe, ...fields });
  }
  function stepEdit(id, redo = false) {
    const e = edit(id),
      from = redo ? e.future : e.past,
      to = redo ? e.past : e.future;
    const step = from.shift();
    if (step) {
      const reverse = { label: step.label, value: e.recipe };
      if (Object.hasOwn(step, 'adopted')) {
        reverse.adopted = e.adopted;
        e.adopted = step.adopted;
      }
      to.unshift(reverse);
      e.recipe = step.value;
      save();
    }
  }
  const uid = () =>
    globalThis.crypto?.randomUUID?.() ?? String(Date.now()) + Math.random().toString(36).slice(2);
  function adoptPromptVersion(id, version) {
    const e = edit(id);
    if (version === e.adopted || !e.versions.some((v) => v.id === version && v.quickPrompt && !v.discarded)) return false;
    e.past.unshift({ label: '采用快速 Prompt', value: structuredClone(e.recipe), adopted: e.adopted });
    e.past.length = Math.min(40, e.past.length);
    e.future = [];
    e.adopted = version;
    save();
    return true;
  }
  function candidate(id, kind, recipe = edit(id).recipe, parent = edit(id).base ?? edit(id).adopted) {
    const e = edit(id),
      src = photo(id);
    const version = {
      id: uid(),
      name: `${kind} ${e.versions.length + 1}`,
      recipe: structuredClone(recipe),
      parent,
    };
    const ratio = { '1:1': 1, '4:5': 0.8, '3:2': 1.5, '16:9': 16 / 9 }[recipe.crop];
    version.w = ratio ? Math.min(src.w, Math.round(src.h * ratio)) : src.w;
    version.h = ratio ? Math.min(src.h, Math.round(src.w / ratio)) : src.h;
    e.versions.push(version);
    if (kind === '初修') {
      e.saved = JSON.stringify(recipe);
      e.lastSaved = version.id;
      e.base = version.id;
    }
    save();
    return version;
  }
  const dirty = (id) => JSON.stringify(edit(id).recipe) !== edit(id).saved;
  function scopeInfo(scope) {
    const c = catalog(),
      [type, id] = scope.split('/');
    if (type === 'project') {
      const p = project(id) ?? c.projects[0];
      return { title: p.name, section: '项目', ids: p.ids, project: p.id };
    }
    if (type === 'group') {
      const g = group(id);
      if (g) return { title: g.name, section: '拍摄组', ids: g.ids, group: g };
    }
    if (type === 'collection') {
      const col = c.collections.find((x) => x.id === id);
      if (col)
        return {
          title: col.name,
          section: '集合',
          ids: col.smart ? admitted().filter((k) => asset(k).stars >= col.rating) : col.ids,
        };
    }
    if (type === 'triage' || type === 'history') {
      const s =
        session(id) ??
        c.sessions.find((x) => (type === 'triage' ? x.state !== 'sealed' : x.state === 'sealed'));
      if (s)
        return {
          title: s.name,
          section: s.state === 'sealed' ? '导入历史' : '导入与初筛',
          ids: s.ids,
          session: s,
        };
    }
    if (type === 'picks')
      return {
        title: '精选照片',
        section: '资料库',
        ids: admitted().filter((k) => asset(k).decision === 'keep'),
      };
    return { title: '全部素材', section: '资料库', ids: admitted() };
  }
  function browser(scope) {
    return (data.browse[scope] ??= {
      query: '',
      minStars: 0,
      availability: 'all',
      decision: 'all',
      camera: 'all',
      date: '',
      tag: '',
      review: 'all',
      sort: '拍摄顺序',
      view: 'grid',
      selected: [],
      focus: null,
      initialized: false,
    });
  }
  function visible(scope) {
    const b = browser(scope);
    const ids = scopeInfo(scope).ids.filter((id) => {
      const a = asset(id),
        p = photo(id);
      return (
        (!b.query ||
          [a.name, p.scene, ...a.tags].join(' ').toLowerCase().includes(b.query.trim().toLowerCase())) &&
        a.stars >= b.minStars &&
        (b.availability === 'all' || a.online === (b.availability === 'online')) &&
        (b.camera === 'all' || p.exif.camera === b.camera) &&
        (!b.date || p.date === b.date) &&
        (!b.tag || a.tags.includes(b.tag)) &&
        (b.review === 'all' || a.reviewed === (b.review === 'reviewed')) &&
        (b.decision === 'all' || a.decision === b.decision)
      );
    });
    if (b.sort === '星级优先') ids.sort((a, b) => asset(b).stars - asset(a).stars);
    if (b.sort === '文件名') ids.sort((a, b) => asset(a).name.localeCompare(asset(b).name));
    return ids;
  }
  function reconcile(scope) {
    const b = browser(scope),
      ids = visible(scope);
    b.selected = b.selected.filter((id) => ids.includes(id));
    if (!ids.includes(b.focus)) b.focus = b.selected[0] ?? ids[0] ?? null;
    if (!b.initialized && b.focus) {
      b.selected = [b.focus];
      b.initialized = true;
    }
    return b;
  }
  function exportItem(id, preferred) {
    const e = edit(id),
      p = photo(id),
      a = asset(id);
    const original = { id: 'original', label: '原始版本', w: p.w, h: p.h };
    const versions = [
      original,
      ...e.versions
        .filter((v) => !v.discarded)
        .map((v) => ({
          id: v.id,
          label: v.name,
          w: v.w,
          h: v.h,
          archive: true,
          look: RMPhotos.displayLook(v.recipe),
        })),
    ];
    const first = versions.find((v) => v.id === (preferred ?? e.adopted)) ?? original;
    return {
      id,
      source: a.source || id,
      name: a.name,
      online: a.online,
      versions: [first, ...versions.filter((v) => v !== first)],
    };
  }
  function reset() {
    data = seed();
    save();
  }
  return {
    get data() {
      return data;
    },
    emptyRecords: () => Object.fromEntries(Object.keys(RMPhotos.photos).map(id => [id, record(id, 100)])),
    photo,
    asset,
    project,
    group,
    session,
    admitted,
    catalog,
    save,
    change,
    undo,
    edit,
    patchRecipe,
    setRecipe,
    stepEdit,
    adoptPromptVersion,
    candidate,
    dirty,
    uid,
    freshRecipe,
    scopeInfo,
    browser,
    visible,
    reconcile,
    exportItem,
    reset,
  };
})();
