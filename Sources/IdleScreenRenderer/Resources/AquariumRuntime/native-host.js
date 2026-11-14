(() => {
  "use strict";
  const scene = window.aquariumStudy;
  if (!scene) throw new Error("Aquarium runtime did not initialize");
  scene.setMode("saver");
  scene.setConditionMode("ecosystem");
  scene.setMotion(false);
  const editorSnapshot = () => ({
    revision: scene.state.presetRevision,
    objects: scene.state.presetObjects,
    placedObjects: scene.designer.layout?.instances || [],
    catalog: AquariumDesignerModel.catalog
  });
  addEventListener("message", event => {
    if (event.source !== window || event.data?.type !== "aquarium-designer-pick"
      || scene.state.mode !== "desktop" || !scene.designer.active) return;
    const pick = event.data;
    window.webkit?.messageHandlers?.idleScreenEditor?.postMessage(JSON.stringify({
      revision: pick.revision, tool: pick.tool, toolGeneration: pick.toolGeneration,
      id: pick.id ?? null, positionCm: pick.positionCm ?? null
    }));
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
      const result = scene.applyPresetObjects(request);
      return result.error ? result : editorSnapshot();
    },
    applyPlacedObjects(request) {
      const result = scene.applyPlacedObjects(request);
      return result.error ? result : editorSnapshot();
    },
    setEditorTool(request) {
      if (scene.state.mode !== "desktop" || !scene.designer.active)
        return { revision: scene.state.presetRevision, error: "Open the tank editor before choosing a tool" };
      if (!Number.isSafeInteger(request.generation) || request.generation < 1)
        return {revision: scene.state.presetRevision, error: "Invalid pointer tool generation"};
      const result = scene.applyDesigner({layout: scene.designer.layout, requestId: request.generation,
        tool: request.tool, selectedId: request.selectedId, assetId: request.assetId});
      return result.error ? {revision: scene.state.presetRevision, error: result.error} : editorSnapshot();
    },
    setAnimating(active) {
      if (typeof active !== "boolean") throw new TypeError("Animation state must be a boolean");
      scene.setMotion(active);
    }
  });
})();
