(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumEpiphytePlantsV2 = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  const references = {
    'java-fern': {
      botanical: 'Microsorum pteropus', primary: 'https://tropica.com/en/plants/plantdetails/4408/4408',
      catalog: 'https://shop.glassaqua.com/products/microsorum-pteropus-java-fern-mother-plant',
      heightCm: [15, 30], basis: 'Nursery height range; leaf dimensions and clump form authored.',
    },
    bucephalandra: {
      botanical: "Bucephalandra pygmaea, Wavy Green form", primary: 'https://tropica.com/en/plants/plantdetails/Bucephalandrapygmaea%27BukitKelam%27%28139%29/18757',
      catalog: 'https://shop.glassaqua.com/products/bucephalandra-dark-green-wavy',
      heightCm: [5, 10], leafCm: [5, 2], basis: 'Nursery height and approximate leaf length/width; original branching and waves authored.',
    },
    fissidens: {
      botanical: 'Fissidens fontanus', primary: 'https://www.nparks.gov.sg/florafaunaweb/flora/5/7/5728',
      catalog: 'https://shop.glassaqua.com/products/fissidens-fontanus',
      heightCm: [0, 5], basis: 'Botanical maximum height and feathery curling form; individual leaflet sizes authored.',
    },
    'christmas-moss': {
      botanical: 'Vesicularia montagnei', primary: 'https://tropica.com/en/plants/plantdetails/Vesiculariamontagnei%27Christmas%27%28003APOR%29/4395',
      catalog: 'https://shop.glassaqua.com/products/christmas-moss',
      heightCm: [1, 5], basis: 'Nursery prose says 1–3 cm; its growth table says 3–5+ cm. Mat and branch sizes authored.',
    },
  };

  function create(THREE, { species, seed = 247, cmPerUnit = 36 / 8.4, growth = 1 } = {}) {
    if (!Object.prototype.hasOwnProperty.call(references, species)) throw new RangeError('species must be java-fern, bucephalandra, fissidens or christmas-moss');
    if (!Number.isFinite(seed)) throw new RangeError('seed must be finite');
    if (!Number.isFinite(cmPerUnit) || cmPerUnit <= 0) throw new RangeError('cmPerUnit must be positive and finite');
    if (!Number.isFinite(growth) || growth <= 0 || growth > 1.5) throw new RangeError('growth must be within (0, 1.5]');
    const originalSeed = seed >>> 0, factor = growth / cmPerUnit, moss = species === 'fissidens' || species === 'christmas-moss';
    let state = originalSeed;
    const random = () => { state = (Math.imul(state, 1664525) + 1013904223) >>> 0; return state / 4294967296; };
    const u = cm => cm * factor, scaled = point => point.map(u);
    const group = new THREE.Group(), geometries = [], materials = [], maps = [], grazeSites = [];
    group.name = 'epiphyte-' + species;
    const botany = { stems: [], leaves: [], attachments: [], fronds: [], seed: originalSeed, growth };
    const batches = Object.fromEntries(['roots', 'stems', 'foliage'].map(name => [name, { name, p: [], color: [], uv: [], indices: [] }]));
    const palettes = {
      'java-fern': [0x48652e, 0x607e39, 0x73904a, 0x536f34],
      bucephalandra: [0x314d41, 0x3e5c47, 0x496450, 0x6c7950],
      fissidens: [0x3f6543, 0x527b4d, 0x638853, 0x476e46],
      'christmas-moss': [0x496e38, 0x5f7e40, 0x6d8b4d, 0x3d6033],
    };
    const colors = palettes[species].map(hex => new THREE.Color(hex)), rootColor = new THREE.Color(moss ? 0x4c5841 : 0x777553);
    const stemColor = new THREE.Color(species === 'bucephalandra' ? 0x695b47 : moss ? 0x4b6c3c : 0x527139);
    const temp = new THREE.Vector3(), tangent = new THREE.Vector3(), lateral = new THREE.Vector3(), normal = new THREE.Vector3();

    function vertex(batch, point, color, uv = [.5, .5], shade = 1) {
      const index = batch.p.length / 3;
      batch.p.push(point[0], Math.max(0, point[1]), point[2]);
      batch.color.push(color.r * shade, color.g * shade, color.b * shade); batch.uv.push(...uv); return index;
    }
    function link(a, b) {
      if (!a || !b || a.id === b.id) return;
      if (!a.links.includes(b.id)) a.links.push(b.id);
      if (!b.links.includes(a.id)) b.links.push(a.id);
    }
    function site(batch, index, kind, previous, radiusCm) {
      const p = batch.p.slice(index * 3, index * 3 + 3);
      const result = { id: species + '-site-' + grazeSites.length, kind, meshName: 'epiphyte-' + batch.name, vertex: index,
        position: p.slice(), rest: p.slice(), normal: [0, 1, 0], links: [], radius: u(radiusCm) };
      grazeSites.push(result); link(result, previous); return result;
    }
    function stem(id, kind, pathCm, radiusCm, parent = null, parentNode = 0, createSites = true) {
      const fixed = ['rhizome', 'runner', 'root', 'rhizoid'].includes(kind), batch = fixed ? batches.roots : batches.stems;
      const path = pathCm.map(scaled), start = batch.p.length / 3, rings = [], pathVertices = [], sides = moss ? 4 : 6;
      const color = kind === 'root' || kind === 'rhizoid' ? rootColor : stemColor;
      for (let i = 0; i < path.length; i++) {
        tangent.fromArray(path[Math.min(path.length - 1, i + 1)]).sub(temp.fromArray(path[Math.max(0, i - 1)])).normalize();
        lateral.set(0, 1, 0).addScaledVector(tangent, -tangent.y);
        if (lateral.lengthSq() < .01) lateral.set(1, 0, 0).addScaledVector(tangent, -tangent.x);
        lateral.normalize(); normal.crossVectors(tangent, lateral).normalize();
        const radius = u(radiusCm) * (kind === 'rhizome' || kind === 'runner' ? 1 : 1 - .6 * i / (path.length - 1));
        rings.push(batch.p.length / 3);
        for (let side = 0; side < sides; side++) {
          const angle = side * Math.PI * 2 / sides;
          vertex(batch, [path[i][0] + radius * (lateral.x * Math.cos(angle) + normal.x * Math.sin(angle)),
            path[i][1] + radius * (lateral.y * Math.cos(angle) + normal.y * Math.sin(angle)),
            path[i][2] + radius * (lateral.z * Math.cos(angle) + normal.z * Math.sin(angle))], color, [i / (path.length - 1), side / sides]);
        }
        pathVertices.push(vertex(batch, path[i], color));
        if (i) for (let side = 0; side < sides; side++) {
          const a = rings[i - 1] + side, b = rings[i - 1] + (side + 1) % sides, c = rings[i] + side, d = rings[i] + (side + 1) % sides;
          batch.indices.push(a, b, c, b, d, c);
        }
      }
      for (let side = 0; side < sides; side++) {
        batch.indices.push(pathVertices[0], rings[0] + (side + 1) % sides, rings[0] + side,
          pathVertices.at(-1), rings.at(-1) + side, rings.at(-1) + (side + 1) % sides);
      }
      const result = { id, kind, parentId: parent?.id || null, parentNode, path, pathCm, pathVertices,
        meshName: 'epiphyte-' + batch.name, range: { start, count: batch.p.length / 3 - start }, sites: [] };
      if (createSites) for (let i = 0; i < path.length; i++) {
        const attachment = (kind === 'root' || kind === 'rhizoid') && i === path.length - 1;
        result.sites.push(site(batch, attachment ? pathVertices[i] : rings[i], attachment ? 'attachment' : kind,
          i ? result.sites[i - 1] : parent?.sites[parentNode], radiusCm));
      }
      botany.stems.push(result); return result;
    }
    function attach(parent, node, dx, dz, index) {
      const origin = parent.pathCm[node], end = [origin[0] + dx, 0, origin[2] + dz];
      const path = [origin, [origin[0] + dx * .42, origin[1] * .42, origin[2] + dz * .4], end];
      const root = stem('attachment-' + index, moss ? 'rhizoid' : 'root', path, moss ? .018 : .045, parent, node);
      botany.attachments.push({ rootId: root.id, point: scaled(end), normal: [0, 1, 0] });
    }

    function broadLeaf(parent, parentNode, config) {
      const { pathCm, widthCm, kind, waves = 0, thicknessCm, color, yaw } = config;
      const batch = batches.foliage, start = batch.p.length / 3, path = pathCm.map(scaled), last = path.length - 1;
      const rows = [], base = vertex(batch, path[0], color, [0, .5]);
      let previousSite = parent.sites[parentNode];
      for (let i = 1; i < last; i++) {
        const t = i / last, fullness = Math.pow(Math.sin(Math.PI * t), kind === 'lanceolate' ? .72 : .42);
        tangent.fromArray(path[i + 1]).sub(temp.fromArray(path[i - 1])).normalize();
        lateral.set(-Math.sin(yaw), 0, Math.cos(yaw)); normal.crossVectors(lateral, tangent).normalize();
        const wave = waves ? 1 + .10 * Math.sin(t * Math.PI * 2 * waves) : 1 + .025 * Math.sin(i * 2.7);
        rows.push(batch.p.length / 3);
        for (const skin of [1, -1]) for (const across of [-1, 0, 1]) {
          const side = u(widthCm * .5 * fullness * wave) * across;
          const ridge = u((across === 0 ? .085 : -.025) * fullness + skin * thicknessCm * .5 * fullness);
          const p = [path[i][0] + lateral.x * side + normal.x * ridge,
            path[i][1] + normal.y * ridge, path[i][2] + lateral.z * side + normal.z * ridge];
          const index = vertex(batch, p, color, [t, (across + 1) / 2], skin === 1 ? across === 0 ? 1.07 : .94 : .78);
          if (skin === 1 && across === 0) previousSite = site(batch, index, 'leaf', previousSite, widthCm * fullness * .25);
        }
        if (rows.length === 1) batch.indices.push(base, rows[0] + 1, rows[0], base, rows[0] + 2, rows[0] + 1,
          base, rows[0] + 3, rows[0] + 4, base, rows[0] + 4, rows[0] + 5,
          base, rows[0], rows[0] + 3, base, rows[0] + 5, rows[0] + 2);
        else {
          const a = rows.at(-2), b = rows.at(-1);
          for (let k = 0; k < 2; k++) batch.indices.push(a + k, a + k + 1, b + k, a + k + 1, b + k + 1, b + k,
            a + k + 3, b + k + 3, a + k + 4, a + k + 4, b + k + 3, b + k + 4);
          batch.indices.push(a, b, a + 3, a + 3, b, b + 3, a + 2, a + 5, b + 2, a + 5, b + 5, b + 2);
        }
      }
      const tip = vertex(batch, path.at(-1), color, [1, .5], 1.08), row = rows.at(-1);
      batch.indices.push(row, row + 1, tip, row + 1, row + 2, tip, row + 3, tip, row + 4, row + 4, tip, row + 5,
        row, tip, row + 3, row + 2, row + 5, tip);
      const lengthCm = pathCm.slice(1).reduce((sum, p, i) => sum + new THREE.Vector3(...p).distanceTo(new THREE.Vector3(...pathCm[i])), 0);
      botany.leaves.push({ parentId: parent.id, parentNode, base: path[0], tip: path.at(-1), path,
        kind, lengthCm: lengthCm * growth, widthCm: widthCm * growth, thicknessCm: thicknessCm * growth, edgeWaves: waves,
        meshName: 'epiphyte-foliage', range: { start, count: batch.p.length / 3 - start } });
    }
    function leaflet(parent, node, tipCm, widthCm, kind, color, faceNormal) {
      const batch = batches.foliage, start = batch.p.length / 3, baseCm = parent.pathCm[node];
      const a = new THREE.Vector3(...baseCm), b = new THREE.Vector3(...tipCm), delta = b.clone().sub(a), lengthCm = delta.length();
      lateral.crossVectors(new THREE.Vector3(...faceNormal), delta).normalize().multiplyScalar(widthCm / 2);
      const middle = a.clone().lerp(b, .48), ridge = new THREE.Vector3(...faceNormal).multiplyScalar(widthCm * .14);
      const points = [a, middle.clone().add(lateral), b, middle.clone().sub(lateral), middle.add(ridge)];
      points.forEach((p, i) => vertex(batch, p.toArray().map(u), color, [[0,.5],[.48,0],[1,.5],[.48,1],[.48,.5]][i], i === 4 ? 1.1 : .96));
      batch.indices.push(start, start + 1, start + 4, start + 1, start + 2, start + 4, start + 2, start + 3, start + 4, start + 3, start, start + 4);
      botany.leaves.push({ parentId: parent.id, parentNode: node, base: scaled(baseCm), tip: scaled(tipCm), kind,
        lengthCm: lengthCm * growth, widthCm: widthCm * growth, thicknessCm: 0, meshName: 'epiphyte-foliage', range: { start, count: 5 } });
    }

    if (!moss) {
      const fern = species === 'java-fern', count = fern ? 12 : 13, width = fern ? 7.2 : 4;
      const rhizomePath = Array.from({ length: 7 }, (_, i) => [(i / 6 - .5) * width, fern ? .44 : .29 + .04 * Math.sin(i), .10 * Math.sin(i * 1.1)]);
      const rhizome = stem('main-rhizome', 'rhizome', rhizomePath, fern ? .16 : .12);
      attach(rhizome, 3, -rhizomePath[3][0], -rhizomePath[3][2], 'center');
      for (let i = 0; i < rhizomePath.length; i++) attach(rhizome, i, (i % 2 ? -1 : 1) * (.45 + random() * .3), (i % 2 ? 1 : -1) * (fern ? 1.25 : .8), i);
      for (let i = 0; i < count; i++) {
        const node = i % 7, origin = rhizomePath[node], yaw = i * 2.399 + (random() - .5) * .35;
        const young = i >= count - 2, height = fern ? 1.7 + random() * 1.1 : 1.8 + random() * 1.25;
        const reach = fern ? .55 : .28;
        const petiolePath = Array.from({ length: 5 }, (_, j) => { const t = j / 4; return [origin[0] + Math.cos(yaw) * reach * t * t, origin[1] + height * t, origin[2] + Math.sin(yaw) * reach * t * t]; });
        const petiole = stem('petiole-' + i, 'petiole', petiolePath, fern ? .085 : .07, rhizome, node), base = petiolePath.at(-1);
        const length = fern ? (young ? 7 + random() * 2 : i === 0 ? 16.7 : 12.7 + random() * 3.6) : young ? 2.5 : 4.2 + random() * .8;
        const widthCm = fern ? length * (.13 + random() * .025) : young ? .95 : 1.65 + random() * .3;
        const rise = fern ? length * .92 : length * (.58 + random() * .14), horizontal = fern ? length * (.22 + random() * .12) : length * .79;
        const rows = fern ? 19 : 15, curl = fern ? .085 : .045;
        const pathCm = Array.from({ length: rows + 1 }, (_, j) => { const t = j / rows; return [base[0] + Math.cos(yaw) * horizontal * Math.pow(t, 1.4),
          base[1] + rise * (t - curl * Math.pow(t, 6)), base[2] + Math.sin(yaw) * horizontal * Math.pow(t, 1.4)]; });
        broadLeaf(petiole, 4, { pathCm, widthCm, yaw, thicknessCm: fern ? .025 : .075, waves: fern ? 0 : 4,
          kind: fern ? 'lanceolate' : 'wavy-thick', color: colors[young ? 3 : i % 3] });
      }
    } else {
      const fissidens = species === 'fissidens', count = fissidens ? 14 : 8;
      const main = stem('basal-runner', 'runner', [[-1.3, .12, 0], [0, .12, 0], [1.3, .12, 0]], .035);
      attach(main, 1, 0, 0, 'center');
      for (let i = 0; i < count; i++) {
        const yaw = i * 2.399 + random() * .25, spread = .55 + random() * (fissidens ? 1.05 : 1.5);
        const rootEnd = [Math.cos(yaw) * spread, .12, Math.sin(yaw) * spread];
        const runner = stem('runner-' + i, 'runner', [main.pathCm[1], [rootEnd[0] * .5, .12, rootEnd[2] * .5], rootEnd], .027, main, 1);
        attach(runner, 2, Math.cos(yaw) * .15, Math.sin(yaw) * .15, i);
        if (fissidens) {
          const height = 2.65 + random() * 1.15, reach = .55 + random() * .8, segments = 15;
          const pathCm = Array.from({ length: segments + 1 }, (_, j) => { const t = j / segments; return [rootEnd[0] + Math.cos(yaw) * reach * t * t,
            rootEnd[1] + height * Math.sin(t * Math.PI * .60), rootEnd[2] + Math.sin(yaw) * reach * t * t]; });
          const shoot = stem('feather-' + i, 'feather-shoot', pathCm, .025, runner, 2);
          for (let j = 2; j < segments; j++) for (const sign of [-1, 1]) {
            const t = j / segments, p = pathCm[j], length = (.25 + .15 * Math.sin(Math.PI * t)) * (.9 + random() * .15);
            const across = sign * length * .88, forward = length * .36;
            const tip = [p[0] - Math.sin(yaw) * across + Math.cos(yaw) * forward,
              p[1] + length * .28 - .10 * Math.pow(t, 3), p[2] + Math.cos(yaw) * across + Math.sin(yaw) * forward];
            leaflet(shoot, j, tip, .065, 'distichous-leaflet', colors[(i + j) % 4], [Math.cos(yaw), .28, Math.sin(yaw)]);
          }
        } else {
          const height = 1.65 + random() * .8, reach = 1.65 + random() * .5, segments = 10;
          const pathCm = Array.from({ length: segments + 1 }, (_, j) => { const t = j / segments; return [rootEnd[0] + Math.cos(yaw) * reach * t,
            rootEnd[1] + height * (t - .1 * Math.pow(t, 5)), rootEnd[2] + Math.sin(yaw) * reach * t]; });
          const shoot = stem('christmas-frond-' + i, 'pinnate-frond', pathCm, .028, runner, 2), frond = { stemId: shoot.id, pinnae: [] };
          botany.fronds.push(frond);
          for (let j = 2; j <= 8; j++) {
            const t = j / segments, widthCm = 1.5 * (1 - t) + .08;
            frond.pinnae.push({ node: j, spanCm: widthCm * 2 * growth });
            for (const sign of [-1, 1]) {
              const p = pathCm[j], pinnaYaw = yaw + sign * 1.14;
              const pinnaPath = Array.from({ length: 6 }, (_, k) => { const q = k / 5; return [p[0] + Math.cos(pinnaYaw) * widthCm * q,
                p[1] + .23 * widthCm * Math.sin(q * Math.PI * .7), p[2] + Math.sin(pinnaYaw) * widthCm * q]; });
              const pinna = stem('pinna-' + i + '-' + j + '-' + sign, 'pinna', pinnaPath, .018, shoot, j, false);
              for (let k = 1; k <= 5; k++) for (const side of [-1, 1]) {
                const p = pinnaPath[k], length = .13 + random() * .05, offset = side * length * .75;
                const tip = [p[0] + Math.cos(pinnaYaw) * length * .5 - Math.sin(pinnaYaw) * offset,
                  p[1] + length * .20, p[2] + Math.sin(pinnaYaw) * length * .5 + Math.cos(pinnaYaw) * offset];
                leaflet(pinna, k, tip, .045, 'pinnate-leaflet', colors[(i + j + k) % 4], [0, 1, 0]);
              }
            }
          }
        }
      }
    }

    const pixels = new Uint8Array(16 * 64 * 4);
    for (let y = 0; y < 64; y++) for (let x = 0; x < 16; x++) {
      const hash = (Math.imul(Math.floor(x / 2) + 7, 97) + Math.imul(Math.floor(y / 3) + originalSeed, 37)) >>> 0;
      let value = [221, 232, 239, 228][hash % 4];
      if (x === 7 || x === 8) value += 8;
      if (species === 'bucephalandra' && (x * 31 + y * 17 + originalSeed) % 97 === 0) value = 253;
      pixels.set([value - 3, value, value - 6, 255], (y * 16 + x) * 4);
    }
    const map = new THREE.DataTexture(pixels, 16, 64, THREE.RGBAFormat); map.name = 'epiphyte-original-pixels';
    map.colorSpace = THREE.SRGBColorSpace; map.minFilter = map.magFilter = THREE.NearestFilter; map.generateMipmaps = false; map.needsUpdate = true; maps.push(map);
    const dynamic = [], byName = new Map();
    for (const batch of Object.values(batches)) {
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.Float32BufferAttribute(batch.p, 3)); geometry.setAttribute('color', new THREE.Float32BufferAttribute(batch.color, 3));
      geometry.setAttribute('uv', new THREE.Float32BufferAttribute(batch.uv, 2)); geometry.setIndex(batch.indices);
      geometry.computeVertexNormals(); geometry.computeBoundingBox(); geometry.computeBoundingSphere();
      const material = new THREE.MeshLambertMaterial({ color: 0xffffff, vertexColors: true, flatShading: true, side: THREE.DoubleSide, map: batch.name === 'foliage' ? map : null });
      material.name = 'epiphyte-' + batch.name;
      const mesh = new THREE.Mesh(geometry, material); mesh.name = material.name; mesh.castShadow = mesh.receiveShadow = true;
      mesh.userData = { species, solid: false, hardscape: false, softPlant: true, plantFoliage: batch.name !== 'roots', plantRoots: batch.name === 'roots', epiphyte: true };
      group.add(mesh); geometries.push(geometry); materials.push(material); byName.set(mesh.name, geometry);
      if (batch.name !== 'roots') {
        geometry.attributes.position.setUsage(THREE.DynamicDrawUsage); geometry.attributes.normal.setUsage(THREE.DynamicDrawUsage);
        dynamic.push({ geometry, rest: geometry.attributes.position.array.slice() });
      }
    }
    const restBounds = new THREE.Box3().setFromObject(group), height = restBounds.max.y;
    const amplitude = u(species === 'java-fern' ? 1.6 : species === 'bucephalandra' ? .38 : .22), pinned = u(moss ? .20 : .70);
    group.userData = { species, botanical: references[species].botanical, seed: originalSeed, cmPerUnit, growth, epiphyte: true, softPlant: true, botany,
      source: { ...references[species], heightCm: references[species].heightCm.slice() },
      placement: { kind: 'attached-hardscape', anchor: [0, 0, 0], normal: [0, 1, 0], buryRhizome: false, mountIncluded: false,
        footprintCm: [restBounds.min.x * cmPerUnit, restBounds.min.z * cmPerUnit, restBounds.max.x * cmPerUnit, restBounds.max.z * cmPerUnit] },
      dimensions: { status: 'authored-with-botanical-reference', sizeCm: restBounds.getSize(new THREE.Vector3()).multiplyScalar(cmPerUnit).toArray(),
        boundsCm: { min: restBounds.min.clone().multiplyScalar(cmPerUnit).toArray(), max: restBounds.max.clone().multiplyScalar(cmPerUnit).toArray() },
        maxFlowDisplacementCm: amplitude * cmPerUnit },
    };
    const inverse = new THREE.Matrix4(), samplePoint = new THREE.Vector3(), flowVector = new THREE.Vector3();
    function refreshContacts() {
      for (const contact of grazeSites) {
        const geometry = byName.get(contact.meshName), p = geometry.attributes.position, n = geometry.attributes.normal;
        contact.position[0] = p.getX(contact.vertex); contact.position[1] = p.getY(contact.vertex); contact.position[2] = p.getZ(contact.vertex);
        normal.fromBufferAttribute(n, contact.vertex);
        if (contact.kind === 'attachment' || normal.lengthSq() < 1e-8) normal.set(0, 1, 0); else normal.normalize();
        contact.normal[0] = normal.x; contact.normal[1] = normal.y; contact.normal[2] = normal.z;
      }
    }
    refreshContacts();
    function update(time, flow) {
      if (!Number.isFinite(time)) return;
      group.updateWorldMatrix(true, false); samplePoint.set(0, height * .65, 0).applyMatrix4(group.matrixWorld);
      const sample = typeof flow?.sample === 'function' ? flow.sample(samplePoint.x, samplePoint.y, samplePoint.z, time) : flow;
      const valid = sample && [sample.x, sample.y, sample.z, sample.strength].every(Number.isFinite);
      const strength = valid ? Math.max(0, Math.min(1, sample.strength)) : 0;
      flowVector.set(valid ? sample.x : 0, valid ? sample.y : 0, valid ? sample.z : 0);
      inverse.copy(group.matrixWorld).invert(); flowVector.transformDirection(inverse);
      for (const batch of dynamic) {
        const position = batch.geometry.attributes.position.array;
        for (let i = 0; i < position.length; i += 3) {
          const h = batch.rest[i + 1], t = Math.max(0, Math.min(1, (h - pinned) / Math.max(.0001, height - pinned)));
          const sway = amplitude * strength * t * t * (.88 + .12 * Math.sin(time * 1.15 + h / factor * .19 + originalSeed * .017));
          position[i] = batch.rest[i] + flowVector.x * sway;
          position[i + 1] = h + flowVector.y * sway * .08;
          position[i + 2] = batch.rest[i + 2] + flowVector.z * sway;
        }
        batch.geometry.attributes.position.needsUpdate = true; batch.geometry.computeVertexNormals(); batch.geometry.computeBoundingBox(); batch.geometry.computeBoundingSphere();
      }
      refreshContacts();
    }
    return { group, geometries, materials, maps, grazeSites, update };
  }
  return { create };
});
