(function(root){
 'use strict';
 root.runAquariumStockHistory=function(study){
  let checks=0;const clone=value=>JSON.parse(JSON.stringify(value));
  function check(value,message){checks++;if(!value)throw new Error(message);}
  check(typeof AquariumRuntimeCheckpoint.removeStock==='function'&&typeof AquariumRuntimeCheckpoint.restoreStock==='function','Animal history needs selective stock inverses');
  const checkpointCodec=AquariumEcosystemCheckpointV1.create({ecology:AquariumEcology,breeding:AquariumBreeding,water:AquariumWaterEcosystem});
  const codec=AquariumTankEnvelope.createCodec({checkpointCodec,catalog:[...AquariumDesignerModel.catalog.map(({id,placement})=>({id,placement})),...['classic-stem','anubias','vallisneria','alternanthera','pixel-driftwood','slate-rock','river-rock'].map(id=>({id,placement:'transform'}))]});
  function advance(input,seconds,environment={shelter:0,light:1,stress:0}){
   const next=clone(input),live=checkpointCodec.restore(next.tank.document.checkpoint.data);
   for(let left=seconds;left>0;left-=Math.min(3600,left)){const dt=Math.min(3600,left);live.ecology.step(dt,{filter:0});live.breeding.step(dt,live.ecology.animals,environment);live.water.step(dt);}
   next.tank.document.checkpoint.data=checkpointCodec.capture(live);next.tank.document.checkpoint.elapsedSeconds=live.ecology.seconds;next.runtime.clock+=seconds;
   return AquariumRuntimeCheckpoint.normalize(next,codec);
  }
  root.idleScreenScene.beginEditing();study.feed({automatic:true});
  let pregnant=advance(study.exportTank({id:'history-tank',name:'History tank'}),1,{shelter:1,light:1,stress:0});
  const original=JSON.stringify(pregnant),brood=pregnant.tank.document.checkpoint.data.breeding.broods[0],id=brood.motherId;
  const taken=AquariumRuntimeCheckpoint.removeStock(pregnant,id,codec);
  check(JSON.stringify(pregnant)===original,'Capturing an inverse must not mutate the live checkpoint');
  check(typeof taken.archive==='string'&&taken.archive.length<=65536,'Per-animal history must be a bounded archive, not a whole tank');
  let current=advance(taken.checkpoint,3600),domain=current.tank.document.checkpoint.data;
  const otherBrood=domain.breeding.broods[0],live=checkpointCodec.restore(domain);
  live.ecology.die(live.ecology.animals.find(a=>a.id===otherBrood.motherId),'history preservation check');
  current.tank.document.checkpoint.data=checkpointCodec.capture(live);current=advance(current,1);
  domain=current.tank.document.checkpoint.data;
  check(domain.ecology.stats.deaths===1&&domain.breeding.stats.cancelledBroods===2,'The actual domains must advance and record the other mother\'s loss');
  domain.breeding.events=domain.breeding.events.map(e=>Object.fromEntries(Object.entries(e).reverse()));
  const currentJSON=JSON.stringify(current),restored=AquariumRuntimeCheckpoint.restoreStock(current,taken.archive,codec),result=restored.tank.document.checkpoint.data;
  check(JSON.stringify(current)===currentJSON,'Applying an inverse must leave its source untouched');
  check(JSON.stringify(result.water)===JSON.stringify(domain.water)&&JSON.stringify(restored.runtime.food)===JSON.stringify(current.runtime.food),'Undo must retain current water and falling food');
  check(domain.ecology.animals.every(a=>JSON.stringify(a)===JSON.stringify(result.ecology.animals.find(b=>b.id===a.id))),'Undo must retain every other animal at its current life state');
  check(JSON.stringify(result.ecology.stats)===JSON.stringify(domain.ecology.stats)&&JSON.stringify(result.ecology.deposits)===JSON.stringify(domain.ecology.deposits),'Undo must not erase current deaths, waste or molts');
  const returned=result.ecology.animals.find(a=>a.id===id),old=pregnant.tank.document.checkpoint.data.ecology.animals.find(a=>a.id===id),delta=domain.ecology.seconds-pregnant.tank.document.checkpoint.data.ecology.seconds;
  check(returned.alive&&returned.id===old.id&&returned.ageDays===old.ageDays&&returned.hunger===old.hunger&&returned.moltDue===old.moltDue+delta,'The archived individual keeps its state and rebases only its paused timer');
  check(result.breeding.broods.find(b=>b.id===brood.id)?.nextAt===brood.nextAt+delta,'The returned carried brood must retain its remaining incubation time');
  check(result.breeding.stats.cancelledBroods===domain.breeding.stats.cancelledBroods-1&&result.breeding.events.some(e=>e.kind==='brood-ended'&&e.motherId===otherBrood.motherId),'Undo must compensate only its own brood cancellation');
  check(result.breeding.serial===domain.breeding.serial&&result.breeding.eventSerial===domain.breeding.eventSerial&&result.ecology.serial===domain.ecology.serial&&result.ecology.seed===domain.ecology.seed,'Undo must not rewind global identities or random state');
  const restoredJSON=JSON.stringify(restored);let rejected=false;try{AquariumRuntimeCheckpoint.restoreStock(restored,taken.archive,codec);}catch(_){rejected=true;}
  check(rejected&&JSON.stringify(restored)===restoredJSON,'An inverse cannot resurrect a second copy of an existing animal');
  const archive=JSON.parse(taken.archive),invalid=[{...archive,schemaVersion:99},{...archive,documentID:'another-tank'},{...archive,ecologySeconds:domain.ecology.seconds+1},{...archive,actor:{...archive.actor,id:'wrong-animal'}}];
  for(const bad of [...invalid,' '.repeat(65537)]){let failed=false;try{AquariumRuntimeCheckpoint.restoreStock(current,typeof bad==='string'?bad:JSON.stringify(bad),codec);}catch(_){failed=true;}check(failed&&JSON.stringify(current)===currentJSON,'Invalid archives must fail without changing the current tank');}
  const full=clone(current),b=full.tank.document.checkpoint.data.breeding;b.maxAnimals=full.tank.document.checkpoint.data.ecology.animals.filter(a=>a.alive).length+b.broods.reduce((n,b)=>n+b.count,0);
  const fullJSON=JSON.stringify(full);rejected=false;try{AquariumRuntimeCheckpoint.restoreStock(full,taken.archive,codec);}catch(_){rejected=true;}
  check(rejected&&JSON.stringify(full)===fullJSON,'An inverse cannot take capacity now reserved by the living ecosystem');
  const longID='虾'.repeat(4096),oversized=JSON.parse(JSON.stringify(pregnant),(key,value)=>value===id?longID:value);oversized.tank.document.checkpoint.data.ecology.animals.find(a=>a.id===longID).reason='虾'.repeat(4096);
  AquariumRuntimeCheckpoint.normalize(oversized,codec);
  const oversizedJSON=JSON.stringify(oversized);rejected=false;try{AquariumRuntimeCheckpoint.removeStock(oversized,longID,codec);}catch(_){rejected=true;}
  check(rejected&&JSON.stringify(oversized)===oversizedJSON,'Archive bounds must use UTF-8 bytes and preserve stock when an inverse is too large');
  return{checks};
 };
 root.runAquariumYoungStockHistory=function(study){
  let checks=0;const clone=value=>JSON.parse(JSON.stringify(value));function check(value,message){checks++;if(!value)throw new Error(message);}
  const checkpointCodec=AquariumEcosystemCheckpointV1.create({ecology:AquariumEcology,breeding:AquariumBreeding,water:AquariumWaterEcosystem});
  const codec=AquariumTankEnvelope.createCodec({checkpointCodec,catalog:[...AquariumDesignerModel.catalog.map(({id,placement})=>({id,placement})),...['classic-stem','anubias','vallisneria','alternanthera','pixel-driftwood','slate-rock','river-rock'].map(id=>({id,placement:'transform'}))]});
  const saved=study.exportTank({id:'young-history',name:'Young history'}),domain=saved.tank.document.checkpoint.data,breeding=AquariumBreeding.create({maxAnimals:80});
  breeding.step(1,domain.ecology.animals,{shelter:1,light:1,stress:0});domain.breeding=breeding.snapshot();
  const boundary=28*86400;
  domain.ecology.seconds=boundary-1;domain.breeding.seconds=boundary-1;domain.breeding.nextCheck=boundary;domain.water.elapsedSeconds=boundary-1;saved.runtime.clock=boundary-1;saved.tank.document.checkpoint.elapsedSeconds=boundary-1;
  const live=checkpointCodec.restore(domain);live.ecology.step(1,{filter:0});
  const born=live.breeding.step(1,live.ecology.animals,{shelter:0,light:1,stress:0});live.water.step(1);
  for(const [index,child]of born.births.entries()){
   const life=live.ecology.addAnimal({id:child.id,kind:child.kind,species:child.species,surface:'floor',position:child.position});Object.assign(life,{variant:child.variant,sex:child.sex,maturity:child.maturity,isOffspring:true});
   const actor=clone(saved.runtime.actors.find(a=>a.kind==='shrimp'&&a.color===child.variant));Object.assign(actor,{id:child.id,phase:1000+index,stage:'juvenile',growthAgeDays:0,position:[child.position.x,child.position.y,child.position.z],facing:1,seenMolt:0,moltStarted:null,corpseId:null,surface:{kind:'shrimp',surface:'floor',pane:null,position:[child.position.x,child.position.y,child.position.z],facing:1}});saved.runtime.actors.push(actor);
  }
  live.breeding.synchronizeRoster(live.ecology.animals);saved.tank.document.checkpoint.data=checkpointCodec.capture(live);saved.tank.document.checkpoint.elapsedSeconds=boundary;saved.runtime.clock=boundary;
  const full=AquariumRuntimeCheckpoint.normalize(saved,codec),id=born.births[0].id,before=full.tank.document.checkpoint.data;
  check(born.births.length>0&&full.runtime.actors.length===80,'A real hatch transition must populate the child history fixture');
  const removed=AquariumRuntimeCheckpoint.removeStock(full,id,codec);
  const elapsed=checkpointCodec.restore(removed.checkpoint.tank.document.checkpoint.data);elapsed.ecology.step(60,{filter:0});elapsed.breeding.step(60,elapsed.ecology.animals,{shelter:0,light:1,stress:0});elapsed.water.step(60);
  removed.checkpoint.tank.document.checkpoint.data=checkpointCodec.capture(elapsed);removed.checkpoint.tank.document.checkpoint.elapsedSeconds+=60;removed.checkpoint.runtime.clock+=60;
  const current=removed.checkpoint.tank.document.checkpoint.data;
  check(!current.breeding.offspring.some(a=>a.id===id)&&current.breeding.stats.births===before.breeding.stats.births,'Removing young must retain cumulative births without reserving a ghost child');
  const returned=AquariumRuntimeCheckpoint.restoreStock(removed.checkpoint,removed.archive,codec),after=returned.tank.document.checkpoint.data;
  check(after.ecology.animals.find(a=>a.id===id)?.isOffspring===true&&returned.runtime.actors.find(a=>a.id===id)?.stage==='juvenile','Undo must restore the actual juvenile instead of purchasing an adult replacement');
  check(JSON.stringify(after.breeding.offspring.find(a=>a.id===id))===JSON.stringify({...before.breeding.offspring.find(a=>a.id===id),bornAt:before.breeding.offspring.find(a=>a.id===id).bornAt+60}),'The child must retain its birth identity and parent links');
  check(current.ecology.animals.every(a=>JSON.stringify(a)===JSON.stringify(after.ecology.animals.find(b=>b.id===a.id))),'Restoring young must not reset any siblings');
  check(after.breeding.serial===current.breeding.serial&&after.breeding.eventSerial===current.breeding.eventSerial&&JSON.stringify(after.breeding.stats)===JSON.stringify(before.breeding.stats)&&JSON.stringify(after.breeding.events)===JSON.stringify(before.breeding.events),'Undo must compensate only its own child-removal event without duplicating a hatch');
  return{checks};
 };
})(globalThis);
