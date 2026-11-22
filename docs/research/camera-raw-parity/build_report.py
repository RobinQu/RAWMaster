#!/usr/bin/env python3
"""Build and validate the Camera Raw × RawMaster parity report.

Canonical content: feature-matrix.json. No third-party packages required.
Run: python3 docs/research/camera-raw-parity/build_report.py
CI/stale check: python3 docs/research/camera-raw-parity/build_report.py --check
"""
from __future__ import annotations
import argparse
import csv
import html
import json
import re
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import quote

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
DATA_PATH = HERE / 'feature-matrix.json'
OUT_PATH = HERE / 'index.html'
STATUSES = ('aligned', 'partial', 'different', 'missing')
PRIORITIES = ('P0', 'P1', 'P2')
REF_RE = re.compile(r'^(.*):(\d+)(?:-(\d+))?$')


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def load_data() -> dict:
    return json.loads(DATA_PATH.read_text(encoding='utf-8'))


def validate(data: dict) -> None:
    assert data.get('schemaVersion') == 1, 'Unsupported schemaVersion'
    panels = data['panels']
    sources = data['sources']
    features = data['features']
    panel_ids = [p['id'] for p in panels]
    assert len(panel_ids) == len(set(panel_ids)) == 9, 'Exactly nine unique panels required'
    assert tuple(data['statuses']) == STATUSES, 'Status order/keys changed'
    feature_ids = [f['id'] for f in features]
    assert len(feature_ids) == len(set(feature_ids)), 'Duplicate feature ID'
    required = {'id','panel','group','name','cameraRaw','status','rawMaster','difference','sources','codeRefs','priority','evidenceLevel','acceptance'}
    for f in features:
        missing = required - f.keys()
        assert not missing, f"{f.get('id')}: missing fields {sorted(missing)}"
        assert f['panel'] in panel_ids, f"{f['id']}: unknown panel"
        assert f['status'] in STATUSES, f"{f['id']}: unknown status"
        assert f['priority'] in PRIORITIES, f"{f['id']}: unknown priority"
        assert f['sources'], f"{f['id']}: official source required"
        assert f['codeRefs'], f"{f['id']}: RawMaster code evidence required"
        assert all(s in sources for s in f['sources']), f"{f['id']}: unknown source"
        for key in ('name','cameraRaw','rawMaster','difference','acceptance'):
            assert str(f[key]).strip(), f"{f['id']}: empty {key}"
        for ref in f['codeRefs']:
            match = REF_RE.match(ref)
            assert match, f"{f['id']}: invalid code ref {ref}"
            rel, first, last = match.group(1), int(match.group(2)), int(match.group(3) or match.group(2))
            path = ROOT / rel
            assert path.is_file(), f"{f['id']}: missing code file {rel}"
            line_count = len(path.read_text(encoding='utf-8').splitlines())
            assert 1 <= first <= last <= line_count, f"{f['id']}: stale code ref {ref} (file has {line_count})"
    for p in panels:
        assert (HERE / p['image']).is_file(), f"{p['id']}: missing image {p['image']}"
        assert all(s in sources for s in p['sources']), f"{p['id']}: unknown panel source"
    for source in sources.values():
        assert source['url'].startswith('https://helpx.adobe.com/'), f"Non-official source: {source['url']}"
        assert source['title'] and source['updated']
    for group in ('rawMasterExtras','verificationBacklog'):
        assert isinstance(data.get(group), list), f'{group} must be a list'
    for extra in data['rawMasterExtras']:
        assert extra['panel'] in panel_ids and extra['name'] and extra['detail']
        for ref in extra['codeRefs']:
            match = REF_RE.match(ref)
            assert match and (ROOT / match.group(1)).is_file(), f"Invalid extra code ref {ref}"
    for pending in data['verificationBacklog']:
        assert pending['panel'] in panel_ids + ['all']
        assert pending['id'] and pending['item'] and pending['reason'] and pending['action']
    plan = data.get('developmentPlan')
    assert plan, 'developmentPlan required'
    workstreams = plan['workstreams']
    assert len({w['id'] for w in workstreams}) == len(workstreams), 'Duplicate workstream ID'
    assert [sum(w['weeks'][0] for w in workstreams), sum(w['weeks'][1] for w in workstreams)] == plan['estimate']['personWeeks'], 'Effort total mismatch'
    for w in workstreams:
        assert w['name'] and w['scope'] and w['exit'] and w['depends']
        assert 0 < w['weeks'][0] <= w['weeks'][1], f"{w['id']}: invalid effort"
    assert plan['phases'] and plan['risks'] and plan['gates']
    pending_count = sum(f['status'] != 'aligned' for f in features)
    release_phase = next(p for p in plan['phases'] if p['id'] == 'R5')
    assert release_phase['gate'].startswith(f'{pending_count} 个未完全具备项'), 'R5 gate has a stale pending-feature count'


