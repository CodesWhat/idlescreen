(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumBotanicalLayout=factory();})(globalThis,function(){
 'use strict';
 const definitions=[
  ['frogbit','floating','floating',-3.8,-2.6],['salvinia-minima','floating','floating',.1,-2.8],['red-root-floater','floating','floating',3.7,-1.2],['tiger-lotus','floating','rooted',1.0,1.1],
  ['java-fern','epiphyte','attached',-3.5,.3],['bucephalandra','epiphyte','attached',3.5,-.1],['fissidens','epiphyte','attached',2.9,.3],['christmas-moss','epiphyte','attached',-2.7,1.0],
  ['cryptocoryne','rooted','rooted',-1.6,1.9],['staurogyne','rooted','rooted',.4,2.8],['rotala','rooted','rooted',3.8,-2.9],['compact-sword','rooted','rooted',3.0,1.8]
 ];
 const species=Object.freeze(definitions.map(d=>d[0]));
 function create(THREE,{choice='botanical',factories,halfWidth,backZ,frontZ,bedLevel,waterLevel,cmPerUnit=36/8.4,solids=[],mountSolids=solids}){
  if(choice!=='botanical'&&!species.includes(choice))throw new RangeError('Unknown botanical selection');
  if(![halfWidth,backZ,frontZ,bedLevel,waterLevel,cmPerUnit].every(Number.isFinite)||halfWidth<=0||frontZ<=backZ||bedLevel<=0||waterLevel<=bedLevel||cmPerUnit<=0)throw new RangeError('Invalid physical plant bounds');
  const group=new THREE.Group();group.name='botanical-collection';const assets=[],geometries=[],materials=[],maps=[],grazeSites=[],omitted=[];
  const solidBoxes=solids.map(o=>{o.geometry.computeBoundingBox();return o.geometry.boundingBox.clone().applyMatrix4(o.matrixWorld);}),ray=new THREE.Raycaster(),point=new THREE.Vector3();
  function clear(box){return !solidBoxes.some(b=>b.intersectsBox(box));}
  const edgeBox=new THREE.Box3(),start=new THREE.Vector3(),end=new THREE.Vector3(),direction=new THREE.Vector3();
  function crossesSolid(edges,origin,box){
   const nearby=solids.filter((_,i)=>solidBoxes[i].intersectsBox(box));if(!nearby.length)return false;
   const nearbyBoxes=nearby.map(o=>o.geometry.boundingBox.clone().applyMatrix4(o.matrixWorld));
   for(const [a,b]of edges){start.copy(a).add(origin);end.copy(b).add(origin);edgeBox.setFromPoints([start,end]);const candidates=nearby.filter((_,i)=>nearbyBoxes[i].intersectsBox(edgeBox));if(!candidates.length)continue;direction.copy(end).sub(start);const distance=direction.length();if(distance<1e-8)continue;ray.set(start,direction.divideScalar(distance));ray.near=.001;ray.far=distance-.001;if(ray.intersectObjects(candidates,false).length)return true;}
   return false;
  }
  for(const [name,family,placement,x,z] of definitions){
   if(choice!=='botanical'&&choice!==name)continue;
   const asset=factories[family].create(THREE,{species:name,seed:931+species.indexOf(name)*47,cmPerUnit,growth:1});
   const object=asset.group;object.name='botanical-'+name;object.userData.species=name;object.userData.placement=placement;
   object.updateMatrixWorld(true);const edges=[];object.traverse(o=>{if(!o.isMesh)return;const p=o.geometry.attributes.position,index=o.geometry.index,seen=new Set(),count=index?index.count:p.count;for(let i=0;i<count;i+=3){const ids=[0,1,2].map(k=>index?index.getX(i+k):i+k);for(let k=0;k<3;k++){const a=ids[k],b=ids[(k+1)%3],key=Math.min(a,b)+':'+Math.max(a,b);if(seen.has(key))continue;seen.add(key);edges.push([new THREE.Vector3().fromBufferAttribute(p,a).applyMatrix4(o.matrixWorld),new THREE.Vector3().fromBufferAttribute(p,b).applyMatrix4(o.matrixWorld)]);}}});const local=new THREE.Box3().setFromObject(object);let mount=null;
   const targetX=choice==='botanical'?x:placement==='floating'?0:2.2,targetZ=choice==='botanical'?z:placement==='floating'?-1:0;
   for(let i=0;i<45;i++){
    const a=i*2.399,r=i===0?0:.35*Math.sqrt(i),px=targetX+Math.cos(a)*r,pz=targetZ+Math.sin(a)*r;
    let y=placement==='floating'?waterLevel:bedLevel;
    if(placement==='attached'&&mountSolids.length){ray.set(new THREE.Vector3(px,waterLevel,pz),new THREE.Vector3(0,-1,0));ray.near=0;ray.far=waterLevel-bedLevel+1;const hit=ray.intersectObjects(mountSolids,false).find(h=>h.face.normal.clone().transformDirection(h.object.matrixWorld).y>.5&&h.point.y>bedLevel+.1&&h.point.y+local.max.y<waterLevel-.05);if(!hit)continue;y=hit.point.y+.012;}
    const origin=new THREE.Vector3(px,y,pz),box=local.clone().translate(origin);
    if(box.min.x < -halfWidth+.07||box.max.x>halfWidth-.07||box.min.z<backZ+.07||box.max.z>frontZ-.07||box.min.y<.02||box.max.y>waterLevel+(placement==='floating'?.22:.04))continue;
    if(placement==='rooted'&&!clear(new THREE.Box3(new THREE.Vector3(px-.10,bedLevel-.04,pz-.10),new THREE.Vector3(px+.10,bedLevel+.12,pz+.10))))continue;
    if(placement!=='attached'&&crossesSolid(edges,origin,box))continue;
    mount=origin;break;
   }
   if(!mount){for(const r of [...asset.geometries,...asset.materials,...asset.maps])r.dispose();omitted.push(name);continue;}
   object.position.copy(mount);group.add(object);const record={...asset,species:name,placement,group:object,sites:[]};assets.push(record);geometries.push(...asset.geometries);materials.push(...asset.materials);maps.push(...asset.maps);object.updateMatrixWorld(true);
   for(const [i,localSite]of (asset.grazeSites||[]).entries()){
    const prefix='botanical-'+name+'-',site={id:prefix+(localSite.id??i),position:[0,0,0],rest:[0,0,0],normal:[0,1,0],links:(localSite.links||[]).map(id=>prefix+id),kind:'foliage',habitat:localSite.habitat};
    point.fromArray(localSite.position||localSite.rest).applyMatrix4(object.matrixWorld);site.position=point.toArray();if(localSite.normal)site.normal=new THREE.Vector3().fromArray(localSite.normal).transformDirection(object.matrixWorld).toArray();site.rest=site.position.slice();grazeSites.push(site);record.sites.push({localSite,worldSite:site});
   }
  }
  function update(time,flow){group.updateMatrixWorld(true);for(const a of assets){a.update?.(time,flow);for(const {localSite,worldSite}of a.sites){point.fromArray(localSite.position||localSite.rest).applyMatrix4(a.group.matrixWorld);point.toArray(worldSite.position);if(localSite.normal)new THREE.Vector3().fromArray(localSite.normal).transformDirection(a.group.matrixWorld).toArray(worldSite.normal);}}}
  group.userData={species:assets.map(a=>a.species),omitted,cmPerUnit};
  return{group,assets,geometries,materials,maps,grazeSites,omitted,update};
 }
 return{create,species};
});
