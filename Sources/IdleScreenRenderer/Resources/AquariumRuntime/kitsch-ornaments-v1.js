(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory();
 else root.AquariumKitschOrnamentsV1=factory();
})(globalThis,function(){
 'use strict';
 const kinds=Object.freeze(['pirate-chest','wreck','diver-helmet']);
 const limits={'pirate-chest':[16,16,14],wreck:[28,22,14],'diver-helmet':[16,20,16]};
 const descriptors=Object.freeze(Object.fromEntries(kinds.map(kind=>[kind,Object.freeze({
  dimensionBasis:'authored',researchedProductDimensionsCm:null,defaultPlacement:false,reviewOnly:true,
  tankExteriorCm:Object.freeze([60,36,36]),authoredEnvelopeLimitCm:Object.freeze(limits[kind])
 })])));
 function create(THREE,{kind='pirate-chest',seed=621,cmPerUnit=36/8.4}={}){
  if(!kinds.includes(kind))throw new RangeError('Unknown ornament kind');
  if(!Number.isFinite(seed))throw new RangeError('seed must be finite');
  if(!Number.isFinite(cmPerUnit)||cmPerUnit<=0)throw new RangeError('cmPerUnit must be positive and finite');
  let randomState=seed>>>0;
  function random(){randomState=(Math.imul(randomState,1664525)+1013904223)>>>0;return randomState/4294967296;}
  const pixels=new Uint8Array(32*32*4);
  for(let y=0;y<32;y++)for(let x=0;x<32;x++){
   const shade=185+Math.floor(random()*65),seam=y%8===0?-.16:0;
   pixels.set([shade*(1+seam),shade*(1+seam),shade*(1+seam),255],(y*32+x)*4);
  }
  const map=new THREE.DataTexture(pixels,32,32,THREE.RGBAFormat);map.colorSpace=THREE.SRGBColorSpace;
  map.magFilter=map.minFilter=THREE.NearestFilter;map.wrapS=map.wrapT=THREE.RepeatWrapping;map.generateMipmaps=false;map.needsUpdate=true;
  const group=new THREE.Group();group.name=kind;
  const materials=[
   new THREE.MeshLambertMaterial({map,vertexColors:true,flatShading:true}),
   new THREE.MeshStandardMaterial({map,vertexColors:true,flatShading:true,metalness:.35,roughness:.62})
  ];
  const batches=materials.map((material,index)=>({material,name:kind+'-surface-'+index,position:[],color:[],uv:[]}));
  const components=[],geometries=[],groundContacts=[],mountAnchors=[],openings=[];
  const wood=[.42,.29,.17],darkWood=[.27,.20,.14],brass=[.68,.46,.22],gold=[.91,.68,.22],patina=[.19,.36,.29];
  function solid(id,points,faces,color=wood,batchIndex=0,transform=p=>p){
   const batch=batches[batchIndex],converted=points.map(p=>new THREE.Vector3(...transform(p)).divideScalar(cmPerUnit));
   const center=converted.reduce((sum,p)=>sum.add(p),new THREE.Vector3()).multiplyScalar(1/converted.length);
   const vertexStart=batch.position.length/3;
   for(const face of faces)for(let j=1;j<face.length-1;j++){
    let triangle=[converted[face[0]],converted[face[j]],converted[face[j+1]]];
    const normal=new THREE.Vector3().subVectors(triangle[1],triangle[0]).cross(new THREE.Vector3().subVectors(triangle[2],triangle[0]));
    const middle=triangle.reduce((sum,p)=>sum.add(p),new THREE.Vector3()).multiplyScalar(1/3);
    if(normal.dot(middle.sub(center))<0)triangle=[triangle[0],triangle[2],triangle[1]];
    for(const p of triangle){batch.position.push(p.x,p.y,p.z);batch.color.push(...color);batch.uv.push((p.x+p.z*.31)*cmPerUnit/4,p.y*cmPerUnit/4);}
   }
   components.push({id,meshName:batch.name,vertexStart,vertexCount:batch.position.length/3-vertexStart});
  }
  const cubeFaces=[[0,3,2,1],[4,5,6,7],[0,1,5,4],[1,2,6,5],[2,3,7,6],[3,0,4,7]];
  function box(id,x,y,z,w,h,d,color=wood,batch=0,transform){
   solid(id,[[-1,-1,-1],[1,-1,-1],[1,1,-1],[-1,1,-1],[-1,-1,1],[1,-1,1],[1,1,1],[-1,1,1]].map(([a,b,c])=>[x+a*w/2,y+b*h/2,z+c*d/2]),cubeFaces,color,batch,transform);
  }
  function prism(id,profile,delta,color=wood,batch=0,transform){
   solid(id,[...profile,...profile.map(p=>p.map((v,i)=>v+delta[i]))],cubeFaces,color,batch,transform);
  }
  function ring(id,inner,outer,low,high,angle0,angle1,color=brass){
   const profile=[[outer,angle0],[outer,angle1],[inner,angle1],[inner,angle0]].map(([radius,angle])=>[Math.cos(angle)*radius,low,Math.sin(angle)*radius]);
   prism(id,profile,[0,high-low,0],color,1);
  }
  function anchor(target,id,position,normal=[0,1,0]){target.push({id,position:position.map(v=>v/cmPerUnit),normal});}
  function opening(id,from,to,radius){openings.push({id,from:from.map(v=>v/cmPerUnit),to:to.map(v=>v/cmPerUnit),clearRadiusCm:radius});}
  if(kind==='pirate-chest'){
   box('chest-floor',0,.35,0,12,.7,8,darkWood);
   for(const side of [-1,1]){
    box('chest-side-'+side,side*5.7,3.1,0,.6,4.8,8,wood);
    for(const face of [-1,1]){
     box('chest-port-panel-'+side+'-'+face,side*4.15,3.1,face*3.7,3.7,4.8,.6,wood);
     box('chest-band-'+side+'-'+face,side*4.7,3.1,face*4.04,.32,4.9,.12,brass,1);
    }
   }
   for(const face of [-1,1]){
    box('chest-port-lintel-'+face,0,5.05,face*3.7,4.6,.9,.6,wood);
    box('chest-port-sill-'+face,0,.95,face*3.7,4.6,.5,.6,darkWood);
   }
   const angle=-Math.PI*.36,turn=([x,y,z])=>{const yy=y-5.5,zz=z+4;return[x,5.5+yy*Math.cos(angle)-zz*Math.sin(angle),-4+yy*Math.sin(angle)+zz*Math.cos(angle)];};
   for(let i=0;i<12;i++){
    const a=i*Math.PI/12,b=(i+1)*Math.PI/12;
    const profile=[[4,2.8,a],[4,2.8,b],[3.6,2.4,b],[3.6,2.4,a]].map(([zRadius,yRadius,t])=>[-6,5.5+Math.sin(t)*yRadius,Math.cos(t)*zRadius]);
    prism('arched-lid-plank-'+i,profile,[12,0,0],i%3?wood:darkWood,0,turn);
   }
   for(const x of [-4.6,4.6])box('raised-lid-band-'+x,x,5.55,0,.35,.2,8,brass,1,turn);
   box('lock-plate',0,5.12,4.12,.9,.7,.24,brass,1);
   box('key-slot',0,5.15,4.26,.15,.29,.06,darkWood);
   for(const x of [-3.8,3.8])for(let i=0;i<4;i++)box('treasure-'+x+'-'+i,x+(i%2)*.45,1.1+Math.floor(i/2)*.16,(i%2-.5)*1.2,.8,.22,.8,gold,1);
   for(const [i,p]of [[-4.8,0,-2.8],[4.8,0,-2.8],[0,0,2.8]].entries())anchor(groundContacts,'foot-'+i,p);
   anchor(mountAnchors,'side-rim',[5.7,5.5,2]);opening('chest-doorway',[0,2.8,8],[0,2.8,-8],.35);
  }else if(kind==='wreck'){
   const stations=[[-12,.5],[-8,4],[-3,5],[3,5],[8,4],[12,.5]];
   for(let i=0;i<stations.length-1;i++){
    const [a,wa]=stations[i],[b,wb]=stations[i+1];
    prism('keel-plank-'+i,[[a,0,-wa],[b,0,-wb],[b,0,wb],[a,0,wa]],[0,.6,0],darkWood);
    for(const side of [-1,1]){
     const profile=[[a,.6,side*wa],[b,.6,side*wb],[b,.6,side*(wb-.4)],[a,.6,side*(wa-.4)]];
     if(i!==2)prism('hull-wall-'+i+'-'+side,profile,[0,5.1,0],wood);
     else{
      prism('hull-port-sill-'+side,profile,[0,.5,0],wood);
      prism('hull-port-lintel-'+side,profile.map(p=>[p[0],4.6,p[2]]),[0,1.1,0],wood);
     }
    }
   }
   for(const x of [-8,-4,4,8])for(const side of [-1,1])box('rib-'+x+'-'+side,x,3,side*(Math.abs(x)>5?3.6:4.6),.38,5.3,.5,darkWood);
   box('broken-mast',5,8.2,-1,.65,15.2,.65,darkWood);
   box('yardarm',4,13,-1,10,.45,.5,darkWood);
   for(let i=0;i<6;i++)box('broken-deck-'+i,-9.6+i*.48,6.05,.1, .35,.5,6.4,wood);
   for(const x of [-8,0,8])anchor(groundContacts,'keel-'+x,[x,0,0]);
   anchor(mountAnchors,'port-side-rail',[-6,5.7,4.15]);opening('wreck-swimthrough',[0,2.8,8],[0,2.8,-8],.4);
  }else{
   const segments=12,tau=Math.PI*2;
   for(let i=0;i<segments;i++){
    const a=i*tau/segments,b=(i+1)*tau/segments;
    ring('helmet-foot-'+i,6.3,7,0,1.2,a,b,patina);
    ring('helmet-lower-shell-'+i,5.5,6.2,1.2,5,a,b);
    if(![2,3,8,9].includes(i))ring('helmet-window-shell-'+i,5.5,6.2,5,10,a,b);
    for(let row=0;row<5;row++){
     const t0=row*Math.PI/10,t1=(row+1)*Math.PI/10;
     const outer0=6.2*Math.cos(t0),outer1=row===4?.12:6.2*Math.cos(t1);
     const inner0=5.6*Math.cos(t0),inner1=row===4?.06:5.6*Math.cos(t1);
     const profile=[[outer0,a,10+6.2*Math.sin(t0)],[outer0,b,10+6.2*Math.sin(t0)],[inner0,b,10+5.6*Math.sin(t0)],[inner0,a,10+5.6*Math.sin(t0)]].map(([r,t,y])=>[Math.cos(t)*r,y,Math.sin(t)*r]);
     const top=[[outer1,a,10+6.2*Math.sin(t1)],[outer1,b,10+6.2*Math.sin(t1)],[inner1,b,10+5.6*Math.sin(t1)],[inner1,a,10+5.6*Math.sin(t1)]].map(([r,t,y])=>[Math.cos(t)*r,y,Math.sin(t)*r]);
     solid('helmet-crown-'+i+'-'+row,[...profile,...top],cubeFaces,brass,1);
    }
   }
   for(const face of [-1,1]){
    for(const x of [-3.2,3.2])box('window-upright-'+face+'-'+x,x,7.5,face*5.4,.28,5.2,.45,patina,1);
    for(const y of [5,10])box('window-crosspiece-'+face+'-'+y,0,y,face*5.4,6.5,.28,.45,patina,1);
   }
   box('top-vent',0,16.14,0,.25,.12,.25,patina,1);
   for(const [i,p]of [[6.65,0,0],[-6.65,0,0],[0,0,6.65]].entries())anchor(groundContacts,'flange-'+i,p);
   anchor(mountAnchors,'flange-top',[6.65,1.2,0]);opening('helmet-window',[0,7.5,9],[0,7.5,-9],.5);
  }
  for(const batch of batches)if(batch.position.length){
   const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(batch.position,3));geometry.setAttribute('color',new THREE.Float32BufferAttribute(batch.color,3));geometry.setAttribute('uv',new THREE.Float32BufferAttribute(batch.uv,2));geometry.computeVertexNormals();geometries.push(geometry);
   const mesh=new THREE.Mesh(geometry,batch.material);mesh.name=batch.name;mesh.castShadow=mesh.receiveShadow=true;mesh.userData={solid:true,hardscape:true,climbable:true};group.add(mesh);
  }
  group.updateMatrixWorld(true);const size=new THREE.Box3().setFromObject(group).getSize(new THREE.Vector3()).multiplyScalar(cmPerUnit),dimensionsCm={x:size.x,y:size.y,z:size.z};
  function worldAnchor(id){const anchor=[...groundContacts,...mountAnchors].find(a=>a.id===id);if(!anchor)throw new RangeError('Unknown anchor');group.updateWorldMatrix(true,false);return{id,position:new THREE.Vector3(...anchor.position).applyMatrix4(group.matrixWorld),normal:new THREE.Vector3(...anchor.normal).applyMatrix3(new THREE.Matrix3().getNormalMatrix(group.matrixWorld)).normalize()};}
  let disposed=false;
  function dispose(){if(disposed)return;disposed=true;for(const resource of [...geometries,...materials,map])resource.dispose();}
  return{group,geometries,materials,maps:[map],components,groundContacts,mountAnchors,openings,dimensionsCm,worldAnchor,dispose};
 }
 return Object.freeze({kinds,descriptors,create});
});
