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
  study.restoreTankJSON(JSON.stringify(saved));
  const after=study.exportTank({id:'stock-tank',name:'Stock tank'});
  check(JSON.stringify(after.tank.document.checkpoint.data.ecology.animals.map(a=>a.id))===JSON.stringify(expected),'Removed stock must not be recreated by the default roster');
  check(after.runtime.actors.length===expected.length&&!after.runtime.actors.some(a=>a.id===removed),'Every actual retained life record must have exactly one visual');
  return{checks:2};
 };
})(globalThis);
