(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumPremiumEquipmentArt = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function point(value, name) {
    const result = Array.isArray(value) ? value.slice(0, 3) : [value?.x, value?.y, value?.z];
    if (result.length !== 3 || !result.every(Number.isFinite)) throw new RangeError(name + ' must contain three finite coordinates');
    return result;
  }

  function tube(THREE, points, radius, sides = 8, capped = true) {
    const positions = [], normals = [], indices = [];
    let normal;
    for (let i = 0; i < points.length; i++) {
      const center = new THREE.Vector3(...points[i]);
      const tangent = new THREE.Vector3(...points[Math.min(points.length - 1, i + 1)])
        .sub(new THREE.Vector3(...points[Math.max(0, i - 1)])).normalize();
      if (normal) normal.addScaledVector(tangent, -normal.dot(tangent));
      if (!normal || normal.lengthSq() < 1e-6) normal = new THREE.Vector3(Math.abs(tangent.y) < .9 ? 0 : 1, Math.abs(tangent.y) < .9 ? 1 : 0, 0).cross(tangent);
      normal.normalize();
      const binormal = new THREE.Vector3().crossVectors(tangent, normal).normalize();
      for (let side = 0; side < sides; side++) {
        const angle = side * Math.PI * 2 / sides;
        const radial = normal.clone().multiplyScalar(Math.cos(angle)).addScaledVector(binormal, Math.sin(angle));
        positions.push(...center.clone().addScaledVector(radial, radius).toArray()); normals.push(...radial.toArray());
        if (i < points.length - 1) {
          const a = i * sides + side, b = i * sides + (side + 1) % sides;
          indices.push(a, b, a + sides, b, b + sides, a + sides);
        }
      }
    }
    if (capped) for (const end of [0, points.length - 1]) {
      const center = positions.length / 3;
      const axis = new THREE.Vector3(...points[end]).sub(new THREE.Vector3(...points[end ? end - 1 : 1])).normalize();
      positions.push(...points[end]); normals.push(...axis.toArray());
      for (let side = 0; side < sides; side++) {
        const a = end * sides + side, b = end * sides + (side + 1) % sides;
        indices.push(center, end ? a : b, end ? b : a);
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
    geometry.setIndex(indices);
    return geometry;
  }

  function create(THREE, { tankHalf, waterLevel = 8.05, rimY = 8.4, stripPlug } = {}) {
    if (!Number.isFinite(tankHalf) || tankHalf < 3) throw new RangeError('tankHalf must be finite and at least 3');
    if (!Number.isFinite(waterLevel) || !Number.isFinite(rimY) || waterLevel < 3 || rimY < waterLevel + .12) throw new RangeError('waterLevel must leave at least .12 below rimY');
    const plugs = { filter: point(stripPlug?.filter, 'stripPlug.filter'), co2: point(stripPlug?.co2, 'stripPlug.co2') };
    if (new THREE.Vector3(...plugs.filter).distanceTo(new THREE.Vector3(...plugs.co2)) < .08) throw new RangeError('stripPlug needs two distinct connections');
    for (const p of Object.values(plugs)) if (p[1] < .05 || p[2] < -4.5 || (Math.abs(p[0]) <= tankHalf + .1 && p[2] >= -2.8)) throw new RangeError('stripPlug must be outside the tank and above the counter');
    const dryGroup = new THREE.Group(), wetGroup = new THREE.Group();
    dryGroup.name = 'premium-equipment-dry'; wetGroup.name = 'premium-equipment-wet';
    const materials = [], batches = new Map();
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

    function add(m, geometry, position = [0, 0, 0], rotation = new THREE.Quaternion(), scale = [1, 1, 1]) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...position), rotation, new THREE.Vector3(...scale)));
      const flat = geometry.index ? geometry.toNonIndexed() : geometry, batch = batches.get(m);
      batch.positions.push(...flat.attributes.position.array); batch.normals.push(...flat.attributes.normal.array);
      if (flat !== geometry) flat.dispose(); geometry.dispose();
    }
    function box(m, w, h, d, p, rotation) { add(m, new THREE.BoxGeometry(w, h, d), p, rotation); }
    function cylinder(m, a, b, radius, endRadius = radius, sides = 10, open = false) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), axis = end.clone().sub(start);
      const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
      add(m, new THREE.CylinderGeometry(endRadius, radius, axis.length(), sides, 1, open), start.add(end).multiplyScalar(.5).toArray(), rotation);
    }
    function marker(group, name, p, bounds) {
      const object = new THREE.Object3D(); object.name = name; object.position.set(...p); if (bounds) object.userData.bounds = bounds; group.add(object); return object;
    }
    function ring(m, center, radius, axis = [0, 1, 0], thickness = .012) {
      add(m, new THREE.TorusGeometry(radius, thickness, 4, 12), center,
        new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 0, 1), new THREE.Vector3(...axis).normalize()));
    }

    const cx = -tankHalf - 1.1, fx = tankHalf * 1.255;
    marker(dryGroup, 'co2-cylinder', [cx, 0, 2.7], { min: [cx - .47, -.055, 2.23], max: [cx + .56, 4.43, 3.18] });
    cylinder(black, [cx, -.055, 2.7], [cx, .085, 2.7], .47, .46, 12);
    const profile = [[0, .06], [.39, .06], [.45, .16], [.45, 3.03], [.42, 3.20], [.32, 3.38], [.16, 3.49], [.13, 3.61], [0, 3.61]];
    add(metal, new THREE.LatheGeometry(profile.map(p => new THREE.Vector2(...p)), 12), [cx, 0, 2.7]);
    cylinder(metal, [cx, 3.55, 2.7], [cx, 3.76, 2.7], .12, .12, 8);
    cylinder(black, [cx, 3.73, 2.7], [cx, 3.80, 2.7], .20, .20, 10);
    cylinder(metal, [cx, 3.62, 2.7], [cx, 3.62, 2.99], .13, .13, 8);
    cylinder(metal, [cx, 3.62, 2.91], [cx, 3.62, 3.10], .20, .18, 10);
    cylinder(black, [cx, 3.62, 3.08], [cx, 3.62, 3.18], .145, .145, 12);
    for (const [offset, name, needleAngle] of [[-.23, 'co2-gauge-high', 2.15], [.23, 'co2-gauge-working', .95]]) {
      const x = cx + offset, y = 3.98;
      marker(dryGroup, name, [x, y, 3.14]);
      cylinder(metal, [cx, 3.72, 2.99], [x, y - .15, 3.00], .047, .047, 8);
      cylinder(metal, [x, y, 2.98], [x, y, 3.12], .205, .205, 12);
      add(dial, new THREE.CircleGeometry(.179, 12), [x, y, 3.125]);
      for (let i = 0; i < 9; i++) {
        const a = -.35 + i * Math.PI * 1.7 / 8;
        box(black, .012, .032, .005, [x + Math.cos(a) * .145, y + Math.sin(a) * .145, 3.13],
          new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), a - Math.PI / 2));
      }
      cylinder(black, [x, y, 3.136], [x + Math.cos(needleAngle) * .12, y + Math.sin(needleAngle) * .12, 3.136], .008, .005, 5);
    }
    cylinder(metal, [cx, 3.62, 2.91], [cx + .38, 3.62, 2.91], .07, .07, 8);
    box(black, .26, .28, .24, [cx + .26, 3.49, 2.91]); marker(dryGroup, 'co2-solenoid', [cx + .26, 3.49, 2.91]);
    cylinder(metal, [cx + .38, 3.62, 2.91], [cx + .38, 3.76, 2.70], .06, .06, 8);
    cylinder(black, [cx + .40, 3.66, 2.91], [cx + .55, 3.66, 2.91], .07, .07, 8);
    const gasStart = [cx + .38, 4.43, 2.70], solenoidPower = [cx + .26, 3.39, 2.72];
    cylinder(black, [cx + .38, 3.73, 2.70], [cx + .38, 3.84, 2.70], .105, .10, 10);
    cylinder(dryGlass, [cx + .38, 3.82, 2.70], [cx + .38, 4.31, 2.70], .09, .09, 10, true);
    cylinder(dryWater, [cx + .38, 3.84, 2.70], [cx + .38, 4.17, 2.70], .067, .067, 10);
    cylinder(metal, [cx + .38, 3.83, 2.70], [cx + .38, 4.07, 2.70], .013, .013, 6);
    cylinder(black, [cx + .38, 4.29, 2.70], [cx + .38, 4.39, 2.70], .10, .10, 10);
    cylinder(metal, [cx + .38, 4.38, 2.70], gasStart, .044, .034, 8);
    cylinder(black, [cx + .26, 3.44, 2.83], solenoidPower, .042, .030, 6);
    marker(dryGroup, 'co2-bubble-counter', [cx + .38, 4.06, 2.70]);
    marker(dryGroup, 'co2-tube-outlet', gasStart); marker(dryGroup, 'co2-power-exit', solenoidPower);

    marker(dryGroup, 'premium-canister', [fx, 0, -.5], { min: [fx - .60, -.055, -1.30], max: [fx + .60, 3.18, .23] });
    box(black, 1.12, .09, 1.08, [fx, -.01, -.5]);
    box(body, 1.08, 2.55, 1.03, [fx, 1.31, -.5]);
    for (const x of [-.49, .49]) box(body, .12, 2.30, .92, [fx + x, 1.31, -.5]);
    box(black, 1.20, .32, 1.14, [fx, 2.70, -.5]);
    for (const x of [-.57, .57]) box(blue, .06, .38, .24, [fx + x, 2.43, -.25]);
    cylinder(blue, [fx - .26, .32, .11], [fx - .26, 2.77, .11], .105, .105, 8);
    for (const y of [.45, 2.42]) box(black, .26, .10, .18, [fx - .26, y, .07]);
    cylinder(blue, [fx - .26, 2.78, -.18], [fx - .26, 2.98, -.18], .12, .12, 8);
    box(black, .50, .09, .12, [fx, 2.99, -.30]);
    for (const x of [-.20, .20]) box(black, .08, .16, .12, [fx + x, 2.90, -.30]);
    box(dial, .30, .10, .012, [fx + .12, 1.62, .024]);
    box(black, .68, .22, .38, [fx, 2.95, -.90]);
    const filterPower = [fx + .35, .32, -1.20];
    cylinder(black, [fx + .35, .32, -.99], filterPower, .05, .032, 8); marker(dryGroup, 'filter-power-exit', filterPower);
    const ports = { intake: [fx - .23, 3.03, -1.30], output: [fx + .23, 3.03, -1.30] };
    for (const [name, p] of Object.entries(ports)) {
      cylinder(black, [p[0], p[1], -.96], p, .145, .125, 8);
      box(blue, .15, .11, .16, [p[0], 3.10, -1.03]);
      marker(dryGroup, 'filter-' + name + '-port', p);
    }

    const intakeX = -tankHalf + .60, returnX = -tankHalf + 1.45, gasX = -tankHalf + 2.15;
    function bend(x, radius, baseHeight) {
      return Array.from({ length: 9 }, (_, i) => { const a = i * Math.PI / 8; return [x, baseHeight + Math.sin(a) * radius, -2.64 - Math.cos(a) * radius]; });
    }
    const intakeBend = bend(intakeX, .40, rimY + .18), returnBend = bend(returnX, .40, rimY + .18), gasBend = bend(gasX, .28, rimY + .10);
    function filterDry(port, x, z, arch) {
      return [port, [port[0], 3.03, -1.65], [port[0], 2.65, -2.6], [port[0], .35, z],
        [port[0] - .25, .075, z], [x + .28, .075, z], [x, .35, z], [x, 3.5, -3.20],
        [x, rimY - .25, -3.10], ...arch];
    }
    const intakeEnd = [intakeX, 1.15, -2.24];
    const returnStem = [returnX + .42, waterLevel - .38, -1.96], returnAxis = new THREE.Vector3(1, 0, .30).normalize();
    const returnPoint = new THREE.Vector3(...returnStem).addScaledVector(returnAxis, .36);
    const diffuserX = gasX - .34, diffuserInlet = [diffuserX, 1.32, -1.99], diffuserPoint = new THREE.Vector3(diffuserX, 1.565, -1.78);
    const routes = {
      filterIntake: { radius: .115, startConnector: 'filter-intake-port', endConnector: 'intake-strainer',
        dry: filterDry(ports.intake, intakeX, -3.52, intakeBend), wet: [intakeBend.at(-1), [intakeX, 6.4, -2.24], intakeEnd] },
      filterReturn: { radius: .115, startConnector: 'filter-output-port', endConnector: 'lily-return-mouth',
        dry: filterDry(ports.output, returnX, -3.85, returnBend), wet: [returnBend.at(-1), [returnX, waterLevel + .02, -2.24],
          [returnX + .05, waterLevel - .25, -2.20], [returnX + .24, waterLevel - .38, -2.08], returnStem, returnPoint.toArray()] },
      co2: { radius: .027, startConnector: 'co2-tube-outlet', endConnector: 'diffuser-inlet',
        dry: [gasStart, [cx + .38, 4.43, 2.45], [cx + .38, 3.60, 1.50], [cx + .32, 1.40, -.7], [cx + .25, .12, -3.9],
          [gasX, .08, -4.12], [gasX, 5, -3.2], [gasX, rimY - .2, -2.98], ...gasBend],
        wet: [gasBend.at(-1), [gasX, 7.3, -2.30], [gasX, 3, -2.24], [gasX - .10, 1.8, -2.15], [gasX - .25, 1.37, -2.10], diffuserInlet] },
    };
    for (const [name, origin, destination, lane] of [['filterPower', filterPower, plugs.filter, -4.27], ['co2Power', solenoidPower, plugs.co2, -4.12]]) {
      const x = origin[0], destinationX = destination[0];
      routes[name] = { radius: .028, startConnector: name === 'filterPower' ? 'filter-power-exit' : 'co2-power-exit',
        endConnector: name === 'filterPower' ? 'filter-strip-connection' : 'co2-strip-connection',
        dry: [origin, [x, Math.min(origin[1], 1.4), origin[2] - .28], [x, .15, lane], [x, -.025, lane],
          [destinationX, -.025, lane], [destinationX, .20, lane], [destinationX, destination[1] * .65, lane],
          [destinationX, destination[1], destination[2] + .18], destination] };
      marker(dryGroup, routes[name].endConnector, destination);
      add(black, tube(THREE, routes[name].dry, .028, 6));
    }
    dryGroup.userData.routes = wetGroup.userData.routes = routes;
    for (const [name, arch] of [['filterIntake', intakeBend], ['filterReturn', returnBend]]) {
      const r = routes[name], hoseEnd = r.dry.length - arch.length;
      add(hose, tube(THREE, r.dry.slice(0, hoseEnd + 1), .115));
      add(dryGlass, tube(THREE, arch, .115, 8, false));
      add(wetGlass, tube(THREE, name === 'filterReturn' ? r.wet.slice(0, -1) : r.wet, .115, 8, false));
    }
    add(hose, tube(THREE, routes.co2.dry, .027, 6));
    add(gasline, tube(THREE, routes.co2.wet, .027, 6));
    marker(wetGroup, 'intake-strainer', intakeEnd); marker(wetGroup, 'lily-return-mouth', returnPoint.toArray());
    marker(wetGroup, 'diffuser-inlet', diffuserInlet); marker(wetGroup, 'diffuser-mist-origin', diffuserPoint.toArray());
    for (let i = 0; i < 7; i++) ring(wetEdge, [intakeX, 1.22 + i * .13, -2.24], .114, [0, 1, 0], .007);
    cylinder(wetGlass, [intakeX, 1.12, -2.24], [intakeX, 1.17, -2.24], .115, .115, 8);
    cylinder(wetWater, [intakeX, 1.18, -2.24], [intakeX, waterLevel - .08, -2.24], .074, .074, 8);
    cylinder(wetGlass, returnStem, returnPoint.toArray(), .115, .27, 12, true);
    ring(wetEdge, returnPoint.toArray(), .27, returnAxis.toArray(), .012);
    for (const [x, y] of [[intakeX, 4.5], [intakeX, 6.7], [returnX, waterLevel - .1]]) {
      cylinder(wetGlass, [x, y, -2.59], [x, y, -2.50], .14, .07, 8);
      cylinder(wetGlass, [x, y, -2.50], [x, y, -2.24], .03, .03, 6);
    }
    cylinder(wetGlass, [diffuserX, 1.40, -2.59], [diffuserX, 1.40, -2.50], .13, .065, 8);
    cylinder(wetGlass, [diffuserX, 1.40, -2.50], [diffuserX, 1.40, -1.94], .03, .03, 6);
    cylinder(wetGlass, [diffuserX, 1.28, -1.78], [diffuserX, 1.53, -1.78], .16, .19, 12, true);
    cylinder(wetGlass, diffuserInlet, [diffuserX, 1.32, -1.78], .035, .035, 8);
    cylinder(ceramic, [diffuserX, 1.515, -1.78], [diffuserX, 1.555, -1.78], .165, .165, 12);
    ring(wetEdge, [diffuserX, 1.54, -1.78], .184, [0, 1, 0], .012);
    cylinder(wetWater, [diffuserX, 1.31, -1.78], [diffuserX, 1.49, -1.78], .13, .15, 10);

    const geometries = [];
    for (const [m, batch] of batches) {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(batch.normals, 3));
      geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const mesh = new THREE.Mesh(geometry, m); mesh.name = m.name;
      mesh.userData.visualWater = batch.visualWater;
      mesh.userData.solid = batch.group === wetGroup && !batch.visualWater;
      mesh.castShadow = !m.transparent; mesh.receiveShadow = !batch.visualWater;
      batch.group.add(mesh); geometries.push(geometry);
    }
    return { dryGroup, wetGroup, geometries, materials, maps: [], returnPoint, diffuserPoint };
  }
  return { create };
});
