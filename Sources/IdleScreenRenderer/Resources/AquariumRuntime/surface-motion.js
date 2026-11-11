(function(root){
 'use strict';
 const panes=Object.freeze(['front','right','back','left']);
 const axes={front:{normal:[0,0,-1],tangent:[1,0,0]},right:{normal:[-1,0,0],tangent:[0,0,-1]},back:{normal:[0,0,1],tangent:[-1,0,0]},left:{normal:[1,0,0],tangent:[0,0,1]}};
 const clamp=(n,lo,hi)=>Math.max(lo,Math.min(hi,n)),wrap=(s,length)=>((s%length)+length)%length;
 function layout(bounds){
  if(!bounds||![bounds.halfWidth,bounds.backZ,bounds.frontZ,bounds.bedLevel,bounds.waterLevel].every(Number.isFinite))throw new RangeError('Finite glass bounds required');
  const insets=Object.fromEntries(panes.map(pane=>[pane,bounds.glassInsets?.[pane]??bounds.glassInset??.04]));
  if(!Object.values(insets).every(n=>Number.isFinite(n)&&n>=0))throw new RangeError('Finite nonnegative glass insets required');
  const left=-bounds.halfWidth+insets.left,right=bounds.halfWidth-insets.right,back=bounds.backZ+insets.back,front=bounds.frontZ-insets.front,low=bounds.bedLevel+.15,high=bounds.waterLevel-.12,width=right-left,depth=front-back;
  if(width<=0||depth<=0||low>high)throw new RangeError('Glass insets and vertical bounds must leave an interior');
  return{left,right,back,front,low,high,width,depth,length:2*(width+depth)};
 }
 function sample(THREE,g,perimeter,y){
  const s=wrap(perimeter,g.length);let pane,x,z;
  if(s<g.width){pane='front';x=g.left+s;z=g.front;}
  else if(s<g.width+g.depth){pane='right';x=g.right;z=g.front-(s-g.width);}
  else if(s<2*g.width+g.depth){pane='back';x=g.right-(s-g.width-g.depth);z=g.back;}
  else{pane='left';x=g.left;z=g.back+(s-2*g.width-g.depth);}
  return{position:new THREE.Vector3(x,clamp(y,g.low,g.high),z),pane,normal:new THREE.Vector3(...axes[pane].normal),tangent:new THREE.Vector3(...axes[pane].tangent),perimeter:s,length:g.length};
 }
 function glassFrame(THREE,bounds,perimeter,y){
  if(!Number.isFinite(perimeter)||!Number.isFinite(y))throw new RangeError('Finite glass perimeter and height required');
  return sample(THREE,layout(bounds),perimeter,y);
 }
 function project(THREE,point,g,pane,preferred){
  if(!point||![point.x,point.y,point.z].every(Number.isFinite))throw new RangeError('Finite glass position required');
  if(pane!==undefined&&!panes.includes(pane))throw new RangeError('Known glass pane required');
  const x=clamp(point.x,g.left,g.right),z=clamp(point.z,g.back,g.front),candidates={front:[x,g.front,x-g.left],right:[g.right,z,g.width+g.front-z],back:[x,g.back,g.width+g.depth+g.right-x],left:[g.left,z,2*g.width+g.depth+z-g.back]};
  let selected=pane,best=Infinity;
  if(selected===undefined)for(const name of panes){const c=candidates[name],distance=(point.x-c[0])**2+(point.z-c[1])**2;if(distance<best-1e-14||(Math.abs(distance-best)<=1e-14&&name===preferred)){selected=name;best=distance;}}
  const c=candidates[selected],result=sample(THREE,g,c[2],point.y);
  result.position.x=c[0];result.position.z=c[1];result.pane=selected;result.normal.set(...axes[selected].normal);result.tangent.set(...axes[selected].tangent);return result;
 }
 function projectGlass(THREE,position,bounds,pane){return project(THREE,position,layout(bounds),pane);}
 function arc(to,from,length,side){const d=wrap(to-from,length);return Math.abs(d-length/2)<1e-12?Math.abs(d)*side:d>length/2?d-length:d;}
 function create(THREE,position,seed,kind,surface='floor',pane='front'){
  const a={position:position.clone(),kind,surface,seed,time:seed%19,facing:1,walking:false,target:null,until:0,detourUntil:0,side:seed%2?1:-1,speed:kind==='otocinclus'?.025+(seed%3)*.003:kind==='shrimp'?.085+(seed%7)*.006:.023+(seed%3)*.004};
  if(surface==='glass'){if(!panes.includes(pane))throw new RangeError('Known glass pane required');a.pane=pane;a.glassHeading={along:0,up:0};a.glassPerimeter=null;a.glassTarget=null;}
  return a;
 }
 function stepGlass(THREE,a,dt,goal,bounds,others,state){
  if(!Number.isFinite(dt)||dt<=0)return;
  const elapsed=Math.min(.1,dt);a.time+=elapsed;a.walking=false;
  if(['recover','premolt','dead','eat','graze'].includes(state))return;
  const g=layout(bounds),current=project(THREE,a.position,g,undefined,a.pane);a.pane=current.pane;a.glassPerimeter=current.perimeter;
  if(!a.glassTarget||a.time>=a.until||Math.hypot(arc(a.glassTarget.perimeter,current.perimeter,g.length,a.side),a.glassTarget.y-a.position.y)<.08){
   const phase=a.time*.17+a.seed,lead=Math.min(g.length*.25,1.2+.25*Math.sin(phase*.37));
   a.glassTarget={perimeter:wrap(current.perimeter+a.side*lead,g.length),y:clamp(a.position.y+Math.cos(phase)*.9,g.low,g.high)};
   a.target=sample(THREE,g,a.glassTarget.perimeter,a.glassTarget.y).position;a.until=a.time+13+(a.seed%11);
  }
  if(a.kind==='otocinclus'&&(a.time+a.seed*.37)%17>4.5)return;
  if((!goal&&(a.time+a.seed)%11>7)||(goal&&(a.time+a.seed*.37)%8>7.25))return;
  // Correct an externally displaced contact at walking speed, never by snapping it to a pane.
  const attachmentDistance=a.position.distanceTo(current.position),budget=a.speed*elapsed;
  if(attachmentDistance>1e-8){a.position.lerp(current.position,Math.min(1,budget/attachmentDistance));a.walking=true;return;}
  const target=goal?project(THREE,goal,g,goal.pane):{perimeter:a.glassTarget.perimeter,position:{y:a.glassTarget.y}};
  let along=arc(target.perimeter,current.perimeter,g.length,a.side),up=target.position.y-a.position.y,distance=Math.hypot(along,up);
  if(distance<.08)return;along/=distance;up/=distance;
  for(const other of others){
   if(other===a||other.surface!=='glass')continue;
   const p=project(THREE,other.position,g,undefined,other.pane),away=arc(current.perimeter,p.perimeter,g.length,a.side),dy=a.position.y-other.position.y,length=Math.hypot(away,dy);
   if(length>.001&&length<.45){const weight=(.45-length)*3/length;along+=away*weight;up+=dy*weight;}
  }
  distance=Math.hypot(along,up);if(distance<1e-12)return;along/=distance;up/=distance;
  const next=sample(THREE,g,current.perimeter+along*budget,a.position.y+up*budget);
  a.walking=next.position.distanceToSquared(a.position)>1e-10;
  if(Math.abs(along*budget)>.0001)a.facing=along<0?-1:1;
  a.glassHeading.along=along;a.glassHeading.up=up;a.pane=next.pane;a.glassPerimeter=next.perimeter;a.position.copy(next.position);
 }
 function step(THREE,a,dt,goal,bounds,world,support,others=[],state='forage'){
  if(a.surface==='glass')return stepGlass(THREE,a,dt,goal,bounds,others,state);
  if(!Number.isFinite(dt)||dt<=0)return;
  const elapsed=Math.min(.1,dt),glassZ=bounds.frontZ-(bounds.glassInset??.04);a.time+=elapsed;a.walking=false;
  if(['recover','premolt','dead','eat','graze'].includes(state))return;
  if(!a.target||a.time>=a.until||a.position.distanceTo(a.target)<.08){
   const phase=a.time*.17+a.seed;
   a.target=new THREE.Vector3(a.position.x+Math.sin(phase)*1.2,a.surface==='glass'?a.position.y+Math.cos(phase)*.9:a.position.y,a.surface==='glass'?glassZ:a.position.z+Math.cos(phase)*.8);a.until=a.time+13+(a.seed%11);
  }
  if(a.kind==='otocinclus'&&(a.time+a.seed*.37)%17>4.5)return;
  const target=goal?new THREE.Vector3(goal.x,goal.y,goal.z):a.target;
  // Brief independent pauses leave the walking frames still during grazing.
  if((!goal&&(a.time+a.seed)%11>7)||(goal&&(a.time+a.seed*.37)%8>7.25))return;
  const delta=target.clone().sub(a.position);
  if(a.surface==='glass')delta.z=0;else delta.y=0;
  if(delta.length()<.08)return;
  delta.normalize();
  for(const other of others){if(other===a)continue;const away=a.position.clone().sub(other.position);if(a.surface==='floor')away.y=0;else away.z=0;const length=away.length();if(length>.001&&length<.45)delta.addScaledVector(away.normalize(),(.45-length)*3);}
  delta.normalize();if(a.time<a.detourUntil){const x=delta.x;delta.x=-delta.z*a.side;delta.z=x*a.side;}
  let next=a.position.clone().addScaledVector(delta,a.speed*elapsed);
  next.x=THREE.MathUtils.clamp(next.x,-bounds.halfWidth+.38,bounds.halfWidth-.38);
  next.z=THREE.MathUtils.clamp(next.z,bounds.backZ+.22,bounds.frontZ-.22);
  if(a.surface==='glass'){
   next.z=glassZ;next.y=THREE.MathUtils.clamp(next.y,bounds.bedLevel+.15,bounds.waterLevel-.12);
  }else{
   const contact=world?.moveSphere(a.position,next,.075);
   if(contact?.collided&&contact.kind==='solid'){a.detourUntil=a.time+1.8;return;}
   const floor=support(next.x,next.z,a.position.y);
   if(!floor||Math.abs(floor.y-a.position.y)>.24){a.detourUntil=a.time+1.8;return;}
   next.y=floor.y;
  }
  a.walking=next.distanceToSquared(a.position)>1e-10;
  if(Math.abs(next.x-a.position.x)>.0001)a.facing=next.x<a.position.x?-1:1;
  a.position.copy(next);
 }
 const api={create,step,panes,glassFrame,projectGlass};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumSurfaceMotion=api;
})(typeof window==='object'?window:globalThis);
