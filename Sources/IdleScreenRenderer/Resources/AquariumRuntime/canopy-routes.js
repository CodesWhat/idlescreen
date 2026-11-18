(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumCanopyRoutes=factory();})(globalThis,function(){
 'use strict';
 function extend(anchors,sites,contacts){
  const occupied=new Set(),added=[],entries=anchors.filter(a=>contacts.has(a.id)||a.id.includes('-leaf-')||a.id==='stem-leaf');
  const ordered=sites.map(site=>({site,distance:Math.min(...entries.map(a=>Math.hypot(site.rest[0]-a.position.x,site.rest[1]-a.position.y,site.rest[2]-a.position.z)))})).sort((a,b)=>a.distance-b.distance);
  // Retain real leaf contacts, with a fixed construction budget.
  for(const {site} of ordered){
   const p=site.rest,key=Math.floor(p[0]/.30)+','+Math.floor(p[2]/.30);
   if(occupied.has(key)||anchors.length>=480)continue;
   occupied.add(key);const id='canopy-'+added.length,node={id,position:{x:p[0],y:p[1],z:p[2]},links:[],kind:'foliage'};
   anchors.push(node);added.push(node);contacts.set(id,site);
  }
  const distance=(a,b)=>Math.hypot(a.x-b.x,a.y-b.y,a.z-b.z);
  for(const a of added)for(const b of anchors){
   if(a===b||!(contacts.has(b.id)||b.id.includes('-leaf-')||b.id==='stem-leaf'))continue;
   if(Math.abs(a.position.y-b.position.y)>.22||distance(a.position,b.position)>.48)continue;
   if(!a.links.includes(b.id))a.links.push(b.id);
   if(!b.links.includes(a.id))b.links.push(a.id);
  }
  return added;
 }
 return{extend};
});
