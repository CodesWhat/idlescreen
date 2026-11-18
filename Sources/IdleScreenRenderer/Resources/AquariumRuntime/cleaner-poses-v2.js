(function(root,factory){
 'use strict';
 if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumCleanerPosesV2=factory();
})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 const descriptors={
  otocinclus:{scientificName:'Otocinclus spp.',referenceCm:[4,5],selectedRangeCm:[4,5],targetCm:4.5,basis:'total-length',reviewOnly:false,source:'https://www.aquariumcoop.com/blogs/aquarium/otocinclus-catfish',uncertainty:'Generic common oto appearance; the genus contains several traded species.'},
  assassin:{scientificName:'Anentome helena (trade name Clea helena)',referenceCm:[2.5,2.5],selectedRangeCm:[2,2.5],targetCm:2.3,basis:'shell-length',reviewOnly:false,source:'https://aquaticarts.com/products/assassin-snails',uncertainty:'Catalog adult length is approximate; selected range is an art choice.'},
  nerite:{scientificName:'Zebra nerite, sold as Neritina natalensis',referenceCm:[1.27,2.54],selectedRangeCm:[2,2.54],targetCm:2.2,basis:'shell-diameter',reviewOnly:false,source:'https://aquaticarts.com/pages/zebra-nerite-snail-care-guide',uncertainty:'Trade identification retained without a taxonomic revision.'},
  'horned-nerite':{scientificName:'Clithon corona/diadema trade group',referenceCm:[.64,1.3],selectedRangeCm:[.9,1.3],targetCm:1.1,basis:'shell-diameter',reviewOnly:true,source:'https://aquaticarts.com/products/zebra-thorn-nerite-snails',uncertainty:'Aquatic Arts lists .64–1.3 cm; Buce lists 2.54 cm. Shell versus horn measurement and trade identity are unresolved.'},
  'orange-rabbit':{scientificName:'Tylomelania, sold as T. gemmifera Orange',referenceCm:[7.6,7.6],selectedRangeCm:[5,7.6],targetCm:6.5,basis:'shell-length',reviewOnly:true,source:'https://buceplant.com/products/orange-poso-rabbit-snail',uncertainty:'Catalog trade identification, not a verified specimen. Selected subadult-sized shell; no tank suitability claim.'},
  ramshorn:{scientificName:'Planorbella duryi, catalog identification',referenceCm:[2.5,2.5],selectedRangeCm:[1.5,2.5],targetCm:2,basis:'shell-diameter',reviewOnly:true,source:'https://buceplant.com/products/ramshorn-snails',uncertainty:'Catalog states up to 2.5 cm; selected range is authored, not a measured population distribution.'}
 };
 for(const d of Object.values(descriptors)){Object.freeze(d.referenceCm);Object.freeze(d.selectedRangeCm);Object.freeze(d);}Object.freeze(descriptors);
 const identities=Object.freeze(Object.keys(descriptors)),aliases={'zebra-nerite':'nerite','rabbit-snail':'orange-rabbit','orange-rabbit-snail':'orange-rabbit'};
 function createSprite(kind,phase=0,preset='daylight',color='natural',options={}){
  kind=aliases[kind]||kind;const descriptor=descriptors[kind],pose=options.pose||'lateral',variant=options.variant??0;
  if(!descriptor)throw new RangeError('Unknown cleaner kind');
  if(!['ventral','lateral'].includes(pose))throw new RangeError('Unknown contact pose');
  if(!Number.isFinite(phase))throw new RangeError('Finite phase required');
  if(!['daylight','warm','moonlight'].includes(preset))throw new RangeError('Unknown lighting preset');
  if(!Number.isInteger(variant)||variant<0||variant>1023)throw new RangeError('variant must be an integer in [0,1023]');
  if(!['natural',...(kind==='ramshorn'?['red','pink','brown']:[])].includes(color))throw new RangeError('Unknown color for cleaner kind');
  const canvas=options.createCanvas?options.createCanvas():typeof document==='object'?document.createElement('canvas'):null;
  if(!canvas)throw new Error('createCanvas required outside browser');
  const ventral=pose==='ventral',oto=kind==='otocinclus',rabbit=kind==='orange-rabbit',ram=kind==='ramshorn',horn=kind==='horned-nerite',cone=kind==='assassin'||rabbit;
  [canvas.width,canvas.height]=oto?(ventral?[32,48]:[50,28]):rabbit?(ventral?[38,60]:[56,38]):ventral?[36,46]:[38,34];
  const g=canvas.getContext('2d');if(!g)throw new Error('2d canvas context required');g.imageSmoothingEnabled=false;g.globalAlpha=1;
  const frame=((Math.floor(phase)%4)+4)%4,sway=[-1,0,1,0][frame],pixels=new Map(),parts=new Map(),attachments=[],palette={
   dark:'#30342c',shade:'#59604b',body:'#898e70',light:'#c5c6a6',belly:'#e0d7b5',fin:'#7f917a',ray:'#b3b99b',eye:'#202b27',mouth:'#6c6552',
   foot:rabbit?'#db8f1c':ram?'#a95c52':'#a5ad94',footLight:rabbit?'#ffc449':ram?'#d58a73':'#cbd0b3',footShade:rabbit?'#ab6619':ram?'#793f3a':'#7b8b77',
   gold:'#bd9547',goldLight:'#dfbc6c',shellDark:'#413b2e',shellShade:'#6a5037',shellPink:'#bd7764',shellLight:'#daae94'
  };
  if(ram&&color==='pink'){palette.foot='#d39d95';palette.footLight='#efd0bc';palette.footShade='#b47a72';palette.shellPink='#cca99c';palette.shellLight='#e4c8ad';}
  if(ram&&color==='brown'){palette.foot='#82634e';palette.footLight='#af9270';palette.footShade='#654632';palette.shellPink='#8b6245';palette.shellLight='#c0966b';}
  const gains=preset==='warm'?[1.08,.94,.79]:preset==='moonlight'?[.48,.65,.89]:[1,1,1],variation=1+(variant%11)*.007;
  const colors=Object.fromEntries(Object.entries(palette).map(([k,c])=>[k,'#'+c.slice(1).match(/../g).map((v,i)=>Math.min(255,Math.round(parseInt(v,16)*gains[i]*variation)).toString(16).padStart(2,'0')).join('')]));
  function p(part,x,y,shade){x=Math.round(x);y=Math.round(y);if(x<0||y<0||x>=canvas.width||y>=canvas.height)throw new RangeError('Cleaner raster exceeds canvas');const id=y*canvas.width+x;if(!parts.has(part))parts.set(part,new Set());parts.get(part).add(id);pixels.set(id,{color:colors[shade],part});}
  function rect(part,x,y,w,h,shade){for(let row=y;row<y+h;row++)for(let col=x;col<x+w;col++)p(part,col,row,typeof shade==='function'?shade(col,row):shade);}
  function line(part,points,shade){for(let i=1;i<points.length;i++){let[x,y]=points[i-1];const[tx,ty]=points[i],dx=Math.abs(tx-x),dy=-Math.abs(ty-y),sx=x<tx?1:-1,sy=y<ty?1:-1;let error=dx+dy;for(;;){p(part,x,y,shade);if(x===tx&&y===ty)break;const twice=error*2;if(twice>=dy){error+=dy;x+=sx;}if(twice<=dx){error+=dx;y+=sy;}}}}
  function ellipse(part,cx,cy,rx,ry,shade){for(let y=Math.ceil(cy-ry);y<=Math.floor(cy+ry);y++)for(let x=Math.ceil(cx-rx);x<=Math.floor(cx+rx);x++)if(((x-cx)/rx)**2+((y-cy)/ry)**2<=1.00001)p(part,x,y,typeof shade==='function'?shade(x,y):shade);}
  function poly(part,vertices,shade){const minY=Math.min(...vertices.map(p=>p[1])),maxY=Math.max(...vertices.map(p=>p[1]));for(let y=minY;y<=maxY;y++){const xs=[];for(let i=0;i<vertices.length;i++){const a=vertices[i],b=vertices[(i+1)%vertices.length];if((a[1]<=y&&b[1]>y)||(b[1]<=y&&a[1]>y))xs.push(a[0]+(y-a[1])*(b[0]-a[0])/(b[1]-a[1]));}xs.sort((a,b)=>a-b);for(let i=0;i+1<xs.length;i+=2)for(let x=Math.ceil(xs[i]);x<=Math.floor(xs[i+1]);x++)p(part,x,y,shade);}line(part,[...vertices,vertices[0]],shade);}
  function join(part,parent,at){attachments.push({part,parent,at:at.slice()});}
  function fin(name,vertices,root,rays=true){poly(name,vertices,'fin');if(rays)line(name,[root,vertices[1]],'ray');join(name,'body',root);}
  let contact,axis,axisMode;
  if(oto){
   if(ventral){
    const widths=[2,4,5,6,6,6,6,5,5,5,5,5,5,4,4,4,4,4,3,3,3,3,3,2,2,2,2,1,1,1,1];
    widths.forEach((half,i)=>rect('body',16-half,5+i,half*2+1,1,i<9?'shade':'body'));
    ellipse('belly',16,20,3,10,'belly');ellipse('belly',16,10,3,4,'light');
    fin('pectoral-left',[[11,15],[4,18+sway],[9,22],[12,18]],[11,15]);
    fin('pectoral-right',[[21,15],[28,18-sway],[23,22],[20,18]],[21,15]);
    fin('pelvic-left',[[13,27],[9,31],[14,30]],[13,27]);fin('pelvic-right',[[19,27],[23,31],[18,30]],[19,27]);
    fin('caudal',[[16,34],[10,43],[16,41],[22,43]],[16,34]);
    p('eyes',10,9,'eye');p('eyes',22,9,'eye');ellipse('mouth',16,10,2,2,'mouth');p('mouth',16,10,'dark');p('mouth',15+frame%2,11,'light');p('mouth',16,12,'footShade');
    rect('gill',12,13,1,2,frame<2?'light':'body');rect('gill',20,13,1,2,frame%2?'body':'light');
    contact={kind:'sucker-mouth',surface:'image-plane',point:[16,10],mouth:[16,10],patchPixels:[[15,10],[16,10],[17,10]],heading:[0,-1]};axis=[[16,5],[10,43]];axisMode='y';
   }else{
    poly('body',[[10,13],[16,10],[30,8],[39,10],[44,14],[44,17],[40,19],[33,19],[24,17],[15,16]],'body');
    ellipse('belly',35,16,8,2,'belly');line('stripe',[[12,14],[24,13],[35,13],[42,15]],'dark');line('stripe',[[12,15],[24,14],[35,14],[42,16]],'shade');
    fin('caudal',[[11,14],[4,7],[6,13],[4,19]],[11,14]);fin('dorsal',[[23,10],[27,3],[32,8]],[23,10]);
    fin('pectoral-left',[[35,16],[31,19+sway],[38,18]],[35,16]);fin('pectoral-right',[[37,16],[40,19],[39,17]],[37,16]);
    fin('pelvic-left',[[23,16],[20,19],[27,17]],[23,16]);fin('pelvic-right',[[26,16],[27,19],[30,17]],[26,16]);
    rect('mouth',39,18,4,3,'mouth');rect('mouth',40,20,2,1,'light');p('mouth',40+frame%2,19,'dark');p('eyes',40,12,'eye');p('eyes',40,11,'light');p('gill',37,14+Math.floor(frame/2),'light');
    contact={kind:'sucker-mouth',surface:'baseline',point:[40,20],mouth:[40,20],patchPixels:[[40,20],[41,20]],heading:[1,0]};axis=[[4,7],[44,15]];axisMode='x';
   }
  }else{
   let footCenter,mouth,soleY,shellJoin;
   const shellShade=(x,y,cx,cy,rx,ry)=>{if(ram)return((x-cx)/rx+(y-cy)/ry)<-.25?'shellLight':'shellPink';const stripe=Math.sin((x-cx)*.82+(y-cy)*.35+(y-cy)**2*.018+variant*.31)>.1;return stripe?'shellDark':y<cy?'goldLight':'gold';};
   function roundShell(cx,cy,rx,ry){ellipse('shell',cx,cy,rx,ry,(x,y)=>shellShade(x,y,cx,cy,rx,ry));}
   function coneShell(a,b,radius){
    const vx=b[0]-a[0],vy=b[1]-a[1],length=Math.hypot(vx,vy),ux=vx/length,uy=vy/length,end=[Math.round(b[0]+ux*radius),Math.round(b[1]+uy*radius)];
    for(let y=1;y<canvas.height-1;y++)for(let x=1;x<canvas.width-1;x++){
     const dx=x-a[0],dy=y-a[1],t=(dx*ux+dy*uy)/length,side=-dx*uy+dy*ux;if(t<0||t>1+radius/length)continue;
     const r=t>1?radius*Math.sqrt(Math.max(0,1-((t-1)*length/radius)**2)):Math.max(.6,radius*Math.pow(t,.8)*(.92+.08*Math.cos(t*Math.PI*12)));
     if(Math.abs(side)>r)continue;const ridge=Math.cos(t*Math.PI*12+side*.12)>.72,band=Math.sin(t*Math.PI*9+side*.22+variant*.3)>.05;
     p('shell',x,y,rabbit?(ridge?'shellShade':side<0?'shellDark':'dark'):(band?(side<0?'goldLight':'gold'):'shellDark'));
    }
    p('shell',...a,'shellShade');p('shell',...end,'shellDark');return end;
   }
   function foot(cx,cy,rx,ry){ellipse('foot',cx,cy,rx,ry,(x,y)=>((ventral?y:x)+frame)%9===0?'footLight':Math.abs(x-cx)>rx*.72?'footShade':'foot');}
   if(ventral){
    if(cone){axis=rabbit?[[11,53],[20,20]]:[[12,39],[18,16]];axis[1]=coneShell(...axis,rabbit?9:8);axisMode='diagonal';}
    else{roundShell(18,26,ram?6:12,ram?13:11);axis=ram?[[18,13],[18,39]]:[[6,26],[30,26]];axisMode=ram?'y':'x';}
    if(horn)for(const [a,b]of[[[9,19],[4,15]],[[12,17],[10,11]],[[22,17],[25,11]],[[28,22],[33,19]],[[28,31],[33,33]]]){line('horns',[a,b],'shellDark');line('horns',[a,[a[0]+1,a[1]+1]],'shellShade');join('horns','shell',a);}
    const cx=rabbit?20:18,cy=rabbit?30:26;foot(cx,cy,ram?5:7,rabbit?14:11);footCenter=[cx,cy];mouth=[cx,rabbit?17:15];
    ellipse('foot',cx,mouth[1]+2,ram?4:5,3,'footLight');shellJoin=[cx,cy];
    if(rabbit){rect('snout',cx-3,16,7,8,'foot');for(let y=17;y<23;y+=2)rect('snout',cx-2,y,5,1,'footShade');join('snout','foot',[cx,23]);}
    for(const side of[-1,1]){const root=[cx+side*4,mouth[1]+2],tip=[cx+side*(10+sway),mouth[1]-5+(side<0?frame%2:0)];line('tentacles',[root,[cx+side*7,mouth[1]-1],tip],'footLight');join('tentacles','foot',root);p('eyes',...root,'eye');}
    if(kind==='assassin'){line('siphon',[[cx+4,19],[cx+8,13],[cx+7+sway,9]],'footShade');line('siphon',[[cx+5,19],[cx+9,13],[cx+8+sway,9]],'footLight');join('siphon','foot',[cx+4,19]);}
    rect('mouth',mouth[0]-1,mouth[1],3,2,'footShade');p('mouth',mouth[0]+frame%2,mouth[1],'dark');
    contact={kind:'muscular-foot',surface:'image-plane',point:footCenter,mouth,patchPixels:[],heading:[0,-1]};for(let y=cy-3;y<=cy+3;y++)for(let x=cx-2;x<=cx+2;x++)contact.patchPixels.push([x,y]);
   }else{
    soleY=rabbit?32:ram?29:27;const cx=rabbit?32:19,rx=rabbit?17:13;foot(cx,soleY-2,rx,2);rect('foot',rabbit?17:8,soleY-1,rabbit?31:23,2,'footLight');
    if(cone){axis=rabbit?[[5,5],[36,23]]:[[6,5],[24,19]];axis[1]=coneShell(...axis,rabbit?7.5:7);axisMode='diagonal';}
    else{roundShell(16,ram?16:16,ram?11:10,ram?11:9);axis=ram?[[5,16],[27,16]]:[[6,16],[26,16]];axisMode='x';}
    if(horn)for(const [a,b]of[[[8,11],[4,7]],[[12,8],[11,3]],[[19,8],[22,3]],[[24,12],[29,9]],[[25,19],[30,20]]]){line('horns',[a,b],'shellDark');line('horns',[a,[a[0]+1,a[1]]],'shellShade');join('horns','shell',a);}
    if(ram){const curve=[];for(let i=0;i<=64;i++){const t=i/64*4*Math.PI,r=.6+i/64*9.4;curve.push([Math.round(16+Math.cos(t)*r),Math.round(16+Math.sin(t)*r)]);}line('spiral',curve,'footShade');}
    const hx=rabbit?45:30;ellipse('foot',hx-1,soleY-3,rabbit?4:3,3,'foot');mouth=[hx,soleY];footCenter=[rabbit?32:19,soleY];shellJoin=rabbit?[32,29]:kind==='assassin'?[20,24]:ram?[16,27]:[16,25];
    if(rabbit){rect('snout',42,26,7,7,'foot');for(let y=27;y<32;y+=2)rect('snout',43,y,5,1,'footShade');join('snout','foot',[45,29]);}
    for(const side of[-1,1]){const root=[hx-1,soleY-4],tip=[hx+5,soleY-7+side+sway];line('tentacles',[root,[hx+2,soleY-6],tip],side<0?'footLight':'footShade');join('tentacles','foot',root);}
    if(kind==='assassin'){line('siphon',[[28,24],[31,19],[33+sway,16]],'footShade');line('siphon',[[29,24],[32,19],[34+sway,16]],'footLight');join('siphon','foot',[29,24]);}
    p('eyes',hx-1,soleY-4,'eye');rect('mouth',hx-1,soleY-1,2,2,'footShade');p('mouth',hx,soleY-1,'dark');
    contact={kind:'muscular-foot',surface:'baseline',point:footCenter,mouth,patchPixels:[],heading:[1,0]};for(let x=rabbit?19:9;x<=(rabbit?43:28);x++)contact.patchPixels.push([x,soleY]);
   }
   join('shell','foot',shellJoin);join('mouth','foot',mouth);
  }
  const decode=id=>[id%canvas.width,Math.floor(id/canvas.width)],visibleCounts={},bounds={minX:Infinity,minY:Infinity,maxX:-Infinity,maxY:-Infinity};
  for(const[id,pixel]of pixels){const[x,y]=decode(id);g.fillStyle=pixel.color;g.fillRect(x,y,1,1);visibleCounts[pixel.part]=(visibleCounts[pixel.part]||0)+1;bounds.minX=Math.min(bounds.minX,x);bounds.maxX=Math.max(bounds.maxX,x);bounds.minY=Math.min(bounds.minY,y);bounds.maxY=Math.max(bounds.maxY,y);}
  const dx=Math.abs(axis[1][0]-axis[0][0]),dy=Math.abs(axis[1][1]-axis[0][1]),axisLength=Math.hypot(dx,dy);
  const spanPixels=axisMode==='diagonal'?axisLength+(dx+dy)/axisLength:1+(axisMode==='x'?dx:dy);
  const measurements={basis:descriptor.basis,axis:axisMode,axisPixels:axis,spanPixels,targetCm:descriptor.targetCm,cmPerPixel:descriptor.targetCm/spanPixels,includes:oto?'caudal fin':'shell only; excludes exposed foot, tentacles and horns',calibrationStatus:descriptor.reviewOnly?'art-review-only':'new-pose-calibration-required'};
  return{canvas,kind,pose,frame,frameCount:4,secondsPerFrame:oto?.32:.6,anchorX:contact.point[0]+.5,anchorY:contact.point[1]+(ventral?.5:1),contact,measurements,bounds,reviewOnly:descriptor.reviewOnly,anatomy:{parts:Object.fromEntries([...parts].map(([k,set])=>[k,[...set].sort((a,b)=>a-b).map(decode)])),attachments,visibleCounts}};
 }
 return{createSprite,identities,descriptors};
});
