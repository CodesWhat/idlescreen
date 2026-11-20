(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumFishVarieties = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  const variants = Object.freeze({ medaka: Object.freeze(['white', 'redcap']), guppy: Object.freeze(['blue', 'pink']) });
  const stages = Object.freeze({ medaka: Object.freeze(['adult', 'egg-carrying', 'fry']), guppy: Object.freeze(['adult', 'female', 'gravid', 'fry']) });
  const gains = Object.freeze({ daylight: [1, 1, 1], warm: [1.08, .94, .79], moonlight: [.48, .65, .89] });

  function rasterize(kind, phase = 0, preset = 'daylight', color, options = {}) {
    if (!Object.hasOwn(variants, kind)) throw new RangeError('Fish variety must be medaka or guppy.');
    if (!Number.isFinite(phase)) throw new RangeError('Fish frame phase must be finite.');
    if (!Object.hasOwn(gains, preset)) throw new RangeError('Fish lighting must be daylight, warm, or moonlight.');
    color ??= variants[kind][0];
    if (!variants[kind].includes(color)) throw new RangeError('Unsupported palette for this fish variety.');
    if (!options || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Fish options must be an object.');
    const stage = options.stage === undefined ? 'adult' : options.stage;
    if (!stages[kind].includes(stage)) throw new RangeError('Unsupported lifecycle stage for this fish variety.');
    const fry = stage === 'fry', femaleGuppy = kind === 'guppy' && (stage === 'female' || stage === 'gravid');
    const width = fry ? 22 : femaleGuppy ? 44 : 40, height = fry ? 14 : femaleGuppy ? 28 : 24;
    const anchorX = fry ? 14 : femaleGuppy ? 25 : 23, anchorY = fry ? 7 : femaleGuppy ? 13 : 12;
    const frameCount = 4, pose = ((Math.floor(phase) % frameCount) + frameCount) % frameCount;
    const pixels = new Uint8ClampedArray(width * height * 4), palette = new Map();
    const fold = [0, 1, 2, 1][pose], lift = [0, -1, 0, 1][pose], finFold = pose % 2;

    function dot(x, y, hex, alpha = 1) {
      if (!Number.isInteger(x) || !Number.isInteger(y) || x < 0 || y < 0 || x >= width || y >= height) throw new RangeError('Fish pixel escaped its canvas.');
      let rgb = palette.get(hex);
      if (!rgb) {
        rgb = [1, 3, 5].map((offset, i) => Math.min(255, Math.round(parseInt(hex.slice(offset, offset + 2), 16) * gains[preset][i])));
        palette.set(hex, rgb);
      }
      pixels.set([...rgb, Math.round(alpha * 255)], (y * width + x) * 4);
    }
    function span(x, y, length, hex, alpha = 1) { for (let i = 0; i < length; i++) dot(x + i, y, hex, alpha); }
    function line(points, hex, alpha = 1) {
      for (let i = 1; i < points.length; i++) {
        let [x, y] = points[i - 1]; const [endX, endY] = points[i];
        const dx = Math.abs(endX - x), dy = -Math.abs(endY - y), sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
        let error = dx + dy;
        for (;;) {
          dot(x, y, hex, alpha);
          if (x === endX && y === endY) break;
          const twice = error * 2;
          if (twice >= dy) { error += dy; x += sx; }
          if (twice <= dx) { error += dx; y += sy; }
        }
      }
    }
    function polygon(points, hex, alpha = 1) {
      const top = Math.min(...points.map(p => p[1])), bottom = Math.max(...points.map(p => p[1]));
      for (let y = top; y < bottom; y++) {
        const crossings = [];
        for (let i = 0; i < points.length; i++) {
          const a = points[i], b = points[(i + 1) % points.length], cy = y + .5;
          if ((a[1] <= cy && b[1] > cy) || (b[1] <= cy && a[1] > cy)) crossings.push(a[0] + (cy - a[1]) * (b[0] - a[0]) / (b[1] - a[1]));
        }
        crossings.sort((a, b) => a - b);
        for (let i = 0; i + 1 < crossings.length; i += 2) {
          const start = Math.ceil(crossings[i] - .5), end = Math.ceil(crossings[i + 1] - .5);
          span(start, y, end - start, hex, alpha);
        }
      }
    }

    if (fry) {
      polygon([[7, 6], [3 + fold, 4 + lift], [2 + fold, 5 + lift], [2 + fold, 9 + lift], [4 + fold, 9 + lift], [7, 7]], '#a1b7ab', .28);
      line([[3 + fold, 5 + lift], [7, 6]], '#bccbbb', .56);
      line([[3 + fold, 8 + lift], [7, 7]], '#8ba59f', .43);
      polygon([[10, 6], [11, 4 + finFold], [14, 5], [15, 6]], '#a3b7a9', .34);
      line([[11, 8], [12 + finFold, 10], [14, 8]], '#a7b9a9', .39);
      if (kind === 'guppy') {
        [[13, 5, 7, '#b3c1ab'], [9, 6, 12, '#c3cdb7'], [7, 7, 14, '#a9bdb0'], [11, 8, 9, '#98aea0'], [14, 9, 4, '#7f988c']]
          .forEach(([x, y, length, hex]) => span(x, y, length, hex));
        span(14, 6, 3, '#d4d8bd'); dot(15, 8, color === 'pink' ? '#b5aaa1' : '#a1b6b0');
      } else {
        [[16, 5, 4, '#b8c7b6'], [8, 6, 13, '#cbd4c2'], [6, 7, 15, '#b5c6b7'], [13, 8, 7, '#94aca2']]
          .forEach(([x, y, length, hex]) => span(x, y, length, hex));
        span(11, 6, 6, '#d6ddc7');
        if (color === 'redcap') dot(17, 5, '#c6b8a4');
      }
      span(17, 6, 3, '#a7beb0'); dot(18, 6, '#193238'); dot(19, 6, '#2b4243'); dot(18, 7, '#263c3c');
      dot(17, 6, '#d7d8be'); dot(20, 7, '#768e81');
      line([[17, 8], [16 + finFold, 9]], '#b1bfaa', .47);
    } else if (femaleGuppy) {
      const gravid = stage === 'gravid';
      const fin = color === 'blue' ? '#879fa3' : '#a2949b', ray = color === 'blue' ? '#b1bfb8' : '#c2b5b4';
      polygon([[13, 12], [10, 11], [6 + fold, 7 + lift], [4 + fold, 8 + lift], [4 + fold, 16 + lift], [7 + fold, 17 + lift], [11, 14], [13, 13]], fin, .49);
      line([[5 + fold, 9 + lift], [9, 11], [13, 12]], ray, .68);
      line([[5 + fold, 12 + lift], [10, 12], [13, 13]], '#a4b4a7', .55);
      line([[6 + fold, 16 + lift], [10, 14], [13, 13]], ray, .58);
      polygon([[20, 10], [21, 6 + finFold], [25, 7 + finFold], [28, 10]], fin, .43);
      line([[22, 7 + finFold], [24, 10]], ray, .62);
      const ventY = gravid ? 18 : 15;
      polygon([[21, ventY - 1], [17 + finFold, ventY + 4], [22, ventY + 3], [25, ventY]], '#8fa495', .46);
      line([[22, ventY], [19 + finFold, ventY + 3], [22, ventY + 2]], '#b8c1aa', .60);
      [[28, 8, 7, '#929e88'], [24, 9, 14, '#a4b19b'], [20, 10, 20, '#b5c0a8'], [16, 11, 25, '#aab99f'],
        [13, 12, 28, '#9cae99'], [13, 13, 28, '#91a58f'], [16, 14, 24, '#a4b39a']]
        .forEach(([x, y, length, hex]) => span(x, y, length, hex));
      const belly = gravid
        ? [[17, 15, 21], [18, 16, 19], [19, 17, 17], [21, 18, 14], [23, 19, 10], [25, 20, 6]]
        : [[20, 15, 18], [23, 16, 12], [26, 17, 6]];
      belly.forEach(([x, y, length], i) => span(x, y, length, i < 3 ? '#b4bba1' : '#8c9b84'));
      span(23, 10, 10, '#c7ceb3'); span(16, 12, 11, '#a9b7a0'); span(24, 13, 10, '#bdc5a8');
      [[20, 11], [24, 11], [28, 11], [31, 10], [29, 14]].forEach(([x, y]) => dot(x, y, '#c9ceb0'));
      if (gravid) {
        span(21, 16, 5, '#727a61'); span(21, 17, 5, '#4d5c4b'); span(22, 18, 4, '#626c53');
        dot(23, 17, '#3b5146'); span(27, 17, 5, '#c0c2a1');
      } else { span(23, 15, 2, '#7c8d74'); }
      line([[34, 10], [33, 12], [34, 14]], '#7d937e');
      span(35, 10, 4, '#c1c4a2'); span(36, 11, 2, '#1d3334'); dot(36, 10, '#243a3b'); dot(35, 10, '#dbd3ae');
      span(36, 14, 3, '#c1bfa0'); dot(40, 12, '#637d69'); dot(39, 13, '#c9c6a8');
      line([[33, 14], [31, 16], [30 + finFold, 17]], '#a8b69c', .48);
    } else if (kind === 'medaka') {
      polygon([[9, 11], [7, 10], [4 + fold, 7 + lift], [2 + fold, 8 + lift], [2 + fold, 15 + lift], [4 + fold, 16 + lift], [7, 13], [9, 12]], '#a3b9af', .32);
      line([[3 + fold, 8 + lift], [6, 10], [9, 11]], '#b9cbbc', .61);
      line([[2 + fold, 11 + lift], [6, 11], [9, 12]], '#d2d9c6', .43);
      line([[3 + fold, 15 + lift], [6, 13], [9, 12]], '#8daaa2', .55);
      line([[4 + fold, 14 + lift], [7, 12], [9, 12]], '#bed0bf', .48);
      polygon([[12, 10], [14, 7 + finFold], [17, 7 + finFold], [18, 10]], '#9fb5aa', .38);
      line([[14, 8 + finFold], [15, 10]], '#b6c7b4', .66);
      line([[17, 8 + finFold], [17, 10]], '#899e97', .58);
      if (stage === 'egg-carrying') {
        polygon([[14, 13], [17, 16 - finFold], [22, 14]], '#92aaa0', .32);
        line([[16, 14], [18, 16 - finFold], [21, 14]], '#b2c4b4', .56);
      } else {
        polygon([[13, 13], [15, 17 - finFold], [19, 18 - finFold], [23, 14]], '#92aaa0', .32);
        line([[14, 13], [16, 17 - finFold], [19, 17 - finFold]], '#b2c4b4', .56);
        line([[19, 14], [19, 17 - finFold]], '#c1ccba', .43);
      }
      line([[24, 13], [23, 16 - finFold]], '#9fb8ab', .45);

      [[21, 9, 14, '#a6bdb2'], [14, 10, 23, '#c7d3c0'], [9, 11, 29, '#cfd9c8'],
        [9, 12, 29, '#b8cbbd'], [13, 13, 23, '#9bb6ac'], [21, 14, 11, '#889f99']]
        .forEach(([x, y, length, hex]) => span(x, y, length, hex));
      span(18, 10, 11, '#d8dfcb'); span(11, 11, 8, '#bed0bf'); span(19, 11, 10, '#c8d5c2');
      span(15, 12, 13, '#a8c2b7'); span(20, 13, 10, '#c6d1bc');
      [[18, 10], [22, 10], [26, 10], [24, 12], [28, 13]].forEach(([x, y]) => dot(x, y, '#e0e2cd'));
      span(10, 12, 4, '#789b99'); span(13, 11, 3, '#a5beb2');
      if (color === 'redcap') {
        span(28, 9, 7, '#d96c43'); span(27, 10, 9, '#dd8150');
        span(29, 11, 6, '#cf663e'); span(29, 12, 4, '#bd744e');
        span(29, 9, 3, '#ed9b64'); dot(28, 10, '#edaa73');
      }
      line([[31, 10], [30, 11], [31, 13]], color === 'redcap' ? '#a6694c' : '#879f97');
      span(33, 13, 3, '#c6cfb8'); dot(37, 11, '#647e79'); dot(36, 12, '#d4d6bf');
      dot(32, 9, '#c4cfb3'); span(32, 10, 3, '#91b9b0'); span(33, 11, 2, '#2c3d3b');
      dot(33, 10, '#132c31'); dot(34, 10, '#203b40'); dot(32, 10, '#d6d9bc');
      line([[30, 13], [28, 14], [27 + finFold, 15]], '#a4b9a9', .48);
      if (stage === 'egg-carrying') {
        span(18, 14, 15, '#a3b8a8'); span(21, 15, 10, '#9aaf9f');
        line([[24, 15], [24, 17], [25, 19]], '#aebfa9', .52);
        for (const [x, y] of [[24, 17], [26, 18], [23, 19], [25, 20]]) {
          dot(x, y, '#8d9d82', .34);
          dot(x - 1, y, '#c2cbb2', .46); dot(x + 1, y, '#9cab95', .40);
          dot(x, y - 1, '#d5d9c0', .68); dot(x, y + 1, '#8ea28d', .42);
        }
      }
    } else {
      const p = color === 'blue'
        ? { fin: '#3f819c', edge: '#769ba8', ray: '#8ebec1', shadow: '#36556c', rear: '#4c7890', mid: '#74949a', glint: '#aed1c8', blush: '#b99b81' }
        : { fin: '#b37896', edge: '#ac8fa9', ray: '#dfb2bf', shadow: '#684f73', rear: '#8e6686', mid: '#b291a4', glint: '#dfc7ce', blush: '#cc9f92' };
      polygon([[14, 11], [11, 10], [6, 5 + lift], [3 + fold, 3 + lift], [2 + fold, 6 + lift],
        [3 + fold, 10 + lift], [2 + fold, 14 + lift], [3 + fold, 19 + lift], [5 + fold, 20 + lift], [9, 16], [14, 13]], p.fin, .78);
      line([[3 + fold, 4 + lift], [6, 7], [10, 10], [14, 11]], p.ray, .83);
      line([[3 + fold, 7 + lift], [7, 10], [14, 12]], p.edge, .70);
      line([[3 + fold, 11 + lift], [8, 12], [14, 12]], p.ray, .83);
      line([[3 + fold, 15 + lift], [9, 13], [14, 12]], p.shadow, .68);
      line([[4 + fold, 18 + lift], [9, 15], [14, 13]], p.ray, .78);
      line([[4 + fold, 19 + lift], [8, 17], [12, 14]], p.edge, .58);
      polygon([[24, 9], [22, 5 + finFold], [17, 4 + finFold], [15, 7 + finFold], [19, 10]], p.fin, .66);
      line([[17, 5 + finFold], [20, 7], [23, 9]], p.ray, .78);
      line([[16, 7 + finFold], [20, 9]], p.edge, .60);
      line([[27, 14], [24, 16 - finFold], [21, 17 - finFold]], p.shadow, .67);
      line([[28, 14], [26, 16 - finFold], [23, 17 - finFold]], p.ray, .59);
      line([[30, 14], [28 + finFold, 16]], '#b4bda5', .52);

      [[27, 8, 7, '#8f9f93'], [22, 9, 14, '#b6b8a0'], [17, 10, 20, '#b9c5af'],
        [14, 11, 24, p.mid], [14, 12, 24, p.rear], [17, 13, 19, '#8b9b91'],
        [22, 14, 12, '#b4b69a'], [25, 15, 6, '#7f8e81']]
        .forEach(([x, y, length, hex]) => span(x, y, length, hex));
      span(17, 10, 10, p.glint); span(15, 11, 10, p.rear); span(15, 12, 10, p.shadow);
      span(18, 13, 8, p.rear); span(25, 11, 7, '#b8c7b0'); span(26, 12, 6, '#a8b7a3');
      span(27, 10, 5, '#d3d5b5'); span(25, 9, 6, '#c6cab1'); span(27, 13, 7, '#c7c9ad');
      [[18, 10], [21, 10], [23, 11], [19, 12], [25, 10]].forEach(([x, y]) => dot(x, y, p.glint));
      span(29, 12, 3, p.blush); dot(30, 13, '#bb9e82');
      line([[31, 10], [30, 11], [31, 13]], '#7c9488');
      span(32, 9, 3, '#cec8a4'); span(32, 10, 4, '#c5c4a0'); span(33, 11, 2, '#182e33');
      dot(33, 10, '#172c32'); dot(34, 10, '#294249'); dot(32, 10, '#e1d2a8');
      span(33, 13, 3, '#c3c0a3'); dot(37, 11, '#657d71'); dot(36, 12, '#d4ccb0');
      line([[30, 13], [28, 14], [27 + finFold, 15]], '#b0bca4', .48);
    }
    return { width, height, pixels, anchorX, anchorY, frameCount, hasTransparency: true, species: kind, variant: color, stage };
  }

  function createSprite(kind, phase = 0, preset = 'daylight', color, options = {}) {
    const art = rasterize(kind, phase, preset, color, options);
    if (typeof document === 'undefined') throw new Error('createSprite needs a browser document and canvas; use rasterize for RGBA data.');
    const canvas = document.createElement('canvas'); canvas.width = art.width; canvas.height = art.height;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('A 2D canvas context is required for fish sprites.');
    const image = context.createImageData(art.width, art.height); image.data.set(art.pixels); context.putImageData(image, 0, 0);
    return { canvas, anchorX: art.anchorX, anchorY: art.anchorY, frameCount: art.frameCount, hasTransparency: true, species: art.species, variant: art.variant, stage: art.stage };
  }

  return { variants, stages, rasterize, createSprite };
});
