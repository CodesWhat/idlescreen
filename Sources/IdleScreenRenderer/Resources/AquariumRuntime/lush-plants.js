(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumLushPlants=factory();})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 function create(THREE,{tankHalf,bedLevel,waterLevel,exclusions=[],includeGrass=true,backZ=-2.6,frontZ=4}){
  if(![tankHalf,bedLevel,waterLevel,backZ,frontZ].every(Number.isFinite)||tankHalf<=0||waterLevel<=bedLevel||frontZ<=backZ)throw new RangeError('Finite plant tank bounds required');
  const depth=frontZ-backZ;
  const group=new THREE.Group();group.name='lush-aquascape-plants';const geometries=[],materials=[],floaters=[];let seed=431;
  function random(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;}
  const blade=new THREE.BufferGeometry();blade.setAttribute('position',new THREE.Float32BufferAttribute([-.018,0,0,.018,0,0,-.012,.17,.015,.012,.17,.015,.035,.34,.04],3));blade.setIndex([0,1,2,1,3,2,2,3,4]);blade.computeVertexNormals();geometries.push(blade);
  const grassMaterial=new THREE.MeshLambertMaterial({color:0xffffff,side:THREE.DoubleSide,flatShading:true});materials.push(grassMaterial);
  const count=Math.round(tankHalf*850),grass=new THREE.InstancedMesh(blade,grassMaterial,count),dummy=new THREE.Object3D(),color=new THREE.Color();grass.name='hairgrass-carpet';grass.castShadow=grass.receiveShadow=true;grass.userData.plantFoliage=true;
  let filled=0;
  for(let attempt=0;includeGrass&&attempt<count*5&&filled<count;attempt++){
   const x=(random()*2-1)*(tankHalf-.18),z=backZ+.2+random()*(depth-.5),y=bedLevel+.01;
   const pathX=Math.sin(z*.65)*tankHalf*.11,clearing=Math.abs(x-pathX)<.28+(z-backZ-.2)*.035;
   const p=new THREE.Vector3(x,y,z);if(clearing||exclusions.some(box=>box.containsPoint(p)))continue;
   dummy.position.copy(p);dummy.rotation.set(0,random()*Math.PI*2,0);dummy.scale.set(.65+random()*.65,.5+random()*.85,.65+random()*.6);dummy.updateMatrix();grass.setMatrixAt(filled,dummy.matrix);
   color.setHex([0x496b28,0x648137,0x759246,0x3f6428,0x8a9e53][filled%5]);grass.setColorAt(filled,color);filled++;
  }
  grass.count=filled;if(includeGrass)group.add(grass);
  const leafGeometry=new THREE.SphereGeometry(1,8,4);leafGeometry.scale(.20,.025,.14);geometries.push(leafGeometry);
  const leafMaterial=new THREE.MeshLambertMaterial({color:0x72994a,flatShading:true});materials.push(leafMaterial);
  const rootMaterial=new THREE.MeshLambertMaterial({color:0x72744b});materials.push(rootMaterial);
  const rootGeometry=new THREE.CylinderGeometry(.009,.003,.85,4);rootGeometry.translate(0,-.425,0);geometries.push(rootGeometry);
  const floaterBounds=new THREE.Box3();
  function keepInside(rosette){
   rosette.updateMatrixWorld(true);floaterBounds.setFromObject(rosette);
   rosette.position.x+=Math.max(-tankHalf+.02-floaterBounds.min.x,Math.min(0,tankHalf-.02-floaterBounds.max.x));
   rosette.position.z+=Math.max(backZ+.02-floaterBounds.min.z,Math.min(0,frontZ-.02-floaterBounds.max.z));
  }
  for(let i=0;i<64;i++){
   const rosette=new THREE.Group(),side=i%2?1:-1;
   const x=side*(tankHalf*(.30+random()*.48)),z=backZ+depth*(.7+random()*3.4)/6.6;
   rosette.position.set(x,waterLevel+.014,z);rosette.scale.setScalar(i%3===0?1.3:2);rosette.userData.phase=i*1.73;
   for(let leaf=0;leaf<4;leaf++){
    const angle=leaf*Math.PI*.5+i*.37,mesh=new THREE.Mesh(leafGeometry,leafMaterial);mesh.position.set(Math.cos(angle)*.13,0,Math.sin(angle)*.13);mesh.rotation.y=-angle;mesh.scale.setScalar(.8+random()*.4);mesh.castShadow=mesh.receiveShadow=true;rosette.add(mesh);
   }
   for(let root=0;root<3;root++){
    const mesh=new THREE.Mesh(rootGeometry,rootMaterial);mesh.position.set((root-1)*.06,-.015,0);mesh.scale.y=.45+random()*.7;mesh.rotation.z=(root-1)*.09;mesh.castShadow=true;rosette.add(mesh);
   }
   keepInside(rosette);rosette.userData.rest=rosette.position.toArray();rosette.name='floating-rosette';group.add(rosette);floaters.push(rosette);
  }
  function update(time,flowField){if(!Number.isFinite(time))return;for(const rosette of floaters){const [x,y,z]=rosette.userData.rest,phase=rosette.userData.phase;rosette.position.set(x+Math.sin(time*.16+phase)*.09,y+Math.sin(time*1.2+phase)*.006,z+Math.cos(time*.13+phase)*.07);const flow=flowField?.sample(x,waterLevel-.15,z,time),valid=flow&&[flow.x,flow.y,flow.z,flow.strength].every(Number.isFinite),strength=valid?Math.max(0,Math.min(1,flow.strength)):0,fx=valid?Math.max(-1,Math.min(1,flow.x)):0,fz=valid?Math.max(-1,Math.min(1,flow.z)):0;rosette.position.x+=fx*strength*.22;rosette.position.z+=fz*strength*.22;rosette.rotation.y=Math.sin(time*.10+phase)*.06;
    for(const root of rosette.children)if(root.geometry===rootGeometry){root.rotation.z=(root.position.x/.06)*.09-fx*strength*.5;root.rotation.x=fz*strength*.5;}keepInside(rosette);}}
  return{group,geometries,materials,maps:[],floaters,update};
 }
 return{create};
});
