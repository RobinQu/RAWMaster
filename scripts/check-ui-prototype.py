#!/usr/bin/env python3
"""Exercise RAWMaster's HTML workbench through its DOM in an isolated Chrome session."""
from argparse import ArgumentParser
from contextlib import suppress
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import os
import shutil
import subprocess
import threading
import uuid

ROOT = Path(__file__).resolve().parents[1]
ENTRY = "docs/ui/prototype/index.html"
EXPORT = "specs/032-export-workspace/prototype.html"


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--editing-only", action="store_true", help="Run the filter and Quick Prompt walkthrough with its setup scenarios.")
    parser.add_argument("--hdr-only", action="store_true", help="Run the Spec 037 darkroom and 032 walkthrough.")
    parser.add_argument("--compatibility-only", action="store_true", help="Run the Spec 038 read-only compatibility graph walkthrough.")
    parser.add_argument("--scene-native-only", action="store_true", help="Walk through the Spec 037 native-review HDR slice.")
    parser.add_argument("--pq-queue-only", action="store_true", help="Walk through the native PQ queue preflight interaction in the workbench.")
    parser.add_argument("--grid-export-only", action="store_true", help="Open 032 directly from the project grid and recover a changed selection.")
    parser.add_argument("--native-graph-only", action="store_true", help="Walk through the editable scene DAG native-review slice.")
    parser.add_argument("--workflow-batch-only", action="store_true", help="Walk the native-template/batch review entry in the workbench.")
    parser.add_argument("--scene-scopes-only", action="store_true", help="Walk through HDR scopes and diagnostics in the native-review prototype.")
    args = parser.parse_args()
    editing_only = args.editing_only
    cli = shutil.which("agent-browser")
    if not cli:
        raise SystemExit("This browser check uses agent-browser. Manual review routes are in docs/ui/coverage.md.")
    session = "rawmaster-ui-" + uuid.uuid4().hex[:12]
    chrome = os.environ.get("RAWMASTER_UI_CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

    def browser(*args):
        result = subprocess.run([cli, "--session", session, *args], capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip())
        return result.stdout.strip()

    helpers = r"""
      const el=(s,r=document)=>r.querySelector(s);
      const all=(s,r=document)=>Array.from(r.querySelectorAll(s));
      const assert=(v,m)=>{if(!v)throw Error(m)};
      const wait=async fn=>{for(let i=0;i<200;i++){if(fn())return;await new Promise(ok=>setTimeout(ok,20));}throw Error('Timed out: '+fn);};
      const tap=(s,r=document)=>{const a=el(s,r);assert(a&&!a.disabled&&a.checkVisibility(),'Unavailable: '+s);a.click();};
      const act=(name,val,root=document)=>{const selector='[data-act="'+name+'"]'+(val==null?'':'[data-val="'+CSS.escape(String(val))+'"]');tap(selector,root);};
      const set=(s,v,r=document)=>{const a=el(s,r);assert(a,'Missing '+s);if(a.type==='checkbox')a.checked=v;else a.value=v;
        a.dispatchEvent(new Event('input',{bubbles:true}));if(a.isConnected)a.dispatchEvent(new Event('change',{bubbles:true}));};
      const hash=async path=>{location.hash=path;await wait(()=>location.hash==='#'+path);await new Promise(ok=>setTimeout(ok,35));};
      const page=async selector=>wait(()=>document.body.dataset.route===(decodeURI(location.hash.slice(1))||'library/project/river')&&el(selector)?.checkVisibility());
      const modal=()=>el('#sheet');
      const pickNode=id=>{
        if(['source','geometry','output'].includes(id)) return tap('[data-dag-node="'+id+'"]');
        act('dag-picker');act('dag-picker-select',id,el('#dag-node-picker'));
      };
      const foldTool=id=>{const button=el('[data-act=canvas-tool-fold][data-val='+id+']');if(button.getAttribute('aria-expanded')!=='true')act('canvas-tool-fold',id);};
      const maskType=type=>{foldTool('mask-types');act('canvas-mask-type',type);};
      const markCenter=()=>{foldTool('remove-more');act('canvas-remove-center');};
      const addNodeMenu=()=>{act('dag-picker');act('dag-picker-command','add',el('#dag-node-picker'));};
      const menuAction=(name,val=null)=>{act('dag-menu');const target=el('[data-act="'+name+'"]',modal()),details=target?.closest('details');if(details&&!details.open)tap('summary',details);act(name,val,modal());};
      const key=(target,k,mod={})=>target.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true,cancelable:true,...mod}));
      const route=async path=>wait(()=>location.hash==='#'+path&&document.querySelector('#workspace'));
    """

    def check_browser_errors():
        errors = json.loads(browser("errors", "--json"))["data"]["errors"]
        if errors:
            raise AssertionError(json.dumps(errors, ensure_ascii=False, indent=2))

    def scenario(title, js):
        if editing_only and "快速 Prompt" not in title and not title.startswith("Node DAG") and title not in {
            "双击入口与本地照片", "标题栏与资料库侧栏开关", "搜索、筛选、多选比较与批量标签",
            "导入、续接、分组、初筛封存与历史恢复", "暗房布局、智能预设与胶片采用", "浮动工具条、邻片、裁切与参考对比", "胶片带对齐、折叠和离线照片", "紧凑示波器、白平衡与蒙版分层",
        }:
            return
        try:
            output = browser("eval", "(async()=>{" + helpers + js + ";return 'PASS';})()")
        except RuntimeError as error:
            state = browser("eval", "({url:location.href, route:document.body.dataset.route, title:document.title, message:document.body.innerText.slice(0,160), heading:document.querySelector('h1')?.textContent, canvasTool:typeof S!=='undefined'&&S.canvasTool?{kind:S.canvasTool.kind,legacy:S.canvasTool.legacy,revisionMatches:JSON.stringify(Studio.edit(S.canvasTool.photo).recipe)===JSON.stringify(S.canvasTool.before),notice:document.querySelector('#notice')?.textContent,invalid:Array.from(document.querySelectorAll('.canvas-tool-dock input:invalid')).map(el=>({name:el.name,key:el.dataset.key,value:el.value,min:el.min,max:el.max,step:el.step}))}:null, dialog:document.querySelector('dialog[open]')?.innerText, filters:document.querySelector('.chips')?.innerText, exportState:{heading:document.querySelector('#export-frame')?.contentDocument?.querySelector('#job-title')?.textContent,open:document.querySelector('#export-frame')?.contentDocument?.querySelector('#job')?.open,result:document.querySelector('#export-frame')?.contentDocument?.querySelector('#job')?.innerText.slice(-1600)}})")
            raise AssertionError(f"{title}\n{state}\n{browser('errors')}\n{error}") from error
        if "PASS" not in output:
            raise AssertionError(title + ": " + output)
        print("✓", title, flush=True)

    handler = partial(QuietHandler, directory=str(ROOT))
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        host = "http://127.0.0.1:" + str(server.server_port) + "/"
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            options = ["--executable-path", chrome] if Path(chrome).exists() else []
            if args.grid_export_only:
                browser(*options, "open", host + ENTRY + "?pqReview=1")
                for theme, width in [("light", "1280"), ("dark", "390")]:
                    browser("set", "viewport", width, "844")
                    scenario("032 网格直达、选区变更与重试 · " + theme, """
                      await hash('settings/general');await page('[name=theme]');set('[name=theme]','""" + theme + """');
                      await hash('library/project/river');await page('.photo-card');
                      if(S.multi)act('multi');act('photo','b1');act('multi');act('photo','r1');
                      const grid=()=>el('.actionbar [data-act=export]'), project=Studio.project('river');
                      const ids=Studio.visible(S.scope).filter(id=>activeIDs().includes(id));
                      assert(ids.length===2&&grid().textContent.includes('批量导出'));
                      Studio.save();grid().click();await page('#export-frame[src]');
                      assert(JSON.stringify(S.delivery.items.map(i=>i.id))===JSON.stringify(ids),'ordered physical selection');
                      const doc=el('#export-frame').contentDocument;await wait(()=>el('#asset-list',doc));
                      act('workflow','library');await page('.photo-card');
                      assert(activeIDs().length===2&&activeBrowser().focus==='r1','return to selection and focus');
                      const old=project.ids.slice();project.ids=old.filter(id=>id!=='r1');
                      grid().focus();grid().click();assert(modal().open&&modal().innerText.includes('请核对选片'));
                      assert(location.hash.includes('library')&&modal().getBoundingClientRect().right<=innerWidth);
                      window.gridReviewIDs=old;
                    """)
                    browser("press", "Escape")
                    scenario("032 核对余下照片并重新导出 · " + theme, """
                      await wait(()=>!modal().open);
                      const grid=()=>el('.actionbar [data-act=export]');
                      assert(document.activeElement?.matches('.photo-card, .actionbar [data-act=export]'),'focus restored to grid');
                      assert(activeIDs().join()==='b1','removed photo must not be replaced');
                      grid().click();await page('#export-frame[src]');assert(S.delivery.items.map(i=>i.id).join()==='b1');
                      Studio.project('river').ids=window.gridReviewIDs;act('workflow','library');await page('.photo-card');
                      el('.photo-card[data-val=b1]').dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:true}));
                      assert(!activeIDs().length&&grid().disabled,'empty selection cannot submit');
                    """)
                check_browser_errors()
                return
            if args.scene_scopes_only:
                browser(*options, "open", host + ENTRY + "?sceneNativeReview=1&scopesNativeReview=1")
                browser("set", "viewport", "1280", "800")
                scenario("037 示波器：阶段、点位、屏幕标线与取消", """
                  await page('.photo-card');act('photo','b1');act('workflow','edit');await page('.inspector-rail');
                  act('edit-tool','basic');await page('.scene-mode-bar');act('scene-mode','hdr');act('scene-review-start',null,modal());
                  const details=()=>el('.scope-native-review');assert(details()&&!details().open);tap('.scope-native-review summary');
                  await wait(()=>details().open);const recipe=JSON.stringify(currentEdit().recipe), h=currentEdit().past.length;
                  act('scene-scope','scene');await wait(()=>el('.scene-axis')?.checkVisibility());assert(el('.scene-scopes').innerText.includes('线性 AP1'));
                  act('scene-pick');const image=el('.edit-image'), box=image.getBoundingClientRect();image.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:box.x+box.width*.35,clientY:box.y+box.height*.6}));
                  assert(el('.scene-scopes').innerText.includes('35%，60%'),'sample stays fixed to image');
                  act('scene-scope','output');const axis=el('.scene-chart-white').getAttribute('d');
                  act('scene-overlay','sensor');act('scene-overlay','target');assert(all('.scene-marks i').length===2);
                  act('scene-open');act('scene-screen','unknown',modal());assert(el('[data-act=scene-overlay][data-val=screen]',modal()).disabled);
                  act('close',null,modal());assert(el('.scene-chart-white').getAttribute('d')===axis);
                  act('scene-pick');key(document.activeElement,'Escape');assert(all('.scene-marks i').length===2);
                  key(document.activeElement,'Escape');assert(!all('.scene-marks i').length);
                  assert(JSON.stringify(currentEdit().recipe)===recipe&&currentEdit().past.length===h,'diagnostics and sample are transient');
                """)
                scopes_evidence = os.environ.get("RAWMASTER_UI_SCOPES_EVIDENCE")
                if scopes_evidence:
                    Path(scopes_evidence).mkdir(parents=True, exist_ok=True)
                    browser("screenshot", str(Path(scopes_evidence) / "scopes-1280.png"))
                browser("set", "viewport", "390", "844")
                scenario("037 示波器：窄窗与原片不可用", """
                  assert(document.documentElement.scrollWidth<=innerWidth,'no horizontal overflow');
                  Studio.asset('b1').online=false;render();
                  assert(el('[data-act=scene-overlay][data-val=sensor]').disabled,'offline is unavailable, not zero');
                """)
                if scopes_evidence:
                    browser("screenshot", str(Path(scopes_evidence) / "scopes-offline-390.png"))
                check_browser_errors()
                return
            if args.workflow_batch_only:
                browser(*options, "open", host + ENTRY + "?batchNativeReview=1")
                browser("set", "viewport", "1280", "800")
                scenario("038 批量：确认前不写入，候选不采用", """
                  await page('.photo-card');act('photo','r1');act('multi');act('photo','b1');
                  const ids=activeIDs(), target=ids.find(id=>id!==activeBrowser().focus), before=JSON.stringify(Studio.edit(target).recipe);
                  act('selection-menu');act('dag-batch-menu',null,modal());act('dag-batch-preflight',null,modal());
                  assert(modal().innerText.includes('只创建候选，不自动采用'));
                  act('close',null,modal());assert(!(Studio.data.dagBatches||[]).length);
                  act('selection-menu');act('dag-batch-menu',null,modal());act('dag-batch-preflight',null,modal());act('dag-batch-start',null,modal());
                  await wait(()=>Studio.data.dagBatches.at(-1)?.running===false);
                  const batch=Studio.data.dagBatches.at(-1), item=batch.items[0];
                  assert(item.state==='done'&&Studio.edit(target).adopted!==item.version&&JSON.stringify(Studio.edit(target).recipe)===before);
                  act('dag-batch-undo',batch.id,modal());assert(item.state==='undone'&&Studio.edit(target).versions.some(v=>v.id===item.version&&v.discarded));
                  act('close',null,modal());assert(JSON.stringify(activeIDs())===JSON.stringify(ids),'selection unchanged');
                """)
                browser("set", "viewport", "390", "844")
                scenario("038 批量：窄窗深色取消、重试及复现冲突", """
                  await hash('settings/general');await page('[name=theme]');set('[name=theme]','dark');
                  await hash('library/project/river');await page('.photo-card');act('photo','r1');act('multi');act('photo','b1');
                  act('selection-menu');act('dag-batch-menu',null,modal());
                  tap('.dag-menu-advanced summary',modal());act('dag-batch-samples','20',modal());
                  S.dagBatchChosen.slice(1,2).forEach(id=>Studio.asset(id).online=false);
                  act('dag-batch-preflight',null,modal());
                  assert(modal().innerText.includes('离线 1')&&modal().getBoundingClientRect().right<=innerWidth,'narrow preflight fits and lists offline');
                  act('dag-batch-start',null,modal());const b=Studio.data.dagBatches.at(-1);
                  act('dag-batch-cancel',b.id,modal());assert(b.items.some(i=>i.state==='done')&&b.items.some(i=>i.state==='cancelled'));
                  act('dag-batch-retry',b.id,modal());await wait(()=>!b.running);
                  assert(b.items.filter(i=>i.state==='done').length===19&&b.items.filter(i=>i.state==='offline').length===1);
                  act('dag-batch-relink',null,modal());act('dag-batch-retry',b.id,modal());await wait(()=>!b.running);
                  assert(b.items.every(i=>i.state==='done'));
                  act('dag-batch-conflict',null,modal());act('dag-batch-undo',b.id,modal());
                  assert(b.items.filter(i=>i.state==='conflict').length===1&&b.items.filter(i=>i.state==='undone').length===19);
                """)
                check_browser_errors()
                return
            if args.native_graph_only:
                browser(*options, "open", host + ENTRY + "?sceneNativeReview=1&graphNativeReview=1")
                browser("set", "viewport", "1440", "900")
                scenario("038 原生评审：HDR 草稿、插入和节点监看", """
                  await page('.photo-card');act('photo','b1');act('workflow','edit');await page('.inspector-rail');
                  act('edit-tool','basic');await page('.scene-mode-bar');act('scene-mode','hdr');act('scene-review-start',null,modal());
                  act('dag-view-toggle');await page('.dag-floating');
                  assert(el('.developed')?.checkVisibility()&&el('.dag-floating').getAttribute('aria-modal')==='false');
                  addNodeMenu();act('dag-add','serial',modal());const node=dagNode().id;
                  set('[name=dagNumber][data-key=ev]',1.25);pickNode('grade');
                  assert(el('[name=dagNumber][data-key=ev]').value==='0','node change does not alter first');
                  const before=JSON.stringify(currentEdit().recipe.dag), history=currentEdit().past.length;
                  menuAction('dag-preview');assert(dagView().target==='grade'&&el('.dag-photo-status').innerText.includes('不用于导出'));
                  pickNode(node);assert(dagView().target==='grade'&&JSON.stringify(currentEdit().recipe.dag)===before);
                  const adopted=currentEdit().adopted, count=currentEdit().versions.length;
                  act('save-version');
                  const saved=currentEdit().versions.find(v=>JSON.stringify(v.recipe.dag)===before);
                  assert(saved&&currentEdit().versions.length===count+1&&currentEdit().adopted===adopted&&dagView().target==='grade','save freezes final graph without adopting or changing monitoring');
                  act('dag-preview-final');assert(currentEdit().past.length===history,'preview only');
                """)
                native_graph_evidence = os.environ.get("RAWMASTER_UI_NATIVE_GRAPH_EVIDENCE")
                if native_graph_evidence:
                    Path(native_graph_evidence).mkdir(parents=True, exist_ok=True)
                    browser("screenshot", str(Path(native_graph_evidence) / "graph-scene-1440.png"))
                scenario("038 原生评审：无效草稿阻止交付，取消后可编辑", """
                  set('[name=dagNumber][data-key=ev]',1.50);
                  const node=dagNode().id, recipe=JSON.stringify(currentEdit().recipe.dag);
                  await wait(()=>!el('[data-act=save-version]').disabled);
                  dagPropose(node,node,'image');assert(el('[data-act=dag-connect-apply]').disabled);
                  assert(el('[data-act=save-version]').disabled,'open connection blocks save');
                  act('workflow','export');assert(!location.hash.includes('export'),'cannot hand off an uncommitted draft');
                  act('dag-connect-cancel');assert(JSON.stringify(currentEdit().recipe.dag)===recipe&&!el('[data-act=save-version]').disabled);
                  act('dag-view-toggle');assert(!el('.dag-floating')&&el('.developed')?.checkVisibility(),'close graph only');
                """)
                for theme in ['light','dark']:
                    browser("set", "viewport", "390", "844")
                    scenario("038 原生评审：窄窗 "+theme+" 取景及退出", """
                      await hash('settings/general');await page('[name=theme]');set('[name=theme]','""" + theme + """');
                      await hash('edit/basic');await page('.scene-mode-bar');act('dag-view-toggle');await page('.dag-viewport');
                      act('dag-fit');const frame=el('.dag-floating').getBoundingClientRect();
                      assert(frame.left>=0&&frame.right<=innerWidth&&el('.dag-viewport').offsetHeight>=240);
                      const bytes=JSON.stringify(currentEdit().recipe.dag);el('.dag-viewport').focus();key(el('.dag-viewport'),'Escape');
                      assert(!el('.dag-floating')&&JSON.stringify(currentEdit().recipe.dag)===bytes&&el('.developed')?.checkVisibility());
                    """)
                    if native_graph_evidence:
                        browser("eval", "actions['dag-view-toggle']();actions['dag-fit']();")
                        browser("screenshot", str(Path(native_graph_evidence) / f"graph-scene-390-{theme}.png"))
                        browser("eval", "actions['dag-view-toggle']();")
                check_browser_errors()
                return
            if args.pq_queue_only:
                browser(*options, "open", host + ENTRY + "?pqReview=1")
                browser("set", "viewport", "1280", "800")
                scenario("037 PQ 队列：混合选区核对", """
                  await page('.photo-card');act('photo','r1');act('multi');act('photo','b1');
                  act('workflow','edit');await page('.inspector-rail');act('edit-tool','basic');await page('.scene-mode-bar');
                  act('scene-mode','hdr');act('workflow','export');act('export-choice','draft',modal());await page('#export-frame[src]');
                  const d=()=>el('#export-frame').contentDocument;
                  await wait(()=>el('#scene-target',d())?.checkVisibility());
                  set('#scene-target','hdr',d());
                  assert(el('#size',d()).disabled&&el('#watermark-shelf',d()).hidden&&el('#metadata',d()).disabled,'fixed output lacks ambiguous controls');
                  tap('#submit',d());assert(el('#pq-review',d()).open&&el('#pq-confirm',d()).disabled,'mixed selection cannot silently switch to SDR');
                  assert(el('#pq-list',d()).textContent.includes('无 HDR 母版')&&el('#pq-list',d()).textContent.includes('.avif'));
                """)
                pq_evidence = os.environ.get("RAWMASTER_UI_PQ_EVIDENCE")
                if pq_evidence:
                    Path(pq_evidence).mkdir(parents=True, exist_ok=True)
                    browser("screenshot", str(Path(pq_evidence) / "pq-mixed-1280.png"))
                browser("set", "viewport", "390", "844")
                scenario("037 PQ 队列：窄窗取消、离线检查及明确冻结", """
                  const d=()=>el('#export-frame').contentDocument, win=d().defaultView;
                  const review=el('#pq-review',d());assert(review.getBoundingClientRect().right<=win.innerWidth,'narrow sheet fits');
                  tap('#pq-cancel',d());
                  assert(!el('#job',d()).open&&!review.open,'cancel did not register task');
                  // Remove only the explicitly incompatible row via the same selection API as its checkbox.
                  const incompatible=win.eval('getPlan(true).find(row=>row.state===\"无 HDR 母版\").index');
                  win.eval('selection.toggle('+incompatible+',false,false)');
                  win.eval('photos[selection.ordered[0]].online=false;plannedKey=\"\";refresh()');
                  tap('#submit',d());assert(el('#pq-confirm',d()).disabled&&el('#pq-list',d()).textContent.includes('待找回'),'offline selection remains blocked');
                  tap('#pq-cancel',d());win.eval('photos[selection.ordered[0]].online=true;plannedKey=\"\";refresh()');
                  tap('#submit',d());assert(!el('#pq-confirm',d()).disabled,'qualified selection ready');
                """)
                if pq_evidence:
                    browser("screenshot", str(Path(pq_evidence) / "pq-ready-390.png"))
                scenario("037 PQ 队列：确认仅冻结 AVIF", """
                  const d=()=>el('#export-frame').contentDocument;
                  tap('#pq-confirm',d());await wait(()=>el('#job',d()).open);
                  assert(el('#job',d()).textContent.includes('.avif')&&!el('#job',d()).textContent.includes('.jpg'),'exact target frozen');
                """)
                check_browser_errors()
                return
            if args.scene_native_only:
                browser(*options, "open", host + ENTRY + "?sceneNativeReview=1&sceneRawRuntime=unavailable")
                browser("set", "viewport", "1440", "900")
                scenario("037 原生评审：运行库不可用时留在原草稿", """
                  await page('.photo-card');act('photo','b1');act('workflow','edit');await page('.inspector-rail');
                  act('edit-tool','basic');await page('.scene-mode-bar');
                  const draft=Studio.edit('b1'), old=JSON.stringify(draft.recipe), count=draft.past.length;
                  act('scene-mode','hdr');act('scene-review-start',null,modal());
                  const mode=el('.scene-modes [data-val=hdr]');
                  assert(el('.scene-warning').textContent.includes('HDR 原片解码运行库不可用'),'runtime reason');
                  assert(!modal().open&&JSON.stringify(draft.recipe)===old&&draft.past.length===count,'no draft or history');
                  assert(document.activeElement===mode,'returns focus to HDR');
                  act('scene-dismiss');assert(!el('.scene-warning'),'dismiss keeps photo in the editor');
                  act('scene-mode','hdr');act('close',null,modal());assert(JSON.stringify(draft.recipe)===old,'can cancel again');
                """)
                browser("open", host + ENTRY + "?sceneNativeReview=1")
                scenario("037 原生评审：从资料库取消、创建与撤销 HDR 草稿", """
                  await page('.photo-card');act('photo','b1');act('workflow','edit');await page('.inspector-rail');
                  act('edit-tool','basic');await page('.scene-mode-bar');
                  const e=Studio.edit('b1'), old=JSON.stringify(e.recipe);sessionStorage.setItem('scene.review.old',old);
                  act('scene-mode','hdr');
                  const create=el('[data-act=scene-review-start]',modal()), cancel=el('.dialog-foot [data-act=close]',modal());
                  assert(modal().innerText.includes('不会把现有 SDR 调整')&&modal().innerText.includes(Studio.asset('b1').name),'confirmation names the source and describes the draft');
                  assert(!create.disabled&&!cancel.disabled&&JSON.stringify(e.recipe)===old,'both actions enabled before rendering');
                  cancel.click();await wait(()=>document.activeElement.dataset.val==='hdr');
                  assert(!modal().open&&JSON.stringify(e.recipe)===old,'cancel returns to HDR without editing');
                  act('scene-mode','hdr');act('scene-review-start',null,modal());
                  assert(e.recipe.sceneOutput?.intent==='hdr'&&!Studio.edit('r1').recipe.sceneOutput,'current photo only');
                  const past=e.past.length;act('scene-view','sdr',el('.scene-hud'));assert(e.past.length===past,'view does not write history');
                  el('[name=sceneGraphExposure]').value='1.25';act('scene-review-exposure');assert(e.recipe.ev===1.25,'node exposure');
                  act('edit-step','undo');assert(e.recipe.sceneOutput&&e.recipe.ev===0,'undo exposure only');
                  act('edit-step','undo');assert(JSON.stringify(e.recipe)===old,'undo HDR restores exact SDR');
                  act('scene-mode','hdr');act('scene-review-start',null,modal());act('scene-open');
                  act('scene-review-fail',null,modal());assert(el('.scene-hud').innerText.includes('预览失败'),'visible failure');
                  act('scene-review-retry');assert(!el('.scene-hud').innerText.includes('预览失败'),'retry returns to same HDR draft');
                """)
                scene_evidence = os.environ.get("RAWMASTER_UI_SCENE_EVIDENCE")
                if scene_evidence:
                    Path(scene_evidence).mkdir(parents=True, exist_ok=True)
                    browser("screenshot", str(Path(scene_evidence) / "scene-review-fit.png"))
                for theme in ['light', 'dark']:
                    browser("set", "viewport", "390", "844")
                    scenario(f"037 原生评审：390px {theme}、回退原因和离线", """
                      await hash('settings/general');await page('[name=theme]');set('[name=theme]','""" + theme + """');
                      await hash('edit/basic');await page('.scene-mode-bar');
                      assert(document.documentElement.scrollWidth<=innerWidth,'no horizontal overflow');
                      act('scene-view','target',el('.scene-hud'));
                      assert(el('.scene-hud').innerText.includes('屏幕无 HDR 余量'),'fallback explicit');
                      const e=Studio.edit('b1'), hdr=JSON.stringify(e.recipe);Studio.asset('b1').online=false;render();
                      act('scene-mode','sdr');assert(el('.scene-warning').innerText.includes('离线')&&JSON.stringify(e.recipe)===hdr,'offline is fail closed');
                      Studio.asset('b1').online=true;render();
                      const button=el('[data-act=scene-mode][data-val=hdr]');button.focus();key(button,'ArrowLeft');
                      assert(document.activeElement.dataset.val==='sdr'&&JSON.stringify(e.recipe)===hdr,'arrow moves focus only');
                    """)
                    if scene_evidence:
                        browser("screenshot", str(Path(scene_evidence) / f"scene-review-390-{theme}.png"))
                check_browser_errors()
                return
            if args.compatibility_only:
                browser(*options, "open", host + ENTRY + "?compatibilityGraph=1")
                browser("set", "viewport", "1440", "900")
                scenario("Node DAG 兼容评审：正常入口、主图和草稿隔离", """
                  await hash('settings/general');await page('[name=theme]');set('[name=theme]','dark');
                  await hash('library/project/river');
                  await page('.photo-card');act('photo','r1');act('workflow','edit');await page('.dag-scope-head');
                  act('edit-tool','basic');await page('.scene-mode-bar');
                  const edit=Studio.edit('r1'), before=JSON.stringify(edit.recipe), history=edit.past.length;
                  sessionStorage.setItem('compat.before',before);sessionStorage.setItem('compat.history',history);
                  act('compatibility-graph-toggle','',el('.dag-scope-head'));
                  assert(el('.dag-compat').getAttribute('aria-modal')==='false'&&el('.edit-center .developed').checkVisibility(),'Graph and photo coexist');
                  assert(document.documentElement.dataset.theme==='dark'&&el('.dag-compat').getBoundingClientRect().left>innerWidth/2,'desktop Graph opens to the side so the main photo remains visible');
                  assert(all('.dag-compat-canvas b').map(x=>x.textContent).join()==='照片来源,兼容显影,最终输出','matches the native stage order');
                  assert(el('[data-act=compatibility-ignore]').disabled&&!el('.dag-compat [data-dag-node]'),'read-only graph has no editing commands');
                  act('compatibility-graph-fold');assert(!el('.dag-compat-canvas'),'collapsed');
                  act('compatibility-graph-fold');assert(el('.dag-compat-canvas'),'expanded');
                  act('compatibility-graph-reset');
                  assert(JSON.stringify(edit.recipe)===before&&edit.past.length===history&&!edit.recipe.dag,'presentation does not seed a recipe or history');
                """)
                compatibility_evidence = os.environ.get("RAWMASTER_UI_DAG_EVIDENCE")
                if compatibility_evidence:
                    Path(compatibility_evidence).mkdir(parents=True, exist_ok=True)
                    browser("screenshot", str(Path(compatibility_evidence) / "compatibility-1440-dark.png"))
                browser("focus", ".dag-compat [data-dag-window-resize]")
                browser("press", "ArrowLeft")
                scenario("Node DAG 兼容评审：键盘调整窗宽不翻片", """
                  assert(el('.dag-compat').getBoundingClientRect().width===620&&document.activeElement.matches('[data-dag-window-resize]'),'keyboard resize preserves focus');
                  assert(Studio.data.work==='r1'&&JSON.stringify(Studio.edit('r1').recipe)===sessionStorage.getItem('compat.before'),'resizing does not route to the photo');
                """)
                browser("press", "Escape")
                scenario("Node DAG 兼容评审：Escape 关闭并返还焦点", """
                  assert(!el('.dag-compat')&&document.activeElement===el('.dag-scope-head [data-act=compatibility-graph-toggle]'),'Escape restores the trigger');
                  act('compatibility-graph-toggle','',el('.dag-scope-head'));
                  act('open-versions');await page('#adjustment-panel');
                  assert(!el('.dag-compat')&&!el('.dag-scope-head'),'versions do not expose the graph');
                  act('return-adjustments');await page('.scene-mode-bar');
                  assert(!el('.dag-compat')&&Studio.data.work==='r1','return to same editor without reopening the window');
                """)
                browser("set", "viewport", "390", "844")
                scenario("Node DAG 兼容评审：390px 浅色布局", """
                  await hash('settings/general');await page('[name=theme]');set('[name=theme]','light');
                  await hash('edit/basic');await page('.dag-scope-head');
                  act('compatibility-graph-toggle','',el('.dag-scope-head'));
                  const frame=el('.dag-compat').getBoundingClientRect();
                  assert(document.documentElement.dataset.theme==='light'&&frame.left>=0&&frame.right<=innerWidth&&el('.dag-compat-canvas').offsetHeight>=240,'narrow canvas stays readable');
                """)
                if compatibility_evidence:
                    browser("screenshot", str(Path(compatibility_evidence) / "compatibility-390-light.png"))
                browser("set", "viewport", "900", "360")
                scenario("Node DAG 兼容评审：短窗标题与原片离线", """
                  await wait(()=>el('.dag-compat.minimized')?.checkVisibility());
                  assert(!el('.dag-compat-canvas')&&el('.dag-compat small').textContent.includes('增高窗口'),'short window explains why only the title is visible');
                  el('.dag-compat [data-act=compatibility-graph-toggle]').click();
                  Studio.asset('r1').online=false;render();
                  assert(!el('.dag-compat')&&el('[data-act=compatibility-graph-toggle]').disabled&&el('.dag-scope-head small').textContent.includes('离线'),'offline source has a reason');
                  Studio.asset('r1').online=true;render();
                  const edit=Studio.edit('r1');assert(JSON.stringify(edit.recipe)===sessionStorage.getItem('compat.before')&&edit.past.length===+sessionStorage.getItem('compat.history'),'original draft remains');
                """)
                check_browser_errors()
                return
            if not editing_only or args.hdr_only:
                browser(*options, "open", host + ENTRY)
                browser("set", "viewport", "1440", "900")
                scenario("037 HDR 暗房状态与冻结交付", """
                  await page('.photo-card');
                  act('workflow','edit'); await page('.inspector-rail'); act('edit-tool','basic'); await page('.scene-mode-bar');
                  act('scene-mode','hdr');
                  assert(!el('#scene-mode-reason')&&el('.edit-center .scene-warning').textContent.includes('场景校准')&&!Studio.edit('r1').recipe.sceneOutput,'unqualified HDR is explained on canvas only');
                  act('scene-dismiss'); assert(!el('.scene-warning'),'warning dismisses');
                  act('goto','library/project/river'); await page('.photo-card');
                  act('photo','b1'); act('workflow','edit'); await page('.inspector-rail');
                  act('edit-tool','basic'); await page('.scene-mode-bar');
                  act('scene-mode','hdr');
                  const edit=Studio.edit('b1');
                  assert(edit.recipe.sceneOutput?.intent==='hdr'&&!Studio.edit('r1').recipe.sceneOutput,'version-scoped intent');
                  const history=edit.past.length;
                  const marker=el('.scene-chart-ok').getAttribute('d');
                  const limit=el('[name=sceneLimit]');
                  assert(limit.labels[0]?.textContent==='HDR 高光限制','HDR Limit has an accessible label');
                  limit.value='1.5';limit.dispatchEvent(new Event('input',{bubbles:true}));
                  assert(el('.scene-limit output').value==='+1.5 EV'&&edit.past.length===history,'dragging updates the live readout before committing');
                  limit.dispatchEvent(new Event('change',{bubbles:true}));
                  assert(edit.recipe.sceneOutput.limitEV===1.5&&edit.recipe.sceneOutput.peak===1000&&el('.scene-chart-ok').getAttribute('d')===marker,'HDR Limit is separate from display and file target');
                  act('edit-step','undo');
                  tap('.scene-rendition summary');set('.scene-rendition [name=sceneExposure]','0.5');
                  act('scene-view','sdr',el('.scene-rendition'));
                  assert(el('.scene-rendition [name=sceneExposure]').value==='0.5'&&edit.past.length===history,'inline SDR preview keeps draft and history');
                  act('scene-trim','',el('.scene-rendition'));assert(edit.recipe.sceneOutput.trim.exposure===0.5,'inline SDR apply');
                  act('edit-step','undo');
                  act('scene-scope','scene'); act('scene-sample');
                  assert(el('.scene-scopes').textContent.includes('−0.02'),'signed AP1 sample');
                  act('scene-overlay','sensor');act('scene-overlay','target');
                  assert(all('.scene-marks i').length===2,'independent overlays');
                  key(document.activeElement,'Escape');
                  assert(!all('.scene-marks i').length&&document.activeElement.dataset.act==='scene-overlay','overlay Escape restores focus');
                  tap('.scene-entry'); set('[name=sceneExposure]','1',modal()); act('scene-screen','hdr',modal());
                  assert(el('[name=sceneExposure]',modal()).value==='1'&&edit.past.length===history,'view preserves draft and history');
                  act('scene-trim','',modal());
                  assert(edit.recipe.sceneOutput.trim.exposure===1&&edit.past.length===history+1,'one SDR history step');
                  act('edit-step','undo');assert(edit.recipe.sceneOutput.trim.exposure===0,'undo trim only');
                  const film=el('[data-act=film-stock]');tap('[data-act=film-stock][data-val="'+CSS.escape(film.dataset.val)+'"]');
                  assert(modal().textContent.includes('仅 SDR')&&el('.scene-film-preview',modal()),'separate film preview');
                  act('close',null,modal());assert(!edit.recipe.sceneOutput.film,'cancel film leaves recipe');
                  act('workflow','export');act('export-choice','draft',modal());await page('#export-frame[src]');
                  const frame=el('#export-frame');
                  const d=()=>frame.contentDocument;
                  await wait(()=>d()?.readyState==='complete' && el('#scene-target',d())?.checkVisibility() && el('#out-name',d())?.textContent.includes('.jpg'));
                  set('#scene-target','both',d());
                  const name=el('#out-name',d()).textContent;
                  assert(name.includes('.avif')&&name.includes('.jpg'),'dual files: '+name+' / '+el('#out-facts',d()).textContent);
                  assert(el('#count',d()).textContent.includes('2 项'),'file count');
                  tap('#submit',d());tap('#job details summary',d());tap('#fail-job',d());
                  await wait(()=>el('#job-summary',d()).textContent.includes('写入失败 1 项')&&el('#job-summary',d()).textContent.includes('已核验 1 / 2'));
                  tap('#retry',d());await wait(()=>el('#job-summary',d()).textContent.includes('已核验 2 / 2'));
                  tap('#close-job',d());act('workflow','library');await page('.photo-card');
                  assert(activeBrowser().focus==='b1','return to selected photo');
                  const saved=edit.lastSaved;edit.adopted=saved;
                  Studio.asset('b1').online=false;Studio.save();
                  act('workflow','edit');await page('.inspector-rail'); act('edit-tool','basic');await page('.scene-entry');tap('.scene-entry');
                  assert(modal().textContent.includes('原片已离线')&&el('[name=sceneExposure]',modal()).disabled,'offline HDR settings');
                  act('close',null,modal());act('workflow','library');await page('.photo-card');
                  act('multi');act('photo','r1');act('workflow','export');await page('#export-frame[src]');
                  const mix=()=>el('#export-frame').contentDocument;
                  await wait(()=>mix()?.readyState==='complete'&&el('#scene-target',mix())?.checkVisibility());
                  set('#scene-target','hdr',mix());
                  let count=el('#count',mix()).textContent;
                  assert(count.includes('待找回 1 项')&&count.includes('无 HDR 母版 1 张')&&el('#submit',mix()).disabled,'offline + unqualified is blocked');
                  set('#scene-fallback',true,mix());
                  assert(el('#count',mix()).textContent.includes('可交付 1 项'),'explicit fallback only for ineligible version');
                  tap('#submit',mix());tap('#cancel-job',mix());
                  assert(el('#job-title',mix()).textContent.includes('已取消'),'cancel mixed batch');
                """)
                browser("set", "viewport", "390", "844")
                scenario("037 HDR 窄窗与外观", """
                  const options=['light','dark'];
                  for(const theme of options){
                    await hash('settings/general');await page('[name=theme]');set('[name=theme]',theme);
                    await hash('edit/basic');await page('.scene-entry');
                    const bounds=el('.edit-right').getBoundingClientRect();
                    assert(bounds.left>=0&&bounds.right<=innerWidth&&all('.scene-modes button').length===3,'mode bar fits '+theme);
                    tap('.scene-entry');
                    assert(document.documentElement.dataset.theme===theme&&modal().getBoundingClientRect().width<=innerWidth,'dialog fits '+theme);
                    assert(el('[data-act=scene-screen][data-val=hdr]',modal()).checkVisibility(),'screen control reachable at 390px');
                    act('close',null,modal());
                  }
                """)
                browser("set", "viewport", "1440", "900")
                scenario("037 HDR 旧版外观冲突", """
                  await hash('library/project/river');await page('.photo-card');
                  act('photo','m1');act('workflow','edit');await page('.inspector-rail'); act('edit-tool','basic'); await page('.scene-entry');
                  const old=Studio.edit('m1');
                  act('film-stock',el('[data-act=film-stock]').dataset.val);
                  const recipe=JSON.stringify(old.recipe);
                  act('scene-mode','hdr');
                  assert(modal().textContent.includes('胶片外观'),'conflict explains incompatible Look');
                  act('close',null,modal());assert(JSON.stringify(old.recipe)===recipe&&!old.versions.length,'cancel creates no versions');
                  act('scene-mode','hdr');act('scene-new',null,modal());
                  assert(old.recipe.sceneOutput?.intent==='hdr'&&!old.recipe.filmStock,'HDR draft carries no old film');
                  assert(old.versions.some(v=>JSON.stringify(v.recipe)===recipe)&&old.adopted==='original','old SDR retained without auto-adoption');
                """)
                scenario("037 色彩模式与 Graph 面板分区", """
                  await hash('edit/basic');await page('.scene-mode-bar');
                  const panel=el('.edit-inspector'), modeBar=el('.scene-mode-bar'), graphBar=el('.dag-scope-head');
                  assert(graphBar.nextElementSibling===panel&&modeBar.parentElement.id==='adjustment-panel'&&modeBar.compareDocumentPosition(el('.scene-scopes'))&Node.DOCUMENT_POSITION_FOLLOWING,'mode section inside Basic before scopes');
                  act('edit-tool','tones');await page('#adjustment-panel');assert(!el('.scene-mode-bar'),'mode section is not repeated in Curves');
                  act('edit-tool','basic');await page('.scene-mode-bar');
                  assert(el('.dag-scope-head').getBoundingClientRect().bottom<el('.edit-inspector').getBoundingClientRect().top&&getComputedStyle(el('.scene-mode-bar')).borderBottomWidth==='1px','gap and separator');
                  assert(!el('.edit-head [data-act=scene-open]'),'no duplicate settings');
                  act('dag-view-toggle');await page('.dag-floating');
                  act('dag-picker');
                  assert(all('.dag-picker-list [data-act=dag-picker-select]').map(b=>b.dataset.val).join()==='grade'&&el('[data-val=base]',el('#dag-node-picker')),'fixed stages excluded from node list');
                  act('dag-picker-select','grade',el('#dag-node-picker'));
                  const menu=()=>el('#dag-context');
                  key(el('[data-dag-node=grade]'),'F10',{shiftKey:true});
                  assert(menu().matches(':popover-open')&&menu().textContent.includes('Solo')&&!menu().textContent.includes('适合全图'),'node-only context');
                  key(document.activeElement,'Escape');
                  assert(!menu()?.matches(':popover-open')&&document.activeElement===el('[data-dag-node=grade]')&&el('.dag-floating'),'node context Escape returns to the node without closing Graph');
                  key(el('[data-dag-viewport]'),'ContextMenu');
                  assert(menu().matches(':popover-open')&&menu().textContent.includes('适合全图')&&!menu().textContent.includes('复位本节点'),'canvas context');key(document.activeElement,'Escape');
                  assert(!menu()?.matches(':popover-open')&&document.activeElement===el('[data-dag-viewport]')&&el('.dag-floating'),'canvas context Escape returns to the canvas');
                  const e=Studio.edit('m1'), selected=dagView().selection.join(), graphNodeBytes=()=>JSON.stringify([e.recipe.dag.nodes,e.recipe.dag.edges]);
                  const nodes=graphNodeBytes(), past=e.past.length, recipe=JSON.stringify(e.recipe);
                  act('dag-solo'); assert(el('.dag-photo-status').textContent.includes('Solo')&&el('.dag-monitor').textContent.includes('Solo'),'Solo labels both previews');
                  act('dag-preview-bypass');assert(el('.dag-photo-status').textContent.includes('旁路')&&!dagPreviewState().solo,'view overrides are exclusive');
                  act('dag-preview-final'); assert(JSON.stringify(e.recipe)===recipe&&e.past.length===past,'temporary view does not change recipe or export');
                  const sw=m=>el('[data-act=scene-mode][data-val='+m+']');
                  sw('hdr').focus();key(sw('hdr'),'ArrowRight');
                  assert(document.activeElement===sw('bw')&&e.past.length===past&&sw('hdr').getAttribute('aria-pressed')==='true','keyboard focus only');
                  act('scene-mode','bw');assert(modal().open&&e.past.length===past,'leaving HDR needs confirmation');
                  act('close',null,modal());await wait(()=>document.activeElement===sw('bw'));
                  assert(e.recipe.sceneOutput&&graphNodeBytes()===nodes,'cancel keeps HDR and graph');
                  act('scene-mode','bw');act('scene-confirm-sdr','bw',modal());
                  assert(!e.recipe.sceneOutput&&RMPhotos.displayLook(e.recipe).mono&&el('.developed').style.filter.includes('grayscale(1)'),'B&W applies grayscale');
                  assert(graphNodeBytes()===nodes&&dagView().selection.join()===selected&&el('.dag-floating')&&e.past.length===past+1,'mode does not change graph topology, state or selection');
                  act('dag-toggle-current');
                  assert(el('[data-act=dag-toggle-current]').getAttribute('aria-pressed')==='true'&&e.recipe.colorMode==='bw'&&!e.recipe.sceneOutput,'bypass preserves mode');
                  act('edit-step','undo');act('edit-step','undo');
                  assert(e.recipe.sceneOutput?.intent==='hdr'&&sw('hdr').getAttribute('aria-pressed')==='true'&&dagView().selection.join()===selected,'undo restores HDR without losing selection');
                  act('dag-toggle-current');assert(e.recipe.sceneOutput?.intent==='hdr','subsequent node edit preserves HDR');
                  act('scene-overlay','bands');act('dag-picker');key(document.activeElement,'Escape');
                  assert(!el('#dag-node-picker').matches(':popover-open')&&el('.scene-marks .bands')&&document.activeElement===el('[name=dagNode]'),'picker Escape does not clear HDR diagnostics');
                  act('dag-view-toggle');assert(!el('.dag-floating')&&sw('hdr').getAttribute('aria-pressed')==='true','Graph control remains independent');
                  act('open-versions');await page('#adjustment-panel');
                  assert(!el('.scene-modes')&&!el('.dag-scope-head'),'saved version is read-only');
                """)
                if args.hdr_only:
                    check_browser_errors()
                    return
                # The scripted offline and delivery states must not seed the general workbench run.
                browser("eval", "localStorage.clear(); sessionStorage.clear();")
            browser(*options, "open", (ROOT / ENTRY).as_uri())
            scenario("双击入口与本地照片", """
              await page('.photo-card');await wait(()=>all('.photo-card img').every(i=>i.complete&&i.naturalWidth));
              assert(all('.photo-card').length===12,'sample library');
              act('workflow','export');await page('#export-frame[src]');
            """)
            browser("open", host + ENTRY)
            browser("set", "viewport", "1440", "900")
            scenario("标题栏与资料库侧栏开关", """
              await page('.photo-card');
              const toggle=()=>el('#chrome [data-act=drawer]');
              assert(!el('#chrome .brand,.brandmark')&&!el('#chrome').textContent.includes('RAWMaster'),'no duplicate app identity');
              assert(toggle().getAttribute('aria-pressed')==='true'&&el('.rail').checkVisibility({visibilityProperty:true}),'sidebar initially visible');
              const photo=el('.photo-card').dataset.val, width=el('.library-main').getBoundingClientRect().width;
              act('drawer');
              assert(toggle().getAttribute('aria-pressed')==='false'&&!el('.rail').checkVisibility({visibilityProperty:true}),'sidebar closes');
              assert(el('.library-main').getBoundingClientRect().width>width&&el('.photo-card').dataset.val===photo,'expand without changing photos');
              act('drawer');assert(toggle().getAttribute('aria-pressed')==='true','sidebar restores');
            """)
            browser("focus", "#chrome [data-act=drawer]")
            browser("press", "Space")
            if browser("get", "attr", "#chrome [data-act=drawer]", "aria-pressed") != "false":
                raise AssertionError("Space should toggle the sidebar")
            browser("press", "Space")
            browser("dblclick", ".photo-card[data-val=r1]")
            if browser("get", "count", ".loupe") != "1":
                raise AssertionError("Double-click should open the selected photo")
            browser("press", "g")
            scenario("搜索、筛选、多选比较与批量标签", """
              act('search-toggle');set('[name=query]','不存在的文件');
              assert(el('.empty h3').textContent.includes('没有符合'),'empty search');
              act('clear-filters');act('filters');set('[name=availability]','offline');
              assert(all('.photo-card').length===1,'availability');act('clear-filters');act('filters');
              act('photo','r1');act('multi');act('photo','b1');act('mode','compare');
              assert(all('.comparison figure').length===2,'compare pair');
              act('tags');set('[name=tagText]','候选');assert(el('#tag-review').textContent.includes('河谷'),'existing tags');
              act('apply-tags',null,modal());act('mode','grid');act('multi');act('photo','r1');
              assert(el('.inspector').textContent.includes('候选'),'tag adoption');
              act('sort');set('[name=fold]',true);act('close',null,modal());assert(el('.contact-grid [data-val="library/group/dusk"]'),'fold group');
              act('sort');set('[name=fold]',false);act('close',null,modal());
            """)
            scenario("导入、续接、分组、初筛封存与历史恢复", """
              act('import');act('begin-import',null,modal());await page('[data-act=seal]');
              assert(!el('.rate-row'),'triage rating');act('triage-menu');act('session-action','pause',modal());act('close',null,modal());act('seal');
              assert(modal().textContent.includes('请先继续'),'paused');act('triage-menu',null,modal());act('session-action','pause',modal());
              act('session-action','groups',modal());act('session-group',null,modal());act('protect-session-group',null,modal());
              act('photo','n2');act('decide','reject');act('seal');
              assert(el('[data-act=confirm-seal]',modal()).disabled,'summary confirmation');set('[name=sealAck]',true);act('confirm-seal',null,modal());
              await page('.view-heading [data-act=import]');assert(el('[data-act=photo][data-val=n1]')&&!el('[data-act=photo][data-val=n2]'),'excluded filtered');
              act('goto','tools/history');await page('[data-act=history-detail]');act('history-detail');act('restore-file',null,modal());
              assert(modal().textContent.includes('已恢复'),'restore from sealed ledger');act('close',null,modal());
              act('goto','library/project/river');await page('[data-act=photo][data-val=n2]');
            """)
            scenario("胶片带对齐、折叠和离线照片", """
              act('mode','single');
              const near=(a,b)=>Math.abs(a-b)<1;
              const checkAlignment=()=>{
                const photos=all('.filmstrip .filmstrip-photo img').map(img=>img.getBoundingClientRect());
                assert(el('.filmstrip > .filmstrip-photo')&&photos.every(r=>near(r.top,photos[0].top)),'grouped and ungrouped thumbnails align');
                const selected=el('.filmstrip > .filmstrip-photo.chosen').getBoundingClientRect();
                for(const group of all('.filmstrip-group')) {
                  const outline=group.getBoundingClientRect(), heading=el('.filmstrip-heading',group).getBoundingClientRect();
                  const button=el('.filmstrip-toggle',group), toggle=button.getBoundingClientRect();
                  const arrow=el('.icon',button).getBoundingClientRect(), name=el('.filmstrip-name',button).getBoundingClientRect();
                  const meta=el('.filmstrip-meta',group).getBoundingClientRect();
                  assert(near(outline.top,selected.top)&&near(outline.bottom,selected.bottom),'group and selected standalone outlines align');
                  assert(near(heading.top+heading.height/2,outline.top+outline.height/2),'group heading is vertically centered');
                  assert(arrow.right<name.left&&arrow.top<name.bottom&&name.top<arrow.bottom&&toggle.bottom<=meta.top&&near(toggle.width,heading.width)&&heading.width<=selected.width,'compact two-row heading');
                  for(const photo of all('.filmstrip-photo',group)) {
                    const card=photo.getBoundingClientRect(), above=card.top-outline.top, below=outline.bottom-card.bottom;
                    assert(above>=3&&near(above,below)&&heading.right<card.left,'group cards follow the heading with equal vertical spacing');
                  }
                }
              };
              checkAlignment();
              const toggle=()=>el('.filmstrip-toggle'), group=toggle().dataset.val, original=el('.filmstrip-name').textContent;
              const stripHeight=()=>el('.filmstrip').getBoundingClientRect().height;
              const firstPhotoLeft=()=>el('.filmstrip-group .filmstrip-photo').getBoundingClientRect().left;
              const count=all('.filmstrip-photo').length, selected=activeBrowser().focus, initialHeight=stripHeight(), initialLeft=firstPhotoLeft();
              tap('.filmstrip-toggle .filmstrip-name');assert(toggle().ariaExpanded==='false'&&all('.filmstrip-photo').length<count&&activeBrowser().focus===selected&&near(stripHeight(),initialHeight),'title click collapses without changing focus or height');
              act('filmstrip-group',group);assert(toggle().ariaExpanded==='true'&&all('.filmstrip-photo').length===count,'expand restores members');
              const settings=()=>act('manage-group',group,el('.filmstrip'));
              const groupName=()=>el('[name=groupName]',modal());
              const rename=(name)=>{set('[name=groupName]',name,modal());act('save-group',group,modal());};
              const longName='河谷日落延时拍摄 · Camera B 第 02 段';
              settings();assert(modal().open&&groupName().value===original,'settings target the visible group');
              rename(longName);
              const name=el('.filmstrip-name',toggle());
              assert(name.scrollWidth>name.clientWidth&&getComputedStyle(name).textOverflow==='ellipsis'&&near(firstPhotoLeft(),initialLeft),'long name uses an ellipsis without moving thumbnails');
              assert(name.textContent===longName&&toggle().title===longName&&toggle().ariaLabel.includes(longName),'full name preserved for hover and accessibility');
              checkAlignment();
              settings();assert(groupName().value===longName,'settings retains the full group name');
              act('close',null,modal());assert(activeBrowser().focus===selected&&toggle().ariaExpanded==='true','cancel preserves the photo and expansion');
              settings();rename(original);
              act('workflow','edit');await page('.canvas-dock');
              assert(!el('.filmstrip')&&Studio.data.work===selected,'editing replaces the strip with the canvas dock');
              act('workflow','library');await page('.loupe');
              assert(all('.filmstrip-photo').length===count&&activeBrowser().focus===selected,'return preserves the library filmstrip and focus');
              act('mode','grid');
            """)
            scenario("暗房布局、智能预设与胶片采用", """
              await hash('library/group/dusk');act('photo','d1');act('workflow','edit');await page('.smart-panel');
              assert(!el('.edit-head .switch,.edit-left .switch,.edit-inspector .tool-palette,.agent-panel'),'single darkroom');
              const headings=all('.edit-left > section[aria-labelledby]').map(section=>el('#'+section.getAttribute('aria-labelledby'),section));
              assert(headings.map(n=>n.textContent).join('/')==='滤镜/快照/历史'&&headings[0].offsetTop<headings[1].offsetTop&&headings[1].offsetTop<headings[2].offsetTop,'stacked left sections');
              const rail=el('.inspector-rail').getBoundingClientRect(),pane=el('.inspector-content').getBoundingClientRect();
              assert(rail.width<51&&rail.right<=pane.left+1&&all('.rail-tool').every(b=>!b.textContent.trim()&&b.getAttribute('aria-label')&&!b.title),'vertical icon rail with accessible labels and no system tooltips');
              assert(!el('[name=aiPrompt]')&&el('[data-act=edit-tool][data-val=agent]'),'opt in to Agent');
              act('scene-card','暮色冷暖');act('scene-preview');act('close',null,modal());assert(all('.edit-history li').length===1,'cancel scene');
              act('scene-preview');act('apply-scene',null,modal());assert(el('.edit-history').textContent.includes('暮色冷暖'),'smart preset adopted');
              act('edit-step','undo');set('[name=scene]','纪实');act('scene-card','同组参考配平');act('scene-preview');
              assert(all('[name=matchReference] option',modal()).length===3,'scope contains just this group');set('[name=matchReference]','d2',modal());
              assert(!el('[name=matchTarget][value=d2]',modal()),'reference protected');act('close',null,modal());
              const neutral=el('.developed').style.filter;
              assert(all('.preset-directory > details > summary > span').slice(0,3).map(x=>x.textContent).join('|')==='Adaptive|胶片模拟|Imported'&&!el('.preset-folder img'),'three primary folders without thumbnails');
              assert(all('[data-folder=adaptive] > .preset-children > details > summary > span').map(x=>x.textContent).join('|')==='Sky|Subject','preserve source folders');
              assert(all('[data-act=film-stock]').length===9&&el('[data-folder=film]').textContent.includes('Spektrafilm 官方模型 · SDR 色彩外观'),'nine official SDR film endpoints');
              for(const stock of ['gold','portrait800','ektar','provia','ektachrome','tungsten']){
                set('[name=presetQuery]',stock==='tungsten'?'500T':RMPhotos.filmStocks[stock].name);
                assert(all('[data-act=film-stock]').length===1&&el('[data-act=film-stock]').dataset.val===stock,'new film searchable: '+stock);
              }
              set('[name=presetQuery]','');
              const filterMenu=()=>el('.filter-options');
              assert(el('[data-key=filmAmount]').disabled&&(el('.film-strength').compareDocumentPosition(el('.preset-directory'))&Node.DOCUMENT_POSITION_FOLLOWING),'film strength remains above folders');
              assert(!el('.filter-header-actions > [data-val=save]')&&!el('.filter-header-actions > [data-act=preset-import]')&&all('.filter-options [data-act]').length===3,'save, import and export live only in the contextual menu');
              tap('summary',filterMenu());act('preset-manage','save',filterMenu());assert(value('presetOperation')==='保存当前调整','Save still routes to saving adjustments');act('close',null,modal());await wait(()=>document.activeElement===el('summary',filterMenu()));
              tap('summary',filterMenu());act('preset-import',null,filterMenu());assert(value('presetOperation').includes('Lightroom')&&!modal().textContent.includes('迁移'),'XMP import remains separate from migration');set('[name=presetName]','走查 XMP',modal());act('preset-command',null,modal());
              const imported=el('[data-act=apply-preset][data-val="走查 XMP"]');
              imported.dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));assert(el('.developed').style.filter!==neutral,'import hover changes the canvas');
              imported.dispatchEvent(new PointerEvent('pointerout',{bubbles:true}));assert(el('.developed').style.filter===neutral,'import hover restores');
              set('[name=presetQuery]','无匹配输入');assert(el('.preset-directory').textContent.includes('没有匹配'),'search empty');
              set('[name=presetQuery]','');
              tap('summary',filterMenu());act('preset-manage','export',filterMenu());assert(value('presetOperation')==='导出原生预设','Export opens its own dialog');act('close',null,modal());
              act('adaptive-preset','subject');act('adaptive-mask-preview','subject',modal());assert(el('.adaptive-mask-proof .subject'),'current-photo mask review');act('close',null,modal());
              let film=el('[data-act=film-stock][data-val=cinema]');film.focus();assert(el('.developed').style.filter!==neutral,'keyboard film preview');
              key(film,'Escape');assert(el('.developed').style.filter===neutral&&el('.look-preview').hidden,'Escape restores applied image');
              key(film,'ArrowUp');assert(document.activeElement.dataset.val==='chrome','film keys stay in the folder');
              document.activeElement.blur();assert(el('.developed').style.filter===neutral&&all('.edit-history li').length===1,'preview reversible');
              film.dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));assert(el('.developed').style.filter!==neutral,'hover preview');
              film.dispatchEvent(new PointerEvent('pointerout',{bubbles:true}));assert(el('.developed').style.filter===neutral,'hover exit');
              act('film-stock','cinema');const fullLook=el('.developed').style.filter;assert(fullLook!==neutral,'applied film');
              set('[data-key=filmAmount]','45');const blend=el('.developed').style.filter;assert(blend!==neutral&&blend!==fullLook,'strength preview');
              act('snapshot');act('save-snap',null,modal());act('edit-step','undo');assert(el('[data-key=filmAmount]').value==='100','one step');
              const snap=el('[data-act=restore-snap]');
              assert(!snap.classList.contains('current')&&snap.getBoundingClientRect().width>140,'snapshot list spans panel');
              snap.focus();assert(el('.developed').style.filter===blend&&el('[data-key=filmAmount]').value==='100','snapshot preview leaves recipe untouched');
              window.dispatchEvent(new Event('blur'));assert(snap.checkVisibility()&&el('.look-preview').hidden&&el('.developed').style.filter===fullLook,'window blur keeps snapshots and ends preview');
              act('restore-snap','0');assert(el('.developed').style.filter===blend,'snapshot restore');
              act('edit-tool','basic',el('.inspector-rail'));await page('[data-adjustment-section=light] .adjustment-disclosure');const basic=el('.rail-tool[data-val=basic]');
              assert(document.activeElement===basic&&el('[data-adjustment-section=whiteBalance] button').ariaExpanded==='true','first section and rail focus');
              const light='[data-adjustment-section=light] .adjustment-disclosure';
              tap(light);
              const slider=el('[data-key=ev]'), numeric=el('[data-adjustment=ev]');
              const box=slider.getBoundingClientRect(), readout=numeric.getBoundingClientRect();
              assert(box.top<=readout.top&&box.bottom>=readout.bottom&&box.width>readout.width*2,'slider and number share a single wide row');
              const rows=all('#adjustment-body-light .range'), bounds=rows.map(row=>row.getBoundingClientRect()), scrollBeforeScale=el('.inspector-content').scrollTop;
              assert(bounds.every((r,i)=>r.height===26&&(i===0||r.top-bounds[i-1].bottom===10)),'stable equal slider spacing');
              const ticks=slider.parentElement.querySelector('.range-ticks');
              assert(getComputedStyle(ticks).visibility==='hidden','scale hidden at rest');
              slider.focus();assert(getComputedStyle(ticks).visibility==='visible'&&ticks.children.length===21,'scale available at keyboard focus');
              assert(rows.every((r,i)=>r.getBoundingClientRect().top+el('.inspector-content').scrollTop===bounds[i].top+scrollBeforeScale),'scale never moves rows within the inspector, including native focus scroll');
              const curveTool=el('.rail-tool[data-val=tones]'), tip=el('.rail-tip');
              curveTool.dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));
              assert(!tip.hidden&&tip.textContent==='曲线'&&!curveTool.hasAttribute('title')&&getComputedStyle(tip).pointerEvents==='none','single passive tooltip');
              assert(tip.dataset.side==='left'&&getComputedStyle(tip,'::after').content!=='none'&&tip.getBoundingClientRect().right+6<curveTool.getBoundingClientRect().left,'tooltip and arrow are left of the button');
              const panel=el('#adjustment-body-light').getBoundingClientRect();
              assert(Math.abs(bounds[0].left-panel.left-(panel.right-bounds[0].right))<1,'tight equal slider insets');
              curveTool.dispatchEvent(new PointerEvent('pointerout',{bubbles:true}));
              assert(tip.hidden,'tooltip dismisses on leave');
              slider.blur();
              assert(el('[data-act=adjustment-reset][data-val=light]').disabled,'no reset available before edits');
              set('[data-adjustment=ev]','0.137');
              assert(el('[data-adjustment=ev]').value==='0.137','numeric input retains precision beyond slider steps');
              await wait(()=>!el('[data-act=adjustment-reset][data-val=light]').disabled);
              act('adjustment-reset','light');
              assert(el('[data-adjustment=ev]').value==='0'&&document.activeElement===el(light),'group reset restores only its values and keeps disclosure focus');
              act('edit-step','undo');assert(el('[data-adjustment=ev]').value==='0.137','group reset is undoable');
              act('edit-step','undo');
              key(el('.rail-tool[data-val=basic]'),'ArrowDown');await page('.curve-chart');assert(document.activeElement.dataset.val==='tones','keyboard navigates rail');
              act('edit-tool','grading');await page('[data-key=warmHighlights]');
              const base=el('.developed').style.filter;
              set('[data-adjustment=warmHighlights]','35');const grade=el('.developed').style.filter;
              assert(grade!==base,'numeric input applies grading');
              set('[name=adjustmentEnabled][data-key=grading]',false);
              assert(el('.developed').style.filter===base&&el('[data-key=warmHighlights]').matches(':disabled'),'toggle bypasses grading effects');
              set('[name=adjustmentEnabled][data-key=grading]',true);
              assert(el('.developed').style.filter===grade&&el('[data-key=warmHighlights]').value==='35','toggle preserves values');
              act('edit-step','undo');act('edit-step','undo');act('edit-step','undo');
              act('edit-tool','basic');await page('[data-key=ev]');
              assert(el(light).ariaExpanded==='true','right panel remembers disclosure');
            """)
            scenario("紧凑示波器、白平衡与蒙版分层", """
              assert(el('.docked .histogram svg').getBoundingClientRect().height===108,'docked histogram triple height');
              const scope=el('[data-act=scope-plot][data-val=histogram]');scope.focus();key(scope,'ArrowRight');
              const selectedStyle=getComputedStyle(document.activeElement);
              assert(selectedStyle.backgroundColor==='rgba(0, 0, 0, 0)'&&selectedStyle.boxShadow==='none'&&selectedStyle.borderBottomWidth==='2px','flat selected tab with no raised background');
              assert(el('.docked .vector-plot').getBoundingClientRect().height===144&&document.activeElement.dataset.val==='vector','docked vector triple height and keyboard selection');
              act('scopes');assert(el('.vector-plot',modal()).getBoundingClientRect().height===130,'detached plot height');
              act('scope-plot','histogram',modal());act('close',null,modal());
              const stacked=()=>{const menu=el('[name=wbMode]').getBoundingClientRect(),buttons=all('.wb-actions button').map(b=>b.getBoundingClientRect());assert(buttons.length===2&&buttons.every(b=>Math.abs(b.width-menu.width)<1&&Math.abs(b.left-menu.left)<1)&&buttons[0].bottom<buttons[1].top,'one full-width correction per row');assert(el('.wb-refinement').getBoundingClientRect().top-el('.wb-correction').getBoundingClientRect().bottom>=12,'correction refinement spacing');};stacked();
              assert(el('[name=wbPreset]').value===''&&el('[data-key=wbTemperature]').ariaLabel==='色温 K','no false daylight selection');
              set('[name=wbPreset]','cloudy');assert(el('[data-key=wbTemperature]').value==='6500'&&el('.wb-panel [role=status]').textContent.includes('阴天'),'RAW preset');
              const history=all('.edit-history li').length;
              set('[name=wbMode]','gray');stacked();assert(!el('[name=wbPreset]')&&all('.edit-history li').length===history,'choose method without editing');
              act('wb-pick','gray');key(el('[data-act=wb-pick]'),'Escape');assert(all('.edit-history li').length===history,'cancel picker without editing');
              act('wb-pick','gray');const image=el('[data-act=canvas-point]'), rect=image.getBoundingClientRect();image.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:rect.left+rect.width/2,clientY:rect.top+rect.height/2}));assert(el('[data-key=warmth]')&&all('.edit-history li').length===history+1,'sample unlocks refinement');
              act('edit-step','undo');act('edit-step','undo');set('[name=wbMode]','temperature');
              act('edit-tool','masks');await page('.mask-panel');
              assert(!el('[data-act=choose-mask]'),'empty layer list');
              el('.mask-create').open=true;const maskButtons=all('.mask-tool-grid button');assert(maskButtons.length===7&&maskButtons.every(b=>b.querySelector('svg'))&&new Set(maskButtons.map(b=>b.querySelector('path').getAttribute('d'))).size===7,'distinct mask tool icons with labels');act('add-mask','径向渐变');assert(el('.mask-stage').textContent.includes('拖动'),'geometric draw instructions');
              key(el('[data-act=cancel-selection]'),'Escape');assert(!el('[data-act=choose-mask]'),'cancel does not append a layer');
              el('.mask-create').open=true;act('add-mask','主体');assert(el('.mask-mark')&&!el('[data-act=choose-mask]'),'unadopted overlay only');
              act('mask-overlay');assert(!el('.mask-mark'),'overlay visibility separate');
              act('mask-adopt');assert(el('.mask-layer.selected')&&el('.mask-mark'),'one adopted layer');
              act('mask-review');assert(el('[data-act=mask-adopt]').disabled,'review alone does not edit');act('cancel-selection');
              el('.mask-create').open=true;act('add-mask','亮度范围');
              el('[data-mask-group=region]').open=true;set('[data-key=rangeLower]','90');
              assert(el('[data-mask-group=region]').open&&el('[data-key=rangeLower]').value==='74','range bounds and open state persist');
              el('.mask-manage').open=true;act('mask-op','delete');assert(all('.mask-layer').length===1,'delete selected only');
              act('edit-step','undo');assert(all('.mask-layer').length===2,'restore removed layer');
              for(let i=0;i<3;i++)act('edit-step','undo');act('canvas-tool-done');
              act('edit-tool','detail');await page('.detail-options');const checkbox=el('[name=detailOption][data-key=rawDetails]'),checkStyle=getComputedStyle(checkbox);assert(checkStyle.appearance==='none'&&checkStyle.boxShadow==='none'&&checkStyle.backgroundImage==='none','flat checkbox without native relief');set('[name=detailOption][data-key=rawDetails]',true);assert(el('[data-key=aiDenoise]').disabled&&el('[data-key=rawDetails]').checked,'detail mutual exclusion');act('edit-step','undo');assert(!el('[data-key=rawDetails]').checked&&!el('[data-key=aiDenoise]').disabled,'detail checkbox undo restores availability');
              act('edit-tool','basic');await page('[name=wbMode]');
            """)
            scenario("浮动工具条、邻片、裁切与参考对比", """
              const bar=el('.canvas-dock').getBoundingClientRect(),canvas=el('.canvas-panel').getBoundingClientRect();
              assert(bar.bottom<canvas.bottom&&bar.width<canvas.width&&Math.abs((bar.left+bar.right)-(canvas.left+canvas.right))<3,'floating dock centered');
              assert(el('[data-act=canvas-nav][data-val=previous]').disabled,'start of current group');
              el('[data-act=canvas-nav][data-val=next]').focus();assert(all('.neighbor-preview').filter(n=>n.checkVisibility()).length===1,'single adjacent preview');
              act('canvas-nav','next');assert(el('[data-key=filmAmount]').disabled,'separate photo recipe');act('canvas-nav','next');
              assert(el('[data-act=canvas-nav][data-val=next]').disabled,'end of group');
              key(el('#workspace'),'ArrowRight');assert(Studio.data.work==='d3','right arrow stops at the end');
              key(el('#workspace'),'ArrowLeft');assert(Studio.data.work==='d2','left arrow stays in the group');
              key(el('#workspace'),'ArrowRight');assert(Studio.data.work==='d3','right arrow moves to the next photo');
              act('canvas-nav','previous');act('canvas-nav','previous');
              assert(el('[data-act=canvas-nav][data-val=previous]').disabled&&!el('.filmstrip'),'start of group without an editing strip');
              assert(el('[data-key=filmAmount]').value==='45','draft survives round trip');
              const width=el('.edit-image').getBoundingClientRect().width;act('edit-zoom','in');assert(el('.edit-image').getBoundingClientRect().width>width,'zoom in');
              key(el('#workspace'),'0',{metaKey:true});assert(Math.abs(el('.edit-image').getBoundingClientRect().width-width)<1,'FIT');
              key(el('#workspace'),'c');assert(el('.canvas-tool-dock[data-canvas-expanded=crop]')&&!el('[data-val=compare][data-act=canvas-menu]')&&!S.compare,'expanded crop tool owns the canvas without comparison commands');
              const beforeCrop=JSON.stringify(Studio.edit(Studio.data.work).recipe);set('[name=crop]','4:5');key(el('[name=crop]'),'Escape');assert(!el('.canvas-tool-dock')&&JSON.stringify(Studio.edit(Studio.data.work).recipe)===beforeCrop,'crop Escape discards draft and restores the normal dock');
              act('canvas-menu','compare');set('[name=compareMode]','wipeVertical');set('[name=comparePosition]','73');
              assert(el('.comparison-layer')&&el('.dark-canvas').style.getPropertyValue('--compare-amount')==='73%','wipe position');
              for(const mode of ['reference','wipeHorizontal','mix','difference','checkerboard','sideTopBottom']) {
                set('[name=compareMode]',mode);
                assert(el('.dark-canvas').dataset.comparison===mode,'selected '+mode);
                if(mode==='reference')assert(!el('.developed')&&el('.reference-image'),'reference only');
                else if(mode==='sideTopBottom')assert(all('.canvas-fit').length===2,'two rows');
                else assert(el('.comparison-layer'),'composited images');
              }
              set('[name=compareMode]','sideLeftRight');act('compare-invert');assert(all('.canvas-fit').length===2,'side-by-side');act('canvas-menu-close');
              key(el('#workspace'),'v');assert(!el('.comparison-layer')&&all('.canvas-fit').length===1,'compare off');
              act('canvas-menu','ground');act('canvas-ground','浅灰');const bg=el('.edit-body').style.getPropertyValue('--ground');
              key(el('#workspace'),'b');assert(el('.edit-body').style.getPropertyValue('--ground')!==bg,'cycle background');
              await hash('library/project/river');await page('.contact-grid');act('photo','r1');act('workflow','edit');await page('.smart-panel');
              act('canvas-nav','next');assert(modal().open&&modal().textContent.includes('原片待找回'),'offline neighbor');
              act('relink','w1',modal());act('close',null,modal());assert(el('.edit-identity').textContent.includes('DJI_0348'),'cancel stays with current photo');
              act('workflow','library');await page('.contact-grid');
            """)
            scenario("调整、蒙版、裁切、候选采用与显式草稿导出", """
              act('photo','r1');act('multi');act('photo','b1');act('workflow','edit');await page('.edit-inspector');
              act('edit-tool','basic');await page('[data-adjustment-section=light] .adjustment-disclosure');if(el('[data-adjustment-section=light] .adjustment-disclosure').ariaExpanded==='false')act('adjustment-disclosure','light');set('[data-key=ev]','0.5');act('edit-tool','masks');await page('.mask-create');el('.mask-create').open=true;act('add-mask','亮度范围');
              assert(el('.mask-mark'),'mask preview');act('edit-step','undo');assert(!el('.mask-mark'),'undo layer');
              act('edit-step','redo');act('canvas-tool-done');act('canvas-crop');set('[name=crop]','1:1');act('canvas-tool-done');act('save-version');
              act('open-versions');await page('.version-row');
              assert(el('.version-row').textContent.includes('候选'),'saved independently');
              act('adopt',null,el('.version-row'));assert(el('.version-row').textContent.includes('当前采用'),'explicit adoption');
              act('return-adjustments');await page('[data-adjustment-section=light]');act('edit-tool','basic');await page('[data-adjustment-section=light] .adjustment-disclosure');if(el('[data-adjustment-section=light] .adjustment-disclosure').ariaExpanded==='false')act('adjustment-disclosure','light');set('[data-key=ev]','0.75');
              act('workflow','export');assert(modal().open&&modal().textContent.includes('导出哪个版本'),'draft decision');
              act('export-choice','draft',modal());await page('#export-frame[src]');
              const f=el('#export-frame');await wait(()=>f.contentDocument?.querySelector('#selected')?.textContent==='2 / 2');
              const doc=f.contentDocument;assert(el('#focus-name',doc).textContent==='DJI_0348.DNG','order');
              tap('#asset-rows .asset:nth-child(2) button',doc);
              assert(el('#focus-name',doc).textContent==='DSC_0712.ARW','second file');
              assert(el('#version',doc).selectedOptions[0].textContent==='初修 2','chosen draft');
              await wait(()=>all('img',doc).some(i=>i.complete&&i.naturalWidth));tap('#edit-layout',doc);assert(el('#layout-dialog',doc).open,'watermark dialog');tap('#cancel-layout',doc);
              tap('#submit',doc);assert(el('#job',doc).open,'job');const cancelled=f.contentWindow.location.hash;
              tap('#cancel-job',doc);assert(el('#retry',doc).hidden&&el('#job-title',doc).textContent.includes('已取消'),'cancel ends this batch');
              tap('#close-job',doc);tap('#submit',doc);assert(f.contentWindow.location.hash!==cancelled,'new submission gets its own receipt');
              await wait(()=>el('#job-title',doc).textContent==='本批交付结果');
              act('workflow','library');await page('.contact-grid');act('goto','settings/general');await page('[name=theme]');
              set('[name=theme]','light');assert(document.documentElement.dataset.theme==='light','theme');set('[name=theme]','dark');
            """)
            scenario("资料库备份、迁移、检索、检查与组片来源", """
              await hash('tools/package');act('backup-plan');act('backup-create',null,modal());assert(el('.utility-main').textContent.includes('河谷备份'),'backup');
              act('goto','tools/migration');await page('[data-act=migration-plan]');act('migration-plan');act('migrate',null,modal());act('migration-missing');act('migration-bind',null,modal());
              act('goto','tools/discovery');await page('[name=discoveryQuery]');set('[name=discoveryQuery]','水鸟');assert(all('.discovery-grid button').length===1,'scene query');
              act('discovery-inspect','b1');await page('[data-act=inspect-verdict]');act('inspect-verdict');act('write-verdict',null,modal());assert(el('.utility-main').textContent.includes('可用'),'evidence');
              act('goto','tools/groups');await page('[data-act=process]');act('process','dusk');await page('[name=processType]');
              set('[name=groupOption]','25 fps');assert(el('[data-act=group-run]').disabled,'stale preview');act('refresh-preview');act('group-run');
              await page('.jobs-page [data-act=job-detail]');await wait(()=>el('.jobs-page').textContent.includes('已完成'));
              act('job-detail');assert(modal().textContent.includes('DSC_0901')&&modal().textContent.includes('25 fps'),'frozen input');act('close',null,modal());
            """)
            scenario("原件伴随范围、独立交付任务与空选区", """
              await hash('library/project/river');act('photo','r1');act('selection-menu');act('original-review','selection',modal());
              assert(el('[name=copyPairs]',modal()).checked,'pair opt-in');act('copy-handoff',null,modal());
              await wait(()=>el('#export-frame').contentDocument?.querySelector('#original')?.getAttribute('aria-pressed')==='true');
              const frame=el('#export-frame'),doc=frame.contentDocument;assert(el('#selected',doc).textContent==='2 / 2','physical files');
              assert(el('#asset-rows',doc).textContent.includes('DJI_0348.JPG'),'companion filename');tap('#submit',doc);
              await wait(()=>frame.dataset.running==='true');act('workflow','library');await page('.contact-grid');
              act('photo','b1');act('workflow','export');await wait(()=>el('#export-frame')!==frame);
              act('goto','jobs');await page('.jobs-page');await wait(()=>all('.jobs-page .record').some(r=>r.textContent.includes('原件交付')&&r.textContent.includes('已完成')));
              const receipt=all('.jobs-page .record').find(r=>r.textContent.includes('原件交付'));act('job-detail',null,receipt);
              assert(modal().textContent.includes('DJI_0348.JPG')&&modal().textContent.includes('清单'),'receipt preserved');act('close',null,modal());
              await hash('library/project/river');act('photo','r1');act('multi');act('photo','r1');act('workflow','export');
              assert(modal().open&&modal().textContent.includes('选择导出范围'),'no implicit focused export');act('close',null,modal());act('multi');
            """)
            scenario("成片交付跨视图继续", """
              await hash('library/project/river');await page('.contact-grid');act('photo','r1');act('workflow','export');
              await wait(()=>el('#export-frame')?.contentDocument?.querySelector('#submit')?.checkVisibility());
              const frame=el('#export-frame'),doc=frame.contentDocument;
              await wait(()=>!el('#submit',doc).disabled);tap('#submit',doc);
              await wait(()=>frame.dataset.running==='true');assert(el('#job-note',doc).textContent.includes('交付继续'),'background delivery status');
              const name=el('#jobrows strong',doc).textContent;tap('#close-job',doc);
              await wait(()=>doc.activeElement===el('#show-job',doc));
              act('workflow','library');await page('.contact-grid');
              act('goto','jobs');await page('.jobs-page');
              await wait(()=>all('.jobs-page .record').some(row=>row.textContent.includes('成片导出')&&row.textContent.includes('已完成')));
              const rows=all('.jobs-page .record').filter(row=>row.textContent.includes('成片导出'));
              act('job-detail',null,rows[0]);assert(modal().textContent.includes(name),'same rendered file after navigation');
              act('close',null,modal());
            """)
            scenario("本机 AI 准备、取消、重试与独立候选", """
              await hash('edit/retouch');assert(el('.smart-panel')&&!el('.agent-panel'),'old retouch link opens smart presets');
              act('edit-tool','agent');await page('[name=aiPrompt]');assert(!el('.smart-panel')&&!el('[data-act=ai-review]'),'independent Agent panel');
              set('[name=aiPrompt]','清理画面右边的杂物');act('agent-send');assert(el('.chat-log').textContent.includes('右边的杂物'),'conversation reply');
              set('[name=aiPrompt]','保留人物轮廓');act('canvas-nav','next');assert(!el('.chat-turn')&&!el('[name=aiPrompt]').value,'private to photo');
              act('canvas-nav','previous');assert(el('[name=aiPrompt]').value==='保留人物轮廓'&&el('[data-act=ai-review]').disabled,'restore pending draft');
              act('agent-send');act('edit-tool','smart',el('.agent-panel'));await page('.smart-panel');
              act('edit-tool','agent');await page('[data-act=ai-review]');assert(all('.chat-turn.reply').length===2,'preserved conversation');
              act('ai-review');assert(modal().textContent.includes('需要准备'),'unavailable model');act('goto-close','settings/runtime',modal());
              await page('.settings-advanced');el('.settings-advanced').open=true;
              await page('[name=licenseAck]');set('[name=licenseAck]',true);act('prepare-runtime');await page('.jobs-page');
              await wait(()=>el('.jobs-page .record small')?.textContent.includes('已完成'));act('goto','edit/agent');await page('[data-act=ai-review]');
              set('[name=strict]',true);act('ai-review');assert(modal().textContent.includes('严格纪实保护'),'strict gate');act('close',null,modal());
              set('[name=strict]',false);act('ai-review');assert(modal().textContent.includes('保留人物轮廓')&&modal().textContent.includes('右边的杂物'),'review conversation context');act('run-ai',null,modal());await page('.jobs-page');
              act('job-detail');act('job-change',null,modal());assert(el('.jobs-page').textContent.includes('已取消'),'cancel');
              act('job-detail');act('job-change',null,modal());await wait(()=>el('.jobs-page .record small')?.textContent.includes('已完成'));act('job-detail');act('job-version',null,modal());await page('.version-row');
              assert(el('.version-row').textContent.includes('候选'),'AI candidate separate');
            """)
            browser("set", "viewport", "390", "844")
            scenario("窄窗暗房、外观与键盘", """
              await hash('settings/general');set('[name=theme]','light');await hash('edit/development');await page('.smart-panel');
              assert(document.documentElement.scrollWidth<=innerWidth&&document.documentElement.dataset.theme==='light','narrow light darkroom');
              const dock=el('.canvas-dock').getBoundingClientRect();
              assert(dock.left>=0&&dock.right<=innerWidth&&dock.bottom<=innerHeight,'all dock controls fit');
              const icons=all('.rail-tool');assert(icons.every(b=>b.offsetLeft===icons[0].offsetLeft)&&icons.at(-1).offsetTop>icons[0].offsetTop,'narrow vertical rail');
              icons[1].dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));
              const tip=el('.rail-tip'), tipBounds=tip.getBoundingClientRect(), iconBounds=icons[1].getBoundingClientRect();
              assert(!tip.hidden&&tip.classList.contains('rail-tip-stacked')&&tipBounds.left>=0&&tipBounds.right<=el('.inspector-content').getBoundingClientRect().left&&(tipBounds.bottom<iconBounds.top||tipBounds.top>iconBounds.bottom),'narrow tooltip stays outside the parameter pane');
              icons[1].dispatchEvent(new PointerEvent('pointerout',{bubbles:true}));
              el('[data-act=edit-tool][data-val=agent]').scrollIntoView();act('edit-tool','agent');await page('.agent-panel');
              const box=el('[name=aiPrompt]');box.focus();key(box,'b');assert(!el('.canvas-popover'),'typing stays in field');
              await hash('settings/general');set('[name=theme]','dark');await hash('edit/agent');assert(el('.chat-turn')&&document.documentElement.dataset.theme==='dark','same photo across themes');
              await hash('edit/basic');await page('[data-adjustment-section=light] .adjustment-disclosure');
              if(el('[data-adjustment-section=light] .adjustment-disclosure').ariaExpanded==='false')act('adjustment-disclosure','light');
              set('[data-adjustment=ev]','-0.35');
              const track=el('[data-key=ev]'), value=el('[data-adjustment=ev]'), row=track.getBoundingClientRect();
              assert(row.left>=0&&value.getBoundingClientRect().right<=innerWidth&&value.value==='-0.35','narrow number and track fit');
              track.focus();assert(document.activeElement===track,'focusable slider');value.focus();
              value.value='99';key(value,'Enter');assert(document.activeElement===value&&value.ariaInvalid==='true','invalid Return keeps numeric focus');
              key(value,'Escape');assert(value.value==='-0.35'&&value.ariaInvalid===null,'Escape cancels the edit');
              el('[data-adjustment-section=light]').scrollIntoView({block:'nearest'});
            """)
            if not editing_only and (adjustment_evidence := os.environ.get("RAWMASTER_UI_ADJUSTMENT_EVIDENCE")):
                browser("screenshot", str(Path(adjustment_evidence).resolve()))
            scenario("窄窗导航、筛选与空结果", """
              await hash('library/project/river');act('drawer');assert(el('.rail.revealed').getBoundingClientRect().width<390,'drawer');
              act('drawer');assert(!el('.rail.revealed'),'close drawer');act('drawer');
              act('goto','library/all');await page('.contact-grid');act('filters');assert(el('.inspector.revealed'),'mobile filters');
              set('[name=tag]','零匹配');assert(el('.empty'),'mobile empty');act('filters',null,el('.inspector'));assert(!el('.inspector.revealed'),'dismiss');
              assert(document.documentElement.scrollWidth<=innerWidth,'horizontal overflow');
            """)
            scenario("空白资料库、恢复与重新打开", """
              await hash('tools/package');act('package-switch');set('[name=demoPackage]','new');act('package-open',null,modal());
              await page('.empty');assert(el('.view-heading h1').textContent==='新项目','new empty library');
              assert(el('[data-act=workflow][data-val=edit]').disabled,'empty edit unavailable');
              await hash('tools/package');act('package-switch');set('[name=demoPackage]','本机资料库');act('package-open',null,modal());
              await page('.photo-card');await hash('tools/package');act('restore-backup');act('restore-new',null,modal());act('package-switch');
              assert(all('[name=demoPackage] option',modal()).some(o=>o.value==='河谷 · 恢复副本'),'backup restored to separate catalog');act('close',null,modal());
            """)
            browser("set", "viewport", "1440", "900")
            scenario("快速 Prompt 浮条形变、模板与范围", """
              withPhoto('r1');await hash('edit/development');await page('.canvas-dock');
              act('canvas-menu','compare');set('[name=compareMode]','wipeVertical');
              const normal = el('.canvas-dock').getBoundingClientRect();
              act('quick-open');const dock=el('#quick-prompt'), morph=dock.getAnimations().find(a=>a.effect.getKeyframes().some(frame=>frame.width&&frame.height));
              assert(morph,'surface animates');morph.pause();await morph.ready;morph.currentTime=morph.effect.getTiming().duration/2;
              const middle=dock.getBoundingClientRect();morph.finish();await wait(()=>!dock.classList.contains('quick-morphing'));
              const expanded=dock.getBoundingClientRect();
              assert(normal.width<middle.width&&middle.width<expanded.width&&normal.height<middle.height&&middle.height<expanded.height,`width and height both morph ${normal.width}×${normal.height} → ${middle.width}×${middle.height} → ${expanded.width}×${expanded.height}`);
              assert(Math.abs(expanded.bottom-normal.bottom)<1&&Math.abs(middle.bottom-normal.bottom)<1,'bottom edge stays anchored');
              const prompt=()=>el('[name=quickPrompt]');
              assert(!el('.canvas-dock [data-act=canvas-nav]')&&document.activeElement===prompt(),'replace controls and focus text');
              assert(el('#quick-scope').textContent==='整张照片'&&!el('.comparison-layer')&&el('[data-act=quick-whole]').getAttribute('aria-pressed')==='true','explicit whole scope');
              assert(prompt().getBoundingClientRect().height>=108&&el('.quick-model').getBoundingClientRect().width<110,'large text surface and compact model');
              key(prompt(),'Escape',{isComposing:true});assert(el('#quick-prompt'),'composition owns Escape');
              key(prompt(),'b');assert(!el('.canvas-popover'),'typing does not cycle background');
              act('quick-template','remove');
              assert(prompt().value.includes('［干扰物］')&&el('[data-act=quick-submit]').disabled,'editable template placeholder');
              set('[name=quickPrompt]','移除岸边路牌。');prompt().focus();prompt().setSelectionRange(prompt().value.length,prompt().value.length);
              el('.quick-menu[data-menu=phrases]').open=true;act('quick-template','water');
              assert(prompt().value.includes('移除岸边路牌。')&&prompt().value.includes('保留水面倒影。'),'short phrase preserves draft');
              act('quick-draw');assert(el('.quick-gesture')&&el('[data-act=quick-submit]').disabled,'pending rectangle blocks generation');
              key(el('[data-act=quick-draw]'),'Escape');assert(!el('.quick-gesture')&&el('#quick-prompt'),'Escape exits only drawing');
              el('.quick-menu[data-menu=selection]').open=true;act('quick-coordinates',null,el('#quick-prompt'));
              set('[name=w]','0');act('quick-set-coordinates',null,modal());
              assert(modal().open&&el('#quick-coord-error').textContent.includes('有效'),'invalid bounds keep waiting');
              set('[name=w]','38');set('[name=h]','24');act('quick-set-coordinates',null,modal());
              assert(el('#quick-scope').textContent==='矩形选区'&&el('.quick-outline').checkVisibility(),'keyboard rectangle');
              act('quick-close');assert(el('.comparison-layer')&&document.activeElement.dataset.act==='quick-open','restore comparison and focus');
              act('quick-open');assert(prompt().value.includes('保留水面倒影。')&&el('#quick-scope').textContent==='矩形选区','same-work draft restored');
              assert(!Studio.data.jobs.some(j=>j.quickPrompt),'entry, templates and ranges do not start tasks');
            """)
            scenario("快速 Prompt 本机准备、候选、采用与撤销", """
              Studio.data.prefs.flux.status='未安装'; Studio.data.prefs.flux.completed=0; Studio.data.prefs.flux.progress=0; render();
              const id=Studio.data.work, before=currentEdit().adopted, steps=currentEdit().past.length, recipe=JSON.stringify(currentEdit().recipe);
              act('quick-setup','runtime');await page('[name=fluxLicense]');set('[name=fluxLicense]',true);act('flux-start');
              await wait(()=>Studio.data.prefs.flux.status==='下载中');
              Object.assign(Studio.data.prefs.flux,{status:'就绪',progress:1,completed:Studio.data.prefs.flux.total});Studio.save();render();
              act('goto','edit/development');await page('#quick-prompt');
              assert(el('[name=quickPrompt]').value.includes('路牌')&&el('#quick-scope').textContent==='矩形选区','settings round trip');
              key(el('[name=quickPrompt]'),'Enter',{metaKey:true});await wait(()=>el('[data-act=quick-job]'));
              assert(currentEdit().adopted===before&&currentEdit().past.length===steps,'running never applies');
              await wait(()=>el('[data-act=quick-apply]'));assert(el('.quick-effect'),'composed candidate shown');
              act('quick-compare','before');assert(!el('.quick-effect'),'frozen base view');
              act('quick-compare','after');act('quick-inspect');assert(el('[data-act=quick-inspect]').getAttribute('aria-pressed')==='true','detail inspection');
              act('quick-apply');assert(!el('#quick-prompt')&&currentEdit().adopted!==before&&!!el('.quick-effect'),'adoption shows creative version');
              assert(currentEdit().past.length===steps+1&&JSON.stringify(currentEdit().recipe)===recipe,'one version-pointer step');
              key(el('#workspace'),'z',{metaKey:true});assert(currentEdit().adopted===before&&!el('.quick-effect'),'reversible adoption');
              assert(Studio.asset(id).online,'source retained');
            """)
            scenario("本机 AI 下载管理、暂停、删除与首次启动提示", """
              await hash('settings/runtime');
              Object.assign(Studio.data.prefs.flux,{status:'未安装',completed:0,progress:0,license:false,file:'',error:''});Studio.save();render();
              assert(el('[data-act=flux-start]').disabled,'license gates download');
              set('[name=fluxLicense]',true);await wait(()=>!el('[data-act=flux-start]').disabled);
              act('flux-start');await wait(()=>Studio.data.prefs.flux.status==='下载中');assert(el('.flux-progress'),'download progress visible');
              act('flux-pause');assert(Studio.data.prefs.flux.status==='已暂停','pause state');
              act('flux-resume');assert(Studio.data.prefs.flux.status==='下载中','resume state');
              Object.assign(Studio.data.prefs.flux,{status:'就绪',progress:1,completed:Studio.data.prefs.flux.total});Studio.save();render();
              assert(el('[data-act=flux-delete]')&&el('[data-act=flux-verify]'),'ready actions');
              act('flux-first-run');assert(modal().textContent.includes('9.58 GiB')&&modal().textContent.includes('不会上传'));act('flux-first-later');
              assert(Studio.data.prefs.flux.firstRunShown,'first-run dismissed');
              act('flux-delete');assert(modal().textContent.includes('删除本机模型'));act('flux-delete-confirm');
              assert(Studio.data.prefs.flux.status==='未安装'&&Studio.data.prefs.flux.completed===0,'delete resets model');
              Object.assign(Studio.data.prefs.flux,{status:'就绪',progress:1,completed:Studio.data.prefs.flux.total,license:true});Studio.save();
              await hash('edit/development');await page('[data-act=quick-open]');
            """)
            scenario("快速 Prompt 云端确认、换片、未知结果和重试", """
              const id=Studio.data.work;
              act('quick-open');set('[name=quickModel]','seedream');
              if (el('[data-act=quick-setup]')) {
                act('quick-setup','cloud');await page('[name=cloudName]');set('[name=cloudName]','Seedream / 中国方舟');act('cloud-save');
                await hash('edit/development');await page('#quick-prompt');
              }
              set('[name=quickPrompt]','将整张照片调为冷蓝色，保留构图与高光。');
              act('quick-whole');
              const count=()=>Studio.data.jobs.filter(j=>j.quickPrompt).length, before=count();
              Object.defineProperty(navigator,'onLine',{configurable:true,value:false});dispatchEvent(new Event('offline'));
              assert(el('[data-act=quick-submit]').disabled&&el('#quick-status').textContent.includes('离线'),'offline cloud block');
              delete navigator.onLine;dispatchEvent(new Event('online'));
              act('quick-submit');assert(modal().textContent.includes('北京')&&modal().textContent.includes('当前构图')&&el('.quick-upload-image img',modal()),'inspect actual scope before submit');
              act('close',null,modal());assert(count()===before,'cancel approval creates no job');
              act('quick-submit');act('quick-cloud-confirm',null,modal());assert(count()===before+1,'explicit one cloud request');
              const job=Studio.data.jobs.find(j=>j.quickPrompt&&j.photo===id&&!j.quickPrompt.reviewed);
              job.due=Date.now()+60000;act('quick-job','cancel');
              assert(job.state==='unknown'&&el('#quick-prompt').textContent.includes('结果待核对'),'cloud cancel is not a claimed refund or failure');
              act('quick-job','reconcile');assert(count()===before+1,'reconcile does not resubmit');
              act('quick-close');withPhoto('b1');render();act('quick-open');assert(el('[name=quickPrompt]').value===''&&!el('.quick-effect'),'other photo is isolated');
              await wait(()=>job.state==='done');assert(!el('[data-act=quick-apply]'),'late event cannot show here');
              act('quick-close');withPhoto(id);render();act('quick-open');assert(el('[data-act=quick-apply]'),'review on original photo');
              act('quick-discard');assert(currentEdit().versions.find(v=>v.id===job.result).discarded,'discard only candidate');
              set('[name=quickPrompt]','改变背景。');act('quick-submit');act('quick-cloud-confirm',null,modal());
              const failed=Studio.data.jobs.find(j=>j.quickPrompt&&j.photo===id&&!j.quickPrompt.reviewed);
              failed.due=Date.now()+60000;act('goto','jobs',el('#quick-prompt'));await page('.jobs-page');
              act('job-detail',failed.id);act('job-change','fail/'+failed.id,modal());act('job-detail',failed.id);
              act('job-change','retry/'+failed.id,modal());await page('[name=quickPrompt]');
              assert(el('[name=quickPrompt]').value==='改变背景。'&&count()===before+2&&el('#quick-status').textContent.includes('失败'),'retry resumes draft before a new cloud approval');
            """)
            scenario("快速 Prompt 过期候选、原版本预览与采用边界", """
              set('[name=quickModel]','flux');set('[name=quickPrompt]','将风景处理成轻微冷调。');act('quick-submit');
              const j=quickTask();act('quick-close');await hash('edit/basic');set('[data-key=ev]','0.7');
              await wait(()=>j.state==='done');act('quick-open');
              assert(el('[data-act=quick-apply]').disabled&&el('#quick-prompt').textContent.includes('提交时不同'),'changed draft blocks late adoption');
              act('quick-inspect-version');await page('.version-row');
              assert(S.versionView===j.result&&el('.quick-effect'),'inspect frozen creative candidate as a separate version');
              assert(el('[data-act=adopt][data-val="'+j.result+'"]').disabled,'versions use the same admission rule');
              act('return-adjustments');await page('[data-act=quick-open]');act('quick-open');act('quick-discard');
            """)
            browser("set", "viewport", "1100", "720")
            scenario("快速 Prompt 已有蒙版、严格纪实和窄窗", """
              act('quick-close');await hash('edit/masks');await page('.mask-create');el('.mask-create').open=true;act('add-mask','亮度范围');act('canvas-tool-done');
              act('quick-open');await wait(()=>!el('.canvas-dock').classList.contains('quick-morphing'));
              el('.quick-menu[data-menu=selection]').open=true;act('quick-mask',null,el('#quick-prompt'));act('quick-use-mask',null,modal());
              assert(el('#quick-scope').textContent.includes('蒙版')&&el('.quick-outline').checkVisibility(),'confirmed mask scope');
              act('quick-close');await hash('edit/agent');conversation().strict=true;
              act('quick-open');assert(el('#quick-status').textContent.includes('严格纪实')&&el('[data-act=quick-submit]').disabled,'strict protect');
              const rect=el('#quick-prompt').getBoundingClientRect(), canvas=el('.canvas-panel').getBoundingClientRect();
              assert(rect.left>=canvas.left&&rect.right<=canvas.right&&rect.bottom<=innerHeight,'1100 viewport');
              conversation().strict=false;act('quick-close');
            """)
            browser("set", "viewport", "390", "844")
            scenario("快速 Prompt 浅色窄窗与键盘退出", """
              await hash('settings/general');set('[name=theme]','light');await hash('edit/development');await page('.canvas-dock');
              act('quick-open');await wait(()=>!el('.canvas-dock').classList.contains('quick-morphing'));
              const dock=el('#quick-prompt').getBoundingClientRect(), primary=el('[data-act=quick-submit]').getBoundingClientRect();
              assert(document.documentElement.dataset.theme==='light'&&dock.left>=0&&dock.right<=innerWidth&&primary.right<=dock.right,'light narrow view');
              key(document.activeElement,'Escape');assert(document.activeElement.dataset.act==='quick-open'&&!el('#quick-prompt'),'keyboard exit');
            """)
            browser("set", "media", "light", "reduced-motion")
            scenario("减少动态效果时快速 Prompt 直接展开", """
              assert(matchMedia('(prefers-reduced-motion: reduce)').matches,'reduced motion emulation');
              act('quick-open');assert(!el('.canvas-dock').getAnimations().length,'no geometry animation');
              assert(document.activeElement.name==='quickPrompt','same focus under reduced motion');
              act('quick-close');
            """)
            browser("open", host + EXPORT)
            scenario("导出 200 / 201 张、千张筛选与离线原件", """
              set('#sample-size','201');assert(el('#submit').disabled&&el('#limit-count').textContent.includes('多选了 1 张'),'201 blocked');
              tap('#limit-selection');assert(!el('#submit').disabled&&el('#selected').textContent==='200 / 201','explicit trim');
              set('#sample-size','1200');set('#selection-search','RIVER_1200');assert(!el('#selection-summary').hidden,'large search');assert(el('#submit').disabled,'filter keeps selection');
              set('#sample-size','3');tap('#original');assert(el('#count').textContent.includes('待找回'),'offline');set('#copy-mode','manifest');
              assert(el('#submit').textContent==='输出清单'&&!el('#submit').disabled,'manifest with offline inputs');
              assert(document.documentElement.scrollWidth<=innerWidth,'narrow export overflow');
            """)
            if not editing_only:
                scenario("成片中断前冻结字面名称、版本与发布票据", """
                  tap('#render');set('#folder','client');set('#template','{name}.proof-{index}');
                  tap('#asset-rows .asset:nth-child(2) button');
                  tap('#submit');await wait(()=>job.items[0].state==='待核验');
                  const first=job.items[0];sessionStorage.setItem('qa.photo',JSON.stringify({id:job.id,
                    names:job.items.map(r=>r.name),versions:job.items.map(r=>r.versionID),file:first.ticket.fileID,
                    folder:job.directory,focus:el('#focus-name').textContent}));
                  const saved=JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.batch.'+job.id));
                  assert(saved.running&&saved.items[0].state==='待核验'&&!saved.items[0].acknowledged,'last persisted state before exit');
                  el('#job-demo').open=true;setTimeout(()=>el('#interrupt-job').click(),50);
                """)
                scenario("重开认领已发布文件、焦点及逐张离线原因", """
                  const before=JSON.parse(sessionStorage.getItem('qa.photo'));
                  await wait(()=>job?.phase==='interrupted'&&el('#job').open&&!job.running);
                  assert(job.id===before.id&&JSON.stringify(job.items.map(r=>r.name))===JSON.stringify(before.names),'same literal names and batch');
                  assert(job.directory===before.folder&&JSON.stringify(job.items.map(r=>r.versionID))===JSON.stringify(before.versions),'same folder and versions');
                  assert(job.items[0].state==='已核验'&&PhotoDelivery.fileAt(job,job.items[0].name).fileID===before.file,'published before ACK');
                  assert(job.items[1].state==='待继续'&&job.items[2].state==='待找回'&&el('#retry').textContent.includes('1'),'pending vs offline');
                  assert(el('#focus-name').textContent===before.focus&&el('#selected').textContent==='3 / 3','original view');
                  tap('#close-job');await wait(()=>document.activeElement===el('#show-job'));set('#folder','pictures');set('#template','new-{index}');tap('#show-job');
                  el('#job-demo').open=true;tap('#disconnect-job');assert(el('#retry').disabled&&document.activeElement===el('#job-volume'),'offline focus and blocked action');
                  assert(document.documentElement.scrollWidth<=innerWidth&&el('#job').getBoundingClientRect().right<=innerWidth&&matchMedia('(prefers-color-scheme:light)').matches,'narrow light');
                """)
                evidence = os.environ.get("RAWMASTER_UI_DELIVERY_EVIDENCE")
                if evidence:
                    folder = Path(evidence)
                    folder.mkdir(parents=True, exist_ok=True)
                    browser("screenshot", str(folder / "continuation-offline-light.png"))
                browser("click", "#mount-other")
                browser("press", "Enter")
                scenario("窄窗同路径另一卷授权失败，焦点留在接回操作", """
                  assert(!job.volumeOnline&&!job.running&&el('#job-title').textContent.includes('离线'),'foreign volume remains offline');
                  assert(el('#job-reason').textContent==='接回提交时使用的输出目录，然后继续。'&&el('#mount-observation').textContent.includes('另一卷')&&document.activeElement===el('#job-volume')&&el('#retry').disabled,'native offline message, simulation evidence, focus and blocked write');
                  assert(job.target.device===job.offeredTarget.device&&job.target.directoryID===job.offeredTarget.directoryID&&job.target.volumeID!==job.offeredTarget.volumeID,'another volume at the same path even with the same directory and device numbers');
                  assert(PhotoDelivery.targetIssue(job.target,{...job.target,directoryID:'other-directory'}).includes('目录不符'),'original volume with a substituted directory also fails');
                  assert(matchMedia('(prefers-color-scheme:light)').matches&&el('#job').getBoundingClientRect().right<=innerWidth,'compact light');
                """)
                if evidence:
                    browser("screenshot", str(folder / "volume-substitute-light.png"))
                browser("reload")
                scenario("接回目标、单项写入重试与原片找回", """
                  const before=JSON.parse(sessionStorage.getItem('qa.photo'));
                  await wait(()=>el('#job').open&&job.id===before.id);
                  assert(!job.volumeOnline&&job.directory===before.folder&&el('#folder').value==='pictures','new draft and frozen destination');
                  assert(el('#job-reason').textContent.includes('接回提交时使用的输出目录')&&job.reconnectIssue.includes('另一卷'),'reopen keeps the failed grant');
                  el('#job-demo').open=true;tap('#mount-original');assert(!job.volumeOnline&&el('#retry').disabled,'mount change alone does not grant access');
                  tap('#job-volume');assert(!job.running&&el('#retry').textContent.includes('1')&&document.activeElement===el('#retry'),'explicit resume after reconnect');
                  tap('#retry');el('#job-demo').open=true;tap('#fail-job');
                  await wait(()=>!job.running&&job.items[1].state==='写入失败');
                  assert(job.items[0].state==='已核验'&&el('#retry').textContent.includes('重试'),'retain first result after failure');
                  tap('#jobrows li:nth-child(3) button');assert(!job.running&&el('#retry').textContent.includes('2'),'relink one frozen source');
                  tap('#retry');await wait(()=>job.phase==='done');
                  assert(job.items.every(r=>r.state==='已核验')&&JSON.stringify(job.items.map(r=>r.name))===JSON.stringify(before.names),'frozen outputs');
                  assert(PhotoDelivery.fileAt(job,job.items[0].name).fileID===before.file,'already verified output kept');
                """)
                browser("set", "media", "dark")
                browser("set", "viewport", "1180", "760")
                scenario("同名同内容的外来文件保留、取消区分中断", """
                  tap('#close-job');set('#template','{name}.v3-{index}');tap('#submit');
                  await wait(()=>job.items[0].state==='已核验'&&job.items[1].state==='处理中');
                  el('#job-demo').open=true;tap('#conflict-job');
                  const row=job.items[1],foreign=PhotoDelivery.fileAt(job,row.name);
                  assert(!job.running&&row.state==='同名文件待核对'&&foreign.content===row.ticket.content&&foreign.fileID!==row.ticket.fileID,'reject identical bytes from another writer');
                  tap('#recheck-job');assert(PhotoDelivery.fileAt(job,row.name).fileID===foreign.fileID,'retain conflicting file');
                  assert(matchMedia('(prefers-color-scheme:dark)').matches&&el('#job').getBoundingClientRect().right<=innerWidth,'desktop dark');
                  sessionStorage.setItem('qa.cancel',JSON.stringify({id:job.id,name:job.items[0].name,file:job.items[0].ticket.fileID}));
                """)
                if evidence:
                    browser("screenshot", str(folder / "continuation-conflict-dark.png"))
                scenario("解除占位后仍需明确继续", """
                  tap('#restore-conflict');assert(!job.running&&job.items[1].state==='待继续','new work requires action');
                  const name=job.items[1].name;tap('#retry');assert(job.items[1].name===name,'prepared name fixed');
                  tap('#cancel-job');assert(job.phase==='cancelled'&&el('#retry').hidden,'terminal cancellation');
                """)
                browser("reload")
                scenario("取消回执重开、已核验文件与键盘返回", """
                  const saved=JSON.parse(sessionStorage.getItem('qa.cancel'));
                  await wait(()=>job?.id===saved.id);if(!el('#job').open)tap('#show-job');
                  assert(job.phase==='cancelled'&&!job.running&&el('#retry').hidden,'remains cancelled on reload');
                  assert(job.items[0].state==='已核验'&&PhotoDelivery.fileAt(job,saved.name).fileID===saved.file,'completed file kept');
                  el('#close-job').focus();
                """)
                browser("press","Tab")
                browser("press","Escape")
                scenario("Escape 返回任务入口、重名策略保留完整字面基名", """
                  await wait(()=>!el('#job').open&&document.activeElement===el('#show-job'));
                  const before=JSON.parse(sessionStorage.getItem('qa.photo'));
                  set('#folder','client');set('#template','{name}.proof-{index}');set('#collision','skip');
                  assert(el('#submit').disabled&&el('#count').textContent.includes('跳过 3 张'),'original skip policy');
                  set('#collision','rename');tap('#submit');
                  assert(job.items.every((r,i)=>before.names[i].endsWith('.jpg')&&r.name===before.names[i].slice(0,-4)+'-2.jpg'),'preserve dots and ordinal while allocating suffix');
                  assert(PhotoDelivery.fileAt(job,before.names[0]).fileID===before.file,'foreign result kept');
                  tap('#cancel-job');
                """)
                browser("open",host+ENTRY)
                scenario("制作任务保留原批、资料库可先换片", """
                  await hash('library/project/river');await page('.contact-grid');
                  if(el('[data-act=multi]').getAttribute('aria-pressed')==='true')act('multi');
                  act('photo','r1');act('multi');act('photo','b1');act('multi');act('workflow','export');
                  await wait(()=>el('#export-frame')?.contentDocument?.querySelector('#submit')?.checkVisibility());
                  const frame=el('#export-frame'),doc=frame.contentDocument;
                  set('#template','submit.{name}.{index}',doc);tap('#submit',doc);
                  await wait(()=>frame.dataset.receipt);const id=frame.dataset.receipt;
                  const record=()=>JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.batch.'+id));
                  await wait(()=>record()?.items[0].state==='待核验');
                  const pending=record();assert(pending.items.length===2&&!pending.items[0].acknowledged,'published before acknowledgement');
                  el('#job-demo',doc).open=true;tap('#disconnect-job',doc);tap('#close-job',doc);
                  act('workflow','library');await page('.contact-grid');act('photo','m1');act('goto','jobs');await page('.jobs-page');
                  await wait(()=>Studio.data.jobs.find(j=>j.photoReceipt===id)?.state==='unknown');
                  sessionStorage.setItem('qa.job',JSON.stringify({id,context:activeIDs(),focus:Studio.data.work,name:pending.items[0].name,
                    first:pending.items[0].ticket,names:pending.items.map(r=>r.name),versions:pending.items.map(r=>r.versionID)}));
                """)
                browser("reload")
                scenario("从制作任务重开，授权同路径的另一卷仍保留原票据", """
                  const saved=JSON.parse(sessionStorage.getItem('qa.job'));await page('.jobs-page');
                  const receipt='delivery-'+saved.id;act('job-detail',receipt);assert(modal().textContent.includes(saved.name),'prior receipt');
                  act('reopen-delivery',receipt,modal());await wait(()=>el('#export-frame')?.contentDocument?.querySelector('#job')?.open);
                  const frame=el('#export-frame'),doc=frame.contentDocument;assert(frame.dataset.receipt===saved.id&&el('#jobrows strong',doc).textContent===saved.name,'exact task');
                  render();assert(el('#export-frame')===frame&&el('#job',doc).open,'normal redraw retains the receipt and its focus');
                  el('#job-demo',doc).open=true;tap('#mount-other',doc);assert(doc.activeElement===el('#job-volume',doc),'authorize the offered directory');
                """)
                browser("press","Enter")
                scenario("另一卷授权后不认领已发布文件，也不开始余项", """
                  const saved=JSON.parse(sessionStorage.getItem('qa.job')),doc=el('#export-frame').contentDocument;
                  const batch=JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.batch.'+saved.id)),first=batch.items[0];
                  const file=JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.studio.file.'+batch.folder+'/'+saved.name));
                  assert(!batch.volumeOnline&&!batch.running&&!first.acknowledged&&first.state==='待核验'&&!batch.items[1].ticket,'no reads claimed and no second write');
                  assert(first.ticket.fileID===saved.first.fileID&&file.fileID===saved.first.fileID&&file.content===saved.first.content,'original ticket and published file survive');
                  assert(el('#job-reason',doc).textContent==='接回提交时使用的输出目录，然后继续。'&&el('#mount-observation',doc).textContent.includes('另一卷')&&doc.activeElement===el('#job-volume',doc)&&el('#retry',doc).disabled,'native message and focus');
                  assert(matchMedia('(prefers-color-scheme:dark)').matches&&el('#job',doc).getBoundingClientRect().right<=doc.documentElement.clientWidth,'wide dark');
                """)
                if evidence:
                    browser("screenshot", str(folder / "volume-substitute-dark.png"))
                scenario("从同一任务接回以新设备号重挂的原卷", """
                  const saved=JSON.parse(sessionStorage.getItem('qa.job')),frame=el('#export-frame'),doc=frame.contentDocument;
                  assert(frame.dataset.receipt===saved.id&&el('#job',doc).open&&doc.activeElement===el('#job-volume',doc),'same task and failed grant still focused');
                  el('#job-demo',doc).open=true;tap('#mount-original',doc);
                  const batch=JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.batch.'+saved.id));
                  assert(!batch.volumeOnline&&!batch.running&&batch.target.device!==batch.offeredTarget.device,'remount alone cannot authorize');
                  assert(batch.target.volumeID===batch.offeredTarget.volumeID&&batch.target.directoryID===batch.offeredTarget.directoryID,'same stable identities');
                  assert(el('#retry',doc).disabled&&doc.activeElement===el('#job-volume',doc),'grant requires explicit action');
                """)
                browser("press","Space")
                scenario("核对原卷先认领待核验文件，仍等待明确继续", """
                  const saved=JSON.parse(sessionStorage.getItem('qa.job')),doc=el('#export-frame').contentDocument;
                  const record=()=>JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.batch.'+saved.id));
                  const batch=record();assert(batch.volumeOnline&&!batch.running&&batch.items[0].state==='已核验'&&batch.items[0].ticket.fileID===saved.first.fileID,'adopt only the published file');
                  assert(batch.items[1].state==='待继续'&&!batch.items[1].ticket&&doc.activeElement===el('#retry',doc),'pending item still has no ticket');
                  await new Promise(ok=>setTimeout(ok,1100));assert(!record().running&&!record().items[1].ticket,'no automatic write across the simulated publication deadline');
                """)
                if evidence:
                    browser("screenshot", str(folder / "volume-original-dark.png"))
                scenario("明确继续余项并返回资料库改选后的照片", """
                  const saved=JSON.parse(sessionStorage.getItem('qa.job')),doc=el('#export-frame').contentDocument;
                  const record=()=>JSON.parse(localStorage.getItem('rawmaster.export.delivery.v1.batch.'+saved.id));
                  tap('#retry',doc);await wait(()=>el('#job-title',doc).textContent==='本批交付结果');
                  const done=record();assert(done.items.every(r=>r.acknowledged)&&JSON.stringify(done.items.map(r=>r.name))===JSON.stringify(saved.names)&&JSON.stringify(done.items.map(r=>r.versionID))===JSON.stringify(saved.versions),'frozen names and versions');
                  tap('#close-job',doc);act('workflow','library');await page('.contact-grid');
                  assert(JSON.stringify(activeIDs())===JSON.stringify(saved.context)&&Studio.data.work===saved.focus,'browse selection and focus preserved');
                """)
            browser("set", "viewport", "1440", "900")
            scenario("界面规范画廊：令牌、四态与外观", """
              await hash('tools/design');await page('.ds-page');
              const slider=el('[data-ds-slider][data-value="0.35"]'),number=slider.querySelector('.ds-number');
              assert(el('.ds-page').textContent.includes('26 + 6')&&el('.ds-page').textContent.includes('AppDesign'),'token tables present');
              assert(Math.round(slider.getBoundingClientRect().height)===32,'slider keeps 26 track plus 6 scale');
              number.value='99';number.dispatchEvent(new Event('change',{bubbles:true}));
              assert(number.getAttribute('aria-invalid')==='true','out-of-range value flagged');
              key(number,'Escape');
              assert(number.value==='0.35'&&number.getAttribute('aria-invalid')==='false','escape restores value');
              const check=el('.ds-check');tap('.ds-check');assert(check.getAttribute('aria-checked')==='false','flat checkbox toggles');
              tap('.ds-tabs [role=tab]:nth-child(2)');assert(all('.ds-tabs [role=tab]')[1].getAttribute('aria-selected')==='true','tabs switch');
              tap('.ds-section-toggle');assert(el('.ds-section-body').hidden===true,'section collapses');
              await hash('settings/general');await page('select[name=theme]');set('[name=theme]','dark');
              await hash('tools/design');await page('.ds-page');
              assert(getComputedStyle(el('.ds-page')).color==='rgb(232, 232, 232)','dark ink applied');
              await hash('settings/general');await page('select[name=theme]');set('[name=theme]','system');
            """)
            browser("open", host + ENTRY)
            tabs = json.loads(browser("tab", "list", "--json"))["data"]["tabs"]
            workbench = next(tab for tab in tabs if tab["active"])
            for tab in tabs:
                if tab["type"] == "page" and tab["tabId"] != workbench["tabId"]:
                    browser("tab", "close", tab["tabId"])
            browser("tab", workbench["tabId"])
            scenario("Node DAG 九域作用域、图事务与显示状态", """
              await hash('library/project/river');act('photo','r1');act('workflow','edit');
              await page('.dag-scope-head');assert(!el('.edit-left .dag-library,.edit-left [data-act^=dag-]')&&all('.edit-left > section').map(n=>el('#'+n.getAttribute('aria-labelledby'),n).textContent).join('/')==='滤镜/快照/历史','darkroom left sidebar has only filters, snapshots and history');act('dag-view-toggle');await page('.dag-workspace');
              assert(dagTransform().scale===1&&!el('.dag-photo-status'),'one editable node opens at readable size without a routine status chip');
              menuAction('dag-preview');assert(el('.dag-photo-status').innerText.includes('不用于导出')&&el('[data-act=dag-preview-final]'),'explicit node output still warns with one editable node');act('dag-preview-final');assert(!el('.dag-photo-status'),'return to final hides routine single-node status');
              pickNode('output');act('dag-failure');assert(el('.dag-photo-status.failed [data-act=dag-retry]'),'a failure still offers retry with one editable node');act('dag-retry');assert(!el('.dag-photo-status'),'successful retry restores quiet single-node state');pickNode('grade');
              act('dag-fit');
              const nodes=()=>currentEdit().recipe.dag.nodes;
              const graph=()=>currentEdit().recipe.dag;
              set('[name=dagNumber][data-key=ev]',1.25);
              assert(nodes().find(n=>n.id==='grade').params.ev===1.25,'base node owns exposure');
              for(const category of dagPanels) {act('edit-tool',category,el('.inspector-rail'));await page('[name=dagNumber][data-key='+dagFields(category,dagNode().params)[0][0]+']');assert(all('[name=dagNumber]').length===dagFields(category,dagNode().params).length+1&&all('[name=dagNumber]').every(input=>input.dataset.node==='grade'),'all declared '+category+' values and node strength are node-scoped');assert(!el('.inspector-content [data-act=dag-reset],.inspector-content [data-act=dag-preview]'),category+' has no duplicate Graph commands');}
              act('edit-tool','basic',el('.inspector-rail'));await page('[name=dagNumber][data-key=ev]');
              addNodeMenu();act('dag-add','serial',modal());const serial=dagView().active;
              set('[name=dagNumber][data-key=ev]',0.5);
              assert(nodes().find(n=>n.id===serial).params.ev===0.5&&nodes().find(n=>n.id==='grade').params.ev===1.25,'node scope does not leak');
              pickNode('grade');assert(el('[name=dagNumber][data-key=ev]').value==='1.25','switch restores its value');
              const before=JSON.stringify(dagEvaluate(graph()));addNodeMenu();act('dag-add','parallel',modal());const branch=dagView().active;
              const mix=nodes().find(n=>n.kind==='mix');assert(mix.params.amount===0&&JSON.stringify(dagEvaluate(graph()))===before,'neutral parallel insertion');
              set('[name=dagNumber][data-key=ev]',1);pickNode(mix.id);set('[name=dagNumber][data-key=amount]',50);
              const final=JSON.stringify(dagEvaluate(graph()));act('dag-swap');act('edit-step','undo');
              assert(JSON.stringify(dagEvaluate(graph()))===final,'undo restores blend and port semantics');
              pickNode(branch);const rootBefore=JSON.stringify(graph());act('dag-menu');act('dag-preview',null,modal());await page('.dag-photo-status');assert(!modal().open,'node preview exits the menu');
              assert(dagView().target===branch&&JSON.stringify(graph())===rootBefore&&el('.dag-photo-status.intermediate').innerText.includes('不用于导出')&&el('.dag-floating'),'middle preview stays labelled without closing Graph or changing recipe');
              assert(el('.dag-photo-status').getBoundingClientRect().width<el('.edit-center').clientWidth,'workflow status is a compact chip, not a full-width banner');
              act('dag-preview-final');if(!el('.dag-floating'))act('dag-view-toggle');act('dag-fit');
              const pixelHistory=currentEdit().past.length;menuAction('dag-layout');
              assert(currentEdit().past.length===pixelHistory,'layout is outside pixel history');
              assert(dagPosition(nodes().find(n=>n.id===branch)).y>dagPosition(nodes().find(n=>n.id==='grade')).y&&dagPosition(mix).x>dagPosition(nodes().find(n=>n.id===branch)).x,'auto-layout separates layer branch and its merge');
              menuAction('dag-connect-menu');
              set('[name=dagFrom]',branch,modal());set('[name=dagTo]',branch,modal());set('[name=dagSlot]','image',modal());act('dag-connect-propose',null,modal());
              assert(el('[data-act=dag-connect-apply]').disabled&&el('.dag-status').textContent.includes('自身')&&JSON.stringify(graph())===rootBefore,'invalid graph cannot publish');
              act('dag-connect-cancel');assert(!S.dagConnectionDraft&&JSON.stringify(graph())===rootBefore,'cancel restores valid graph');
              menuAction('dag-connect-menu');set('[name=dagTo]','output',modal());act('dag-connect-disconnect',null,modal());
              assert(el('[data-act=dag-connect-apply]').disabled,'missing input cannot publish');act('dag-connect-cancel');
              sessionStorage.setItem('qa.dag',JSON.stringify({photo:Studio.data.work,branch,serial,mix:mix.id,rootBefore}));
            """)
            scenario("Node DAG 蒙版、组路径与模板身份", """
              const qa=JSON.parse(sessionStorage.getItem('qa.dag')), {branch,serial,rootBefore}=qa;
              const nodes=()=>currentEdit().recipe.dag.nodes,graph=()=>currentEdit().recipe.dag,mix=nodes().find(n=>n.id===qa.mix);
              assert(Studio.data.work===qa.photo&&JSON.stringify(graph())===rootBefore,'graph fixture and photo persist across scenario boundaries');
              pickNode(branch);act('edit-tool','masks');maskType('径向渐变');
              act('canvas-tool-done');assert(!nodes().find(n=>n.id===branch).mask&&JSON.stringify(graph())===rootBefore,'opening or choosing the current mask tool does not create an empty mask');act('edit-tool','masks');
              assert(S.canvasTool?.kind==='mask'&&el('.developed')&&el('.dag-floating.minimized'),'Mask expands on the photo and temporarily collapses Graph');
              assert(el('[name=dagNode]').disabled,'picker disables switching during a photo tool');changes.dagNode({value:'grade'});assert(dagView().active===branch&&dagView().selection.join()===branch&&S.canvasTool?.owner===branch,'pending photo tool refuses even a late scope change');act('canvas-tool-cancel');
              assert(dagView().mode==='graph'&&!nodes().find(n=>n.id===branch).mask,'mask cancel returns to Graph');
              act('edit-tool','masks');maskType('主体');act('canvas-tool-done');
              assert(dagView().mode==='graph'&&nodes().find(n=>n.id===branch).mask.kind==='主体','mask adoption is node-scoped');
              act('edit-tool','masks');foldTool('mask-more');act('canvas-mask-missing');assert(el('[data-act=canvas-tool-done]').disabled,'missing mask draft cannot be committed');act('canvas-mask-rebuild');act('canvas-tool-done');
              assert(!nodes().find(n=>n.id===branch).mask.missing,'asset retry clears missing state');
              dagView().selection=[serial];dagView().active=serial;render();menuAction('dag-group');
              const group=dagView().active;assert(nodes().find(n=>n.id===group).kind==='group','single-IO fragment groups');
              act('dag-enter',group);assert(dagView().path[0]===group,'enter group');act('dag-path','0');
              pickNode(group);act('dag-template-save','group');set('[name=dagTemplateName]','DAG 测试组',modal());act('dag-template-save-confirm',null,modal());
              const template=Studio.data.dagTemplates.at(-1);assert(template.kind==='group','save group template');
              pickNode('grade');const ambiguous=JSON.stringify(graph());menuAction('dag-template-library');act('dag-template-open',template.id,modal());act('dag-template-apply',null,modal());
              assert(JSON.stringify(graph())===ambiguous&&modal().open,'template refuses ambiguous fan-out');act('close',null,modal());
              pickNode(mix.id);const next=graph().edges.find(e=>e.from===mix.id).to,count=nodes().length;
              menuAction('dag-template-library');act('dag-template-open',template.id,modal());act('dag-template-apply',null,modal());const inserted=dagView().active;
              assert(nodes().length===count+1&&graph().edges.some(e=>e.from===mix.id&&e.to===inserted)&&graph().edges.some(e=>e.from===inserted&&e.to===next),'template inserts at current edge, not graph tail');
              act('dag-enter',group);const innerCount=dagCurrent().nodes.length;pickNode(dagCurrent().nodes.find(n=>n.kind==='grade').id);
              menuAction('dag-template-library');act('dag-template-open',template.id,modal());act('dag-template-apply',null,modal());assert(dagView().path.join()===group&&dagCurrent().nodes.length===innerCount+1,'template insertion preserves current group path');act('dag-path','0');
              const copiedIDs=nodes().filter(n=>n.kind==='group').flatMap(n=>dagAllNodes(n.graph).map(x=>x.node.id));
              assert(new Set(copiedIDs).size===copiedIDs.length,'template remaps internal IDs');
            """)
            scenario("Node DAG 批量、取消与修订冲突", """
              const qa=JSON.parse(sessionStorage.getItem('qa.dag')),nodes=()=>currentEdit().recipe.dag.nodes,graph=()=>currentEdit().recipe.dag;
              assert(Studio.data.work===qa.photo&&!dagError(graph()),'batch starts from the same valid photo workflow');
              pickNode('grade');const frozen=JSON.stringify(graph());act('workflow','library');await page('.contact-grid');
              act('photo','b1');act('selection-menu');assert(el('[data-act=dag-batch-menu]',modal()).disabled,'single photo cannot be a batch');act('close',null,modal());
              act('multi');act('photo',qa.photo);const selection=activeIDs().slice();
              const openBatch=()=>{act('selection-menu');act('dag-batch-menu',null,modal());};
              openBatch();assert(S.dagBatchSource.id===qa.photo&&S.dagBatchChosen.join()==='b1'&&modal().textContent.includes('源照片不写入'),'library focus is frozen as source; other selections alone are targets');
              set('[name=dagBatchOperation]','template',modal());assert(el('.dag-batch-template',modal()).checkVisibility()&&el('[name=dagBatchTemplate]',modal()).options.length>=2,'saved templates remain available to batch from the library');
              act('close',null,modal());assert(activeIDs().join()===selection.join()&&JSON.stringify(graph())===frozen,'cancel returns to the same selection and preserves source');
              openBatch();tap('.dag-menu-advanced summary',modal());act('dag-batch-samples','20',modal());
              act('dag-batch-preflight',null,modal());assert(modal().textContent.includes('20 张'),'batch full scope reviewed');act('dag-batch-start',null,modal());
              const batch=Studio.data.dagBatches.at(-1);await wait(()=>!batch.running);
              assert(batch.items.length===20&&batch.items.every(i=>i.state==='done'),'all 20 target versions created');
              act('dag-batch-undo',batch.id,modal());assert(batch.items.every(i=>i.state==='undone'),'batch undo restores each target');
              act('close',null,modal());act('selection-menu');act('dag-batch-results',batch.id,modal());assert(modal().textContent.includes('已撤销'),'batch results reopen from the library list');act('close',null,modal());
              openBatch();tap('.dag-menu-advanced summary',modal());act('dag-batch-samples','200',modal());act('dag-batch-preflight',null,modal());act('dag-batch-start',null,modal());
              const large=Studio.data.dagBatches.at(-1);act('dag-batch-cancel',large.id,modal());
              assert(large.items.length===200&&large.items.some(i=>i.state==='cancelled')&&!large.running,'200 target cancellation preserves completed items');
              act('dag-batch-conflict',null,modal());act('dag-batch-undo',large.id,modal());assert(large.items.some(i=>i.state==='conflict'),'undo refuses newer target revisions');
              act('close',null,modal());assert(activeIDs().join()===selection.join()&&JSON.stringify(graph())===frozen,'batch and rollback leave the library selection and source intact');act('workflow','edit');await page('.dag-scope-head');act('edit-tool','basic',el('.inspector-rail'));await page('[name=dagNumber]');pickNode('output');act('dag-failure');act('dag-retry');assert(!S.dagRenderFailed,'render failure retry');
              pickNode('grade');if(!el('.dag-floating'))act('dag-view-toggle');act('dag-fit');
              el('[data-dag-viewport]').focus();key(document.activeElement,'a',{metaKey:true});assert(dagView().selection.length>1&&!el('[name=dagNumber]'),'Graph multi-selection never broadcasts values');
              pickNode('grade');const stable=JSON.stringify(graph());el('[data-dag-viewport]').focus();key(document.activeElement,'0',{metaKey:true});assert(JSON.stringify(graph())===stable,'Graph fit is not a pixel edit');
              menuAction('dag-layout');assert(!dagError(graph()),'final graph validates');
            """)
            scenario("Node DAG 悬浮窗口、九域子域与画布工具事务", """
              const graph=()=>Studio.edit(Studio.data.work).recipe.dag, history=()=>Studio.edit(Studio.data.work).past.length;
              const base=JSON.stringify(graph()),past=history(),photo=Studio.data.work;
              act('edit-zoom','in');const fit=el('.canvas-fit');fit.scrollLeft=20;fit.scrollTop=10;
              const view={zoom:S.editZoom,left:fit.scrollLeft,top:fit.scrollTop},imageBox=el('.edit-image').getBoundingClientRect();
              dagTransform().y=10000;delete dagWindowFrame().layoutVersion;
              act('dag-view','photo');assert(!el('.dag-floating')&&el('.developed'),'close only Graph');if(!el('.dag-floating'))act('dag-view-toggle');await wait(()=>dagWindowFrame().layoutVersion===3);
              const graphViewport=el('.dag-viewport').getBoundingClientRect(),visibleCard=el('.dag-card.active').getBoundingClientRect();
              assert(dagTransform().scale===1&&dagTransform().framing==='readable'&&visibleCard.left>=graphViewport.left&&visibleCard.right<=graphViewport.right&&visibleCard.top>=graphViewport.top&&visibleCard.bottom<=graphViewport.bottom,'old blank view is migrated to readable scale with the active card in view');
              act('dag-fit');const initialCards=all('.dag-card').map(card=>card.getBoundingClientRect());assert(initialCards.length===graph().nodes.length&&initialCards.every(card=>card.left>=graphViewport.left-1&&card.right<=graphViewport.right+1&&card.top>=graphViewport.top-1&&card.bottom<=graphViewport.bottom+1),'explicit fit still contains all cards');
              act('dag-readable');act('dag-zoom','in');const manual={...dagTransform()};act('dag-view-toggle');act('dag-view-toggle');await wait(()=>el('.dag-stage'));assert(JSON.stringify(dagTransform())===JSON.stringify(manual),'reopening respects a deliberate manual zoom');act('dag-readable');
              assert(S.editZoom===view.zoom&&el('.canvas-fit').scrollLeft===view.left&&el('.canvas-fit').scrollTop===view.top&&el('.edit-image').getBoundingClientRect().width===imageBox.width,'Graph reopening preserves photo zoom, pan and geometry');
              const resize=el('.dag-window-resize');resize.focus();key(resize,'ArrowRight');
              act('dag-window-minimize');assert(el('.dag-floating.minimized'),'minimize');act('dag-window-minimize');
              assert(JSON.stringify(graph())===base&&history()===past&&Studio.data.work===photo,'window resize and collapse create no pixel history');
              act('canvas-crop');assert(el('.canvas-crop-box')&&el('.dag-floating.minimized'),'crop range and unobstructed collapsed Graph');
              const cropDraft=JSON.stringify(S.canvasTool.draft),film=el('[data-act=film-stock]');assert(film,'film fixture exists');film.closest('details').open=true;act('film-stock',film.dataset.val);assert(JSON.stringify(S.canvasTool.draft)===cropDraft&&JSON.stringify(graph())===base,'photo-level look cannot leak into a Crop draft');
              set('[name=canvasCropwidth]',70);set('[name=canvasCropheight]',60);set('[name=canvasCropx]',10);act('canvas-turn');
              assert(history()===past&&JSON.stringify(graph())===base,'Crop only changes draft');act('canvas-tool-cancel');assert(history()===past&&JSON.stringify(graph())===base,'Crop cancel discards draft');
              act('canvas-crop');set('[name=canvasCropwidth]',70);act('canvas-tool-done');assert(history()===past+1&&graph().nodes.find(n=>n.kind==='geometry').params.cropBox.width===70,'Crop finish commits one geometry edit');act('edit-step','undo');assert(JSON.stringify(graph())===base,'Crop undo restores graph');
              pickNode('grade');act('edit-tool','warper',el('.inspector-rail'));await page('.dag-warper-grid');
              assert(!el('[name=dagNumber]:invalid'),'valid initial grid values');el('.dag-warper-grid').focus();key(document.activeElement,'Enter');assert(dagNode().params.pins.length===1,'keyboard adds a scoped grid point');act('dag-warper-clear');
              act('edit-tool','color',el('.inspector-rail'));await page('[name=dagCategoryChoice]');set('[name=dagCategoryChoice]','RGB 矩阵');assert(all('[name=dagNumber]').length===10,'nine RGB matrix values plus node strength');
              pickNode(graph().nodes.find(n=>n.kind==='mix').id);assert(all('.inspector-rail [data-act=edit-tool]').length===1&&!el('.dag-warper-grid'),'Mixer does not inherit Corrector categories');
              set('[name=dagMixMode]','layer');for(const mode of dagBlendModes){set('[name=dagBlend]',mode);assert(dagNode().params['blend:layer']===mode,'Layer mode '+mode+' persists independently');}
              const mixer=dagNode().id,ids=new Set(graph().nodes.map(n=>n.id));act('dag-add-input');const owner=graph().nodes.find(n=>!ids.has(n.id)&&n.kind==='grade').id;
              assert(graph().nodes.find(n=>n.id===mixer).params['weight:layer2']===0,'additional Layer input is initially neutral');
              set('[name=dagNumber][data-key="weight:layer2"]',25);set('[name=dagBlend][data-slot=layer2]','multiply');act('dag-input-move','layer2:-1');
              assert(graph().edges.find(e=>e.to===mixer&&e.slot==='layer').from===owner&&dagNode().params.amount===25&&dagNode().params['blend:layer']==='multiply','moving an input preserves its weight and blend mode');
              pickNode(owner);const beforeMask=JSON.stringify(graph()),maskPast=history();act('edit-tool','masks');actions['quick-open']();assert(!quickPromptVisible()&&S.canvasTool.owner===owner,'Prompt cannot overlap a Mask transaction');
              maskType('亮度范围');set('[name=canvasMaskLow]',80);set('[name=canvasMaskHigh]',60);assert(el('[data-act=canvas-tool-done]').disabled,'inverted range cannot commit');set('[name=canvasMaskLow]',20);
              act('canvas-mask-op','subtract');act('canvas-mask-component');set('[name=canvasComponentOpacity]',40);act('canvas-component-invert','0');foldTool('mask-refine');set('[name=canvasRefinehairRefine]',30);
              assert(S.canvasTool.mask.components[0].op==='subtract'&&el('.canvas-mask-component .icon')&&el('[data-canvas-number=canvasRefinehairRefine]').value==='30','semantic group controls and numeric slider stay in sync');
              assert(S.canvasTool.owner===owner&&S.canvasTool.mask.components[0].opacity===40&&S.canvasTool.mask.components[0].invert&&S.canvasTool.mask.refine.hairRefine===30,'component and refinement are owner-scoped draft values');
              act('edit-step','undo',el('.canvas-tool-footer'));assert(!S.canvasTool.mask.refine?.hairRefine,'draft undo restores the mask');act('edit-step','redo',el('.canvas-tool-footer'));
              assert(history()===maskPast&&JSON.stringify(graph())===beforeMask,'mask draft never publishes early');act('canvas-tool-done');assert(history()===maskPast+1&&graph().nodes.find(n=>n.id===owner).mask.components[0].opacity===40,'Mask finish commits once');
              const masked=dagNode();addNodeMenu();tap('.dag-menu-advanced summary',modal());act('dag-outside',null,modal());assert(dagNode().id!==owner&&dagNode().mask.invert!==masked.mask.invert&&Object.keys(dagNode().params).length===0,'Outside is a new neutral Corrector with inverse copied coverage');
              const dependency=structuredClone(graph());dependency.nodes.find(n=>n.id===owner).mask={kind:'来自节点',reference:owner};assert(dagError(dependency).includes('自身'),'Mask self-reference is rejected');
              const beforeRemove=JSON.stringify(graph()),removePast=history();act('edit-tool','repair');assert(all('.canvas-remove-modes button .icon').length===4&&!el('[data-act=canvas-remove-preview]'),'four graphic modes, no irrelevant generation action');
              act('canvas-remove-kind','clone');markCenter();assert(el('[data-act=canvas-tool-done]').disabled,'Clone requires a sample');markCenter();assert(S.canvasTool.draft.repairs.at(-1).source,'second mark is the Clone sample');
              act('canvas-remove-kind','inpaint');markCenter();assert(el('[data-act=canvas-tool-done]').disabled,'Inpaint waits for a candidate');foldTool('remove-more');act('canvas-remove-fail');assert(S.canvasTool.removeState==='failed'&&el('[data-act=canvas-remove-preview]').textContent.includes('重试'),'candidate failure is explicit');act('canvas-remove-preview');
              assert(history()===removePast&&JSON.stringify(graph())===beforeRemove,'Remove preview is not published');act('canvas-tool-done');assert(history()===removePast+1&&Studio.edit(photo).recipe.repairs.length>=2,'Remove finish commits one ordered stage');act('edit-step','undo');assert(JSON.stringify(graph())===beforeRemove,'Remove undo restores original recipe');
              act('edit-tool','repair');const image=el('.edit-image'),box=image.getBoundingClientRect(),count=S.canvasTool.draft.repairs.length;image.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:box.left+box.width/2,clientY:box.top+box.height/2}));assert(S.canvasTool.draft.repairs.length===count+1,'one click creates exactly one repair mark');act('canvas-tool-cancel');
              pickNode('grade');act('edit-tool','basic',el('.inspector-rail'));act('edit-zoom','fit');act('dag-fit');assert(!dagError(graph()),'expanded feature graph remains valid');
            """)
            scenario("Node DAG 单行选择器、精简菜单与忽略撤销", """
              pickNode('grade');act('edit-tool','basic',el('.inspector-rail'));await page('[name=dagNumber][data-key=ev]');
              const before=JSON.stringify(currentEdit().recipe.dag),past=currentEdit().past.length,view={zoom:S.editZoom,left:el('.canvas-fit').scrollLeft,top:el('.canvas-fit').scrollTop};
              assert(!el('.dag-view-tabs')&&!el('.dag-scope-head [data-act=dag-menu]')&&all('.dag-picker-row > button').length===3,'one selector plus ignore and Graph, no duplicated menus or view tabs');
              act('dag-picker');assert(el('#dag-node-picker').matches(':popover-open')&&all('.dag-picker-list button').map(b=>b.dataset.val).join()===dagCurrent().nodes.filter(dagEditable).map(n=>n.id).join()&&el('.dag-picker-base [data-val=base]')&&all('.dag-picker-commands button').length===3,'editable node list, separate base correction and three common commands share one dropdown');
              key(document.activeElement,'Escape');assert(!el('#dag-node-picker').matches(':popover-open')&&document.activeElement===el('[name=dagNode]')&&el('.dag-floating'),'Escape closes only the picker and returns focus');
              act('dag-toggle-current','grade');assert(dagNode().enabled===false&&el('[data-act=dag-toggle-current]').getAttribute('aria-pressed')==='true'&&el('.dag-card[data-dag-card=grade]').classList.contains('bypass')&&currentEdit().past.length===past+1,'ignore is scoped, visible and one history step');
              assert(JSON.stringify(dagNode().params)===JSON.stringify(JSON.parse(before).nodes.find(n=>n.id==='grade').params),'ignore preserves node parameters');
              act('edit-step','undo');assert(JSON.stringify(currentEdit().recipe.dag)===before,'undo restores the original graph');
              pickNode('source');assert(el('[data-act=dag-toggle-current]').disabled&&el('[data-act=dag-toggle-current]').title.includes('固定'),'fixed stages explain why ignore is disabled');
              pickNode('grade');act('dag-menu');assert(all('.dialog-body > .dag-menu-grid > button',modal()).length===6&&!el('.dag-menu-advanced',modal()).open,'node menu has six first-level commands and folded advanced commands');act('close',null,modal());
              act('dag-picker');act('dag-picker-command','add',el('#dag-node-picker'));assert(modal().open&&!el('.dag-menu-advanced',modal()).open,'alternate insertion choices are folded in Add, not removed');act('close',null,modal());
              act('dag-view-toggle');assert(!el('.dag-floating')&&el('.developed')&&el('[data-act=dag-view-toggle]').getAttribute('aria-pressed')==='false','Graph toggle closes only the floating window');act('dag-view-toggle');
              assert(el('.dag-floating')&&el('[data-act=dag-view-toggle]').getAttribute('aria-pressed')==='true'&&S.editZoom===view.zoom&&el('.canvas-fit').scrollLeft===view.left&&el('.canvas-fit').scrollTop===view.top&&JSON.stringify(currentEdit().recipe.dag)===before,'Graph toggle restores without changing photo or recipe');
              act('dag-picker');act('dag-picker-command','layout',el('#dag-node-picker'));pickNode('source');act('dag-fit');
            """)
            browser("click", ".dag-card[data-dag-card=grade] .dag-node-title")
            scenario("Node DAG 真实节点点击与键盘选择联动", """
              assert(dagView().active==='grade'&&dagView().selection.join()==='grade'&&el('[name=dagNode]').textContent.includes('基础调色')&&el('.dag-node-title[data-val=grade]').getAttribute('aria-pressed')==='true','trusted pointer selection synchronizes graph, picker and inspector');
              const before=JSON.stringify(currentEdit().recipe.dag),past=currentEdit().past.length;
              const next=dagCurrent().nodes[(dagCurrent().nodes.findIndex(n=>n.id==='grade')+1)%dagCurrent().nodes.length];
              key(document.activeElement,'ArrowRight');assert(dagView().active===next.id&&el('[name=dagNode]').textContent.includes(next.name),'Graph keyboard selection synchronizes the picker');
              el('[data-dag-viewport]').focus();key(document.activeElement,'a',{metaKey:true});assert(dagView().selection.length>1&&el('[data-act=dag-toggle-current]').disabled&&el('[name=dagNode]').textContent.includes('已选')&&!el('[name=dagNumber]'),'multi-selection disables single-node ignore and parameter broadcasting');
              pickNode('grade');assert(JSON.stringify(currentEdit().recipe.dag)===before&&currentEdit().past.length===past,'selection creates no pixel history');
            """)
            node_x, node_y = browser("eval", "(() => {const r = document.querySelector('[data-dag-node=grade]').getBoundingClientRect(); return `${Math.round(r.x + r.width / 2)} ${Math.round(r.y + r.height / 2)}`;})()").strip('"').split()
            browser("mouse", "move", node_x, node_y)
            browser("mouse", "down", "right")
            browser("mouse", "up", "right")
            scenario("Node DAG 鼠标右键打开节点菜单", """
              const menu=el('#dag-context:popover-open');
              assert(menu?.textContent.includes('基础调色')&&menu.textContent.includes('Solo')&&!menu.textContent.includes('适合全图'),'right pointer opens the node menu rather than dragging or opening the canvas menu');
              key(document.activeElement,'Escape');
              assert(!menu.matches(':popover-open')&&document.activeElement===el('[data-dag-node=grade]'),'right-click menu Escape returns focus');
            """)
            browser("set", "viewport", "900", "360")
            scenario("Node DAG 短窗保留可关闭标题条", """
              assert(document.visibilityState==='visible','the active workbench must receive viewport changes');
              await wait(()=>el('.dag-floating.minimized')?.checkVisibility());
              assert(innerWidth===900&&innerHeight===360&&dagWindowShort()&&!el('.dag-viewport')&&el('.dag-window-head').textContent.includes('增高窗口'),'short window explains why the graph cannot expand');
              const box=el('.dag-floating').getBoundingClientRect();assert(box.top>=0&&box.bottom<=innerHeight&&el('[data-act=dag-window-minimize]').disabled,'title controls stay reachable without squeezing the canvas');
            """)
            dag_evidence = os.environ.get("RAWMASTER_UI_DAG_EVIDENCE")
            if dag_evidence and not editing_only:
                Path(dag_evidence).mkdir(parents=True, exist_ok=True)
                browser("screenshot", str(Path(dag_evidence) / "graph-short-window.png"))
            browser("click", ".dag-window-head [data-act=dag-view][data-val=photo]")
            scenario("Node DAG 短窗真实关闭", """
              assert(!el('.dag-floating')&&el('.developed')&&el('[data-act=dag-view-toggle]').getAttribute('aria-pressed')==='false','short-window close removes the floating panel and leaves the primary photo in place');
            """)
            browser("set", "viewport", "1440", "900")
            scenario("Node DAG 短窗关闭后恢复工作区", """
              act('dag-view-toggle');assert(el('.dag-viewport')&&el('[data-act=dag-view-toggle]').getAttribute('aria-pressed')==='true','Graph can reopen when the workspace has room');
            """)
            if dag_evidence and not editing_only:
                scenario("Node DAG 视觉样本准备与正常添加入口", """
                  Studio.setRecipe(Studio.data.work,'视觉评审中性底稿',Studio.freshRecipe());dagLeavePhoto();S.graphOpen=true;S.tool='basic';dagEnsure();render();
                  addNodeMenu();act('dag-add','parallel',modal());set('[name=dagNumber][data-key=ev]',0.2);
                  const mixer=dagCurrent().nodes.find(n=>n.kind==='mix').id;pickNode(mixer);set('[name=dagNumber][data-key=amount]',50);pickNode('grade');menuAction('dag-layout');
                  assert(dagCurrent().nodes.length===6&&Math.abs(dagEvaluate(dagCurrent()).ev-0.1)<0.0001,'neutral base and 0.2EV parallel branch at 50% make a reproducible visual fixture');
                """)
                for kind in ["crop", "mask", "remove"]:
                    scenario(f"Node DAG {kind} 工具视觉与返回上下文", """
                      await hash('settings/general');await page('[name=theme]');set('[name=theme]','dark');await hash('edit/dag');await page('.dag-workspace');pickNode('grade');
                      const before=JSON.stringify(Studio.edit(Studio.data.work).recipe),kind='""" + kind + """';sessionStorage.setItem('qa.canvas.before',before);
                      if(kind==='crop'){act('canvas-crop');set('[name=canvasCropwidth]',80);}
                      if(kind==='mask'){act('edit-tool','masks');maskType('颜色范围');act('canvas-mask-component');set('[name=canvasMaskOpacity]',70);foldTool('mask-refine');const scroller=el('.canvas-tool-body');scroller.scrollTop=scroller.scrollHeight;assert(el('.canvas-tool-scope').getBoundingClientRect().top>=scroller.getBoundingClientRect().top-1,'mask owner remains visible while scrolling');scroller.scrollTop=0;act('canvas-tool-fold','mask-refine');}
                      if(kind==='remove'){act('edit-tool','repair');act('canvas-remove-kind','inpaint');markCenter();foldTool('remove-more');act('canvas-remove-fail');assert(el('[data-act=canvas-tool-done]').disabled,'failed repair cannot finish');}
                      await wait(()=>el('.canvas-tool-dock').getAnimations().every(a=>a.playState==='finished')&&!el('#notice').classList.contains('show'));
                      assert(el('.canvas-tool-dock').dataset.canvasExpanded===kind&&el('.edit-center .developed').checkVisibility(),'expanded tool and primary image visible');
                      if(kind!=='remove')assert(getComputedStyle(el('.canvas-tool-footer .primary')).backgroundColor!=='rgba(0, 0, 0, 0)','enabled finish has a visible primary background');
                      assert(JSON.stringify(Studio.edit(Studio.data.work).recipe)===before,'visual drafts do not publish');
                    """)
                    browser("screenshot", str(Path(dag_evidence) / f"canvas-{kind}-desktop.png"))
                    browser("eval", "actions['canvas-tool-cancel'](); if(JSON.stringify(Studio.edit(Studio.data.work).recipe)!==sessionStorage.getItem('qa.canvas.before'))throw Error('cancel changed recipe');")
            for width, height, theme in [(1440, 900, "dark"), (1440, 900, "light"), (390, 844, "dark"), (390, 844, "light")]:
                browser("set", "viewport", str(width), str(height))
                scenario(f"Node DAG {width}×{height} {theme} 布局、监看与焦点", """
                  await hash('settings/general');await page('[name=theme]');set('[name=theme]','""" + theme + """');
                  await hash('edit/dag');await page('.dag-workspace');act('dag-fit');
                  pickNode('grade');
                  const graph=JSON.stringify(currentEdit().recipe.dag),history=currentEdit().past.length;
                  const box=el('.dag-workspace').getBoundingClientRect();
                  assert(!el('.inspector-content [data-act=dag-reset],.inspector-content [data-act=dag-preview]'),'inspector contains parameters, not duplicate graph commands');
                  assert(document.documentElement.scrollWidth<=innerWidth&&box.left>=0&&box.right<=innerWidth,'Graph fits viewport without horizontal document overflow');
                  assert(document.documentElement.dataset.theme==='""" + theme + """','requested theme');
                  const floating=el('.dag-floating'),windowBox=floating.getBoundingClientRect();
                  assert(getComputedStyle(floating).position==='fixed'&&floating.getAttribute('aria-modal')==='false'&&el('.edit-center .developed').checkVisibility(),'non-modal floating Graph keeps primary photo visible');
                  assert(windowBox.left>=0&&windowBox.right<=innerWidth&&windowBox.top>=0&&windowBox.bottom<=innerHeight,'floating window remains reachable within viewport');
                  const viewport=el('.dag-viewport').getBoundingClientRect(),cards=all('.dag-card').map(card=>card.getBoundingClientRect());assert(viewport.height>=240&&viewport.width>=Math.min(480,innerWidth-26)&&windowBox.height>=392&&windowBox.width>=Math.min(520,innerWidth-24),'minimum applies to actual graph viewport, not just the outer window');const row=all('.dag-picker-row > button').map(button=>button.getBoundingClientRect());assert(row.length===3&&row.every(rect=>Math.abs(rect.top-row[0].top)<1)&&row[0].right<=row[1].left&&row[1].right<=row[2].left,'selector, ignore and Graph stay on one line');assert(cards.length===dagCurrent().nodes.length&&cards.every(card=>card.left>=viewport.left-1&&card.right<=viewport.right+1&&card.top>=viewport.top-1&&card.bottom<=viewport.bottom+1),'FIT contains all actual node cards, not just the floating window');
                  const midX=(Math.min(...cards.map(c=>c.left))+Math.max(...cards.map(c=>c.right)))/2,midY=(Math.min(...cards.map(c=>c.top))+Math.max(...cards.map(c=>c.bottom)))/2;
                  assert(Math.abs(midX-(viewport.left+viewport.right)/2)<1&&Math.abs(midY-(viewport.top+viewport.bottom)/2)<1,'explicit fit centers the actual node bounds');
                  act('dag-readable');const focused=el('.dag-card.active').getBoundingClientRect();assert(dagTransform().scale===1&&focused.left>=viewport.left&&focused.right<=viewport.right&&focused.top>=viewport.top&&focused.bottom<=viewport.bottom,'readable framing keeps the current node on-screen even if the whole graph cannot fit');act('dag-fit');
                  const monitoring=dagView().monitor;menuAction('dag-monitor');assert(dagView().monitor!==monitoring,'monitor can be hidden');
                  menuAction('dag-monitor');assert(dagView().monitor===monitoring&&JSON.stringify(currentEdit().recipe.dag)===graph&&currentEdit().past.length===history,'monitor and fit do not alter recipe or history');
                  const opener=el('.dag-workspace [data-act=dag-menu]');opener.focus();act('dag-menu');act('close',null,modal());await wait(()=>document.activeElement===opener);
                """)
                if dag_evidence and not editing_only:
                    browser("screenshot", str(Path(dag_evidence) / f"graph-{width}-{theme}.png"))
                    if width == 1440 and theme == "light":
                        browser("click", ".dag-zoom-controls [data-act=dag-readable]")
                        browser("screenshot", str(Path(dag_evidence) / "graph-readable-desktop.png"))
                        browser("click", ".dag-commandbar [data-act=dag-menu]")
                        browser("click", "#sheet [data-act=dag-preview]")
                        browser("screenshot", str(Path(dag_evidence) / "photo-node-preview-status.png"))
                        browser("eval", "document.querySelector('.dag-photo-status [data-act=dag-preview-final]').click()")
                    if width == 1440 and theme == "dark":
                        scenario("Node DAG 下拉与六项菜单视觉证据", """
                          pickNode('grade');act('dag-picker');assert(el('#dag-node-picker').matches(':popover-open'),'unified dropdown opens from the normal selector');
                          const rect=el('#dag-node-picker').getBoundingClientRect();assert(rect.left>=0&&rect.right<=innerWidth&&rect.top>=0&&rect.bottom<=innerHeight,'dropdown remains within the viewport');
                        """)
                        browser("screenshot", str(Path(dag_evidence) / "node-picker-desktop.png"))
                        browser("press", "Escape")
                        browser("click", ".dag-commandbar [data-act=dag-menu]")
                        browser("screenshot", str(Path(dag_evidence) / "node-menu-desktop.png"))
                        browser("press", "Escape")
            for theme in ['light', 'dark']:
                scenario(f"Node DAG 390px {theme} 紧凑 Mask／Remove", """
                  await hash('settings/general');await page('[name=theme]');set('[name=theme]','""" + theme + """');await hash('edit/dag');await page('.dag-workspace');pickNode('grade');
                  const before=JSON.stringify(currentEdit().recipe),past=currentEdit().past.length;
                  const bounds=()=>{const dock=el('.canvas-compact-tool').getBoundingClientRect(),canvas=el('.dark-canvas').getBoundingClientRect();assert(dock.left>=0&&dock.right<=innerWidth&&document.documentElement.scrollWidth<=innerWidth&&canvas.height>=150&&canvas.bottom<=dock.top+1,'narrow compact panel keeps photo space without overlap or horizontal overflow');};
                  tap('[data-canvas-tool=mask] button');await wait(()=>el('.canvas-tool-dock').getAnimations().every(a=>a.playState==='finished'));bounds();
                  assert(document.activeElement.dataset.val==='mask-types'&&el('.canvas-tool-scope').textContent.includes('基础调色'),'Mask focuses its type picker and identifies the owner');
                  foldTool('mask-types');assert(all('.canvas-mask-family').length===3&&all('[data-act=canvas-mask-type] .icon').length===14,'all mask types retain icons in three families');
                  key(document.activeElement,'Escape');assert(!el('.canvas-tool-dock')&&document.activeElement.closest('[data-canvas-tool=mask]'),'Escape returns focus to Mask');
                  tap('[data-canvas-tool=remove] button');await wait(()=>el('.canvas-tool-dock').getAnimations().every(a=>a.playState==='finished'));bounds();
                  const s=S.canvasTool,edit=Studio.edit(s.photo),conversation=edit.conversation;edit.conversation={...conversation,strict:true};render();assert(all('.canvas-remove-modes button').every(b=>b.disabled)&&el('.canvas-tool-state').textContent.includes('严格纪实'),'strict documentary makes mode buttons unavailable with a reason');
                  edit.conversation=conversation;Studio.asset(s.photo).online=false;render();assert(all('.canvas-remove-modes button').every(b=>b.disabled)&&el('.canvas-tool-state').textContent.includes('离线'),'offline explains why marking is unavailable');
                  Studio.asset(s.photo).online=true;act('canvas-tool-cancel');assert(JSON.stringify(currentEdit().recipe)===before&&currentEdit().past.length===past,'both exits leave recipe and history untouched');
                """)
                if dag_evidence and not editing_only:
                    browser("eval", "document.querySelector('[data-canvas-tool=mask] button').click()")
                    browser("eval", "Promise.all(document.querySelector('.canvas-tool-dock').getAnimations().map(animation=>animation.finished))")
                    browser("screenshot", str(Path(dag_evidence) / f"canvas-mask-390-{theme}.png"))
                    browser("press", "Escape")
            check_browser_errors()
        finally:
            with suppress(Exception):
                browser("close")
            server.shutdown()


if __name__ == "__main__":
    main()
