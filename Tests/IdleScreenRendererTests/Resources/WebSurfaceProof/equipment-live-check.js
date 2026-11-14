(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.runAquariumEquipmentLiveCheck=factory();})(globalThis,function(){
 'use strict';
 return function(study,basic,configurations,T,mossRock){
  function check(value,message){if(!value)throw new Error(message);}
  study.setMode('desktop');study.applyDesigner({selectionScope:'all',layout:{schemaVersion:1,units:'cm',name:'Equipment',base:{setup:'basic'},instances:[]}});
  let result=study.applyPresetObjects({expectedRevision:study.state.presetRevision,objects:[]});check(!result.error,result.error);
  result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[{id:'clearance-plant',assetId:'rotala',positionCm:{x:10,y:5,z:8},rotationY:0}]});check(!result.error,result.error);
  const original=study.equipment.objects,originalCreate=basic.create,instances=[];
  basic.create=function(...args){const asset=originalCreate(...args),counts=new Map();for(const resource of [...asset.geometries,...asset.materials,...asset.maps]){counts.set(resource,0);resource.addEventListener('dispose',()=>counts.set(resource,counts.get(resource)+1));}instances.push({asset,counts});return asset;};
  function move(x,z){return original.map(o=>o.id==='equipment/filter'?{...o,positionCm:{...o.positionCm,x,z}}:o);}
  const saved=()=>JSON.stringify(study.exportTank({id:'equipment-test',name:'Equipment'}));
  try{
   const before=saved(),revision=study.state.presetRevision;
   const incomplete=original.map(o=>o.id==='equipment/filter'?{...o,positionCm:{x:-15}}:o);result=study.applyEquipmentObjects({expectedRevision:revision,objects:incomplete});check(!!result.error&&saved()===before,'Live edits require complete equipment poses instead of silently applying defaults');
   result=study.applyEquipmentObjects({expectedRevision:revision,objects:move(10,8)});check(!!result.error,'Equipment must not bury an added plant');check(saved()===before,'Rejected equipment must retain layout and biology');
   check([...instances[0].counts.values()].every(n=>n===1),'Rejected candidate resources must be released once');
   result=study.applyEquipmentObjects({expectedRevision:revision,objects:move(-15,8)});check(!result.error,result.error);
   check(study.equipment.objects.find(o=>o.id==='equipment/filter').positionCm.x===-15,'Live hardware position must change');
   check(Math.abs(study.equipment.outlet.x*study.state.physical.cmPerUnit+19.1)<1e-6,'Flow/bubble origin follows the moved filter');
   const active=instances.at(-1);check(active.asset.wetGroup.getObjectByName('filter-riser-above-water'),'Riser belongs to the captured wet physical geometry');
   const prior=JSON.parse(before),after=JSON.parse(saved());check(JSON.stringify(prior.tank.document.checkpoint)===JSON.stringify(after.tank.document.checkpoint),'Equipment edits retain domain biology and elapsed time');
   result=study.applyEquipmentObjects({expectedRevision:study.state.presetRevision,objects:original});check(!result.error,result.error);check([...active.counts.values()].every(n=>n===1),'Replaced live resources must be released once');
   const finalActive=instances.at(-1),cm=study.state.physical.cmPerUnit,centerZ=(study.state.world.floorBackZ+study.state.world.floorFrontZ)/2;
   const probe=basic.create(T,{bedLevel:5/cm,placementsCm:{...finalActive.asset.placementsCm,filter:{...finalActive.asset.placementsCm.filter,x:-15,z:12}}});
   const route=probe.routes.airline.points,point=new T.Vector3(...route[1]).add(new T.Vector3(...route[2])).multiplyScalar(.5);probe.dispose();
   const makeRock=mossRock.create;
   mossRock.create=function(){const group=new T.Group(),height=point.y-5/cm+.004,geometry=new T.BoxGeometry(.25/cm,height,.25/cm),material=new T.MeshBasicMaterial(),mesh=new T.Mesh(geometry,material);mesh.position.y=height/2+.001;mesh.userData={solid:true,hardscape:true,climbable:true};group.add(mesh);return{group,geometries:[geometry],materials:[material],maps:[],grazeSites:[]};};
   try{
    result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[{id:'wire-blocker',assetId:'moss-rock',positionCm:{x:point.x*cm,y:5,z:(point.z-centerZ)*cm},rotationY:0}]});check(!result.error,result.error);
    const wired=saved();result=study.applyEquipmentObjects({expectedRevision:study.state.presetRevision,objects:move(-15,12)});check(!!result.error&&saved()===wired,'A moved submerged lead cannot pass through hardscape');
    result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[]});check(!result.error,result.error);
   }finally{mossRock.create=makeRock;}
   const configuration=study.exportTank({id:'equipment-test',name:'Equipment'}).tank.configuration;
   check(configuration.schemaVersion===2&&configuration.equipment.filter.x===original.find(o=>o.id==='equipment/filter').positionCm.x,'Schema2 captures actual poses');
   const future={...configuration,schemaVersion:3};let rejected=false;try{configurations.normalize(future);}catch(_){rejected=true;}check(rejected,'Future configuration versions stay rejected');
   let reads=0;const accessor={...configuration};Object.defineProperty(accessor,'schemaVersion',{enumerable:true,get(){reads++;return 2;}});
   rejected=false;try{configurations.normalize(accessor);}catch(_){rejected=true;}check(rejected&&reads===0,'Configuration validation cannot execute input getters');
   const state=study.state,equipment={...state.equipment};Object.defineProperty(equipment,'placementsCm',{enumerable:true,get(){reads++;return configuration.equipment;}});
   rejected=false;try{configurations.capture({...state,equipment});}catch(_){rejected=true;}check(rejected&&reads===0,'Capture validates equipment data before reading it');
   study.setSceneStyle('lush');check([...finalActive.counts.values()].every(n=>n===1),'Scene replacement releases current equipment once');
   return {checks:9};
  }finally{basic.create=originalCreate;}
 };
});
