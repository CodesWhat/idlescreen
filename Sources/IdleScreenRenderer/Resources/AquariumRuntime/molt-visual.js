(function(root,factory){if(typeof module==='object'&&module.exports)module.exports=factory();else root.AquariumMoltVisual=factory();})(globalThis,function(){
 'use strict';
 function pose(age){
  if(!Number.isFinite(age)||age<0||age>=12)return{active:false,x:0,y:0,rotation:0,tint:1};
  const release=age>=.8&&age<2.3?Math.sin((age-.8)/1.5*Math.PI):0;
  return{active:true,x:-.23*release,y:.18*release,rotation:age<.8?Math.sin(age*19)*.12:release*.28,tint:.82+.18*Math.min(1,age/12)};
 }
 return{pose};
});
