(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumRootedPlantsV2=factory();
})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 const profiles={
  'cryptocoryne-wendtii':{habit:'rosette',selectedForm:'selected compact aquarium rosette',source:'https://tropica.com/en/plants/plantdetails/Cryptocorynewendtii%27Green%27%28109TC%29/19226',catalogHeightCm:[10,30],selectedHeightCm:[12,18],bendCm:.8,palette:[0x54733a,0x668442,0x718946,0x597941]},
  'staurogyne-repens':{habit:'branching stem',selectedForm:'trimmed low creeping patch',source:'https://tropica.com/en/articles/staurogyne-repens/',catalogHeightCm:null,selectedHeightCm:[5,10],bendCm:.35,palette:[0x769b43,0x86a64d,0x699239,0x8bad55]},
  'rotala-rotundifolia':{habit:'branching stem',selectedForm:'trimmed submerged stem clump',source:'https://tropica.com/en/plants/plantdetails/Rotalarotundifolia%28033%29/4447',catalogHeightCm:[15,30],selectedHeightCm:[23,28],bendCm:1.6,palette:[0x75934a,0x87924b,0xa17e54,0xae6d60]},
  'echinodorus-tropica':{habit:'rosette',selectedForm:'compact cultivar, not a full-size Amazon sword',source:'https://dennerleplants.com/en/plants/plantdetails/Echinodorus-grisebachii-%27Tropica%27-%28456%29/27860',catalogHeightCm:[5,10],selectedHeightCm:[7,10.5],bendCm:.42,palette:[0x46743d,0x568447,0x638d49,0x4d7940]}
 };
 const aliases={crypt:'cryptocoryne-wendtii',cryptocoryne:'cryptocoryne-wendtii',staurogyne:'staurogyne-repens',rotala:'rotala-rotundifolia',sword:'echinodorus-tropica','compact-sword':'echinodorus-tropica'};
 function create(THREE,{species,seed=913,cmPerUnit=36/8.4,growth=1}={}){
  species=aliases[species]||species;const profile=profiles[species];
  if(!profile)throw new RangeError('Known rooted plant species required');
  if(!Number.isFinite(seed)||!Number.isFinite(cmPerUnit)||cmPerUnit<.1||cmPerUnit>100||!Number.isFinite(growth)||growth<=0||growth>1)throw new RangeError('Finite seed, cmPerUnit in [.1,100], and growth in (0,1] required');
  const originalSeed=seed>>>0;seed=originalSeed;const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296;};
  const u=n=>n*growth/cmPerUnit,point=p=>p.map(u),group=new THREE.Group(),geometries=[],materials=[],maps=[],grazeSites=[];
  group.name='rooted-v2-'+species;group.userData={species,softPlant:true,substratePlant:true,cmPerUnit,growth,maxBendCm:profile.bendCm*growth};
  const botany={species,seed:originalSeed,cmPerUnit,growth,habit:profile.habit,selectedForm:profile.selectedForm,source:profile.source,catalogHeightCm:profile.catalogHeightCm,selectedHeightCm:profile.selectedHeightCm,crowns:[],roots:[],stems:[],leaves:[]};
  group.userData.botany=botany;
  const batches=Object.fromEntries(['roots','stems','foliage'].map(name=>[name,{name,p:[],c:[],uv:[],index:[]}]));
  const colors=profile.palette.map(c=>new THREE.Color(c)),rootColor=new THREE.Color(0xaaa48b),stemColor=new THREE.Color(species==='rotala-rotundifolia'?0x8d7052:species==='staurogyne-repens'?0x68794a:0x657d44);
  const up=new THREE.Vector3(0,1,0),side=new THREE.Vector3(1,0,0);
  function vertex(batch,p,color,uv=[.5,.5],shade=1){const i=batch.p.length/3;batch.p.push(...point(p));batch.c.push(color.r*shade,color.g*shade,color.b*shade);batch.uv.push(...uv);return i;}
  function site(batch,index,kind,parent,radiusCm){
   const rest=batch.p.slice(index*3,index*3+3),id=species+'-'+grazeSites.length,s={id,kind,position:rest.slice(),rest,normal:[0,1,0],links:[],radius:u(radiusCm),meshName:'rooted-v2-'+batch.name,vertex:index};
   if(parent){parent.links.push(id);s.links.push(parent.id);}grazeSites.push(s);return s;
  }
  function samplePath(path){
   const result=[path[0].slice()];
   for(let i=1;i<path.length;i++){const a=path[i-1],b=path[i],steps=Math.max(1,Math.ceil(Math.hypot(...a.map((v,j)=>b[j]-v))/1.25));for(let k=1;k<=steps;k++)result.push(a.map((v,j)=>v+(b[j]-v)*k/steps));}
   return result;
  }
  function tube(batch,path,radius,color,sides=5){
   const points=samplePath(path),start=batch.p.length/3,rings=[],tangent=new THREE.Vector3(),lateral=new THREE.Vector3(),cross=new THREE.Vector3();
   for(let i=0;i<points.length;i++){
    const a=points[Math.max(0,i-1)],b=points[Math.min(points.length-1,i+1)];tangent.set(b[0]-a[0],b[1]-a[1],b[2]-a[2]).normalize();lateral.crossVectors(Math.abs(tangent.y)>.95?side:up,tangent).normalize();cross.crossVectors(tangent,lateral);
    rings.push(batch.p.length/3);const r=radius*(1-.55*i/(points.length-1));
    for(let j=0;j<sides;j++){const angle=j*Math.PI*2/sides,x=Math.cos(angle)*r,y=Math.sin(angle)*r,p=points[i].map((v,k)=>v+lateral.getComponent(k)*x+cross.getComponent(k)*y);p[1]=batch.name==='roots'?Math.min(0,p[1]):Math.max(0,p[1]);vertex(batch,p,color);}
    if(i)for(let j=0;j<sides;j++){const a=rings[i-1]+j,b=rings[i]+j,c=rings[i]+(j+1)%sides,d=rings[i-1]+(j+1)%sides;batch.index.push(a,b,c,a,c,d);}
   }
   const base=vertex(batch,points[0],color),tip=vertex(batch,points.at(-1),color);
   for(let j=0;j<sides;j++)batch.index.push(base,rings[0]+(j+1)%sides,rings[0]+j,tip,rings.at(-1)+j,rings.at(-1)+(j+1)%sides);
   return{points,rings,base,tip,range:{start,count:batch.p.length/3-start}};
  }
  function crown(p){
   botany.crowns.push(point(p));
   const batch=batches.stems,center=vertex(batch,p,stemColor),ring=[];
   for(let j=0;j<8;j++){const angle=j*Math.PI/4;ring.push(vertex(batch,[p[0]+Math.cos(angle)*.28,0,p[2]+Math.sin(angle)*.28],stemColor));}
   for(let j=0;j<8;j++)batch.index.push(center,ring[(j+1)%8],ring[j]);
   const contact=site(batch,center,'crown',null,.24);
   for(let i=0;i<5;i++){
    const angle=i*2.399+random()*.5,depth=2.65+random()*1.45,spread=.65+random()*.55;
    const path=[p,[p[0]+Math.cos(angle)*.32,-depth*.38,p[2]+Math.sin(angle)*.32],[p[0]+Math.cos(angle)*spread,-depth,p[2]+Math.sin(angle)*spread]];
    const main=tube(batches.roots,path,.085,rootColor,4);botany.roots.push({path:path.map(point),range:main.range});
    const fork=[path[1],[p[0]+Math.cos(angle+.6)*spread*1.2,-depth*.81,p[2]+Math.sin(angle+.6)*spread*1.2]];
    const branch=tube(batches.roots,fork,.045,rootColor,4);botany.roots.push({path:fork.map(point),range:branch.range});
   }
   return contact;
  }
  function stem(path,parent,parentId,radius=.10){
   const built=tube(batches.stems,path,radius,stemColor),id='stem-'+botany.stems.length,contacts=[];
   for(let i=0;i<built.points.length;i++)contacts.push(site(batches.stems,i===built.points.length-1?built.tip:built.rings[i],'stem',i?contacts[i-1]:parent,radius*.45));
   const metadata={id,parent:parentId,path:path.map(point),samples:built.points.map(point),range:built.range};botany.stems.push(metadata);
   function at(p){let index=0,distance=Infinity;for(let i=0;i<built.points.length;i++){const d=Math.hypot(...p.map((v,j)=>v-built.points[i][j]));if(d<distance){distance=d;index=i;}}return contacts[index];}
   return{id,contacts,at};
  }
  function leaf(base,length,width,yaw,lift,color,parent,pair=null){
   const crypt=species==='cryptocoryne-wendtii',sword=species==='echinodorus-tropica',rows=crypt?10:sword?8:4,columns=crypt||sword?5:3,center=(columns-1)/2;
   const corrugation=crypt?.18:sword?.035:.012,veins=sword?5:1,arch=crypt?.24:sword?.20:.07;
   const horizontal=Math.sqrt(1-lift*lift),axis=new THREE.Vector3(Math.cos(yaw)*horizontal,lift,Math.sin(yaw)*horizontal),across=new THREE.Vector3(-Math.sin(yaw),0,Math.cos(yaw)),normal=new THREE.Vector3().crossVectors(across,axis).normalize();
   const batch=batches.foliage,start=batch.p.length/3,skinStride=(rows+1)*columns;
   for(const skin of [1,-1])for(let row=0;row<=rows;row++){
    const t=row/rows,envelope=Math.pow(Math.sin(Math.PI*t),sword?.68:crypt?.85:1),half=width*.5*envelope;
    for(let col=0;col<columns;col++){
     const a=col/center-1,ruffle=corrugation*Math.sin(t*Math.PI*7)*Math.abs(a)*Math.sin(Math.PI*t),ridge=arch*Math.sin(Math.PI*t)*(1-a*a);
     const lateral=half*a*(crypt?1+.13*Math.sin(t*Math.PI*7):1),bulge=ridge+ruffle+skin*.012*Math.sin(Math.PI*t);
     const p=base.map((v,k)=>v+axis.getComponent(k)*length*t+across.getComponent(k)*lateral+normal.getComponent(k)*bulge);
     vertex(batch,p,color,[col/(columns-1),t],(skin>0?1:.72)*(col===center?1.10:sword&&(col===1||col===3)?1.04:.91));
    }
   }
   for(let skin=0;skin<2;skin++)for(let row=0;row<rows;row++)for(let col=0;col<columns-1;col++){
    const a=start+skin*skinStride+row*columns+col,b=a+columns,c=b+1,d=a+1;batch.index.push(...(skin?[a,b,c,a,c,d]:[a,c,b,a,d,c]));
   }
   for(let row=0;row<rows;row++)for(const col of [0,columns-1]){const a=start+row*columns+col,b=a+columns,c=a+skinStride,d=b+skinStride;batch.index.push(a,b,c,b,d,c);}
   let previous=parent;for(let row=crypt||sword?1:2;row<rows;row+=crypt||sword?1:2)previous=site(batch,start+row*columns+center,'leaf',previous,Math.max(.025,width*.11*Math.sin(Math.PI*row/rows)));
   const tip=base.map((v,k)=>v+axis.getComponent(k)*length),entry={base:point(base),tip:point(tip),lengthCm:length*growth,widthCm:width*growth,corrugationCm:corrugation*growth,veins,pair,stemSite:parent.id,range:{start,count:batch.p.length/3-start}};
   botany.leaves.push(entry);
  }

  if(profile.habit==='rosette'){
   const base=[0,0,0],root=crown(base),crypt=species==='cryptocoryne-wendtii',count=crypt?13:10;
   for(let i=0;i<count;i++){
    const angle=i*2.399+random()*.20,outer=i%4!==0,petiole=crypt?(i===0?6:3.5+random()*2.2):(i===0?2.5:1.6+random()*.9);
    const lean=crypt?(outer?1.8:1.1):(outer?.85:.35),tip=[Math.cos(angle)*lean,petiole,Math.sin(angle)*lean];
    const path=[base,[tip[0]*.25,petiole*.48,tip[2]*.25],tip],shoot=stem(path,root,null,crypt?.095:.13);
    const length=crypt?(i===0?11.3:8.1+random()*3):(i===0?7:5.2+random()*1.7),width=crypt?2.2+random()*.8:2.55+random()*.65;
    leaf(tip,length,width,angle,crypt?(outer?.73+random()*.11:.91):(outer?.83+random()*.08:.96),colors[i%4],shoot.contacts.at(-1));
   }
  }else{
   const rotala=species==='rotala-rotundifolia',count=rotala?5:3,main=[];
   function leafyStem(path,root,parentId,yaw){
    const shoot=stem(path,root,parentId,rotala?.075:.12);
    for(let j=1;j<path.length;j++){
     const p=path[j],t=j/(path.length-1),length=rotala?1.25+random()*.45:1.8+random()*.9,width=rotala?.32+random()*.14:.83+random()*.35;
     const pair=botany.leaves.length/2,color=rotala?colors[Math.min(3,Math.floor(t*4))]:colors[j%4],size=j===path.length-1?.62:1;
     for(let side=0;side<2;side++)leaf(p,length*size,width*size,yaw+j*Math.PI/2+side*Math.PI,.22+(t>.8?.14:0),color,shoot.at(p),pair);
    }
    return shoot;
   }
   for(let i=0;i<count;i++){
    const yaw=i*2.399,spread=rotala?1.25:1.35,base=[Math.cos(yaw)*spread,0,Math.sin(yaw)*spread],root=crown(base),height=rotala?(i===0?25.2:22.3+random()*2.4):(i===0?7:5.6+random()*1.0),nodes=rotala?16:5;
    const path=[base];for(let j=1;j<=nodes;j++){const t=j/nodes,lean=rotala?.85:1.2;path.push([base[0]+Math.cos(yaw)*lean*t*t,height*t,base[2]+Math.sin(yaw)*lean*t*t]);}
    main.push({path,root,shoot:leafyStem(path,root,null,yaw),yaw});
   }
   for(let i=0;i<(rotala?2:3);i++){
    const parent=main[i],join=parent.path[rotala?6:1],yaw=parent.yaw+.85,height=rotala?9.8:3.7,nodes=rotala?7:4,path=[join];
    for(let j=1;j<=nodes;j++){const t=j/nodes,reach=rotala?1.8:3;path.push([join[0]+Math.cos(yaw)*reach*t,join[1]+height*t*(rotala?1:t),join[2]+Math.sin(yaw)*reach*t]);}
    leafyStem(path,parent.shoot.at(join),parent.shoot.id,yaw);
   }
  }

  const data=new Uint8Array(16*32*4);
  for(let y=0;y<32;y++)for(let x=0;x<16;x++){
   const vein=Math.abs(x-7.5)<1||(species==='echinodorus-tropica'&&Math.abs(Math.abs(x-7.5)-3.5)<.6),fleck=(x*17+y*13+originalSeed)%19<3;
   data.set(vein?[248,249,230,255]:fleck?[208,220,196,255]:[231,238,218,255],(y*16+x)*4);
  }
  const texture=new THREE.DataTexture(data,16,32,THREE.RGBAFormat);texture.colorSpace=THREE.SRGBColorSpace;texture.minFilter=texture.magFilter=THREE.NearestFilter;texture.generateMipmaps=false;texture.needsUpdate=true;maps.push(texture);
  const dynamic=[],byName=new Map();
  for(const batch of Object.values(batches)){
   const geometry=new THREE.BufferGeometry();geometry.setAttribute('position',new THREE.Float32BufferAttribute(batch.p,3));geometry.setAttribute('color',new THREE.Float32BufferAttribute(batch.c,3));geometry.setAttribute('uv',new THREE.Float32BufferAttribute(batch.uv,2));geometry.setIndex(batch.index);geometry.computeVertexNormals();geometry.computeBoundingBox();geometry.computeBoundingSphere();
   const material=new THREE.MeshLambertMaterial({color:0xffffff,map:batch.name==='foliage'?texture:null,vertexColors:true,flatShading:true,side:THREE.DoubleSide}),mesh=new THREE.Mesh(geometry,material);
   mesh.name='rooted-v2-'+batch.name;mesh.userData={softPlant:true,solid:false,plantRoots:batch.name==='roots',plantFoliage:batch.name!=='roots'};mesh.castShadow=mesh.receiveShadow=true;group.add(mesh);geometries.push(geometry);materials.push(material);byName.set(mesh.name,geometry);
   if(batch.name!=='roots'){geometry.attributes.position.setUsage(THREE.DynamicDrawUsage);geometry.attributes.normal.setUsage(THREE.DynamicDrawUsage);dynamic.push({geometry,rest:geometry.attributes.position.array.slice()});}
  }
  const height=Math.max(...geometries.map(g=>g.boundingBox.max.y)),pin=u(.25),amplitude=u(profile.bendCm),phase=originalSeed*.0127,position=new THREE.Vector3(),direction=new THREE.Vector3(),inverse=new THREE.Matrix4();
  group.userData.heightCm=height*cmPerUnit;group.userData.rootDepthCm=-geometries[0].boundingBox.min.y*cmPerUnit;
  let lastTime,lastX,lastY,lastZ,lastStrength=0,disposed=false;
  function contacts(){for(const s of grazeSites){const g=byName.get(s.meshName);for(let k=0;k<3;k++){s.position[k]=g.attributes.position.array[s.vertex*3+k];s.normal[k]=g.attributes.normal.array[s.vertex*3+k];}}}
  contacts();
  function update(time,flow){
   if(disposed||!Number.isFinite(time))return;
   group.updateWorldMatrix(true,false);position.set(0,height*.65,0).applyMatrix4(group.matrixWorld);
   const sample=typeof flow?.sample==='function'?flow.sample(position.x,position.y,position.z,time):null,valid=sample&&[sample.x,sample.y,sample.z,sample.strength].every(Number.isFinite),strength=valid?Math.max(0,Math.min(1,sample.strength)):0;
   direction.set(valid?sample.x:0,valid?sample.y:0,valid?sample.z:0);inverse.copy(group.matrixWorld).invert();direction.transformDirection(inverse);
   if(time===lastTime&&direction.x===lastX&&direction.y===lastY&&direction.z===lastZ&&strength===lastStrength)return;
   if(strength||lastStrength)for(const batch of dynamic){
    const p=batch.geometry.attributes.position.array,r=batch.rest;
    for(let i=0;i<p.length;i+=3){const t=Math.max(0,Math.min(1,(r[i+1]-pin)/(height-pin))),bend=amplitude*strength*t*t*(.90+.10*Math.sin(time*.9+t*2+phase));p[i]=r[i]+direction.x*bend;p[i+1]=r[i+1]+direction.y*bend*.05;p[i+2]=r[i+2]+direction.z*bend;}
    batch.geometry.attributes.position.needsUpdate=true;batch.geometry.computeVertexNormals();batch.geometry.computeBoundingBox();batch.geometry.computeBoundingSphere();
   }
   contacts();lastTime=time;lastX=direction.x;lastY=direction.y;lastZ=direction.z;lastStrength=strength;
  }
  function dispose(){if(disposed)return;disposed=true;for(const resource of [...geometries,...materials,...maps])resource.dispose();}
  return{group,geometries,materials,maps,grazeSites,update,dispose};
 }
 return{create,species:Object.freeze(Object.keys(profiles))};
});
