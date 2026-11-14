(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory();
 else root.AquariumPresetAssemblies=factory();
})(globalThis,function(){
 'use strict';
 function create(THREE,{world,cmPerUnit,centerZ=0}){
  if(!world?.isObject3D||!Number.isFinite(cmPerUnit)||cmPerUnit<=0||!Number.isFinite(centerZ))throw new TypeError('Invalid preset world or centimeter scale');
  const entries=new Map(),owners=new WeakMap(),tau=Math.PI*2;
  const id=value=>{if(typeof value!=='string'||!/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value))throw new TypeError('Invalid assembly id');return value;};
  function point(value){if(!value||!['x','y','z'].every(k=>typeof value[k]==='number'&&Number.isFinite(value[k])))throw new TypeError('Assembly position must contain finite centimeters');return{x:value.x,y:value.y,z:value.z};}
  function add({id:identity,assetId,objects,anchor}){
   id(identity);id(assetId);point(anchor);
   if(entries.has(identity))throw new Error('Duplicate assembly id');
   if(!Array.isArray(objects)||!objects.length||new Set(objects).size!==objects.length)throw new TypeError('Assembly needs distinct authored objects');
   for(const object of objects){
    if(!object?.isObject3D)throw new TypeError('Assembly needs authored objects');
    let owned=false;object.traverse(child=>{if(owners.has(child))owned=true;});if(owned)throw new Error('Authored object is already owned');
    if(object.parent!==world)throw new TypeError('Assembly needs direct children of its world');
   }
   const group=new THREE.Group();group.name='preset-'+identity;group.userData.presetId=identity;group.userData.presetAnchorY=anchor.y;group.position.set(anchor.x,anchor.y,anchor.z);world.add(group);world.updateMatrixWorld(true);
   for(const object of objects){group.attach(object);object.traverse(child=>owners.set(child,identity));}
   entries.set(identity,{id:identity,assetId,group});return group;
  }
  function snapshot(){return [...entries.values()].filter(e=>e.group.visible).map(e=>({id:e.id,assetId:e.assetId,positionCm:{x:e.group.position.x*cmPerUnit,y:e.group.position.y*cmPerUnit,z:(e.group.position.z-centerZ)*cmPerUnit},rotationY:e.group.rotation.y}));}
  function apply(records){
   if(!Array.isArray(records))throw new TypeError('Assembly records must be an array');
   const seen=new Set(),prepared=records.map(record=>{
    const entry=entries.get(record?.id);if(!entry)throw new Error('Unknown assembly id');
    if(seen.has(record.id))throw new Error('Duplicate assembly id');seen.add(record.id);
    if(record.assetId!==entry.assetId)throw new Error('Assembly asset identity cannot change');
    const p=point(record.positionCm);if(!Number.isFinite(record.rotationY))throw new TypeError('Assembly rotation must be finite');
    return{entry,p,angle:((record.rotationY%tau)+tau)%tau};
   });
   for(const entry of entries.values())entry.group.visible=false;
   for(const {entry,p,angle}of prepared){entry.group.visible=true;entry.group.position.set(p.x/cmPerUnit,p.y/cmPerUnit,centerZ+p.z/cmPerUnit);entry.group.rotation.y=angle;}
   world.updateMatrixWorld(true);return snapshot();
  }
  function ownerOf(object){for(let current=object;current&&current!==world;current=current.parent){const owner=owners.get(current)||current.userData?.presetId;if(owner)return owner;}return null;}
  function meshes(accept=()=>true){
   const result=[];world.updateMatrixWorld(true);
   for(const {group}of entries.values())if(group.visible)group.traverseVisible(object=>{if(object.isMesh&&!object.isInstancedMesh&&accept(object))result.push(object);});
   return result;
  }
  return Object.freeze({add,snapshot,apply,ownerOf,meshes,get size(){return entries.size;}});
 }
 return Object.freeze({create});
});
