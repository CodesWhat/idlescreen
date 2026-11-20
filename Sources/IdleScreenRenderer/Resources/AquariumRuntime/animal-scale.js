(function(root){
  'use strict';
  const cmPerWorldUnit=36/8.4;
  const clone=x=>JSON.parse(JSON.stringify(x));
  const tank=Object.freeze({model:'UNS60U',centimeters:Object.freeze({width:60,depth:36,height:36}),world:Object.freeze({width:14,depth:8.4,height:8.4})});
  const profiles={
    chili:{male:[1.8,2],female:[1.9,2],unknown:[1.8,2],birthCm:null,source:'https://www.aquariumcoop.com/blogs/aquarium/chili-rasbora'},
    medaka:{male:[3,3.6],female:[3.3,4],unknown:[3,4],birthCm:.45,source:'https://www.aquariumcoop.com/blogs/aquarium/medaka-rice-fish'},
    guppy:{male:[3.8,4.8],female:[4.8,6],unknown:[3.8,6],birthCm:.62*19/14,source:'https://aquaticarts.com/collections/bredby-aquatic-arts-guppies/products/golden-dragon-guppy-poecilia-reticulata-bred-by-aquatic-arts'},
    neocaridina:{male:[2.5,3],female:[3.1,4],unknown:[2.5,4],birthCm:.2,source:'https://www.aquariumcoop.com/blogs/aquarium/cherry-shrimp-care'},
    amano:{male:[4,4.5],female:[4.5,5],unknown:[4,5],birthCm:null,source:'https://www.aquariumcoop.com/blogs/aquarium/amano-shrimp'},
    'caridina-bee':{male:[2.3,2.7],female:[2.7,3.175],unknown:[2.3,3.175],birthCm:.2,source:'https://buceplant.com/products/crystal-black-shrimp'},
    otocinclus:{male:[4,5],female:[4,5],unknown:[4,5],birthCm:null,source:'https://www.aquariumcoop.com/blogs/aquarium/otocinclus-catfish'},
    assassin:{male:[2,2.5],female:[2,2.5],unknown:[2,2.5],birthCm:null,source:'https://aquaticarts.com/products/assassin-snails'},
    nerite:{male:[2,2.54],female:[2,2.54],unknown:[2,2.54],birthCm:null,source:'https://aquaticarts.com/pages/zebra-nerite-snail-care-guide'},
  };
  for(const p of Object.values(profiles)){for(const sex of ['male','female','unknown'])Object.freeze(p[sex]);Object.freeze(p);}Object.freeze(profiles);
  const species=Object.freeze(Object.keys(profiles));
  const aliases={fish:'chili','chili-rasbora':'chili','boraras-brigittae':'chili',cherry:'neocaridina','neocaridina-davidi':'neocaridina','neocaridina-color':'neocaridina','amano-shrimp':'amano','caridina-multidentata':'amano','crystal-shrimp':'caridina-bee','crystal-black':'caridina-bee','caridina-cantonensis':'caridina-bee','caridina-logemanni':'caridina-bee','oryzias-latipes':'medaka','poecilia-reticulata':'guppy','clea-helena':'assassin','anentome-helena':'assassin','zebra-nerite':'nerite','neritina-natalensis':'nerite'};
  function canonical(name){name=String(name??'').toLowerCase().replace(/\s+/g,'-');const result=profiles[name]?name:aliases[name];if(!result)throw new RangeError('Unsupported animal species');return result;}
  function stages(name){name=canonical(name);return ['neocaridina','amano','caridina-bee'].includes(name)?['adult','berried','juvenile']:name==='guppy'?['adult','female','gravid','fry']:name==='medaka'?['adult','egg-carrying','fry']:['adult'];}
  function shape(width,height,anchor,axis,endpoints,core,mouth,vent,foot,basis){
    const measurement={basis,axis,endpoints,pixels:axis==='x'?Math.abs(endpoints[1][0]-endpoints[0][0]):axis==='y'?Math.abs(endpoints[1][1]-endpoints[0][1]):Math.hypot(endpoints[1][0]-endpoints[0][0],endpoints[1][1]-endpoints[0][1])};
    return{canvas:{width,height},anchor,measurement,core:{minX:core[0],minY:core[1],maxX:core[2],maxY:core[3]},landmarks:{mouth,vent,foot,bodyCenter:[(core[0]+core[2])/2,(core[1]+core[3])/2]}};
  }
  function metrics(name,stage='adult'){
    name=canonical(name);if(!stages(name).includes(stage))throw new RangeError('Unsupported animal sprite stage');
    if(['neocaridina','amano','caridina-bee'].includes(name))return stage==='juvenile'
      ?shape(34,20,[17,16],'x',[[8,10.5],[27,8.5]],[11,8,23,13],[22.5,12.5],[11.5,11.5],[19,17],'rostrum-to-tail; antennae excluded')
      :shape(34,20,[17,16],'x',[[2,10.5],[30,6.5]],[7,5,26,14],[25.5,11.5],[7.5,11.5],[20,18],'rostrum-to-tail; antennae excluded');
    if(name==='assassin')return shape(36,28,[18,26],'diagonal',[[7.5,2.5],[28.5,22.5]],[7,2,29,24],[29.5,23.5],[26.5,20.5],[17,26],'shell apex-to-aperture axis; foot excluded');
    if(name==='nerite')return shape(32,26,[16,24],'x',[[5,13.5],[26,13.5]],[5,4,26,22],[26.5,21.5],[25.5,20.5],[16,24],'shell diameter; foot and tentacles excluded');
    if(name==='otocinclus')return shape(28,40,[14,9],'y',[[14,5],[14,36]],[8,5,20,31],[14,10],[14,25],[14,10],'head-to-caudal-fin total length');
    if(name==='chili')return shape(40,24,[23,12],'x',[[2,6.5],[38,12.5]],[9,8,38,16],[37.5,12.5],[18,14.5],null,'snout-to-caudal-fin total length');
    if(stage==='fry')return name==='guppy'
      ?shape(22,14,[14,7],'x',[[2,6.5],[21,7.5]],[7,5,21,10],[20.5,7.5],[12,8.5],null,'snout-to-caudal-fin total length')
      :shape(22,14,[14,7],'x',[[2,6.5],[21,7.5]],[6,5,21,9],[20.5,7.5],[12,8.5],null,'snout-to-caudal-fin total length');
    if(name==='medaka')return shape(40,24,[23,12],'x',[[2,11.5],[38,11.5]],[9,9,38,stage==='egg-carrying'?16:15],[37.5,11.5],[24.5,14.5],null,'snout-to-caudal-fin total length');
    if(stage==='female'||stage==='gravid')return shape(44,28,[25,13],'x',[[4,12.5],[41,12.5]],[13,8,41,stage==='gravid'?21:18],[40.5,12.5],[23,stage==='gravid'?18:15],null,'snout-to-caudal-fin total length');
    return shape(40,24,[23,12],'x',[[2,12.5],[38,11.5]],[14,8,38,16],[37.5,11.5],[25.5,14.5],null,'snout-to-caudal-fin total length');
  }
  function fraction(seed,id){
    let hash=(2166136261^(seed>>>0))>>>0;
    for(const character of String(id??'reference'))hash=Math.imul(hash^character.codePointAt(0),16777619)>>>0;
    hash^=hash>>>16;hash=Math.imul(hash,0x7feb352d);hash^=hash>>>15;hash=Math.imul(hash,0x846ca68b);hash^=hash>>>16;
    return(hash>>>0)/4294967296;
  }
  function validateMetrics(m){
    const finitePoint=p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite);
    if(!m||!m.canvas||![m.canvas.width,m.canvas.height].every(n=>Number.isInteger(n)&&n>0)||!finitePoint(m.anchor)||!m.measurement||!['x','y','diagonal'].includes(m.measurement.axis)||!Array.isArray(m.measurement.endpoints)||m.measurement.endpoints.length!==2||!m.measurement.endpoints.every(finitePoint)||!m.core||![m.core.minX,m.core.minY,m.core.maxX,m.core.maxY].every(Number.isFinite)||m.core.minX>=m.core.maxX||m.core.minY>=m.core.maxY||!m.landmarks||!['mouth','vent','bodyCenter'].every(key=>finitePoint(m.landmarks[key]))||(m.landmarks.foot!==null&&!finitePoint(m.landmarks.foot)))throw new Error('Finite anatomical pixel metrics required');
    const [a,b]=m.measurement.endpoints,span=m.measurement.axis==='x'?Math.abs(b[0]-a[0]):m.measurement.axis==='y'?Math.abs(b[1]-a[1]):Math.hypot(b[0]-a[0],b[1]-a[1]);
    if(!Number.isFinite(span)||span<=0)throw new Error('Positive anatomical pixel span required');
    m.measurement.pixels=span;return m;
  }
  function calibrate(options){
    const name=canonical(options?.species),p=profiles[name];
    let sex=options.sex??'unknown';if(!['male','female','unknown'].includes(sex))throw new RangeError('Known sex or unknown required');
    const stage=options.stage??(name==='guppy'&&sex==='female'?'female':'adult');
    if(['berried','gravid','egg-carrying','female'].includes(stage)){if(sex==='male')throw new RangeError('Maternal sprite stage requires female sex');sex='female';}
    if(!stages(name).includes(stage))throw new RangeError('Unsupported animal sprite stage');
    const seed=options.seed??8401;if(!Number.isFinite(seed))throw new Error('Finite individual seed required');
    const range=p[sex],adultLengthCm=range[0]+(range[1]-range[0])*fraction(seed,options.id);
    const young=stage==='juvenile'||stage==='fry';
    const age=options.growthAgeDays??(young?0:null);
    if(age!==null&&(!Number.isFinite(age)||age<0))throw new Error('Finite nonnegative growth age required');
    let lengthCm=options.lengthCm;
    if(lengthCm===undefined){
      if(age===null)lengthCm=adultLengthCm;
      else{
        if(p.birthCm===null)throw new Error('An explicit lengthCm is required for post-larval or uncalibrated young');
        const t=Math.min(1,age/90),growth=t*t*(3-2*t);
        lengthCm=p.birthCm+(adultLengthCm-p.birthCm)*growth;
      }
    }
    if(!Number.isFinite(lengthCm)||lengthCm<=0)throw new Error('Finite positive animal length required');
    const m=validateMetrics(options.metrics?clone(options.metrics):metrics(name,stage));
    const basePixelToWorld=options.basePixelToWorld??1;
    if(!Number.isFinite(basePixelToWorld)||basePixelToWorld<=0)throw new Error('Finite positive base pixel scale required');
    const facing=options.facing??1;if(facing!==1&&facing!==-1)throw new Error('Facing must be +1 or -1');
    const lengthWorld=lengthCm/cmPerWorldUnit,pixelToWorld=lengthWorld/m.measurement.pixels;
    const offsets=Object.fromEntries(Object.entries(m.landmarks).map(([key,p])=>[key,p?{x:(p[0]-m.anchor[0])*pixelToWorld*facing,y:(m.anchor[1]-p[1])*pixelToWorld,z:0}:null]));
    const width=(m.core.maxX-m.core.minX)*pixelToWorld,height=(m.core.maxY-m.core.minY)*pixelToWorld;
    const movementCollisionRadius=Math.min(width,height)/2;
    return{species:name,stage,sex,adultLengthRangeCm:[...range],adultLengthCm,lengthCm,lengthWorld,cmPerWorldUnit,pixelToWorld,basePixelToWorld,scale:pixelToWorld/basePixelToWorld,facing,
      measurement:clone(m.measurement),pixelMetrics:m,plane:{width:m.canvas.width*pixelToWorld,height:m.canvas.height*pixelToWorld},worldBodyDimensions:{width,height},offsets,movementCollisionRadius,
      collision:{centerOffset:{...offsets.bodyCenter},crossSectionRadius:movementCollisionRadius,enclosingRadius:Math.hypot(width,height)/2,halfLength:Math.max(width,height)/2,longAxis:width>=height?'x':'y'},
      growth:{ageDays:age,adultAgeDays:p.birthCm===null?null:90,relativeLength:lengthCm/adultLengthCm,alreadyIncludedInPixelToWorld:true},source:p.source};
  }
  const api={calibrate,metrics,stages,species,profiles,tank,cmPerWorldUnit};
  if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumAnimalScale=api;
})(typeof window==='object'?window:globalThis);
