// Runs against the published LightFlow PixelEngine JS/WASM pair served by benchmark-lightflow.py.
import init, {PixelEngine} from './lightflow_host_wasm.js';

async function report(payload) {
  await fetch('result', {method: 'POST', body: JSON.stringify(payload)});
}

function initialEdit(asShot) {
  return {
    version: 1,
    source: {demosaic: 'auto', highlightReconstruction: true, lensCorrections: true, assumeColorSpace: null},
    retouch: [],
    base: {profile: 'standard', profileAmount: 100, wbMode: 'as-shot', temperature: asShot.temperature, tint: asShot.tint,
      exposure: 0, contrast: 0, highlights: 0, shadows: 0, whites: 0, blacks: 0, vibrance: 0, saturation: 0},
    grade: {nodes: [{id: 'bench', kind: 'corrector', enabled: true, number: 1, label: '', color: null,
      x: 1, y: 0, tools: {}, mask: null, opacity: 1}], edges: [{from: '@input', to: 'bench', index: 0}, {from: 'bench', to: '@output', index: 0}]},
    geometry: {crop: {x: 0, y: 0, w: 1, h: 1}, angle: 0, quarterTurns: 0, flipH: false, flipV: false, aspect: null},
  };
}

function localMask() {
  return {invert: false, refine: {feather: 0, expand: 0, smooth: 0, edgeRefine: 0, hairRefine: false, denoise: 0},
    components: [{id: 'fixed-radial', type: 'radial', op: 'add', enabled: true, opacity: 1, invert: false,
      center: {x: .5, y: .5}, rx: .35, ry: .3, angle: 0, feather: 50, inside: true}]};
}

// LightFlow requires a complete tool object when the corresponding corrector is active.
const zeroes = keys => Object.fromEntries(keys.split(' ').map(k => [k,0]));
const eightColors = zeroes('red orange yellow green aqua blue purple magenta');
const linearCurve = [[0,0],[1,1]], midline = [[0,.5],[1,.5]];
const toolDefaults = {
  basic: zeroes('temperature tint exposure contrast highlights shadows whites blacks texture clarity dehaze vibrance saturation'),
  effects: {vignetteAmount:0, vignetteMidpoint:50, vignetteRoundness:0, vignetteFeather:50, vignetteHighlights:0,
    vignetteStyle:'highlight-priority', grainAmount:0, grainSize:25, grainRoughness:50, bloom:0, bloomThreshold:2, halation:0, lut:null},
  detail: {sharpenAmount:0, sharpenRadius:1, sharpenDetail:25, sharpenMasking:0, noiseLuminance:0, noiseLumDetail:50,
    noiseLumContrast:0, noiseColor:0, noiseColorDetail:50, noiseColorSmoothness:50, blur:0},
  mixer: {hue:eightColors, saturation:eightColors, luminance:eightColors, rgb:[1,0,0,0,1,0,0,0,1], preserveLuminance:true, monochrome:false},
  curves: {master:linearCurve, red:linearCurve, green:linearCurve, blue:linearCurve, lumMix:100,
    parametric:{shadows:0,darks:0,lights:0,highlights:0,split1:.25,split2:.5,split3:.75}, hueVsHue:[],hueVsSat:[],hueVsLum:[],
    lumVsSat:midline, satVsSat:midline, satVsLum:midline},
  wheels: {...Object.fromEntries('lift gamma gain offset logShadow logMidtone logHighlight'.split(' ').map(k => [k,{x:0,y:0,master:0}])),
    ...Object.fromEntries('lrShadows lrMidtones lrHighlights lrGlobal'.split(' ').map(k => [k,{hue:0,sat:0,lum:0}])),
    contrast:1, pivot:.435, midDetail:0, colorBoost:0, shadows:0, highlights:0, saturation:50, hue:50, lumMix:100,
    logLowRange:.333, logHighRange:.55, lrBlending:50, lrBalance:0},
};

function assignPath(object, path, value) {
  const keys = path.split('.');
  for (const key of keys.slice(0, -1)) object = object[key] ??= {};
  object[keys.at(-1)] = value;
}

const cases = [];
function parameter(id, path, lowest, highest, setup = {}, options = {}) {
  cases.push({id, path, lowest, highest, setup, ...options});
}

