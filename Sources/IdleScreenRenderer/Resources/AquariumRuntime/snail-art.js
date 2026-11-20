/* Original assassin-snail study. Every visible mark is an opaque source pixel. */
(() => {
  'use strict';
  const tint = (hex, preset) => {
    const gains = preset === 'warm' ? [1.08, .94, .79] : preset === 'moonlight' ? [.48, .65, .89] : [1, 1, 1];
    return '#' + hex.slice(1).match(/../g).map((value, i) => Math.min(255, Math.round(parseInt(value, 16) * gains[i])).toString(16).padStart(2, '0')).join('');
  };

  function createSprite(phase = 0, preset = 'daylight', species = 'assassin') {
    if(species==='nerite')return createNerite(phase,preset);
    const canvas = document.createElement('canvas');
    canvas.width = 36;
    canvas.height = 28;
    const g = canvas.getContext('2d');
    const palette = Object.fromEntries(Object.entries({
      h: '#e7c66d', g: '#cda346', o: '#a77c38',
      b: '#715039', d: '#44362b', a: '#302d29',
      s: '#65766e', m: '#95a69a', l: '#c2cab3', e: '#3c4b46'
    }).map(([key, color]) => [key, tint(color, preset)]));
    const r = (x, y, w, h, shade) => {
      g.fillStyle = palette[shade];
      g.fillRect(x, y, w, h);
    };
    const line = (points, shade) => {
      for (let i = 1; i < points.length; i++) {
        let [x, y] = points[i - 1];
        const [endX, endY] = points[i];
        const dx = Math.abs(endX - x), dy = -Math.abs(endY - y);
        const sx = x < endX ? 1 : -1, sy = y < endY ? 1 : -1;
        let error = dx + dy;
        for (;;) {
          r(x, y, 1, 1, shade);
          if (x === endX && y === endY) break;
          const twice = error * 2;
          if (twice >= dy) { error += dy; x += sx; }
          if (twice <= dx) { error += dx; y += sy; }
        }
      }
    };
    const rows = (startY, pixels) => pixels.forEach(([x, row], offsetY) => {
      [...row].forEach((shade, offsetX) => r(x + offsetX, startY + offsetY, 1, 1, shade));
    });
    const frameCount = 4;
    const pose = ((Math.floor(phase) % frameCount) + frameCount) % frameCount;

    // One muscular foot stays planted. Its tapered tail and level sole never step.
    rows(20, [
      [21, 'ssmmmss'],
      [12, 'ssmmmmmmmmmmmmmmmss'],
      [8,  'ssmllmmmmmmmmmmmmmmmmlms'],
      [5,  'smlllllmmmmmmmmmmmmmlllmm'],
      [3,  'smllllllllmmmmmmllllllllmms'],
      [4,  'ssmmmmmmmmmmmmmmmmmmmmmmss']
    ]);
    r(8, 24, 3, 1, 'm');
    r(15, 24, 3, 1, 'l');
    r(28, 22, 3, 1, 'l');

    // A broad siphon sits above the two fine head tentacles, ahead of the shell.
    const siphons = [
      [[27, 21], [30, 20], [33, 18], [34, 16]],
      [[27, 21], [30, 20], [33, 19], [34, 17]],
      [[27, 21], [30, 20], [33, 19], [34, 18]],
      [[27, 21], [30, 20], [33, 18], [34, 17]]
    ];
    line(siphons[pose], 's');
    line(siphons[pose].map(([x, y]) => [x, y - 1]), 'l');
    const feelers = [
      [[[29, 22], [32, 21], [34, 21]], [[29, 23], [32, 24], [33, 24]]],
      [[[29, 22], [32, 21], [34, 20]], [[29, 23], [32, 24], [33, 24]]],
      [[[29, 22], [32, 22], [34, 21]], [[29, 23], [32, 24], [34, 24]]],
      [[[29, 22], [32, 22], [34, 21]], [[29, 23], [32, 23], [34, 24]]]
    ];
    line(feelers[pose][0], 'm');
    line(feelers[pose][1], 's');
    r(29, 22, 1, 1, 'e');

    // Expanding diagonal bands wrap a leaning cone, with a broad final whorl.
    rows(2, [
      [7,  'ho'],
      [7,  'hgo'],
      [7,  'oggbd'],
      [7,  'oobbbo'],
      [8,  'ddbggghd'],
      [8,  'ddggggbbbd'],
      [8,  'dogggbbbbhho'],
      [9,  'oogbbbbgghhhd'],
      [9,  'oobbbbgggghbbbd'],
      [10, 'ddbbgggggbbbbbho'],
      [10, 'ddbgggggbbbbbhhho'],
      [10, 'ddgggggbbbbbhhhhho'],
      [11, 'oogggbbbbbgghhhhbd'],
      [11, 'ooggbbbbbggghhhbbd'],
      [12, 'oobbbbbggggghbbbd'],
      [13, 'ddbbbggggggbbbbd'],
      [13, 'ddbbggggggbbbbbo'],
      [14, 'ddoooooodddddoo'],
      [15, 'oooooodddddoo'],
      [16, 'oooodddddooo'],
      [18, 'odddddooo']
    ]);
    // Short whorl lips make the spiral readable without outlining every band.
    line([[9, 5], [11, 5], [13, 6]], 'h');
    line([[12, 8], [15, 8], [18, 9]], 'h');
    line([[15, 11], [19, 11], [22, 13]], 'o');
    r(21, 14, 2, 1, 'h');
    r(20, 15, 1, 1, 'h');
    line([[23, 20], [24, 22], [26, 23], [28, 22]], 'a');
    line([[25, 20], [26, 21], [27, 21], [28, 20]], 'o');

    return { canvas, anchorX: 18, anchorY: 26, frameCount };
  }

  function createNerite(phase,preset){
    const canvas=document.createElement('canvas');canvas.width=32;canvas.height=26;const g=canvas.getContext('2d');
    const pixel=(x,y,color)=>{g.fillStyle=tint(color,preset);g.fillRect(x,y,1,1);};
    for(let y=19;y<24;y++)for(let x=4;x<29;x++)if((x-16)**2/169+(y-21)**2/10<1)pixel(x,y,y===19?'#7b8475':'#adb29c');
    for(let y=4;y<22;y++)for(let x=5;x<27;x++){
      const dx=(x-15)/10,dy=(y-13)/9;if(dx*dx+dy*dy>1)continue;
      const stripe=Math.sin(Math.atan2(dy,dx)*7+Math.hypot(dx,dy)*5)>.15;
      pixel(x,y,stripe?(y<12?'#423d2d':'#292f29'):(y<12?'#d4ac62':'#a88348'));
    }
    for(let i=0;i<5;i++){pixel(26+i,20-Math.floor(i/2)-(phase%2),'#a8b4a0');pixel(26+i,22+Math.floor(i/3),'#7d8e7a');}
    pixel(26,21,'#293930');return{canvas,anchorX:16,anchorY:24,frameCount:4};
  }
  window.AquariumSnailArt = { createSprite };
})();
