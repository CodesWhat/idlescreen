(() => {
  "use strict";
  const scene = window.aquariumStudy;
  if (!scene) throw new Error("Aquarium runtime did not initialize");
  scene.setMode("saver");
  scene.setConditionMode("ecosystem");
  scene.setMotion(false);
  const editorSnapshot = () => ({
    revision: scene.state.presetRevision,
    objects: scene.state.presetObjects
  });
  window.idleScreenScene = Object.freeze({
    editorSnapshot,
    exportTank(identity) { return scene.exportTank(identity); },
    restoreTankJSON(text) {
      try { scene.restoreTankJSON(text); return editorSnapshot(); }
      catch (error) { return { revision: scene.state.presetRevision, error: error.message }; }
    },
    beginEditing() {
      scene.setMode("desktop");
      if (!scene.designer.active) {
        const result = scene.applyDesigner({
          requestId: 0,
          layout: scene.designer.layout || {
            schemaVersion: 1, units: "cm", name: "Planted tank",
            base: { setup: scene.state.sceneStyle }, instances: []
          }
        });
        if (result.error) return { revision: scene.state.presetRevision, error: result.error };
      }
      return editorSnapshot();
    },
    applyPresetObjects(request) {
      return scene.applyPresetObjects(request);
    },
    setAnimating(active) {
      if (typeof active !== "boolean") throw new TypeError("Animation state must be a boolean");
      scene.setMotion(active);
    }
  });
})();
