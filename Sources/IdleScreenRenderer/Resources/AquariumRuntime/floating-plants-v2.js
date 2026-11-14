(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumFloatingPlantsV2 = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';
  const species = Object.freeze(['frogbit', 'salvinia-minima', 'red-root-floater', 'tiger-lotus']);
  function create(THREE, { species: name, seed = 913, cmPerUnit = 36 / 8.4, growth = 1, lotusForm = 'submerged', waterColumnCm = 29.5 } = {}) {
    if (!species.includes(name)) throw new RangeError('Unknown floating plant species.');
    if (![seed, cmPerUnit, growth, waterColumnCm].every(Number.isFinite) || cmPerUnit <= 0 || growth <= 0 || growth > 1 || waterColumnCm < 15 || waterColumnCm > 35) throw new RangeError('Invalid seed, physical conversion, growth or water column.');
    if (!['submerged', 'surface'].includes(lotusForm) || (name !== 'tiger-lotus' && lotusForm !== 'submerged')) throw new RangeError('Lotus form must be submerged or surface, and surface applies only to tiger lotus.');
    const originalSeed = seed >>> 0, factor = growth / cmPerUnit, lotus = name === 'tiger-lotus';
    seed = originalSeed;
    const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
    const point = p => p.map(v => v * factor), clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
    const group = new THREE.Group(), geometries = [], materials = [], maps = [], grazeSites = [];
    group.name = 'floating-plants-v2-' + name;
    Object.assign(group.userData, { species: name, softPlant: true, solid: false, substratePlant: lotus, floatingPlant: !lotus });
    const botany = { species: name, seed: originalSeed, cmPerUnit, growth, lotusForm: lotus ? lotusForm : null, waterColumnCm,
      anchor: { kind: lotus ? 'substrate-crown' : 'surface-crown', local: [0, 0, 0] },
      dimensionsStatus: 'Authored aquarium form within cited reference ranges; not a maximum mature plant.',
      nodes: [], stems: [], roots: [], submergedFronds: [], leaves: [], hairs: 0 };
    group.userData.botany = botany;
    const batches = Object.fromEntries(['dangling', 'stems', 'foliage'].map(key => [key, { key, meshName: 'floating-v2-' + key, p: [], c: [], uv: [], index: [] }]));
    const colors = {};
    function color(hex) { return colors[hex] || (colors[hex] = new THREE.Color(hex)); }
    const stemColor = color(lotus ? 0x785342 : name === 'red-root-floater' ? 0x915747 : 0x68834a);
    const rootColor = color(name === 'red-root-floater' ? 0x94413a : name === 'salvinia-minima' ? 0x82664c : 0x9b9574);
    const palette = (lotus ? [0x9a6147, 0xaa6c4f, 0x7c784a, 0x995956, 0xa07852] : name === 'red-root-floater' ? [0x9f5947, 0xa66b45, 0x89924c, 0x93534c, 0xb57d50] : name === 'salvinia-minima' ? [0x819a50, 0x91a359, 0x718d48] : [0x719844, 0x83a34b, 0x688b3d, 0x9bae58]).map(color);
    function vertex(batch, p, c, u = .5, v = .5, shade = 1) {
      const index = batch.p.length / 3; batch.p.push(...point(p)); batch.c.push(c.r * shade, c.g * shade, c.b * shade); batch.uv.push(u, v); return index;
    }
    function site(batch, index, kind, parent, radiusCm) {
      const position = batch.p.slice(index * 3, index * 3 + 3);
      const s = { id: name + '-site-' + grazeSites.length, kind, habitat: position[1] > (lotus ? waterColumnCm / cmPerUnit : 0) ? 'aerial' : 'submerged', meshName: batch.meshName, vertex: index, position: [...position], rest: [...position], normal: [0, 1, 0], radius: radiusCm * factor, links: [] };
      if (parent) { s.links.push(parent.id); parent.links.push(s.id); }
      grazeSites.push(s); return s;
    }
    const tangent = new THREE.Vector3(), lateral = new THREE.Vector3(), normal = new THREE.Vector3(), up = new THREE.Vector3(0, 1, 0), right = new THREE.Vector3(1, 0, 0);
    function tube(batch, path, radius, c, { sides = 5, taper = .2, contacts = false, parent = null, profile = null } = {}) {
      const start = batch.p.length / 3, rings = [];
      for (let i = 0; i < path.length; i++) {
        const a = path[Math.max(0, i - 1)], b = path[Math.min(path.length - 1, i + 1)], t = i / (path.length - 1);
        tangent.set(b[0] - a[0], b[1] - a[1], b[2] - a[2]).normalize();
        lateral.crossVectors(Math.abs(tangent.y) > .95 ? right : up, tangent).normalize(); normal.crossVectors(tangent, lateral);
        const r = radius * (profile ? profile(t) : 1 - taper * t); rings.push(batch.p.length / 3);
        for (let j = 0; j < sides; j++) {
          const angle = j * Math.PI * 2 / sides, x = Math.cos(angle) * r, y = Math.sin(angle) * r;
          vertex(batch, [path[i][0] + lateral.x * x + normal.x * y, path[i][1] + lateral.y * x + normal.y * y, path[i][2] + lateral.z * x + normal.z * y], c, j / sides, t, .85 + .15 * j / sides);
        }
        if (i) for (let j = 0; j < sides; j++) {
          const a = rings[i - 1] + j, b = rings[i] + j, c = rings[i] + (j + 1) % sides, d = rings[i - 1] + (j + 1) % sides;
          batch.index.push(a, b, c, a, c, d);
        }
      }
      const first = vertex(batch, path[0], c), last = vertex(batch, path.at(-1), c);
      for (let j = 0; j < sides; j++) batch.index.push(first, rings[0] + (j + 1) % sides, rings[0] + j, last, rings.at(-1) + j, rings.at(-1) + (j + 1) % sides);
      let endSite = parent;
      if (contacts) {
        endSite = site(batch, first, 'stem-junction', parent, radius);
        for (let i = 1; i < rings.length - 1; i++) endSite = site(batch, rings[i], 'stem', endSite, radius * (1 - taper * i / (rings.length - 1)));
        endSite = site(batch, last, 'stem-junction', endSite, radius * (1 - taper));
      }
      return { meshName: batch.meshName, range: { start, count: batch.p.length / 3 - start }, path: path.map(point), endSite };
    }
    let crownSite = null;
    function stem(path, radius, parent = crownSite, id = 'stem-' + botany.stems.length) {
      const part = tube(batches.stems, path, radius, stemColor, { contacts: true, parent });
      botany.stems.push({ id, meshName: part.meshName, range: part.range, path: part.path });
      if (!crownSite) crownSite = grazeSites[0]; return part.endSite;
    }
    function dangling(path, radius, kind, nodeId, taper = .85) {
      const part = tube(batches.dangling, path, radius, rootColor, { sides: 4, taper });
      const record = { id: kind + '-' + (botany.roots.length + botany.submergedFronds.length), nodeId, meshName: part.meshName, range: part.range, path: part.path };
      (kind === 'root' ? botany.roots : botany.submergedFronds).push(record); return record;
    }
    function roots(base, count, depth, nodeId, fern = false) {
      for (let n = 0; n < count; n++) {
        const angle = n * 2.39996 + random() * .4, length = depth * (.70 + .30 * random());
        const path = [base];
        for (let j = 1; j <= 6; j++) {
          const t = j / 6, spread = (fern ? .16 : lotus ? .55 : .9) * t;
          path.push([base[0] + Math.cos(angle) * spread + .08 * Math.sin(t * 6), base[1] - length * t, base[2] + Math.sin(angle) * spread]);
        }
        const kind = fern ? 'submerged-frond' : 'root';
        dangling(path, fern ? .035 : lotus ? .065 : .07, kind, nodeId);
        for (let j = 2; j <= 5; j++) for (const sign of [-1, 1]) {
          const start = path[j], branchLength = (fern ? .5 : lotus ? .65 : .9) * (1 - j * .10);
          const end = [start[0] + Math.cos(angle + sign * 1.2) * branchLength, start[1] - branchLength * (fern ? .65 : 1.1), start[2] + Math.sin(angle + sign * 1.2) * branchLength];
          const mid = start.map((v, k) => (v + end[k]) / 2);
          dangling([start, mid, end], fern ? .016 : .025, kind, nodeId);
          if (fern) for (const fork of [-1, 1]) dangling([mid, [end[0] + fork * .12, end[1] - .10, end[2] + fork * .08]], .009, kind, nodeId);
        }
      }
    }
    function leaf(base, angle, length, width, parent, { kind = 'oval', habitat = 'floating', slope = .035, cup = .09, nodeId = null } = {}) {
      const batch = batches.foliage, start = batch.p.length / 3, sectors = lotus ? 18 : 12, c = palette[Math.floor(random() * palette.length)];
      const dx = Math.cos(angle), dz = Math.sin(angle), centerForward = length * .42, rings = [];
      function xyz(forward, side, r = 1) {
        const pocket = kind === 'pocketed' ? .14 * Math.pow(Math.abs(side) / (width * .5), .7) : cup * Math.pow(side / (width * .5), 2);
        return [base[0] + dx * forward - dz * side, base[1] + slope * forward + pocket + (lotus ? .04 * Math.sin(r * Math.PI) : 0), base[2] + dz * forward + dx * side];
      }
      const centerPoint = xyz(centerForward, 0, 0), center = vertex(batch, centerPoint, c, .42, .5, 1.05);
      const outline = [];
      for (let j = 0; j < sectors; j++) {
        const a = -Math.PI + .43 + j / (sectors - 1) * (2 * Math.PI - .86);
        const margin = lotus ? 1 + .045 * (j % 2 ? 1 : -1) : 1;
        outline.push([centerForward + Math.cos(a) * length * .55 * margin, Math.sin(a) * width * .5 * margin]);
      }
      outline.push([0, 0]);
      for (let k = 1; k <= 3; k++) {
        const r = k / 3, indices = [];
        for (let j = 0; j < outline.length; j++) {
          const forward = centerForward * (1 - r) + outline[j][0] * r, side = outline[j][1] * r;
          const mottled = lotus && (j * 7 + k * 3 + originalSeed) % 7 < 2;
          indices.push(vertex(batch, xyz(forward, side, r), mottled ? color(0x633b3d) : c, forward / length, .5 + side / width, j % 3 === 0 ? .90 : 1));
        }
        rings.push(indices);
        for (let j = 0; j < indices.length; j++) {
          const next = (j + 1) % indices.length;
          if (k === 1) batch.index.push(center, indices[next], indices[j]);
          else { const prev = rings[k - 2]; batch.index.push(prev[j], prev[next], indices[next], prev[j], indices[next], indices[j]); }
        }
      }
      const attachment = rings[2].at(-1), topCount = batch.p.length / 3 - start;
      const thickness = name === 'frogbit' ? .075 : lotus ? .035 : .025;
      for (let i = start; i < start + topCount; i++) {
        const raw = batch.p.slice(i * 3, i * 3 + 3).map(v => v / factor); raw[1] -= thickness;
        if (!lotus || habitat === 'surface') raw[1] = Math.min(raw[1], (lotus ? waterColumnCm / growth : 0) - .025);
        vertex(batch, raw, c, batch.uv[i * 2], batch.uv[i * 2 + 1], .72);
      }
      const topIndices = batch.index.filter(i => i >= start && i < start + topCount);
      for (let i = 0; i < topIndices.length; i += 3) batch.index.push(topIndices[i] + topCount, topIndices[i + 2] + topCount, topIndices[i + 1] + topCount);
      for (let j = 0; j < rings[2].length; j++) {
        const a = rings[2][j], b = rings[2][(j + 1) % rings[2].length]; batch.index.push(a, b, b + topCount, a, b + topCount, a + topCount);
      }
      const record = { id: 'leaf-' + botany.leaves.length, nodeId, shape: lotus ? 'notched-pad' : kind, habitat, base: point(base), lengthCm: length * growth, widthCm: width * growth,
        meshName: batch.meshName, range: { start, count: batch.p.length / 3 - start } };
      botany.leaves.push(record);
      const contactOffset = !lotus || habitat === 'surface' ? topCount : 0;
      let previous = site(batch, attachment + contactOffset, 'leaf-base', parent, Math.min(.12, width * .15));
      for (let k = 1; k >= 0; k--) previous = site(batch, rings[k].at(-1) + contactOffset, 'leaf', previous, width * .12);
      previous = site(batch, center + contactOffset, 'leaf', previous, width * .22);
      const tipColumn = Math.floor(sectors / 2);
      for (let k = 0; k < 2; k++) previous = site(batch, rings[k][tipColumn] + contactOffset, 'leaf', previous, width * .15);
      if (name === 'salvinia-minima') {
        for (const index of [center, rings[1][3], rings[1][8]]) {
          const p = batch.p.slice(index * 3, index * 3 + 3).map(v => v / factor), top = [p[0], p[1] + .055, p[2]];
          tube(batch, [p, top], .009, color(0xb6b488), { sides: 3, taper: .1 });
          for (let j = 0; j < 4; j++) { const a = j * Math.PI / 2; tube(batch, [top, [top[0] + Math.cos(a) * .028, top[1] + .025, top[2] + Math.sin(a) * .028]], .006, color(0xc8c69e), { sides: 3, taper: .6 }); }
          botany.hairs++;
        }
      }
      return record;
    }
    if (name === 'frogbit') {
      const crown = [0, 0, 0]; botany.nodes.push({ id: 'crown', position: point(crown) });
      for (let i = 0; i < 7; i++) {
        const angle = i * 2.39996 + random() * .13, radius = 1.05 + random() * .55, base = [Math.cos(angle) * radius, .05 + .10 * random(), Math.sin(angle) * radius];
        const middle = [base[0] * .52, -.06, base[2] * .52], parent = stem([crown, middle, base], .07);
        leaf(base, angle, 2.5 + random() * .9, 2.3 + random() * .65, parent, { kind: 'cordate', slope: i === 6 ? .16 : .045, cup: .14, nodeId: 'crown' });
      }
      roots(crown, 5, 12, 'crown');
    } else if (name === 'salvinia-minima' || name === 'red-root-floater') {
      const fern = name === 'salvinia-minima', count = fern ? 5 : 7, nodes = [];
      for (let i = 0; i < count; i++) nodes.push([i * (fern ? .86 : .82), 0, i ? Math.sin(i * .8) * .12 : 0]);
      const nodeSites = [];
      for (let i = 1; i < nodes.length; i++) {
        const end = stem([nodes[i - 1], nodes[i]], fern ? .035 : .06, i > 1 ? nodeSites[i - 1] : null);
        if (i === 1) nodeSites[0] = crownSite; nodeSites[i] = end;
      }
      for (let i = 0; i < nodes.length; i++) {
        const node = nodes[i], id = 'node-' + i; botany.nodes.push({ id, position: point(node) });
        const directions = fern ? [-1, 1] : [i % 2 ? 1 : -1];
        for (const sign of directions) {
          const base = [node[0], .015, node[2] + sign * (fern ? .06 : .045)], parent = stem([node, base], fern ? .025 : .035, nodeSites[i]);
          const length = fern ? 1.05 + random() * .4 : 1.12 + random() * .5;
          leaf(base, sign * Math.PI / 2 + (random() - .5) * .12, length, length * (fern ? .76 : .90), parent, { kind: fern ? 'folded-frond' : 'pocketed', nodeId: id, cup: fern ? .19 : .11, slope: .025 });
        }
        roots(node, fern ? 1 : 2, fern ? 2.6 : 5.6, id, fern);
      }
    } else {
      const crown = [0, 0, 0]; botany.nodes.push({ id: 'crown', position: point(crown) });
      const bulb = tube(batches.dangling, [crown, [0, -.4, 0], [0, -1.3, 0], [0, -1.8, 0]], .9, color(0x695240), { sides: 8, profile: t => .12 + .88 * Math.sin(t * Math.PI) });
      botany.bulb = { meshName: bulb.meshName, range: bulb.range };
      roots(crown, 7, 3.8, 'crown');
      for (let i = 0; i < 7; i++) {
        const angle = i * 2.39996 + random() * .14, reach = 2.8 + random() * 1.2;
        const surface = lotusForm === 'surface' && i >= 5, authoredHeight = 15.5 + i * 1.65 + random() * .35;
        const height = surface ? waterColumnCm / growth : Math.min(authoredHeight, (waterColumnCm - 1.2) / growth);
        const base = [Math.cos(angle) * reach, height, Math.sin(angle) * reach], path = [crown];
        const steps = Math.ceil(height / 1.7);
        for (let j = 1; j <= steps; j++) { const t = j / steps; path.push([base[0] * t * t + Math.sin(angle + .4) * Math.sin(t * Math.PI) * .6, height * t, base[2] * t * t]); }
        const parent = stem(path, .105, crownSite), length = 4.6 + random() * 2.6;
        leaf(base, angle, length, length * (.84 + random() * .08), parent, { kind: 'notched-pad', habitat: surface ? 'surface' : 'submerged', slope: surface ? 0 : .08, cup: surface ? .045 : .18, nodeId: 'crown' });
      }
    }
    const texSize = 32, pixels = new Uint8Array(texSize * texSize * 4);
    for (let y = 0; y < texSize; y++) for (let x = 0; x < texSize; x++) {
      const hash = ((x >> 1) * 83 + (y >> 1) * 127 + originalSeed * 7) >>> 0;
      const vein = Math.abs(y - 15.5) < 1 || (Math.abs(y - 15.5) > 2 && (x + Math.floor(Math.abs(y - 15.5) * .6)) % 9 === 0);
      let value = vein ? 177 : 224 + hash % 26;
      if (lotus && hash % 13 < 3) value = 147;
      if (name === 'salvinia-minima' && x % 4 === 1 && y % 4 === 1) value = 255;
      pixels.set([value, value, value, 255], (y * texSize + x) * 4);
    }
    const map = new THREE.DataTexture(pixels, texSize, texSize, THREE.RGBAFormat); map.magFilter = map.minFilter = THREE.NearestFilter; map.generateMipmaps = false; map.needsUpdate = true; maps.push(map);
    const dynamic = [], byName = new Map();
    for (const batch of Object.values(batches)) {
      const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.p, 3)); geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.c, 3)); geometry.setAttribute('uv', new THREE.Float32BufferAttribute(batch.uv, 2));
      geometry.setIndex(batch.index); geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      geometry.attributes.position.setUsage(THREE.DynamicDrawUsage); geometry.attributes.normal.setUsage(THREE.DynamicDrawUsage);
      const material = new THREE.MeshLambertMaterial({ color: 0xffffff, map: batch.key === 'foliage' ? map : null, vertexColors: true, flatShading: true, side: THREE.DoubleSide });
      const mesh = new THREE.Mesh(geometry, material); mesh.name = batch.meshName; mesh.castShadow = mesh.receiveShadow = true;
      Object.assign(mesh.userData, { softPlant: true, solid: false, plantRoots: batch.key === 'dangling' && name !== 'salvinia-minima', submergedFrond: batch.key === 'dangling' && name === 'salvinia-minima', plantFoliage: batch.key === 'foliage' });
      group.add(mesh); geometries.push(geometry); materials.push(material); byName.set(mesh.name, geometry);
      if (!lotus || batch.key !== 'dangling') dynamic.push({ geometry, rest: geometry.attributes.position.array.slice() });
    }
    const localBox = new THREE.Box3().setFromObject(group);
    botany.restBoundsCm = { min: localBox.min.toArray().map(v => v * cmPerUnit), max: localBox.max.toArray().map(v => v * cmPerUnit) };
    botany.maxCurrentDisplacementCm = (lotus ? 1.6 : name === 'frogbit' ? 1.3 : .65) * growth;
    const inverse = new THREE.Matrix4(), vector = new THREE.Vector3(), phase = originalSeed * .013;
    function refreshSites() {
      for (const s of grazeSites) {
        const g = byName.get(s.meshName), p = g.attributes.position, n = g.attributes.normal;
        s.position[0] = p.getX(s.vertex); s.position[1] = p.getY(s.vertex); s.position[2] = p.getZ(s.vertex);
        s.normal[0] = n.getX(s.vertex); s.normal[1] = n.getY(s.vertex); s.normal[2] = n.getZ(s.vertex);
      }
    }
    refreshSites(); let lastTime = null, lastX = 0, lastZ = 0, lastStrength = 0, disposed = false;
    function update(time, flow) {
      if (disposed || !Number.isFinite(time)) return;
      group.updateWorldMatrix(true, false); vector.set(0, lotus ? localBox.max.y * .55 : 0, 0).applyMatrix4(group.matrixWorld);
      const sample = typeof flow?.sample === 'function' ? flow.sample(vector.x, vector.y, vector.z, time) : null;
      const valid = sample && [sample.x, sample.y, sample.z, sample.strength].every(Number.isFinite), strength = valid ? clamp(sample.strength, 0, 1) : 0;
      vector.set(valid ? sample.x : 0, 0, valid ? sample.z : 0); inverse.copy(group.matrixWorld).invert(); vector.transformDirection(inverse);
      const x = vector.x, z = vector.z;
      if (time === lastTime && x === lastX && z === lastZ && strength === lastStrength) return;
      if (!strength && !lastStrength) { lastTime = time; lastX = x; lastZ = z; return; }
      for (const batch of dynamic) {
        const p = batch.geometry.attributes.position.array, rest = batch.rest;
        for (let i = 0; i < p.length; i += 3) {
          const yCm = rest[i + 1] * cmPerUnit, radiusCm = Math.hypot(rest[i], rest[i + 2]) * cmPerUnit;
          const surfaceFlex = .22 * clamp(radiusCm / 3, 0, 1), depthFlex = clamp(-yCm / Math.max(-localBox.min.y * cmPerUnit, .01), 0, 1);
          const weight = lotus ? Math.pow(clamp(yCm / Math.max(localBox.max.y * cmPerUnit, .01), 0, 1), 2) : surfaceFlex + (1 - surfaceFlex) * depthFlex;
          const shift = botany.maxCurrentDisplacementCm / cmPerUnit * strength * weight * (.90 + .10 * Math.sin(time * .9 + yCm * .21 + phase));
          p[i] = rest[i] + x * shift; p[i + 1] = rest[i + 1]; p[i + 2] = rest[i + 2] + z * shift;
        }
        batch.geometry.attributes.position.needsUpdate = true; batch.geometry.computeVertexNormals(); batch.geometry.computeBoundingBox(); batch.geometry.computeBoundingSphere();
      }
      refreshSites(); lastTime = time; lastX = x; lastZ = z; lastStrength = strength;
    }
    function dispose() { if (disposed) return; disposed = true; for (const resource of [...geometries, ...materials, ...maps]) resource.dispose(); }
    return { group, geometries, materials, maps, grazeSites, update, dispose };
  }
  return { create, species };
});