for (const name of ['exposure', 'contrast', 'highlights', 'shadows', 'whites', 'blacks']) {
  const range = name === 'exposure' ? [.12, 1.24] : [10, 82];
  parameter(`light-${name}`, `base.${name}`, ...range);
  parameter(`light-mask-${name}`, `basic.${name}`, ...range, {}, {local: true});
}
parameter('color-temp-raw', 'base.temperature', 3900, 8200, {'base.wbMode': 'custom'});
parameter('color-tint', 'base.tint', 10, 62, {'base.wbMode': 'custom'});
for (const key of ['vibrance', 'saturation']) parameter(`color-${key}`, `base.${key}`, 10, 82);
for (const [id, key] of [['temp','temperature'], ['tint','tint'], ['saturation','saturation']]) {
  parameter(`color-mask-${id}`, `basic.${key}`, 10, 80, {}, {local: true});
}
parameter('color-mask-hue', 'wheels.hue', 10, 90, {'wheels.hue':50}, {local:true,supplement:true});
for (const key of ['texture', 'clarity', 'dehaze']) {
  parameter(`effects-${key}`, `basic.${key}`, 12, 82);
  parameter(key === 'dehaze' ? 'local-dehaze' : `effects-mask-${key}`, `basic.${key}`, 12, 82, {}, {local: true});
}
for (const [id, key, lo, hi, setup] of [
  ['grain-amount', 'grainAmount', 10, 82], ['grain-size', 'grainSize', 10, 82, {'effects.grainAmount': 65}],
  ['grain-roughness', 'grainRoughness', 10, 85, {'effects.grainAmount': 65}],
  ['pcv-amount', 'vignetteAmount', -85, -15], ['pcv-midpoint', 'vignetteMidpoint', 10, 82],
  ['pcv-roundness', 'vignetteRoundness', -85, 75], ['pcv-feather', 'vignetteFeather', 10, 82],
  ['pcv-highlights', 'vignetteHighlights', 10, 82],
]) {
  const prerequisite = setup ?? (id.startsWith('pcv-') && key !== 'vignetteAmount' ? {'effects.vignetteAmount': -75} : {});
  parameter(`effects-${id}`, `effects.${key}`, lo, hi, prerequisite);
}
parameter('effects-mask-grain', 'effects.grainAmount', 10, 82, {}, {local: true});
parameter('effects-pcv-style', 'effects.vignetteStyle', 0, 1,
  {'effects.vignetteAmount': -70, 'effects.vignetteHighlights': 80},
  {supplement: true, levels: ['highlight-priority', 'paint-overlay']});
parameter('color-bw-treatment', 'base.profile', 0, 1, {},
  {supplement: true, levels: ['standard', 'monochrome']});
parameter('color-wb-presets', 'base.wbMode', 0, 1, {},
  {supplement: true, whiteBalancePreset: true, levels: ['daylight', 'tungsten']});
parameter('color-wb-as-shot', 'base.wbMode', 0, 1, {},
  {supplement: true, whiteBalancePreset: true, levels: ['tungsten', 'as-shot']});
