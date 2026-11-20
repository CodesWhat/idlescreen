(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory(root);
  else root.AquariumShrimpVarieties = factory(root);
})(typeof globalThis !== 'undefined' ? globalThis : this, function (root) {
  'use strict';

  const profiles = {
    amano: {
      label: 'Amano', identity: 'amano-shrimp',
      shell: { h: '#d7d6b5', m: '#b9c1a5', r: '#b0bca3', s: '#7e8d73', d: '#66775f', c: '#bac7b0' },
      alpha: { h: .72, m: .36, r: .25, s: .53, d: .61, c: .29 },
      limb: '#b5b99a', far: '#899b88', antenna: '#c6c8a7', limbAlpha: .59
    },
    'blue-dream': {
      label: 'Blue Dream', identity: 'neocaridina-color',
      shell: { h: '#74b1c6', m: '#2e78ad', r: '#205f9a', s: '#1c466f', d: '#18374d', c: '#528baf' },
      alpha: { h: .96, m: .86, r: .84, s: .92, d: .97, c: .71 },
      limb: '#6c9da9', far: '#547c87', antenna: '#adc9c6', limbAlpha: .68
    },
    'green-jade': {
      label: 'Green Jade', identity: 'neocaridina-color',
      shell: { h: '#8ba574', m: '#41794c', r: '#2e6845', s: '#244c37', d: '#203d2d', c: '#5e8664' },
      alpha: { h: .97, m: .92, r: .90, s: .95, d: .98, c: .78 },
      limb: '#8d9b72', far: '#6a8164', antenna: '#b8bfa0', limbAlpha: .67
    },
    'yellow-goldenback': {
      label: 'Yellow Goldenback', identity: 'neocaridina-color',
      shell: { h: '#f4df8c', m: '#e0bf4c', r: '#d7ae35', s: '#a88831', d: '#80702e', c: '#e5cb6b' },
      alpha: { h: .94, m: .84, r: .78, s: .88, d: .94, c: .69 },
      limb: '#c8be83', far: '#aaa77e', antenna: '#d8d4a5', limbAlpha: .64
    },
    'crystal-black': {
      label: 'Crystal Black', identity: 'crystal-shrimp',
      shell: { h: '#72776b', m: '#474f46', r: '#303c37', s: '#28342f', d: '#202b28', c: '#4d5b51' },
      alpha: { h: .98, m: .97, r: .98, s: 1, d: 1, c: .92 },
      limb: '#bdc5aa', far: '#8a9c8b', antenna: '#cbbda1', limbAlpha: .71
    },
    'orange-rili': {
      label: 'Orange Rili', identity: 'neocaridina-color',
      shell: { h: '#ffca80', m: '#ed9b46', r: '#de7e2f', s: '#ae612b', d: '#8d4c29', c: '#eda35b' },
      alpha: { h: .98, m: .95, r: .96, s: .98, d: 1, c: .87 },
      limb: '#c1ae83', far: '#8c9c87', antenna: '#d0c7a0', limbAlpha: .70
    }
  };
  const legacyPalettes = {
    red: ['#6c2931', '#c73e3b', '#f18a66', '#e65e49', '#9e3035', '#882d34', '#b43a3c', '#e76a50', '#c3856e', '#d89d7d', '#985d56', '#bd7260'],
    'red-rili': ['#812c2b', '#e44934', '#ffc478', '#f57444', '#b13b30', '#9a372e', '#d53f30', '#f3804c', '#b9bca7', '#c9c3a7', '#708783', '#a9b4a4'],
    'red-white': ['#752d2b', '#dd4230', '#f6ac63', '#f2673d', '#a6382c', '#8b302b', '#c63c2e', '#ed7950', '#d0d1b7', '#bbc5b5', '#84988e', '#bfc5ae'],
    yellow: ['#655521', '#d8ad30', '#f5dc71', '#e8c64a', '#aa822a', '#957125', '#b68d2b', '#e9c653', '#bcaa64', '#e0d4a0', '#a89b6a', '#bdab65'],
    blue: ['#203e63', '#367db3', '#79bad9', '#559ac8', '#2b608c', '#28577e', '#2f699b', '#5a9dc7', '#6f9cad', '#a4c4cb', '#749ba8', '#719da8'],
    orange: ['#704226', '#d67a32', '#f1b367', '#e89543', '#a95b2a', '#965027', '#b7632c', '#e99b50', '#c1956a', '#dec09a', '#ae9273', '#bd9367']
  };
  const legacyLabels = { red: 'Red', 'red-rili': 'Red Rili', 'red-white': 'Red / White', yellow: 'Yellow', blue: 'Blue', orange: 'Orange' };
  for (const [variant, shades] of Object.entries(legacyPalettes)) {
    profiles[variant] = {
      label: legacyLabels[variant], identity: variant === 'red-white' ? 'display-pattern' : 'neocaridina-color', legacy: shades,
      shell: { h: shades[2], m: shades[3], r: shades[1], s: shades[4], d: shades[5], c: shades[3] },
      alpha: { h: 1, m: 1, r: 1, s: 1, d: 1, c: 1 },
      limb: shades[8], far: shades[10], antenna: shades[9], limbAlpha: variant === 'red-rili' ? .72 : .82
    };
  }
  const variants = Object.freeze(Object.keys(profiles));
  const stages = Object.freeze(['adult', 'berried', 'juvenile']);
  const bodyRows = [
    [14, 'hhhhmm'], [11, 'hhmrrrrrmmm'], [9, 'hmrrrrrrrrmmmmm'],
    [8, 'mrrrrrrrrrrmcccccc'], [7, 'mrrrrrrrrrrmcccccrrr'], [7, 'rrrrrrrrrrrcccccrrr'],
    [8, 'srrrrrsssssccccrr'], [11, 'ssssddddscccdd'], [19, 'ddddd']
  ];
  const legPoses = [
    [[[18, 11], [16, 14], [13, 17]], [[20, 12], [19, 14], [18, 17]], [[22, 12], [23, 14], [22, 17]], [[24, 11], [26, 14], [27, 17]]],
    [[[18, 11], [16, 14], [14, 16]], [[20, 12], [19, 14], [18, 17]], [[22, 12], [24, 14], [23, 16]], [[24, 11], [26, 14], [27, 17]]],
    [[[18, 11], [17, 14], [15, 17]], [[20, 12], [20, 14], [19, 17]], [[22, 12], [24, 14], [24, 17]], [[24, 11], [26, 14], [28, 17]]],
    [[[18, 11], [17, 14], [15, 17]], [[20, 12], [20, 14], [19, 16]], [[22, 12], [24, 14], [24, 17]], [[24, 11], [26, 13], [27, 16]]]
  ];
  const clearSpans = [[14, 19], [12, 19], [12, 19], [11, 19], [11, 18], [12, 18], [12, 18], [13, 18], null];
  const crystalSpans = [
    [[14, 16]], [[11, 12], [15, 17]], [[9, 10], [14, 16], [22, 22]],
    [[8, 9], [14, 16], [23, 25]], [[7, 8], [14, 17], [23, 25]],
    [[7, 8], [14, 17], [23, 24]], [[8, 9], [15, 17], [22, 23]],
    [[15, 17], [22, 23]], [[23, 23]]
  ];
  const clearShell = { h: '#dce0ca', m: '#c5cdb8', r: '#bfc9b2', s: '#8c9e88', d: '#718772', c: '#bcc9b7' };
  const clearAlpha = { h: .66, m: .28, r: .18, s: .42, d: .52, c: .20 };
  const ivoryShell = { h: '#eee8cd', m: '#e6e4ca', r: '#d9ddc6', s: '#b3bfa9', d: '#92a598', c: '#d9dec8' };
  const legacyClearShell = { h: '#d5dccb', m: '#bfc9b6', r: '#b8c3b1', s: '#819585', d: '#657d70', c: '#b6c4b3' };
  const legacyIvoryShell = { h: '#f3edd1', m: '#eeead0', r: '#dedfc4', s: '#b5c0ad', d: '#899f98', c: '#e9e7ce' };
  const legacyIvorySpans = [
    [[17, 18]], [[11, 12]], [[9, 10], [12, 13], [22, 23]],
    [[8, 9], [12, 13], [22, 24]], [[7, 8], [13, 14], [20, 21], [24, 25]],
    [[7, 8], [13, 14], [21, 22], [25, 25]], [[8, 9], [14, 15], [21, 23]],
    [[14, 15], [22, 23]], [[23, 23]]
  ];

  function createSprite(kind = 'shrimp', phase = 0, preset = 'daylight', variant = 'amano', options = {}) {
    if (kind !== 'shrimp') throw new RangeError('kind must be shrimp; route existing animals to AquariumAnimalArt');
    if (!Number.isFinite(phase)) throw new RangeError('phase must be finite');
    if (!Object.prototype.hasOwnProperty.call(profiles, variant)) throw new RangeError('unsupported shrimp variant: ' + variant);
    const stage = options.stage === undefined ? 'adult' : options.stage;
    if (!stages.includes(stage)) throw new RangeError('stage must be adult, berried or juvenile');
    const profile = profiles[variant], pose = ((Math.floor(phase) % 4) + 4) % 4;
    const eggMarks = [], fanOffset = stage === 'berried' ? [0, 1, 0, -1][pose] : 0;
    const canvas = options.createCanvas ? options.createCanvas(34, 20) : root.document?.createElement('canvas');
    if (!canvas?.getContext) throw new TypeError('createCanvas must provide a canvas when document is unavailable');
    canvas.width = 34; canvas.height = 20;
    const context = canvas.getContext('2d');
    if (!context) throw new Error('a 2d canvas context is required');
    context.imageSmoothingEnabled = false;
    const gains = preset === 'warm' ? [1.08, .94, .79] : preset === 'moonlight' ? [.48, .65, .89] : [1, 1, 1];
    const tintCache = new Map();
    function tint(hex) {
      if (!tintCache.has(hex)) {
        const values = hex.slice(1).match(/../g).map((value, i) => Math.min(255, Math.round(parseInt(value, 16) * gains[i])));
        tintCache.set(hex, '#' + values.map(value => value.toString(16).padStart(2, '0')).join(''));
      }
      return tintCache.get(hex);
    }
    function pixel(x, y, width, height, color, alpha = 1) {
      context.clearRect(x, y, width, height);
      context.globalAlpha = alpha; context.fillStyle = tint(color);
      context.fillRect(x, y, width, height); context.globalAlpha = 1;
    }
    function line(points, color, alpha = 1) {
      for (let i = 1; i < points.length; i++) {
        let [x, y] = points[i - 1]; const [endX, endY] = points[i];
        const dx = Math.abs(endX - x), dy = -Math.abs(endY - y), sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
        let error = dx + dy;
        for (;;) {
          pixel(x, y, 1, 1, typeof color === 'function' ? color(x, y) : color, typeof alpha === 'function' ? alpha(x, y) : alpha);
          if (x === endX && y === endY) break;
          const twice = error * 2;
          if (twice >= dy) { error += dy; x += sx; }
          if (twice <= dx) { error += dx; y += sy; }
        }
      }
    }
    const rili = variant === 'orange-rili' || variant === 'red-rili', crystal = variant === 'crystal-black', amano = variant === 'amano';
    const legacy = profile.legacy, redWhite = variant === 'red-white';
    function sample(x, y, shade) {
      const span = clearSpans[y - 5];
      if (rili && span && x >= span[0] && x <= span[1]) return [clearShell[shade], clearAlpha[shade]];
      if (crystal && crystalSpans[y - 5]?.some(([left, right]) => x >= left && x <= right)) return [ivoryShell[shade], 1];
      return [profile.shell[shade], profile.alpha[shade]];
    }
    function drawJuvenile() {
      const youngLegs = [
        [[[16, 11], [15, 13], [14, 15]], [[18, 12], [18, 14], [17, 16]], [[20, 12], [21, 14], [21, 16]], [[22, 11], [23, 13], [24, 15]]],
        [[[16, 11], [15, 13], [15, 14]], [[18, 12], [18, 14], [17, 16]], [[20, 12], [21, 14], [22, 15]], [[22, 11], [23, 13], [24, 15]]],
        [[[16, 11], [16, 13], [15, 15]], [[18, 12], [19, 14], [18, 16]], [[20, 12], [22, 14], [22, 16]], [[22, 11], [24, 13], [25, 15]]],
        [[[16, 11], [16, 13], [15, 15]], [[18, 12], [19, 14], [18, 15]], [[20, 12], [22, 14], [22, 16]], [[22, 11], [23, 13], [24, 14]]]
      ];
      const paleCache = new Map();
      function pale(hex) {
        if (!paleCache.has(hex)) {
          const neutral = [180, 192, 163];
          const color = hex.slice(1).match(/../g).map((part, i) => Math.round(parseInt(part, 16) * .67 + neutral[i] * .33));
          paleCache.set(hex, '#' + color.map(value => value.toString(16).padStart(2, '0')).join(''));
        }
        return paleCache.get(hex);
      }
      function youngSample(x, y, shade) {
        if (rili && x >= (y === 8 ? 16 : y === 12 ? 15 : 13) && x <= (y === 12 ? 18 : 17)) {
          return [(legacy ? legacyClearShell : clearShell)[shade], Math.max(.16, clearAlpha[shade] * .84)];
        }
        if ((crystal || redWhite) && (x === 13 || x === 14 || x === 17 || x === 18 || x === 22)) return [(redWhite ? legacyIvoryShell : ivoryShell)[shade], .82];
        return [pale(profile.shell[shade]), Math.max(.18, profile.alpha[shade] * .82)];
      }
      for (const points of youngLegs[pose]) line(points, pale(profile.limb), profile.limbAlpha * .85);
      line([[13, 11], [13, 13], [14, 14]], pale(profile.far), .40);
      line([[15, 12], [15, 13], [16, 14]], pale(profile.far), .40);
      line([[11, 10], [9, 10], [8, 9]], pale(profile.shell.m), .56);
      line([[11, 11], [9, 11], [8, 10]], pale(profile.shell.s), .52);
      line([[11, 11], [9, 12], [8, 12]], pale(profile.shell.s), .52);
      const rows = [[16, 'hhhm'], [13, 'hmrrrrmm'], [11, 'mrrrrrrmccc'], [11, 'srrrrrsscccc'], [14, 'ssddssccc']];
      rows.forEach(([start, row], index) => [...row].forEach((shade, column) => {
        const x = start + column, y = index + 8; pixel(x, y, 1, 1, ...youngSample(x, y, shade));
      }));
      for (const [x, y] of [[14, 10], [17, 11], [20, 11]]) pixel(x, y, 1, 1, ...youngSample(x, y, 's'));
      if (amano) for (const [x, y] of [[13, 11], [16, 10], [19, 11]]) pixel(x, y, 1, 1, '#858364', .65);
      if (variant === 'yellow-goldenback') {
        pixel(16, 8, 4, 1, '#ede0a4', .86); pixel(13, 9, 4, 1, '#e3d38b', .83);
      }
      if (variant === 'green-jade') pixel(18, 9, 1, 1, '#93aa7f', .78);
      line([[22, 10], [24, 9], [26, 8]], pale(redWhite ? legacyIvoryShell.h : crystal ? ivoryShell.h : profile.shell.m), .65);
      line([[23, 10], [25, 8], [28, 7]], pale(profile.antenna), .48);
      line([[23, 11], [26, 11], [28, 10]], pale(profile.limb), .51);
      line([[22, 12], [23, 13], [23, 14]], pale(profile.limb), .54);
      pixel(22, 10, 1, 1, '#172c2b');
    }
    function drawBrood() {
      const eggs = amano ? ['#798164', '#a8b18b', '#586b53']
        : crystal ? ['#8c8963', '#bcb991', '#646d53']
          : variant === 'yellow-goldenback' || variant === 'yellow' ? ['#ae984a', '#d6c275', '#857c40']
            : ['#91944c', '#c2bf73', '#6e7942'];
      for (const [rootX, rootY, tipX, tipY] of [[10, 10, 11, 15], [13, 11, 14, 16], [16, 11, 17, 16]]) {
        line([[rootX, rootY], [rootX, 13], [tipX + fanOffset, tipY]], profile.far, .73);
      }
      line([[10, 13], [13, 14], [18, 14]], eggs[2], .86);
      for (const [x, y] of [[9, 12], [12, 13], [15, 13], [10, 14], [13, 15], [16, 15]]) {
        pixel(x, y, 2, 2, eggs[0], .94);
        pixel(x, y, 1, 1, eggs[1], .96);
        pixel(x + 1, y + 1, 1, 1, eggs[2], .91);
        eggMarks.push({ x, y, width: 2, height: 2 });
      }
    }
    if (stage === 'juvenile') { drawJuvenile(); return finish(); }
    if (legacy) { drawLegacy(); return finish(); }
    const farAlpha = rili || amano ? .44 : .54;
    line([[18, 11], [16, 13], [16, 16]], profile.far, farAlpha);
    line([[23, 11], [24, 13], [25, 16]], profile.far, farAlpha);
    for (const points of legPoses[pose]) line(points, profile.limb, profile.limbAlpha);
    if (crystal) for (const [, [x, y]] of legPoses[pose]) pixel(x, y, 1, 1, '#697566', .88);
    for (const points of [[[10, 10], [10, 13], [12, 14]], [[13, 11], [13, 13], [15, 14]], [[16, 11], [16, 13], [17, 14]]]) {
      line(points, profile.far, rili || amano ? .46 : .65);
    }
    if (stage === 'berried') {
      drawBrood();
      for (const points of legPoses[pose]) line(points, profile.limb, profile.limbAlpha);
      if (crystal) for (const [, [x, y]] of legPoses[pose]) pixel(x, y, 1, 1, '#697566', .88);
    }

    line([[7, 10], [5, 9], [3, 8]], crystal ? ivoryShell.h : profile.shell.m, amano ? .53 : .86);
    line([[7, 11], [4, 11], [2, 10]], crystal ? ivoryShell.s : profile.shell.s, amano ? .47 : .84);
    line([[7, 11], [5, 13], [3, 13]], crystal ? ivoryShell.s : profile.shell.s, amano ? .47 : .84);
    pixel(4, 10, 3, 2, crystal ? ivoryShell.r : profile.shell.r, amano ? .38 : .91);
    pixel(4, 10, 1, 1, crystal ? ivoryShell.h : profile.shell.h, amano ? .62 : .95);

    bodyRows.forEach(([start, row], index) => [...row].forEach((shade, column) => {
      const x = start + column, y = index + 5;
      pixel(x, y, 1, 1, ...sample(x, y, shade));
    }));
    for (const points of [[[10, 8], [11, 10], [12, 11]], [[13, 7], [14, 9], [15, 11]],
      [[17, 7], [18, 9], [18, 11]], [[21, 8], [20, 10], [20, 12]]]) {
      line(points, (x, y) => sample(x, y, 's')[0], (x, y) => sample(x, y, 's')[1]);
    }
    pixel(12, 7, 1, 1, ...sample(12, 7, 'h'));
    pixel(16, 6, 1, 1, ...sample(16, 6, 'h'));
    for (const x of [22, 23]) pixel(x, 8, 1, 1, ...sample(x, 8, 'h'));

    if (amano) {
      line([[11, 10], [16, 10], [20, 11]], '#858b68', .45);
      for (const [x, y] of [[9, 9], [12, 9], [15, 9], [18, 9], [21, 9], [23, 10], [11, 11], [14, 11], [17, 11], [21, 12]]) {
        pixel(x, y, 1, 1, '#71684b', .83);
      }
      pixel(19, 7, 2, 1, '#8c8a62', .49);
    } else if (rili) {
      pixel(12, 11, 3, 1, '#b29976', .60); pixel(15, 11, 3, 1, '#b5a080', .60); pixel(18, 10, 1, 1, '#a79171', .60);
    } else if (variant === 'yellow-goldenback') {
      pixel(14, 5, 6, 1, '#f7e5a4', .99); pixel(11, 6, 8, 1, '#f2d981', .98);
      pixel(9, 7, 3, 1, '#edcc68', .97); pixel(8, 8, 1, 1, '#e8c260', .95);
    } else if (variant === 'green-jade') {
      pixel(13, 7, 1, 1, '#718e57', .94); pixel(18, 6, 1, 1, '#78995e', .94);
    } else if (variant === 'blue-dream') {
      pixel(14, 6, 2, 1, '#5b9fbd', .94); pixel(19, 7, 1, 1, '#488ba9', .89);
    }

    line([[24, 8], [27, 7], [29, 6]], crystal ? ivoryShell.h : profile.shell.m, amano ? .56 : .90);
    line([[26, 9], [28, 6], [31, 4], [33, 3]], profile.antenna, .62);
    line([[26, 10], [30, 10], [33, 9]], profile.limb, .67);
    pixel(rili || crystal ? 24 : 25, 8, rili || crystal ? 2 : 1, 1, '#172c2b');
    pixel(25, 11, 1, 1, profile.shell.d, amano ? .66 : profile.alpha.d);
    line([[25, 12], [27, 13], [26, 14]], profile.limb, .67);

    return finish();
    function drawLegacy() {
      // Keep the approved animal-art shrimp draw order, including its wider highlight mark.
      const shades = legacy;
      const walkingLegs = () => {
        for (const points of legPoses[pose]) line(points, shades[8], rili ? .72 : .82);
        if (redWhite) for (const [, [x, y]] of legPoses[pose]) pixel(x, y, 1, 1, shades[1]);
      };
      line([[18, 11], [16, 13], [16, 16]], shades[10], rili ? .46 : .56);
      line([[23, 11], [24, 13], [25, 16]], shades[10], rili ? .46 : .56);
      walkingLegs();
      const swimmeret = rili || redWhite ? shades[10] : shades[6];
      for (const points of [[[10, 10], [10, 13], [12, 14]], [[13, 11], [13, 13], [15, 14]], [[16, 11], [16, 13], [17, 14]]]) {
        line(points, swimmeret, rili ? .46 : .74);
      }
      if (stage === 'berried') { drawBrood(); walkingLegs(); }
      line([[7, 10], [5, 9], [3, 8]], redWhite ? '#eee7c9' : shades[7]);
      line([[7, 11], [4, 11], [2, 10]], redWhite ? '#c9d0b8' : shades[6]);
      line([[7, 11], [5, 13], [3, 13]], redWhite ? '#c9d0b8' : shades[6]);
      pixel(4, 10, 3, 2, redWhite ? '#dedfc2' : shades[1]);
      pixel(4, 10, 1, 1, redWhite ? '#f3edd1' : shades[7]);
      function legacySample(x, y, shade) {
        const span = clearSpans[y - 5];
        if (rili && span && x >= span[0] && x <= span[1]) return [legacyClearShell[shade], clearAlpha[shade]];
        if (redWhite && legacyIvorySpans[y - 5]?.some(([left, right]) => x >= left && x <= right)) return [legacyIvoryShell[shade], 1];
        return [profile.shell[shade], 1];
      }
      bodyRows.forEach(([start, row], index) => [...row].forEach((shade, column) => {
        const x = start + column, y = index + 5; pixel(x, y, 1, 1, ...legacySample(x, y, shade));
      }));
      for (const points of [[[10, 8], [11, 10], [12, 11]], [[13, 7], [14, 9], [15, 11]],
        [[17, 7], [18, 9], [18, 11]], [[21, 8], [20, 10], [20, 12]]]) {
        line(points, (x, y) => legacySample(x, y, 's')[0], (x, y) => legacySample(x, y, 's')[1]);
      }
      pixel(12, 7, 1, 1, rili || redWhite ? legacySample(12, 7, 'h')[0] : shades[7], legacySample(12, 7, 'h')[1]);
      pixel(16, 6, 1, 1, rili ? legacyClearShell.h : shades[7], legacySample(16, 6, 'h')[1]);
      pixel(22, 8, 2, 1, redWhite ? legacyIvoryShell.h : shades[2]);
      if (rili) {
        pixel(12, 11, 3, 1, '#b98376', .62); pixel(15, 11, 3, 1, '#bc8b7c', .62); pixel(18, 10, 1, 1, '#ad716c', .62);
      }
      line([[24, 8], [27, 7], [29, 6]], redWhite ? '#e7e4c8' : shades[3]);
      line([[26, 9], [28, 6], [31, 4], [33, 3]], shades[9], .66);
      line([[26, 10], [30, 10], [33, 9]], shades[8], .72);
      pixel(rili || redWhite ? 24 : 25, 8, rili || redWhite ? 2 : 1, 1, '#172c2b');
      pixel(25, 11, 1, 1, shades[5]);
      line([[25, 12], [27, 13], [26, 14]], shades[11], .72);
    }
    function finish() {
      let disposed = false;
      return {
        canvas, anchorX: 17, anchorY: 16, frameCount: 4, hasTransparency: true,
        variant, label: profile.label, identity: profile.identity, stage, renderScale: 1, eggMarks, fanOffset,
        lifecycle: {
          development: amano ? 'larval-brackish' : redWhite ? 'unspecified' : 'direct-development',
          juvenileRepresents: amano ? 'post-larval-juvenile' : 'juvenile', spawningSimulated: false
        },
        bounds: stage === 'juvenile' ? { minX: 8, minY: 7, maxX: 28, maxY: 16 } : { minX: 2, minY: 3, maxX: 33, maxY: 17 },
        dispose() {
          if (disposed) return;
          context.clearRect(0, 0, canvas.width, canvas.height); canvas.width = canvas.height = 0; disposed = true;
        }
      };
    }
  }
  return { createSprite, variants, stages };
});
