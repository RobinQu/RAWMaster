'use strict';

// Display names and signals are shared by the darkroom and the existing 032 workspace.
const RMSceneOutput = (() => {
  const targets = Object.freeze({
    sdr: { title: 'SDR 分享', signal: 'JPEG · 8 位 · sRGB / Rec.709 · 100 nits' },
    hdr: { title: 'HDR 成片', signal: 'AVIF · 10 位 · Rec.2020 / PQ · 参考白 100 nits · 峰值 1000 nits' },
  });
  const defaults = { exposure: 0, mapping: 'balanced', compression: 0 };
  function clean(value) {
    if (value?.intent !== 'hdr') return undefined;
    const n = (v, max) => typeof v === 'number' && Number.isFinite(v) && Math.abs(v) <= max ? v : 0;
    const limit = value.limitEV;
    return { intent: 'hdr', reference: 'scene', route: 'aces2', white: 100, peak: 1000,
      limitEV: typeof limit === 'number' && Number.isFinite(limit) && limit >= 0 && limit <= 3.32 ? limit : 3.32,
      bandEV: Array.from({length:4}, (_, index) => n(value.bandEV?.[index], 0.5)),
      trim: { exposure: n(value.trim?.exposure, 3), mapping: value.trim?.mapping === 'soft' ? 'soft' : 'balanced',
        compression: Math.max(0, n(value.trim?.compression, 100)) },
      film: Object.hasOwn(RMPhotos.filmStocks, value.film ?? '') ? value.film : '' };
  }
  // Fixtures model admission explicitly; the JPEG preview and filename do not prove support.
  function fixtureReason(source) {
    return ['b1', 'm1', 'd1'].includes(source) ? '' : '此样本没有已验证的场景校准。可保留 SDR 编辑，不能生成 HDR 母版。';
  }
  const eligible = (source, value) => fixtureReason(source) ? undefined : clean(value);
  function sdrPreview(recipe, scene = clean(recipe.sceneOutput)) {
    if (!scene) return recipe;
    const {exposure, mapping, compression} = scene.trim;
    return { ...recipe, ev: (recipe.ev ?? 0) + exposure,
      contrast: (recipe.contrast ?? 0) - compression / 3 - (mapping === 'soft' ? 10 : 0),
      filmStock:scene.film, filmEnabled:!!scene.film, filmAmount:100 };
  }
  function files(mode, version, fallback) {
    if (mode === 'sdr') return ['sdr'];
    if (clean(version.sceneOutput)) return mode === 'both' ? ['hdr', 'sdr'] : ['hdr'];
    return fallback ? ['sdr'] : [];
  }
  return { clean, defaults, targets, fixtureReason, eligible, sdrPreview, files };
})();
