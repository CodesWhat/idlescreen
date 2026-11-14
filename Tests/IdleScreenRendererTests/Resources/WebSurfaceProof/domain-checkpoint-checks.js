(function(root){
 'use strict';
 root.runAquariumDomainCheckpointChecks=function(){
 let checks=0;
 const canonical=value=>Array.isArray(value)?value.map(canonical):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,canonical(value[key])])):value;
 function check(value,message='Assertion failed'){if(!value)throw new Error(message);}
 const assert={
  ok:check,
  equal:(actual,expected,message)=>check(actual===expected,message),
  notEqual:(actual,expected,message)=>check(actual!==expected,message),
  deepEqual:(actual,expected,message)=>check(JSON.stringify(canonical(actual))===JSON.stringify(canonical(expected)),message),
  throws:(body,expected,message)=>{let error;try{body();}catch(e){error=e;}check(!!error,message||'Expected rejection');if(expected)check(typeof expected==='function'?expected(error):expected.test(error.message),message||error.message);}
 };
 function test(name,body){try{body();checks++;}catch(error){throw new Error(name+': '+error.message);}}
 const ecologyModule=AquariumEcology,breedingModule=AquariumBreeding,waterModule=AquariumWaterEcosystem,wasteMotion=AquariumWasteMotion,collisionModule=AquariumCollisions;
 const modules={ecology:ecologyModule,breeding:breedingModule,water:waterModule};
const clone = value => JSON.parse(JSON.stringify(value));
const position = { x: 0, y: 1, z: 0 };
const environment = { shelter: 1, light: 1, stress: 0, plantSupports: [{ id: 'leaf-1', kind: 'plant', position }] };
function adapter() { return AquariumEcosystemCheckpointV1.create(modules); }
function runtime() {
  return { ecology: ecologyModule.create({ seed: 41 }), breeding: breedingModule.create({ seed: 41, maxAnimals: 80 }),
    water: waterModule.create({ volumeL: 50, filterMaturity: .8 }), accountedDissolved: 0 };
}
function animal(r, id, kind, species, sex = 'female', extra = {}) {
  const a = r.ecology.addAnimal({ id, kind, species, position, lifespanDays: 10000, ...extra });
  Object.assign(a, { sex, maturity: 1, variant: species, isOffspring: false }); return a;
}
function seedParents(r) {
  for (const species of ['cherry', 'guppy', 'medaka', 'amano']) for (const sex of ['female', 'male']) {
    animal(r, species + '-' + sex, ['guppy', 'medaka'].includes(species) ? 'fish' : 'shrimp', species, sex);
  }
}
function advance(r, dt, env = environment) {
  const tick = r.ecology.seconds, ids = [];
  for (let i = 0; i < Math.ceil(r.ecology.animals.length / 4); i++) {
    const id = 'feed-' + tick + '-' + i; r.ecology.addFood({ id, position, amount: 1 }); ids.push(id);
  }
  r.ecology.step(dt, { filter: 0, light: .5, stress: 0 });
  ids.forEach(id => r.ecology.retireFood(id));
  const delta = r.ecology.stats.dissolved - r.accountedDissolved;
  if (delta > 0) r.water.addNitrogen({ organic: delta * 4 });
  r.accountedDissolved = r.ecology.stats.dissolved;
  r.water.step(dt, { plantCoverage: .6, filterOutput: .8, light: .7 });
  const young = new Set(r.breeding.offspring.map(a => a.id));
  const roster = r.ecology.animals.filter(a => a.alive || young.has(a.id)).map(a => ({ ...a }));
  const result = r.breeding.step(dt, roster, env);
  for (const child of result.births) {
    const a = animal(r, child.id, child.kind, child.species, child.sex, { position: child.position, ageDays: child.ageDays });
    Object.assign(a, { maturity: child.maturity, variant: child.variant, isOffspring: true });
  }
  for (const child of r.breeding.offspring) {
    const a = r.ecology.animals.find(a => a.id === child.id); if (a) a.maturity = child.maturity;
  }
  return result;
}
function advanceHours(r, hours, env = environment) { for (let i = 0; i < hours; i++) advance(r, 3600, env); }
function richRuntime() {
  const r = runtime(); seedParents(r); animal(r, 'departed', 'fish', 'chili'); animal(r, 'glass-snail', 'snail', 'nerite', 'female', { surface: 'glass' });
  advanceHours(r, 3);
  r.ecology.die(r.ecology.animals.find(a => a.id === 'departed'), 'explicit review preview');
  r.ecology.beginMolt(r.ecology.animals.find(a => a.id === 'cherry-female'));
  const shell = r.ecology.deposits.findLast(d => d.kind === 'molt'); shell.shellScale = .93; shell.supportY = shell.position.y;
  const world = collisionModule.createWorld(THREE, { halfWidth: 7, backZ: -4, frontZ: 4, floorY: 0 });
  for (const phase of ['attached', 'sinking', 'settled']) {
    const d = r.ecology.addDeposit('feces', phase === 'settled' ? { x: 0, y: .025, z: 0 } : position, .025); d.owner = 'guppy-female';
    const fish = { kind: 'fish', scale: 1, facing: 1, position };
    wasteMotion.step(THREE, d, .1, phase === 'settled' ? null : fish, world);
    if (phase === 'sinking') for (let i = 0; i < 5; i++) wasteMotion.step(THREE, d, .1, fish, world);
    assert.equal(d.motion.phase, phase);
  }
  return r;
}

