// The published editor routes these menu actions through query.autoBase. Its worker
// reuses a 384px analysisSample for the same source revision, retouch and geometry.
export async function automaticSettings(engine, neutral, config, metadata, report) {
  const tests = {
    'light-auto': {
      options:{whiteBalance:false}, fields:['exposure','contrast','highlights','shadows','whites','blacks'],
      starting:[{exposure:-1.25, contrast:20}, {exposure:1.75, contrast:-25}],
    },
    'color-wb-auto': {
      options:{tone:false}, fields:['temperature','tint'],
      starting:[{wbMode:'tungsten',temperature:2850,tint:0}, {wbMode:'daylight',temperature:5500,tint:10}],
    },
  };
  const names = config.operations.length ? config.operations : Object.keys(tests);
  if (names.some(key => !(key in tests))) throw Error('Unknown automatic setting');
  const start = performance.now();
  const ticket = engine.analysisSample('fixture', JSON.stringify(neutral), 384);
  const bytes = await engine.readTicket(ticket.ticket);
  const sampleReadyMs = performance.now() - start;
  const pixels = new Float32Array(bytes.buffer, bytes.byteOffset, bytes.byteLength / 4);
  if (bytes.byteLength !== ticket.width * ticket.height * 16 || Math.max(ticket.width, ticket.height) !== 384)
    throw Error('Wrong analysis sample dimensions');
  let opaque = 0, darkest = Infinity, brightest = -Infinity;
  for (let i = 0; i < pixels.length; i += 4) {
    const [r,g,b,a] = pixels.subarray(i,i+4);
    if (![r,g,b,a].every(Number.isFinite)) throw Error('Analysis sample has nonfinite pixels');
    if (a > .98) { opaque++; darkest = Math.min(darkest,r,g,b); brightest = Math.max(brightest,r,g,b); }
  }
  if (opaque < .98*ticket.width*ticket.height || brightest - darkest < .05) throw Error('Unexpected RAW sample');
  const digest = async data => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),
    value => value.toString(16).padStart(2,'0')).join('');
  const operations = [];
  for (const id of names) {
    const spec = tests[id], seen = [new Set(), new Set()];
    const row = {id,featureIds:[id],options:spec.options,fields:spec.fields,startingEdits:spec.starting,
      status:'inconclusive', trials:[]};
    for (let i = 0; i < config.samples + 2; i++) {
      const state = i % 2, base = {...neutral.base, ...spec.starting[state]};
      const input = JSON.stringify(base), options = JSON.stringify(spec.options);
      const submitted = performance.now();
      const values = JSON.parse(engine.analysisAuto('fixture', ticket.width, ticket.height, bytes, input, options));
      const ms = performance.now() - submitted;
      const result = Object.fromEntries(spec.fields.map(field => [field,values[field]]));
      const changed = spec.fields.filter(field => base[field] !== result[field]);
      const verified = spec.fields.every(field => Number.isFinite(result[field])) && changed.length > 0;
      const hash = await digest(new TextEncoder().encode(JSON.stringify(result)));
      row.trials.push({state,phase:i<2?'first':'warm',ms,digest:hash,values,changed,verified});
      if (!verified) { row.reason = 'Automatic action did not return changed finite target fields'; break; }
      seen[state].add(hash);
    }
    if (row.trials.length === config.samples + 2 && seen.every(states => states.size === 1)) row.status = 'measured';
    operations.push(row);
    await report({progress:id+' '+row.status});
  }
  await report({...metadata,protocol:'lightflow-auto-analysis-v1',samples:config.samples,
    sample:{width:ticket.width,height:ticket.height,format:'linear RGBA32F',sha256:await digest(bytes),
      opaque,minimumRGB:darkest,maximumRGB:brightest,sampleReadyMs},operations});
}
