(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory(require('./cleaner-poses-v2.js'));
 else root.AquariumCleanerPaneArt=factory(root.AquariumCleanerPosesV2);
})(typeof globalThis==='object'?globalThis:this,function(Base){
 'use strict';
 if(!Base||typeof Base.createSprite!=='function')throw new Error('AquariumCleanerPosesV2 must load before cleaner pane art');
 const identities=Object.freeze(['otocinclus','assassin','nerite']),panes=Object.freeze(['front','left','right','back']);
 const descriptors=Object.freeze(Object.fromEntries(identities.map(kind=>[kind,Base.descriptors[kind]])));
 function createSprite(kind,phase=0,preset='daylight',color='natural',options={}){
  if(kind==='zebra-nerite')kind='nerite';
  const pane=options.pane??'front',pose=pane==='front'?'ventral':pane==='back'?'dorsal':'lateral',variant=options.variant??0;
  if(!identities.includes(kind))throw new RangeError('Unsupported cleaner kind; only existing species have pane art');
  if(!panes.includes(pane))throw new RangeError('Unknown glass pane');
  if(options.pose!==undefined&&options.pose!==pose)throw new RangeError('The glass pane determines its pose');
  if(!Number.isFinite(phase))throw new RangeError('Finite phase required');
  if(!['daylight','warm','moonlight'].includes(preset))throw new RangeError('Unknown lighting preset');
  if(color!=='natural')throw new RangeError('Unknown cleaner color');
  if(!Number.isInteger(variant)||variant<0||variant>1023)throw new RangeError('variant must be an integer in [0,1023]');
  const sprite=pane==='back'?dorsal(kind,phase,preset,variant,options):Base.createSprite(kind,phase,preset,color,{...options,pose});
  sprite.pane=pane;
  sprite.bodyReferenceAxis={axis:pose==='lateral'?'x':'y',heading:pose==='lateral'?[1,0]:[0,-1],space:'image-pixels'};
  return sprite;
 }
 function dorsal(kind,phase,preset,variant,options){
  const canvas=options.createCanvas?options.createCanvas():typeof document==='object'?document.createElement('canvas'):null;
  if(!canvas)throw new Error('createCanvas required outside browser');
  const oto=kind==='otocinclus';[canvas.width,canvas.height]=oto?[32,48]:[36,46];
  const context=canvas.getContext('2d');if(!context)throw new Error('2d canvas context required');context.imageSmoothingEnabled=false;context.globalAlpha=1;
  const frame=((Math.floor(phase)%4)+4)%4,sway=[-1,0,1,0][frame],parts=new Map(),pixels=new Map(),attachments=[];
  const palette={body:'#757c67',shade:'#555d4d',dark:'#30382d',mottle:'#4c5445',light:'#afb69b',fin:'#7f917a',ray:'#b3b99b',eye:'#202b27',belly:'#e0d7b5',mouth:'#6c6552',foot:'#a5ad94',footLight:'#cbd0b3',footShade:'#7b8b77',gold:'#bd9547',goldLight:'#dfbc6c',shellDark:'#413b2e',shellShade:'#6a5037',shellLight:'#daae94'};
  const gain=preset==='warm'?[1.08,.94,.79]:preset==='moonlight'?[.48,.65,.89]:[1,1,1],variation=1+(variant%11)*.007;
  const colors=Object.fromEntries(Object.entries(palette).map(([name,value])=>[name,'#'+value.slice(1).match(/../g).map((v,i)=>Math.min(255,Math.round(parseInt(v,16)*gain[i]*variation)).toString(16).padStart(2,'0')).join('')]));
  function pixel(part,x,y,shade){
   if(!Number.isInteger(x)||!Number.isInteger(y)||x<0||y<0||x>=canvas.width||y>=canvas.height)throw new RangeError('Cleaner pixel must be an integer inside the canvas');
   const id=y*canvas.width+x;if(!parts.has(part))parts.set(part,new Set());parts.get(part).add(id);pixels.set(id,{part,color:colors[shade]});
  }
  function rect(part,x,y,w,h,shade){for(let row=y;row<y+h;row++)for(let col=x;col<x+w;col++)pixel(part,col,row,typeof shade==='function'?shade(col,row):shade);}
  function ellipse(part,cx,cy,rx,ry,shade){for(let y=Math.ceil(cy-ry);y<=Math.floor(cy+ry);y++)for(let x=Math.ceil(cx-rx);x<=Math.floor(cx+rx);x++)if(((x-cx)/rx)**2+((y-cy)/ry)**2<=1.000001)pixel(part,x,y,typeof shade==='function'?shade(x,y):shade);}
  function line(part,points,shade){for(let i=1;i<points.length;i++){let[x,y]=points[i-1];const[tx,ty]=points[i],dx=Math.abs(tx-x),dy=-Math.abs(ty-y),sx=x<tx?1:-1,sy=y<ty?1:-1;let error=dx+dy;for(;;){pixel(part,x,y,shade);if(x===tx&&y===ty)break;const twice=error*2;if(twice>=dy){error+=dy;x+=sx;}if(twice<=dx){error+=dx;y+=sy;}}}}
  function polygon(part,vertices,shade){
   const ys=vertices.map(p=>p[1]);for(let y=Math.min(...ys);y<=Math.max(...ys);y++){const intersections=[];for(let i=0;i<vertices.length;i++){const a=vertices[i],b=vertices[(i+1)%vertices.length];if((a[1]<=y&&b[1]>y)||(b[1]<=y&&a[1]>y))intersections.push(a[0]+(y-a[1])*(b[0]-a[0])/(b[1]-a[1]));}intersections.sort((a,b)=>a-b);for(let i=0;i+1<intersections.length;i+=2)for(let x=Math.ceil(intersections[i]);x<=Math.floor(intersections[i+1]);x++)pixel(part,x,y,shade);}line(part,[...vertices,vertices[0]],shade);
  }
  function join(part,parent,at){attachments.push({part,parent,at:at.slice()});}
  function fin(part,vertices,root){polygon(part,vertices,'fin');line(part,[root,vertices[1]],'ray');join(part,'body',root);}
  let contact,axis,axisPixels;
  if(oto){
   // The underside layers remain hidden projection masks for the approved scale adapter.
   ellipse('belly',16,20,3,9,'belly');ellipse('mouth',16,10,2,2,'mouth');
   const widths=[3,5,6,7,7,7,6,6,6,6,6,5,5,5,5,5,4,4,4,4,3,3,3,3,2,2,2,2,1,1,1];
   widths.forEach((half,i)=>{
    const y=5+i;rect('body',16-half,y,half*2+1,1,(x)=>Math.abs(x-16)>half*.65?'shade':i<9?'body':'light');
    if(i>2&&i<27){pixel('stripe',16-half,y,'dark');pixel('stripe',16+half,y,'dark');}
    for(let x=16-half+1;x<16+half;x++)if((x*5+y*3+variant)%11<3)pixel('mottle',x,y,'mottle');
   });
   fin('pectoral-left',[[11,15],[4,17+sway],[7,23],[12,19]],[11,15]);
   fin('pectoral-right',[[21,15],[28,17-sway],[25,23],[20,19]],[21,15]);
   fin('pelvic-left',[[13,27],[8,30],[13,31],[14,28]],[13,27]);
   fin('pelvic-right',[[19,27],[24,30],[19,31],[18,28]],[19,27]);
   fin('caudal',[[16,34],[10,44],[16,41],[22,44]],[16,34]);
   polygon('dorsal',[[16,17],[18,20],[17,26],[15,24]],'shade');line('dorsal',[[16,17],[17+[0,1,0,-1][frame],22],[16,25]],'ray');join('dorsal','body',[16,17]);
   pixel('eyes',10,10,'eye');pixel('eyes',22,10,'eye');pixel('eyes',10,9,'light');pixel('eyes',22,9,'light');
   rect('gill',11,12,1,2,frame<2?'light':'shade');rect('gill',21,12,1,2,frame%2?'shade':'light');
   contact={kind:'sucker-mouth',surface:'image-plane',point:[16,10],mouth:[16,10],patchPixels:[[15,10],[16,10],[17,10]],heading:[0,-1],occluded:true};
   axis='y';axisPixels=[[16,5],[10,44]];
  }else{
   rect('mouth',17,14,3,2,'mouth');
   ellipse('foot',18,27,7,11,(x,y)=>(x+y+frame)%9===0?'footLight':Math.abs(x-18)>5?'footShade':'foot');
   ellipse('foot',18,15,4,4,(x,y)=>(x+y+frame)%9===0?'footLight':'foot');
   for(const side of [-1,1]){
    const root=[18+side*3,13],tip=[18+side*(10+sway),7+(side>0?frame%2:0)];
    line('tentacles',[root,[18+side*6,10],tip],'footLight');join('tentacles','foot',root);
   }
   if(kind==='assassin'){
    line('siphon',[[22,18],[26,12],[25+sway,6]],'footShade');line('siphon',[[21,18],[25,12],[24+sway,6]],'footLight');join('siphon','foot',[22,18]);
    for(let y=14;y<=40;y++){
     const radius=y<=23?9*Math.sqrt(Math.max(0,1-((y-23)/9)**2)):Math.max(.6,9*((40-y)/17)**.75*(.94+.06*Math.cos((y-23)*1.1)));
     for(let x=Math.ceil(18-radius);x<=Math.floor(18+radius);x++){
      const band=Math.sin((y-14)*.66+Math.abs(x-18)*.12+variant*.3)>.08;
      pixel('shell',x,y,band?(x<18?'goldLight':'gold'):x<18?'shellShade':'shellDark');
     }
    }
    axis='y';axisPixels=[[18,14],[18,40]];
   }else{
    ellipse('shell',18,26,13,12,(x,y)=>{
     const angle=Math.atan2(y-29,x-16),ridge=Math.sin(angle*11+(Math.hypot(x-16,y-29))*.18+variant*.3)>.1;
     return ridge?'shellDark':x+y<42?'goldLight':x+y>56?'shellShade':'gold';
    });
    axis='x';axisPixels=[[5,26],[31,26]];
   }
   pixel('eyes',15,13,frame===3?'footShade':'eye');pixel('eyes',21,13,'eye');
   join('shell','foot',[18,26]);join('mouth','foot',[18,15]);
   contact={kind:'muscular-foot',surface:'image-plane',point:[18,26],mouth:[18,15],patchPixels:[],heading:[0,-1],occluded:true};
   for(let y=23;y<=29;y++)for(let x=16;x<=20;x++)contact.patchPixels.push([x,y]);
  }
  const decode=id=>[id%canvas.width,Math.floor(id/canvas.width)],bounds={minX:Infinity,minY:Infinity,maxX:-Infinity,maxY:-Infinity},visibleCounts={};
  for(const[id,paint]of pixels){const[x,y]=decode(id);context.fillStyle=paint.color;context.fillRect(x,y,1,1);visibleCounts[paint.part]=(visibleCounts[paint.part]||0)+1;bounds.minX=Math.min(bounds.minX,x);bounds.minY=Math.min(bounds.minY,y);bounds.maxX=Math.max(bounds.maxX,x);bounds.maxY=Math.max(bounds.maxY,y);}
  const spanPixels=1+Math.abs(axisPixels[1][axis==='x'?0:1]-axisPixels[0][axis==='x'?0:1]),descriptor=descriptors[kind];
  return{canvas,kind,pose:'dorsal',frame,frameCount:4,secondsPerFrame:oto?.32:.6,anchorX:contact.point[0]+.5,anchorY:contact.point[1]+.5,contact,measurements:{basis:descriptor.basis,axis,axisPixels,spanPixels,targetCm:descriptor.targetCm,cmPerPixel:descriptor.targetCm/spanPixels,includes:oto?'caudal fin':'shell only; excludes exposed foot, tentacles and horns',calibrationStatus:'new-pose-calibration-required'},bounds,reviewOnly:false,anatomy:{parts:Object.fromEntries([...parts].map(([name,ids])=>[name,[...ids].sort((a,b)=>a-b).map(decode)])),attachments,visibleCounts,occludedParts:oto?['belly','mouth']:['mouth']}};
 }
 return{createSprite,identities,panes,descriptors};
});
