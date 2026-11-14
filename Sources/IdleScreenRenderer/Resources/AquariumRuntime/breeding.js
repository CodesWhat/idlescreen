(function(root){
  'use strict';
  const HOUR=3600,DAY=24*HOUR,CHECK=6*HOUR,MAX_EVENTS=64,VERSION=1;
  const profiles=Object.freeze({
    neocaridina:Object.freeze({kind:'shrimp',development:'direct',incubation:28*DAY,cooldown:7*DAY,matureAge:90*DAY,youngStage:'juvenile',initialSize:.10,broodMin:20,broodMax:30}),
    guppy:Object.freeze({kind:'fish',development:'livebearing',incubation:30*DAY,cooldown:DAY,matureAge:90*DAY,youngStage:'fry',initialSize:.18,broodMin:8,broodMax:16}),
    medaka:Object.freeze({kind:'fish',development:'external-eggs',incubation:10*DAY,carry:2*HOUR,cooldown:DAY,matureAge:90*DAY,youngStage:'fry',initialSize:.16,broodMin:4,broodMax:8}),
    amano:Object.freeze({kind:'shrimp',development:'brackish-larvae',incubation:28*DAY,cooldown:14*DAY,matureAge:120*DAY,youngStage:null,initialSize:0,broodMin:0,broodMax:0}),
  });
  const aliases={cherry:'neocaridina','neocaridina-davidi':'neocaridina','neocaridina-color':'neocaridina','amano-shrimp':'amano','caridina-multidentata':'amano','poecilia-reticulata':'guppy','oryzias-latipes':'medaka'};
  const clone=value=>JSON.parse(JSON.stringify(value));
  const clamp=n=>Math.max(0,Math.min(1,n));
  const point=p=>p&&[p.x,p.y,p.z].every(Number.isFinite);
  const copyPoint=p=>({x:p.x,y:p.y,z:p.z});
  const distance=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y,a.z-b.z);
  function familyOf(animal){const name=String(animal.family||animal.species||'').toLowerCase().replace(/\s+/g,'-');return profiles[name]?name:aliases[name]||null;}

  function create(options={}){
    let seed=(options.seed??8401)>>>0,seconds=0,nextCheck=0,serial=0,eventSerial=0;
    let maxAnimals=options.maxAnimals??80,parents=new Map(),young=new Map(),broods=[],events=[];
    let stats={conceptions:0,births:0,hatchedBroods:0,larvalReleases:0,cancelledBroods:0,failedDeposits:0,lostEggs:0,capacitySuppressed:0};
    if(options.snapshot){
      const s=clone(options.snapshot);
      if(s.version!==VERSION||!Number.isSafeInteger(s.maxAnimals)||!Number.isFinite(s.seconds)||s.seconds<0||!Number.isFinite(s.nextCheck)||s.nextCheck<s.seconds||
          !Number.isSafeInteger(s.seed)||!Number.isSafeInteger(s.serial)||!Number.isSafeInteger(s.eventSerial)||!Array.isArray(s.parents)||!Array.isArray(s.offspring)||!Array.isArray(s.broods)||!Array.isArray(s.events))throw new Error('Invalid breeding snapshot');
      ({seed,seconds,nextCheck,serial,eventSerial,maxAnimals,stats}=s);
      if(!stats||Object.values(stats).some(n=>!Number.isFinite(n)||n<0)||s.parents.length>maxAnimals||s.offspring.length>maxAnimals||s.broods.length>maxAnimals||s.events.length>MAX_EVENTS)throw new Error('Invalid breeding snapshot bounds');
      for(const a of s.parents)if(!a||typeof a.id!=='string'||!point(a.position)||!Number.isFinite(a.nextEligible))throw new Error('Invalid breeding snapshot parent');
      for(const a of s.offspring)if(!a||typeof a.id!=='string'||!profiles[a.family]||!point(a.position)||!Number.isFinite(a.bornAt)||a.bornAt>seconds)throw new Error('Invalid breeding snapshot offspring');
      for(const b of s.broods)if(!b||!profiles[b.family]||!Number.isFinite(b.nextAt)||b.nextAt<seconds||!Number.isInteger(b.count)||b.count<0||b.count>maxAnimals)throw new Error('Invalid breeding snapshot brood');
      parents=new Map(s.parents.map(a=>[a.id,a]));young=new Map(s.offspring.map(a=>[a.id,a]));broods=s.broods;events=s.events;
      if(parents.size!==s.parents.length||young.size!==s.offspring.length)throw new Error('Duplicate breeding snapshot ids');
    }
    if(!Number.isSafeInteger(maxAnimals)||maxAnimals<1||maxAnimals>256)throw new RangeError('Population capacity must be between 1 and 256');
    function random(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;}
    function emit(kind,detail,output){const e={id:++eventSerial,kind,at:seconds,...detail};events.push(e);if(events.length>MAX_EVENTS)events.shift();if(output){output.events.push(e);if(output.events.length>MAX_EVENTS)output.events.shift();}}
    function livingCount(){const ids=new Set([...young.keys()]);for(const a of parents.values())if(a.alive)ids.add(a.id);return ids.size;}
    function reserved(){return broods.reduce((sum,b)=>sum+b.count,0);}
    function cancel(b,reason,output){
      broods=broods.filter(candidate=>candidate!==b);
      if(reason==='missing-support')stats.lostEggs+=b.count;
      else if(reason==='no-deposit')stats.failedDeposits++;
      else stats.cancelledBroods++;
      emit('brood-ended',{broodId:b.id,motherId:b.motherId,reason},output);
    }
    function supportsFor(env){
      const supplied=env.plantSupports||[];
      if(!Array.isArray(supplied)||supplied.length>256)throw new Error('Plant support budget is 256 finite contacts');
      const supports=new Map();
      for(const site of supplied){
        if(!site||typeof site.id!=='string'||!point(site.position)||supports.has(site.id))throw new Error('Unique plant support ids and finite positions required');
        if(site.kind==='plant'&&site.reachable!==false)supports.set(site.id,{id:site.id,position:copyPoint(site.position)});
      }
      return supports;
    }
    function nearestSupport(position,supports){let best=null,d=Infinity;for(const support of supports.values()){const next=distance(position,support.position);if(next<d){best=support;d=next;}}return best;}
    function synchronize(roster,supports,output){
      if(!Array.isArray(roster)||roster.length>maxAnimals)throw new Error('Animal roster exceeds population capacity');
      const next=new Map();
      for(const input of [...roster].sort((a,b)=>String(a.id).localeCompare(String(b.id)))){
        if(!input||typeof input.id!=='string'||!point(input.position)||next.has(input.id))throw new Error('Unique animal ids and finite positions required');
        const old=parents.get(input.id),family=familyOf(input);
        const a={id:input.id,kind:input.kind,species:String(input.species||''),family,sex:input.sex==='female'?'female':input.sex==='male'?'male':'unknown',maturity:input.maturity===true?1:Number.isFinite(input.maturity)?clamp(input.maturity):0,alive:input.alive===true,position:copyPoint(input.position),habitat:input.habitat||'freshwater',variant:input.variant??null,nextEligible:old?.nextEligible??seconds};
        next.set(a.id,a);
      }
      const population=new Set([...young.keys()].filter(id=>!next.has(id)||next.get(id).alive));
      for(const a of next.values())if(a.alive)population.add(a.id);
      const pending=broods.filter(b=>b.phase==='deposited-eggs'?supports.has(b.supportId):next.get(b.motherId)?.alive&&next.get(b.motherId).family===b.family).reduce((sum,b)=>sum+b.count,0);
      if(population.size+pending>maxAnimals)throw new Error('Combined living population and reserved broods exceed capacity');
      parents=next;
      for(const a of parents.values())if(young.has(a.id)){if(!a.alive){young.delete(a.id);emit('offspring-removed',{animalId:a.id},output);}else young.get(a.id).position=copyPoint(a.position);}
      for(const b of [...broods]){
        if(b.phase==='deposited-eggs'){
          const support=supports.get(b.supportId);
          if(!support)cancel(b,'missing-support',output);else b.position=copyPoint(support.position);
        }else{
          const mother=parents.get(b.motherId);
          if(!mother?.alive||mother.sex!=='female'||mother.family!==b.family)cancel(b,'mother-unavailable',output);
          else if(b.phase==='carried-eggs'){const site=nearestSupport(mother.position,supports);b.target=site?{kind:'egg-site',supportId:site.id,position:copyPoint(site.position)}:null;}
        }
      }
    }
    function ready(a,profile){return a.alive&&a.kind===profile.kind&&a.maturity>=1&&a.habitat==='freshwater';}
    function tryConceptions(env,supports,output){
      if((env.habitat??'freshwater')!=='freshwater'||(env.shelter??0)<.2||(env.light??0)<.25||(env.stress??0)>.35)return;
      const activeMothers=new Set(broods.filter(b=>b.phase!=='deposited-eggs').map(b=>b.motherId));
      const males=new Map();
      for(const a of parents.values())if(a.family&&a.sex==='male'&&ready(a,profiles[a.family])&&!males.has(a.family))males.set(a.family,a);
      for(const mother of parents.values()){
        const profile=profiles[mother.family];
        if(!profile||mother.sex!=='female'||!ready(mother,profile)||mother.nextEligible>seconds||activeMothers.has(mother.id))continue;
        const father=males.get(mother.family);if(!father)continue;
        const capacity=Math.max(0,maxAnimals-livingCount()-reserved());
        if(!capacity&&mother.family!=='amano')continue;
        const proposed=profile.broodMin+Math.floor(random()*(profile.broodMax-profile.broodMin+1));
        const count=Math.min(capacity,proposed);
        const b={id:'brood-'+(++serial),motherId:mother.id,fatherId:father.id,family:mother.family,kind:mother.kind,species:mother.species,variant:mother.variant,count,startedAt:seconds,phase:mother.family==='guppy'?'gravid':mother.family==='medaka'?'carried-eggs':'berried',nextAt:seconds+(profile.carry||profile.incubation),supportId:null,position:copyPoint(mother.position)};
        if(mother.family==='medaka'){const site=nearestSupport(mother.position,supports);b.target=site?{kind:'egg-site',supportId:site.id,position:copyPoint(site.position)}:null;}
        broods.push(b);mother.nextEligible=seconds+profile.cooldown;stats.conceptions++;stats.capacitySuppressed+=proposed-count;
        emit('conception',{broodId:b.id,motherId:mother.id,fatherId:father.id,family:mother.family,phase:b.phase},output);
      }
    }
    function finishBrood(b,position,supports,output){
      const profile=profiles[b.family],mother=parents.get(b.motherId);
      broods=broods.filter(candidate=>candidate!==b);
      if(mother)mother.nextEligible=seconds+profile.cooldown;
      if(b.family==='amano'){
        stats.larvalReleases++;emit('larval-release',{broodId:b.id,motherId:b.motherId,juveniles:0,requires:'brackish-larval-rearing',rearingSimulated:false},output);return;
      }
      const count=Math.min(b.count,Math.max(0,maxAnimals-livingCount()-reserved())),shelter=nearestSupport(position,supports);
      stats.capacitySuppressed+=b.count-count;
      for(let i=0;i<count;i++){
        const child={id:'offspring-'+(++serial),family:b.family,kind:b.kind,species:b.species,variant:b.variant,sex:random()<.5?'female':'male',alive:true,bornAt:seconds,position:copyPoint(position),parentIds:[b.motherId,b.fatherId],shelterTarget:shelter?{kind:'shelter',supportId:shelter.id,position:copyPoint(shelter.position)}:null};
        young.set(child.id,child);output.birthIds.push(child.id);stats.births++;
      }
      stats.hatchedBroods++;emit(b.family==='guppy'?'live-birth':'hatch',{broodId:b.id,motherId:b.motherId,family:b.family,count,position:copyPoint(position),supportId:b.supportId},output);
    }
    function transition(b,env,supports,output){
      const mother=parents.get(b.motherId),profile=profiles[b.family];
      if(b.phase==='carried-eggs'){
        if(!mother?.alive){cancel(b,'mother-unavailable',output);return;}
        const support=nearestSupport(mother.position,supports);
        if(support&&distance(mother.position,support.position)<=.35&&(!env.canReach||env.canReach(mother.position,support.position))){
          b.phase='deposited-eggs';b.supportId=support.id;b.position=copyPoint(support.position);b.nextAt=seconds+profile.incubation;
          mother.nextEligible=Math.max(mother.nextEligible,b.startedAt+DAY);
          emit('eggs-deposited',{broodId:b.id,motherId:b.motherId,supportId:b.supportId,count:b.count,position:copyPoint(b.position)},output);
        }else if(seconds>=b.startedAt+DAY){mother.nextEligible=seconds+DAY;cancel(b,'no-deposit',output);}
        else b.nextAt=seconds+HOUR;
      }else if(b.phase==='deposited-eggs'){
        const support=supports.get(b.supportId);if(!support)cancel(b,'missing-support',output);else finishBrood(b,support.position,supports,output);
      }else if(!mother?.alive)cancel(b,'mother-unavailable',output);
      else finishBrood(b,mother.position,supports,output);
    }
    function offspringView(a){
      const profile=profiles[a.family],age=Math.max(0,seconds-a.bornAt),maturity=clamp(age/profile.matureAge);
      return {...clone(a),ageDays:age/DAY,maturity,stage:maturity<1?profile.youngStage:a.family==='guppy'&&a.sex==='female'?'female':'adult',relativeAdultSize:profile.initialSize+(1-profile.initialSize)*Math.sqrt(maturity),shelterSeeking:age<(a.kind==='shrimp'?14:21)*DAY};
    }
    function stateFor(id){
      const child=young.has(id)?offspringView(young.get(id)):null;
      const a=parents.get(id);if(!a)return child;
      const b=broods.find(candidate=>candidate.motherId===id&&candidate.phase!=='deposited-eggs');
      let stage=child?.stage??(a.family==='guppy'&&a.sex==='female'?'female':'adult');
      if(b)stage=b.phase==='carried-eggs'?'egg-carrying':b.phase;
      return {...clone(a),...child,stage,broodId:b?.id??null,progress:b?clamp((seconds-b.startedAt)/((profiles[b.family].carry||profiles[b.family].incubation))):0,transitionAt:b?.nextAt??null,target:clone(b?.target??null)};
    }
    function synchronizeRoster(roster,env={}){
      const output={birthIds:[],events:[]};synchronize(roster,supportsFor(env),output);
      return{events:clone(output.events)};
    }
    function step(dt,roster=[],env={}){
      if(!Number.isFinite(dt)||dt<=0)return{births:[],events:[]};
      if(dt>366*DAY)throw new RangeError('Advance at most 366 simulated days per call');
      for(const name of ['shelter','light','stress'])if(env[name]!==undefined&&(!Number.isFinite(env[name])||env[name]<0||env[name]>1))throw new Error('Breeding environment values must be finite fractions');
      const supports=supportsFor(env),output={birthIds:[],events:[]};
      synchronize(roster,supports,output);
      const end=seconds+dt;
      while(true){
        let next=nextCheck;for(const b of broods)next=Math.min(next,b.nextAt);
        if(next>end+1e-8)break;
        seconds=next;
        for(const b of [...broods])if(b.nextAt<=seconds+1e-8)transition(b,env,supports,output);
        if(nextCheck<=seconds+1e-8){tryConceptions(env,supports,output);nextCheck+=CHECK;}
      }
      seconds=end;
      return{births:output.birthIds.map(id=>offspringView(young.get(id))),events:clone(output.events)};
    }
    function snapshot(){return clone({version:VERSION,maxAnimals,seed,seconds,nextCheck,serial,eventSerial,parents:[...parents.values()],offspring:[...young.values()],broods,events,stats});}
    return{step,synchronizeRoster,snapshot,stateFor,get seconds(){return seconds;},get offspring(){return[...young.values()].map(offspringView);},get broods(){return clone(broods);},get eggs(){return clone(broods.filter(b=>b.phase==='deposited-eggs'));},get events(){return clone(events);},get stats(){return{...stats};}};
  }
  const api={create,profiles,familyOf};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumBreeding=api;
})(typeof window==='object'?window:globalThis);
