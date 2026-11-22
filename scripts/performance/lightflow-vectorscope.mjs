// Stock worker scope plan for a single, unzoomed vectorscope with the normal 1024px input.
// The editor draws the graticule separately. This measures the actual render of the color trace.
export async function vectorscope(engine, neutral, repeats) {
  const width = 256, height = 168, normal = 1024;
  const target = JSON.stringify({kind:'image', maxSize:normal, exact:true});
  const display = JSON.stringify({brightness:1, colorize:true, channels:7, range:'all', view:[0,0,1,1]});
  const sources = [], textures = [], trials = [], byState = [new Set(), new Set()];
  try {
    for (const saturation of [0, 70]) {
      const edit = structuredClone(neutral);
      edit.base.saturation = saturation;
      const start = performance.now();
      const frame = engine.render('fixture', JSON.stringify(edit), target, '{}');
      textures.push(frame);
      await engine.idle();
      if (frame.provisional || frame.pending || frame.width !== normal) throw Error('Incomplete resident scope input');
      sources.push({pixels:[frame.width,frame.height],saturation,sourceRenderMs:performance.now() - start});
    }
    for (let i = 0; i < repeats + 2; i++) {
      const state = i % 2, source = textures[state];
      const region = {geometry:[1,0,0,1,0,0], rect:source.rect, offset:source.offset,
        frameSize:[source.width,source.height]};
      const options = JSON.stringify({columns:256, rows:256, vecBins:256, cieBins:0, cieDiagram:'xy',
        maxSamples:normal, vecZoom:1, vecBoost:0, vecRanges:['all'], vecSplit:[.3,.7], vecColor:true,
        waveColor:false, chroma:false, extents:false, waveChannels:0, vectorscope:true, lowPass:0, region});
      const start = performance.now();
      const stats = engine.scopeAccumulate(source.handle, options);
      const ticket = engine.scopeResolveImage('vectorscope', display, width, height);
      engine.scopeSubmit();
      const pixels = await engine.readTicket(ticket), ms = performance.now() - start;
      if (pixels.byteLength !== width * height * 4 || stats.samples < normal * 640) {
        throw Error('Wrong scope sample count or readback area: ' + JSON.stringify(stats));
      }
      let colored = 0, sum = 0;
      for (let j = 0; j < pixels.length; j += 4) {
        const lo = Math.min(pixels[j],pixels[j+1],pixels[j+2]), hi = Math.max(pixels[j],pixels[j+1],pixels[j+2]);
        if (hi - lo >= 4) colored++;
        sum += hi - lo;
      }
      if (colored < 5) throw Error('No measured color trace in scope output');
      const digest = Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', pixels)),
        byte => byte.toString(16).padStart(2,'0')).join('');
      byState[state].add(digest);
      trials.push({state,phase:i<2?'first':'warm',ms,digest,stats,coloredPixels:colored,totalRGBChroma:sum});
    }
    const stable = byState.every(group => group.size === 1) && trials[0].digest !== trials[1].digest;
    return {protocol:'lightflow-vectorscope-trace-readback-v1',pixels:[width,height],sources,samples:repeats,
      operations:[{id:'color-vectorscope',featureIds:['color-vectorscope'],status:stable?'measured':'inconclusive',
        verification:'Same input produces exactly the same complete colored scope trace, and two RAW grades produce distinct full RGBA8 traces.',
        trials}]};
  } finally {
    for (const frame of textures) engine.release(frame.handle);
  }
}
