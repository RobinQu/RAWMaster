const assert = (value, message) => { if (!value) throw new Error(message); };
const style = element => getComputedStyle(element);
const gap = (a, b) => b.getBoundingClientRect().top - a.getBoundingClientRect().bottom;
const oldTool = S.tool, oldPoints = structuredClone(colorSamplerPoints());
const asset = Studio.asset(Studio.data.work), online = asset.online;
const recipe = JSON.stringify(currentEdit().recipe);
let result;
try {
  S.tool = 'detail'; render();
  const groups = [...document.querySelectorAll('.detail-options > .inspector-text-group')];
  assert(groups.length === 3, 'Three detail groups');
  assert(Math.abs(gap(groups[0].querySelector('label'), groups[0].querySelector('p')) - 7) < 0.1, 'Detail label/description 7px');
  assert(Math.abs(gap(groups[0], groups[1]) - 12) < 0.1, 'Detail groups 12px');
  S.tool = 'basic'; render();
  const correction = document.querySelector('.wb-correction');
  assert(Math.abs(gap(correction.querySelector('.field span'), correction.querySelector('select')) - 7) < 0.1, 'WB label/menu 7px');
  assert(gap(correction, document.querySelector('.wb-refinement')) >= 12, 'WB correction/refinement boundary');
  const scalarRows = [...document.querySelectorAll('.wb-refinement .range')];
  assert(scalarRows.length === 2, 'Temperature and tint rows');
  assert(Math.abs(gap(scalarRows[0], scalarRows[1]) - 6 - 4) < 0.1, '4px scalar gap after the reserved 6px tick strip');
  (Studio.data.colorSamplers ??= {})[Studio.data.work] = []; render();
  assert(!document.querySelector('.sampler-row'), 'Empty sampler list');
  for (let i = 0; i < 9; i++) { actions['sampler-pick'](''); point(10 + i * 8, 30); }
  assert(document.querySelectorAll('.sampler-row').length === 9, 'Nine points');
  assert(document.querySelector('[data-act=sampler-pick]').disabled, 'Limit disables add');
  actions['sampler-pick']('0'); point(55, 40);
  assert(colorSamplerPoints()[0].x === 55 && colorSamplerPoints().length === 9, 'Replace at full capacity');
  refreshSamplerPanel();
  const row = document.querySelector('.sampler-row'), swatch = row.querySelector('.sampler-swatch');
  assert(swatch.getBoundingClientRect().width === 18, '18px colour icon');
  assert(style(row).borderRadius === '5px', 'Shared flat list shape');
  assert(!row.classList.contains('outside'), 'Loaded sample has an actual colour');
  actions['sampler-remove']('8');
  assert(colorSamplerPoints().length === 8 && !document.querySelector('[data-act=sampler-pick]').disabled, 'Delete enables add');
  actions['sampler-pick'](''); actions['cancel-selection']();
  assert(!S.canvasSelection && colorSamplerPoints().length === 8, 'Cancel changes no points');
  asset.online = false; render();
  assert(document.querySelector('[data-act=sampler-pick]').disabled, 'Offline disables add');
  assert(document.querySelectorAll('.sampler-row.outside').length === 8, 'Unavailable image preserves numbered placeholders');
  assert(style(document.querySelector('.sampler-swatch')).borderStyle === 'dashed', 'No fabricated unavailable colour');
  assert(JSON.stringify(currentEdit().recipe) === recipe, 'Sampling does not mutate recipe');
  result = { textGap:7, groupGap:12, samplerLimit:9, colourIcon:18, cases:'empty/add/replace/delete/cancel/offline/recipe unchanged' };
} finally {
  asset.online = online;
  (Studio.data.colorSamplers ??= {})[Studio.data.work] = oldPoints;
  S.canvasSelection = null; S.tool = oldTool; Studio.save(); render();
}
return result;
