(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumMetricBasicArt = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function create(THREE, { tankHalf = 7, cmPerUnit = 36 / 8.4, backZ = -4.36, frontZ = 4.04,
    waterLevel = 8.05, bedLevel = .7, rimY = 8.4 } = {}) {
    if (!Number.isFinite(cmPerUnit) || cmPerUnit <= 0) throw new RangeError('cmPerUnit must be positive and finite');
    const u = cm => cm / cmPerUnit;
    if (![tankHalf, backZ, frontZ, waterLevel, bedLevel, rimY].every(Number.isFinite)) throw new RangeError('Tank dimensions must be finite');
    if (tankHalf < u(20) || frontZ - backZ < u(20)) throw new RangeError('Basic assembly requires at least 40 by 20 cm floor area');
    if (bedLevel < 0 || waterLevel - bedLevel < u(28.9) || rimY - waterLevel < u(.8)) throw new RangeError('28 cm heater requires 28.9 cm water above substrate and .8 cm headspace');
    const wetGroup = new THREE.Group(), dryGroup = new THREE.Group();
    wetGroup.name = 'metric-basic-wet'; dryGroup.name = 'metric-basic-dry';
    const geometries = [], materials = [], maps = [], batches = new Map(), parts = {}, stack = [], routes = {}, mounts = [];
    const tags = { solid: true, equipmentSolid: true, hardEquipment: true, hardscape: false, climbable: false };
    function group(name, parent) { const g = new THREE.Group(); g.name = name; g.userData = { ...tags }; parent.add(g); return g; }
    const filter = group('sponge-filter', wetGroup), heater = group('aquarium-heater', wetGroup), thermometer = group('aquarium-thermometer', wetGroup);
    const riser = group('filter-riser-above-water', dryGroup), lines = group('basic-over-rim-lines', dryGroup);
    function material(name, color, options = {}) {
      const m = new THREE.MeshPhongMaterial({ color, flatShading: true, shininess: 8, ...options }); m.name = name; materials.push(m); return m;
    }
    function map(width, height, pixel) {
      const data = new Uint8Array(width * height * 4);
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) data.set([...pixel(x, y), 255], (y * width + x) * 4);
      const texture = new THREE.DataTexture(data, width, height); texture.colorSpace = THREE.SRGBColorSpace;
      texture.minFilter = texture.magFilter = THREE.NearestFilter; texture.generateMipmaps = false; texture.needsUpdate = true; maps.push(texture); return texture;
    }
    const foamMap = map(64, 64, (x, y) => { const n = ((x * 73856093 ^ y * 19349663) >>> 0) % 13; return n < 3 ? [25, 39, 30] : n < 8 ? [48, 65, 48] : [64, 80, 59]; });
    foamMap.wrapS = foamMap.wrapT = THREE.RepeatWrapping;
    const scaleMap = map(16, 128, (x, y) => {
      const row = Math.floor(y / 8), tick = y >= 16 && y <= 113 && y % 8 < 2 && (x < (row % 2 ? 4 : 6) || x > (row % 2 ? 11 : 9));
      return tick ? [80, 92, 81] : y > 42 && y < 62 ? [148, 167, 114] : [223, 221, 193];
    });
    const black = material('basic-rubber', 0x303c3e), green = material('filter-green', 0x315640), joint = material('filter-joint', 0x244b3b);
    const clear = material('filter-clear', 0x82b69a, { transparent: true, opacity: .32, depthWrite: false, side: THREE.DoubleSide, shininess: 38 });
    const foam = material('filter-foam', 0xc9d1c6, { map: foamMap, shininess: 0 });
    const ribs = material('heater-ribs', 0x465355), blue = material('heater-dial', 0x246e9c), coil = material('heater-coil', 0x867b65);
    const ceramic = material('heater-ceramic', 0x89958b), reflection = material('heater-reflection', 0x637f80), amber = material('heater-indicator', 0xb48137);
    const glass = material('basic-glass', 0xadc7bc, { transparent: true, opacity: .20, depthWrite: false, shininess: 30 });
    const pale = material('thermometer-scale', 0xffffff, { map: scaleMap }), red = material('thermometer-liquid', 0xa73628), weight = material('thermometer-weight', 0x626a60);
    const dryBlack = material('basic-dry-rubber', 0x303c3e), dryJoint = material('basic-dry-joint', 0x244b3b);
    function part(id, draw) { parts[id] = { ranges: [] }; stack.push(id); draw(); stack.pop(); }
    function add(parent, m, geometry, position = [0, 0, 0], quaternion = new THREE.Quaternion()) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...position), quaternion, new THREE.Vector3(1, 1, 1)));
      const flat = geometry.index ? geometry.toNonIndexed() : geometry, name = parent.name + '/' + m.name;
      if (!batches.has(name)) batches.set(name, { parent, m, positions: [], normals: [], uv: [] });
      const b = batches.get(name), start = b.positions.length / 3, count = flat.attributes.position.count;
      for (const id of stack) parts[id].ranges.push({ mesh: name, start, count });
      b.positions.push(...flat.attributes.position.array); b.normals.push(...flat.attributes.normal.array);
      if (flat.attributes.uv) b.uv.push(...flat.attributes.uv.array); else for (let i = 0; i < count; i++) b.uv.push(0, 0);
      if (flat !== geometry) flat.dispose(); geometry.dispose();
    }
    function box(g, m, w, h, d, p) { add(g, m, new THREE.BoxGeometry(u(w), u(h), u(d)), p); }
    function cylinder(g, m, a, b, r, endR = r, sides = 12, open = false) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), axis = end.clone().sub(start);
      add(g, m, new THREE.CylinderGeometry(u(endR), u(r), axis.length(), sides, 1, open), start.add(end).multiplyScalar(.5).toArray(),
        new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.normalize()));
    }
    function pipe(g, m, points, outerCm, innerCm = 0, sides = 8) {
      const positions = [], indices = [], uv = []; let lastNormal;
      const shells = innerCm ? 2 : 1, stride = shells * sides;
      for (let i = 0; i < points.length; i++) {
        const p = new THREE.Vector3(...points[i]), tangent = new THREE.Vector3(...points[Math.min(i + 1, points.length - 1)])
          .sub(new THREE.Vector3(...points[Math.max(0, i - 1)])).normalize();
        let normal = lastNormal?.clone().addScaledVector(tangent, -lastNormal.dot(tangent));
        if (!normal || normal.lengthSq() < 1e-7) normal = new THREE.Vector3(Math.abs(tangent.y) < .9 ? 0 : 1, Math.abs(tangent.y) < .9 ? 1 : 0, 0).cross(tangent);
        normal.normalize(); lastNormal = normal; const binormal = new THREE.Vector3().crossVectors(tangent, normal).normalize();
        for (let shell = 0; shell < shells; shell++) for (let j = 0; j < sides; j++) {
          const angle = j / sides * Math.PI * 2, radius = u(shell ? innerCm : outerCm) / 2;
          positions.push(...p.clone().addScaledVector(normal, radius * Math.cos(angle)).addScaledVector(binormal, radius * Math.sin(angle)).toArray()); uv.push(j / sides, i / (points.length - 1));
        }
      }
      for (let i = 0; i < points.length - 1; i++) for (let shell = 0; shell < shells; shell++) for (let j = 0; j < sides; j++) {
        const a = i * stride + shell * sides + j, b = i * stride + shell * sides + (j + 1) % sides, c = a + stride, d = b + stride;
        indices.push(...(shell ? [a, c, b, b, c, d] : [a, b, c, b, d, c]));
      }
      for (const end of [0, points.length - 1]) for (let j = 0; j < sides; j++) {
        const a = end * stride + j, b = end * stride + (j + 1) % sides;
        if (innerCm) { const c = a + sides, d = b + sides; indices.push(...(end ? [a, c, b, b, c, d] : [a, b, c, b, d, c])); }
        else { const c = positions.length / 3; positions.push(...points[end]); uv.push(.5, .5); indices.push(...(end ? [a, c, b] : [a, b, c])); }
      }
      const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
      geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); geometry.setIndex(indices); geometry.computeVertexNormals(); add(g, m, geometry);
    }

    const innerBack = backZ + u(.6), innerFront = frontZ - u(.6);
    const fx = tankHalf - u(11), fz = innerBack + u(6), hx = tankHalf - u(3.2), hz = innerBack + u(2.5);
    const F = (x, y, z) => [fx + u(x), bedLevel + u(y), fz + u(z)];
    part('filter-weight', () => {
      cylinder(filter, black, F(0, 0, 0), F(0, .28, 0), 4.9, 5.08, 28);
      cylinder(filter, green, F(0, .28, 0), F(0, 1.2, 0), 5.08, 5.08, 28);
      cylinder(filter, green, F(0, 1.2, 0), F(0, 1.5, 0), 5.08, 3.9, 28);
    });
    cylinder(filter, joint, F(0, 1.4, 0), F(0, 3.05, 0), 1.55, 1.12);
    part('filter-foam', () => {
      const columns = 28, rows = 16, radius = 4.445, bottom = 2.8, top = 12.96, positions = [], uv = [];
      let seed = 6143; const rand = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
      const blend = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
      function triangle(a, b, c) { for (const p of [a, b, c]) { positions.push(...F(...p)); uv.push(p[0] / 2 + .5, p[1] / 2); } }
      function pore(corners, normal) {
        const outer = []; for (let i = 0; i < 4; i++) outer.push(corners[i], blend(corners[i], corners[(i + 1) % 4], .5));
        const center = blend(blend(corners[0], corners[2], .5), blend(corners[1], corners[3], .5), .5);
        const inner = outer.map(p => blend(center, p, .57 + rand() * .18)), depth = .16 + rand() * .10, floor = center.map((v, i) => v - normal[i] * depth);
        for (let i = 0; i < 8; i++) { const j = (i + 1) % 8; triangle(outer[i], outer[j], inner[j]); triangle(outer[i], inner[j], inner[i]); triangle(inner[i], inner[j], floor); }
      }
      function node(row, col) { const a = col * 2 * Math.PI / columns; return [Math.sin(a) * radius, bottom + row * (top - bottom) / rows, Math.cos(a) * radius]; }
      for (let row = 0; row < rows; row++) for (let col = 0; col < columns; col++) {
        const a = (col + .5) * Math.PI * 2 / columns;
        pore([node(row, col), node(row, col + 1), node(row + 1, col + 1), node(row + 1, col)], [Math.sin(a), 0, Math.cos(a)]);
      }
      function cap(ring, col) { const r = 1.2 + (radius - 1.2) * ring / 2, a = col * 2 * Math.PI / columns; return [Math.sin(a) * r, top, Math.cos(a) * r]; }
      for (let ring = 0; ring < 2; ring++) for (let col = 0; col < columns; col++) pore([cap(ring, col), cap(ring + 1, col), cap(ring + 1, col + 1), cap(ring, col + 1)], [0, 1, 0]);
      const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
      geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2)); geometry.computeVertexNormals(); add(filter, foam, geometry);
      cylinder(filter, foam, F(0, bottom, 0), F(0, top - .3, 0), radius - .32, radius - .32, 28);
    });
    cylinder(filter, green, F(0, 12.88, 0), F(0, 13.22, 0), 1.62);
    cylinder(filter, joint, F(0, 13.18, 0), F(0, 14.35, 0), 1.23, .9);
    cylinder(filter, joint, F(.8, 13.85, .1), F(1.45, 14.15, .1), .30, .25, 8);
    cylinder(filter, joint, F(1.45, 14.12, .1), F(1.45, 15.0, .1), .22, .18, 8);
    for (const y of [14.5, 14.73]) cylinder(filter, joint, F(1.45, y, .1), F(1.45, y + .12, .1), .25, .25, 8);

    const outletY = waterLevel - u(1.25 / 6), bendRadius = u(2.5), bendY = outletY - bendRadius;
    const returnPoints = [F(0, 14.25, 0), [fx, bendY - u(.5), fz], [fx, bendY, fz]];
    for (let i = 1; i <= 12; i++) { const a = i * Math.PI / 24; returnPoints.push([fx - bendRadius + bendRadius * Math.cos(a), bendY + bendRadius * Math.sin(a), fz]); }
    returnPoints.push([fx - u(4.1), outletY, fz]);
    part('filter-return', () => pipe(riser, clear, returnPoints, 1.5, 1.25, 12));
    for (const t of [.08, .53]) { const y = bedLevel + u(14.25) + (bendY - bedLevel - u(14.25)) * t; cylinder(riser, dryJoint, [fx, y, fz], [fx, y + u(.65), fz], .93, .93, 12, true); }
    routes.filterReturn = { points: returnPoints, outerDiameterCm: 1.5, innerDiameterCm: 1.25 };
    const filterOutlet = { x: fx - u(4.1), y: outletY, z: fz }, filterOutletDirection = { x: -1, y: 0, z: 0 };

    const heaterTop = waterLevel - u(.5), heaterBottom = heaterTop - u(28), H = (x, y, z) => [hx + u(x), heaterBottom + u(y), hz + u(z)];
    part('heater-body', () => {
      cylinder(heater, black, H(0, 6.5, 0), H(0, 22.9, 0), .9, .9);
      cylinder(heater, black, H(0, 22.6, 0), H(0, 27, 0), .98, 1.23);
      for (let i = 0; i < 7; i++) { const y = 23.2 + i * .51, r = 1.03 + i * .035; cylinder(heater, ribs, H(0, y, 0), H(0, y + .18, 0), r, r); }
      cylinder(heater, black, H(0, 26.95, 0), H(0, 27.15, 0), 1.25);
      cylinder(heater, blue, H(-.1, 27.15, .08), H(-.1, 27.32, .08), .55, .51, 8);
      box(heater, blue, .58, .68, .48, H(-.1, 27.66, .08));
      cylinder(heater, black, H(0, 1.4, 0), H(0, 7.1, 0), .61, .61, 8);
      cylinder(heater, ceramic, H(0, 1.5, .16), H(0, 7.0, .16), .39, .39, 8);
      for (const x of [-.32, .32]) {
        cylinder(heater, coil, H(x, 2, .40), H(x, 6.9, .40), .17, .17, 6);
        for (let i = 0; i < 16; i++) cylinder(heater, coil, H(x, 2 + i * .30, .40), H(x, 2.10 + i * .30, .40), .25, .25, 6);
      }
      cylinder(heater, glass, H(0, 1.25, 0), H(0, 7.1, 0), .88);
      box(heater, reflection, .12, 5.2, .08, H(-.67, 4.15, .50));
      box(heater, reflection, .07, 2.3, .07, H(.71, 5.1, .44));
      cylinder(heater, ceramic, H(0, .6, 0), H(0, 1.6, 0), .63, .75);
      cylinder(heater, black, H(0, 0, 0), H(0, .42, 0), .64, .87);
      cylinder(heater, black, H(0, 1.5, 0), H(0, 1.8, 0), .94);
      for (let i = 0; i < 8; i++) { const a = i * Math.PI / 4; cylinder(heater, black, H(Math.sin(a) * .70, .3, Math.cos(a) * .70), H(Math.sin(a) * .84, 1.7, Math.cos(a) * .84), .12, .12, 6); }
      box(heater, amber, .18, .21, .05, H(-.03, 17.3, .91));
      box(heater, ceramic, .45, .08, .04, H(-.13, 16.2, .90));
      box(heater, ceramic, .30, .06, .04, H(-.18, 15.9, .90));
      cylinder(heater, black, H(.53, 26.4, -.35), H(.58, 27.8, -.40), .24, .19, 8);
    });
    for (const [name, y] of [['lower', 9.4], ['upper', 20.4]]) part('heater-mount-' + name, () => {
      cylinder(heater, black, [hx, heaterBottom + u(y), innerBack], H(0, y, -2.32), 1.25, 1.2);
      cylinder(heater, black, H(0, y, -2.32), H(0, y, -1.75), 1.2, .40);
      cylinder(heater, black, H(0, y, -1.78), H(0, y, -.65), .35);
      box(heater, ribs, 1.95, .75, .65, H(0, y, -.70));
      cylinder(heater, black, H(0, y - .38, 0), H(0, y + .38, 0), .98);
    });

    const tx = -tankHalf + u(4), ty = waterLevel - u(17), tz = innerFront - u(1.7), T = (x, y, z) => [tx + u(x), ty + u(y), tz + u(z)];
    part('thermometer-body', () => {
      const profile = [[0, 0], [.24, .08], [.40, .31], [.48, .72], [.48, 13.38], [.42, 13.75], [.24, 13.96], [0, 14]];
      add(thermometer, glass, new THREE.LatheGeometry(profile.map(([r, y]) => new THREE.Vector2(u(r), u(y))), 12), T(0, 0, 0));
      cylinder(thermometer, weight, T(0, .36, 0), T(0, 1.65, 0), .31, .35, 8);
      box(thermometer, pale, .65, 8.5, .10, T(0, 7.2, -.03));
      const sphere = new THREE.SphereGeometry(u(.23), 8, 6); sphere.scale(.88, 1.75, .88); add(thermometer, red, sphere, T(0, 2.14, .17));
      cylinder(thermometer, red, T(0, 2.14, .17), T(0, 8.27, .17), .075, .075, 6);
    });
    part('thermometer-mount', () => {
      add(thermometer, black, new THREE.TorusGeometry(u(.52), u(.08), 4, 12, Math.PI * 1.6), T(0, 12.35, 0),
        new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), Math.PI / 2));
      cylinder(thermometer, black, T(0, 12.35, .44), T(0, 12.35, 1.1), .23);
      cylinder(thermometer, black, T(0, 12.35, .98), T(0, 12.35, 1.6), .25, 1.02);
      cylinder(thermometer, black, T(0, 12.35, 1.6), T(0, 12.35, 1.7), 1.02);
    });

    function overRim(name, start, laneX, outerCm, m) {
      const radius = u(outerCm / 2), high = rimY + u(.5), inside = innerBack + u(.9), outside = backZ - u(.9);
      const approachY = waterLevel - u(.4);
      const points = [start, [laneX, Math.min(start[1] + u(.8), (start[1] + approachY) / 2), start[2]], [laneX, approachY, inside],
        [laneX, high, inside], [laneX, high + u(.1), innerBack + u(.2)], [laneX, high + u(.1), backZ - u(.2)],
        [laneX, high, outside], [laneX, rimY - u(.7), outside]];
      if (radius >= u(.9)) throw new RangeError('Line cannot fit rim clearance');
      part(name, () => pipe(lines, m, points, outerCm, 0, 8)); routes[name] = { points, outerDiameterCm: outerCm };
      const p = points.at(-1); return { x: p[0], y: p[1], z: p[2] };
    }
    const airlineEnd = overRim('airline', F(1.45, 14.94, .1), fx + u(1.45), .6, dryJoint);
    const heaterEnd = overRim('heaterCable', H(.58, 27.74, -.40), hx + u(.58), .5, dryBlack);
    function rimClip(id, x) {
      const wall = .18, high = rimY + u(.18), bottom = rimY - u(.9);
      part(id, () => {
        box(lines, dryBlack, .85, (high - bottom) * cmPerUnit, wall, [x, (high + bottom) / 2, backZ - u(wall / 2)]);
        box(lines, dryBlack, .85, (high - bottom) * cmPerUnit, wall, [x, (high + bottom) / 2, innerBack + u(wall / 2)]);
        box(lines, dryBlack, .85, wall, .6 + wall * 2, [x, high + u(wall / 2), (backZ + innerBack) / 2]);
      });
      mounts.push({ id, outerFaceZ: backZ, innerFaceZ: innerBack, bridgeBottom: high });
    }
    rimClip('airline-rim-clip', airlineEnd.x); rimClip('heater-rim-clip', heaterEnd.x);
    filter.userData.airEnd = [airlineEnd.x, airlineEnd.y, airlineEnd.z]; heater.userData.powerEnd = [heaterEnd.x, heaterEnd.y, heaterEnd.z];
    for (const [name, b] of batches) {
      const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(b.positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(b.normals, 3)); geometry.setAttribute('uv', new THREE.Float32BufferAttribute(b.uv, 2));
      geometry.computeBoundingBox(); geometry.computeBoundingSphere(); const mesh = new THREE.Mesh(geometry, b.m);
      mesh.name = name; mesh.userData = { ...tags }; mesh.castShadow = !b.m.transparent; mesh.receiveShadow = true; b.parent.add(mesh); geometries.push(geometry);
    }
    const dimensions = {
      filter: { model: 'Medium Easy Flow coarse', status: 'manufacturer-chart', foamDiameterCm: 8.89, foamHeightCm: 10.16, baseDiameterCm: 10.16,
        untrimmedHeightRangeCm: [30.48, 55.88], installedHeightCm: (outletY + u(.75) - bedLevel) * cmPerUnit,
        trimmedRiser: (outletY + u(.75) - bedLevel) * cmPerUnit < 30.48,
        source: 'https://www.aquariumcoop.com/cdn/shop/files/small_sponge_filter_graphic_chart_update.jpg?v=1724958521' },
      heater: { model: 'Generic heater with M50 dimensional envelope', status: 'manufacturer-dimensional-envelope', bodyCm: [2.5, 28, 2.5],
        source: 'https://fluvalaquatics.com/us/shop/product/m50-submersible-heater-50w-up-to-15-us-gal-50-l', sourceFetchVerified: true },
      thermometer: { model: 'Authored slim glass thermometer', status: 'authored', lengthCm: 14, diameterCm: .96 },
      authored: { filterBaseHeightCm: 1.5, foamBottomAboveBedCm: 2.8, riserOuterInnerCm: [1.5, 1.25], airlineDiameterCm: .6,
        heaterCableDiameterCm: .5, heaterSubmergenceCm: .5, glassThicknessCm: .6, rimClipWallCm: .18 }
    };
    const resources = { geometries, materials, maps };
    wetGroup.userData = { cmPerUnit, dimensions }; dryGroup.userData = { cmPerUnit, routes, mounts, dimensions };
    let disposed = false;
    function dispose() { if (disposed) return; disposed = true; for (const resource of [...geometries, ...materials, ...maps]) resource.dispose(); }
    return { wetGroup, dryGroup, resources, geometries, materials, maps, parts, routes, mounts, dimensions,
      filterOutlet, filterOutletDirection, heaterEnd, airlineEnd, dispose };
  }
  return { create };
});