def code_link(ref: str) -> str:
    match = REF_RE.match(ref)
    assert match
    path, first = match.group(1), match.group(2)
    href = '../../../' + quote(path) + '#L' + first
    return f'<a class="code-ref" href="{esc(href)}"><code>{esc(ref)}</code></a>'


def source_links(data: dict, ids: list[str]) -> str:
    return ' · '.join(f'<a href="{esc(data["sources"][sid]["url"])}" target="_blank" rel="noopener">{esc(data["sources"][sid]["title"])} <span class="source-date">{esc(data["sources"][sid]["updated"])}</span></a>' for sid in ids)


def status_chip(status: str, data: dict) -> str:
    return f'<span class="status status-{status}">{esc(data["statuses"][status])}</span>'


def feature_row(f: dict, data: dict) -> str:
    search = ' '.join(str(f[k]) for k in ('id','group','name','cameraRaw','rawMaster','difference','acceptance')).lower()
    return f'''<tr class="feature" id="{esc(f['id'])}" data-status="{f['status']}" data-search="{esc(search)}">
      <td class="feature-name"><span class="group-label">{esc(f['group'])}</span><strong>{esc(f['name'])}</strong><span class="priority priority-{f['priority']}">{f['priority']}</span><div class="feature-id">{esc(f['id'])}</div></td>
      <td>{esc(f['cameraRaw'])}</td>
      <td>{esc(f['rawMaster'])}</td>
      <td class="status-cell">{status_chip(f['status'], data)}</td>
    </tr>
    <tr class="feature-detail" data-status="{f['status']}" data-search="{esc(search)}"><td colspan="4"><details>
      <summary>差异、验收与证据</summary>
      <div class="detail-grid"><div><h4>差异判定</h4><p>{esc(f['difference'])}</p></div><div><h4>完成验收</h4><p>{esc(f['acceptance'])}</p></div></div>
      <div class="evidence"><div><h4>Camera Raw 官方依据</h4><p>{source_links(data, f['sources'])}</p></div><div><h4>RawMaster 代码证据 <span class="muted">（静态）</span></h4><p>{'<br>'.join(code_link(r) for r in f['codeRefs'])}</p></div></div>
    </details></td></tr>'''


def panel_section(p: dict, features: list[dict], data: dict) -> str:
    own = [f for f in features if f['panel'] == p['id']]
    counts = Counter(f['status'] for f in own)
    total = len(own)
    bars = ''.join(f'<span class="bar-{s}" style="width:{counts[s]/total*100:.3f}%" title="{esc(data["statuses"][s])} {counts[s]}"></span>' for s in STATUSES if counts[s])
    stat_text = ' · '.join(f'{data["statuses"][s]} {counts[s]}' for s in STATUSES)
    return f'''<section class="panel-section" id="panel-{p['id']}" data-panel="{p['id']}">
      <div class="panel-heading"><div><div class="eyebrow">{esc(p['title'])}</div><h2><span class="panel-icon">{esc(p['icon'])}</span>{esc(p['zh'])} <span class="english">/ {esc(p['title'])}</span></h2></div><div class="panel-total">{total}<small>对照项</small></div></div>
      <div class="stacked-bar" aria-label="{esc(stat_text)}">{bars}</div>
      <div class="panel-stats">{esc(stat_text)}</div>
      <figure><a href="{esc(p['image'])}" target="_blank"><img src="{esc(p['image'])}" alt="{esc(p['caption'])}" loading="lazy"></a><figcaption>{esc(p['caption'])}<br><span class="figure-source">官方配图来源：{source_links(data, p['sources'])}</span></figcaption></figure>
      <div class="table-wrap"><table><thead><tr><th>功能点</th><th>Camera Raw 功能清单</th><th>RawMaster 当前实现</th><th>状态</th></tr></thead><tbody>{''.join(feature_row(f, data) for f in own)}</tbody></table></div>
      <p class="empty-panel" hidden>此面板没有符合当前筛选条件的项目。</p>
    </section>'''


