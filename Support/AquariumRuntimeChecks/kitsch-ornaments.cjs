'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const THREE = require('../../Sources/IdleScreenRenderer/Resources/AquariumRuntime/vendor/three.min.js');
const collisions = require('../../Sources/IdleScreenRenderer/Resources/AquariumRuntime/collisions.js');
const source = path.join(__dirname, '../../Sources/IdleScreenRenderer/Resources/AquariumRuntime/kitsch-ornaments-v1.js');
const kinds = ['pirate-chest', 'wreck', 'diver-helmet'], cm = 36 / 8.4;
function api() { assert.ok(fs.existsSync(source), 'original three-ornament factory required'); return require(source); }
function create(kind, options = {}) { return api().create(THREE, { kind, ...options }); }
function meshes(asset) { const out = []; asset.group.traverse(o => { if (o.isMesh) out.push(o); }); return out; }
function near(a, b, label) { assert.ok(Math.abs(a - b) < 4e-5, `${label}: ${a} != ${b}`); }
function box(asset) { return new THREE.Box3().setFromObject(asset.group); }
function triangles(asset) {
  const out = [];
  for (const mesh of meshes(asset)) {
    const p = mesh.geometry.attributes.position;
    for (let i = 0; i < p.count; i += 3) out.push(new THREE.Triangle(...[0, 1, 2].map(j => new THREE.Vector3().fromBufferAttribute(p, i + j))));
  }
  return out;
}

test('exactly the queued three original kinds expose authored centimeter envelopes and grounded support', () => {
  assert.deepEqual(api().kinds, kinds);
  for (const kind of kinds) {
    const asset = create(kind), d = api().descriptors[kind], size = box(asset).getSize(new THREE.Vector3()).multiplyScalar(cm);
    assert.equal(asset.group.name, kind); assert.equal(d.dimensionBasis, 'authored'); assert.equal(d.researchedProductDimensionsCm, null);
    assert.equal(d.defaultPlacement, false); assert.equal(d.reviewOnly, true); assert.deepEqual(d.tankExteriorCm, [60, 36, 36]);
    for (const [index, axis] of ['x', 'y', 'z'].entries()) {
      near(size[axis], asset.dimensionsCm[axis], kind + ' measured ' + axis);
      assert.ok(size[axis] <= d.authoredEnvelopeLimitCm[index] && size[axis] > d.authoredEnvelopeLimitCm[index] * .6, kind + ' authored envelope');
    }
    near(box(asset).min.y, 0, kind + ' ground'); assert.ok(size.y < 29.5);
    assert.ok(asset.groundContacts.length >= 3); asset.group.updateMatrixWorld(true);
    for (const contact of asset.groundContacts) {
      near(contact.position[1], 0, contact.id);
      const p = new THREE.Vector3(...contact.position);
      const hit = new THREE.Raycaster(p.clone().add(new THREE.Vector3(0, -.1, 0)), new THREE.Vector3(0, 1, 0), 0, .2).intersectObjects(meshes(asset))[0];
      assert.ok(hit, contact.id + ' contacts real geometry'); near(hit.point.y, 0, contact.id);
    }
  }
});

test('each rendered component is finite, closed and outward wound, including hollow shell and cutout walls', () => {
  for (const kind of kinds) {
    const asset = create(kind), rendered = meshes(asset); assert.ok(asset.components.length >= 8);
    assert.equal(new Set(asset.components.map(c => c.id)).size, asset.components.length);
    for (const c of asset.components) {
      const mesh = rendered.find(m => m.name === c.meshName); assert.ok(mesh, c.id);
      const p = mesh.geometry.attributes.position, edges = new Map(); let volume = 0;
      for (let i = c.vertexStart; i < c.vertexStart + c.vertexCount; i += 3) {
        const v = [0, 1, 2].map(j => new THREE.Vector3().fromBufferAttribute(p, i + j));
        assert.ok(v.every(q => q.toArray().every(Number.isFinite)), c.id);
        assert.ok(new THREE.Triangle(...v).getArea() > 1e-11, c.id + ' has no degenerate faces');
        volume += v[0].dot(v[1].clone().cross(v[2]));
        const keys = v.map(q => q.toArray().map(n => n.toFixed(5)).join(','));
        for (let j = 0; j < 3; j++) { const key = [keys[j], keys[(j + 1) % 3]].sort().join('|'); edges.set(key, (edges.get(key) || 0) + 1); }
      }
      assert.ok(volume > 0, c.id + ' outward'); assert.ok([...edges.values()].every(count => count === 2), c.id + ' closed');
    }
  }
});

test('every promised passage has actual swept body clearance while adjacent solid faces block travel', () => {
  const probes = { 'pirate-chest': [-4, 2.8, 3.5], wreck: [-8, 2.8, 2.9], 'diver-helmet': [4.8, 7.5, 3.4] };
  for (const kind of kinds) {
    const asset = create(kind), ts = triangles(asset), closest = new THREE.Vector3(); asset.group.updateMatrixWorld(true);
    const world = collisions.createWorld(THREE, { halfWidth: 30 / cm, backZ: -18 / cm, frontZ: 18 / cm, floorY: 0 });
    world.capture(asset.group, mesh => mesh.userData.solid); assert.ok(asset.openings.length >= 1);
    for (const opening of asset.openings) {
      const from = new THREE.Vector3(...opening.from), to = new THREE.Vector3(...opening.to), radius = opening.clearRadiusCm / cm;
      assert.ok(radius > 0); assert.equal(world.moveSphere(from, to, radius).collided, false, kind + ' ' + opening.id);
      const length = from.distanceTo(to), steps = Math.ceil(length * cm / .2), margin = length / steps / 2;
      for (let i = 0; i <= steps; i++) {
        const p = from.clone().lerp(to, i / steps);
        for (const tri of ts) { tri.closestPointToPoint(p, closest); assert.ok(closest.distanceTo(p) > radius + margin, kind + ' conservative capsule ' + opening.id); }
      }
    }
    const target = new THREE.Vector3(...probes[kind]).divideScalar(cm), from = target.clone().setZ(10 / cm);
    assert.equal(world.moveSphere(from, target, .1 / cm).kind, 'solid', kind + ' solid control');
  }
});

