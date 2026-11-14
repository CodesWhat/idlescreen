(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AquariumEcosystemCheckpointV1 = factory();
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';
  const has = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
  const MAX_SERIAL = Number.MAX_SAFE_INTEGER - 1;
  const kinds = ['fish', 'shrimp', 'snail'];
  const familyKinds = { neocaridina: 'shrimp', amano: 'shrimp', guppy: 'fish', medaka: 'fish' };
  function fail(code, path, message) {
    const error = new Error(path + ': ' + message);
    error.name = 'EcosystemCheckpointError'; error.code = code; error.path = path; throw error;
  }
  function dataCopy(input) {
    const ancestors = new Set(); let nodes = 0;
    function visit(value, path, depth) {
      if (++nodes > 250000 || depth > 32) fail('DATA_LIMIT', path, 'checkpoint data exceeds traversal bounds');
      if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
      if (typeof value === 'number' && Number.isFinite(value)) return value;
      if (typeof value !== 'object' || value === null) fail('INVALID_DATA', path, 'finite JSON data required');
      if (ancestors.has(value)) fail('INVALID_DATA', path, 'cyclic data is not a snapshot');
      const array = Array.isArray(value), prototype = Object.getPrototypeOf(value);
      if (!array && prototype !== null && Object.getPrototypeOf(prototype) !== null) fail('INVALID_DATA', path, 'plain records required');
      ancestors.add(value);
      const result = array ? [] : {}, keys = Reflect.ownKeys(value);
      if (array && keys.length !== value.length + 1) fail('INVALID_DATA', path, 'dense arrays without extra fields required');
      for (const key of keys) {
        if (array && key === 'length') continue;
        if (typeof key !== 'string' || (array && !/^(0|[1-9]\d*)$/.test(key))) fail('INVALID_DATA', path, 'string data keys required');
        const d = Object.getOwnPropertyDescriptor(value, key);
        if (!has(d, 'value') || !d.enumerable) fail('INVALID_DATA', path + '.' + key, 'enumerable data fields required');
        Object.defineProperty(result, key, { value: visit(d.value, path + '.' + key, depth + 1), enumerable: true, writable: true, configurable: true });
      }
      ancestors.delete(value); return result;
    }
    return visit(input, 'checkpoint', 0);
  }
  function record(value, required, optional, path) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) fail('INVALID_RECORD', path, 'record required');
    for (const key of required) if (!has(value, key)) fail('MISSING_FIELD', path + '.' + key, 'required field missing');
    for (const key of Object.keys(value)) if (!required.includes(key) && !optional.includes(key)) fail('UNKNOWN_FIELD', path + '.' + key, 'unsupported snapshot field');
  }
  function number(value, path, minimum = 0, maximum = Number.MAX_VALUE) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) fail('INVALID_NUMBER', path, 'finite value within the domain range required');
  }
  function integer(value, path, minimum = 0, maximum = MAX_SERIAL) {
    number(value, path, minimum, maximum); if (!Number.isSafeInteger(value)) fail('INVALID_NUMBER', path, 'safe integer required');
  }
  function text(value, path, nonempty = true) { if (typeof value !== 'string' || (nonempty && !value.length)) fail('INVALID_TEXT', path, 'string required'); }
  function boolean(value, path) { if (typeof value !== 'boolean') fail('INVALID_BOOLEAN', path, 'boolean required'); }
  function choice(value, allowed, path) { if (!allowed.includes(value)) fail('INVALID_VALUE', path, 'unsupported domain value'); }
  function list(value, path, maximum = 250000) { if (!Array.isArray(value) || value.length > maximum) fail('INVALID_LIST', path, 'bounded array required'); }
  function position(value, path) {
    record(value, ['x', 'y', 'z'], [], path); for (const key of ['x', 'y', 'z']) number(value[key], path + '.' + key, -Number.MAX_VALUE);
  }
  function optional(value, key, check, path) { if (has(value, key)) check(value[key], path + '.' + key); }
  function variant(value, path) { if (value !== null) text(value, path, false); }
  function unique(id, ids, path) { text(id, path); if (ids.has(id)) fail('DUPLICATE_ID', path, 'duplicate identity'); ids.add(id); }
  function generated(id, prefix, serial, path) {
    text(id, path); const suffix = id.slice(prefix.length);
    if (!id.startsWith(prefix) || !/^[1-9]\d*$/.test(suffix)) fail('INVALID_ID', path, 'invalid generated identity');
    integer(Number(suffix), path, 1, serial);
  }
  function counters(value, integers, masses, path) {
    record(value, [...integers, ...masses], [], path);
    integers.forEach(key => integer(value[key], path + '.' + key)); masses.forEach(key => number(value[key], path + '.' + key));
  }
  function target(value, kind, path) {
    if (value === null) return;
    const support = kind === 'shelter' || kind === 'egg-site';
    record(value, [support ? 'supportId' : 'id', 'kind', 'position'], [], path);
    text(value[support ? 'supportId' : 'id'], path + '.id'); position(value.position, path + '.position');
    choice(value.kind, support ? [kind] : ['food', 'scavenge', 'graze'], path + '.kind');
  }
  function validateEcology(s) {
    const path = 'ecology';
    record(s, ['seed', 'seconds', 'serial', 'animals', 'food', 'deposits', 'patches', 'events', 'stats'], [], path);
    integer(s.seed, path + '.seed', 0, 4294967295); number(s.seconds, path + '.seconds', 0, 1e12); integer(s.serial, path + '.serial');
    const ids = new Set();
    for (const key of ['animals', 'food', 'patches']) list(s[key], path + '.' + key);
    list(s.deposits, path + '.deposits', 256); list(s.events, path + '.events', 32);
    for (const a of s.animals) {
      const p = path + '.animals';
      record(a, ['id', 'kind', 'surface', 'position', 'alive', 'state', 'hunger', 'health', 'gut', 'poop', 'ageDays', 'lifespanDays', 'moltDue', 'recoveryUntil', 'target'],
        ['species', 'reason', 'moltCount', 'variant', 'sex', 'maturity', 'isOffspring'], p);
      unique(a.id, ids, p + '.id'); choice(a.kind, kinds, p + '.kind'); choice(a.surface, ['free', 'floor', 'glass'], p + '.surface');
      position(a.position, p + '.position'); boolean(a.alive, p + '.alive');
      choice(a.state, ['forage', 'rest', 'approach', 'eat', 'graze', 'premolt', 'recover', 'dead'], p + '.state');
      if ((a.state === 'dead') !== !a.alive) fail('ANIMAL_STATE', p + '.alive', 'alive and dead state disagree');
      if (['premolt', 'recover'].includes(a.state) && a.kind !== 'shrimp') fail('ANIMAL_STATE', p + '.state', 'only shrimp molt');
      for (const key of ['hunger', 'health']) number(a[key], p + '.' + key, 0, 1);
      if (a.alive && a.health === 0) fail('ANIMAL_STATE', p + '.health', 'living animal requires positive health');
      for (const key of ['gut', 'poop', 'ageDays', 'moltDue', 'recoveryUntil']) number(a[key], p + '.' + key);
      number(a.lifespanDays, p + '.lifespanDays', Number.MIN_VALUE); target(a.target, 'ecology', p + '.target');
      if (!a.alive && a.target !== null) fail('ANIMAL_STATE', p + '.target', 'dead animals have no active target');
      optional(a, 'species', (v, k) => text(v, k, false), p); optional(a, 'reason', text, p); optional(a, 'moltCount', integer, p);
      optional(a, 'variant', variant, p); optional(a, 'sex', (v, k) => choice(v, ['female', 'male', 'unknown'], k), p);
      optional(a, 'maturity', (v, k) => number(v, k, 0, 1), p); optional(a, 'isOffspring', boolean, p);
    }
    for (const key of ['food', 'patches']) for (const a of s[key]) {
      const p = path + '.' + key; record(a, ['id', 'position', 'amount', ...(key === 'food' ? ['age'] : [])], [], p);
      unique(a.id, ids, p + '.id'); position(a.position, p + '.position'); number(a.amount, p + '.amount', 0, 1);
      if (key === 'food') number(a.age, p + '.age');
    }
    for (const d of s.deposits) {
      const p = path + '.deposits'; record(d, ['id', 'kind', 'position', 'amount', 'initial', 'age'], ['owner', 'supportY', 'shellScale', 'motion'], p);
      unique(d.id, ids, p + '.id'); generated(d.id, 'deposit-', s.serial, p + '.id');
      choice(d.kind, ['feces', 'molt', 'corpse', 'uneaten'], p + '.kind'); position(d.position, p + '.position');
      number(d.initial, p + '.initial', Number.MIN_VALUE); number(d.amount, p + '.amount', 0, d.initial); number(d.age, p + '.age');
      optional(d, 'owner', text, p); optional(d, 'supportY', (v, k) => number(v, k, -Number.MAX_VALUE), p);
      optional(d, 'shellScale', (v, k) => number(v, k, Number.MIN_VALUE), p);
      if ((has(d, 'supportY') || has(d, 'shellScale')) && d.kind !== 'molt') fail('DEPOSIT_STATE', p, 'shell support belongs to a molt');
      if (has(d, 'motion')) {
        if (d.kind !== 'feces') fail('DEPOSIT_STATE', p + '.motion', 'waste motion belongs to feces');
        record(d.motion, ['age', 'phase', 'speed'], [], p + '.motion'); number(d.motion.age, p + '.motion.age');
        choice(d.motion.phase, ['attached', 'sinking', 'settled'], p + '.motion.phase'); number(d.motion.speed, p + '.motion.speed', 0, .27);
      }
    }
    let last = 0;
    for (const e of s.events) {
      record(e, ['kind', 'id', 'at'], [], path + '.events'); choice(e.kind, ['death', 'molt'], path + '.events.kind'); text(e.id, path + '.events.id');
      number(e.at, path + '.events.at', last, s.seconds); last = e.at;
    }
    counters(s.stats, ['feces', 'molts', 'deaths'], ['eaten', 'algaeEaten', 'dissolved', 'filtered'], path + '.stats');
    if (s.stats.algaeEaten > s.stats.eaten) fail('INVALID_STATS', path + '.stats', 'algae consumption exceeds total consumption');
  }
  function family(value, kind, path, nullable = false) {
    if (nullable && value === null) return;
    choice(value, Object.keys(familyKinds), path);
    if (familyKinds[value] !== kind) fail('FAMILY_KIND', path, 'family and animal kind disagree');
  }
  function validateBreedingEvents(s) {
    const ids = new Set(); let lastAt = 0, lastId = 0;
    const fields = {
      conception: ['broodId', 'motherId', 'fatherId', 'family', 'phase'],
      'brood-ended': ['broodId', 'motherId', 'reason'], 'offspring-removed': ['animalId'],
      'larval-release': ['broodId', 'motherId', 'juveniles', 'requires', 'rearingSimulated'],
      'live-birth': ['broodId', 'motherId', 'family', 'count', 'position', 'supportId'],
      hatch: ['broodId', 'motherId', 'family', 'count', 'position', 'supportId'],
      'eggs-deposited': ['broodId', 'motherId', 'supportId', 'count', 'position']
    };
    for (const e of s.events) {
      const p = 'breeding.events';
      if (!e || typeof e !== 'object' || Array.isArray(e)) fail('INVALID_RECORD', p, 'event record required');
      choice(e.kind, Object.keys(fields), p + '.kind'); record(e, ['id', 'kind', 'at', ...fields[e.kind]], [], p);
      integer(e.id, p + '.id', lastId + 1, s.eventSerial); if (ids.has(e.id)) fail('DUPLICATE_ID', p + '.id', 'duplicate event identity'); ids.add(e.id);
      number(e.at, p + '.at', lastAt, s.seconds); lastAt = e.at; lastId = e.id;
      for (const key of ['motherId', 'fatherId', 'animalId']) optional(e, key, text, p);
      optional(e, 'broodId', (v, k) => generated(v, 'brood-', s.serial, k), p);
      optional(e, 'count', (v, k) => integer(v, k, 0, s.maxAnimals), p); optional(e, 'position', position, p);
      optional(e, 'supportId', (v, k) => { if (v !== null) text(v, k); }, p);
      optional(e, 'family', (v, k) => choice(v, Object.keys(familyKinds), k), p);
      optional(e, 'phase', (v, k) => choice(v, ['gravid', 'berried', 'carried-eggs'], k), p);
      optional(e, 'reason', (v, k) => choice(v, ['missing-support', 'no-deposit', 'mother-unavailable'], k), p);
      if (e.kind === 'conception') choice(e.phase, [e.family === 'guppy' ? 'gravid' : e.family === 'medaka' ? 'carried-eggs' : 'berried'], p + '.phase');
      if (e.kind === 'live-birth') { choice(e.family, ['guppy'], p + '.family'); choice(e.supportId, [null], p + '.supportId'); }
      if (e.kind === 'hatch') {
        choice(e.family, ['medaka', 'neocaridina'], p + '.family');
        if (e.family === 'medaka') text(e.supportId, p + '.supportId'); else choice(e.supportId, [null], p + '.supportId');
      }
      if (e.kind === 'eggs-deposited') text(e.supportId, p + '.supportId');
      if (e.kind === 'offspring-removed') generated(e.animalId, 'offspring-', s.serial, p + '.animalId');
      if (e.kind === 'larval-release' && (e.juveniles !== 0 || e.requires !== 'brackish-larval-rearing' || e.rearingSimulated !== false)) fail('EVENT_STATE', p, 'Amano release does not create freshwater juveniles');
    }
  }
  function validateBreeding(s) {
    const path = 'breeding';
    record(s, ['version', 'maxAnimals', 'seed', 'seconds', 'nextCheck', 'serial', 'eventSerial', 'parents', 'offspring', 'broods', 'events', 'stats'], [], path);
    if (s.version !== 1) fail('UNSUPPORTED_SCHEMA', path + '.version', 'breeding version 1 required');
    integer(s.maxAnimals, path + '.maxAnimals', 1, 256); integer(s.seed, path + '.seed', 0, 4294967295);
    number(s.seconds, path + '.seconds', 0, 1e12); number(s.nextCheck, path + '.nextCheck', s.seconds);
    integer(s.serial, path + '.serial'); integer(s.eventSerial, path + '.eventSerial');
    for (const key of ['parents', 'offspring', 'broods']) list(s[key], path + '.' + key, s.maxAnimals);
    list(s.events, path + '.events', 64);
    const parents = new Map(), childIds = new Set(), broodIds = new Set(), activeMothers = new Set();
    for (const a of s.parents) {
      const p = path + '.parents'; record(a, ['id', 'kind', 'species', 'family', 'sex', 'maturity', 'alive', 'position', 'habitat', 'variant', 'nextEligible'], [], p);
      text(a.id, p + '.id'); if (parents.has(a.id)) fail('DUPLICATE_ID', p + '.id', 'duplicate parent identity'); parents.set(a.id, a);
      choice(a.kind, kinds, p + '.kind'); text(a.species, p + '.species', false); family(a.family, a.kind, p + '.family', true);
      choice(a.sex, ['female', 'male', 'unknown'], p + '.sex'); number(a.maturity, p + '.maturity', 0, 1); boolean(a.alive, p + '.alive');
      position(a.position, p + '.position'); text(a.habitat, p + '.habitat'); variant(a.variant, p + '.variant'); number(a.nextEligible, p + '.nextEligible');
    }
    for (const a of s.offspring) {
      const p = path + '.offspring'; record(a, ['id', 'family', 'kind', 'species', 'variant', 'sex', 'alive', 'bornAt', 'position', 'parentIds', 'shelterTarget'], [], p);
      unique(a.id, childIds, p + '.id'); generated(a.id, 'offspring-', s.serial, p + '.id'); family(a.family, a.kind, p + '.family');
      if (a.family === 'amano') fail('OFFSPRING_STATE', p, 'Amano freshwater offspring are not supported');
      text(a.species, p + '.species', false); variant(a.variant, p + '.variant'); choice(a.sex, ['female', 'male'], p + '.sex');
      if (a.alive !== true) fail('OFFSPRING_STATE', p + '.alive', 'retained offspring must be alive');
      number(a.bornAt, p + '.bornAt', 0, s.seconds); position(a.position, p + '.position'); list(a.parentIds, p + '.parentIds', 2);
      if (a.parentIds.length !== 2 || a.parentIds[0] === a.parentIds[1]) fail('OFFSPRING_STATE', p + '.parentIds', 'two distinct parent identities required');
      a.parentIds.forEach(id => text(id, p + '.parentIds')); target(a.shelterTarget, 'shelter', p + '.shelterTarget');
      const parent = parents.get(a.id);
      if (parent && (!parent.alive || parent.kind !== a.kind || parent.family !== a.family)) fail('OFFSPRING_STATE', p, 'shared parent and offspring identity disagrees');
    }
    let reserved = 0;
    for (const b of s.broods) {
      const p = path + '.broods'; record(b, ['id', 'motherId', 'fatherId', 'family', 'kind', 'species', 'variant', 'count', 'startedAt', 'phase', 'nextAt', 'supportId', 'position'], ['target'], p);
      unique(b.id, broodIds, p + '.id'); generated(b.id, 'brood-', s.serial, p + '.id'); family(b.family, b.kind, p + '.family');
      text(b.motherId, p + '.motherId'); text(b.fatherId, p + '.fatherId'); if (b.motherId === b.fatherId) fail('BROOD_STATE', p, 'distinct parents required');
      text(b.species, p + '.species', false); variant(b.variant, p + '.variant');
      integer(b.count, p + '.count', b.family === 'amano' ? 0 : 1, b.family === 'amano' ? 0 : s.maxAnimals); reserved += b.count;
      number(b.startedAt, p + '.startedAt', 0, s.seconds); number(b.nextAt, p + '.nextAt', s.seconds);
      choice(b.phase, b.family === 'guppy' ? ['gravid'] : b.family === 'medaka' ? ['carried-eggs', 'deposited-eggs'] : ['berried'], p + '.phase');
      position(b.position, p + '.position');
      if (b.phase === 'deposited-eggs') text(b.supportId, p + '.supportId');
      else {
        if (b.supportId !== null) fail('BROOD_STATE', p + '.supportId', 'only deposited eggs own a support');
        const mother = parents.get(b.motherId);
        if (!mother || !mother.alive || mother.sex !== 'female' || mother.family !== b.family) fail('BROOD_STATE', p + '.motherId', 'active brood needs its retained mother');
        if (activeMothers.has(b.motherId)) fail('BROOD_STATE', p + '.motherId', 'multiple active carried broods'); activeMothers.add(b.motherId);
      }
      optional(b, 'target', (v, k) => target(v, 'egg-site', k), p);
    }
    const living = new Set(childIds); for (const a of parents.values()) if (a.alive) living.add(a.id);
    if (living.size + reserved > s.maxAnimals) fail('POPULATION_CAPACITY', path, 'living animals and reserved births exceed capacity');
    counters(s.stats, ['conceptions', 'births', 'hatchedBroods', 'larvalReleases', 'cancelledBroods', 'failedDeposits', 'lostEggs', 'capacitySuppressed'], [], path + '.stats');
    if (s.stats.births < s.offspring.length || s.stats.conceptions < s.broods.length) fail('INVALID_STATS', path + '.stats', 'retained records exceed cumulative history');
    validateBreedingEvents(s);
  }
  function create(modules) {
    if (!modules || ['ecology', 'breeding', 'water'].some(key => typeof modules[key]?.create !== 'function') || typeof modules.water.validateSnapshot !== 'function') {
      fail('INVALID_MODULES', 'modules', 'actual ecology, breeding and water modules are required');
    }
    function validate(input) {
      const s = dataCopy(input);
      record(s, ['schemaVersion', 'ecology', 'breeding', 'water', 'runtime'], [], 'checkpoint');
      if (s.schemaVersion !== 1) fail('UNSUPPORTED_SCHEMA', 'checkpoint.schemaVersion', 'checkpoint version 1 required');
      validateEcology(s.ecology); validateBreeding(s.breeding);
      try { s.water = modules.water.validateSnapshot(s.water); }
      catch (error) { fail('WATER_' + (error.code || 'INVALID'), 'water', error.message); }
      record(s.runtime, ['accountedDissolved', 'dissolvedMode', 'ecologyFilter', 'organicMgNPerDissolvedUnit'], [], 'runtime');
      if (s.runtime.dissolvedMode !== 'cumulative' || s.runtime.ecologyFilter !== 0 || s.runtime.organicMgNPerDissolvedUnit !== 4 || s.ecology.stats.filtered !== 0) {
        fail('DISSOLVED_POLICY', 'runtime', 'cumulative ecology waste, legacy filter 0 and 4 mg-N per dissolved unit required');
      }
      number(s.runtime.accountedDissolved, 'runtime.accountedDissolved', 0, s.ecology.stats.dissolved);
      const represented = s.runtime.accountedDissolved * 4, tolerance = Math.max(1e-8, s.water.ledger.addedMgN * 1e-12);
      if (!Number.isFinite(represented) || represented > s.water.ledger.addedMgN + tolerance) fail('DISSOLVED_LEDGER', 'runtime.accountedDissolved', 'accounted waste exceeds nitrogen recorded as added');
      const clocks = [s.ecology.seconds, s.breeding.seconds, s.water.elapsedSeconds], high = Math.max(...clocks);
      if (high - Math.min(...clocks) > Math.max(1e-8, high * Number.EPSILON * 16)) fail('CLOCK_MISMATCH', 'checkpoint', 'domain clocks disagree beyond floating roundoff');
      return s;
    }
    function capture(runtime) {
      if (!runtime || !has(runtime, 'accountedDissolved')) fail('MISSING_FIELD', 'runtime.accountedDissolved', 'explicit dissolved accounting marker required');
      for (const key of ['ecology', 'breeding', 'water']) if (typeof runtime[key]?.snapshot !== 'function') fail('INVALID_MODEL', key, 'live model snapshot method required');
      return validate({ schemaVersion: 1, ecology: runtime.ecology.snapshot(), breeding: runtime.breeding.snapshot(), water: runtime.water.snapshot(),
        runtime: { accountedDissolved: runtime.accountedDissolved, dissolvedMode: 'cumulative', ecologyFilter: 0, organicMgNPerDissolvedUnit: 4 } });
    }
    function restore(input) {
      const s = validate(input);
      return { ecology: modules.ecology.create({ snapshot: s.ecology }), breeding: modules.breeding.create({ snapshot: s.breeding }),
        water: modules.water.create({ snapshot: s.water }), accountedDissolved: s.runtime.accountedDissolved };
    }
    return Object.freeze({ validate, capture, restore });
  }
  return Object.freeze({ create });
});
