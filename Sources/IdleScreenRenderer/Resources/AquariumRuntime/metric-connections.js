(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumMetricConnections = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function endpoint(value, name) {
    const point = Array.isArray(value) ? value.slice(0, 3) : [value?.x, value?.y, value?.z];
    if (point.length !== 3 || !point.every(Number.isFinite)) throw new RangeError(name + ' must contain three finite coordinates');
    return point;
  }

  function tubeGeometry(THREE, points, radius) {
    const sides = 6, positions = [], normals = [], indices = [];
    let normal;
    for (let i = 0; i < points.length; i++) {
      const center = new THREE.Vector3(...points[i]);
      const previous = new THREE.Vector3(...points[Math.max(0, i - 1)]);
      const next = new THREE.Vector3(...points[Math.min(points.length - 1, i + 1)]);
      const tangent = next.sub(previous).normalize();
      if (normal) normal.addScaledVector(tangent, -normal.dot(tangent));
      if (!normal || normal.lengthSq() < 1e-6) normal = new THREE.Vector3(Math.abs(tangent.y) < .9 ? 0 : 1, Math.abs(tangent.y) < .9 ? 1 : 0, 0).cross(tangent);
      normal.normalize();
      const binormal = new THREE.Vector3().crossVectors(tangent, normal).normalize();
      for (let side = 0; side < sides; side++) {
        const angle = side / sides * Math.PI * 2;
        const radial = normal.clone().multiplyScalar(Math.cos(angle)).addScaledVector(binormal, Math.sin(angle));
        positions.push(...center.clone().addScaledVector(radial, radius).toArray());
        normals.push(...radial.toArray());
        if (i < points.length - 1) {
          const a = i * sides + side, b = i * sides + (side + 1) % sides;
          indices.push(a, b, a + sides, b, b + sides, a + sides);
        }
      }
    }
    for (const end of [0, points.length - 1]) {
      const center = positions.length / 3;
      const outward = new THREE.Vector3(...points[end]).sub(new THREE.Vector3(...points[end === 0 ? 1 : end - 1])).normalize();
      positions.push(...points[end]); normals.push(...outward.toArray());
      for (let side = 0; side < sides; side++) {
        const a = end * sides + side, b = end * sides + (side + 1) % sides;
        indices.push(center, end === 0 ? b : a, end === 0 ? a : b);
      }
    }
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
    geometry.setIndex(indices);
    return geometry;
  }

  function roundRoute(THREE, points, bendRadius, preserve = 1) {
    const rounded = points.slice(0, preserve).map(p => p.slice());
    for (let i = preserve; i < points.length - 1; i++) {
      const previous = new THREE.Vector3(...points[i - 1]), center = new THREE.Vector3(...points[i]), next = new THREE.Vector3(...points[i + 1]);
      const distance = Math.min(bendRadius, center.distanceTo(previous) * .22, center.distanceTo(next) * .22);
      const entry = center.clone().addScaledVector(previous.sub(center).normalize(), distance);
      const exit = center.clone().addScaledVector(next.sub(center).normalize(), distance);
      rounded.push(entry.toArray());
      for (let j = 1; j <= 4; j++) {
        const t = j / 4;
        rounded.push(entry.clone().multiplyScalar((1 - t) * (1 - t)).addScaledVector(center, 2 * t * (1 - t)).addScaledVector(exit, t * t).toArray());
      }
    }
    rounded.push(points.at(-1).slice());
    return rounded.filter((p, i) => !i || p.some((v, axis) => Math.abs(v - rounded[i - 1][axis]) > 1e-7));
  }

  function create(THREE, options = {}) {
    const { tankHalf = 7, cmPerUnit = 36 / 8.4, backZ = -4.36, wallGap = 3 } = options;
    for (const [name, value] of Object.entries({ tankHalf, cmPerUnit })) if (!Number.isFinite(value) || value <= 0) throw new RangeError(name + ' must be positive and finite');
    if (!Number.isFinite(backZ)) throw new RangeError('backZ must be finite');
    if (!Number.isFinite(wallGap) || wallGap <= 1 + 5 / cmPerUnit) throw new RangeError('wallGap must leave room behind the strip');
    const mode = options.hob ? 'hob' : options.premium ? 'premium' : 'basic';
    const ledEnd = endpoint(options.ledEnd, 'ledEnd');
    const heaterEnd = mode === 'basic' ? endpoint(options.heaterEnd, 'heaterEnd') : null;
    const airlineEnd = mode === 'basic' ? endpoint(options.airlineEnd, 'airlineEnd') : null;
    const u = cm => cm / cmPerUnit, counterY = -.055, wallZ = backZ - wallGap;
    const group = new THREE.Group(); group.name = 'equipment-connections';
    const cable = new THREE.MeshLambertMaterial({ color: 0x242b2c });
    const housing = new THREE.MeshPhongMaterial({ color: 0x30393c, shininess: 9, specular: 0x11120f });
    const detail = new THREE.MeshLambertMaterial({ color: 0x697976, flatShading: true });
    const airline = new THREE.MeshLambertMaterial({ color: 0x486c60 });
    const ivory = new THREE.MeshLambertMaterial({ color: 0xa9a99f, flatShading: true });
    const materials = [cable, housing, detail, airline, ivory];
    ['equipment-cables', 'equipment-hard-plastic', 'equipment-fittings', 'equipment-airline', 'equipment-wall-tap'].forEach((name, i) => { materials[i].name = name; });
    const batches = new Map(materials.map(m => [m, { positions: [], normals: [] }]));
    const parts = {}, counterBounds = new THREE.Box3();

    function part(id, material, geometry, position = [0, 0, 0], rotation = new THREE.Quaternion(), scale = [1, 1, 1], onCounter = true) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...position), rotation, new THREE.Vector3(...scale)));
      const flat = geometry.index ? geometry.toNonIndexed() : geometry, batch = batches.get(material);
      const start = batch.positions.length / 3, positions = flat.attributes.position;
      const bounds = new THREE.Box3().setFromBufferAttribute(positions);
      const record = parts[id] || (parts[id] = { ranges: [], bounds: { min: [Infinity, Infinity, Infinity], max: [-Infinity, -Infinity, -Infinity] } });
      record.ranges.push({ material: material.name, start, count: positions.count });
      for (let i = 0; i < 3; i++) { record.bounds.min[i] = Math.min(record.bounds.min[i], bounds.min.getComponent(i)); record.bounds.max[i] = Math.max(record.bounds.max[i], bounds.max.getComponent(i)); }
      if (onCounter) counterBounds.union(bounds);
      for (const value of positions.array) batch.positions.push(value);
      for (const value of flat.attributes.normal.array) batch.normals.push(value);
      if (flat !== geometry) flat.dispose(); geometry.dispose();
    }
    function box(id, material, width, height, depth, point, onCounter = true) {
      part(id, material, new THREE.BoxGeometry(width, height, depth), point, undefined, undefined, onCounter);
    }
    function cylinder(id, material, a, b, radius, endRadius = radius, sides = 8, onCounter = true) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), axis = end.clone().sub(start);
      const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
      part(id, material, new THREE.CylinderGeometry(endRadius, radius, axis.length(), sides), start.add(end).multiplyScalar(.5).toArray(), rotation, undefined, onCounter);
    }
    function marker(name, point, direction) {
      const object = new THREE.Object3D(); object.name = name; object.position.set(...point);
      if (direction) object.userData.direction = direction.slice();
      group.add(object); return object;
    }
    function receptacle(id, center, vertical, occupied, name) {
      const holes = [
        { type: 'neutral', localCm: [-.635, .45], heightCm: .85, widthCm: .18 },
        { type: 'hot', localCm: [.635, .45], heightCm: .65, widthCm: .18 },
        { type: 'ground', localCm: [0, -.85], diameterCm: .5 },
      ];
      if (vertical) box(id, ivory, u(3.2), u(3.1), u(.24), center, false);
      else box(id, ivory, u(3.2), u(.16), u(3.1), center);
      for (const hole of holes) {
        const [x, y] = hole.localCm;
        const point = vertical ? [center[0] + u(x), center[1] + u(y), center[2] + u(.13)] : [center[0] + u(x), center[1] + u(.09), center[2] - u(y)];
        if (hole.type === 'ground') {
          const end = point.slice(); end[vertical ? 2 : 1] += u(.04);
          cylinder(id, cable, point, end, u(.25), u(.25), 8, !vertical);
        } else box(id, cable, u(.18), u(vertical ? hole.heightCm : .04), u(vertical ? .04 : hole.heightCm), point, !vertical);
      }
      return { name, occupied, faceCenter: center.slice(), holes };
    }

    const stripX = tankHalf + u(4), stripZ = backZ - 1, wallX = stripX + u(6), wallY = counterY + u(34);
    const outlet = marker('wall-outlet', [wallX, wallY, wallZ + u(.4318)], [0, 0, 1]); outlet.userData.receptacles = 2;
    box('wallplate', ivory, u(6.985), u(11.43), u(.4318), [wallX, wallY, wallZ + u(.4318 / 2)], false);
    const wallReceptacles = [-1.905, 1.905].map((dy, index) => receptacle('wall-receptacle-' + index, [wallX, wallY + u(dy), wallZ + u(.5518)], true, index === 0, 'wall-' + index));
    cylinder('wallplate-screw', detail, [wallX, wallY, wallZ + u(.44)], [wallX, wallY, wallZ + u(.55)], u(.22), u(.22), 8, false);
    box('wallplate-screw-slot', cable, u(.3), u(.055), u(.015), [wallX, wallY, wallZ + u(.5575)], false);
    const wallPlugY = wallY - u(1.905), plugBackZ = wallZ + u(.69);
    box('wall-plug', housing, u(3), u(2.4), u(2.4), [wallX, wallPlugY, plugBackZ + u(1.2)], false);
    const wallPlug = [wallX, wallPlugY, plugBackZ + u(3.4)];
    cylinder('wall-plug', housing, [wallX, wallPlugY, plugBackZ + u(2.4)], wallPlug, u(.35), u(.3), 8, false);
    marker('wall-plug', wallPlug, [0, 0, 1]);

    marker('counter-power-strip', [stripX, counterY + u(1.5), stripZ]);
    box('strip-body', ivory, u(24), u(3), u(6), [stripX, counterY + u(1.5), stripZ]);
    const plugPoints = {}, sockets = [];
    for (const [name, dx] of [['heater', -8], ['pump', 0], ['led', 8]]) {
      const x = stripX + u(dx), occupied = mode !== 'hob' || name !== 'pump';
      sockets.push(receptacle(name + '-socket', [x, counterY + u(3.08), stripZ], false, occupied, name));
      marker(name + '-socket', [x, counterY + u(3.16), stripZ], [0, 1, 0]);
      if (!occupied) continue;
      box(name + '-plug', housing, u(3), u(2.4), u(2.4), [x, counterY + u(4.36), stripZ]);
      for (const sx of [-.635, .635]) box(name + '-plug', detail, u(.15), u(.8), u(.5), [x + u(sx), counterY + u(3), stripZ - u(.45)]);
      const point = [x, counterY + u(4.36), stripZ + u(2.3)];
      cylinder(name + '-plug', housing, [x, point[1], stripZ + u(1.2)], point, u(.35), u(.25));
      for (const z of [1.5, 1.85]) cylinder(name + '-plug', housing, [x, point[1], stripZ + u(z)], [x, point[1], stripZ + u(z + .12)], u(.38));
      plugPoints[name] = point; marker(name + '-plug', point, [0, 0, 1]);
    }
    const stripExit = [stripX - u(12.9), counterY + u(1.2), stripZ];
    cylinder('strip-power-exit', housing, [stripX - u(12), stripExit[1], stripZ], stripExit, u(.4), u(.3));
    marker('strip-power-exit', stripExit, [-1, 0, 0]);

    const pumpX = tankHalf + u(6.5), pumpZ = 4.04 - u(6);
    const pumpAir = [pumpX, counterY + u(2.8), pumpZ - u(8.5)], pumpPower = [pumpX + u(2), counterY + u(2), pumpZ - u(7.7)];
    if (mode === 'basic') {
      const profile = [[0, .6], [.75, .6], [.95, 1.2], [1, 2.8], [.94, 5.4], [.72, 6.6], [0, 6.6]];
      part('pump-body', housing, new THREE.LatheGeometry(profile.map(([r, y]) => new THREE.Vector2(r, u(y))), 12), [pumpX, counterY, pumpZ], undefined, [u(4.5), 1, u(7.5)]);
      for (const x of [-2.2, 2.2]) for (const z of [-3.8, 3.8]) cylinder('pump-body', housing, [pumpX + u(x), counterY, pumpZ + u(z)], [pumpX + u(x), counterY + u(.8), pumpZ + u(z)], u(.55), u(.5));
      cylinder('pump-body', detail, [pumpX, counterY + u(6.6), pumpZ + u(3)], [pumpX, counterY + u(7), pumpZ + u(3)], u(1.3), u(1.1), 12);
      for (const x of [-.7, 0, .7]) box('pump-body', housing, u(.25), u(.1), u(2), [pumpX + u(x), counterY + u(6.65), pumpZ - u(1.5)]);
      const pump = marker('external-air-pump', [pumpX, counterY + u(3.5), pumpZ]); pump.userData.bounds = parts['pump-body'].bounds;
      cylinder('pump-air-outlet', detail, [pumpX, pumpAir[1], pumpZ - u(7.1)], pumpAir, u(.3));
      for (const z of [7.6, 8.05]) cylinder('pump-air-outlet', detail, [pumpX, pumpAir[1], pumpZ - u(z)], [pumpX, pumpAir[1], pumpZ - u(z + .15)], u(.38), u(.3));
      cylinder('pump-power-exit', housing, [pumpPower[0], pumpPower[1], pumpZ - u(6.4)], pumpPower, u(.35), u(.25));
      marker('pump-air-outlet', pumpAir, [0, 0, -1]); marker('pump-power-exit', pumpPower, [0, 0, -1]);
    }

    const lowY = counterY + u(.4), sideX = tankHalf + u(1), corridorZ = backZ - u(.7), rearZ = backZ - u(1.4);
    const routes = {};
    function route(name, points, diameterCm, endConnector, startConnector, preserve = 1) {
      routes[name] = { points: roundRoute(THREE, points, u(1.8), preserve), radius: u(diameterCm / 2), diameterCm, endConnector };
      if (startConnector) routes[name].startConnector = startConnector;
    }
    function upperLead(start) {
      const points = [start.slice()];
      if (start[2] + u(.3) >= backZ) {
        const y = Math.max(start[1], u(36.8));
        if (y !== start[1]) points.push([start[0], y, start[2]]);
        points.push([start[0], y, rearZ]);
      } else points.push([start[0], start[1] - u(.5), Math.min(start[2], rearZ)]);
      points.push([start[0] + u(.25), u(25), rearZ - u(.4)], [start[0] + u(.6), u(13), rearZ - u(.1)], [start[0] + u(.8), counterY + u(5), rearZ]);
      return points;
    }
    function plugApproach(point, x) {
      return [[x, counterY + u(5), corridorZ], [x, lowY, corridorZ], [point[0] + u(.6), lowY, corridorZ], [point[0], point[1], point[2] + u(1)], point];
    }
    route('led', [...upperLead(ledEnd), ...plugApproach(plugPoints.led, ledEnd[0] + u(.8))], .5, 'led-plug', undefined, 2);
    if (mode === 'basic') {
      route('heater', [...upperLead(heaterEnd), ...plugApproach(plugPoints.heater, heaterEnd[0] + u(.8))], .5, 'heater-plug', undefined, 2);
      const airY = counterY + u(.5), valveZ = pumpAir[2] - u(4), approachZ = pumpAir[2] - u(.7);
      route('airline', [...upperLead(airlineEnd), [airlineEnd[0] + u(.8), counterY + u(5), corridorZ],
        [airlineEnd[0] + u(.8), airY, corridorZ], [sideX, airY, corridorZ],
        [sideX, airY, valveZ - u(2.4)], [sideX, airY, valveZ + u(2.4)], [sideX, airY, approachZ],
        [pumpAir[0], pumpAir[1], approachZ], pumpAir], .6, 'pump-air-outlet', undefined, 2);
      route('pumpPower', [pumpPower, [pumpPower[0], pumpPower[1], pumpPower[2] - u(.7)], [sideX, lowY, pumpPower[2] - u(.7)],
        [sideX, lowY, corridorZ + u(1.5)], [sideX, lowY, corridorZ], [plugPoints.pump[0] + u(.6), lowY, corridorZ],
        [plugPoints.pump[0], plugPoints.pump[1], plugPoints.pump[2] + u(1)], plugPoints.pump], .5, 'pump-plug', 'pump-power-exit');
      marker('airline-check-valve', [sideX, airY, valveZ], [0, 0, 1]);
      cylinder('airline-check-valve', detail, [sideX, airY, valveZ - u(1.6)], [sideX, airY, valveZ + u(1.6)], u(.5), u(.45));
      cylinder('airline-check-valve', ivory, [sideX, airY, valveZ - u(.25)], [sideX, airY, valveZ + u(.25)], u(.5));
    }
    const rearLane = wallZ + u(4);
    route('stripPower', [stripExit, [stripExit[0] - u(1.2), stripExit[1], stripExit[2]], [stripExit[0] - u(1.8), lowY, stripExit[2] - u(2)],
      [stripExit[0] - u(1.8), lowY, rearLane], [wallX + u(2), lowY, rearLane], [wallX + u(2.3), counterY + u(8), wallZ + u(3.1)],
      [wallX + u(.7), counterY + u(22), wallZ + u(3.5)], [wallPlug[0], wallPlug[1] - u(2), wallPlug[2] + u(1)], wallPlug], .6, 'wall-plug', 'strip-power-exit');
    for (const [name, data] of Object.entries(routes)) part('route-' + name, name === 'airline' ? airline : cable, tubeGeometry(THREE, data.points, data.radius));

    const geometries = [];
    for (const [material, batch] of batches) {
      if (!batch.positions.length) continue;
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(batch.normals, 3));
      geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const mesh = new THREE.Mesh(geometry, material); mesh.name = material.name; mesh.userData.solid = false;
      mesh.castShadow = mesh.receiveShadow = true; group.add(mesh); geometries.push(geometry);
    }
    group.userData = {
      mode, cmPerUnit, backZ, wallGap, wallZ, routes, parts, sockets, wallReceptacles,
      requiredCounterBounds: { min: [counterBounds.min.x, counterY, counterBounds.min.z], max: [counterBounds.max.x, counterY, counterBounds.max.z] },
      dimensions: {
        wallplate: { status: 'manufacturer', cm: [6.985, 11.43, .4318], source: 'https://hubbellcdn.com/specsheet/TAYM-WWD-SPEC-EN.pdf' },
        strip: { status: 'authored', cm: [24, 3, 6] },
        pump: { status: 'manufacturer-envelope-authored-orientation', cm: [9, 7, 15], source: 'https://www.oase.com/en-US/aquarium/oxymax-100' },
        fittings: { status: 'authored', cordDiameterCm: [.5, .6], airlineOuterDiameterCm: .6 },
      },
    };
    return { group, geometries, materials, maps: [] };
  }
  return { create };
});
