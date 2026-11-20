(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumRoomArt = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function grain(x, y, seed) {
    let value = Math.imul(x + seed, 374761393) ^ Math.imul(y + seed, 668265263);
    value = Math.imul(value ^ value >>> 13, 1274126177);
    return ((value ^ value >>> 16) >>> 0) / 4294967296;
  }

  function makeMap(THREE, name, width, height, palette, choose) {
    const pixels = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      pixels.set([...palette[choose(x, y)], 255], (y * width + x) * 4);
    }
    const map = new THREE.DataTexture(pixels, width, height, THREE.RGBAFormat);
    map.name = name;
    map.colorSpace = THREE.SRGBColorSpace;
    map.magFilter = map.minFilter = THREE.NearestFilter;
    map.wrapS = map.wrapT = THREE.RepeatWrapping;
    map.generateMipmaps = false;
    map.needsUpdate = true;
    return map;
  }

  function slabGeometry(THREE, halfWidth, front, back) {
    const top = -.055, bottom = -.35;
    const positions = [], normals = [], uvs = [], indices = [];
    function face(points, normal) {
      const start = positions.length / 3;
      for (const point of points) {
        positions.push(...point);
        normals.push(...normal);
        if (normal[1]) uvs.push(point[0] / 8, point[2] / 4);
        else uvs.push((normal[0] ? point[2] : point[0]) / 8, point[1] / 4);
      }
      indices.push(start, start + 1, start + 2, start, start + 2, start + 3);
    }
    face([[-halfWidth, top, back], [-halfWidth, top, front], [halfWidth, top, front], [halfWidth, top, back]], [0, 1, 0]);
    face([[-halfWidth, bottom, front], [halfWidth, bottom, front], [halfWidth, top, front], [-halfWidth, top, front]], [0, 0, 1]);
    face([[halfWidth, bottom, back], [-halfWidth, bottom, back], [-halfWidth, top, back], [halfWidth, top, back]], [0, 0, -1]);
    face([[-halfWidth, bottom, back], [-halfWidth, bottom, front], [-halfWidth, top, front], [-halfWidth, top, back]], [-1, 0, 0]);
    face([[halfWidth, bottom, front], [halfWidth, bottom, back], [halfWidth, top, back], [halfWidth, top, front]], [1, 0, 0]);
    face([[-halfWidth, bottom, front], [-halfWidth, bottom, back], [halfWidth, bottom, back], [halfWidth, bottom, front]], [0, -1, 0]);
    const geometry = new THREE.BufferGeometry();
    geometry.setAttribute('position', new THREE.Float32BufferAttribute(positions, 3));
    geometry.setAttribute('normal', new THREE.Float32BufferAttribute(normals, 3));
    geometry.setAttribute('uv', new THREE.Float32BufferAttribute(uvs, 2));
    geometry.setIndex(indices);
    geometry.addGroup(0, 6, 0);
    geometry.addGroup(6, 30, 1);
    return geometry;
  }

  function create(THREE, { tankHalf = 9.5, frontZ = 4.04, backZ = -2.6, wallGap = 2 } = {}) {
    if (!Number.isFinite(tankHalf) || tankHalf <= 0) throw new RangeError('tankHalf must be a positive finite number');
    if (!Number.isFinite(frontZ) || !Number.isFinite(backZ) || frontZ <= backZ) {
      throw new RangeError('frontZ and backZ must be finite, with frontZ greater than backZ');
    }
    if (!Number.isFinite(wallGap) || wallGap < 0) throw new RangeError('wallGap must be finite and nonnegative');

    const plaster = makeMap(THREE, 'room-plaster-pixels', 64, 64,
      [[248, 247, 244], [253, 252, 249], [244, 243, 240], [250, 249, 246]],
      (x, y) => {
        const patch = grain(Math.floor(x / 4), Math.floor(y / 4), 917);
        return patch < .22 ? 1 : patch > .84 ? 2 : grain(Math.floor(x / 2), Math.floor(y / 2), 508) > .8 ? 3 : 0;
      });
    const walnut = makeMap(THREE, 'room-walnut-pixels', 128, 64,
      [[83, 62, 47], [88, 66, 50], [93, 70, 54], [78, 58, 44], [73, 54, 41], [98, 74, 57]],
      (x, y) => {
        const bend = Math.round(Math.sin(x / 128 * Math.PI * 2) * 1.5 + Math.sin(x / 128 * Math.PI * 4));
        const row = (y + bend + 64) % 64;
        if (row % 8 === 0 && grain(Math.floor(x / 16), Math.floor(row / 8), 641) > .3) return 4;
        if (row % 16 === 5 && grain(Math.floor(x / 32), Math.floor(row / 16), 392) > .5) return 5;
        return Math.floor(grain(Math.floor(x / 32), Math.floor(row / 3), 142) * 4);
      });
    const concrete = makeMap(THREE, 'room-concrete-pixels', 128, 64,
      [[142, 144, 138], [146, 148, 142], [137, 139, 133], [132, 134, 128], [150, 152, 146]],
      (x, y) => {
        const fleck = grain(Math.floor(x / 2), Math.floor(y / 2), 780);
        if (fleck < .035) return 3;
        if (fleck > .965) return 4;
        return Math.floor(grain(Math.floor(x / 4), Math.floor(y / 4), 211) * 3);
      });

    const wallMaterial = new THREE.MeshLambertMaterial({ map: plaster });
    const topMaterial = new THREE.MeshPhongMaterial({ map: walnut, shininess: 11, specular: 0x11100d });
    const edgeMaterial = new THREE.MeshLambertMaterial({ map: walnut });
    const matMaterial = new THREE.MeshLambertMaterial({ color: 0x262725 });
    wallMaterial.name = 'room-wall-finish';
    topMaterial.name = 'room-counter-top-finish';
    edgeMaterial.name = 'room-counter-edge-finish';
    matMaterial.name = 'room-support-mat';

    const group = new THREE.Group();
    group.name = 'aquarium-room';
    const geometries = [], materials = [wallMaterial, topMaterial, edgeMaterial, matMaterial];
    const maps = [plaster, walnut, concrete];
    function add(name, geometry, material) {
      geometries.push(geometry);
      const object = new THREE.Mesh(geometry, material);
      object.name = name;
      object.receiveShadow = true;
      object.castShadow = false;
      group.add(object);
      return object;
    }

    const halfWidth = Math.max(18, tankHalf * 1.65 + 2);
    const wallGeometry = new THREE.PlaneGeometry(halfWidth * 2, 24.35);
    const position = wallGeometry.attributes.position, uv = wallGeometry.attributes.uv;
    for (let i = 0; i < position.count; i++) uv.setXY(i, position.getX(i) / 4, (position.getY(i) + 11.825) / 4);
    const wallZ = backZ - wallGap;
    add('room-wall', wallGeometry, wallMaterial).position.set(0, 11.825, wallZ);
    add('room-counter', slabGeometry(THREE, halfWidth, frontZ + 1.16, wallZ + .1), [topMaterial, edgeMaterial]);
    add('room-tank-mat', new THREE.BoxGeometry(tankHalf * 2 + .08, .055, frontZ - backZ + .08), matMaterial)
      .position.set(0, -.0275, (frontZ + backZ) / 2);

    function setFinish(name) {
      if (name !== 'neutral' && name !== 'charcoal' && name !== 'concrete') return false;
      wallMaterial.color.setHex(name === 'charcoal' ? 0x4a4b49 : 0xa8a59c);
      const isConcrete = name === 'concrete';
      topMaterial.map = edgeMaterial.map = isConcrete ? concrete : walnut;
      topMaterial.color.setHex(0xffffff);
      topMaterial.specular.setHex(isConcrete ? 0x050505 : 0x11100d);
      topMaterial.shininess = isConcrete ? 4 : 11;
      edgeMaterial.color.setHex(isConcrete ? 0xd5d4ce : 0xc2b7aa);
      group.userData.finish = name;
      return true;
    }
    setFinish('neutral');
    return { group, geometries, materials, maps, setFinish };
  }

  return { create };
});
