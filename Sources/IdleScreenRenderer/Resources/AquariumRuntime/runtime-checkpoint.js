(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory(require('./tank-configuration.js'));
 else root.AquariumRuntimeCheckpoint=factory(root.AquariumTankConfiguration);
})(globalThis,function(configuration){
 'use strict';
 const maxChars=4194304,maxStockArchiveBytes=65536;
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
 function changingSettings(input,settings,codec){
  fields(settings,['light','room','surface','pump','rasterHeight']);
  const result=normalize(input,codec);
  result.tank.configuration=configuration.normalize({...result.tank.configuration,...settings});
  return normalize(result,codec);
 }
 function removeStock(input,id,codec){
  const result=normalize(input,codec),domain=result.tank.document.checkpoint.data,breeding=domain.breeding;
  if(typeof id!=='string'||!domain.ecology.animals.some(a=>a.id===id&&a.alive))fail('choose a living animal to remove');
  const broods=breeding.broods.filter(b=>b.motherId===id&&b.phase!=='deposited-eggs'),parent=breeding.parents.find(a=>a.id===id)||null,offspring=breeding.offspring.find(a=>a.id===id)||null,serial=breeding.eventSerial;
  const archive={schemaVersion:1,documentID:result.tank.document.id,ecologySeconds:domain.ecology.seconds,breedingSeconds:breeding.seconds,sceneClock:result.runtime.clock,
   life:domain.ecology.animals.find(a=>a.id===id),actor:result.runtime.actors.find(a=>a.id===id),parent,offspring,broods,endedEvents:[],
   indices:{life:domain.ecology.animals.findIndex(a=>a.id===id),actor:result.runtime.actors.findIndex(a=>a.id===id),parent:parent?breeding.parents.indexOf(parent):null,offspring:offspring?breeding.offspring.indexOf(offspring):null,broods:broods.map(b=>breeding.broods.indexOf(b))}};
  domain.ecology.animals=domain.ecology.animals.filter(a=>a.id!==id);
  result.runtime.actors=result.runtime.actors.filter(a=>a.id!==id);
  function event(kind,detail){breeding.events.push({id:++breeding.eventSerial,kind,at:breeding.seconds,...detail});if(breeding.events.length>64)breeding.events.shift();}
  for(const brood of broods){breeding.stats.cancelledBroods++;event('brood-ended',{broodId:brood.id,motherId:id,reason:'mother-unavailable'});}
  breeding.broods=breeding.broods.filter(b=>b.motherId!==id||b.phase==='deposited-eggs');
  if(offspring)event('offspring-removed',{animalId:id});
  breeding.offspring=breeding.offspring.filter(a=>a.id!==id);
  breeding.parents=breeding.parents.filter(a=>a.id!==id);
  archive.endedEvents=breeding.events.filter(e=>e.id>serial);
  const text=JSON.stringify(archive);if(text.length>maxStockArchiveBytes||new TextEncoder().encode(text).byteLength>maxStockArchiveBytes)fail('animal history exceeds its size limit');
  return{checkpoint:normalize(result,codec),archive:text};
 }
 function removingAnimal(input,id,codec){return removeStock(input,id,codec).checkpoint;}
 function stockArchive(text){
  if(typeof text!=='string'||text.length>maxStockArchiveBytes||new TextEncoder().encode(text).byteLength>maxStockArchiveBytes)fail('bounded animal history JSON required');
  let a;try{a=JSON.parse(text);}catch(_){fail('animal history JSON could not be parsed');}
  fields(a,['schemaVersion','documentID','ecologySeconds','breedingSeconds','sceneClock','life','actor','parent','offspring','broods','endedEvents','indices']);
  if(a.schemaVersion!==1)fail('unsupported animal history schema');
  number(a.ecologySeconds,0);number(a.breedingSeconds,0);number(a.sceneClock,0);
  const id=a.life?.id;if(typeof id!=='string'||!id||a.life.alive!==true||a.actor?.id!==id||a.parent!==null&&a.parent?.id!==id||a.offspring!==null&&a.offspring?.id!==id)fail('animal history identities disagree');
  fields(a.indices,['life','actor','parent','offspring','broods']);
  function index(value,max=255){count(value);if(value>max)fail('animal history index exceeds capacity');}
  index(a.indices.life,79);index(a.indices.actor,79);
  for(const key of ['parent','offspring']){if(a[key]===null){if(a.indices[key]!==null)fail('animal history index disagrees');}else index(a.indices[key]);}
  if(!Array.isArray(a.broods)||a.broods.length>1||!Array.isArray(a.indices.broods)||a.indices.broods.length!==a.broods.length)fail('invalid carried brood history');
  a.indices.broods.forEach(value=>index(value));
  for(const b of a.broods)if(!b||b.motherId!==id||b.phase==='deposited-eggs')fail('animal history contains an unrelated brood');
  if(!Array.isArray(a.endedEvents)||a.endedEvents.length!==a.broods.length+(a.offspring?1:0))fail('animal history cancellation records disagree');
  const seen=new Set(),broodIDs=new Set();let childEvent=false;
  for(const e of a.endedEvents){
   if(e?.kind==='brood-ended'){
    fields(e,['id','kind','at','broodId','motherId','reason']);
    if(e.motherId!==id||e.reason!=='mother-unavailable'||!a.broods.some(b=>b.id===e.broodId)||broodIDs.has(e.broodId))fail('animal history contains an unrelated cancellation');
    broodIDs.add(e.broodId);
   }else if(e?.kind==='offspring-removed'){
    fields(e,['id','kind','at','animalId']);if(!a.offspring||e.animalId!==id||childEvent)fail('animal history contains an unrelated offspring event');childEvent=true;
   }else fail('unsupported animal history event');
   count(e.id);if(e.id<1||seen.has(e.id))fail('animal history event identities disagree');seen.add(e.id);number(e.at,a.breedingSeconds,a.breedingSeconds);
  }
  return a;
 }
 function restoreStock(input,text,codec){
  const result=normalize(input,codec),a=stockArchive(text),domain=result.tank.document.checkpoint.data,b=domain.breeding,id=a.life.id;
  if(a.documentID!==result.tank.document.id)fail('animal history belongs to another tank');
  const ecologyDelta=domain.ecology.seconds-a.ecologySeconds,breedingDelta=b.seconds-a.breedingSeconds,sceneDelta=result.runtime.clock-a.sceneClock;
  [ecologyDelta,breedingDelta,sceneDelta].forEach(delta=>number(delta,0));
  if(domain.ecology.animals.some(v=>v.id===id)||b.parents.some(v=>v.id===id)||b.offspring.some(v=>v.id===id))fail('animal identity is already present');
  const population=new Set([...domain.ecology.animals.filter(v=>v.alive).map(v=>v.id),...b.offspring.map(v=>v.id)]),pending=[...b.broods,...a.broods].reduce((n,v)=>n+v.count,0);
  if(domain.ecology.animals.length>=80||population.size+1+pending>Math.min(80,b.maxAnimals))fail('animal history no longer fits the tank capacity');
  if(a.broods.some(v=>b.broods.some(current=>current.id===v.id))||b.stats.cancelledBroods<a.broods.length)fail('carried brood history conflicts with the current tank');
  for(const event of a.endedEvents){
   if(event.id>b.eventSerial)fail('animal history event is newer than the tank');
   const current=b.events.find(e=>e.id===event.id);if(current&&(Object.keys(current).length!==Object.keys(event).length||Object.keys(event).some(key=>current[key]!==event[key])))fail('animal history event ownership disagrees');
  }
  a.life.moltDue+=ecologyDelta;a.life.recoveryUntil+=ecologyDelta;
  if(a.actor.moltStarted!==null)a.actor.moltStarted+=sceneDelta;
  if(a.parent)a.parent.nextEligible+=breedingDelta;
  if(a.offspring)a.offspring.bornAt+=breedingDelta;
  for(const brood of a.broods){brood.startedAt+=breedingDelta;brood.nextAt+=breedingDelta;}
  function insert(list,index,value){list.splice(Math.min(index,list.length),0,value);}
  insert(domain.ecology.animals,a.indices.life,a.life);insert(result.runtime.actors,a.indices.actor,a.actor);
  if(a.parent)insert(b.parents,a.indices.parent,a.parent);if(a.offspring)insert(b.offspring,a.indices.offspring,a.offspring);
  a.broods.forEach((brood,i)=>insert(b.broods,a.indices.broods[i],brood));
  const owned=new Set(a.endedEvents.map(e=>e.id));b.events=b.events.filter(e=>!owned.has(e.id));b.stats.cancelledBroods-=a.broods.length;
  return normalize(result,codec);
 }
 function importJSON(text,codec){
  if(typeof text!=='string'||text.length>maxChars)fail('bounded JSON text required');
  return normalize(JSON.parse(text),codec);
 }
 return Object.freeze({normalize,importJSON,changingSettings,removingAnimal,removeStock,restoreStock,maxChars,maxStockArchiveBytes});
});
