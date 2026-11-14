(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory(require('./tank-document.js'),require('./tank-configuration.js'));
 else root.AquariumTankEnvelope=factory(root.AquariumTankDocument,root.AquariumTankConfiguration);
})(globalThis,function(documents,configurations){
 'use strict';
 const format='idlescreen.aquarium',maxChars=2097152;
 function fields(value,keys){
  if(!value||typeof value!=='object'||Array.isArray(value))throw new TypeError('Tank envelope needs data fields');
  const prototype=Object.getPrototypeOf(value);if(prototype!==null&&Object.getPrototypeOf(prototype)!==null)throw new TypeError('Tank envelope needs plain data fields');
  if(Reflect.ownKeys(value).length!==keys.length)throw new TypeError('Tank envelope has unsupported fields');
  for(const key of keys){const descriptor=Object.getOwnPropertyDescriptor(value,key);if(!descriptor||!Object.prototype.hasOwnProperty.call(descriptor,'value')||!descriptor.enumerable)throw new TypeError('Tank envelope has missing or unsupported fields');}
 }
 function createCodec({catalog,checkpointCodec}){
  if(typeof checkpointCodec?.validate!=='function'||typeof checkpointCodec?.capture!=='function')throw new TypeError('A domain checkpoint codec is required');
  const model=documents.createModel({catalog,validateCheckpoint:data=>{checkpointCodec.validate(data);return true;}});
  function normalize(value){
   fields(value,['format','schemaVersion','document','configuration']);
   if(value.format!==format||value.schemaVersion!==1)throw new TypeError('Unsupported full tank envelope format');
   const document=model.normalize(value.document),configuration=configurations.normalize(value.configuration);
   if(document.layout.setup!==configuration.setup)throw new TypeError('Tank setup disagrees with its scene configuration');
   if(document.checkpoint){
    const elapsed=document.checkpoint.data.ecology.seconds,high=Math.max(elapsed,document.checkpoint.elapsedSeconds);
    if(Math.abs(elapsed-document.checkpoint.elapsedSeconds)>Math.max(1e-8,high*Number.EPSILON*16))throw new TypeError('Tank checkpoint time disagrees with the ecosystem clock');
   }
   const result={format,schemaVersion:1,document,configuration};
   if(JSON.stringify(result).length>maxChars)throw new RangeError('Full tank envelope is too large');return result;
  }
  function capture({id,name,state,live}){
   const configuration=configurations.capture(state),physical=state.physical?.tankCm;
   if(!physical)throw new TypeError('Actual physical tank geometry is required');
   if(!Array.isArray(state.presetObjects))throw new TypeError('Actual preset objects are required');
   const added=state.designer?.layout?.instances||[],status=state.designer?.status||[];
   if(!Array.isArray(added)||!Array.isArray(status)||status.length!==added.length)throw new TypeError('Every added object needs a complete placement check');
   const confirmed=new Map();for(const entry of status){if(!entry||entry.valid!==true||confirmed.has(entry.id))throw new TypeError('Invalid or duplicate placement check blocks tank capture');confirmed.set(entry.id,entry);}
   const objects=[...state.presetObjects,...added.map(item=>{const accepted=confirmed.get(item.id);if(!accepted||accepted.assetId!==item.assetId)throw new TypeError('Missing or mismatched placement check blocks tank capture');return {...item,positionCm:accepted.positionCm,rotationY:accepted.rotationY};})];
   const data=checkpointCodec.capture(live);
   const document=model.create({id,name,setup:configuration.setup,geometry:{outerCm:{width:physical.width,height:physical.height,depth:physical.depth},glassCm:physical.glass,bedCm:physical.bed,waterCm:physical.water},objects,checkpoint:{schemaVersion:1,elapsedSeconds:data.ecology.seconds,data}});
   return normalize({format,schemaVersion:1,document,configuration});
  }
  function exportJSON(value){return JSON.stringify(normalize(value));}
  function importJSON(text){
   if(typeof text!=='string')throw new TypeError('Full tank JSON must be text');
   if(text.length>maxChars)throw new RangeError('Full tank JSON is too large');
   let parsed;try{parsed=JSON.parse(text);}catch(_){throw new TypeError('Full tank JSON could not be parsed');}return normalize(parsed);
  }
  return Object.freeze({capture,normalize,exportJSON,importJSON,documentModel:model});
 }
 return Object.freeze({createCodec});
});
