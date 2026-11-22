// The portable envelope contains rendering instructions. A destination belongs to the local batch.
const ExportPreset = (() => {
  const kind = 'rawmaster.export-preset';
  const maxFile = 2 * 1024 * 1024;
  const defaults = {mode:'render',copyMode:'files',originalFormat:'all',format:'jpeg',size:'2048',edge:'3000',quality:'90',color:'srgb',template:'{name}-{index}',collision:'rename',metadata:'rights',gps:false};
  const builtin = id => {
    const settings = {...defaults,layout:ExportLayout.style()};
    if (id === 'master') Object.assign(settings,{format:'tiff',size:'0'});
    if (id === 'full') Object.assign(settings,{size:'0',quality:'95'});
    if (id === 'portfolio') Object.assign(settings,{quality:'95',layout:ExportLayout.style('paper')});
    if (id === 'social') Object.assign(settings,{size:'1350',layout:ExportLayout.style('mist')});
    if (id === 'originals') settings.mode='original';
    return settings;
  };
  const keysMatch = (obj,keys) => obj && typeof obj==='object' && !Array.isArray(obj) &&
    Object.keys(obj).length===keys.length && keys.every(key=>Object.hasOwn(obj,key));
  function templateOK(value) {
    return typeof value==='string' && value.trim() && value.length<=180 && !/[\/\\:\x00-\x1f]/.test(value)
      && !/[{}]/.test(value.replace(/\{(name|index|date|captureDate)\}/g,'')) && !/^\.{1,2}$/.test(value.trim());
  }
  function canonical(settings) {
    const output=Object.fromEntries(Object.keys(defaults).map(k=>[k,settings[k]]));
    const look=settings.layout;
    output.layout=Object.fromEntries(Object.keys(ExportLayout.style()).map(k=>[k,structuredClone(look[k])]));
    if (output.layout.logo) {
      const {mime,sha256,base64}=output.layout.logo;
      output.layout.logo={mime,sha256,base64};
    }
    return output;
  }
  function settingsOK(s) {
    const l=s?.layout;
    const digits=(v,min,max)=>typeof v==='string' && /^\d+$/.test(v) && +v>=min && +v<=max;
    return keysMatch(s,[...Object.keys(defaults),'layout']) && ['render','original'].includes(s.mode)
      && ['files','manifest'].includes(s.copyMode) && ['all','both','jpeg','raw'].includes(s.originalFormat) && ['jpeg','tiff','png'].includes(s.format)
      && ['0','1080','1350','2048','4096','custom'].includes(s.size) && digits(s.edge,64,100000) && digits(s.quality,5,100)
      && s.color==='srgb' && templateOK(s.template) && ['rename','skip'].includes(s.collision)
      && ['rights','photo','none'].includes(s.metadata) && typeof s.gps==='boolean'
      && keysMatch(l,Object.keys(ExportLayout.style())) && ExportLayout.valid(l) && !ExportLayout.problem(l)
      && (l.logo===null || keysMatch(l.logo,['mime','sha256','base64']));
  }
  function envelope(name,settings) {
    if (typeof name!=='string' || !name.trim() || name.trim().length>70 || /[\x00-\x1f]/.test(name))
      throw new Error('请填写 1 至 70 个字符的预设名称。');
    if (!settingsOK(settings)) throw new Error('预设中有不支持的设置，请检查格式、尺寸、命名或版式。');
    return {kind,schemaVersion:2,name:name.trim(),settings:canonical(settings)};
  }
  function upgradeLocal(settings) {
    const migrated={...builtin('web'),...settings};
    if (settings.layout && !Object.hasOwn(settings.layout,'builtin')) {
      const l=settings.layout;
      const id=l.frame==='solid'?'paper':l.frame==='blur'?'mist':l.mark==='signature'?'sign':'plain';
      migrated.layout={builtin:id,...l};
    }
    return migrated;
  }
  function loadImage(url) {
    return new Promise((resolve,reject)=>{
      const img=new Image();
      img.onload=()=>resolve(img); img.onerror=()=>reject(new Error('无法解码 Logo 图像。'));
      img.src=url;
    });
  }
  const hex = buffer => Array.from(new Uint8Array(buffer),b=>b.toString(16).padStart(2,'0')).join('');
  async function makeLogo(file) {
    if (!['image/png','image/jpeg'].includes(file.type) || file.size>12*1024*1024)
      throw new Error('请选择 12 MiB 以内的 PNG 或 JPEG。');
    const url=URL.createObjectURL(file);
    try {
      const img=await loadImage(url);
      const scale=Math.min(1,512/Math.max(img.naturalWidth,img.naturalHeight));
      const canvas=document.createElement('canvas');
      canvas.width=Math.max(1,Math.round(img.naturalWidth*scale));
      canvas.height=Math.max(1,Math.round(img.naturalHeight*scale));
      canvas.getContext('2d').drawImage(img,0,0,canvas.width,canvas.height);
      const base64=canvas.toDataURL('image/png').split(',')[1];
      const bytes=Uint8Array.from(atob(base64),c=>c.charCodeAt(0));
      return {mime:'image/png',sha256:hex(await crypto.subtle.digest('SHA-256',bytes)),base64};
    } finally { URL.revokeObjectURL(url); }
  }
  function logoURL(logo) { return 'data:image/png;base64,'+logo.base64; }
  async function checkLogo(logo) {
    let bytes;
    try { bytes=Uint8Array.from(atob(logo.base64),c=>c.charCodeAt(0)); } catch { throw new Error('Logo 的编码无法读取。'); }
    const header=[137,80,78,71,13,10,26,10];
    if (bytes.length<33 || !header.every((v,i)=>bytes[i]===v)) throw new Error('内嵌 Logo 不是 PNG。');
    const info=new DataView(bytes.buffer);
    const width=info.getUint32(16), height=info.getUint32(20);
    if (!width || !height || width>512 || height>512) throw new Error('内嵌 Logo 的长边超过 512 px 或尺寸无效。');
    if (hex(await crypto.subtle.digest('SHA-256',bytes))!==logo.sha256) throw new Error('Logo 校验失败，请重新取得预设文件。');
    const image=await loadImage(logoURL(logo));
    if (image.naturalWidth!==width || image.naturalHeight!==height) throw new Error('Logo 的实际尺寸不一致。');
  }
  async function read(file) {
    if (!file || file.size>maxFile) throw new Error('请选择 2 MiB 以内的导出预设。');
    let data;
    try { data=JSON.parse(await file.text()); } catch { throw new Error('文件不是可读取的 JSON 导出预设。'); }
    if (data?.kind!==kind) throw new Error('请选择 RAWMaster 导出预设（.rmexport.json）。');
    if (![1,2].includes(data.schemaVersion)) throw new Error('此预设的版本暂不支持。');
    if (!keysMatch(data,['kind','schemaVersion','name','settings'])) throw new Error('导出预设含未识别的字段。');
    let settings=data.settings;
    if (data.schemaVersion===1) {
      const oldSettings=Object.keys(defaults).filter(k=>!['mode','copyMode','originalFormat'].includes(k)).concat('layout');
      if (!keysMatch(settings,oldSettings) || !keysMatch(settings.layout,Object.keys(ExportLayout.style()).filter(k=>k!=='builtin')))
        throw new Error('旧版导出预设字段不完整或含未识别的内容。');
      settings=upgradeLocal(settings);
    }
    const result=envelope(data.name,settings);
    if (data.settings.layout.logo) await checkLogo(data.settings.layout.logo);
    return result;
  }
  function download(payload) {
    const blob=new Blob([JSON.stringify(payload,null,2)+'\n'],{type:'application/json'});
    const a=document.createElement('a');
    a.href=URL.createObjectURL(blob);
    a.download=(payload.name.replace(/[/\\:*?"<>|]/g,'-').replace(/^\.+/,'').trim() || 'RAWMaster')+'.rmexport.json';
    document.body.append(a); a.click(); a.remove();
    setTimeout(()=>URL.revokeObjectURL(a.href),5000);
  }
  return {builtin,canonical,upgradeLocal,templateOK,envelope,read,download,makeLogo,loadImage,logoURL};
})();
