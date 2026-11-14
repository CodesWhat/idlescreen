(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.runAquariumMountEditCheck=factory();})(globalThis,function(){
 'use strict';
 return function(study){
  function check(value,message){if(!value)throw new Error(message);}
  study.setMode('desktop');study.applyDesigner({layout:{schemaVersion:1,units:'cm',name:'Mounted plants',base:{setup:'basic'},instances:[]}});
  const rock=study.state.presetObjects.find(o=>o.id==='base-rock');check(!!rock,'Actual rock required');
  const centered={...rock,positionCm:{...rock.positionCm,x:0,z:0}};
  let result=study.applyPresetObjects({expectedRevision:study.state.presetRevision,objects:[centered]});check(!result.error,'Clear actual rock placement: '+result.error);
  let plant=null;const attempts=[];
  for(const [x,z] of [[0,0],[-4,0],[4,0],[0,-4],[0,4],[-4,-4],[4,-4],[-4,4],[4,4]]){
   const candidate={id:'placed-moss',assetId:'fissidens',positionCm:{x,y:5,z},rotationY:0};
   result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[candidate]});
   if(!result.error){plant=candidate;break;}attempts.push([x,z,result.error]);
  }
  check(!!plant,'Actual rock mount: '+JSON.stringify(attempts));
  check(study.designer.status[0].valid&&study.designer.status[0].positionCm.y>5,'Plant must sit on actual rock geometry');
  const before=JSON.stringify(study.exportTank({id:'mount-test',name:'Mounted plants'})),revision=study.state.presetRevision;
  result=study.applyPresetObjects({expectedRevision:revision,objects:[]});
  check(!!result.error,'Removing a live plant mount must be rejected before it strands the plant');
  check(study.state.presetRevision===revision,'Rejected support removal must retain revision');
  check(JSON.stringify(study.exportTank({id:'mount-test',name:'Mounted plants'}))===before,'Rejected support removal must retain geometry, attached plants and biology');
  check(study.designer.status[0].valid,'Rollback must restore the live mounted plant');
  result=study.applyPlacedObjects({expectedRevision:revision,objects:[]});check(!result.error,result.error);
  result=study.applyPresetObjects({expectedRevision:study.state.presetRevision,objects:[]});check(!result.error,result.error);
  result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[plant]});check(!!result.error,'No hardscape means no eligible plant mount');
  const baselineSolids=study.state.collisions.solids;
  const hardscape={id:'placed-rock',assetId:'moss-rock',positionCm:{x:0,y:5,z:0},rotationY:0};
  result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[hardscape]});check(!result.error,'Added actual hardscape must be placeable: '+result.error);
  check(study.state.collisions.solids>baselineSolids,'Added rock must join actual collision world');
  result=study.applyPlacedObjects({expectedRevision:study.state.presetRevision,objects:[]});check(!result.error,result.error);
  check(study.state.collisions.solids===baselineSolids,'Removing added rock must remove its collision geometry');
  return {checks:9,mountX:plant.positionCm.x,mountZ:plant.positionCm.z};
 };
});
