(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumDragonDriftwoodV1 = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const descriptor = Object.freeze({
    id: 'dragon-driftwood', label: 'Rootwood dragon', kind: 'ornament', material: 'authored sculpted wood',
    dimensionBasis: 'authored', researchedProductDimensionsCm: null, tankExteriorCm: Object.freeze([60, 36, 36]),
    defaultPlacement: false, reviewOnly: true, animated: false,
    reference: '../references/user/dragon-driftwood-sculpture.png',
    localAxes: Object.freeze({ up: '+Y', displayFront: '+Z', headDirection: '-X' })
  });
  function randomSource(seed) {
    return function () {
      seed = (seed + 0x6d2b79f5) >>> 0;
      let value = Math.imul(seed ^ seed >>> 15, seed | 1);
      value ^= value + Math.imul(value ^ value >>> 7, value | 61);
      return ((value ^ value >>> 14) >>> 0) / 4294967296;
    };
  }
  function grainMap(THREE, seed) {
    const random = randomSource(seed), width = 24, height = 64, data = new Uint8Array(width * height * 4);
    for (let x = 0; x < width; x++) {
      const stripe = Math.floor(random() * 22);
      for (let y = 0; y < height; y++) {
        const seam = (x + Math.floor(y / 21)) % 7 === 0, value = 217 + stripe - (seam ? 40 : 0) + (Math.floor(y / 5) % 2) * 8;
        data.set([value, value - 8, value - 19, 255], (y * width + x) * 4);
      }
    }
    const map = new THREE.DataTexture(data, width, height, THREE.RGBAFormat);
    map.name = 'original-dragon-root-grain'; map.colorSpace = THREE.SRGBColorSpace;
    map.wrapS = map.wrapT = THREE.RepeatWrapping; map.minFilter = map.magFilter = THREE.NearestFilter;
    map.generateMipmaps = false; map.needsUpdate = true; return map;
  }
  function create(THREE, { seed = 1049, cmPerUnit = 36 / 8.4, size = 1 } = {}) {
    if (!Number.isFinite(seed)) throw new RangeError('seed must be finite');
    if (!Number.isFinite(cmPerUnit) || cmPerUnit <= 0) throw new RangeError('cmPerUnit must be positive and finite');
    if (!Number.isFinite(size) || size < .7 || size > 1.15) throw new RangeError('size must be within .7..1.15');
    seed >>>= 0;
    const factor = size / cmPerUnit, group = new THREE.Group(), map = grainMap(THREE, seed);
    group.name = 'dragon-driftwood';
    const material = new THREE.MeshLambertMaterial({ color: 0xa88758, map, vertexColors: true, flatShading: true });
    material.name = 'rootwood-dragon-facets';
    const positions = [], colors = [], uv = [], branches = [], byId = new Map(), groundContacts = [];
    const vector = p => new THREE.Vector3(...p), scale = p => p.map(n => n * factor);
    function triangle(a, b, c, shade = 1, tex = [[0, 0], [1, 0], [0, 1]]) {
      positions.push(...a.toArray(), ...b.toArray(), ...c.toArray());
      for (let j = 0; j < 3; j++) { colors.push(shade, shade * .98, shade * .94); uv.push(...tex[j]); }
    }
    function tube(id, controls, radii, parentId = null, parentStation = null, sides = 6, tone = 1) {
      const curve = new THREE.CatmullRomCurve3(controls.map(vector), false, 'centripetal');
      const steps = Math.max(3, Math.min(64, Math.ceil(curve.getLength() / .65))), points = [], widths = [], rings = [];
      const vertexStart = positions.length / 3; let frame, distance = 0;
      for (let i = 0; i <= steps; i++) {
        const t = i / steps, p = curve.getPoint(t), tangent = curve.getTangent(t).normalize();
        if (i === 0) p.copy(vector(controls[0]));
        if (i) distance += p.distanceTo(points.at(-1));
        if (!frame) frame = new THREE.Vector3().crossVectors(tangent, Math.abs(tangent.z) < .85 ? new THREE.Vector3(0, 0, 1) : new THREE.Vector3(1, 0, 0)).normalize();
        frame.addScaledVector(tangent, -frame.dot(tangent)).normalize();
        const across = new THREE.Vector3().crossVectors(tangent, frame).normalize();
        const interval = Math.min(radii.length - 2, Math.floor(t * (radii.length - 1)));
        const r = THREE.MathUtils.lerp(radii[interval], radii[interval + 1], t * (radii.length - 1) - interval);
        points.push(p); widths.push(r);
        rings.push(Array.from({ length: sides }, (_, j) => {
          const angle = j / sides * Math.PI * 2 + .13;
          return p.clone().addScaledVector(frame, Math.cos(angle) * r).addScaledVector(across, Math.sin(angle) * r);
        }));
      }
      for (let i = 0; i < steps; i++) for (let j = 0; j < sides; j++) {
        const next = (j + 1) % sides, shade = [.84, 1, .95, .88, 1.04, .91, .97, .86][j] * tone;
        const a = j / sides, b = (j + 1) / sides, v = i / steps * distance * .22, w = (i + 1) / steps * distance * .22;
        triangle(rings[i][j], rings[i][next], rings[i + 1][j], shade, [[a, v], [b, v], [a, w]]);
        triangle(rings[i][next], rings[i + 1][next], rings[i + 1][j], shade, [[b, v], [b, w], [a, w]]);
      }
      for (let j = 0; j < sides; j++) {
        const next = (j + 1) % sides;
        triangle(points[0], rings[0][next], rings[0][j], .8 * tone);
        triangle(points.at(-1), rings.at(-1)[j], rings.at(-1)[next], 1.07 * tone);
      }
      const record = { id, parentId, parentStation, points: points.map(p => p.toArray()), radii: widths,
        vertexStart, vertexCount: positions.length / 3 - vertexStart };
      branches.push(record); byId.set(id, record); return record;
    }
    function attach(id, parentId, fraction, controls, radii, sides = 6, tone = 1) {
      const parent = byId.get(parentId), station = Math.round((parent.points.length - 1) * fraction);
      return tube(id, [parent.points[station], ...controls], radii, parentId, station, sides, tone);
    }
    const spine = tube('spine', [[-7, 16, 0], [-5.5, 12, 0], [-4, 8.8, .1], [.2, 8.2, 0], [4.5, 11.7, -.25],
      [7.2, 7.3, .2], [9.8, 6.8, 0], [12, 8.4, .4], [13.5, 10.8, .1]], [1.1, 1.25, 1.45, 1.15, 1.3, 1.1, .65, .3, .07], null, null, 8);
    attach('upper-jaw', 'spine', 0, [[-8.4, 17.2, 0], [-10.3, 17.1, 0], [-12, 16.4, 0]], [1.1, 1.3, .8, .3], 8);
    attach('lower-jaw', 'spine', .02, [[-7.6, 14.2, 0], [-9.6, 13.4, 0], [-11.1, 14.2, 0]], [.7, .65, .38, .06]);
    for (const side of [-1, 1]) {
      attach('horn-' + side, 'upper-jaw', .14, [[-6.5, 18.8, side * .65], [-7.1, 20.4, side * .95], [-6.7, 22, side * .8]], [.55, .43, .25, .035]);
      attach('brow-' + side, 'upper-jaw', .38, [[-8.7, 17.7, side * .9], [-7.6, 17.5, side * 1.25], [-6.9, 16.2, side * .9]], [.35, .3, .23, .1]);
      attach('eye-knot-' + side, 'upper-jaw', .34, [[-8.35, 17.1, side * .8], [-8.35, 17.1, side * 1.38]], [.25, .27, .18], 8, .25);
      attach('muzzle-root-' + side, 'upper-jaw', .62, [[-11.1, 17.4, side * .55], [-11.9, 17.0, side * .65], [-12.4, 16.5, side * .25]], [.24, .19, .13, .035]);
      attach('whisker-' + side, 'lower-jaw', .5, [[-9.1, 12.9, side * 1.0], [-9.7, 11.7, side * 1.3], [-8.7, 11.3, side * 1.15]], [.18, .15, .1, .025]);
      for (let i = 0; i < 3; i++) {
        const t = .42 + i * .16, parent = byId.get('upper-jaw'), point = parent.points[Math.round((parent.points.length - 1) * t)];
        attach(`upper-fang-${side}-${i}`, 'upper-jaw', t, [[point[0] - .14, point[1] - .6, side * .40], [point[0] + .03, point[1] - .95, side * .32]], [.2, .13, .025], 5);
      }
    }
    for (let i = 0; i < 12; i++) {
      const t = .025 + i * .016, parent = spine.points[Math.round((spine.points.length - 1) * t)], side = i % 2 ? 1 : -1;
      const lift = 2.3 + (i % 3) * .55, sweep = 2.3 + (i % 4) * .45;
      attach('mane-' + i, 'spine', t, [[parent[0] + .8, parent[1] + .8, side * .65],
        [parent[0] + sweep, parent[1] + lift, side * 1.1], [parent[0] + sweep + .9, parent[1] + lift + .5, side * .9]], [.31, .24, .13, .025]);
    }
    for (let strand = 0; strand < 6; strand++) {
      const angle = strand / 6 * Math.PI * 2, controls = spine.points.filter((_, i) => i % 4 === 0 || i === spine.points.length - 1)
        .map((p, i) => {
          const station = Math.min(i * 4, spine.points.length - 1), twist = angle + station * .075;
          return [p[0], p[1] + Math.cos(twist) * spine.radii[station], p[2] + Math.sin(twist) * spine.radii[station]];
        });
      attach('body-strand-' + strand, 'spine', 0, controls.slice(1), [.3, .34, .25, .04], 5, strand % 2 ? .86 : 1.06);
    }
    for (let i = 0; i < 6; i++) {
      const t = .77 + i * .035, p = spine.points[Math.round((spine.points.length - 1) * t)];
      attach('tail-twig-' + i, 'spine', t, [[p[0] + .6, p[1] + 1, p[2] + (i % 2 ? .6 : -.6)],
        [p[0] + 1.2, p[1] + 2.2, p[2] + (i % 2 ? .9 : -.9)]], [.16, .12, .025], 5);
    }
    function foot(id, parentId, center) {
      const parent = byId.get(parentId), parentStation = parent.points.length - 1, vertexStart = positions.length / 3;
      const ring = Array.from({ length: 8 }, (_, i) => {
        const a = i * Math.PI / 4; return new THREE.Vector3(center[0] + Math.cos(a) * .9, 0, center[2] + Math.sin(a) * .72);
      });
      const top = ring.map(p => p.clone().setY(.55)), below = new THREE.Vector3(center[0], 0, center[2]), above = below.clone().setY(.55);
      for (let i = 0; i < 8; i++) {
        const j = (i + 1) % 8;
        triangle(below, ring[i], ring[j], .78); triangle(above, top[j], top[i]);
        triangle(ring[i], top[i], ring[j], .88); triangle(top[i], top[j], ring[j], .88);
      }
      const record = { id, parentId, parentStation, points: [parent.points[parentStation]], radii: [.8], vertexStart, vertexCount: positions.length / 3 - vertexStart };
      branches.push(record); byId.set(id, record);
      groundContacts.push({ id: id + '-ground', position: [center[0], 0, center[2]], normal: [0, 1, 0], radiusCm: .55 * size });
    }
    for (const side of [-1, 1]) for (const rear of [false, true]) {
      const id = `${rear ? 'rear' : 'fore'}-${side}`, x = rear ? 5.3 : -4.6, z = side * 2.35;
      attach(id + '-leg', 'spine', rear ? .59 : .24, rear ? [[7.2, 6.1, side * 1.2], [6.7, 3.0, side * 2.1], [x, .48, z]] :
        [[-5.8, 6.1, side * 1.2], [-5.8, 3.1, side * 2.0], [x, .48, z]], [1, .85, .6, .39], 8);
      foot(id + '-foot', id + '-leg', [x, .48, z]);
      for (let toe = -1; toe <= 1; toe++) {
        const tz = z + toe * .55;
        attach(id + '-claw-' + toe, id + '-leg', 1, [[x - .6, .3, tz], [x - 1.35, .35, tz + side * .18], [x - 1.2, .8, tz + side * .22]], [.23, .2, .13, .025], 5);
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setAttribute('color', new THREE.Float32BufferAttribute(colors, 3));
    geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    geometry.scale(factor, factor, factor); geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
    const mesh = new THREE.Mesh(geometry, material); mesh.name = 'grounded-rootwood-dragon';
    mesh.userData = { solid: true, hardscape: true, climbable: true, species: descriptor.id };
    mesh.castShadow = mesh.receiveShadow = true; group.add(mesh); group.updateMatrixWorld(true);
    for (const branch of branches) { branch.points = branch.points.map(scale); branch.radii = branch.radii.map(r => r * factor); }
    groundContacts.forEach(a => { a.position = scale(a.position); });
    const ray = new THREE.Raycaster(), mountAnchors = [];
    for (const [id, x, z] of [['shoulder-mount', -4, .1], ['back-mount', 4.5, -.25], ['tail-mount', 9.8, 0]]) {
      ray.set(new THREE.Vector3(x * factor, 27 * factor, z * factor), new THREE.Vector3(0, -1, 0));
      const hit = ray.intersectObject(mesh)[0];
      if (hit) mountAnchors.push({ id, position: hit.point.toArray(), normal: hit.face.normal.toArray(), radiusCm: .3 * size, surface: 'wood' });
    }
    const openings = [
      { id: 'body-arch', from: scale([0, 3.4, -6]), to: scale([0, 3.4, 6]), clearRadiusCm: 1.3 * size },
      { id: 'open-jaw', from: scale([-9.8, 15.15, -5]), to: scale([-9.8, 15.15, 5]), clearRadiusCm: .35 * size }
    ];
    const measured = geometry.boundingBox.getSize(new THREE.Vector3()).multiplyScalar(cmPerUnit);
    const dimensionsCm = { x: measured.x, y: measured.y, z: measured.z };
    group.userData = { species: descriptor.id, seed, cmPerUnit, size, dimensionBasis: 'authored', dimensionsCm, contacts: groundContacts, openings };
    const geometries = [geometry], materials = [material], maps = [map], anchors = new Map([...groundContacts, ...mountAnchors].map(a => [a.id, a]));
    let disposed = false;
    return {
      group, geometries, materials, maps, branches, groundContacts, mountAnchors, openings, dimensionsCm,
      worldAnchor(id) {
        const anchor = anchors.get(id); if (!anchor) throw new RangeError('Unknown dragon anchor: ' + id);
        group.updateWorldMatrix(true, false);
        return { ...anchor, position: vector(anchor.position).applyMatrix4(group.matrixWorld),
          normal: vector(anchor.normal).applyNormalMatrix(new THREE.Matrix3().getNormalMatrix(group.matrixWorld)) };
      },
      dispose() { if (disposed) return; disposed = true; [...geometries, ...materials, ...maps].forEach(r => r.dispose()); }
    };
  }
  return { descriptor, create };
});