for (const key of ['highlights','lights','darks','shadows']) parameter(`curve-param-${key}`, `curves.parametric.${key}`, 12, 82);
parameter('curve-param-splits', 'curves.parametric.split2', .31, .72, {'curves.parametric.darks': 50});
const curve = v => [[0, 0], [.5, v], [1, 1]];
parameter('curve-point', 'curves.master', .56, .83, {}, {transform: curve});
parameter('curve-channels', 'curves.red', .56, .83, {}, {transform: curve});
parameter('curve-mask-curve', 'curves.master', .56, .83, {}, {local: true, transform: curve});
for (const key of ['hue', 'saturation', 'luminance']) parameter(`mixer-${key}`, `mixer.${key}.blue`, 12, 82);
for (const [id, key] of [['shadows','lrShadows'],['midtones','lrMidtones'],['highlights','lrHighlights'],['global','lrGlobal']]) {
  parameter(`grading-${id}`, `wheels.${key}.sat`, 10, 80, {[`wheels.${key}.hue`]: 180});
}
parameter('grading-luminance', 'wheels.lrMidtones.lum', 10, 80);
const grading = {'wheels.lrShadows': {hue: 185, sat: 60, lum: 0}, 'wheels.lrHighlights': {hue: 35, sat: 60, lum: 0}};
parameter('grading-blending', 'wheels.lrBlending', 10, 82, grading);
parameter('grading-balance', 'wheels.lrBalance', -82, 75, grading);
parameter('grading-mask-wheels', 'wheels.lrShadows.sat', 10, 80, {'wheels.lrShadows.hue': 185}, {local: true});
for (const [id, key, setup, lo, hi] of [
  ['sharpen-amount', 'sharpenAmount', {}, 10, 90], ['sharpen-radius', 'sharpenRadius', {sharpenAmount: 80}, .6, 2.9],
  ['sharpen-detail', 'sharpenDetail', {sharpenAmount: 80}, 10, 80], ['sharpen-masking', 'sharpenMasking', {sharpenAmount: 80}, 10, 80],
  ['nr-luminance', 'noiseLuminance', {}, 10, 80], ['nr-lum-detail', 'noiseLumDetail', {noiseLuminance: 80}, 10, 80],
  ['nr-lum-contrast','noiseLumContrast', {noiseLuminance: 80}, 10, 80], ['nr-color','noiseColor', {}, 10, 80],
  ['nr-color-detail','noiseColorDetail', {noiseColor: 80}, 10, 80],
]) parameter(`detail-${id}`, `detail.${key}`, lo, hi, Object.fromEntries(Object.entries(setup).map(([k,v]) => [`detail.${k}`,v])));
parameter('detail-mask-sharpness', 'detail.sharpenAmount', 10, 90, {}, {local: true});
parameter('detail-mask-noise', 'detail.noiseLuminance', 10, 80, {}, {local: true});

// These tables match RAWMaster's two 2³ built-in looks. The stock editor's worker registers
// parsed CUBE bytes through setLuts; its Effects tool accepts sRGB input and output spaces.
const lutTables = {}, lutNames = {};
for (const [name, asset] of [['warm','lut-a01'], ['mono','lut-b02']]) {
  const rgb = [];
  for (let b=0;b<2;b++) for(let g=0;g<2;g++) for(let r=0;r<2;r++) {
    const gray = .2126*r + .7152*g + .0722*b;
    rgb.push(...(name === 'warm' ? [.94*r+.06, g, .9*b] : [gray,gray,gray]));
  }
  lutTables[asset] = {size:2, dim:'3d', data:rgb, domainMin:[0,0,0], domainMax:[1,1,1]};
  lutNames[name] = asset;
}

for (const [suffix, field, levels] of [
  ['select','effects.lut.asset',['warm','mono']],
  ['amount','effects.lut.strength',null],
  ['stack','grade.nodes.count',[2,3]],
  ['manage','grade.edges.order',['warm,mono','mono,warm']],
  ['mask','effects.lut.strength',null],
]) {
  parameter('grading-lut-'+suffix, field, 15, 95, {}, {lut:suffix, local:suffix==='mask', levels});
}

function lutEdit(base, spec, selected) {
  const edit = structuredClone(base);
  const type = spec.lut;
  const v = selected ?? (spec.levels ? spec.levels[0] : 0);
  let names = [type === 'select' ? v : 'mono'];
  if (type === 'stack') names = v === 3 ? ['warm','mono','warm'] : ['warm','mono'];
  if (type === 'manage') names = v.split(',');
  edit.grade.nodes = names.map((name,i) => {
    const node = structuredClone(base.grade.nodes[0]);
    node.id = 'corrector-'+i; node.number = i+1; node.x = i+1;
    if (spec.local) node.mask = localMask();
    const strength = type==='amount' || type==='mask' ? v : (i===2 ? 65 : 100);
    node.tools.effects = {...toolDefaults.effects, lut: {asset:lutNames[name],name, strength,inputSpace:'srgb',outputSpace:'srgb'}};
    return node;
  });
  edit.grade.edges = edit.grade.nodes.map((node,i) => ({from:i ? edit.grade.nodes[i-1].id : '@input',to:node.id,index:0}));
  edit.grade.edges.push({from:edit.grade.nodes.at(-1).id,to:'@output',index:0});
  return edit;
}

