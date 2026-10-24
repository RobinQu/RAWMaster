'use strict';
const ReviewModel = (() => {
  const clone = value => JSON.parse(JSON.stringify(value));
  const assert = (condition, message) => { if (!condition) throw new Error(message); };
  function parseStrictJSON(text) {
    assert(text.length <= 10 * 1024 * 1024, '修订文件过大'); let i = 0;
    const ws = () => { while (/\s/.test(text[i] || '') && i < text.length) i++; };
    function string() { const start = i++; while (i < text.length) { if (text[i] === '\\') { i += 2; continue; } if (text[i++] === '"') return JSON.parse(text.slice(start, i)); } throw new Error('无效 JSON 字符串'); }
    function value(depth = 0) {
      assert(depth < 30, 'JSON 层级过深'); ws(); const c = text[i];
      if (c === '"') return string();
      if (c === '{') { i++; const result = Object.create(null); ws(); if (text[i] === '}') { i++; return result; } while (true) { ws(); assert(text[i] === '"', '无效 JSON 字段'); const key = string(); assert(!Object.hasOwn(result, key) && key !== '__proto__', 'JSON 有重复或无效字段'); ws(); assert(text[i++] === ':', '无效 JSON 分隔'); result[key] = value(depth + 1); ws(); const next = text[i++]; if (next === '}') return result; assert(next === ',', '无效 JSON 对象'); } }
      if (c === '[') { i++; const result = []; ws(); if (text[i] === ']') { i++; return result; } while (true) { result.push(value(depth + 1)); ws(); const next = text[i++]; if (next === ']') return result; assert(next === ',', '无效 JSON 数组'); } }
      const match = text.slice(i).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/); assert(match, '无效 JSON 值'); i += match[0].length; const result = JSON.parse(match[0]); assert(typeof result !== 'number' || Number.isFinite(result), '数字超出范围'); return result;
    }
    const result = value(); ws(); assert(i === text.length, 'JSON 有多余内容'); return result;
  }
  function empty(catalog) { return {kind: 'RAWMaster-sequence-label-revision', schemaVersion: 1, ...clone(catalog.binding), caseEdits: [], reviewer: '人工复核', note: ''}; }
  function caseEdit(draft, id) { let edit = draft.caseEdits.find(c => c.caseID === id); if (!edit) { edit = {caseID: id, edgeEdits: [], groupEdits: [], removedGroupIDs: []}; draft.caseEdits.push(edit); } return edit; }
  function groups(c, draft) {
    const edit = draft.caseEdits.find(e => e.caseID === c.id), map = new Map(c.truth.groups.map(g => [g.id, {id: g.id, firstOrdinal: Math.min(...g.assetIDs.map(id => c.assets.find(a => a.assetID === id).ordinal)), lastOrdinal: Math.max(...g.assetIDs.map(id => c.assets.find(a => a.assetID === id).ordinal)), kind: g.kind}]));
    if (edit) { edit.removedGroupIDs.forEach(id => map.delete(id)); edit.groupEdits.forEach(g => map.set(g.id, g)); } return [...map.values()].sort((a, b) => a.firstOrdinal - b.firstOrdinal);
  }
  function truthRelation(c, first) {
    const a = c.assets[first]?.assetID, b = c.assets[first + 1]?.assetID;
    if (c.truth.groups.some(g => g.assetIDs.includes(a) && g.assetIDs.includes(b))) return 'same';
    if (c.truth.negativePairs.some(p => (p.from === a && p.to === b) || (p.from === b && p.to === a))) return 'separate';
    return 'unknown';
  }
  function conflicts(catalog, draft) {
    const found = [];
    for (const c of catalog.cases) {
      const gs = groups(c, draft), edit = draft.caseEdits.find(e => e.caseID === c.id);
      for (let i = 1; i < gs.length; i++) if (gs[i].firstOrdinal <= gs[i - 1].lastOrdinal) found.push(c.id + '：组范围重叠');
      for (const edge of edit?.edgeEdits || []) {
        const first = c.assets.find(a => a.assetID === edge.leftAssetID).ordinal;
        if (edge.relation !== 'same' && gs.some(g => first >= g.firstOrdinal && first + 1 <= g.lastOrdinal)) found.push(c.id + ' #' + first + '：边界关系与草稿组范围冲突，请调整范围或恢复关系');
        const leftGroup = gs.find(g => first >= g.firstOrdinal && first <= g.lastOrdinal), rightGroup = gs.find(g => first + 1 >= g.firstOrdinal && first + 1 <= g.lastOrdinal);
        if (edge.relation === 'same' && leftGroup && rightGroup && leftGroup.id !== rightGroup.id) found.push(c.id + ' #' + first + '：同组关系连接了两个不同的草稿组，请合并范围或恢复关系');
      }
    } return found;
  }
  function validate(draft, catalog, allowConflicts = false) {
    const keys = (o, allowed) => assert(o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).every(k => allowed.includes(k)), '修订含未知字段');
    keys(draft, ['kind', 'schemaVersion', 'indexSHA256', 'truthSHA256ByCase', 'assetBindings', 'caseEdits', 'reviewer', 'note']);
    assert(draft.kind === 'RAWMaster-sequence-label-revision' && draft.schemaVersion === 1, '修订格式不支持');
    assert(draft.indexSHA256 === catalog.binding.indexSHA256, '数据集版本不一致');
    assert(Object.keys(draft.truthSHA256ByCase).length === catalog.cases.length && catalog.cases.every(c => draft.truthSHA256ByCase[c.id] === c.truthSHA256), '旧标签版本不一致');
    assert(Array.isArray(draft.assetBindings) && draft.assetBindings.length === catalog.binding.assetBindings.length, '文件绑定数量不一致');
    draft.assetBindings.forEach((a, i) => { keys(a, ['caseID', 'assetID', 'ordinal', 'jpegSHA256', 'originalSHA256']); assert(Object.keys(a).length === 5 && Object.keys(catalog.binding.assetBindings[i]).every(k => a[k] === catalog.binding.assetBindings[i][k]), '文件身份或哈希不一致'); });
    assert(typeof draft.reviewer === 'string' && draft.reviewer.length <= 500 && typeof draft.note === 'string' && draft.note.length <= 10000, '修订说明无效');
    assert(Array.isArray(draft.caseEdits) && draft.caseEdits.length <= catalog.cases.length, '案例修订无效'); const seen = new Set();
    for (const edit of draft.caseEdits) {
      keys(edit, ['caseID', 'edgeEdits', 'groupEdits', 'removedGroupIDs']); const c = catalog.cases.find(c => c.id === edit.caseID);
      assert(c && !seen.has(c.id), '案例重复或不存在'); seen.add(c.id); const edgeIDs = new Set(), groupIDs = new Set();
      assert(Array.isArray(edit.edgeEdits) && edit.edgeEdits.length <= c.assets.length - 1, '边界数量无效');
      for (const edge of edit.edgeEdits) { keys(edge, ['leftAssetID', 'rightAssetID', 'relation', 'note']); const first = c.assets.findIndex(a => a.assetID === edge.leftAssetID); assert(first >= 0 && c.assets[first + 1]?.assetID === edge.rightAssetID && !edgeIDs.has(first), '必须是相邻且唯一的照片边界'); edgeIDs.add(first); assert(['same', 'separate', 'unknown'].includes(edge.relation) && typeof edge.note === 'string' && edge.note.length <= 2000, '边界修订无效'); }
      assert(Array.isArray(edit.groupEdits) && edit.groupEdits.length <= c.assets.length, '组数量无效');
      for (const group of edit.groupEdits) { keys(group, ['id', 'firstOrdinal', 'lastOrdinal', 'kind']); assert(typeof group.id === 'string' && group.id.length > 0 && group.id.length <= 128 && !groupIDs.has(group.id), '组 ID 无效或重复'); groupIDs.add(group.id); assert(Number.isInteger(group.firstOrdinal) && Number.isInteger(group.lastOrdinal) && group.firstOrdinal >= 0 && group.lastOrdinal > group.firstOrdinal && group.lastOrdinal < c.assets.length && ['burst', 'interval', 'sequence'].includes(group.kind), '组范围或类型无效'); }
      assert(Array.isArray(edit.removedGroupIDs) && new Set(edit.removedGroupIDs).size === edit.removedGroupIDs.length && edit.removedGroupIDs.every(id => c.truth.groups.some(g => g.id === id) && !groupIDs.has(id)), '移除的组无效或同时被编辑');
    }
    const problems = conflicts(catalog, draft); assert(allowConflicts || problems.length === 0, problems.join('；')); return clone(draft);
  }
  return {clone, empty, caseEdit, groups, truthRelation, conflicts, validate, parseStrictJSON};
})();
if (typeof module !== 'undefined') module.exports = ReviewModel;
if (typeof document !== 'undefined') (() => {
  const C = JSON.parse(document.getElementById('catalog-data').textContent), M = ReviewModel;
  const $ = id => document.getElementById(id), el = (tag, text, className) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (className) n.className = className; return n; };
  const storageKey = 'RAWMaster-sequence-review:' + C.indexSHA256 + ':' + C.cases.map(c => c.truthSHA256).join(':');
  let draft = M.empty(C), history = [], caseID = C.cases[0].id, algorithmID = C.algorithms.find(a => a.id === '009:009-strict')?.id || C.algorithms.at(-1)?.id, page = 0, selected = 0, errorLimit = 50;
  const typeName = {burst: '连拍', interval: '间隔', sequence: '序列'}, relationName = {same: '同组', separate: '分开', unknown: '未知'};
  function status(text, bad = false) { $('status').textContent = text; $('status').className = bad ? 'warning' : ''; }
  function persist() { try { localStorage.setItem(storageKey, JSON.stringify(draft)); status('草稿已保存在当前浏览器；请导出 JSON 留存。'); } catch (_) { status('浏览器未允许本地保存。草稿仍可编辑，请导出 JSON 留存。', true); } }
  try { const old = localStorage.getItem(storageKey); if (old) draft = M.validate(M.parseStrictJSON(old), C, true); } catch (_) { status('本地草稿不可读取或版本不匹配；已保留旧数据，当前使用空草稿。请导出后保存。', true); }
  function change(fn) { const next = M.clone(draft); fn(next); try { M.validate(next, C, true); history.push(M.clone(draft)); if (history.length > 100) history.shift(); draft = next; persist(); renderDraft(); renderBrowse(); } catch (error) { status(error.message, true); } }
  function option(value, title) { const o = el('option', title); o.value = value; return o; }
  function thumbnail(asset, callback) { const b = el('button'); b.type = 'button'; const img = document.createElement('img'); img.src = asset.thumbnail; img.alt = asset.filename + ' / ' + asset.assetID; img.loading = 'lazy'; b.append(img); if (callback) b.onclick = callback; return b; }
  function jump(id, ordinal) { $('group').value = ''; $('group-first').value = ''; caseID = id; selected = ordinal; page = Math.floor(ordinal / 60); $('case').value = id; $('search').value = ''; setView('browse'); renderBrowse(); }
  function currentCase() { return C.cases.find(c => c.id === caseID); }
  function currentUnit(c) { return c.algorithms.find(a => a.id === algorithmID); }
  function groupAt(groups, ordinal) { return groups.find(g => ordinal >= g.firstOrdinal && ordinal <= g.lastOrdinal); }
  function addFact(card, title, text) { const p = el('div', null, 'fact'); p.append(el('b', title), el('p', Array.isArray(text) ? text.join(' ') : text)); card.append(p); }
  function renderIntro() {
    const unitID = C.algorithms.find(a => a.id === '009:009-strict')?.id || algorithmID;
    const sony = C.cases.filter(c => !c.id.startsWith('dji')).map(c => c.algorithms.find(a => a.id === unitID)).filter(Boolean);
    $('summary').append(el('h2', '目前的结果'), el('p', '已知 Sony 案例 · ' + unitID + '。指标来自封存报告；未知和未标边界不补成负例。', 'muted'));
    const stats = el('div', null, 'stats'); for (const [key, label] of [['truePositive', '正确连接'], ['falsePositive', '错误合并'], ['falseNegative', '错误拆分'], ['trueNegative', '已标负边分开']]) { const box = el('div', null, 'stat'); box.append(el('strong', sony.reduce((s, u) => s + (u.metrics[key] || 0), 0)), el('span', label)); stats.append(box); } $('summary').append(stats);
    $('summary').append(el('p', 'DJI 的文件对与拍摄事件不是同一层：严格模式可大量漏连，假设配对的改善也不代表已证实配对精度。旧版本的失败仍保留在下方历史清单。', 'warning'));
    const unknown = C.cases.flatMap(c => c.assets.filter(a => c.unknownAssetIDs.includes(a.assetID)));
    $('unknown').textContent = '仍未知：' + unknown.map(a => a.filename).join(' / ') + '。不因相似画面或文件命名自动并入。'; $('unknown').className = 'warning';
    $('provenance').append(el('p', C.assetCount + ' 个文件 / ' + C.cases.length + ' 个案例。索引 ' + C.indexSHA256));
    for (const a of C.artifacts) $('provenance').append(el('p', a.id + ' · SHA256 ' + a.sha256));
    for (const text of C.visualReview.limitations || []) $('provenance').append(el('p', text));
    $('provenance').append(el('p', '实际视觉复核记录：' + C.visualReview.reviews.length + '。未列出的图片不视为已复核。'));
    $('binding').textContent = C.datasetID + ' · ' + C.indexSHA256.slice(0, 12);
  }
  function renderReviews() {
    const target = $('review-cards'); target.replaceChildren();
    for (const r of C.visualReview.reviews) {
      const c = C.cases.find(c => c.id === r.caseID), card = el('article', null, 'card'), images = el('div', null, 'images');
      card.append(el('span', r.caseID + ' · ' + r.confidence, 'eyebrow'), el('h3', ({retain: '建议保留旧标签', 'human-review': '需要你判断拍摄意图', unknown: '保持未知'})[r.labelAssessment]));
      const chosen = r.ordinals.length <= 4 ? r.ordinals : [r.ordinals[0], r.ordinals[Math.floor(r.ordinals.length / 2)], r.ordinals.at(-1)];
      for (const ordinal of chosen) images.append(thumbnail(c.assets[ordinal], () => jump(c.id, ordinal))); card.append(images);
      addFact(card, '实际看到', r.observations); addFact(card, '算法归因', r.attribution); addFact(card, '人工复核建议', r.recommendation);
      if (r.ordinals.length > 4) { const detail = el('details'); detail.append(el('summary', '实际查看 ' + r.ordinals.length + ' 张 · 展开文件清单'), el('small', r.ordinals.map(i => c.assets[i].filename).join(' / '))); card.append(detail); }
      else card.append(el('small', '已看：' + r.ordinals.map(i => c.assets[i].filename).join(' / ')));
      const b = el('button', '查看这段并修订', 'jump'); b.onclick = () => jump(c.id, r.ordinals[0]); card.append(b); target.append(card);
    }
    if (!C.visualReview.reviews.length) target.append(el('p', '未提供实际视觉复核。以下历史算法错误仍可逐一检查。', 'warning'));
    const dji = C.errors.filter(e => e.caseID.startsWith('dji'));
    if (dji.length) { const card = el('article', null, 'card'); card.append(el('h3', 'DJI：' + dji.length + ' 个历史错误边界归为一类'), el('p', '拍摄事件时钟 / DNG 与 JPG 表示层限制。完整边界仍在历史清单；不是每一对都经过视觉复核。')); const b = el('button', '展开完整 DJI 边界'); b.onclick = () => { $('error-case').value = dji[0].caseID; $('catalog-details').open = true; errorLimit = 50; renderErrors(); }; card.append(b); target.append(card); }
    $('error-title').textContent = '完整历史错误清单 · ' + C.errors.length + ' 个独立边界（含已修复错误）'; renderErrors();
  }
  function renderErrors() {
    const q = $('error-search').value.toLowerCase(), cs = $('error-case').value, alg = $('error-algorithm').value;
    const errors = C.errors.filter(e => (!cs || e.caseID === cs) && (!alg || e.occurrences.some(o => o.algorithmID === alg)) && (!q || (e.caseID + ' ' + e.occurrences.map(o => o.outcome + ' ' + o.algorithmID).join(' ') + ' ' + C.cases.find(c => c.id === e.caseID).assets.slice(e.firstOrdinal, e.firstOrdinal + 2).map(a => a.filename + ' ' + a.assetID).join(' ')).toLowerCase().includes(q)));
    const table = el('table'), head = el('tr'); ['案例 / 边界', '旧标签', '历史失败版本', '操作'].forEach(t => head.append(el('th', t))); table.append(head);
    for (const e of errors.slice(0, errorLimit)) { const c = C.cases.find(c => c.id === e.caseID), row = el('tr'); row.append(el('td', c.id + ' #' + e.firstOrdinal + ' → #' + (e.firstOrdinal + 1) + '\n' + c.assets[e.firstOrdinal].filename + ' / ' + c.assets[e.firstOrdinal + 1].filename), el('td', relationName[e.expected]), el('td', e.occurrences.map(o => o.algorithmID + ':' + o.outcome).join(' / '))); const td = el('td'), b = el('button', '查看 / 标注'); b.onclick = () => jump(c.id, e.firstOrdinal); td.append(b); row.append(td); table.append(row); }
    $('error-list').replaceChildren(el('p', '当前 ' + errors.length + ' 个边界；显示 ' + Math.min(errors.length, errorLimit)), table); $('more-errors').disabled = errorLimit >= errors.length;
  }
  function renderDraft() { const n = draft.caseEdits.reduce((s, c) => s + c.edgeEdits.length + c.groupEdits.length + c.removedGroupIDs.length, 0); $('draft-count').textContent = n + ' 项草稿修改'; $('undo').disabled = history.length === 0; const issues = M.conflicts(C, draft); $('conflicts').textContent = issues.join('；'); $('export').disabled = issues.length > 0; }
  function renderBrowse() {
    const c = currentCase(), u = currentUnit(c), gs = M.groups(c, draft); $('case').value = c.id; $('algorithm').value = algorithmID;
    const q = $('search').value.toLowerCase(); const assets = c.assets.filter(a => !q || (a.filename + ' ' + a.assetID + ' ' + a.ordinal).toLowerCase().includes(q)); page = Math.max(0, Math.min(page, Math.ceil(assets.length / 60) - 1));
    $('page').textContent = (assets.length ? page + 1 : 0) + ' / ' + Math.ceil(assets.length / 60); $('previous').disabled = page === 0; $('next').disabled = (page + 1) * 60 >= assets.length;
    $('case-info').textContent = c.assets.length + ' 个文件全部保留；匹配 ' + assets.length + '。绿色为草稿组，蓝色为所选算法组，旧标签单独标示。' + (c.unknownAssetIDs.length ? ' ⚠ 包含未确认的0188，不自动赋予真值。' : '');
    const table = el('table'), tr = el('tr'); ['版本', 'TP / FP / FN / TN', 'Precision / Recall', '整组 exact', '备注'].forEach(t => tr.append(el('th', t))); table.append(tr);
    if (u) { const m = u.metrics, row = el('tr'), percent = x => x == null ? '未定义' : (x * 100).toFixed(1) + '%'; row.append(el('td', u.title), el('td', ['truePositive', 'falsePositive', 'falseNegative', 'trueNegative'].map(k => m[k] ?? '—').join(' / ')), el('td', percent(m.precision) + ' / ' + percent(m.recall)), el('td', percent(m.exactGroupFraction)), el('td', u.associationAssumed ? '假设配对 · 配对精度未证实' : '声明来源内的分组指标')); table.append(row); } $('metrics').replaceChildren(table);
    const grid = $('grid'); grid.replaceChildren();
    for (const a of assets.slice(page * 60, (page + 1) * 60)) { const card = el('button', null, 'photo' + (a.ordinal === selected ? ' selected' : '') + (c.unknownAssetIDs.includes(a.assetID) ? ' unknown' : '')); const img = document.createElement('img'); img.src = a.thumbnail; img.alt = a.filename; img.loading = 'lazy'; card.append(img, el('span', a.filename, 'filename'), el('span', '#' + a.ordinal + ' · ' + a.assetID, 'ordinal')); const bars = el('div', null, 'bars'), truth = c.truth.groups.find(g => g.assetIDs.includes(a.assetID)), predicted = u?.ranges.find(g => a.ordinal >= g.range.first && a.ordinal <= g.range.last), draftGroup = groupAt(gs, a.ordinal); bars.append(el('span', c.unknownAssetIDs.includes(a.assetID) ? '旧：未知' : truth ? '旧：' + typeName[truth.kind] : '旧：未标')); if (predicted) bars.append(el('span', '算 #' + predicted.range.first, 'pred')); if (draftGroup) bars.append(el('span', '草 #' + draftGroup.firstOrdinal, 'draft')); card.append(bars); card.onclick = () => { selected = a.ordinal; renderBrowse(); }; grid.append(card); }
    renderEditor(); renderDraft();
  }
  function renderEditor() {
    const c = currentCase(), a = c.assets[selected]; if (!a) return;
    $('selection').replaceChildren(el('b', a.filename), el('p', '#' + selected + ' / ' + a.assetID), el('details'));
    const detail = $('selection').lastChild; detail.append(el('summary', '文件绑定'), el('p', 'JPEG ' + a.jpegSHA256 + '\n原片 ' + a.originalSHA256, 'file-detail'));
    $('edge-editor').hidden = selected >= c.assets.length - 1;
    if (selected < c.assets.length - 1) { const b = c.assets[selected + 1]; $('edge-images').replaceChildren(...[a, b].map(v => { const img = document.createElement('img'); img.src = v.thumbnail; img.alt = v.filename; return img; })); const edit = draft.caseEdits.find(e => e.caseID === c.id)?.edgeEdits.find(e => e.leftAssetID === a.assetID); $('edge-info').textContent = a.filename + ' → ' + b.filename + '；旧：' + relationName[M.truthRelation(c, selected)] + '；草稿：' + (edit ? relationName[edit.relation] : '沿用旧标签'); document.querySelectorAll('[data-relation]').forEach(b => b.classList.toggle('active', b.dataset.relation === edit?.relation)); }
    const previousGroup = $('group').value; $('group').replaceChildren(option('', '新建范围…')); for (const g of M.groups(c, draft)) $('group').append(option(g.id, g.id + ' · #' + g.firstOrdinal + '–' + g.lastOrdinal)); if ([...$('group').options].some(o => o.value === previousGroup)) $('group').value = previousGroup;
    loadGroup(false);
  }
  function loadGroup(reset = true) { const c = currentCase(), g = M.groups(c, draft).find(g => g.id === $('group').value); if (g) { $('group-first').value = g.firstOrdinal; $('group-last').value = g.lastOrdinal; $('group-kind').value = g.kind; } else if (reset || !$('group-first').value) { $('group-first').value = selected; $('group-last').value = Math.min(selected + 1, c.assets.length - 1); } groupPreview(); }
  function groupPreview() { const c = currentCase(), first = Number($('group-first').value), last = Number($('group-last').value); $('group-preview').textContent = Number.isInteger(first) && Number.isInteger(last) && c.assets[first] && c.assets[last] && first < last ? c.assets[first].filename + ' → ' + c.assets[last].filename + ' · ' + (last - first + 1) + ' 个文件' : '请选择至少两张、按基础顺序连续的照片。'; }
  function setView(view) { $('review-view').hidden = view !== 'review'; $('browse-view').hidden = view !== 'browse'; document.querySelectorAll('[data-view]').forEach(b => b.classList.toggle('active', b.dataset.view === view)); }
  for (const c of C.cases) { $('case').append(option(c.id, c.id + ' · ' + c.assets.length)); $('error-case').append(option(c.id, c.id)); } for (const a of C.algorithms) { $('algorithm').append(option(a.id, a.title)); $('error-algorithm').append(option(a.id, a.title)); }
  document.querySelectorAll('[data-view]').forEach(b => b.onclick = () => setView(b.dataset.view));
  $('case').onchange = () => { caseID = $('case').value; page = 0; selected = 0; $('group').value = ''; $('group-first').value = ''; renderBrowse(); };
  $('algorithm').onchange = () => { algorithmID = $('algorithm').value; renderBrowse(); }; $('search').oninput = () => { page = 0; renderBrowse(); };
  $('previous').onclick = () => { page--; renderBrowse(); }; $('next').onclick = () => { page++; renderBrowse(); };
  for (const id of ['error-case', 'error-algorithm', 'error-search']) $(id).oninput = () => { errorLimit = 50; renderErrors(); }; $('more-errors').onclick = () => { errorLimit += 100; renderErrors(); };
  document.querySelectorAll('[data-relation]').forEach(b => b.onclick = () => change(d => { const c = currentCase(), edit = M.caseEdit(d, c.id), left = c.assets[selected], right = c.assets[selected + 1]; edit.edgeEdits = edit.edgeEdits.filter(e => e.leftAssetID !== left.assetID); edit.edgeEdits.push({leftAssetID: left.assetID, rightAssetID: right.assetID, relation: b.dataset.relation, note: ''}); }));
  $('remove-edge').onclick = () => change(d => { const edit = M.caseEdit(d, caseID); edit.edgeEdits = edit.edgeEdits.filter(e => e.leftAssetID !== currentCase().assets[selected].assetID); });
  $('group').onchange = () => loadGroup(); $('group-first').oninput = groupPreview; $('group-last').oninput = groupPreview;
  $('save-group').onclick = () => change(d => { const edit = M.caseEdit(d, caseID), id = $('group').value || 'human-' + Date.now(); edit.groupEdits = edit.groupEdits.filter(g => g.id !== id); edit.removedGroupIDs = edit.removedGroupIDs.filter(g => g !== id); edit.groupEdits.push({id, firstOrdinal: Number($('group-first').value), lastOrdinal: Number($('group-last').value), kind: $('group-kind').value}); });
  $('remove-group').onclick = () => { const id = $('group').value; if (!id) return; change(d => { const edit = M.caseEdit(d, caseID); edit.groupEdits = edit.groupEdits.filter(g => g.id !== id); if (currentCase().truth.groups.some(g => g.id === id) && !edit.removedGroupIDs.includes(id)) edit.removedGroupIDs.push(id); }); };
  $('undo').onclick = () => { if (history.length) { draft = history.pop(); persist(); renderBrowse(); } }; $('reset').onclick = () => { if (confirm('清空当前修订草稿？旧标签与图像不会改变，可用撤销恢复。')) change(d => { d.caseEdits = []; }); };
  $('export').onclick = () => { try { M.validate(draft, C); const blob = new Blob([JSON.stringify(draft, null, 2)], {type: 'application/json'}), url = URL.createObjectURL(blob), a = el('a'); a.href = url; a.download = 'RAWMaster-label-revision-' + C.indexSHA256.slice(0, 12) + '.json'; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); status('修订已导出；源标签未改变。'); } catch (e) { status(e.message, true); } };
  $('import').onchange = async event => { const file = event.target.files[0]; if (!file) return; try { const imported = M.validate(M.parseStrictJSON(await file.text()), C); history.push(M.clone(draft)); if (history.length > 100) history.shift(); draft = imported; persist(); renderBrowse(); status('修订已导入为草稿；源标签未改变。'); } catch (e) { status('导入被拒绝：' + e.message, true); } event.target.value = ''; };
  renderIntro(); renderReviews(); renderBrowse();
})();
