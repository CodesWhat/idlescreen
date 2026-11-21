(function(root){
 'use strict';
 function roomLevelAtHour(hour){return Number.isFinite(hour)?Math.max(0,Math.min(1,hour-7,20-hour)):0;}
 const api={roomLevelAtHour};if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumDaylight=api;
})(typeof window==='object'?window:globalThis);
