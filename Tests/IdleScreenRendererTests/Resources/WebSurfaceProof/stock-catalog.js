(function(root){
 'use strict';
 root.runAquariumStockCatalog=function(){
  function check(value,message){if(!value)throw new Error(message);}
  const configuration=root.AquariumTankConfiguration,catalog=configuration.stockCatalog;
  check(Array.isArray(catalog),'The stock picker needs the shared finished-animal catalog');
  check(catalog.length===35&&new Set(catalog.map(a=>a.id)).size===35,'Every supported finished animal needs one stable catalog identity');
  check(catalog.every(a=>typeof a.label==='string'&&a.label.length>0&&['fish','shrimp','snail'].includes(a.kind)),'Every stock item needs a readable label and supported animal kind');
  check(catalog.filter(a=>a.kind==='shrimp').length===21&&!catalog.some(a=>a.variant==='skittles'),'Mixed-tank color presets must not be sold as an individual animal');
  check(catalog.filter(a=>a.kind==='fish'&&a.variant!=='otocinclus').every(a=>configuration.choices.assets.fish.includes(a.variant)),'Fish stock must resolve to finished supported fish art');
  check(catalog.filter(a=>a.kind==='shrimp').every(a=>configuration.choices.assets.shrimp.includes(a.variant)),'Shrimp stock must resolve to finished supported shrimp art');
  check(catalog.some(a=>a.id==='fish/otocinclus')&&catalog.some(a=>a.id==='snail/nerite')&&catalog.some(a=>a.id==='snail/assassin'),'Supported cleaner forms belong in the same stock inventory');
  check(!catalog.some(a=>/betta|bristlenose|rabbit|ramshorn/.test(a.id)),'Review-only animal forms must stay out of supported stock');
  check(Object.isFrozen(catalog)&&catalog.every(Object.isFrozen),'Consumers must not mutate the shared stock registry');
  return{checks:9};
 };
})(globalThis);
