(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumTankConfiguration = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';
  const limits = Object.freeze({ MAX_JSON_CHARS: 32768 });
  const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  function freeze(value) {
    for (const child of Object.values(value)) if (child && typeof child === 'object') freeze(child);
    return Object.freeze(value);
  }
  const choices = freeze({
    setup: ['basic', 'lush', 'waterfall'],
    assets: {
      gravel: ['basalt', 'river', 'mixed-river'], rock: ['slate', 'river', 'moss'],
      shrimp: ['red', 'red-rili', 'red-white', 'skittles', 'amano', 'blue-dream', 'green-jade',
        'yellow-goldenback', 'crystal-black', 'orange-rili', 'black-king-kong', 'red-king-kong',
        'blue-bolt', 'tangerine-tiger', 'orange-eye-blue-tiger', 'black-pinto', 'red-pinto',
        'red-galaxy-pinto', 'golden-bee', 'snowball', 'chocolate-black-rose', 'black-rili'],
      fish: ['chili', 'medaka-white', 'medaka-redcap', 'guppy-blue', 'guppy-pink',
        'guppy-double-sword', 'guppy-dumbo-redtail', 'guppy-metal-lace', 'guppy-full-gold',
        'medaka-white-galaxy-longfin', 'medaka-tricolor'],
      decor: ['none', 'skull-castle', 'tetrapods'], wood: ['pixel', 'smooth', 'manzanita'],
      plants: ['classic', 'varied', 'botanical', 'frogbit', 'salvinia-minima', 'red-root-floater',
        'tiger-lotus', 'java-fern', 'bucephalandra', 'fissidens', 'christmas-moss',
        'cryptocoryne', 'staurogyne', 'rotala', 'compact-sword'],
      cleaners: ['classic', 'contact']
    },
    lightPreset: ['daylight', 'warm', 'moonlight', 'off'], lightCount: [1, 3, 5],
    lightSpread: ['focused', 'natural', 'broad'], roomMode: ['auto', 'on', 'off'],
    roomFinish: ['neutral', 'charcoal', 'concrete'], surface: ['calm', 'current', 'lively'],
    rasterHeight: [648, 864, 1080], conditionMode: ['auto', 'manual', 'ecosystem']
  });
  const assetKeys = Object.keys(choices.assets);
  const configurationKeys = ['schemaVersion', 'setup', 'assets', 'light', 'room', 'surface', 'pump', 'rasterHeight', 'condition'];
  const stateKeys = ['presetRevision', 'water', 'presetObjects', 'designer', 'glass', 'projection', 'botanical', 'physical',
    'sceneStyle', 'current', 'breeding', 'navigation', 'rasterHeight', 'surface', 'premium', 'room',
    'ecology', 'condition', 'assets', 'inventory', 'lighting', 'direction', 'view', 'framing', 'mode',
    'preset', 'motion', 'clock', 'collisions', 'feeding', 'renderer', 'renderedFrames', 'drawCalls',
    'triangles', 'camera', 'world', 'landmarks'];
  const lightingKeys = ['depthSpread', 'output', 'shadows', 'shadowResolution', 'source', 'roomLevel',
    'roomMode', 'banks', 'ambient', 'fill', 'key', 'shadowSources'];
  const conditionKeys = ['level', 'label', 'particleCount', 'debrisCount', 'hardscapePatches', 'hazeOpacity', 'clock', 'mode'];

  function fail(code, message) {
    const error = new Error(message);
    error.name = 'TankConfigurationError'; error.code = code;
    throw error;
  }
  function record(value, allowed, required = allowed, path = 'configuration') {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) fail('INVALID_TYPE', path + ' must be a plain data object');
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== null) {
      const constructor = Object.getOwnPropertyDescriptor(prototype, 'constructor');
      if (Object.getPrototypeOf(prototype) !== null || !constructor || !has(constructor, 'value')
        || typeof constructor.value !== 'function'
        || Function.prototype.toString.call(constructor.value) !== Function.prototype.toString.call(Object)) {
        fail('INVALID_TYPE', path + ' must be a plain data object');
      }
    }
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== 'string' || !allowed.includes(key)) fail('UNKNOWN_FIELD', path + ' contains an unsupported field');
      const property = Object.getOwnPropertyDescriptor(value, key);
      if (!has(property, 'value') || !property.enumerable) fail('INVALID_TYPE', path + ' supports only enumerable data fields');
    }
    if (required.some(key => !has(value, key))) fail('MISSING_FIELD', path + ' is missing a required field');
  }
  function choice(value, supported, path) {
    if (!supported.includes(value)) fail('INVALID_CHOICE', path + ' is not a supported choice');
    return value;
  }
  function finite(value, minimum, maximum, path) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) {
      fail('INVALID_NUMBER', path + ' must be finite and within ' + minimum + '–' + maximum);
    }
    return value === 0 ? 0 : value;
  }
  function manualLevel(value, manual, path) {
    if (manual && value === null) fail('INVALID_LEVEL_MODE', path + ' requires an explicit manual level');
    if (!manual && value !== null) fail('INVALID_LEVEL_MODE', path + ' requires null for a derived level');
    return manual ? finite(value, 0, 1, path) : null;
  }
  function normalize(value) {
    record(value, configurationKeys);
    if (value.schemaVersion !== 1) fail('INVALID_SCHEMA', 'Only scene configuration schema 1 is supported');
    record(value.assets, assetKeys, assetKeys, 'assets');
    record(value.light, ['preset', 'count', 'output', 'spread'], undefined, 'light');
    record(value.room, ['mode', 'finish', 'manualLevel'], undefined, 'room');
    record(value.condition, ['mode', 'manualLevel'], undefined, 'condition');
    const roomMode = choice(value.room.mode, choices.roomMode, 'room.mode');
    const conditionMode = choice(value.condition.mode, choices.conditionMode, 'condition.mode');
    return {
      schemaVersion: 1,
      setup: choice(value.setup, choices.setup, 'setup'),
      assets: Object.fromEntries(assetKeys.map(key => [key, choice(value.assets[key], choices.assets[key], 'assets.' + key)])),
      light: {
        preset: choice(value.light.preset, choices.lightPreset, 'light.preset'),
        count: choice(value.light.count, choices.lightCount, 'light.count'),
        output: finite(value.light.output, 0.25, 1.5, 'light.output'),
        spread: choice(value.light.spread, choices.lightSpread, 'light.spread')
      },
      room: {
        mode: roomMode, finish: choice(value.room.finish, choices.roomFinish, 'room.finish'),
        manualLevel: manualLevel(value.room.manualLevel, roomMode !== 'auto', 'room.manualLevel')
      },
      surface: choice(value.surface, choices.surface, 'surface'),
      pump: finite(value.pump, 0, 1.5, 'pump'),
      rasterHeight: choice(value.rasterHeight, choices.rasterHeight, 'rasterHeight'),
      condition: { mode: conditionMode,
        manualLevel: manualLevel(value.condition.manualLevel, conditionMode === 'manual', 'condition.manualLevel') }
    };
  }
  function capture(state) {
    record(state, stateKeys, ['sceneStyle', 'current', 'rasterHeight', 'surface', 'room', 'condition', 'assets', 'lighting', 'preset'], 'scene state');
    record(state.current, ['output'], undefined, 'current');
    record(state.surface, ['mode', 'impacts'], ['mode'], 'surface');
    record(state.room, ['finish', 'implemented'], ['finish'], 'room');
    record(state.condition, conditionKeys, ['level', 'mode'], 'condition');
    record(state.lighting, lightingKeys, ['depthSpread', 'output', 'roomLevel', 'roomMode', 'banks'], 'lighting');
    const roomLevel = finite(state.lighting.roomLevel, 0, 1, 'lighting.roomLevel');
    const conditionLevel = finite(state.condition.level, 0, 1, 'condition.level');
    return normalize({
      schemaVersion: 1, setup: state.sceneStyle, assets: state.assets,
      light: { preset: state.preset, count: state.lighting.banks, output: state.lighting.output, spread: state.lighting.depthSpread },
      room: { mode: state.lighting.roomMode, finish: state.room.finish,
        manualLevel: state.lighting.roomMode === 'auto' ? null : roomLevel },
      surface: state.surface.mode, pump: state.current.output, rasterHeight: state.rasterHeight,
      condition: { mode: state.condition.mode, manualLevel: state.condition.mode === 'manual' ? conditionLevel : null }
    });
  }
  function planChanges(beforeValue, afterValue) {
    const before = normalize(beforeValue), after = normalize(afterValue), changes = [];
    function compare(a, b, prefix) {
      for (const key of Object.keys(a)) {
        const path = prefix ? prefix + '.' + key : key;
        if (a[key] !== null && typeof a[key] === 'object') compare(a[key], b[key], path);
        else if (a[key] !== b[key]) changes.push({ path, from: a[key], to: b[key] });
      }
    }
    compare(before, after, '');
    const paths = new Set(changes.map(change => change.path));
    const changed = (...names) => names.some(name => paths.has(name));
    const rebuild = changed('setup', ...assetKeys.map(key => 'assets.' + key));
    const resize = changed('rasterHeight');
    return {
      schemaVersion: 1, before, after, changes, rebuild,
      refresh: {
        roomFromClock: changed('room.mode') && after.room.mode === 'auto',
        condition: changed('condition.mode', 'condition.manualLevel'),
        roomFinish: !rebuild && changed('room.finish'),
        tankLights: !rebuild && changed('light.count', 'light.spread'),
        lighting: !rebuild && changed('light.preset', 'light.count', 'light.output', 'light.spread', 'room.mode', 'room.manualLevel'),
        surface: !rebuild && changed('surface'), pump: !rebuild && changed('pump'),
        resize, render: changes.length > 0 && !rebuild && !resize
      }
    };
  }
  function exportJSON(value) { return JSON.stringify(normalize(value)); }
  function importJSON(text) {
    if (typeof text !== 'string') fail('INVALID_TYPE', 'Configuration JSON must be a string');
    if (text.length > limits.MAX_JSON_CHARS) fail('LIMIT', 'Configuration JSON exceeds its supported size');
    let value;
    try { value = JSON.parse(text); }
    catch (_) { fail('INVALID_JSON', 'Configuration JSON could not be parsed'); }
    return normalize(value);
  }
  return Object.freeze({ choices, limits, normalize, capture, planChanges, exportJSON, importJSON });
});