function editFor(base, spec, value) {
  if (spec.lut) return lutEdit(base, spec, value);
  const edit = structuredClone(base);
  if (spec.whiteBalancePreset) {
    // These are the three fields set together by the original White Balance menu action.
    const mode = value ?? spec.levels[0];
    const values = {daylight: [5500, 10], tungsten: [2850, 0],
      'as-shot': [Math.round(base.base.temperature), Math.round(base.base.tint)]};
    const [temperature, tint] = values[mode];
    Object.assign(edit.base, {wbMode: mode, temperature, tint});
    return edit;
  }
  const node = edit.grade.nodes[0];
  if (spec.local) node.mask = localMask();
  function set(path, val) {
    if (path.startsWith('base.')) assignPath(edit, path, val);
    else {
      const tool = path.split('.')[0];
      // JSON roundtrip also detaches equal defaults shared by the separate HSL channels.
      node.tools[tool] ??= JSON.parse(JSON.stringify(toolDefaults[tool]));
      assignPath(node.tools, path, val);
    }
  }
  for (const [path, val] of Object.entries(spec.setup)) set(path, structuredClone(val));
  if (value !== undefined) set(spec.path, spec.transform ? spec.transform(value) : value);
  return edit;
}

function rounded(x) { return Math.round(x * 1000) / 1000; }

function testValues(spec, base, count) {
  if (spec.levels) return Array.from({length:count}, (_,i) => spec.levels[(i+1) % spec.levels.length]);
  let step = Number.isInteger(spec.lowest) && Number.isInteger(spec.highest) ? 1 : .01;
  if (spec.path === 'detail.sharpenRadius') step = .1;
  const defaults = spec.path.startsWith('base.') ? {base:base.base} : toolDefaults;
  const original = spec.path.split('.').reduce((obj,key) => obj?.[key], defaults);
  const candidates = [];
  for (let i=0; i<=Math.round((spec.highest-spec.lowest)/step); i++) {
    const value = +(spec.lowest+i*step).toFixed(5);
    if (value !== original) candidates.push(value);
  }
  if (candidates.length < count) throw Error(`Only ${candidates.length} distinct non-default inputs in this fixture range`);
  const spaced = Array.from({length:count}, (_,i) => candidates[Math.round(i*(candidates.length-1)/(count-1))]);
  return spaced.map((_,i) => i%2===0 ? spaced[Math.floor(i/2)] : spaced[count-1-Math.floor(i/2)]);
}

async function textureWitness(engine, rendered, radialWitness = false) {
  const tensor = await engine.readTicket(engine.copyHandle(rendered.handle));
  const bits = new Uint16Array(tensor.buffer, tensor.byteOffset, tensor.byteLength / 2);
  if (bits.length !== rendered.width * rendered.height * 4) throw Error(`unexpected RGBA16F readback size ${bits.length}`);
  const color = new Uint16Array(96 * 64 * 3);
  let i = 0, opaque = 0;
  for (let j = 0; j < 64; j++) {
    const y = Math.floor((j + .5) * rendered.height / 64);
    for (let k = 0; k < 96; k++) {
      const x = Math.floor((k + .5) * rendered.width / 96);
      const offset = 4 * (y * rendered.width + x);
      for (let channel=0; channel<3; channel++) {
        const value = bits[offset + channel];
        if ((value & 0x7c00) === 0x7c00) throw Error('non-finite RGB output');
        color[i++] = value;
      }
      if (bits[offset + 3] === 0x3c00) opaque++;
    }
  }
  if (opaque < 96 * 64 * .98) throw Error(`insufficient opaque sample coverage: ${opaque}`);
  const sha = async data => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', data)),
    v => v.toString(16).padStart(2,'0')).join('');
  const all = await sha(color);
  if (!radialWitness) return {all};
  const outer=[], inner=[];
  for (let y=0; y<64; ++y) for (let x=0; x<96; ++x) {
    const u=(x+.5)/96-.5, v=(y+.5)/64-.5;
    const radius=Math.hypot(u/.35,v/.3);
    const offset=3*(y*96+x);
    if (radius<.45) inner.push(...color.subarray(offset,offset+3));
    if (radius>1.5) outer.push(...color.subarray(offset,offset+3));
  }
  return {all,inside:await sha(new Uint16Array(inner)),outside:await sha(new Uint16Array(outer)),
    insideCount:inner.length/3,outsideCount:outer.length/3};
}

