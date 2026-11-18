(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumPlantVarieties = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  function create(THREE, { species, seed = 913, growth = 1 } = {}) {
    if (!['vallisneria', 'alternanthera'].includes(species)) throw new RangeError('Plant species must be vallisneria or alternanthera.');
    if (!Number.isFinite(seed) || !Number.isFinite(growth) || growth <= 0 || growth > 1) throw new RangeError('Plant seed must be finite and growth must be within (0, 1].');
    const originalSeed = seed >>> 0;
    seed = originalSeed;
    const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
    const group = new THREE.Group(), geometries = [], materials = [], maps = [], grazeSites = [];
    group.name = 'plant-variety-' + species;
    Object.assign(group.userData, { species, softPlant: true, substratePlant: true });
    const botany = { species, seed: originalSeed, growth, crowns: [], roots: [], stems: [], blades: [], leaves: [] };
    group.userData.botany = botany;
    const batches = Object.fromEntries(['roots', 'stems', 'foliage'].map(name => [name, { name, p: [], c: [], uv: [], index: [] }]));
    const rootColor = new THREE.Color(0x929277), stemColor = new THREE.Color(species === 'vallisneria' ? 0x5c7938 : 0x886451);
    const greens = [0x6e8c3d, 0x7e984a, 0x5b7b35, 0x8ca557].map(hex => new THREE.Color(hex));
    const reds = [0x9b5556, 0xa96256, 0x89505c, 0xb46d61].map(hex => new THREE.Color(hex));
    const scaled = p => p.map(n => n * growth);
    const vector = new THREE.Vector3(), tangent = new THREE.Vector3(), lateral = new THREE.Vector3(), cross = new THREE.Vector3();
    const referenceY = new THREE.Vector3(0, 1, 0), referenceX = new THREE.Vector3(1, 0, 0);

    function vertex(batch, p, color, u = .5, v = .5, shade = 1) {
      const i = batch.p.length / 3;
      batch.p.push(...p); batch.c.push(color.r * shade, color.g * shade, color.b * shade); batch.uv.push(u, v);
      return i;
    }
    function contact(batch, index, kind, parent, radius) {
      const position = batch.p.slice(index * 3, index * 3 + 3), id = species + '-site-' + grazeSites.length;
      const site = { id, kind, position: [...position], rest: position, normal: [0, 1, 0], meshName: 'plant-variety-' + batch.name, vertex: index, links: [], radius };
      if (parent) { site.links.push(parent.id); parent.links.push(id); }
      grazeSites.push(site); return site;
    }
    function tube(batch, points, radius, color, sides = 5) {
      const start = batch.p.length / 3, rings = [];
      for (let i = 0; i < points.length; i++) {
        const a = points[Math.max(0, i - 1)], b = points[Math.min(points.length - 1, i + 1)];
        tangent.set(b[0] - a[0], b[1] - a[1], b[2] - a[2]).normalize();
        lateral.crossVectors(Math.abs(tangent.y) > .95 ? referenceX : referenceY, tangent).normalize();
        cross.crossVectors(tangent, lateral);
        const r = radius * (1 - .68 * i / (points.length - 1));
        rings.push(batch.p.length / 3);
        for (let j = 0; j < sides; j++) {
          const angle = j * 2 * Math.PI / sides, x = Math.cos(angle) * r, y = Math.sin(angle) * r;
          vertex(batch, [points[i][0] + lateral.x * x + cross.x * y, points[i][1] + lateral.y * x + cross.y * y, points[i][2] + lateral.z * x + cross.z * y], color);
        }
        if (i) for (let j = 0; j < sides; j++) {
          const a = rings[i - 1] + j, b = rings[i] + j, c = rings[i] + (j + 1) % sides, d = rings[i - 1] + (j + 1) % sides;
          batch.index.push(a, b, c, a, c, d);
        }
      }
      const base = vertex(batch, points[0], color), tip = vertex(batch, points.at(-1), color);
      for (let j = 0; j < sides; j++) batch.index.push(base, rings[0] + (j + 1) % sides, rings[0] + j, tip, rings.at(-1) + j, rings.at(-1) + (j + 1) % sides);
      return { range: { start, count: batch.p.length / 3 - start }, rings, base, tip };
    }

    const crowns = [[-.18, 0, -.07], [.06, 0, .12], [.22, 0, -.08]].map(scaled);
    botany.crowns.push(...crowns);
    const crownSites = [];
    for (const crown of crowns) {
      const [x, y, z] = crown, depth = (.40 + random() * .18) * growth;
      const rootPaths = [
        [crown, [x - .04 * growth, y - depth * .43, z + .055 * growth], [x - .16 * growth, y - depth, z + .13 * growth]],
        [crown, [x + .07 * growth, y - depth * .48, z - .06 * growth], [x + .15 * growth, y - depth * .88, z - .17 * growth]]
      ];
      rootPaths.push([rootPaths[0][1], [x - .20 * growth, y - depth * .85, z + .02 * growth]]);
      for (const path of rootPaths) {
        const result = tube(batches.roots, path, .012 * growth, rootColor, 4);
        botany.roots.push({ path, range: result.range });
      }
      const crownPath = [crown, [x, .11 * growth, z]];
      const sheath = tube(batches.stems, crownPath, .029 * growth, stemColor, 5);
      crownSites.push(contact(batches.stems, sheath.base, 'crown', null, .035 * growth));
      botany.stems.push({ id: 'crown-' + crownSites.length, parent: null, path: crownPath, range: sheath.range });
    }

    if (species === 'vallisneria') {
      for (let i = 0; i < 12; i++) {
        const base = crowns[i % crowns.length], height = (i === 0 ? 6.32 + random() * .25 : 4.85 + random() * 1.55) * growth;
        const width = (.14 + random() * .065) * growth, bend = (.65 + random() * .73) * growth;
        const yaw = i * 2.399 + random() * .35, twist = (random() - .5) * 1.2, segments = 25;
        const batch = batches.foliage, start = batch.p.length / 3, color = greens[i % greens.length];
        const first = vertex(batch, base, color, 0, .5, .72), centers = [base], rows = [];
        let parent = contact(batch, first, 'blade-base', crownSites[i % crowns.length], width * .2);
        for (let row = 1; row < segments; row++) {
          const t = row / segments, angle = yaw + twist * Math.sin(Math.PI * t);
          const center = [base[0] + Math.cos(yaw) * bend * t * t, height * Math.sin(t * Math.PI / 2), base[2] + Math.sin(yaw) * bend * t * t];
          centers.push(center); rows.push(batch.p.length / 3);
          const half = width * .5 * Math.min(1, t * 8) * (1 - .45 * t ** 8), ridge = .016 * growth * Math.sin(Math.PI * t);
          for (const across of [-1, 0, 1]) {
            const p = [center[0] + Math.sin(angle) * half * across + Math.cos(angle) * ridge * (1 - Math.abs(across)), center[1], center[2] - Math.cos(angle) * half * across + Math.sin(angle) * ridge * (1 - Math.abs(across))];
            const index = vertex(batch, p, color, t, across * .5 + .5, across === 0 ? 1.03 : .9 + t * .08);
            if (across === 0) parent = contact(batch, index, 'leaf', parent, half * .65);
          }
          if (row === 1) batch.index.push(first, rows[0] + 1, rows[0], first, rows[0] + 2, rows[0] + 1);
          else for (let k = 0; k < 2; k++) {
            const a = rows[row - 2] + k, b = rows[row - 1] + k;
            batch.index.push(a, b + 1, b, a, a + 1, b + 1);
          }
        }
        const tip = [base[0] + Math.cos(yaw) * bend, height, base[2] + Math.sin(yaw) * bend];
        const last = vertex(batch, tip, color, 1, .5, 1.06);
        batch.index.push(rows.at(-1), rows.at(-1) + 1, last, rows.at(-1) + 1, rows.at(-1) + 2, last);
        centers.push(tip);
        botany.blades.push({ base, tip, height, width, path: centers, range: { start, count: batch.p.length / 3 - start } });
      }
    } else {
      function redLeaf(base, length, yaw, lift, color, parent, pairIndex) {
        const batch = batches.foliage, start = batch.p.length / 3, width = length * (.49 + random() * .10);
        const outline = [[0, 0], [.16, -.28], [.43, -.5], [.76, -.34], [1, 0], [.76, .34], [.43, .5], [.16, .28]];
        const center = [.48, 0];
        function point(u, v, skin) {
          const arch = Math.sin(Math.PI * u), side = width * v;
          return [base[0] + Math.cos(yaw) * length * u - Math.sin(yaw) * side,
            base[1] + length * lift * u + arch * (.036 * growth - Math.abs(v) * .025 * growth + skin * .006 * growth),
            base[2] + Math.sin(yaw) * length * u + Math.cos(yaw) * side];
        }
        for (const skin of [1, -1]) {
          for (const [u, v] of [...outline, center]) vertex(batch, point(u, v, skin), color, u, v + .5, skin > 0 ? 1 : .77);
        }
        for (let j = 0; j < 8; j++) {
          const next = (j + 1) % 8;
          batch.index.push(start + 8, start + next, start + j, start + 17, start + j + 9, start + next + 9);
          if (j !== 0 && j !== 4) batch.index.push(start + j, start + next, start + j + 9);
          if (next !== 0 && next !== 4) batch.index.push(start + next, start + next + 9, start + j + 9);
        }
        contact(batch, start + 8, 'leaf', parent, width * .28);
        const tip = point(1, 0, 1);
        botany.leaves.push({ base, tip, length, width, pairIndex, range: { start, count: batch.p.length / 3 - start } });
      }
      function shoot(path, parent, parentId, leafNodes, yaw, stemId) {
        const tubeResult = tube(batches.stems, path, .025 * growth, stemColor, 5);
        const sites = [];
        for (let i = 0; i < path.length; i++) {
          const site = contact(batches.stems, i === 0 ? tubeResult.base : tubeResult.rings[i], 'stem', i ? sites[i - 1] : parent, .025 * growth);
          sites.push(site);
        }
        botany.stems.push({ id: stemId, parent: parentId, path, range: tubeResult.range });
        for (const node of leafNodes) {
          const young = node === path.length - 1, length = (young ? .35 + random() * .06 : .53 + random() * .14) * growth;
          const angle = yaw + node * Math.PI / 2 + (random() - .5) * .14, color = reds[(node + stemId.length) % reds.length];
          for (let side = 0; side < 2; side++) redLeaf(path[node], length, angle + side * Math.PI, young ? .36 : .28 + random() * .35, color, sites[node], node);
        }
        return sites;
      }
      for (let i = 0; i < crowns.length; i++) {
        const base = crowns[i], yaw = i * 2.399 + random() * .6, height = (i === 1 ? 2.82 + random() * .12 : 2.44 + random() * .25) * growth;
        const reach = (.16 + random() * .12) * growth;
        const path = Array.from({ length: 9 }, (_, j) => {
          const t = j / 8;
          return [base[0] + Math.cos(yaw) * reach * t * t, height * t, base[2] + Math.sin(yaw) * reach * t * t];
        });
        const sites = shoot(path, crownSites[i], null, [1, 2, 3, 4, 5, 6, 7, 8], yaw, 'main-' + i);
        const origin = path[3], branchYaw = yaw + 1.1, branchHeight = (1.03 + random() * .18) * growth, branchReach = (.44 + random() * .12) * growth;
        const branch = Array.from({ length: 6 }, (_, j) => {
          const t = j / 5;
          return [origin[0] + Math.cos(branchYaw) * branchReach * t, origin[1] + branchHeight * t, origin[2] + Math.sin(branchYaw) * branchReach * t];
        });
        shoot(branch, sites[3], 'main-' + i, [2, 3, 5], yaw + .7, 'branch-' + i);
      }
    }

    const pixels = new Uint8Array(16 * 32 * 4), shades = [221, 233, 242, 227];
    for (let y = 0; y < 32; y++) for (let x = 0; x < 16; x++) {
      const value = shades[(Math.floor(y / 3) * 7 + Math.floor(x / 2) * 11 + originalSeed) % shades.length];
      pixels.set([value, Math.min(255, value + 5), value - 7, 255], (y * 16 + x) * 4);
    }
    const map = new THREE.DataTexture(pixels, 16, 32, THREE.RGBAFormat);
    map.name = 'plant-variety-leaf-pixels'; map.colorSpace = THREE.SRGBColorSpace;
    map.minFilter = map.magFilter = THREE.NearestFilter; map.generateMipmaps = false; map.needsUpdate = true; maps.push(map);
    const dynamic = [], byName = new Map();
    for (const batch of Object.values(batches)) {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.p, 3));
      geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.c, 3));
      geometry.setAttribute('uv', new THREE.Float32BufferAttribute(batch.uv, 2));
      geometry.setIndex(batch.index); geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const material = new THREE.MeshLambertMaterial({ color: 0xffffff, map: batch.name === 'foliage' ? map : null, vertexColors: true, flatShading: true, side: THREE.DoubleSide });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.name = 'plant-variety-' + batch.name; mesh.castShadow = mesh.receiveShadow = true;
      Object.assign(mesh.userData, { softPlant: true, solid: false, plantFoliage: batch.name !== 'roots', plantRoots: batch.name === 'roots' });
      group.add(mesh); geometries.push(geometry); materials.push(material); byName.set(mesh.name, geometry);
      if (batch.name !== 'roots') {
        geometry.attributes.position.setUsage(THREE.DynamicDrawUsage); geometry.attributes.normal.setUsage(THREE.DynamicDrawUsage);
        dynamic.push({ geometry, rest: geometry.attributes.position.array.slice() });
      }
    }
    const height = Math.max(...geometries.map(g => g.boundingBox.max.y)), amplitude = (species === 'vallisneria' ? .70 : .24) * growth;
    const phase = originalSeed * .0127, pinned = .08 * growth;
    let lastTime = null, lastX = 0, lastY = 0, lastZ = 0, lastStrength = 0;
    const inverse = new THREE.Matrix4();
    function refreshContacts() {
      for (const site of grazeSites) {
        const geometry = byName.get(site.meshName), p = geometry.attributes.position, n = geometry.attributes.normal;
        site.position[0] = p.getX(site.vertex); site.position[1] = p.getY(site.vertex); site.position[2] = p.getZ(site.vertex);
        site.normal[0] = n.getX(site.vertex); site.normal[1] = n.getY(site.vertex); site.normal[2] = n.getZ(site.vertex);
      }
    }
    refreshContacts();
    function update(time, flowField) {
      if (!Number.isFinite(time)) return;
      group.updateWorldMatrix(true, false);
      vector.set(0, height * .65, 0).applyMatrix4(group.matrixWorld);
      const sample = typeof flowField?.sample === 'function' ? flowField.sample(vector.x, vector.y, vector.z, time) : null;
      const valid = sample && [sample.x, sample.y, sample.z, sample.strength].every(Number.isFinite);
      const strength = valid ? Math.max(0, Math.min(1, sample.strength)) : 0;
      vector.set(valid ? sample.x : 0, valid ? sample.y : 0, valid ? sample.z : 0);
      inverse.copy(group.matrixWorld).invert(); vector.transformDirection(inverse);
      const x = vector.x, y = vector.y, z = vector.z;
      if (lastTime === time && lastX === x && lastY === y && lastZ === z && lastStrength === strength) return;
      if (!strength && !lastStrength) { lastTime = time; lastX = x; lastY = y; lastZ = z; return; }
      for (const batch of dynamic) {
        const p = batch.geometry.attributes.position.array;
        for (let i = 0; i < p.length; i += 3) {
          const h = batch.rest[i + 1], t = Math.max(0, Math.min(1, (h - pinned) / (height - pinned)));
          const flex = amplitude * strength * t * t * (.88 + .12 * Math.sin(time * 1.05 + h * .43 + phase));
          p[i] = batch.rest[i] + x * flex; p[i + 1] = h + y * flex * .08; p[i + 2] = batch.rest[i + 2] + z * flex;
        }
        batch.geometry.attributes.position.needsUpdate = true; batch.geometry.computeVertexNormals();
        batch.geometry.computeBoundingBox(); batch.geometry.computeBoundingSphere();
      }
      refreshContacts(); lastTime = time; lastX = x; lastY = y; lastZ = z; lastStrength = strength;
    }
    return { group, geometries, materials, maps, update, grazeSites };
  }
  return { create };
});
