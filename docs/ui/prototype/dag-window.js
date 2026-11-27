'use strict';

const dagLegacyTools = Object.fromEntries(['basic','detail','grading','effects'].map(key=>[key,structuredClone(editTools[key][1])]));
Object.assign(editTools, {
  hdr: ['HDR 色轮', [['hdrBlack','黑部曝光',-6,6,.05],['hdrDark','暗部曝光',-6,6,.05],['hdrShadow','阴影曝光',-6,6,.05],['hdrLight','亮部曝光',-6,6,.05],['hdrHighlight','高光曝光',-6,6,.05],['hdrSpecular','镜面高光曝光',-6,6,.05],['hdrSaturation','HDR 饱和度'],['hdrRange','区域范围'],['hdrFalloff','区域过渡',0,100]]],
  slice: ['色彩切片', [['sliceHue','切片色相'],['sliceSaturation','切片饱和度'],['sliceDensity','切片密度'],['sliceWidth','切片宽度',0,100],['sliceDepth','色彩深度',0,100]]],
  warper: ['色彩变形', [['warperHue','网格色相'],['warperSaturation','网格饱和度'],['warperStrength','网格强度',0,100]]],
  input: ['输入',[]], mix: ['混合',[]], group: ['节点组',[]], geometry: ['照片几何',[]], output: ['最终输出',[]],
});
Object.assign(panelIcons,{hdr:'grading',slice:'mix',warper:'grid',input:'camera',mix:'layers',group:'folder',geometry:'crop',output:'export'});
const dagPanels = ['basic','grading','hdr','tones','color','slice','warper','detail','effects'];
const dagBlendModes = ['normal','add','subtract','multiply','screen','overlay','soft-light','hard-light','lighten','darken','difference','color','luminosity'];
editTools.basic[1] = [['warmth','创意色温'],['tint','创意色调'],['ev','曝光',-5,5,.01],['contrast','对比度'],['high','高光'],['shadow','阴影'],['white','白色色阶'],['black','黑色色阶'],['texture','纹理'],['clarity','清晰度'],['dehaze','去雾'],['vibrance','自然饱和度'],['sat','饱和度']];
editTools.grading[1].push(['lift','Lift'],['gamma','Gamma'],['gain','Gain'],['offset','Offset'],['wheelContrast','色轮对比'],['pivot','枢轴'],['midDetail','中间调细节'],['colorBoost','色彩增强'],['lumMix','亮度混合',0,100],['logLow','Log 低范围',0,100],['logHigh','Log 高范围',0,100]);
editTools.detail[1] = [['sharp','锐化量',0,100],['sharpRadius','锐化半径',0,10,.1],['sharpDetail','锐化细节',0,100],['sharpMasking','锐化遮蔽',0,100],['noise','明度降噪',0,100],['noiseLumDetail','明度降噪细节',0,100],['noiseLumContrast','明度降噪对比',0,100],['noiseColor','颜色降噪',0,100],['noiseColorDetail','颜色降噪细节',0,100],['noiseColorSmooth','颜色平滑',0,100],['blur','模糊',-100,100]];
editTools.effects[1].push(['vignetteMidpoint','暗角中心',0,100],['vignetteRoundness','暗角圆度'],['vignetteFeather','暗角羽化',0,100],['vignetteHighlights','暗角高光',0,100],['grainAmount','颗粒数量',0,100],['grainSize','颗粒大小',0,100],['grainRoughness','颗粒粗糙度',0,100],['bloom','Bloom',0,100],['bloomThreshold','Bloom 阈值',0,10,.1],['halation','Halation',0,100]);
dagScalarKeys.push(...dagPanels.flatMap(key=>editTools[key][1].map(([field])=>field)).filter(key=>!dagScalarKeys.includes(key)));
const dagToolFields = Object.fromEntries(Object.entries(editTools).map(([key,tool])=>[key,structuredClone(tool[1])]));
for(const [key,fields] of Object.entries(dagLegacyTools))editTools[key][1]=fields;
dagToolFields.color = [['hue','选色色相'],['sat','选色饱和度'],['luminance','选色明度']];
dagToolFields.slice.push(['sliceCenter','切片中心'],['sliceGlobalSaturation','全局饱和度'],['sliceGlobalDensity','全局密度']);
dagToolFields.warper.push(['hueColumns','色相网格列数',2,16,1],['satRows','饱和度网格行数',2,16,1],['mesh','网格精度',2,12,1]);
const dagDefaults={sharpRadius:1,sharpDetail:25,noiseLumDetail:50,noiseColorDetail:50,noiseColorSmooth:50,vignetteMidpoint:50,vignetteFeather:50,grainSize:25,grainRoughness:50,bloomThreshold:2,warperStrength:100,hueColumns:6,satRows:5,mesh:4};
function dagFields(category,params) {
  const choice=params['choice:'+category];
  if(category==='color'&&choice==='RGB 矩阵')return Array.from({length:9},(_,i)=>['rgbMatrix'+i,'RGB '+(Math.floor(i/3)+1)+' → '+(i%3+1),-200,200,1]);
  if(category==='tones'&&choice==='参数曲线')return [['paramShadows','阴影'],['paramDarks','暗调'],['paramLights','亮调'],['paramHighlights','高光'],['split1','分割点 1',0,100],['split2','分割点 2',0,100],['split3','分割点 3',0,100]].map(([k,l,lo=-100,hi=100])=>[k,l,lo,hi,1]);
  if(category==='grading'&&choice&&choice!=='全局')return [['wheelX:'+choice,'色轮 X',-100,100,1],['wheelY:'+choice,'色轮 Y',-100,100,1],['wheelMaster:'+choice,'色轮明度',-100,100,1],['wheelSaturation:'+choice,'色轮饱和度',0,100,1]];
  const fields=dagToolFields[category] || [];
  return fields.map(([key,label,low=-100,high=100,step=1])=>{
    const choice=params['choice:'+category];
    const scoped=choice && ['tones','color','slice','grading'].includes(category) ? key+':'+choice : key;
    return [scoped,label,low,high,step];
  });
}
function dagCategoryOptions(category,params) {
  const options={grading:['全局','Lift','Gamma','Gain','Offset','Log 阴影','Log 中间调','Log 高光','分级阴影','分级中间调','分级高光'],tones:['master','red','green','blue','参数曲线','Hue vs Hue','Hue vs Sat','Hue vs Lum','Lum vs Sat','Sat vs Sat','Sat vs Lum'],color:['red','orange','yellow','green','aqua','blue','purple','magenta','RGB 矩阵'],slice:['red','skin','yellow','green','cyan','blue','magenta']}[category];
  const selector=options ? select('参数子域','dagCategoryChoice',options,params['choice:'+category] || options[0]).replace('<select ','<select data-key="choice:'+category+'" ') : '';
  return selector + (category==='color' ? check('保留亮度','dagPreserveLuminance',params.preserveLuminance !== false) + check('单色','dagMonochrome',!!params.mono) : '') + (category==='effects' ? select('暗角模式','dagCategoryChoice',['highlight-priority','color-priority','paint-overlay'],params.vignetteStyle || 'highlight-priority').replace('<select ','<select data-key="vignetteStyle" ') : '') + (category==='warper' ? `<div class="dag-warper-grid" data-act="dag-warper-pin" data-node="${h(dagView().active)}" data-photo="${h(Studio.data.work)}" role="button" tabindex="0" aria-label="在色彩网格添加控制点">${(params.pins || []).map(pin=>`<i style="left:${pin.x}%;top:${pin.y}%"></i>`).join('')}</div>${btn('清除网格控制点','dag-warper-clear')}` : '');
}
changes.dagPreserveLuminance=el=>dagCommit('保留节点亮度',g=>g.nodes.find(n=>n.id===dagView().active).params.preserveLuminance=el.checked);
changes.dagMonochrome=el=>dagCommit('节点单色',g=>g.nodes.find(n=>n.id===dagView().active).params.mono=el.checked);
actions['dag-warper-pin']=(value,event,element)=>{
  if(element.dataset.node!==dagView().active||element.dataset.photo!==Studio.data.work)return;
  const box=element.getBoundingClientRect(),x=Number.isFinite(event.clientX)&&event.clientX?Math.max(0,Math.min(100,(event.clientX-box.left)*100/box.width)):50,y=Number.isFinite(event.clientY)&&event.clientY?Math.max(0,Math.min(100,(event.clientY-box.top)*100/box.height)):50;
  dagCommit('添加色彩网格控制点',g=>{const node=g.nodes.find(n=>n.id===dagView().active);(node.params.pins ??= []).push({id:Studio.uid(),x,y});node.params.warperHue=(x-50)/2;node.params.warperSaturation=(50-y)/2;});
};
actions['dag-warper-clear']=()=>dagCommit('清除色彩网格控制点',g=>{const p=g.nodes.find(n=>n.id===dagView().active).params;p.pins=[];p.warperHue=0;p.warperSaturation=0;});
function dagCapabilities(node = dagEnabled() ? dagNode() : {kind:'grade'}) {
  return node?.kind === 'grade' ? dagPanels : [{source:'input',mix:'mix',group:'group',geometry:'geometry',output:'output'}[node?.kind]].filter(Boolean);
}
function dagWindowFrame(v = dagView()) {
  const margin = 12, top = innerHeight >= 420 ? 60 : margin;
  const maxWidth = Math.max(1, innerWidth - 2 * margin), maxHeight = Math.max(1, innerHeight - top - margin);
  if (!v.window) {
    const width = Math.min(760, maxWidth), height = Math.min(460, maxHeight);
    v.window = {x:(innerWidth-width)/2, y:top+(maxHeight-height)/2, width, height};
  }
  const w = v.window;
  w.width = Math.min(maxWidth, Math.max(520, w.width));
  w.height = Math.min(maxHeight, Math.max(240, w.height));
  w.x = Math.max(margin, Math.min(w.x, innerWidth-w.width-margin));
  w.y = Math.max(top, Math.min(w.y, innerHeight-w.height-margin));
  return w;
}
function dagWindowHandles(close, value = '') {
  return `<div class="graph-window-actions"><button type="button" class="dag-window-move" data-dag-window-drag aria-label="移动 Graph 窗口" title="拖动或用方向键移动窗口">${icon('move', 14)}</button>
    ${btn('关闭 Graph', close, value, {icon:'close', only:true})}</div>
    <button type="button" class="dag-window-resize" data-dag-window-resize aria-label="调整 Graph 窗口大小" title="拖动或用方向键调整窗口大小">◢</button>`;
}
function dagFloatingWindow() {
  if (!dagEnabled() || dagView().mode !== 'graph' || S.tool === 'versions' || S.canvasTool) return '';
  const w = dagWindowFrame();
  if (!w.framePending) {
    const photo=Studio.data.work; w.framePending=true;
    queueMicrotask(()=>{
      delete w.framePending;
      if(S.page!=='edit'||photo!==Studio.data.work||dagView().window!==w||dagView().mode!=='graph'||!$('[data-dag-viewport]')||S.canvasTool)return;
      if (w.layoutVersion!==3) { w.layoutVersion=3; dagFrameGraph('readable'); }
      else if (dagTransform().framing!=='manual') dagFrameGraph();
    });
  }
  return `<section id="dag-floating-window" class="dag-floating" role="dialog" aria-modal="false" aria-label="工作流 Graph 悬浮窗口 · ${h(Studio.displayName(Studio.data.work))}" style="left:${w.x}px;top:${w.y}px;width:${w.width}px;height:${w.height}px">${dagCanvas()}${dagWindowHandles('dag-view','photo')}</section>`;
}
// Review the native compatibility slice in the same workbench without seeding a graph recipe.
const compatibilityGraphMode = new URLSearchParams(location.search).get('compatibilityGraph') === '1';
const compatibilityGraphFrames = new Map();
let compatibilityGraphPhoto = null;
function compatibilityGraphReason() {
  if (!Studio.asset(Studio.data.work)?.online) return '原片离线，请先接回原片';
  if (S.canvasTool || quickPromptVisible()) return '请先完成或取消画布工具';
  if (dagEnabled() || SceneEditor.hdr()) return '只读兼容图仅支持旧显影配方';
  return '';
}
function compatibilityGraphToolbar() {
  const reason = compatibilityGraphReason();
  return `<section class="dag-scope-head" aria-label="节点作用域"><span class="dag-picker-label">当前节点</span><div class="dag-picker-row"><strong>兼容显影</strong>
    ${btn('忽略该节点','compatibility-ignore','',{icon:'bypass',only:true,cls:'icon-btn',disabled:true,title:'兼容显影节点不能忽略'})}
    ${btn('Graph 窗口','compatibility-graph-toggle','',{icon:'layers',only:true,cls:'icon-btn',pressed:!reason && compatibilityGraphPhoto===Studio.data.work,disabled:!!reason,title:reason || '打开只读兼容图'})}</div>
    <small>${h(reason || '只读兼容图 · 现有调整仍作用于整张照片')}</small></section>`;
}
function compatibilityGraphFrame() {
  const id = Studio.data.work;
  if (!compatibilityGraphFrames.has(id)) {
    const width=Math.min(640,innerWidth-24),height=392;
    compatibilityGraphFrames.set(id, {window:{x:innerWidth-width-12,y:innerHeight-height-76,width,height,scale:1}});
  }
  return dagWindowFrame(compatibilityGraphFrames.get(id));
}
function compatibilityGraphWindow() {
  if (compatibilityGraphPhoto !== Studio.data.work || S.tool === 'versions' || compatibilityGraphReason()) {
    compatibilityGraphPhoto = null;
    return '';
  }
  const w = compatibilityGraphFrame();
  return `<section class="dag-floating dag-compat" role="dialog" aria-modal="false" aria-label="只读兼容图 · ${h(Studio.displayName(Studio.data.work))}" style="left:${w.x}px;top:${w.y}px;width:${w.width}px;height:${w.height}px">
    <div class="dag-compat-canvas" tabindex="0" aria-label="照片来源到最终输出" aria-description="只读兼容图，使用现有显影配方"><div class="dag-compat-nodes" style="zoom:${w.scale}"><div><b>照片来源</b><small>固定输入</small></div><span aria-hidden="true">→</span><div><b>兼容显影</b><small>沿用现有配方</small></div><span aria-hidden="true">→</span><div><b>最终输出</b><small>预览与交付不变</small></div></div></div>
    <div class="dag-zoom-controls" aria-label="Graph 缩放">${btn('−','compatibility-zoom','out')}${btn(Math.round(100 * w.scale) + '%','compatibility-zoom','fit',{title:'复位缩放'})}${btn('＋','compatibility-zoom','in')}</div>
    ${dagWindowHandles('compatibility-graph-toggle')}</section>`;
}
actions['compatibility-graph-toggle'] = () => {
  if (compatibilityGraphPhoto === Studio.data.work) {
    compatibilityGraphPhoto = null;
    dagRenderFocus('.dag-scope-head [data-act=compatibility-graph-toggle]');
  } else if (!compatibilityGraphReason()) {
    compatibilityGraphPhoto = Studio.data.work;
    dagRenderFocus('.dag-compat-canvas');
  }
};
actions['compatibility-zoom'] = direction => {
  const w = compatibilityGraphFrame();
  w.scale = direction === 'fit' ? 1 : Math.min(2, Math.max(.5, w.scale * (direction === 'in' ? 1.2 : 1/1.2)));
  dagRenderFocus('.dag-compat-canvas');
};
window.addEventListener('hashchange', () => {
  if (!location.hash.startsWith('#edit/') || location.hash === '#edit/versions') compatibilityGraphPhoto = null;
});
document.addEventListener('keydown', event => {
  if (event.defaultPrevented || !event.target.closest('.dag-compat')) return;
  if (event.key === 'Escape') { event.preventDefault(); actions['compatibility-graph-toggle'](); }
  else if (event.target.matches('.dag-compat-canvas') && ['-', '+', '=', '0'].includes(event.key)) {
    event.preventDefault(); actions['compatibility-zoom'](event.key === '0' ? 'fit' : event.key === '-' ? 'out' : 'in');
  }
});
let dagWindowResizeFrame;
window.addEventListener('resize',()=>{
  dagPickerClose();cancelAnimationFrame(dagWindowResizeFrame);
  dagWindowResizeFrame=requestAnimationFrame(()=>{if(S.page==='edit'&&(compatibilityGraphMode ? compatibilityGraphPhoto : dagEnabled()&&dagView().mode==='graph'))render();});
});
let dagWindowPointer;
document.addEventListener('pointerdown',event=>{
  const handle=event.target.closest('[data-dag-window-drag],[data-dag-window-resize]');
  if(!handle||S.canvasTool||event.button!==0)return;
  const panel=handle.closest('.dag-floating'),frame=panel.classList.contains('dag-compat')?compatibilityGraphFrame:dagWindowFrame;dagWindowPointer={panel,frame,photo:Studio.data.work,resize:handle.hasAttribute('data-dag-window-resize'),x:event.clientX,y:event.clientY,origin:{...frame()}};
  handle.setPointerCapture(event.pointerId);event.preventDefault();
});
document.addEventListener('pointermove',event=>{
  const p=dagWindowPointer;if(!p)return;if(p.photo!==Studio.data.work||!p.panel.isConnected){dagWindowPointer=null;return;}const w=p.frame(),dx=event.clientX-p.x,dy=event.clientY-p.y;
  if(p.resize){w.width=p.origin.width+dx;w.height=p.origin.height+dy;}else{w.x=p.origin.x+dx;w.y=p.origin.y+dy;}
  p.frame();Object.assign(p.panel.style,{left:w.x+'px',top:w.y+'px',width:w.width+'px',height:w.height+'px'});
});
function dagWindowEnd(){const pointer=dagWindowPointer;if(!pointer)return;dagWindowPointer=null;if(pointer.panel.classList.contains('dag-compat'))return;if(pointer.resize&&pointer.panel.isConnected&&pointer.photo===Studio.data.work)dagFrameGraph();Studio.save();}
document.addEventListener('pointerup',dagWindowEnd);document.addEventListener('pointercancel',dagWindowEnd);
document.addEventListener('keydown',event=>{
  const handle = event.target.closest('[data-dag-window-resize],[data-dag-window-drag]');
  if (!handle || !event.key.startsWith('Arrow')) return;
  const frame = handle.closest('.dag-compat') ? compatibilityGraphFrame : dagWindowFrame, w = frame();
  const resize = handle.hasAttribute('data-dag-window-resize');
  const dx = {ArrowLeft:-20, ArrowRight:20}[event.key] || 0, dy = {ArrowUp:-20, ArrowDown:20}[event.key] || 0;
  if (resize) { w.width += dx; w.height += dy; }
  else { w.x += dx; w.y += dy; }
  event.preventDefault(); frame(); dagRenderFocus(resize ? '[data-dag-window-resize]' : '[data-dag-window-drag]');
});
changes.dagBlend=el=>dagCommit('图层混合方式',g=>g.nodes.find(n=>n.id===dagView().active).params['blend:'+el.dataset.slot]=el.value);
changes.dagMixMode=el=>dagCommit('切换 Mixer 类型',g=>g.nodes.find(n=>n.id===dagView().active).params.mode=el.value);
changes.dagCategoryChoice=el=>dagCommit('节点选项：'+el.value,g=>g.nodes.find(n=>n.id===dagView().active).params[el.dataset.key]=el.value);
actions['dag-add-input']=()=>{
  const mixer=dagNode();if(mixer?.kind!=='mix')return;
  let id;dagCommit('添加 Mixer 输入（0%）',g=>{
    const slots=g.edges.filter(e=>e.to===mixer.id),base=slots.find(e=>e.slot==='base'),slot='layer'+slots.length;
    id=dagID();g.nodes.splice(g.nodes.findIndex(n=>n.id===mixer.id),0,{id,kind:'grade',name:'混合输入 '+slots.length,enabled:true,params:{}});
    g.edges.push({from:base.from,to:id,slot:'image'},{from:id,to:mixer.id,slot});g.nodes.find(n=>n.id===mixer.id).params['weight:'+slot]=0;
  });render();
};
actions['dag-input-move']=value=>{
  const [slot,direction]=value.split(':');dagCommit('调整混合输入顺序',g=>{
    const edges=g.edges.filter(e=>e.to===dagView().active).sort((a,b)=>dagSlotRank(a.slot)-dagSlotRank(b.slot)),index=edges.findIndex(e=>e.slot===slot),other=edges[index+Number(direction)];
    if(!other||other.slot==='base'||slot==='base')return;
    const node=g.nodes.find(n=>n.id===dagView().active),weight=s=>s==='layer'?node.params.amount ?? 0:node.params['weight:'+s] ?? 0,a=weight(slot),b=weight(other.slot),modeA=node.params['blend:'+slot] || 'normal',modeB=node.params['blend:'+other.slot] || 'normal';
    [edges[index].from,other.from]=[other.from,edges[index].from];
    for(const [s,value,mode] of [[slot,b,modeB],[other.slot,a,modeA]]){if(s==='layer')node.params.amount=value;else node.params['weight:'+s]=value;node.params['blend:'+s]=mode;}
  });
};
function dagSlotRank(slot){return slot==='base'?0:slot==='layer'?1:Number(slot.slice(5));}
actions['dag-outside']=()=>{
  closeSheet();const original=dagNode();if(original?.kind!=='grade'||!original.mask)return notify('Outside 需要一个已有蒙版的调色节点');
  if(!dagInsertion(dagCurrent()))return;let id;
  dagCommit('添加 Outside 调色',g=>{const edge=dagInsertion(g),copy=structuredClone(original);copy.id=id=dagID();copy.name=original.name+' · Outside';copy.params={};copy.enabled=true;copy.mask.invert=!copy.mask.invert;for(const component of copy.mask.components || [])component.id=Studio.uid();g.nodes.splice(g.nodes.findIndex(n=>n.id===edge.to),0,copy);g.edges=g.edges.filter(e=>e!==edge);g.edges.push({from:edge.from,to:id,slot:'image'},{from:id,to:edge.to,slot:edge.slot});});
  if(id)dagSelect(id);
};
actions['dag-duplicate']=()=>{actions['dag-copy']();actions['dag-paste']();};
actions['dag-paste-attributes']=()=>{
  closeSheet();const source=S.dagClipboard?.nodes.find(n=>n.kind==='grade');if(!source||dagNode()?.kind!=='grade')return notify('先复制调色节点，再选择目标调色节点');
  dagCommit('粘贴节点参数（不改变拓扑）',g=>g.nodes.find(n=>n.id===dagView().active).params=structuredClone(source.params));
};
actions['dag-add-before']=()=>{closeSheet();const edge=dagCurrent().edges.find(e=>e.to===dagView().active);if(!edge)return notify('当前节点前没有可插入的图像边');dagView().edge=edge.to+':'+edge.slot;actions['dag-add']('serial');};
actions['dag-append']=()=>{closeSheet();dagView().edge=null;dagView().active=dagCurrent().nodes.find(n=>n.kind==='output').id;actions['dag-add']('serial');};
actions['dag-reset-grades']=()=>{closeSheet();dagCommit('复位调色参数并保留节点',g=>g.nodes.filter(n=>n.kind==='grade').forEach(n=>n.params={}));};
actions['dag-bypass-all']=()=>{closeSheet();dagCommit('切换忽略所有调色节点',g=>{const nodes=g.nodes.filter(n=>n.kind==='grade'),enabled=nodes.some(n=>n.enabled===false);nodes.forEach(n=>n.enabled=enabled);});};
actions['dag-neighbor']=direction=>{const nodes=dagCurrent().nodes,i=nodes.findIndex(n=>n.id===dagView().active);dagSelect(nodes[Math.max(0,Math.min(nodes.length-1,i+Number(direction)))].id);};
let dagWirePointer;
document.addEventListener('pointerdown',event=>{
  const port=event.target.closest('.output-port');if(!port||event.button!==0||S.canvasTool)return;
  dagWirePointer={from:port.dataset.val.split(':')[0],x:event.clientX,y:event.clientY,moved:false};
});
document.addEventListener('pointermove',event=>{if(dagWirePointer&&Math.hypot(event.clientX-dagWirePointer.x,event.clientY-dagWirePointer.y)>5){dagWirePointer.moved=true;$('.dag-status').textContent='拖线中：释放到有名输入端口，生成待校验草稿';}});
document.addEventListener('pointerup',event=>{const wire=dagWirePointer;dagWirePointer=null;if(!wire?.moved)return;const target=event.target.closest('.input-port');if(!target)return notify('连接已取消：请释放到输入端口');const [id,slot]=target.dataset.val.split(':');dagPropose(wire.from,id,slot);});
document.addEventListener('pointercancel',()=>dagWirePointer=null);
document.addEventListener('keydown',event=>{
  if(event.defaultPrevented||event.isComposing||!['Enter',' '].includes(event.key)||!event.target.matches('.dag-warper-grid,.dag-wire'))return;
  event.preventDefault();actions[event.target.dataset.act](event.target.dataset.val,event,event.target);
});
