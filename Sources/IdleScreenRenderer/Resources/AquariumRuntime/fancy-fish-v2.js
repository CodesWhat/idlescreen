(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./fish-varieties.js'), root);
  else root.AquariumFancyFishV2 = factory(root.AquariumFishVarieties, root);
})(typeof globalThis === 'object' ? globalThis : this, function (base, root) {
  'use strict';
  if (!base || typeof base.rasterize !== 'function') throw new Error('Load fish-varieties.js before fancy-fish-v2.js.');

  const variants = Object.freeze({
    guppy: Object.freeze(['guppy-double-sword', 'guppy-dumbo-redtail', 'guppy-metal-lace', 'guppy-full-gold']),
    medaka: Object.freeze(['medaka-white-galaxy-longfin', 'medaka-tricolor'])
  });
  const stages = base.stages;
  const gains = { daylight: [1, 1, 1], warm: [1.08, .94, .79], moonlight: [.48, .65, .89] };
  const forms = {
    'guppy-double-sword': { kind: 'guppy', form: 'Paired caudal swords with a short translucent central fan', source: 'https://buceplant.com/products/japan-blue-double-sword-guppies-breeding-pair', body: [103, 151, 169], fin: '#668fa0', ray: '#bbbf87', shade: '#426578' },
    'guppy-dumbo-redtail': { kind: 'guppy', form: 'Rounded red fan and enlarged blue pectoral fins', source: 'https://buceplant.com/products/dumbo-redtail-guppies', body: [108, 153, 169], fin: '#bf5947', ray: '#e39768', shade: '#7b4442' },
    'guppy-metal-lace': { kind: 'guppy', form: 'Wide scalloped delta tail, trailing dorsal and sparse lace marks', source: 'https://buceplant.com/products/green-metal-lace-guppies', body: [99, 155, 146], fin: '#6cafa2', ray: '#b2c4a0', shade: '#38585c' },
    'guppy-full-gold': { kind: 'guppy', form: 'Compact rounded gold fan with long ventral rays', source: 'https://buceplant.com/products/full-gold-guppies', body: [199, 183, 105], fin: '#baac68', ray: '#e4d7a0', shade: '#867f55' },
    'medaka-white-galaxy-longfin': { kind: 'medaka', form: 'Pearly flecks and extended caudal, dorsal and anal rays', source: 'https://buceplant.com/products/white-galaxy-long-fin-medaka-rice-fish', body: [190, 204, 207], fin: '#a0bfc0', ray: '#e0e5d4', shade: '#6c949e' },
    'medaka-tricolor': { kind: 'medaka', form: 'Short rounded ray fins and separate white, orange and charcoal patches', source: 'https://buceplant.com/products/lame-tricolor-medaka-rice-fish', body: [198, 203, 185], fin: '#a8b4a2', ray: '#d4d4b8', shade: '#879b94' }
  };
  const clone = value => JSON.parse(JSON.stringify(value));
  function freeze(value) { for (const child of Object.values(value)) if (child && typeof child === 'object') freeze(child); return Object.freeze(value); }

  function settings(kind, phase, preset, color, options) {
    if (Object.hasOwn(forms, kind)) { color ??= kind; kind = forms[kind].kind; }
    if (!Object.hasOwn(variants, kind)) throw new RangeError('Fancy fish kind must be guppy or medaka.');
    color ??= variants[kind][0];
    if (!variants[kind].includes(color)) throw new RangeError('Fancy fish key does not belong to this species.');
    if (!Number.isFinite(phase)) throw new RangeError('Fish phase must be finite.');
    if (!Object.hasOwn(gains, preset)) throw new RangeError('Unsupported fish lighting preset.');
    if (!options || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Fish options must be an object.');
    const stage = options.stage === undefined ? 'adult' : options.stage;
    if (!stages[kind].includes(stage)) throw new RangeError('Unsupported fish lifecycle stage.');
    return { kind, color, stage, pose: ((Math.floor(phase) % 4) + 4) % 4 };
  }

  function painter(width, height, dx, dy) {
    const pixels = new Uint8ClampedArray(width * height * 4), colors = new Map();
    function dot(x, y, color, alpha = 1) {
      x += dx; y += dy;
      if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || y < 0 || x >= width || y >= height) throw new RangeError('Fancy fin escaped its canvas.');
      let rgb = colors.get(color);
      if (!rgb) { rgb = [1, 3, 5].map(n => parseInt(color.slice(n, n + 2), 16)); colors.set(color, rgb); }
      pixels.set([...rgb, Math.round(alpha * 255)], (y * width + x) * 4);
    }
    function line(points, color, alpha = 1) {
      for (let n = 1; n < points.length; n++) {
        let [x, y] = points[n - 1]; const [endX, endY] = points[n];
        const ax = Math.abs(endX - x), ay = -Math.abs(endY - y), sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
        let error = ax + ay;
        for (;;) {
          dot(x, y, color, alpha); if (x === endX && y === endY) break;
          const twice = 2 * error;
          if (twice >= ay) { error += ay; x += sx; }
          if (twice <= ax) { error += ax; y += sy; }
        }
      }
    }
    function polygon(points, color, alpha) {
      const top = Math.min(...points.map(p => p[1])), bottom = Math.max(...points.map(p => p[1]));
      for (let y = top; y < bottom; y++) {
        const crossings = [];
        for (let i = 0; i < points.length; i++) {
          const a = points[i], b = points[(i + 1) % points.length], cy = y + .5;
          if ((a[1] <= cy && b[1] > cy) || (b[1] <= cy && a[1] > cy)) crossings.push(a[0] + (cy - a[1]) * (b[0] - a[0]) / (b[1] - a[1]));
        }
        crossings.sort((a, b) => a - b);
        for (let i = 0; i + 1 < crossings.length; i += 2) for (let x = Math.ceil(crossings[i] - .5); x < Math.ceil(crossings[i + 1] - .5); x++) dot(x, y, color, alpha);
      }
    }
    return { pixels, dot, line, polygon };
  }

  function guppyFins(p, key, pose, palette) {
    const fold = [0, 1, 2, 1][pose], lift = [0, -1, 0, 1][pose], beat = pose % 2;
    const { line, polygon, dot } = p, { fin, ray, shade } = palette;
    if (key === 'guppy-double-sword') {
      polygon([[14, 11], [8, 9], [7 + fold, 11], [7 + fold, 14], [10, 15], [14, 13]], fin, .33);
      polygon([[14, 11], [9, 8], [-3 + fold, 5 + lift], [3 + fold, 8 + lift], [10, 11]], fin, .68);
      polygon([[14, 12], [10, 14], [-2 + fold, 21 + lift], [5 + fold, 18 + lift], [11, 15]], fin, .70);
      line([[-3 + fold, 5 + lift], [6, 8], [14, 11]], ray, .76);
      line([[-2 + fold, 21 + lift], [7, 17], [14, 12]], '#a6c6bf', .72);
      line([[8 + fold, 12], [14, 12]], shade, .44);
      polygon([[24, 9], [20, 5 + beat], [13, 5 + beat], [17, 8], [20, 10]], fin, .51);
      line([[14, 5 + beat], [20, 7], [24, 9]], ray, .62);
    } else if (key === 'guppy-dumbo-redtail') {
      polygon([[14, 11], [10, 8], [7, 4 + lift], [3 + fold, 3 + lift], [1 + fold, 6 + lift], [fold, 11 + lift],
        [1 + fold, 17 + lift], [4 + fold, 21 + lift], [7, 22 + lift], [11, 17], [14, 13]], fin, .76);
      for (const y of [5, 9, 14, 18, 21]) line([[3 + fold, y + lift], [8, Math.round((y + 12) / 2)], [14, 12]], y % 2 ? ray : shade, .64);
      polygon([[24, 9], [21, 3 + beat], [15, 3 + beat], [12, 7], [19, 10]], fin, .69);
      line([[16, 4 + beat], [21, 7], [24, 9]], ray, .74);
    } else if (key === 'guppy-metal-lace') {
      polygon([[14, 11], [9, 7], [2 + fold, 2 + lift], [fold, 4 + lift], [1 + fold, 8 + lift], [fold, 11 + lift],
        [1 + fold, 15 + lift], [fold, 20 + lift], [3 + fold, 23 + lift], [8, 19], [14, 13]], fin, .64);
      for (const y of [4, 8, 12, 17, 21]) line([[2 + fold, y + lift], [9, Math.round((y + 12) / 2)], [14, 12]], ray, .59);
      for (let y = 5; y < 21; y += 3) for (let x = 2 + fold; x < 10; x += 3) {
        const index = ((y + lift + 4) * 48 + x + 6) * 4;
        if (p.pixels[index + 3] > 0) dot(x, y + lift, shade, .72);
      }
      polygon([[25, 9], [21, 5 + beat], [15, 3 + beat], [11, 4 + beat], [15, 7], [20, 10]], fin, .54);
      line([[12, 4 + beat], [19, 7], [25, 9]], ray, .73);
      line([[15, 4 + beat], [18, 6]], shade, .66);
    } else {
      polygon([[14, 11], [10, 8], [6 + fold, 6 + lift], [3 + fold, 8 + lift], [2 + fold, 12 + lift], [4 + fold, 17 + lift],
        [7 + fold, 19 + lift], [11, 16], [14, 13]], fin, .56);
      for (const y of [8, 12, 17]) line([[4 + fold, y + lift], [10, Math.round((y + 12) / 2)], [14, 12]], ray, .74);
      polygon([[24, 9], [22, 5 + beat], [18, 4 + beat], [15, 6 + beat], [20, 10]], fin, .50);
      line([[18, 5 + beat], [21, 7], [24, 9]], ray, .76);
      polygon([[28, 14], [26, 17], [20 + beat, 23], [24, 20], [30, 14]], fin, .32);
      line([[28, 14], [25, 19], [19 + beat, 24]], ray, .62);
      line([[30, 14], [28, 19], [24 + beat, 23]], '#cbd4b2', .52);
    }
    line([[27, 14], [24, 16 - beat], [21, 17 - beat]], shade, .60);
    line([[29, 14], [27 + beat, 16]], ray, .57);
  }

  function medakaFins(p, key, pose, palette, stage) {
    const fold = [0, 1, 2, 1][pose], lift = [0, -1, 0, 1][pose], beat = pose % 2;
    const { polygon, line } = p, { fin, ray, shade } = palette;
    if (key === 'medaka-white-galaxy-longfin') {
      polygon([[9, 11], [6, 9], [-2 + fold, 5 + lift], [-3 + fold, 8 + lift], [-2 + fold, 12 + lift], [-3 + fold, 17 + lift], [-1 + fold, 19 + lift], [6, 14], [9, 12]], fin, .29);
      for (const y of [6, 10, 15, 18]) line([[-2 + fold, y + lift], [4, Math.round((y + 12) / 2)], [9, 12]], y % 2 ? shade : ray, .57);
      polygon([[18, 10], [17, 5 + beat], [11, 2 + beat], [9 + beat, 4], [13, 10]], fin, .32);
      line([[10 + beat, 3], [15, 6], [17, 10]], ray, .64);
      const trailing = stage === 'egg-carrying' ? 20 : 23;
      polygon([[13, 13], [10, 18], [9 + beat, trailing], [15, trailing - 2], [22, 14]], fin, .26);
      line([[14, 13], [12, 19], [9 + beat, trailing]], ray, .56);
      line([[21, 14], [17, 19], [14 + beat, trailing - 1]], shade, .52);
      line([[25, 13], [23, 18], [20 + beat, 20]], ray, .46);
    } else {
      polygon([[9, 11], [6, 9], [3 + fold, 8 + lift], [2 + fold, 10 + lift], [2 + fold, 14 + lift], [4 + fold, 16 + lift], [7, 14], [9, 12]], fin, .30);
      for (const y of [9, 12, 15]) line([[3 + fold, y + lift], [7, 12], [9, 12]], ray, .53);
      polygon([[12, 10], [14, 7 + beat], [17, 7 + beat], [19, 10]], fin, .36);
      line([[14, 8 + beat], [16, 10]], ray, .59);
      polygon([[13, 13], [15, 17 - beat], [19, stage === 'egg-carrying' ? 16 : 18 - beat], [23, 14]], fin, .30);
      line([[14, 13], [16, 17 - beat], [19, 16]], shade, .48);
      line([[25, 13], [23, 16 - beat]], ray, .43);
    }
  }

  function bodyColor(rgb, x, key, stage) {
    if (Math.max(...rgb) < 95) return rgb;
    let target = forms[key].body;
    if (key === 'guppy-double-sword' && x >= 27) target = [187, 173, 124];
    if (key === 'guppy-dumbo-redtail' && x < 25) target = [67, 87, 99];
    const luminance = rgb[0] * .3 + rgb[1] * .5 + rgb[2] * .2;
    const strength = stage === 'fry' ? .20 : stage === 'female' || stage === 'gravid' ? .48 : .82;
    return rgb.map((c, i) => Math.max(0, Math.min(255, Math.round(c * (1 - strength) + (target[i] + (luminance - 165) * .7) * strength))));
  }

  function draw(s) {
    const { kind, color: key, stage, pose } = s, fry = stage === 'fry', female = stage === 'female' || stage === 'gravid';
    const original = base.rasterize(kind, pose, 'daylight', kind === 'guppy' ? 'blue' : 'white', { stage });
    const width = fry ? 22 : 48, height = fry ? 14 : 32, dx = fry ? 0 : female ? 2 : 6, dy = fry ? 0 : female ? 2 : 4;
    const p = painter(width, height, dx, dy), palette = forms[key], beat = pose % 2;
    if (!fry && !female) {
      if (kind === 'guppy') guppyFins(p, key, pose, palette);
      else medakaFins(p, key, pose, palette, stage);
    }
    const trunk = kind === 'guppy'
      ? [[27, 8, 7], [22, 9, 14], [17, 10, 20], [14, 11, 24], [14, 12, 24], [17, 13, 19], [22, 14, 12], [25, 15, 6]]
      : [[21, 9, 14], [14, 10, 23], [9, 11, 29], [9, 12, 29], [13, 13, 23], [21, 14, 11]];
    for (let y = 0; y < original.height; y++) for (let x = 0; x < original.width; x++) {
      const i = (y * original.width + x) * 4, alpha = original.pixels[i + 3];
      const eggs = stage === 'egg-carrying' && x >= 22 && x <= 27 && y >= 16;
      const bodyPixel = trunk.some(([left, row, length]) => row === y && x >= left && x < left + length);
      if (!alpha || (!fry && !female && !eggs && alpha < 255 && !bodyPixel)) continue;
      const rgb = bodyColor(Array.from(original.pixels.slice(i, i + 3)), x, key, stage);
      p.pixels.set([...rgb, !fry && !female && bodyPixel ? 255 : alpha], ((y + dy) * width + x + dx) * 4);
    }
    if (!fry) {
      if (key === 'guppy-dumbo-redtail') {
        const ox = female ? 3 : 0, oy = female ? 1 : 0;
        const transform = points => points.map(([x, y]) => [x + ox, y + oy]);
        p.polygon(transform([[30, 11], [26, 11], [21 + beat, 13], [22 + beat, 17], [25, 19], [28, 17], [30, 13]]), '#4c7d99', .67);
        p.line(transform([[30, 12], [25, 14], [22 + beat, 16]]), '#adc3c6', .72);
        p.line(transform([[30, 13], [26, 17], [25 + beat, 18]]), '#93b3b8', .61);
      } else if (!female) {
        p.line([[30, 13], [28, 14], [27 + beat, 15]], palette.ray, .48);
      }
      if (!female) {
        if (key === 'guppy-metal-lace') {
          for (const [x, y] of [[17, 11], [20, 12], [23, 11], [25, 12]]) p.dot(x, y, '#426665');
          p.line([[24, 9], [28, 10]], '#bdd1b9');
        } else if (key === 'medaka-white-galaxy-longfin') {
          for (const [x, y] of [[13, 11], [17, 10], [21, 11], [25, 10], [28, 12]]) p.dot(x, y, '#e5e8db');
          for (const [x, y] of [[15, 12], [23, 12], [30, 10]]) p.dot(x, y, '#97b4bb');
        } else if (key === 'medaka-tricolor') {
          p.line([[28, 9], [32, 9]], '#cc8955'); p.line([[27, 10], [31, 10]], '#d3945e');
          p.line([[29, 11], [31, 11]], '#ba7448'); p.line([[17, 10], [20, 10]], '#c08753');
          p.line([[18, 11], [21, 11]], '#d19e6b'); p.line([[22, 12], [25, 12]], '#46565a');
          p.dot(24, 11, '#65716c'); p.dot(14, 11, '#566962'); p.dot(16, 12, '#e0e1c8'); p.dot(27, 11, '#e5ddbd');
        }
      }
    }
    return { width, height, pixels: p.pixels, anchorX: original.anchorX + dx, anchorY: original.anchorY + dy, frameCount: 4, hasTransparency: true, species: kind, variant: key, stage };
  }

  function measure(art) {
    const { species: kind, stage, width, height } = art, fry = stage === 'fry', female = stage === 'female' || stage === 'gravid';
    const dx = fry ? 0 : female ? 2 : 6, dy = fry ? 0 : female ? 2 : 4;
    const core = fry ? [kind === 'guppy' ? 7 : 6, 5, 21, kind === 'guppy' ? 10 : 9] : female ? [13, 8, 41, stage === 'gravid' ? 21 : 18] : kind === 'guppy' ? [14, 8, 38, 16] : [9, 9, 38, stage === 'egg-carrying' ? 16 : 15];
    const mouth = fry ? [20.5, 7.5] : female ? [40.5, 12.5] : [37.5, 11.5];
    const vent = fry ? [12, 8.5] : female ? [23, stage === 'gravid' ? 18 : 15] : kind === 'guppy' ? [25.5, 14.5] : [24.5, 14.5];
    const peduncle = fry ? [kind === 'guppy' ? 7 : 6, 7] : female ? [13, 12.5] : [kind === 'guppy' ? 14 : 9, 12];
    let minX = width, maxX = -1, minY = height, maxY = -1, tailY = 0;
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) if (art.pixels[(y * width + x) * 4 + 3] > 7) {
      if (x < minX) { minX = x; tailY = y + .5; }
      maxX = Math.max(maxX, x); minY = Math.min(minY, y); maxY = Math.max(maxY, y);
    }
    const point = p => [p[0] + dx, p[1] + dy];
    return {
      canvas: { width, height }, anchor: [art.anchorX, art.anchorY],
      measurement: { basis: 'snout-to-caudal-fin total length, horizontal projection of reference frame 0 including ornamental extensions', axis: 'x', endpoints: [[minX, tailY], [maxX + 1, mouth[1] + dy]], pixels: maxX + 1 - minX, referenceFrame: 0 },
      standardLengthPixels: mouth[0] + .5 - peduncle[0],
      core: { minX: core[0] + dx, minY: core[1] + dy, maxX: core[2] + dx, maxY: core[3] + dy },
      landmarks: { mouth: point(mouth), vent: point(vent), foot: null, bodyCenter: point([(core[0] + core[2]) / 2, (core[1] + core[3]) / 2]), caudalPeduncle: point(peduncle) },
      occupiedReferenceBounds: { minX, minY, maxX: maxX + 1, maxY: maxY + 1 }
    };
  }

  const descriptors = {};
  for (const [key, form] of Object.entries(forms)) {
    const metricsByStage = {};
    for (const stage of stages[form.kind]) metricsByStage[stage] = measure(draw({ kind: form.kind, color: key, stage, pose: 0 }));
    descriptors[key] = { key, kind: form.kind, species: form.kind, scientificName: form.kind === 'guppy' ? 'Poecilia reticulata' : 'Oryzias latipes',
      form: form.form, source: form.source, stages: [...stages[form.kind]], metrics: metricsByStage.adult, metricsByStage,
      interpretation: 'Original pixel interpretation of a captive ornamental form; not a verified pedigree or a strain-specific body-size claim.' };
  }
  freeze(descriptors);

  function descriptor(key, stage = 'adult') {
    if (!Object.hasOwn(descriptors, key) || !descriptors[key].stages.includes(stage)) throw new RangeError('Unsupported fancy fish descriptor.');
    const result = clone(descriptors[key]); result.metrics = clone(result.metricsByStage[stage]); result.stage = stage; return result;
  }
  function rasterize(kind, phase = 0, preset = 'daylight', color, options = {}) {
    const s = settings(kind, phase, preset, color, options), art = draw(s);
    for (let i = 0; i < art.pixels.length; i += 4) if (art.pixels[i + 3]) for (let channel = 0; channel < 3; channel++) art.pixels[i + channel] = Math.min(255, Math.round(art.pixels[i + channel] * gains[preset][channel]));
    art.metrics = clone(descriptors[s.color].metricsByStage[s.stage]);
    return art;
  }
  function createSprite(kind, phase = 0, preset = 'daylight', color, options = {}) {
    const art = rasterize(kind, phase, preset, color, options);
    const canvas = options.createCanvas ? options.createCanvas(art.width, art.height) : root.document?.createElement('canvas');
    if (!canvas || typeof canvas.getContext !== 'function') throw new TypeError('A canvas is required; supply options.createCanvas or use rasterize.');
    canvas.width = art.width; canvas.height = art.height;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Fish sprites require a 2D canvas context.');
    const image = context.createImageData(art.width, art.height); image.data.set(art.pixels); context.putImageData(image, 0, 0);
    const { pixels, ...metadata } = art;
    return { canvas, ...metadata };
  }
  return { variants, stages, descriptors, descriptor, rasterize, createSprite };
});
