(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumCarpetArt = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  function create(THREE, { tankHalf, bedLevel, waterLevel, exclusions = [], backZ = -2.575, frontZ = 3.98 }) {
    if (![tankHalf, bedLevel, waterLevel, backZ, frontZ].every(Number.isFinite) || tankHalf < .6 || bedLevel <= .12 || waterLevel <= bedLevel + .12 || frontZ - backZ <= .5) {
      throw new RangeError('Carpet needs finite tank dimensions, substrate depth, and water above the bed.');
    }
    const group = new THREE.Group(), geometries = [], materials = [], maps = [];
    group.name = 'rooted-planted-carpet';
    group.userData.substratePlant = true;
    const plants = [], grazeSites = [], dynamic = [];
    group.userData.botany = { plants };
    group.userData.grazeSites = grazeSites;
    let seed = 740931;
    const random = () => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed / 4294967296; };
    const clamp = (value, low, high) => Math.max(low, Math.min(high, value));
    const depth = frontZ - backZ, sideX = tankHalf - .02;
    const heightScale = Math.min(1, (waterLevel - bedLevel - .07) / 1.1);
    const rootScale = Math.min(1, (bedLevel - .085) / .6);
    const colors = [0x789c45, 0x698d38, 0x89a84d, 0x567c32, 0x739340].map(hex => new THREE.Color(hex));
    const rootColor = new THREE.Color(0x9a9b6c), stemColor = new THREE.Color(0x5c8139);
    const up = new THREE.Vector3(0, 1, 0), tangent = new THREE.Vector3(), side = new THREE.Vector3(), across = new THREE.Vector3();
    const batches = Object.fromEntries(['roots', 'stems', 'foliage'].map(name => [name, { name, p: [], c: [], uv: [], indices: [] }]));

    function vertex(batch, point, color, u = .5, v = .5, shade = 1) {
      const index = batch.p.length / 3;
      batch.p.push(...point); batch.c.push(color.r * shade, color.g * shade, color.b * shade); batch.uv.push(u, v);
      return index;
    }
    function tube(batch, points, radius, color) {
      const first = batch.p.length / 3, sides = 3;
      for (let i = 0; i < points.length; i++) {
        const before = points[Math.max(0, i - 1)], after = points[Math.min(points.length - 1, i + 1)];
        tangent.set(after[0] - before[0], after[1] - before[1], after[2] - before[2]).normalize();
        side.crossVectors(Math.abs(tangent.y) < .95 ? up : new THREE.Vector3(1, 0, 0), tangent).normalize();
        across.crossVectors(tangent, side);
        const r = radius * (1 - .76 * i / (points.length - 1));
        for (let j = 0; j < sides; j++) {
          const angle = j * Math.PI * 2 / sides, a = Math.cos(angle) * r, b = Math.sin(angle) * r;
          vertex(batch, [points[i][0] + side.x * a + across.x * b, points[i][1] + side.y * a + across.y * b, points[i][2] + side.z * a + across.z * b], color);
        }
        if (i) for (let j = 0; j < sides; j++) {
          const a = first + (i - 1) * sides + j, b = first + i * sides + j, c = first + i * sides + (j + 1) % sides, d = first + (i - 1) * sides + (j + 1) % sides;
          batch.indices.push(a, b, c, a, c, d);
        }
      }
      const bottom = vertex(batch, points[0], color), top = vertex(batch, points.at(-1), color), end = first + (points.length - 1) * sides;
      for (let j = 0; j < sides; j++) batch.indices.push(bottom, first + (j + 1) % sides, first + j, top, end + j, end + (j + 1) % sides);
    }
    function inTank(point) {
      return [clamp(point[0], -sideX + .01, sideX - .01), point[1], clamp(point[2], backZ + .012, frontZ - .012)];
    }
    function leaf(base, length, yaw, lift, color, plantIndex) {
      const batch = batches.foliage, start = batch.p.length / 3, width = length * (.79 + random() * .14);
      const outline = [[0, 0], [.14, -.32], [.42, -.49], [.78, -.42], [1, 0], [.78, .42], [.42, .49], [.14, .32]];
      function point(u, v) {
        return inTank([base[0] + Math.cos(yaw) * length * u - Math.sin(yaw) * width * v,
          base[1] + length * lift * u + Math.sin(Math.PI * u) * .018 * heightScale + Math.abs(v) * .012 * heightScale,
          base[2] + Math.sin(yaw) * length * u + Math.cos(yaw) * width * v]);
      }
      for (const [u, v] of outline) vertex(batch, point(u, v), color, u, v + .5, .96 + u * .07);
      const site = point(.49, 0), center = vertex(batch, site, color, .49, .5, 1.035);
      for (let j = 0; j < outline.length; j++) batch.indices.push(center, start + (j + 1) % outline.length, start + j);
      grazeSites.push({ plantIndex, position: [...site], rest: [...site] });
      return { base: [...base], site, range: { start, count: batch.p.length / 3 - start } };
    }
    function blade(anchor, height, yaw, width, lean, color) {
      const batch = batches.foliage, first = batch.p.length / 3, path = [anchor];
      vertex(batch, anchor, color, 0, .5, .83);
      for (const t of [.18, .51, .79]) {
        const center = inTank([anchor[0] + Math.cos(yaw) * lean * t * t, anchor[1] + height * t, anchor[2] + Math.sin(yaw) * lean * t * t]);
        path.push(center);
        for (const sign of [-1, 1]) vertex(batch, inTank([center[0] + Math.sin(yaw) * width * sign * (1 - t * .7), center[1], center[2] - Math.cos(yaw) * width * sign * (1 - t * .7)]), color, t, sign > 0 ? 1 : 0, .88 + t * .16);
      }
      const tip = inTank([anchor[0] + Math.cos(yaw) * lean, anchor[1] + height, anchor[2] + Math.sin(yaw) * lean]);
      path.push(tip); vertex(batch, tip, color, 1, .5, 1.04);
      batch.indices.push(first, first + 2, first + 1, first + 1, first + 2, first + 3, first + 2, first + 4, first + 3,
        first + 3, first + 4, first + 5, first + 4, first + 6, first + 5, first + 5, first + 6, first + 7);
      return { path, leaves: [] };
    }

    function addPlant(x, z, front) {
      const pathX = Math.sin(z * .68) * tankHalf * .11;
      const laneWidth = .12 + .045 * (.5 + .5 * Math.sin(z * 1.8));
      const feedingPocket = Math.hypot(x - tankHalf * .075, (z - (backZ + depth * (4.375 / 6.555))) * 1.2) < .31;
      if (Math.abs(x - pathX) < laneWidth || feedingPocket) return;
      const species = random() < .59 + .12 * Math.sin(x * 1.8 - z * 1.6) ? 'monte-carlo' : 'hairgrass';
      const tall = random() < .085;
      const height = (tall ? .97 + random() * .09 : front ? .46 + random() * .36 : .35 + random() * .45) * heightScale;
      const anchor = [x, bedLevel, z], phase = random() * Math.PI * 2;
      const envelope = new THREE.Box3(new THREE.Vector3(x - .40, bedLevel - .62 * rootScale, z - .40), new THREE.Vector3(x + .40, bedLevel + height + .10, z + .40));
      if (exclusions.some(box => box.intersectsBox(envelope))) return;
      const plant = { anchor, height, front, species, phase, roots: [], shoots: [], ranges: {}, dx: 0, dy: 0, dz: 0 };
      const plantIndex = plants.length;
      for (const batch of Object.values(batches)) plant.ranges[batch.name] = { start: batch.p.length / 3, count: 0 };
      const rootDepth = (.41 + random() * .18) * rootScale, spread = .07 + random() * .06;
      const rootA = [anchor,
        inTank([x + spread * .35, bedLevel - rootDepth * .48, front ? z - .002 - random() * .004 : z + .025]),
        inTank([x + spread, bedLevel - rootDepth, front ? z - .008 - random() * .005 : z + .09])];
      const rootB = [anchor,
        inTank([x - spread * .5, bedLevel - rootDepth * .35, z - .055]),
        inTank([x - spread * .8, bedLevel - rootDepth * .84, z - .09 - random() * .025])];
      const branch = [rootA[1], inTank([x + spread * 1.35, bedLevel - rootDepth * .82, front ? z - .044 : z + .13])];
      plant.roots.push(rootA, rootB, branch);
      tube(batches.roots, rootA, .0067, rootColor); tube(batches.roots, rootB, .0050, rootColor); tube(batches.roots, branch, .0035, rootColor);
      const color = colors[Math.floor(random() * colors.length)];
      if (species === 'hairgrass') {
        const count = 6 + Math.floor(random() * 3);
        for (let i = 0; i < count; i++) {
          const yaw = front ? -random() * Math.PI : phase + i * 2.399;
          const lean = .045 + random() * .14;
          plant.shoots.push(blade(anchor, height * (i === 0 ? 1 : .58 + random() * .4), yaw, .010 + random() * .006, lean, colors[(i + plantIndex) % colors.length]));
        }
      } else {
        for (let i = 0; i < 2; i++) {
          const sign = i ? 1 : -1, spreadX = (.045 + random() * .055) * sign;
          const shootHeight = height * (i ? 1 : .70 + random() * .15);
          const path = [anchor, inTank([x + spreadX * .7, bedLevel + .015 * heightScale, z - .015]),
            inTank([x + spreadX, bedLevel + shootHeight * .28, z - .03]),
            inTank([x + spreadX * 1.25, bedLevel + shootHeight * .59, z - .045]),
            inTank([x + spreadX * 1.65, bedLevel + shootHeight * .92, z - .055])];
          tube(batches.stems, path, .009, stemColor);
          const shoot = { path, leaves: [] };
          for (let node = 2; node < path.length; node++) {
            const yaw = front ? (random() - .5) * .28 : phase + node * 1.62 + i * .7;
            const length = (.14 + random() * .065) * (node === 4 ? .77 : 1) * Math.min(1, heightScale * 1.4);
            for (let side = 0; side < 2; side++) shoot.leaves.push(leaf(path[node], length, yaw + side * Math.PI, .18 + random() * .18, color, plantIndex));
          }
          plant.shoots.push(shoot);
        }
      }
      const bounds = new THREE.Box3();
      for (const batch of Object.values(batches)) {
        const range = plant.ranges[batch.name]; range.count = batch.p.length / 3 - range.start;
        for (let i = range.start; i < range.start + range.count; i++) bounds.expandByPoint(new THREE.Vector3(batch.p[i * 3], batch.p[i * 3 + 1], batch.p[i * 3 + 2]));
      }
      plant.limits = { minX: Math.max(-.13, -sideX - bounds.min.x), maxX: Math.min(.13, sideX - bounds.max.x), minZ: Math.max(-.13, backZ - bounds.min.z), maxZ: Math.min(.13, frontZ - bounds.max.z), maxY: Math.min(.025, waterLevel - .025 - bounds.max.y) };
      plants.push(plant);
    }

    const step = .30, columns = Math.floor((tankHalf * 2 - .30) / step), rows = Math.max(2, Math.round((depth - .444) / .291) + 1);
    const rowStep = (depth - .444) / (rows - 1);
    for (let row = 0; row < rows; row++) for (let col = 0; col < columns; col++) {
      const x = -tankHalf + .20 + (col + .4 + (random() - .5) * .68) * (tankHalf * 2 - .40) / columns;
      const z = backZ + .225 + row * rowStep + (random() - .5) * .18;
      addPlant(x, z, false);
    }
    const frontColumns = Math.floor((tankHalf * 2 - .24) / .23);
    for (let col = 0; col < frontColumns; col++) {
      const x = -tankHalf + .15 + (col + .45 + (random() - .5) * .48) * (tankHalf * 2 - .30) / frontColumns;
      addPlant(x, frontZ - .037 + random() * .007, true);
    }

    function leafMap() {
      const pixels = new Uint8Array(16 * 16 * 4), shades = [224, 236, 246, 231];
      for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++) {
        const shade = shades[(Math.floor(x / 2) * 13 + Math.floor(y / 2) * 7 + Math.floor(x / 6)) % shades.length];
        pixels.set([shade, Math.min(255, shade + 8), shade - 12, 255], (y * 16 + x) * 4);
      }
      const map = new THREE.DataTexture(pixels, 16, 16, THREE.RGBAFormat);
      map.name = 'carpet-leaf-pixels'; map.colorSpace = THREE.SRGBColorSpace;
      map.minFilter = map.magFilter = THREE.NearestFilter; map.generateMipmaps = false; map.needsUpdate = true;
      maps.push(map); return map;
    }
    for (const batch of Object.values(batches)) {
      if (!batch.p.length) continue;
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.p, 3));
      geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.c, 3));
      geometry.setAttribute('uv', new THREE.Float32BufferAttribute(batch.uv, 2));
      geometry.setIndex(batch.indices); geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const material = new THREE.MeshLambertMaterial({ color: 0xffffff, vertexColors: true, flatShading: true, side: THREE.DoubleSide, map: batch.name === 'foliage' ? leafMap() : null });
      const mesh = new THREE.Mesh(geometry, material);
      mesh.name = 'carpet-' + batch.name; mesh.castShadow = mesh.receiveShadow = true;
      mesh.userData.plantFoliage = batch.name === 'foliage'; mesh.userData.substratePlant = true;
      mesh.userData.carpetBatch = batch.name;
      group.add(mesh); geometries.push(geometry); materials.push(material);
      if (batch.name !== 'roots') {
        geometry.attributes.position.setUsage(THREE.DynamicDrawUsage); geometry.attributes.normal.setUsage(THREE.DynamicDrawUsage);
        geometry.boundingBox.min.x = Math.max(-sideX, geometry.boundingBox.min.x - .13);
        geometry.boundingBox.max.x = Math.min(sideX, geometry.boundingBox.max.x + .13);
        geometry.boundingBox.min.z = Math.max(backZ, geometry.boundingBox.min.z - .13);
        geometry.boundingBox.max.z = Math.min(frontZ, geometry.boundingBox.max.z + .13);
        geometry.boundingBox.min.y -= .018; geometry.boundingBox.max.y += .025;
        geometry.boundingSphere.radius += .15;
        const rest = geometry.attributes.position.array.slice(), normals = geometry.attributes.normal.array.slice();
        const weights = new Float32Array(rest.length / 3), slopes = new Float32Array(weights.length);
        for (const plant of plants) {
          const range = plant.ranges[batch.name];
          for (let i = range.start; i < range.start + range.count; i++) {
            const t = clamp((rest[i * 3 + 1] - bedLevel) / plant.height, 0, 1);
            weights[i] = t * t; slopes[i] = t < 1 ? 2 * t / plant.height : 0;
          }
        }
        dynamic.push({ name: batch.name, geometry, rest, normals, weights, slopes });
      }
    }

    function update(time, flowField) {
      if (!Number.isFinite(time)) return;
      const flowing = typeof flowField?.sample === 'function';
      let changed = false;
      for (const plant of plants) {
        const [x, y, z] = plant.anchor;
        const flow = flowing ? flowField.sample(x, y + plant.height * .65, z, time) : null;
        const valid = flow && [flow.x, flow.y, flow.z, flow.strength].every(Number.isFinite);
        const force = valid ? clamp(flow.strength, 0, 1) * (.075 + plant.height * .075) * (plant.species === 'hairgrass' ? 1 : .78) * (.88 + .12 * Math.sin(time * 1.7 + plant.phase)) : 0;
        const dx = force ? clamp(clamp(flow.x, -1, 1) * force, plant.limits.minX, plant.limits.maxX) : 0;
        const dz = force ? clamp(clamp(flow.z, -1, 1) * force, plant.limits.minZ, plant.limits.maxZ) : 0;
        const dy = force ? clamp(clamp(flow.y, -1, 1) * force * .15, -.018, plant.limits.maxY) : 0;
        if (plant.dx !== dx || plant.dy !== dy || plant.dz !== dz) changed = true;
        plant.dx = dx; plant.dy = dy; plant.dz = dz;
      }
      if (!changed) return;
      for (const batch of dynamic) {
        const p = batch.geometry.attributes.position.array, n = batch.geometry.attributes.normal.array;
        for (const plant of plants) {
          const range = plant.ranges[batch.name], { dx, dy, dz } = plant;
          for (let i = range.start; i < range.start + range.count; i++) {
            const j = i * 3, weight = batch.weights[i], slope = batch.slopes[i];
            p[j] = batch.rest[j] + dx * weight; p[j + 1] = batch.rest[j + 1] + dy * weight; p[j + 2] = batch.rest[j + 2] + dz * weight;
            if (!dx && !dy && !dz) { n[j] = batch.normals[j]; n[j + 1] = batch.normals[j + 1]; n[j + 2] = batch.normals[j + 2]; continue; }
            const nx = batch.normals[j], nz = batch.normals[j + 2], ny = (batch.normals[j + 1] - slope * (dx * nx + dz * nz)) / (1 + dy * slope);
            const inverse = 1 / (Math.hypot(nx, ny, nz) || 1);
            n[j] = nx * inverse; n[j + 1] = ny * inverse; n[j + 2] = nz * inverse;
          }
        }
        batch.geometry.attributes.position.needsUpdate = true; batch.geometry.attributes.normal.needsUpdate = true;
      }
      for (const site of grazeSites) {
        const plant = plants[site.plantIndex], t = clamp((site.rest[1] - bedLevel) / plant.height, 0, 1), weight = t * t;
        site.position[0] = site.rest[0] + plant.dx * weight;
        site.position[1] = site.rest[1] + plant.dy * weight;
        site.position[2] = site.rest[2] + plant.dz * weight;
      }
    }
    return { group, geometries, materials, maps, update };
  }
  return { create };
});
