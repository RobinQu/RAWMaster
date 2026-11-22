// All coordinates in the plan are final output pixels, including the mat and the caption.
const ExportLayout = (() => {
  const exifNames = {camera:'相机', lens:'镜头', focal:'焦距', aperture:'光圈', shutter:'快门', iso:'ISO', date:'拍摄日期'};
  const ratios = {source:null, '1:1':1, '4:5':4/5, '3:2':3/2, '16:9':16/9};
  const styleNames = {plain:'净图', paper:'相纸展签', split:'双栏参数卡', mist:'模糊留白', sign:'画内署名', date:'日期戳'};
  function style(id = 'plain') {
    const base = {
      builtin:id, frame:'none', ratio:'source', fit:'contain', paper:'#f6f1e7', margin:5,
      stroke:0, strokeColor:'#575653', shadow:false, mark:'off', place:'photo', anchor:'br',
      signature:'© 河谷影集', fields:['camera','focal','aperture','shutter','iso'],
      font:'sans', ink:'#ffffff', opacity:95, scale:100, logo:null
    };
    switch (id) {
      case 'paper': return {...base,frame:'solid',ratio:'3:2',stroke:1,mark:'both',place:'footer',anchor:'bc',font:'serif',ink:'#282823'};
      case 'mist': return {...base,frame:'blur',ratio:'4:5',shadow:true,mark:'exif',place:'footer',anchor:'bc'};
      case 'sign': return {...base,mark:'signature',font:'serif',opacity:78};
      case 'split': return {...base,frame:'solid',paper:'#ffffff',margin:0,mark:'both',place:'footer',anchor:'bl',
        ink:'#242424',fields:['camera','lens','focal','aperture','shutter','iso','date']};
      case 'date': return {...base,mark:'exif',fields:['date'],ink:'#f4a75d',font:'mono',opacity:90,scale:120};
      default: return base;
    }
  }
  const enumFields = {
    builtin:Object.keys(styleNames), frame:['none','solid','blur'], ratio:Object.keys(ratios), fit:['contain','cover'],
    mark:['off','signature','exif','both','logo'], place:['photo','footer'],
    anchor:['tl','tc','tr','cl','cc','cr','bl','bc','br'], font:['sans','serif','mono']
  };
  function valid(layout) {
    if (!layout || typeof layout !== 'object') return false;
    for (const [field,values] of Object.entries(enumFields))
      if (!values.includes(layout[field])) return false;
    const between = (v,min,max) => Number.isInteger(v) && v >= min && v <= max;
    return between(layout.margin,0,16) && between(layout.stroke,0,5) && between(layout.opacity,0,100)
      && between(layout.scale,60,160) && [layout.ink,layout.paper,layout.strokeColor].every(v=>typeof v === 'string' && /^#[a-f0-9]{6}$/i.test(v))
      && typeof layout.shadow === 'boolean' && typeof layout.signature === 'string' && layout.signature.length <= 100
      && Array.isArray(layout.fields) && layout.fields.every(k=>Object.hasOwn(exifNames,k))
      && new Set(layout.fields).size === layout.fields.length
      && (layout.frame !== 'none' || layout.place === 'photo')
      && (layout.place !== 'footer' || layout.anchor[0] === 'b')
      && (layout.logo === null || (typeof layout.logo === 'object' && layout.logo.mime === 'image/png'
        && typeof layout.logo.sha256 === 'string' && /^[a-f0-9]{64}$/.test(layout.logo.sha256)
        && typeof layout.logo.base64 === 'string' && layout.logo.base64.length > 0 && layout.logo.base64.length <= 1500000));
  }
  function problem(layout) {
    if (layout.mark === 'logo' && !layout.logo) return '请选择要绘制的 Logo。';
    if (['signature','both'].includes(layout.mark) && !layout.signature.trim()) return '请填写画面上的署名。';
    if (['exif','both'].includes(layout.mark) && !layout.fields.length) return '请选择至少一项 EXIF 字段。';
    return '';
  }
  function plan(version, maxEdge, layout) {
    const {w,h} = version;
    const framed = layout.frame !== 'none';
    const ratio = (framed && ratios[layout.ratio]) || w / h;
    const budget = Math.max(1,Math.min(maxEdge || Math.max(w,h),Math.max(w,h)));
    function measure(edge) {
      const width = Math.max(1,Math.round(edge*Math.min(1,ratio)));
      const height = Math.max(1,Math.round(edge/Math.max(1,ratio)));
      const wholeSource={x:0,y:0,w,h};
      if (!framed) return {width,height,photo:{x:0,y:0,w:width,h:height},caption:{x:0,y:height,w:width,h:0},
        sourceCrop:wholeSource,zoom:edge/Math.max(w,h),cover:false};
      const short = Math.min(width,height);
      const pad = framed ? Math.min(Math.floor((short-1)/2),Math.round(short*layout.margin/100)) : 0;
      const footer = framed && layout.mark !== 'off' && layout.place === 'footer'
        ? Math.min(height-2*pad-1,Math.round(short*(layout.builtin==='split'?0.15:0.12)*layout.scale/100)) : 0;
      const area = {x:pad,y:pad,w:width-2*pad,h:height-2*pad-footer};
      const cover = framed && layout.fit === 'cover';
      const zoom = cover ? Math.max(area.w/w,area.h/h) : Math.min(area.w/w,area.h/h);
      const pw = cover ? area.w : Math.max(1,Math.round(w*zoom));
      const ph = cover ? area.h : Math.max(1,Math.round(h*zoom));
      const photo = {x:area.x+Math.floor((area.w-pw)/2),y:area.y+Math.floor((area.h-ph)/2),w:pw,h:ph};
      const caption = {x:pad,y:height-pad-footer,w:width-2*pad,h:footer};
      const cropW=Math.min(w,area.w/zoom), cropH=Math.min(h,area.h/zoom);
      const sourceCrop=cover ? {x:(w-cropW)/2,y:(h-cropH)/2,w:cropW,h:cropH} : wholeSource;
      return {width,height,photo,caption,sourceCrop,zoom,cover};
    }
    const proposed = measure(budget);
    if (!proposed.cover || proposed.zoom <= 1) return proposed;
    // A panorama filling a portrait frame can hit the short source edge first.
    let low=1, high=budget;
    while (low < high) {
      const mid = Math.ceil((low+high)/2);
      if (measure(mid).zoom <= 1) low=mid;
      else high=mid-1;
    }
    return measure(low);
  }
  function lettering(layout,photo) {
    const exif = ['exif','both'].includes(layout.mark);
    const values = photo.exif || {};
    return {
      signature:['signature','both'].includes(layout.mark) ? layout.signature.trim() : '',
      values:exif ? layout.fields.map(k=>values[k]).filter(Boolean) : [],
      byField:exif ? Object.fromEntries(layout.fields.filter(k=>values[k]).map(k=>[k,values[k]])) : {},
      missing:exif ? layout.fields.filter(k=>!values[k]).map(k=>exifNames[k]) : []
    };
  }
  function drawPhoto(ctx,image,rect,version,sourceCrop) {
    // The test thumbnails stand in for oriented/cropped version pixels.
    // First fit the sample to the version's crop, then fit that crop to the frame.
    function crop(w,h,r) {
      const cw=Math.min(w,h*r), ch=Math.min(h,w/r);
      return {x:(w-cw)/2,y:(h-ch)/2,w:cw,h:ch};
    }
    const first=crop(image.naturalWidth,image.naturalHeight,version.w/version.h);
    const scale=first.w/version.w;
    const second=sourceCrop ? {x:sourceCrop.x*scale,y:sourceCrop.y*scale,w:sourceCrop.w*scale,h:sourceCrop.h*scale}
      : crop(first.w,first.h,rect.w/rect.h);
    ctx.drawImage(image,first.x+second.x,first.y+second.y,second.w,second.h,rect.x,rect.y,rect.w,rect.h);
  }
  function mark(ctx,layout,geometry,lines,logoImage) {
    if (layout.mark === 'off') return;
    const footer = layout.place === 'footer' && geometry.caption.h > 0;
    if (layout.builtin==='split' && footer && ['exif','both'].includes(layout.mark)) {
      const area=geometry.caption, fields=lines.byField || {}, pad=Math.max(1,Math.min(area.w*.045,area.h*.29));
      const size=Math.min(area.h*.25,area.w*.037)*layout.scale/100;
      const family={sans:'system-ui, sans-serif',serif:'Georgia, serif',mono:'Menlo, monospace'}[layout.font];
      const split=area.x+area.w*.49;
      const group1=[fields.camera || lines.signature, [fields.lens,fields.camera ? lines.signature : ''].filter(Boolean).join(' · ')];
      const group2=[['focal','aperture','shutter','iso'].map(k=>fields[k]).filter(Boolean).join('  '),fields.date];
      ctx.save(); ctx.beginPath(); ctx.rect(area.x,area.y,area.w,area.h); ctx.clip();
      ctx.globalAlpha=layout.opacity/100; ctx.fillStyle=layout.ink; ctx.textBaseline='middle';
      function drawColumn(rows,x,width,align) {
        const present=rows.filter(Boolean);
        present.forEach((value,index)=>{
          const fontSize=size*(index===0?1:.76);
          ctx.font=(index===0?'600 ':'400 ')+fontSize+'px '+family; ctx.textAlign=align;
          const y=area.y+area.h*(present.length===1?.50:index===0?.36:.69);
          ctx.fillText(value,x,y,Math.max(1,width));
        });
      }
      const logoH=logoImage && layout.logo ? Math.min(size*1.65,area.h*.55,area.w*.13*logoImage.naturalHeight/logoImage.naturalWidth) : 0;
      const logoW=logoH ? logoH*logoImage.naturalWidth/logoImage.naturalHeight : 0;
      if (logoH) ctx.drawImage(logoImage,area.x+pad,area.y+(area.h-logoH)/2,logoW,logoH);
      const left=area.x+pad+(logoW?logoW+pad*.45:0);
      drawColumn(group1,left,split-pad-left,'left');
      drawColumn(group2,area.x+area.w-pad,area.x+area.w-split-2*pad,'right');
      if (group1.some(Boolean) && group2.some(Boolean)) {
        ctx.globalAlpha*=.38; ctx.fillRect(split,area.y+area.h*.25,Math.max(1,area.w/1500),area.h*.5);
      }
      ctx.restore(); return;
    }
    const area = footer ? geometry.caption : geometry.photo;
    const short = Math.min(geometry.width,geometry.height);
    const inset = Math.min(area.w*0.08,area.h*0.12,short*(footer?0.012:0.028));
    const usableWidth=Math.max(1,area.w-2*inset);
    const unit=Math.min(short*0.032*layout.scale/100,area.h*(footer?0.31:0.16));
    const logo = layout.logo && logoImage && logoImage.naturalWidth>0;
    const logoHeight = logo ? Math.min(unit*1.9,area.h-2*inset,usableWidth*.25*logoImage.naturalHeight/logoImage.naturalWidth) : 0;
    const logoWidth = logo ? logoHeight*logoImage.naturalWidth/logoImage.naturalHeight : 0;
    const family = {sans:'system-ui, sans-serif',serif:'Georgia, "Songti SC", serif',mono:'Menlo, monospace'}[layout.font];
    const gap=logo && (lines.signature || lines.values.length) ? unit*.48 : 0;
    const available=Math.max(1,usableWidth-logoWidth-gap);
    const textRows=[];
    function add(text,size,weight) {
      ctx.font=weight+' '+size+'px '+family;
      const width=ctx.measureText(text).width;
      textRows.push({text,size:size*Math.min(1,available/Math.max(1,width)),weight});
    }
    if (lines.signature) add(lines.signature,unit,'600');
    if (lines.values.length) {
      const fontSize = unit*(lines.signature ? .60 : .79);
      ctx.font='400 '+fontSize+'px '+family;
      let text='';
      for (const value of lines.values) {
        const candidate=text ? text+'  ·  '+value : value;
        if (text && ctx.measureText(candidate).width>available) { add(text,fontSize,'400'); text=value; ctx.font='400 '+fontSize+'px '+family; }
        else text=candidate;
      }
      if (text) add(text,fontSize,'400');
    }
    let textHeight=textRows.reduce((sum,row)=>sum+row.size*1.35,0);
    const fit=Math.min(1,Math.max(1,area.h-2*inset)/Math.max(1,textHeight));
    textRows.forEach(row=>row.size*=fit);
    textHeight*=fit;
    let textWidth=0;
    for (const row of textRows) {
      ctx.font=row.weight+' '+row.size+'px '+family;
      textWidth=Math.max(textWidth,ctx.measureText(row.text).width);
    }
    const groupW=logoWidth+gap+textWidth, groupH=Math.max(logoHeight,textHeight);
    const h=layout.anchor[1], v=footer ? 'c' : layout.anchor[0];
    const x=h==='l'?area.x+inset:h==='r'?area.x+area.w-inset-groupW:area.x+(area.w-groupW)/2;
    const y=v==='t'?area.y+inset:v==='b'?area.y+area.h-inset-groupH:area.y+(area.h-groupH)/2;
    ctx.save();
    ctx.beginPath(); ctx.rect(area.x,area.y,area.w,area.h); ctx.clip();
    ctx.globalAlpha=layout.opacity/100;
    if (logo) ctx.drawImage(logoImage,x,y+(groupH-logoHeight)/2,logoWidth,logoHeight);
    ctx.textBaseline='middle'; ctx.fillStyle=layout.ink;
    let rowY=y+(groupH-textHeight)/2;
    for (const row of textRows) {
      const lineH=row.size*1.35;
      ctx.font=row.weight+' '+row.size+'px '+family;
      const rowWidth=ctx.measureText(row.text).width;
      const rowOffset=h==='r'?textWidth-rowWidth:h==='c'?(textWidth-rowWidth)/2:0;
      ctx.fillText(row.text,x+logoWidth+gap+rowOffset,rowY+lineH/2);
      rowY+=lineH;
    }
    ctx.restore();
  }
  function draw(canvas,image,version,layout,geo,lines,logoImage) {
    const ctx=canvas.getContext('2d');
    const {width,height,photo}=geo;
    ctx.save();
    ctx.setTransform(canvas.width/width,0,0,canvas.height/height,0,0);
    ctx.clearRect(0,0,width,height);
    ctx.imageSmoothingQuality='high';
    if (layout.frame !== 'none') {
      ctx.fillStyle=layout.paper; ctx.fillRect(0,0,width,height);
      if (layout.frame==='blur') {
        const bleed=Math.min(width,height)*.09;
        ctx.save(); ctx.filter='blur('+Math.max(1,bleed*canvas.width/width*.3)+'px)';
        drawPhoto(ctx,image,{x:-bleed,y:-bleed,w:width+2*bleed,h:height+2*bleed},version);
        ctx.restore(); ctx.fillStyle='rgba(0,0,0,.38)'; ctx.fillRect(0,0,width,height);
      }
    }
    ctx.save();
    if (layout.frame!=='none' && layout.shadow) {
      ctx.shadowColor='rgba(0,0,0,.35)'; ctx.shadowBlur=canvas.width*.014; ctx.shadowOffsetY=canvas.height*.006;
    }
    drawPhoto(ctx,image,photo,version,geo.sourceCrop); ctx.restore();
    if (layout.frame!=='none' && layout.stroke) {
      const line=Math.min(Math.min(width,height)*layout.stroke/1000,photo.w/2,photo.h/2);
      ctx.lineWidth=line; ctx.strokeStyle=layout.strokeColor;
      ctx.strokeRect(photo.x+line/2,photo.y+line/2,photo.w-line,photo.h-line);
    }
    mark(ctx,layout,geo,lines,logoImage);
    ctx.restore();
  }
  return {exifNames,styleNames,style,valid,problem,plan,lettering,draw};
})();
