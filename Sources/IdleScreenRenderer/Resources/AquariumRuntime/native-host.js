(() => {
  "use strict";
  const scene = window.aquariumStudy;
  if (!scene) throw new Error("Aquarium runtime did not initialize");
  scene.setMode("saver");
  scene.setConditionMode("ecosystem");
  scene.setMotion(false);
  window.idleScreenScene = Object.freeze({
    setAnimating(active) {
      if (typeof active !== "boolean") throw new TypeError("Animation state must be a boolean");
      scene.setMotion(active);
    }
  });
})();
