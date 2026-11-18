(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumManzanitaArt = factory();
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
  function grainMap(THREE, seed) {
    const random = randomSource(seed ^ 7159), width = 32, height = 64, data = new Uint8Array(width * height * 4);
    for (let x = 0; x < width; x++) {
      const grain = Math.floor(random() * 16);
      for (let y = 0; y < height; y++) {
        const streak = (x + Math.floor(y / 17)) % 9 === 0;
        const shade = 224 + grain - (streak ? 35 : 0) + (Math.floor(y / 4) % 3) * 3;
        data.set([shade, shade - 3, shade - 8, 255], (y * width + x) * 4);
      }
    }
    const map = new THREE.DataTexture(data, width, height, THREE.RGBAFormat);
    map.name = 'manzanita-long-grain-pixels'; map.colorSpace = THREE.SRGBColorSpace;
    map.wrapS = map.wrapT = THREE.RepeatWrapping; map.minFilter = map.magFilter = THREE.NearestFilter;
    map.generateMipmaps = false; map.needsUpdate = true; return map;
  }

  function create(THREE, { seed = 731, growth = 1 } = {}) {
    if (!Number.isFinite(seed)) throw new RangeError('seed must be finite');
    if (!Number.isFinite(growth) || growth <= 0) throw new RangeError('growth must be positive and finite');
    growth = Math.max(.45, Math.min(1.35, growth)); seed >>>= 0;
    const random = randomSource(seed), group = new THREE.Group(); group.name = 'manzanita-root';
    const map = grainMap(THREE, seed), maps = [map], geometries = [];
    const wood = new THREE.MeshLambertMaterial({ color: 0xb49b76, map, vertexColors: true, flatShading: true });
    const moss = new THREE.MeshLambertMaterial({ color: 0x677f40, vertexColors: true, flatShading: true, side: THREE.DoubleSide });
    wood.name = 'manzanita-solid-wood'; moss.name = 'manzanita-sparse-moss';
    const materials = [wood, moss], batches = new Map(materials.map(mat => [mat, { positions: [], colors: [], uv: [] }]));
    const branches = [], branchById = new Map(), contacts = [], faceSamples = [], mossRoots = [], grazeSites = [];
    const vec = point => new THREE.Vector3(...point), scaled = point => point.map(value => value * growth);
    function triangle(mat, a, b, c, color = [1, 1, 1], uv = [[0, 0], [0, 1], [1, 0]], sample) {
      const normal = b.clone().sub(a).cross(c.clone().sub(a));
      if (normal.lengthSq() < 1e-12) return;
      normal.normalize();
      const batch = batches.get(mat);
      batch.positions.push(...a.toArray(), ...b.toArray(), ...c.toArray());
      for (let i = 0; i < 3; i++) { batch.colors.push(...color); batch.uv.push(...uv[i]); }
      if (sample) faceSamples.push({ ...sample, point: a.clone().add(b).add(c).multiplyScalar(1 / 3), normal });
    }
    function branch(id, controlPoints, radii, { parentId = null, parentStation = null, sides = 6, climb = false, fixedEnd = false } = {}) {
      const parent = parentId ? branchById.get(parentId) : null;
      const start = parent ? parent.points[parentStation].slice() : controlPoints[0].slice();
      const points = controlPoints.map((point, index) => {
        if (index === 0) return vec(start);
        const p = vec(point);
        if (parent) p.add(vec(start));
        if (!(fixedEnd && index === controlPoints.length - 1)) {
          p.x += (random() - .5) * .055; p.y += (random() - .5) * .045; p.z += (random() - .5) * .055;
        }
        return p;
      });
      const curve = new THREE.CatmullRomCurve3(points, false, 'centripetal');
      const steps = Math.max(4, Math.ceil(curve.getLength() / .17));
      const centers = [], actualRadii = [], rings = [], distances = [], vertexStart = batches.get(wood).positions.length / 3;
      let frame, distance = 0;
      const twist = random() * .45;
      for (let station = 0; station <= steps; station++) {
        const t = station / steps, point = curve.getPoint(t), tangent = curve.getTangent(t).normalize();
        if (station === 0) point.copy(vec(start));
        if (station) distance += point.distanceTo(centers.at(-1));
        distances.push(distance); centers.push(point);
        if (!frame) frame = new THREE.Vector3().crossVectors(tangent, Math.abs(tangent.z) < .8 ? new THREE.Vector3(0, 0, 1) : new THREE.Vector3(1, 0, 0)).normalize();
        frame.addScaledVector(tangent, -frame.dot(tangent)).normalize();
        const across = new THREE.Vector3().crossVectors(tangent, frame).normalize();
        const interval = Math.min(radii.length - 2, Math.floor(t * (radii.length - 1))), fraction = t * (radii.length - 1) - interval;
        const radius = THREE.MathUtils.lerp(radii[interval], radii[interval + 1], fraction); actualRadii.push(radius);
        rings.push(Array.from({ length: sides }, (_, side) => {
          const angle = side / sides * Math.PI * 2 + twist + .12 * t, lobe = 1 + .055 * Math.cos(angle * 3 + t * 2);
          return point.clone().addScaledVector(frame, Math.cos(angle) * radius * lobe)
            .addScaledVector(across, Math.sin(angle) * radius * lobe * .88);
        }));
      }
      for (let station = 0; station < steps; station++) for (let side = 0; side < sides; side++) {
        const next = (side + 1) % sides, u = side / sides, v = (side + 1) / sides;
        const color = side % 4 === 0 ? [.89, .85, .77] : side % 3 === 0 ? [1, .97, .91] : [.96, .93, .87];
        const sample = climb ? { branchId: id, station } : undefined;
        triangle(wood, rings[station][side], rings[station][next], rings[station + 1][side], color,
          [[u, distances[station] * .7], [v, distances[station] * .7], [u, distances[station + 1] * .7]], sample);
        triangle(wood, rings[station][next], rings[station + 1][next], rings[station + 1][side], color,
          [[v, distances[station] * .7], [v, distances[station + 1] * .7], [u, distances[station + 1] * .7]], sample);
      }
      for (let side = 0; side < sides; side++) {
        const next = (side + 1) % sides;
        triangle(wood, centers[0], rings[0][next], rings[0][side], [.77, .69, .56]);
        triangle(wood, centers.at(-1), rings.at(-1)[side], rings.at(-1)[next], [1, .93, .78]);
      }
      const record = { id, parentId, parentStation, points: centers.map(point => point.toArray()), radii: actualRadii,
        vertexStart, vertexCount: batches.get(wood).positions.length / 3 - vertexStart, climb };
      branches.push(record); branchById.set(id, record); return record;
    }
    function at(parentId, fraction) { return Math.round((branchById.get(parentId).points.length - 1) * fraction); }
    function limb(id, parentId, fraction, offsets, radius, climb = false, fixedEnd = false) {
      const station = at(parentId, fraction), parent = branchById.get(parentId), base = Math.min(radius, parent.radii[station] * .9);
      return branch(id, [[0, 0, 0], ...offsets], [base, base * .75, base * .43, .010].slice(0, offsets.length + 1),
        { parentId, parentStation: station, sides: base > .12 ? 8 : 6, climb, fixedEnd });
    }
    branch('root-arch', [[-1.72, .14, .10], [-1.42, .65, .02], [-.72, 1.19, -.10], [.05, 1.37, -.16], [.87, 1.04, .05], [1.72, .13, .43]],
      [.19, .23, .21, .18, .15, .11], { sides: 8, climb: true, fixedEnd: true });
    limb('rising-fork', 'root-arch', .52, [[.18, .40, -.13], [.61, .91, -.34], [1.06, 1.42, -.47]], .15);
    limb('left-fork', 'root-arch', .31, [[-.23, .43, .20], [-.58, .78, .33], [-.90, 1.00, .43]], .13);
    limb('right-sweep', 'root-arch', .70, [[.39, .31, .26], [.79, .48, .47], [1.10, .66, .55]], .10);
    const frontStation = at('root-arch', .31), frontStart = vec(branchById.get('root-arch').points[frontStation]);
    const rearStation = at('root-arch', .52), rearStart = vec(branchById.get('root-arch').points[rearStation]);
    branch('front-root', [[0, 0, 0], vec([-.65, .62, .56]).sub(frontStart).toArray(), vec([-.58, .10, 1.02]).sub(frontStart).toArray()],
      [.17, .14, .09], { parentId: 'root-arch', parentStation: frontStation, sides: 8, climb: true, fixedEnd: true });
    branch('rear-root', [[0, 0, 0], vec([.18, .62, -.70]).sub(rearStart).toArray(), vec([.51, .09, -1.02]).sub(rearStart).toArray()],
      [.14, .11, .065], { parentId: 'root-arch', parentStation: rearStation, sides: 8, climb: true, fixedEnd: true });
    for (const [id, parent, fraction, offsets, radius] of [
      ['high-left', 'rising-fork', .55, [[-.24, .23, .12], [-.43, .49, .23], [-.46, .67, .31]], .053],
      ['high-right', 'rising-fork', .75, [[.20, .11, .12], [.42, .25, .17], [.60, .29, .22]], .035],
      ['upper-prong', 'rising-fork', .35, [[.21, .14, -.13], [.39, .30, -.20], [.42, .47, -.25]], .048],
      ['left-spur', 'left-fork', .55, [[-.18, .10, -.18], [-.36, .26, -.32], [-.42, .41, -.35]], .043],
      ['left-tip', 'left-fork', .76, [[.08, .26, .01], [.04, .40, .08], [.10, .52, .07]], .027],
      ['front-fork', 'front-root', .32, [[-.38, .14, .20], [-.61, .32, .28], [-.78, .49, .30]], .059],
      ['sweep-up', 'right-sweep', .45, [[.01, .29, -.03], [-.07, .48, -.10], [.02, .62, -.15]], .040],
      ['sweep-down', 'right-sweep', .60, [[.13, -.19, .03], [.23, -.35, .16], [.36, -.39, .19]], .032],
      ['rear-fine', 'rear-root', .40, [[.35, .08, -.10], [.56, .22, -.10], [.71, .27, -.04]], .045]
    ]) limb(id, parent, fraction, offsets, radius);
    for (const [id, parent, fraction, offsets] of [
      ['high-left-tip', 'high-left', .59, [[-.14, .07, -.08], [-.23, .17, -.13], [-.23, .25, -.14]]],
      ['left-spur-tip', 'left-spur', .53, [[-.12, .02, .07], [-.21, .10, .12], [-.27, .13, .14]]],
      ['sweep-up-tip', 'sweep-up', .55, [[.15, .05, .08], [.26, .13, .10], [.30, .21, .10]]],
      ['front-fork-tip', 'front-fork', .60, [[-.06, .14, -.07], [-.03, .24, -.15], [.01, .31, -.18]]]
    ]) limb(id, parent, fraction, offsets, .018);

    function foot(id, branchId, station, radius) {
      const center = vec(branchById.get(branchId).points[station]), rings = [];
      for (const [scale, y] of [[.81, 0], [1, .07], [.62, .19]]) rings.push(Array.from({ length: 8 }, (_, i) => {
        const angle = i * Math.PI / 4;
        return new THREE.Vector3(center.x + Math.cos(angle) * radius * scale, y, center.z + Math.sin(angle) * radius * scale * .68);
      }));
      const bottom = new THREE.Vector3(center.x, 0, center.z), crown = new THREE.Vector3(center.x, .22, center.z);
      for (let i = 0; i < 8; i++) {
        const j = (i + 1) % 8;
        triangle(wood, bottom, rings[0][i], rings[0][j], [.80, .74, .65]);
        triangle(wood, crown, rings[2][j], rings[2][i], [1, .95, .87]);
        for (let row = 0; row < 2; row++) {
          triangle(wood, rings[row][i], rings[row + 1][i], rings[row][j]);
          triangle(wood, rings[row + 1][i], rings[row + 1][j], rings[row][j]);
        }
      }
      contacts.push({ id, branchId, station, position: bottom.toArray(), normal: [0, 1, 0], radius });
    }
    foot('left-ground', 'root-arch', 0, .25);
    foot('right-ground', 'root-arch', branchById.get('root-arch').points.length - 1, .19);
    foot('front-ground', 'front-root', branchById.get('front-root').points.length - 1, .18);
    foot('rear-ground', 'rear-root', branchById.get('rear-root').points.length - 1, .15);

    function finish(mat) {
      const batch = batches.get(mat), geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.positions, 3));
      geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.colors, 3));
      if (mat.map) geometry.setAttribute('uv', new THREE.Float32BufferAttribute(batch.uv, 2));
      geometry.computeVertexNormals();
      const mesh = new THREE.Mesh(geometry, mat); mesh.name = mat.name;
      const solid = mat === wood;
      mesh.userData = { solid, hardscape: solid, climbable: solid, plantFoliage: !solid, species: solid ? 'manzanita-wood' : 'aquarium-moss' };
      mesh.castShadow = mesh.receiveShadow = true; geometries.push(geometry); group.add(mesh); return mesh;
    }
    const woodMesh = finish(wood); woodMesh.updateMatrixWorld(true);
    const ray = new THREE.Raycaster();
    function exposed(face) {
      ray.set(face.point.clone().addScaledVector(face.normal, .03), face.normal.clone().negate()); ray.near = 0; ray.far = .06;
      const hit = ray.intersectObject(woodMesh)[0]; return hit && hit.point.distanceTo(face.point) < .0001;
    }
    const branchSites = new Map();
    for (const branch of branches.filter(record => record.climb)) {
      const sites = [];
      for (let station = 0; station < branch.points.length - 1; station++) {
        const candidates = faceSamples.filter(face => face.branchId === branch.id && face.station === station && face.normal.y > .05)
          .sort((a, b) => (b.normal.y * .8 + b.normal.z * .6) - (a.normal.y * .8 + a.normal.z * .6));
        const face = candidates.find(exposed); if (!face) continue;
        const site = { id: branch.id + '-graze-' + station, position: face.point.toArray(), normal: face.normal.toArray(), links: [], surface: 'wood', branchId: branch.id };
        sites.push(site); grazeSites.push(site);
      }
      branchSites.set(branch.id, sites);
    }
    function link(a, b) {
      if (!a || !b || vec(a.position).distanceTo(vec(b.position)) * growth > .64) return;
      if (!a.links.includes(b.id)) a.links.push(b.id);
      if (!b.links.includes(a.id)) b.links.push(a.id);
    }
    for (const branch of branches.filter(record => record.climb)) {
      const sites = branchSites.get(branch.id);
      for (let i = 1; i < sites.length; i++) link(sites[i - 1], sites[i]);
      if (branch.parentId && sites.length) {
        const parentSites = branchSites.get(branch.parentId);
        const nearest = parentSites.slice().sort((a, b) => vec(a.position).distanceTo(vec(sites[0].position)) - vec(b.position).distanceTo(vec(sites[0].position)))[0];
        link(sites[0], nearest);
      }
    }
    for (const contact of contacts) {
      const entry = { id: contact.id + '-entry', position: [contact.position[0], 0, contact.position[2] + contact.radius * .85], normal: [0, 1, 0], links: [], surface: 'substrate', branchId: contact.branchId };
      const nearest = branchSites.get(contact.branchId).slice().sort((a, b) => vec(a.position).distanceTo(vec(entry.position)) - vec(b.position).distanceTo(vec(entry.position)))[0];
      link(entry, nearest); grazeSites.push(entry);
    }

    const mossSites = branchSites.get('root-arch').filter(site => site.normal[1] > .5 && site.position[1] > 1);
    for (const site of [mossSites[Math.floor(mossSites.length * .25)], mossSites[Math.floor(mossSites.length * .75)]].filter(Boolean)) {
      const point = vec(site.position), normal = vec(site.normal);
      const side = new THREE.Vector3().crossVectors(normal, new THREE.Vector3(0, 0, 1)).normalize();
      mossRoots.push({ position: point.toArray(), normal: normal.toArray() });
      for (let i = 0; i < 9; i++) {
        const root = point.clone().addScaledVector(normal, -.002), direction = new THREE.Vector3((random() - .5) * .6, 1, (random() - .5) * .6).normalize();
        const tip = point.clone().addScaledVector(direction, .08 + random() * .09), color = i % 3 ? [.76, .86, .67] : [1, 1, .83];
        const mid = root.clone().lerp(tip, .60);
        triangle(moss, root.clone().addScaledVector(side, -.004), root.clone().addScaledVector(side, .004), tip, color);
        for (const sign of [-1, 1]) {
          const leafTip = mid.clone().addScaledVector(side, sign * (.025 + random() * .02)).addScaledVector(normal, .035);
          triangle(moss, mid.clone().addScaledVector(normal, -.004), leafTip, mid.clone().addScaledVector(normal, .008), color);
        }
      }
    }
    finish(moss);
    for (const geometry of geometries) { geometry.scale(growth, growth, growth); geometry.computeBoundingBox(); geometry.computeBoundingSphere(); }
    for (const branch of branches) { branch.points = branch.points.map(scaled); branch.radii = branch.radii.map(radius => radius * growth); }
    for (const contact of contacts) { contact.position = scaled(contact.position); contact.radius *= growth; }
    for (const root of mossRoots) root.position = scaled(root.position);
    for (const site of grazeSites) site.position = scaled(site.position);
    group.userData = { species: 'manzanita-root', seed, growth, branches, contacts, mossRoots,
      openings: [{ from: scaled([-.10, .36, -1.45]), to: scaled([-.10, .36, 1.45]) }] };
    return { group, geometries, materials, maps, grazeSites };
  }
  return { create };
});
