(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.runAquariumPresetSceneCheck=factory();})(globalThis,function(){
 'use strict';
 return function(study){
  function check(value,message){if(!value)throw new Error(message);}
  check(typeof study.applyPresetObjects==='function','Preset edits must reach actual scene objects and collision surfaces');
  const closed=study.state;check(!!study.applyPresetObjects({expectedRevision:closed.presetRevision,objects:closed.presetObjects}).error,'Playback must not accept editor operations');
  study.setMode('desktop');study.applyDesigner({requestId:1,layout:{schemaVersion:1,units:'cm',name:'Preset editing',base:{setup:'basic'},instances:[]}});
  const before=study.state,life=JSON.stringify({ecology:before.ecology,breeding:before.breeding,feeding:before.feeding,clock:before.clock}),original=before.presetObjects;
  const rock=original.find(o=>o.id==='base-rock');check(!!rock,'Baseline rock must be editable');
  const moved=original.map(o=>o.id===rock.id?{...o,positionCm:{...o.positionCm,z:o.positionCm.z+3}}:o);
  const result=study.applyPresetObjects({expectedRevision:before.presetRevision,objects:moved});check(!result.error,result.error);
  check(Math.abs(study.state.presetObjects.find(o=>o.id===rock.id).positionCm.z-rock.positionCm.z-3)<1e-7,'Actual preset record must move in centimeters');
  check(JSON.stringify({ecology:study.state.ecology,breeding:study.state.breeding,feeding:study.state.feeding,clock:study.state.clock})===life,'Edits must preserve biological time, losses, broods and feeding');
  const stable=JSON.stringify(study.state.presetObjects),revision=study.state.presetRevision;
  const stale=study.applyPresetObjects({expectedRevision:before.presetRevision,objects:original});check(!!stale.error&&JSON.stringify(study.state.presetObjects)===stable,'Stale edit must not mutate scene');
  const invalid=moved.map(o=>o.id===rock.id?{...o,positionCm:{...o.positionCm,x:50}}:o);
  check(!!study.applyPresetObjects({expectedRevision:revision,objects:invalid}).error,'Crossing glass must be rejected');check(JSON.stringify(study.state.presetObjects)===stable,'Invalid edit must restore actual transforms');
  const floating=moved.map(o=>o.id===rock.id?{...o,positionCm:{...o.positionCm,y:o.positionCm.y+1}}:o);check(!!study.applyPresetObjects({expectedRevision:revision,objects:floating}).error,'Base hardscape must retain its substrate anchor');
  const restored=study.applyPresetObjects({expectedRevision:revision,objects:original});check(!restored.error,restored.error);
  const without=original.filter(o=>o.id!==rock.id);const removed=study.applyPresetObjects({expectedRevision:study.state.presetRevision,objects:without});check(!removed.error,removed.error);check(!study.state.presetObjects.some(o=>o.id===rock.id),'Removed base object stays removed');
  check(study.state.collisions.solids<before.collisions.solids,'Removing rock removes its actual collision surfaces');
  const undo=study.applyPresetObjects({expectedRevision:study.state.presetRevision,objects:original});check(!undo.error,undo.error);check(study.state.collisions.solids===before.collisions.solids,'Restoring rock restores collision surfaces');
  return {checks:10};
 };
});
