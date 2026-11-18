(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory(root, () => require('./shrimp-varieties.js'));
  else root.AquariumPatternShrimpV2 = factory(root, () => root.AquariumShrimpVarieties);
})(typeof globalThis !== 'undefined' ? globalThis : this, function (root, getBase) {
  'use strict';
  const rows = [
    ['black-king-kong', 'Black King Kong', 'king-black', 'caridina-bee', 'black-king-kong-panda-striped-shrimp', 'Taiwan bee trade form'],
    ['red-king-kong', 'Red King Kong', 'king-red', 'caridina-bee', 'red-king-kong-shrimp', 'Taiwan bee trade form'],
    ['blue-bolt', 'Blue Bolt', 'blue-frost', 'caridina-bee', 'blue-bolt-shrimp', 'Taiwan bee trade form'],
    ['tangerine-tiger', 'Tangerine Tiger', 'amber-tiger', 'caridina-bee', 'tangerine-tiger-shrimp', 'Caridina serrata trade identification; generic Caridina routing'],
    ['orange-eye-blue-tiger', 'Orange Eye Blue Tiger', 'blue-tiger', 'caridina-bee', 'orange-eye-blue-tiger', 'Caridina mariae trade identification; generic Caridina routing'],
    ['black-pinto', 'Black Pinto', 'pinto-black', 'caridina-bee', 'white-back-pinto-shrimp', 'Pinto Caridina trade form'],
    ['red-pinto', 'Red Pinto', 'pinto-red', 'caridina-bee', 'red-pinto-shrimp-mix', 'Pinto Caridina trade form'],
    ['red-galaxy-pinto', 'Red Galaxy Pinto', 'galaxy-red', 'caridina-bee', 'red-galaxy-pinto', 'Galaxy Pinto Caridina trade form'],
    ['golden-bee', 'Golden Bee', 'gold-speckled', 'caridina-bee', 'golden-bee-shrimp', 'Golden bee Caridina trade form'],
    ['snowball', 'Snowball', 'milky-clear', 'neocaridina', 'snow-ball-shrimp', 'White Pearl Neocaridina trade form; palmata/older cf. zhangjiajiensis labels'],
    ['chocolate-black-rose', 'Chocolate / Black Rose', 'bronze-dark', 'neocaridina', 'chocolate-shrimp', 'Neocaridina davidi dark trade form'],
    ['black-rili', 'Black Rili', 'black-clear', 'neocaridina', 'black-rili-shrimp', 'Neocaridina davidi rili trade form']
  ];
  const variants = Object.freeze(rows.map(r => r[0])), stages = Object.freeze(['adult', 'berried', 'juvenile']);
  function freezeTree(value) { if (value && typeof value === 'object') { for (const item of Object.values(value)) freezeTree(item); Object.freeze(value); } return value; }
  const anatomyByStage = freezeTree(Object.fromEntries(stages.map(stage => [stage, anatomy(stage)])));
  const descriptors = Object.freeze(Object.fromEntries(rows.map(([key, label, pattern, biologicalGroup, handle, taxonNote]) => [key, Object.freeze({
    label, pattern, biologicalGroup, taxonNote, source: 'https://buceplant.com/products/' + handle,
    anatomy: anatomyByStage,
    paletteKey: key, eyeColor: key === 'orange-eye-blue-tiger' ? '#ffa74f' : '#172c2b',
    ecologyPolicy: biologicalGroup === 'caridina-bee' ? 'unsupported-caridina' : 'parent-owned-neocaridina',
    spawningSimulated: false
  })])));
  const shadeKeys = ['h', 'm', 'r', 's', 'd', 'c'];
  const palette = values => Object.freeze(Object.fromEntries(shadeKeys.map((k, i) => [k, values[i]])));
  const palettes = {
    black: palette(['#7e857a', '#48544f', '#2e3d37', '#26332e', '#1b2926', '#55675c']),
    red: palette(['#efa17e', '#cd5945', '#b63630', '#91332d', '#6e292a', '#d57559']),
    blue: palette(['#8ec0ce', '#468caa', '#2a7597', '#28566c', '#213d50', '#649bae']),
    amber: palette(['#efc17d', '#dca347', '#d28d34', '#b17a32', '#886430', '#ddb064']),
    bronze: palette(['#926b55', '#644438', '#49372f', '#342c28', '#282827', '#73523f']),
    ivory: palette(['#f7efd8', '#ede8d2', '#dce0ca', '#b8c6b2', '#97ac9a', '#e1e5d0']),
    frost: palette(['#e7efdf', '#cedfd7', '#bdd8d3', '#b0c8c3', '#7b9fa6', '#d4e3d7']),
    gold: palette(['#f4e3b3', '#e6cf9c', '#d8ba7f', '#baa071', '#9a8863', '#e4d0a0']),
    clear: palette(['#e0e3d7', '#cbd4c3', '#c2cfbb', '#92a58f', '#7c927f', '#c1d0bd']),
    tiger: palette(['#7e7958', '#665b3e', '#564a32', '#453e2e', '#36372b', '#746b4b'])
  };
  const alpha = { dense: { h: .99, m: .97, r: .96, s: .98, d: 1, c: .91 }, tiger: { h: .84, m: .68, r: .57, s: .76, d: .85, c: .49 }, clear: { h: .65, m: .28, r: .18, s: .42, d: .52, c: .20 }, snow: { h: .74, m: .44, r: .31, s: .48, d: .58, c: .32 }, gold: { h: .98, m: .92, r: .88, s: .93, d: .96, c: .84 } };
  const profiles = {
    'black-king-kong': ['black', 'dense', '#bfc3a9', .68], 'red-king-kong': ['red', 'dense', '#d5c0a0', .70],
    'blue-bolt': ['blue', 'dense', '#bbd2c8', .67], 'tangerine-tiger': ['amber', 'tiger', '#d3bb82', .59],
    'orange-eye-blue-tiger': ['blue', 'tiger', '#87b2bc', .63], 'black-pinto': ['black', 'dense', '#cbd0b7', .72],
    'red-pinto': ['red', 'dense', '#dbc7a5', .70], 'red-galaxy-pinto': ['red', 'dense', '#ded0b5', .72],
    'golden-bee': ['gold', 'gold', '#ded4ae', .67], snowball: ['ivory', 'snow', '#d2ddcf', .52],
    'chocolate-black-rose': ['bronze', 'dense', '#927b60', .62], 'black-rili': ['black', 'dense', '#aebaa5', .66]
  };
  const rawBase = { h: '#74b1c6', m: '#2e78ad', r: '#205f9a', s: '#1c466f', d: '#18374d', c: '#528baf', limb: '#6c9da9', far: '#547c87', antenna: '#adc9c6' };
  const channels = hex => hex.slice(1).match(/../g).map(v => parseInt(v, 16));
  const hexColor = values => '#' + values.map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('');
  const youngBase = hex => hexColor(channels(hex).map((v, i) => v * .67 + [180, 192, 163][i] * .33));
  const sourceRoles = new Map();
  for (const [role, hex] of Object.entries(rawBase)) { sourceRoles.set(hex, role); sourceRoles.set(youngBase(hex), role); }
  for (const [hex, role] of [['#5b9fbd', 'h'], ['#488ba9', 'm'], ['#172c2b', 'eye'], ['#91944c', 'egg'], ['#c2bf73', 'egg-light'], ['#6e7942', 'egg-dark']]) sourceRoles.set(hex, role);
  function anatomy(stage) {
    const young = stage === 'juvenile', core = young ? [11, 8, 23, 13] : [7, 5, 26, 14];
    return { canvas: { width: 34, height: 20 }, anchor: [17, 16],
      measurement: { basis: 'rostrum-to-tail; antennae excluded', axis: 'x', endpoints: young ? [[8, 10.5], [27, 8.5]] : [[2, 10.5], [30, 6.5]], pixels: young ? 19 : 28 },
      core: { minX: core[0], minY: core[1], maxX: core[2], maxY: core[3] },
      landmarks: { mouth: young ? [22.5, 12.5] : [25.5, 11.5], vent: young ? [11.5, 11.5] : [7.5, 11.5], foot: young ? [19, 17] : [20, 18], bodyCenter: [(core[0] + core[2]) / 2, (core[1] + core[3]) / 2] } };
  }
  function region(key, x, y) {
    const band = (center, width = .72, slope = .18) => Math.abs(x - (center + slope * (y - 8))) <= width;
    switch (key) {
      case 'black-king-kong': return x < 7 || band(9.3, .75) || band(15, 1.25, .08) || (x >= 23 && y <= 8) ? 'ivory' : 'base';
      case 'red-king-kong': return x < 7 || (x <= 17.1 && !band(10.5, .7, .12)) || (x >= 24 && y <= 9) ? 'ivory' : 'base';
      case 'blue-bolt': return x <= 12.4 || (y <= 6.4 && x <= 18) || (x < 19 && (Math.round(x) * 7 + Math.round(y) * 3) % 9 < 2) ? 'frost' : 'base';
      case 'tangerine-tiger': return y >= 7.3 && (band(10, .5, .3) || band(14, .65, .2) || band(18, .55, -.15) || (x > 21 && (Math.round(x) + Math.round(y) * 3) % 7 === 0)) ? 'tiger' : 'base';
      case 'orange-eye-blue-tiger': return band(9, .6, .3) || band(13.6, .8, .25) || band(17.5, .8, -.2) || (x > 20 && y >= 8 && (Math.round(x) * 2 + Math.round(y)) % 6 < 2) ? 'black' : x < 7 ? 'frost' : 'base';
      case 'black-pinto': return x < 7 || (x < 19 && (band(9, .9, -.3) || band(13.3, 1, .18) || band(17.8, .8, -.2))) || (x >= 19 && ((y <= 7.4 && x < 22) || (y >= 9 && y <= 10 && x >= 22) || (x >= 24 && y >= 11))) ? 'ivory' : 'base';
      case 'red-pinto': return x < 7 || (x < 18.5 && (y <= 7.2 || band(10.8, 1.1, .1) || band(15.4, .9, -.25))) || (x >= 19 && x <= 21 && y >= 9.5) || (x >= 23 && y <= 8) ? 'ivory' : 'base';
      case 'red-galaxy-pinto': return x < 7 || (x < 18.5 && (band(9.5, .9, .2) || band(13.2, .75, -.25) || band(16.4, .75, .15))) || (x >= 19 && ((Math.round(x) * 3 + Math.round(y) * 5) % 8 <= 1 || (x >= 23 && y <= 6.5))) ? 'ivory' : 'base';
      case 'golden-bee': return y <= 6.3 || (Math.round(x) * 3 + Math.round(y) * 7) % 11 < 3 ? 'ivory' : 'base';
      case 'snowball': return x >= 18 && x <= 21 && y <= 7.5 ? 'saddle' : 'base';
      case 'chocolate-black-rose': return (y <= 6.4 && x <= 19) || (band(12, .3, .25) && y <= 9) ? 'gold-brown' : 'base';
      case 'black-rili': return x >= (y <= 6 ? 12 : 11) && x <= (y >= 10 ? 18 : 19) ? 'clear' : 'base';
      default: return 'base';
    }
  }
  function createSprite(kind = 'shrimp', phase = 0, preset = 'daylight', variant = 'black-king-kong', options = {}) {
    if (kind !== 'shrimp' || !Number.isFinite(phase) || !Object.prototype.hasOwnProperty.call(descriptors, variant)) throw new RangeError('Expected shrimp, finite phase and a supported pattern variant.');
    const stage = options.stage === undefined ? 'adult' : options.stage;
    if (!stages.includes(stage)) throw new RangeError('Stage must be adult, berried or juvenile.');
    const base = getBase(); if (typeof base?.createSprite !== 'function') throw new Error('Load AquariumShrimpVarieties before AquariumPatternShrimpV2.');
    const descriptor = descriptors[variant], profile = profiles[variant], young = stage === 'juvenile';
    const canvas = options.createCanvas ? options.createCanvas(34, 20) : root.document?.createElement('canvas');
    if (!canvas?.getContext) throw new TypeError('A canvas factory is required outside a browser.');
    canvas.width = 34; canvas.height = 20;
    const context = canvas.getContext('2d'); if (!context) throw new TypeError('A 2d canvas context is required.');
    const gains = preset === 'warm' ? [1.08, .94, .79] : preset === 'moonlight' ? [.48, .65, .89] : [1, 1, 1], cache = new Map();
    function tint(hex, pale = false) {
      const key = hex + '/' + pale;
      if (!cache.has(key)) {
        const c = channels(hex).map((v, i) => pale ? Math.round(v * .77 + [190, 199, 178][i] * .23) : v);
        cache.set(key, hexColor(c.map((v, i) => v * gains[i])));
      }
      return cache.get(key);
    }
    function sample(role, x, y, sourceAlpha) {
      if (role === 'eye') return [descriptor.eyeColor, 1, false];
      if (role.startsWith('egg')) {
        const eggs = variant === 'snowball' ? ['#e8eddb', '#ffffed', '#b8c9b3'] : descriptor.biologicalGroup === 'caridina-bee' ? ['#918662', '#c3b993', '#666a4f'] : ['#91944c', '#c2bf73', '#6e7942'];
        return [eggs[role === 'egg' ? 0 : role === 'egg-light' ? 1 : 2], sourceAlpha, false];
      }
      if (['limb', 'far', 'antenna'].includes(role)) {
        const c = role === 'far' ? palettes[profile[0]].s : role === 'antenna' ? palettes.ivory.s : profile[2];
        return [c, Math.min(.9, sourceAlpha * profile[3] / .68), young];
      }
      const virtualX = young ? 7 + (x - 11) * 19 / 12 : x, virtualY = young ? 5 + (y - 8) * 2 : y;
      const area = region(variant, virtualX, virtualY);
      let colors = palettes[profile[0]], opacity = alpha[profile[1]][role];
      if (area === 'clear') { colors = palettes.clear; opacity = alpha.clear[role]; }
      else if (area === 'saddle') { colors = palettes.ivory; opacity = .78; }
      else if (area === 'gold-brown') { colors = palettes.bronze; role = role === 'd' ? 's' : 'h'; opacity = .96; }
      else if (area !== 'base') { colors = palettes[area]; opacity = area === 'tiger' || area === 'black' ? .93 : .99; }
      return [colors[role], opacity * (young ? .80 : 1), young];
    }
    let fillStyle = '#000000', globalAlpha = 1;
    const proxyContext = {
      get fillStyle() { return fillStyle; }, set fillStyle(value) { fillStyle = value.toLowerCase(); },
      get globalAlpha() { return globalAlpha; }, set globalAlpha(value) { globalAlpha = value; context.globalAlpha = 1; },
      get imageSmoothingEnabled() { return context.imageSmoothingEnabled; }, set imageSmoothingEnabled(value) { context.imageSmoothingEnabled = value; },
      clearRect(x, y, w, h) { context.clearRect(x, y, w, h); },
      fillRect(x, y, w, h) {
        const role = sourceRoles.get(fillStyle);
        if (!role) throw new Error('Unrecognized approved shrimp draw color: ' + fillStyle);
        for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) {
          const [color, opacity, pale] = sample(role, xx, yy, globalAlpha);
          context.fillStyle = tint(color, pale); context.globalAlpha = opacity; context.fillRect(xx, yy, 1, 1);
        }
        context.globalAlpha = 1;
      }
    };
    const proxyCanvas = {
      get width() { return canvas.width; }, set width(v) { canvas.width = v; },
      get height() { return canvas.height; }, set height(v) { canvas.height = v; },
      getContext(type) { return type === '2d' ? proxyContext : null; }
    };
    let frame;
    try { frame = base.createSprite('shrimp', phase, 'daylight', 'blue-dream', { stage, createCanvas: () => proxyCanvas }); }
    catch (error) { context.clearRect(0, 0, canvas.width, canvas.height); canvas.width = canvas.height = 0; throw error; }
    return { ...frame, canvas, variant, paletteKey: variant, label: descriptor.label, biologicalGroup: descriptor.biologicalGroup,
      identity: descriptor.biologicalGroup === 'caridina-bee' ? 'crystal-shrimp' : 'neocaridina-color', anatomy: anatomy(stage),
      lifecycle: { development: 'direct-development', juvenileRepresents: 'juvenile', spawningSimulated: false,
        ecologyPolicy: descriptor.ecologyPolicy, offspringPaletteKey: variant, inheritance: 'display-key-only; no genetic or spawning rules' } };
  }
  return { createSprite, variants, stages, descriptors };
});
