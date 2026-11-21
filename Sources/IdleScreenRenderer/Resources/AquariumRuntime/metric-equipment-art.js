(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumMetricEquipmentArt = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function point(value, name) {
    const result = Array.isArray(value) ? value.slice(0, 3) : [value?.x, value?.y, value?.z];
    if (result.length !== 3 || !result.every(Number.isFinite)) throw new RangeError(name + ' must contain three finite coordinates');
    return result;
  }

  function create(THREE, { tankHalf = 7, cmPerUnit = 36 / 8.4, backZ = -4.36, frontZ = 4.04,
    waterLevel = 8.05, rimY = 8.4, bedLevel = .7, stripPlug } = {}) {
    if (!Number.isFinite(cmPerUnit) || cmPerUnit <= 0) throw new RangeError('cmPerUnit must be positive and finite');
    const u = cm => cm / cmPerUnit, counterY = -.055;
    if (!Number.isFinite(tankHalf) || tankHalf < u(20)) throw new RangeError('tankHalf must allow at least 40 cm tank width');
    if (![backZ, frontZ].every(Number.isFinite) || frontZ - backZ < u(15)) throw new RangeError('backZ and frontZ must define at least 15 cm depth');
    if (![waterLevel, rimY].every(Number.isFinite) || waterLevel < u(15) || rimY - waterLevel < u(.2)) throw new RangeError('waterLevel must be below rimY and at least 15 cm high');
    if (!Number.isFinite(bedLevel) || bedLevel < 0 || bedLevel + u(6.7) >= waterLevel) throw new RangeError('bedLevel must leave room for the diffuser below water');
    const plugs = { filter: point(stripPlug?.filter, 'stripPlug.filter'), co2: point(stripPlug?.co2, 'stripPlug.co2') };
    if (new THREE.Vector3(...plugs.filter).distanceTo(new THREE.Vector3(...plugs.co2)) < u(.5)) throw new RangeError('stripPlug connections must be distinct');
    for (const p of Object.values(plugs)) if (p[1] < counterY + u(.3) || (Math.abs(p[0]) < tankHalf + u(.4) && p[2] > backZ - u(.4) && p[2] < frontZ)) throw new RangeError('stripPlug must be above the counter and outside the tank');
    const dryGroup = new THREE.Group(), wetGroup = new THREE.Group();
    dryGroup.name = 'premium-equipment-dry'; wetGroup.name = 'premium-equipment-wet';
    const materials = [], geometries = [], maps = [], batches = new Map(), parts = {}, partStack = [], mounts = [];
    function material(group, name, color, options = {}) {
      const { phong = false, visualWater = false, ...parameters } = options;
      const m = new THREE[phong ? 'MeshPhongMaterial' : 'MeshLambertMaterial']({ color, flatShading: true, ...parameters });
      m.name = name; materials.push(m); batches.set(m, { group, visualWater, positions: [], normals: [] }); return m;
    }
    const black = material(dryGroup, 'premium-dry-black', 0x202a2d);
    const metal = material(dryGroup, 'premium-dry-metal', 0xa1aaa7, { phong: true, shininess: 24, specular: 0x3d4140 });
    const body = material(dryGroup, 'premium-canister-body', 0x36444a);
    const blue = material(dryGroup, 'premium-dry-accent', 0x34798a);
    const dial = material(dryGroup, 'premium-dry-dials', 0xd1d5c8);
    const hose = material(dryGroup, 'premium-dry-hoses', 0x3b514c);
    const glassOptions = { phong: true, shininess: 36, specular: 0x3b5149, transparent: true, opacity: .30, depthWrite: false, side: THREE.DoubleSide };
    const dryGlass = material(dryGroup, 'premium-dry-glass', 0xb8d2ca, glassOptions);
    const dryWater = material(dryGroup, 'premium-counter-water', 0x629588, { transparent: true, opacity: .24, depthWrite: false, visualWater: true });
    const wetGlass = material(wetGroup, 'premium-wet-glass', 0xb8d2ca, glassOptions);
    const wetEdge = material(wetGroup, 'premium-wet-fittings', 0x819d93);
    const ceramic = material(wetGroup, 'premium-ceramic', 0xc5cabc);
    const gasline = material(wetGroup, 'premium-wet-gasline', 0x495f58);
    const wetWater = material(wetGroup, 'premium-pipe-water', 0x6caaa1, { transparent: true, opacity: .12, depthWrite: false, visualWater: true });

    function part(id, draw) {
      if (!parts[id]) parts[id] = { ranges: [], bounds: new THREE.Box3(), tubeRings: [] };
      partStack.push(id); draw(); partStack.pop();
    }
    function add(m, geometry, p = [0, 0, 0], rotation = new THREE.Quaternion(), scale = [1, 1, 1]) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...p), rotation, new THREE.Vector3(...scale)));
      const indices = geometry.index?.array, flat = indices ? geometry.toNonIndexed() : geometry, batch = batches.get(m);
      const start = batch.positions.length / 3, range = { material: m.name, start, count: flat.attributes.position.count }, first = [];
      if (indices) for (let i = 0; i < indices.length; i++) { if (first[indices[i]] === undefined) first[indices[i]] = start + i; }
      else for (let i = 0; i < range.count; i++) first[i] = start + i;
      batch.positions.push(...flat.attributes.position.array); batch.normals.push(...flat.attributes.normal.array);
      flat.computeBoundingBox();
      for (const id of partStack) { parts[id].ranges.push(range); parts[id].bounds.union(flat.boundingBox); }
      if (flat !== geometry) flat.dispose(); geometry.dispose(); return { range, first };
    }
    function box(m, w, h, d, p, rotation) { return add(m, new THREE.BoxGeometry(u(w), u(h), u(d)), p, rotation); }
    function cylinder(m, a, b, radiusCm, endRadiusCm = radiusCm, sides = 12, open = false) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), axis = end.clone().sub(start);
      const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
      return add(m, new THREE.CylinderGeometry(u(endRadiusCm), u(radiusCm), axis.length(), sides, 1, open), start.add(end).multiplyScalar(.5).toArray(), rotation);
    }
    function ring(m, center, radiusCm, axis = [0, 1, 0], thicknessCm = .08) {
      add(m, new THREE.TorusGeometry(u(radiusCm), u(thicknessCm), 4, 12), center,
        new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 0, 1), new THREE.Vector3(...axis).normalize()));
    }
    function marker(group, name, p) { const object = new THREE.Object3D(); object.name = name; object.position.set(...p); group.add(object); return object; }
    function pipe(m, points, outerCm, innerCm = 0, sides = 8) {
      const positions = [], normals = [], indices = [], frames = []; let normal;
      for (let i = 0; i < points.length; i++) {
        const center = new THREE.Vector3(...points[i]), tangent = new THREE.Vector3(...points[Math.min(points.length - 1, i + 1)])
          .sub(new THREE.Vector3(...points[Math.max(0, i - 1)])).normalize();
        if (normal) normal.addScaledVector(tangent, -normal.dot(tangent));
        if (!normal || normal.lengthSq() < 1e-6) normal = new THREE.Vector3(Math.abs(tangent.y) < .9 ? 0 : 1, Math.abs(tangent.y) < .9 ? 1 : 0, 0).cross(tangent);
        normal.normalize(); const binormal = new THREE.Vector3().crossVectors(tangent, normal).normalize();
        const frame = { center: points[i].slice(), outerVertices: [], innerVertices: [] };
        for (let shell = 0; shell < (innerCm ? 2 : 1); shell++) for (let side = 0; side < sides; side++) {
          const angle = side * Math.PI * 2 / sides, radial = normal.clone().multiplyScalar(Math.cos(angle)).addScaledVector(binormal, Math.sin(angle));
          const index = positions.length / 3; frame[shell ? 'innerVertices' : 'outerVertices'].push(index);
          positions.push(...center.clone().addScaledVector(radial, u(shell ? innerCm : outerCm) / 2).toArray());
          normals.push(...radial.multiplyScalar(shell ? -1 : 1).toArray());
        }
        frames.push(frame);
      }
      for (let i = 0; i < frames.length - 1; i++) for (const shell of innerCm ? ['outerVertices', 'innerVertices'] : ['outerVertices']) for (let side = 0; side < sides; side++) {
        const a = frames[i][shell][side], b = frames[i][shell][(side + 1) % sides], c = frames[i + 1][shell][side], d = frames[i + 1][shell][(side + 1) % sides];
        indices.push(...(shell === 'outerVertices' ? [a, b, c, b, d, c] : [a, c, b, b, c, d]));
      }
      if (innerCm) for (const end of [0, frames.length - 1]) for (let side = 0; side < sides; side++) {
        const f = frames[end], a = f.outerVertices[side], b = f.outerVertices[(side + 1) % sides], c = f.innerVertices[side], d = f.innerVertices[(side + 1) % sides];
        indices.push(...(end ? [a, c, b, b, c, d] : [a, b, c, b, d, c]));
      }
      const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3)); geometry.setIndex(indices);
      const added = add(m, geometry);
      for (const id of partStack) for (const frame of frames) parts[id].tubeRings.push({ material: m.name, center: frame.center,
        outerVertices: frame.outerVertices.map(i => added.first[i]), innerVertices: frame.innerVertices.map(i => added.first[i]) });
    }
    function smooth(points, radiusCm = 2) {
      const output = [points[0]];
      for (let i = 1; i < points.length - 1; i++) {
        const a = new THREE.Vector3(...points[i - 1]), b = new THREE.Vector3(...points[i]), c = new THREE.Vector3(...points[i + 1]);
        const before = b.clone().lerp(a, Math.min(.28, u(radiusCm) / a.distanceTo(b)));
        const after = b.clone().lerp(c, Math.min(.28, u(radiusCm) / c.distanceTo(b))); output.push(before.toArray());
        for (let step = 1; step <= 3; step++) { const t = step / 3; output.push(before.clone().multiplyScalar((1 - t) ** 2).addScaledVector(b, 2 * t * (1 - t)).addScaledVector(after, t * t).toArray()); }
      }
      output.push(points.at(-1)); return output;
    }
    function chamferBox(m, w, h, d, p, corner = .8) {
      const shape = new THREE.Shape(), outline = [[-w / 2 + corner, -d / 2], [w / 2 - corner, -d / 2], [w / 2, -d / 2 + corner],
        [w / 2, d / 2 - corner], [w / 2 - corner, d / 2], [-w / 2 + corner, d / 2], [-w / 2, d / 2 - corner], [-w / 2, -d / 2 + corner]];
      outline.forEach(([x, y], i) => i ? shape.lineTo(u(x), u(y)) : shape.moveTo(u(x), u(y))); shape.closePath();
      add(m, new THREE.ExtrudeGeometry(shape, { depth: u(h), bevelEnabled: false, steps: 1 }), p,
        new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(1, 0, 0), -Math.PI / 2));
    }

    const fx = tankHalf + u(11.1), fz = backZ + u(14), cx = -tankHalf - u(8.5), cz = frontZ - u(8);
    const F = (x, y, z) => [fx + u(x), counterY + u(y), fz + u(z)];
    const C = (x, y, z) => [cx + u(x), counterY + u(y), cz + u(z)];
    const ports = { intake: F(-5.2, 26, -3.5), output: F(5.2, 26, -3.5) }, filterPower = F(6.8, 24, -6.1);
    part('canister-housing', () => {
      chamferBox(black, 17.6, .7, 11.6, F(0, 0, 0));
      chamferBox(body, 17.4, 21.1, 11.4, F(0, .7, 0));
      chamferBox(black, 18.2, 2.6, 12.2, F(0, 21.8, 0));
      for (const x of [-8.75, 8.75]) box(blue, .7, 4.6, 2.5, F(x, 21.2, 0));
      box(black, 3.1, 4.4, .45, F(0, 21.6, 5.875)); box(dial, 1.8, .5, .06, F(0, 20.9, 6.0));
      for (const p of Object.values(ports)) {
        cylinder(black, [p[0], counterY + u(24.4), p[2]], p, 1.05, .8);
        ring(blue, [p[0], counterY + u(24.9), p[2]], 1.0, [0, 1, 0], .08);
      }
    });
    marker(dryGroup, 'premium-canister', F(0, 0, 0));
    for (const [name, p] of Object.entries(ports)) marker(dryGroup, 'filter-' + name + '-port', p);
    marker(dryGroup, 'filter-power-exit', filterPower);

    part('cylinder-chart-envelope', () => {
      const profile = [[0, 0], [5.1, 0], [5.55, .7], [5.55, 21.7], [5.3, 22.8], [4.5, 24], [2.4, 25.2], [1.2, 25.7], [1.2, 26], [0, 26]];
      add(metal, new THREE.LatheGeometry(profile.map(([r, y]) => new THREE.Vector2(u(r), u(y))), 12), C(0, 0, 0));
      cylinder(metal, C(0, 25.7, 0), C(0, 27.5, 0), .9);
      cylinder(black, C(0, 27.5, 0), C(0, 28, 0), 1.8);
      cylinder(metal, C(0, 26.8, 0), C(0, 26.8, 2.8), .8);
    });
    marker(dryGroup, 'co2-cylinder', C(0, 0, 0));
    const gasStart = C(5.1, 36.8, 3.5), solenoidPower = C(3.5, 25.4, 2.5);
    part('regulator-inferred', () => {
      cylinder(metal, C(0, 26.8, 2.8), C(0, 26.8, 4.8), 1.8);
      cylinder(black, C(0, 26.8, 4.8), C(0, 26.8, 5.6), 1.45);
      for (const [offset, name, angle] of [[-2.4, 'co2-gauge-high', 2.15], [2.4, 'co2-gauge-working', .95]]) {
        cylinder(metal, C(0, 27.3, 3.6), C(offset, 29.2, 4.9), .35);
        cylinder(metal, C(offset, 30.2, 4.9), C(offset, 30.2, 6.1), 2);
        add(dial, new THREE.CircleGeometry(u(1.76), 12), C(offset, 30.2, 6.11));
        marker(dryGroup, name, C(offset, 30.2, 6.12));
        for (let i = 0; i < 9; i++) {
          const a = -.35 + i * Math.PI * 1.7 / 8;
          box(black, .10, .28, .035, C(offset + Math.cos(a) * 1.4, 30.2 + Math.sin(a) * 1.4, 6.15),
            new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), a - Math.PI / 2));
        }
        cylinder(black, C(offset, 30.2, 6.18), C(offset + Math.cos(angle) * 1.15, 30.2 + Math.sin(angle) * 1.15, 6.18), .055, .035, 6);
      }
      cylinder(metal, C(0, 26.8, 3.5), C(5.1, 26.8, 3.5), .55);
      box(black, 2.5, 2.8, 2.4, C(3.5, 26.8, 3.5)); marker(dryGroup, 'co2-solenoid', C(3.5, 26.8, 3.5));
      cylinder(metal, C(5.1, 26.8, 3.5), C(5.1, 30, 3.5), .45);
      cylinder(black, C(5.1, 28.4, 3.5), C(6.1, 28.4, 3.5), .55);
      cylinder(black, C(5.1, 29.5, 3.5), C(5.1, 30.2, 3.5), .85);
      cylinder(dryGlass, C(5.1, 30.1, 3.5), C(5.1, 35.6, 3.5), .75, .75, 12, true);
      cylinder(dryWater, C(5.1, 30.2, 3.5), C(5.1, 34.1, 3.5), .56);
      cylinder(metal, C(5.1, 30.2, 3.5), C(5.1, 32.5, 3.5), .10);
      cylinder(black, C(5.1, 35.5, 3.5), C(5.1, 36.3, 3.5), .85);
      cylinder(metal, C(5.1, 36.3, 3.5), gasStart, .3);
      marker(dryGroup, 'co2-bubble-counter', C(5.1, 32.8, 3.5));
    });
    marker(dryGroup, 'co2-tube-outlet', gasStart); marker(dryGroup, 'co2-power-exit', solenoidPower);
    part('co2-power-adapter', () => box(black, 3.4, 2, 5.4, [cx, counterY + u(1), backZ + u(3)]));

    const intakeX = -tankHalf + u(4), returnX = -tankHalf + u(10), gasX = -tankHalf + u(16);
    const innerZ = backZ + u(2.2), outerZ = backZ - u(2), rearInner = backZ + u(.6);
    function rimBend(x, inner = innerZ, outer = outerZ, liftCm = 1.1) {
      const radius = (inner - outer) / 2, middle = (inner + outer) / 2, y = rimY + u(liftCm);
      return Array.from({ length: 13 }, (_, i) => { const angle = i * Math.PI / 12; return [x, y + Math.sin(angle) * radius, middle - Math.cos(angle) * radius]; });
    }
    function filterHose(port, x, laneCm, arch) {
      return smooth([port, [port[0], port[1] + u(1.5), port[2]], [port[0], port[1] + u(.5), backZ - u(2)],
        [port[0], counterY + u(2.4), backZ - u(laneCm)], [port[0] - u(1), counterY + u(1), backZ - u(laneCm)],
        [x + u(2), counterY + u(1), backZ - u(laneCm)], [x, counterY + u(3), backZ - u(laneCm)],
        [x, rimY - u(5), outerZ], arch[0]], 2.2);
    }
    const intakeArch = rimBend(intakeX), returnArch = rimBend(returnX);
    const gasArch = rimBend(gasX, innerZ, backZ - u(1.3), .55);
    const intakeEnd = [intakeX, u(6), innerZ];
    const returnDirection = new THREE.Vector3(1, 0, .22).normalize(), returnStem = new THREE.Vector3(returnX + u(2.2), waterLevel - u(1.9), innerZ + u(1));
    const returnPoint = returnStem.clone().addScaledVector(returnDirection, u(2.1));
    const diffuserBase = [gasX - u(.65), Math.max(u(4.2), bedLevel + u(.8)), innerZ], D = (x, y, z = 0) => [diffuserBase[0] + u(x), diffuserBase[1] + u(y), diffuserBase[2] + u(z)];
    const diffuserInlet = D(.65, 5.9), diffuserPoint = new THREE.Vector3(...D(-.35, 1.2));
    const routes = {};
    for (const [name, x, port, arch, lane] of [['filterIntake', intakeX, ports.intake, intakeArch, 5.5], ['filterReturn', returnX, ports.output, returnArch, 7.5]]) {
      const flexible = filterHose(port, x, lane, arch), dryPipe = [...arch, [x, waterLevel, innerZ]];
      const wet = name === 'filterIntake' ? [dryPipe.at(-1), [x, u(12), innerZ], intakeEnd]
        : [dryPipe.at(-1), [x, waterLevel - u(.6), innerZ], [x + u(.7), waterLevel - u(1.5), innerZ + u(.3)], returnStem.toArray(), returnPoint.toArray()];
      routes[name] = { outerDiameterCm: 1.6, innerDiameterCm: 1.2, glassOuterDiameterCm: 1.3, radius: u(.8), hosePart: name + '-hose',
        startConnector: name === 'filterIntake' ? 'filter-intake-port' : 'filter-output-port', endConnector: name === 'filterIntake' ? 'intake-strainer' : 'lily-return-mouth',
        dry: [...flexible, ...dryPipe.slice(1)], wet };
      part(name + '-hose', () => pipe(hose, flexible, 1.6, 1.2));
      part(name + '-air-pipe', () => pipe(dryGlass, dryPipe, 1.3, 1.1));
      part(name + '-wet-pipe', () => pipe(wetGlass, name === 'filterReturn' ? wet.slice(0, -1) : wet, 1.3, 1.1));
    }
    const cylinderLaneX = cx - u(7);
    const gasFlexible = smooth([gasStart, [gasStart[0], gasStart[1] - u(.5), gasStart[2] + u(1)],
      [cylinderLaneX, counterY + u(34), cz + u(6.8)], [cylinderLaneX, counterY + u(20), cz + u(6.8)],
      [cylinderLaneX, counterY + u(1), backZ - u(8.7)], [gasX, counterY + u(1), backZ - u(8.7)],
      [gasX, rimY - u(5), backZ - u(1.3)], gasArch[0]], 1.5);
    const gasDry = [...gasFlexible, ...gasArch.slice(1), [gasX, waterLevel, innerZ]], gasWet = [[gasX, waterLevel, innerZ], [gasX, u(13), innerZ], diffuserInlet];
    routes.co2 = { outerDiameterCm: .6, innerDiameterCm: .4, radius: u(.3), hosePart: 'co2-hose',
      startConnector: 'co2-tube-outlet', endConnector: 'diffuser-inlet', dry: gasDry, wet: gasWet };
    part('co2-hose', () => pipe(hose, gasDry, .6, .4)); part('co2-wet-hose', () => pipe(gasline, gasWet, .6, .4));
    marker(wetGroup, 'intake-strainer', intakeEnd); marker(wetGroup, 'lily-return-mouth', returnPoint.toArray());
    marker(wetGroup, 'diffuser-inlet', diffuserInlet); marker(wetGroup, 'diffuser-mist-origin', diffuserPoint.toArray());

    part('intake-open-slots', () => {
      for (let i = 0; i < 8; i++) ring(wetEdge, [intakeX, u(6.15 + i * .35), innerZ], .64, [0, 1, 0], .045);
      cylinder(wetWater, [intakeX, u(6.05), innerZ], [intakeX, waterLevel - u(.2), innerZ], .48, .48, 8);
    });
    part('lily-bell', () => {
      cylinder(wetGlass, returnStem.toArray(), returnPoint.toArray(), .65, 1.6, 12, true);
      ring(wetEdge, returnPoint.toArray(), 1.6, returnDirection.toArray(), .06);
    });
    part('small-diffuser', () => {
      cylinder(wetGlass, D(-.35, 0), D(-.35, 1.08), .55, .55, 12, true);
      const stem = [D(-.35, .45), D(.2, .45), D(.55, .65), D(.65, 1), D(.65, 5.9)];
      pipe(wetGlass, stem, .4, .25);
      cylinder(wetGlass, D(.65, 5.4), D(.65, 5.9), .3, .3, 12, true);
      part('ceramic-disc', () => cylinder(ceramic, D(-.35, 1.03), D(-.35, 1.2), .6, .6, 12));
      cylinder(wetWater, D(-.35, .12), D(-.35, .95), .43);
    });

    function suction(id, x, y, z, radiusCm) {
      const wallPoint = [x, y, rearInner], pipePoint = [x, y, z];
      part(id, () => {
        cylinder(wetGlass, wallPoint, [x, y, rearInner + u(.4)], .9, .4, 12);
        cylinder(wetGlass, [x, y, rearInner + u(.3)], pipePoint, .12, .12, 6);
        ring(wetGlass, pipePoint, radiusCm + .07, [0, 1, 0], .10);
      });
      mounts.push({ kind: 'suction', partId: id, wallPoint, pipePoint, status: 'authored-contact', cupDiameterCm: 1.8 });
    }
    suction('intake-low-cup', intakeX, u(12), innerZ, .65); suction('intake-high-cup', intakeX, waterLevel - u(5), innerZ, .65);
    suction('return-cup', returnX, waterLevel - u(.8), innerZ, .65);
    suction('diffuser-low-cup', gasX, diffuserBase[1] + u(1.6), innerZ, .2);
    suction('diffuser-high-cup', gasX, diffuserBase[1] + u(4.6), innerZ, .2);
    function rimMount(id, x, radiusCm) {
      const contact = [x, rimY, backZ + u(.3)], pipePoint = [x, rimY - u(.55), innerZ];
      part(id, () => {
        box(dryGlass, 1.4, .2, .8, [x, rimY + u(.1), backZ + u(.3)]);
        for (const z of [backZ - u(.2), backZ + u(.8)]) box(dryGlass, 1.4, .9, .2, [x, rimY - u(.25), z]);
        box(dryGlass, .35, .25, 1.5, [x, rimY - u(.55), backZ + u(1.45)]);
        ring(dryGlass, pipePoint, radiusCm + .06, [0, 1, 0], .09);
      });
      mounts.push({ kind: 'rim', partId: id, contact, pipePoint, status: 'authored-contact', clipGapCm: .8 });
    }
    rimMount('intake-rim-mount', intakeX, .65); rimMount('return-rim-mount', returnX, .65); rimMount('co2-rim-mount', gasX, .3);

    for (const [name, origin, destination, laneCm] of [['filterPower', filterPower, plugs.filter, 9.6], ['co2Power', solenoidPower, plugs.co2, 8.8]]) {
      const lane = backZ - u(laneCm), lowY = counterY + u(.32), x = name === 'filterPower' ? origin[0] : cylinderLaneX;
      const descent = name === 'filterPower' ? [[x, origin[1] - u(1), origin[2] - u(.8)]] :
        [[origin[0], origin[1] - u(1), cz + u(6.7)], [x, counterY + u(16), cz + u(6.7)]];
      const approach = destination[2] < backZ ? [[tankHalf - u(10), lowY, lane], [tankHalf - u(10), lowY, backZ - u(.7)],
        [destination[0] - u(.6), lowY, backZ - u(.7)]] : [[destination[0], lowY, lane]];
      const dry = smooth([origin, ...descent, [x, counterY + u(.8), backZ + u(5.7)],
        [x, lowY, lane], ...approach, [destination[0], destination[1], destination[2] + u(1)], destination], .6);
      routes[name] = { radius: u(.25), outerDiameterCm: .5, startConnector: name === 'filterPower' ? 'filter-power-exit' : 'co2-power-exit',
        endConnector: name === 'filterPower' ? 'filter-strip-connection' : 'co2-strip-connection', dry };
      part(name, () => pipe(black, dry, .5, 0, 6)); marker(dryGroup, routes[name].endConnector, destination);
    }

    for (const [m, batch] of batches) {
      const geometry = new THREE.BufferGeometry(); geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(batch.normals, 3)); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const mesh = new THREE.Mesh(geometry, m); mesh.name = m.name;
      mesh.userData = { visualWater: batch.visualWater, solid: batch.group === wetGroup && !batch.visualWater };
      mesh.castShadow = !m.transparent; mesh.receiveShadow = !batch.visualWater; batch.group.add(mesh); geometries.push(geometry);
    }
    const dryBounds = new THREE.Box3().setFromObject(dryGroup);
    for (const p of Object.values(parts)) p.bounds = { min: p.bounds.min.toArray(), max: p.bounds.max.toArray() };
    for (const [name, id] of [['premium-canister', 'canister-housing'], ['co2-cylinder', 'cylinder-chart-envelope']]) dryGroup.getObjectByName(name).userData.bounds = parts[id].bounds;
    const dimensions = {
      canister: { model: 'UNS DELTA 60', status: 'manufacturer', widthCm: 18.2, depthCm: 12.2, heightCm: 26,
        source: 'https://ultumnaturesystems.com/delta-aquarium-canister-filter/' },
      cylinder: { model: 'Cyl-Tec 2.5 lb aluminum CO2', status: 'manufacturer-chart-height-basis-unresolved', diameterCm: 11.1, chartHeightCm: 28,
        source: 'https://cyl-tec.com/wp-content/uploads/2024/09/Cylinder_size_charts_-_Aluminum_CO2.pdf' },
      regulator: { model: 'CO2Art PRO-SE-inspired assembly', status: 'inferred', source: 'https://www.co2art.us/products/pro-se-series-aquarium-co2-dual-stage-regulator-with-integrated-solenoid',
        note: 'Connection architecture is sourced; component dimensions and installed height are authored, not manufacturer dimensions.' },
      diffuser: { model: 'UNS small ceramic diffuser', status: 'manufacturer', widthCm: 1.9, heightCm: 5.9, discDiameterCm: 1.2, source: 'https://ultumnaturesystems.com/co2/' },
      filterTubing: { status: 'manufacturer', innerDiameterMm: 12, outerDiameterMm: 16 },
      gasTubing: { status: 'manufacturer-standard', innerDiameterMm: 4, outerDiameterMm: 6, source: 'https://ultumnaturesystems.com/co2/' },
      installedCo2Verified: false
    };
    dryGroup.userData = { cmPerUnit, routes, parts, dimensions, mounts,
      authored: { glassThicknessCm: .6, rimClearanceCm: 1.1, clipGapCm: .8, filterSideGapCm: 2, cylinderSideGapCm: 2.95,
        glassPipeOuterDiameterCm: 1.3, glassPipeInnerDiameterCm: 1.1, installedCo2HeightCm: 36.8, counterY },
      requiredCounterBounds: { min: [dryBounds.min.x, counterY, dryBounds.min.z], max: [dryBounds.max.x, counterY, dryBounds.max.z] },
      returnDirection: returnDirection.toArray()
    };
    wetGroup.userData = { cmPerUnit, routes, parts, mounts, returnDirection: returnDirection.toArray() };
    return { dryGroup, wetGroup, geometries, materials, maps, returnPoint, diffuserPoint, returnDirection };
  }
  return { create };
});
