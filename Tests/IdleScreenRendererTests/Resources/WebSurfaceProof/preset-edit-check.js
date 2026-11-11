(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.runAquariumPresetEditCheck=factory();})(globalThis,function(){
 'use strict';
 return function(THREE,placement,rooted){
  function check(value,message){if(!value)throw new Error(message);}
  const CM=36/8.4,bed=5/CM,validator=placement.create(THREE,{factories:{},bedLevel:bed});
  check(typeof validator.inspectObject==='function','Existing preset geometry needs the same bounds and triangle checks as added items');
  const group=new THREE.Group(),material=new THREE.MeshBasicMaterial(),geometry=new THREE.BoxGeometry(1,1,1),mesh=new THREE.Mesh(geometry,material);group.add(mesh);group.position.y=bed+.5;
  check(validator.inspectObject(group,{solids:[]}).valid,'A supported clear object must be movable');
  const blocker=new THREE.Mesh(new THREE.BoxGeometry(3,3,3),material);blocker.position.y=bed+1.5;blocker.updateMatrixWorld(true);
  check(!validator.inspectObject(group,{solids:[blocker]}).valid,'Contained intersections must block preset movement');
  group.position.x=7;check(!validator.inspectObject(group,{solids:[]}).valid,'Preset geometry cannot cross glass');
  group.position.set(0,0,0);check(!validator.inspectObject(group,{solids:[]}).valid,'Preset geometry cannot cross tank bottom');
  check(mesh.geometry===geometry&&mesh.material===material,'Inspecting existing geometry must not clone, restyle or release it');
  validator.dispose();geometry.dispose();blocker.geometry.dispose();material.dispose();
  const obstacle=new THREE.Mesh(new THREE.BoxGeometry(2,2,2),new THREE.MeshBasicMaterial());obstacle.position.set(5,bed+1,0);obstacle.updateMatrixWorld(true);
  const editor=placement.create(THREE,{factories:{rooted},bedLevel:bed,solids:[obstacle]});
  editor.setLayout([{id:'plant',assetId:'rotala',positionCm:{x:0,y:5,z:0},rotationY:0}]);
  check(editor.status[0].valid,'Clear rooted specimen must start valid');const plant=editor.group.children[0];
  check(typeof editor.setEnvironment==='function','Base-object edits must refresh placement obstacles without replacing additions');
  obstacle.position.x=0;obstacle.updateMatrixWorld(true);editor.setEnvironment({solids:[obstacle]});
  check(!editor.status[0].valid,'Moving base geometry must invalidate an intersecting added plant');check(editor.group.children[0]===plant,'Environment refresh must retain live added objects');
  obstacle.position.x=5;obstacle.updateMatrixWorld(true);editor.setEnvironment({solids:[obstacle]});check(editor.status[0].valid,'Moving obstacle away restores the same plant');
  editor.dispose();obstacle.geometry.dispose();obstacle.material.dispose();
  return {checks:9};
 };
});
