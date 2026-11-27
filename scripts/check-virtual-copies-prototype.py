#!/usr/bin/env python3
"""Exercise virtual copy selection, snapshots and frozen 032 inputs in one clean browser."""
import importlib.util
import json
import os
import shutil
import subprocess
import threading
import uuid
from functools import partial
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('workbench_check', ROOT/'scripts/check-ui-prototype.py')
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
session = 'rawmaster-copies-' + uuid.uuid4().hex[:10]
browser = [shutil.which('agent-browser') or 'agent-browser', '--session', session]
chrome = os.environ.get('RAWMASTER_UI_CHROME', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
evidence = os.environ.get('RAWMASTER_COPY_EVIDENCE')

def call(*args):
    done = subprocess.run([*browser, *args],capture_output=True,text=True,timeout=45)
    if done.returncode:
        raise RuntimeError(done.stderr.strip() or done.stdout.strip())
    return done.stdout.strip()

helpers = """
const el=(s,r=document)=>r.querySelector(s),all=(s,r=document)=>[...r.querySelectorAll(s)],dlg=()=>el('#sheet');
const assert=(v,m)=>{if(!v)throw Error(m)};
const wait=async(fn,m)=>{for(let i=0;i<220;i++){if(fn())return;await new Promise(resolve=>setTimeout(resolve,20));}throw Error(m)};
const tap=(s,r=document)=>{const t=el(s,r);assert(t&&t.checkVisibility()&&!t.disabled,'Unavailable '+s);t.click();};
const act=(a,id,r=document)=>tap('[data-act="'+a+'"]'+(id!=null?'[data-val="'+CSS.escape(String(id))+'"]':''),r);
const set=(s,v,r=document)=>{const t=el(s,r);assert(t,'Missing '+s);t.value=v;t.dispatchEvent(new Event('input',{bubbles:true}));if(t.isConnected)t.dispatchEvent(new Event('change',{bubbles:true}));};
const library=async()=>{act('workflow','library');await wait(()=>el('.photo-card')?.checkVisibility(),'grid');};
const edit=async()=>{act('workflow','edit');await wait(()=>el('.scene-modes')?.checkVisibility(),'editor');};
const ctx=id=>{el('.photo-card[data-val="'+id+'"]').dispatchEvent(new MouseEvent('contextmenu',{bubbles:true,cancelable:true}));};
const snapshots=()=>all('[data-act=restore-snap]').map(b=>b.textContent.trim());
const saveSnap=n=>{act('snapshot');set('[name=snapshotName]',n,dlg());act('save-snap',null,dlg());};
const copyID=()=>sessionStorage.getItem('qa.copy');
const d032=()=>el('#export-frame')?.contentDocument;
const choose=(id,add=false)=>el('.photo-card[data-val="'+id+'"]').dispatchEvent(new MouseEvent('click',{bubbles:true,metaKey:add}));
"""

def run(label, js):
    try:
        call('eval','(async()=>{'+helpers+js+";return 'PASS';})()")
    except RuntimeError as error:
        state=call('eval',"({route:location.hash,dialog:document.querySelector('dialog[open]')?.innerText,header:document.querySelector('.edit-identity')?.innerText,copies:typeof Studio==='undefined'?null:Studio.catalog().virtualCopies,errors:document.querySelector('[role=alert]')?.innerText})")
        raise AssertionError(label+' '+state+'\\n'+str(error)) from error
    print('✓',label,flush=True)

def capture(name):
    if evidence:
        folder=Path(evidence);folder.mkdir(parents=True,exist_ok=True)
        call('eval',"""(async()=>{
          const frame=document.querySelector('#export-frame')?.contentDocument;
          const photos=frame ? [...frame.querySelectorAll('#photo,#asset-rows img')]
            : [...document.querySelectorAll('.photo-card img')];
          await Promise.all(photos.map(image=>image.decode().catch(()=>{})));
          for(let n=0;n<35&&document.querySelector('#notice.show');n++)await new Promise(done=>setTimeout(done,100));
          await new Promise(done=>requestAnimationFrame(()=>requestAnimationFrame(done)));
        })()""")
        call('screenshot',str(folder/(name+'.png')))

def main():
    handler=partial(shared.QuietHandler,directory=str(ROOT))
    with shared.WorkbenchHTTPServer(('127.0.0.1',0),handler) as server:
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            options=['--executable-path',chrome] if Path(chrome).exists() else []
            call(*options,'open',f'http://127.0.0.1:{server.server_port}/{shared.ENTRY}?sceneNativeReview=1')
            call('set','viewport','1440','900');call('set','media','light')
            run('原片建立独立 SDR 和 HDR 命名快照',"""
              await wait(()=>el('.photo-card')?.checkVisibility(),'initial grid');
              choose('b1');await edit();set('[data-adjustment=ev]','0.55');saveSnap('原片彩色');
              act('scene-mode','hdr');set('[name=sceneGraphExposure]','1.25');act('scene-review-exposure');saveSnap('原片高光');
              assert(snapshots().join()==='原片高光','HDR snapshot scope');
              act('scene-mode','sdr');assert(snapshots().join()==='原片彩色','SDR snapshot scope');await library();
            """)
            run('照片右键、名称验证和取消',"""
              sessionStorage.setItem('qa.shots',el('.view-heading p').textContent);
              ctx('b1');act('copy-request','create',dlg());assert(el('[name=copyName]').value==='副本 1','prefilled');
              set('[name=copyName]','');act('copy-commit',null,dlg());assert(el('[name=copyName]').ariaInvalid==='true','blank blocked');
              act('copy-cancel',null,dlg());await wait(()=>document.activeElement.dataset.val==='b1','cancel returns focus');
              ctx('b1');act('copy-request','create',dlg());set('[name=copyName]','黑白水鸟');act('copy-commit',null,dlg());
              const id=activeBrowser().focus;sessionStorage.setItem('qa.copy',id);
              assert(Studio.physicalID(id)==='b1'&&el('.view-heading p').textContent===sessionStorage.getItem('qa.shots'),'one physical shot');
              const cards=all('.photo-card').map(b=>b.dataset.val);assert(cards.indexOf(id)===cards.indexOf('b1')+1,'adjacent default sort');
              assert(Studio.edit(id).recipe.ev===0.55&&!Studio.edit(id).snapshots.length,'snapshot inheritance boundary');
              await edit();act('scene-mode','hdr');assert(currentEdit().recipe.ev===1.25&&!snapshots().length,'own HDR branch starts from current state');
              act('scene-mode','bw');set('[data-adjustment=ev]','-0.5');saveSnap('副本黑白');
              assert(currentEdit().recipe.mono&&Studio.edit('b1').recipe.ev===0.55,'private edits');
            """)
            call('reload')
            run('重开和切换恢复本份快照，恢复可撤销',"""
              await wait(()=>el('.edit-identity')?.checkVisibility(),'editor reopens');
              assert(Studio.data.work===copyID()&&el('.edit-identity').innerText.includes('黑白水鸟')&&snapshots().join()==='副本黑白','copy restored');
              set('[data-adjustment=ev]','0.2');act('restore-snap',0);assert(currentEdit().recipe.ev===-0.5,'restore');act('edit-step','undo');assert(currentEdit().recipe.ev===0.2,'undo restore');
              act('restore-snap',0);await library();choose('b1');await edit();assert(snapshots().join()==='原片彩色'&&!currentEdit().recipe.mono,'source restored');
              act('scene-mode','hdr');assert(snapshots().join()==='原片高光','source HDR restored');act('scene-mode','sdr');await library();
              choose(copyID());act('selection-menu');act('copy-request','rename',dlg());set('[name=copyName]','银盐黑白');act('copy-commit',null,dlg());
              choose('b1');choose(copyID(),true);assert(activeIDs().length===2,'both selected');
              assert(el('.photo-card[data-val="'+copyID()+'"] img').style.filter!==el('.photo-card[data-val=b1] img').style.filter,'different thumbnail looks');
            """)
            capture('01-library-copies')
            run('同源多选共享文件元数据，修改标签只列出一张照片',"""
              assert(activeIDs().length===2&&selectedPhysicalIDs().length===1,'two selected looks share a file');
              act('rate','4');assert(Studio.asset('b1').stars===4&&Studio.asset(copyID()).stars===4,'shared rating');
              act('selection-menu');act('tags',null,dlg());set('[name=tagText]','银盐选片',dlg());
              assert(all('#tag-review dt',dlg()).length===1,'preview one physical file');act('apply-tags',null,dlg());
              assert(Studio.asset(copyID()).tags.includes('银盐选片')&&Studio.asset('b1').tags.includes('银盐选片'),'same tags');
            """)
            run('032 两份成片与一份原件，分别冻结并提交',"""
              act('workflow','export');await wait(()=>d032()?.querySelector('#selected')?.textContent==='2 / 2','two inputs');
              const d=d032();tap('#asset-rows .asset:nth-child(2) button',d);assert(el('#focus-name',d).textContent.includes('银盐黑白'),'copy title');
              assert(el('#asset-rows .asset:nth-child(2) img',d).style.filter.includes('grayscale'),'copy grade in 032 list');
              set('#template','{name}',d);assert(el('#out-name',d).textContent.includes('DSC_0712-银盐黑白'),'copy filename');
              tap('#original',d);assert(el('#selected',d).textContent.includes('1 份原件')&&!el('#asset-rows .asset:nth-child(2) img',d).style.filter,'physical dedup and source thumbnail');
              tap('#render',d);assert(el('#selected',d).textContent==='2 / 2','two renditions retained');
            """)
            capture('02-export-copies')
            run('冻结回执在继续编辑后维持身份与名称',"""
              const d=d032();tap('#submit',d);await wait(()=>el('#export-frame').dataset.receipt,'submitted');
              const id=el('#export-frame').dataset.receipt,key='rawmaster.export.delivery.v1.batch.'+id;
              await wait(()=>JSON.parse(localStorage.getItem(key))?.items.length===2,'two receipts');
              const rows=JSON.parse(localStorage.getItem(key)).items;assert(new Set(rows.map(x=>x.presentationID)).size===2&&rows.every(x=>x.physicalID==='b1'),'two independent presentations one physical');
              assert(rows[1].copyName==='银盐黑白'&&rows[0].versionID!==rows[1].versionID,'frozen identity');sessionStorage.setItem('qa.receipt',key);
              await library();choose(copyID());await edit();set('[data-adjustment=ev]','-0.8');await library();
              const frozen=JSON.parse(localStorage.getItem(key)).items;
              assert(frozen[1].copyName==='银盐黑白'&&frozen[1].versionID===rows[1].versionID,'stable batch');
            """)
            call('set','viewport','390','844');call('set','media','dark')
            run('窄窗移除确认、键盘取消与撤销',"""
              choose(copyID());ctx(copyID());act('copy-request','remove',dlg());assert(dlg().textContent.includes('原片和已交付文件会保留')&&document.activeElement.dataset.act==='copy-cancel','safe action');
              document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
              await wait(()=>!dlg().open&&document.activeElement.dataset.val===copyID(),'escape returns focus');
              ctx(copyID());act('copy-request','remove',dlg());act('copy-commit',null,dlg());
              assert(!Studio.copy(copyID())&&activeBrowser().focus==='b1'&&JSON.parse(localStorage.getItem(sessionStorage.getItem('qa.receipt'))).items.length===2,'remove only this copy');
              el('#workspace').dispatchEvent(new KeyboardEvent('keydown',{key:'z',metaKey:true,bubbles:true,cancelable:true}));
              assert(activeBrowser().focus===copyID()&&Studio.copy(copyID()).name==='银盐黑白'&&Studio.edit(copyID()).snapshots.length===1,'undo restores same copy');
              assert(document.documentElement.scrollWidth<=innerWidth+1,'narrow library fits');
            """)
            capture('03-compact-library')
            run('离线副本指向同一原片，重连一次同时恢复',"""
              ctx('w1');act('copy-request','create',dlg());set('[name=copyName]','山坡备选');act('copy-commit',null,dlg());const id=activeBrowser().focus;
              assert(!Studio.asset(id).online&&!Studio.asset('w1').online,'shared unavailable source');act('workflow','edit');
              assert(dlg().open&&dlg().textContent.includes('原片待找回'),'offline reason');act('relink',id,dlg());act('link-file',id,dlg());
              assert(Studio.asset(id).online&&Studio.asset('w1').online,'relink applies to both');
              choose('b1');choose(copyID(),true);act('workflow','export');await wait(()=>d032()?.querySelector('#selected')?.textContent==='2 / 2','narrow export');
              await wait(()=>d032()?.querySelector('#asset-rows .asset:nth-child(2) button')?.checkVisibility(),'narrow copy row');
              const d=d032();tap('#asset-rows .asset:nth-child(2) button',d);
              assert(d.documentElement.scrollWidth<=d.documentElement.clientWidth+1&&el('#stage',d).clientHeight>=170,'narrow export and full preview fit');
            """)
            capture('04-compact-export')
            run('只勾副本也能交付唯一同源原件',"""
              const d=d032();tap('#original',d);tap('#asset-rows .asset:first-child input',d);
              assert(el('#selected',d).textContent==='1 / 2'&&el('#asset-rows .asset:nth-child(2) input',d).checked,'only the copy is checked');
              tap('#submit',d);await wait(()=>el('#job',d).open&&all('#jobrows li',d).length===2,'one original and its manifest');
              const rows=all('#jobrows li',d);assert(rows[0].innerText.includes('DSC_0712.ARW')&&!rows[0].innerText.includes('银盐黑白')&&rows[1].innerText.includes('交付清单'),'delivered physical filename');
            """)
            run('每份呈现的每个色彩分支独立保留 32 个快照',"""
              await library();choose('b1');await edit();
              for(let n=1;n<32;n++)saveSnap('日常调色 '+n);
              assert(snapshots().length===32,'32 stored');act('snapshot');assert(!dlg().open&&el('.editor-toast.error')?.innerText.includes('32 个命名快照'),'limit retains all');
              act('scene-mode','hdr');assert(snapshots().join()==='原片高光','independent branch');
              saveSnap('保留高光');const row=all('.snapshot-list .preset-item').at(-1);tap('summary',row);
              act('rename-snap',null,row);set('[name=snapshotName]','高光标记',dlg());act('save-snap-name',null,dlg());
              assert(snapshots().includes('高光标记'),'rename');const renamed=all('.snapshot-list .preset-item').at(-1);
              tap('summary',renamed);act('delete-snap',null,renamed);assert(snapshots().join()==='原片高光','delete only selected');
            """)
            run('重命名快照保留错误输入，Esc 退出，过期目标不会更改其他快照',"""
              const manage=n=>{
                const row=all('.snapshot-list .preset-item').find(item=>el('[data-act=restore-snap]',item)?.textContent.trim()===n);
                assert(row,'snapshot '+n);if(!el('details',row).open)tap('summary',row);act('rename-snap',null,row);
              };
              const key=k=>el('[name=snapshotName]',dlg()).dispatchEvent(new KeyboardEvent('keydown',{key:k,bubbles:true,cancelable:true}));
              manage('原片高光');set('[name=snapshotName]','',dlg());key('Enter');
              assert(dlg().open&&el('#snapshot-name-error').textContent.includes('60 个字符'),'blank rejected');
              const tooLong='光'.repeat(61);set('[name=snapshotName]',tooLong,dlg());key('Enter');
              assert(el('[name=snapshotName]').value===tooLong&&document.activeElement===el('[name=snapshotName]'),'invalid text stays focused');
              key('Escape');assert(!dlg().open&&snapshots().includes('原片高光'),'cancel preserves name');
              manage('原片高光');const allowed='高'.repeat(60);set('[name=snapshotName]',allowed,dlg());key('Enter');
              assert(!dlg().open&&snapshots().includes(allowed),'60 character commit');
              saveSnap('同步删除');saveSnap('保留邻项');manage('同步删除');set('[name=snapshotName]','错误目标',dlg());
              const e=currentEdit();e.snapshots.splice(e.snapshots.findIndex(x=>x.name==='同步删除'),1);Studio.save();key('Enter');
              assert(dlg().open&&el('#snapshot-name-error').textContent.includes('已被删除')&&e.snapshots.some(s=>s.name==='保留邻项'),'stale row never writes its successor');
              key('Escape');render();manage('保留邻项');set('[name=snapshotName]','旧窗口',dlg());
              const oldPhoto=Studio.data.work;Studio.data.work=copyID();key('Enter');
              assert(dlg().open&&el('#snapshot-name-error').textContent.includes('分支已改变')&&el('[name=snapshotName]').value==='旧窗口','photo switch preserves draft');
              assert(!Studio.edit(copyID()).snapshots.some(s=>s.name==='旧窗口')&&!Studio.edit(oldPhoto).snapshots.some(s=>s.name==='旧窗口'),'neither photo changed');
              key('Escape');Studio.data.work=oldPhoto;Studio.save();render();
            """)
            run('本地显影归档可继续调整，外部归档随副本交付',"""
              await library();choose('b1');await edit();act('scene-mode','sdr');
              const source=Studio.data.work,e=currentEdit(),saved=Studio.candidate(source,'初修',{...structuredClone(e.recipe),ev:0.9});
              const openSaved=()=>{const details=el('.results-menu');if(!details.open)tap('summary',details);act('open-versions',null,details);};
              const makeCopy=async label=>{await library();ctx(source);act('copy-request','create',dlg());set('[name=copyName]',label,dlg());act('copy-commit',null,dlg());return activeBrowser().focus;};
              openSaved();act('adopt',saved.id,dlg());act('return-adjustments',null,dlg());const local=await makeCopy('归档调色');
              assert(Studio.edit(local).recipe.ev===0.9&&Studio.activeArchive(local).originVersionID===saved.id,'adopted development recipe and artifact');
              assert(Studio.exportItem(local).versions[0].archive,'frozen local archive');await edit();set('[data-adjustment=ev]','0.6');
              assert(!Studio.exportItem(local).versions[0].archive&&Studio.exportItem(local).versions[0].recipe.ev===0.6,'new draft after editing');
              await library();choose(source);await edit();openSaved();act('external',null,dlg());act('external-result',null,dlg());
              const external=currentEdit().versions.at(-1);act('adopt',external.id,dlg());act('return-adjustments',null,dlg());
              const derived=await makeCopy('外部候选');Studio.asset(source).online=false;
              const item=Studio.exportItem(derived);assert(!item.online&&item.versions[0].archive&&Studio.activeArchive(derived).originVersionID===external.id,'offline source retains external bytes');
              Studio.asset(source).online=true;
            """)
            errors=json.loads(call('errors','--json'))['data']['errors']
            if errors: raise AssertionError(errors)
        finally:
            call('close'); server.shutdown()
if __name__=='__main__':
    main()
