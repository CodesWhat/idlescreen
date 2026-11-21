(function(root){
 'use strict';
 const spreads={focused:[.16,.48],natural:[.25,.68],broad:[.65,.98]};
 function mask(v,spread){const [inner,outer]=spreads[spread]||spreads.natural,t=Math.max(0,Math.min(1,(Math.abs(v*2-1)-inner)/(outer-inner)));return .025+.975*(1-t*t*(3-2*t));}
 function createTexture(THREE,spread){
  const data=new Uint8Array(64*64*4);
  for(let y=0;y<64;y++)for(let x=0;x<64;x++){const i=(y*64+x)*4,value=Math.round(mask((y+.5)/64,spread)*255);data[i]=data[i+1]=data[i+2]=value;data[i+3]=255;}
  const texture=new THREE.DataTexture(data,64,64,THREE.RGBAFormat);texture.magFilter=texture.minFilter=THREE.LinearFilter;texture.generateMipmaps=false;texture.needsUpdate=true;return texture;
 }
 function transmission(THREE,light,x,y,z,spread){const projected=new THREE.Vector3(x,y,z).applyMatrix4(light.shadow.matrix);return mask(projected.y,spread);}
 const api={createTexture,transmission};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumLightFootprint=api;
})(typeof window==='object'?window:globalThis);