test('capture validates actual pending broods, molt, corpse and all waste phases without mutating live modules', () => {
  const api = adapter(), r = richRuntime(), before = [r.ecology.snapshot(), r.breeding.snapshot(), r.water.snapshot()];
  const saved = api.capture(r);
  assert.equal(saved.schemaVersion, 1);
  assert.deepEqual(saved.runtime, { accountedDissolved: r.accountedDissolved, dissolvedMode: 'cumulative', ecologyFilter: 0, organicMgNPerDissolvedUnit: 4 });
  assert.ok(saved.breeding.broods.some(b => b.phase === 'deposited-eggs'));
  assert.ok(saved.breeding.broods.some(b => b.phase === 'gravid'));
  assert.ok(saved.ecology.deposits.some(d => d.shellScale === .93));
  assert.deepEqual([r.ecology.snapshot(), r.breeding.snapshot(), r.water.snapshot()], before);
  const validated = api.validate(saved); assert.deepEqual(validated, saved);
  validated.ecology.animals[0].health = 0; saved.water.nitrogenMg.organic = 999;
  assert.deepEqual([r.ecology.snapshot(), r.breeding.snapshot(), r.water.snapshot()], before);
});

test('JSON restore continues all three actual constructors deterministically with no dissolved double addition', () => {
  const api = adapter(), a = richRuntime(), saved = api.capture(a), b = api.restore(clone(saved));
  assert.notEqual(a.ecology, b.ecology); assert.notEqual(a.breeding, b.breeding); assert.notEqual(a.water, b.water);
  assert.equal(b.accountedDissolved, a.accountedDissolved); assert.deepEqual(api.capture(b), saved);
  const added = b.water.snapshot().ledger.addedMgN;
  assert.equal(b.ecology.stats.dissolved - b.accountedDissolved, 0);
  assert.equal(b.water.snapshot().ledger.addedMgN, added, 'restore neither adds nor advances');
  saved.ecology.stats.dissolved = 999;
  for (const dt of [1, .016, 30, 57.6, 3600, 900]) { advance(a, dt); advance(b, dt); }
  assert.deepEqual(api.capture(b), api.capture(a));
});

