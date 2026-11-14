(function(root){
 'use strict';
 root.runAquariumStockReturnPlacement=function(study){
  let checks=0;function check(value,message){checks++;if(!value)throw new Error(message);}
  check(typeof study.reconcileStockPose==='function','Returned animals need placement validation in the current world');
  const saved=study.exportTank({id:'return-placement',name:'Return placement'}),rock=saved.tank.document.layout.objects.find(o=>o.id==='base-rock');
  const actor=saved.runtime.actors.find(a=>a.kind==='shrimp'&&a.surface.surface==='floor'),life=saved.tank.document.checkpoint.data.ecology.animals.find(a=>a.id===actor.id);
  const gain=study.state.physical.cmPerUnit||36/8.4,x=rock.positionCm.x/gain,z=rock.positionCm.z/gain,dx=x-actor.surface.position[0],dz=z-actor.surface.position[2];
  actor.position[0]+=dx;actor.position[2]+=dz;actor.surface.position[0]+=dx;actor.surface.position[2]+=dz;life.position.x+=dx;life.position.z+=dz;
  saved.tank.document.layout.objects=saved.tank.document.layout.objects.filter(o=>o.id!==rock.id);
  study.restoreTankJSON(JSON.stringify(saved));root.idleScreenScene.beginEditing();
  const result=study.applyPresetObjects({expectedRevision:study.state.presetRevision,objects:[...study.state.presetObjects,rock]});check(!result.error,'The current layout must restore a real rock over the archived pose');
  const capture=()=>study.exportTank({id:'return-placement',name:'Return placement'}),before=capture();
  study.reconcileStockPose(actor.id);const after=capture(),returned=after.runtime.actors.find(a=>a.id===actor.id);
  check(JSON.stringify(returned.position)!==JSON.stringify(actor.position),'A body inside the restored rock must move to a clear location');
  check(before.runtime.actors.filter(a=>a.id!==actor.id).every(a=>JSON.stringify(a)===JSON.stringify(after.runtime.actors.find(b=>b.id===a.id))),'Return placement must not move other animals');
  check(JSON.stringify(before.tank.document.checkpoint.data.water)===JSON.stringify(after.tank.document.checkpoint.data.water)&&JSON.stringify(before.runtime.food)===JSON.stringify(after.runtime.food),'Return placement must preserve water and food');
  const state=study.state;check(Math.abs(returned.surface.position[0])<state.world.width/2&&returned.surface.position[1]>=state.world.floorY&&returned.surface.position[2]>=state.world.floorBackZ&&returned.surface.position[2]<=state.world.floorFrontZ,'The returned floor animal must stay inside the tank');
  const expected=JSON.stringify(after);let rejected=false;try{study.reconcileStockPose('missing');}catch(_){rejected=true;}check(rejected&&JSON.stringify(capture())===expected,'Unknown return identities must leave the current world alone');
  return{checks};
 };
 root.runAquariumStockPaneReturn=function(study,pane){
  let checks=0;function check(value,message){checks++;if(!value)throw new Error(message);}
  check(typeof study.reconcileStockPose==='function','Glass returns need placement validation');root.idleScreenScene.beginEditing();
  const id=study.state.ecology.animals.find(a=>a.species==='otocinclus').id;study.setGlassPane(id,pane);
  const before=study.exportTank({id:'pane-return',name:'Pane return'});study.reconcileStockPose(id);const after=study.exportTank({id:'pane-return',name:'Pane return'});
  check(after.runtime.actors.find(a=>a.id===id)?.surface.pane===pane,'A returned cleaner must retain its own glass pane');
  check(before.runtime.actors.filter(a=>a.id!==id).every(a=>JSON.stringify(a)===JSON.stringify(after.runtime.actors.find(b=>b.id===a.id))),'Glass reconciliation must not disturb other actors');
  return{checks};
 };
})(globalThis);
