/* Original study sprites shared by the A/B prototypes. No imported artwork. */
(() => {
  'use strict';
  const tint = (hex, preset) => {
    const c = hex.slice(1).match(/../g).map(v => parseInt(v, 16));
    const gains = preset === 'warm' ? [1.08, .94, .79] : preset === 'moonlight' ? [.48, .65, .89] : [1, 1, 1];
    return '#' + c.map((v, i) => Math.min(255, Math.round(v * gains[i])).toString(16).padStart(2, '0')).join('');
  };
  function createSprite(kind, phase = 0, preset = 'daylight', color = 'red') {
    const canvas = document.createElement('canvas');
    canvas.width = kind === 'otocinclus' ? 28 : kind === 'shrimp' ? 34 : 40;
    canvas.height = kind === 'otocinclus' ? 40 : kind === 'shrimp' ? 20 : 24;
    const g = canvas.getContext('2d');
    const isRili = kind === 'shrimp' && color === 'red-rili';
    const isRedWhite = kind === 'shrimp' && color === 'red-white';
    const shades = isRili
      ? ['#812c2b','#e44934','#ffc478','#f57444','#b13b30','#9a372e','#d53f30','#f3804c','#b9bca7','#c9c3a7','#708783','#a9b4a4']
      : isRedWhite
        ? ['#752d2b','#dd4230','#f6ac63','#f2673d','#a6382c','#8b302b','#c63c2e','#ed7950','#d0d1b7','#bbc5b5','#84988e','#bfc5ae']
        : ['#6c2931','#c73e3b','#f18a66','#e65e49','#9e3035','#882d34','#b43a3c','#e76a50','#c3856e','#d89d7d','#985d56','#bd7260'];
    const variants = {yellow:['#655521','#d8ad30','#f5dc71','#e8c64a','#aa822a','#957125','#b68d2b','#e9c653','#bcaa64','#e0d4a0','#a89b6a','#bdab65'],blue:['#203e63','#367db3','#79bad9','#559ac8','#2b608c','#28577e','#2f699b','#5a9dc7','#6f9cad','#a4c4cb','#749ba8','#719da8'],orange:['#704226','#d67a32','#f1b367','#e89543','#a95b2a','#965027','#b7632c','#e99b50','#c1956a','#dec09a','#ae9273','#bd9367']};
    const recolor = c => kind === 'shrimp' && variants[color] && shades.includes(c) ? variants[color][shades.indexOf(c)] : c;
    const r = (x, y, w, h, c) => { g.fillStyle = tint(recolor(c), preset); g.fillRect(x, y, w, h); };
    const p = (points, c) => {
      g.fillStyle = tint(recolor(c), preset); g.beginPath();
      points.forEach((v, i) => i ? g.lineTo(v[0], v[1]) : g.moveTo(v[0], v[1]));
      g.closePath(); g.fill();
    };
    if (kind === 'otocinclus') {
      // Belly faces the viewer while the sucker mouth stays against the front glass.
      const pose = Math.floor(phase) % 2;
      const widths = [3,5,6,6,5,5,4,4,3,3,2,2,1];
      widths.forEach((half,i)=>{
        const y=5+i*2;
        r(14-half,y,half*2,2,'#494e3c');
        if(half>2)r(15-half,y+1,half*2-2,1,'#a3a087');
        r(13,y,2,2,i<3?'#d5c6a1':'#c1bea0');
        if(i>3&&i<9)r(12,y,4,2,'#e2d6b2');
      });
      for(const side of [-1,1]){
        for(let row=0;row<5;row++){
          const length=5-row;
          r(side<0?10-length:18,14+row+pose,length+2,1,'#6e8170');
          r(side<0?10-length:19+length,14+row+pose,1,1,'#bdc3a4');
        }
        r(side<0?8:19,8,1,2,'#202b28');
        r(side<0?8:19,8,1,1,'#d9bd77');
        for(let row=0;row<5;row++)r(side<0?13-row:14,31+row,Math.max(1,row),1,'#778474');
      }
      r(13,29,2,4,'#7e8570');
      r(12,8,4,4,'#9b8e6e');r(13,9,2,2,'#443f32');
      r(12,7,4,1,'#e0cfac');r(13,12,2,1,pose?'#b1a181':'#d2c29c');
      return {canvas,anchorX:14,anchorY:9,frameCount:2};
    }
    const step = Math.floor(phase) % 2;
    if (kind === 'shrimp') {
      const frameCount = 4;
      const pose = ((Math.floor(phase) % frameCount) + frameCount) % frameCount;
      const pixel = (x, y, w, h, color, alpha = 1) => {
        // Replace covered limb pixels so the clear shell cannot inherit their opacity.
        g.clearRect(x, y, w, h);
        g.globalAlpha = alpha;
        r(x, y, w, h, color);
        g.globalAlpha = 1;
      };
      // Rasterize one-pixel limbs directly; canvas strokes soften diagonal edges.
      const line = (points, color, alpha = 1) => {
        for (let i = 1; i < points.length; i++) {
          let [x, y] = points[i - 1];
          const [endX, endY] = points[i];
          const dx = Math.abs(endX - x), dy = -Math.abs(endY - y);
          const sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
          let error = dx + dy;
          for (;;) {
            pixel(x, y, 1, 1, typeof color === 'function' ? color(x, y) : color, typeof alpha === 'function' ? alpha(x, y) : alpha);
            if (x === endX && y === endY) break;
            const twice = error * 2;
            if (twice >= dy) { error += dy; x += sx; }
            if (twice <= dx) { error += dx; y += sy; }
          }
        }
      };
      const legs = [
        [[[18,11],[16,14],[13,17]], [[20,12],[19,14],[18,17]], [[22,12],[23,14],[22,17]], [[24,11],[26,14],[27,17]]],
        [[[18,11],[16,14],[14,16]], [[20,12],[19,14],[18,17]], [[22,12],[24,14],[23,16]], [[24,11],[26,14],[27,17]]],
        [[[18,11],[17,14],[15,17]], [[20,12],[20,14],[19,17]], [[22,12],[24,14],[24,17]], [[24,11],[26,14],[28,17]]],
        [[[18,11],[17,14],[15,17]], [[20,12],[20,14],[19,16]], [[22,12],[24,14],[24,17]], [[24,11],[26,13],[27,16]]]
      ];
      line([[18,11],[16,13],[16,16]], shades[10], isRili ? .46 : .56);
      line([[23,11],[24,13],[25,16]], shades[10], isRili ? .46 : .56);
      legs[pose].forEach(points => line(points, shades[8], isRili ? .72 : .82));
      if (isRedWhite) legs[pose].forEach(([, [x, y]]) => pixel(x, y, 1, 1, shades[1]));
      // Short, folded swimmerets belong to the abdomen, behind the walking legs.
      const swimmeret = isRili || isRedWhite ? shades[10] : shades[6];
      line([[10,10],[10,13],[12,14]], swimmeret, isRili ? .46 : .74);
      line([[13,11],[13,13],[15,14]], swimmeret, isRili ? .46 : .74);
      line([[16,11],[16,13],[17,14]], swimmeret, isRili ? .46 : .74);

      // Three small tail lobes meet a narrow peduncle instead of a broad fish tail.
      line([[7,10],[5,9],[3,8]], isRedWhite ? '#eee7c9' : shades[7]);
      line([[7,11],[4,11],[2,10]], isRedWhite ? '#c9d0b8' : shades[6]);
      line([[7,11],[5,13],[3,13]], isRedWhite ? '#c9d0b8' : shades[6]);
      pixel(4, 10, 3, 2, isRedWhite ? '#dedfc2' : shades[1]);
      pixel(4, 10, 1, 1, isRedWhite ? '#f3edd1' : shades[7]);

      const shell = { h: shades[2], m: shades[3], r: shades[1], s: shades[4], d: shades[5], c: shades[3] };
      const clearShell = { h: '#d5dccb', m: '#bfc9b6', r: '#b8c3b1', s: '#819585', d: '#657d70', c: '#b6c4b3' };
      const clearAlpha = { h: .66, m: .28, r: .18, s: .42, d: .52, c: .20 };
      const ivoryShell = { h: '#f3edd1', m: '#eeead0', r: '#dedfc4', s: '#b5c0ad', d: '#899f98', c: '#e9e7ce' };
      // These masks follow body rows; appendages and the red ends stay separate.
      const clearSpans = [[14,19],[12,19],[12,19],[11,19],[11,18],[12,18],[12,18],[13,18],null];
      const ivorySpans = [
        [[17,18]], [[11,12]], [[9,10],[12,13],[22,23]],
        [[8,9],[12,13],[22,24]], [[7,8],[13,14],[20,21],[24,25]],
        [[7,8],[13,14],[21,22],[25,25]], [[8,9],[14,15],[21,23]],
        [[14,15],[22,23]], [[23,23]]
      ];
      const shellColor = (x, y, shade) => {
        const span = clearSpans[y - 5];
        if (isRili && span && x >= span[0] && x <= span[1]) return clearShell[shade];
        if (isRedWhite && ivorySpans[y - 5]?.some(([left, right]) => x >= left && x <= right)) return ivoryShell[shade];
        return shell[shade];
      };
      const shellAlpha = (x, y, shade) => {
        const span = clearSpans[y - 5];
        return isRili && span && x >= span[0] && x <= span[1] ? clearAlpha[shade] : 1;
      };
      [
        [14, 'hhhhmm'],
        [11, 'hhmrrrrrmmm'],
        [9,  'hmrrrrrrrrmmmmm'],
        [8,  'mrrrrrrrrrrmcccccc'],
        [7,  'mrrrrrrrrrrmcccccrrr'],
        [7,  'rrrrrrrrrrrcccccrrr'],
        [8,  'srrrrrsssssccccrr'],
        [11, 'ssssddddscccdd'],
        [19, 'ddddd']
      ].forEach(([x, row], y) => [...row].forEach((shade, i) => pixel(x + i, y + 5, 1, 1, shellColor(x + i, y + 5, shade), shellAlpha(x + i, y + 5, shade))));

      // Curved seams follow the taper. They stop below the dorsal highlight.
      const seam = (x, y) => shellColor(x, y, 's');
      const seamAlpha = (x, y) => shellAlpha(x, y, 's');
      line([[10,8],[11,10],[12,11]], seam, seamAlpha);
      line([[13,7],[14,9],[15,11]], seam, seamAlpha);
      line([[17,7],[18,9],[18,11]], seam, seamAlpha);
      line([[21,8],[20,10],[20,12]], seam, seamAlpha);
      pixel(12, 7, 1, 1, isRili || isRedWhite ? shellColor(12, 7, 'h') : shades[7], shellAlpha(12, 7, 'h'));
      pixel(16, 6, 1, 1, isRili ? clearShell.h : shades[7], shellAlpha(16, 6, 'h'));
      pixel(22, 8, 2, 1, isRedWhite ? ivoryShell.h : shades[2]);
      if (isRili) {
        pixel(12, 11, 3, 1, '#b98376', .62);
        pixel(15, 11, 3, 1, '#bc8b7c', .62);
        pixel(18, 10, 1, 1, '#ad716c', .62);
      }

      // A pointed rostrum, exposed eye and two antennae establish the head.
      line([[24,8],[27,7],[29,6]], isRedWhite ? '#e7e4c8' : shades[3]);
      line([[26,9],[28,6],[31,4],[33,3]], shades[9], .66);
      line([[26,10],[30,10],[33,9]], shades[8], .72);
      pixel(isRili || isRedWhite ? 24 : 25, 8, isRili || isRedWhite ? 2 : 1, 1, '#172c2b');
      pixel(25, 11, 1, 1, shades[5]);
      line([[25,12],[27,13],[26,14]], shades[11], .72);
      return { canvas, anchorX: 17, anchorY: 16, frameCount, hasTransparency: true };
    }
    const frameCount = 4;
    const pose = ((Math.floor(phase) % frameCount) + frameCount) % frameCount;
    const pixel = (x, y, color, alpha = 1) => {
      g.globalAlpha = alpha;
      r(x, y, 1, 1, color);
      g.globalAlpha = 1;
    };
    const ray = (points, color, alpha = 1) => {
      for (let i = 1; i < points.length; i++) {
        let [x, y] = points[i - 1];
        const [endX, endY] = points[i];
        const dx = Math.abs(endX - x), dy = -Math.abs(endY - y);
        const sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
        let error = dx + dy;
        for (;;) {
          pixel(x, y, color, alpha);
          if (x === endX && y === endY) break;
          const twice = error * 2;
          if (twice >= dy) { error += dy; x += sx; }
          if (twice <= dx) { error += dx; y += sy; }
        }
      }
    };
    // Sparse clear membrane and separate vermilion rays keep the caudal fork open.
    const tailRows = [[2,2],[2,3],[2,4],[3,4],[4,4],[5,5],[7,3],[5,5],[4,4],[3,4],[2,4],[2,3]];
    const narrow = pose === 1 || pose === 3;
    tailRows.forEach(([x, width], row) => {
      const inset = narrow && (row < 5 || row > 7) ? 1 : 0;
      const lean = (pose === 2 && row < 3) || (pose === 3 && row > 8) ? 1 : 0;
      for (let i = inset; i < width; i++) pixel(x + i + lean, row + 6, '#91aaa1', .32);
    });
    const tailTips = [[[2,6],[2,17]],[[3,7],[3,16]],[[3,6],[2,17]],[[3,7],[4,16]]][pose];
    ray([tailTips[0],[6,9],[9,11]], '#9fbbb0', .48);
    ray([[tailTips[0][0]+1,tailTips[0][1]+1],[7,10],[9,11]], '#ef4930');
    ray([[4,9],[7,11],[9,12]], '#9fbbb0', .34);
    ray([tailTips[1],[6,15],[9,13]], '#8fa89e', .45);
    ray([[tailTips[1][0]+1,tailTips[1][1]-1],[7,14],[9,12]], '#e63b29');
    ray([[4,15],[7,13],[9,12]], '#8fa89e', .32);
    pixel(8, 12, '#b9322b');

    const finFold = narrow ? 1 : 0;
    const finShades = { c: ['#9eb2a5', .36], r: ['#ed452d', 1], d: ['#343e38', 1] };
    [[18,4,'cr'],[18,5,'crd'],[18,6,'crrd'],[19,7,'crrd']].forEach(([x,y,row]) => {
      [...row].forEach((shade,i) => pixel(x+i,y+finFold,...finShades[shade]));
    });
    [[17,15,'cccd'],[17,16,'ccd'],[17,17,'crd'],[17,18,'rr']].forEach(([x,y,row]) => {
      [...row].forEach((shade,i) => pixel(x+i+finFold,y-finFold,...finShades[shade]));
    });
    pixel(17+finFold, 19-finFold, '#e75132');
    ray([[25,14],[24,16],[23+finFold,17]], '#a9b6a1', .39);
    ray([[25,15],[24+finFold,16]], '#d64b32');

    // The body stays fixed while the tail and small fins alternate.
    [
      [20,8,10,'#b95036'], [15,9,19,'#e45a36'],
      [11,10,25,'#ee482e'], [9,11,28,'#e93629'],
      [9,12,29,'#e73228'], [10,13,27,'#d92e27'],
      [15,14,20,'#c8392b'], [22,15,9,'#a94d38']
    ].forEach(([x,y,w,color]) => r(x,y,w,1,color));
    r(20, 8, 7, 1, '#cc6842');
    r(15, 9, 6, 1, '#f36b42');
    r(11, 10, 5, 1, '#e95437');
    r(10, 13, 5, 1, '#a82c29');
    r(16, 13, 5, 1, '#f03e2b');
    r(23, 14, 5, 1, '#e74730');
    [[17,10],[21,9],[25,9],[28,9],[29,13]].forEach(([x,y]) => pixel(x,y,'#ed754a'));

    // Chili rasbora's lateral blotch narrows into a broken point at the tail.
    r(23, 10, 7, 1, '#24475a');
    r(18, 11, 12, 1, '#142d3b');
    r(14, 12, 15, 1, '#1c3343');
    r(22, 12, 7, 1, '#254b60');
    r(20, 11, 3, 1, '#244357');
    pixel(17,11,'#263a49');
    pixel(12,12,'#273749');
    pixel(27,10,'#3b5968');

    // A small warm iris surrounds a dark eye; the jaw is pale, never luminous.
    ray([[31,10],[30,12],[31,13]], '#b42d25');
    r(32, 13, 3, 1, '#d8815d');
    r(32, 14, 2, 1, '#b69370');
    pixel(35,13,'#cda17c');
    pixel(37,12,'#b07650');
    pixel(36,13,'#783e31');
    r(33, 9, 2, 1, '#b49a58');
    r(32, 10, 4, 2, '#bea668');
    r(33, 12, 2, 1, '#8a7750');
    r(33, 10, 2, 2, '#111b23');
    pixel(32,10,'#dfc68a');
    pixel(34,10,'#283c46');
    ray([[30,13],[28,14],[27+(pose===2?1:0),15+finFold]], '#b6b6a1', .44);
    pixel(29,14,'#d7b297',.57);
    return { canvas, anchorX: 23, anchorY: 12, frameCount };
  }
  window.AquariumAnimalArt = { createSprite };
})();
