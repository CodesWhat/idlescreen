(function(root){
 'use strict';
 root.runAquariumStockAddition=function(study){
  function check(value,message){if(!value)throw new Error(message);}
  check(typeof study.addStock==='function','A staged tank needs a supported animal addition command');
  root.idleScreenScene.beginEditing();study.feed({automatic:true});
  const capture=()=>study.exportTank({id:'stock-addition',name:'Stock addition'}),before=capture();
  let count=before.runtime.actors.length;
  for(const asset of AquariumTankConfiguration.stockCatalog){
   const id='stock-'+count;
   study.addStock({assetID:asset.id,id});
   const saved=capture(),life=saved.tank.document.checkpoint.data.ecology.animals.find(a=>a.id===id);
   check(saved.runtime.actors.length===++count&&life?.alive&&life.maturity===1&&life.isOffspring===false,'Every finished stock item must create one living purchased adult');
  }
  const stocked=capture(),domain=stocked.tank.document.checkpoint.data,prior=before.tank.document.checkpoint.data;
  const inventory=study.state.inventory;
  check(inventory.fish===23&&inventory.shrimp===33&&inventory.snails===4,'Inventory must count the living individuals actually added to the starter tank');
  check(inventory.fishSpecies===4&&inventory.shrimpSpecies===3&&inventory.snailSpecies===2,'Inventory must distinguish modeled species groups from color variants');
  check(before.runtime.actors.every(a=>JSON.stringify(a)===JSON.stringify(stocked.runtime.actors.find(b=>b.id===a.id))),'Adding stock must preserve every existing visual binding');
  check(prior.ecology.animals.every(a=>JSON.stringify(a)===JSON.stringify(domain.ecology.animals.find(b=>b.id===a.id))),'Adding stock must preserve the other life records');
  check(JSON.stringify(before.runtime.food)===JSON.stringify(stocked.runtime.food)&&JSON.stringify(prior.water)===JSON.stringify(domain.water),'Adding stock must preserve food motion and water chemistry');
  for(const request of [{assetID:'fish/missing',id:'stock-invalid'},{assetID:'fish/chili',id:'stock-'+before.runtime.actors.length}]){
   let rejected=false;try{study.addStock(request);}catch(_){rejected=true;}
   check(rejected&&JSON.stringify(stocked)===JSON.stringify(capture()),'Unknown and duplicate stock requests must fail before changing state');
  }
  while(count<80){study.addStock({assetID:'fish/chili',id:'stock-fill-'+count});count++;}
  const full=capture();let rejected=false;try{study.addStock({assetID:'fish/chili',id:'stock-overflow'});}catch(_){rejected=true;}
  check(rejected&&JSON.stringify(full)===JSON.stringify(capture()),'The rendering capacity must reject additions without changing state');
  check(full.tank.document.checkpoint.data.breeding.parents.filter(a=>a.alive).length===80,'Purchased adults must join the breeding roster without advancing its clock');
  check(full.tank.document.checkpoint.data.ecology.seconds===prior.ecology.seconds&&full.tank.document.checkpoint.data.breeding.seconds===prior.breeding.seconds,'Stock edits must not advance biological time');
  return{checks:46};
 };
 root.runAquariumReservedStock=function(study){
  function check(value,message){if(!value)throw new Error(message);}
  const saved=study.exportTank({id:'reserved-stock',name:'Reserved stock'}),domain=saved.tank.document.checkpoint.data;
  const breeding=AquariumBreeding.create({maxAnimals:domain.ecology.animals.length+1});
  breeding.step(1,domain.ecology.animals,{shelter:1,light:1,stress:0});domain.breeding=breeding.snapshot();
  const ecology=AquariumEcology.create({snapshot:domain.ecology});ecology.step(1,{filter:0});domain.ecology=ecology.snapshot();
  const water=AquariumWaterEcosystem.create({snapshot:domain.water});water.step(1);domain.water=water.snapshot();saved.tank.document.checkpoint.elapsedSeconds=1;
  check(domain.breeding.broods.reduce((n,b)=>n+b.count,0)===1,'The real breeding model must reserve the last stock slot');
  study.restoreTankJSON(JSON.stringify(saved));root.idleScreenScene.beginEditing();
  const capture=()=>study.exportTank({id:'reserved-stock',name:'Reserved stock'}),before=capture();
  let rejected=false;try{study.addStock({assetID:'fish/chili',id:'stock-reserved'});}catch(_){rejected=true;}
  check(rejected&&JSON.stringify(before)===JSON.stringify(capture()),'A reserved brood slot must reject a purchase before changing the staged tank');
  return{checks:2};
 };
})(globalThis);
