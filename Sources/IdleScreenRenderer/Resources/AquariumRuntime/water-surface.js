(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumWaterSurface=factory();})(typeof globalThis==='object'?globalThis:this,function(){
 'use strict';
 const settings={calm:{height:.012,flow:.025,ripple:.60},current:{height:.052,flow:.085,ripple:1.30},lively:{height:.075,flow:.115,ripple:1.55}};
 function create(THREE,{mesh,halfWidth,level,clippingPlanes=[],centerZ=.7}){
  if(!Number.isFinite(centerZ))throw new RangeError('Water centerZ must be finite');
  let mode='current',serial=0,flowField=null;const group=new THREE.Group();group.name='water-surface-impacts';
  const geometry=new THREE.RingGeometry(.92,1,48),materials=[],impacts=[];
  for(let i=0;i<8;i++){
   const material=new THREE.MeshBasicMaterial({color:0xc8dcd4,transparent:true,opacity:0,depthWrite:false,side:THREE.DoubleSide,clippingPlanes});materials.push(material);
   const ring=new THREE.Mesh(geometry,material);ring.rotation.x=-Math.PI/2;ring.visible=false;ring.name='bubble-surface-ripple';group.add(ring);impacts.push({ring,at:-Infinity});
  }
  const attribute=mesh.geometry.attributes.position,rest=new Float32Array(attribute.array);attribute.setUsage(THREE.DynamicDrawUsage);
  function emit(x,z,time){if(![x,z,time].every(Number.isFinite))return;const impact=impacts[serial++%impacts.length];impact.at=time;impact.ring.position.set(THREE.MathUtils.clamp(x,-halfWidth,halfWidth),level+.015,z);}
  function update(time){
   if(!Number.isFinite(time))return;const preset=settings[mode];
   for(let i=0;i<attribute.count;i++){
    const x=rest[i*3],z=rest[i*3+1],edge=Math.min(1,Math.max(0,(halfWidth-Math.abs(x))/.35));
    const local=flowField?.sample(x,level,centerZ-z,time),localGain=flowField?(mode==='current'&&flowField.output!==0?.60+.4*(local?.strength||0):.12+(local?.strength||0)):1;
    attribute.setZ(i,preset.height*edge*localGain*(Math.sin(z*5.7-time*1.2+x*.17)*.65+Math.sin(x*2.2+z*1.8-time*.71)*.35));
   }
   attribute.needsUpdate=true;
   if(mesh.material.map){mesh.material.map.offset.set(Math.sin(time*.12)*preset.flow,time*preset.flow*.12);}
   for(const impact of impacts){const age=time-impact.at,ring=impact.ring;ring.visible=age>=0&&age<2.1;
    if(ring.visible){ring.material.color.copy(mesh.material.color);const t=age/2.1,radius=.035+t*(.58+preset.ripple*.35);ring.scale.setScalar(radius);ring.material.opacity=.32*preset.ripple*(1-t)*(1-t);}
   }
  }
  function setMode(next){if(settings[next])mode=next;}
  return{setFlowField(field){flowField=field;},group,mesh,geometries:[geometry],materials,maps:[],emit,update,setMode,get mode(){return mode;}};
 }
 return{create};
});
