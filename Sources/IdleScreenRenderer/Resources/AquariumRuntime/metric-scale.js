(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumMetricScale=factory();})(globalThis,function(){
 'use strict';
 const cmPerUnit=36/8.4,toWorld=cm=>cm/cmPerUnit,frontZ=4.04;
 const tank=Object.freeze({model:'UNS60U',widthCm:60,depthCm:36,heightCm:36,glassCm:.6,bedCm:5,halfWidth:toWorld(30),height:toWorld(36),frontZ,backZ:frontZ-toWorld(36),frontBound:frontZ-toWorld(.6),backBound:frontZ-toWorld(36-.6),bedLevel:toWorld(5),waterLevel:toWorld(34.5),glass:toWorld(.6)});
 function camera(aspect){if(!Number.isFinite(aspect)||aspect<=0)throw new RangeError('Positive viewport aspect required');const verticalSpan=Math.max(tank.height/.66,26/aspect),frontDistance=.8*(tank.frontZ-tank.backZ)/.2;return{pitch:0,verticalSpan,horizontalSpan:verticalSpan*aspect,eyeHeight:.91*verticalSpan,eyeDepth:tank.frontZ+frontDistance,frontDistance,fov:2*Math.atan(verticalSpan/(2*frontDistance))*180/Math.PI};}
 return{cmPerUnit,toWorld,tank,camera};
});