async function measure(engine, target, edit, radialWitness = false) {
  const recipe = JSON.stringify(edit);
  const start = performance.now();
  const frame = engine.render('fixture', recipe, target, '{}');
  try {
    await engine.idle();
    const milliseconds = rounded(performance.now() - start);
    if (frame.provisional || frame.pending) throw Error('provisional or pending render');
    const witness = await textureWitness(engine, frame, radialWitness);
    const errors = engine.takeErrors();
    if (errors.length) throw Error(errors.join(' / '));
    return {milliseconds, witness:witness.all, regions:radialWitness ? witness:undefined, width: frame.width, height: frame.height};
  } finally { engine.release(frame.handle); }
}

// The stock viewer's readback sink wraps these bytes directly in a browser ImageData.
// Keep the fitted photograph edge-to-edge and disable split, UI overlays, HDR and P3.
async function displayComparison(engine, source, neutral, config, metadata) {
  const width = 2400, height = 1600;
  const panel = config.panelControls;
  const values = panel ? Object.fromEntries(Object.entries(panel).map(([id, spec]) => [id, spec.values])) :
    {'light-exposure':[0,.5], 'light-contrast':[0,30], 'light-highlights':[0,30],
    'light-shadows':[0,30], 'light-whites':[0,30], 'light-blacks':[0,-30],
    'color-saturation':[0,30], 'color-vibrance':[0,30]};
  const selected = config.operations.length ? config.operations : Object.keys(values);
  const view = {photo:'fixture', compare:'off', side:'left-right',
    wipe:{compare:0,split:.5,wipeStyle:0,wipeInvert:false,beforeGeometry:null,beforeFit:null},
    tool:'pointer', soloNode:null, bypassGrade:false, bypassBase:false, clipping:false,
    zoom:width/source.width, center:{x:.5,y:.5}, before:null, keepNode:null, matteFor:null, maskStyle:null,
    alt:null, zoneView:null, overlay:null, background:[1,0,1], cw:width,ch:height,dpr:1,legacy:false};
  if (config.panelSchedule) {
    const {measurePanelSchedule} = await import('./lightflow-panel-schedule.mjs');
    if (config.extendedPhotoOperators) {
      const {photoOperatorRecipes} = await import('./lightflow-paired-photo-operators.mjs');
      const recipes = photoOperatorRecipes(engine, neutral, config.extendedPhotoOperators, toolDefaults, localMask);
      return report({...metadata, ...await measurePanelSchedule(engine, view, neutral, config, selected, recipes, report)});
    }
    const recipeFor = (key, state) => {
      const spec = cases.find(item => item.id === key);
      if (!spec || !panel[key]) throw Error('Unknown panel control ' + key);
      return editFor(neutral, {...spec, setup:{...spec.setup, ...panel[key].fixed}}, values[key][state]);
    };
    return report({...metadata, ...await measurePanelSchedule(engine, view, neutral, config, selected, recipeFor)});
  }
  engine.createViewer('display', null, false, false, true);
  engine.viewerSize('display',width,height);
  engine.viewerPhotoChanged('display');
  let editKey = 0, lastSeq = -1;
  async function draw(recipe) {
    const edit = JSON.stringify(recipe);
    const inputs = JSON.stringify({...view, editKey:++editKey, now:performance.now()});
    const start = performance.now();
    const info = JSON.parse(engine.viewerFrame('display','fixture',inputs,edit,'',''));
    await engine.idle();
    engine.viewerDone('display',performance.now());
    const frame = await engine.viewerReadback('display');
    const ms = performance.now() - start;
    if (!frame || frame.seq <= lastSeq || frame.width !== width || frame.height !== height ||
        frame.data.byteLength !== width*height*4 || info.provisional) throw Error('Incomplete display frame: '+JSON.stringify({info,
          seq:frame?.seq, lastSeq, width:frame?.width, height:frame?.height, bytes:frame?.data.byteLength}));
    lastSeq = frame.seq;
    const sample = new Uint8Array(96*64*3);
    let n=0;
    for (let y=0; y<64; ++y) for (let x=0; x<96; ++x) {
      const index=4*(Math.floor((y+.5)*height/64)*width + Math.floor((x+.5)*width/96));
      const [r,g,b,a]=frame.data.subarray(index,index+4);
      if (a!==255 || (r===255 && g===0 && b===255)) throw Error('Transparent or letterboxed photograph');
      sample[n++]=r; sample[n++]=g; sample[n++]=b;
    }
    const bytes=new Uint8Array(await crypto.subtle.digest('SHA-256',sample));
    const digest=Array.from(bytes, b=>b.toString(16).padStart(2,'0')).join('');
    return {ms:rounded(ms),digest, info};
  }
  const rows = [];
  try {
    const first = await draw(neutral);
    for (const key of selected) {
      const sourceSpec = cases.find(s=>s.id===key);
      if (!sourceSpec || !(key in values)) throw Error('Unknown paired readback control: '+key);
      const spec = panel ? {...sourceSpec,setup:{...sourceSpec.setup,...panel[key].fixed}} : sourceSpec;
      const row = {id:key,values:values[key],samples:[],status:'inconclusive'};
      const seen=[new Set(),new Set()];
      for(let i=0; i<config.samples+2; i++) {
        const state=i%2, value=values[key][state];
        const frame=await draw(editFor(neutral,spec,value));
        row.samples.push({state,phase:i<2?'first':'warm',ms:frame.ms,digest:frame.digest});
        seen[state].add(frame.digest);
      }
      const stable = seen.every(s=>s.size===1) && row.samples[0].digest!==row.samples[1].digest;
      if (panel) {
        row.fixed = panel[key].fixed;
        row.status = stable ? 'measured' : 'inconclusive';
        rows.push(row);
        await report({progress:key+' '+row.status});
        continue;
      }
      row.distinctInputs = [];
      const distinct = new Set();
      for (let level=1;level<=config.samples;level++) {
        const value=level*(key==='light-exposure' ? .04 : (key==='light-blacks' ? -1 : 1));
        const frame=await draw(editFor(neutral,spec,value));
        row.distinctInputs.push({value,ms:frame.ms,digest:frame.digest});
        distinct.add(frame.digest);
      }
      if (stable && distinct.size===config.samples) row.status='measured';
      rows.push(row);
      await report({progress:key+' '+row.status});
    }
    await report({...metadata,protocol:panel ? 'resident-srgb8-panels-v1' : 'resident-srgb8-readback-v1',pixels:[width,height],samples:config.samples,
      cachePolicy:'shipping defaults',distinctInputCount:panel ? 0 : config.samples,
      boundary:'Changed resident recipe to complete CPU-readable sRGB RGBA8 display buffer',viewInputs:view,
      firstFrameInfo:first.info,operations:rows});
  } finally { engine.disposeViewer('display'); }
}

