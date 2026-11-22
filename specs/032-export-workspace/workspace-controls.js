const layoutFields=['frame','ratio','fit','paper','margin','stroke','strokeColor','shadow','mark','place','anchor','signature','font','ink','opacity','scale'];
const numericLookFields=new Set(['margin','stroke','opacity','scale']);
const anchors={tl:'左上',tc:'上中',tr:'右上',cl:'左中',cc:'居中',cr:'右中',bl:'左下',bc:'下中',br:'右下'};
let layoutRevision=0;
let incomingPreset=null;
let importRevision=0;

function presetStatus(message,warning=false) {
  const status=byId('preset-status');
  status.textContent=message;
  status.classList.toggle('warn',warning);
}
function imprintSummary(look,lines) {
  const pieces=[look.logo?'Logo':'',lines.signature,...lines.values].filter(Boolean);
  const result=pieces.length ? pieces.join(' · ') : '本张没有可绘制的内容';
  return result+(lines.missing.length?'（缺少'+lines.missing.join('、')+'）':'');
}
let draftLayout=null;
let paintRequest=0;
const logoImages=new Map();

function styleID(look) {
  const base=ExportLayout.style(look.builtin);
  if (base.mark==='both' && !look.signature.trim()) base.mark='exif';
  const appearance=l=>Object.keys(base).filter(k=>!['signature','logo'].includes(k)).every(k=>JSON.stringify(l[k])===JSON.stringify(base[k]));
  return appearance(look)?look.builtin:'custom';
}
function styleName(look) {
  return (styleID(look)==='custom'?'自定义 · ':'')+ExportLayout.styleNames[look.builtin];
}
function withIdentity(id,source) {
  const look=ExportLayout.style(id);
  look.signature=source.signature; look.logo=source.logo;
  if (look.mark==='both' && !look.signature.trim()) look.mark='exif';
  return look;
}
function requestPaint() {
  if (!paintRequest) paintRequest=requestAnimationFrame(()=>{ paintRequest=0; paint(); });
}
function logoFor(look) {
  if (!look.logo || look.mark==='off') return null;
  const {sha256}=look.logo;
  if (!logoImages.has(sha256)) {
    const entry={image:null}; logoImages.set(sha256,entry);
    if (logoImages.size>8) logoImages.delete(logoImages.keys().next().value);
    ExportPreset.loadImage(ExportPreset.logoURL(look.logo)).then(image=>{ entry.image=image; requestPaint(); })
      .catch(()=>{ if (draftLayout?.logo?.sha256===sha256) byId('studio-error').textContent='无法解码此 Logo。'; });
  }
  return logoImages.get(sha256)?.image;
}
function setLayout(look) {
  layout=structuredClone(look);
  byId('applied-look').hidden=styleID(layout)!=='custom';
  byId('applied-look').textContent=styleName(layout);
  selectCard('quick-styles',layout);
  requestPaint();
}
function commitLook(look) {
  setLayout(look); byId('preset').value='custom'; presetStatus(''); refresh();
}
function selectCard(container,look) {
  const selected=styleID(look);
  for (const radio of byId(container).querySelectorAll('input')) radio.checked=radio.value===selected;
}
function makeCards(container,pick) {
  const group=byId(container);
  for (const [id,name] of Object.entries(ExportLayout.styleNames)) {
    const label=document.createElement('label'); label.className='style-tile';
    const radio=document.createElement('input');
    radio.type='radio'; radio.name=container; radio.value=id; radio.id=container+'-'+id; radio.setAttribute('aria-label',name);
    const canvas=document.createElement('canvas'); canvas.width=234; canvas.height=126; canvas.setAttribute('aria-hidden','true');
    const title=document.createElement('span'); title.className='style-name'; title.textContent=name;
    radio.onchange=()=>{ if (radio.checked) pick(id); };
    label.append(radio,canvas,title); group.append(label);
  }
}
function renderCards(container,identity,image,photo,version) {
  const group=byId(container);
  for (const radio of group.querySelectorAll('input')) {
    const canvas=radio.nextElementSibling, look=withIdentity(radio.value,identity);
    const logo=logoFor(look);
    const key=[focus,photo.name,photo.choice,version.w,version.h,look.signature,logo?look.logo.sha256:'',radio.value].join('|');
    if (canvas.dataset.paint===key) continue;
    const geo=ExportLayout.plan(version,480,look);
    const factor=Math.min((canvas.width-10)/geo.width,(canvas.height-10)/geo.height);
    const sample=document.createElement('canvas'); sample.width=Math.max(1,Math.round(geo.width*factor)); sample.height=Math.max(1,Math.round(geo.height*factor));
    ExportLayout.draw(sample,image,version,look,geo,ExportLayout.lettering(look,photo),logo);
    const ctx=canvas.getContext('2d'); ctx.fillStyle='#262827'; ctx.fillRect(0,0,canvas.width,canvas.height);
    ctx.drawImage(sample,Math.floor((canvas.width-sample.width)/2),Math.floor((canvas.height-sample.height)/2));
    canvas.dataset.paint=key;
  }
}
function drawFitted(stage,canvas,image,version,look,geo,photo) {
  const factor=Math.min(Math.max(1,stage.clientWidth-20)/geo.width,Math.max(1,stage.clientHeight-20)/geo.height,1);
  const width=Math.max(1,Math.round(geo.width*factor)),height=Math.max(1,Math.round(geo.height*factor));
  const dpr=Math.min(window.devicePixelRatio || 1,2);
  canvas.style.width=width+'px'; canvas.style.height=height+'px';
  const pixelsW=Math.max(1,Math.round(width*dpr)),pixelsH=Math.max(1,Math.round(height*dpr));
  if (canvas.width!==pixelsW) canvas.width=pixelsW;
  if (canvas.height!==pixelsH) canvas.height=pixelsH;
  ExportLayout.draw(canvas,image,version,look,geo,ExportLayout.lettering(look,photo),logoFor(look));
}
function drawPreview() {
  const image=byId('photo'), photo=photos[focus], canvas=byId('composition');
  const ready=mode==='render' && inputAvailable(photo,mode) && !validateSettings() && image.complete && image.naturalWidth>0;
  image.hidden=ready; canvas.hidden=!ready;
  requestPaint();
}
function paint() {
  const image=byId('photo'),photo=photos[focus], canvas=byId('composition');
  if (!photo || !image.complete || !image.naturalWidth || mode!=='render') return;
  const version=photo.versions[photo.choice];
  if (!canvas.hidden) {
    const geo=geometry(version);
    canvas.setAttribute('aria-label',photo.scene+'，'+styleName(layout)+'，成品 '+geo.width+' × '+geo.height);
    drawFitted(byId('stage'),canvas,image,version,layout,geo,photo);
  }
  renderCards('quick-styles',layout,image,photo,version);
  if (!draftLayout || !byId('layout-dialog').open) return;
  renderCards('studio-styles',draftLayout,image,photo,version);
  if (!ExportLayout.valid(draftLayout)) return;
  const limit=Number(byId('size').value==='custom'?byId('edge').value:byId('size').value);
  const geo=ExportLayout.plan(version,limit>0?limit:0,draftLayout);
  drawFitted(byId('studio-stage'),byId('studio-image'),image,version,draftLayout,geo,photo);
  const lines=ExportLayout.lettering(draftLayout,photo);
  byId('studio-caption').textContent=[styleName(draftLayout),geo.width+' × '+geo.height+' px',
    draftLayout.mark!=='off'?imprintSummary(draftLayout,lines):''].filter(Boolean).join(' · ');
  const logo=logoFor(draftLayout);
  byId('logo-info').textContent=logo?logo.naturalWidth+' × '+logo.naturalHeight+' px · PNG':'PNG / JPEG · 长边最多 512 px';
}
function syncDraft(fill=false) {
  if (!draftLayout) return;
  const look=draftLayout, framed=look.frame!=='none';
  if (!framed) look.place='photo';
  if (look.place==='footer' && look.anchor[0]!=='b') look.anchor='b'+look.anchor[1];
  if (fill) {
    for (const key of layoutFields) {
      if (key==='shadow') byId(key).checked=look[key]; else if (key!=='anchor') byId(key).value=look[key];
    }
    for (const box of byId('exif-checks').querySelectorAll('input')) box.checked=look.fields.includes(box.value);
  }
  byId('place').value=look.place;
  byId('place').querySelector('[value=footer]').disabled=!framed;
  const choices=Object.entries(anchors).filter(([key])=>look.place!=='footer' || key[0]==='b');
  const anchor=byId('anchor');
  if (anchor.options.length!==choices.length) anchor.replaceChildren(...choices.map(([key,name])=>new Option(look.place==='footer'?{bl:'靠左',bc:'居中',br:'靠右'}[key]:name,key)));
  anchor.value=look.anchor;
  selectCard('studio-styles',look);
  byId('frame-options').hidden=!framed; byId('paper-field').hidden=look.frame!=='solid'; byId('stroke-field').hidden=!look.stroke;
  byId('cover-hint').hidden=!framed || look.fit!=='cover'; byId('mark-options').hidden=look.mark==='off';
  byId('signature-field').hidden=!['signature','both'].includes(look.mark); byId('exif-field').hidden=!['exif','both'].includes(look.mark);
  byId('font').closest('.two').hidden=look.mark==='logo';
  byId('choose-logo').textContent=look.logo?'更换 Logo…':'添加 Logo…'; byId('remove-logo').hidden=!look.logo;
  const error=ExportLayout.valid(look)?ExportLayout.problem(look):'请检查边距、细线、大小和不透明度的取值。';
  byId('studio-error').textContent=error;
  byId('apply-layout').disabled=Boolean(error) || logoPending;
  requestPaint();
}
let logoPending=false;
function openStudio(look=layout) {
  layoutRevision++; logoPending=false; draftLayout=structuredClone(look);
  const photo=photos[focus];
  byId('studio-source').textContent=photo.name+(inputAvailable(photo,mode)?'':' · 资料库缩略图试排');
  byId('layout-panel').open=Boolean(ExportLayout.problem(look));
  byId('layout-dialog').showModal(); syncDraft(true);
  const selected=byId('studio-styles').querySelector('input:checked') || byId('studio-styles').querySelector('input');
  selected.focus();
}
byId('edit-layout').onclick=()=>openStudio();
byId('cancel-layout').onclick=()=>byId('layout-dialog').close();
byId('apply-layout').onclick=()=>{
  if (!draftLayout || byId('apply-layout').disabled) return;
  commitLook(draftLayout); byId('layout-dialog').close();
};
byId('layout-dialog').addEventListener('close',()=>{ layoutRevision++; draftLayout=null; logoPending=false; selectCard('quick-styles',layout); });
makeCards('quick-styles',id=>{
  const look=withIdentity(id,layout);
  if (ExportLayout.problem(look)) { selectCard('quick-styles',layout); openStudio(look); }
  else commitLook(look);
});
makeCards('studio-styles',id=>{
  layoutRevision++; logoPending=false; draftLayout=withIdentity(id,draftLayout); syncDraft(true);
});
for (const [key,name] of Object.entries(ExportLayout.exifNames)) {
  const box=document.createElement('input'),label=document.createElement('label');
  box.type='checkbox'; box.value=key;
  box.onchange=()=>{ if (draftLayout) { draftLayout.fields=Array.from(byId('exif-checks').querySelectorAll('input:checked'),el=>el.value); syncDraft(); } };
  label.append(box,name); byId('exif-checks').append(label);
}
for (const key of layoutFields) byId(key).addEventListener('input',event=>{
  if (!draftLayout) return;
  const el=event.target;
  draftLayout[key]=key==='shadow'?el.checked:numericLookFields.has(key)?el.valueAsNumber:el.value;
  syncDraft();
});
byId('choose-logo').onclick=()=>byId('logo-file').click();
byId('logo-file').onchange=async event=>{
  const file=event.target.files[0]; event.target.value='';
  if (!file || !draftLayout) return;
  const revision=++layoutRevision; logoPending=true; syncDraft();
  try {
    const logo=await ExportPreset.makeLogo(file);
    if (revision===layoutRevision && draftLayout) { draftLayout.logo=logo; logoPending=false; syncDraft(); }
  } catch (error) {
    if (revision===layoutRevision && draftLayout) { logoPending=false; syncDraft(); byId('studio-error').textContent=error.message; }
  }
};
byId('remove-logo').onclick=()=>{ layoutRevision++; logoPending=false; draftLayout.logo=null; syncDraft(); };
new ResizeObserver(requestPaint).observe(byId('studio-stage'));

