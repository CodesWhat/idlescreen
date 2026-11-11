(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumDesignerPlacement = factory();
})(globalThis, function () {
  'use strict';
  const DEFAULT_CM = 36 / 8.4, EPS = 1e-7, MAX_INSTANCES = 24;
  const definitions = [
    ['frogbit', 'floating', 'floating'], ['salvinia-minima', 'floating', 'floating'],
    ['red-root-floater', 'floating', 'floating'], ['tiger-lotus', 'floating', 'rooted'],
    ['java-fern', 'epiphyte', 'attached'], ['bucephalandra', 'epiphyte', 'attached'],
    ['fissidens', 'epiphyte', 'attached'], ['christmas-moss', 'epiphyte', 'attached'],
    ['cryptocoryne', 'rooted', 'rooted'], ['staurogyne', 'rooted', 'rooted'],
    ['rotala', 'rooted', 'rooted'], ['compact-sword', 'rooted', 'rooted'],
    ['manzanita', 'manzanita', 'hardscape'], ['moss-rock', 'mossRock', 'hardscape'], ['dragon-driftwood', 'dragon', 'hardscape']
  ];
  const catalog = Object.freeze(definitions.map(d => d[0]));
  const descriptions = new Map(definitions.map(d => [d[0], { family: d[1], placement: d[2] }]));

  function create(THREE, options = {}) {
    const { factories, cmPerUnit = DEFAULT_CM, tankHalf = 7, backZ = -4.36, frontZ = 4.04,
      bedLevel = 1.1667, waterLevel = 8.05, solids = [], mountSolids = solids } = options;
    if (!factories || ![cmPerUnit, tankHalf, backZ, frontZ, bedLevel, waterLevel].every(Number.isFinite)
      || cmPerUnit <= 0 || tankHalf <= 0 || frontZ <= backZ || bedLevel <= .6 / cmPerUnit || waterLevel <= bedLevel) {
      throw new RangeError('Invalid designer factories or physical bounds');
    }
    const group = new THREE.Group(); group.name = 'designer-placement';
    const geometries = [], materials = [], maps = [], validSolids = [];
    const resources = new Map(), centerZ = (backZ + frontZ) / 2, glass = .6 / cmPerUnit;
    const panes = [-tankHalf + glass, tankHalf - glass, backZ + glass, frontZ - glass];
    let records = [], disposed = false;
    const point = new THREE.Vector3(), tri = new THREE.Triangle();
    const vertices = Array.from({ length: 6 }, () => new THREE.Vector3());
    const edges = Array.from({ length: 6 }, () => new THREE.Vector3());
    const normals = [new THREE.Vector3(), new THREE.Vector3()], axis = new THREE.Vector3();
    const ray = new THREE.Ray(), rayPoint = new THREE.Vector3(), normal = new THREE.Vector3();
    const parityDirection = new THREE.Vector3(.917, .337, .211).normalize();
    const geometryTopology = new WeakMap();

    function boundsEmpty() { return [Infinity, Infinity, Infinity, -Infinity, -Infinity, -Infinity]; }
    function union(a, b) { for (let k = 0; k < 3; k++) { a[k] = Math.min(a[k], b[k]); a[k + 3] = Math.max(a[k + 3], b[k + 3]); } return a; }
    function overlaps(a, b) { return a[0] <= b[3] + EPS && a[3] + EPS >= b[0] && a[1] <= b[4] + EPS && a[4] + EPS >= b[1] && a[2] <= b[5] + EPS && a[5] + EPS >= b[2]; }
    function contains(b, p) { return p.x >= b[0] - EPS && p.x <= b[3] + EPS && p.y >= b[1] - EPS && p.y <= b[4] + EPS && p.z >= b[2] - EPS && p.z <= b[5] + EPS; }
    function vertex(data, id, out) { return out.fromArray(data.points, id * 3); }
    function triangle(data, id, out) {
      const at = id * 3; vertex(data, data.indices[at], out.a); vertex(data, data.indices[at + 1], out.b); vertex(data, data.indices[at + 2], out.c); return out;
    }
    function triangleBounds(data, id) {
      const b = data.triangleBounds[id] || boundsEmpty(); b[0] = b[1] = b[2] = Infinity; b[3] = b[4] = b[5] = -Infinity;
      for (let j = 0; j < 3; j++) { const at = data.indices[id * 3 + j] * 3; for (let k = 0; k < 3; k++) { const n = data.points[at + k]; b[k] = Math.min(b[k], n); b[k + 3] = Math.max(b[k + 3], n); } }
      return b;
    }
    function buildTree(data, ids) {
      const box = boundsEmpty(); for (const id of ids) union(box, data.triangleBounds[id]);
      if (ids.length <= 10) return { box, ids };
      let k = 0; if (box[4] - box[1] > box[3] - box[0]) k = 1; if (box[5] - box[2] > box[k + 3] - box[k]) k = 2;
      ids.sort((a, b) => (data.triangleBounds[a][k] + data.triangleBounds[a][k + 3]) - (data.triangleBounds[b][k] + data.triangleBounds[b][k + 3]));
      const middle = Math.floor(ids.length / 2);
      return { box, left: buildTree(data, ids.slice(0, middle)), right: buildTree(data, ids.slice(middle)) };
    }
    function refitTree(data, node) {
      node.box[0] = node.box[1] = node.box[2] = Infinity; node.box[3] = node.box[4] = node.box[5] = -Infinity;
      if (node.ids) for (const id of node.ids) union(node.box, data.triangleBounds[id]);
      else { union(node.box, refitTree(data, node.left)); union(node.box, refitTree(data, node.right)); }
      return node.box;
    }
    function topology(geometry, indices) {
      if (geometryTopology.has(geometry)) return geometryTopology.get(geometry);
      const p = geometry.attributes.position, weld = new Map(), welded = [], representatives = [], parents = [], edgeCounts = new Map();
      function find(i) { while (parents[i] !== i) { parents[i] = parents[parents[i]]; i = parents[i]; } return i; }
      for (let i = 0; i < p.count; i++) {
        const key = [p.getX(i), p.getY(i), p.getZ(i)].map(n => Math.round(n * 1e6)).join(',');
        let id = weld.get(key); if (id === undefined) { id = parents.length; weld.set(key, id); parents.push(id); representatives.push(i); } welded.push(id);
      }
      for (let i = 0; i < indices.length; i += 3) {
        const ids = [welded[indices[i]], welded[indices[i + 1]], welded[indices[i + 2]]];
        if (new Set(ids).size < 3) continue;
        for (let j = 0; j < 3; j++) { const a = ids[j], b = ids[(j + 1) % 3]; parents[find(a)] = find(b); const key = Math.min(a, b) + ':' + Math.max(a, b); edgeCounts.set(key, (edgeCounts.get(key) || 0) + 1); }
      }
      const components = new Map(); for (const id of welded) components.set(find(id), representatives[id]);
      const closedComponents = new Set(components.keys());
      for (const [edge, count] of edgeCounts) if (count < 2 || count % 2) closedComponents.delete(find(Number(edge.split(':')[0])));
      const triangleComponents = Uint32Array.from({ length: indices.length / 3 }, (_, i) => find(welded[indices[i * 3]]));
      const result = { closed: closedComponents.size > 0, closedComponents, triangleComponents, representatives: [...components.values()] };
      geometryTopology.set(geometry, result); return result;
    }
    function meshData(mesh) {
      if (mesh.isInstancedMesh || mesh.isSkinnedMesh) throw new TypeError('Designer placement requires ordinary static triangle meshes');
      const p = mesh.geometry?.attributes?.position, index = mesh.geometry?.index;
      if (!p || p.count < 3 || (index ? index.count : p.count) % 3 !== 0) throw new TypeError('Designer mesh needs complete triangles');
      const count = index ? index.count : p.count;
      if (count > 300000) throw new RangeError('Designer mesh exceeds 100000 triangle budget');
      const indices = Uint32Array.from({ length: count }, (_, i) => index ? index.getX(i) : i);
      if (indices.some(i => i >= p.count)) throw new TypeError('Designer mesh has an invalid index');
      const data = { mesh, points: new Float64Array(p.count * 3), indices, triangleBounds: [], tree: null, topology: topology(mesh.geometry, indices) };
      refresh(data); ensureTree(data); return data;
    }
    function refresh(data) {
      const p = data.mesh.geometry.attributes.position, matrix = data.mesh.matrixWorld.elements;
      if (p.count * 3 !== data.points.length) throw new TypeError('Designer updates must preserve geometry topology');
      if (p.version === data.version && data.matrix?.every((n, i) => n === matrix[i])) return;
      data.box = boundsEmpty(); data.version = p.version; data.matrix = matrix.slice(); data.dirty = true;
      for (let i = 0; i < p.count; i++) {
        point.fromBufferAttribute(p, i).applyMatrix4(data.mesh.matrixWorld);
        if (!Number.isFinite(point.x) || !Number.isFinite(point.y) || !Number.isFinite(point.z)) throw new TypeError('Non-finite designer geometry');
        point.toArray(data.points, i * 3);
        data.box[0] = Math.min(data.box[0], point.x); data.box[1] = Math.min(data.box[1], point.y); data.box[2] = Math.min(data.box[2], point.z);
        data.box[3] = Math.max(data.box[3], point.x); data.box[4] = Math.max(data.box[4], point.y); data.box[5] = Math.max(data.box[5], point.z);
      }
    }
    function ensureTree(data) {
      if (!data.dirty) return;
      for (let i = 0; i < data.indices.length / 3; i++) data.triangleBounds[i] = triangleBounds(data, i);
      if (data.tree) refitTree(data, data.tree);
      else data.tree = buildTree(data, Array.from({ length: data.indices.length / 3 }, (_, i) => i));
      data.dirty = false;
    }
    function separated(testAxis) {
      if (testAxis.lengthSq() < 1e-20) return false;
      let a0 = Infinity, a1 = -Infinity, b0 = Infinity, b1 = -Infinity;
      for (let i = 0; i < 3; i++) { const a = vertices[i].dot(testAxis), b = vertices[i + 3].dot(testAxis); a0 = Math.min(a0, a); a1 = Math.max(a1, a); b0 = Math.min(b0, b); b1 = Math.max(b1, b); }
      const margin = EPS * Math.sqrt(testAxis.lengthSq()); return a1 < b0 - margin || b1 < a0 - margin;
    }
    function trianglesIntersect(a, ai, b, bi) {
      for (let i = 0; i < 3; i++) { vertex(a, a.indices[ai * 3 + i], vertices[i]); vertex(b, b.indices[bi * 3 + i], vertices[i + 3]); }
      for (let i = 0; i < 3; i++) { edges[i].subVectors(vertices[(i + 1) % 3], vertices[i]); edges[i + 3].subVectors(vertices[3 + (i + 1) % 3], vertices[i + 3]); }
      normals[0].crossVectors(edges[0], edges[1]); normals[1].crossVectors(edges[3], edges[4]);
      if (normals[0].lengthSq() < 1e-20 || normals[1].lengthSq() < 1e-20) return false;
      if (separated(normals[0]) || separated(normals[1])) return false;
      for (let i = 0; i < 3; i++) for (let j = 3; j < 6; j++) if (separated(axis.crossVectors(edges[i], edges[j]))) return false;
      // In-plane edge normals also separate coplanar faces; edge cross-products alone cannot.
      for (let i = 0; i < 6; i++) if (separated(axis.crossVectors(normals[i < 3 ? 0 : 1], edges[i]))) return false;
      return true;
    }
    function treeIntersection(a, an, b, bn) {
      if (!overlaps(an.box, bn.box)) return false;
      if (an.ids && bn.ids) { for (const ai of an.ids) for (const bi of bn.ids) if (overlaps(a.triangleBounds[ai], b.triangleBounds[bi]) && trianglesIntersect(a, ai, b, bi)) return true; return false; }
      if (!an.ids) return treeIntersection(a, an.left, b, bn) || treeIntersection(a, an.right, b, bn);
      return treeIntersection(a, an, b, bn.left) || treeIntersection(a, an, b, bn.right);
    }
    function rayBox(box) {
      let near = 0, far = Infinity;
      for (let k = 0; k < 3; k++) {
        const origin = ray.origin.getComponent(k), direction = ray.direction.getComponent(k);
        if (Math.abs(direction) < 1e-12) { if (origin < box[k] - EPS || origin > box[k + 3] + EPS) return false; }
        else { const a = (box[k] - origin) / direction, b = (box[k + 3] - origin) / direction; near = Math.max(near, Math.min(a, b)); far = Math.min(far, Math.max(a, b)); if (far < near - EPS) return false; }
      }
      return true;
    }
    function rayHits(data, node, hits, upwardOnly, components = false) {
      if (!rayBox(node.box)) return;
      if (!node.ids) { rayHits(data, node.left, hits, upwardOnly, components); rayHits(data, node.right, hits, upwardOnly, components); return; }
      for (const id of node.ids) {
        triangle(data, id, tri); tri.getNormal(normal);
        if (upwardOnly && normal.y < .5) continue;
        if (ray.intersectTriangle(tri.a, tri.b, tri.c, false, rayPoint)) { const distance = rayPoint.distanceTo(ray.origin); if (distance > EPS) hits.push(components ? { distance, component: data.topology.triangleComponents[id] } : distance); }
      }
    }
    function inside(data, position) {
      if (!data.topology.closed || !contains(data.box, position)) return false;
      ensureTree(data);
      ray.set(position, parityDirection); const hits = []; rayHits(data, data.tree, hits, false, true); hits.sort((a, b) => a.distance - b.distance);
      const counts = new Map(), previous = new Map();
      for (const { distance, component } of hits) if (data.topology.closedComponents.has(component) && distance - (previous.get(component) ?? -Infinity) > 1e-6) {
        counts.set(component, (counts.get(component) || 0) + 1); previous.set(component, distance);
      }
      return [...counts.values()].some(count => count % 2 === 1);
    }
    function meshesIntersect(a, b) {
      if (!overlaps(a.box, b.box)) return false;
      ensureTree(a); ensureTree(b);
      if (treeIntersection(a, a.tree, b, b.tree)) return true;
      for (const id of a.topology.representatives) if (inside(b, vertex(a, id, point))) return true;
      for (const id of b.topology.representatives) if (inside(a, vertex(b, id, point))) return true;
      return false;
    }
    const crownBox = new THREE.Box3();
    function boxIntersects(data, box, node = data.tree) {
      if (!overlaps(node.box, box)) return false;
      if (!node.ids) return boxIntersects(data, box, node.left) || boxIntersects(data, box, node.right);
      crownBox.min.set(box[0], box[1], box[2]); crownBox.max.set(box[3], box[4], box[5]);
      for (const id of node.ids) if (overlaps(data.triangleBounds[id], box) && crownBox.intersectsTriangle(triangle(data, id, tri))) return true;
      return false;
    }
    function crownIntersects(data, box) {
      if (!overlaps(data.box, box)) return false;
      ensureTree(data);
      if (boxIntersects(data, box)) return true;
      if (inside(data, point.set((box[0] + box[3]) / 2, (box[1] + box[4]) / 2, (box[2] + box[5]) / 2))) return true;
      return data.topology.representatives.some(id => contains(box, vertex(data, id, point)));
    }
    function collectMeshes(objects) {
      const result = new Set();
      for (const object of objects) {
        if (!object) continue;
        if (object.isMesh) result.add(object);
        else if (object.traverse) object.traverse(m => { if (m.isMesh && m.userData.solid) result.add(m); });
        else throw new TypeError('Solids must be Three mesh or group references');
      }
      return [...result];
    }
    function mountEligible(mesh) { const d = mesh.userData || {}; return (d.hardscape || d.climbable) && !d.equipmentSolid && !d.hardEquipment; }
    // Collision capture meshes carry matrixWorld without matching local transforms. Never update them.
    const externalMeshes = [...new Set([...collectMeshes(solids), ...collectMeshes(mountSolids)])];
    const external = externalMeshes.map(meshData), allowedMounts = new Set(collectMeshes(mountSolids).filter(mountEligible));
    const externalMounts = external.filter(d => allowedMounts.has(d.mesh));

    function acquire(record, resource, type) {
      if (!resource || record.resources.has(resource)) return;
      if (typeof resource.dispose !== 'function') throw new TypeError('Factory resources must be disposable');
      record.resources.add(resource); const existing = resources.get(resource);
      if (existing) existing.count++; else resources.set(resource, { count: 1, type });
    }
    function release(record) {
      for (const resource of record.resources) { const entry = resources.get(resource); if (--entry.count === 0) { resources.delete(resource); resource.dispose(); } }
      record.resources.clear(); record.object?.removeFromParent();
    }
    function syncResources() {
      geometries.length = materials.length = maps.length = 0;
      for (const [resource, entry] of resources) ({ geometry: geometries, material: materials, map: maps })[entry.type].push(resource);
    }
    function own(record) {
      for (const [key, type] of [['geometries', 'geometry'], ['materials', 'material'], ['maps', 'map']]) for (const resource of record.asset?.[key] || []) acquire(record, resource, type);
      record.object?.traverse?.(mesh => {
        if (!mesh.isMesh) return;
        acquire(record, mesh.geometry, 'geometry');
        for (const material of Array.isArray(mesh.material) ? mesh.material : [mesh.material]) {
          acquire(record, material, 'material');
          for (const value of Object.values(material)) if (value?.isTexture) acquire(record, value, 'map');
        }
      });
    }
    function seedFor(id, assetId) { let n = 2166136261; for (const c of id + ':' + assetId) n = Math.imul(n ^ c.charCodeAt(0), 16777619); return n >>> 0; }
    function normalize(layout) {
      const list = Array.isArray(layout) ? layout : layout?.instances;
      if (!Array.isArray(list) || list.length > MAX_INSTANCES) throw new RangeError('Designer layout requires an array of at most 24 instances');
      const seen = new Set();
      return list.map(item => {
        if (typeof item?.id !== 'string' || !item.id.length || seen.has(item.id)) throw new TypeError('Designer instance id must be unique and nonempty');
        seen.add(item.id); const definition = descriptions.get(item.assetId);
        if (!definition) throw new RangeError('Unknown designer catalog asset: ' + item.assetId);
        const p = item.positionCm, rotationY = item.rotationY ?? 0;
        if (!p || ![p.x, p.y, p.z, rotationY].every(Number.isFinite)) throw new TypeError('Designer positionCm and rotationY must be finite');
        const factory = factories[definition.family]; if (typeof factory !== 'function' && typeof factory?.create !== 'function') throw new TypeError('Missing factory for ' + definition.family);
        return { id: item.id, assetId: item.assetId, positionCm: { x: p.x, y: p.y, z: p.z }, rotationY, ...definition };
      });
    }
    function createRecord(input) {
      const factory = factories[input.family], config = { species: input.assetId, seed: seedFor(input.id, input.assetId), cmPerUnit, growth: 1, waterColumnCm: (waterLevel - bedLevel) * cmPerUnit };
      const asset = typeof factory === 'function' ? factory(THREE, config) : factory.create(THREE, config);
      const object = asset?.group;
      if (object?.parent) throw new TypeError('Factory must return a fresh unparented group');
      const record = { ...input, asset, object, sites: [], resources: new Set(), meshStates: [], meshes: [], ghostMaterials: new Map(), valid: false, reason: '' };
      try {
        own(record);
        if (!object?.isObject3D) throw new TypeError('Factory must return a fresh unparented group');
        object.name = 'designer-' + input.id; object.userData.designerId = input.id; object.userData.assetId = input.assetId;
        object.position.set(input.positionCm.x / cmPerUnit, input.placement === 'floating' ? waterLevel : bedLevel, centerZ + input.positionCm.z / cmPerUnit);
        object.rotation.set(0, input.rotationY, 0);
        if (input.placement === 'hardscape' && input.family !== 'dragon') object.scale.multiplyScalar(DEFAULT_CM / cmPerUnit);
        object.updateMatrixWorld(true);
        object.traverse(mesh => {
          if (!mesh.isMesh) return;
          if (record.meshes.length >= 64) throw new RangeError('Designer asset exceeds 64 mesh budget');
          record.meshStates.push({ mesh, material: mesh.material, castShadow: mesh.castShadow, solid: mesh.userData.solid, hardscape: mesh.userData.hardscape, climbable: mesh.userData.climbable, equipmentSolid: mesh.userData.equipmentSolid, hardEquipment: mesh.userData.hardEquipment });
          record.meshes.push(meshData(mesh)); mesh.userData.designerId = input.id;
        });
        if (input.placement !== 'hardscape') for (const [i, localSite] of (asset.grazeSites || []).entries()) {
          const prefix = 'designer-' + input.id.length + ':' + input.id + ':';
          record.sites.push({ localSite, worldSite: { id: prefix + (localSite.id ?? i), position: [0, 0, 0], rest: [0, 0, 0], normal: [0, 1, 0], links: (localSite.links || []).map(id => prefix + id), kind: 'foliage', habitat: localSite.habitat } });
        }
        if (!record.meshes.length) throw new TypeError('Designer asset must contain visible mesh geometry');
        if (record.meshes.reduce((sum, data) => sum + data.indices.length / 3, 0) > 100000) throw new RangeError('Designer asset exceeds 100000 triangle budget');
        return record;
      } catch (error) { release(record); throw error; }
    }
    function placeMount(record, mounts) {
      const p = record.object.position; let height = -Infinity, mount = null;
      for (const data of mounts) {
        ensureTree(data);
        ray.set(point.set(p.x, waterLevel + .75 / cmPerUnit, p.z), normal.set(0, -1, 0)); const hits = [];
        rayHits(data, data.tree, hits, true);
        for (const distance of hits) { const y = waterLevel + .75 / cmPerUnit - distance; if (y > height && y >= bedLevel - EPS && y < waterLevel) { height = y; mount = data; } }
      }
      record.mount = mount;
      if (mount) { p.y = height + .002; record.object.updateMatrixWorld(true); record.meshes.forEach(refresh); }
      return !!mount;
    }
    function boundsReason(record) {
      for (const data of record.meshes) {
        const b = data.box;
        if (b[0] < panes[0] - EPS || b[3] > panes[1] + EPS || b[2] < panes[2] - EPS || b[5] > panes[3] + EPS) return 'Geometry crosses an inner glass pane';
        if (b[1] < glass - EPS) return 'Roots or geometry cross the tank bottom';
        const crownBlend = record.placement === 'rooted' && !data.mesh.userData.plantFoliage ? .1 / cmPerUnit : 0;
        if (!['floating', 'buried-hardscape'].includes(record.placement) && !data.mesh.userData.plantRoots && b[1] < bedLevel - crownBlend - EPS) return 'Above-bed geometry penetrates the substrate';
        if (record.placement === 'floating' && b[1] < bedLevel - EPS) return 'Floating roots reach below the substrate surface';
        if (record.placement === 'rooted' && data.mesh.userData.plantRoots && b[4] > bedLevel + crownBlend + EPS) return 'Root geometry extends above its bed anchor';
        if (b[4] > waterLevel + (record.placement === 'floating' ? .75 / cmPerUnit : 0) + EPS) return 'Geometry exceeds the water level or floating leaf headroom';
      }
      return '';
    }
    function collisionReason(record, obstacles) {
      for (const candidate of record.meshes) for (const obstacle of obstacles) if (meshesIntersect(candidate, obstacle)) return 'Geometry collision with a hard solid';
      if (record.placement === 'rooted') {
        const p = record.object.position, radius = .35 / cmPerUnit;
        const box = [p.x - radius, bedLevel - .15 / cmPerUnit, p.z - radius, p.x + radius, bedLevel + .5 / cmPerUnit, p.z + radius];
        for (const obstacle of obstacles) if (crownIntersects(obstacle, box)) return 'Root crown lacks clearance from a hard solid';
      }
      return '';
    }
    function ghostMaterial(record, material) {
      if (record.ghostMaterials.has(material)) return record.ghostMaterials.get(material);
      const ghost = material.clone(); if (ghost.color) ghost.color.setHex(0xff2525);
      if (ghost.emissive) ghost.emissive.setHex(0x350000);
      ghost.map = null; ghost.vertexColors = false; ghost.transparent = true; ghost.opacity = .34; ghost.depthWrite = false; ghost.alphaTest = 0;
      record.ghostMaterials.set(material, ghost); acquire(record, ghost, 'material'); return ghost;
    }
    function style(record) {
      record.object.userData.valid = record.valid; record.object.userData.designerCollision = record.valid && record.placement === 'hardscape';
      for (const state of record.meshStates) {
        const mesh = state.mesh; mesh.userData.designerCollision = record.valid && record.placement === 'hardscape' && !!state.solid;
        for (const key of ['solid', 'hardscape', 'climbable']) mesh.userData[key] = record.valid ? state[key] : false;
        mesh.castShadow = record.valid ? state.castShadow : false;
        mesh.material = record.valid ? state.material : Array.isArray(state.material) ? state.material.map(m => ghostMaterial(record, m)) : ghostMaterial(record, state.material);
      }
    }
    function validate(list) {
      const obstacles = external.slice(), mounts = externalMounts.slice();
      for (const record of [...list.filter(r => r.placement === 'hardscape'), ...list.filter(r => r.placement !== 'hardscape')]) {
        record.reason = record.placement === 'attached' && !placeMount(record, mounts) ? 'No eligible wood or rock mount below the anchor' : boundsReason(record) || collisionReason(record, obstacles);
        record.valid = !record.reason;
        if (record.valid && record.placement === 'hardscape') {
          for (let i = 0; i < record.meshes.length; i++) if (record.meshStates[i].solid) { obstacles.push(record.meshes[i]); if (mountEligible({ userData: record.meshStates[i] })) mounts.push(record.meshes[i]); }
        }
        style(record);
      }
    }
    function syncSolids() {
      validSolids.length = 0;
      for (const record of records) if (record.valid && record.placement === 'hardscape') for (const state of record.meshStates) if (state.solid) validSolids.push(state.mesh);
    }
    const contactPoint = new THREE.Vector3(), contactNormal = new THREE.Vector3(), contactNormalMatrix = new THREE.Matrix3();
    function syncContacts(initialize = false) {
      group.updateMatrixWorld(true);
      for (const record of records) {
        record.object.updateMatrixWorld(true); contactNormalMatrix.getNormalMatrix(record.object.matrixWorld);
        for (const { localSite, worldSite } of record.sites) {
          contactPoint.fromArray(localSite.position || localSite.rest).applyMatrix4(record.object.matrixWorld).toArray(worldSite.position);
          contactNormal.fromArray(localSite.normal || [0, 1, 0]).applyNormalMatrix(contactNormalMatrix).toArray(worldSite.normal);
          if (initialize) contactPoint.fromArray(localSite.rest || localSite.position).applyMatrix4(record.object.matrixWorld).toArray(worldSite.rest);
        }
      }
    }
    function setLayout(layout) {
      if (disposed) throw new Error('Designer placement is disposed');
      const normalized = normalize(layout), staged = [];
      try {
        let triangles = 0;
        for (const input of normalized) { const record = createRecord(input); staged.push(record); triangles += record.meshes.reduce((sum, data) => sum + data.indices.length / 3, 0); if (triangles > 600000) throw new RangeError('Designer layout exceeds 600000 triangle budget'); }
        validate(staged);
      }
      catch (error) { staged.forEach(release); syncResources(); throw error; }
      const old = records; records = staged;
      for (const record of old) record.object.removeFromParent();
      for (const record of records) group.add(record.object);
      old.forEach(release); syncResources(); syncSolids(); syncContacts(true); return status();
    }
    function status() {
      return records.map(record => ({ id: record.id, assetId: record.assetId, valid: record.valid, reason: record.reason,
        positionCm: { x: record.object.position.x * cmPerUnit, y: record.object.position.y * cmPerUnit, z: (record.object.position.z - centerZ) * cmPerUnit }, rotationY: record.rotationY }));
    }
    function setEnvironment({ solids: nextSolids, mountSolids: nextMounts = nextSolids }) {
      if (disposed) throw new Error('Designer placement is disposed');
      const nextMeshes = [...new Set([...collectMeshes(nextSolids), ...collectMeshes(nextMounts)])];
      const prepared = nextMeshes.map(meshData), eligible = new Set(collectMeshes(nextMounts).filter(mountEligible));
      external.splice(0, external.length, ...prepared);
      externalMounts.splice(0, externalMounts.length, ...prepared.filter(data => eligible.has(data.mesh)));
      group.updateMatrixWorld(true); validate(records); syncResources(); syncSolids(); syncContacts(true);
      return status();
    }
    function inspectObject(object, { solids: obstacles = [], placement = 'transform' } = {}) {
      if (disposed) throw new Error('Designer placement is disposed');
      if (!object?.isObject3D) throw new TypeError('Existing object must contain scene geometry');
      object.updateWorldMatrix(true, true);
      const meshes = [];
      object.traverseVisible(mesh => {
        if (mesh.isMesh && !mesh.userData.contactShadow) meshes.push(meshData(mesh));
      });
      if (!meshes.length) return { valid: false, reason: 'Object has no visible geometry' };
      if (meshes.reduce((sum, data) => sum + data.indices.length / 3, 0) > 100000) throw new RangeError('Existing object exceeds 100000 triangle budget');
      const record = { object, meshes, placement };
      const reason = boundsReason(record) || collisionReason(record, collectMeshes(obstacles).map(meshData));
      return { valid: !reason, reason };
    }
    function update(time, flow) {
      if (disposed) return;
      if (!Number.isFinite(time)) throw new TypeError('Designer animation time must be finite');
      group.updateMatrixWorld(true);
      for (const record of records) { record.asset.update?.(time, flow); record.object.updateMatrixWorld(true); record.meshes.forEach(refresh); }
      validate(records); syncResources(); syncSolids(); syncContacts();
    }
    function dispose() {
      if (disposed) return; disposed = true; records.forEach(release); records = []; syncResources(); validSolids.length = 0;
    }
    return { group, geometries, materials, maps, validSolids, get plants() { return records.filter(record => record.valid && record.placement !== 'hardscape'); }, setEnvironment, inspectObject, setLayout, get status() { return status(); }, update, dispose };
  }
  return { create, catalog, maxInstances: MAX_INSTANCES };
});
