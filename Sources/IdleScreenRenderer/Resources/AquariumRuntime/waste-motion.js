(function(root){
 'use strict';
 function step(THREE,deposit,dt,source,world){
  if(!Number.isFinite(dt)||dt<0)return;
  if(!deposit.motion)deposit.motion={age:0,phase:source?.kind==='fish'?'attached':'sinking',speed:.035};
  const m=deposit.motion,elapsed=Math.min(.1,dt);m.age+=elapsed;
  if(m.phase==='settled')return;
  if(m.phase==='attached'&&source&&m.age<.45){
   deposit.position={x:source.position.x-.10*source.scale*source.facing,y:source.position.y-.15*source.scale-Math.min(.055,m.age*.12),z:source.position.z+.025};return;
  }
  m.phase='sinking';m.speed=Math.min(.27,m.speed+elapsed*.18);
  const from=new THREE.Vector3(deposit.position.x,deposit.position.y,deposit.position.z),to=from.clone();to.y-=m.speed*elapsed;
  const hit=world.moveSphere(from,to,.025);deposit.position={x:hit.position.x,y:hit.position.y,z:hit.position.z};
  if(hit.collided&&hit.kind!=='glass')m.phase='settled';
 }
 const api={step};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumWasteMotion=api;
})(typeof window==='object'?window:globalThis);