test('mount hints have actual exposed support and world anchors follow transformed ownership', () => {
  for (const kind of kinds) {
    const asset = create(kind); asset.group.updateMatrixWorld(true); assert.ok(asset.mountAnchors.length >= 1);
    for (const a of asset.mountAnchors) {
      const p = new THREE.Vector3(...a.position), n = new THREE.Vector3(...a.normal); near(n.length(), 1, 'unit normal');
      const hit = new THREE.Raycaster(p.clone().addScaledVector(n, .02), n.clone().negate(), 0, .04).intersectObjects(meshes(asset))[0];
      assert.ok(hit, a.id); assert.ok(hit.point.distanceTo(p) < 4e-5); assert.ok(hit.face.normal.dot(n) > .99);
    }
    const parent = new THREE.Group(); parent.position.set(1, 2, -3); parent.rotation.set(.1, .7, -.05); parent.add(asset.group); parent.updateMatrixWorld(true);
    for (const a of [...asset.mountAnchors, ...asset.groundContacts]) {
      const actual = asset.worldAnchor(a.id), expected = new THREE.Vector3(...a.position).applyMatrix4(asset.group.matrixWorld);
      assert.ok(actual.position.distanceTo(expected) < 1e-8); near(actual.normal.length(), 1, 'world unit normal');
    }
    assert.throws(() => asset.worldAnchor('missing'), /anchor/);
  }
});

test('cmPerUnit converts every geometry position and declared passage without legacy scaling', () => {
  for (const kind of kinds) {
    const a = create(kind), b = create(kind, { cmPerUnit: 1 });
    for (const axis of ['x', 'y', 'z']) { near(box(a).min[axis] * cm, box(b).min[axis], 'min ' + axis); near(box(a).max[axis] * cm, box(b).max[axis], 'max ' + axis); }
    for (let i = 0; i < a.openings.length; i++) {
      a.openings[i].from.forEach((n, j) => near(n * cm, b.openings[i].from[j], 'opening conversion'));
      assert.equal(a.openings[i].clearRadiusCm, b.openings[i].clearRadiusCm);
    }
  }
});

test('all instances own bounded original pixel resources and dispose exactly once', () => {
  for (const kind of kinds) {
    const a = create(kind), b = create(kind), c = create(kind, { seed: 17 }); let tris = 0, bytes = 0;
    for (let i = 0; i < a.geometries.length; i++) {
      const g = a.geometries[i]; tris += g.attributes.position.count / 3;
      for (const attribute of Object.values(g.attributes)) { assert.ok([...attribute.array].every(Number.isFinite)); bytes += attribute.array.byteLength; }
      assert.deepEqual(g.attributes.position.array, b.geometries[i].attributes.position.array);
    }
    assert.ok(meshes(a).length <= 4 && tris < 9000 && tris > 200, `${kind}: ${tris} triangles`); assert.ok(bytes < 1300000);
    assert.ok(a.maps.length >= 1 && a.maps.length <= 2);
    for (const [i, map] of a.maps.entries()) {
      assert.ok(map.isDataTexture); assert.equal(map.minFilter, THREE.NearestFilter); assert.equal(map.magFilter, THREE.NearestFilter);
      assert.ok(map.image.width <= 32 && map.image.height <= 64); assert.deepEqual(map.image.data, b.maps[i].image.data); assert.notDeepEqual(map.image.data, c.maps[i].image.data);
    }
    const resources = [...a.geometries, ...a.materials, ...a.maps], other = [...b.geometries, ...b.materials, ...b.maps];
    assert.equal(new Set(resources).size, resources.length); assert.ok(resources.every(r => !other.includes(r)));
    a.group.traverse(o => { assert.ok(!o.isLight); if (o.isMesh) { assert.ok(a.geometries.includes(o.geometry)); assert.ok(a.materials.includes(o.material)); assert.equal(o.userData.solid, true); assert.equal(o.userData.hardscape, true); assert.equal(o.userData.climbable, true); assert.equal(o.material.transparent, false); assert.ok(o.castShadow && o.receiveShadow); } });
    const counts = new Map(resources.map(r => [r, 0])); resources.forEach(r => r.addEventListener('dispose', () => counts.set(r, counts.get(r) + 1)));
    a.dispose(); a.dispose(); assert.ok([...counts.values()].every(count => count === 1));
  }
});

test('browser factory needs no DOM, clocks or loaders and rejects invalid inputs', () => {
  const sandbox = {}; for (const key of ['document', 'setTimeout', 'fetch', 'performance']) Object.defineProperty(sandbox, key, { get() { throw new Error('unexpected ' + key); } });
  vm.createContext(sandbox); vm.runInContext(fs.readFileSync(source, 'utf8'), sandbox);
  for (const kind of kinds) assert.equal(sandbox.AquariumKitschOrnamentsV1.create(THREE, { kind }).group.name, kind);
  for (const options of [{ kind: 'other' }, { kind: kinds[0], seed: NaN }, { kind: kinds[0], cmPerUnit: 0 }, { kind: kinds[0], cmPerUnit: Infinity }]) assert.throws(() => api().create(THREE, options), /kind|seed|cmPerUnit/);
});
