(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.runAquariumMountNormalCheck=factory();})(globalThis,function(){
 'use strict';
 return function(T,placement,epiphyte){
  function check(value,message){if(!value)throw new Error(message);}
  const cm=36/8.4,bed=5/cm,mount=new T.Mesh(new T.BoxGeometry(3,1,3),new T.MeshBasicMaterial());
  mount.position.y=bed+.6;mount.rotation.z=.2;mount.userData={solid:true,hardscape:true};mount.updateMatrixWorld(true);
  const editor=placement.create(T,{factories:{epiphyte},cmPerUnit:cm,bedLevel:bed,solids:[mount]});
  for(const species of ['java-fern','bucephalandra','fissidens','christmas-moss']){
   editor.setLayout([{id:'mounted-test',assetId:species,positionCm:{x:0,y:5,z:0},rotationY:.7}]);
   check(editor.status[0].valid,species+' should mount on a sloped solid: '+editor.status[0].reason);
   const up=new T.Vector3(0,1,0).applyQuaternion(editor.group.children[0].quaternion),expected=new T.Vector3(0,1,0).transformDirection(mount.matrixWorld);
   check(up.dot(expected)>.9999,'Mount must use the actual upward surface normal');
  }
  mount.rotation.z=0;mount.updateMatrixWorld(true);editor.setEnvironment({solids:[mount]});
  check(editor.status[0].valid,'Refreshing support preserves the mounted specimen');
  check(new T.Vector3(0,1,0).applyQuaternion(editor.group.children[0].quaternion).y>.9999,'Changed support normal must not accumulate tilt');
  editor.setEnvironment({solids:[]});check(!editor.status[0].valid,'Removing support must invalidate an attached plant');
  editor.setEnvironment({solids:[mount]});check(editor.status[0].valid,'Restored support must reattach the same plant');
  editor.dispose();mount.geometry.dispose();mount.material.dispose();
  return {checks:8};
 };
});
