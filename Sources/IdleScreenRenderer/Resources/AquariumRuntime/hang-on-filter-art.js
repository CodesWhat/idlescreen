(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumHangOnFilterArt = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function tubeGeometry(THREE, points, radius) {
    const positions = [], indices = [], sides = 8;
    const vectors = points.map(point => new THREE.Vector3(...point));
    for (let ring = 0; ring < vectors.length; ring++) {
      const before = vectors[Math.max(0, ring - 1)], after = vectors[Math.min(vectors.length - 1, ring + 1)];
      const tangent = after.clone().sub(before).normalize();
      const reference = Math.abs(tangent.x) < .9 ? new THREE.Vector3(1, 0, 0) : new THREE.Vector3(0, 0, 1);
      const u = new THREE.Vector3().crossVectors(tangent, reference).normalize();
      const v = new THREE.Vector3().crossVectors(tangent, u).normalize();
      for (let side = 0; side < sides; side++) {
        const angle = side * Math.PI * 2 / sides;
        const vertex = vectors[ring].clone().addScaledVector(u, Math.cos(angle) * radius).addScaledVector(v, Math.sin(angle) * radius);
        positions.push(vertex.x, vertex.y, vertex.z);
        if (ring < vectors.length - 1) {
          const a = ring * sides + side, b = ring * sides + (side + 1) % sides;
          indices.push(a, b, a + sides, b, b + sides, a + sides);
        }
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setIndex(indices); geometry.computeVertexNormals();
    return geometry;
  }

  function caseGeometry(THREE, x, rimY) {
    const vertices = [];
    for (const [width, y, back, front] of [[2.08, rimY - 1.15, -4.01, -2.94], [2.30, rimY + .48, -4.12, -2.88]]) {
      vertices.push(x - width / 2, y, back, x + width / 2, y, back,
        x + width / 2, y, front, x - width / 2, y, front);
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(vertices, 3));
    geometry.setIndex([0, 1, 2, 0, 2, 3, 4, 6, 5, 4, 7, 6,
      0, 5, 1, 0, 4, 5, 1, 6, 2, 1, 5, 6, 2, 7, 3, 2, 6, 7, 3, 4, 0, 3, 7, 4]);
    geometry.computeVertexNormals();
    return geometry;
  }

  function create(THREE, { tankHalf, waterLevel = 8.05, rimY = 8.4, backZ = -2.6, cmPerUnit = 36 / 8.4, stripPlug } = {}) {
    if (!Number.isFinite(tankHalf) || tankHalf < 3) throw new RangeError('tankHalf must be finite and at least 3');
    if (!Number.isFinite(backZ) || !Number.isFinite(cmPerUnit) || cmPerUnit <= 0) throw new RangeError('backZ and cmPerUnit must be finite, with positive cmPerUnit');
    if (!Number.isFinite(rimY) || rimY < 4 || !Number.isFinite(waterLevel) || waterLevel < 3 || waterLevel > rimY - .15) {
      throw new RangeError('waterLevel must be at least 3 and at least .15 below a finite rimY');
    }
    const plug = Array.isArray(stripPlug) ? stripPlug.slice() : stripPlug?.toArray?.();
    if (!plug || plug.length !== 3 || !plug.every(Number.isFinite) || (plug[0] < tankHalf + .2 && plug[2] > backZ - .2) ||
        plug[1] < .1 || plug[1] > 2 || plug[2] < backZ - 2.8 || plug[2] > 4.8) {
      throw new RangeError('stripPlug must be a finite exterior-counter [x,y,z] anchor');
    }
    const shiftZ = backZ + 2.6; plug[2] -= shiftZ;
    const dryGroup = new THREE.Group(), wetGroup = new THREE.Group();
    dryGroup.name = 'hang-on-filter-dry'; wetGroup.name = 'hang-on-filter-wet';
    const geometries = [], materials = [], maps = [], batches = new Map();
    function material(name, color, group, properties = {}) {
      const result = new THREE.MeshPhongMaterial({ color, flatShading: true, shininess: 8, specular: 0x202626, ...properties });
      result.name = name; materials.push(result); batches.set(result, { group, positions: [], normals: [] });
      return result;
    }
    const shell = material('hob-charcoal-case', 0x242b2b, dryGroup);
    const trim = material('hob-graphite-trim', 0x414a49, dryGroup);
    const rubber = material('hob-rubber-mounts-cord', 0x171d1c, dryGroup, { shininess: 2 });
    const glassDry = material('hob-dry-intake-glass', 0xa7cec3, dryGroup, { transparent: true, opacity: .50, depthWrite: false, shininess: 40, side: THREE.DoubleSide });
    const glassWet = material('hob-wet-intake-glass', 0xa7cec3, wetGroup, { transparent: true, opacity: .46, depthWrite: false, shininess: 40, side: THREE.DoubleSide });
    const sponge = material('hob-intake-foam', 0x35423b, wetGroup, { shininess: 1 });
    const wetTrim = material('hob-wet-collars', 0x202b27, wetGroup, { shininess: 3 });
    const water = material('hob-flow-water', 0xb4ded1, wetGroup, {
      transparent: true, opacity: .43, depthWrite: false, shininess: 44, specular: 0x697e75, side: THREE.DoubleSide, vertexColors: true
    });
    function mesh(geometry, mat, group, name, extra = {}) {
      const object = new THREE.Mesh(geometry, mat); object.name = name;
      object.userData = { solid: true, equipment: 'hang-on-filter', ...extra };
      object.castShadow = !mat.transparent; object.receiveShadow = true;
      geometries.push(geometry); group.add(object); return object;
    }
    function add(mat, geometry, position = [0, 0, 0], rotation = new THREE.Quaternion()) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...position), rotation, new THREE.Vector3(1, 1, 1)));
      const flat = geometry.index ? geometry.toNonIndexed() : geometry, batch = batches.get(mat);
      batch.positions.push(...flat.attributes.position.array); batch.normals.push(...flat.attributes.normal.array);
      if (flat !== geometry) flat.dispose(); geometry.dispose();
    }
    function box(mat, width, height, depth, position) { add(mat, new THREE.BoxGeometry(width, height, depth), position); }
    function cylinder(mat, radius, height, position, sides = 10) { add(mat, new THREE.CylinderGeometry(radius, radius, height, sides), position); }
    function bar(mat, a, b, width, depth) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), delta = end.clone().sub(start);
      add(mat, new THREE.BoxGeometry(width, delta.length(), depth), start.add(end).multiplyScalar(.5).toArray(),
        new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), delta.normalize()));
    }
    function marker(group, name, point, data = {}) {
      const object = new THREE.Object3D(); object.name = name; object.position.fromArray(point); object.userData = data; group.add(object); return object;
    }
    const x = -tankHalf + 1.65, intakeX = x - .68, returnX = x + .30;
    add(shell, caseGeometry(THREE, x, rimY));
    box(rubber, 2.34, .055, 1.29, [x, rimY + .505, -3.50]);
    box(shell, 2.40, .13, 1.34, [x, rimY + .595, -3.50]);
    box(trim, 2.13, .035, 1.08, [x, rimY + .6775, -3.50]);
    box(shell, .56, .08, .16, [x + .21, rimY + .735, -3.52]);
    for (let i = 0; i < 4; i++) box(rubber, .065, .018, .34, [x + .44 + .14 * i, rimY + .704, -3.73]);
    cylinder(shell, .30, .48, [intakeX, rimY - 1.30, -3.36]);
    cylinder(trim, .32, .075, [intakeX, rimY - 1.53, -3.36]);
    marker(dryGroup, 'filter-case', [x, rimY - .335, -3.50], {
      bounds: { min: [x - 1.20, rimY - 1.57, -4.17], max: [x + 1.20, rimY + .775, -2.83] }
    });

    const mounts = [];
    for (const [label, offset] of [['left', -.98], ['right', .98]]) {
      const mountX = x + offset;
      box(trim, .16, .12, .67, [mountX, rimY + .06, -2.665]);
      box(shell, .16, .76, .14, [mountX, rimY - .26, -2.93]);
      box(rubber, .16, .20, .12, [mountX, rimY + .02, -2.39]);
      const rimName = 'filter-rim-contact-' + label;
      marker(dryGroup, rimName, [mountX, rimY, -2.60]);
      mounts.push({ connector: rimName, kind: 'rim', normal: [0, 1, 0] });
      box(shell, .13, .13, .36, [mountX, rimY - .99, -2.83]);
      box(rubber, .20, .19, .10, [mountX, rimY - .99, -2.65]);
      const rearName = 'filter-rear-contact-' + label;
      marker(dryGroup, rearName, [mountX, rimY - .99, -2.60]);
      mounts.push({ connector: rearName, kind: 'rear', normal: [0, 0, -1] });
    }
    dryGroup.userData.mounts = mounts;

    const tray = [[returnX, rimY + .09, -2.94], [returnX, rimY + .09, -2.40], [returnX, rimY - .07, -2.00]];
    for (let i = 1; i < tray.length; i++) {
      bar(shell, tray[i - 1], tray[i], 1.18, .07);
      for (const sign of [-1, 1]) {
        const a = tray[i - 1].slice(), b = tray[i].slice(); a[0] += sign * .60; b[0] += sign * .60; a[1] += .07; b[1] += .07;
        bar(trim, a, b, .065, .17);
      }
    }
    const lip = [returnX, rimY - .035, -1.99], impact = [returnX, waterLevel, -1.80];
    box(trim, 1.24, .055, .055, [returnX, lip[1] - .0275, lip[2]]);
    marker(dryGroup, 'filter-return-lip', lip, { direction: [0, -1, .4] });
    marker(wetGroup, 'filter-surface-impact', impact, { direction: [0, 0, 1], visualWater: true, solid: false });

    const intakeDry = [[intakeX, rimY - .50, -3.35], [intakeX, rimY + .15, -3.35],
      [intakeX, rimY + .34, -3.27], [intakeX, rimY + .42, -3.08], [intakeX, rimY + .42, -2.86],
      [intakeX, rimY + .35, -2.61], [intakeX, rimY + .20, -2.36], [intakeX, rimY + .18, -2.24], [intakeX, rimY + .04, -2.24]];
    const intakeWet = [intakeDry.at(-1).slice(), [intakeX, rimY - .27, -2.24], [intakeX, 2.69, -2.24], [intakeX, 2.43, -2.24]];
    marker(dryGroup, 'filter-pump-well', intakeDry[0]);
    marker(wetGroup, 'filter-intake-connection', intakeWet.at(-1));
    mesh(tubeGeometry(THREE, intakeDry, .09), glassDry, dryGroup, 'filter-intake-dry', { route: 'intake', routeSection: 'dry' });
    mesh(tubeGeometry(THREE, intakeWet, .09), glassWet, wetGroup, 'filter-intake-wet', { route: 'intake', routeSection: 'wet' });
    cylinder(sponge, .255, .85, [intakeX, 2.12, -2.24], 12);
    cylinder(wetTrim, .095, .22, [intakeX, 2.56, -2.24], 8);
    cylinder(wetTrim, .26, .055, [intakeX, 1.72, -2.24], 12);
    for (let row = 0; row < 5; row++) for (let side = 0; side < 8; side++) {
      const angle = side * Math.PI / 4 + (row % 2) * .16;
      box(wetTrim, .039, .043, .039, [intakeX + .246 * Math.sin(angle), 1.83 + row * .14, -2.24 + .246 * Math.cos(angle)]);
    }
    marker(wetGroup, 'intake-sponge', [intakeX, 2.12, -2.24], {
      bounds: { min: [intakeX - .27, 1.6925, -2.51], max: [intakeX + .27, 2.67, -1.97] }, solid: true
    });

    const origin = [intakeX, rimY - 1.36, -3.67];
    let power = [origin, [intakeX, rimY - 1.43, -3.90], [intakeX + .10, rimY - 1.65, -4.22],
      [intakeX + .12, .18, -4.22], [intakeX + .25, .004, -4.22], [tankHalf + .45, .004, -4.22],
      [tankHalf + .57, .004, plug[2] - .30], [plug[0] + .12, plug[1] + .20, plug[2] - .08],
      [plug[0], plug[1] + .17, plug[2]], plug.slice()];
    if (shiftZ) {
      const u = cm => cm / cmPerUnit, lowY = -.055 + u(.4), leftX = tankHalf - u(10), corridorZ = -2.6 - u(.7);
      const corners = [origin, [intakeX, rimY - 1.43, -3.90], [intakeX + .1, rimY - 1.65, -4.7],
        [intakeX + .15, lowY, -4.7], [leftX, lowY, -4.7], [leftX, lowY, corridorZ],
        [plug[0] - u(.6), lowY, corridorZ], [plug[0], plug[1], plug[2] + u(1)], plug.slice()];
      power = [corners[0]];
      for (let i = 1; i < corners.length - 1; i++) {
        const a = new THREE.Vector3(...corners[i - 1]), b = new THREE.Vector3(...corners[i]), c = new THREE.Vector3(...corners[i + 1]);
        const radius = Math.min(u(1.4), b.distanceTo(a) * .2, b.distanceTo(c) * .2);
        const entry = b.clone().addScaledVector(a.sub(b).normalize(), radius), exit = b.clone().addScaledVector(c.sub(b).normalize(), radius);
        power.push(entry.toArray());
        for (let j = 1; j <= 4; j++) { const t = j / 4; power.push(entry.clone().multiplyScalar((1 - t) ** 2).addScaledVector(b, 2 * t * (1 - t)).addScaledVector(exit, t * t).toArray()); }
      }
      power.push(corners.at(-1));
    }
    marker(dryGroup, 'filter-cord-outlet', origin);
    marker(dryGroup, 'filter-strip-connection', plug, { direction: shiftZ ? [0, 0, 1] : [0, -1, 0] });
    const cordRadius = shiftZ ? .25 / cmPerUnit : .026;
    add(rubber, tubeGeometry(THREE, power, cordRadius));
    bar(rubber, [intakeX, rimY - 1.36, -3.55], origin, .10, .10);
    dryGroup.userData.routes = {
      intake: { dry: intakeDry, wet: intakeWet, radius: .09, startConnector: 'filter-pump-well', endConnector: 'filter-intake-connection' },
      power: { dry: power, radius: cordRadius, startConnector: 'filter-cord-outlet', endConnector: 'filter-strip-connection' }
    };
    for (const [mat, batch] of batches) {
      if (!batch.positions.length) continue;
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(batch.normals, 3));
      mesh(geometry, mat, batch.group, mat.name);
    }

    const rows = 9, columns = 11, positions = new Float32Array(rows * columns * 3), colors = [], indices = [];
    for (let row = 0; row < rows; row++) for (let column = 0; column < columns; column++) {
      const shade = column % 3 === 0 ? .96 : .72;
      colors.push(shade, shade, shade);
      if (row < rows - 1 && column < columns - 1) {
        const a = row * columns + column;
        indices.push(a, a + columns, a + 1, a + 1, a + columns, a + columns + 1);
      }
    }
    const flowGeometry = new THREE.BufferGeometry();
    flowGeometry.setAttribute('position', new THREE.BufferAttribute(positions, 3).setUsage(THREE.DynamicDrawUsage));
    flowGeometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3)); flowGeometry.setIndex(indices);
    const sheet = mesh(flowGeometry, water, wetGroup, 'filter-waterfall-sheet', { visualWater: true, solid: false, rows, columns });
    sheet.renderOrder = 5; sheet.castShadow = false; sheet.receiveShadow = false;
    function update(time) {
      if (!Number.isFinite(time)) return;
      for (let row = 0; row < rows; row++) for (let column = 0; column < columns; column++) {
        const u = row / (rows - 1), lateral = column / (columns - 1) - .5;
        const envelope = Math.sin(Math.PI * u);
        const wave = Math.sin(time * 6.2 - u * 12 + column * 1.7);
        const i = (row * columns + column) * 3;
        positions[i] = returnX + lateral * (1.12 - .12 * u) + envelope * wave * .008;
        positions[i + 1] = lip[1] + (waterLevel - lip[1]) * u;
        positions[i + 2] = lip[2] + (impact[2] - lip[2]) * Math.sqrt(u) + envelope * wave * .018;
      }
      flowGeometry.attributes.position.needsUpdate = true; flowGeometry.computeVertexNormals();
    }
    update(0);
    flowGeometry.computeBoundingBox(); flowGeometry.boundingBox.expandByScalar(.025);
    flowGeometry.boundingSphere = new THREE.Sphere(); flowGeometry.boundingBox.getBoundingSphere(flowGeometry.boundingSphere);
    if (shiftZ) {
      for (const geometry of geometries) geometry.translate(0, 0, shiftZ);
      for (const group of [dryGroup, wetGroup]) group.traverse(object => {
        if (!object.isMesh && object !== group) object.position.z += shiftZ;
        if (object.userData.bounds) for (const side of ['min', 'max']) object.userData.bounds[side][2] += shiftZ;
      });
      for (const points of [intakeDry, intakeWet, power]) for (const point of points) point[2] += shiftZ;
      lip[2] += shiftZ; impact[2] += shiftZ;
    }
    dryGroup.userData.dimensions = { status: 'authored', caseWidthCm: 2.4 * cmPerUnit, backZ, cmPerUnit };
    dryGroup.userData.requiredCounterBounds = { min: [Math.min(...power.map(p => p[0])) - cordRadius, -.055, Math.min(...power.map(p => p[2])) - cordRadius], max: [Math.max(...power.map(p => p[0])) + cordRadius, -.055, Math.max(...power.map(p => p[2])) + cordRadius] };
    dryGroup.userData.equipment = wetGroup.userData.equipment = 'hang-on-back-waterfall-filter';
    return { dryGroup, wetGroup, geometries, materials, maps, returnPoint: new THREE.Vector3(...impact), update };
  }
  return { create };
});
