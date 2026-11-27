"use strict";

const PhotographicScopes = (() => {
  const hdrBands = SceneEditor.bands.map(([label],i)=>['hdr'+i,label,-.5,.5,.05]);
  const regions = () => SceneEditor.hdr() ? [...toneBands,...hdrBands] : toneBands;
  function value(key) {
    const r=currentEdit().recipe;
    return key.startsWith('hdr') ? RMSceneOutput.clean(r.sceneOutput)?.bandEV[Number(key.slice(3))] ?? 0 : photoParameters(r)[key] ?? 0;
  }
  function write(key, next) {
    const field=regions().find(([k])=>k===key);
    if (!field || !Number.isFinite(next) || next===value(key)) return false;
    const label='直方图 · '+field[1], r=currentEdit().recipe;
    if (key.startsWith('hdr')) {
      const scene=RMSceneOutput.clean(r.sceneOutput);
      if (!scene) return false;
      scene.bandEV[Number(key.slice(3))]=next;
      const updated={...r,sceneOutput:scene};
      if (r.dag) {updated.dag=structuredClone(r.dag);updated.dag.base.sceneOutput=scene;}
      Studio.setRecipe(Studio.data.work,label,updated);
    } else setPhotoParameters(label,{[key]:next});
    render(); return true;
  }
  function chart(docked) {
    const hdr=SceneEditor.hdr(), fig=hdr ? SceneEditor.rgbPlot() : histogram(Studio.data.work);
    if (!docked || !fig) return fig;
    const why=hdr ? SceneEditor.unavailable() : '';
    const white=hdr ? 56.25 : 100;
    const cells=regions().map(([key,label,min,max],i)=>`<div tabindex="${why ? -1 : 0}" role="slider" class="hist-band"${why ? ' aria-disabled="true" title="'+h(why)+'"' : ''} data-band="${key}"
      aria-label="${h((i>=5?'HDR ':'')+label)}" aria-valuemin="${min}" aria-valuemax="${max}" aria-valuenow="${value(key)}"
      aria-describedby="histogram-instructions" style="width:${i<5 ? white/5 : (100-white)/4}%"></div>`).join('');
    return `<div class="tone-control" data-histogram="${hdr?'hdr':'sdr'}">${fig}
      <div class="hist-bands" role="group" aria-label="可调亮度区段">${cells}</div>
      <div class="hist-caption"><span>${hdr?'SDR · 100 nits':'SDR'}</span><output></output><span>${hdr?'HDR · +1　+2　+3 EV':'RGB'}</span></div>
      <span class="visually-hidden" id="histogram-instructions">拖动或用左右方向键调整本区，Home 复位。</span></div>`;
  }
  const round=(v,min,max,step)=>Number(Math.min(max,Math.max(min,Math.round(v/step)*step)).toFixed(2));
  function feedback(el,n) {
    const [,name]=regions().find(([k])=>k===el.dataset.band);
    el.closest('.tone-control').querySelector('output').textContent=name+' '+(n>0?'+':'')+n;
    el.setAttribute('aria-valuetext',name+' '+n);
  }
  for(const type of ['focusin','pointerover']) document.addEventListener(type,e=>{
    const el=e.target.closest('.hist-band');if(el)feedback(el,value(el.dataset.band));
  });
  document.addEventListener('keydown',e=>{
    const el=e.target.closest('.hist-band');
    if(!el || el.ariaDisabled==='true' || !['ArrowLeft','ArrowRight','ArrowUp','ArrowDown','Home'].includes(e.key)) return;
    e.preventDefault(); e.stopPropagation();
    const key=el.dataset.band,[,,min,max,step]=regions().find(([k])=>k===key);
    const n=e.key==='Home'?0:round(value(key)+(['ArrowLeft','ArrowDown'].includes(e.key)?-1:1)*step*(e.shiftKey?5:1),min,max,step);
    if(write(key,n)) $('.hist-band[data-band="'+key+'"]')?.focus({preventScroll:true});
  });
  document.addEventListener('pointerdown',e=>{
    const el=e.target.closest('.hist-band');
    if(!el || el.ariaDisabled==='true' || e.button!==0 || !e.isPrimary) return;
    e.preventDefault(); el.focus({preventScroll:true});
    const key=el.dataset.band,[,,min,max,step]=regions().find(([k])=>k===key),start=e.clientX,initial=value(key);
    const width=Math.max(72,el.closest('.hist-bands').clientWidth), photo=Studio.data.work;
    let next=initial; el.setPointerCapture(e.pointerId);
    function move(event) {
      next=round(initial+(event.clientX-start)*(max-min)/width,min,max,step);feedback(el,next);
      if(key.startsWith('hdr')) drawImagePreview(Number(key.slice(3)),next);
      else paintEditPreview({...currentEdit().recipe,[key]:next});
    }
    function end(event) {
      el.removeEventListener('pointermove',move); el.removeEventListener('pointerup',end);el.removeEventListener('pointercancel',end);el.removeEventListener('lostpointercapture',end);
      if(!el.isConnected || Studio.data.work!==photo)return;
      if(event.type==='pointerup' && write(key,next))$('.hist-band[data-band="'+key+'"]')?.focus({preventScroll:true});
      else {feedback(el,initial);drawImagePreview();paintEditPreview(currentEdit().recipe);}
    }
    el.addEventListener('pointermove',move);el.addEventListener('pointerup',end);el.addEventListener('pointercancel',end);el.addEventListener('lostpointercapture',end);
  });
  const bandColors = [[56,120,204], [82,174,119], [223,170,66], [216,93,86]];
  function filterForPreview(recipe, scene, adjustments, visualize) {
    if (!scene) {
      // In this JPEG preview each hue control weights lightness before monochrome output.
      const coefficients = [.2126,.7152,.0722].map((base,channel) =>
        bwBands.reduce((sum,[key,,hue]) =>
          sum + (recipe[key] ?? 0) / 100 * .30 * Math.cos((hue-channel*120)*Math.PI/180),base));
      const row = [...coefficients,0,0].join(' ');
      return `<feColorMatrix type="matrix" values="${row} ${row} ${row} 0 0 0 1 0"/>`;
    }
    const table = [[],[],[]];
    for (let sample=0; sample<256; sample++) {
      // A JPEG has no super-white samples. The prototype maps its highlights to example stops.
      const ev = Math.min(scene.limitEV,(sample-152)/27 + (recipe.ev ?? 0));
      const band = Math.min(3,Math.floor(ev));
      const fraction = ev-Math.floor(ev);
      const feather = Math.min(1,fraction/.16,(1-fraction)/.16);
      const delta = ev>0 ? adjustments[band]*feather : 0;
      const output = Math.min(scene.limitEV,ev+delta);
      const ink = output>0 ? bandColors[Math.min(3,Math.floor(output))] : [sample,sample,sample];
      const shade = output>0 ? .84+.16*(output-Math.floor(output)) : 1;
      for (let channel=0;channel<3;channel++) {
        table[channel].push((visualize ? ink[channel]*shade/255 : 2**delta/2).toFixed(4));
      }
    }
    const transfer = ['R','G','B'].map((channel,i) =>
      `<feFunc${channel} type="table" tableValues="${table[i].join(' ')}"/>`).join('');
    return '<feColorMatrix type="saturate" values="0"/><feComponentTransfer result="bandMap">'+transfer+'</feComponentTransfer>' +
      (visualize ? '' : '<feComposite in="SourceGraphic" in2="bandMap" operator="arithmetic" k1="2"/>');
  }
  function drawImagePreview(dragBand=-1,dragValue=0) {
    const canvas = $('.hdr-range-preview,.bw-range-preview');
    const image = $('.canvas-layer .developed');
    if (!canvas || !image) return;
    if (!image.complete || !image.naturalWidth) {
      image.addEventListener('load', () => { if (canvas.isConnected) drawImagePreview(); }, {once:true});
      return;
    }
    const scene = SceneEditor.config(), recipe=currentEdit().recipe;
    const visualize = canvas.dataset.visualize==='true';
    const adjustments = scene ? scene.bandEV.slice() : bwBands.map(([key])=>recipe[key] ?? 0);
    if (dragBand>=0) adjustments[dragBand]=dragValue;
    canvas.hidden = !visualize && !adjustments.some(amount=>amount!==0);
    if (canvas.hidden) return;

    let filter = $('#photographic-preview-filter');
    if (!filter) {
      canvas.insertAdjacentHTML('afterend','<svg width="0" height="0" aria-hidden="true" style="position:absolute"><defs><filter id="photographic-preview-filter" color-interpolation-filters="sRGB"></filter></defs></svg>');
      filter = $('#photographic-preview-filter');
    }
    filter.innerHTML=filterForPreview(recipe,scene,adjustments,visualize);
    canvas.width=Math.min(700,image.naturalWidth);
    canvas.height=Math.max(1,Math.round(canvas.width*image.naturalHeight/image.naturalWidth));
    const ctx=canvas.getContext('2d');
    const base=visualize ? '' : RMPhotos.filter({...RMPhotos.displayLook(SceneEditor.preview(recipe)),mono:false})+' ';
    // Drawing the fixture with a display filter also works when the HTML is opened from Finder.
    ctx.filter=base+'url(#photographic-preview-filter)';
    ctx.drawImage(image,0,0,canvas.width,canvas.height);
  }
  return {chart,drawImagePreview};
})();
