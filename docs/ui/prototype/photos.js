'use strict';

// Only these repository fixtures can travel between the workbench and Spec 032.
const RMPhotos = (() => {
  const base = 'Tests/RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/';
  const sets = {
    river: ['dji187-context376', 'DJI Mavic 3', '24 mm', 'ƒ/2.8', '1/500 s', 100, 6000, 3375],
    bird: ['burst48-context72', 'Sony α7 IV', '400 mm', 'ƒ/6.3', '1/1600 s', 400, 6000, 4000],
    woods: ['burst193-context217', 'Sony α7 IV', '45 mm', 'ƒ/5.6', '1/250 s', 200, 6000, 4000],
    plain: ['burst14-context38', 'Sony α7 IV', '200 mm', 'ƒ/8', '1/640 s', 320, 6000, 4000],
    mirror: ['burst123', 'Sony α7 IV', '50 mm', 'ƒ/4', '1/320 s', 100, 4000, 6000],
    dusk: ['interval427-context439', 'Sony α7 IV', '24 mm', 'ƒ/8', '1/100 s', 200, 6000, 4000],
  };
  const rows = [
    ['r1', 'DJI_0348.DNG', '日落河湾', 'river', 0],
    ['w1', 'DSC_0713.JPG', '秋日山坡', 'woods', 0],
    ['b1', 'DSC_0712.ARW', '岸边的水鸟', 'bird', 0],
    ['m1', 'DSC_0804.ARW', '镜湖人像', 'mirror', 61],
    ['p1', 'DSC_0621.ARW', '草原迁徙', 'plain', 19],
    ['w2', 'DSC_0738.ARW', '溪流与岩石', 'woods', 25],
    ['d1', 'DSC_0901.ARW', '暮色初临', 'dusk', 25],
    ['b2', 'DSC_0717.ARW', '掠过水面', 'bird', 5],
    ['r2', 'DJI_0349.DNG', '河湾余晖', 'river', 188],
    ['w3', 'DSC_0718.ARW', '林间溪水', 'woods', 5],
    ['d2', 'DSC_0912.ARW', '蓝调时刻', 'dusk', 219],
    ['d3', 'DSC_0924.ARW', '最后一线光', 'dusk', 438],
    ['i1', 'DSC_0805.ARW', '镜湖连拍一', 'mirror', 5],
    ['i2', 'DSC_0806.ARW', '镜湖连拍二', 'mirror', 25],
    ['i3', 'DSC_0807.ARW', '镜湖连拍三', 'mirror', 122],
    ['n1', 'DJI_0350.DNG', '河谷航拍一', 'river', 5],
    ['n2', 'DJI_0351.DNG', '河谷航拍二', 'river', 25],
    ['n3', 'DJI_0352.DNG', '河谷航拍三', 'river', 375],
  ];
  const photos = Object.fromEntries(
    rows.map(([id, name, scene, series, frame], i) => {
      const [image, camera, focal, aperture, shutter, iso, w, h] = sets[series];
      const date = ['woods', 'bird', 'mirror'].includes(series) ? '2026-10-18' : '2026-10-17';
      const clock = {
        river: '18:24',
        woods: '14:32',
        bird: '09:46',
        mirror: '12:08',
        plain: '11:25',
        dusk: '18:58',
      }[series];
      return [
        id,
        {
          id,
          name,
          scene,
          image,
          series,
          frame,
          w,
          h,
          date,
          clock: clock + ':' + String((i * 3) % 60).padStart(2, '0'),
          gps: series === 'river',
          rights: true,
          exif: { camera, focal, aperture, shutter, iso: 'ISO ' + iso, date },
        },
      ];
    }),
  );
  const file = (photo) => photo.image + '/files/asset' + String(photo.frame ?? 0).padStart(4, '0') + '.jpg';
  const url = (photo) => '../../../' + base + file(photo);

  function readHandoff(fragment) {
    try {
      const payload = JSON.parse(new URLSearchParams(fragment.slice(1)).get('selection'));
      if (!Array.isArray(payload?.items) || !payload.items.length) return null;
      const seen = new Set();
      const result = [];
      for (const item of payload.items) {
        const source = item.source || item.id;
        const p = Object.hasOwn(photos, source) && photos[source];
        if (!p || typeof item.id !== 'string' || seen.has(item.id)) continue;
        seen.add(item.id);
        const versions = (Array.isArray(item.versions) ? item.versions : [])
          .filter(
            (v) =>
              typeof v.label === 'string' &&
              v.label.length <= 100 &&
              Number.isInteger(v.w) &&
              v.w > 0 &&
              v.w <= 100000 &&
              Number.isInteger(v.h) &&
              v.h > 0 &&
              v.h <= 100000,
          )
          .map((v, index) => ({
            id: typeof v.id === 'string' ? v.id.slice(0, 100) : String(index),
            label: v.label,
            w: v.w,
            h: v.h,
            archive: v.archive === true,
            look: cleanLook(v.look),
          }));
        if (!versions.length) versions.push({ label: '原始版本', w: p.w, h: p.h });
        result.push({
          ...p,
          id: item.id,
          name: typeof item.name === 'string' ? item.name.slice(0, 100) : p.name,
          date: p.date.replaceAll('-', ''),
          online: item.online === true,
          versions,
          choice: 0,
        });
      }
      return result.length
        ? {
            photos: result,
            source: String(payload.source || '资料库所选').slice(0, 100),
            mode: payload.mode === 'original' ? 'original' : 'render',
          }
        : null;
    } catch {
      return null;
    }
  }

  // A bounded set of display-only operations is shared with the export canvas.
  function cleanLook(input = {}) {
    const bounded = (key, low, high, fallback) =>
      typeof input?.[key] === 'number' && Number.isFinite(input[key])
        ? Math.min(high, Math.max(low, input[key]))
        : fallback;
    return {
      ev: bounded('ev', -3, 3, 0),
      contrast: bounded('contrast', -100, 100, 0),
      sat: bounded('sat', -100, 100, 0),
      warmth: bounded('warmth', -100, 100, 0),
      mono: input?.mono === true,
    };
  }
  function filter(input) {
    const p = cleanLook(input);
    return `brightness(${Math.pow(2, p.ev * 0.55)}) contrast(${1 + p.contrast * 0.006}) saturate(${p.mono ? 0 : 1 + p.sat * 0.01}) sepia(${Math.max(0, p.warmth) * 0.004}) hue-rotate(${Math.min(0, p.warmth) * 0.13}deg)`;
  }
  const filmStocks = {
    daylight: { name: 'Portra 400 / Endura', contrast: -16, sat: -19, warmth: 56 },
    chrome: { name: 'Velvia 100', contrast: 30, sat: 28, warmth: -68 },
    cinema: { name: 'VISION3 250D / 2383', contrast: 18, sat: -14, warmth: 23 },
  };
  function displayLook(r) {
    const film = Object.hasOwn(filmStocks, r.filmStock) ? filmStocks[r.filmStock] : null;
    const amount = film ? (r.filmAmount ?? 100) / 100 : 0;
    const enabled = (group) => r.sectionEnabled?.[group] !== false;
    const n = (key, group) => enabled(group) ? Number(r[key]) || 0 : 0;
    const light = (key) => n(key, 'light');
    return cleanLook({
      ev:
        light('ev') + (light('high') + light('shadow') + light('white') + light('black') + n('levels', 'levels') + n('luminance', 'mix')) * 0.002,
      contrast:
        light('contrast') +
        (n('curveHigh', 'curves') - n('curveLow', 'curves') + n('dehaze', 'dehaze') + n('clarity', 'clarity') + n('definition', 'definition') + n('texture', 'detail')) * 0.22 +
        n('sharp', 'detail') * 0.1 +
        (film?.contrast ?? 0) * amount,
      sat:
        (100 + n('sat', 'color') + n('vibrance', 'color') * 0.4 + (r.profile === '相机鲜艳' ? 15 : 0)) *
          (1 + ((film?.sat ?? 0) * amount) / 100) -
        100,
      warmth:
        n('warmth', 'whiteBalance') +
        (film?.warmth ?? 0) * amount +
        (n('warmHighlights', 'grading') - n('coolShadows', 'grading') + n('balance', 'grading')) * 0.35 +
        (enabled('lut') ? r.lut === '柔和胶片' ? 25 : r.lut === '冷调' ? -25 : 0 : 0),
      mono: r.mono,
    });
  }
  return { photos, file, url, readHandoff, cleanLook, displayLook, filter, filmStocks };
})();
