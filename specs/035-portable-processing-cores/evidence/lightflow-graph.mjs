// Run: node lightflow-graph.mjs /path/to/build/rust/web /path/to/chromium
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawn} from 'node:child_process';

// Runs in Chromium using only the unmodified release's public PixelEngine interface.
async function observe() {
  const {default: init, PixelEngine} = await import('./lightflow_host_wasm.js');
  await init();
  const engine = await PixelEngine.open(64 * 1024 * 1024);
  try {
    const size = 128;
    const texels = new Float16Array(size * size * 4);
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        texels.set([0.12 + x / 255, 0.03 + y / 320, 0.09 + (x + y) / 768, 1], 4 * (y * size + x));
      }
    }
    engine.setSource('chart', size, size, new Uint16Array(texels.buffer), 'rgb', false);
    const basic = Object.fromEntries('temperature tint exposure contrast highlights shadows whites blacks texture clarity dehaze vibrance saturation'.split(' ').map(name => [name, 0]));
    const branch = (id, exposure, opacity) => ({id, kind:'corrector', enabled:true, number:id === 'A' ? 1 : 2,
      label:id, color:null, x:1, y:0, opacity, mask:null, tools:{basic:{...basic, exposure}}});
    const a = branch('A', -0.75, 0.55), b = branch('B', 1, 0.7);
    const mix = {id:'M', kind:'layer', enabled:true, number:0, label:'Layer', color:null, x:2, y:0,
      opacity:1, mask:null, tools:{}, blendModes:['normal', 'normal']};
    const edge = (from, to, index = 0) => ({from, to, index});
    const recipe = {version:1, source:{demosaic:'auto',highlightReconstruction:true,lensCorrections:true,assumeColorSpace:null},
      base:{profile:'standard',profileAmount:100,wbMode:'as-shot',temperature:6500,tint:0,exposure:0,contrast:0,
        highlights:0,shadows:0,whites:0,blacks:0,vibrance:0,saturation:0}, retouch:[],
      geometry:{crop:{x:0,y:0,w:1,h:1},angle:0,quarterTurns:0,flipH:false,flipV:false,aspect:null}};
    const diamond = reverse => [edge('@input','A'),edge('@input','B'),edge('A','M',Number(reverse)),
      edge('B','M',Number(!reverse)),edge('M','@output')];
    const single = node => ({nodes:[node], edges:[edge('@input',node.id),edge(node.id,'@output')]});
    const ab = {nodes:[a,b,mix],edges:diamond(false)}, ba = {nodes:[a,b,mix],edges:diamond(true)};
    const cases = [['A',single(a)],['B',single(b)],['A+B',ab],['B+A',ba],['A+B again',ab]];
    const target = JSON.stringify({kind:'image',maxSize:size,exact:true});
    const rows = [];
    for (const [label,grade] of cases) {
      const attempts = [];
      let finalHash;
      for (let i = 0; i < 8; i++) {
        engine.beginFrame();
        engine.compileDemanded(16);
        engine.compileQueued(16);
        const frame = engine.render('chart', JSON.stringify({...recipe,grade}), target, '{}');
        try {
          await engine.idle();
          attempts.push({segments:frame.segments, cached:frame.cached, provisional:frame.provisional});
          if (frame.provisional) continue;
          const bytes = await engine.readTicket(engine.copyHandle(frame.handle));
          if (bytes.byteLength !== size * size * 8) throw Error('Unexpected RGBA16F size');
          const pixels = new Float16Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 2);
          if (pixels.some((v,k) => !Number.isFinite(v) || (k % 4 === 3 && v !== 1))) throw Error('Non-finite or non-opaque chart');
          finalHash = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)), b => b.toString(16).padStart(2,'0')).join('');
          break;
        } finally { engine.release(frame.handle); }
      }
      if (!finalHash) throw Error('Graph did not settle: ' + label);
      rows.push({label,sha256:finalHash,attempts});
    }
    if (new Set(rows.slice(0,4).map(row => row.sha256)).size !== 4 || rows[2].sha256 !== rows[4].sha256) {
      throw Error('Layer port order or restored output did not pass the pixel witness: ' + JSON.stringify(rows));
    }
    const adapter = (await navigator.gpu.requestAdapter())?.info;
    return {browser:navigator.userAgent, engineAdapter:engine.adapter, adapter:adapter && {vendor:adapter.vendor,
      architecture:adapter.architecture, device:adapter.device, isFallbackAdapter:adapter.isFallbackAdapter},
      size:[size,size], source:'opaque RGBA16F synthetic ramp', recipe, branches:ab, rows, memory:engine.memory()};
  } finally { engine.free(); }
}

const [directory, chrome] = process.argv.slice(2);
if (!directory || !chrome) throw Error('Specify the pinned rust/web directory and Chromium executable');
const pins = JSON.parse(await readFile(new URL('./lightflow-release.json',import.meta.url)));
const assets = new Map();
for (const row of pins.files.filter(row => row.path.includes('/rust/web/'))) {
  const name = row.path.split('/').at(-1), bytes = await readFile(join(directory,name));
  if (createHash('sha256').update(bytes).digest('hex') !== row.sha256) throw Error('Incorrect release: ' + name);
  assets.set('/'+name,bytes);
}
const profile = await mkdtemp(join(tmpdir(),'rawmaster-lf-graph-'));
const {promise,resolve,reject} = Promise.withResolvers();
const server = createServer(async (req,res) => {
  if (req.url === '/result' && req.method === 'POST') {
    let body = '';
    for await (const chunk of req) body += chunk;
    res.end(); resolve(JSON.parse(body)); return;
  }
  if (req.url === '/') {
    res.setHeader('Content-Type','text/html');
    res.end(`<script type="module">const report = result => fetch('/result',{method:'POST',body:JSON.stringify(result)}); (${observe})().then(report, err => report({error:String(err.stack || err)}));</script>`);
  } else if (assets.has(req.url)) {
    res.setHeader('Content-Type',req.url.endsWith('.wasm') ? 'application/wasm' : 'text/javascript');
    res.end(assets.get(req.url));
  } else { res.writeHead(404).end(); }
});
await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
const child = spawn(chrome,['--headless=new','--enable-gpu','--disable-background-networking','--no-first-run',
  `--user-data-dir=${profile}`,`http://127.0.0.1:${server.address().port}/`],{stdio:'ignore'});
const exited = new Promise(resolve => child.once('close',resolve));
child.once('error',reject);
child.once('close',code => reject(Error('Chromium exited: '+code)));
const timer = setTimeout(() => reject(Error('Timed out waiting for GPU')),60000);
try {
  const result = await promise;
  if (result.error) throw Error(result.error);
  console.log(JSON.stringify(result,null,2));
} finally {
  clearTimeout(timer);
  child.kill();
  const force = setTimeout(() => child.kill('SIGKILL'),2000);
  await exited;
  clearTimeout(force);
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await rm(profile,{recursive:true,force:true});
}
