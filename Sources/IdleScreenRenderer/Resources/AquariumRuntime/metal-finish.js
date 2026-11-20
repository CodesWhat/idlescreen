(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumMetalFinish=factory();})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 function create(THREE,document){
  const faces=[];
  for(let face=0;face<6;face++){
   const canvas=document.createElement('canvas');canvas.width=canvas.height=128;const g=canvas.getContext('2d');
   for(let y=0;y<128;y++)for(let x=0;x<128;x+=2){
    const u=x/128,v=y/128,softbox=Math.exp(-Math.pow((u-(face%2?.70:.24))/.11,2)),bar=Math.exp(-Math.pow((v-.22)/.025,2));
    const wall=.12+.13*(1-v),shade=Math.min(1,wall+softbox*.55+bar*.55),r=Math.round(shade*235),green=Math.round(shade*244),b=Math.round(shade*249);
    g.fillStyle='rgb('+r+','+green+','+b+')';g.fillRect(x,y,2,1);
   }
   faces.push(canvas);
  }
  const map=new THREE.CubeTexture(faces);map.colorSpace=THREE.SRGBColorSpace;map.needsUpdate=true;
  const material=new THREE.MeshStandardMaterial({color:0xd4d9d6,metalness:.96,roughness:.23,envMap:map,envMapIntensity:1,flatShading:false});material.name='counter-chrome';
  function update(room,led){material.envMapIntensity=.035+Math.max(0,room)*.90+Math.max(0,led)*.45;}
  return{material,map,update};
 }
 return{create};
});
