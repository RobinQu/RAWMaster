#!/usr/bin/env python3
"""Build an evidence-preserving RAW performance report from actual JSON measurements.

This report deliberately does not declare cross-application parity while timing boundaries differ.
"""
from __future__ import annotations
import argparse
import hashlib
import html
import math
import sys
import json
import statistics
import zipfile
from pathlib import Path
from performance_controls import assemble, compositor_measurements, matched_readback, panel_readback, panel_schedule, readback_repeatability, render_controls as control_section, stats
from paired_photo_operator_report import MANIFEST, panel_photo_operators, validated_rows

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT_JSON = HERE / 'performance-data.json'
OUT_HTML = HERE / 'performance-report.html'


HISTORY = HERE / 'evidence/history'
HISTORICAL_INPUTS = json.loads((HISTORY / 'manifest.json').read_text())


def archived(rel: str) -> str:
    return str((HISTORY / HISTORICAL_INPUTS[rel]).relative_to(ROOT))


def photo_build_history():
    evidence = HERE / 'evidence'
    manifest = json.loads(MANIFEST.read_bytes())
    sources = [(path.name, json.loads(path.read_bytes())) for path in
               [evidence / 'rawmaster-photo-operators-initial-v2.json'] if path.is_file()]
    for path in sorted(HISTORY.glob('release-background-*.zip')):
        with zipfile.ZipFile(path) as archive:
            if 'photo-operators-v2.json' in archive.namelist():
                sources.append((str(path.relative_to(evidence)), json.loads(archive.read('photo-operators-v2.json'))))
    current = evidence / 'rawmaster-photo-operators-v2.json'
    sources.append((current.name, json.loads(current.read_bytes())))
    out = []
    for name, raw in sources:
        rows = validated_rows(raw, manifest, 'RAWMaster')
        if any(row['status'] != 'measured' for row in rows.values()):
            continue
        out.append({'evidence':name, 'binarySHA256':raw['binarySHA256'], 'recordedAt':raw['recordedAt'],
                    'first':stats([ms for row in rows.values() for ms in row['initial']['first']]),
                    'final':stats([ms for row in rows.values() for ms in row['initial']['final']])})
    return sorted(out, key=lambda row:row['recordedAt'])


def read(rel: str) -> dict:
    return json.loads((ROOT / archived(rel)).read_text(encoding='utf-8'))


def exists(rel: str) -> bool:
    return rel in HISTORICAL_INPUTS and (ROOT / archived(rel)).is_file()


def metric(values, boundary, source):
    values = [float(v) for v in values if type(v) in (int, float) and math.isfinite(v) and v > 0]
    if not values:
        return None
    ordered = sorted(values)
    p95 = ordered[math.ceil(len(ordered) * 0.95) - 1] if len(ordered) > 1 else None
    return {'count':len(values),'medianMs':statistics.median(values),'p95Ms':p95,'maxMs':max(values),'samplesMs':values,'boundary':boundary,'evidence':archived(source) if source in HISTORICAL_INPUTS else source}


