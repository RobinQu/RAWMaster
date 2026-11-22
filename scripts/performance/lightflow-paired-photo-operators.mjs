// Build stock PhotoEdit and FrameInputs from the same operator manifest as the native capture.
export function photoOperatorRecipes(engine, neutral, manifest, defaults, localMask) {
  const ids = {warm:'lut-a01', mono:'lut-b02'};
  const tables = {};
  for (const [name, text] of Object.entries(manifest.luts)) {
    const rows = text.trim().split('\n');
    const rgb = rows.filter(line => /^[0-9.+-]/.test(line)).flatMap(line => line.split(/\s+/).map(Number));
    if (!rows.includes('LUT_3D_SIZE 2') || !rows.includes('DOMAIN_MIN 0 0 0') ||
        !rows.includes('DOMAIN_MAX 1 1 1') || rgb.length !== 24 || rgb.some(x => !Number.isFinite(x))) {
      throw Error('Invalid reference CUBE '+name);
    }
    tables[ids[name]] = {size:2,dim:'3d',data:rgb.map(Math.fround),domainMin:[0,0,0],domainMax:[1,1,1]};
  }
  engine.setLuts(JSON.stringify(tables));
  const clone = value => JSON.parse(JSON.stringify(value));
  function build(id,state) {
    const spec=manifest.controls[id], value=spec.values[state], f=spec.fixed;
    const edit=clone(neutral), node=edit.grade.nodes[0], view={};
    if (spec.region === 'radial') {
      const m=manifest.radial;
      node.mask=localMask();
      Object.assign(node.mask.components[0],{center:{x:m.center[0],y:m.center[1]},rx:m.radius[0],ry:m.radius[1],
        angle:0, inside:true, feather:m.feather*100, opacity:m.opacity, invert:m.inverted});
    }
    const tool=(name,fields) => {node.tools[name]={...clone(defaults[name]),...fields};return node.tools[name];};
    if (id.startsWith('grading-lut-')) {
      let names = id==='grading-lut-select' ? [value] : f.cube ? [f.cube] : value.split(',');
      edit.grade.nodes=names.map((name,i)=>{
        const n=clone(node);
        n.id='paired-'+i; n.number=i+1; n.x=i+1;
        const strength=f.amounts ? f.amounts[i] : f.amount ?? value;
        n.tools.effects={...clone(defaults.effects),lut:{asset:ids[name],name,strength,inputSpace:'srgb',outputSpace:'srgb'}};
        return n;
      });
      edit.grade.edges=edit.grade.nodes.map((n,i)=>({from:i ? edit.grade.nodes[i-1].id:'@input',to:n.id,index:0}));
      edit.grade.edges.push({from:edit.grade.nodes.at(-1).id,to:'@output',index:0});
    } else if (id.includes('-mask-') && id!=='detail-mask-preview') {
      const name = id.split('-').at(-1);
      if (id.startsWith('light-') || id.startsWith('color-')&&name!=='hue' || ['texture','clarity'].includes(name)) {
        tool('basic',{[name==='temp'?'temperature':name]:value});
      } else if (name==='hue') {
        tool('wheels',{hue:50+50*value});
      } else if (name==='grain') {
        tool('effects',{grainAmount:value,grainSize:f.size,grainRoughness:f.roughness});
      } else if (name==='curve') {
        tool('curves',{[f.channel]:[[0,0],[f.input,value],[1,1]]});
      } else if (name==='wheels') {
        tool('wheels',{lrMidtones:{hue:f.hue,sat:value,lum:0},lrBlending:f.blending,lrBalance:f.balance});
      } else if (name==='sharpness'||name==='noise') {
        tool('detail',{[name==='sharpness'?'sharpenAmount':'noiseLuminance']:value});
      } else throw Error('Unknown local operation '+id);
    } else if (id.startsWith('color-wb-')) {
      const [temperature,tint]=value==='as-shot' ? [Math.round(neutral.base.temperature),Math.round(neutral.base.tint)] : f[value];
      Object.assign(edit.base,{temperature,tint,wbMode:value});
    } else if (id==='color-bw-treatment') {
      edit.base.profile=value==='color'?'standard':'monochrome';
    } else if (id==='effects-pcv-style') {
      tool('effects',{vignetteAmount:f.amount,vignetteMidpoint:f.midpoint,vignetteRoundness:f.roundness,
        vignetteFeather:f.feather,vignetteHighlights:f.highlights,vignetteStyle:value});
    } else if (id==='effects-dehaze') {
      tool('basic',{dehaze:value});
    } else if (id.startsWith('curve-')) {
      tool('curves',{[f.channel]:[[0,0],[f.input,value],[1,1]]});
    } else if (id.startsWith('grading-')) {
      tool('wheels',{lrShadows:{hue:f.shadowsHue,sat:f.shadowsSaturation,lum:id==='grading-luminance'?value:0},
        lrHighlights:{hue:f.highlightsHue,sat:f.highlightsSaturation,lum:0},
        lrBlending:id==='grading-blending'?value:f.blending,lrBalance:id==='grading-balance'?value:f.balance});
    } else if (id==='detail-nr-lum-contrast') {
      tool('detail',{noiseLuminance:f.luminanceNoise,noiseColor:f.colorNoise,noiseLumDetail:f.luminanceDetail,noiseLumContrast:value});
    } else if (id==='detail-nr-color-detail') {
      tool('detail',{noiseLuminance:f.luminanceNoise,noiseColor:f.colorNoise,noiseColorSmoothness:f.colorSmoothness,noiseColorDetail:value});
    } else if (id==='detail-mask-preview') {
      tool('detail',{sharpenAmount:f.sharpenAmount,sharpenRadius:f.sharpenRadius,sharpenDetail:f.sharpenDetail,sharpenMasking:f.masking});
      view.alt=value?{node:node.id,view:'mask'}:null;
      view.keepNode=node.id;
    } else if (id.startsWith('light-clipping-')) {
      edit.base.exposure=f.exposure;
      if (id==='light-clipping-indicators') view.clipping=value;
      else view.alt=value?{node:'',view:'clip-high'}:null;
    } else throw Error('Unknown paired operator '+id);
    return {edit,view};
  }
  return Object.assign(build,{registeredLUTs:tables});
}
