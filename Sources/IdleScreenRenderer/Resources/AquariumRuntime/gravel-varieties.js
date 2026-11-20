(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumGravelVarieties = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const SHAPES = ['round', 'oblong', 'flattened', 'angular'];
  const MAX_INSTANCES = 60000;

  function hash(value) {
    value = Math.imul(value ^ value >>> 16, 0x7feb352d);
    value = Math.imul(value ^ value >>> 15, 0x846ca68b);
    return (value ^ value >>> 16) >>> 0;
  }
  function randomSource(seed) {
    return function () {
      seed = (seed + 0x6d2b79f5) >>> 0;
      let value = Math.imul(seed ^ seed >>> 15, seed | 1);
      value ^= value + Math.imul(value ^ value >>> 7, value | 61);
      return ((value ^ value >>> 14) >>> 0) / 4294967296;
    };
  }
  function grainGeometry(THREE, shape) {
    const geometry = new THREE.IcosahedronGeometry(1, 0), position = geometry.attributes.position;
    const proportions = [[1, .96, .94], [1, .61, .66], [1, .32, .82], [1, .81, .88]][shape];
    const point = new THREE.Vector3(), shade = [];
    for (let i = 0; i < position.count; i++) {
      point.fromBufferAttribute(position, i);
      const irregular = shape === 3 ? .88 + .12 * point.x + .08 * point.y * point.z : 1;
      position.setXYZ(i, point.x * proportions[0] * irregular, point.y * proportions[1] * irregular, point.z * proportions[2] * irregular);
    }
    geometry.computeBoundingBox(); const center = geometry.boundingBox.getCenter(new THREE.Vector3());
    geometry.translate(-center.x, -center.y, -center.z);
    let radius = 0;
    for (let i = 0; i < position.count; i++) radius = Math.max(radius, point.fromBufferAttribute(position, i).length());
    geometry.scale(.5 / radius, .5 / radius, .5 / radius);
    for (let face = 0; face < position.count / 3; face++) {
      const value = .91 + (hash(face + shape * 29) % 10) * .01;
      for (let vertex = 0; vertex < 3; vertex++) shade.push(value, value, value);
    }
    geometry.deleteAttribute('uv'); geometry.setAttribute('color', new THREE.Float32BufferAttribute(shade, 3));
    geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
    geometry.name = 'river-grain-' + SHAPES[shape];
    return geometry;
  }

  function layout(width, depth, bedLevel) {
    let pitch = .076, plan;
    do {
      const columns = Math.ceil(width / pitch), rows = Math.ceil(depth / pitch), strata = Math.ceil(bedLevel / (pitch * .84));
      const count = columns * rows + columns * strata * 2 + rows * strata * 2;
      plan = { pitch, columns, rows, strata, count };
      if (count > MAX_INSTANCES) pitch *= Math.sqrt(count / MAX_INSTANCES) * 1.002;
    } while (plan.count > MAX_INSTANCES);
    return plan;
  }

  function create(THREE, { seed = 613, tankHalf = 9, bedLevel = .70, frontZ = 4, backZ = -2.6, style = 'river', diameterRange = [.055,.14] } = {}) {
    if (!Number.isFinite(seed)) throw new RangeError('seed must be finite');
    if (!Number.isFinite(tankHalf) || tankHalf < .25 || tankHalf > 32) throw new RangeError('tankHalf must be within .25..32');
    if (!Number.isFinite(bedLevel) || bedLevel < .14 || bedLevel > 2) throw new RangeError('bedLevel must be within .14..2');
    if (!Number.isFinite(frontZ) || !Number.isFinite(backZ) || frontZ - backZ < .3 || frontZ - backZ > 16) throw new RangeError('frontZ and backZ must define a depth within .3..16');
    if (style !== 'river') throw new RangeError('style must be river; the parent owns basalt');
    if(!Array.isArray(diameterRange)||diameterRange.length!==2||!diameterRange.every(Number.isFinite)||diameterRange[0]<=0||diameterRange[1]<diameterRange[0]||diameterRange[1]>.3)throw new RangeError('Invalid grain diameter range');
    seed >>>= 0;
    const random = randomSource(seed), width = tankHalf * 2, depth = frontZ - backZ;
    const plan = layout(width, depth, bedLevel), group = new THREE.Group(); group.name = 'river-gravel';
    const geometries = SHAPES.map((name, i) => grainGeometry(THREE, i));
    const material = new THREE.MeshPhongMaterial({ color: 0xffffff, specular: 0x171816, shininess: 9, flatShading: true, vertexColors: true });
    material.name = 'muted-river-gravel';
    const materials = [material], maps = [], layers = [
      { name: 'top', rows: plan.rows, columns: plan.columns },
      { name: 'front', rows: plan.strata * 2, columns: plan.columns },
      { name: 'left', rows: plan.strata, columns: plan.rows },
      { name: 'right', rows: plan.strata, columns: plan.rows }
    ];
    const counts = [0, 0, 0, 0], ranges = [[], [], [], []];
    const shapeAt = index => { const value = hash((index ^ seed) >>> 0) / 4294967296; return value < .36 ? 0 : value < .64 ? 1 : value < .86 ? 2 : 3; };
    let serial = 0;
    for (const layer of layers) {
      const start = counts.slice();
      for (let i = 0; i < layer.rows * layer.columns; i++) counts[shapeAt(serial++)]++;
      for (let shape = 0; shape < 4; shape++) ranges[shape].push({ layer: layer.name, start: start[shape], count: counts[shape] - start[shape] });
    }
    const meshes = geometries.map((geometry, shape) => {
      const mesh = new THREE.InstancedMesh(geometry, material, counts[shape]);
      mesh.name = 'river-gravel-' + SHAPES[shape];
      mesh.userData = { shape: SHAPES[shape], substrate: true, solid: false, hardscape: false, plantFoliage: false, layers: ranges[shape] };
      mesh.boundingBox = new THREE.Box3();
      mesh.receiveShadow = true; mesh.castShadow = false; group.add(mesh); return mesh;
    });
    const vertices = geometries.map(geometry => {
      const unique = new Map(), position = geometry.attributes.position;
      for (let i = 0; i < position.count; i++) {
        const point = new THREE.Vector3().fromBufferAttribute(position, i); unique.set(point.toArray().join(','), point);
      }
      return [...unique.values()];
    });
    const palette = [0x77776d, 0x8b806b, 0x5f6866, 0x9d927a, 0x71655c, 0x858981].map(value => new THREE.Color(value));
    const color = new THREE.Color(), matrix = new THREE.Matrix4(), orientation = new THREE.Quaternion(), euler = new THREE.Euler();
    const position = new THREE.Vector3(), scale = new THREE.Vector3(), point = new THREE.Vector3(), low = new THREE.Vector3(), high = new THREE.Vector3();
    const offsets = [0, 0, 0, 0], phase = seed % 997 / 997 * Math.PI * 2;
    const wave = (x, z) => .0045 * Math.sin(x * 2.13 + z * 1.71 + phase) + .0035 * Math.sin(x * 5.17 - z * 3.11 - phase);
    const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
    const stepX = width / plan.columns, stepZ = depth / plan.rows, stepY = bedLevel / plan.strata;

    function grain(shape, x, y, z, layer, band) {
      const size = random(), diameter = diameterRange[0]+(diameterRange[1]-diameterRange[0])*(size*.55+random()*.45);
      const tilt = layer === 'top' ? .6 : 1.8;
      euler.set((random() - .5) * tilt, random() * Math.PI * 2, (random() - .5) * tilt); orientation.setFromEuler(euler);
      scale.setScalar(diameter); position.set(0, 0, 0); matrix.compose(position, orientation, scale);
      low.set(Infinity, Infinity, Infinity); high.set(-Infinity, -Infinity, -Infinity);
      for (const vertex of vertices[shape]) { point.copy(vertex).applyMatrix4(matrix); low.min(point); high.max(point); }
      x = clamp(x, -tankHalf + .004 - low.x, tankHalf - .004 - high.x);
      z = clamp(z, backZ + .004 - low.z, frontZ - .004 - high.z);
      if (layer === 'top') y = bedLevel - .034 + wave(x, z) - low.y;
      else {
        y = clamp(y, .002 - low.y, bedLevel + wave(x, z) - high.y);
        if (layer === 'front') z = band === 0 ? frontZ - .006 - high.z - random() * .018 : frontZ - .126 + (random() - .5) * .046;
        if (layer === 'left') x = -tankHalf + .006 - low.x + random() * .018;
        if (layer === 'right') x = tankHalf - .006 - high.x - random() * .018;
      }
      position.set(x, y, z); matrix.setPosition(position); const mesh = meshes[shape], index = offsets[shape]++;
      mesh.setMatrixAt(index, matrix);
      mesh.boundingBox.expandByPoint(low.add(position)); mesh.boundingBox.expandByPoint(high.add(position));
      const tone = Math.floor(random() * palette.length), shade = (layer === 'top' ? 1 : .80 + .20 * y / bedLevel) * (.94 + random() * .09);
      color.copy(palette[tone]).multiplyScalar(shade); mesh.setColorAt(index, color);
    }

    serial = 0;
    for (const layer of layers) for (let row = 0; row < layer.rows; row++) for (let col = 0; col < layer.columns; col++) {
      const jitterX = (random() - .5) * .94, jitterY = (random() - .5) * .94;
      let x, y, z, band = 0;
      if (layer.name === 'top') {
        x = -tankHalf + (col + .5 + jitterX) * stepX;
        z = backZ + (row + .5 + jitterY) * stepZ; y = bedLevel;
        x += .014 * Math.sin(z * 7.1 + phase); z += .012 * Math.sin(x * 6.3 - phase);
      } else if (layer.name === 'front') {
        band = Math.floor(row / plan.strata); x = -tankHalf + (col + .5 + jitterX) * stepX;
        y = (row % plan.strata + .5 + jitterY) * stepY; z = frontZ - .08;
      } else {
        x = layer.name === 'left' ? -tankHalf + .08 : tankHalf - .08;
        y = (row + .5 + jitterY) * stepY; z = backZ + (col + .5 + jitterX) * stepZ;
      }
      grain(shapeAt(serial++), x, y, z, layer.name, band);
    }
    for (const mesh of meshes) {
      mesh.instanceMatrix.needsUpdate = true; mesh.instanceColor.needsUpdate = true;
      mesh.boundingBox.expandByScalar(.000005);
      mesh.boundingSphere = mesh.boundingBox.getBoundingSphere(new THREE.Sphere());
    }
    group.userData = {
      style, seed, bedLevel, tankHalf, frontZ, backZ, solid: false, substrate: true,
      instanceCount: plan.count, instanceBytes: plan.count * 76, maxInstances: MAX_INSTANCES,
      diameterRange: diameterRange.slice(), pitch: plan.pitch, strata: plan.strata, frontDepthBands: 2,
      heightSampling: 'nominal top envelope, not a grain collision surface',
      sampleHeight(x, z) {
        if (!Number.isFinite(x) || !Number.isFinite(z) || x < -tankHalf || x > tankHalf || z < backZ || z > frontZ) return null;
        return bedLevel + .026 + wave(x, z);
      }
    };
    return { group, geometries, materials, maps };
  }
  return { create };
});