def normalize():
    rawmaster = {}
    engine_rel = 'output/performance/refine-saturation-real-raw-20261121/interactive-performance.json'
    if not exists(engine_rel):
        engine_rel = 'output/performance/engine-telemetry-baseline-20261121/interactive-performance.json'
    if not exists(engine_rel):
        engine_rel = 'output/performance/flashraw-interactive-operators-optimized-20261120/interactive-performance.json'
    engine = read(engine_rel)
    for row in engine.get('measurements',[]):
        rawmaster[row['label']] = {
            'interactive': metric(row.get('interactiveMilliseconds',[]),'Engine API return; 2400 px interactive proxy',engine_rel),
            'settled': metric([row.get('settledMilliseconds')],'Engine API return; canonical settled render',engine_rel),
            'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    prewarm = {}
    prewarm_rel = 'output/performance/shader-prewarm-real-raw-20261121/interactive-performance.json'
    if exists(prewarm_rel):
        prewarm_data = read(prewarm_rel)
        for row in prewarm_data.get('measurements',[]):
            prewarm[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'Explicit shader prewarm; Engine API return; not cold',prewarm_rel),
                'settled': metric([row.get('settledMilliseconds')],'Explicit shader prewarm; canonical settled render',prewarm_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    flashraw = {}
    flashraw_rel = 'output/performance/flashraw-shared-base-real-raw-20261121/interactive-performance.json'
    if exists(flashraw_rel):
        flashraw_data = read(flashraw_rel)
        for row in flashraw_data.get('measurements',[]):
            flashraw[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'FlashRaw neutral shared base; Engine API return',flashraw_rel),
                'settled': metric([row.get('settledMilliseconds')],'CIRAW canonical settled render',flashraw_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    ahd = {}
    ahd_rel = 'output/performance/flashraw-ahd-real-raw-20261121/interactive-performance.json'
    if exists(ahd_rel):
        ahd_data = read(ahd_rel)
        for row in ahd_data.get('measurements',[]):
            ahd[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'FlashRaw AHD measurement; Engine API return',ahd_rel),
                'settled': metric([row.get('settledMilliseconds')],'CIRAW canonical settled render',ahd_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    canonical_flashraw = {}
    canonical_flashraw_rel = 'output/performance/flashraw-canonical-all-operations-20261122/interactive-performance.json'
    if exists(canonical_flashraw_rel):
        canonical_data = read(canonical_flashraw_rel)
        for row in canonical_data.get('measurements',[]):
            canonical_flashraw[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'FlashRaw proxy; Engine API return',canonical_flashraw_rel),
                'settled': metric([row.get('settledMilliseconds')],'FlashRaw supplied canonical; experimental opt-in',canonical_flashraw_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    cached_flashraw = {}
    cached_flashraw_rel = 'output/performance/flashraw-canonical-cached-20261122/interactive-performance.json'
    if exists(cached_flashraw_rel):
        cached_data = read(cached_flashraw_rel)
        for row in cached_data.get('measurements',[]):
            cached_flashraw[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'FlashRaw proxy; cached experiment',cached_flashraw_rel),
                'settled': metric([row.get('settledMilliseconds')],'RawBasePool CV/IOSurface experiment; rejected regression',cached_flashraw_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    mask_validation_baseline = {}
    mask_baseline_rel = 'output/performance/local-point-color-real-raw-20261122/interactive-performance.json'
    if exists(mask_baseline_rel):
        for row in read(mask_baseline_rel).get('measurements',[]):
            mask_validation_baseline[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'Before interactive mask finite-validation elimination',mask_baseline_rel),
                'settled': metric([row.get('settledMilliseconds')],'FlashRaw canonical; unchanged operator validation',mask_baseline_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    direct_cache = {}
    direct_cache_rel = 'output/performance/point-curve-targeted-release-gate-repeat-20261122/interactive-performance.json'
    cache_stats = {}
    if exists(direct_cache_rel):
        direct_data = read(direct_cache_rel)
        cache_stats = direct_data.get('flashRawTextureCache',{})
        for row in direct_data.get('measurements',[]):
            direct_cache[row['label']] = {
                'interactive': metric(row.get('interactiveMilliseconds',[]),'FlashRaw proxy; direct texture cache; deferred interactive mask validation',direct_cache_rel),
                'settled': metric([row.get('settledMilliseconds')],'FlashRaw canonical with direct MTL texture cache and operator validation',direct_cache_rel),
                'p99ChannelError': row.get('p99ChannelError'), 'maximumChannelError': row.get('maximumChannelError')}
    canvas_rel = 'output/performance/editing-workspace-flashraw-20261121/editing-interaction-performance.json'
    canvas = read(canvas_rel)
    canvas_boundary = canvas.get('measurementBoundary','Canvas draw return')
    canvas_rows = {}
    for name in ('exposure','color','texture','clarity','compound'):
        row = canvas.get(name,{})
        canvas_rows[name] = {'interactive':metric(row.get('interactive',{}).get('samplesMs',[]),canvas_boundary,canvas_rel),
            'settled':metric(row.get('settledAfterGesture',{}).get('samplesMs',[]),'Gesture end to settled AppKit canvas draw return',canvas_rel)}
    filter_rel = 'output/performance/filter-canvas-final-20261121-v3/editing-interaction-performance.json'
    filter_data = read(filter_rel)
    filter_boundary = filter_data.get('measurementBoundary','Canvas draw return')
    filter_rows = {}
    for name in ('filterLook','filterIntensity','filterCompound'):
        filter_rows[name] = {'interactive':metric(filter_data.get(name,{}).get('interactive',{}).get('samplesMs',[]),filter_boundary,filter_rel)}
    lf_rel = 'output/lightflow-research/same-size-runtime.json'
    lf = read(lf_rel)
    lightflow = {}
    for row in lf.get('measurements',[]):
        label = row['operation']
        key = next((k for k in ('exposure','texture','clarity','dehaze') if label.startswith(k)),label)
        lightflow.setdefault(key,[]).append(row['frameMs'])
    lightflow = {k:metric(v,'LightFlow frame event after GPU idle; programmatic edit state',lf_rel) for k,v in lightflow.items()}
    acr_rel = 'output/performance/acr-baseline/baseline.json'
    acr = read(acr_rel)
    camera_raw = {}
    for row in acr.get('measurements',[]):
        label = row['operation']
        key = next((k for k in ('exposure','clarity','dehaze') if label.lower().startswith(k.lower())),label)
        camera_raw.setdefault(key, []).append(row.get('principalCanvasChangeMilliseconds'))
    camera_raw = {key: metric(values, 'AXValue edit to principal canvas mean RGB change; ScreenCaptureKit 60 Hz', acr_rel)
                  for key, values in camera_raw.items()}
    stage_groups = {}
    for row in engine.get('engineStages',[]):
        key = (row['operation'],row['stage'],row['boundary'],int(row.get('pixelCount',0)))
        stage_groups.setdefault(key,[]).append(row['durationMilliseconds'])
    engine_stages = [
        {'operation':key[0],'stage':key[1],'boundary':key[2],'pixelCount':key[3],
         'timing':metric(values,key[2],engine_rel)}
        for key,values in sorted(stage_groups.items())
    ]
    parity_rel = 'output/performance/flashraw-canonical-parity-upright-20261121/parity.json'
    parity = read(parity_rel) if exists(parity_rel) else {}
    source_sha = canvas.get('sourceSHA256') or engine.get('sourceSHA256')
    return {
        'schemaVersion':2,
        'reportDate':'2026-11-22',
        'status':'measured-with-open-parity-gaps',
        'source':{'sha256':source_sha,'pixelWidth':canvas.get('sourcePixelWidth',9504),'pixelHeight':canvas.get('sourcePixelHeight',6336),'camera':'Sony ILCE-7RM5'},
        'engineStages':engine_stages,
        'flashRawParity':parity,
        'flashRawTextureCache':cache_stats,
        'correctnessGate':{
            'transparentFrameAssertion':'交互与 settled 全透明输出均使性能测试失败',
            'sequenceRegression':'local-point-color → local-light-extended 连续蒙版回归',
            'whiteBoxDebug':'RAWMASTER_INTERACTIVE_DEBUG_ALPHA=1 输出 RAW 基图与 suffix 的 RGBA 均值',
        },
        'applications':{
            'RawMaster 引擎（CIRAW 回退）':{'operations':rawmaster,'boundary':'CIRAW 参数化基图与 canonical API 返回分别报告'},
            'RawMaster 引擎（CIRAW + shader 预热）':{'operations':prewarm,'boundary':'CIRAW 显式预热后的 API 返回；不是 cold 数据'},
            'RawMaster 引擎（FlashRaw 共享基图）':{'operations':flashraw,'boundary':'FlashRaw 中性基图交互；CIRAW canonical settled'},
            'RawMaster 引擎（FlashRaw canonical 实验）':{'operations':canonical_flashraw,'boundary':'FlashRaw 代理与 supplied canonical；显式实验开关'},
            'RawMaster 引擎（FlashRaw 直接纹理缓存）':{'operations':direct_cache,'boundary':f'保留 MTL 纹理身份；{cache_stats.get("fills",0)} 次 fill、{cache_stats.get("hits",0)} 次 hit，关闭后释放；交互蒙版延迟校验'},
            'RawMaster 引擎（蒙版交互校验优化前）':{'operations':mask_validation_baseline,'boundary':'局部点颜色融合 GPU 算子；交互仍执行完整有限值校验'},
            'RawMaster 引擎（RawBasePool 回退实验）':{'operations':cached_flashraw,'boundary':'CV/IOSurface 缓存实验；性能回退，代码未采用'},
            'RawMaster 引擎（FlashRaw AHD 对照）':{'operations':ahd,'boundary':'AHD 测量；误差未降低，未采用为默认值'},
            'RawMaster 真实画布':{'operations':canvas_rows,'boundary':canvas_boundary},
            'RawMaster 滤镜画布':{'operations':filter_rows,'boundary':filter_boundary},
            'LightFlow':{'operations':{k:{'interactive':v} for k,v in lightflow.items()},'boundary':lf.get('method')},
            'Camera Raw 19.0':{'operations':{k:{'interactive':v} for k,v in camera_raw.items()},'boundary':acr.get('method')},
        },
        'limitations':[
            '主表的三种终点分别是引擎或工具结果、交互输出和 Adobe 文档打开。屏幕表另列三方各自从哪一种输入开始计时。',
            '历史 Adobe 基线每个控件只有一次观测。新采集的记录单列其计时边界和像素验证。',
            '每行记录该原片是否适用、对方是否提供同义操作，以及实测是否得到可重复的图像或界面变化。',
            '历史样本中的 FlashRaw 双线性代理与 CIRAW 高质量输出有明显通道差。原生 FlashRaw 的各项像素复核使用相应版本的配方和解码器。',
            '首次请求、连续新值与重复已用参数分别列出。首次请求中的各个档位只有一个样本，汇总分位数描述的是固定的整组工作负载。'
        ],
        'parityGate':{'status':'not-qualified','required':'完整验收还需要同一输入至画面显示的计时边界，以及未覆盖项目的冷路径、暖路径和图像正确性记录。'}
    }


def fmt(value):
    if value is None:
        return '未测量'
    tail = f" · p95 {value['p95Ms']:.2f}" if value['p95Ms'] is not None else ''
    return f"{value['medianMs']:.2f} ms<br><small>n={value['count']}{tail} · max {value['maxMs']:.2f}</small>"


def render(data):
    cards = []
    for app, block in data['applications'].items():
        operations = block['operations']
        cards.append(f'<article><h3>{html.escape(app)}</h3><strong>{len(operations)}</strong><span>已有操作类别</span><p>{html.escape(block["boundary"])}</p></article>')
    sections = []
    for app, block in data['applications'].items():
        rows = []
        for operation, phases in block['operations'].items():
            cells = ''.join(f'<td>{fmt(phases.get(phase))}</td>' for phase in ('interactive','settled'))
            error = ''
            if phases.get('p99ChannelError') is not None:
                error = f"<br><small>交互/settled p99 通道差 {html.escape(str(phases['p99ChannelError']))}/255</small>"
            rows.append(f'<tr><th>{html.escape(operation)}{error}</th>{cells}</tr>')
        evidence = sorted({phase['evidence'] for op in block['operations'].values() for phase in op.values() if isinstance(phase, dict) and phase.get('evidence')})
        evidence_html = '<ul>' + ''.join(f'<li><a href="../../../{html.escape(path)}">{html.escape(path)}</a></li>' for path in evidence) + '</ul>'
        sections.append(f'<section><h2>{html.escape(app)}</h2><p>{html.escape(block["boundary"])}</p><div class="scroll"><table><thead><tr><th>操作</th><th>交互 / 帧</th><th>Settled / Canonical</th></tr></thead><tbody>{"".join(rows)}</tbody></table></div><details><summary>原始证据文件</summary>{evidence_html}</details></section>')
    stage_rows = ''.join(
        f'<tr><th>{html.escape(row["operation"])}<br><small>{html.escape(row["stage"])}</small></th>'
        f'<td>{html.escape(row["boundary"])}</td><td>{row["pixelCount"]/1_000_000:.3f} MP</td><td>{fmt(row["timing"])}</td></tr>'
        for row in data.get('engineStages',[])
    )
    stage_section = ''
    if stage_rows:
        stage_section = f'<section><h2>RawMaster 白盒阶段</h2><p>阶段边界独立展示；图构建时间不能当作 GPU 完成时间。蒙版阶段包含最终有限值校验所强制执行的完整上游子图。</p><div class="scroll"><table><thead><tr><th>操作 / 阶段</th><th>边界</th><th>工作量</th><th>耗时</th></tr></thead><tbody>{stage_rows}</tbody></table></div></section>'
    gate=data['correctnessGate']
    correctness_section=f'<section><h2>连续操作正确性门禁</h2><ul><li>{html.escape(gate["transparentFrameAssertion"])}</li><li>{html.escape(gate["sequenceRegression"])}</li><li><code>{html.escape(gate["whiteBoxDebug"])}</code></li></ul><p>门禁存在不等于所有批次已通过；每个操作仍需核对 p99 与原始证据。</p></section>'
    parity_section = ''
    parity = data.get('flashRawParity',{})
    if parity:
        parity_section = f'''<section><h2>FlashRaw 同核心 canonical 对照</h2><p>实验性 suppliedRawBase 入口：代理与 FlashRaw canonical 的 p99 通道差 <strong>{html.escape(str(parity['proxyFlashRawCanonicalP99']))}/255</strong>；相对 CIRAW canonical 为 <strong>{html.escape(str(parity['proxyCIRAWCanonicalP99']))}/255</strong>。此处记录旧版基线。新版 RAW 的解码选择和实测条件见上方实验记录。</p><div style="display:grid;grid-template-columns:1fr 1fr;gap:12px"><figure><img src="assets/history-proxy.jpg" style="width:100%;height:auto"><figcaption>FlashRaw 交互代理</figcaption></figure><figure><img src="assets/history-flash-canonical.jpg" style="width:100%;height:auto"><figcaption>FlashRaw supplied canonical</figcaption></figure></div><a href="evidence/history/parity.json">原始一致性证据</a></section>'''
    return f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>真实 RAW 图像处理性能报告</title><style>
:root{{--ink:#17221f;--muted:#64716b;--paper:#f3f5f1;--line:#d9e0da;--green:#14755a;--amber:#9a5b00}}*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:14px/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif}}.wrap{{width:min(1280px,calc(100% - 36px));margin:auto}}header{{background:#14241e;color:white;padding:44px 0}}h1{{font-size:38px;line-height:1.2;margin:8px 0 16px}}h2{{margin:0 0 8px}}header p{{color:#d3ded8;max-width:900px}}.badge{{color:#c1f67b;text-transform:uppercase;letter-spacing:.12em;font-size:11px}}.notice{{background:#fff5df;border-left:4px solid var(--amber);padding:14px 17px;margin:20px 0;border-radius:0 8px 8px 0}}.cards{{display:grid;grid-template-columns:repeat(5,1fr);gap:10px}}article,section{{background:white;border:1px solid var(--line);border-radius:12px}}article{{padding:15px}}article strong{{font-size:28px;display:block;color:var(--green)}}article span,article p,section p,small{{color:var(--muted)}}article p{{font-size:11px}}section{{padding:20px;margin:18px 0}}table{{width:100%;border-collapse:collapse}}th,td{{text-align:left;border-top:1px solid var(--line);padding:11px;vertical-align:top}}thead th{{border:0;color:var(--muted);font-size:11px}}td{{font-variant-numeric:tabular-nums}}ul{{color:var(--muted)}}a{{color:var(--green);overflow-wrap:anywhere}}.scroll{{overflow:auto}}.filters{{display:flex;align-items:center;gap:15px;flex-wrap:wrap;padding:12px 0}}.filters label{{display:flex;align-items:center;gap:6px}}.filters input,.filters select{{font:inherit;border:1px solid var(--line);border-radius:5px;background:white;color:var(--ink);padding:5px 9px}}[hidden]{{display:none!important}}header code{{overflow-wrap:anywhere}}summary{{cursor:pointer;font-weight:600;margin:8px 0}}#controls th:first-child{{min-width:155px}}.muted{{color:var(--muted)}}footer{{padding:15px 0 35px;color:var(--muted)}}@media(max-width:900px){{.cards{{grid-template-columns:1fr 1fr}}}}@media print{{body{{background:white}}.wrap{{width:100%}}header{{background:white;color:black;padding:10px 0}}header p{{color:#333}}section,article{{break-inside:avoid}}}}
</style></head><body><header><div class="wrap"><h1>LightFlow / RawMaster / Camera Raw<br>图像处理与渲染性能报告</h1><p>Sony 实拍 RAW 为 {data['source']['pixelWidth']} × {data['source']['pixelHeight']} 像素。SHA-256 <code>{html.escape(str(data['source']['sha256']))}</code>。每个控件的测量边界和原始样本可在下表核对。</p></div></header><main class="wrap"><div class="notice"><strong>三方同水位验收尚未通过。</strong>主表分别记录 LightFlow 的 GPU 完成、RAWMaster 的交互帧或分析结果、Camera Raw 的全尺寸文档打开。双引擎对照另以同一份 2400 × 1600 的 sRGB 输出缓冲区作为终点。</div>{control_section(data)}<details><summary>展开历次引擎实验、组合配方和旧版画布记录</summary><div class="cards">{''.join(cards)}</div>{''.join(sections)}</details>{correctness_section}{stage_section}{parity_section}<div class="notice"><ul>{''.join(f'<li>{html.escape(x)}</li>' for x in data['limitations'])}</ul><p>{html.escape(data['parityGate']['required'])}</p></div></main><footer class="wrap">生成日期 {data['reportDate']} · <a href="performance-data.json">机器可读数据</a> · 原始文件链接指向本工作区证据。</footer></body></html>'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Verify committed outputs without changing them')
    parser.add_argument('--require-complete', action='store_true', help='Require closed collection sessions for a release')
    args = parser.parse_args()
    data = normalize()
    sha = data['source']['sha256']
    data['controlMatrix'] = assemble(sha)
    if (HERE / 'evidence/lightflow-compositor.json').is_file():
        data['lightflowCompositor'] = compositor_measurements(sha, data['controlMatrix'])
    if all((HERE / 'evidence' / name).is_file() for name in ('lightflow-display-readback.json','rawmaster-display-readback.json')):
        data['matchedReadback'] = matched_readback(sha)
    if all((HERE / 'evidence' / name).is_file() for name in ('lightflow-panel-readback.json','rawmaster-panel-readback.json')):
        data['panelReadback'] = panel_readback(sha)
    if all((HERE / 'evidence' / name).is_file() for name in ('lightflow-panel-schedule.json','rawmaster-panel-schedule.json')):
        data['panelSchedule'] = panel_schedule(sha)
    if all((HERE / 'evidence' / name).is_file() for name in ('lightflow-photo-operators-v2.json','rawmaster-photo-operators-v2.json')):
        data['pairedPhotoOperators'] = panel_photo_operators(sha)
        data['photoBuildHistory'] = photo_build_history()
    if (HERE / 'evidence/interactive-merged-readback-repeatability.json').is_file():
        data['readbackRepeatability'] = readback_repeatability(sha)
    if args.require_complete:
        for filename in ('camera-raw-open.json', 'camera-raw-points.json', 'camera-raw-spatial.json', 'camera-raw-supplement.json',
                         'camera-raw-native-ca.json', 'camera-raw-native-pixels.json', 'camera-raw-grading-mask.json', 'camera-raw-lens-blur-native.json',
                         'camera-raw-profile-match.json', 'camera-raw-hsl-bands.json'):
            capture = HERE / 'evidence' / filename
            if not capture.is_file() or not json.loads(capture.read_text()).get('finishedAt'):
                raise SystemExit(f'Adobe capture is missing or still open: {filename}')
    bench = json.loads((HERE / 'evidence/engine-optimization.json').read_text())
    if bench['sourceSHA256'] != sha or bench['viewport'] != [2400, 1600]:
        raise ValueError('Engine optimization source or viewport mismatch')
    data['engineOptimization'] = {
        k: [statistics.median(v[phase]['settledTrialsMs']) for phase in ('before', 'after')]
        for k, v in bench['metrics'].items()
    }
    app_validation = json.loads((HERE / 'evidence/interactive-validation.json').read_text())
    if app_validation['sourceSHA256'] != sha or app_validation['sourceSHA256After'] != sha:
        raise ValueError('Interactive optimization fixture mismatch')
    data['interactiveValidation'] = {r['operation']:[r['beforeMedianMs'],r['afterMedianMs']] for r in app_validation['cases']}
    if (HERE / 'evidence/rawmaster-settled-stages-after-v2.json').is_file():
        from settled_stage_report import read_capture
        reference = HERE / 'evidence/rawmaster-photo-operators-v2.json'
        before = read_capture('serial-control', reference, True)
        after = read_capture('after', reference, False)
        if before['binary'] != after['binary'] or before['gpu'] != after['gpu'] or before['os'] != after['os']:
            raise ValueError('Different test binaries or devices in the native stage profile')
        data['nativeSettleProfile'] = {name:{k:row[k] for k in ('median','finite','scratch','peak','binary')}
                                       for name,row in (('before',before),('after',after))}
    hsl_path = HERE / 'evidence/camera-raw-hsl-bands.json'
    if hsl_path.is_file():
        from hsl_band_witness import verify_report as verify_hsl
        hsl = json.loads(hsl_path.read_bytes())
        if hsl['sourceSHA256'] != sha:
            raise ValueError('Different Adobe RAW in the eight-color measurements')
        data['adobeHSL'] = verify_hsl(hsl, HERE / 'evidence/camera-raw-hsl-bands-xmp.zip', HERE / 'evidence/camera-raw-open.json')
    guide_file = HERE / 'evidence/native-dehaze-guide.json'
    if guide_file.is_file():
        guide = json.loads(guide_file.read_bytes())
        runs = guide['shipping']['summary']
        digests = [tuple(r['settledDisplaySHA256']) for r in runs.values()]
        if (guide['source']['sourceSHA256'] != sha or len(runs) != 4 or len(set(digests)) != 1
                or len(set(digests[0])) != 2 or any(not r['verifiedAgainstArchivedPhotoBuffers'] for r in runs.values())
                or not guide['shipping']['qualifiedComparisons']['allFinalDisplayBytesEqual']):
            raise ValueError('Missing independent native dehaze output checks')
        data['nativeDehazeGuide'] = {'order':guide['shipping']['chronologicalRunOrder'], 'runs':{
            key:{'settledMs':r['settledRequestToCPUDisplayMs'], 'peakBytes':r['processPeakPhysicalFootprintBytes']}
            for key,r in runs.items()}}
    detail = HERE / 'evidence/raw-details.json'
    if detail.is_file():
        data['rawDetails'] = [{k:r[k] for k in ('mode','exportMs')} for r in json.loads(detail.read_text())['rows']]
    neural = HERE / 'evidence/raw9-denoise.json'
    if neural.is_file():
        v = json.loads(neural.read_text())
        if v['sha256'] != sha or v['export']['bitDepth'] != 16 or [v['export']['width'],v['export']['height']] != [9504,6336]:
            raise ValueError('RAW 9 source or full-size TIFF mismatch')
        requests = {r['input']:r for r in v['requests']}
        if (requests['amount0']['sampledSRGBSHA256'] != requests['amount0-replay']['sampledSRGBSHA256']
            or requests['original']['sampledSRGBSHA256'] != requests['disabled']['sampledSRGBSHA256']
            or requests['amount0']['sampledSRGBSHA256'] == requests['amount100']['sampledSRGBSHA256']):
            raise ValueError('Missing RAW 9 changed and restored pixels')
        prior = json.loads((HERE / 'evidence/history/raw9-denoise-before-cache.json').read_text())
        if v.get('sourceSHA256After') != sha or prior['export']['sha256'] != v['export']['sha256']:
            raise ValueError('RAW 9 regression changed input or exported pixels')
        data['neuralDenoise'] = {'model':v['model'], 'prepareMs':v['resourcePrepareMs'], 'requests':{k:r['previewMs'] for k,r in requests.items()},
            'exportMs':v['export']['elapsedMs'],'peakRSS':v['processPeakRSSBytes'],
            'priorRepeatedMs':next(r['previewMs'] for r in prior['requests'] if r['input']=='amount0-replay')}
    scene = HERE / 'evidence/scene-depth.json'
    if scene.is_file():
        v = json.loads(scene.read_text())
        if v["sourceSHA256"] != sha or v["sourceSHA256After"] != sha:
            raise ValueError("Scene depth provenance mismatch")
        data["sceneDepth"] = {"coldMs":v["coldMs"],"warm":stats(v["warmMs"]),"model":v["model"]}
    lut = HERE / 'evidence/lut-import.json'
    if lut.is_file():
        records = json.loads(lut.read_text())['rows']
        data['lutImport'] = {row['file']: stats(row['samplesMs']) for row in records}
    photo = HERE / 'evidence/photo-denoise.json'
    analysis = HERE / 'evidence/photo-denoise-comparison.json'
    if photo.is_file() and analysis.is_file():
        denoise = json.loads(photo.read_text())
        latency = json.loads(analysis.read_text())
        rows = denoise['results']
        if (len(rows) != len({(Path(r['source']).suffix.lower(),r['container']) for r in rows}) or any(r['exportBits'] != 16 for r in rows)
                or denoise['model'] != latency['model'] or denoise['cameraJPEGSHA256'] != latency['cameraJPEGSHA256']
                or not all(v['n'] == 10 for v in latency['warm'].values())):
            raise ValueError('Incompatible source or model in rendered-photo measurements')
        data['photoDenoise'] = {'sources': [{k:r[k] for k in ('source','container','sourceBits','nativePixels','exportMs')} for r in rows],
                                'model':denoise['model'], 'warm':latency['warm'],
                                'interactiveMax':max(r['interactiveVsSettled']['maxRGB8'] for r in rows),
                                'exportMax':max(r['settledVsTIFF16']['maxRGB8'] for r in rows)}
    enhanced = HERE / 'evidence/super-resolution-learned-full.json'
    adobe_path = HERE / 'evidence/adobe-enhance-baseline.json'
    if adobe_path.is_file():
        adobe = json.loads(adobe_path.read_text())
        repeat = adobe['untouchedPixelRepeat']
        if (adobe['state'] != 'baseline' or adobe['sourceSHA256'] != sha or adobe['bits'] != 16
                or adobe['actualPixels'] != adobe['sourcePixels'] or not repeat['identical'] or repeat['documentOpens'] < 2
                or repeat['rgb16SHA256'] != adobe['nativeRGB16']['rgb16SHA256']
                or repeat['rgb16Bytes'] != adobe['actualPixels'][0] * adobe['actualPixels'][1] * 6):
            raise ValueError('Adobe full-resolution reference failed independent RGB16 verification')
        data['adobeReference'] = {key:adobe[key] for key in ('photoshop','openMs','saveMs')} | {'rgb16Bytes': repeat['rgb16Bytes']}
    if enhanced.is_file():
        comparison = json.loads(enhanced.read_text())
        frame = comparison['fullDiagnosticFloatTIFF']
        if (comparison['rawSHA256']!=sha or [frame['width'],frame['height']]!=[19008,12672]
                or frame['sampleFormat']!='IEEEFP' or frame['bitsPerChannel']!=16
                or frame['decodedRange']!=comparison['sourceLinearRange']
                or comparison['tiledVsWhole']['maximum']>0):
            raise ValueError('Incompatible native 2× diagnostic frame, dynamic range or tile evidence')
        data['learnedDoubleSize'] = {**frame,'peakRSS':comparison['maxRSSBytes']}
    grouped = HERE / 'evidence/release-operator-regression.json'
    if grouped.is_file():
        compare = json.loads(grouped.read_text())
        if compare['sourceSHA256'] != sha or len(compare['operations']) != compare['operationCount']:
            raise ValueError('Invalid combined operation evidence')
        medians = [r['current']['interactive']['medianMs'] for r in compare['operations']]
        data['groupRegression'] = {'count':len(medians),'medianRange':[min(medians),max(medians)],
            'failures':compare['failures'], 'relativePassed':compare['passed']}
        same_day = HERE / 'evidence/release-operator-same-day.json'
        if same_day.is_file():
            recent = json.loads(same_day.read_text())
            if recent['sourceSHA256'] != sha or recent['operationCount'] != len(medians):
                raise ValueError('Different recent sequence baseline')
            data['groupRegression']['sameDayFailures'] = recent['failures']
        follow = HERE / 'evidence/overlay-regression-check.json'
        if follow.is_file():
            observations = json.loads(follow.read_text())
            if observations['sourceSHA256'] != sha: raise ValueError('Mismatched overlay A/B source')
            data['groupRegression']['targeted'] = observations['focusedTiming']['pairedProcessMedians']
    image_report = HERE / 'evidence/release-image.json'
    if image_report.is_file():
        batch = json.loads(image_report.read_text())
        if len(batch['fixtures']) < 15 or not batch['metrics']:
            raise ValueError('Incomplete background image workload')
        data['backgroundRegression'] = {'fixtures':len(batch['fixtures']), 'status':batch['status'],
            'build':batch['build'], 'imageMetrics':{m['name']:{k:m[k] for k in ('count','p50Milliseconds','p95Milliseconds')} for m in batch['metrics']}}
        prior = json.loads((HERE / 'evidence/history/release-image-before-flashraw.json').read_text())
        prior_cold = next(m for m in prior['metrics'] if m['name'] == 'true_raw_app_cache_cold')
        data['backgroundRegression']['priorColdP95'] = prior_cold['p95Milliseconds']
        bundle = HERE / 'evidence/release-background-results.zip'
        if bundle.is_file():
            with zipfile.ZipFile(bundle) as reports:
                def read_stage(name):
                    return json.loads(reports.read(name + '.json'))
                summary = read_stage('summary')
                binaries = read_stage('test-build')['testBinariesSHA256']
                reference = read_stage('lightflow-comparison')
                controls = read_stage('control-comparison')
                if (read_stage('image') != batch or reference['rawSHA256'] != sha
                        or reference['nativeBinarySHA256'] != binaries['RAWMasterImagingTests']
                        or controls['sourceSHA256'] != sha or summary.get('hostedUI') != 'not-run'):
                    raise ValueError('Background archive has a different input, executable or scope')
                data['backgroundRegression']['suite'] = {
                    'summary':summary, 'binaries':binaries,'archiveSHA256':hashlib.sha256(bundle.read_bytes()).hexdigest(),
                    'measuredControls':controls['measuredCount'], 'combinations':read_stage('interactive-comparison')['operationCount'],
                    'inspectionOperations':read_stage('inspection-comparison')['count'], 'crossEnginePassed':reference['passed'],
                    'runStages':{Path(n).name.removesuffix('.command.json'):read_stage(n.removesuffix('.json'))['status']
                                 for n in sorted(reports.namelist()) if n.endswith('.command.json')},
                }
                data['parityGate']['releaseComparisonFailures'] = reference['failures']
                if 'firstAppearanceMix' in reference:
                    data['parityGate']['firstAppearanceMix'] = reference['firstAppearanceMix']
    ledger = data['controlMatrix']
    data['parityGate']['threeProductProcessingRows'] = ledger['allThreeMeasured']
    data['parityGate']['threeProductScreenRows'] = sum(
        all(row['canvas'].get(product, {}).get('state') == 'measured' for product in ('LightFlow','RAWMaster','Camera Raw'))
        for row in ledger['controls'])
    repeat_archive = HISTORY / 'release-4-5-abba.zip'
    if repeat_archive.is_file():
        from frozen_release_repeats import summarize
        data['frozenReleaseRepeats'] = summarize(repeat_archive, sha)
    package = HERE / 'evidence/local-release-build.json'
    if package.is_file():
        record = json.loads(package.read_bytes())
        suite = data['backgroundRegression']['suite']
        if (record['benchmarkArchiveSHA256'] != suite['archiveSHA256']
                or record['benchmarkTestBinaries']['testBinariesSHA256'] != suite['binaries']
                or record['regressionPassed'] != suite['summary']['passed']
                or record['packageVerification']['exitStatus'] != 0):
            raise ValueError('Application receipt and benchmark evidence are from different releases')
        data['localBuild'] = {'version':record['bundleVersion'], 'appSHA256':record['packageFiles']['app']['sha256']}
    outputs = {OUT_JSON: json.dumps(data, ensure_ascii=False, indent=2) + '\n', OUT_HTML: render(data)}
    for path, expected in outputs.items():
        if args.check:
            if not path.is_file() or path.read_text(encoding='utf-8') != expected:
                raise SystemExit(f'Outdated generated report: {path}')
        else:
            path.write_text(expected, encoding='utf-8')
    print(f"{len(data['controlMatrix']['controls'])} controls · {data['controlMatrix']['coverage']}")


if __name__ == '__main__':
    main()
