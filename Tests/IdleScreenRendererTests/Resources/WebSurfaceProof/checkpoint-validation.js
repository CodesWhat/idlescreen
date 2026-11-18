(function(root){
 'use strict';
 root.runAquariumCheckpointValidation=function(study){
  function check(value,message){if(!value)throw new Error(message);}
  const original=study.exportTank({id:'validation-tank',name:'Validation tank'});
  const before=JSON.stringify({revision:study.state.presetRevision,designer:study.designer,ecology:study.state.ecology,feeding:study.state.feeding});
  const mutations=[
   s=>{s.runtime.actors[0].fishChoice='unbuilt-future-fish';},
   s=>{s.runtime.actors[0].stage='unbuilt-stage';},
   s=>{s.runtime.actors.find(a=>a.kind==='shrimp').color='unbuilt-shrimp';},
   s=>{s.runtime.actors.find(a=>a.kind==='shrimp').surface.kind='snail';},
   s=>{s.runtime.actors[0].position=[Infinity,0,0];},
   s=>{s.runtime.actors.pop();},
   s=>{s.runtime.actors[0].quaternion=[0,0,0,0];},
   s=>{s.runtime.feedSequence=10;},
   s=>{s.runtime.extra='must reject';}
  ];
  for(const mutate of mutations){
   const saved=JSON.parse(JSON.stringify(original));mutate(saved);let error;
   try{study.restoreTankJSON(JSON.stringify(saved));}catch(e){error=e;}
   check(!!error,'Invalid or unsupported saved state must be rejected before rebuilding');
   check(error.message.startsWith('Tank checkpoint:'),'Native validation must reject the actual bad data, not a previous failed load');
   check(JSON.stringify({revision:study.state.presetRevision,designer:study.designer,ecology:study.state.ecology,feeding:study.state.feeding})===before,'Rejected checkpoint mutated the fresh runtime');
  }
  return{checks:mutations.length};
 };
})(globalThis);
