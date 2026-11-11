(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumAnubiasArt = factory();
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

  function leafMap(THREE, seed) {
    const random = randomSource(seed ^ 3611), width = 32, height = 16;
    const pixels = new Uint8Array(width * height * 4);
    const palette = [[221, 233, 205], [232, 240, 218], [211, 224, 195], [239, 244, 225], [224, 234, 207]];
    for (let y = 0; y < height; y += 2) for (let x = 0; x < width; x += 2) {
      const color = palette[Math.floor(random() * 5)];
      for (let dy = 0; dy < 2; dy++) for (let dx = 0; dx < 2; dx++) pixels.set([...color, 255], ((y + dy) * width + x + dx) * 4);
    }
    for (let x = 1; x < 31; x++) pixels.set([...palette[1], 255], (8 * width + x) * 4);
    for (const x of [6, 12, 18, 24]) for (let step = 1; step <= 5; step++) {
      for (const sign of [-1, 1]) pixels.set([...palette[0], 255], ((8 + sign * step) * width + x + Math.floor(step / 2)) * 4);
    }
    const map = new THREE.DataTexture(pixels, width, height, THREE.RGBAFormat);
    map.name = 'anubias-leaf-pixels';
    map.colorSpace = THREE.SRGBColorSpace;
    map.minFilter = map.magFilter = THREE.NearestFilter;
    map.generateMipmaps = false;
    map.needsUpdate = true;
    return map;
  }

  function mountGeometry(THREE) {
    const outline = [[-.58, -.15], [-.38, -.33], [.12, -.34], [.53, -.22], [.60, .13], [.32, .35], [-.18, .36], [-.55, .22]];
    const rings = [[.85, 0], [1, .12], [.78, .24]].map(([scale, y]) => outline.map(([x, z]) => [x * scale, y, z * scale]));
    const positions = [];
    function triangle(a, b, c) { positions.push(...a, ...b, ...c); }
    for (let i = 0; i < outline.length; i++) {
      const j = (i + 1) % outline.length;
      triangle([0, .24, 0], rings[2][j], rings[2][i]);
      triangle([0, 0, 0], rings[0][i], rings[0][j]);
      for (let ring = 0; ring < 2; ring++) {
        triangle(rings[ring][i], rings[ring + 1][i], rings[ring][j]);
        triangle(rings[ring + 1][i], rings[ring + 1][j], rings[ring][j]);
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.computeVertexNormals();
    return geometry;
  }

  function bladeGeometry(THREE, length, width, lift, twist) {
    const rows = [[.12, .58], [.28, .92], [.48, 1], [.68, .83], [.86, .52]];
    const positions = [], uv = [], indices = [];
    for (const skin of [1, -1]) {
      positions.push(0, 0, 0); uv.push(0, .5);
      for (const [u, fullness] of rows) for (const lateral of [-1, -.5, 0, .5, 1]) {
        const arch = Math.sin(Math.PI * u);
        const y = length * (lift * u + .045 * arch) + width * .055 * (1 - lateral * lateral) * arch + twist * lateral * arch;
        positions.push(length * u, y + skin * .004 * (.5 + .5 * arch), width * .5 * fullness * lateral);
        uv.push(u, .5 + fullness * lateral * .5);
      }
      positions.push(length, length * lift, 0); uv.push(1, .5);
    }
    const count = 27, top = [];
    for (let side = 0; side < 4; side++) top.push(0, 2 + side, 1 + side);
    for (let row = 0; row < 4; row++) for (let side = 0; side < 4; side++) {
      const a = 1 + row * 5 + side, b = a + 5, c = b + 1, d = a + 1;
      top.push(a, c, b, a, d, c);
    }
    for (let side = 0; side < 4; side++) top.push(21 + side, 22 + side, 26);
    indices.push(...top);
    for (let i = 0; i < top.length; i += 3) indices.push(top[i] + count, top[i + 2] + count, top[i + 1] + count);
    const outline = [0, 1, 6, 11, 16, 21, 26, 25, 20, 15, 10, 5];
    for (let i = 0; i < outline.length; i++) {
      const a = outline[i], b = outline[(i + 1) % outline.length];
      if (b !== 0 && b !== 26) indices.push(a, b, b + count);
      if (a !== 0 && a !== 26) indices.push(a, b + count, a + count);
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    geometry.setIndex(indices);
    geometry.computeVertexNormals();
    return geometry;
  }

  function create(THREE, { seed = 913, growth = 1 } = {}) {
    if (!Number.isFinite(seed)) throw new RangeError('seed must be finite');
    if (!Number.isFinite(growth) || growth <= 0) throw new RangeError('growth must be positive and finite');
    growth = Math.min(1.35, Math.max(.45, growth));
    seed = seed >>> 0;
    const random = randomSource(seed), map = leafMap(THREE, seed);
    const stone = new THREE.MeshLambertMaterial({ color: 0x5c655e, flatShading: true });
    const stems = new THREE.MeshLambertMaterial({ color: 0x667951, flatShading: true });
    const roots = new THREE.MeshLambertMaterial({ color: 0x6e7756, flatShading: true });
    const mature = new THREE.MeshLambertMaterial({ color: 0x557b3c, map, flatShading: true });
    const young = new THREE.MeshLambertMaterial({ color: 0x829f52, map, flatShading: true });
    const materials = [stone, stems, roots, mature, young];
    ['anubias-mount', 'anubias-rhizome-petioles', 'anubias-roots', 'anubias-mature-leaves', 'anubias-young-leaves']
      .forEach((name, index) => { materials[index].name = name; });
    const batches = new Map(materials.map(material => [material, { position: [], normal: [], uv: [] }]));
    const scaled = point => point.map(value => value * growth);
    function add(material, geometry, position = [0, 0, 0], rotation = new THREE.Quaternion()) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...position), rotation, new THREE.Vector3(1, 1, 1)));
      geometry.scale(growth, growth, growth);
      const flat = geometry.index ? geometry.toNonIndexed() : geometry;
      const batch = batches.get(material), range = { start: batch.position.length / 3, count: flat.attributes.position.count };
      batch.position.push(...flat.attributes.position.array);
      batch.normal.push(...flat.attributes.normal.array);
      if (flat.attributes.uv) batch.uv.push(...flat.attributes.uv.array);
      else for (let i = 0; i < flat.attributes.position.count; i++) batch.uv.push(0, 0);
      if (flat !== geometry) flat.dispose();
      geometry.dispose();
      return range;
    }
    function stalk(material, a, b, radius, endRadius = radius, sides = 6) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), axis = end.clone().sub(start);
      const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
      add(material, new THREE.CylinderGeometry(endRadius, radius, axis.length(), sides), start.add(end).multiplyScalar(.5).toArray(), rotation);
    }

    const group = new THREE.Group();
    group.name = 'anubias-nana';
    group.userData.species = 'Anubias barteri var. nana';
    group.userData.epiphyte = true;
    const rhizome = [[-.43, .30, -.04], [-.20, .30, -.02], [.07, .30, .035], [.35, .30, .015], [.47, .30, .04]];
    const botany = { species: group.userData.species, seed, growth, rhizome: { points: rhizome.map(scaled), radius: .065 * growth }, roots: [], leaves: [] };
    group.userData.botany = botany;
    for (let i = 1; i < rhizome.length; i++) stalk(stems, rhizome[i - 1], rhizome[i], .065 - i * .003, .062 - i * .003, 8);

    const mount = mountGeometry(THREE), probe = new THREE.Mesh(mount, stone);
    probe.updateMatrixWorld();
    const ray = new THREE.Raycaster();
    function surface(x, z) {
      ray.set(new THREE.Vector3(x, 1, z), new THREE.Vector3(0, -1, 0));
      const hit = ray.intersectObject(probe)[0];
      return [x, hit.point.y, z];
    }
    for (let i = 0; i < 4; i++) {
      const node = rhizome[i], sign = i % 2 ? -1 : 1, radius = .014;
      const contact = surface(node[0] * .75, sign * .28);
      const top = surface(node[0] * .95, sign * .13), shoulder = surface(node[0] * .85, sign * .23);
      const points = [[node[0], node[1] - .025, node[2]], top, shoulder, contact].map((point, index) =>
        index ? [point[0], point[1] + radius * .55, point[2]] : point);
      for (let j = 1; j < points.length; j++) stalk(roots, points[j - 1], points[j], radius, radius * .8);
      botany.roots.push({ points: points.map(scaled), contact: scaled(contact), radius: radius * growth });
    }
    add(stone, mount);

    const specs = [
      [.02, 2.80, .55, .16, .88, -.05, false], [.16, 2.00, .80, .13, .95, -.28, false],
      [.28, 4.10, .63, .16, .98, .45, false], [.42, 1.25, .65, .15, 1.02, -.22, false],
      [.54, 4.80, .68, .12, .93, .55, false], [.67, .45, .78, .15, .98, -.12, false],
      [.79, 5.70, .64, .12, .91, .25, false], [.91, 1.75, .84, .06, .55, .55, true],
      [1, 4.80, .75, .055, .42, .80, true],
    ];
    const selected = growth < .8 ? new Set([0, 1, 3, 5, 7, 8]) : new Set(specs.map((_, index) => index));
    for (let i = 0; i < specs.length; i++) {
      const [t, yaw, height, reach, nominalLength, nominalLift, isYoung] = specs[i];
      const angle = yaw + (random() - .5) * .20, length = nominalLength * (.94 + random() * .12);
      const width = length * (isYoung ? .43 + random() * .06 : .59 + random() * .09);
      const lift = nominalLift + (random() - .5) * .08, twist = (random() - .5) * .026;
      if (!selected.has(i)) continue;
      const along = t * (rhizome.length - 1), segment = Math.min(rhizome.length - 2, Math.floor(along));
      const origin = new THREE.Vector3(...rhizome[segment]).lerp(new THREE.Vector3(...rhizome[segment + 1]), along - segment).toArray();
      const direction = [Math.cos(angle), Math.sin(angle)];
      const stemPath = [0, .35, .70, 1].map(u => [origin[0] + direction[0] * reach * u * u,
        origin[1] + height * u, origin[2] + direction[1] * reach * u * u]);
      for (let j = 1; j < stemPath.length; j++) stalk(stems, stemPath[j - 1], stemPath[j], .022 - j * .002, .020 - j * .002);
      const base = stemPath.at(-1), rotation = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), -angle);
      const material = isYoung ? young : mature;
      const range = add(material, bladeGeometry(THREE, length, width, lift, twist), base, rotation);
      const tip = new THREE.Vector3(length, length * lift, 0).applyQuaternion(rotation).add(new THREE.Vector3(...base)).toArray();
      botany.leaves.push({ base: scaled(base), tip: scaled(tip), stemPath: stemPath.map(scaled), length: length * growth,
        width: width * growth, young: isYoung, meshName: material.name, range });
    }

    const geometries = [];
    for (const [material, batch] of batches) {
      const geometry = new THREE.BufferGeometry();
      for (const name of ['position', 'normal', 'uv']) geometry.setAttribute(name, new THREE.Float32BufferAttribute(batch[name], name === 'uv' ? 2 : 3));
      geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const mesh = new THREE.Mesh(geometry, material);
      mesh.name = material.name;
      mesh.castShadow = mesh.receiveShadow = true;
      mesh.userData.species = group.userData.species;
      mesh.userData.solid = material === stone;
      mesh.userData.plantFoliage = material !== stone;
      if (material === stone) mesh.userData.mount = true;
      group.add(mesh); geometries.push(geometry);
    }
    return { group, geometries, materials, maps: [map] };
  }

  return { create };
});