async function main() {
  const config = await (await fetch('config.json')).json();
  const selected = config.operations.length ? cases.filter(r => config.operations.includes(r.id)) : cases.filter(r => !r.lut && !r.supplement);
  if (!config.viewerTools && !config.autoAnalysis && !config.vectorscope && !config.extendedPhotoOperators &&
      config.operations.some(id => !selected.some(s => s.id === id))) throw Error('unknown operation ID');
  const gpu = await navigator.gpu.requestAdapter();
  if (!gpu || gpu.info.isFallbackAdapter) throw Error('a physical WebGPU adapter is required');
  const adapterInfo = Object.fromEntries(['vendor','architecture','device','description','isFallbackAdapter'].map(k => [k,gpu.info[k]]));
  await init();
  const engine = await PixelEngine.open(1024 * 1024 * 1024);
  try {
    engine.installPlugs(null, null); // The geometric radial mask has no external matte or patch asset.
    if (/swiftshader|llvmpipe|software/i.test(engine.adapter+' '+JSON.stringify(adapterInfo))) throw Error(`hardware GPU required: ${engine.adapter}`);
    const bytes = new Uint8Array(await (await fetch('fixture.raw')).arrayBuffer());
    const start = performance.now();
    const source = JSON.parse(await engine.openRaw('fixture', bytes, JSON.stringify({quality:'full', demosaic:'auto', highlights:'reconstruct',lensCorrections:true})));
    await engine.idle();
    const rawOpenMs = rounded(performance.now() - start);
    if (!source.full || source.reduced || source.incomplete) throw Error('a complete full-resolution RAW source is required');
    const neutral = initialEdit(source.asShot);
    if (config.vectorscope) {
      const {vectorscope} = await import('./lightflow-vectorscope.mjs');
      if (config.operations.some(id => id !== 'color-vectorscope')) throw Error('Unexpected vectorscope operation');
      return report({browser:navigator.userAgent, adapter:engine.adapter, adapterInfo, rawSize:[source.width,source.height],
        rawOpenMs, ...await vectorscope(engine,neutral,config.samples)});
    }
    if (config.viewerTools) {
      const {viewerTools} = await import('./lightflow-viewer-tools.mjs');
      await viewerTools(engine,source,neutral,config,{browser:navigator.userAgent,adapter:engine.adapter,adapterInfo,
        rawSize:[source.width,source.height],rawOpenMs},toolDefaults.detail,report);
      return;
    }
    if (config.autoAnalysis) {
      const {automaticSettings} = await import('./lightflow-analysis.mjs');
      await automaticSettings(engine, neutral, config, {browser:navigator.userAgent,adapter:engine.adapter,adapterInfo,
        rawSize:[source.width,source.height],rawOpenMs}, report);
      return;
    }
    if (config.displayReadback) {
      await displayComparison(engine,source,neutral,config,{browser:navigator.userAgent,adapter:engine.adapter,adapterInfo,
        rawSize:[source.width,source.height],rawOpenMs});
      return;
    }
    const target = JSON.stringify({kind:'image', maxSize:config.size, exact:true});
    if (selected.some(s => s.lut)) engine.setLuts(JSON.stringify(lutTables));
    const operations = [];
    for (const spec of selected) {
      const row = {id:spec.id, featureIds:spec.id === 'local-dehaze' ? [] : [spec.id], field:spec.path, fixed:spec.setup, localMask:!!spec.local, trials:[]};
      if (spec.supplement) row.change = {alternating:spec.levels};
      if (spec.whiteBalancePreset) row.menuRecipeValues = Object.fromEntries(spec.levels.map(mode => {
        const {wbMode, temperature, tint} = editFor(neutral, spec, mode).base;
        return [mode, {wbMode, temperature, tint}];
      }));
      if (spec.lut) {
        row.colorSpace = 'sRGB';
        row.tableSize = 2;
        row.change = spec.levels ? {alternating:spec.levels} : {strengthRange:[spec.lowest,spec.highest]};
      }
      operations.push(row);
      try {
        const radialWitness = spec.id === 'color-mask-hue';
        const baseline = await measure(engine, target, editFor(neutral, spec), radialWitness);
        row.referenceDigest = baseline.witness;
        if (radialWitness) row.referenceRegions = baseline.regions;
        row.texture = [baseline.width, baseline.height];
        let previous = baseline.witness;
        for (const [index,value] of testValues(spec,neutral,config.samples+1).entries()) {
          const result = await measure(engine, target, editFor(neutral,spec,value), radialWitness);
          const verified = result.witness !== previous && (spec.levels ?
            (value === spec.levels[0]) === (result.witness === baseline.witness) : result.witness !== baseline.witness)
            && (!radialWitness || (result.regions.inside !== baseline.regions.inside && result.regions.outside === baseline.regions.outside));
          row.trials.push({phase:index===0?'first-in-session':'warm',value,ms:result.milliseconds,digest:result.witness,
            ...(radialWitness ? {regions:result.regions} : {}), verified});
          if (!verified) throw Error('RGB did not change from the previous input or did not match the expected reference state');
          previous = result.witness;
        }
        row.status = 'measured';
      } catch (error) { row.status = 'unverified'; row.reason = String(error); }
      await report({progress:`${row.id} ${row.status}${row.reason ? ' '+row.reason : ''}`});
    }
    await report({browser:navigator.userAgent, adapter:engine.adapter, adapterInfo, rawSize:[source.width,source.height],
      rawOpenMs, rawDecodeMs:source.decodeMs, rawDevelopMs:source.developMs, target:JSON.parse(target), samples:config.samples,
      verification:'SHA-256 of a 96 × 64 grid of finite linear RGB half-float triplets with at least 98% opaque samples. Every accepted edit changes the grid relative to its previous trial. Each continuous edit must also differ from the fixed reference. Discrete paired edits must return to the reference digest exactly when restoring its setting.', operations});
  } finally { engine.free(); }
}

main().catch(error => report({error:String(error.stack || error)}));
