#!/usr/bin/env python3
"""Exercise RAWMaster's HTML workbench through its DOM in an isolated Chrome session."""
from contextlib import suppress
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
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
      const key=(target,k,mod={})=>target.dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true,cancelable:true,...mod}));
      const route=async path=>wait(()=>location.hash==='#'+path&&document.querySelector('#workspace'));
    """

    def scenario(title, js):
        try:
            output = browser("eval", "(async()=>{" + helpers + js + ";return 'PASS';})()")
        except RuntimeError as error:
            state = browser("eval", "({url:location.href, route:document.body.dataset.route, title:document.title, message:document.body.innerText.slice(0,160), heading:document.querySelector('h1')?.textContent, dialog:document.querySelector('dialog[open]')?.innerText, filters:document.querySelector('.chips')?.innerText})")
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
            scenario("暗房布局、智能预设与胶片采用", """
              await hash('library/group/dusk');act('photo','d1');act('workflow','edit');await page('.smart-panel');
              assert(!el('.edit-head .switch,.edit-left .switch,.edit-inspector .tool-palette,.edit-page .filmstrip,.agent-panel'),'single darkroom');
              const headings=all('.edit-left > section h2');
              assert(headings.map(n=>n.textContent).join('/')==='预设/快照/历史'&&headings[0].offsetTop<headings[1].offsetTop&&headings[1].offsetTop<headings[2].offsetTop,'stacked left sections');
              const rail=el('.inspector-rail').getBoundingClientRect(),pane=el('.inspector-content').getBoundingClientRect();
              assert(rail.width<51&&rail.right<=pane.left+1&&all('.rail-tool').every(b=>!b.textContent.trim()&&b.title),'vertical labeled icon rail');
              assert(!el('[name=aiPrompt]')&&el('[data-act=edit-tool][data-val=agent]'),'opt in to Agent');
              act('scene-card','暮色冷暖');act('scene-preview');act('close',null,modal());assert(all('.edit-history li').length===1,'cancel scene');
              act('scene-preview');act('apply-scene',null,modal());assert(el('.edit-history').textContent.includes('暮色冷暖'),'smart preset adopted');
              act('edit-step','undo');set('[name=scene]','纪实');act('scene-card','同组参考配平');act('scene-preview');
              assert(all('[name=matchReference] option',modal()).length===3,'scope contains just this group');set('[name=matchReference]','d2',modal());
              assert(!el('[name=matchTarget][value=d2]',modal()),'reference protected');act('close',null,modal());
              const neutral=el('.developed').style.filter;
              let film=el('[data-act=film-stock][data-val=silver]');film.focus();assert(el('.developed').style.filter!==neutral,'keyboard film preview');
              key(film,'Escape');assert(el('.developed').style.filter===neutral&&el('.look-preview').hidden,'Escape restores applied image');
              key(film,'ArrowLeft');assert(document.activeElement.dataset.val==='chrome','film keys stay in the gallery');
              document.activeElement.blur();assert(el('.developed').style.filter===neutral&&all('.edit-history li').length===1,'preview reversible');
              film.dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));assert(el('.developed').style.filter!==neutral,'hover preview');
              film.dispatchEvent(new PointerEvent('pointerout',{bubbles:true}));assert(el('.developed').style.filter===neutral,'hover exit');
              act('film-stock','silver');assert(el('.developed').style.filter.includes('saturate(0)'),'applied black and white');
              set('[data-key=filmAmount]','45');const blend=el('.developed').style.filter;assert(blend!==neutral&&!blend.includes('saturate(0)'),'strength preview');
              act('snapshot');act('save-snap',null,modal());act('edit-step','undo');assert(el('[data-key=filmAmount]').value==='100','one step');
              act('restore-snap','0');assert(el('.developed').style.filter===blend,'snapshot restore');
              act('edit-tool','basic',el('.inspector-rail'));await page('[data-key=ev]');const basic=el('.rail-tool[data-val=basic]');
              assert(document.activeElement===basic,'focus on icon');key(basic,'ArrowDown');await page('.curve-chart');
              assert(document.activeElement.dataset.val==='tones','keyboard navigates rail');
            """)
            scenario("浮动工具条、邻片、裁切与参考对比", """
              const bar=el('.canvas-dock').getBoundingClientRect(),canvas=el('.canvas-panel').getBoundingClientRect();
              assert(bar.bottom<canvas.bottom&&bar.width<canvas.width&&Math.abs((bar.left+bar.right)-(canvas.left+canvas.right))<3,'floating dock centered');
              assert(el('[data-act=canvas-nav][data-val=previous]').disabled,'start of current group');
              el('[data-act=canvas-nav][data-val=next]').focus();assert(all('.neighbor-preview').filter(n=>n.checkVisibility()).length===1,'single adjacent preview');
              act('canvas-nav','next');assert(!el('[data-key=filmAmount]'),'separate photo recipe');act('canvas-nav','next');
              assert(el('[data-act=canvas-nav][data-val=next]').disabled,'end of group');key(el('#workspace'),'ArrowLeft');act('canvas-nav','previous');
              assert(el('[data-key=filmAmount]').value==='45','draft survives round trip');
              const width=el('.edit-image').getBoundingClientRect().width;act('edit-zoom','in');assert(el('.edit-image').getBoundingClientRect().width>width,'zoom in');
              key(el('#workspace'),'0',{metaKey:true});assert(Math.abs(el('.edit-image').getBoundingClientRect().width-width)<1,'FIT');
              key(el('#workspace'),'c');assert(el('.crop-panel')&&el('[data-val=compare][data-act=canvas-menu]').disabled,'crop on canvas');
              set('[name=crop]','4:5');key(el('[name=crop]'),'Escape');assert(!el('.crop-panel'),'crop escape');
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
              act('edit-tool','basic');await page('[data-key=ev]');set('[data-key=ev]','0.5');act('edit-tool','masks');await page('[data-act=add-mask]');act('add-mask');
              assert(el('.mask-mark'),'mask preview');act('edit-step','undo');assert(!el('.mask-mark'),'undo layer');
              act('edit-step','redo');act('canvas-crop');set('[name=crop]','1:1');act('canvas-crop');act('save-version');
              act('open-versions');await page('.version-row');
              assert(el('.version-row').textContent.includes('候选'),'saved independently');
              act('adopt',null,el('.version-row'));assert(el('.version-row').textContent.includes('当前采用'),'explicit adoption');
              act('return-adjustments');await page('[data-act=add-mask]');act('edit-tool','basic');await page('[data-key=ev]');set('[data-key=ev]','0.75');
              act('workflow','export');assert(modal().open&&modal().textContent.includes('导出哪个版本'),'draft decision');
              act('export-choice','draft',modal());await page('#export-frame[src]');
              const f=el('#export-frame');await wait(()=>f.contentDocument?.querySelector('#selected')?.textContent==='2 / 2');
              const doc=f.contentDocument;assert(el('#focus-name',doc).textContent==='DJI_0348.DNG','order');
              tap('#asset-rows .asset:nth-child(2) button',doc);
              assert(el('#focus-name',doc).textContent==='DSC_0712.ARW','second file');
              assert(el('#version',doc).selectedOptions[0].textContent==='初修 2','chosen draft');
              await wait(()=>all('img',doc).some(i=>i.complete&&i.naturalWidth));tap('#edit-layout',doc);assert(el('#layout-dialog',doc).open,'watermark dialog');tap('#cancel-layout',doc);
              tap('#submit',doc);assert(el('#job',doc).open,'job');tap('#cancel-job',doc);assert(!el('#retry',doc).hidden,'retry');tap('#retry',doc);
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
            scenario("本机 AI 准备、取消、重试与独立候选", """
              await hash('edit/retouch');assert(el('.smart-panel')&&!el('.agent-panel'),'old retouch link opens smart presets');
              act('edit-tool','agent');await page('[name=aiPrompt]');assert(!el('.smart-panel')&&!el('[data-act=ai-review]'),'independent Agent panel');
              set('[name=aiPrompt]','清理画面右边的杂物');act('agent-send');assert(el('.chat-log').textContent.includes('右边的杂物'),'conversation reply');
              set('[name=aiPrompt]','保留人物轮廓');act('canvas-nav','next');assert(!el('.chat-turn')&&!el('[name=aiPrompt]').value,'private to photo');
              act('canvas-nav','previous');assert(el('[name=aiPrompt]').value==='保留人物轮廓'&&el('[data-act=ai-review]').disabled,'restore pending draft');
              act('agent-send');act('edit-tool','smart',el('.agent-panel'));await page('.smart-panel');
              act('edit-tool','agent');await page('[data-act=ai-review]');assert(all('.chat-turn.reply').length===2,'preserved conversation');
              act('ai-review');assert(modal().textContent.includes('需要准备'),'unavailable model');act('goto-close','settings/runtime',modal());
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
              el('[data-act=edit-tool][data-val=agent]').scrollIntoView();act('edit-tool','agent');await page('.agent-panel');
              const box=el('[name=aiPrompt]');box.focus();key(box,'b');assert(!el('.canvas-popover'),'typing stays in field');
              await hash('settings/general');set('[name=theme]','dark');await hash('edit/agent');assert(el('.chat-turn')&&document.documentElement.dataset.theme==='dark','same photo across themes');
            """)
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
              act('quick-open');const dock=el('#quick-prompt'), morph=dock.getAnimations()[0];
              assert(morph,'surface animates');morph.pause();morph.currentTime=125;
              const middle=dock.getBoundingClientRect();morph.finish();await wait(()=>!dock.classList.contains('quick-morphing'));
              const expanded=dock.getBoundingClientRect();
              assert(normal.width<middle.width&&middle.width<expanded.width&&normal.height<middle.height&&middle.height<expanded.height,'width and height both morph');
              assert(Math.abs(expanded.bottom-normal.bottom)<1&&Math.abs(middle.bottom-normal.bottom)<1,'bottom edge stays anchored');
              const prompt=()=>el('[name=quickPrompt]');
              assert(!el('.canvas-dock [data-act=canvas-nav]')&&document.activeElement===prompt(),'replace controls and focus text');
              assert(el('#quick-scope').textContent==='整张照片'&&!el('.comparison-layer'),'explicit whole scope');
              key(prompt(),'Escape',{isComposing:true});assert(el('#quick-prompt'),'composition owns Escape');
              key(prompt(),'b');assert(!el('.canvas-popover'),'typing does not cycle background');
              act('quick-template','remove');
              assert(prompt().value.includes('［干扰物］')&&el('[data-act=quick-submit]').disabled,'editable template placeholder');
              set('[name=quickPrompt]','移除岸边路牌。');prompt().focus();prompt().setSelectionRange(prompt().value.length,prompt().value.length);
              el('.quick-menu[data-menu=phrases]').open=true;act('quick-template','water');
              assert(prompt().value.includes('移除岸边路牌。')&&prompt().value.includes('保留水面倒影。'),'short phrase preserves draft');
              act('quick-draw');assert(el('.quick-gesture')&&el('[data-act=quick-submit]').disabled,'pending rectangle blocks generation');
              key(el('[data-act=quick-draw]'),'Escape');assert(!el('.quick-gesture')&&el('#quick-prompt'),'Escape exits only drawing');
              el('.quick-menu[data-menu=scope]').open=true;act('quick-coordinates',null,el('#quick-prompt'));
              set('[name=w]','0');act('quick-set-coordinates',null,modal());
              assert(modal().open&&el('#quick-coord-error').textContent.includes('有效'),'invalid bounds keep waiting');
              set('[name=w]','38');set('[name=h]','24');act('quick-set-coordinates',null,modal());
              assert(el('#quick-scope').textContent==='矩形选区'&&el('.quick-outline').checkVisibility(),'keyboard rectangle');
              act('quick-close');assert(el('.comparison-layer')&&document.activeElement.dataset.act==='quick-open','restore comparison and focus');
              act('quick-open');assert(prompt().value.includes('保留水面倒影。')&&el('#quick-scope').textContent==='矩形选区','same-work draft restored');
              assert(!Studio.data.jobs.some(j=>j.quickPrompt),'entry, templates and ranges do not start tasks');
            """)
            scenario("快速 Prompt 本机准备、候选、采用与撤销", """
              Studio.data.prefs.runtime='待准备';render();
              const id=Studio.data.work, before=currentEdit().adopted, steps=currentEdit().past.length, recipe=JSON.stringify(currentEdit().recipe);
              act('quick-setup','runtime');await page('[name=licenseAck]');set('[name=licenseAck]',true);act('prepare-runtime');await page('.jobs-page');
              await wait(()=>Studio.data.prefs.runtime==='就绪');act('goto','edit/development');await page('#quick-prompt');
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
            scenario("快速 Prompt 云端确认、换片、未知结果和重试", """
              const id=Studio.data.work;
              act('quick-open');set('[name=quickModel]','seedream');
              if (el('[data-act=quick-setup]')) {
                act('quick-setup','cloud');await page('[name=cloudName]');set('[name=cloudName]','Seedream / 中国方舟');act('cloud-save');
                await hash('edit/development');await page('#quick-prompt');
              }
              set('[name=quickPrompt]','将整张照片调为冷蓝色，保留构图与高光。');
              el('.quick-menu[data-menu=scope]').open=true;act('quick-whole');
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
              act('quick-close');await hash('edit/masks');await page('[data-act=add-mask]');act('add-mask');
              act('quick-open');await wait(()=>!el('.canvas-dock').classList.contains('quick-morphing'));
              el('.quick-menu[data-menu=scope]').open=true;act('quick-mask',null,el('#quick-prompt'));act('quick-use-mask',null,modal());
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
            errors = browser("errors")
            if errors:
                raise AssertionError(errors)
        finally:
            with suppress(Exception):
                browser("close")
            server.shutdown()


if __name__ == "__main__":
    main()
