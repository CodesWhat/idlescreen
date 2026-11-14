(function(root,factory){
  if(typeof module==='object'&&module.exports)module.exports=factory();
  else root.runAquariumCollisionCheck=factory();
})(globalThis,function(){
  'use strict';
  return function(THREE,collisions){
    function check(value,message){if(!value)throw new Error(message);}
    const geometry=new THREE.PlaneGeometry(40,40,100,100),scene=new THREE.Group();
    const source=new THREE.Mesh(geometry,new THREE.MeshBasicMaterial({side:THREE.DoubleSide}));scene.add(source);
    const world=collisions.createWorld(THREE,{floorY:-100,halfWidth:100,backZ:-100,frontZ:100});
    let samples=0,maxVertexReads=0;
    for(const indexed of [true,false]){
      source.geometry=indexed?geometry:geometry.toNonIndexed();
      for(const mirror of [1,-1]){
        source.position.set(2,3,-1);source.rotation.set(.2,.3,-.1);source.scale.set(mirror*1.5,.75,2);scene.updateMatrixWorld(true);
        for(const side of [THREE.FrontSide,THREE.BackSide,THREE.DoubleSide]){
          source.material.side=side;world.capture(scene,o=>o===source);const captured=world.meshes[0];
          let reads=0;const original=captured.getVertexPosition;captured.getVertexPosition=function(index,out){reads++;return original.call(this,index,out);};
          for(const sign of [1,-1]){
            const target=source.localToWorld(new THREE.Vector3(.123,.277,0)),normal=new THREE.Vector3(0,0,1).transformDirection(source.matrixWorld).multiplyScalar(sign);
            const ray=new THREE.Raycaster(target.clone().addScaledVector(normal,5),normal.clone().negate(),0,10);
            const expected=ray.intersectObject(source,false),actual=ray.intersectObject(captured,false);
            check(actual.length===expected.length,'Accelerated ray must preserve front/back material contacts');
            for(let i=0;i<actual.length;i++){check(actual[i].point.distanceTo(expected[i].point)<1e-7,'Contact position changed');check(Math.abs(actual[i].distance-expected[i].distance)<1e-7,'Contact distance changed');check(actual[i].faceIndex===expected[i].faceIndex,'Original triangle identity changed');check(actual[i].face.normal.distanceTo(expected[i].face.normal)<1e-7,'Contact normal changed');}
            samples++;
          }
          maxVertexReads=Math.max(maxVertexReads,reads);
          check(reads<500,'A localized ray must skip distant triangles; observed '+reads+' vertex reads');
        }
      }
      if(!indexed)source.geometry.dispose();
    }
    source.geometry=geometry;
    const replacement=geometry.attributes.position.array.slice();for(let i=0;i<replacement.length;i+=3)replacement[i]+=60;
    geometry.setAttribute('position',new THREE.Float32BufferAttribute(replacement,3));geometry.computeBoundingSphere();world.capture(scene,o=>o===source);
    const target=source.localToWorld(new THREE.Vector3(60.123,.277,0)),normal=new THREE.Vector3(0,0,1).transformDirection(source.matrixWorld);
    const changedRay=new THREE.Raycaster(target.clone().addScaledVector(normal,5),normal.clone().negate(),0,10);
    check(changedRay.intersectObject(source,false).length===1,'Changed source control must hit');
    check(changedRay.intersectObjects(world.meshes,false).length===1,'Recapture must refresh replaced geometry attributes even when versions match');
    const reference=collisions.createWorld(THREE,{floorY:-100,halfWidth:100,backZ:-100,frontZ:100});reference.capture(scene,o=>o===source);
    for(const mesh of reference.meshes)mesh.raycast=THREE.Mesh.prototype.raycast;
    let bodyQueries=0;
    for(const radius of [.02,.15,.4])for(const sign of [1,-1]){
      const from=target.clone().addScaledVector(normal,5*sign),to=target.clone().addScaledVector(normal,-5*sign);
      const actual=world.moveSphere(from,to,radius),expected=reference.moveSphere(from,to,radius);
      check(actual.kind===expected.kind&&actual.collided===expected.collided,'Swept body contact classification changed');
      check(actual.position.distanceTo(expected.position)<1e-7&&actual.normal.distanceTo(expected.normal)<1e-7,'Swept body position or normal changed');bodyQueries++;
    }
    source.geometry.setDrawRange(3,300);const partialExpected=changedRay.intersectObject(source,false),partialActual=changedRay.intersectObjects(world.meshes,false);
    check(partialActual.length===partialExpected.length,'Changed draw range must preserve visible triangle selection');
    source.geometry.setDrawRange(0,Infinity);
    source.material=[source.material,source.material];world.meshes[0].material=source.material;source.geometry.clearGroups();source.geometry.addGroup(0,30000,0);source.geometry.addGroup(30000,30000,1);
    check(changedRay.intersectObjects(world.meshes,false).length===changedRay.intersectObject(source,false).length,'Multi-material fallback must preserve contacts');
    geometry.dispose();source.material[0].dispose();
    return {samples,maxVertexReads,bodyQueries};
  };
});