def render(data: dict) -> str:
    features = data['features']
    counts = Counter(f['status'] for f in features)
    total = len(features)
    gaps = total - counts['aligned']
    pct = counts['aligned'] / total * 100
    priority_gaps = Counter(f['priority'] for f in features if f['status'] != 'aligned')
    panel_nav = ''.join(f'<a href="#panel-{p["id"]}"><span>{esc(p["icon"])}</span>{esc(p["title"])}</a>' for p in data['panels'])
    panel_cards = ''.join(f'''<a class="panel-card" href="#panel-{p['id']}"><div><span class="panel-card-icon">{esc(p['icon'])}</span><strong>{esc(p['title'])}</strong></div><span>{len([f for f in features if f['panel']==p['id']])} 项</span><small>{len([f for f in features if f['panel']==p['id'] and f['status']=='missing'])} 缺失 · {len([f for f in features if f['panel']==p['id'] and f['status']=='aligned'])} 已具备</small></a>''' for p in data['panels'])
    open_features = ''.join(
        f'<article class="conclusion"><h3><a href="#{esc(f["id"])}">{esc(f["name"])}</a></h3>'
        f'{status_chip(f["status"], data)}<p>{esc(f["rawMaster"])}</p></article>'
        for f in features if f['status'] != 'aligned')
    extras = ''.join(f'<article class="extra"><span class="tag">RawMaster 扩展</span><h3>{esc(e["name"])}</h3><p>{esc(e["detail"])}</p><p>{'<br>'.join(code_link(r) for r in e['codeRefs'])}</p></article>' for e in data['rawMasterExtras'])
    backlog = ''.join(f'<article class="backlog-item"><div><span class="tag tag-verify">待实机复核</span><code>{esc(v["id"])}</code><h3>{esc(v["item"])}</h3><p>{esc(v["reason"])}</p><p><strong>下一步：</strong>{esc(v["action"])}</p></div></article>' for v in data['verificationBacklog'])
    plan = data['developmentPlan']
    workstreams = ''.join(f'<article class="backlog-item"><span class="tag">{esc(w["id"])} · {w["weeks"][0]}–{w["weeks"][1]} 人周</span><h3>{esc(w["name"])}</h3><p>{esc(w["scope"])}</p><p><strong>依赖：</strong>{esc(w["depends"])}</p><p><strong>退出标准：</strong>{esc(w["exit"])}</p></article>' for w in plan['workstreams'])
    phases = ''.join(f'<article class="extra"><span class="tag">{esc(r["id"])} · {esc(r["duration"])}</span><h3>{esc(r["name"])}</h3><p>{esc(r["contents"])}</p><p><strong>阶段门禁：</strong>{esc(r["gate"])}</p></article>' for r in plan['phases'])
    risks = ''.join(f'<article class="backlog-item"><h3>{esc(r["risk"])}</h3><p>{esc(r["response"])}</p></article>' for r in plan['risks'])
    gates = ''.join(f'<li>{esc(g)}</li>' for g in plan['gates'])
    data_json = json.dumps(data, ensure_ascii=False, separators=(',',':')).replace('</','<\\/')
    return f'''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light">
<title>{esc(data['meta']['title'])}</title>
<style>
:root{{--ink:#17221f;--muted:#63716c;--paper:#f4f5f1;--card:#fff;--line:#dce2dd;--green:#13795b;--green-soft:#e2f3eb;--amber:#9a5b00;--amber-soft:#fff1d8;--red:#b6403a;--red-soft:#fbe9e6;--blue:#355f9b;--blue-soft:#e7eef9;--dark:#13231e;--accent:#b9f56b;--shadow:0 14px 40px rgba(24,44,36,.07)}}
*{{box-sizing:border-box}}html{{scroll-behavior:smooth;scroll-padding-top:84px}}body{{margin:0;background:var(--paper);color:var(--ink);font:14px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif}}a{{color:var(--blue);text-decoration:none}}a:hover{{text-decoration:underline}}button,select,input{{font:inherit}}button,.button{{border:1px solid var(--line);background:#fff;color:var(--ink);border-radius:9px;padding:8px 12px;cursor:pointer;display:inline-flex;align-items:center;gap:6px}}button:hover,.button:hover{{border-color:#aab8b0;text-decoration:none}}code{{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}}.wrap{{width:min(1460px,calc(100% - 48px));margin:auto}}.hero{{background:var(--dark);color:#fff;padding:54px 0 44px;position:relative;overflow:hidden}}.hero:after{{content:"";position:absolute;width:520px;height:520px;border:1px solid rgba(185,245,107,.18);border-radius:50%;right:-110px;top:-260px;box-shadow:0 0 0 70px rgba(185,245,107,.035),0 0 0 140px rgba(185,245,107,.025)}}.hero .wrap{{position:relative;z-index:1}}.kicker{{text-transform:uppercase;letter-spacing:.17em;color:var(--accent);font-size:12px;font-weight:700}}h1{{font-size:clamp(30px,4.3vw,56px);line-height:1.14;letter-spacing:-.035em;max-width:1050px;margin:14px 0 20px}}.hero-sub{{max-width:920px;color:#d4dfda;font-size:16px}}.meta-row{{display:flex;flex-wrap:wrap;gap:8px;margin-top:24px}}.meta-pill{{border:1px solid #40554c;background:#1b3028;color:#e3ebe7;padding:5px 10px;border-radius:99px;font-size:12px}}.actions{{display:flex;gap:8px;flex-wrap:wrap;margin-top:24px}}.hero .button,.hero button{{background:var(--accent);border-color:var(--accent);color:#14221d;font-weight:700}}.hero .secondary{{background:transparent;color:#fff;border-color:#566b61}}.summary-grid{{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-top:-1px;padding:24px 0}}.summary-card{{background:var(--card);border:1px solid var(--line);padding:18px;border-radius:13px;box-shadow:var(--shadow)}}.summary-card strong{{display:block;font-size:30px;line-height:1.2;letter-spacing:-.04em}}.summary-card span{{color:var(--muted);font-size:12px}}.summary-card.aligned strong{{color:var(--green)}}.summary-card.missing strong{{color:var(--red)}}.summary-card.different strong{{color:var(--blue)}}.summary-card.partial strong{{color:var(--amber)}}.notice{{border-left:4px solid var(--amber);background:#fff8e9;padding:14px 17px;border-radius:0 10px 10px 0;margin:0 0 26px}}.section-title{{margin:42px 0 16px;display:flex;align-items:end;justify-content:space-between;gap:20px}}h2{{font-size:26px;line-height:1.25;margin:0;letter-spacing:-.02em}}h3{{line-height:1.35}}.section-title p{{margin:0;color:var(--muted);max-width:700px}}.panel-cards{{display:grid;grid-template-columns:repeat(9,1fr);gap:8px}}.panel-card{{background:#fff;border:1px solid var(--line);padding:13px;border-radius:11px;color:var(--ink)}}.panel-card:hover{{border-color:#93a49a;text-decoration:none;transform:translateY(-1px)}}.panel-card>div{{display:flex;gap:7px;align-items:center}}.panel-card-icon{{font-size:20px;color:var(--green)}}.panel-card>span,.panel-card small{{display:block;color:var(--muted);margin-top:5px;font-size:11px}}.conclusions{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px}}.conclusion{{background:#fff;border:1px solid var(--line);border-radius:12px;padding:18px}}.conclusion h3{{margin:0 0 8px;font-size:16px}}.conclusion p{{margin:0;color:var(--muted)}}.toolbar{{position:sticky;top:0;z-index:10;background:rgba(244,245,241,.96);backdrop-filter:blur(12px);border-block:1px solid var(--line);margin-top:34px;padding:11px 0}}.toolbar-inner{{display:flex;align-items:center;gap:8px;flex-wrap:wrap}}.search{{flex:1;min-width:210px;border:1px solid var(--line);border-radius:9px;padding:8px 11px;background:#fff;color:var(--ink)}}.check{{display:inline-flex;align-items:center;gap:6px;color:var(--muted);padding:6px}}.result-count{{color:var(--muted);margin-left:auto;font-variant-numeric:tabular-nums}}.panel-nav{{display:flex;gap:5px;overflow:auto;padding:10px 0 0}}.panel-nav a{{white-space:nowrap;color:var(--muted);padding:4px 8px;border-radius:6px;font-size:12px}}.panel-nav a:hover{{background:#e4e9e4;text-decoration:none}}.panel-section{{margin:38px 0 46px}}.panel-heading{{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}}.eyebrow{{font-size:11px;color:var(--green);text-transform:uppercase;letter-spacing:.15em;font-weight:700}}.panel-icon{{color:var(--green);margin-right:8px}}.english{{color:var(--muted);font-weight:400;font-size:18px}}.panel-total{{font-size:32px;font-weight:700;text-align:right;line-height:1}}.panel-total small{{display:block;color:var(--muted);font-size:11px;font-weight:400;margin-top:6px}}.stacked-bar{{height:8px;display:flex;overflow:hidden;border-radius:99px;background:#e3e7e3}}.stacked-bar span{{height:100%}}.bar-aligned{{background:var(--green)}}.bar-partial{{background:#df9c32}}.bar-different{{background:#5a7faf}}.bar-missing{{background:#d46a61}}.panel-stats{{color:var(--muted);font-size:12px;margin:6px 0 14px}}figure{{margin:0 0 16px;background:#fff;border:1px solid var(--line);border-radius:13px;overflow:hidden;display:grid;grid-template-columns:minmax(0,1.65fr) minmax(260px,.8fr)}}figure img{{display:block;width:100%;height:100%;max-height:390px;object-fit:contain;background:#e9ece8}}figcaption{{padding:20px;color:var(--muted);font-size:13px;align-self:center}}.figure-source{{font-size:11px}}.source-date{{color:var(--muted);font-size:.85em}}.table-wrap{{border:1px solid var(--line);border-radius:13px;overflow:hidden;background:#fff}}table{{width:100%;border-collapse:collapse;table-layout:fixed}}th{{background:#edf0eb;color:#52615a;text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:.06em;padding:11px 14px}}th:nth-child(1){{width:23%}}th:nth-child(2){{width:28%}}th:nth-child(3){{width:34%}}th:nth-child(4){{width:15%}}td{{padding:14px;border-top:1px solid var(--line);vertical-align:top}}.feature td{{border-top:1px solid var(--line)}}.feature-name strong{{display:inline;overflow-wrap:anywhere}}.group-label{{display:block;color:var(--green);font-size:10px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:3px}}.feature-id{{color:#8a958f;font:10px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;margin-top:5px}}.priority{{display:inline-block;margin-left:7px;border-radius:4px;padding:0 4px;font-size:9px;vertical-align:1px}}.priority-P0{{background:#f3e4e1;color:#983d35}}.priority-P1{{background:#e8eef5;color:#3d618e}}.priority-P2{{background:#ecefeb;color:#66746c}}.status{{display:inline-flex;align-items:center;border-radius:99px;padding:3px 9px;font-size:11px;font-weight:700;white-space:nowrap}}.status-aligned{{color:var(--green);background:var(--green-soft)}}.status-partial{{color:var(--amber);background:var(--amber-soft)}}.status-different{{color:var(--blue);background:var(--blue-soft)}}.status-missing{{color:var(--red);background:var(--red-soft)}}.feature-detail td{{padding:0 14px;border-top:0;background:#fafbf9}}.feature-detail details{{margin:-7px 0 9px}}summary{{cursor:pointer;color:var(--blue);font-size:12px;padding:5px 0}}.detail-grid,.evidence{{display:grid;grid-template-columns:1fr 1fr;gap:20px;border-top:1px dashed var(--line);padding-top:10px;margin-top:5px}}.detail-grid h4,.evidence h4{{margin:0;font-size:11px;color:var(--muted)}}.detail-grid p,.evidence p{{margin:5px 0 10px;font-size:12px}}.code-ref{{overflow-wrap:anywhere}}.empty-panel{{padding:24px;text-align:center;color:var(--muted);background:#fff;border:1px dashed var(--line)}}.extras-grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}}.extra,.backlog-item{{background:#fff;border:1px solid var(--line);border-radius:12px;padding:18px}}.extra h3,.backlog-item h3{{margin:10px 0 6px;font-size:16px}}.extra p,.backlog-item p{{color:var(--muted);margin:6px 0}}.tag{{display:inline-block;background:#e8eee9;color:#42554b;padding:2px 7px;border-radius:5px;font-size:10px;font-weight:700}}.tag-verify{{background:var(--amber-soft);color:var(--amber)}}.backlog-list{{display:grid;grid-template-columns:1fr 1fr;gap:12px}}.maintenance{{background:var(--dark);color:#eef5f0;border-radius:16px;padding:28px;margin:38px 0}}.maintenance h2{{color:#fff}}.maintenance p{{color:#c6d3cc;max-width:1000px}}.maintenance-grid{{display:grid;grid-template-columns:repeat(4,1fr);gap:18px;margin-top:20px}}.maintenance-step{{border-top:1px solid #40554c;padding-top:12px}}.maintenance-step strong{{color:var(--accent);display:block;margin-bottom:6px}}.command{{display:block;background:#0b1713;color:#dcf5cf;padding:13px;border-radius:8px;overflow:auto;margin-top:16px;white-space:nowrap}}.rules{{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:20px}}.rules ul{{margin:6px 0;padding-left:20px;color:#c6d3cc}}footer{{color:var(--muted);padding:10px 0 40px;font-size:12px}}[hidden]{{display:none!important}}
@media(max-width:1100px){{.panel-cards{{grid-template-columns:repeat(3,1fr)}}.summary-grid{{grid-template-columns:repeat(3,1fr)}}.conclusions{{grid-template-columns:1fr 1fr}}.maintenance-grid{{grid-template-columns:1fr 1fr}}}}
@media(max-width:760px){{.wrap{{width:min(100% - 24px,1460px)}}.hero{{padding:36px 0}}.summary-grid{{grid-template-columns:1fr 1fr}}.panel-cards{{grid-template-columns:1fr 1fr}}.section-title{{display:block}}.section-title p{{margin-top:8px}}.conclusions,.extras-grid,.backlog-list,.rules{{grid-template-columns:1fr}}figure{{grid-template-columns:1fr}}figure img{{max-height:300px}}.table-wrap{{overflow:visible;border:0;background:transparent}}table,tbody{{display:block}}thead{{display:none}}.feature{{display:grid;grid-template-columns:1fr auto;background:#fff;border:1px solid var(--line);border-radius:12px 12px 0 0;padding:12px;gap:10px}}.feature td{{display:block;border:0;padding:5px}}.feature td:nth-child(2):before{{content:"Camera Raw：";color:var(--muted)}}.feature td:nth-child(3):before{{content:"RawMaster：";color:var(--muted)}}.feature .feature-name{{grid-column:1/-1}}.feature .status-cell{{position:absolute;right:20px}}.feature-detail{{display:block;background:#fff;border:1px solid var(--line);border-top:0;border-radius:0 0 12px 12px;margin-bottom:12px}}.feature-detail td{{display:block;border:0}}.detail-grid,.evidence{{grid-template-columns:1fr;gap:0}}.maintenance-grid{{grid-template-columns:1fr}}.result-count{{width:100%;margin:0}}}}
@media print{{body{{background:#fff;font-size:10px}}.wrap{{width:100%}}.hero{{background:#fff;color:#000;padding:10px 0}}.hero-sub,.meta-pill{{color:#333}}.hero:after,.actions,.toolbar,.panel-cards,.conclusions,.maintenance,.extras-grid,.backlog-list,footer{{display:none!important}}.summary-grid{{grid-template-columns:repeat(5,1fr);padding:8px 0}}.summary-card{{box-shadow:none;padding:8px}}.panel-section{{break-before:page;margin:10px 0}}figure{{grid-template-columns:35% 65%;break-inside:avoid}}figure img{{max-height:170px}}.table-wrap{{overflow:visible}}th,td{{padding:6px}}.feature-detail details>*{{display:block!important}}.feature-detail summary{{display:none}}a{{color:#000}}code{{overflow-wrap:anywhere}}}}
</style></head><body>
<header class="hero"><div class="wrap"><div class="kicker">Feature parity · Living audit</div><h1>{esc(data['meta']['title'])}</h1><p class="hero-sub">先列出 Camera Raw 的官方功能，再标注 RawMaster 的已实现、部分一致、语义差异与缺失。九个面板、原子功能、证据与验收标准共用一份可维护数据源。</p><div class="meta-row"><span class="meta-pill">基线：{esc(data['meta']['cameraRawBaseline'])}</span><span class="meta-pill">RawMaster：{esc(data['meta']['rawMasterSnapshot'])}</span><span class="meta-pill">审计：{esc(data['meta']['reportDate'])}</span></div><div class="actions"><a class="button" href="#matrix">查看逐项清单</a><a class="button secondary" href="feature-matrix.json" download>下载功能 JSON</a><a class="button secondary" href="performance-report.html">性能报告</a><button class="secondary" id="printReport" type="button">打印 / 存为 PDF</button></div></div></header>
<main class="wrap">
<section class="summary-grid" aria-label="总体统计"><div class="summary-card"><strong>{total}</strong><span>Camera Raw 原子对照项</span></div><div class="summary-card aligned"><strong>{counts['aligned']}</strong><span>已具备 · {pct:.1f}%</span></div><div class="summary-card partial"><strong>{counts['partial']}</strong><span>部分一致</span></div><div class="summary-card different"><strong>{counts['different']}</strong><span>有差异</span></div><div class="summary-card missing"><strong>{counts['missing']}</strong><span>缺失 · 待处理合计 {gaps}</span></div></section>
<div class="notice"><strong>判读边界：</strong>{esc(data['meta']['caveat'])} 本轮不是 Adobe 像素级对照测试；所有代码引用都指向当前工作区快照，后续行号变化时应更新 JSON。</div>
<div class="section-title"><div><h2>九面板总览</h2></div><p>点击面板跳转。建议优先处理 P0（{priority_gaps['P0']} 项未完全具备），再处理 P1（{priority_gaps['P1']} 项）与 P2（{priority_gaps['P2']} 项）。</p></div>
<nav class="panel-cards">{panel_cards}</nav>
<div class="conclusions" style="margin-top:14px">{open_features}</div>
<div class="toolbar" id="matrix"><div class="wrap"><div class="toolbar-inner"><input class="search" id="search" type="search" placeholder="搜索功能、差异、代码或验收标准…" aria-label="搜索功能"><select id="statusFilter" aria-label="按状态筛选"><option value="all">全部状态</option>{''.join(f'<option value="{s}">{esc(data["statuses"][s])}</option>' for s in STATUSES)}</select><label class="check"><input id="gapsOnly" type="checkbox">仅看未完全具备</label><button id="expandAll" type="button">展开当前证据</button><button id="exportCsv" type="button">导出当前 CSV</button><button id="resetFilters" type="button">重置</button><span class="result-count" id="resultCount"></span></div><nav class="panel-nav">{panel_nav}</nav></div></div>
{''.join(panel_section(p, features, data) for p in data['panels'])}
<div class="section-title"><div><h2>RawMaster 自有扩展</h2></div><p>这些能力不计入 Camera Raw 对照项，也不因“超出基线”而抵消缺失项。</p></div><section class="extras-grid">{extras}</section>
<div class="section-title"><div><h2>待实机复核，不计入 {total} 项统计</h2></div><p>没有足够当前官方证据的项目保持开放，避免把 Lightroom 功能或旧版界面误写成 Camera Raw 19.0 的确定缺口。</p></div><section class="backlog-list">{backlog}</section>
<section id="development-plan"><div class="section-title"><div><h2>项目初始工作量估算</h2></div><p>以下为九个面板从基础建设到发布验证的原始规划。当前仍需补齐的 {gaps} 个功能在上方逐项列出。</p></div><div class="notice"><strong>目标与边界：</strong>{esc(plan['target'])}</div><div class="conclusions"><article class="conclusion"><h3>{plan['estimate']['personWeeks'][0]}–{plan['estimate']['personWeeks'][1]} 人周</h3><p>功能完整可用的总工作量，含共用基础、局部调整和发布硬化。</p></article><article class="conclusion"><h3>12–16 个月</h3><p>{esc(plan['estimate']['calendar'])}</p></article><article class="conclusion"><h3>推荐团队</h3><p>{esc(plan['estimate']['recommendedTeam'])}</p></article><article class="conclusion"><h3>估算置信度：中低</h3><p>{esc(plan['estimate']['confidence'])}</p></article></div><div class="notice" style="margin-top:14px"><strong>不包含：</strong>{esc(plan['estimate']['excluded'])}</div>
<div class="section-title"><div><h2>工作分解与依赖</h2></div><p>人周是工作量，不是顺序日历；WP1–WP7 可在接口冻结后并行，WP8 贯穿全程。</p></div><div class="backlog-list">{workstreams}</div>
<div class="section-title"><div><h2>阶段路线与 Go / No-Go</h2></div><p>先消除高风险技术不确定性，再扩大 UI 和算子开发；各阶段有重叠，不应把时长直接相加。</p></div><div class="extras-grid">{phases}</div>
<div class="section-title"><div><h2>主要风险与应对</h2></div><p>任何高风险项未通过原型验证，都应调整方案或范围，而不是用不可维护的占位控件赶进度。</p></div><div class="backlog-list">{risks}</div>
<div class="section-title"><div><h2>功能关闭的统一门禁</h2></div><p>所有面板和局部能力共用以下验收条件。</p></div><div class="notice"><ul>{gates}</ul></div></section>
<section class="maintenance" id="maintenance"><h2>长期维护与研发门禁</h2><p><code>feature-matrix.json</code> 是唯一事实源；HTML 由脚本生成，禁止只改 HTML。每次 Camera Raw 版本升级、RawMaster 面板/配方/渲染变更或验收完成时，都应更新对应稳定 ID，而不是新增同义项。</p><div class="maintenance-grid"><div class="maintenance-step"><strong>01 · 更新基线</strong>核对 Adobe 当前手册与 Release Notes；将实机差异放入 verificationBacklog，确认后再转为 feature。</div><div class="maintenance-step"><strong>02 · 更新实现</strong>修改 status、rawMaster、difference、codeRefs、priority 与 acceptance；保留稳定 ID 和历史语义。</div><div class="maintenance-step"><strong>03 · 构建校验</strong>脚本检查必填字段、重复 ID、官方来源、本地配图、代码文件及行号，并重新计算所有统计。</div><div class="maintenance-step"><strong>04 · 验收后关闭</strong>除静态代码外，还需通过预览、保存/重开、撤销/重做、导出和代表性图像测试；像素等价另建参考图门禁。</div></div><code class="command">python3 docs/research/camera-raw-parity/build_report.py\npython3 docs/research/camera-raw-parity/build_report.py --check</code><div class="rules"><div><h3>状态规则</h3><ul><li><strong>已具备：</strong>主要控件和链路存在；仍不自动等于 Adobe 算法等价。</li><li><strong>部分一致：</strong>有可用入口，但子参数、模式或关键交互不完整。</li><li><strong>有差异：</strong>存在明确范围、单位、色域或处理语义冲突。</li><li><strong>缺失：</strong>当前面板、配方与渲染链路均无对应能力。</li></ul></div><div><h3>建议提交门禁</h3><ul><li>将 <code>--check</code> 纳入文档/研发 CI，防止 JSON 与 HTML 漂移。</li><li>功能 PR 必须更新对应功能 ID；代码移动导致行号变化时同步更新引用。</li><li>“完成”必须附自动化测试或实机记录，不能只凭 UI 出现滑杆。</li><li>同图视觉一致性另需 ACR 参考输出、色彩管理与容差，不在本静态报告中虚构。</li></ul></div></div></section>
</main><footer class="wrap">{esc(data['meta']['method'])} · 范围：{esc(data['meta']['scope'])}<br>生成日期 {esc(data['meta']['reportDate'])} · Schema v{data['schemaVersion']} · 本页面离线可读，官方链接需联网打开。</footer>
<script id="matrixData" type="application/json">{data_json}</script>
<script>
const DATA=JSON.parse(document.getElementById('matrixData').textContent);
const search=document.getElementById('search'),status=document.getElementById('statusFilter'),gaps=document.getElementById('gapsOnly');
const featureRows=[...document.querySelectorAll('.feature')],detailRows=[...document.querySelectorAll('.feature-detail')];
function applyFilters(){{
 const q=search.value.trim().toLowerCase();let visible=0;
 featureRows.forEach((row,i)=>{{const ok=(!q||row.dataset.search.includes(q))&&(status.value==='all'||row.dataset.status===status.value)&&(!gaps.checked||row.dataset.status!=='aligned');row.hidden=!ok;detailRows[i].hidden=!ok;if(!ok)detailRows[i].querySelector('details').open=false;if(ok)visible++;}});
 document.querySelectorAll('.panel-section').forEach(panel=>{{const count=[...panel.querySelectorAll('.feature')].filter(r=>!r.hidden).length;panel.querySelector('.empty-panel').hidden=count>0;panel.querySelector('.table-wrap').hidden=count===0;}});
 document.getElementById('resultCount').textContent=`显示 ${{visible}} / ${{DATA.features.length}} 项`;
}}
[search,status,gaps].forEach(el=>el.addEventListener(el===search?'input':'change',applyFilters));
document.getElementById('resetFilters').onclick=()=>{{search.value='';status.value='all';gaps.checked=false;applyFilters();}};
document.getElementById('expandAll').onclick=()=>{{const rows=detailRows.filter(r=>!r.hidden);const shouldOpen=rows.some(r=>!r.querySelector('details').open);rows.forEach(r=>r.querySelector('details').open=shouldOpen);}};
document.getElementById('printReport').onclick=()=>{{search.value='';status.value='all';gaps.checked=false;applyFilters();detailRows.forEach(r=>r.querySelector('details').open=true);window.print();}};
document.getElementById('exportCsv').onclick=()=>{{
 const visible=new Set(featureRows.filter(r=>!r.hidden).map(r=>r.id));const quote=v=>'"'+String(v??'').replaceAll('"','""')+'"';
 const rows=[['id','panel','group','priority','name','cameraRaw','status','rawMaster','difference','acceptance','officialSources','codeRefs']];
 DATA.features.filter(f=>visible.has(f.id)).forEach(f=>rows.push([f.id,f.panel,f.group,f.priority,f.name,f.cameraRaw,DATA.statuses[f.status],f.rawMaster,f.difference,f.acceptance,f.sources.map(s=>DATA.sources[s].url).join(' | '),f.codeRefs.join(' | ')]));
 const blob=new Blob(['\ufeff'+rows.map(r=>r.map(quote).join(',')).join('\\r\\n')],{{type:'text/csv;charset=utf-8'}});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='camera-raw-rawmaster-parity.csv';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000);
}};
applyFilters();
</script></body></html>'''


def main() -> int:
    parser=argparse.ArgumentParser()
    parser.add_argument('--check',action='store_true',help='Validate and fail if index.html is stale')
    args=parser.parse_args()
    data=load_data()
    validate(data)
    output=render(data)
    if args.check:
        if not OUT_PATH.is_file() or OUT_PATH.read_text(encoding='utf-8') != output:
            print(f'STALE: {OUT_PATH} — run {Path(__file__).name} without --check',file=sys.stderr)
            return 1
        print(f'OK: {len(data["features"])} features; report valid and up to date')
        return 0
    OUT_PATH.write_text(output,encoding='utf-8')
    counts=Counter(f['status'] for f in data['features'])
    print(f'Wrote {OUT_PATH} ({len(output):,} chars); {len(data["features"])} features; {dict(counts)}')
    return 0

if __name__=='__main__':
    raise SystemExit(main())
