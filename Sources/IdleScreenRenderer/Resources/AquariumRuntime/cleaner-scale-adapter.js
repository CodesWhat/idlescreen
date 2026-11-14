(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumCleanerScaleAdapter=factory();
})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 const supported=Object.freeze(['otocinclus','assassin','nerite']),review=Object.freeze(['horned-nerite','orange-rabbit','ramshorn']);
 const copy=value=>JSON.parse(JSON.stringify(value));
 function metrics(sprite){
  const art=sprite?.measurements,canvas=sprite?.canvas,parts=sprite?.anatomy?.parts,contact=sprite?.contact;
  if(!sprite||![...supported,...review].includes(sprite.kind)||!canvas||![canvas.width,canvas.height].every(n=>Number.isInteger(n)&&n>0&&n<=64)||!art||!parts||!contact)throw new Error('Complete cleaner sprite metrics and anatomy required');
  const point=p=>Array.isArray(p)&&p.length===2&&p.every(Number.isFinite),pixel=p=>point(p)&&p.every(Number.isInteger)&&p[0]>=0&&p[0]<canvas.width&&p[1]>=0&&p[1]<canvas.height;
  if(!point([sprite.anchorX,sprite.anchorY])||!pixel(contact.point)||!pixel(contact.mouth)||!['x','y','diagonal'].includes(art.axis)||!Array.isArray(art.axisPixels)||art.axisPixels.length!==2||!art.axisPixels.every(pixel)||!Number.isFinite(art.spanPixels)||art.spanPixels<=0)throw new Error('Finite cleaner contact and measurement pixels required');
  const oto=sprite.kind==='otocinclus',required=oto?['body','belly','mouth']:['shell','foot'],coreNames=oto?required:[...required,'snout'];
  for(const name of required)if(!Array.isArray(parts[name])||!parts[name].length||!parts[name].every(pixel))throw new Error('Painted '+name+' anatomy required');
  const corePixels=coreNames.flatMap(name=>parts[name]||[]);if(!corePixels.every(pixel))throw new Error('Finite painted core anatomy required');
  const xs=corePixels.map(p=>p[0]),ys=corePixels.map(p=>p[1]),core={minX:Math.min(...xs),minY:Math.min(...ys),maxX:Math.max(...xs)+1,maxY:Math.max(...ys)+1};
  const [a,b]=art.axisPixels,dx=b[0]-a[0],dy=b[1]-a[1],length=Math.hypot(dx,dy);if(!length)throw new Error('Positive anatomical measurement span required');
  const endpoints=[a.map(v=>v+.5),b.map(v=>v+.5)];
  if(art.axis==='diagonal'){
   const extent=(Math.abs(dx)+Math.abs(dy))/length/2;
   for(let k=0;k<2;k++){const unit=(k?dy:dx)/length;endpoints[0][k]-=unit*extent;endpoints[1][k]+=unit*extent;}
  }else{const k=art.axis==='x'?0:1,sign=Math.sign(b[k]-a[k]);endpoints[0][k]-=sign*.5;endpoints[1][k]+=sign*.5;}
  const span=art.axis==='diagonal'?Math.hypot(endpoints[1][0]-endpoints[0][0],endpoints[1][1]-endpoints[0][1]):Math.abs(endpoints[1][art.axis==='x'?0:1]-endpoints[0][art.axis==='x'?0:1]);
  if(Math.abs(span-art.spanPixels)>1e-7)throw new Error('Cleaner anatomical span does not match its pixel endpoints');
  function nearest(points,target){let best=points[0],distance=Infinity;for(const p of points){const d=(p[0]-target[0])**2+(p[1]-target[1])**2;if(d<distance){distance=d;best=p;}}return best.map(v=>v+.5);}
  const ventral=sprite.pose==='ventral',mouth=contact.mouth.map(v=>v+.5),bodyCenter=[(core.minX+core.maxX)/2,(core.minY+core.maxY)/2];
  let vent;
  if(oto)vent=nearest(parts.body,ventral?[bodyCenter[0]-.5,core.minY+(core.maxY-core.minY)*.68]:[core.minX+(core.maxX-core.minX)*.42,core.maxY-1]);
  else{
   const foot=new Set(parts.foot.map(p=>p.join(','))),shared=parts.shell.filter(p=>foot.has(p.join(',')));
   if(!shared.length)throw new Error('Joined shell and foot anatomy required');
   vent=nearest(shared,ventral?[contact.mouth[0]+3,contact.mouth[1]+5]:[contact.mouth[0]-4,contact.mouth[1]-4]);
  }
  return{canvas:{width:canvas.width,height:canvas.height},anchor:[sprite.anchorX,sprite.anchorY],measurement:{basis:art.basis+'; '+art.includes,axis:art.axis,endpoints,pixels:span},core,landmarks:{mouth,vent,foot:[sprite.anchorX,sprite.anchorY],bodyCenter}};
 }
 function calibrate(scale,{sprite,reference}={}){
  if(!supported.includes(sprite?.kind)||sprite.reviewOnly)throw new RangeError('New cleaner species remain art-review-only');
  if(reference?.species!==sprite.kind)throw new RangeError('Reference species must match the cleaner sprite');
  if(!scale||typeof scale.calibrate!=='function'||![reference.lengthCm,reference.adultLengthCm,reference.cmPerWorldUnit,reference.basePixelToWorld].every(n=>Number.isFinite(n)&&n>0)||reference.cmPerWorldUnit!==scale.cmPerWorldUnit||!reference.growth)throw new Error('Complete existing animal scale reference with positive length required');
  const calibrated=scale.calibrate({species:reference.species,stage:reference.stage,sex:reference.sex,lengthCm:reference.lengthCm,basePixelToWorld:reference.basePixelToWorld,facing:reference.facing,metrics:metrics(sprite)});
  for(const key of ['adultLengthCm','adultLengthRangeCm','growth','source'])calibrated[key]=copy(reference[key]);
  return calibrated;
 }
 return{metrics,calibrate,supported};
});
