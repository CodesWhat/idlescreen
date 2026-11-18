(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumMossRockArt = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function randomSource(seed) {
    return function () {
      seed = (seed + 0x6d2b79f5) >>> 0;
      let value = Math.imul(seed ^ seed >>> 15, seed | 1);
      value ^= value + Math.imul(value ^ value >>> 7, value | 61);
      return ((value ^ value >>> 14) >>> 0) / 4294967296;
    };
  }

  function stoneMap(THREE, seed) {
    const random = randomSource(seed ^ 709), size = 32, data = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y += 2) for (let x = 0; x < size; x += 2) {
      const shade = 214 + Math.floor(random() * 27);
      for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) {
        data.set([shade, shade, shade, 255], ((y + dy) * size + x + dx) * 4);
      }
    }
    for (let x = 0; x < size; x++) for (const offset of [3, 19]) {
      const y = (offset + Math.floor(x * .28)) % size, index = (y * size + x) * 4;
      data.set([180, 185, 180, 255], index);
      if (x % 5 < 2) data.set([246, 245, 231, 255], (((y + 1) % size) * size + x) * 4);
    }
    const map = new THREE.DataTexture(data, size, size, THREE.RGBAFormat);
    map.name = 'moss-rock-mineral-pixels'; map.colorSpace = THREE.SRGBColorSpace;
    map.wrapS = map.wrapT = THREE.RepeatWrapping; map.minFilter = map.magFilter = THREE.NearestFilter;
    map.generateMipmaps = false; map.needsUpdate = true;
    return map;
  }

  function create(THREE, { seed = 421, growth = 1 } = {}) {
    if (!Number.isFinite(seed)) throw new RangeError('seed must be finite');
    if (!Number.isFinite(growth) || growth <= 0) throw new RangeError('growth must be positive and finite');
    growth = Math.max(.45, Math.min(1.35, growth)); seed >>>= 0;
    const random = randomSource(seed), group = new THREE.Group(); group.name = 'moss-rock-formation';
    const map = stoneMap(THREE, seed), maps = [map], geometries = [];
    const stone = new THREE.MeshLambertMaterial({ color: 0xffffff, vertexColors: true, map, flatShading: true });
    const pads = new THREE.MeshLambertMaterial({ color: 0x395b2b, vertexColors: true, flatShading: true });
    const stems = new THREE.MeshLambertMaterial({ color: 0x537536, flatShading: true });
    const tips = new THREE.MeshLambertMaterial({ color: 0x7e9844, vertexColors: true, flatShading: true, side: THREE.DoubleSide });
    const materials = [stone, pads, stems, tips];
    ['moss-rock-stone', 'moss-attached-pads', 'moss-stems', 'moss-fine-tips'].forEach((name, i) => { materials[i].name = name; });
    const batches = new Map(materials.map(mat => [mat, { positions: [], colors: [], uv: [] }]));
    const faces = [], rockRecords = [], patches = [], grazeSites = [];
    const vector = point => new THREE.Vector3(...point);
    const scaled = point => point.map(value => value * growth);
    function triangle(mat, a, b, c, color = [1, 1, 1], rockId) {
      const batch = batches.get(mat), normal = b.clone().sub(a).cross(c.clone().sub(a)).normalize();
      const start = batch.positions.length / 3;
      for (const p of [a, b, c]) {
        batch.positions.push(p.x, p.y, p.z); batch.colors.push(...color);
        if (Math.abs(normal.y) > .6) batch.uv.push(p.x * 1.4, p.z * 1.4);
        else batch.uv.push((Math.abs(normal.x) > Math.abs(normal.z) ? p.z : p.x) * 1.4, p.y * 1.4);
      }
      if (rockId) faces.push({ a, b, c, normal, rockId, area: b.clone().sub(a).cross(c.clone().sub(a)).length() * .5 });
      return start;
    }
    function rock(spec) {
      const outline = [[-.78, -.46], [-.25, -.74], [.40, -.68], [.78, -.32], [.69, .05], [.35, .16], [.72, .47], [.22, .69], [-.32, .63], [-.78, .29]];
      const wobble = outline.map(() => .92 + random() * .16);
      const contour = [[0, .86], [.16, 1], [.43, .87], [.68, .65], [.88, .34]];
      const rotation = spec.rotation || 0, cosine = Math.cos(rotation), sine = Math.sin(rotation);
      function point(px, y, pz) { return new THREE.Vector3(spec.x + px * cosine + pz * sine, y, spec.z - px * sine + pz * cosine); }
      const rings = contour.map(([height, scale], row) => outline.map(([ox, oz], i) => {
        const drift = spec.lean * height;
        const radius = wobble[i] * scale * (row === 0 ? 1 : .94 + random() * .12);
        const y = row === 0 ? 0 : spec.height * height + (random() - .5) * spec.height * .045 + ox * spec.height * .025;
        return point(ox * spec.width * radius + drift, y, oz * spec.depth * radius + height * .09);
      }));
      const peak = point(spec.lean * 1.04 - .045, spec.height, .03);
      const ground = point(0, 0, 0), palette = [[.40, .45, .43], [.46, .49, .46], [.35, .40, .39], [.49, .52, .47]];
      function face(a, b, c, fracture) {
        const color = palette[Math.floor(random() * palette.length)];
        if (fracture) {
          const middle = a.clone().add(b).add(c).multiplyScalar(1 / 3);
          const toward = point(spec.lean * middle.y / spec.height, middle.y, 0).sub(middle).normalize();
          middle.addScaledVector(toward, spec.width * (.035 + random() * .045));
          triangle(stone, a, b, middle, color, spec.id);
          triangle(stone, b, c, middle, color.map(value => value * .92), spec.id);
          triangle(stone, c, a, middle, color, spec.id);
        } else triangle(stone, a, b, c, color, spec.id);
      }
      for (let i = 0; i < outline.length; i++) {
        const j = (i + 1) % outline.length;
        face(ground, rings[0][i], rings[0][j], false);
        face(peak, rings.at(-1)[j], rings.at(-1)[i], false);
        for (let row = 0; row < rings.length - 1; row++) {
          face(rings[row][i], rings[row + 1][i], rings[row][j], row > 0 && i % 3 === 1);
          face(rings[row + 1][i], rings[row + 1][j], rings[row][j], row > 0 && i % 3 === 2);
        }
      }
      rockRecords.push({ id: spec.id, height: spec.height * growth, groundContact: scaled(ground.toArray()), peak: scaled(peak.toArray()), mossLimit: spec.moss });
    }
    for (const spec of [
      { id: 'hero', x: -.67, z: -.25, width: 1.36, depth: 1.27, height: 3.65, lean: -.48, rotation: -.08, moss: 16 },
      { id: 'secondary', x: 1.30, z: .16, width: 1.01, depth: 1.11, height: 2.18, lean: -.14, rotation: .24, moss: 12 },
      { id: 'front-join', x: .22, z: 1.02, width: .85, depth: .67, height: .72, lean: -.13, rotation: -.31, moss: 2 },
      { id: 'left-foot', x: -1.63, z: .77, width: .76, depth: .62, height: .62, lean: -.11, rotation: .18, moss: 2 },
      { id: 'right-foot', x: 2.02, z: .83, width: .67, depth: .68, height: .50, lean: -.04, rotation: -.28, moss: 2 },
      { id: 'rear-chip', x: -1.90, z: -.74, width: .53, depth: .64, height: .46, lean: -.08, rotation: .42, moss: 1 }
    ]) rock(spec);

    function finish(mat) {
      const batch = batches.get(mat), geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      if (mat.vertexColors) geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.colors, 3));
      if (mat.map) geometry.setAttribute('uv', new THREE.Float32BufferAttribute(batch.uv, 2));
      geometry.computeVertexNormals();
      const mesh = new THREE.Mesh(geometry, mat); mesh.name = mat.name;
      const solid = mat === stone;
      mesh.userData = { solid, hardscape: solid, climbable: solid, plantFoliage: !solid, species: solid ? 'slate-rock' : 'aquarium-moss' };
      mesh.castShadow = mesh.receiveShadow = true; group.add(mesh); geometries.push(geometry); return mesh;
    }
    const rockMesh = finish(stone); rockMesh.updateMatrixWorld(true);
    const ray = new THREE.Raycaster();
    function exposed(point) {
      ray.set(new THREE.Vector3(point.x, 5, point.z), new THREE.Vector3(0, -1, 0));
      const hit = ray.intersectObject(rockMesh)[0];
      return hit && hit.point.distanceTo(point) < .0001;
    }
    function segment(a, b, radius) {
      const delta = b.clone().sub(a).normalize();
      const reference = Math.abs(delta.z) < .9 ? new THREE.Vector3(0, 0, 1) : new THREE.Vector3(1, 0, 0);
      const u = new THREE.Vector3().crossVectors(delta, reference).normalize();
      const v = new THREE.Vector3().crossVectors(delta, u).normalize();
      const rings = [a, b].map((center, ring) => [0, 1, 2].map(side => center.clone()
        .addScaledVector(u, Math.cos(side * Math.PI * 2 / 3) * radius * (ring ? .55 : 1))
        .addScaledVector(v, Math.sin(side * Math.PI * 2 / 3) * radius * (ring ? .55 : 1))));
      const start = batches.get(stems).positions.length / 3;
      for (let side = 0; side < 3; side++) {
        const j = (side + 1) % 3;
        triangle(stems, rings[0][side], rings[0][j], rings[1][side]);
        triangle(stems, rings[0][j], rings[1][j], rings[1][side]);
      }
      triangle(stems, rings[0][0], rings[0][2], rings[0][1]);
      triangle(stems, rings[1][0], rings[1][1], rings[1][2]);
      return start;
    }
    function leaf(start, direction, normal) {
      const side = new THREE.Vector3().crossVectors(direction, normal).normalize();
      if (side.lengthSq() < .01) side.set(1, 0, 0);
      const end = start.clone().addScaledVector(direction, .047 + random() * .025);
      const middle = start.clone().lerp(end, .40), color = [.82 + random() * .18, .84 + random() * .16, .76 + random() * .18];
      triangle(tips, start, middle.clone().addScaledVector(side, .010), end, color);
      triangle(tips, start, end, middle.clone().addScaledVector(side, -.010), color);
    }
    function patch(face, number) {
      const center = face.a.clone().add(face.b).add(face.c).multiplyScalar(1 / 3), normal = face.normal;
      const original = [face.a, face.b, face.c], contour = [];
      for (let i = 0; i < 3; i++) {
        contour.push(center.clone().lerp(original[i], .60 + random() * .12));
        contour.push(center.clone().lerp(original[i].clone().lerp(original[(i + 1) % 3], .5), .73 + random() * .09));
      }
      const topCenter = center.clone().addScaledVector(normal, .013), color = [.86 + random() * .14, .92 + random() * .08, .8 + random() * .20];
      for (let i = 0; i < contour.length; i++) {
        const j = (i + 1) % contour.length;
        const topA = contour[i].clone().addScaledVector(normal, .005), topB = contour[j].clone().addScaledVector(normal, .005);
        const baseA = contour[i].clone().addScaledVector(normal, -.004), baseB = contour[j].clone().addScaledVector(normal, -.004);
        triangle(pads, topCenter, topA, topB, color);
        triangle(pads, center.clone().addScaledVector(normal, -.004), baseB, baseA, color);
        triangle(pads, topA, baseA, topB, color); triangle(pads, topB, baseA, baseB, color);
      }
      const roots = [], id = 'moss-pad-' + number, tangent = face.b.clone().sub(face.a).normalize();
      const across = new THREE.Vector3().crossVectors(normal, tangent).normalize();
      for (let i = 0; i < 8; i++) {
        const edge = Math.floor(random() * contour.length), a = Math.sqrt(random()) * .88, b = random();
        const root = center.clone().multiplyScalar(1 - a).addScaledVector(contour[edge], a * (1 - b)).addScaledVector(contour[(edge + 1) % contour.length], a * b);
        const direction = new THREE.Vector3(0, .85, 0).addScaledVector(normal, .5)
          .addScaledVector(tangent, (random() - .5) * .42).addScaledVector(across, (random() - .5) * .36).normalize();
        const tip = root.clone().addScaledVector(direction, .12 + random() * .105);
        const vertex = segment(root.clone().addScaledVector(normal, -.003), tip, .0065 + random() * .002);
        leaf(tip, direction, normal);
        for (const sign of [-1, 1]) {
          const start = root.clone().lerp(tip, .42 + random() * .22);
          const branchDirection = direction.clone().multiplyScalar(.55).addScaledVector(tangent, sign * .64).normalize();
          const branchTip = start.clone().addScaledVector(branchDirection, .040 + random() * .022);
          segment(start, branchTip, .0045); leaf(branchTip, branchDirection, normal);
        }
        roots.push({ position: scaled(root.toArray()), tip: scaled(tip.toArray()), stemVertex: vertex });
      }
      patches.push({ id, rockId: face.rockId, position: scaled(center.toArray()), normal: normal.toArray(), roots });
      for (const [suffix, position] of [['center', scaled(center.toArray())], ['edge-a', roots[0].position], ['edge-b', roots[4].position]]) {
        grazeSites.push({ id: id + '-' + suffix, position: position.slice(), normal: normal.toArray(), links: [], rockId: face.rockId });
      }
    }
    for (const record of rockRecords) {
      const candidates = faces.filter(face => face.rockId === record.id && face.normal.y > .46 && face.area > .027)
        .map(face => ({ face, center: face.a.clone().add(face.b).add(face.c).multiplyScalar(1 / 3), rank: random() }))
        .filter(item => item.center.y > record.height / growth * .35 && exposed(item.center))
        .sort((a, b) => a.rank - b.rank).slice(0, record.mossLimit);
      for (const item of candidates) patch(item.face, patches.length);
    }
    for (let i = 0; i < grazeSites.length; i++) for (let j = i + 1; j < grazeSites.length; j++) {
      const a = grazeSites[i], b = grazeSites[j];
      if (a.rockId === b.rockId && vector(a.position).distanceTo(vector(b.position)) <= Math.min(.48 * growth, .64)) {
        a.links.push(b.id); b.links.push(a.id);
      }
    }
    for (const mat of [pads, stems, tips]) finish(mat);
    for (const geometry of geometries) { geometry.scale(growth, growth, growth); geometry.computeBoundingBox(); geometry.computeBoundingSphere(); }
    group.userData = {
      species: 'moss-covered-slate-formation', growth, seed, rocks: rockRecords, mossPatches: patches,
      crevices: [{ from: scaled([.48, 1.18, -1.5]), to: scaled([.48, 1.18, 1.5]) }]
    };
    return { group, geometries, materials, maps, grazeSites };
  }
  return { create };
});
