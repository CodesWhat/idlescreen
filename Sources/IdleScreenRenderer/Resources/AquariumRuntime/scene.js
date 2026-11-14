/* B v2: original procedural 3D aquarium. Three.js MIT. Shared A/B sprite artwork. */
(() => {
'use strict';
const embedded=top!==self;
document.body.classList.toggle('embedded',embedded);
let renderer;
try { renderer=new THREE.WebGLRenderer({antialias:false,alpha:false,powerPreference:'low-power'}); }
catch (_) { document.getElementById('error').style.display='block';return; }
document.body.prepend(renderer.domElement);
renderer.localClippingEnabled=true;renderer.setPixelRatio(1);renderer.outputColorSpace=THREE.SRGBColorSpace;renderer.setClearColor(0x000000);
renderer.shadowMap.enabled=true;renderer.shadowMap.type=THREE.PCFSoftShadowMap;
const assets={gravel:'basalt',rock:'slate',shrimp:'red',fish:'chili',decor:'none',wood:'pixel',plants:'classic',cleaners:'contact'};
const scene=new THREE.Scene(),world=new THREE.Group();scene.add(world);
const camera=new THREE.PerspectiveCamera(29.5,Math.max(1,innerWidth)/Math.max(1,innerHeight),.1,100);
const metric=AquariumMetricScale,cmPerUnit=metric.cmPerUnit;
const tankHalf=metric.tank.halfWidth,innerHalf=tankHalf-metric.tank.glass,frontZ=metric.tank.frontZ,outerBack=metric.tank.backZ;
const frontBound=metric.tank.frontBound,backBound=metric.tank.backBound,innerDepth=frontBound-backBound,centerZ=(frontBound+backBound)/2;
const bedLevel=metric.tank.bedLevel,waterLevel=metric.tank.waterLevel;
let rasterHeight=864,conditionLevel=0,waterCondition=null,lastSimulation=0,conditionMode='manual',conditionEpoch=0,conditionStart=0;
let breeding=AquariumBreeding.create({seed:8401,maxAnimals:80}),breedingSupports=[],stageFrameCache=new Map();
let water=AquariumWaterEcosystem.create({volumeL:50,filterMaturity:.8});let accountedDissolved=0;
let ecology=AquariumEcology.create({seed:8401});let ecologyRate=1,ecologyVisuals=null,lastEcologyReport=-1;
let filterOutlet={x:0,y:7.25,z:-1.80},collisionWorld=null,pelletMaterial=null,pelletGeometry=null;
const horizon=0;
let eyeHeight=0,eyeDepth=0,matchedFov=0;
const tankClip=[new THREE.Plane(new THREE.Vector3(1,0,0),innerHalf),new THREE.Plane(new THREE.Vector3(-1,0,0),innerHalf),new THREE.Plane(new THREE.Vector3(0,0,-1),frontBound),new THREE.Plane(new THREE.Vector3(0,1,0),-.1)];
const ambient=new THREE.AmbientLight(0xc1ccd0,.675);scene.add(ambient);
const fill=new THREE.DirectionalLight(0xcbd5d8,.8);fill.position.set(4,7,10);fill.target.position.set(0,2.8,-1.4);scene.add(fill,fill.target);
const tankLights=Array.from({length:5},(_,index)=>{const light=new THREE.SpotLight(0xedf2da,0,0,.62,.40,2);light.name='tank-led-source-'+index;light.shadow.mapSize.set(512,512);light.shadow.camera.near=.15;light.shadow.camera.far=24;light.shadow.bias=-.00015;light.shadow.normalBias=.025;light.shadow.radius=2;scene.add(light,light.target);return light;});
const lightDepthMaps=Object.fromEntries(['focused','natural','broad'].map(name=>[name,AquariumLightFootprint.createTexture(THREE,name)]));
let roomArt=null,roomFinish='neutral',lightSpread='natural',lightOutput=1;
let roomLevel=1,tankLightCount=3,lampSpan=0,roomMode='auto',lastRoomCheck=-Infinity;
let view='front',framing='whole',mode='desktop',preset='daylight',enabled=false,clock=0,last=0,handle=0,visibleWidth=tankHalf*2,worldWidth=tankHalf*2,lastDraw=0;
let presetAssemblies=null,presetRevision=0,restoringTank=false,basicEquipment=null,equipmentConnections=null,equipmentConnectionOptions=null;
let botanicalArt=null,physicalParts=[],manzanitaArt=null,variedPlants=[];
let sceneStyle='basic',lushPlants=null,premiumEquipment=null,hangOnFilter=null,carpetArt=null,mossFormation=null,surfaceNavigation=null,navigationSites=[],leafContacts=new Map(),flowField=null,pumpOutput=1,chromeFinish=null,co2Mist=[],nextReturnRipple=0;
let surfaceStudy=null,surfaceMode='current';
let designerActive=typeof location==='object'&&new URLSearchParams(location.search).get('designer')==='1',designerRuntime=null,designerLayout=null,designerSelectedId=null,designerTool='select',designerSelectionScope='added',designerAssetId=null,designerRequestId=0,designerLayoutSignature='',designerSolidSignature='',designerStatusSignature='',designerNavigationError='',designerSelection=null,baselineCollisionMeshes=[];
let fish=[],shrimps=[],snails=[],bubbles=[],plants=[],mats=[],geometries=[],maps=[],lightPools=[],lampEmitters=[],backdrop,waterSurface,sideWater=[];
const makeRandom=seed=>()=>{seed=Math.imul(seed^seed>>>15,1|seed);seed^=seed+Math.imul(seed^seed>>>7,61|seed);return((seed^seed>>>14)>>>0)/4294967296;};
let random=makeRandom(8401);
function rememberMaterial(m){m.clippingPlanes=tankClip;mats.push(m);return m;}
function material(color,map=null){return rememberMaterial(new THREE.MeshLambertMaterial({color,map,flatShading:true}));}
function basic(color,options={}){return rememberMaterial(new THREE.MeshBasicMaterial({color,...options}));}
function mesh(geometry,mat,x=0,y=0,z=0,parent=world){geometries.push(geometry);const result=new THREE.Mesh(geometry,mat);result.position.set(x,y,z);parent.add(result);result.castShadow=!!(Array.isArray(mat)?mat.some(m=>m.isMeshLambertMaterial):mat.isMeshLambertMaterial);result.receiveShadow=result.castShadow;return result;}
function box(w,h,d,mat,x,y,z,parent=world){return mesh(new THREE.BoxGeometry(w,h,d),mat,x,y,z,parent);}
function cylinder(a,b,r0,r1,mat,parent=world,sides=7,openEnded=false){const start=new THREE.Vector3(...a),end=new THREE.Vector3(...b),v=end.clone().sub(start);const middle=start.clone().add(end).multiplyScalar(.5);const o=mesh(new THREE.CylinderGeometry(r1,r0,v.length(),sides,1,openEnded),mat,middle.x,middle.y,middle.z,parent);o.quaternion.setFromUnitVectors(new THREE.Vector3(0,1,0),v.normalize());return o;}
function pixelMap(palette,kind,seed){
 const c=document.createElement('canvas');c.width=c.height=64;const g=c.getContext('2d'),rnd=makeRandom(seed);
 g.fillStyle=palette[0];g.fillRect(0,0,64,64);
 if(kind==='wood'){
  for(let i=0;i<25;i++){g.fillStyle=palette[1+i%(palette.length-1)];const x=Math.floor(rnd()*16)*4;let y=Math.floor(rnd()*12)*4;for(let n=0;n<3;n++){g.fillRect(x+(n%2)*2,y,2+rnd()*3,8+rnd()*16);y+=14;}}
  g.fillStyle=palette[palette.length-1];for(let i=0;i<5;i++)g.fillRect(Math.floor(rnd()*16)*4,Math.floor(rnd()*16)*4,2,12);
 }else if(kind==='sponge'){
  for(let y=0;y<64;y+=4)for(let x=0;x<64;x+=4){const shade=Math.floor(rnd()*palette.length);g.fillStyle=palette[shade];g.fillRect(x,y,2+(shade%2),2);}
 }else if(kind==='gravel'){
  for(let i=0;i<100;i++){g.fillStyle=i%4?palette[0]:palette[1];g.fillRect(Math.floor(rnd()*64),Math.floor(rnd()*64),1,1);}
 }else{
  for(let i=0;i<90;i++){g.fillStyle=palette[Math.floor(rnd()*palette.length)];const x=Math.floor(rnd()*32)*2,y=Math.floor(rnd()*32)*2,w=2+Math.floor(rnd()*3)*2,h=2+Math.floor(rnd()*2)*2;g.fillRect(x,y,w,h);if(i%6===0)g.fillRect(x+2,y-2,Math.max(2,w-2),2);}
  if(kind==='slate'){g.fillStyle=palette[palette.length-1];g.fillRect(0,22,28,1);g.fillRect(24,23,20,1);g.fillRect(42,24,22,1);g.fillRect(3,50,25,1);}
 }
 const map=new THREE.CanvasTexture(c);map.colorSpace=THREE.SRGBColorSpace;map.minFilter=map.magFilter=THREE.NearestFilter;map.wrapS=map.wrapT=THREE.RepeatWrapping;maps.push(map);return map;
}
function contact(x,z,rx,rz,opacity=.19){const o=mesh(new THREE.CircleGeometry(1,16),basic(0x061a22,{transparent:true,opacity,depthWrite:false}),x,.17,z);o.rotation.x=-Math.PI/2;o.scale.set(rx,rz,1);o.userData.contactShadow=true;return o;}
function polygonShape(profile=0){
 const outlines=[
  [[-1,-.46],[-.65,-.88],[.18,-.94],[.76,-.58],[1,-.12],[.86,.51],[.45,.83],[-.05,.74],[-.44,.9],[-.93,.41]],
  [[-.96,-.32],[-.67,-.82],[.4,-.74],[.87,-.35],[.76,.23],[.48,.44],[.35,.69],[-.19,.77],[-.48,.61],[-.96,.31]],
  [[-.98,-.42],[-.64,-.79],[.25,-.74],[.79,-.31],[.72,.18],[.4,.31],[.28,.7],[-.31,.73],[-.72,.57],[-1,.14]],
  [[-1,-.55],[-.44,-.85],[.61,-.62],[1,.21],[.44,.72],[-.68,.38]],
  [[-.96,-.38],[-.5,-.72],[.56,-.63],[1,-.12],[.46,.53],[-.47,.71],[-.84,.23]]
 ];
 const shape=new THREE.Shape();outlines[profile%outlines.length].forEach(([x,z],i)=>i?shape.lineTo(x,z):shape.moveTo(x,z));shape.closePath();return shape;
}
let M={};
function slate(x,y,z,w,d,h,rotation=0,profile=0){
 const outline=polygonShape(profile).getPoints();outline.pop();
 if(THREE.ShapeUtils.isClockWise(outline))outline.reverse();
 const wear=[.035,-.055,.018,-.025,.045,-.03,.025,-.04,.008,-.02];
 const rings=[[],[],[],[]],perimeter=[0];
 for(let i=0;i<outline.length;i++){
  const p=outline[i],chip=wear[(i+profile*3)%wear.length],slope=-p.x*.12+p.y*.025,breakoff=profile===2?Math.max(0,p.x)*.24:0;
  rings[0].push([p.x*w*.94,h*(slope+chip*.4),p.y*d*.94]);
  rings[1].push([p.x*w,h*(.08+slope+chip),p.y*d]);
  rings[2].push([p.x*w*(.99+chip),h*(.86+slope-chip*1.5-breakoff*.5),p.y*d*(.98-chip)]);
  rings[3].push([p.x*w*(.91-chip),h*(1+slope+chip-breakoff),p.y*d*(.91+chip)]);
  const q=outline[(i+1)%outline.length];perimeter.push(perimeter[i]+Math.hypot((q.x-p.x)*w,(q.y-p.y)*d));
 }
 const positions=[],uvs=[];
 function triangle(a,b,c,ta,tb,tc){positions.push(...a,...b,...c);uvs.push(...ta,...tb,...tc);}
 const planeUV=p=>[p[0]*.46+profile*.23,p[2]*.46];
 if(profile===2){
  const crown=[-.035*w,h*1.015,-.08*d];
  for(let i=0;i<outline.length;i++){const a=rings[3][i],b=rings[3][(i+1)%outline.length];triangle(crown,b,a,planeUV(crown),planeUV(b),planeUV(a));}
 }else for(const [a,b,c] of THREE.ShapeUtils.triangulateShape(outline,[])){
  triangle(rings[3][a],rings[3][c],rings[3][b],planeUV(rings[3][a]),planeUV(rings[3][c]),planeUV(rings[3][b]));
 }
 const topCount=positions.length/3;
 for(const [a,b,c] of THREE.ShapeUtils.triangulateShape(outline,[])){
  triangle(rings[0][a],rings[0][b],rings[0][c],planeUV(rings[0][a]),planeUV(rings[0][b]),planeUV(rings[0][c]));
 }
 for(let ring=0;ring<3;ring++)for(let i=0;i<outline.length;i++){
  const j=(i+1)%outline.length,a=rings[ring][i],b=rings[ring+1][i],c=rings[ring][j],e=rings[ring+1][j];
  const ta=[perimeter[i]*.52,a[1]*.8],tb=[perimeter[i]*.52,b[1]*.8],tc=[perimeter[i+1]*.52,c[1]*.8],te=[perimeter[i+1]*.52,e[1]*.8];
  triangle(a,b,c,ta,tb,tc);triangle(b,e,c,tb,te,tc);
 }
 const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setAttribute('uv',new THREE.Float32BufferAttribute(uvs,2));geometry.addGroup(0,topCount,0);geometry.addGroup(topCount,positions.length/3-topCount,1);geometry.computeVertexNormals();
 const stone=mesh(geometry,[M.slateTop,M.slateSide],x,y,z);stone.rotation.y=rotation;return stone;
}
function rockStack(x,z,size=1){
 contact(x,z,size*1.78,size*1.04,.24);
 slate(x,.14,z,size*1.7,size*.89,.56,-.055,0);
 slate(x-.16,.53,z-.025,size*1.54,size*.8,.86,-.018,1);
 slate(x-.23,1.26,z+.08,size*1.48,size*.75,.84,.035,2);
 slate(x+size*1.21,.19,z+size*.15,size*.49,size*.55,.38,-.17,3);
 slate(x+size*.76,.59,z+size*.34,size*.48,size*.39,.19,-.1,4);
}
function branch(points,radius,parent=world,shape=null){
 const profile=shape||{},sides=10,steps=(points.length-1)*4;
 const spine=new THREE.CatmullRomCurve3(points.map(p=>new THREE.Vector3(p[0],p[1],p[2])),false,'catmullrom',.32);
 const positions=[],uvs=[],indices=[],centers=[];
 let distance=0,previous=null,normal=null;
 for(let i=0;i<=steps;i++){
  const t=i/steps,point=spine.getPoint(t),tangent=spine.getTangent(t).normalize();
  if(previous)distance+=point.distanceTo(previous);previous=point.clone();centers.push(point);
  if(!normal){const reference=Math.abs(tangent.z)<.85?new THREE.Vector3(0,0,1):new THREE.Vector3(0,1,0);normal=reference.cross(tangent).normalize();}
  normal.addScaledVector(tangent,-normal.dot(tangent)).normalize();
  const binormal=new THREE.Vector3().crossVectors(tangent,normal).normalize();
  const segment=Math.min(points.length-2,Math.floor(t*(points.length-1))),fraction=t*(points.length-1)-segment,ease=fraction*fraction*(3-2*fraction);
  const a=points[segment],b=points[segment+1],r=radius*THREE.MathUtils.lerp(a[3]??1,b[3]??.035,ease),flat=THREE.MathUtils.lerp(a[4]??.76,b[4]??.76,ease);
  const twist=(profile.twist||0)+t*.34+Math.sin(t*5.8)*.1;
  for(let j=0;j<=sides;j++){
   const angle=j/sides*Math.PI*2+twist,lobe=1+.13*Math.cos(angle*3+t*1.1)+.05*Math.sin(angle*5-t*2);
   const radial=normal.clone().multiplyScalar(Math.cos(angle)).addScaledVector(binormal,Math.sin(angle)*flat);
   const vertex=point.clone().addScaledVector(radial,r*lobe);
   if(profile.broken&&i===steps)vertex.addScaledVector(tangent,r*(.65*Math.cos(angle*3)-.22));
   positions.push(vertex.x,vertex.y,vertex.z);uvs.push(j/sides,distance*.58);
   if(i<steps&&j<sides){const k=i*(sides+1)+j;indices.push(k,k+1,k+sides+1,k+1,k+sides+2,k+sides+1);}
  }
 }
 for(const end of [0,steps]){
  const cap=positions.length/3,point=centers[end],tangent=spine.getTangent(end/steps).normalize();
  if(end===steps&&!profile.broken)point.addScaledVector(tangent,radius*.055);
  positions.push(point.x,point.y,point.z);uvs.push(.5,end?distance*.58:0);
  for(let j=0;j<sides;j++){const k=end*(sides+1)+j;if(end===0)indices.push(cap,k+1,k);else indices.push(cap,k,k+1);}
 }
 const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setAttribute('uv',new THREE.Float32BufferAttribute(uvs,2));geometry.setIndex(indices);geometry.computeVertexNormals();
 const normals=geometry.attributes.normal;
 for(let i=0;i<=steps;i++){
  const first=i*(sides+1),last=first+sides,seam=new THREE.Vector3().fromBufferAttribute(normals,first).add(new THREE.Vector3().fromBufferAttribute(normals,last)).normalize();
  normals.setXYZ(first,seam.x,seam.y,seam.z);normals.setXYZ(last,seam.x,seam.y,seam.z);
 }
 return mesh(geometry,M.wood,0,0,0,parent);
}
function mossPatch(x,y,z,length=1,angle=0){
 const g=new THREE.Group();g.position.set(x,y,z);g.rotation.y=angle;world.add(g);
 const rnd=makeRandom(Math.floor(random()*4294967296));for(let i=1;i<64;i++)random();
 if(!M.moss.map){
  const width=64,height=128,data=new Uint8Array(width*height*4),grain=makeRandom(418);
  const shades=[[194,205,152],[218,224,180],[165,187,129],[202,216,157]];
  function dot(px,py,r,shade){for(let yy=Math.floor(py-r);yy<=Math.ceil(py+r);yy++)for(let xx=Math.floor(px-r);xx<=Math.ceil(px+r);xx++){if(xx<0||xx>=width||yy<0||yy>=height||Math.hypot(xx-px,yy-py)>r+.3)continue;const k=(yy*width+xx)*4;data[k]=shade[0];data[k+1]=shade[1];data[k+2]=shade[2];data[k+3]=255;}}
  function stroke(ax,ay,bx,by,r,shade){const steps=Math.max(1,Math.ceil(Math.hypot(bx-ax,by-ay)*1.5));for(let i=0;i<=steps;i++){const t=i/steps;dot(ax+(bx-ax)*t,ay+(by-ay)*t,r,shade);}}
  const stem=t=>32+Math.sin(t*.068)*2.2;
  for(let py=2;py<123;py++)stroke(stem(py),py,stem(py+1),py+1,.65,shades[2]);
  for(let i=0;i<17;i++){
   const py=12+i*6.2,side=i%2?1:-1,span=(11+grain()*10)*(1-py/170),ex=stem(py)+side*span,ey=py+7+grain()*5;
   stroke(stem(py),py,ex,ey,.65,shades[i%4]);
   for(let n=1;n<=4;n++){
    const t=n/5,bx=stem(py)+(ex-stem(py))*t,by=py+(ey-py)*t,size=3+grain()*3;
    stroke(bx,by,bx+side*size,by+size*(.7+grain()*.5),.8,shades[(i+n)%4]);
    stroke(bx,by,bx+side*size*.65,by-size*.45,.65,shades[(i+n+1)%4]);
   }
  }
  for(let py=8;py<122;py+=5){const side=py%2?1:-1;stroke(stem(py),py,stem(py)+side*(2+grain()*2),py+5,.7,shades[1]);}
  const map=new THREE.DataTexture(data,width,height,THREE.RGBAFormat);map.colorSpace=THREE.SRGBColorSpace;map.minFilter=map.magFilter=THREE.NearestFilter;map.generateMipmaps=false;map.needsUpdate=true;maps.push(map);
  [[M.moss,0x7b9143],[M.mossLight,0xa0af58],[M.mossLeaf,0x647b3b]].forEach(([m,color])=>{m.color.setHex(color);m.map=map;m.side=THREE.DoubleSide;m.alphaTest=.45;m.needsUpdate=true;});
 }
 const shades=[M.moss,M.mossLight,M.mossLeaf];
 function sprig(root,height,width,bend,yaw,mat,droop=false){
  const along=new THREE.Vector3(Math.cos(yaw),0,Math.sin(yaw));
  const stations=[0,.34,.72,1],profile=[.08,.89,1,.24];
  for(let cross=0;cross<2;cross++){
   const side=new THREE.Vector3(Math.cos(yaw+cross*Math.PI/2+.4),0,Math.sin(yaw+cross*Math.PI/2+.4)),positions=[],uv=[],indices=[];
   for(let i=0;i<4;i++){
    const t=stations[i],rise=droop?Math.sin(t*Math.PI)*.095-height*t*t:height*(t-.08*Math.sin(t*Math.PI));
    const center=new THREE.Vector3(root[0],root[1]+rise,root[2]).addScaledVector(along,bend*t*t);
    for(const sign of [-1,1]){const p=center.clone().addScaledVector(side,sign*width*profile[i]*.5);positions.push(p.x,p.y,p.z*.88);uv.push(sign<0?0:1,t);}
    if(i<3){const k=i*2;indices.push(k,k+2,k+1,k+1,k+2,k+3);}
   }
   const geo=new THREE.BufferGeometry();geo.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geo.setAttribute('uv',new THREE.Float32BufferAttribute(uv,2));geo.setIndex(indices);geo.computeVertexNormals();mesh(geo,mat,0,0,0,g);
  }
 }
 const tufts=Math.max(3,Math.round(length*3.5)+1);
 for(let i=0;i<tufts;i++){
  const cx=(i/(tufts-1)-.5)*length*.79+(rnd()-.5)*.025,cz=Math.sin(i*2.1)*.055+(rnd()-.5)*.035;
  const crown=.245+rnd()*.075;
  for(let n=0;n<10;n++){
   const azimuth=n*2.39996+rnd()*.65,spread=.012+Math.sqrt(rnd())*.066,edge=spread/.078;
   const root=[cx+Math.cos(azimuth)*spread,-.045-rnd()*.025,cz+Math.sin(azimuth)*spread];
   const height=crown*(1-edge*.28)+rnd()*.018,width=.13+rnd()*.065,bend=.035+edge*.095;
   sprig(root,height,width,bend,azimuth,shades[(n+i)%7===0?1:n%3===0?2:0]);
  }
 }
 const drapes=length>1.2?3:2;
 for(let i=0;i<drapes;i++){
  const xx=((i+.45)/drapes-.5)*length*.77;
  sprig([xx,-.05,.095+rnd()*.035],.10+rnd()*.055,.12+rnd()*.025,.12+rnd()*.045,Math.PI*.5+(rnd()-.5)*.65,shades[i%2?0:2],true);
 }
 batchStatic(g);
}
function batchStatic(parent,deep=true,excluded=new Set()){
 parent.updateWorldMatrix(true,true);
 const inverse=parent.matrixWorld.clone().invert(),groups=new Map(),selected=[];
 function collect(object){if(!object.isMesh||object.isInstancedMesh||object.material.vertexColors||Array.isArray(object.material)||excluded.has(object))return;const key=[object.material.uuid,object.castShadow,object.receiveShadow,object.renderOrder].join('/');if(!groups.has(key))groups.set(key,[]);groups.get(key).push(object);selected.push(object);}
 if(deep)parent.traverse(collect);else parent.children.forEach(collect);
 for(const objects of groups.values()){
  if(objects.length<2)continue;
  const positions=[],normals=[],uvs=[],point=new THREE.Vector3(),normal=new THREE.Vector3();
  for(const object of objects){
   const matrix=inverse.clone().multiply(object.matrixWorld),normalMatrix=new THREE.Matrix3().getNormalMatrix(matrix),source=object.geometry.index?object.geometry.toNonIndexed():object.geometry;
   const p=source.attributes.position,n=source.attributes.normal,uv=source.attributes.uv;
   for(let i=0;i<p.count;i++){point.fromBufferAttribute(p,i).applyMatrix4(matrix);normal.fromBufferAttribute(n,i).applyMatrix3(normalMatrix).normalize();positions.push(point.x,point.y,point.z);normals.push(normal.x,normal.y,normal.z);uvs.push(uv?uv.getX(i):0,uv?uv.getY(i):0);}
   if(source!==object.geometry)source.dispose();
  }
  const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setAttribute('normal',new THREE.Float32BufferAttribute(normals,3));geometry.setAttribute('uv',new THREE.Float32BufferAttribute(uvs,2));
  const first=objects[0],combined=mesh(geometry,first.material,0,0,0,parent);combined.castShadow=first.castShadow;combined.receiveShadow=first.receiveShadow;combined.renderOrder=first.renderOrder;
  for(const object of objects)object.removeFromParent();
 }
}
function plant(x,z,height,purple=false,seed=1){
 if(z<0)z+=(backBound+2.6)*Math.min(1,-z/2.4);
 const g=new THREE.Group();g.position.set(x,bedLevel+.04,z);g.userData.substratePlant=true;world.add(g);const rnd=makeRandom(seed);
 if(!M.leaf.map){
  const pixels=new Uint8Array(32*16*4),textureRandom=makeRandom(76413),palette=[[234,240,218],[226,233,209],[243,245,226],[218,228,201]];
  for(let by=0;by<16;by+=2)for(let bx=0;bx<32;bx+=4){
   const choice=textureRandom(),shade=palette[choice<.58?0:choice<.77?1:choice<.94?2:3];
   for(let yy=by;yy<by+2;yy++)for(let xx=bx;xx<bx+4;xx++){const i=(yy*32+xx)*4;pixels.set([...shade,255],i);}
  }
  const map=new THREE.DataTexture(pixels,32,16,THREE.RGBAFormat);map.colorSpace=THREE.SRGBColorSpace;map.magFilter=map.minFilter=THREE.NearestFilter;map.generateMipmaps=false;map.needsUpdate=true;maps.push(map);
  M.stem.color.setHex(0x789051);M.leaf.color.setHex(0x7e9c58);M.leafLight.color.setHex(0xa1b970);
  for(const mat of [M.leaf,M.leafLight]){mat.map=map;mat.needsUpdate=true;}
 }
 const growth=Math.min(1,height/2.8),spread=.09+.15*growth;
 function leafGeometry(length,width,lift,twist){
  const positions=[0,0,0],uvs=[0,.5],indices=[],rows=[[.08,.20],[.22,.53],[.42,.85],[.64,1],[.82,.87],[.94,.48]],sides=10;
  for(const [u,fullness] of rows)for(let side=0;side<sides;side++){
   const angle=side/sides*Math.PI*2,lateral=Math.cos(angle),profile=Math.sin(Math.PI*u);
   positions.push(length*u,length*(lift*u+.075*profile)+width*(.16*lateral*lateral*profile+twist*lateral*u)+length*.022*Math.sin(angle)*profile,width*.5*fullness*lateral);
   uvs.push(u,.5+fullness*lateral*.5);
  }
  const tip=positions.length/3;positions.push(length,length*lift,0);uvs.push(1,.5);
  for(let side=0;side<sides;side++){
   const next=(side+1)%sides;indices.push(0,1+side,1+next);
   for(let row=0;row<rows.length-1;row++){
    const a=1+row*sides+side,b=1+(row+1)*sides+side,c=1+(row+1)*sides+next,d=1+row*sides+next;indices.push(a,b,c,a,c,d);
   }
   const last=1+(rows.length-1)*sides;indices.push(last+side,tip,last+next);
  }
  const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setAttribute('uv',new THREE.Float32BufferAttribute(uvs,2));geometry.setIndex(indices);geometry.computeVertexNormals();return geometry;
 }
 for(let stem=0;stem<3;stem++){
  const sx=(stem-1)*spread,sz=(stem===1?.13:-.06)*growth,h=height*(stem===1?.94:.73+rnd()*.18),leanX=(rnd()-.5)*(.12+.28*growth),leanZ=(rnd()-.5)*.20*growth,sway=(rnd()-.5)*.08*growth;
  const point=t=>[sx+leanX*t*t+sway*Math.sin(Math.PI*t),h*t,sz+leanZ*t+.035*growth*Math.sin(Math.PI*t)];
  const nodes=Math.max(3,Math.min(10,Math.round(h/.39))),azimuth=rnd()*Math.PI,radius=.009+.008*growth;
  let previous=point(0),previousT=0;
  for(let node=0;node<nodes;node++){
   const t=.10+.78*node/(nodes-1),p=point(t),young=node>=nodes-2;
   cylinder(previous,p,radius*(1-.5*previousT),radius*(1-.5*t),M.stem,g,6);previous=p;previousT=t;
   const angle=azimuth+node*Math.PI*.5+(rnd()-.5)*.16,length=(.18+.25*growth)*(.88+rnd()*.18)*(node===nodes-1?.64:node===0?.76:1),lift=(young?.42:.16)+rnd()*.24;
   for(let side=0;side<2;side++){
    const l=Math.min(metric.toWorld(1.5),length*(.94+rnd()*.12)),width=metric.toWorld(.3+.2*rnd())*(.65+.35*growth),leaf=mesh(leafGeometry(l,width,lift+(rnd()-.5)*.12,(rnd()-.5)*.16),young?M.leafLight:M.leaf,...p,g);
    leaf.rotation.set((rnd()-.5)*.65,angle+side*Math.PI,0,'YXZ');
   }
  }
  const tip=point(1);cylinder(previous,tip,radius*(1-.5*previousT),radius*.34,M.stem,g,6);
  const bud=point(.965),budLength=Math.min((.18+.25*growth)*.38,h*.13);
  for(let side=0;side<2;side++){const leaf=mesh(leafGeometry(budLength,budLength*.49,.85,.025),M.leafLight,...bud,g);leaf.rotation.y=azimuth+nodes*Math.PI*.5+side*Math.PI;}
 }
 const bounds=new THREE.Box3().setFromObject(g),dx=Math.max(-innerHalf+.05-bounds.min.x,Math.min(0,innerHalf-.05-bounds.max.x)),dz=Math.max(backBound+.05-bounds.min.z,Math.min(0,frontBound-.05-bounds.max.z));
 if(dx||dz)for(const part of g.children){part.position.x+=dx;part.position.z+=dz;}
 batchStatic(g);plants.push({g,phase:seed});return g;
}
function spriteFrames(kind,color='red',stage='adult',pane='floor'){
 const create=phase=>{
  if(assets.cleaners==='contact'&&(kind==='otocinclus'||kind==='snail')){
   const art=(kind==='otocinclus'||color==='nerite'||pane!=='floor'?AquariumCleanerPaneArt:AquariumCleanerPosesV2).createSprite(kind==='otocinclus'?'otocinclus':color,phase,'daylight','natural',{pane:pane==='floor'?'front':pane});art.metrics=AquariumCleanerScaleAdapter.metrics(art);return art;
  }
  if(kind==='shrimp'&&AquariumPatternShrimpV2.variants.includes(color))return AquariumPatternShrimpV2.createSprite('shrimp',phase,'daylight',color,{stage});
  if(kind==='fish'&&AquariumFancyFishV2.descriptors[color])return AquariumFancyFishV2.createSprite(color.split('-')[0],phase,'daylight',color,{stage});
  if(kind==='shrimp'&&(stage!=='adult'||AquariumShrimpVarieties.variants.includes(color)))return AquariumShrimpVarieties.createSprite('shrimp',phase,'daylight',color,{stage});
  if(kind==='fish'&&color!=='chili'&&color!=='red')return AquariumFishVarieties.createSprite(color.split('-')[0],phase,'daylight',color.split('-')[1],{stage});
  if(kind==='snail')return AquariumSnailArt.createSprite(phase,'daylight',color);
  return AquariumAnimalArt.createSprite(kind,phase,'daylight',color);
 };
 const first=create(0);
 return Array.from({length:first.frameCount||2},(_,phase)=>{const art=phase?create(phase):first;const tex=new THREE.CanvasTexture(art.canvas);tex.colorSpace=THREE.SRGBColorSpace;tex.minFilter=tex.magFilter=THREE.NearestFilter;tex.generateMipmaps=false;tex.userData.shrimpColor=color;if(art.pose)tex.userData.cleanerPose=art.pose;maps.push(tex);return{...art,tex};});
}
let renderedFrames=0;
let animalFrames={},foodJar=null,pellets=[],feedStarted=-100,feedSequence=0,automaticFeedCount=0,manualFeedCount=0,lastFeedReason=null,nextFeedDue=24;
function animalPlane(art){
 const geometry=new THREE.PlaneGeometry(art.canvas.width,art.canvas.height);
 geometry.translate(art.canvas.width/2-art.anchorX,art.anchorY-art.canvas.height/2,0);return geometry;
}
function animalOffset(a,key){
 const p=a.metric.offsets[key];if(!p)return new THREE.Vector3();
 return new THREE.Vector3(p.x*Math.sign(a.o.scale.x),p.y,p.z).applyQuaternion(a.o.quaternion);
}
function animalPoint(a,key){return a.o.position.clone().add(animalOffset(a,key));}
function animalWasteSource(a){
 const vent=animalPoint(a,'vent');
 // The legacy waste helper adds .025 Z; its scale offsets are already in the calibrated vent.
 return{position:{x:vent.x,y:vent.y,z:vent.z-.025},kind:a.kind,scale:0,facing:1};
}
function animalSurfaceContact(a,from,to){
 const centerOffset=animalOffset(a,'bodyCenter').sub(animalOffset(a,'foot'));
 if(a.surfaceMotion.surface!=='glass')centerOffset.y-=.12;
 const radius=a.metric.movementCollisionRadius,span=Math.max(0,a.metric.collision.halfLength-radius);
 const axis=new THREE.Vector3(a.metric.collision.longAxis==='x'?Math.sign(a.o.scale.x):0,a.metric.collision.longAxis==='y'?1:0,0).applyQuaternion(a.o.quaternion);
 for(const amount of span?[-span,0,span]:[0]){
  const shift=centerOffset.clone().addScaledVector(axis,amount),hit=collisionWorld.moveSphere(from.clone().add(shift),to.clone().add(shift),radius);
  if(hit.collided&&hit.kind==='solid')return{...hit,position:from.clone()};
 }
 return{position:to.clone(),collided:false};
}
const glassBounds={halfWidth:innerHalf,backZ:backBound,frontZ:frontBound,bedLevel,waterLevel,glassInset:.005};
function glassBoundsFor(a){
 if(!a.metric)return glassBounds;const m=a.metric.pixelMetrics,p=a.metric.pixelToWorld,anchor=m.anchor;
 const pad=a.glassPaddingRatio?a.glassPaddingRatio*a.metric.lengthWorld+.005:Math.max(.15,...[[0,0],[m.canvas.width,0],[0,m.canvas.height],[m.canvas.width,m.canvas.height]].map(([x,y])=>Math.hypot(x-anchor[0],y-anchor[1])*p))+.005;
 return{...glassBounds,bedLevel:bedLevel+pad-.15,waterLevel:waterLevel-pad+.12};
}
function orientGlassAnimal(a,elapsed=0){
 const frame=AquariumSurfaceMotion.projectGlass(THREE,a.surfaceMotion.position,glassBoundsFor(a),a.surfaceMotion.pane);
 const h=a.surfaceMotion.glassHeading;
 if(a.glassDirectionAngle===undefined)a.glassDirectionAngle=Math.PI/2;
 if(h&&Math.hypot(h.along,h.up)>1e-8&&elapsed>0){const desired=Math.atan2(h.up,h.along),delta=Math.atan2(Math.sin(desired-a.glassDirectionAngle),Math.cos(desired-a.glassDirectionAngle));a.glassDirectionAngle+=THREE.MathUtils.clamp(delta,-elapsed*1.6,elapsed*1.6);}
 const out=frame.normal.clone().negate(),up=new THREE.Vector3(0,1,0),right=up.clone().cross(out),basis=new THREE.Matrix4().makeBasis(right,up,out);
 const axis=a.frames[0].bodyReferenceAxis?.axis||(a.life.species==='otocinclus'?'y':'x');
 a.o.quaternion.setFromRotationMatrix(basis);a.o.rotateZ(a.glassDirectionAngle-(axis==='y'?Math.PI/2:0));a.o.scale.setScalar(a.scale);
}
function setGlassPose(a,pane){
 if(a.o.userData.glassPane===pane&&a.glassArt===assets.cleaners)return;
 a.o.userData.glassPane=pane;a.glassArt=assets.cleaners;
 if(assets.cleaners==='contact'&&['otocinclus','assassin','nerite'].includes(a.life.species)){
  for(const face of ['front','left','right','back']){const faceKey='pane:'+a.life.species+':'+face;if(!stageFrameCache.has(faceKey))stageFrameCache.set(faceKey,spriteFrames(a.life.species==='otocinclus'?'otocinclus':'snail',a.life.species,'adult',face));}
  if(!a.glassPaddingRatio)a.glassPaddingRatio=Math.max(...['front','left','right','back'].map(face=>{const art=stageFrameCache.get('pane:'+a.life.species+':'+face)[0],m=art.metrics;return Math.max(...[[0,0],[m.canvas.width,0],[0,m.canvas.height],[m.canvas.width,m.canvas.height]].map(([x,y])=>Math.hypot(x-m.anchor[0],y-m.anchor[1])/m.measurement.pixels));}));
  const key='pane:'+a.life.species+':'+pane;
  const frames=stageFrameCache.get(key),geometry=animalPlane(frames[0]),previous=a.o.geometry;geometries.push(geometry);a.ownedGeometries.add(geometry);a.o.geometry=geometry;a.frames=frames;a.material.map=frames[0].tex;a.ownedGeometries.delete(previous);geometries=geometries.filter(g=>g!==previous);previous.dispose();updateAnimalMetric(a);
 }
}
function setGlassPane(id,pane){
 if(!['front','left','right','back'].includes(pane))return false;
 const a=[...fish,...shrimps,...snails].find(a=>a.life.id===id);if(!a||!a.life.alive||a.kind==='fish'&&a.life.species!=='otocinclus')return false;
 a.surfaceMotion.surface='glass';a.surfaceMotion.pane=pane;a.surfaceMotion.glassHeading={along:0,up:0};a.surfaceMotion.glassTarget=null;const frame=AquariumSurfaceMotion.projectGlass(THREE,a.surfaceMotion.position,glassBoundsFor(a),pane);a.surfaceMotion.position.copy(frame.position);a.surfaceMotion.glassPerimeter=frame.perimeter;a.surfaceMotion.target=null;a.life.surface='glass';setGlassPose(a,pane);orientGlassAnimal(a);placeAnimal(a);render();return true;
}
function placeAnimal(a){
 if(a.motion)a.o.position.copy(a.motion.position).sub(animalOffset(a,'bodyCenter'));
 else if(a.surfaceMotion){
  const p=a.surfaceMotion.position.clone();
  if(a.surfaceMotion.surface==='glass'){const frame=AquariumSurfaceMotion.projectGlass(THREE,p,glassBoundsFor(a),a.surfaceMotion.pane);p.copy(frame.position);a.surfaceMotion.position.copy(p);orientGlassAnimal(a);}
  else p.y-=.12;
  a.o.position.copy(p).sub(animalOffset(a,'foot'));
 }
 if(a.contact){const foot=animalPoint(a,'foot');a.contact.position.set(foot.x,bedLevel+.008,foot.z);a.contact.visible=a.life.alive&&Math.abs(foot.y-bedLevel)<.08;a.contact.scale.set(a.metric.worldBodyDimensions.width*.6,a.metric.worldBodyDimensions.height*.25,1);}
}
function updateAnimalMetric(a,growthAgeDays=a.growthAgeDays){
 const species=a.life.species==='bee'?'caridina-bee':a.life.species;
 a.growthAgeDays=AquariumAnimalScale.profiles[species==='cherry'?'neocaridina':species].birthCm===null?undefined:growthAgeDays;
 a.metric=AquariumAnimalScale.calibrate({species,stage:a.stage,sex:a.life.sex,id:a.life.id,seed:8401,growthAgeDays:a.growthAgeDays,metrics:a.frames[0].metrics||a.frames[0].anatomy});
 a.scale=a.metric.pixelToWorld;const facing=Math.sign(a.o.scale.x)||a.facing;a.o.scale.set(a.scale*facing,a.scale,a.scale);
 a.o.userData.anatomy={lengthCm:a.metric.lengthCm,adultLengthCm:a.metric.adultLengthCm,pixelToWorld:a.scale,measurement:a.metric.measurement.basis};
 if(a.motion){a.motion.radius=a.metric.collision.enclosingRadius;a.motion.speed=a.adultSpeed*Math.max(.3,a.metric.growth.relativeLength);}
 if(a.surfaceMotion)a.surfaceMotion.radius=a.metric.movementCollisionRadius;
 placeAnimal(a);
}
function animal(kind,x,y,z,_legacyScale=1,phase=0,facing=1,species='assassin',options={}){
 const fishChoice=options.fish||assets.fish,color=options.color??(kind==='shrimp'?(assets.shrimp==='skittles'?['red','yellow','blue','orange'][phase%4]:assets.shrimp):null),grazer=species==='otocinclus';
 const selectedSpecies=grazer?'otocinclus':kind==='fish'?fishChoice.split('-')[0]:kind==='shrimp'?(color==='amano'?'amano':color==='crystal-black'||AquariumPatternShrimpV2.descriptors[color]?.biologicalGroup==='caridina-bee'?'bee':'cherry'):species;
 const life=ecology.addAnimal({id:options.id||((grazer?'otocinclus':kind)+'-'+phase),kind,species:selectedSpecies,surface:grazer||species==='nerite'?'glass':kind==='fish'?'free':'floor',position:{x,y,z}});
 life.position={x,y,z};life.species=selectedSpecies;life.variant=kind==='fish'?fishChoice:color;life.sex=options.sex||life.sex||(Math.round(phase*101)%2?'male':'female');life.maturity=options.maturity??life.maturity??1;life.isOffspring=options.isOffspring??!!options.id;
 const stage=selectedSpecies==='guppy'&&life.sex==='female'&&(!options.stage||options.stage==='adult')?'female':options.stage||'adult';
 const frames=grazer?animalFrames.otocinclus:kind==='snail'?(species==='nerite'?animalFrames.nerite:animalFrames.snail):cachedStageFrames(kind,kind==='shrimp'?color:fishChoice,stage);
 const art=frames[0],geometry=animalPlane(art),m=rememberMaterial(new THREE.MeshBasicMaterial({map:art.tex,alphaTest:kind==='snail'?.5:.02,transparent:kind!=='snail',depthWrite:kind==='snail'||kind==='fish',side:THREE.DoubleSide}));
 const o=mesh(geometry,m,x,y,z);o.scale.x=facing;o.quaternion.copy(camera.quaternion);o.userData.animalKind=kind;o.userData.species=selectedSpecies;o.userData.animalId=life.id;if(kind!=='fish'||grazer)o.userData.surfaceCapabilities=['front','left','right','back'];if(color)o.userData.shrimpColor=color;
 const entry={o,x,y,z,phase,facing,material:m,kind,frames,life,ownedGeometries:new Set([geometry]),color,fishChoice,stage,growthAgeDays:options.growthAgeDays,adultSpeed:0,seenMolt:life.moltCount||0,moltStarted:-Infinity};
 updateAnimalMetric(entry);
 if(kind!=='fish'||grazer){entry.surfaceMotion=AquariumSurfaceMotion.create(THREE,new THREE.Vector3(x,y,z),8401+Math.round(phase*101),grazer?'otocinclus':kind,grazer||species==='nerite'?'glass':'floor');entry.surfaceMotion.facing=facing;entry.surfaceMotion.radius=entry.metric.movementCollisionRadius;}
 if(grazer)entry.heading=0;
 if(entry.surfaceMotion?.surface==='glass'){const pane=options.glassPane||(grazer?['front','left','back'][Math.round(phase)%3]:'right'),frame=AquariumSurfaceMotion.projectGlass(THREE,entry.surfaceMotion.position,glassBoundsFor(entry),pane);entry.surfaceMotion.pane=pane;entry.surfaceMotion.position.copy(frame.position);entry.surfaceMotion.glassPerimeter=frame.perimeter;setGlassPose(entry,pane);orientGlassAnimal(entry);}
 if(kind==='fish'&&!grazer){entry.motion=AquariumFishMotion.createAgent(THREE,animalPoint(entry,'bodyCenter'),8401+Math.round(phase*101),clock);entry.motion.facing=facing;entry.adultSpeed=entry.motion.speed;entry.motion.radius=entry.metric.collision.enclosingRadius;entry.motion.speed=entry.adultSpeed*Math.max(.3,entry.metric.growth.relativeLength);}
 if(kind==='shrimp'){entry.contact=contact(x,z,1,1,.19);shrimps.push(entry);}else if(kind==='snail'){if(species!=='nerite')entry.contact=contact(x,z,1,1,.15);snails.push(entry);}else fish.push(entry);
 placeAnimal(entry);const mouth=animalPoint(entry,'mouth');life.position={x:mouth.x,y:mouth.y,z:mouth.z};return entry;
}
function clearWorld(retireFood=true){releaseEquipment();clearDesignerPlacement();presetAssemblies=null;botanicalArt=null;physicalParts=[];breedingSupports=[];stageFrameCache=new Map();manzanitaArt=null;variedPlants=[];surfaceStudy=null;lushPlants=null;premiumEquipment=null;hangOnFilter=null;carpetArt=null;mossFormation=null;surfaceNavigation=null;navigationSites=[];leafContacts=new Map();flowField=null;chromeFinish=null;co2Mist=[];nextReturnRipple=clock;if(roomArt){roomArt.group.removeFromParent();for(const resource of [...roomArt.geometries,...roomArt.materials,...roomArt.maps])resource.dispose();roomArt=null;}if(retireFood)for(const p of pellets)ecology.retireFood(p.food.id);ecologyVisuals=null;world.traverse(object=>{if(object.isInstancedMesh)object.dispose();});world.clear();for(const g of new Set(geometries))g.dispose();for(const m of new Set(mats))m.dispose();for(const m of new Set(maps))m.dispose();geometries=[];mats=[];maps=[];fish=[];shrimps=[];snails=[];bubbles=[];plants=[];lightPools=[];lampEmitters=[];pellets=[];foodJar=null;sideWater=[];waterCondition=null;collisionWorld=null;lastSimulation=clock;pelletMaterial=null;pelletGeometry=null;random=makeRandom(8401);}
function makeBackdrop(){
 const geometry=new THREE.PlaneGeometry(tankHalf*2,waterLevel,24,16);
 const count=geometry.attributes.position.count;
 geometry.setAttribute('color',new THREE.BufferAttribute(new Float32Array(count*3),3));
 const waterMaterial=rememberMaterial(new THREE.MeshBasicMaterial({vertexColors:true,side:THREE.DoubleSide,transparent:true,opacity:.24+.28*conditionLevel,depthWrite:false}));
 backdrop=mesh(geometry,waterMaterial,0,waterLevel/2,backBound);backdrop.name='water-rear-depth';
 for(const sign of [-1,1]){const side=geometry.clone();side.scale(innerDepth/(tankHalf*2),1,1);const wall=mesh(side,waterMaterial,sign*innerHalf,waterLevel/2,centerZ);wall.rotation.y=Math.PI/2;wall.name=sign<0?'water-left-depth':'water-right-depth';sideWater.push(wall);}
}
function updateWaterTransmission(){if(backdrop)backdrop.material.opacity=.24+.28*conditionLevel;}
function backdropColors(topHex,bottomHex){
 if(!backdrop)return;
 const topColor=new THREE.Color(topHex),bottomColor=new THREE.Color(bottomHex),color=new THREE.Color(),neutral=new THREE.Color();
 for(const endpoint of [topColor,bottomColor]){const luminance=endpoint.r*.2126+endpoint.g*.7152+endpoint.b*.0722;neutral.setRGB(luminance,luminance,luminance);endpoint.lerp(neutral,.62).multiplyScalar(.88);}
 for(const wall of [backdrop,...sideWater]){const positions=wall.geometry.attributes.position,colors=wall.geometry.attributes.color;
 for(let i=0;i<positions.count;i++){
  const height=Math.max(0,Math.min(1,(positions.getY(i)+waterLevel/2)/waterLevel)),depth=wall===backdrop?0:(innerDepth/2-positions.getX(i))/innerDepth;
  const across=wall===backdrop?positions.getX(i)/tankHalf:Math.sign(wall.position.x),lightFalloff=.92+.08*Math.max(0,1-Math.abs(across+.24));
  const fraction=height*height*(3-2*height);color.copy(bottomColor).lerp(topColor,fraction).multiplyScalar(lightFalloff*(1+depth*.035));colors.setXYZ(i,color.r,color.g,color.b);
 }
 colors.needsUpdate=true;}
 if(waterSurface)waterSurface.material.color.setHex(preset==='warm'?0xc4bc9e:preset==='moonlight'?0x8195b2:0xb4c3b8);
}
function makeWaveBreakCluster(x,y,z){
 const group=new THREE.Group();group.name='concrete-wave-breaks';group.userData.solid=true;world.add(group);
 const concrete=material(0xb1b1a1,pixelMap(['#9a9c8d','#b2b3a1','#7c8275','#c5c4af'],'concrete',543));
 const directions=[[0,1,0],[Math.sqrt(8/9),-1/3,0],[-Math.sqrt(2/9),-1/3,Math.sqrt(2/3)],[-Math.sqrt(2/9),-1/3,-Math.sqrt(2/3)]];
 for(const [index,[dx,dz,size,yaw,lean]]of [[-.78,-.32,1.08,.15,0],[.77,.26,.81,1.9,.25],[-.55,1.25,.66,.8,-.3]].entries()){
  const block=new THREE.Group();block.name='tetrapod-'+index;block.userData.waveBlock=true;block.rotation.set(lean,yaw,0);block.scale.setScalar(size);group.add(block);
  mesh(new THREE.IcosahedronGeometry(.43,1),concrete,0,0,0,block);
  for(const values of directions){
   const direction=new THREE.Vector3(...values),arm=mesh(new THREE.CylinderGeometry(.22,.38,1.05,8,1),concrete,direction.x*.49,direction.y*.49,direction.z*.49,block);arm.quaternion.setFromUnitVectors(new THREE.Vector3(0,1,0),direction);arm.userData.waveArm=true;
  }
  block.position.set(x+dx,0,z+dz);block.updateMatrixWorld(true);const bounds=new THREE.Box3().setFromObject(block);block.position.y=y-bounds.min.y;
 }
 return group;
}

function makeFoodJar(){
 const g=new THREE.Group();g.position.set(-visibleWidth*.29,9.575,centerZ);g.name="shrimp-food-jar";g.scale.setScalar(metric.toWorld(5)/.94);g.userData.physical={widthCm:5,definition:"authored jar envelope; package dimensions unverified"};world.add(g);
 const body=material(0x151817),cap=material(0x202322),grip=material(0x3c413d);
 cylinder([0,.0175,0],[0,.065,0],.4,.43,body,g,16);
 cylinder([0,.06,0],[0,.56,0],.43,.43,body,g,16);
 cylinder([0,.55,0],[0,.605,0],.43,.412,body,g,16);
 cylinder([0,.59,0],[0,.625,0],.47,.47,cap,g,16);
 cylinder([0,.615,0],[0,.75,0],.46,.46,cap,g,16);
 cylinder([0,.74,0],[0,.78,0],.47,.435,cap,g,16);
 cylinder([0,.778,0],[0,.784,0],.385,.385,body,g,16);
 for(let i=0;i<24;i++){
  const angle=i*Math.PI*2/24,rib=box(.026,.12,.035,grip,Math.sin(angle)*.465,.68,Math.cos(angle)*.465,g);rib.rotation.y=angle;
 }
 const c=document.createElement('canvas');c.width=64;c.height=32;const ctx=c.getContext('2d');ctx.fillStyle='#151817';ctx.fillRect(0,0,64,32);
 ctx.fillStyle='#2b302a';for(const [x,y,w] of [[3,2,8],[52,2,7],[2,28,4],[57,28,5],[14,30,15],[34,30,8]])ctx.fillRect(x,y,w,1);
 const letters={S:['111','100','111','001','111'],H:['101','101','111','101','101'],R:['110','101','110','101','101'],I:['111','010','010','010','111'],M:['101','111','111','101','101'],P:['110','101','110','100','100'],F:['111','100','110','100','100'],O:['111','101','101','101','111'],D:['110','101','101','101','110']};
 for(const [word,y,color] of [['SHRIMP',3,'#f18a36'],['FOOD',17,'#ebe5c8']]){
  ctx.fillStyle=color;[...word].forEach((letter,i)=>letters[letter].forEach((row,yy)=>[...row].forEach((v,x)=>{if(v==='1')ctx.fillRect(9+i*8+x*2,y+yy*2,2,2);})));
 }
 ctx.fillStyle='#6b993c';ctx.fillRect(48,17,8,12);ctx.fillRect(46,19,12,8);ctx.fillStyle='#c1d680';ctx.fillRect(49,18,6,1);ctx.fillRect(47,20,1,6);
 ctx.fillStyle='#ebe5c8';ctx.fillRect(49,21,6,2);ctx.fillRect(50,24,4,1);
 const map=new THREE.CanvasTexture(c);map.colorSpace=THREE.SRGBColorSpace;map.magFilter=map.minFilter=THREE.NearestFilter;map.generateMipmaps=false;maps.push(map);
 mesh(new THREE.CylinderGeometry(.435,.435,.44,6,1,true,-Math.PI*3/8,Math.PI*3/4),material(0xffffff,map),0,.315,0,g);
 batchStatic(g);g.updateWorldMatrix(true,true);const jarSize=new THREE.Box3().setFromObject(g).getSize(new THREE.Vector3());g.scale.multiplyScalar(metric.toWorld(5)/jarSize.x);g.visible=true;return g;
}
function makeThermometer(x,y,z,parent=world){
 const g=new THREE.Group();g.name='aquarium-thermometer';g.position.set(x,y,z);parent.add(g);
 const pale=material(0xd8d7bd),liquid=material(0xa73628),weight=material(0x626a60),rubber=material(0x75817a);
 const glass=material(0xadc7bc);glass.transparent=true;glass.opacity=.25;glass.depthWrite=false;

 // The sealed tube is 2.04 high and .14 wide, with a small weighted foot.
 const outline=[[0,0],[.035,.012],[.059,.045],[.070,.105],[.070,1.95],[.062,2.005],[.035,2.035],[0,2.04]];
 const shell=mesh(new THREE.LatheGeometry(outline.map(p=>new THREE.Vector2(...p)),8),glass,0,0,0,g);
 shell.castShadow=false;shell.receiveShadow=false;
 cylinder([0,.052,0],[0,.24,0],.045,.051,weight,g,8);
 cylinder([0,.235,0],[0,.263,0],.051,.040,weight,g,8);

 // The paper insert has thickness; its front stays behind the red capillary.
 box(.096,1.24,.014,pale,0,1.05,-.004,g);
 const c=document.createElement('canvas');c.width=16;c.height=128;
 const ink=c.getContext('2d');ink.fillStyle='#dfddc1';ink.fillRect(0,0,16,128);
 ink.fillStyle='#94a772';ink.fillRect(0,42,16,20);
 ink.fillStyle='#505c51';
 for(let i=0;i<13;i++){
  const yy=16+i*8,w=i%2?3:5;
  ink.fillRect(1,yy,w,2);ink.fillRect(15-w,yy,w,2);
 }
 ink.fillRect(2,5,2,3);ink.fillRect(12,5,2,3);
 const scaleMap=new THREE.CanvasTexture(c);scaleMap.colorSpace=THREE.SRGBColorSpace;
 scaleMap.minFilter=scaleMap.magFilter=THREE.NearestFilter;scaleMap.generateMipmaps=false;maps.push(scaleMap);
 mesh(new THREE.PlaneGeometry(.095,1.24),material(0xffffff,scaleMap),0,1.05,.004,g);

 const bulb=mesh(new THREE.SphereGeometry(.034,8,6),liquid,0,.312,.024,g);bulb.scale.set(.88,1.75,.88);
 cylinder([0,.312,.024],[0,1.205,.024],.011,.011,liquid,g,6);

 // Local +Z points to the front pane. The cup's open lip meets z + .25.
 const mountY=1.80;
 const clip=mesh(new THREE.TorusGeometry(.077,.012,4,12,Math.PI*1.6),rubber,0,mountY,0,g);clip.rotation.x=Math.PI/2;
 cylinder([0,mountY,.064],[0,mountY,.154],.034,.035,rubber,g,8);
 const cupProfile=[[.033,.106],[.049,.127],[.090,.176],[.139,.224],[.150,.235],[.148,.250],[.128,.250],[.117,.229],[.075,.182],[.033,.153]];
 const cup=mesh(new THREE.LatheGeometry(cupProfile.map(p=>new THREE.Vector2(...p)),12),rubber,0,mountY,0,g);
 cup.rotation.x=Math.PI/2;
 rubber.side=THREE.DoubleSide;

 batchStatic(g,true,new Set([shell]));
 return g;
}

function makeSkullCastle(x,y,z,parent=world){
 const g=new THREE.Group();g.name='skull-castle';g.userData.solid=true;g.position.set(x,y,z);parent.add(g);
 function surfaceMap(stone){
  const canvas=document.createElement('canvas');canvas.width=canvas.height=64;const ctx=canvas.getContext('2d');
  let seed=stone?1937:5279;const rnd=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;};
  const colors=stone?['#777970','#83857a','#6d7169','#919184','#626960']:['#b7b3a0','#c2beaa','#aaa895','#cbc5b0','#9b9f8b'];
  ctx.fillStyle=colors[0];ctx.fillRect(0,0,64,64);
  for(let i=0;i<150;i++){ctx.fillStyle=colors[1+Math.floor(rnd()*4)];ctx.fillRect(Math.floor(rnd()*32)*2,Math.floor(rnd()*32)*2,2+Math.floor(rnd()*3),1+Math.floor(rnd()*2));}
  if(stone){
   ctx.fillStyle='#555e55';
   for(let row=0;row<4;row++){const yy=row*16;ctx.fillRect(0,yy,64,1);for(let col=0;col<4;col++)ctx.fillRect((col*16+(row%2)*8)%64,yy,1,16);}
   ctx.fillStyle='#969689';for(let row=0;row<4;row++)ctx.fillRect(0,row*16+1,64,1);
  }else{
   ctx.fillStyle='#8d9481';for(const [xx,yy] of [[9,13],[37,29],[23,50]]){ctx.fillRect(xx,yy,1,4);ctx.fillRect(xx+1,yy+3,2,1);}
  }
  const map=new THREE.CanvasTexture(canvas);map.colorSpace=THREE.SRGBColorSpace;map.minFilter=map.magFilter=THREE.NearestFilter;
  map.wrapS=map.wrapT=THREE.RepeatWrapping;map.generateMipmaps=false;maps.push(map);return map;
 }
 const boneMap=surfaceMap(false),stoneMap=surfaceMap(true);
 const bone=material(0xffffff,boneMap),tooth=material(0xd6d0b7,boneMap),stone=material(0xffffff,stoneMap),edge=material(0x969b89,stoneMap),moss=material(0x566348),mossTip=material(0x768065);
 function outline(points){const shape=new THREE.Shape();points.forEach(([xx,yy],i)=>i?shape.lineTo(xx,yy):shape.moveTo(xx,yy));shape.closePath();return shape;}
 function cutout(shape,points){const hole=new THREE.Path();points.forEach(([xx,yy],i)=>i?hole.lineTo(xx,yy):hole.moveTo(xx,yy));hole.closePath();shape.holes.push(hole);}
 function relief(shape,depth,mat,xx,yy,zz,bevel=.025){
  const geometry=new THREE.ExtrudeGeometry(shape,{depth,steps:1,bevelEnabled:bevel>0,bevelSize:bevel,bevelThickness:bevel,bevelSegments:1,curveSegments:1});
  const uv=geometry.attributes.uv,p=geometry.attributes.position;
  for(let i=0;i<uv.count;i++)uv.setXY(i,p.getX(i)*.72,p.getY(i)*.72+p.getZ(i)*.25);
  return mesh(geometry,mat,xx,yy,zz,g);
 }
 function towerShell(cx,cz,low,high,radius,mat){
  const profile=[[radius+.03,low],[radius,low+.07],[radius-.035,high-.07],[radius-.01,high],[radius-.12,high],[radius-.14,low]];
  const geometry=new THREE.LatheGeometry(profile.map(p=>new THREE.Vector2(...p)),10),uv=geometry.attributes.uv,p=geometry.attributes.position;
  for(let i=0;i<uv.count;i++)uv.setY(i,p.getY(i)/1.08);
  return mesh(geometry,mat,cx,0,cz,g);
 }
 function band(cx,cz,height,radius){
  const profile=[[radius-.035,height-.04],[radius+.025,height-.04],[radius+.04,height],[radius+.015,height+.055],[radius-.035,height+.055]];
  return mesh(new THREE.LatheGeometry(profile.map(p=>new THREE.Vector2(...p)),10),edge,cx,0,cz,g);
 }
 function crown(cx,cz,height,radius,missing){
  band(cx,cz,height,radius);
  for(let i=0;i<7;i++){
   if(i===missing)continue;const angle=i*Math.PI*2/7,broken=i===(missing+1)%7,h=broken?.12:.26;
   const block=box(.235,h,.19,edge,cx+Math.sin(angle)*(radius-.025),height+.035+h/2,cz+Math.cos(angle)*(radius-.025),g);block.rotation.y=angle;
  }
 }

 // A low, irregular molded foot seats the whole ornament into the gravel.
 const foot=relief(outline([[-1.79,-.58],[-1.54,-.86],[-.69,-.89],[.19,-.80],[1.45,-.77],[1.80,-.42],[1.83,.31],[1.58,.75],[.66,.88],[-.55,.85],[-1.56,.70],[-1.84,.19]]),.12,stone,0,.12,0,.018);
 foot.rotation.x=Math.PI/2;

 // The skull is a thick sculpted gate. Every opening passes through the casting.
 const face=outline([[-.66,.14],[-.89,.29],[-.91,.62],[-1.08,.93],[-1.09,1.32],[-.98,1.53],[-1.01,1.88],[-.84,2.14],[-.53,2.28],[-.12,2.32],[.39,2.30],[.77,2.16],[.99,1.93],[1.02,1.60],[1.12,1.34],[1.07,1.01],[.89,.65],[.87,.31],[.63,.15]]);
 cutout(face,[[-.57,.27],[.57,.27],[.60,.51],[.55,.84],[.38,1.02],[0,1.08],[-.35,1.03],[-.55,.85],[-.61,.52]]);
 cutout(face,[[-.83,1.49],[-.68,1.39],[-.39,1.42],[-.20,1.64],[-.25,1.87],[-.57,1.91],[-.83,1.78]]);
 cutout(face,[[.20,1.66],[.37,1.44],[.66,1.40],[.84,1.51],[.86,1.76],[.58,1.91],[.27,1.87]]);
 cutout(face,[[-.155,1.19],[.155,1.19],[.10,1.40],[0,1.51],[-.10,1.40]]);
 const skull=relief(face,.39,bone,0,0,.41,.035),position=skull.geometry.attributes.position;
 for(let i=0;i<position.count;i++){
  const xx=position.getX(i),yy=position.getY(i),zz=position.getZ(i);
  if(zz>.38){const brow=Math.max(0,1-Math.abs(yy-1.96)/.45),round=Math.max(0,1-xx*xx);position.setZ(i,zz+.065*brow*round);}
 }
 skull.geometry.computeVertexNormals();
 relief(outline([[-.90,1.88],[-.60,2.04],[-.18,1.96],[-.22,1.84],[-.59,1.90],[-.84,1.80]]),.10,bone,0,0,.77,.015);
 relief(outline([[.18,1.95],[.57,2.03],[.91,1.86],[.84,1.80],[.58,1.90],[.23,1.84]]),.10,bone,0,0,.77,.015);
 for(let i=0;i<5;i++){
  const xx=(i-2)*.19,h=i===0?.135:i===4?.155:.19;
  const upper=box(.14,h,.16,tooth,xx,1.025-h/2,.80,g);upper.rotation.z=(i-2)*.035;
 }
 for(let i=0;i<4;i++)box(.15,i===1?.09:.12,.13,tooth,(i-1.5)*.22,.28,.79,g);

 towerShell(-1.23,-.27,.10,3.02,.43,stone);band(-1.23,-.27,.25,.45);band(-1.23,-.27,1.16,.43);band(-1.23,-.27,2.18,.405);crown(-1.23,-.27,3.02,.43,5);
 const arch=outline([[-.46,.10],[.46,.10],[.43,1.16],[-.42,1.16]]);
 cutout(arch,[[-.265,.18],[.265,.18],[.265,.60],[.17,.79],[0,.87],[-.17,.79],[-.265,.60]]);
 relief(arch,.79,stone,1.26,0,-.65,.025);
 towerShell(1.26,-.255,1.06,2.56,.40,stone);band(1.26,-.255,1.13,.41);band(1.26,-.255,2.03,.385);crown(1.26,-.255,2.56,.40,2);

 // Buttresses and broken stone remain attached to the foot and the towers.
 relief(outline([[-1.73,.12],[-1.63,.72],[-1.47,1.03],[-1.39,.16]]),.40,stone,0,0,-.14,.025);
 relief(outline([[1.46,.14],[1.53,.84],[1.69,.60],[1.77,.13]]),.36,stone,0,0,-.10,.025);
 const chip=box(.24,.12,.22,edge,-1.46,.18,.48,g);chip.rotation.y=.32;chip.rotation.z=-.12;
 const lip=box(.27,.10,.20,edge,1.54,.17,.43,g);lip.rotation.y=-.21;

 // Sparse raised algae pick out damp ledges without filling the holes.
 for(const [xx,yy,zz,sx,sz] of [[-1.48,.20,.47,.31,.17],[-1.49,1.23,-.02,.24,.11],[-1.02,2.24,-.04,.21,.12],[1.47,1.20,-.05,.23,.12],[1.56,.20,.38,.29,.18],[-.76,.23,.77,.15,.10],[.88,1.12,.71,.12,.09]]){
  const patch=mesh(new THREE.DodecahedronGeometry(.10,0),moss,xx,yy,zz,g);patch.scale.set(sx/.10,.25,sz/.10);
  const tip=mesh(new THREE.DodecahedronGeometry(.065,0),mossTip,xx+.055,yy+.018,zz+.015,g);tip.scale.set(1.15,.32,.80);
 }
 batchStatic(g);
 return g;
}

function resolvePlantClearance(){
 world.updateMatrixWorld(true);
 const equipment=['sponge-filter','aquarium-heater','aquarium-thermometer'].map(name=>world.getObjectByName(name)).filter(object=>object?.visible).map(object=>new THREE.Box3().setFromObject(object).expandByScalar(.14));
 for(const {g}of plants){
  const bounds=new THREE.Box3().setFromObject(g),overlap=equipment.filter(box=>box.intersectsBox(bounds));
  if(!overlap.length)continue;
  const right=Math.min(...overlap.map(box=>box.min.x));g.position.x-=bounds.max.x-right;g.updateMatrixWorld(true);
 }
}
function makeWaterCondition({solids=[],level=0}={}){
 const group=new THREE.Group();group.name='water-condition';world.add(group);
 const state={level:0,label:'clean',particleCount:0,debrisCount:0,hardscapePatches:0,hazeOpacity:0,clock:0};
 const clamp=THREE.MathUtils.clamp,smooth=THREE.MathUtils.smoothstep;
 const seeded=initial=>{let seed=initial;return()=>{seed=Math.imul(seed^seed>>>15,1|seed);seed^=seed+Math.imul(seed^seed>>>7,61|seed);return((seed^seed>>>14)>>>0)/4294967296;};};
 const bottom=bedLevel+.035,top=waterLevel-.035,back=-2.58,front=3.99;
 const rnd=seeded(731409),lit=(color,options={})=>rememberMaterial(new THREE.MeshLambertMaterial({color,transparent:true,depthTest:true,depthWrite:false,...options}));
 function surface(geometry,mat,name,x=0,y=0,z=0){const o=mesh(geometry,mat,x,y,z,group);o.name=name;o.castShadow=false;o.receiveShadow=false;return o;}
 function patchMap(width,height,seed,patches){
  const data=new Uint8Array(width*height*4),noise=seeded(seed);
  const shades=[[100,114,65],[118,127,76],[91,104,59],[128,121,79],[107,115,71]];
  for(let y=0;y<height;y++)for(let x=0;x<width;x++){
   const u=(x+.5)/width,v=(y+.5)/height,grain=noise();let density=0;
   for(let i=0;i<patches.length;i++){
    const [cx,cy,rx,ry]=patches[i],dx=(u-cx)/rx,dy=(v-cy)/ry;
    const edge=.11*Math.sin(dx*6+dy*3+i)+.10*Math.cos(dy*8-dx*2+i*.7);
    density=Math.max(density,1-dx*dx-dy*dy+edge);
   }
   if(density<=.05||grain<.16+(1-Math.min(1,density))*.18)continue;
   const shade=shades[Math.floor(noise()*shades.length)],i=(y*width+x)*4;
   data[i]=shade[0];data[i+1]=shade[1];data[i+2]=shade[2];data[i+3]=Math.round(255*clamp(density*.65+.16,0,.82));
  }
  const map=new THREE.DataTexture(data,width,height,THREE.RGBAFormat);map.colorSpace=THREE.SRGBColorSpace;
  map.minFilter=map.magFilter=THREE.NearestFilter;map.generateMipmaps=false;map.needsUpdate=true;maps.push(map);return map;
 }
 const frontPatches=[
  [[.035,.14,.045,.14],[.09,.045,.065,.07],[.956,.19,.044,.16],[.76,.035,.075,.045],[.982,.57,.025,.09]],
  [[.12,.29,.055,.13],[.88,.39,.055,.14],[.31,.038,.09,.052],[.035,.76,.035,.09],[.962,.81,.028,.085],[.56,.045,.06,.042]]
 ];
 const sidePatches=[
  [[.13,.09,.13,.12],[.85,.12,.11,.13],[.05,.45,.045,.15],[.97,.69,.04,.09]],
  [[.27,.045,.14,.06],[.71,.29,.10,.13],[.08,.79,.07,.10],[.89,.53,.06,.11],[.52,.05,.12,.05]]
 ];
 const glassMaterials=[];
 for(let stage=0;stage<2;stage++){
  const options={opacity:0,side:THREE.DoubleSide,forceSinglePass:true,alphaTest:.002};
  const frontMat=lit(0xffffff,{...options,map:patchMap(256,128,9021+stage,frontPatches[stage])});
  const sideMat=lit(0xffffff,{...options,map:patchMap(96,128,6113+stage,sidePatches[stage])});
  glassMaterials.push([frontMat,sideMat]);
  const pane=surface(new THREE.PlaneGeometry(tankHalf*2-.03,top-bottom),frontMat,'water-condition-glass-front-'+stage,0,(top+bottom)*.5,front);pane.renderOrder=15+stage;
  for(const sign of [-1,1]){
   const wall=surface(new THREE.PlaneGeometry(front-back-.015,top-bottom),sideMat,'water-condition-glass-side-'+sign+'-'+stage,sign*(tankHalf-.015),(top+bottom)*.5,(front+back-.015)*.5);
   wall.rotation.y=sign*Math.PI/2;wall.renderOrder=15+stage;
  }
 }

 // Project small textured grids onto real triangles; no assumed rock or branch anchors.
 const hardMap=patchMap(32,32,19437,[[.48,.52,.46,.43],[.66,.35,.21,.25],[.25,.38,.22,.19]]);
 const hardMaterial=lit(0xffffff,{map:hardMap,opacity:0,side:THREE.DoubleSide,forceSinglePass:true,alphaTest:.003});
 const targets=Array.from(new Set(solids.filter(o=>o?.isMesh&&!o.isInstancedMesh&&o.geometry?.attributes.position)));
 world.updateMatrixWorld(true);group.updateMatrixWorld(true);
 const inverse=group.matrixWorld.clone().invert(),localNormal=new THREE.Matrix3().getNormalMatrix(inverse),candidates=[];
 let totalArea=0;
 for(const target of targets){
  const position=target.geometry.attributes.position,index=target.geometry.index,normalMatrix=new THREE.Matrix3().getNormalMatrix(target.matrixWorld),faceCount=(index?index.count:position.count)/3;
  for(let face=0;face<faceCount;face++){
   const vertices=[0,1,2].map(corner=>new THREE.Vector3().fromBufferAttribute(position,index?index.getX(face*3+corner):face*3+corner).applyMatrix4(target.matrixWorld));
   const [a,b,c]=vertices,normal=b.clone().sub(a).cross(c.clone().sub(a)),area=normal.length()*.5;
   if(area<.005)continue;normal.normalize();
   const center=a.clone().add(b).add(c).multiplyScalar(1/3),local=center.clone().applyMatrix4(inverse),facing=normal.clone().applyMatrix3(localNormal).normalize();
   if(local.y<bottom+.12||local.y>top-.16||Math.abs(local.x)>tankHalf-.15||local.z<back+.1||local.z>front-.1||facing.y<-.2||(facing.y<.2&&facing.z<.25))continue;
   totalArea+=area;candidates.push({target,center,normal,normalMatrix,cumulative:totalArea});
  }
 }
 const skinPositions=[],skinNormals=[],skinUV=[],centers=[],ray=new THREE.Raycaster();
 const axis=new THREE.Vector3(0,1,0);
 for(let attempt=0;attempt<48&&centers.length<9&&candidates.length;attempt++){
  const choice=rnd()*totalArea;let low=0,high=candidates.length-1;
  while(low<high){const middle=(low+high)>>1;if(candidates[middle].cumulative<choice)low=middle+1;else high=middle;}
  const selected=candidates[low],radius=.19+rnd()*.19;
  if(centers.some(center=>center.distanceTo(selected.center)<radius*1.8))continue;
  const tangent=new THREE.Vector3().crossVectors(Math.abs(selected.normal.y)<.9?axis:new THREE.Vector3(1,0,0),selected.normal).normalize();
  const bitangent=new THREE.Vector3().crossVectors(selected.normal,tangent).normalize(),grid=[],steps=5;
  for(let y=0;y<=steps;y++)for(let x=0;x<=steps;x++){
   const origin=selected.center.clone().addScaledVector(tangent,(x/steps-.5)*radius*2).addScaledVector(bitangent,(y/steps-.5)*radius*2).addScaledVector(selected.normal,radius+.035);
   ray.set(origin,selected.normal.clone().negate());ray.near=0;ray.far=radius*2+.07;
   const hit=ray.intersectObject(selected.target,false)[0];
   if(!hit){grid.push(null);continue;}
   const normal=hit.face.normal.clone().applyMatrix3(selected.normalMatrix).normalize();
   const p=hit.point.clone().addScaledVector(normal,.006).applyMatrix4(inverse);
   if(normal.dot(selected.normal)<.35||p.y<bottom||p.y>top||Math.abs(p.x)>tankHalf-.025||p.z<back||p.z>front-.025){grid.push(null);continue;}
   grid.push({p,n:normal.applyMatrix3(localNormal).normalize(),uv:[x/steps,y/steps]});
  }
  const before=skinPositions.length;
  for(let y=0;y<steps;y++)for(let x=0;x<steps;x++){
   const a=y*(steps+1)+x,b=a+1,c=a+steps+1,d=c+1;
   for(const corners of [[a,b,c],[b,d,c]]){
    const triangle=corners.map(i=>grid[i]);if(triangle.some(vertex=>!vertex))continue;
    if(triangle.some((vertex,i)=>vertex.p.distanceTo(triangle[(i+1)%3].p)>radius*.8))continue;
    if(triangle[1].p.clone().sub(triangle[0].p).cross(triangle[2].p.clone().sub(triangle[0].p)).lengthSq()<1e-12)continue;
    for(const vertex of triangle){skinPositions.push(...vertex.p.toArray());skinNormals.push(...vertex.n.toArray());skinUV.push(...vertex.uv);}
   }
  }
  if(skinPositions.length>before)centers.push(selected.center);
 }
 const hardGeometry=new THREE.BufferGeometry();hardGeometry.setAttribute('position',new THREE.Float32BufferAttribute(skinPositions,3));hardGeometry.setAttribute('normal',new THREE.Float32BufferAttribute(skinNormals,3));hardGeometry.setAttribute('uv',new THREE.Float32BufferAttribute(skinUV,2));
 const hardscape=surface(hardGeometry,hardMaterial,'water-condition-hardscape');hardscape.receiveShadow=true;hardscape.renderOrder=2;state.hardscapePatches=centers.length;

 // Three very faint depth slices keep fish readable and leave the dry rim untouched.
 const hazePositions=[],hazeNormals=[];
 for(const z of [-1.25,1.25,frontBound-.004])for(const [x,y] of [[-tankHalf+.025,bottom],[tankHalf-.025,bottom],[-tankHalf+.025,top],[tankHalf-.025,bottom],[tankHalf-.025,top],[-tankHalf+.025,top]]){hazePositions.push(x,y,z);hazeNormals.push(0,0,1);}
 const hazeGeometry=new THREE.BufferGeometry();hazeGeometry.setAttribute('position',new THREE.Float32BufferAttribute(hazePositions,3));hazeGeometry.setAttribute('normal',new THREE.Float32BufferAttribute(hazeNormals,3));
 const hazeMaterial=rememberMaterial(new THREE.MeshBasicMaterial({color:0x788365,transparent:true,opacity:0,depthTest:true,depthWrite:false,side:THREE.DoubleSide,forceSinglePass:true}));
 hazeMaterial.userData.lightingBase=hazeMaterial.color.clone();
 const haze=surface(hazeGeometry,hazeMaterial,'water-condition-haze');haze.renderOrder=3;

 const particleMaterial=lit(0xb9b39b,{opacity:0}),debrisMaterial=lit(0x8c7651,{opacity:0});
 const particleGeometry=new THREE.BoxGeometry(.014,.019,.014),debrisGeometry=new THREE.OctahedronGeometry(1,0);geometries.push(particleGeometry,debrisGeometry);
 const particles=new THREE.InstancedMesh(particleGeometry,particleMaterial,28),debris=new THREE.InstancedMesh(debrisGeometry,debrisMaterial,64);
 particles.name='water-condition-particles';debris.name='water-condition-debris';particles.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
 for(const o of [particles,debris]){o.castShadow=false;o.receiveShadow=true;o.frustumCulled=false;o.renderOrder=4;group.add(o);}
 const dummy=new THREE.Object3D(),specks=[],color=new THREE.Color();
 for(let i=0;i<28;i++){
  specks.push({x:(rnd()*2-1)*(tankHalf-.3),y:bottom+.18+rnd()*(top-bottom-.4),z:back+.25+rnd()*(front-back-.55),phase:rnd()*Math.PI*2,speed:.009+rnd()*.012,size:.8+rnd()*.8});
  particles.setColorAt(i,color.setHex(i%4===0?0xa0a487:0xc0bca6));
 }
 for(let i=0;i<64;i++){
  const pocket=i%4,centerX=[-.6,.52,-.88,.89][pocket]*tankHalf,centerZ=[-.15,.25,2.2,2.75][pocket];
  const x=clamp(centerX+(rnd()-.5)*tankHalf*.32,-tankHalf+.12,tankHalf-.12),z=clamp(centerZ+(rnd()-.5)*1.9,back+.12,front-.12);
  dummy.position.set(x,bedLevel+.027+rnd()*.012,z);dummy.rotation.set(0,rnd()*Math.PI,.08*(rnd()-.5));dummy.scale.set(.027+rnd()*.052,.006+rnd()*.008,.024+rnd()*.044);dummy.updateMatrix();debris.setMatrixAt(i,dummy.matrix);
  debris.setColorAt(i,color.setHex([0xa29370,0x8a7859,0x948260,0xb1a37d][i%4]));
 }
 debris.instanceMatrix.needsUpdate=true;
 function update(nextClock){
  if(Number.isFinite(nextClock))state.clock=nextClock;
  const t=state.clock,span=top-bottom-.35;
  for(let i=0;i<specks.length;i++){
   const p=specks[i],drift=(p.y-bottom-.18-t*p.speed)%span;
   dummy.position.set(p.x+Math.sin(t*.13+p.phase)*.07,bottom+.18+(drift+span)%span,p.z+Math.cos(t*.09+p.phase)*.045);
   dummy.rotation.set(p.phase+t*.025,p.phase*.7+t*.018,0);dummy.scale.setScalar(p.size);dummy.updateMatrix();particles.setMatrixAt(i,dummy.matrix);
  }
  particles.instanceMatrix.needsUpdate=true;
 }
 function setLevel(next){
  const value=Number.isFinite(next)?clamp(next,0,1):0,established=smooth(value,.025,.65),overdue=smooth(value,.5,1),cloud=smooth(value,.42,1);
  state.level=value;state.label=value===0?'clean':value<.7?'established':'overdue maintenance';group.visible=value>0;
  for(const mat of glassMaterials[0])mat.opacity=established*.34;
  for(const mat of glassMaterials[1])mat.opacity=overdue*.32;
  hardMaterial.opacity=established*.34+overdue*.19;hardscape.visible=state.hardscapePatches>0&&hardMaterial.opacity>0;
  hazeMaterial.opacity=cloud*.014;haze.visible=hazeMaterial.opacity>0;state.hazeOpacity=1-Math.pow(1-hazeMaterial.opacity,3);
  state.particleCount=Math.round(28*smooth(value,.17,1));state.debrisCount=Math.round(64*smooth(value,.2,1));
  particles.count=state.particleCount;debris.count=state.debrisCount;particleMaterial.opacity=.25+value*.35;debrisMaterial.opacity=.25+value*.6;
  for(let stage=0;stage<2;stage++)for(const o of group.children)if(o.name.startsWith('water-condition-glass-')&&o.name.endsWith('-'+stage))o.visible=glassMaterials[stage][0].opacity>0;
  return state;
 }
 update(0);setLevel(level);return{setLevel,update,group,state};
}

function recoverRemovedPlantSupport(previous){
 for(const [shrimp,id]of previous){const a=shrimp.surfaceMotion,site=leafContacts.get(id);
  if(site&&a.position.distanceTo(new THREE.Vector3(...site.position).add(new THREE.Vector3(0,.12,0)))<.04){a.contactId=id;a.falling=false;}
  else a.falling=!surfaceNavigation?.plan(a.position,a.position);
 }
}
function rebuildSurfaceNavigation(rehome=false){
 const previous=new Map(shrimps.filter(s=>s.life.alive&&s.surfaceMotion?.surface!=='glass'&&(leafContacts.has(s.surfaceMotion?.contactId)||s.surfaceMotion?.contactKind==='foliage')).map(s=>[s,s.surfaceMotion.contactId]));
 surfaceNavigation=null;navigationSites=[];leafContacts=new Map();designerNavigationError='';
 for(const shrimp of shrimps){shrimp.perchGoal=null;shrimp.perchUntil=0;if(shrimp.surfaceMotion)shrimp.surfaceMotion.contactId=null;}
 if(!carpetArt&&!visibleInWorld(manzanitaArt?.group)&&!visibleInWorld(mossFormation?.group)&&!designerRuntime?.validSolids.length&&!designerRuntime?.plants.length){recoverRemovedPlantSupport(previous);return;}
  const anchors=[],botany=carpetArt?.group.userData.botany.plants||[],step=Math.max(1,Math.ceil(botany.length/16));
  const navigationRadius=.045,navigationOffset=.12,navigationInset=navigationRadius+.005,canopyPoint=new THREE.Vector3();
  const canopyBlockers=collisionWorld.meshes.map(o=>{if(!o.geometry.boundingBox)o.geometry.computeBoundingBox();return o.geometry.boundingBox.clone().applyMatrix4(o.matrixWorld).expandByScalar(navigationRadius+.01);});
  const eligibleContact=p=>p.every(Number.isFinite)&&p[1]>=bedLevel&&Math.abs(p[0])<=innerHalf-navigationInset&&p[2]>=backBound+navigationInset&&p[2]<=frontBound-navigationInset&&!canopyBlockers.some(box=>box.containsPoint(canopyPoint.set(p[0],p[1]+navigationOffset,p[2])));
  for(let i=0;i<botany.length;i+=step){const plant=botany[i],shoot=plant.shoots.find(s=>s.leaves.length);if(!shoot)continue;let previous=null;
   const points=[plant.anchor,...shoot.path];if(!points.every(eligibleContact))continue;
   for(let j=0;j<points.length;j++){const p=points[j],id='plant-'+i+'-'+j;anchors.push({id,position:{x:p[0],y:p[1],z:p[2]},links:previous?[previous]:[]});previous=id;}
   for(const [j,leaf]of shoot.leaves.slice(-2).entries()){const index=shoot.path.findIndex(p=>p.every((v,k)=>Math.abs(v-leaf.base[k])<.00001));if(index<0||!eligibleContact(leaf.site))continue;const id='plant-'+i+'-leaf-'+j,p=leaf.site;anchors.push({id,position:{x:p[0],y:p[1],z:p[2]},links:['plant-'+i+'-'+(index+1)]});const site=carpetArt.group.userData.grazeSites.find(s=>s.plantIndex===i&&s.rest.every((v,k)=>Math.abs(v-p[k])<.00001));if(site)leafContacts.set(id,site);}
  }
  for(const art of [manzanitaArt,mossFormation])if(art&&visibleInWorld(art.group)){art.group.updateWorldMatrix(true,true);for(const a of art.grazeSites){const p=art.group.localToWorld(new THREE.Vector3(...a.position)),n=new THREE.Vector3(...a.normal).transformDirection(art.group.matrixWorld);anchors.push({...a,position:{x:p.x,y:p.y,z:p.z},normal:{x:n.x,y:n.y,z:n.z}});}}
  const contactAssets=[...(botanicalArt?.assets||[]),...(designerRuntime?.plants||[])];
  if(contactAssets.length){
   const solids=collisionWorld.meshes.map(mesh=>({mesh,box:mesh.geometry.boundingBox.clone().applyMatrix4(mesh.matrixWorld),triangles:null})),centers=new Map(),closest=new THREE.Vector3();
   const trianglesOf=solid=>{
    if(solid.triangles)return solid.triangles;
    const mesh=solid.mesh,positions=mesh.geometry.attributes.position,indices=mesh.geometry.index,count=indices?.count??positions.count,mirrored=mesh.matrixWorld.determinant()<0;solid.triangles=[];
    for(let i=0;i+2<count;i+=3){const vertices=[0,1,2].map(j=>new THREE.Vector3().fromBufferAttribute(positions,indices?indices.getX(i+j):i+j).applyMatrix4(mesh.matrixWorld)),[a,b,c]=vertices,triangle=new THREE.Triangle(a,b,c),normal=triangle.getNormal(new THREE.Vector3());if(normal.lengthSq()<.5)continue;if(mirrored)normal.negate();solid.triangles.push({a,b,c,triangle,normal,box:new THREE.Box3().setFromPoints(vertices),determinant:(b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)});}
    return solid.triangles;
   };
   const contactClear=site=>{
    if(site.habitat==='aerial'||!site.rest.every(Number.isFinite)||!site.normal.every(Number.isFinite))return false;
    const normal=new THREE.Vector3().fromArray(site.normal);if(normal.lengthSq()<1e-12)return false;
    const p=new THREE.Vector3().fromArray(site.rest).addScaledVector(normal.normalize(),navigationOffset);
    if(p.x<-innerHalf+navigationInset-1e-8||p.x>innerHalf-navigationInset+1e-8||p.z<backBound+navigationInset-1e-8||p.z>frontBound-navigationInset+1e-8||p.y<bedLevel+navigationOffset-1e-7)return false;
    for(const solid of solids){
     if(p.x<solid.box.min.x-navigationRadius||p.x>solid.box.max.x+navigationRadius||p.z<solid.box.min.z-navigationRadius||p.z>solid.box.max.z+navigationRadius)continue;
     let firstAbove=null;
     for(const t of trianglesOf(solid)){
      if(Math.abs(t.determinant)>=1e-10){const dx=p.x-t.a.x,dz=p.z-t.a.z,u=(dx*(t.c.z-t.a.z)-dz*(t.c.x-t.a.x))/t.determinant,v=((t.b.x-t.a.x)*dz-(t.b.z-t.a.z)*dx)/t.determinant;
       if(u>=-1e-7&&v>=-1e-7&&u+v<=1+1e-7){const y=t.a.y+u*(t.b.y-t.a.y)+v*(t.c.y-t.a.y);if(y>p.y+1e-7&&(!firstAbove||firstAbove.y>y))firstAbove={y,normal:t.normal.y};}
      }
      if(t.box.distanceToPoint(p)<=navigationRadius){t.triangle.closestPointToPoint(p,closest);if(p.distanceToSquared(closest)<navigationRadius*navigationRadius-1e-9)return false;}
     }
     if(firstAbove?.normal>1e-6)return false;
    }
    centers.set(site.id,p);return true;
   };
   const segmentDistanceSq=(a,b,c,d)=>{
    const ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=d.x-c.x,vy=d.y-c.y,vz=d.z-c.z,wx=a.x-c.x,wy=a.y-c.y,wz=a.z-c.z;
    const aa=ux*ux+uy*uy+uz*uz,bb=ux*vx+uy*vy+uz*vz,cc=vx*vx+vy*vy+vz*vz,dd=ux*wx+uy*wy+uz*wz,ee=vx*wx+vy*wy+vz*wz,den=aa*cc-bb*bb;
    let sn=den<1e-12?0:bb*ee-cc*dd,sd=den<1e-12?1:den,tn=den<1e-12?ee:aa*ee-bb*dd,td=den<1e-12?cc:den;
    if(sn<0){sn=0;tn=ee;td=cc;}else if(sn>sd){sn=sd;tn=ee+bb;td=cc;}
    if(tn<0){tn=0;if(-dd<0)sn=0;else if(-dd>aa)sn=sd;else{sn=-dd;sd=aa;}}
    else if(tn>td){tn=td;if(-dd+bb<0)sn=0;else if(-dd+bb>aa)sn=sd;else{sn=-dd+bb;sd=aa;}}
    const s=Math.abs(sn)<1e-12?0:sn/sd,t=Math.abs(tn)<1e-12?0:tn/td;
    return(wx+s*ux-t*vx)**2+(wy+s*uy-t*vy)**2+(wz+s*uz-t*vz)**2;
   };
   const segmentBox=new THREE.Box3(),segmentRay=new THREE.Ray(),segmentHit=new THREE.Vector3(),segmentDirection=new THREE.Vector3();
   const clearContactSegment=(a,b)=>{
    const length=a.distanceTo(b);if(length<1e-9)return true;
    segmentBox.setFromPoints([a,b]).expandByScalar(navigationRadius);segmentRay.set(a,segmentDirection.copy(b).sub(a).divideScalar(length));
    for(const solid of solids){if(!solid.box.intersectsBox(segmentBox))continue;
     for(const t of trianglesOf(solid)){if(!t.box.intersectsBox(segmentBox))continue;
      if(segmentRay.intersectTriangle(t.a,t.b,t.c,false,segmentHit)&&segmentHit.distanceTo(a)<=length+1e-8)return false;
      if(segmentDistanceSq(a,b,t.a,t.b)<navigationRadius*navigationRadius-1e-9||segmentDistanceSq(a,b,t.b,t.c)<navigationRadius*navigationRadius-1e-9||segmentDistanceSq(a,b,t.c,t.a)<navigationRadius*navigationRadius-1e-9)return false;
     }
    }
    return true;
   };
   for(const asset of contactAssets){
   const sourceById=new Map(asset.sites.map(s=>[s.worldSite.id,s])),candidates=asset.sites.map(s=>s.worldSite).filter(contactClear),byId=new Map(candidates.map(s=>[s.id,s])),chosen=new Set(),links=new Map(candidates.map(s=>[s.id,new Set()]));
   const root=candidates.slice().sort((a,b)=>a.rest[1]-b.rest[1])[0];if(!root)continue;
   const shortLink=(a,b)=>centers.get(a).distanceTo(centers.get(b))<=.65;
   for(const site of candidates)for(const id of site.links)if(byId.has(id)&&shortLink(site.id,id))links.get(site.id).add(id);
   if(asset.placement==='rooted')for(const start of candidates){
    const startPoint=new THREE.Vector3().fromArray(start.rest),pending=[{id:start.id,path:[start.id],length:0}],seen=new Set([start.id]);
    for(let i=0;i<pending.length;i++){const current=pending[i],source=sourceById.get(current.id).worldSite;
     for(const id of source.links){if(seen.has(id)||!sourceById.has(id))continue;seen.add(id);const record=sourceById.get(id),site=record.worldSite,endPoint=new THREE.Vector3().fromArray(site.rest),length=current.length+endPoint.distanceTo(new THREE.Vector3().fromArray(source.rest));if(length>.65)continue;
      const path=[...current.path,id];
      if(byId.has(id)){
       if(path.length<3||!shortLink(start.id,id))continue;
       const chord=new THREE.Line3(startPoint,endPoint);if(path.slice(1,-1).some(key=>{const p=new THREE.Vector3().fromArray(sourceById.get(key).worldSite.rest);return chord.closestPointToPoint(p,true,closest).distanceTo(p)>.035;}))continue;
       if(!clearContactSegment(centers.get(start.id),centers.get(id)))continue;
       links.get(start.id).add(id);links.get(id).add(start.id);
      }else if(record.localSite.kind==='stem'&&site.rest[1]>=bedLevel-1e-7&&site.rest[1]<bedLevel+navigationOffset+navigationRadius)pending.push({id,path,length});
     }
    }
   }
   const queue=[root.id],parents=new Map([[root.id,null]]);for(let i=0;i<queue.length;i++)for(const id of links.get(queue[i]))if(!parents.has(id)){parents.set(id,queue[i]);queue.push(id);}
   const targets=candidates.slice().sort((a,b)=>(asset.placement==='rooted'?Number(sourceById.get(b.id).localSite.kind==='leaf')-Number(sourceById.get(a.id).localSite.kind==='leaf'):0)||b.rest[1]-a.rest[1]);
   for(const leaf of targets){if(!parents.has(leaf.id))continue;const path=[];for(let id=leaf.id;id!==null;id=parents.get(id))path.push(id);if(new Set([...chosen,...path]).size>22)continue;for(const id of path)chosen.add(id);if(chosen.size>=20)break;}
   for(const id of chosen){const site=byId.get(id),p=site.rest;anchors.push({id,position:{x:p[0],y:p[1],z:p[2]},normal:{x:site.normal[0],y:site.normal[1],z:site.normal[2]},links:[...links.get(id)].filter(other=>chosen.has(other)),kind:'foliage'});leafContacts.set(id,site);}
   }
  }
  AquariumCanopyRoutes.extend(anchors,(carpetArt?.group.userData.grazeSites||[]).filter(site=>eligibleContact(site.rest)),leafContacts);
  const navigationOptions={world:collisionWorld,bedLevel,halfWidth:innerHalf,backZ:backBound,frontZ:frontBound,radius:navigationRadius,offset:navigationOffset,spacing:.38,maxNodes:8192,anchors};
  try{surfaceNavigation=AquariumSurfaceContacts.create(THREE,navigationOptions);}catch(error){if(!designerActive)throw error;designerNavigationError=error.message;leafContacts.clear();try{surfaceNavigation=AquariumSurfaceContacts.create(THREE,{...navigationOptions,anchors:[]});}catch(fallback){designerNavigationError+='; '+fallback.message;recoverRemovedPlantSupport(previous);return;}}navigationSites=surfaceNavigation.sites;recoverRemovedPlantSupport(previous);
  const leaves=navigationSites.filter(s=>leafContacts.has(s.id));for(let i=0;rehome&&i<Math.min(3,leaves.length);i++){const shrimp=shrimps[4+i];shrimp.o.position.copy(leaves[Math.floor(i*leaves.length/3)].position);shrimp.surfaceMotion.position.copy(shrimp.o.position);shrimp.life.position={x:shrimp.o.position.x,y:shrimp.o.position.y,z:shrimp.o.position.z};}
}
function build(){
 const retained=!restoringTank&&world.children.length?captureRuntimeBindings():null;
 presetRevision++;
 clearWorld(!retained);
 const woodMap=pixelMap(['#69503a','#795c3e','#916e47','#4c3d30','#a38354'],'wood',101);
 const rockMap=pixelMap(assets.rock==='river'?['#606463','#747a73','#8c9184','#505d5c','#a7ab96']:['#3e4547','#484f50','#353c3f','#505858','#5b6160'],'slate',84);
 const sideMap=pixelMap(['#30373a','#394144','#42494c','#2b3236','#515757'],'slate',84);
 const gravelPalette=assets.gravel==='river'?['#727168','#8b826c','#555d5d','#a6997d','#6d6159']:['#252b2e','#333b3f','#454c4e','#554f45','#69706c'];
 const floorMap=pixelMap(assets.gravel==='river'?['#303832','#363d35']:['#111a1d','#172024'],'gravel',612);floorMap.repeat.set(visibleWidth/2.2,3);

 const spongeMap=pixelMap(['#1b3036','#223b3d','#304743','#122930'],'sponge',17);
 M={wood:rememberMaterial(new THREE.MeshLambertMaterial({color:0xd8c2a3,map:woodMap})),slateTop:material(assets.rock==='slate'?0xd2d6d6:0xd0e0ef,rockMap),slateSide:material(0xc4cacb,sideMap),floor:material(0xc6cbc1,floorMap),stem:material(0x335e4b),stemPurple:material(0x403e5b),leaf:rememberMaterial(new THREE.MeshLambertMaterial({color:0x82995f,side:THREE.DoubleSide})),leafLight:rememberMaterial(new THREE.MeshLambertMaterial({color:0xa3ae76,side:THREE.DoubleSide})),leafVein:basic(0xa2ad6b,{side:THREE.DoubleSide}),purple:rememberMaterial(new THREE.MeshLambertMaterial({color:0x996b96,side:THREE.DoubleSide})),purpleLight:rememberMaterial(new THREE.MeshLambertMaterial({color:0xb58ca8,side:THREE.DoubleSide})),purpleVein:basic(0xaf839b,{side:THREE.DoubleSide}),moss:material(0x718950),mossLight:material(0x95a65e),mossLeaf:rememberMaterial(new THREE.MeshLambertMaterial({color:0x618453,side:THREE.DoubleSide})),mossLeafLight:rememberMaterial(new THREE.MeshLambertMaterial({color:0x8ca168,side:THREE.DoubleSide})),edge:material(0x263e48),metal:material(0x506a72),rubber:material(0x172d35),sponge:material(0xd4d6c6,spongeMap)};
 makeBackdrop();
 // The front pane and its bottom corners remain visible inside the viewport.
 const floor=mesh(new THREE.PlaneGeometry(innerHalf*2,innerDepth-.02),M.floor,0,bedLevel-.018,centerZ);floor.rotation.x=-Math.PI/2;
 const pebbleGeo=new THREE.IcosahedronGeometry(1,0);geometries.push(pebbleGeo);
 const positions=pebbleGeo.attributes.position,normals=pebbleGeo.attributes.normal,radial=new THREE.Vector3();
 for(let i=0;i<positions.count;i++){radial.fromBufferAttribute(positions,i).normalize();normals.setXYZ(i,radial.x,radial.y,radial.z);}
 const isRiver=assets.gravel!=='basalt',gravelRandom=makeRandom(isRiver?613:612),nominalPitch=.065;
 const pitch=Math.max(nominalPitch,Math.sqrt(innerHalf*2*(innerDepth-.06+bedLevel/.88+nominalPitch)/33000));
 const rows=Math.ceil((innerDepth-.06)/pitch),frontRows=Math.ceil(bedLevel/(pitch*.88)),columns=Math.max(2,Math.min(Math.ceil(innerHalf*2/pitch)+1,Math.floor(35000/(rows+frontRows+1))));
 const surfaceCount=columns*rows,frontCount=columns*frontRows,shoulderCount=columns,stepX=innerHalf*2/(columns-1),stepZ=(innerDepth-.06)/rows;
 const gravelClip=[...tankClip.slice(0,3),new THREE.Plane(new THREE.Vector3(0,0,1),-backBound),new THREE.Plane(new THREE.Vector3(0,1,0),0)];
 const pebbleMat=rememberMaterial(new THREE.MeshPhongMaterial({color:0xffffff,specular:isRiver?0x333933:0x303b40,shininess:24,flatShading:false}));pebbleMat.clippingPlanes=gravelClip;
 const pebbles=new THREE.InstancedMesh(pebbleGeo,pebbleMat,surfaceCount+frontCount+shoulderCount),dummy=new THREE.Object3D();pebbles.name='substrate-pebbles';pebbles.userData={surfaceCount,frontCount,shoulderCount,bedLevel,columns,rows,frontRows};
 const gravelColors=gravelPalette.map(hex=>new THREE.Color(hex)),color=new THREE.Color(),weights=isRiver?[.40,.65,.85,.95,1]:[.52,.80,.93,.98,1];
 function grain(i,x,y,z,front=false){
  const size=gravelRandom(),diameter=metric.toWorld(.2+.2*(size*.55+gravelRandom()*.45));
  const shape=gravelRandom(),sx=diameter*.5,sy=sx*(shape<.65?.75+gravelRandom()*.20:shape<.90?.55+gravelRandom()*.20:.72+gravelRandom()*.23),sz=sx*(shape<.90?.84+gravelRandom()*.16:.74+gravelRandom()*.16);
  dummy.position.set(x,y+(front?0:sy*.18),z);dummy.scale.set(sx,sy,sz);dummy.rotation.set((gravelRandom()-.5)*1.25,gravelRandom()*Math.PI*2,(gravelRandom()-.5)*1.25);dummy.updateMatrix();
  const e=dummy.matrix.elements,ex=Math.hypot(e[0],e[4],e[8]),ey=Math.hypot(e[1],e[5],e[9]),ez=Math.hypot(e[2],e[6],e[10]);
  dummy.position.x=THREE.MathUtils.clamp(dummy.position.x,-innerHalf+ex+.006,innerHalf-ex-.006);dummy.position.y=Math.max(ey+.006,dummy.position.y);dummy.position.z=THREE.MathUtils.clamp(dummy.position.z,backBound+ez+.006,frontBound-ez-.012);dummy.updateMatrix();pebbles.setMatrixAt(i,dummy.matrix);
  const patchSeed=Math.imul(Math.floor((x+tankHalf)/.55),73856093)^Math.imul(Math.floor((front?y:z+2.6)/.55),19349663)^612;
  const sample=gravelRandom()<.28?makeRandom(patchSeed)():gravelRandom();let shade=0;while(sample>weights[shade])shade++;
  const depthShade=front?.80+.20*Math.min(1,Math.max(0,y)/(bedLevel*.28)):1;
  color.copy(gravelColors[shade]).multiplyScalar(depthShade*(.96+gravelRandom()*.08));pebbles.setColorAt(i,color);
 }
 for(let row=0;row<rows;row++){
  const rowPhase=(gravelRandom()-.5)*.8;
  for(let col=0;col<columns;col++){
   const x=-innerHalf+(col+rowPhase+(gravelRandom()-.5)*.48)*stepX,z=backBound+.03+(row+.5+(gravelRandom()-.5)*.62)*stepZ;
   const y=bedLevel-.006+Math.sin(x*1.13+z*.72)*.006+(gravelRandom()-.5)*.009;
   grain(row*columns+col,x,y,z);
  }
 }
 for(let row=0;row<frontRows;row++){
  const rowPhase=(gravelRandom()-.5)*.9;
  for(let col=0;col<columns;col++){
   const x=-innerHalf+(col+rowPhase+(gravelRandom()-.5)*.58)*stepX,y=(row+.5+(gravelRandom()-.5)*.48)*bedLevel/frontRows;
   grain(surfaceCount+row*columns+col,x,y,frontBound-.054+gravelRandom()*.016,true);
  }
 }
 for(let col=0;col<columns;col++){
  const x=-innerHalf+(col+(gravelRandom()-.5)*.7)*stepX;
  grain(surfaceCount+frontCount+col,x,bedLevel-.009+(gravelRandom()-.5)*.014,frontBound-.056+(gravelRandom()-.5)*.018);
 }
 pebbles.receiveShadow=true;world.add(pebbles);
 if(assets.gravel==='mixed-river'){
  world.remove(pebbles);pebbles.dispose();const a=AquariumGravelVarieties.create(THREE,{tankHalf:innerHalf,bedLevel,backZ:backBound,frontZ:frontBound,diameterRange:[metric.toWorld(.2),metric.toWorld(.4)],seed:919,style:'river'});world.add(a.group);geometries.push(...a.geometries);maps.push(...a.maps);for(const m of a.materials){m.clippingPlanes=gravelClip;mats.push(m);}
 }
 const bedFaceMap=pixelMap(gravelPalette,'gravel',613);bedFaceMap.repeat.set(innerHalf*2/.65,Math.max(1,bedLevel/.65));
 const bedFace=material(isRiver?0x777f72:0x68747a,bedFaceMap);bedFace.clippingPlanes=gravelClip;
 const substrateFill=box(innerHalf*2,bedLevel-.020,innerDepth-.13,bedFace,0,(bedLevel-.020)*.5,centerZ-.055);substrateFill.name='substrate-fill';
 // Preserve the frozen scene's random stream for every item after the substrate.
 const previousPitch=isRiver?.155:.105,previousColumns=Math.floor((tankHalf*2-.2)/previousPitch),previousDraws=previousColumns*(Math.ceil(6.4/previousPitch)*11+Math.ceil(bedLevel/previousPitch)*10);
 for(let i=0;i<previousDraws;i++)random();
 const bedContentsStart=world.children.length;
 // Sparse background plants and shadow establish depth without filling the swimming lane.
 plant(-visibleWidth*.46,-2.3,3.6,true,11);plant(-visibleWidth*.34,-2.4,4.2,false,7);plant(-visibleWidth*.16,-2.35,3.4,true,9);
 plant(visibleWidth*.30,-2.25,4.2,true,15);plant(visibleWidth*.40,-1.95,3.2,false,4);
 // Tapered driftwood silhouette, broad rooted base and connected branches.
 const woodStart=world.children.length;
 const wx=-visibleWidth*.29;
 if(assets.wood==='manzanita'){
  manzanitaArt=AquariumManzanitaArt.create(THREE,{seed:731,growth:1});manzanitaArt.group.position.set(wx,.12,.35);world.add(manzanitaArt.group);geometries.push(...manzanitaArt.geometries);maps.push(...manzanitaArt.maps);for(const m of manzanitaArt.materials)rememberMaterial(m);
 }else{
 contact(wx,-.3,2.4,1.2,.23);
 // A twisted root crown with broad buttresses, folded limbs and fine weathered tips.
 // Each fourth coordinate is a radius multiplier; the fifth flattens a root ribbon.
 branch([[wx-.85,.10,.78,1.25,.65],[wx-.74,.58,.53,1.40,.76],[wx-.63,1.28,.27,1.08,.81],[wx-.83,1.95,-.02,.89,.75],[wx-.59,2.75,-.20,.67,.69],[wx-.31,3.57,-.27,.54,.71],[wx-.64,4.39,-.31,.36,.73],[wx-.42,5.12,-.59,.27,.73],[wx-.55,5.63,-.72,.18,.69],[wx-.29,6.04,-.78,.12,.72],[wx-.18,6.38,-.78,.06,.73]],.43,world,{broken:true});
 // The long low arm rises out of the crown before turning toward open water.
 branch([[wx-.66,1.51,.13,1.05],[wx-.26,1.96,.02,1.13],[wx+.19,2.25,-.08,.90],[wx+.74,2.34,-.25,.68],[wx+1.22,2.54,-.34,.43],[wx+1.59,2.96,-.57,.28],[wx+1.69,3.31,-.64,.18],[wx+2.08,3.44,-.70,.10],[wx+2.39,3.73,-.73,.025]],.30,world,{twist:.4});
 // A folded upper fork, deliberately unequal to the left arm.
 branch([[wx-.43,3.18,-.22,1.06],[wx-.12,3.62,-.28,1.10],[wx+.27,3.95,-.34,.82],[wx+.64,4.30,-.43,.52],[wx+.96,4.61,-.63,.33],[wx+.89,5.03,-.74,.20],[wx+1.04,5.32,-.83,.035]],.22,world,{twist:-.5});
 branch([[wx-.49,2.64,-.17,1.03],[wx-.97,3.14,-.34,1.04],[wx-1.30,3.47,-.51,.77],[wx-1.57,3.92,-.61,.51],[wx-1.96,4.09,-.71,.31],[wx-2.19,4.44,-.81,.21],[wx-2.07,4.78,-.90,.12],[wx-2.29,5.05,-.88,.035]],.245,world,{twist:.85});
 // Buttresses start within the crown and flatten onto the bed instead of meeting as poles.
 branch([[wx-.65,1.02,.34,1.04,.63],[wx-.36,.63,.70,1.15,.51],[wx+.12,.30,1.02,.93,.40],[wx+.63,.18,1.28,.59,.33],[wx+1.16,.12,1.49,.31,.32],[wx+1.45,.12,1.47,.035,.35]],.39,world,{twist:.18});
 branch([[wx-.70,.85,.38,1.12,.69],[wx-1.02,.42,.86,1.18,.49],[wx-1.48,.19,1.25,.78,.34],[wx-1.98,.13,1.54,.45,.29],[wx-2.45,.12,1.53,.22,.34],[wx-2.67,.10,1.69,.035,.36]],.36,world,{twist:-.2});
 branch([[wx-.67,.80,.21,.96,.63],[wx-1.02,.47,-.31,1.10,.52],[wx-1.20,.23,-.81,.70,.35],[wx-1.75,.13,-1.16,.39,.32],[wx-2.02,.10,-1.19,.035,.34]],.33,world,{twist:.32});
 branch([[wx-.69,.75,.29,1.04,.69],[wx-.36,.40,-.17,.98,.48],[wx+.13,.17,-.56,.61,.31],[wx+.69,.12,-.63,.28,.31],[wx+.93,.10,-.88,.035,.34]],.31,world,{twist:-.1});
 // A split toe and a handful of fine root forks keep the silhouette irregular.
 branch([[wx-1.59,.18,1.33,.72,.36],[wx-1.98,.13,1.29,.72,.30],[wx-2.24,.10,1.21,.43,.26],[wx-2.52,.10,1.26,.035,.30]],.19,world,{twist:.2});
 branch([[wx+.69,2.34,-.25,1],[wx+.91,2.73,-.34,.78],[wx+.99,3.09,-.39,.43],[wx+.88,3.28,-.36,.20],[wx+1.01,3.57,-.39,.035]],.105,world,{twist:.6});
 branch([[wx-1.55,3.90,-.61,1],[wx-1.64,4.28,-.48,.75],[wx-1.46,4.51,-.43,.43],[wx-1.53,4.81,-.46,.035]],.09,world,{twist:-.5});
 branch([[wx+.65,4.30,-.45,1],[wx+.99,4.33,-.33,.71],[wx+1.22,4.56,-.40,.43],[wx+1.48,4.50,-.41,.035]],.085,world,{twist:.3});
 // An exposed return root bridges above the toe and leaves a dark open pocket.
 branch([[wx-.72,1.06,.43,1],[wx-1.13,1.35,.62,1.16],[wx-1.51,1.25,.88,.92],[wx-1.71,.85,1.06,.68],[wx-1.69,.42,1.30,.54],[wx-1.92,.17,1.51,.35]],.16,world,{twist:.3});
 branch([[wx+1.15,2.49,-.34,1],[wx+1.45,2.29,-.16,.84],[wx+1.53,1.95,-.06,.53],[wx+1.82,1.77,-.10,.28],[wx+2.06,1.82,-.14,.035]],.095,world,{twist:-.2});
 // Two short, uneven fracture ends interrupt the otherwise fine taper.
 branch([[wx-.62,1.48,.29,1],[wx-.98,1.82,.46,.89],[wx-1.13,2.18,.49,.58]],.14,world,{broken:true,twist:.3});
 branch([[wx-.45,5.09,-.59,1],[wx-.73,5.45,-.51,.79],[wx-.75,5.69,-.49,.40]],.08,world,{broken:true,twist:-.3});
 mossPatch(wx-.3,3.8,-.24,1.1);mossPatch(wx+.7,2.55,-.25,1.7,.12);mossPatch(wx-.6,1.4,.25,.8);mossPatch(wx-.4,5.3,-.6,.65);mossPatch(wx-1,.3,1.2,1.4);
 }
 const baseWoodNodes=world.children.slice(woodStart),rockStart=world.children.length;
 // Layered slate rather than smooth boulders.
 const rx=visibleWidth*.25;
 if(assets.decor==='none'){if(assets.rock==='slate')rockStack(rx,-.3,1.35);
 else if(assets.rock==='river'){contact(rx,-.3,2.1,1.4,.25);const boulder=mesh(new THREE.DodecahedronGeometry(1,0),material(0x81908a),rx,1.05,-.3);boulder.userData.solid=true;boulder.scale.set(1.95,1.12,1.3);boulder.rotation.set(.1,.28,-.13);const foot=mesh(new THREE.DodecahedronGeometry(1,0),material(0x637772),rx-1.3,.43,.55);foot.userData.solid=true;foot.scale.set(.8,.36,.65);}}

 if(assets.decor==='none'&&assets.rock!=='moss')mossPatch(rx-.2,assets.rock==='slate'?2.09:2.06,-.45,1.1);
 const baseRockNodes=world.children.slice(rockStart);
 plant(rx+.5,-1.8,2.7,true,18);plant(rx+1.8,1.4,1.3,false,22);plant(wx-1.65,1.5,1.45,false,8);plant(wx+1.2,.6,1.05,false,12);
 for(let i=bedContentsStart;i<world.children.length;i++)if(!world.children[i].userData.substratePlant)world.children[i].position.y+=bedLevel-.12;
 if(assets.decor==='skull-castle')makeSkullCastle(rx,bedLevel,-.3);if(assets.decor==='tetrapods')makeWaveBreakCluster(rx,bedLevel,-.3);
 const metricBasic=basicEquipment=AquariumMetricBasicArt.create(THREE,{tankHalf,cmPerUnit,backZ:outerBack,frontZ,waterLevel,bedLevel,rimY:8.4});
 prepareEquipment(metricBasic);
 const filter=metricBasic.wetGroup.getObjectByName('sponge-filter'),heater=metricBasic.wetGroup.getObjectByName('aquarium-heater');
 filter.visible=heater.visible=metricBasic.dryGroup.visible=sceneStyle==='basic';
 world.add(metricBasic.wetGroup);if(sceneStyle==='basic')world.add(metricBasic.dryGroup);
 const basicWetMaterials=new Set();metricBasic.wetGroup.traverse(o=>{if(o.isMesh)basicWetMaterials.add(o.material);});
 for(const m of metricBasic.materials){if(basicWetMaterials.has(m))m.clippingPlanes=tankClip;mats.push(m);}geometries.push(...metricBasic.geometries);maps.push(...metricBasic.maps);
 filterOutlet=metricBasic.filterOutlet;const fz=filterOutlet.z;
 // Water, side panes and substrate terminate at the same glass boundaries.
 const waterClip=[...tankClip,new THREE.Plane(new THREE.Vector3(0,0,1),-backBound)];
 const surfaceCanvas=document.createElement('canvas');surfaceCanvas.width=512;surfaceCanvas.height=128;
 const surfaceContext=surfaceCanvas.getContext('2d'),surfacePixels=surfaceContext.createImageData(512,128);
 for(let y=0;y<128;y++)for(let x=0;x<512;x++){
  const wx=((x+.5)/512-.5)*tankHalf*2,wz=backBound+(y+.5)/128*innerDepth;
  const lightX=(wx+visibleWidth*.12)/(visibleWidth*.34),lightZ=(wz-1.6)/2.5;
  const reflection=Math.max(0,1-lightX*lightX)*Math.max(0,1-lightZ*lightZ);
  const bend=Math.sin(wx*.63+wz*.4)*.045+Math.sin(wx*1.7-.6)*.012;
  const crest=Math.pow(Math.max(0,Math.cos((wz+bend)*10.5)),28);
  const broken=.3+.7*Math.pow(.5+.5*Math.sin(wx*1.14+wz*.8),2);
  const alpha=.045+reflection*crest*broken*.14,index=(y*512+x)*4;
  surfacePixels.data[index]=surfacePixels.data[index+1]=surfacePixels.data[index+2]=255;surfacePixels.data[index+3]=Math.round(alpha*255);
 }
 surfaceContext.putImageData(surfacePixels,0,0);
 const surfaceMap=new THREE.CanvasTexture(surfaceCanvas);surfaceMap.colorSpace=THREE.SRGBColorSpace;surfaceMap.minFilter=surfaceMap.magFilter=THREE.NearestFilter;surfaceMap.generateMipmaps=false;surfaceMap.wrapS=surfaceMap.wrapT=THREE.RepeatWrapping;maps.push(surfaceMap);
 const surfaceMaterial=basic(0xb4c3b8,{map:surfaceMap,transparent:true,depthWrite:false,side:THREE.DoubleSide});surfaceMaterial.clippingPlanes=waterClip;
 waterSurface=mesh(new THREE.PlaneGeometry(innerHalf*2,innerDepth,64,24),surfaceMaterial,0,waterLevel,centerZ);waterSurface.rotation.x=-Math.PI/2;waterSurface.name='water-surface';
 surfaceStudy=AquariumWaterSurface.create(THREE,{mesh:waterSurface,halfWidth:innerHalf,backZ:backBound,frontZ:frontBound,centerZ,level:waterLevel,clippingPlanes:waterClip});surfaceStudy.setMode(surfaceMode);world.add(surfaceStudy.group);geometries.push(...surfaceStudy.geometries);mats.push(...surfaceStudy.materials);
 const meniscusMaterial=basic(0xffffff,{transparent:true,opacity:.2,depthWrite:false,side:THREE.DoubleSide});meniscusMaterial.color=surfaceMaterial.color;meniscusMaterial.clippingPlanes=waterClip;meniscusMaterial.name='water-meniscus';
 for(const z of [backBound+.001,frontBound-.001])mesh(new THREE.PlaneGeometry(tankHalf*2,.026),meniscusMaterial,0,waterLevel-.013,z);
 for(const sign of [-1,1]){const edge=mesh(new THREE.PlaneGeometry(innerDepth,.026),meniscusMaterial,sign*(innerHalf-.001),waterLevel-.013,centerZ);edge.rotation.y=Math.PI/2;}
 // The visible LED assembly stays in the top strip, attached to the implied tank rim.
 const lampY=9.36,lampWidth=metric.toWorld(60),lampDepth=metric.toWorld(14),lampHeight=metric.toWorld(1.8);
 const lamp=new THREE.Group();lamp.name='aquarium-light-fixture';lamp.position.set(0,lampY,centerZ);world.add(lamp);
 const lampShell=material(sceneStyle==='lush'?0x161d20:0x263238),lampCap=material(0x172329),lampFin=material(sceneStyle==='lush'?0x687677:0x3b494e),lampTop=basic(0x46575d),lampBoard=basic(0x17272b);
 lampTop.name='lamp-top-room-response';lampTop.userData.roomOnly=true;lampBoard.userData.roomOnly=true;lampSpan=lampWidth*.36;
 const lampHalf=lampWidth*.5,lampCore=lampWidth-.48;
 box(lampCore,.28,2.14,lampShell,0,.015,0,lamp);
 // The broad flat heat spreader is also the accepted shelf: top 9.545, depth 2.15.
 box(lampCore,.03,2.15,lampTop,0,.17,0,lamp);
 for(const side of [-1,1]){
  box(lampCore,.085,.15,lampShell,0,-.1425,side*1.025,lamp);
  for(const y of [-.075,.015,.105])box(lampCore,.018,.04,lampFin,0,y,side*1.08,lamp);
 }
 box(lampWidth-.60,.02,1.73,lampBoard,0,-.143,0,lamp);
 // Molded caps close the extrusion; the small seam and fastener belong to the cap.
 const capProfile=new THREE.Shape();
 [[-1.045,-.185],[1.045,-.185],[1.1,-.13],[1.1,.13],[1.045,.185],[-1.045,.185],[-1.1,.13],[-1.1,-.13]].forEach(([z,y],i)=>i?capProfile.lineTo(z,y):capProfile.moveTo(z,y));capProfile.closePath();
 for(const sign of [-1,1]){
  const capGeometry=new THREE.ExtrudeGeometry(capProfile,{depth:.26,steps:1,bevelEnabled:false});capGeometry.rotateY(Math.PI/2);
  mesh(capGeometry,lampCap,sign<0?-lampHalf:lampHalf-.26,0,0,lamp);
  box(.018,.31,2.16,M.rubber,sign*(lampHalf-.259),0,0,lamp);
  cylinder([sign*(lampHalf-.13),-.025,1.075],[sign*(lampHalf-.13),-.025,1.102],.034,.034,M.metal,lamp,8);
 }
 if(sceneStyle==='lush'){
  const lenses=[[-.62,0xd6e5da],[-.20,0x52739d],[.20,0x9ba98b],[.62,0xba7373]].map(([row,color])=>[row,basic(color)]);
  for(let i=0;i<24;i++)for(const [row,diode]of lenses){
   box(.11,.014,.07,diode,(i/23-.5)*(lampWidth-.9),-.165,row,lamp);
  }
 }
 const housingParts=lamp.children.slice();
 // Paired sliding wire arms turn down into one padded saddle on each glass rim.
 for(const sign of [-1,1]){
  const railX=sign*(lampWidth*.5-.25),footX=sign*(tankHalf-.055);
  for(const z of [-.76,.76]){
   box(.44,.09,.16,lampCap,railX-sign*.17,-.145,z,lamp);
   cylinder([railX-sign*.35,-.145,z],[railX,-.145,z],.032,.032,M.metal,lamp,6);
   cylinder([railX,-.145,z],[footX,8.50-lampY,z],.032,.032,M.metal,lamp,6);
  }
  cylinder([footX,8.50-lampY,-.76],[footX,8.50-lampY,.76],.035,.035,M.metal,lamp,6);
  box(.20,.11,1.86,lampCap,footX,8.445-lampY,0,lamp);
 }
 // A bank is one lens cluster and one downward source. Additional banks spread the same peak illumination.
 for(let bank=0;bank<5;bank++){
  const group=new THREE.Group();group.name='tank-led-bank-'+bank;lamp.add(group);const emitters=basic(0xe5eed1);
  for(const x of [-.26,0,.26]){
   for(const z of [-.55,.55])box(.16,.016,.20,emitters,x,-.161,z,group);
   box(.20,.025,.012,emitters,x,-.167,1.10,group);
  }
  batchStatic(group);group.children[0].name='tank-led-emitter';lampEmitters.push(group.children[0]);
 }
 // Housing dimensions follow the measured fixture; mounting arms retain their rim positions.
 const housingDepthScale=lampDepth/2.2,housingHeightScale=lampHeight/.37;
 const housing=new THREE.Group();housing.name='metric-led-housing';lamp.add(housing);
 for(const part of housingParts)housing.add(part);
 housing.scale.set(1,housingHeightScale,housingDepthScale);
 housing.updateWorldMatrix(true,true);const housingBounds=new THREE.Box3().setFromObject(housing).getSize(new THREE.Vector3()).multiplyScalar(cmPerUnit);
 housing.userData.physical={measuredCm:housingBounds.toArray()};
 for(const part of lamp.children)if(part.name.startsWith('tank-led-bank-'))part.scale.set(1,housingHeightScale,housingDepthScale);
 const leadX=lampHalf-.15,rearLocal=outerBack-centerZ-.25;
 const lead=[[leadX,0,-lampDepth*.5],[leadX-.02,-.035,-lampDepth*.5-.35],[leadX-.08,-.11,rearLocal+.55],[leadX-.18,-.26,rearLocal],[leadX-.30,-.49,rearLocal-.05],[leadX-.34,-.85,rearLocal-.05],[leadX-.34,-1.50,rearLocal-.05]];
 for(let i=1;i<lead.length;i++)cylinder(lead[i-1],lead[i],metric.toWorld(.22),metric.toWorld(.22),M.rubber,lamp,6);
 lamp.userData.powerEnd=[...lead[lead.length-1]];
 lamp.userData.physical={widthCm:60,depthCm:14,heightCm:1.8,definition:'housing; mounting hardware separately authored',measuredCm:housingBounds.toArray()};
 batchStatic(lamp,true,new Set(lampEmitters));
 foodJar=makeFoodJar();
 // Broad subtle light pools sit on and recede along the real floor.
 for(const x of [-visibleWidth*.27,0,visibleWidth*.27]){const o=mesh(new THREE.CircleGeometry(1,24),basic(0xb5c29b,{transparent:true,opacity:.065,depthWrite:false}),x,bedLevel+.055,1.2);o.rotation.x=-Math.PI/2;o.scale.set(3.0,3.6,1);lightPools.push(o);}
 // Same authored pixel animals as A, anchored within the actual depth-buffered scene.
 animalFrames={shrimp:Object.fromEntries(['red','red-rili','red-white','yellow','blue','orange','amano','blue-dream','green-jade','yellow-goldenback','crystal-black','orange-rili'].map(color=>[color,spriteFrames('shrimp',color)])),fish:spriteFrames('fish',assets.fish),otocinclus:spriteFrames('otocinclus'),snail:spriteFrames('snail','assassin'),nerite:spriteFrames('snail','nerite')};
 const animalSpan=tankHalf*2-.6,animalFront=AquariumMetricScale.tank.frontBound-.005;
 if(retained)restoreAnimalBindings(retained.actors);
 else if(!restoringTank){
 animal('shrimp',-animalSpan*.32,bedLevel+.12,3.5,1,0,1);animal('shrimp',-.6,bedLevel+.12,animalFront-.15,1,1,-1);animal('shrimp',animalSpan*.18,bedLevel+.12,2.3,1,2,1);animal('shrimp',animalSpan*.36,bedLevel+.12,3.7,1,3,-1);
 animal('snail',-animalSpan*.06,bedLevel+.12,3.2,1,0,1);animal('snail',animalSpan*.14,bedLevel+1.25,animalFront,1,1,1,'nerite');
 for(let i=0;i<8;i++)animal('fish',-animalSpan*.30+i*animalSpan*.085,3.6+(i%3)*.65,-1.4+(i%4)*1.2,1,i*.8,1);
 for(let i=4;i<12;i++)animal('shrimp',animalSpan*(-.38+(i-4)*.103),bedLevel+.12,1.4+(i%3)*.85,1,i,i%2?1:-1);
 for(let i=0;i<3;i++)animal('fish',animalSpan*(-.27+i*.27),2.0+i*1.6,animalFront,1,i,1,'otocinclus');
 }
 const bubbleCanvas=document.createElement('canvas');bubbleCanvas.width=bubbleCanvas.height=16;const bubblePixels=bubbleCanvas.getContext('2d');
 for(let y=0;y<16;y++)for(let x=0;x<16;x++){
  const dx=(x-7.5)/7,dy=(y-7.5)/7,r=dx*dx+dy*dy;if(r>1)continue;
  bubblePixels.fillStyle=r>.65?(x+y<13?'rgba(211,238,224,.88)':'rgba(132,190,188,.56)'):'rgba(163,209,204,.08)';bubblePixels.fillRect(x,y,1,1);
 }
 const bubbleMap=new THREE.CanvasTexture(bubbleCanvas);bubbleMap.colorSpace=THREE.SRGBColorSpace;bubbleMap.magFilter=bubbleMap.minFilter=THREE.NearestFilter;bubbleMap.generateMipmaps=false;maps.push(bubbleMap);
 const bubbleMaterial=basic(0xc2e1db,{map:bubbleMap,transparent:true,opacity:.82,alphaTest:.015,depthWrite:false,side:THREE.DoubleSide});
 const sizes=[.044,.058,.035,.071,.052,.063,.032,.048],phases=[0,.19,.47,.56,.91,1.23,1.48,1.86];
 for(let i=0;i<sizes.length;i++){
  const radius=sizes[i],riseSpeed=.25+radius*1.4+(i%3)*.017,o=mesh(new THREE.PlaneGeometry(radius*2,radius*2),bubbleMaterial,filterOutlet.x,filterOutlet.y,fz);
  o.name='filter-bubble';o.userData={radius,riseSpeed,phase:phases[i]};o.quaternion.copy(camera.quaternion);bubbles.push({o,i,radius,riseSpeed,phase:phases[i],x:filterOutlet.x,z:fz});
 }

 if(!restoringTank&&!retained)for(const child of breeding.offspring)spawnYoung(child);
 // Foreground plants enter from the monitor edges instead of enclosing a miniature tank.
 plant(-visibleWidth*.44,3.6,2.4,true,27);plant(visibleWidth*.44,3.7,1.9,true,31);plant(visibleWidth*.04,3.5,.65,false,43);
 if(sceneStyle!=='basic')for(const [i,[x,z,height]]of [[-.37,-1.45,6.9],[-.30,-1.25,5.6],[-.20,-1.65,6.6],[.12,-1.65,5.0],[.32,-1.35,6.8],[.39,-.95,5.8]].entries()){const g=plant(visibleWidth*x,z,height,false,701+i*19);g.name='tall-background-'+i;}
 const glass=basic(0x527e86,{depthTest:false,depthWrite:false}),highlight=basic(0x8baaa7,{depthTest:false,depthWrite:false});glass.clippingPlanes=[];highlight.clippingPlanes=[];glass.name='front-glass-edges';highlight.name='glass-polished-edges';
 const innerGlass=basic(0x86b4b0,{transparent:true,opacity:.23,depthWrite:false,depthTest:true});innerGlass.clippingPlanes=[];innerGlass.name='glass-inner-returns';
 // Six-millimeter glass, with rear seams occluded by objects inside the tank.
 const thickness=metric.tank.glass;
 for(const sign of [-1,1]){
  const x=sign*(tankHalf-thickness/2);
  box(thickness,8.4,thickness,glass,x,4.2,frontZ-thickness/2).renderOrder=20;
  box(.012,8.4,.012,highlight,x-sign*thickness*.25,4.2,frontZ-.005).renderOrder=21;
  box(thickness,thickness,8.4,glass,x,8.4-thickness/2,centerZ).renderOrder=20;
  box(.012,.012,8.4-.02,highlight,x,8.395,centerZ).renderOrder=21;
  box(.012,8.4-bedLevel,.012,innerGlass,sign*innerHalf,(8.4+bedLevel)*.5,frontBound).renderOrder=19;
 }
 box(tankHalf*2,thickness,thickness,glass,0,thickness/2,frontZ-thickness/2).renderOrder=20;
 box(tankHalf*2-.02,.012,.012,highlight,0,thickness+.006,frontZ-.005).renderOrder=21;
 box(tankHalf*2,thickness,thickness,glass,0,8.4-thickness/2,frontZ-thickness/2).renderOrder=20;
 box(tankHalf*2-.02,.014,.015,highlight,0,8.395,frontZ-.005).renderOrder=21;
 const rearGlass=basic(0x72999d,{depthWrite:true,depthTest:true});rearGlass.clippingPlanes=[];rearGlass.name='rear-glass-seams';
 for(const sign of [-1,1])box(thickness,8.4-bedLevel,thickness,rearGlass,sign*(tankHalf-thickness/2),(8.4+bedLevel)*.5,outerBack+thickness/2).renderOrder=19;
 const rearTopMaterial=basic(0x8baaa7,{depthWrite:true,depthTest:true});rearTopMaterial.clippingPlanes=[];rearTopMaterial.name='rear-glass-top-edge';
 box(tankHalf*2,thickness,thickness,rearTopMaterial,0,8.4-thickness/2,outerBack+thickness/2);
 if(assets.rock==='moss'&&assets.decor==='none'){
  mossFormation=AquariumMossRockArt.create(THREE,{seed:421,growth:.9});mossFormation.group.position.set(rx,bedLevel,-.2);world.add(mossFormation.group);for(const m of mossFormation.materials)rememberMaterial(m);geometries.push(...mossFormation.geometries);maps.push(...mossFormation.maps);
 }
 for(const [index,[x,z,growth]]of [[-visibleWidth*.18,2.0,1],[visibleWidth*.12,2.8,.65]].entries()){
  const asset=AquariumAnubiasArt.create(THREE,{seed:913+index*17,growth});asset.group.position.set(x,bedLevel+.01,z);asset.group.userData.substratePlant=true;world.add(asset.group);
  for(const material of asset.materials)rememberMaterial(material);geometries.push(...asset.geometries);maps.push(...asset.maps);plants.push({g:asset.group,phase:index,sway:false});
 }
 if(sceneStyle!=='basic'&&assets.decor==='none'){
  world.updateMatrixWorld(true);const rocks=[];world.traverse(o=>{if(o.isMesh&&((Array.isArray(o.material)?o.material:[o.material]).some(m=>m===M.slateTop||m===M.slateSide)||o.userData.solid)&&!o.userData.equipmentSolid)rocks.push(o);});
  const ray=new THREE.Raycaster();for(const [i,dx]of [-.45,.35].entries()){
   ray.set(new THREE.Vector3(rx+dx,waterLevel,-.3),new THREE.Vector3(0,-1,0));const hit=ray.intersectObjects(rocks,false).find(h=>h.point.y>bedLevel+.5&&h.face.normal.y>.3);if(!hit)continue;
   const a=AquariumAnubiasArt.create(THREE,{seed:1101+i,growth:i?.65:.85});a.group.position.copy(hit.point);a.group.position.y+=.01;a.group.name='rock-mounted-anubias-'+i;world.add(a.group);for(const m of a.materials)rememberMaterial(m);geometries.push(...a.geometries);maps.push(...a.maps);plants.push({g:a.group,phase:i,sway:false});
  }
 }
 equipmentConnectionOptions={tankHalf,cmPerUnit,backZ:outerBack,wallGap:3,premium:sceneStyle!=='basic',hob:sceneStyle==='waterfall',ledEnd:lamp.localToWorld(new THREE.Vector3(...lamp.userData.powerEnd)).toArray()};
 const hookups=equipmentConnections=AquariumMetricConnections.create(THREE,{...equipmentConnectionOptions,heaterEnd:metricBasic.heaterEnd,airlineEnd:metricBasic.airlineEnd});
 if(sceneStyle==='lush'){
  filter.visible=heater.visible=false;for(const bubble of bubbles)bubble.o.visible=false;
  premiumEquipment=AquariumMetricEquipmentArt.create(THREE,{tankHalf,cmPerUnit,backZ:outerBack,frontZ,waterLevel,bedLevel,rimY:8.4,stripPlug:{filter:hookups.group.getObjectByName('heater-plug').position.toArray(),co2:hookups.group.getObjectByName('pump-plug').position.toArray()}});
  chromeFinish=AquariumMetalFinish.create(THREE,document);premiumEquipment.dryGroup.traverse(o=>{if(o.isMesh&&o.material.name==='premium-dry-metal')o.material=chromeFinish.material;});premiumEquipment.materials.push(chromeFinish.material);premiumEquipment.maps.push(chromeFinish.map);
  world.add(premiumEquipment.wetGroup);const wetMaterials=new Set();premiumEquipment.wetGroup.traverse(o=>{if(o.isMesh)wetMaterials.add(o.material);});for(const m of premiumEquipment.materials){if(wetMaterials.has(m))m.clippingPlanes=tankClip;mats.push(m);}geometries.push(...premiumEquipment.geometries);maps.push(...premiumEquipment.maps);
  const mistGeometry=new THREE.PlaneGeometry(.025,.025),mistMaterial=basic(0xb3cfc2,{map:bubbleMap,transparent:true,opacity:.30,depthWrite:false,side:THREE.DoubleSide});geometries.push(mistGeometry);
  for(let i=0;i<18;i++){const o=new THREE.Mesh(mistGeometry,mistMaterial);o.name='co2-fine-mist';o.visible=false;world.add(o);co2Mist.push({o,phase:i*.137});}
 }
 if(sceneStyle==='waterfall'){
  filter.visible=heater.visible=false;for(const b of bubbles)b.o.visible=false;
  hangOnFilter=AquariumHangOnFilterArt.create(THREE,{tankHalf,cmPerUnit,backZ:outerBack,waterLevel,rimY:8.4,stripPlug:hookups.group.getObjectByName('heater-plug').position.toArray()});world.add(hangOnFilter.wetGroup);const wet=new Set();hangOnFilter.wetGroup.traverse(o=>{if(o.isMesh){wet.add(o.material);o.userData.equipmentSolid=true;}});for(const m of hangOnFilter.materials){if(wet.has(m))m.clippingPlanes=tankClip;mats.push(m);}geometries.push(...hangOnFilter.geometries);maps.push(...hangOnFilter.maps);
 }
 if(premiumEquipment)premiumEquipment.wetGroup.traverse(o=>{if(o.isMesh)o.userData.equipmentSolid=true;});
 if(assets.plants==='varied')for(const [i,[species,x,z,growth]]of [['vallisneria',-.12,-1.45,1],['vallisneria',.12,-1.45,.91],['alternanthera',.13,1.65,1],['alternanthera',-.10,1.6,.75]].entries()){
  const a=AquariumPlantVarieties.create(THREE,{species,seed:913+i*27,growth});a.group.position.set(visibleWidth*x,bedLevel,z);world.add(a.group);for(const m of a.materials)rememberMaterial(m);geometries.push(...a.geometries);maps.push(...a.maps);variedPlants.push(a);plants.push({g:a.group,phase:i,sway:false});
 }
 resolvePlantClearance();
 presetAssemblies=AquariumPresetAssemblies.create(THREE,{world,cmPerUnit,centerZ});
 for(const [i,p]of plants.entries())if(p.g.parent===world)presetAssemblies.add({id:'base-plant-'+i,assetId:['vallisneria','alternanthera'].includes(p.g.userData.species)?p.g.userData.species:(p.g.name.startsWith('rock-mounted-')?'anubias':p.sway===false?'anubias':'classic-stem'),objects:[p.g],anchor:p.g.position.clone()});
 if(baseWoodNodes.length)presetAssemblies.add({id:'base-wood',assetId:assets.wood==='manzanita'?'manzanita':'pixel-driftwood',objects:baseWoodNodes,anchor:{x:wx,y:bedLevel,z:.35}});
 const rockNodes=mossFormation?[mossFormation.group]:baseRockNodes;
 if(rockNodes.length)presetAssemblies.add({id:'base-rock',assetId:assets.rock+'-rock',objects:rockNodes,anchor:{x:rx,y:bedLevel,z:-.3}});
 collisionWorld=AquariumCollisions.createWorld(THREE,{floorY:bedLevel+.045,halfWidth:innerHalf,backZ:backBound,frontZ:frontBound,glassInset:.004});
 metricBasic.dryGroup.removeFromParent();
 captureBaselineCollisions();
 if(assets.plants==='botanical'||AquariumBotanicalLayout.species.includes(assets.plants)){
  botanicalArt=AquariumBotanicalLayout.create(THREE,{choice:assets.plants,factories:{floating:AquariumFloatingPlantsV2,epiphyte:AquariumEpiphytePlantsV2,rooted:AquariumRootedPlantsV2},halfWidth:innerHalf,backZ:backBound,frontZ:frontBound,bedLevel,waterLevel,cmPerUnit,solids:collisionWorld.meshes,mountSolids:collisionWorld.meshes.filter(o=>o.userData.hardscape&&!o.userData.equipmentSolid)});
  world.add(botanicalArt.group);for(const m of botanicalArt.materials)rememberMaterial(m);geometries.push(...botanicalArt.geometries);maps.push(...botanicalArt.maps);botanicalArt.group.traverse(o=>{if(o.isMesh){o.castShadow=true;o.receiveShadow=true;}});
 }

 waterCondition=makeWaterCondition({solids:collisionWorld.meshes.filter(mesh=>mesh.userData.hardscape),level:conditionLevel});
 if(sceneStyle!=='basic'){
  const exclusions=collisionWorld.meshes.filter(o=>o.geometry.boundingBox?.min.y<bedLevel+.4).map(o=>new THREE.Box3().setFromObject(o).expandByScalar(.06));
  lushPlants=AquariumLushPlants.create(THREE,{tankHalf:innerHalf,backZ:backBound,frontZ:frontBound,bedLevel,waterLevel,exclusions,includeGrass:false});world.add(lushPlants.group);for(const m of lushPlants.materials)rememberMaterial(m);geometries.push(...lushPlants.geometries);maps.push(...lushPlants.maps);
  carpetArt=AquariumCarpetArt.create(THREE,{tankHalf:innerHalf,backZ:backBound,frontZ:frontBound,bedLevel,waterLevel,exclusions});world.add(carpetArt.group);for(const m of carpetArt.materials)rememberMaterial(m);geometries.push(...carpetArt.geometries);maps.push(...carpetArt.maps);
 }
 initializeDesignerPlacement();
 rebuildSurfaceNavigation(!restoringTank&&!retained);
 const currentSource=premiumEquipment?.returnPoint||hangOnFilter?.returnPoint||filterOutlet;flowField=AquariumFlowField.create({halfWidth:innerHalf,backZ:backBound,frontZ:frontBound,bedLevel,waterLevel,source:currentSource,direction:hangOnFilter?{x:0,y:0,z:1}:premiumEquipment?{x:1,y:0,z:.3}:{x:-1,y:0,z:0},output:pumpOutput});surfaceStudy.setFlowField(flowField);
 buildBreedingSupports();ecologyVisuals=makeEcologyVisuals();if(retained){restoreFoodBindings(retained.food);drawEcologyDetails(0,[...fish,...shrimps,...snails],false);}else updateEcology(0);
 world.updateMatrixWorld(true);
 const boundsOf=o=>{const b=new THREE.Box3().setFromObject(o),d=b.getSize(new THREE.Vector3());return{width:+(d.x*cmPerUnit).toFixed(2),height:+(d.y*cmPerUnit).toFixed(2),depth:+(d.z*cmPerUnit).toFixed(2)};};
 physicalParts=world.children.filter(o=>o.name||o.userData.substratePlant||o.userData.solid||o.userData.hardscape).filter(o=>!o.userData.animalKind).map(o=>({part:o.name||'authored-hardscape-or-plant',dimensionsCm:boundsOf(o),basis:o.userData.physical?.definition||'rendered envelope; authored dimensions unless reference specified'}));
 physicalParts.push({part:'LED housing',dimensionsCm:{width:60,depth:14,height:1.8},measuredCm:housingBounds.toArray(),basis:'WRGB II Pro60 manufacturer housing dimensions; arms separately authored'},{part:'substrate grains',diameterMm:[2,4],basis:'selected aquarium gravel grade'},{part:'food pellet',diameterMm:3.09,basis:'authored 0.036-world radius'},{part:'CO2 mist',diameterMm:1.07,basis:'authored review-visible particle'},{part:'medaka egg',diameterMm:2.14,basis:'authored review-visible egg'});
 const moving=new Set([...fish,...shrimps,...snails].map(a=>a.o));for(const bubble of bubbles)moving.add(bubble.o);for(const bubble of co2Mist)moving.add(bubble.o);moving.add(ecologyVisuals.group);batchStatic(world,false,moving);
 roomArt=AquariumRoomArt.create(THREE,{tankHalf,frontZ,backZ:outerBack,wallGap:3});roomArt.group.name='aquarium-room';roomArt.setFinish(roomFinish);scene.add(roomArt.group);
 roomArt.group.add(metricBasic.dryGroup);roomArt.group.add(hookups.group);roomArt.geometries.push(...hookups.geometries);roomArt.materials.push(...hookups.materials);roomArt.maps.push(...hookups.maps);if(premiumEquipment)roomArt.group.add(premiumEquipment.dryGroup);if(hangOnFilter)roomArt.group.add(hangOnFilter.dryGroup);

 configureTankLights();
 applyLighting();applyCamera();render();
}
function applyCamera(){
 const framing=metric.camera(camera.aspect);eyeHeight=framing.eyeHeight;eyeDepth=framing.eyeDepth;matchedFov=framing.fov;
 camera.fov=matchedFov;camera.position.set(0,eyeHeight,eyeDepth);camera.lookAt(0,eyeHeight,0);camera.updateProjectionMatrix();
 camera.projectionMatrix.elements[9]=2*horizon-1;
 camera.projectionMatrixInverse.copy(camera.projectionMatrix).invert();camera.updateMatrixWorld();
 for(const a of [...fish,...shrimps,...snails]){if(a.surfaceMotion?.surface==='glass')orientGlassAnimal(a);else{a.o.quaternion.copy(camera.quaternion);if(!a.life.alive&&a.corpseId)a.o.rotateZ(Math.PI);}}
}
function setView(_next){view='front';applyCamera();render();}
function resize(){
 const aspect=Math.max(1,innerWidth)/Math.max(1,innerHeight);
 camera.aspect=aspect;camera.updateProjectionMatrix();
 const pixelWidth=Math.max(280,Math.min(1200,Math.round(aspect*216)));

 const resolution=Math.min(1,rasterHeight/Math.max(1,innerHeight));renderer.setSize(Math.max(1,Math.round(innerWidth*resolution)),Math.max(1,Math.round(innerHeight*resolution)),false);
 if(!backdrop)build();else{applyCamera();render();}
}
function setSceneStyle(next){if(!['basic','lush','waterfall'].includes(next)||next===sceneStyle)return;sceneStyle=next;build();}
function setPumpOutput(value){if(!Number.isFinite(value))return;pumpOutput=THREE.MathUtils.clamp(value,0,1.5);flowField?.setOutput(pumpOutput);const sheet=hangOnFilter?.wetGroup.getObjectByName('filter-waterfall-sheet');if(sheet)sheet.visible=pumpOutput>0;render();}
function setSurfaceMode(next){if(!['calm','current','lively'].includes(next))return;surfaceMode=next;surfaceStudy?.setMode(next);surfaceStudy?.update(clock);render();}
function setConditionMode(next){if(!['auto','manual','ecosystem'].includes(next)||next===conditionMode)return;conditionMode=next;conditionEpoch=clock;conditionStart=conditionLevel;}
function setCondition(value){conditionMode='manual';if(!Number.isFinite(value))return;conditionLevel=THREE.MathUtils.clamp(value,0,1);waterCondition.setLevel(conditionLevel);updateWaterTransmission();render();}
function setResolution(next){if(![648,864,1080].includes(next)||next===rasterHeight)return;rasterHeight=next;resize();}
function setFraming(_next){framing='whole';resize();}

function setMode(next){if(!['desktop','saver'].includes(next))return;mode=next;if(foodJar)foodJar.visible=true;document.getElementById('hint').hidden=designerActive||mode!=='desktop';renderer.domElement.style.cursor='default';render();}
function feed(options={}){
 const automatic=options.automatic===true;if(!automatic&&(designerActive||mode!=='desktop'))return;
 if(automatic)automaticFeedCount++;else manualFeedCount++;lastFeedReason=automatic?'automatic':'manual';nextFeedDue=clock+24;
 for(const p of pellets){ecology.retireFood(p.food.id);world.remove(p.o);}pellets=[];feedStarted=clock;feedSequence++;
 if(!pelletMaterial){pelletMaterial=material(0xc49a61);pelletGeometry=new THREE.OctahedronGeometry(.036,0);geometries.push(pelletGeometry);}
 for(let i=0;i<10;i++){const o=new THREE.Mesh(pelletGeometry,pelletMaterial);const x=-visibleWidth*.29+(i%4-1.5)*.28,z=-.85+Math.floor(i/4)*.75;o.position.set(x,waterLevel+.08,z);o.name='food-pellet';world.add(o);const food=ecology.addFood({id:'feed-'+feedSequence+'-'+i,position:o.position,amount:.10});pellets.push({o,food,velocity:new THREE.Vector3(Math.sin(i*1.8)*.025,-.85,Math.cos(i*1.7)*.02),delay:i*.06,lastT:0,settled:false});}
 render();parent.postMessage({type:'aquarium-fed',scene:'b',sequence:feedSequence,reason:lastFeedReason},'*');
}
const raycaster=new THREE.Raycaster(),pointer=new THREE.Vector2();
function hitJar(event){if(designerActive||mode!=='desktop'||!foodJar)return false;const rect=renderer.domElement.getBoundingClientRect();pointer.set((event.clientX-rect.left)/rect.width*2-1,-(event.clientY-rect.top)/rect.height*2+1);raycaster.setFromCamera(pointer,camera);return raycaster.intersectObjects(foodJar.children,true).length>0;}
renderer.domElement.addEventListener('pointermove',event=>{renderer.domElement.style.cursor=designerActive?designerTool==='select'?'pointer':'crosshair':hitJar(event)?'pointer':'default';});
renderer.domElement.addEventListener('pointerdown',event=>{if(designerActive){pickDesigner(event);return;}if(hitJar(event))feed();});
function clearDesignerPlacement(){
 designerRuntime?.dispose();designerRuntime=null;baselineCollisionMeshes=[];designerSolidSignature='';designerLayoutSignature='';designerStatusSignature='';
 if(designerSelection){designerSelection.removeFromParent();designerSelection.geometry.dispose();designerSelection.material.dispose();designerSelection=null;}
}
function designerState(){return{active:designerActive,layout:designerLayout?JSON.parse(JSON.stringify(designerLayout)):null,status:designerRuntime?.status||[],selectedId:designerSelectedId,tool:designerTool,selectionScope:designerSelectionScope,assetId:designerAssetId,navigationError:designerNavigationError};}
function replyDesigner(error){
 const reply={type:'aquarium-designer-state',requestId:designerRequestId,status:designerRuntime?.status||[],selectedId:designerSelectedId};if(error)reply.error=error;
 designerStatusSignature=JSON.stringify(reply.status);parent.postMessage(reply,'*');return reply;
}
function refreshDesignerSelection(){
 if(!designerActive||!designerRuntime)return;
 if(!designerSelection){designerSelection=new THREE.Box3Helper(new THREE.Box3(),0xf1cf72);designerSelection.name='designer-selection';designerSelection.material.depthTest=false;designerSelection.material.transparent=true;designerSelection.material.opacity=.8;designerSelection.renderOrder=10;scene.add(designerSelection);}
 const selected=designerSelectedId&&(designerRuntime.group.getObjectByName('designer-'+designerSelectedId)||(designerSelectionScope==='all'?world.getObjectByName('preset-'+designerSelectedId):null));
 const groups=selected?[selected]:designerSelectionScope==='all'&&equipmentObjects().some(o=>o.id===designerSelectedId)?equipmentGroups(designerSelectedId):[];
 designerSelection.box.makeEmpty();for(const group of groups)if(visibleInWorld(group))designerSelection.box.expandByObject(group,true);designerSelection.visible=!designerSelection.box.isEmpty();
}
function visibleInWorld(object){
 if(!object)return false;for(let parent=object;parent;parent=parent.parent)if(!parent.visible)return false;return true;
}
function captureBaselineCollisions(){
 const hardMaterials=new Set([M.wood,M.slateTop,M.slateSide]);
 const lines=sceneStyle==='basic'?basicEquipment?.dryGroup.getObjectByName('basic-over-rim-lines'):null,parent=lines?.parent;
 if(parent)world.attach(lines);
 try{collisionWorld.capture(world,object=>{
  if(!visibleInWorld(object))return false;
  for(let parent=object;parent&&parent!==world;parent=parent.parent)if(parent.userData.designerId)return false;
  object.userData.presetOwner=presetAssemblies?.ownerOf(object)||null;
  for(let parent=object;parent&&parent!==world;parent=parent.parent){
   if(parent.userData.solid){if(!object.userData.equipmentSolid)object.userData.hardscape=true;return true;}
   if(['sponge-filter','aquarium-heater','aquarium-thermometer'].includes(parent.name))return true;
  }
  const materials=Array.isArray(object.material)?object.material:[object.material];
  if(materials.some(material=>hardMaterials.has(material))){object.userData.hardscape=true;return true;}
  return false;
 });}finally{if(parent)parent.attach(lines);}
 baselineCollisionMeshes=collisionWorld.meshes;
}
function applyPresetObjects(message){
 let previous=null,transforms=null,applied=false;
 try{
  if(mode!=='desktop'||!designerActive||!designerRuntime)throw new Error('Open the tank editor before editing preset objects');
  if(!Number.isSafeInteger(message?.expectedRevision)||message.expectedRevision!==presetRevision)throw new Error('Preset revision is stale');
  previous=presetAssemblies.snapshot();if(JSON.stringify(message.objects)===JSON.stringify(previous))return{revision:presetRevision,objects:previous};
  transforms=world.children.filter(group=>group.userData.presetId).map(group=>({group,position:group.position.clone(),quaternion:group.quaternion.clone(),visible:group.visible}));
  presetAssemblies.apply(message.objects);applied=true;
  const current=presetAssemblies.snapshot();if(JSON.stringify(current)===JSON.stringify(previous))return{revision:presetRevision,objects:current};
  captureBaselineCollisions();
  const old=new Map(previous.map(record=>[record.id,record]));
  for(const record of current){
   if(JSON.stringify(record)===JSON.stringify(old.get(record.id)))continue;
   const group=world.getObjectByName('preset-'+record.id);
   if(Math.abs(record.positionCm.y-group.userData.presetAnchorY*cmPerUnit)>1e-7)throw new Error('Preset objects must retain their supported height');
   const obstacles=[...baselineCollisionMeshes.filter(mesh=>mesh.userData.presetOwner!==record.id),...designerRuntime.validSolids];
   const status=designerRuntime.inspectObject(group,{solids:obstacles,placement:['base-wood','base-rock'].includes(record.id)?'buried-hardscape':'transform'});if(!status.valid)throw new Error(status.reason);
  }
  designerRuntime.setEnvironment({solids:baselineCollisionMeshes,mountSolids:baselineCollisionMeshes.filter(mesh=>mesh.userData.hardscape&&!mesh.userData.equipmentSolid)});
  const invalidPlacement=designerRuntime.status.find(item=>!item.valid);if(invalidPlacement)throw new Error('Preset edit invalidates '+invalidPlacement.id+': '+invalidPlacement.reason);
  recaptureDesignerCollisions();rebuildSurfaceNavigation(false);buildBreedingSupports();presetRevision++;render();
  return{revision:presetRevision,objects:current,status:designerRuntime.status};
 }catch(error){
  if(applied){for(const saved of transforms){saved.group.position.copy(saved.position);saved.group.quaternion.copy(saved.quaternion);saved.group.visible=saved.visible;}captureBaselineCollisions();designerRuntime.setEnvironment({solids:baselineCollisionMeshes,mountSolids:baselineCollisionMeshes.filter(mesh=>mesh.userData.hardscape&&!mesh.userData.equipmentSolid)});recaptureDesignerCollisions();rebuildSurfaceNavigation(false);buildBreedingSupports();}
  return{revision:presetRevision,error:error.message};
 }
}
function recaptureDesignerCollisions(){
 const temporary=new THREE.Group();world.updateMatrixWorld(true);
 for(const source of [...baselineCollisionMeshes,...designerRuntime.validSolids]){const copy=new THREE.Mesh(source.geometry,source.material);copy.name=source.name;copy.userData={...source.userData};copy.matrixAutoUpdate=false;copy.matrix.copy(source.matrixWorld);temporary.add(copy);}
 collisionWorld.capture(temporary,()=>true);temporary.clear();designerSolidSignature=designerRuntime.validSolids.map(m=>m.uuid).join('|');
}
const equipmentDefinitions={
 'equipment/filter':{slot:'filter',assetId:'aquarium-co-op-coarse-sponge-filter',groups:['sponge-filter','filter-riser-above-water'],mount:'substrate'},
 'equipment/heater':{slot:'heater',assetId:'glass-heater',groups:['aquarium-heater'],mount:'back-glass'},
 'equipment/thermometer':{slot:'thermometer',assetId:'glass-thermometer',groups:['aquarium-thermometer'],mount:'front-glass'}
};
function equipmentGroups(id,asset=basicEquipment){return asset?(equipmentDefinitions[id]?.groups||[]).map(name=>asset.wetGroup.getObjectByName(name)||asset.dryGroup.getObjectByName(name)).filter(Boolean):[];}
function equipmentObjects(){
 if(sceneStyle!=='basic'||!basicEquipment)return [];
 return Object.entries(equipmentDefinitions).map(([id,definition])=>{const p=basicEquipment.placementsCm[definition.slot];return{id,assetId:definition.assetId,positionCm:{x:p.x,y:p.y,z:p.z},rotationY:p.rotationY};});
}
function equipmentState(){return{supported:sceneStyle==='basic',placementsCm:sceneStyle==='basic'&&basicEquipment?JSON.parse(JSON.stringify(basicEquipment.placementsCm)):null,objects:equipmentObjects(),outlet:{...filterOutlet}};}
function prepareEquipment(asset){
 const riser=asset.dryGroup.getObjectByName('filter-riser-above-water');if(riser){asset.wetGroup.attach(riser);riser.visible=sceneStyle==='basic';}
 for(const id of Object.keys(equipmentDefinitions))for(const group of equipmentGroups(id,asset))group.traverse(object=>{if(object.isMesh)Object.assign(object.userData,{editorEquipmentId:id,equipmentSolid:true,hardEquipment:true,hardscape:false});});
 const lines=asset.dryGroup.getObjectByName('basic-over-rim-lines');lines?.traverse(object=>{if(object.isMesh)Object.assign(object.userData,{editorEquipmentId:'equipment/lines',equipmentSolid:true,hardEquipment:true,hardscape:false});});
 asset.wetGroup.updateMatrixWorld(true);asset.dryGroup.updateMatrixWorld(true);
}
function disposeEquipmentAsset(asset){
 if(!asset)return;asset.wetGroup?.removeFromParent();asset.dryGroup?.removeFromParent();asset.group?.removeFromParent();
 const gs=new Set(asset.geometries),ms=new Set(asset.materials),ts=new Set(asset.maps);
 geometries=geometries.filter(g=>!gs.has(g));mats=mats.filter(m=>!ms.has(m));maps=maps.filter(t=>!ts.has(t));
 if(roomArt){roomArt.geometries=roomArt.geometries.filter(g=>!gs.has(g));roomArt.materials=roomArt.materials.filter(m=>!ms.has(m));roomArt.maps=roomArt.maps.filter(t=>!ts.has(t));}
 if(asset.dispose)asset.dispose();else for(const resource of new Set([...gs,...ms,...ts]))resource.dispose();
}
function releaseEquipment(){disposeEquipmentAsset(basicEquipment);disposeEquipmentAsset(equipmentConnections);basicEquipment=null;equipmentConnections=null;equipmentConnectionOptions=null;}
function registerEquipment(asset,connections){
 const wetMaterials=new Set();asset.wetGroup.traverse(o=>{if(o.isMesh)wetMaterials.add(o.material);});
 for(const m of asset.materials){if(wetMaterials.has(m))m.clippingPlanes=tankClip;mats.push(m);}geometries.push(...asset.geometries);maps.push(...asset.maps);
 world.add(asset.wetGroup);roomArt.group.add(asset.dryGroup,connections.group);roomArt.geometries.push(...connections.geometries);roomArt.materials.push(...connections.materials);roomArt.maps.push(...connections.maps);
}
function equipmentEffects(outlet){Object.assign(filterOutlet,outlet);for(const bubble of bubbles){bubble.x=filterOutlet.x;bubble.z=filterOutlet.z;}}
function applyEquipmentObjects(message){
 let candidate=null,connections=null,staged=null,previous=null,committed=false;const revision=presetRevision;
 try{
  if(mode!=='desktop'||!designerActive||sceneStyle!=='basic'||!basicEquipment)throw new Error('Open the basic tank editor before editing equipment');
  if(!Number.isSafeInteger(message?.expectedRevision)||message.expectedRevision!==presetRevision)throw new Error('Preset revision is stale');
  if(!Array.isArray(message.objects)||message.objects.length!==3)throw new Error('All three equipment components are required');
  const poses={},seen=new Set();for(const item of message.objects){const definition=equipmentDefinitions[item?.id];if(!definition||item.assetId!==definition.assetId||seen.has(item.id))throw new Error('Unknown or duplicate equipment identity');if(!item.positionCm||Array.isArray(item.positionCm)||!['x','y','z'].every(key=>typeof item.positionCm[key]==='number'&&Number.isFinite(item.positionCm[key]))||!Number.isFinite(item.rotationY))throw new Error('Equipment edits require complete finite poses');seen.add(item.id);poses[definition.slot]={x:item.positionCm.x,y:item.positionCm.y,z:item.positionCm.z,rotationY:item.rotationY};}
  candidate=AquariumMetricBasicArt.create(THREE,{tankHalf,cmPerUnit,backZ:outerBack,frontZ,waterLevel,bedLevel,rimY:8.4,placementsCm:poses});prepareEquipment(candidate);
  if(JSON.stringify(candidate.placementsCm)===JSON.stringify(basicEquipment.placementsCm))return{revision:presetRevision};
  const external=baselineCollisionMeshes.filter(mesh=>!mesh.userData.editorEquipmentId),parts=Object.fromEntries(Object.keys(equipmentDefinitions).map(id=>[id,equipmentGroups(id,candidate).flatMap(group=>{const out=[];group.traverse(o=>{if(o.isMesh)out.push(o);});return out;})]));
  const rimValidator=AquariumDesignerPlacement.create(THREE,{factories:{},cmPerUnit,tankHalf,backZ:outerBack,frontZ,bedLevel,waterLevel:8.4});
  try{for(const id of Object.keys(equipmentDefinitions))for(const group of equipmentGroups(id,candidate)){
   const obstacles=[...external,...Object.entries(parts).filter(([other])=>other!==id).flatMap(([,meshes])=>meshes),...designerRuntime.validSolids];
   const validator=group.name==='filter-riser-above-water'?rimValidator:designerRuntime,result=validator.inspectObject(group,{solids:obstacles,placement:'transform'});if(!result.valid)throw new Error(result.reason);
  }}finally{rimValidator.dispose();}
  const lines=candidate.dryGroup.getObjectByName('basic-over-rim-lines'),lineMeshes=[];lines.traverse(o=>{if(o.isMesh)lineMeshes.push(o);});
  const leadValidator=AquariumDesignerPlacement.create(THREE,{factories:{},cmPerUnit,tankHalf,backZ:outerBack-2/cmPerUnit,frontZ,bedLevel,waterLevel:8.4+1/cmPerUnit});
  try{const result=leadValidator.inspectObject(lines,{solids:[...external,...designerRuntime.validSolids],placement:'transform'});if(!result.valid)throw new Error('Cable or airline placement is blocked: '+result.reason);}finally{leadValidator.dispose();}
  const environment=[...external,...Object.values(parts).flat(),...lineMeshes];staged=createDesignerPlacement(environment);staged.setLayout(designerLayout);const invalid=staged.status.find(item=>!item.valid);if(invalid)throw new Error('Equipment invalidates '+invalid.id+': '+invalid.reason);
  connections=AquariumMetricConnections.create(THREE,{...equipmentConnectionOptions,heaterEnd:candidate.heaterEnd,airlineEnd:candidate.airlineEnd});
  previous={asset:basicEquipment,connections:equipmentConnections,outlet:{...filterOutlet}};
  previous.asset.wetGroup.removeFromParent();previous.asset.dryGroup.removeFromParent();previous.connections.group.removeFromParent();
  basicEquipment=candidate;equipmentConnections=connections;committed=true;registerEquipment(candidate,connections);equipmentEffects(candidate.filterOutlet);
  captureBaselineCollisions();designerRuntime.setEnvironment({solids:baselineCollisionMeshes,mountSolids:baselineCollisionMeshes.filter(mesh=>mesh.userData.hardscape&&!mesh.userData.equipmentSolid)});recaptureDesignerCollisions();rebuildSurfaceNavigation(false);buildBreedingSupports();presetRevision++;render();
  disposeEquipmentAsset(previous.asset);disposeEquipmentAsset(previous.connections);return{revision:presetRevision};
 }catch(error){
  if(committed){disposeEquipmentAsset(candidate);disposeEquipmentAsset(connections);candidate=null;connections=null;basicEquipment=previous.asset;equipmentConnections=previous.connections;world.add(basicEquipment.wetGroup);roomArt.group.add(basicEquipment.dryGroup,equipmentConnections.group);equipmentEffects(previous.outlet);presetRevision=revision;captureBaselineCollisions();designerRuntime.setEnvironment({solids:baselineCollisionMeshes,mountSolids:baselineCollisionMeshes.filter(mesh=>mesh.userData.hardscape&&!mesh.userData.equipmentSolid)});recaptureDesignerCollisions();rebuildSurfaceNavigation(false);buildBreedingSupports();}
  return{revision:presetRevision,error:error.message};
 }finally{staged?.dispose();if(!committed){disposeEquipmentAsset(candidate);disposeEquipmentAsset(connections);}}
}
function createDesignerPlacement(environment=baselineCollisionMeshes){
 return AquariumDesignerPlacement.create(THREE,{factories:{floating:AquariumFloatingPlantsV2,epiphyte:AquariumEpiphytePlantsV2,rooted:AquariumRootedPlantsV2,manzanita:AquariumManzanitaArt,mossRock:AquariumMossRockArt,dragon:AquariumDragonDriftwoodV1},cmPerUnit,tankHalf,backZ:outerBack,frontZ,bedLevel,waterLevel,solids:environment,mountSolids:environment.filter(o=>o.userData.hardscape&&!o.userData.equipmentSolid)});
}
function applyPlacedObjects(message){
 let staged=null;
 try{
  if(mode!=='desktop'||!designerActive||!designerRuntime)throw new Error('Open the tank editor before placing objects');
  if(!Number.isSafeInteger(message?.expectedRevision)||message.expectedRevision!==presetRevision)throw new Error('Preset revision is stale');
  const normalized=AquariumDesignerModel.normalize({...designerLayout,instances:message.objects});
  if(normalized.instances.some(item=>item.id.startsWith('base-')||presetAssemblies.snapshot().some(base=>base.id===item.id)))throw new Error('Placed object id conflicts with a preset object');
  if(JSON.stringify(normalized.instances)===designerLayoutSignature)return {revision:presetRevision};
  staged=createDesignerPlacement();staged.setLayout(normalized);
  const invalid=staged.status.find(item=>!item.valid);if(invalid)throw new Error(invalid.reason);
  const result=applyDesigner({layout:normalized});if(result.error)throw new Error(result.error);
  buildBreedingSupports();
  return {revision:presetRevision};
 }catch(error){return {revision:presetRevision,error:error.message};}
 finally{staged?.dispose();}
}
function initializeDesignerPlacement(){
 if(!designerActive)return;
 if(typeof AquariumDesignerModel==='undefined'||typeof AquariumDesignerPlacement==='undefined')throw new Error('Designer modules are unavailable');
 designerLayout=designerLayout||AquariumDesignerModel.createSession().snapshot();
 document.getElementById('controls').style.display='none';document.getElementById('hint').hidden=true;
 designerRuntime=createDesignerPlacement();
 designerRuntime.setLayout(designerLayout);world.add(designerRuntime.group);designerLayoutSignature=JSON.stringify(designerLayout.instances);recaptureDesignerCollisions();refreshDesignerSelection();
}
function applyDesigner(message){
 const requestId=message?.requestId??0;
 try{
  if(!Number.isSafeInteger(requestId)||requestId<0)throw new Error('Designer requestId must be a nonnegative integer');
  const normalized=AquariumDesignerModel.normalize(message.layout),tool=message.tool??'select',selectedId=message.selectedId??null,assetId=message.assetId??null;
  if(!['select','place','move'].includes(tool))throw new Error('Unknown designer pointer tool');
  const selectionScope=message.selectionScope??designerSelectionScope;
  if(!['added','all'].includes(selectionScope))throw new Error('Unknown editor selection scope');
  if(selectedId!==null&&!normalized.instances.some(i=>i.id===selectedId)&&!(selectionScope==='all'&&(presetAssemblies?.snapshot().some(i=>i.id===selectedId)||equipmentObjects().some(i=>i.id===selectedId))))throw new Error('Selected designer instance does not exist');
  if(tool==='place'&&!AquariumDesignerModel.catalog.some(a=>a.id===assetId))throw new Error('Place mode needs a known specimen');
  const first=!designerRuntime,baseChanged=normalized.base.setup!==sceneStyle,signature=JSON.stringify(normalized.instances),layoutChanged=signature!==designerLayoutSignature;
  if(!first&&!baseChanged&&signature!==designerLayoutSignature)designerRuntime.setLayout(normalized);
  designerActive=true;designerRequestId=requestId;designerLayout=normalized;designerSelectedId=selectedId;designerTool=tool;designerSelectionScope=selectionScope;designerAssetId=assetId;
  if(baseChanged){sceneStyle=normalized.base.setup;build();}
  else if(first){initializeDesignerPlacement();rebuildSurfaceNavigation(false);}
  else if(signature!==designerLayoutSignature){designerLayoutSignature=signature;if(designerSolidSignature!==designerRuntime.validSolids.map(m=>m.uuid).join('|'))recaptureDesignerCollisions();rebuildSurfaceNavigation(false);}
  if(!first&&!baseChanged&&layoutChanged)presetRevision++;
  document.getElementById('controls').style.display='none';document.getElementById('hint').hidden=true;refreshDesignerSelection();render();return replyDesigner();
 }catch(error){const reply={type:'aquarium-designer-state',requestId,status:[],error:error.message};parent.postMessage(reply,'*');return reply;}
}
function pickDesigner(event){
 if(!designerRuntime||event.button!==undefined&&event.button!==0)return;
 const rect=renderer.domElement.getBoundingClientRect();pointer.set((event.clientX-rect.left)/rect.width*2-1,-(event.clientY-rect.top)/rect.height*2+1);raycaster.setFromCamera(pointer,camera);
 if(designerTool==='select'){
  const hits=raycaster.intersectObject(designerRuntime.group,true);
  if(designerSelectionScope==='all')hits.push(...raycaster.intersectObjects([...presetAssemblies.meshes(),...collisionWorld.meshes],false));
  hits.sort((a,b)=>a.distance-b.distance);
  const hit=hits[0],id=hit?(hit.object.userData.designerId||(designerSelectionScope==='all'?(presetAssemblies.ownerOf(hit.object)||hit.object.userData.presetOwner||(equipmentObjects().some(o=>o.id===hit.object.userData.editorEquipmentId)?hit.object.userData.editorEquipmentId:null)):null)):null;
  parent.postMessage({type:'aquarium-designer-pick',revision:presetRevision,tool:designerTool,toolGeneration:designerRequestId,id:id??null},'*');return;
 }
 const presetObject=designerSelectionScope==='all'&&designerTool==='move'?presetAssemblies.snapshot().find(i=>i.id===designerSelectedId):null;
 const equipmentObject=designerSelectionScope==='all'&&designerTool==='move'?equipmentObjects().find(i=>i.id===designerSelectedId):null;
 const supportedObject=equipmentObject||presetObject,equipmentMount=equipmentObject&&equipmentDefinitions[equipmentObject.id].mount;
 const item=designerLayout.instances.find(i=>i.id===designerSelectedId),assetId=designerTool==='place'?designerAssetId:item?.assetId,definition=supportedObject?{placement:'preset'}:AquariumDesignerModel.catalog.find(a=>a.id===assetId);if(!definition)return;
 let hit;
 if(definition.placement==='attached')hit=raycaster.intersectObjects(collisionWorld.meshes.filter(m=>m.userData.hardscape&&!m.userData.equipmentSolid),false).find(h=>h.face.normal.clone().transformDirection(h.object.matrixWorld).y>=.5)?.point;
 else if(equipmentObject&&equipmentMount!=='substrate')hit=raycaster.ray.intersectPlane(new THREE.Plane(new THREE.Vector3(0,0,1),-(centerZ+equipmentObject.positionCm.z/cmPerUnit)),new THREE.Vector3());
 else hit=raycaster.ray.intersectPlane(new THREE.Plane(new THREE.Vector3(0,1,0),-(supportedObject?supportedObject.positionCm.y/cmPerUnit:definition.placement==='floating'?waterLevel:bedLevel)),new THREE.Vector3());
 if(!hit||Math.abs(hit.x)>innerHalf+1e-7||hit.z<backBound-1e-7||hit.z>frontBound+1e-7||hit.y<bedLevel-1e-7||hit.y>waterLevel+1e-7)return;
 const positionCm={x:THREE.MathUtils.clamp(hit.x*cmPerUnit,-29.4,29.4),y:supportedObject?supportedObject.positionCm.y:definition.placement==='attached'?THREE.MathUtils.clamp(hit.y*cmPerUnit,5,34.5):definition.placement==='floating'?34.5:5,z:equipmentObject&&equipmentMount!=='substrate'?equipmentObject.positionCm.z:THREE.MathUtils.clamp((hit.z-centerZ)*cmPerUnit,-17.4,17.4)};
 parent.postMessage({type:'aquarium-designer-pick',revision:presetRevision,tool:designerTool,toolGeneration:designerRequestId,...(designerTool==='move'?{id:designerSelectedId}:{}),positionCm},'*');
}
function updateDesigner(){
 if(!designerRuntime)return;const previousPlants=JSON.stringify(designerRuntime.plants.map(p=>p.id));designerRuntime.update(clock,flowField);
 if(designerSolidSignature!==designerRuntime.validSolids.map(m=>m.uuid).join('|')){recaptureDesignerCollisions();rebuildSurfaceNavigation(false);}else if(previousPlants!==JSON.stringify(designerRuntime.plants.map(p=>p.id)))rebuildSurfaceNavigation(false);
 refreshDesignerSelection();if(designerStatusSignature!==JSON.stringify(designerRuntime.status))replyDesigner();
}
function tankLightFalloff(light,x,y,z){
 const ray=new THREE.Vector3(x,y,z).sub(light.position),distanceSquared=ray.lengthSq();ray.normalize();
 const axis=light.target.position.clone().sub(light.position).normalize(),outer=Math.cos(light.angle),inner=Math.cos(light.angle*(1-light.penumbra));
 const cone=THREE.MathUtils.smoothstep(ray.dot(axis),outer,inner);
 return cone*Math.max(0,-ray.y)/Math.max(.01,distanceSquared)*AquariumLightFootprint.transmission(THREE,light,x,y,z,lightSpread);
}
function configureTankLights(){
 for(let i=0;i<tankLights.length;i++){
  const light=tankLights[i],active=i<tankLightCount,x=!active||tankLightCount===1?0:(i/(tankLightCount-1)*2-1)*lampSpan;
  light.visible=active;light.position.set(x,9.10,centerZ);light.target.position.set(x,bedLevel,centerZ);light.map=lightDepthMaps[lightSpread];light.updateMatrixWorld();light.target.updateMatrixWorld();light.shadow.updateMatrices(light);
  light.userData.powerWeight=tankLightCount===5&&i%2?.45:1;light.userData.castsTankShadow=active&&(tankLightCount<5||i%2===0);
  if(!light.userData.castsTankShadow){light.shadow.map?.dispose();light.shadow.map=null;light.shadow.mapPass?.dispose();light.shadow.mapPass=null;}
  if(lampEmitters[i]){lampEmitters[i].parent.visible=active;lampEmitters[i].parent.position.x=x;}
 }
 if(tankLightCount===5){
  let aa=0,ac=0,cc=0,ay=0,cy=0;
  for(let i=0;i<=40;i++){
   const x=(i/40*2-1)*tankHalf*.95;
   const outer=tankLightFalloff(tankLights[0],x,bedLevel,.7)+tankLightFalloff(tankLights[4],x,bedLevel,.7)+.45*(tankLightFalloff(tankLights[1],x,bedLevel,.7)+tankLightFalloff(tankLights[3],x,bedLevel,.7));
   const center=tankLightFalloff(tankLights[2],x,bedLevel,.7);aa+=outer*outer;ac+=outer*center;cc+=center*center;ay+=outer;cy+=center;
  }
  const denominator=ay*cc-cy*ac;
  tankLights[2].userData.powerWeight=denominator>1e-12?THREE.MathUtils.clamp((cy*aa-ay*ac)/denominator,.25,1.5):1;
 }
 let peak=0;
 for(let i=0;i<=40;i++)for(const z of [-2.4,-.85,.7,2.25,3.8]){
  const x=(i/40*2-1)*tankHalf;let sum=0;
  for(const light of tankLights)if(light.visible)sum+=light.userData.powerWeight*tankLightFalloff(light,x,bedLevel,z);
  peak=Math.max(peak,sum);
 }
 for(const light of tankLights)light.userData.unitIntensity=light.visible?3.3*light.userData.powerWeight/Math.max(.001,peak):0;
}
function applyLighting(){
 if(chromeFinish)chromeFinish.update(roomLevel,preset==='off'?0:preset==='moonlight'?.12:lightOutput);
 const palettes={daylight:{color:0xedf2da,emitter:0xe5eed1,tint:0xffffff,power:1},warm:{color:0xffd5a2,emitter:0xffd9ac,tint:0xffe4c2,power:.93},moonlight:{color:0xadbee6,emitter:0xadbfe5,tint:0xa9bdd5,power:.38},off:{color:0xedf2da,emitter:0x17272b,tint:0xffffff,power:0}};
 const p=palettes[preset];ambient.intensity=.025+.35*roomLevel;fill.intensity=.55*roomLevel;
 for(const light of tankLights){light.color.setHex(p.color);light.intensity=light.userData.unitIntensity*p.power*lightOutput;light.castShadow=light.userData.castsTankShadow&&p.power>0;}
 for(let i=0;i<lampEmitters.length;i++)lampEmitters[i].material.color.setHex(p.emitter).multiplyScalar(p.power?Math.min(1,tankLights[i].userData.powerWeight)*Math.pow(p.power*lightOutput,.3):.2+.8*roomLevel);
 const animals=[...fish,...shrimps,...snails],special=new Set([...animals.map(a=>a.material),...lampEmitters.map(o=>o.material)]);
 const unlit=mats.filter(m=>m.isMeshBasicMaterial&&!m.vertexColors&&!special.has(m));
 for(const m of unlit)if(!m.userData.lightingBase)m.userData.lightingBase=m.color.clone();
 const sceneGain=Math.min(1,.002+.43*roomLevel+.60*p.power*lightOutput),roomGain=.002+.998*roomLevel;
 for(const m of unlit)m.color.copy(m.userData.lightingBase).multiplyScalar(m.userData.roomOnly?roomGain:sceneGain);
 const backgroundGain=.002+.5*roomLevel+.5*p.power;
 backdropColors(new THREE.Color(0x103a47).multiplyScalar(backgroundGain),new THREE.Color(0x0d2734).multiplyScalar(backgroundGain));
 if(waterSurface)waterSurface.material.color.multiplyScalar(sceneGain);
 for(const o of lightPools)o.visible=false;
 for(const a of animals){const tint=new THREE.Color(p.tint).lerp(new THREE.Color(0xffffff),roomLevel*.55);tint.multiplyScalar(sceneGain*(a.kind==='fish'?.90:.96));a.material.color.copy(tint);}
 renderer.setClearColor(0x000000);
}
function setRoomFinish(next){if(!['neutral','charcoal','concrete'].includes(next)||next===roomFinish)return;roomFinish=next;roomArt?.setFinish(next);render();}
function setLightSpread(next){if(!['focused','natural','broad'].includes(next)||next===lightSpread)return;lightSpread=next;configureTankLights();applyLighting();render();}
function setLightOutput(next){if(!Number.isFinite(next)||next<.25||next>1.5||next===lightOutput)return;lightOutput=next;applyLighting();render();}
function setAsset(kind,value){const choices={gravel:['basalt','river','mixed-river'],rock:['slate','river','moss'],shrimp:['red','red-rili','red-white','skittles','amano','blue-dream','green-jade','yellow-goldenback','crystal-black','orange-rili',...AquariumPatternShrimpV2.variants],fish:['chili','medaka-white','medaka-redcap','guppy-blue','guppy-pink',...Object.keys(AquariumFancyFishV2.descriptors)],decor:['none','skull-castle','tetrapods'],wood:['pixel','smooth','manzanita'],cleaners:['classic','contact'],plants:['classic','varied','botanical',...AquariumBotanicalLayout.species]};if(!choices[kind]?.includes(value)||assets[kind]===value)return;assets[kind]=value;build();}
function setLight(next){if(!['daylight','warm','moonlight','off'].includes(next))return;preset=next;applyLighting();render();}
function setRoomLight(level){if(!Number.isFinite(level))return;roomLevel=THREE.MathUtils.clamp(level,0,1);applyLighting();render();}
function setTankLightCount(count){if(![1,3,5].includes(count)||count===tankLightCount)return;tankLightCount=count;configureTankLights();applyLighting();render();}
function updateRoomFromClock(){
 const now=new Date(),hour=now.getHours()+now.getMinutes()/60;
 setRoomLight(roomMode==='on'?1:roomMode==='off'?0:AquariumDaylight.roomLevelAtHour(hour));
}
function setRoomMode(next){if(!['auto','on','off'].includes(next))return;roomMode=next;updateRoomFromClock();}
function updateJarTarget(){
 const button=document.getElementById('jar-target');button.hidden=designerActive||mode!=='desktop';button.disabled=designerActive||mode!=='desktop';if(designerActive||!foodJar||mode!=='desktop')return;
 foodJar.updateWorldMatrix(true,true);const bounds=new THREE.Box3().setFromObject(foodJar);let left=1,right=-1,top=-1,bottom=1;
 for(const x of [bounds.min.x,bounds.max.x])for(const y of [bounds.min.y,bounds.max.y])for(const z of [bounds.min.z,bounds.max.z]){const p=new THREE.Vector3(x,y,z).project(camera);left=Math.min(left,p.x);right=Math.max(right,p.x);top=Math.max(top,p.y);bottom=Math.min(bottom,p.y);}
 button.style.left=((left+1)*.5*innerWidth)+'px';button.style.top=((1-top)*.5*innerHeight)+'px';button.style.width=((right-left)*.5*innerWidth)+'px';button.style.height=((top-bottom)*.5*innerHeight)+'px';
}
function render(){renderer.render(scene,camera);renderedFrames++;updateJarTarget();}
function animate(stamp){
 handle=0;if(document.hidden||!enabled){last=0;return;}if(!last)last=stamp;
 if(roomMode==='auto'&&stamp-lastRoomCheck>=30000){lastRoomCheck=stamp;updateRoomFromClock();}
 clock+=Math.min(.08,(stamp-last)/1000);last=stamp;
 if(clock>=nextFeedDue)feed({automatic:true});
 if(stamp-lastDraw>=1000/60-.75){
  const elapsed=Math.min(.08,Math.max(0,clock-lastSimulation));lastSimulation=clock;
  updateEcology(elapsed);
  const activeFish=fish.filter(f=>f.life.alive&&!f.surfaceMotion);for(const f of activeFish)f.motion.hungry=f.life.hunger>.15&&!breeding.stateFor(f.life.id)?.target;
  AquariumFishMotion.step(THREE,activeFish.map(f=>f.motion),elapsed,clock,{halfWidth:tankHalf,bedLevel,waterLevel,backZ:backBound,frontZ:frontBound,glassInset:.004},collisionWorld,pellets.filter(p=>p.o.visible&&!p.settled&&p.food.amount>.001).map(p=>p.o.position),{illumination:THREE.MathUtils.clamp((preset==='off'?0:preset==='moonlight'?.08:.70*lightOutput)+roomLevel*.15,0,1),shelters:[{x:-visibleWidth*.26,y:bedLevel+1.5,z:.7},{x:visibleWidth*.22,y:bedLevel+1.5,z:1.2}]});
  for(const f of activeFish){f.o.userData.lightReaction=f.motion.lightState;f.o.scale.set(f.scale*f.motion.facing,f.scale,f.scale);f.o.quaternion.copy(camera.quaternion);placeAnimal(f);f.material.map=f.frames[Math.floor(clock*5+f.phase)%f.frames.length].tex;}
  if(conditionMode==='auto'){conditionLevel=Math.min(1,conditionStart+(clock-conditionEpoch)/600);waterCondition.setLevel(conditionLevel);updateWaterTransmission();}
  if(conditionMode==='ecosystem'){conditionLevel=Math.min(1,water.readings().condition+ecology.patches.reduce((sum,p)=>sum+p.amount,0)/Math.max(1,ecology.patches.length)*.35);waterCondition.setLevel(conditionLevel);updateWaterTransmission();}
  waterCondition.update(clock);
  botanicalArt?.update(clock,flowField);carpetArt?.update(clock,flowField);for(const a of variedPlants)a.update(clock,flowField);updateDesigner();
  const surfaceAgents=[...shrimps,...snails,...fish.filter(f=>f.surfaceMotion)].filter(s=>s.life.alive);
  for(const s of surfaceAgents){
   const before=s.surfaceMotion.position.clone();
   const falling=s.surfaceMotion.falling===true;
   if(falling){const a=s.surfaceMotion,to=a.position.clone();to.y=Math.max(bedLevel+.12,to.y-elapsed*.65);const hit=animalSurfaceContact(s,a.position,to);a.position.copy(hit.position);a.walking=false;a.contactId=null;if(hit.collided||a.position.y<=bedLevel+.120001){a.falling=false;a.contactKind='floor';}}
   else if(s.kind==='shrimp'&&surfaceNavigation&&s.surfaceMotion.surface!=='glass'){
    const a=s.surfaceMotion;a.walking=false;a.time+=elapsed;let goal=s.life.target?.position;
    if(!goal&&navigationSites.length){if(!s.perchUntil||clock>s.perchUntil){s.perchUntil=clock+12+s.phase;s.perchGoal=navigationSites[Math.floor((s.phase*97+Math.floor(clock/12)*31)%navigationSites.length)].position;}goal=s.perchGoal;}
    if(goal&&(clock+s.phase*.37)%11<7)surfaceNavigation.step(a,elapsed,goal,s.life.state);
    const site=leafContacts.get(a.contactId);if(site&&!a.walking)a.position.set(site.position[0],site.position[1]+.12,site.position[2]);
   }else AquariumSurfaceMotion.step(THREE,s.surfaceMotion,elapsed,s.life.target?.position,s.surfaceMotion.surface==='glass'?glassBoundsFor(s):glassBounds,{moveSphere:(from,to)=>animalSurfaceContact(s,from,to)},surfaceSupport,surfaceAgents.map(a=>a.surfaceMotion),s.life.state);
   if(!falling&&s.kind==='shrimp'&&surfaceNavigation&&animalSurfaceContact(s,before,s.surfaceMotion.position).collided){s.surfaceMotion.position.copy(before);s.surfaceMotion.walking=false;}
   const traveled=s.surfaceMotion.position.clone().sub(before);
   s.o.scale.set(s.scale*s.surfaceMotion.facing,s.scale,s.scale);s.o.quaternion.copy(camera.quaternion);
   if(s.surfaceMotion.surface==='glass'){setGlassPose(s,s.surfaceMotion.pane);orientGlassAnimal(s,elapsed);}else if(s.life.species==='otocinclus'){
    if(traveled.lengthSq()>1e-10){const desired=Math.atan2(traveled.y,traveled.x)-Math.PI/2;const change=Math.atan2(Math.sin(desired-s.heading),Math.cos(desired-s.heading));s.heading+=THREE.MathUtils.clamp(change,-elapsed*1.6,elapsed*1.6);}
    s.o.scale.setScalar(s.scale);s.o.rotateZ(s.heading);
   }
   placeAnimal(s);
   if(s.kind==='shrimp'){
    const pose=AquariumMoltVisual.pose(clock-s.moltStarted);s.material.opacity=pose.tint;
    if(pose.active){const center=animalOffset(s,'bodyCenter'),from=s.o.position.clone().add(center),gain=s.metric.lengthWorld/.8,to=from.clone().add(new THREE.Vector3(pose.x*s.surfaceMotion.facing*gain,pose.y*gain,0));s.o.position.copy(collisionWorld.moveSphere(from,to,s.metric.movementCollisionRadius).position).sub(center);s.o.rotateZ(pose.rotation*s.surfaceMotion.facing);}
   }
   s.o.userData.walking=s.surfaceMotion.walking;const cadence=s.frames[0].secondsPerFrame;const frame=cadence?Math.floor(clock/cadence+s.phase)%s.frames.length:s.surfaceMotion.walking?Math.floor(clock*(s.kind==='shrimp'?6:.4)+s.phase)%s.frames.length:0;s.material.map=s.frames[frame].tex;
  }
  for(const b of bubbles){
   b.o.visible=sceneStyle==='basic'&&pumpOutput>0;if(!b.o.visible)continue;
   const span=Math.max(.02,waterLevel-filterOutlet.y-b.radius-.015),rise=((clock+b.phase)*b.riseSpeed)%span,spread=rise/span;
   b.o.position.y=filterOutlet.y+rise;b.o.position.x=b.x-rise*.13+Math.sin(clock*(1.1+b.i*.07)+b.i*2.4)*(.008+spread*.045);
   b.o.position.z=b.z+Math.sin(clock*.9+b.i*1.7)*spread*.025;
   if(b.lastRise!==undefined&&rise<b.lastRise)surfaceStudy.emit(b.x-span*.13,b.o.position.z,clock);b.lastRise=rise;b.o.quaternion.copy(camera.quaternion);
  }

  if(premiumEquipment){
   const source=premiumEquipment.diffuserPoint;
   for(const b of co2Mist){b.o.visible=true;const rise=((clock*.16+b.phase)%2.4);b.o.position.set(source.x+Math.sin(rise*2+b.phase)*.025+rise*.08,source.y+rise,source.z+Math.sin(rise+b.phase)*.03);b.o.quaternion.copy(camera.quaternion);}
   if(pumpOutput>0&&clock>=nextReturnRipple){const p=premiumEquipment.returnPoint;surfaceStudy.emit(p.x,p.z,clock);nextReturnRipple=clock+1.1;}
  }
  if(hangOnFilter){hangOnFilter.update(clock*pumpOutput);if(pumpOutput>0&&clock>=nextReturnRipple){const p=hangOnFilter.returnPoint;surfaceStudy.emit(p.x,p.z,clock);nextReturnRipple=clock+.7;}}
  surfaceStudy.update(clock);lushPlants?.update(clock,flowField);
  for(const p of pellets){
   const t=clock-feedStarted-p.delay;p.o.visible=t>=0&&t<22&&p.food.amount>.001;if(t<0||p.settled||!p.o.visible)continue;
   const elapsed=Math.min(.08,Math.max(0,t-p.lastT));p.lastT=t;p.velocity.y=Math.max(-1.7,p.velocity.y-elapsed*.16);
   const next=p.o.position.clone().addScaledVector(p.velocity,elapsed),contact=collisionWorld.moveSphere(p.o.position,next,.036);
   p.o.position.copy(contact.position);if(contact.collided&&contact.kind!=='glass'){p.settled=true;p.o.userData.landedOn=contact.kind;}
   else p.o.rotation.z+=elapsed*.6;
  }
  for(const p of plants)if(p.sway!==false){const position=p.g.getWorldPosition(new THREE.Vector3()),flow=flowField?.sample(position.x,position.y+1,position.z,clock);p.g.rotation.z=-(flow?.x||0)*(flow?.strength||0)*(.035+.012*Math.sin(clock*.9+p.phase));p.g.rotation.x=(flow?.z||0)*(flow?.strength||0)*.035;}
  if(Math.floor(clock)!==lastEcologyReport){lastEcologyReport=Math.floor(clock);parent.postMessage({type:'aquarium-ecology-report',alive:ecology.animals.filter(a=>a.alive).length,molts:ecology.stats.molts,deaths:ecology.stats.deaths,waste:ecology.deposits.filter(d=>d.kind==='feces').length,algaeEaten:ecology.stats.algaeEaten,broods:breeding.broods.length,young:breeding.offspring.length,eggs:breeding.eggs.reduce((n,b)=>n+b.count,0),days:ecology.seconds/86400,water:water.readings()},'*');}
  render();lastDraw+=Math.max(1,Math.floor((stamp-lastDraw+.75)/(1000/60)))*(1000/60);
 }
 handle=requestAnimationFrame(animate);
}
function retireSpentYoung(){
 const retained=new Set(breeding.offspring.map(a=>a.id));for(const a of [...fish,...shrimps]){
  if(!a.life.isOffspring||a.life.alive||retained.has(a.life.id)||!ecology.retireDeadAnimal(a.life.id))continue;
  a.o.removeFromParent();for(const g of a.ownedGeometries){g.dispose();geometries=geometries.filter(v=>v!==g);}a.material.dispose();mats=mats.filter(m=>m!==a.material);
  if(a.contact){a.contact.removeFromParent();a.contact.geometry.dispose();a.contact.material.dispose();geometries=geometries.filter(g=>g!==a.contact.geometry);mats=mats.filter(m=>m!==a.contact.material);}
  fish=fish.filter(v=>v!==a);shrimps=shrimps.filter(v=>v!==a);
 }
}
function cachedStageFrames(kind,variant,stage){
 const key=[kind,variant,stage].join(':');if(!stageFrameCache.has(key))stageFrameCache.set(key,spriteFrames(kind,variant,stage));return stageFrameCache.get(key);
}
function setAnimalStage(a,stage){
 if(a.life.species==='guppy'&&a.life.sex==='female'&&stage==='adult')stage='female';
 if(a.stage===stage)return;const variant=a.kind==='shrimp'?a.color:a.fishChoice;if(a.kind==='fish'&&!['guppy','medaka'].includes(a.life.species))return;
 const frames=cachedStageFrames(a.kind,variant,stage),geometry=animalPlane(frames[0]),previous=a.o.geometry;
 geometries.push(geometry);a.ownedGeometries.add(geometry);a.o.geometry=geometry;a.frames=frames;a.material.map=frames[0].tex;a.stage=stage;
 a.ownedGeometries.delete(previous);geometries=geometries.filter(g=>g!==previous);previous.dispose();updateAnimalMetric(a);
}
function spawnYoung(child){
 if([...fish,...shrimps].some(a=>a.life.id===child.id))return;const index=Number(child.id.split('-').at(-1))||1;
 const mother=child.kind==='shrimp'?shrimps.find(a=>a.life.id===child.parentIds?.[0]):null,position=mother?.surfaceMotion.position||child.position;
 const a=animal(child.kind,position.x,child.kind==='shrimp'?Math.max(bedLevel+.12,position.y):position.y,position.z,1,1000+index,index%2?1:-1,'assassin',{id:child.id,sex:child.sex,maturity:child.maturity,stage:child.stage,growthAgeDays:child.ageDays||0,color:child.kind==='shrimp'?child.variant:undefined,fish:child.kind==='fish'?child.variant:undefined});a.life.ageDays=child.ageDays||0;
}
function buildBreedingSupports(){
 breedingSupports=[];world.updateMatrixWorld(true);for(const [i,p]of plants.entries()){
  if(!visibleInWorld(p.g))continue;
  let best=null,distance=Infinity;const bounds=new THREE.Box3().setFromObject(p.g),target=bounds.min.y+(bounds.max.y-bounds.min.y)*.65;
  p.g.traverse(o=>{const positions=o.isMesh&&o.geometry?.attributes.position;if(!positions)return;for(let j=0;j<positions.count;j+=3){const v=new THREE.Vector3().fromBufferAttribute(positions,j).applyMatrix4(o.matrixWorld),d=Math.abs(v.y-target);if(d<distance){best={id:'plant-support-'+i,mesh:o,index:j};distance=d;}}});if(best)breedingSupports.push(best);
 }
}
function updateBreeding(dt){
 const all=[...fish,...shrimps,...snails],young=breeding.offspring,youngIds=new Set(young.map(a=>a.id));
 const supports=breedingSupports.map(s=>{s.mesh.updateWorldMatrix(true,false);const p=new THREE.Vector3().fromBufferAttribute(s.mesh.geometry.attributes.position,s.index).applyMatrix4(s.mesh.matrixWorld);return{id:s.id,kind:'plant',position:{x:p.x,y:p.y,z:p.z}};});
 const roster=all.filter(a=>a.life.alive||youngIds.has(a.life.id)).map(a=>{const child=young.find(c=>c.id===a.life.id);return{id:a.life.id,kind:a.kind,species:a.life.species,sex:a.life.sex,maturity:child?.maturity??a.life.maturity,alive:a.life.alive,variant:a.kind==='shrimp'?a.color:a.fishChoice,position:a.life.position};});
 const result=breeding.step(dt,roster,{habitat:'freshwater',shelter:plants.length?.8:0,light:preset==='off'?0:preset==='moonlight'?.15:1,stress:conditionLevel,plantSupports:supports,canReach:(from,to)=>{const a=new THREE.Vector3(from.x,from.y,from.z),b=new THREE.Vector3(to.x,to.y,to.z);return collisionWorld.moveSphere(a,b,.025).position.distanceTo(b)<.06;}});
 for(const child of result.births)spawnYoung(child);
 for(const a of [...fish,...shrimps]){
  const state=breeding.stateFor(a.life.id);if(!state)continue;if(state.family===AquariumBreeding.familyOf(a.life)&&(a.life.species==='cherry'||a.life.species==='amano'||a.life.species==='guppy'||a.life.species==='medaka'))setAnimalStage(a,state.stage);
  a.o.userData.lifeStage=state.stage;
  if(state.relativeAdultSize){a.life.maturity=state.maturity;updateAnimalMetric(a,state.ageDays);}
  const target=state.target||state.shelterSeeking&&state.shelterTarget;if(target&&a.motion){a.motion.target=new THREE.Vector3(target.position.x,target.position.y,target.position.z);a.motion._targetUntil=clock+2;a.motion.hungry=false;}
 }
}
function setEcologyRate(value){if([1,120,3600].includes(value))ecologyRate=value;}
function maintainTank(action,fraction=.25){
 if(mode!=='desktop'||designerActive||!Number.isFinite(fraction)||fraction<=0||fraction>1)return false;
 if(action==='water-change')water.waterChange(fraction);
 else if(action==='clean-substrate'){ecology.cleanSubstrate(fraction);water.cleanSubstrate(fraction);}
 else if(action==='service-filter')water.serviceFilter({removeFraction:fraction,maturityRetention:.95});
 else if(action==='harvest-plants')water.harvestPlants(fraction);
 else return false;
 if(conditionMode==='ecosystem'){conditionLevel=Math.min(1,water.readings().condition+ecology.patches.reduce((sum,p)=>sum+p.amount,0)/Math.max(1,ecology.patches.length)*.35);waterCondition.setLevel(conditionLevel);updateWaterTransmission();}
 updateEcology(0);parent.postMessage({type:'aquarium-water-report',readings:water.readings()},'*');render();return true;
}
function previewLifeEvent(event){
 if(mode!=='desktop')return false;
 const entry=event==='molt'?shrimps.filter(a=>a.life.alive&&a.life.state!=='recover').sort((a,b)=>(b.o.position.y+b.o.position.z*.2)-(a.o.position.y+a.o.position.z*.2))[0]:event==='death'?fish.find(a=>a.life.alive):null;
 if(!entry)return false;
 if(event==='molt'){entry.life.position={x:entry.o.position.x,y:entry.o.position.y,z:entry.o.position.z};ecology.beginMolt(entry.life);}else ecology.die(entry.life,'explicit review preview');
 updateEcology(0);render();return true;
}
const supportRay=new THREE.Raycaster();
function surfaceSupport(x,z,previousY){
 supportRay.set(new THREE.Vector3(x,previousY+.3,z),new THREE.Vector3(0,-1,0));supportRay.near=0;supportRay.far=.6;
 const hit=supportRay.intersectObjects(collisionWorld.meshes,false).find(h=>h.face.normal.clone().transformDirection(h.object.matrixWorld).y>.35);
 return{x,y:hit?hit.point.y+.12:bedLevel+.12,z};
}
function makeEcologyVisuals(){
 const group=new THREE.Group();group.name='ecosystem-details';world.add(group);
 if(!ecology.patches.length)for(let i=0;i<16;i++)ecology.addPatch({id:'algae-'+i,position:{x:0,y:0,z:0},amount:.2+(i%4)*.07});
 for(let i=0;i<ecology.patches.length;i++){
  const patch=ecology.patches[i];patch.position=i<10?{x:(i/9-.5)*tankHalf*1.55,y:bedLevel+.13,z:.25+(i%3)*1.1}:{x:((i-10)/5-.5)*tankHalf*1.5,y:bedLevel+.65+(i%3)*.60,z:frontBound-.004};
 }
 const canvas=document.createElement('canvas');canvas.width=canvas.height=16;const g=canvas.getContext('2d');
 for(let y=0;y<16;y++)for(let x=0;x<16;x++)if((x-8)**2+(y-8)**2<53&&(x*11+y*7)%5>0){g.fillStyle=(x+y)%3?'#53633c':'#85905a';g.fillRect(x,y,1,1);}
 const tex=new THREE.CanvasTexture(canvas);tex.magFilter=tex.minFilter=THREE.NearestFilter;tex.generateMipmaps=false;tex.colorSpace=THREE.SRGBColorSpace;maps.push(tex);
 const patchMaterial=rememberMaterial(new THREE.MeshLambertMaterial({map:tex,transparent:true,opacity:.55,alphaTest:.1,depthWrite:false,side:THREE.DoubleSide}));
 const patchGeometry=new THREE.PlaneGeometry(.6,.4);geometries.push(patchGeometry);
 const algae=new THREE.InstancedMesh(patchGeometry,patchMaterial,16);algae.name='grazeable-algae';algae.instanceMatrix.setUsage(THREE.DynamicDrawUsage);algae.frustumCulled=false;group.add(algae);
 const dirtGeometry=new THREE.IcosahedronGeometry(1,0);geometries.push(dirtGeometry);
 const dirtMaterial=rememberMaterial(new THREE.MeshLambertMaterial({color:0x74604a,flatShading:true}));
 const dirt=new THREE.InstancedMesh(dirtGeometry,dirtMaterial,256);dirt.name='organic-waste';dirt.instanceMatrix.setUsage(THREE.DynamicDrawUsage);dirt.frustumCulled=false;group.add(dirt);
 const shellCanvas=document.createElement('canvas');shellCanvas.width=32;shellCanvas.height=20;const c=shellCanvas.getContext('2d');c.fillStyle='#dae4c9';
 const lines=[[6,7,12,1],[3,9,4,1],[17,8,4,1],[20,9,4,1],[23,10,3,1],[25,9,2,1],[24,12,4,1],[7,12,13,1],[7,8,1,4],[10,13,1,3],[14,13,1,4],[18,13,1,3]];for(const rect of lines)c.fillRect(...rect);
 const shellTexture=new THREE.CanvasTexture(shellCanvas);shellTexture.minFilter=shellTexture.magFilter=THREE.NearestFilter;shellTexture.generateMipmaps=false;maps.push(shellTexture);
 const shellMaterial=rememberMaterial(new THREE.MeshBasicMaterial({map:shellTexture,transparent:true,opacity:.62,alphaTest:.02,depthWrite:false,side:THREE.DoubleSide}));const shellGeometry=new THREE.PlaneGeometry(.95,.60);shellGeometry.translate(0,.13,0);geometries.push(shellGeometry);
 const shells=new THREE.InstancedMesh(shellGeometry,shellMaterial,256);shells.name='shed-shrimp-shells';shells.instanceMatrix.setUsage(THREE.DynamicDrawUsage);shells.frustumCulled=false;group.add(shells);
 const eggGeometry=new THREE.SphereGeometry(.025,6,4),eggMaterial=rememberMaterial(new THREE.MeshBasicMaterial({color:0xdfd9ab,transparent:true,opacity:.75}));geometries.push(eggGeometry);const eggs=new THREE.InstancedMesh(eggGeometry,eggMaterial,80);eggs.count=0;eggs.name='plant-attached-eggs';group.add(eggs);return{group,algae,dirt,shells,eggs,dummy:new THREE.Object3D()};
}
function updateEcology(elapsed){
 const all=[...fish,...shrimps,...snails];
 for(const a of all)if(a.life.alive){const mouth=animalPoint(a,'mouth');a.life.position={x:mouth.x,y:mouth.y,z:mouth.z};}
 for(const p of pellets)p.food.position={x:p.o.position.x,y:p.o.position.y,z:p.o.position.z};
 const simulatedElapsed=Math.min(3600,elapsed*(mode==='saver'?1:ecologyRate));
 const light=preset==='off'?0:preset==='moonlight'?.08:Math.min(1,lightOutput*tankLightCount/3),waterBefore=water.readings();
 ecology.step(simulatedElapsed,{light,filter:0,stress:waterBefore.stress,nutrients:Math.min(2,waterBefore.concentrationsMgL.ammonia+waterBefore.concentrationsMgL.nitrate),canReach:(from,to)=>{
  const target=new THREE.Vector3(to.x,to.y,to.z),hit=collisionWorld.moveSphere(new THREE.Vector3(from.x,from.y,from.z),target,.015);return !hit.collided||hit.position.distanceTo(target)<.06;
 }});
 const dissolved=ecology.stats.dissolved-accountedDissolved;
 if(dissolved>0)water.addNitrogen({organic:dissolved*4});
 accountedDissolved=ecology.stats.dissolved;
 water.step(simulatedElapsed,{filterOutput:Math.min(1,pumpOutput),light,plantCoverage:sceneStyle==='basic'?.35:.85,aeration:Math.min(1,pumpOutput*(surfaceMode==='lively'?.8:.35)),respirationMgLPerHour:all.filter(a=>a.life.alive).length*.002,co2InjectionMgLPerHour:sceneStyle==='lush'?1:0});
 updateBreeding(simulatedElapsed);
 for(const a of all){
  a.o.userData.behavior=a.life.state;if(a.kind==='shrimp'&&(a.life.moltCount||0)>a.seenMolt){a.seenMolt=a.life.moltCount;a.moltStarted=clock;}a.o.userData.moltPhase=Number.isFinite(a.moltStarted)&&clock-a.moltStarted<12?'shedding':'none';
  if(a.life.alive)continue;
  const corpse=ecology.deposits.find(d=>d.kind==='corpse'&&d.owner===a.life.id);
  if(!corpse){a.o.visible=false;a.corpseId=null;continue;}if(!a.corpseId){const center=animalPoint(a,'bodyCenter');corpse.position={x:center.x,y:center.y,z:center.z};}a.corpseId=corpse.id;
  const from=new THREE.Vector3(corpse.position.x,corpse.position.y,corpse.position.z),to=from.clone();to.y-=elapsed*.18;
  const contact=collisionWorld.moveSphere(from,to,a.metric.collision.enclosingRadius);corpse.position={x:contact.position.x,y:contact.position.y,z:contact.position.z};
  a.o.quaternion.copy(camera.quaternion);a.o.rotateZ(Math.PI);a.o.position.copy(contact.position).sub(animalOffset(a,'bodyCenter'));a.o.visible=corpse.amount/corpse.initial>.08;if(a.contact)a.contact.visible=false;
 }
 drawEcologyDetails(elapsed,all,true);
}
var stockCount,stockDeaths,stockBirths;
function notifyStockChange(){
 if(stockCount===ecology.animals.length&&stockDeaths===ecology.stats.deaths&&stockBirths===breeding.stats.births)return;
 stockCount=ecology.animals.length;stockDeaths=ecology.stats.deaths;stockBirths=breeding.stats.births;
 dispatchEvent(new CustomEvent('aquarium-stock-change',{detail:ecology.animals.map(({id,kind,species,variant,alive})=>({id,kind,species,variant:variant??null,alive}))}));
}
function drawEcologyDetails(elapsed,all,advance){
 const v=ecologyVisuals;if(!v)return;let eggCount=0;for(const batch of breeding.eggs)for(let i=0;i<batch.count&&eggCount<80;i++){const o=v.dummy;o.position.set(batch.position.x+Math.sin(i*2.4)*.045,batch.position.y+(i%3)*.025,batch.position.z+Math.cos(i*2.4)*.035);o.rotation.set(0,0,0);o.scale.setScalar(1);o.updateMatrix();v.eggs.setMatrixAt(eggCount++,o.matrix);}v.eggs.count=eggCount;v.eggs.instanceMatrix.needsUpdate=true;let dirt=0,shell=0;
 for(const d of ecology.deposits){
  if(d.kind==='corpse')continue;
  if(advance){
  if(d.kind==='molt'&&!d.shellScale){const owner=all.find(a=>a.life.id===d.owner);if(owner){d.shellScale=owner.metric.lengthWorld/(.95*25/32);const foot=animalPoint(owner,'foot');d.position={x:foot.x,y:foot.y+.08*d.shellScale,z:foot.z};d.supportY=d.position.y;}}
  if(d.kind==='feces'){const emitter=all.find(a=>a.life.id===d.owner&&a.life.alive);if(emitter&&!d.motion){const vent=animalPoint(emitter,'vent');d.position={x:vent.x,y:vent.y,z:vent.z};}AquariumWasteMotion.step(THREE,d,elapsed,emitter?animalWasteSource(emitter):null,collisionWorld);}
  else{const from=new THREE.Vector3(d.position.x,d.position.y,d.position.z),to=from.clone();to.y-=elapsed*.25;const hit=collisionWorld.moveSphere(from,to,.035);d.position={x:hit.position.x,y:d.kind==='molt'?Math.max(d.supportY??bedLevel+.12,hit.position.y):hit.position.y,z:hit.position.z};}
  }
  const o=v.dummy;o.position.set(d.position.x,d.position.y,d.position.z);o.quaternion.identity();o.rotation.set(0,0,0);
  if(d.kind==='molt'){o.quaternion.copy(camera.quaternion);o.scale.setScalar((d.shellScale||1)*Math.max(.1,d.amount/d.initial));o.updateMatrix();v.shells.setMatrixAt(shell++,o.matrix);}
  else{if(d.kind==='feces'&&d.motion?.phase!=='settled')o.scale.set(.027,.065,.027);else o.scale.set(.06,.027,.035);o.scale.multiplyScalar(Math.max(.15,Math.cbrt(d.amount/.025)));o.updateMatrix();v.dirt.setMatrixAt(dirt++,o.matrix);}
 }
 v.dirt.count=dirt;v.shells.count=shell;v.dirt.instanceMatrix.needsUpdate=v.shells.instanceMatrix.needsUpdate=true;
 for(let i=0;i<ecology.patches.length;i++){
  const patch=ecology.patches[i],o=v.dummy;o.position.set(patch.position.x,patch.position.y,patch.position.z);o.rotation.set(i<10?-Math.PI/2:0,0,0);o.scale.setScalar(Math.sqrt(patch.amount));o.updateMatrix();v.algae.setMatrixAt(i,o.matrix);
 }
 v.algae.count=ecology.patches.length;v.algae.instanceMatrix.needsUpdate=true;if(advance)retireSpentYoung();notifyStockChange();
}

const tankCheckpoints=AquariumEcosystemCheckpointV1.create({ecology:AquariumEcology,breeding:AquariumBreeding,water:AquariumWaterEcosystem});
const tankEnvelope=AquariumTankEnvelope.createCodec({checkpointCodec:tankCheckpoints,catalog:[
 ...AquariumDesignerModel.catalog.map(({id,placement})=>({id,placement})),
 ...['classic-stem','anubias','vallisneria','alternanthera','pixel-driftwood','slate-rock','river-rock'].map(id=>({id,placement:'transform'}))
]});
function captureRuntimeBindings(){
 const actors=[...fish,...shrimps,...snails].map(a=>({id:a.life.id,kind:a.kind,phase:a.phase,facing:a.facing,fishChoice:a.fishChoice,color:a.color??null,stage:a.stage,growthAgeDays:a.growthAgeDays??null,position:a.o.position.toArray(),quaternion:a.o.quaternion.toArray(),visible:a.o.visible,seenMolt:a.seenMolt,moltStarted:Number.isFinite(a.moltStarted)?a.moltStarted:null,corpseId:a.corpseId??null,surface:a.surfaceMotion?{kind:a.surfaceMotion.kind,surface:a.surfaceMotion.surface,pane:a.surfaceMotion.pane??null,position:a.surfaceMotion.position.toArray(),facing:a.surfaceMotion.facing}:null}));
 const foodIds=new Set(ecology.food.map(f=>f.id)),food=pellets.filter(p=>foodIds.has(p.food.id)).map(p=>({id:p.food.id,position:p.o.position.toArray(),velocity:p.velocity.toArray(),quaternion:p.o.quaternion.toArray(),visible:p.o.visible,delay:p.delay,lastT:p.lastT,settled:p.settled,landedOn:p.o.userData.landedOn??null}));
 return {actors,food};
}
function restoreAnimalBindings(actors){
 for(const a of actors){
  const life=ecology.animals.find(l=>l.id===a.id),original=JSON.parse(JSON.stringify(life));
  const entry=animal(a.kind,...a.position,1,a.phase,a.facing,life.species,{id:a.id,sex:life.sex,maturity:life.maturity,fish:a.fishChoice,color:a.color,stage:a.stage,growthAgeDays:a.growthAgeDays??undefined,glassPane:a.surface?.pane??undefined});
  Object.assign(entry.life,original);
  if(a.surface){entry.surfaceMotion.position.fromArray(a.surface.position);entry.surfaceMotion.surface=a.surface.surface;entry.surfaceMotion.facing=a.surface.facing;
   if(a.surface.pane){entry.surfaceMotion.pane=a.surface.pane;entry.surfaceMotion.glassHeading={along:0,up:0};entry.surfaceMotion.glassPerimeter=null;entry.surfaceMotion.glassTarget=null;setGlassPose(entry,a.surface.pane);}}
  entry.o.position.fromArray(a.position);entry.o.quaternion.fromArray(a.quaternion);entry.o.visible=a.visible;entry.seenMolt=a.seenMolt;entry.moltStarted=a.moltStarted??-Infinity;if(a.corpseId)entry.corpseId=a.corpseId;
  if(entry.motion)entry.motion.position.copy(animalPoint(entry,'bodyCenter'));
  if(entry.contact)entry.contact.visible=entry.life.alive&&a.surface?.surface!=='glass';
 }
}
function restoreFoodBindings(food){
 if(food.length){pelletMaterial=material(0xc49a61);pelletGeometry=new THREE.OctahedronGeometry(.036,0);geometries.push(pelletGeometry);}
 for(const p of food){const o=new THREE.Mesh(pelletGeometry,pelletMaterial);o.name='food-pellet';o.position.fromArray(p.position);o.quaternion.fromArray(p.quaternion);o.visible=p.visible;if(p.landedOn)o.userData.landedOn=p.landedOn;world.add(o);pellets.push({o,food:ecology.food.find(f=>f.id===p.id),velocity:new THREE.Vector3().fromArray(p.velocity),delay:p.delay,lastT:p.lastT,settled:p.settled});}
}
function exportTank(identity){
 const tank=tankEnvelope.capture({...identity,state:window.aquariumStudy.state,live:{ecology,breeding,water,accountedDissolved}});
 const {actors,food}=captureRuntimeBindings();
 return AquariumRuntimeCheckpoint.normalize({schemaVersion:1,tank,runtime:{clock,ecologyRate,conditionLevel,conditionEpoch,conditionStart,feedStarted,feedSequence,automaticFeedCount,manualFeedCount,lastFeedReason,nextFeedDue,actors,food}},tankEnvelope);
}
function placeStockAnimal(a,preferCurrent=false){
 const others=[...fish,...shrimps,...snails].filter(other=>other!==a),blockers=collisionWorld.meshes.map(mesh=>mesh.geometry.boundingBox.clone().applyMatrix4(mesh.matrixWorld));
 const glass=a.surfaceMotion?.surface==='glass',pane=a.surfaceMotion?.pane||'front',radius=a.surfaceMotion?a.metric.collision.crossSectionRadius:a.metric.collision.enclosingRadius;
 const span=a.surfaceMotion?Math.max(0,a.metric.collision.halfLength-radius):0;
 function clear(){
  const axis=new THREE.Vector3(a.metric.collision.longAxis==='x'?Math.sign(a.o.scale.x):0,a.metric.collision.longAxis==='y'?1:0,0).applyQuaternion(a.o.quaternion);
  const center=animalPoint(a,'bodyCenter'),start=center.clone().addScaledVector(axis,-span),end=center.clone().addScaledVector(axis,span);
  for(const point of [start,end])if(point.y-radius<bedLevel-.005||point.y+radius>waterLevel+.005||!glass&&(Math.abs(point.x)+radius>innerHalf||point.z-radius<backBound||point.z+radius>frontBound))return false;
  const skin=Math.max(.0001,radius-.002),direction=end.clone().sub(start),length=direction.length(),ray=length?new THREE.Ray(start,direction.normalize()):null;
  for(const bounds of blockers){
   if(!ray){if(bounds.intersectsSphere(new THREE.Sphere(center,skin)))return false;}
   else{const expanded=bounds.clone().expandByScalar(skin),hit=new THREE.Vector3();if(expanded.containsPoint(start)||ray.intersectBox(expanded,hit)&&hit.distanceTo(start)<=length)return false;}
  }
  return !others.some(other=>other.o.visible&&center.distanceTo(animalPoint(other,'bodyCenter'))<a.metric.collision.enclosingRadius+other.metric.collision.enclosingRadius+.025);
 }
 placeAnimal(a);if(preferCurrent&&clear())return;
 for(const level of glass?[.65,.4,.8,.25]:a.motion?[.65,.4,.8]:[0]){
  for(let iz=0;iz<(glass?1:7);iz++)for(let ix=0;ix<9;ix++){
   let x=(ix/8-.5)*innerHalf*1.6,z=backBound+(frontBound-backBound)*(.12+iz/6*.76);
   if(glass){if(pane==='left'||pane==='right'){x=pane==='left'?-innerHalf:innerHalf;z=backBound+(frontBound-backBound)*(.12+ix/8*.76);}else z=pane==='back'?backBound:frontBound;}
   const y=a.motion||glass?bedLevel+(waterLevel-bedLevel)*level:bedLevel+.12;
   if(a.motion)a.motion.position.set(x,y,z);else a.surfaceMotion.position.set(x,y,z);placeAnimal(a);
   if(clear())return;
  }
 }
 throw new Error('No clear place is available for this animal');
}
function reconcileStockPose(id){
 if(enabled||!designerActive||mode!=='desktop')throw new Error('Stock returns require an isolated paused editor');
 const a=[...fish,...shrimps,...snails].find(a=>a.life.id===id&&a.life.alive);if(!a)throw new Error('Returned animal is not available');
 placeStockAnimal(a,true);const mouth=animalPoint(a,'mouth');a.life.position={x:mouth.x,y:mouth.y,z:mouth.z};
 const snapshot=breeding.snapshot();for(const record of [...snapshot.parents,...snapshot.offspring])if(record.id===id)record.position={...a.life.position};
 for(const brood of snapshot.broods)if(brood.motherId===id&&brood.phase!=='deposited-eggs')brood.position={...a.life.position};
 breeding=AquariumBreeding.create({snapshot});render();return{id};
}
function addStock(request){
 if(enabled||!designerActive||mode!=='desktop')throw new Error('Stock additions require an isolated paused editor');
 const asset=AquariumTankConfiguration.stockCatalog.find(a=>a.id===request?.assetID),id=request?.id;
 if(!asset||typeof id!=='string'||!/^stock-[a-zA-Z0-9-]{1,64}$/.test(id))throw new Error('Choose a supported stock item and stable identity');
 const all=[...fish,...shrimps,...snails],reserved=breeding.broods.reduce((n,b)=>n+b.count,0),population=new Set([...ecology.animals.filter(a=>a.alive).map(a=>a.id),...breeding.offspring.map(a=>a.id)]);
 if(ecology.animals.some(a=>a.id===id))throw new Error('Stock identity is already in use');
 if(all.length>=80||population.size+reserved>=Math.min(80,breeding.snapshot().maxAnimals))throw new Error('The tank has no unreserved animal capacity');
 const phase=[...id].reduce((n,c)=>(Math.imul(n,31)+c.charCodeAt(0))>>>0,0)%100000;
 const grazer=asset.variant==='otocinclus',species=asset.kind==='snail'?asset.variant:grazer?'otocinclus':'assassin';
 const a=animal(asset.kind,0,bedLevel+.12,0,1,phase,1,species,{id,isOffspring:false,sex:phase%2?'male':'female',maturity:1,stage:'adult',fish:asset.kind==='fish'&&!grazer?asset.variant:assets.fish,color:asset.kind==='shrimp'?asset.variant:undefined,glassPane:'front'});
 placeStockAnimal(a);
 const mouth=animalPoint(a,'mouth');a.life.position={x:mouth.x,y:mouth.y,z:mouth.z};
 const supports=breedingSupports.map(s=>{s.mesh.updateWorldMatrix(true,false);const p=new THREE.Vector3().fromBufferAttribute(s.mesh.geometry.attributes.position,s.index).applyMatrix4(s.mesh.matrixWorld);return{id:s.id,kind:'plant',position:{x:p.x,y:p.y,z:p.z}};});
 breeding.synchronizeRoster(ecology.animals,{plantSupports:supports});notifyStockChange();render();return{id};
}
function prepareStockRemovalHistory(id,identity){const change=AquariumRuntimeCheckpoint.removeStock(exportTank(identity),id,tankEnvelope);return{checkpointJSON:JSON.stringify(change.checkpoint),archive:change.archive};}
function prepareStockRestoration(archive,identity){return{checkpointJSON:JSON.stringify(AquariumRuntimeCheckpoint.restoreStock(exportTank(identity),archive,tankEnvelope))};}
function prepareStockRemoval(id,identity){return AquariumRuntimeCheckpoint.removingAnimal(exportTank(identity),id,tankEnvelope);}
function restoreTankJSON(text){
 if(enabled||clock!==0||ecology.seconds!==0||feedSequence!==0||designerActive)throw new Error('Tank restoration requires a fresh paused runtime');
 const saved=AquariumRuntimeCheckpoint.importJSON(text,tankEnvelope),configuration=saved.tank.configuration,document=saved.tank.document;
 const current=window.aquariumStudy.state.physical.tankCm,g=document.layout.geometry;
 if(g.outerCm.width!==current.width||g.outerCm.depth!==current.depth||g.outerCm.height!==current.height||g.glassCm!==current.glass||g.bedCm!==current.bed||g.waterCm!==current.water)throw new Error('Unsupported physical tank geometry');
 const restored=tankCheckpoints.restore(document.checkpoint.data),r=saved.runtime;
 if(configuration.schemaVersion===2&&configuration.equipment){const checked=AquariumMetricBasicArt.create(THREE,{tankHalf,cmPerUnit,backZ:outerBack,frontZ,waterLevel,bedLevel,rimY:8.4,placementsCm:configuration.equipment});checked.dispose();}
 Object.assign(assets,configuration.assets);sceneStyle=configuration.setup;rasterHeight=configuration.rasterHeight;
 preset=configuration.light.preset;tankLightCount=configuration.light.count;lightOutput=configuration.light.output;lightSpread=configuration.light.spread;
 roomMode=configuration.room.mode;roomFinish=configuration.room.finish;if(configuration.room.manualLevel!==null)roomLevel=configuration.room.manualLevel;
 pumpOutput=configuration.pump;surfaceMode=configuration.surface;conditionMode=configuration.condition.mode;
 conditionLevel=r.conditionLevel;conditionEpoch=r.conditionEpoch;conditionStart=r.conditionStart;
 mode='desktop';designerActive=true;designerLayout={schemaVersion:1,units:'cm',name:document.layout.name,base:{setup:sceneStyle},instances:[]};
 restoringTank=true;try{build();resize();}finally{restoringTank=false;}
 const base=document.layout.objects.filter(o=>o.id.startsWith('base-')),added=document.layout.objects.filter(o=>!o.id.startsWith('base-'));
 const baseResult=applyPresetObjects({expectedRevision:presetRevision,objects:base});if(baseResult.error)throw new Error(baseResult.error);
 if(configuration.schemaVersion===2&&configuration.equipment){const eq=equipmentObjects().map(item=>({...item,positionCm:configuration.equipment[equipmentDefinitions[item.id].slot],rotationY:0}));const result=applyEquipmentObjects({expectedRevision:presetRevision,objects:eq});if(result.error)throw new Error(result.error);}
 const placement=applyDesigner({layout:{...designerLayout,instances:added}});if(placement.error||placement.status.some(s=>!s.valid))throw new Error(placement.error||'Saved specimen placement is invalid');
 ecology=restored.ecology;breeding=restored.breeding;water=restored.water;accountedDissolved=restored.accountedDissolved;
 clock=r.clock;lastSimulation=clock;ecologyRate=r.ecologyRate;feedStarted=r.feedStarted;feedSequence=r.feedSequence;automaticFeedCount=r.automaticFeedCount;manualFeedCount=r.manualFeedCount;lastFeedReason=r.lastFeedReason;nextFeedDue=r.nextFeedDue;
 restoreAnimalBindings(r.actors);restoreFoodBindings(r.food);
 drawEcologyDetails(0,[...fish,...shrimps,...snails],false);waterCondition.setLevel(conditionLevel);updateWaterTransmission();render();
 return {id:document.id,name:document.layout.name};
}
function setMotion(value){enabled=!!value;document.getElementById('motion').setAttribute('aria-pressed',String(enabled));if(handle)cancelAnimationFrame(handle);handle=0;last=0;if(enabled&&!document.hidden)handle=requestAnimationFrame(animate);else render();}
addEventListener('message',e=>{if(e.source!==parent)return;const d=e.data;if(d?.type==='aquarium-designer'){applyDesigner(d);return;}if(d?.type==='aquarium-preset-objects'){parent.postMessage({type:'aquarium-preset-state',requestId:d.requestId,...applyPresetObjects(d)},'*');return;}if(d?.type==='aquarium-maintenance'){maintainTank(d.action,d.fraction);return;}if(d?.type==='aquarium-asset')setAsset(d.kind,d.value);if(d?.type==='aquarium-resolution')setResolution(d.height);if(d?.type==='aquarium-room')setRoomMode(d.mode);if(d?.type==='aquarium-pump')setPumpOutput(d.output);if(d?.type==='aquarium-scene')setSceneStyle(d.style);if(d?.type==='aquarium-surface')setSurfaceMode(d.mode);if(d?.type==='aquarium-room-finish')setRoomFinish(d.finish);if(d?.type==='aquarium-light-spread')setLightSpread(d.spread);if(d?.type==='aquarium-light-output')setLightOutput(d.output);if(d?.type==='aquarium-banks')setTankLightCount(d.count);if(d?.type==='aquarium-ecology-rate')setEcologyRate(d.rate);if(d?.type==='aquarium-life-event')previewLifeEvent(d.event);if(d?.type==='aquarium-condition'){if(['auto','ecosystem'].includes(d.mode))setConditionMode(d.mode);else setCondition(d.level);}if(d?.type==='aquarium-view')setView(d.view);if(d?.type==='aquarium-mode')setMode(d.mode);if(d?.type==='aquarium-feed')feed();if(d?.type==='aquarium-motion')setMotion(d.enabled);if(d?.type==='aquarium-framing')setFraming(d.framing);if(d?.type==='aquarium-light')setLight(d.preset);});
document.getElementById('jar-target').addEventListener('click',event=>{event.stopPropagation();feed();});
document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>setView(b.dataset.view)));document.getElementById('motion').addEventListener('click',()=>setMotion(!enabled));
document.addEventListener('visibilitychange',()=>{if(handle)cancelAnimationFrame(handle);handle=0;last=0;if(enabled&&!document.hidden)handle=requestAnimationFrame(animate);});addEventListener('resize',resize);
function stockInventory(){
 const counts={fish:0,shrimp:0,snails:0},groups={fish:new Set(),shrimp:new Set(),snail:new Set()};
 for(const a of ecology.animals){if(!a.alive)continue;counts[a.kind==='snail'?'snails':a.kind]++;groups[a.kind].add(a.species);}
 return{...counts,fishSpecies:groups.fish.size,shrimpSpecies:groups.shrimp.size,snailSpecies:groups.snail.size};
}
function landmarks(){camera.updateMatrixWorld();const points={floorBack:[0,bedLevel,backBound],floorFront:[0,bedLevel,frontBound],bottomLeft:[-tankHalf,0,4.04],bottomRight:[tankHalf,0,4.04],frontTopLeft:[-tankHalf,8.4,4.04],frontTopRight:[tankHalf,8.4,4.04],rearTopLeft:[-tankHalf,8.4,outerBack],rearTopRight:[tankHalf,8.4,outerBack],lamp:[0,9.36,-.4],foodJarTop:[-visibleWidth*.29,10.35,-.4],surfaceBack:[0,waterLevel,backBound],surfaceFront:[0,waterLevel,frontBound],filterOutlet:[filterOutlet.x,filterOutlet.y,filterOutlet.z],woodTop:[-visibleWidth*.29-.35,6.4+bedLevel-.12,-.7]};return Object.fromEntries(Object.entries(points).map(([name,p])=>{const v=new THREE.Vector3(...p).project(camera);return[name,{x:Math.round((v.x*.5+.5)*1000)/10,y:Math.round((.5-v.y*.5)*1000)/10}];}));}
window.aquariumStudy={exportTank,addStock,reconcileStockPose,prepareStockRemovalHistory,prepareStockRestoration,prepareStockRemoval,restoreTankJSON,applyPresetObjects,applyEquipmentObjects,get equipment(){return equipmentState();},applyPlacedObjects,maintainTank,applyDesigner,get designer(){return designerState();},setGlassPane,setPumpOutput,setSceneStyle,setSurfaceMode,setRoomFinish,setLightSpread,setLightOutput,setEcologyRate,previewLifeEvent,setAsset,setCondition,setConditionMode,setResolution,setView,setFraming,setLight,setRoomLight,setTankLightCount,setRoomMode,setMotion,setMode,feed,info:()=>window.aquariumStudy.state,get state(){return{presetRevision,equipment:equipmentState(),water:{...water.readings(),elapsedSeconds:water.snapshot().elapsedSeconds,volumeL:50,volumeBasis:'authored effective water volume estimate; excludes tank glass, substrate and hardscape',massBasis:'mg nitrogen; 4 mg-N per dissolved game waste unit'},presetObjects:presetAssemblies?.snapshot()||[],designer:designerState(),glass:{panes:['front','left','right','back'],attachments:[...fish,...shrimps,...snails].filter(a=>a.surfaceMotion?.surface==='glass').map(a=>({id:a.life.id,pane:a.surfaceMotion.pane,pose:a.frames[0].pose||'legacy'}))},projection:{kind:'perspective',worldSizeChangesWithDepth:false},botanical:{species:botanicalArt?.assets.map(a=>a.species)||[],omitted:botanicalArt?.omitted||[],contacts:botanicalArt?.grazeSites.length||0},physical:{cmPerUnit,tankCm:{width:60,depth:36,height:36,glass:.6,bed:5,water:34.5},scaleStatus:'metric-reference',parts:physicalParts},sceneStyle,current:{output:pumpOutput},breeding:{broods:breeding.broods.length,eggs:breeding.eggs.reduce((n,b)=>n+b.count,0),young:breeding.offspring.length,stats:breeding.stats},navigation:{...(surfaceNavigation?.stats||{nodes:0}),canopySites:navigationSites.filter(s=>s.id?.startsWith('canopy-')).length},rasterHeight,surface:{mode:surfaceMode,impacts:surfaceStudy?.group.children.filter(o=>o.visible).length||0},premium:{implemented:!!premiumEquipment,carpet:!!lushPlants,floaters:lushPlants?.floaters.length||0},room:{finish:roomFinish,implemented:!!roomArt},ecology:{seconds:ecology.seconds,rate:ecologyRate,stats:{...ecology.stats},animals:ecology.animals.map(a=>({id:a.id,kind:a.kind,variant:a.variant??null,species:a.species,state:a.state,alive:a.alive,hunger:a.hunger,health:a.health})),deposits:ecology.deposits.length},condition:{...waterCondition?.state,mode:conditionMode},assets:{...assets},inventory:{tank:1,gravel:1,rock:assets.decor==='none'?1:0,ornament:assets.decor!=='none'?1:0,driftwood:1,fixture:1,thermometer:1,plantSpecies:sceneStyle==='lush'?4:2,filter:1,...stockInventory()},lighting:{depthSpread:lightSpread,output:lightOutput,shadows:renderer.shadowMap.enabled,shadowResolution:512,source:'Downward LED banks',roomLevel,roomMode,banks:tankLightCount,ambient:ambient.intensity,fill:fill.intensity,key:tankLights.reduce((sum,light)=>sum+light.intensity,0),shadowSources:tankLights.filter(light=>light.castShadow).length},direction:'B',view,framing,mode,preset,motion:enabled,clock,collisions:{solids:collisionWorld?.count||0,settled:pellets.filter(p=>p.settled).length,solidLandings:pellets.filter(p=>p.o.userData.landedOn==='solid').length},feeding:{automaticCount:automaticFeedCount,manualCount:manualFeedCount,lastReason:lastFeedReason,nextDue:nextFeedDue,sequence:feedSequence},renderer:'Actual pixel-textured 3D with shared A/B sprite billboards',renderedFrames,drawCalls:renderer.info.render.calls,triangles:renderer.info.render.triangles,camera:{kind:'PerspectiveCamera',fov:camera.fov,position:[0,eyeHeight,eyeDepth],target:[0,eyeHeight,0],pitchDegrees:0,horizonPercent:horizon*100,aspect:camera.aspect},world:{width:worldWidth,floorY:bedLevel,floorBackZ:backBound,floorFrontZ:frontBound,waterY:waterLevel,waterBackZ:backBound,waterFrontZ:frontBound},landmarks:landmarks()};}};
resize();setRoomMode('auto');setView('front');setMode('desktop');setMotion(enabled);parent.postMessage({type:'aquarium-ready',scene:'b',renderer:'Three.js WebGL'},'*');
})();
