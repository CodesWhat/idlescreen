(function (root) {
  'use strict';

  const limits = Object.freeze({
    MIN_VOLUME_L: 0.1, MAX_VOLUME_L: 10000, MAX_MASS_MG: 1e9,
    MAX_LEDGER_MG: 1e12, MAX_ELAPSED_SECONDS: 1e12,
    MAX_CONCENTRATION_MG_L: 1000, STEP_SECONDS: 60, MAX_ADVANCE_SECONDS: 21600
  });
  const waterPools = ['organic', 'ammonia', 'nitrite', 'nitrate'];
  const allPools = [...waterPools, 'filterWaste', 'plantBiomass'];
  const unitLabel = 's,L,mg-N,mg-gas';
  const clamp = value => Math.max(0, Math.min(1, value));
  const sum = object => Object.values(object).reduce((a, b) => a + b, 0);
  const copy = value => JSON.parse(JSON.stringify(value));
  const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

  function fail(code, message) {
    const error = new Error(message);
    error.name = 'WaterModelError';
    error.code = code;
    throw error;
  }

  function record(value, allowed, required = []) {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      fail('INVALID_OBJECT', 'Expected a plain data object');
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== null && Object.getPrototypeOf(prototype) !== null) {
      fail('INVALID_OBJECT', 'Only plain data objects are supported');
    }
    for (const key of Reflect.ownKeys(value)) {
      if (typeof key !== 'string' || !allowed.includes(key)) {
        fail('UNKNOWN_FIELD', 'Unknown water-model field');
      }
      const descriptor = Object.getOwnPropertyDescriptor(value, key);
      if (!has(descriptor, 'value') || !descriptor.enumerable) {
        fail('INVALID_OBJECT', 'Water-model fields must be enumerable data');
      }
    }
    if (required.some(key => !has(value, key))) fail('MISSING_FIELD', 'Incomplete water snapshot');
    return value;
  }

  function number(value, label, maximum, minimum = 0) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > maximum) {
      fail('INVALID_NUMBER', label + ' is outside the supported finite range');
    }
    return value === 0 ? 0 : value;
  }

  function optional(value, key, fallback, maximum, minimum = 0) {
    return number(has(value, key) ? value[key] : fallback, key, maximum, minimum);
  }

  function pools(value = {}, names = waterPools, maximum = limits.MAX_MASS_MG, strict = false) {
    record(value, names, strict ? names : []);
    return Object.fromEntries(names.map(key => [key, optional(value, key, 0, maximum)]));
  }

  function validatedSnapshot(input) {
    const fields = ['schemaVersion', 'units', 'volumeL', 'elapsedSeconds', 'nitrogenMg',
      'oxygenMg', 'carbonDioxideMg', 'filterMaturity', 'ledger'];
    record(input, fields, fields);
    if (input.schemaVersion !== 1 || input.units !== unitLabel) {
      fail('UNSUPPORTED_SCHEMA', 'Unsupported water snapshot schema or units');
    }
    const nitrogenMg = pools(input.nitrogenMg, allPools, limits.MAX_MASS_MG, true);
    const ledgerFields = ['initialMgN', 'addedMgN', 'removedMgN'];
    record(input.ledger, ledgerFields, ledgerFields);
    const ledger = Object.fromEntries(ledgerFields.map(key =>
      [key, number(input.ledger[key], key, limits.MAX_LEDGER_MG)]));
    const available = ledger.initialMgN + ledger.addedMgN;
    const accounted = sum(nitrogenMg) + ledger.removedMgN;
    if (Math.abs(available - accounted) > Math.max(1e-8, available * 1e-12)) {
      fail('MASS_BALANCE', 'Water snapshot nitrogen ledger does not balance');
    }
    return {
      schemaVersion: 1, units: unitLabel,
      volumeL: number(input.volumeL, 'volumeL', limits.MAX_VOLUME_L, limits.MIN_VOLUME_L),
      elapsedSeconds: number(input.elapsedSeconds, 'elapsedSeconds', limits.MAX_ELAPSED_SECONDS),
      nitrogenMg,
      oxygenMg: number(input.oxygenMg, 'oxygenMg', limits.MAX_MASS_MG),
      carbonDioxideMg: number(input.carbonDioxideMg, 'carbonDioxideMg', limits.MAX_MASS_MG),
      filterMaturity: number(input.filterMaturity, 'filterMaturity', 1), ledger
    };
  }

  function initialState(options) {
    const fields = ['volumeL', 'nitrogenMg', 'oxygenMgL', 'carbonDioxideMgL', 'filterMaturity', 'snapshot'];
    record(options, fields);
    if (has(options, 'snapshot')) {
      if (Object.keys(options).length !== 1) fail('INVALID_OPTIONS', 'Snapshot cannot be mixed with initial values');
      return validatedSnapshot(options.snapshot);
    }
    const volumeL = optional(options, 'volumeL', 50, limits.MAX_VOLUME_L, limits.MIN_VOLUME_L);
    const nitrogenMg = { ...pools(options.nitrogenMg), filterWaste: 0, plantBiomass: 0 };
    return validatedSnapshot({
      schemaVersion: 1, units: unitLabel, volumeL, elapsedSeconds: 0, nitrogenMg,
      oxygenMg: volumeL * optional(options, 'oxygenMgL', 8, limits.MAX_CONCENTRATION_MG_L),
      carbonDioxideMg: volumeL * optional(options, 'carbonDioxideMgL', 3, limits.MAX_CONCENTRATION_MG_L),
      filterMaturity: optional(options, 'filterMaturity', 0.5, 1),
      ledger: { initialMgN: sum(nitrogenMg), addedMgN: 0, removedMgN: 0 }
    });
  }

  function environment(input) {
    const defaults = { filterOutput: 1, light: 0.5, plantCoverage: 0, aeration: 0.35,
      respirationMgLPerHour: 0, co2InjectionMgLPerHour: 0 };
    record(input, [...Object.keys(defaults), 'paused']);
    if (has(input, 'paused') && typeof input.paused !== 'boolean') {
      fail('INVALID_OPTIONS', 'paused must be boolean');
    }
    return { ...Object.fromEntries(Object.entries(defaults).map(([key, value]) =>
      [key, optional(input, key, value, key.endsWith('PerHour') ? 100 : 1)])), paused: input.paused === true };
  }

  function transfer(state, from, to, amount) {
    const moved = Math.min(state.nitrogenMg[from], Math.max(0, amount));
    state.nitrogenMg[from] -= moved;
    state.nitrogenMg[to] += moved;
    return moved;
  }

  function consumeOxygen(state, requested) {
    const consumed = Math.min(state.oxygenMg, requested);
    state.oxygenMg -= consumed;
    return consumed;
  }

  function mineralize(state, pool, rate, hours) {
    const amount = Math.min(state.nitrogenMg[pool] * -Math.expm1(-rate * hours), state.oxygenMg / 1.2);
    transfer(state, pool, 'ammonia', amount);
    consumeOxygen(state, amount * 1.2);
    state.carbonDioxideMg += amount * 1.5;
  }

  function plantUptake(state, env, hours) {
    const carbonLimit = state.carbonDioxideMg / (state.carbonDioxideMg + state.volumeL * 3);
    const capacity = Math.min(state.carbonDioxideMg / 1.5,
      state.volumeL * 0.05 * env.plantCoverage * env.light * carbonLimit * hours);
    const ammonia = transfer(state, 'ammonia', 'plantBiomass', capacity);
    const nitrate = transfer(state, 'nitrate', 'plantBiomass', capacity - ammonia);
    const used = ammonia + nitrate;
    state.carbonDioxideMg = Math.max(0, state.carbonDioxideMg - used * 1.5);
    state.oxygenMg += used * 1.2;
  }

  function advanceSlice(state, seconds, env) {
    const hours = seconds / 3600, n = state.nitrogenMg;
    const clearFlow = env.filterOutput / (1 + n.filterWaste / (state.volumeL * 2));
    const exchange = -Math.expm1(-(env.aeration * 0.6 + clearFlow * 0.25) * hours);
    state.oxygenMg += (state.volumeL * 8 - state.oxygenMg) * exchange;
    state.carbonDioxideMg += (state.volumeL * 3 - state.carbonDioxideMg) * exchange;
    state.carbonDioxideMg += env.co2InjectionMgLPerHour * state.volumeL * hours;
    const respiration = consumeOxygen(state,
      state.volumeL * (env.respirationMgLPerHour + env.plantCoverage * 0.025) * hours);
    state.carbonDioxideMg += respiration * 1.2;

    transfer(state, 'organic', 'filterWaste', n.organic * -Math.expm1(-clearFlow * 0.25 * hours));
    mineralize(state, 'organic', 0.08, hours);
    mineralize(state, 'filterWaste', 0.04, hours);
    const oxygenFraction = clamp(state.oxygenMg / (state.volumeL * 4));
    const activity = clearFlow * state.filterMaturity * oxygenFraction;
    const ammonia = Math.min(n.ammonia * -Math.expm1(-activity * 0.22 * hours), state.oxygenMg / 3);
    transfer(state, 'ammonia', 'nitrite', ammonia);
    consumeOxygen(state, ammonia * 3);
    const nitrite = Math.min(n.nitrite * -Math.expm1(-activity * 0.16 * hours), state.oxygenMg);
    transfer(state, 'nitrite', 'nitrate', nitrite);
    consumeOxygen(state, nitrite);
    plantUptake(state, env, hours);

    const substrate = clamp((n.ammonia + n.nitrite) / (state.volumeL * 0.5));
    const growth = clearFlow * oxygenFraction * substrate;
    state.filterMaturity += (1 - state.filterMaturity) * -Math.expm1(-growth * 0.008 * hours);
    state.filterMaturity *= Math.exp(-(1 - clearFlow * oxygenFraction) * 0.0005 * hours);
    state.filterMaturity = clamp(state.filterMaturity);
  }

  function readings(state) {
    const concentrationsMgL = Object.fromEntries(waterPools.map(key => [key, state.nitrogenMg[key] / state.volumeL]));
    concentrationsMgL.oxygen = state.oxygenMg / state.volumeL;
    concentrationsMgL.carbonDioxide = state.carbonDioxideMg / state.volumeL;
    const c = concentrationsMgL;
    const stressFactors = {
      ammonia: clamp(c.ammonia / 0.5), nitrite: clamp(c.nitrite / 0.5),
      nitrate: clamp((c.nitrate - 15) / 50), oxygen: clamp((4 - c.oxygen) / 4),
      carbonDioxide: clamp((c.carbonDioxide - 20) / 40)
    };
    const filterLoad = state.nitrogenMg.filterWaste / (state.volumeL * 2);
    const condition = clamp(c.organic / 3 * 0.6 + c.nitrate / 30 * 0.25 + clamp(filterLoad) * 0.15);
    return { concentrationsMgL, stressFactors, stress: Math.max(...Object.values(stressFactors)),
      condition, clarity: 1 - condition, filterLoad, filterMaturity: state.filterMaturity,
      nitrogenBalanceMg: state.ledger.initialMgN + state.ledger.addedMgN
        - state.ledger.removedMgN - sum(state.nitrogenMg) };
  }

  function create(options = {}) {
    let state = initialState(options);
    function transact(operation) {
      const candidate = copy(state);
      operation(candidate);
      state = validatedSnapshot(candidate);
      return copy(state);
    }
    function remove(candidate, pool, fraction) {
      const amount = candidate.nitrogenMg[pool] * fraction;
      candidate.nitrogenMg[pool] -= amount;
      candidate.ledger.removedMgN += amount;
    }
    return Object.freeze({
      snapshot: () => copy(state),
      readings: () => readings(state),
      step(elapsed, input = {}) {
        if (typeof elapsed !== 'number' || !Number.isFinite(elapsed) || elapsed <= 0) {
          return { advancedSeconds: 0, unappliedSeconds: 0, steps: 0, reason: 'invalid-elapsed' };
        }
        const env = environment(input);
        if (env.paused) return { advancedSeconds: 0, unappliedSeconds: elapsed, steps: 0, reason: 'paused' };
        const applied = Math.min(elapsed, limits.MAX_ADVANCE_SECONDS);
        const steps = Math.ceil(applied / limits.STEP_SECONDS);
        transact(candidate => {
          for (let i = 0; i < steps; i++) advanceSlice(candidate,
            Math.min(limits.STEP_SECONDS, applied - i * limits.STEP_SECONDS), env);
          candidate.elapsedSeconds += applied;
        });
        return { advancedSeconds: applied, unappliedSeconds: elapsed - applied, steps, reason: 'advanced' };
      },
      addNitrogen(input) {
        const additions = pools(input);
        return transact(candidate => {
          for (const key of waterPools) candidate.nitrogenMg[key] += additions[key];
          candidate.ledger.addedMgN += sum(additions);
        });
      },
      waterChange(fraction, input = {}) {
        number(fraction, 'fraction', 1);
        record(input, ['nitrogenMgL', 'oxygenMgL', 'carbonDioxideMgL']);
        const incoming = pools(input.nitrogenMgL, waterPools, limits.MAX_CONCENTRATION_MG_L);
        const oxygen = optional(input, 'oxygenMgL', 8, limits.MAX_CONCENTRATION_MG_L);
        const carbon = optional(input, 'carbonDioxideMgL', 3, limits.MAX_CONCENTRATION_MG_L);
        return transact(candidate => {
          const liters = candidate.volumeL * fraction;
          for (const key of waterPools) {
            remove(candidate, key, fraction);
            candidate.nitrogenMg[key] += incoming[key] * liters;
          }
          candidate.ledger.addedMgN += sum(incoming) * liters;
          candidate.oxygenMg = candidate.oxygenMg * (1 - fraction) + oxygen * liters;
          candidate.carbonDioxideMg = candidate.carbonDioxideMg * (1 - fraction) + carbon * liters;
        });
      },
      serviceFilter(input = {}) {
        record(input, ['removeFraction', 'maturityRetention']);
        const fraction = optional(input, 'removeFraction', 1, 1);
        const retention = optional(input, 'maturityRetention', 0.9, 1);
        return transact(candidate => {
          remove(candidate, 'filterWaste', fraction);
          candidate.filterMaturity *= retention;
        });
      },
      cleanSubstrate(fraction) {
        number(fraction, 'fraction', 1);
        return transact(candidate => remove(candidate, 'organic', fraction));
      },
      harvestPlants(fraction) {
        number(fraction, 'fraction', 1);
        return transact(candidate => remove(candidate, 'plantBiomass', fraction));
      }
    });
  }

  const api = Object.freeze({ create, validateSnapshot: input => validatedSnapshot(input), limits });
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.AquariumWaterEcosystem = api;
})(typeof globalThis === 'object' ? globalThis : this);
