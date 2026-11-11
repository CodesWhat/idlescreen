(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumEquipmentConnections = factory();
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
      if (!normal || normal.lengthSq() < 1e-6) {
        normal = new THREE.Vector3(Math.abs(tangent.y) < .9 ? 0 : 1, Math.abs(tangent.y) < .9 ? 1 : 0, 0).cross(tangent);
      }
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
      positions.push(...points[end]);
      normals.push(...outward.toArray());
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

  function create(THREE, options = {}) {
    const { tankHalf } = options;
    if (!Number.isFinite(tankHalf) || tankHalf <= 0) throw new RangeError('tankHalf must be positive and finite');
    const heaterEnd = endpoint(options.heaterEnd, 'heaterEnd');
    const ledEnd = endpoint(options.ledEnd, 'ledEnd');
    const airlineEnd = endpoint(options.airlineEnd, 'airlineEnd');
    const group = new THREE.Group();
    group.name = 'equipment-connections';
    const cable = new THREE.MeshLambertMaterial({ color: 0x242b2c });
    const housing = new THREE.MeshPhongMaterial({ color: 0x30393c, shininess: 9, specular: 0x11120f });
    const detail = new THREE.MeshLambertMaterial({ color: 0x697976, flatShading: true });
    const airline = new THREE.MeshLambertMaterial({ color: 0x486c60 });
    const ivory = new THREE.MeshLambertMaterial({ color: 0xa9a99f, flatShading: true });
    const materials = [cable, housing, detail, airline, ivory];
    ['equipment-cables', 'equipment-hard-plastic', 'equipment-fittings', 'equipment-airline', 'equipment-wall-tap']
      .forEach((name, index) => { materials[index].name = name; });
    const batches = new Map(materials.map(material => [material, { positions: [], normals: [] }]));

    function part(material, geometry, position = [0, 0, 0], rotation = new THREE.Quaternion(), scale = [1, 1, 1]) {
      geometry.applyMatrix4(new THREE.Matrix4().compose(new THREE.Vector3(...position), rotation, new THREE.Vector3(...scale)));
      const flat = geometry.index ? geometry.toNonIndexed() : geometry;
      const batch = batches.get(material);
      batch.positions.push(...flat.attributes.position.array);
      batch.normals.push(...flat.attributes.normal.array);
      if (flat !== geometry) flat.dispose();
      geometry.dispose();
    }
    function box(material, width, height, depth, point) {
      part(material, new THREE.BoxGeometry(width, height, depth), point);
    }
    function cylinder(material, a, b, radius, endRadius = radius, sides = 8) {
      const start = new THREE.Vector3(...a), end = new THREE.Vector3(...b), axis = end.clone().sub(start);
      const rotation = new THREE.Quaternion().setFromUnitVectors(new THREE.Vector3(0, 1, 0), axis.clone().normalize());
      part(material, new THREE.CylinderGeometry(endRadius, radius, axis.length(), sides), start.add(end).multiplyScalar(.5).toArray(), rotation);
    }
    function marker(name, point, direction) {
      const object = new THREE.Object3D();
      object.name = name;
      object.position.set(...point);
      if (direction) object.userData.direction = direction;
      group.add(object);
      return object;
    }

    const pumpX = tankHalf + .8, tapX = tankHalf * 1.33 + .35;
    if(!options.premium){
    const pump = marker('external-air-pump', [pumpX, .20, 2.8]);
    pump.userData.bounds = { min: [pumpX - .5, -.055, 2.2], max: [pumpX + .5, .435, 3.4] };
    const profile = [[0, .025], [.73, .025], [.95, .07], [1, .16], [.94, .30], [.73, .405], [.40, .425], [0, .425]];
    part(housing, new THREE.LatheGeometry(profile.map(point => new THREE.Vector2(...point)), 12),
      [pumpX, 0, 2.8], new THREE.Quaternion(), [.5, 1, .6]);
    for (const x of [-.28, .28]) for (const z of [-.34, .34]) {
      cylinder(cable, [pumpX + x, -.055, 2.8 + z], [pumpX + x, .04, 2.8 + z], .085, .075);
    }
    for (const x of [-.12, 0, .12]) box(cable, .045, .01, .20, [pumpX + x, .43, 2.8]);
    part(detail, new THREE.CylinderGeometry(1, 1, .018, 12, 1, true), [pumpX, .16, 2.8], new THREE.Quaternion(), [.501, 1, .601]);

    }
    const pumpAir = [pumpX, .20, 2.045], pumpPower = [pumpX + .31, .13, 2.18];
    if(!options.premium){
    marker('pump-air-outlet', pumpAir, [0, 0, -1]);
    marker('pump-power-exit', pumpPower, [0, 0, -1]);
    cylinder(detail, [pumpX, .20, 2.27], pumpAir, .049, .039);
    for (const z of [2.105, 2.17]) cylinder(detail, [pumpX, .20, z + .02], [pumpX, .20, z], .061, .051);
    cylinder(housing, [pumpX + .31, .13, 2.40], pumpPower, .049, .037);
    for (const z of [2.23, 2.28, 2.33]) cylinder(housing, [pumpX + .31, .13, z + .018], [pumpX + .31, .13, z], .054);

    }
    const stripX = tankHalf + .90;
    const outlet = marker('wall-outlet', [tapX, 1.5, -4.55], [0, 0, 1]);
    outlet.userData.receptacles = 2;
    box(ivory, .68, 1.30, .08, [tapX, 1.5, -4.555]);
    for (const y of [1.22, 1.78]) {
      box(ivory, .40, .40, .04, [tapX, y, -4.50]);
      for (const x of [-.085, .085]) box(cable, .035, .12, .012, [tapX+x,y+.04,-4.473]);
      cylinder(cable,[tapX,y-.11,-4.48],[tapX,y-.11,-4.46],.037);
    }
    for (const y of [.96, 2.04]) cylinder(detail,[tapX,y,-4.52],[tapX,y,-4.505],.025);
    box(housing,.29,.24,.24,[tapX,1.22,-4.35]);
    const wallPlug=[tapX,1.22,-4.15];
    cylinder(housing,[tapX,1.22,-4.25],wallPlug,.055,.039);
    marker('wall-plug',wallPlug,[0,0,1]);
    marker('counter-power-strip',[stripX,.11,-.50]);
    box(ivory,.60,.33,2.10,[stripX,.11,-.50]);
    const plugPoints = {};
    for (const [name,z] of [['heater',-1.16],['pump',-.50],['led',.16]]) {
      box(cable,.36,.018,.38,[stripX,.283,z]);
      box(housing,.29,.24,.29,[stripX,.40,z]);
      plugPoints[name]=[stripX,.62,z];
      cylinder(housing,[stripX,.50,z],plugPoints[name],.055,.039);
      for(const y of [.53,.57]) cylinder(housing,[stripX,y-.012,z],[stripX,y+.012,z],.059,.052);
      marker(name+'-plug',plugPoints[name],[0,1,0]);
    }
    const stripExit=[stripX,.10,-1.65];
    cylinder(housing,[stripX,.10,-1.48],stripExit,.055,.039);
    marker('strip-power-exit',stripExit,[0,0,-1]);

    const routes = {
      heater: {
        radius: .028, endConnector: 'heater-plug', points: [
          heaterEnd,[heaterEnd[0],heaterEnd[1]-.15,-3.14],
          [heaterEnd[0]+.04,6.4,-3.21],[heaterEnd[0]+.12,3.7,-3.15],
          [heaterEnd[0]+.2,1.2,-3.04],[tankHalf+.30,.18,-3.0],
          [tankHalf+.63,.04,-2.1],[stripX+.18,.04,-1.55],
          [stripX+.22,.28,-1.16],plugPoints.heater,
        ],
      },
      led: {
        radius: .032, endConnector: 'led-plug', points: [
          ledEnd,[ledEnd[0]+.02,ledEnd[1]-.12,-2.98],
          [ledEnd[0]+.08,6.1,-3.12],[ledEnd[0]+.17,3.5,-3.18],
          [ledEnd[0]+.22,1.2,-3.02],[tankHalf+.5,.18,-3.0],
          [tankHalf+1.1,.04,-.8],[stripX+.28,.04,.35],
          [stripX+.15,.32,.40],plugPoints.led,
        ],
      },
      airline: {
        radius: .027, endConnector: 'pump-air-outlet', points: [
          airlineEnd,[airlineEnd[0],airlineEnd[1]-.13,-3.12],
          [airlineEnd[0]+.05,5.7,-3.18],[airlineEnd[0]+.15,3.1,-3.08],
          [airlineEnd[0]+.24,1.0,-2.95],[tankHalf+.35,.25,-3.0],
          [tankHalf+.54,.16,-.7],[tankHalf+.62,.14,.2],
          [tankHalf+.76,.13,.9],[tankHalf+.88,.12,1.45],
          [tankHalf+.86,.18,1.88],pumpAir,
        ],
      },
      pumpPower: {
        radius: .026, startConnector: 'pump-power-exit', endConnector: 'pump-plug', points: [
          pumpPower, [pumpX+.41,.10,1.9], [pumpX+.56,.015,1.25],
          [pumpX+.61,-.026,.5], [stripX+.40,-.026,-.55],
          [stripX+.25,.20,-.72], plugPoints.pump,
        ],
      },
    };
    routes.stripPower = {radius:.032,startConnector:'strip-power-exit',endConnector:'wall-plug',points:[
      stripExit,[stripX,.02,-1.95],[stripX+.25,.02,-2.5],
      [tapX-.35,.02,-3.55],[tapX+.14,.16,-3.90],
      [tapX+.20,.55,-4.02],[tapX,1.05,-4.10],wallPlug
    ]};
    if(options.premium){delete routes.heater;delete routes.airline;delete routes.pumpPower;}
    // Round each bend inside its adjacent segments, retaining exact connector endpoints.
    for(const route of Object.values(routes)){
      const points=route.points, rounded=[points[0],points[1]];
      for(let i=2;i<points.length-1;i++){
        const previous=new THREE.Vector3(...points[i-1]),center=new THREE.Vector3(...points[i]),next=new THREE.Vector3(...points[i+1]);
        const entry=center.clone().lerp(previous,.18),exit=center.clone().lerp(next,.18);
        rounded.push(entry.toArray());
        for(let j=1;j<=3;j++){
          const t=j/3;
          rounded.push(entry.clone().multiplyScalar((1-t)*(1-t)).addScaledVector(center,2*t*(1-t)).addScaledVector(exit,t*t).toArray());
        }
      }
      rounded.push(points.at(-1));route.points=rounded;
    }
    group.userData.routes = routes;
    for (const [name, route] of Object.entries(routes)) part(name === 'airline' ? airline : cable, tubeGeometry(THREE, route.points, route.radius));

    if(!options.premium){
    const valveA = new THREE.Vector3(...[tankHalf + .54, .66, -.7]);
    const valveB = new THREE.Vector3(...[tankHalf + .62, .30, .2]);
    const valveCenter = valveA.clone().lerp(valveB, .5), valveAxis = valveB.sub(valveA).normalize();
    const valveStart = valveCenter.clone().addScaledVector(valveAxis, -.18);
    const valveEnd = valveCenter.clone().addScaledVector(valveAxis, .18);
    marker('airline-check-valve', valveCenter.toArray(), valveAxis.toArray());
    cylinder(detail, valveStart.toArray(), valveEnd.toArray(), .078, .068);
    cylinder(ivory, valveCenter.clone().addScaledVector(valveAxis, -.04).toArray(), valveCenter.clone().addScaledVector(valveAxis, .04).toArray(), .087);
    for (const end of [valveStart, valveEnd]) {
      cylinder(detail, end.clone().addScaledVector(valveAxis, -.04).toArray(), end.clone().addScaledVector(valveAxis, .04).toArray(), .044);
    }

    }
    const geometries = [];
    for (const [material, batch] of batches) {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('normal', new THREE.Float32BufferAttribute(batch.normals, 3));
      geometry.computeBoundingBox();
      geometry.computeBoundingSphere();
      const mesh = new THREE.Mesh(geometry, material);
      mesh.name = material.name;
      mesh.castShadow = mesh.receiveShadow = true;
      group.add(mesh);
      geometries.push(geometry);
    }
    return { group, geometries, materials, maps: [] };
  }

  return { create };
});
