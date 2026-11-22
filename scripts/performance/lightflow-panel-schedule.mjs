// Follow the stock photo viewer's released-input loop with a resident original RAW and no occlusion.
// The returned times distinguish the renderer/readback, dispatch-to-readback and idle confirmation.
const round = value => Math.round(value * 1000) / 1000;

function rasterWitness(frame, width, height, fullAlpha = false) {
  if (frame.width !== width || frame.height !== height || frame.data.byteLength !== width * height * 4) {
    throw Error('Wrong readback dimensions');
  }
  const pixels = new Uint8Array(96 * 64 * 3);
  if (fullAlpha) {
    for (let i=3; i<frame.data.length; i+=4) {
      if (frame.data[i] !== 255) throw Error('Transparent full-resolution output');
    }
  }
  let cursor = 0;
  for (let y = 0; y < 64; ++y) for (let x = 0; x < 96; ++x) {
    const i = 4 * (Math.floor((y + .5) * height / 64) * width + Math.floor((x + .5) * width / 96));
    const bytes = frame.data.subarray(i, i + 4);
    const edge = x === 0 || x === 95 || y === 0 || y === 63;
    if (bytes[3] !== 255 || ((!fullAlpha || edge) && bytes[0] === 255 && bytes[1] === 0 && bytes[2] === 255)) {
      throw Error('Transparent or letterboxed photograph');
    }
    pixels.set(bytes.subarray(0, 3), cursor);
    cursor += 3;
  }
  return pixels;
}

function delta(a, b) {
  let sum = 0, max = 0, changedChannels = 0;
  for (let i = 0; i < a.length; ++i) {
    const d = Math.abs(a[i] - b[i]);
    sum += d;
    max = Math.max(max, d);
    changedChannels += Number(d !== 0);
  }
  return {mean: round(sum / a.length), max, changedChannels};
}

async function sha(bytes) {
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return Array.from(hash, b => b.toString(16).padStart(2, '0')).join('');
}

async function radialEvidence(pixels, radial) {
  const [w, h] = radial.witnessGrid;
  const inside = [], outside = [];
  for (let y = 0; y < h; ++y) for (let x = 0; x < w; ++x) {
    const dx = ((x + .5) / w - radial.center[0]) / radial.radius[0];
    const dy = ((y + .5) / h - radial.center[1]) / radial.radius[1];
    const r = Math.hypot(dx, dy);
    const region = r <= radial.interiorMaximumRadius ? inside : r >= radial.exteriorMinimumRadius ? outside : null;
    if (region) region.push(...pixels.subarray((y*w+x)*3, (y*w+x)*3+3));
  }
  return {inside:await sha(new Uint8Array(inside)), outside:await sha(new Uint8Array(outside)),
    insideCount:inside.length/3, outsideCount:outside.length/3};
}

