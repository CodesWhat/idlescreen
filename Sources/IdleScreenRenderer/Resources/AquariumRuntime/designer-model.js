(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory();
 else root.AquariumDesignerModel=factory();
})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 const limits=Object.freeze({MAX_INSTANCES:24,MAX_LAYOUTS:30,MAX_HISTORY:100,MAX_NAME_LENGTH:80,MAX_ID_LENGTH:64,MAX_JSON_CHARS:65536,MAX_STORE_CHARS:262144});
 const bounds=Object.freeze({outerCm:Object.freeze({width:60,depth:36,height:36}),innerCm:Object.freeze({width:58.8,depth:34.8}),bedCm:5,waterCm:34.5});
 const definitions=[
  ['frogbit','Frogbit','floating'],['salvinia-minima','Salvinia minima','floating'],['red-root-floater','Red-root floater','floating'],['tiger-lotus','Tiger lotus','rooted'],
  ['java-fern','Java fern','attached'],['bucephalandra','Bucephalandra','attached'],['fissidens','Fissidens','attached'],['christmas-moss','Christmas moss','attached'],
  ['cryptocoryne','Cryptocoryne','rooted'],['staurogyne','Staurogyne','rooted'],['rotala','Rotala','rooted'],['compact-sword','Compact sword','rooted'],
  ['manzanita','Manzanita wood','hardscape'],['moss-rock','Moss rock','hardscape'],['dragon-driftwood','Rootwood dragon','hardscape']
 ];
 const catalog=Object.freeze(definitions.map(([id,label,placement])=>Object.freeze({id,category:placement==='hardscape'?'hardscape':'plants',label,placement,inspectUrl:placement==='hardscape'?'designer-inspect.html?asset='+id:'botanical-review.html?species='+id})));
 const assets=new Map(catalog.map(entry=>[entry.id,entry])),setups=new Set(['basic','lush','waterfall']),storageKey='idlescreen.aquarium.layouts.v1',tau=Math.PI*2;
 function fail(code,message,cause){const error=new Error(message);error.name='DesignerModelError';error.code=code;if(cause!==undefined)error.cause=cause;throw error;}
 function record(value,allowed,required,label){
  if(!value||typeof value!=='object'||Array.isArray(value)||Object.prototype.toString.call(value)!=='[object Object]')fail('INVALID_TYPE',label+' must be a plain object');
  const prototype=Object.getPrototypeOf(value);if(prototype!==null&&Object.getPrototypeOf(prototype)!==null)fail('INVALID_TYPE',label+' must be a plain object');
  for(const key of Reflect.ownKeys(value)){
   if(typeof key!=='string'||!allowed.includes(key))fail('UNKNOWN_KEY','Unknown '+label+' key: '+String(key));
   if(!Object.prototype.hasOwnProperty.call(Object.getOwnPropertyDescriptor(value,key),'value'))fail('INVALID_TYPE',label+' must contain data properties');
  }
  for(const key of required)if(!Object.prototype.hasOwnProperty.call(value,key))fail('MISSING_FIELD',label+'.'+key+' is required');
 }
 function array(value,maximum,label){
  if(!Array.isArray(value))fail('INVALID_TYPE',label+' must be an array');
  if(value.length>maximum)fail('LIMIT',label+' cannot exceed '+maximum+' entries');
  for(const key of Reflect.ownKeys(value))if(key!=='length'&&(typeof key!=='string'||!/^\d+$/.test(key)||String(Number(key))!==key||Number(key)>=value.length))fail('UNKNOWN_KEY','Unknown '+label+' array property');
  for(let i=0;i<value.length;i++){const descriptor=Object.getOwnPropertyDescriptor(value,String(i));if(!descriptor||!Object.prototype.hasOwnProperty.call(descriptor,'value'))fail('INVALID_TYPE',label+' must contain dense data entries');}
 }
 function name(value){
  if(typeof value!=='string')fail('INVALID_TYPE','Layout name must be text');
  const result=value.trim();if(!result||result.length>limits.MAX_NAME_LENGTH||/[\u0000-\u001f\u007f-\u009f]/.test(value))fail('INVALID_NAME','Layout name must be 1–80 characters without control characters');
  return result;
 }
 function id(value){if(typeof value!=='string'||!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value))fail('INVALID_ID','Instance id must be 1–64 letters, digits, hyphens or underscores, starting with a letter or digit');return value;}
 function finite(value,label){if(typeof value!=='number'||!Number.isFinite(value))fail('INVALID_NUMBER',label+' must be a finite number');return value===0?0:value;}
 function setup(value){if(!setups.has(value))fail('INVALID_SETUP','Setup must be basic, lush or waterfall');return value;}
 function normalizeInstance(value){
  record(value,['id','assetId','positionCm','rotationY'],['id','assetId','positionCm','rotationY'],'instance');
  const instanceId=id(value.id),asset=assets.get(value.assetId);if(!asset)fail('UNKNOWN_ASSET','Unknown assetId');
  record(value.positionCm,['x','y','z'],['x','y','z'],'positionCm');
  const positionCm={x:finite(value.positionCm.x,'positionCm.x'),y:finite(value.positionCm.y,'positionCm.y'),z:finite(value.positionCm.z,'positionCm.z')};
  if(Math.abs(positionCm.x)>bounds.innerCm.width/2||Math.abs(positionCm.z)>bounds.innerCm.depth/2)fail('OUT_OF_BOUNDS','Anchor must be inside the 58.8 × 34.8 cm tank interior');
  if(asset.placement==='attached'){
   if(positionCm.y<bounds.bedCm||positionCm.y>bounds.waterCm)fail('OUT_OF_BOUNDS','Attached anchor must be between the substrate and waterline');
  }else{
   const height=asset.placement==='floating'?bounds.waterCm:bounds.bedCm;
   if(Math.abs(positionCm.y-height)>1e-9)fail('INVALID_ANCHOR',asset.placement+' anchors must use y='+height+' cm');
   positionCm.y=height;
  }
  const angle=finite(value.rotationY,'rotationY')%tau,rotationY=((angle<0?angle+tau:angle)%tau)||0;
  return{id:instanceId,assetId:asset.id,positionCm,rotationY};
 }
 function normalize(value){
  record(value,['schemaVersion','units','name','base','instances'],['schemaVersion','units','name','base','instances'],'layout');
  if(value.schemaVersion!==1)fail('INVALID_VERSION','Only layout schemaVersion 1 is supported');
  if(value.units!=='cm')fail('INVALID_UNITS','Layout units must be cm');
  record(value.base,['setup'],['setup'],'base');array(value.instances,limits.MAX_INSTANCES,'instances');
  const instances=[],seen=new Set();for(const source of value.instances){const item=normalizeInstance(source);if(seen.has(item.id))fail('DUPLICATE_ID','Duplicate instance id: '+item.id);seen.add(item.id);instances.push(item);}
  return{schemaVersion:1,units:'cm',name:name(value.name),base:{setup:setup(value.base.setup)},instances};
 }
 function validate(value){normalize(value);return true;}
 const copy=value=>JSON.parse(JSON.stringify(value));
 function emptyLayout(){return{schemaVersion:1,units:'cm',name:'Untitled aquarium',base:{setup:'basic'},instances:[]};}
 function createSession(options={}){
  record(options,['layout'],[],'session options');
  let current=options.layout===undefined?emptyLayout():normalize(options.layout),selectedId=null;
  const past=[],future=[];
  const snapshot=()=>copy(current),state=()=>({layout:current,selectedId});
  function restore(saved){current=saved.layout;selectedId=saved.selectedId;return snapshot();}
  function select(value){if(value!==null){id(value);if(!current.instances.some(item=>item.id===value))fail('UNKNOWN_INSTANCE','Selected instance does not exist');}selectedId=value;return selectedId;}
  const fields={add:['type','instance'],update:['type','id','patch'],remove:['type','id'],base:['type','setup'],replace:['type','layout']};
  function apply(command){
   record(command,['type','instance','id','patch','setup','layout'],['type'],'command');
   if(typeof command.type!=='string'||!Object.prototype.hasOwnProperty.call(fields,command.type))fail('INVALID_COMMAND','Unknown designer command');
   record(command,fields[command.type],fields[command.type],'command');
   let candidate=snapshot(),nextSelection=selectedId;
   if(command.type==='add'){
    const item=normalizeInstance(command.instance);candidate.instances.push(item);nextSelection=item.id;
   }else if(command.type==='update'||command.type==='remove'){
    const itemId=id(command.id),index=candidate.instances.findIndex(item=>item.id===itemId);if(index<0)fail('UNKNOWN_INSTANCE','Instance does not exist: '+itemId);
    if(command.type==='remove'){candidate.instances.splice(index,1);if(nextSelection===itemId)nextSelection=null;}
    else{
     record(command.patch,['assetId','positionCm','rotationY'],[],'update patch');const target=candidate.instances[index];
     if(Object.prototype.hasOwnProperty.call(command.patch,'assetId'))target.assetId=command.patch.assetId;
     if(Object.prototype.hasOwnProperty.call(command.patch,'rotationY'))target.rotationY=command.patch.rotationY;
     if(Object.prototype.hasOwnProperty.call(command.patch,'positionCm')){record(command.patch.positionCm,['x','y','z'],[],'position patch');target.positionCm={...target.positionCm,...command.patch.positionCm};}
    }
   }else if(command.type==='base')candidate.base.setup=setup(command.setup);
   else candidate=normalize(command.layout);
   candidate=normalize(candidate);
   if(nextSelection!==null&&!candidate.instances.some(item=>item.id===nextSelection))nextSelection=null;
   if(JSON.stringify(candidate)===JSON.stringify(current))return snapshot();
   past.push(state());if(past.length>limits.MAX_HISTORY)past.shift();future.length=0;current=candidate;selectedId=nextSelection;return snapshot();
  }
  function undo(){if(!past.length)return snapshot();future.push(state());return restore(past.pop());}
  function redo(){if(!future.length)return snapshot();past.push(state());return restore(future.pop());}
  return Object.freeze({snapshot,apply,undo,redo,select,get selectedId(){return selectedId;},get canUndo(){return past.length>0;},get canRedo(){return future.length>0;}});
 }
 function exportJSON(value){const text=JSON.stringify(normalize(value),null,2);if(text.length>limits.MAX_JSON_CHARS)fail('LIMIT','Layout JSON is too large');return text;}
 function importJSON(text){
  if(typeof text!=='string')fail('INVALID_TYPE','Layout JSON must be text');
  if(text.length>limits.MAX_JSON_CHARS)fail('LIMIT','Layout JSON is too large');
  let parsed;try{parsed=JSON.parse(text);}catch(error){fail('INVALID_JSON','Layout JSON could not be parsed',error);}return normalize(parsed);
 }
 function createStore(storage){
  try{if(!storage||typeof storage.getItem!=='function'||typeof storage.setItem!=='function')fail('STORAGE_UNAVAILABLE','Named layout storage is unavailable');}
  catch(error){if(error.code==='STORAGE_UNAVAILABLE')throw error;fail('STORAGE_UNAVAILABLE','Named layout storage is unavailable',error);}
  function read(){
   let text;try{text=storage.getItem(storageKey);}catch(error){fail('STORAGE_READ','Saved layouts could not be read; no saved data was changed',error);}
   if(text===null)return[];
   try{
    if(typeof text!=='string'||text.length>limits.MAX_STORE_CHARS)fail('LIMIT','Saved layout data has an invalid size');
    const envelope=JSON.parse(text);record(envelope,['schemaVersion','layouts'],['schemaVersion','layouts'],'saved layouts');
    if(envelope.schemaVersion!==1)fail('INVALID_VERSION','Unsupported saved layout version');
    array(envelope.layouts,limits.MAX_LAYOUTS,'saved layouts');
    const layouts=[],names=new Set();for(const item of envelope.layouts){const normalized=normalize(item);if(names.has(normalized.name))fail('DUPLICATE_NAME','Duplicate saved layout name');names.add(normalized.name);layouts.push(normalized);}return layouts;
   }catch(error){fail('CORRUPT_STORAGE','Saved layout data is invalid; it has been preserved without changes',error);}
  }
  function write(layouts){
   const text=JSON.stringify({schemaVersion:1,layouts});if(text.length>limits.MAX_STORE_CHARS)fail('LIMIT','Saved layout data is too large');
   try{storage.setItem(storageKey,text);}catch(error){fail('STORAGE_WRITE','Saved layouts could not be written; no success was recorded',error);}
  }
  function list(){return read().map(value=>({name:value.name,instanceCount:value.instances.length,setup:value.base.setup})).sort((a,b)=>a.name<b.name?-1:a.name>b.name?1:0);}
  function save(value){
   const normalized=normalize(value),layouts=read(),index=layouts.findIndex(item=>item.name===normalized.name);
   if(index<0){if(layouts.length>=limits.MAX_LAYOUTS)fail('LIMIT','At most '+limits.MAX_LAYOUTS+' named layouts can be saved');layouts.push(normalized);}else layouts[index]=normalized;
   write(layouts);return copy(normalized);
  }
  function load(value){const wanted=name(value);return read().find(item=>item.name===wanted)||null;}
  function remove(value){const wanted=name(value),layouts=read(),index=layouts.findIndex(item=>item.name===wanted);if(index<0)return false;layouts.splice(index,1);write(layouts);return true;}
  return Object.freeze({list,save,load,remove});
 }
 return Object.freeze({catalog,bounds,limits,normalize,validate,createSession,createStore,exportJSON,importJSON});
});