function storePreset(payload) {
  const {name:base,settings}=payload;
  const json=JSON.stringify(settings);
  for (const saved of memory.presets) {
    if (saved.name!==base && saved.sourceName!==base) continue;
    const upgraded=ExportPreset.upgradeLocal(saved.settings);
    if (JSON.stringify(ExportPreset.canonical(upgraded))===json) return saved;
  }
  let name=base, count=2;
  while (memory.presets.some(p=>p.name===name)) {
    const suffix=' ('+count+')';
    name=base.slice(0,70-suffix.length)+suffix; count++;
  }
  const saved={id:'user-'+crypto.randomUUID(),name,sourceName:base,settings};
  memory.presets.push(saved);
  try { updateMemory(); }
  catch { memory.presets.pop(); throw new Error('本机存储空间不足或不可用，无法保存这个预设。'); }
  return saved;
}
function showExchange(settings,imported) {
  incomingPreset=imported;
  byId('exchange-error').textContent='';
  byId('exchange-title').textContent=imported?'导入导出预设':'分享导出预设';
  byId('confirm-exchange').textContent=imported?'添加并应用':'保存预设文件';
  byId('share-name-field').hidden=Boolean(imported);
  byId('share-name').required=!imported;
  byId('import-name').hidden=!imported;
  if (imported) byId('import-name').textContent='「'+imported.name+'」';
  else {
    const preset=byId('preset');
    byId('share-name').value=['custom','previous'].includes(preset.value)?'我的导出设置':preset.selectedOptions[0].textContent;
  }
  const look=settings.layout;
  const size=settings.size==='0'?'版本全尺寸':'长边 '+(settings.size==='custom'?settings.edge:settings.size)+' px';
  const fields=['exif','both'].includes(look.mark)?look.fields.map(k=>ExportLayout.exifNames[k]).join('、'):'';
  const embed=look.logo;
  const signature=look.signature;
  const metadata={rights:'仅版权',photo:'拍摄信息与版权',none:'移除描述性元数据'}[settings.metadata];
  const mat={none:'无边框',solid:'纯色边框',blur:'模糊底板'}[look.frame];
  const printing=[signature?'署名「'+signature+'」':'',fields,embed?'包含 Logo 图像':''].filter(Boolean).join(' · ') || '关闭';
  const rows=[
    ['交付方式',settings.mode==='render'?'导出成片':'原件与清单'],
    ['原件设置',(settings.copyMode==='manifest'?'仅写清单':'复制原始字节，保留原有元数据并附清单')+' · '+({all:'全部格式',both:'RAW 与 JPEG',raw:'仅 RAW',jpeg:'仅 JPEG'})[settings.originalFormat]],
    ['成片设置',[settings.format.toUpperCase(),size,settings.format==='jpeg'?'质量 '+settings.quality+'%':'16 位','sRGB'].join(' · ')],
    ['版式',mat+(look.frame==='none'?'':' · '+(look.ratio==='source'?'随照片':look.ratio)+' · '+(look.fit==='cover'?'居中填满':'完整保留'))],
    ['水印档案',printing+(look.mark==='off' || settings.mode==='original'?'（本次关闭）':'')],['成片元数据',metadata+' · '+(settings.gps && settings.metadata==='photo'?'保留已有 GPS':settings.gps?'去除定位，拍摄信息模式保留 GPS':'去除定位')],
    ['命名',settings.template+' · '+(settings.collision==='skip'?'重名跳过':'重名保留两份')]
  ];
  const list=byId('exchange-summary'); list.replaceChildren();
  for (const [label,value] of rows) {
    const term=document.createElement('dt'),desc=document.createElement('dd');
    term.textContent=label; desc.textContent=value; list.append(term,desc);
  }
  const slot=byId('exchange-logo-slot'); slot.hidden=!embed; slot.replaceChildren();
  if (embed) {
    const img=new Image(); img.id='exchange-logo'; img.alt='预设内嵌的 Logo';
    img.src=ExportPreset.logoURL(embed); slot.append(img);
  }
  byId('exchange').showModal();
  (imported?byId('confirm-exchange'):byId('share-name')).focus();
}
byId('share-preset').onclick=()=>{ presetStatus(''); showExchange(currentSettings(),null); };
byId('import-preset').onclick=()=>byId('preset-file').click();
byId('preset-file').onchange=async event=>{
  const file=event.target.files[0]; event.target.value='';
  if (!file) return;
  const revision=++importRevision;
  try {
    const payload=await ExportPreset.read(file);
    if (revision===importRevision) { presetStatus(''); showExchange(payload.settings,payload); }
  } catch (error) { if (revision===importRevision) presetStatus(error.message,true); }
};
byId('cancel-exchange').onclick=()=>byId('exchange').close();
byId('exchange-form').onsubmit=event=>{
  event.preventDefault();
  try {
    if (incomingPreset) {
      const saved=storePreset(incomingPreset);
      byId('preset').value=saved.id; loadPreset(); refresh();
      presetStatus('已应用「'+saved.name+'」。');
    } else {
      const file=ExportPreset.envelope(byId('share-name').value,currentSettings());
      ExportPreset.download(file); presetStatus('已生成「'+file.name+'」预设文件。');
    }
    byId('exchange').close();
  } catch (error) { byId('exchange-error').textContent=error.message; }
};
byId('photo').addEventListener('load',drawPreview);
new ResizeObserver(drawPreview).observe(byId('stage'));
showPresets(); setLayout(layout); refresh();
