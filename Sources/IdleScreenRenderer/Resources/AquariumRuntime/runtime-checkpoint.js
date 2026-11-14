(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory(require('./tank-configuration.js'));
 else root.AquariumRuntimeCheckpoint=factory(root.AquariumTankConfiguration);
})(globalThis,function(configuration){
 'use strict';
 const maxChars=4194304;
 function fail(message){throw new TypeError('Tank checkpoint: '+message);}
 function fields(value,keys){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).length!==keys.length||keys.some(k=>!Object.prototype.hasOwnProperty.call(value,k)))fail('unsupported or missing fields');
 }
 function number(value,minimum=-1e12,maximum=1e12){if(typeof value!=='number'||!Number.isFinite(value)||value<minimum||value>maximum)fail('finite bounded number required');}
 function count(value){number(value,0,Number.MAX_SAFE_INTEGER-1);if(!Number.isSafeInteger(value))fail('safe counter required');}
 function choice(value,choices){if(!choices.includes(value))fail('unsupported value');}
 function boolean(value){if(typeof value!=='boolean')fail('boolean required');}
 function vector(value,size=3){if(!Array.isArray(value)||value.length!==size)fail('vector required');value.forEach(v=>number(v,-100,100));}
 function quaternion(value){vector(value,4);if(Math.abs(Math.hypot(...value)-1)>1e-6)fail('unit quaternion required');}
 function identities(records,models){
  if(!Array.isArray(records)||records.length!==models.length)fail('every model needs one visual binding');
  const known=new Set(models.map(m=>m.id)),seen=new Set();
  for(const entry of records){if(!known.has(entry?.id)||seen.has(entry.id))fail('unknown or duplicate visual binding');seen.add(entry.id);}
 }
 function normalize(input,codec){
  fields(input,['schemaVersion','tank','runtime']);if(input.schemaVersion!==1)fail('unsupported schema');
  const tank=codec.normalize(input.tank),checkpoint=tank.document.checkpoint?.data;
  if(!checkpoint)fail('complete ecosystem state is required');
  if(checkpoint.ecology.animals.length>80||checkpoint.ecology.food.length>10||checkpoint.ecology.patches.length>16)fail('native rendering capacity exceeded');
  const r=input.runtime;
  fields(r,['clock','ecologyRate','conditionLevel','conditionEpoch','conditionStart','feedStarted','feedSequence','automaticFeedCount','manualFeedCount','lastFeedReason','nextFeedDue','actors','food']);
  number(r.clock,0);choice(r.ecologyRate,[1,120,3600]);number(r.conditionLevel,0,1);number(r.conditionEpoch,0,r.clock);number(r.conditionStart,0,1);number(r.feedStarted,-100,r.clock);number(r.nextFeedDue,0);
  [r.feedSequence,r.automaticFeedCount,r.manualFeedCount].forEach(count);
  if(r.feedSequence!==r.automaticFeedCount+r.manualFeedCount)fail('feeding history disagrees');
  choice(r.lastFeedReason,r.feedSequence?["automatic","manual"]:[null]);
  identities(r.actors,checkpoint.ecology.animals);identities(r.food,checkpoint.ecology.food);
  for(const a of r.actors){
   fields(a,['id','kind','phase','facing','fishChoice','color','stage','growthAgeDays','position','quaternion','visible','seenMolt','moltStarted','corpseId','surface']);
   const life=checkpoint.ecology.animals.find(l=>l.id===a.id);
   if(a.kind!==life.kind)fail('actor kind disagrees with life');number(a.phase,0);choice(a.facing,[-1,1]);
   choice(a.fishChoice,configuration.choices.assets.fish);
   choice(a.stage,['adult','female','juvenile','fry','berried','gravid','egg-carrying']);
   choice(a.color,a.kind==='shrimp'?[...configuration.choices.assets.shrimp,'yellow','blue','orange']:[null]);
   choice(life.species,a.kind==='fish'?['chili','medaka','guppy','otocinclus']:a.kind==='shrimp'?['cherry','amano','bee']:['assassin','nerite']);
   if(life.variant!==(a.kind==='fish'?a.fishChoice:a.color))fail('art variant disagrees with life');
   if(a.growthAgeDays!==null)number(a.growthAgeDays,0);vector(a.position);quaternion(a.quaternion);boolean(a.visible);count(a.seenMolt);
   if(a.moltStarted!==null)number(a.moltStarted,0,r.clock);
   if(a.corpseId!==null&&!checkpoint.ecology.deposits.some(d=>d.id===a.corpseId&&d.kind==='corpse'&&d.owner===a.id))fail('corpse binding is missing');
   if(a.surface!==null){fields(a.surface,['kind','surface','pane','position','facing']);choice(a.surface.kind,[life.species==='otocinclus'?'otocinclus':a.kind]);choice(a.surface.surface,['floor','glass']);choice(a.surface.pane,a.surface.surface==='glass'?['front','left','right','back']:[null]);vector(a.surface.position);choice(a.surface.facing,[-1,1]);}
   if((a.kind!=='fish'||life.species==='otocinclus')!==(a.surface!==null))fail('surface binding is missing');
  }
  for(const p of r.food){
   fields(p,['id','position','velocity','quaternion','visible','delay','lastT','settled','landedOn']);
   vector(p.position);vector(p.velocity);quaternion(p.quaternion);boolean(p.visible);number(p.delay,0,10);number(p.lastT,0);boolean(p.settled);choice(p.landedOn,[null,'solid','glass','floor']);
  }
  const result={schemaVersion:1,tank,runtime:r};
  if(JSON.stringify(result).length>maxChars)fail('document exceeds size limit');
  return JSON.parse(JSON.stringify(result));
 }
 function removingAnimal(input,id,codec){
  const result=normalize(input,codec),domain=result.tank.document.checkpoint.data;
  if(typeof id!=='string'||!domain.ecology.animals.some(a=>a.id===id&&a.alive))fail('choose a living animal to remove');
  domain.ecology.animals=domain.ecology.animals.filter(a=>a.id!==id);
  result.runtime.actors=result.runtime.actors.filter(a=>a.id!==id);
  const breeding=domain.breeding;
  function event(kind,detail){breeding.events.push({id:++breeding.eventSerial,kind,at:breeding.seconds,...detail});if(breeding.events.length>64)breeding.events.shift();}
  for(const brood of breeding.broods){
   if(brood.motherId===id&&brood.phase!=='deposited-eggs'){
    breeding.stats.cancelledBroods++;
    event('brood-ended',{broodId:brood.id,motherId:id,reason:'mother-unavailable'});
   }
  }
  breeding.broods=breeding.broods.filter(b=>b.motherId!==id||b.phase==='deposited-eggs');
  if(breeding.offspring.some(a=>a.id===id))event('offspring-removed',{animalId:id});
  breeding.offspring=breeding.offspring.filter(a=>a.id!==id);
  breeding.parents=breeding.parents.filter(a=>a.id!==id);
  return normalize(result,codec);
 }
 function importJSON(text,codec){
  if(typeof text!=='string'||text.length>maxChars)fail('bounded JSON text required');
  return normalize(JSON.parse(text),codec);
 }
 return Object.freeze({normalize,importJSON,removingAnimal,maxChars});
});
