(function(root){
 'use strict';
 const HOUR=3600,DAY=24*HOUR,MAX_DEPOSITS=256;
 const clamp=(n,lo=0,hi=1)=>Math.max(lo,Math.min(hi,n));
 const distance=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y,a.z-b.z);
 const copy=p=>({x:p.x,y:p.y,z:p.z});
 function validPosition(p){if(!p||![p.x,p.y,p.z].every(Number.isFinite))throw new Error('Finite animal coordinates required');return copy(p);}
 function create(options={}){
  let seed=options.seed??8401,seconds=0,serial=0;
  let animals=[],food=[],deposits=[],patches=[],events=[];
  let stats={feces:0,molts:0,deaths:0,eaten:0,algaeEaten:0,dissolved:0,filtered:0};
  function random(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;}
  function event(kind,id){events.push({kind,id,at:seconds});if(events.length>32)events.shift();}
  function addAnimal(input){
   const existing=animals.find(a=>a.id===input.id);if(existing)return existing;
   if(!['fish','shrimp','snail'].includes(input.kind)||typeof input.id!=='string')throw new Error('Known animal kind and stable id required');
   const lifespan=input.lifespanDays??(input.kind==='shrimp'?360:720)*(1+random()*.3);
   const a={id:input.id,kind:input.kind,species:input.species,surface:input.surface||'free',position:validPosition(input.position),alive:true,state:'forage',hunger:.35,health:1,gut:0,poop:0,ageDays:input.ageDays??0,lifespanDays:lifespan,moltDue:input.moltDue??seconds+(21+random()*14)*DAY,recoveryUntil:0,target:null};
   animals.push(a);return a;
  }
  function addFood(input){if(food.some(f=>f.id===input.id))throw new Error('Food id must be unique');const f={id:input.id,position:validPosition(input.position),amount:clamp(input.amount??.1,0,1),age:0};food.push(f);return f;}
  function addDeposit(kind,position,amount){
   if(!['feces','molt','corpse','uneaten'].includes(kind)||!Number.isFinite(amount)||amount<=0)return null;
   const d={id:'deposit-'+(++serial),kind,position:validPosition(position),amount,initial:amount,age:0};
   if(deposits.length>=MAX_DEPOSITS)stats.dissolved+=deposits.shift().amount;
   deposits.push(d);return d;
  }
  function retireFood(id){const i=food.findIndex(f=>f.id===id);if(i<0)return;const f=food[i];if(f.amount>1e-5)addDeposit('uneaten',f.position,f.amount);food.splice(i,1);}
  function addPatch(input){const p={id:input.id,position:validPosition(input.position),amount:clamp(input.amount??.3)};patches.push(p);return p;}
  function die(a,reason){if(!a.alive)return;a.alive=false;a.state='dead';a.reason=reason;a.target=null;const corpse=addDeposit('corpse',a.position,a.kind==='fish'?.8:a.kind==='shrimp'?.3:.5);corpse.owner=a.id;stats.deaths++;event('death',a.id);}
  function beginMolt(a){if(!a.alive||a.kind!=='shrimp')return;a.state='recover';a.recoveryUntil=seconds+2*HOUR;a.moltDue=seconds+(21+random()*14)*DAY;const shell=addDeposit('molt',a.position,.04);if(shell){shell.owner=a.id;shell.supportY=a.position.y;}a.moltCount=(a.moltCount||0)+1;a.target=null;stats.molts++;event('molt',a.id);}
  function candidates(a){
   const choices=food.filter(f=>f.amount>.001).map(f=>({item:f,kind:'food'}));
   if(a.kind!=='fish')for(const d of deposits)if(d.amount>.001&&['corpse','uneaten','molt'].includes(d.kind)&&!(a.species==='assassin'&&d.kind==='molt'))choices.push({item:d,kind:'scavenge'});
   if(a.kind==='shrimp'||a.species==='otocinclus'||(a.kind==='snail'&&a.species==='nerite'))for(const p of patches)if(p.amount>.005)choices.push({item:p,kind:'graze'});
   return a.surface==='glass'?choices.filter(choice=>Math.abs(choice.item.position.z-a.position.z)<.12):a.surface==='floor'?choices.filter(choice=>choice.kind!=='graze'||Math.abs(choice.item.position.y-a.position.y)<.3):choices;
  }
  function advance(dt,env){
   seconds+=dt;
   const light=clamp(env.light??.5),filter=clamp(env.filter??1),stress=clamp(env.stress??0),nutrients=env.nutrients??stats.dissolved;
   for(const f of food){f.age+=dt;}
   // Game quantities, not a prediction of measured aquarium chemistry.
   for(const d of deposits){
    d.age+=dt;const lifetime=d.kind==='molt'?7*DAY:d.kind==='corpse'?36*HOUR:24*HOUR;
    const loss=d.amount*(1-Math.exp(-dt/lifetime));d.amount-=loss;stats.dissolved+=loss;
   }
   deposits=deposits.filter(d=>d.amount>.0001);
   const removed=stats.dissolved*(1-Math.exp(-dt*filter/(6*HOUR)));stats.dissolved-=removed;stats.filtered+=removed;
   for(const p of patches)p.amount=clamp(p.amount+dt/DAY*.08*light*(.2+Math.min(2,nutrients))*(1-p.amount));
   for(const a of animals){
    if(!a.alive)continue;
    a.ageDays+=dt/DAY;a.hunger=clamp(a.hunger+dt/(16*HOUR));
    const digest=a.gut*(1-Math.exp(-dt/(.5*HOUR)));a.gut-=digest;a.poop+=digest*.35;
    if(a.poop>=.025){const waste=addDeposit('feces',a.position,a.poop);waste.owner=a.id;a.poop=0;stats.feces++;}
    const damage=stress*dt/(24*HOUR)*(a.state==='recover'?1.5:1)+(a.hunger>.98?dt/(72*HOUR):0);
    a.health=clamp(a.health-damage+(stress===0&&a.hunger<.8?dt/(7*DAY):0));
    if(a.health<=0||a.ageDays>=a.lifespanDays){die(a,a.health<=0?'sustained stress or starvation':'old age');continue;}
    if(a.kind==='shrimp'&&seconds>=a.moltDue){beginMolt(a);continue;}
    if(a.state==='recover'&&seconds<a.recoveryUntil){a.target=null;continue;}
    if(a.kind==='shrimp'&&a.moltDue-seconds<6*HOUR){a.state='premolt';a.target=null;continue;}
    let nearest=null,best=Infinity;
    if(a.hunger>.12)for(const choice of candidates(a)){
     const d=distance(a.position,choice.item.position),weighted=d+(choice.kind==='graze'?.3:0);
     if(weighted<best){best=weighted;nearest=choice;}
    }
    a.target=nearest?{id:nearest.item.id,kind:nearest.kind,position:copy(nearest.item.position)}:null;
    a.state=nearest?'approach':'rest';
    if(nearest&&distance(a.position,nearest.item.position)<(a.kind==='fish'?.55:.34)&&(!env.canReach||env.canReach(a.position,nearest.item.position))){
     const bite=Math.min(nearest.item.amount,dt*.002,Math.max(0,a.hunger)*.25);
     nearest.item.amount-=bite;a.gut+=bite;a.hunger=clamp(a.hunger-bite*3);a.state=nearest.kind==='graze'?'graze':'eat';stats.eaten+=bite;if(nearest.kind==='graze')stats.algaeEaten+=bite;
    }
   }
  }
  function step(dt,env={}){if(!Number.isFinite(dt)||dt<=0)return;let left=Math.min(dt,HOUR);while(left>1e-8){const amount=Math.min(30,left);advance(amount,env);left-=amount;}}
  function retireDeadAnimal(id){const a=animals.find(a=>a.id===id);if(!a||a.alive||deposits.some(d=>d.kind==='corpse'&&d.owner===id))return false;animals=animals.filter(a=>a.id!==id);return true;}
  function cleanSubstrate(fraction){
   if(!Number.isFinite(fraction)||fraction<0||fraction>1)throw new RangeError('Cleaning fraction must be between zero and one');
   let removed=0;for(const deposit of deposits)if(['feces','uneaten'].includes(deposit.kind)){const amount=deposit.amount*fraction;removed+=amount;deposit.amount-=amount;}
   deposits=deposits.filter(deposit=>deposit.amount>.0001);return removed;
  }
  function snapshot(){return JSON.parse(JSON.stringify({seed,seconds,serial,animals,food,deposits,patches,events,stats}));}
  if(options.snapshot){const s=JSON.parse(JSON.stringify(options.snapshot));({seed,seconds,serial,animals,food,deposits,patches,events,stats}=s);}
  return{cleanSubstrate,addAnimal,retireDeadAnimal,addFood,retireFood,addDeposit,addPatch,step,beginMolt,die,snapshot,get seconds(){return seconds;},get animals(){return animals;},get food(){return food;},get deposits(){return deposits;},get patches(){return patches;},get events(){return events;},get stats(){return stats;}};
 }
 const api={create};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumEcology=api;
})(typeof window==='object'?window:globalThis);
