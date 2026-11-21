(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.runAquariumEquipmentPlacementCheck=factory();})(globalThis,function(){
 'use strict';
 return function(T,basic,connections){
  function check(value,message){if(!value)throw new Error(message);}
  const cm=36/8.4,options={bedLevel:5/cm},original=basic.create(T,options);
  check(!!original.placementsCm,'Equipment needs reusable centimeter placements');
  const moved=basic.create(T,{...options,placementsCm:{filter:{x:-15,z:8},heater:{x:23},thermometer:{x:-20}}});
  const near=(a,b)=>Math.abs(a-b)<.00002;
  const shift={x:(moved.placementsCm.filter.x-original.placementsCm.filter.x)/cm,z:(moved.placementsCm.filter.z-original.placementsCm.filter.z)/cm};
  for(const name of ['sponge-filter','filter-riser-above-water']){
   const before=new T.Box3().setFromObject(original.wetGroup.getObjectByName(name)||original.dryGroup.getObjectByName(name),true);
   const after=new T.Box3().setFromObject(moved.wetGroup.getObjectByName(name)||moved.dryGroup.getObjectByName(name),true);
   check(near(after.min.x-before.min.x,shift.x)&&near(after.max.z-before.max.z,shift.z),'Body and riser must follow the same filter placement');
  }
  check(near(moved.filterOutlet.x-original.filterOutlet.x,shift.x)&&near(moved.filterOutlet.z-original.filterOutlet.z,shift.z),'Bubble/flow outlet must follow the filter');
  check(near(moved.routes.airline.points[0][0]-original.routes.airline.points[0][0],shift.x)&&near(moved.routes.airline.points[0][2]-original.routes.airline.points[0][2],shift.z),'Airline starts at the moved port');
  check(near(moved.airlineEnd.x-original.airlineEnd.x,shift.x)&&moved.airlineEnd.z===original.airlineEnd.z,'Airline exits over the actual rear rim');
  check(near((moved.heaterEnd.x-original.heaterEnd.x)*cm,23-original.placementsCm.heater.x)&&moved.heaterEnd.z===original.heaterEnd.z,'Heater cord reroutes to its rear rim clip');
  const lead=connections.create(T,{ledEnd:[0,9.36,0],heaterEnd:moved.heaterEnd,airlineEnd:moved.airlineEnd});
  for(const [name,port]of [['heater',moved.heaterEnd],['airline',moved.airlineEnd]])check(lead.group.userData.routes[name].points[0].every((n,i)=>near(n,[port.x,port.y,port.z][i])),'Counter lead must begin at the matching rim endpoint');
  const repeated=basic.create(T,{...options,placementsCm:moved.placementsCm});check(JSON.stringify(repeated.placementsCm)===JSON.stringify(moved.placementsCm),'Placement output must round-trip as factory input');
  repeated.dispose();moved.dispose();original.dispose();for(const resource of [...lead.geometries,...lead.materials,...lead.maps])resource.dispose();
  let allocations=0;const tracked=Object.create(T);
  tracked.Group=class extends T.Group{constructor(...args){super(...args);allocations++;}};
  tracked.MeshPhongMaterial=class extends T.MeshPhongMaterial{constructor(...args){super(...args);allocations++;}};
  for(const placementsCm of [{filter:{x:29}},{filter:{z:17}},{filter:{y:6}},{heater:{z:0}},{thermometer:{rotationY:1}},{heater:{x:Infinity}},{unknown:{}},{filter:{unknown:1}}]){
   let rejected=false;try{const asset=basic.create(tracked,{...options,placementsCm});asset.dispose();}catch(error){rejected=error instanceof RangeError||error instanceof TypeError;}
   check(rejected,'Unsupported or invalid hardware placement must fail before building resources');
  }
  check(allocations===0,'Rejected placements must not allocate groups or materials');
  return {checks:8};
 };
});
