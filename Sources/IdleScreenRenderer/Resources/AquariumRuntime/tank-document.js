(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory(require('./designer-model.js'));
  else root.AquariumTankDocument = factory(root.AquariumDesignerModel);
})(typeof globalThis === 'object' ? globalThis : this, function (legacyModel) {
  'use strict';
  const limits = Object.freeze({ MAX_OBJECTS: 256, MAX_CATALOG: 512, MAX_HISTORY: 100,
    MAX_NAME_LENGTH: 80, MAX_ID_LENGTH: 64, MAX_DIMENSION_CM: 1000, MAX_POSITION_CM: 10000,
    MAX_JSON_CHARS: 2097152, MAX_DATA_DEPTH: 16, MAX_DATA_NODES: 40000,
    MAX_DATA_ARRAY: 4096, MAX_DATA_STRING: 4096, MAX_REVISION: Number.MAX_SAFE_INTEGER });
  const has = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
  const copy = value => JSON.parse(JSON.stringify(value));
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  const placements = ['rooted', 'hardscape', 'floating', 'attached', 'interior', 'exterior', 'transform'];
  const standardGeometry = { outerCm: { width: 60, depth: 36, height: 36 }, glassCm: 0.6, bedCm: 5, waterCm: 34.5 };

  function fail(code, message, cause) {
    const error = new Error(message);
    error.name = 'TankDocumentError'; error.code = code;
    if (cause !== undefined) error.cause = cause;
    throw error;
  }
  function record(value, allowed, required = allowed) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) fail('INVALID_TYPE', 'Expected a plain data object');
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== null && Object.getPrototypeOf(prototype) !== null) fail('INVALID_TYPE', 'Expected a plain data object');
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== 'string' || !allowed.includes(key)) fail('UNKNOWN_FIELD', 'Unknown document field');
      const property = Object.getOwnPropertyDescriptor(value, key);
      if (!has(property, 'value') || !property.enumerable) fail('INVALID_TYPE', 'Only enumerable data fields are supported');
    }
    if (required.some(key => !has(value, key))) fail('MISSING_FIELD', 'Required document field is missing');
  }
  function array(value, maximum) {
    if (!Array.isArray(value)) fail('INVALID_TYPE', 'Expected a dense array');
    if (value.length > maximum) fail('LIMIT', 'Array exceeds its supported size');
    for (const key of Reflect.ownKeys(value)) {
      if (key !== 'length' && (typeof key !== 'string' || !/^(0|[1-9]\d*)$/.test(key) || Number(key) >= value.length)) {
        fail('UNKNOWN_FIELD', 'Unexpected array field');
      }
    }
    for (let i = 0; i < value.length; i++) {
      const property = Object.getOwnPropertyDescriptor(value, String(i));
      if (!property || !has(property, 'value') || !property.enumerable) fail('INVALID_TYPE', 'Array entries must be dense data');
    }
  }
  function finite(value, maximum, minimum = -maximum) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) fail('INVALID_NUMBER', 'Number is outside its supported finite range');
    return value === 0 ? 0 : value;
  }
  function revision(value) {
    if (!Number.isSafeInteger(value) || value < 0) fail('INVALID_REVISION', 'Revision must be a nonnegative safe integer');
    return value;
  }
  function id(value) {
    if (typeof value !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/.test(value)) fail('INVALID_ID', 'IDs require 1–64 letters, digits, hyphens or underscores');
    return value;
  }
  function name(value) {
    if (typeof value !== 'string' || !value.trim() || value.trim().length > limits.MAX_NAME_LENGTH
      || /[\u0000-\u001f\u007f-\u009f]/.test(value)) fail('INVALID_NAME', 'Tank name must be nonempty text without control characters');
    return value.trim();
  }
  function geometry(value) {
    record(value, ['outerCm', 'glassCm', 'bedCm', 'waterCm']);
    record(value.outerCm, ['width', 'depth', 'height']);
    const outerCm = Object.fromEntries(['width', 'depth', 'height'].map(key =>
      [key, finite(value.outerCm[key], limits.MAX_DIMENSION_CM, 1)]));
    const glassCm = finite(value.glassCm, 20, 0.01);
    const bedCm = finite(value.bedCm, limits.MAX_DIMENSION_CM, glassCm);
    const waterCm = finite(value.waterCm, limits.MAX_DIMENSION_CM, glassCm);
    if (Math.min(...Object.values(outerCm)) <= glassCm * 2 || waterCm <= bedCm || waterCm > outerCm.height - glassCm) {
      fail('INVALID_GEOMETRY', 'Glass, substrate and water must fit the declared tank');
    }
    return { outerCm, glassCm, bedCm, waterCm };
  }
  function jsonData(value) {
    let nodes = 0;
    const ancestors = new Set();
    function visit(entry, depth) {
      if (++nodes > limits.MAX_DATA_NODES || depth > limits.MAX_DATA_DEPTH) fail('LIMIT', 'Checkpoint data is too large or deeply nested');
      if (entry === null || typeof entry === 'boolean') return entry;
      if (typeof entry === 'number') return finite(entry, Number.MAX_SAFE_INTEGER);
      if (typeof entry === 'string') {
        if (entry.length > limits.MAX_DATA_STRING) fail('LIMIT', 'Checkpoint string is too long');
        return entry;
      }
      if (typeof entry !== 'object' || ancestors.has(entry)) fail('INVALID_CHECKPOINT', 'Checkpoint must be finite acyclic JSON data');
      ancestors.add(entry);
      let result;
      if (Array.isArray(entry)) {
        array(entry, limits.MAX_DATA_ARRAY); result = entry.map(item => visit(item, depth + 1));
      } else {
        const keys = Reflect.ownKeys(entry);
        if (keys.some(key => typeof key !== 'string' || key.length > 128 || ['__proto__', 'constructor', 'prototype'].includes(key))) {
          fail('INVALID_CHECKPOINT', 'Checkpoint contains an unsupported data key');
        }
        record(entry, keys);
        result = Object.fromEntries(keys.map(key => [key, visit(entry[key], depth + 1)]));
      }
      ancestors.delete(entry);
      return result;
    }
    return visit(value, 0);
  }
  function sizeCheck(value) {
    if (JSON.stringify(value).length > limits.MAX_JSON_CHARS) fail('LIMIT', 'Tank document is too large');
    return value;
  }

  function createModel(options) {
    record(options, ['catalog', 'validateCheckpoint'], ['catalog']);
    array(options.catalog, limits.MAX_CATALOG);
    const assets = new Map();
    for (const entry of options.catalog) {
      record(entry, ['id', 'placement']);
      const assetId = id(entry.id);
      if (assets.has(assetId)) fail('DUPLICATE_ID', 'Duplicate catalog asset ID');
      if (!placements.includes(entry.placement)) fail('INVALID_PLACEMENT', 'Unknown catalog placement class');
      assets.set(assetId, { id: assetId, placement: entry.placement });
    }
    if (has(options, 'validateCheckpoint') && typeof options.validateCheckpoint !== 'function') fail('INVALID_TYPE', 'Checkpoint validator must be a function');
    const checkpointValidator = options.validateCheckpoint;

    function object(value, dimensions) {
      record(value, ['id', 'assetId', 'positionCm', 'rotationY']);
      const objectId = id(value.id), asset = assets.get(value.assetId);
      if (!asset) fail('UNKNOWN_ASSET', 'Asset is not in the supplied catalog');
      record(value.positionCm, ['x', 'y', 'z']);
      const positionCm = Object.fromEntries(['x', 'y', 'z'].map(key =>
        [key, finite(value.positionCm[key], limits.MAX_POSITION_CM)]));
      const freeTransform = asset.placement === 'exterior' || asset.placement === 'transform';
      if (!freeTransform) {
        if (Math.abs(positionCm.x) > dimensions.outerCm.width / 2 - dimensions.glassCm
          || Math.abs(positionCm.z) > dimensions.outerCm.depth / 2 - dimensions.glassCm
          || positionCm.y < dimensions.glassCm || positionCm.y > dimensions.waterCm) {
          fail('OUT_OF_BOUNDS', 'Object anchor is outside the tank interior');
        }
        if (['rooted', 'hardscape', 'floating'].includes(asset.placement)) {
          const anchor = asset.placement === 'floating' ? dimensions.waterCm : dimensions.bedCm;
          if (Math.abs(positionCm.y - anchor) > 1e-9) fail('INVALID_ANCHOR', 'Object does not use its declared substrate or water anchor');
          positionCm.y = anchor;
        } else if (asset.placement === 'attached' && positionCm.y < dimensions.bedCm) {
          fail('INVALID_ANCHOR', 'Attached object must be above the substrate');
        }
      }
      const turn = Math.PI * 2, angle = finite(value.rotationY, Number.MAX_VALUE) % turn;
      const rotationY = ((angle < 0 ? angle + turn : angle) % turn) || 0;
      return { id: objectId, assetId: asset.id, positionCm, rotationY };
    }
    function objectList(value, dimensions) {
      array(value, limits.MAX_OBJECTS);
      const seen = new Set();
      return value.map(entry => {
        const result = object(entry, dimensions);
        if (seen.has(result.id)) fail('DUPLICATE_ID', 'Object IDs must be unique');
        seen.add(result.id); return result;
      });
    }
    function layout(value) {
      record(value, ['name', 'setup', 'geometry', 'objects']);
      const dimensions = geometry(value.geometry);
      return { name: name(value.name), setup: id(value.setup), geometry: dimensions, objects: objectList(value.objects, dimensions) };
    }
    function checkpoint(value) {
      if (value === null) return null;
      record(value, ['schemaVersion', 'elapsedSeconds', 'data']);
      if (value.schemaVersion !== 1) fail('INVALID_CHECKPOINT', 'Unsupported checkpoint envelope');
      const result = { schemaVersion: 1, elapsedSeconds: finite(value.elapsedSeconds, 1e12, 0), data: jsonData(value.data) };
      sizeCheck(result);
      if (!checkpointValidator) fail('CHECKPOINT_VALIDATOR_REQUIRED', 'Nonempty life state needs its domain validator');
      try {
        if (checkpointValidator(copy(result.data)) !== true) fail('CHECKPOINT_REJECTED', 'Checkpoint validator did not accept the data');
      } catch (error) { fail('CHECKPOINT_REJECTED', 'Ecosystem checkpoint validation failed', error); }
      return result;
    }
    function normalize(value) {
      record(value, ['schemaVersion', 'units', 'id', 'revision', 'layoutRevision', 'ecosystemRevision', 'layout', 'checkpoint']);
      if (value.schemaVersion !== 2 || value.units !== 'cm') fail('INVALID_SCHEMA', 'Expected canonical tank schema 2 in centimeters');
      const documentRevision = revision(value.revision), layoutRevision = revision(value.layoutRevision), ecosystemRevision = revision(value.ecosystemRevision);
      if (!Number.isSafeInteger(layoutRevision + ecosystemRevision) || documentRevision !== layoutRevision + ecosystemRevision) {
        fail('INVALID_REVISION', 'Document revision must equal layout plus ecosystem revisions');
      }
      if (value.checkpoint === null && ecosystemRevision !== 0) fail('INVALID_CHECKPOINT', 'An advanced ecosystem cannot have an empty checkpoint');
      return sizeCheck({ schemaVersion: 2, units: 'cm', id: id(value.id), revision: documentRevision,
        layoutRevision, ecosystemRevision, layout: layout(value.layout), checkpoint: checkpoint(value.checkpoint) });
    }
    function create(input) {
      record(input, ['id', 'name', 'setup', 'geometry', 'objects', 'checkpoint'], ['id', 'name', 'setup', 'geometry', 'objects']);
      return normalize({ schemaVersion: 2, units: 'cm', id: input.id, revision: 0, layoutRevision: 0, ecosystemRevision: 0,
        layout: { name: input.name, setup: input.setup, geometry: input.geometry, objects: input.objects },
        checkpoint: has(input, 'checkpoint') ? input.checkpoint : null });
    }
    function preset(input) {
      if (!input || !has(input, 'objects')) {
        fail('PRESET_REQUIRED', 'Supply the complete nonempty preset object records');
      }
      record(input, ['setup', 'geometry', 'objects']);
      if (!Array.isArray(input.objects) || input.objects.length === 0) fail('PRESET_REQUIRED', 'Supply the complete nonempty preset object records');
      const normalized = layout({ name: 'Preset', ...input });
      return { setup: normalized.setup, geometry: normalized.geometry, objects: normalized.objects };
    }
    function legacyLayout(input) {
      if (!legacyModel || typeof legacyModel.normalize !== 'function') fail('LEGACY_MODEL_REQUIRED', 'Browser schema-1 migration needs the existing designer model');
      try { return legacyModel.normalize(input); }
      catch (error) { fail('INVALID_LEGACY_LAYOUT', 'Input is not a supported browser schema-1 layout', error); }
    }
    function migrateDesignerLayoutV1(input, settings) {
      record(settings, ['id', 'preset'], ['id']);
      if (!has(settings, 'preset')) fail('PRESET_REQUIRED', 'Migration requires explicit preset object records');
      const old = legacyLayout(input), base = preset(settings.preset);
      if (base.setup !== old.base.setup || !same(base.geometry, standardGeometry)) {
        fail('PRESET_MISMATCH', 'Preset must match the browser layout setup and fixed centimeter geometry');
      }
      return create({ id: settings.id, name: old.name, setup: base.setup, geometry: base.geometry, objects: [...base.objects, ...old.instances] });
    }
    function toDesignerLayoutV1(input, settings) {
      const doc = normalize(input);
      record(settings, ['preset']);
      const base = preset(settings.preset);
      if (!same(base.geometry, standardGeometry) || !same(doc.layout.geometry, base.geometry) || doc.layout.setup !== base.setup
        || base.objects.some((entry, index) => !same(doc.layout.objects[index], entry))) {
        fail('NOT_REPRESENTABLE', 'Edited baseline objects cannot be represented by browser schema 1');
      }
      const ids = new Set(base.objects.map(entry => entry.id));
      try { return legacyLayout({ schemaVersion: 1, units: 'cm', name: doc.layout.name,
        base: { setup: base.setup }, instances: doc.layout.objects.filter(entry => !ids.has(entry.id)) }); }
      catch (error) { fail('NOT_REPRESENTABLE', 'This canonical layout requires the new designer', error); }
    }

    function createSession(input) {
      let current = normalize(input), selectedId = null;
      const past = [], future = [];
      const snapshot = () => copy(current), layoutSnapshot = () => copy(current.layout);
      const historyState = () => ({ layout: current.layout, selectedId });
      function fence(settings, life = false) {
        const fields = life ? ['expectedLayoutRevision', 'expectedEcosystemRevision'] : ['expectedLayoutRevision'];
        record(settings, fields);
        for (const key of fields) revision(settings[key]);
        if (settings.expectedLayoutRevision !== current.layoutRevision
          || (life && settings.expectedEcosystemRevision !== current.ecosystemRevision)) {
          fail('STALE_REVISION', 'Document changed since this command was prepared');
        }
      }
      function changed(value, domain) {
        const next = { ...current, ...value, revision: current.revision + 1, [domain]: current[domain] + 1 };
        revision(next.revision); revision(next[domain]); sizeCheck(next);
        return next;
      }
      function select(value) {
        if (value !== null && !current.layout.objects.some(entry => entry.id === id(value))) fail('UNKNOWN_OBJECT', 'Selected object does not exist');
        selectedId = value; return selectedId;
      }
      function apply(command, settings) {
        fence(settings);
        record(command, ['type', 'instance', 'id', 'patch', 'layout', 'preset', 'setup'], ['type']);
        const fields = { add: ['type', 'instance'], update: ['type', 'id', 'patch'], remove: ['type', 'id'],
          replace: ['type', 'layout'], base: ['type', 'preset'] };
        if (!has(fields, command.type)) fail('INVALID_COMMAND', 'Unknown layout command');
        if (command.type === 'base' && !has(command, 'preset')) fail('PRESET_REQUIRED', 'A setup name cannot reconstruct editable preset objects');
        record(command, fields[command.type]);
        let candidate = layoutSnapshot(), nextSelection = selectedId;
        if (command.type === 'add') {
          const entry = object(command.instance, candidate.geometry); candidate.objects.push(entry); nextSelection = entry.id;
        } else if (command.type === 'update' || command.type === 'remove') {
          const objectId = id(command.id), index = candidate.objects.findIndex(entry => entry.id === objectId);
          if (index < 0) fail('UNKNOWN_OBJECT', 'Object does not exist');
          if (command.type === 'remove') candidate.objects.splice(index, 1);
          else {
            record(command.patch, ['assetId', 'positionCm', 'rotationY'], []);
            const target = candidate.objects[index];
            for (const key of ['assetId', 'rotationY']) if (has(command.patch, key)) target[key] = command.patch[key];
            if (has(command.patch, 'positionCm')) {
              record(command.patch.positionCm, ['x', 'y', 'z'], []);
              target.positionCm = { ...target.positionCm, ...command.patch.positionCm };
            }
          }
        } else if (command.type === 'replace') candidate = command.layout;
        else candidate = { name: candidate.name, ...preset(command.preset) };
        candidate = layout(candidate);
        if (same(candidate, current.layout)) return snapshot();
        if (!candidate.objects.some(entry => entry.id === nextSelection)) nextSelection = null;
        const next = changed({ layout: candidate }, 'layoutRevision');
        past.push(historyState()); if (past.length > limits.MAX_HISTORY) past.shift();
        future.length = 0; current = next; selectedId = nextSelection;
        return snapshot();
      }
      function restore(from, to, settings) {
        fence(settings);
        if (!from.length) return snapshot();
        const previous = from[from.length - 1];
        const next = changed({ layout: previous.layout }, 'layoutRevision');
        to.push(historyState()); if (to.length > limits.MAX_HISTORY) to.shift();
        from.pop(); current = next; selectedId = previous.selectedId;
        return snapshot();
      }
      function commitCheckpoint(inputCheckpoint, settings) {
        fence(settings, true);
        if (inputCheckpoint === null) fail('INVALID_CHECKPOINT', 'Life updates cannot clear the checkpoint');
        const nextCheckpoint = checkpoint(inputCheckpoint);
        if (current.checkpoint && nextCheckpoint.elapsedSeconds < current.checkpoint.elapsedSeconds) fail('TIME_REGRESSION', 'Life updates cannot rewind biological time');
        if (same(nextCheckpoint, current.checkpoint)) return snapshot();
        current = changed({ checkpoint: nextCheckpoint }, 'ecosystemRevision');
        return snapshot();
      }
      return Object.freeze({ snapshot, layoutSnapshot, apply, select, commitCheckpoint,
        undo: settings => restore(past, future, settings), redo: settings => restore(future, past, settings),
        get selectedId() { return selectedId; }, get canUndo() { return past.length > 0; }, get canRedo() { return future.length > 0; } });
    }
    function exportJSON(value) { return JSON.stringify(normalize(value)); }
    function importJSON(text) {
      if (typeof text !== 'string' || text.length > limits.MAX_JSON_CHARS) fail('LIMIT', 'Document JSON must be bounded text');
      let value;
      try { value = JSON.parse(text); } catch (error) { fail('INVALID_JSON', 'Tank document JSON could not be parsed', error); }
      return normalize(value);
    }
    return Object.freeze({ create, normalize, normalizeLayout: value => layout(value), createSession,
      migrateDesignerLayoutV1, toDesignerLayoutV1, exportJSON, importJSON });
  }
  return Object.freeze({ createModel, limits });
});
