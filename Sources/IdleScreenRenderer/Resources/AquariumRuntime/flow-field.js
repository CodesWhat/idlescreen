(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumFlowField=factory();})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 function create({halfWidth,bedLevel,waterLevel,source,direction={x:1,y:0,z:0},output=1,backZ=-2.6,frontZ=4}){
  if(![halfWidth,bedLevel,waterLevel,backZ,frontZ,source?.x,source?.y,source?.z].every(Number.isFinite)||halfWidth<=0||waterLevel<=bedLevel||frontZ<=backZ)throw new RangeError('Finite tank and outlet bounds required');
  const length=Math.hypot(direction.x,direction.z)||1,dx=direction.x/length,dz=direction.z/length;let rate=1;
  function setOutput(value){if(Number.isFinite(value))rate=Math.max(0,Math.min(1.5,value));}setOutput(output);
  function sample(x,y,z,time=0){
   if(![x,y,z].every(Number.isFinite)||Math.abs(x)>halfWidth||y<bedLevel||y>waterLevel+.08||z<backZ||z>frontZ||rate===0)return{x:0,y:0,z:0,strength:0};
   const t=Number.isFinite(time)?time:0,h=Math.max(0,Math.min(1,(y-bedLevel)/(waterLevel-bedLevel))),rx=x-source.x,rz=z-source.z,along=rx*dx+rz*dz;
   const cross=rx*dz-rz*dx,width=.32+Math.max(0,along)*.20,jet=along>=-.12?Math.exp(-Math.max(0,along)/5-cross*cross/(width*width)-Math.pow((y-source.y)/.6,2)):0;
   const pulse=.94+.06*Math.sin(t*1.3+along*.4),circulation=.15*(h-.45),speed=rate*pulse*(jet*.60+circulation);
   const bottom=rate*(1-h)*.038;
   const vx=dx*speed+Math.sin(z*.7)*bottom*.15,vz=dz*speed+Math.sin(x*.3)*bottom*.2,vy=-rate*jet*.035+rate*.009*Math.sin(x/halfWidth*Math.PI);
   const magnitude=Math.hypot(vx,vy,vz);return{x:magnitude?vx/magnitude:0,y:magnitude?vy/magnitude:0,z:magnitude?vz/magnitude:0,strength:Math.min(1,magnitude*7)};
  }
  return{sample,setOutput,get output(){return rate;}};
 }
 return{create};
});
