(function(root){
 'use strict';
 root.runAquariumCheckpointStock=function(study){
  function check(value,message){if(!value)throw new Error(message);}
  const saved=study.exportTank({id:'stock-tank',name:'Stock tank'}),domain=saved.tank.document.checkpoint.data;
  const removed=domain.ecology.animals.find(a=>a.kind==='fish'&&a.species==='chili').id;
  domain.ecology.animals=domain.ecology.animals.filter(a=>a.id!==removed);
  domain.breeding.parents=domain.breeding.parents.filter(a=>a.id!==removed);
  saved.runtime.actors=saved.runtime.actors.filter(a=>a.id!==removed);
  const expected=domain.ecology.animals.map(a=>a.id);
  check(typeof study.prepareStockRemoval==='function','Stock removal must prepare a validated replacement without changing the running tank');
  const before=study.exportTank({id:'stock-tank',name:'Stock tank'});
  const replacement=study.prepareStockRemoval(removed,{id:'stock-tank',name:'Stock tank'});
  check(JSON.stringify(before)===JSON.stringify(study.exportTank({id:'stock-tank',name:'Stock tank'})),'Preparing stock removal must not mutate the live world');
  check(replacement.runtime.actors.length===before.runtime.actors.length-1&&!replacement.runtime.actors.some(a=>a.id===removed),'Removal must retain exactly the other visual bindings');
  const next=replacement.tank.document.checkpoint.data;
  check(JSON.stringify(next.ecology.food)===JSON.stringify(before.tank.document.checkpoint.data.ecology.food)&&JSON.stringify(next.water)===JSON.stringify(before.tank.document.checkpoint.data.water),'Stock removal must retain food and water chemistry');
  let rejected=false;try{study.prepareStockRemoval('missing',{id:'stock-tank',name:'Stock tank'});}catch(_){rejected=true;}
  check(rejected&&JSON.stringify(before)===JSON.stringify(study.exportTank({id:'stock-tank',name:'Stock tank'})),'Unknown stock must fail without changing state');
  study.restoreTankJSON(JSON.stringify(replacement));
  const after=study.exportTank({id:'stock-tank',name:'Stock tank'});
  check(JSON.stringify(after.tank.document.checkpoint.data.ecology.animals.map(a=>a.id))===JSON.stringify(expected),'Removed stock must not be recreated by the default roster');
  check(after.runtime.actors.length===expected.length&&!after.runtime.actors.some(a=>a.id===removed),'Every actual retained life record must have exactly one visual');
  const checkpointCodec=AquariumEcosystemCheckpointV1.create({ecology:AquariumEcology,breeding:AquariumBreeding,water:AquariumWaterEcosystem});
  const codec=AquariumTankEnvelope.createCodec({checkpointCodec,catalog:[...AquariumDesignerModel.catalog.map(({id,placement})=>({id,placement})),...['classic-stem','anubias','vallisneria','alternanthera','pixel-driftwood','slate-rock','river-rock'].map(id=>({id,placement:'transform'}))]});
  const pregnant=JSON.parse(JSON.stringify(after)),pregnantDomain=pregnant.tank.document.checkpoint.data;
  const breeding=AquariumBreeding.create({maxAnimals:80});
  breeding.step(1,pregnantDomain.ecology.animals,{shelter:1,light:1,stress:0});
  pregnantDomain.breeding=breeding.snapshot();
  const ecology=AquariumEcology.create({snapshot:pregnantDomain.ecology});ecology.step(1,{filter:0});pregnantDomain.ecology=ecology.snapshot();
  const water=AquariumWaterEcosystem.create({snapshot:pregnantDomain.water});water.step(1);pregnantDomain.water=water.snapshot();
  pregnant.tank.document.checkpoint.elapsedSeconds=pregnantDomain.ecology.seconds;
  const brood=pregnantDomain.breeding.broods.find(b=>b.phase==='berried');
  check(!!brood,'The real breeding model must produce a carried brood for this removal check');
  checkpointCodec.validate(pregnantDomain);
  const motherRemoved=AquariumRuntimeCheckpoint.removingAnimal(pregnant,brood.motherId,codec),remaining=motherRemoved.tank.document.checkpoint.data;
  check(!remaining.breeding.broods.some(b=>b.motherId===brood.motherId)&&remaining.breeding.stats.cancelledBroods===pregnantDomain.breeding.stats.cancelledBroods+1,'Removing a mother must release her reserved carried brood');
  check(remaining.ecology.stats.deaths===pregnantDomain.ecology.stats.deaths&&JSON.stringify(remaining.ecology.deposits)===JSON.stringify(pregnantDomain.ecology.deposits),'Taking an animal out must not create death or waste');
  const fatherRemoved=AquariumRuntimeCheckpoint.removingAnimal(pregnant,brood.fatherId,codec);
  check(JSON.stringify(fatherRemoved.tank.document.checkpoint.data.breeding.broods)===JSON.stringify(pregnantDomain.breeding.broods),'Removing the father must not discard a retained mother brood');
  const eggTank=JSON.parse(JSON.stringify(after)),eggDomain=eggTank.tank.document.checkpoint.data;
  const pair=eggDomain.ecology.animals.filter(a=>a.kind==='fish'&&a.species==='chili').slice(0,2);
  pair.forEach((a,i)=>{a.species='medaka';a.variant='medaka-white';a.sex=i?'female':'male';a.maturity=1;eggTank.runtime.actors.find(actor=>actor.id===a.id).fishChoice='medaka-white';});
  const eggs=AquariumBreeding.create({maxAnimals:80});eggs.step(7201,eggDomain.ecology.animals,{shelter:1,light:1,stress:0,plantSupports:[{id:'egg-plant',kind:'plant',position:pair[1].position}]});eggDomain.breeding=eggs.snapshot();
  const eggEcology=AquariumEcology.create({snapshot:eggDomain.ecology});for(let left=7201;left>0;left-=Math.min(3600,left))eggEcology.step(Math.min(3600,left),{filter:0});eggDomain.ecology=eggEcology.snapshot();
  const eggWater=AquariumWaterEcosystem.create({snapshot:eggDomain.water});eggWater.step(7201);eggDomain.water=eggWater.snapshot();eggTank.tank.document.checkpoint.elapsedSeconds=7201;
  check(eggDomain.breeding.broods.some(b=>b.phase==='deposited-eggs'&&b.motherId===pair[1].id),'The real breeding model must deposit medaka eggs for this check');
  const eggMotherRemoved=AquariumRuntimeCheckpoint.removingAnimal(eggTank,pair[1].id,codec);
  check(JSON.stringify(eggMotherRemoved.tank.document.checkpoint.data.breeding.broods)===JSON.stringify(eggDomain.breeding.broods),'Removing a mother must leave her already deposited eggs in the tank');
  study.previewLifeEvent('death');
  const dead=study.exportTank({id:'stock-tank',name:'Stock tank'}).tank.document.checkpoint.data.ecology.animals.find(a=>!a.alive);
  rejected=false;try{study.prepareStockRemoval(dead.id,{id:'stock-tank',name:'Stock tank'});}catch(_){rejected=true;}
  check(rejected,'A dead animal must use corpse cleanup rather than living-stock removal');
  return{checks:14};
 };
})(globalThis);