export async function measurePanelSchedule(engine, view, neutral, config, selected, recipeFor, progress) {
  const id = 'scheduled', width = view.cw, height = view.ch;
  const extended = config.extendedPhotoOperators;
  let editKey = 0, lastSeq = -1;
  engine.createViewer(id, null, false, false, true);
  engine.viewerSize(id, width, height);
  engine.viewerPhotoChanged(id);
  async function submit(recipe, overrides = {}) {
    const edit = JSON.stringify(recipe), key = ++editKey, frames = [], buffers = [];
    const submitted = performance.now();
    engine.viewerInvalidate(id, submitted);
    const states = [];
    while (performance.now() - submitted < 3000) {
      await new Promise(resolve => requestAnimationFrame(resolve));
      const now = performance.now();
      engine.compileDemanded(4);
      const bits = engine.viewerTick(id, now, true, 0);
      if (states.at(-1)?.bits !== bits) states.push({atMs:round(now - submitted), bits});
      if (!(bits & 1)) {
        if (!(bits & 2) && frames.length) {
          const idleConfirmedMs = round(performance.now() - submitted);
          let finalPixels;
          for (const [i, buffer] of buffers.entries()) {
            finalPixels = rasterWitness(buffer, width, height, !!extended);
            [frames[i].digest, frames[i].wholeRasterSHA256] = await Promise.all([sha(finalPixels), sha(buffer.data)]);
          }
          const final = frames.at(-1);
          const firstMatch = frames.find(frame => frame.wholeRasterSHA256 === final.wholeRasterSHA256);
          return {frames, schedulerTransitions:states, idleConfirmedMs, pixels:finalPixels,
            renderToFinalMs:round(final.actionToPixelsMs - frames[0].frameStartAfterDispatchMs),
            renderToFirstExactFinalMs:round(firstMatch.actionToPixelsMs - frames[0].frameStartAfterDispatchMs)};
        }
        continue;
      }
      const inputs = JSON.stringify({...view, ...overrides, editKey:key, now});
      const start = performance.now();
      const info = JSON.parse(engine.viewerFrame(id, 'fixture', inputs, frames.length ? '' : edit, '', ''));
      const readback = engine.viewerReadback(id).then(buffer => ({buffer,at:performance.now()}));
      const gpu = engine.idle().then(() => engine.viewerDone(id, performance.now()));
      const [{buffer, at}] = await Promise.all([readback, gpu]);
      if (!buffer || buffer.seq <= lastSeq) throw Error('Missing or stale viewer readback');
      lastSeq = buffer.seq;
      buffers.push(buffer);
      frames.push({seq:buffer.seq, ms:round(at - start), actionToPixelsMs:round(at - submitted),
        frameStartAfterDispatchMs:round(start - submitted), interactive:info.interactive, provisional:info.provisional,
        fullRes:info.fullRes, ppu:info.ppu, detailPpu:info.detailPpu, need:info.need, rung:info.rung,
        renderedPx:info.renderedPx, tiles:info.tiles});
    }
    throw Error('No released viewer settlement for edit ' + key + ' · ' + JSON.stringify({frames,states}));
  }
  try {
    const first = await submit(neutral);
    delete first.pixels;
    const operations = [];
    for (const key of selected) {
      const spec = config.panelControls[key];
      const out = {id:key, values:spec.values, fixed:spec.fixed, samples:[], status:'inconclusive'};
      if (extended) {
        out.region = spec.region;
        out.unit = spec.unit;
        out.stateDescriptions = [recipeFor(key,0),recipeFor(key,1)];
      }
      const signatures = [new Set(), new Set()], references = [];
      try {
      for (let i = 0; i < config.samples + 2; ++i) {
        const state = i % 2;
        const observation = extended
          ? await submit(out.stateDescriptions[state].edit, out.stateDescriptions[state].view)
          : await submit(recipeFor(key,state));
        const pixels = observation.pixels;
        delete observation.pixels;
        const last = observation.frames.at(-1);
        const sample = {state, phase:i < 2 ? 'first':'warm', ms:observation.renderToFinalMs, digest:last.digest,
          ...observation, finalSameStateDelta:references[state] ? delta(pixels, references[state]):null,
          finalOtherStateDelta:references[1-state] ? delta(pixels, references[1-state]):null};
        if (extended && spec.region === 'radial') sample.regions = await radialEvidence(pixels, extended.radial);
        references[state] ??= pixels;
        signatures[state].add(extended ? last.wholeRasterSHA256 : last.digest);
        out.samples.push(sample);
      }
      } catch (e) {
        if (!extended) throw e;
        out.reason = String(e);
      }
      const stable = out.samples.length === config.samples + 2 && signatures.every(set => set.size === 1) &&
        [...signatures[0]][0] !== [...signatures[1]][0];
      if (stable && out.samples.every(s => {const f=s.frames.at(-1);return f.fullRes && !f.provisional && !f.interactive;})) {
        out.status = 'measured';
      }
      const equalsFinal = s => s.frames[0].wholeRasterSHA256 === s.frames.at(-1).wholeRasterSHA256;
      out.firstFrameExactFinal = {all:out.samples.filter(equalsFinal).length, total:out.samples.length,
        warm:out.samples.slice(2).filter(equalsFinal).length, warmTotal:out.samples.length - 2};
      out.finalWholeRasterDigestsByState = [0, 1].map(state => [...new Set(out.samples.filter(s => s.state === state)
        .map(s => s.frames.at(-1).wholeRasterSHA256))]);
      if (extended) {
        const [a,b] = out.finalWholeRasterDigestsByState;
        const validRegions = spec.region !== 'radial' || (stable &&
          new Set(out.samples.map(s=>s.regions.outside)).size === 1 &&
          out.samples[0].regions.inside !== out.samples[1].regions.inside &&
          [0,1].every(i=>new Set(out.samples.filter(s=>s.state===i).map(s=>s.regions.inside)).size===1));
        if (a.length !== 1 || b.length !== 1 || a[0] === b[0] || !validRegions) {
          out.status = 'inconclusive';
          out.reason ??= !validRegions ? 'Masked interior or exterior did not meet the spatial witness' : 'Full A/B output was identical or not bit-repeatable';
        }
        await progress({progress:key+' '+out.status});
      }
      operations.push(out);
    }
    return {protocol:extended ? 'resident-photo-operators-stock-scheduler-v2' : 'resident-srgb8-panels-stock-scheduler-v1', samples:config.samples, pixels:[width,height],
      cachePolicy:'stock viewer residency, demand compilation, released input, unobstructed photo',
      timing:'Sample ms is first changed viewerFrame entry to the final complete CPU-readable RGBA8 buffer, including subsequent scheduling. renderToFirstExactFinalMs ends at the earliest whole-buffer match with that final output. Per-frame ms measures one viewerFrame. actionToPixelsMs includes the initial animation frame. idleConfirmedMs ends at the first following tick with neither draw nor busy. Pixel verification follows all timed work.',
      verification:extended ? 'Entire opaque sRGB RGBA8 SHA-256 must repeat separately per state and differ between A/B. On radial operations the interior must change while the far exterior repeats across both states. Final stock frame must be fullRes, non-interactive and non-provisional.' : 'Exact final 96×64 RGB grid per state across both first and all warm samples, distinct A/B, final stock fullRes=true, interactive=false and provisional=false. All intermediate frames are retained.',
      ...(extended ? {registeredLUTs:recipeFor.registeredLUTs, radial:extended.radial, viewInputs:view} : {}),
      firstFrameInfo:first, operations};
  } finally {
    engine.disposeViewer(id);
  }
}