test('newborns absent from parents and later shared parent/offspring IDs are legitimate complete snapshots', () => {
  const api = adapter(), a = runtime(); seedParents(a); advanceHours(a, 28 * 24);
  const saved = api.capture(a), born = saved.breeding.offspring.filter(a => a.bornAt === saved.breeding.seconds);
  assert.ok(born.length > 0, 'actual module emitted newborns at 28 days');
  assert.ok(born.some(child => !saved.breeding.parents.some(p => p.id === child.id)));
  const b = api.restore(clone(saved)); advance(a, 1); advance(b, 1);
  assert.ok(a.breeding.snapshot().offspring.some(child => a.breeding.snapshot().parents.some(p => p.id === child.id)));
  assert.deepEqual(api.capture(a), api.capture(b));
  const birthsBefore = a.breeding.stats.births;
  advanceHours(a, 48); advanceHours(b, 48);
  assert.ok(a.breeding.stats.births > birthsBefore && a.breeding.events.some(e => e.kind === 'live-birth'));
  assert.deepEqual(api.capture(a), api.capture(b), 'future birth transitions and random offspring sex continue exactly');
  for (const change of [s => s.breeding.offspring[0].alive = false, s => s.breeding.offspring[0].bornAt = s.breeding.seconds + 1,
    s => s.breeding.offspring.push(clone(s.breeding.offspring[0])), s => s.breeding.offspring[0].family = 'amano']) {
    const bad = api.capture(a); change(bad); assert.throws(() => api.validate(bad), e => e.name === 'EcosystemCheckpointError');
  }
  const young = a.breeding.offspring[0]; a.ecology.die(a.ecology.animals.find(x => x.id === young.id), 'fixture');
  advance(a, 1); assert.ok(a.breeding.events.some(e => e.kind === 'offspring-removed')); api.validate(api.capture(a));
});

test('actual fractional stepping tolerates roundoff without rewriting clocks and rejects material skew', () => {
  const api = adapter(), r = runtime();
  for (let i = 0; i < 16; i++) advance(r, 60 + Math.sin(i) * 50);
  const saved = api.capture(r); assert.notEqual(saved.ecology.seconds, saved.breeding.seconds);
  assert.deepEqual(api.restore(saved).ecology.snapshot(), r.ecology.snapshot());
  for (const key of ['ecology', 'breeding', 'water']) {
    const bad = clone(saved); bad[key][key === 'water' ? 'elapsedSeconds' : 'seconds'] += .01;
    assert.throws(() => api.validate(bad), e => e.code === 'CLOCK_MISMATCH');
  }
});

test('pending untransferred cumulative waste is preserved while missing, advanced or incompatible markers fail', () => {
  const api = adapter(), r = runtime();
  for (let i = 0; i < 257; i++) r.ecology.addDeposit('feces', position, .025);
  assert.equal(r.ecology.stats.dissolved, .025);
  const saved = api.capture(r), b = api.restore(saved);
  assert.equal(b.accountedDissolved, 0); assert.equal(b.water.snapshot().ledger.addedMgN, 0);
  advance(r, 1); advance(b, 1); assert.deepEqual(api.capture(r), api.capture(b));
  assert.ok(b.water.snapshot().ledger.addedMgN >= .1);
  const good = api.capture(r);
  const changes = [s => delete s.runtime.accountedDissolved, s => s.runtime.accountedDissolved = -1,
    s => s.runtime.accountedDissolved = s.ecology.stats.dissolved + 1, s => s.runtime.organicMgNPerDissolvedUnit = 5,
    s => s.runtime.ecologyFilter = 1, s => s.runtime.dissolvedMode = 'remaining', s => s.ecology.stats.filtered = 1,
    s => { s.water.ledger.addedMgN = 0; s.water.ledger.initialMgN = Object.values(s.water.nitrogenMg).reduce((a, b) => a + b, 0); }];
  for (const change of changes) { const bad = clone(good); change(bad); assert.throws(() => api.validate(bad), e => e.name === 'EcosystemCheckpointError'); }
  const noMarker = { ...r }; delete noMarker.accountedDissolved; assert.throws(() => api.capture(noMarker), /accountedDissolved/);
});

