(function(root){
 'use strict';
 function createWorld(THREE,bounds){
  let solids=[];
  const acceleration=new WeakMap();
  function accelerate(mesh){
   const geometry=mesh.geometry,position=geometry.attributes.position,index=geometry.index,count=index?index.count:position.count;
   if(count<384||count%3||Array.isArray(mesh.material)||geometry.morphAttributes.position?.length)return;
   const range=geometry.drawRange;
   if(range.start%3||(Number.isFinite(range.count)&&range.count%3))return;
   let cached=acceleration.get(geometry);
   if(!cached||cached.positionAttribute!==position||cached.indexAttribute!==index||cached.positionVersion!==position.version||cached.indexVersion!==index?.version||cached.count!==count){
    const boxes=[],centers=[],point=new THREE.Vector3();
    for(let i=0;i<count/3;i++){
     const box=new THREE.Box3();for(let j=0;j<3;j++)box.expandByPoint(point.fromBufferAttribute(position,index?index.getX(i*3+j):i*3+j));
     boxes.push(box);centers.push(box.getCenter(new THREE.Vector3()));
    }
    function build(ids){
     const box=new THREE.Box3();for(const id of ids)box.union(boxes[id]);
     if(ids.length<=16)return{box,ids};
     const size=box.getSize(new THREE.Vector3()),axis=size.x>=size.y&&size.x>=size.z?'x':size.y>=size.z?'y':'z';
     ids.sort((a,b)=>centers[a][axis]-centers[b][axis]);const middle=Math.floor(ids.length/2);
     return{box,left:build(ids.slice(0,middle)),right:build(ids.slice(middle))};
    }
    geometry.computeBoundingSphere();
    cached={positionAttribute:position,indexAttribute:index,tree:build(Array.from({length:count/3},(_,i)=>i)),positionVersion:position.version,indexVersion:index?.version,count};acceleration.set(geometry,cached);
   }
   const subset=new THREE.BufferGeometry();subset.attributes=geometry.attributes;subset.boundingBox=geometry.boundingBox;
   if(!geometry.boundingSphere)geometry.computeBoundingSphere();subset.boundingSphere=geometry.boundingSphere;
   const values=new Uint32Array(count),attribute=new THREE.BufferAttribute(values,1);subset.setIndex(attribute);
   const localRay=new THREE.Ray(),inverse=new THREE.Matrix4(),nativeRaycast=mesh.raycast;
   mesh.raycast=function(raycaster,hits){
    // Keep Three.js responsible for material sides, transforms, normals and near/far.
    if(Array.isArray(this.material)||geometry.drawRange.start%3||(Number.isFinite(geometry.drawRange.count)&&geometry.drawRange.count%3)){nativeRaycast.call(this,raycaster,hits);return;}
    inverse.copy(this.matrixWorld).invert();localRay.copy(raycaster.ray).applyMatrix4(inverse);
    const ids=[],first=Math.max(0,geometry.drawRange.start),last=Math.min(count,geometry.drawRange.start+geometry.drawRange.count);
    function visit(node){
     if(!localRay.intersectsBox(node.box))return;
     if(node.ids){for(const id of node.ids)if(id*3>=first&&id*3+2<last)ids.push(id);}
     else{visit(node.left);visit(node.right);}
    }
    visit(cached.tree);if(!ids.length)return;ids.sort((a,b)=>a-b);
    for(let i=0;i<ids.length;i++)for(let j=0;j<3;j++)values[i*3+j]=index?index.getX(ids[i]*3+j):ids[i]*3+j;
    attribute.count=ids.length*3;subset.setDrawRange(0,attribute.count);
    const start=hits.length,original=this.geometry;this.geometry=subset;
    try{nativeRaycast.call(this,raycaster,hits);}finally{this.geometry=original;}
    for(let i=start;i<hits.length;i++)hits[i].faceIndex=ids[hits[i].faceIndex];
   };
  }
  const ray=new THREE.Raycaster(),direction=new THREE.Vector3(),segment=new THREE.Box3(),normalMatrix=new THREE.Matrix3();
  function capture(scene,accept){
   solids=[];scene.updateMatrixWorld(true);
   scene.traverse(object=>{
    if(!object.isMesh||object.isInstancedMesh||!accept(object))return;
    object.geometry.computeBoundingBox();
    const mesh=new THREE.Mesh(object.geometry,object.material);mesh.userData={...object.userData};mesh.name=object.name;mesh.matrixWorld.copy(object.matrixWorld);
    accelerate(mesh);
    solids.push({mesh,bounds:object.geometry.boundingBox.clone().applyMatrix4(object.matrixWorld)});
   });
  }
  function moveSphere(from,to,radius){
   const position=to.clone(),normal=new THREE.Vector3(0,1,0);
   position.x=THREE.MathUtils.clamp(position.x,-bounds.halfWidth+radius,bounds.halfWidth-radius);
   position.z=THREE.MathUtils.clamp(position.z,bounds.backZ+radius,bounds.frontZ-radius);
   direction.copy(position).sub(from);const distance=direction.length();
   let contact=null;
   const floor=bounds.floorY+radius;
   if(position.y<=floor){
    const t=from.y>floor?(from.y-floor)/Math.max(1e-9,from.y-position.y):0;
    contact={position:from.clone().lerp(position,t),normal:normal.clone(),collided:true,kind:'gravel',distance:t*distance};contact.position.y=floor;
   }
   if(distance>1e-8){
    direction.divideScalar(distance);segment.setFromPoints([from,position]).expandByScalar(radius);
    const candidates=solids.filter(solid=>solid.bounds.intersectsBox(segment)).map(solid=>solid.mesh);
    const offsets=[[0,0,0],[radius,0,0],[-radius,0,0],[0,0,radius],[0,0,-radius]];
    for(const values of offsets){
     const offset=new THREE.Vector3(...values);ray.set(from.clone().add(offset),direction);ray.near=0;ray.far=distance+radius;
     for(const hit of ray.intersectObjects(candidates,false)){
      const travel=Math.max(0,hit.distance-radius);
      if(contact&&travel>=contact.distance)break;
      normalMatrix.getNormalMatrix(hit.object.matrixWorld);const n=hit.face.normal.clone().applyNormalMatrix(normalMatrix);
      if(n.dot(direction)>0)n.negate();
      contact={position:hit.point.clone().sub(offset).addScaledVector(n,radius),normal:n,collided:true,kind:'solid',distance:travel};break;
     }
    }
   }
   if(contact){contact.position.x=THREE.MathUtils.clamp(contact.position.x,-bounds.halfWidth+radius,bounds.halfWidth-radius);contact.position.z=THREE.MathUtils.clamp(contact.position.z,bounds.backZ+radius,bounds.frontZ-radius);return contact;}
   return{position,normal,collided:!position.equals(to),kind:position.equals(to)?null:'glass'};
  }
  return{capture,moveSphere,get count(){return solids.length;},get meshes(){return solids.map(solid=>solid.mesh);}};
 }
 const api={createWorld};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumCollisions=api;
})(typeof window==='object'?window:globalThis);
