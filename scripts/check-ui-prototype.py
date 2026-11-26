#!/usr/bin/env python3
"""Exercise RAWMaster's HTML workbench through its DOM in an isolated Chrome session."""
from argparse import ArgumentParser
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
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--editing-only", action="store_true", help="Run the filter and Quick Prompt walkthrough with its setup scenarios.")
    editing_only = parser.parse_args().editing_only
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
        if editing_only and "快速 Prompt" not in title and title not in {
            "双击入口与本地照片", "标题栏与资料库侧栏开关", "搜索、筛选、多选比较与批量标签",
            "导入、续接、分组、初筛封存与历史恢复", "暗房布局、智能预设与胶片采用", "浮动工具条、邻片、裁切与参考对比", "胶片带对齐、折叠和离线照片",
        }:
            return
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
            scenario("胶片带对齐、折叠和离线照片", """
              act('mode','single');
              const centers=()=>all('.filmstrip-photo img').map(img=>{const r=img.getBoundingClientRect();return r.top+r.height/2;});
              assert(Math.max(...centers())-Math.min(...centers())<1,'grouped and ungrouped thumbnails align');
              const label=el('.filmstrip-group .filmstrip-label'), first=label.nextElementSibling;
              assert(label.getBoundingClientRect().right<first.getBoundingClientRect().left,'group label before first photo');
              const count=all('.filmstrip-photo').length, selected=activeBrowser().focus;
              act('filmstrip-group',label.dataset.val);assert(all('.filmstrip-photo').length<count&&activeBrowser().focus===selected,'collapse preserves focus');
              act('filmstrip-group',label.dataset.val);assert(all('.filmstrip-photo').length===count,'expand restores members');
              act('workflow','edit');await page('.edit-center .filmstrip');
              assert(Math.max(...centers())-Math.min(...centers())<1,'editing strip also aligns');
              act('edit-photo','w1');assert(modal().textContent.includes('原片待找回'),'offline entry explains recovery');
              act('close',null,modal());assert(Studio.data.work===selected,'offline cancel retains photo');
              act('workflow','library');await page('.loupe');act('mode','grid');
            """)
            scenario("暗房布局、智能预设与胶片采用", """
              await hash('library/group/dusk');act('photo','d1');act('workflow','edit');await page('.smart-panel');
              assert(!el('.edit-head .switch,.edit-left .switch,.edit-inspector .tool-palette,.agent-panel'),'single darkroom');
              const headings=all('.edit-left > section h2');
              assert(headings.map(n=>n.textContent).join('/')==='滤镜/快照/历史'&&headings[0].offsetTop<headings[1].offsetTop&&headings[1].offsetTop<headings[2].offsetTop,'stacked left sections');
              const rail=el('.inspector-rail').getBoundingClientRect(),pane=el('.inspector-content').getBoundingClientRect();
              assert(rail.width<51&&rail.right<=pane.left+1&&all('.rail-tool').every(b=>!b.textContent.trim()&&b.title),'vertical labeled icon rail');
              assert(!el('[name=aiPrompt]')&&el('[data-act=edit-tool][data-val=agent]'),'opt in to Agent');
              act('scene-card','暮色冷暖');act('scene-preview');act('close',null,modal());assert(all('.edit-history li').length===1,'cancel scene');
              act('scene-preview');act('apply-scene',null,modal());assert(el('.edit-history').textContent.includes('暮色冷暖'),'smart preset adopted');
              act('edit-step','undo');set('[name=scene]','纪实');act('scene-card','同组参考配平');act('scene-preview');
              assert(all('[name=matchReference] option',modal()).length===3,'scope contains just this group');set('[name=matchReference]','d2',modal());
              assert(!el('[name=matchTarget][value=d2]',modal()),'reference protected');act('close',null,modal());
              const neutral=el('.developed').style.filter;
              assert(all('.preset-directory > details > summary > span').slice(0,3).map(x=>x.textContent).join('|')==='Adaptive|胶片模拟|Imported'&&!el('.preset-folder img'),'three primary folders without thumbnails');
              assert(all('[data-folder=adaptive] > .preset-children > details > summary > span').map(x=>x.textContent).join('|')==='Sky|Subject','preserve source folders');
              assert(el('[data-key=filmAmount]').disabled&&el('.filter-actions').compareDocumentPosition(el('.preset-directory'))&Node.DOCUMENT_POSITION_FOLLOWING,'amount and import before folders');
              act('preset-import');set('[name=presetName]','走查 XMP',modal());act('preset-command',null,modal());
              const imported=el('[data-act=apply-preset][data-val="走查 XMP"]');
              imported.dispatchEvent(new PointerEvent('pointerover',{bubbles:true}));assert(el('.developed').style.filter!==neutral,'import hover changes the canvas');
              imported.dispatchEvent(new PointerEvent('pointerout',{bubbles:true}));assert(el('.developed').style.filter===neutral,'import hover restores');
              set('[name=presetQuery]','无匹配输入');assert(el('.preset-directory').textContent.includes('没有匹配'),'search empty');
              set('[name=presetQuery]','');
              act('preset-manage');assert(all('[name=presetOperation] option',modal()).some(x=>x.value.includes('Lightroom'))&&!modal().textContent.includes('迁移'),'XMP import without migration UI');act('close',null,modal());
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
              act('edit-tool','basic',el('.inspector-rail'));await page('[data-adjustment-section=light] summary');const basic=el('.rail-tool[data-val=basic]');
              assert(document.activeElement===basic&&el('[data-adjustment-section=whiteBalance]').open,'first section and rail focus');
              tap('[data-adjustment-section=light] summary');
              const slider=el('[data-key=ev]'), numeric=el('[data-adjustment=ev]');
              assert(slider.getBoundingClientRect().top>numeric.getBoundingClientRect().bottom&&slider.getBoundingClientRect().width>numeric.getBoundingClientRect().width*2,'slider has its own wide row');
              key(basic,'ArrowDown');await page('.curve-chart');assert(document.activeElement.dataset.val==='tones','keyboard navigates rail');
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
              assert(el('[data-adjustment-section=light]').open,'right panel remembers disclosure');
            """)
            scenario("浮动工具条、邻片、裁切与参考对比", """
              const bar=el('.canvas-dock').getBoundingClientRect(),canvas=el('.canvas-panel').getBoundingClientRect();
              assert(bar.bottom<canvas.bottom&&bar.width<canvas.width&&Math.abs((bar.left+bar.right)-(canvas.left+canvas.right))<3,'floating dock centered');
              assert(el('[data-act=canvas-nav][data-val=previous]').disabled,'start of current group');
              el('[data-act=canvas-nav][data-val=next]').focus();assert(all('.neighbor-preview').filter(n=>n.checkVisibility()).length===1,'single adjacent preview');
              act('canvas-nav','next');assert(el('[data-key=filmAmount]').disabled,'separate photo recipe');act('canvas-nav','next');
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
              act('edit-tool','basic');await page('[data-adjustment-section=light] summary');if(!el('[data-adjustment-section=light]').open)tap('[data-adjustment-section=light] summary');set('[data-key=ev]','0.5');act('edit-tool','masks');await page('[data-act=add-mask]');act('add-mask');
              assert(el('.mask-mark'),'mask preview');act('edit-step','undo');assert(!el('.mask-mark'),'undo layer');
              act('edit-step','redo');act('canvas-crop');set('[name=crop]','1:1');act('canvas-crop');act('save-version');
              act('open-versions');await page('.version-row');
              assert(el('.version-row').textContent.includes('候选'),'saved independently');
              act('adopt',null,el('.version-row'));assert(el('.version-row').textContent.includes('当前采用'),'explicit adoption');
              act('return-adjustments');await page('[data-act=add-mask]');act('edit-tool','basic');await page('[data-adjustment-section=light] summary');if(!el('[data-adjustment-section=light]').open)tap('[data-adjustment-section=light] summary');set('[data-key=ev]','0.75');
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
              act('quick-close');await hash('edit/masks');await page('[data-act=add-mask]');act('add-mask');
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
            errors = browser("errors")
            if errors:
                raise AssertionError(errors)
        finally:
            with suppress(Exception):
                browser("close")
            server.shutdown()


if __name__ == "__main__":
    main()