test('corrupt animal, mass, ID, serial, capacity, brood and event states are rejected before constructors run', () => {
  const api = adapter(), good = api.capture(richRuntime()), changes = [
    s => s.ecology.animals[0].alive = 'false', s => s.ecology.animals[0].state = 'dead',
    s => s.ecology.animals[0].health = -1, s => s.ecology.animals[0].health = 0, s => s.ecology.animals[0].gut = -1,
    s => s.ecology.animals[0].position.y = Infinity, s => s.ecology.animals.push(clone(s.ecology.animals[0])),
    s => s.ecology.deposits[0].amount = -1, s => s.ecology.deposits[0].amount = s.ecology.deposits[0].initial + 1,
    s => s.ecology.serial = 0, s => s.ecology.deposits.push(clone(s.ecology.deposits[0])),
    s => s.ecology.deposits.find(d => d.motion).motion.speed = -1,
    s => s.ecology.deposits.find(d => d.shellScale).shellScale = 0,
    s => s.ecology.patches.push({ id: 'guppy-female', amount: .2, position }),
    s => s.breeding.parents[0].alive = 1, s => s.breeding.parents.push(clone(s.breeding.parents[0])),
    s => s.breeding.broods.push(clone(s.breeding.broods[0])), s => s.breeding.broods[0].phase = 'nonsense',
    s => s.breeding.broods[0].count = -1, s => s.breeding.broods[0].count = 80,
    s => s.breeding.broods[0].nextAt = 0, s => s.breeding.serial = 0,
    s => s.breeding.events.push(clone(s.breeding.events[0])), s => s.breeding.eventSerial = 0,
    s => s.breeding.events[0].at = s.breeding.seconds + 1,
    s => s.breeding.events[0].phase = 'gravid',
    s => s.water.nitrogenMg.ammonia = -1, s => s.water.nitrogenMg.nitrate += 1,
    s => s.schemaVersion = 2, s => s.runtime.extra = true
  ];
  for (const [domain, fields] of Object.entries({ ecology: ['animals', 'food', 'deposits', 'patches', 'events'], breeding: ['parents', 'offspring', 'broods', 'events'] })) {
    for (const field of fields) changes.push(s => s[domain][field].push(null));
  }
  let calls = 0; const spies = Object.fromEntries(Object.entries(modules).map(([key, value]) => [key, { ...value, create(...args) { calls++; return value.create(...args); } }]));
  const checked = AquariumEcosystemCheckpointV1.create(spies);
  for (const [index, change] of changes.entries()) { const bad = clone(good); change(bad); assert.throws(() => checked.restore(bad), e => e.name === 'EcosystemCheckpointError', 'corruption ' + index); }
  assert.equal(calls, 0, 'no constructor is called for invalid domains');
});

test('consumed zero-mass deposits and an explicit death before breeding sync retain valid live shapes', () => {
  const api = adapter(), r = runtime(), shrimp = animal(r, 'grazer', 'shrimp', 'cherry');
  const food = r.ecology.addDeposit('uneaten', position, .0015);
  r.ecology.step(1, { filter: 0, light: 0 }); r.water.step(1); r.breeding.step(1, [shrimp], environment);
  assert.equal(food.amount, 0); api.validate(api.capture(r));
  const full = richRuntime(); full.ecology.die(full.ecology.animals.find(a => a.id === 'guppy-female'), 'explicit review preview');
  assert.equal(full.breeding.snapshot().parents.find(a => a.id === 'guppy-female').alive, true, 'breeding roster is from the last positive step');
  api.validate(api.capture(full));
});

test('data validation never executes getters and rejects lossy JSON values, cycles and unknown fields', () => {
  const api = adapter(), good = api.capture(runtime()); let getterRan = false;
  const accessor = clone(good); Object.defineProperty(accessor.ecology, 'seconds', { enumerable: true, get() { getterRan = true; return 0; } });
  const cycle = clone(good); cycle.ecology.extra = cycle;
  const corrupt = [accessor, cycle, null, [], new Date(), { ...good, extra: 1 }];
  for (const value of [NaN, Infinity, undefined, () => 0, 2n]) { const bad = clone(good); bad.runtime.accountedDissolved = value; corrupt.push(bad); }
  for (const bad of corrupt) assert.throws(() => api.validate(bad), e => e.name === 'EcosystemCheckpointError');
  assert.equal(getterRan, false);
});


 return{checks};
 };
})(globalThis);
