// The stock worker builds FrameInputs.alt from the inspector's Option-held control and node.
export async function viewerTools(engine, source, neutral, config, metadata, detailDefaults, report) {
  const width = 2400, height = 1600;
  const view = {
    photo: 'fixture',
    compare: 'off',
    side: 'left-right',
    wipe: { compare: 0, split: .5, wipeStyle: 0, wipeInvert: false, beforeGeometry: null, beforeFit: null },
    tool: 'pointer',
    soloNode: null,
    bypassGrade: false,
    bypassBase: false,
    clipping: false,
    zoom: width / source.width,
    center: { x: .5, y: .5 },
    before: null,
    keepNode: null,
    matteFor: null,
    maskStyle: null,
    alt: null,
    zoneView: null,
    overlay: null,
    background: [1, 0, 1],
    cw: width,
    ch: height,
    dpr: 1,
    legacy: false,
  };
  const cases = {
    'light-clipping-indicators': {
      field: 'FrameInputs.clipping',
      values: [false, true],
      fixed: { exposure: 1.5 },
    },
    'light-clipping-modifier': {
      field: 'FrameInputs.alt',
      values: [null, { node: '', view: 'clip-high' }],
      fixed: { exposure: 1.5 },
    },
    'detail-mask-preview': {
      field: 'FrameInputs.alt',
      values: [null, { node: 'bench', view: 'mask' }],
      fixed: { sharpenAmount: 110, sharpenMasking: 70 },
    },
    'detail-sharpen-radius': {
      field: 'detail.sharpenRadius',
      values: [.5, 3],
      fixed: { sharpenAmount: 110, sharpenDetail: 50 },
    },
  };
  const selected = config.operations.length ? config.operations : Object.keys(cases);
  if (selected.some((key) => !(key in cases))) throw Error('Unknown viewer tool');
  engine.createViewer('tools', null, false, false, true);
  let sequence = 0, previous = -1;
  try {
    engine.viewerSize('tools', width, height);
    engine.viewerPhotoChanged('tools');
    const operations = [];
    for (const id of selected) {
      const { field, values, fixed } = cases[id];
      const row = { id, featureIds: [id], field, values, fixed, trials: [], status: 'inconclusive' };
      const seen = [new Set(), new Set()];
      let previousPlain = null;
      try {
        for (let i = 0; i < config.samples + 2; i++) {
          const state = i % 2,
            value = values[state],
            recipe = structuredClone(neutral),
            inputs = { ...view, editKey: ++sequence, now: performance.now() };
          if (id.startsWith('light-')) Object.assign(recipe.base, fixed);
          else {
            recipe.grade.nodes[0].tools.detail = { ...detailDefaults, ...fixed };
            inputs.keepNode = recipe.grade.nodes[0].id;
          }
          if (field === 'FrameInputs.clipping') inputs.clipping = value;
          else if (field === 'FrameInputs.alt') inputs.alt = value;
          else recipe.grade.nodes[0].tools.detail.sharpenRadius = value;
          const edit = JSON.stringify(recipe), frameInputs = JSON.stringify(inputs);
          const start = performance.now();
          const info = JSON.parse(engine.viewerFrame('tools', 'fixture', frameInputs, edit, '', ''));
          await engine.idle();
          engine.viewerDone('tools', performance.now());
          const frame = await engine.viewerReadback('tools');
          const ms = performance.now() - start;
          if (
            !frame || frame.seq <= previous || info.provisional || frame.width !== width ||
            frame.height !== height ||
            frame.data.byteLength !== width * height * 4
          ) throw Error('Incomplete viewer output');
          previous = frame.seq;
          const rgb = new Uint8Array(96 * 64 * 3);
          let n = 0, grey = 0, red = 0, blue = 0, black = 0, white = 0;
          for (let y = 0; y < 64; y++) {
            for (let x = 0; x < 96; x++) {
              const offset = 4 *
                (Math.floor((y + .5) * height / 64) * width + Math.floor((x + .5) * width / 96));
              const [r, g, b, a] = frame.data.subarray(offset, offset + 4);
              if (a !== 255 || r === 255 && g === 0 && b === 255) throw Error('Photo coverage failed');
              rgb[n++] = r;
              rgb[n++] = g;
              rgb[n++] = b;
              if (r === g && g === b) grey++;
              if (r >= 250 && g < 6 && b < 6) red++;
              if (r < 6 && g < 6 && b >= 250) blue++;
              if (Math.max(r, g, b) < 6) black++;
              if (Math.min(r, g, b) >= 250) white++;
            }
          }
          const digest = Array.from(
            new Uint8Array(await crypto.subtle.digest('SHA-256', rgb)),
            (v) => v.toString(16).padStart(2, '0'),
          ).join('');
          let clipping;
          if (id === 'light-clipping-indicators') {
            if (state === 0) previousPlain = rgb;
            else {
              const examples = [];
              let changed = 0, inExtremes = 0, changedInBrightRegions = 0;
              for (let p = 0; p < 96 * 64; p++) {
                const before = previousPlain.subarray(3 * p, 3 * p + 3),
                  after = rgb.subarray(3 * p, 3 * p + 3);
                if (before.every((v, channel) => v === after[channel])) continue;
                changed++;
                const bright = Math.max(...before) >= 245, dark = Math.min(...before) <= 10;
                if (bright || dark) inExtremes++;
                if (bright) changedInBrightRegions++;
                if (examples.length < 24) examples.push([p % 96, Math.floor(p / 96), ...before, ...after]);
              }
              clipping = { changed, inExtremes, changedInBrightRegions, examples };
            }
          }
          seen[state].add(digest);
          row.trials.push({
            state,
            value,
            phase: i < 2 ? 'first' : 'warm',
            ms,
            digest,
            verified: true,
            grey,
            red,
            blue,
            black,
            white,
            clipping,
          });
        }
        if (id === 'detail-mask-preview') {
          row.witness =
            'At least 99% of the 6144 source-grid samples are neutral with Option held, with both dark and bright mask regions. Releasing Option restores a predominantly chromatic photo.';
          const maskOK = row.trials.every((t) =>
            t.state ? t.grey >= 0.99 * 6144 && t.black > 16 && t.white > 16 : t.grey < 0.1 * 6144
          );
          if (!maskOK) throw Error('Did not alternate a grayscale sharpening mask with the chromatic photo');
        } else if (!seen.every((set) => set.size === 1) || row.trials[0].digest === row.trials[1].digest) {
          throw Error('Two independently repeatable photographed states were not observed');
        }
        if (id === 'light-clipping-indicators') {
          row.witness =
            'Both states reproduce exact RGB digests. At least eight sampled RGB positions change with clipping, at least 90% of changed positions were near channel clipping in the control frame.';
          if (
            !row.trials.filter((t) => t.state).every(({ clipping: c }) =>
              c.changed >= 8 && c.inExtremes >= .9 * c.changed
            )
          ) {
            throw Error('Clipping did not affect a consistent set of near-clipped source pixels');
          }
        }
        row.status = 'measured';
      } catch (error) {
        row.reason = String(error);
        row.trials.forEach((trial) => trial.verified = false);
      }
      operations.push(row);
      await report({ progress: id + ' ' + row.status + (row.reason ? ' ' + row.reason : '') });
    }
    await report({
      ...metadata,
      protocol: 'lightflow-stock-viewer-tools-v1',
      samples: config.samples,
      pixels: [width, height],
      witnessGrid: [96, 64],
      operations,
    });
  } finally {
    engine.disposeViewer('tools');
  }
}
