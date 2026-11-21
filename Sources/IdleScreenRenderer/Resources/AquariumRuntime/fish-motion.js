(function (root) {
  'use strict';

  const MAX_SPEED = .55, MAX_FRAME = .1, SUBSTEP = 1 / 60;

  function random(agent) {
    agent._random = (agent._random + 0x6d2b79f5) >>> 0;
    let value = agent._random;
    value = Math.imul(value ^ value >>> 15, value | 1);
    value ^= value + Math.imul(value ^ value >>> 7, value | 61);
    return ((value ^ value >>> 14) >>> 0) / 4294967296;
  }

  function createAgent(THREE, position, seed, clock = 0) {
    const agent = {
      position: position.clone(), velocity: new THREE.Vector3(),
      facing: 1, state: 'cruise', target: null, radius: .29,
      _random: seed >>> 0, _seed: seed >>> 0, _time: clock,
      _targetUntil: clock + 24, _avoidTarget: null, _avoidUntil: 0,
      _faceCandidate: 1, _faceTime: 0,
    };
    agent.speed = .25 + random(agent) * .30;
    agent._phase = random(agent) * Math.PI * 2;
    agent._depthSign = random(agent) < .5 ? -1 : 1;
    agent._nextPause = clock + 6 + random(agent) * 12;
    agent._pauseUntil = 0;
    return agent;
  }

  function contain(position, bounds, radius) {
    const margin = Math.max(.5, radius);
    position.x = Math.max(-bounds.halfWidth + margin, Math.min(bounds.halfWidth - margin, position.x));
    position.y = Math.max(bounds.bedLevel + .7, Math.min(bounds.waterLevel - .4, position.y));
    position.z = Math.max(bounds.backZ + radius, Math.min(bounds.frontZ - radius, position.z));
    return position;
  }

  function chooseTarget(THREE, agent, bounds) {
    const direction = random(agent) < .5 ? -1 : 1;
    agent.target = contain(new THREE.Vector3(
      agent.position.x + direction * (2 + random(agent) * 3),
      agent.position.y + (random(agent) - .5) * 2.5,
      agent.position.z + (random(agent) - .5) * 3.8
    ), bounds, agent.radius + .08);
    if(agent._illumination<.18){
      const shelter=agent._shelters?.length?agent._shelters.reduce((best,p)=>agent.position.distanceTo(new THREE.Vector3(p.x,p.y,p.z))<agent.position.distanceTo(new THREE.Vector3(best.x,best.y,best.z))?p:best):null;
      agent.target.y=bounds.bedLevel+1.1+(agent._seed%5)*.12;if(shelter)agent.target.lerp(new THREE.Vector3(shelter.x,shelter.y,shelter.z),.8);contain(agent.target,bounds,agent.radius+.08);
    }
    agent._targetUntil = agent._time + 18 + random(agent) * 10;
  }

  function probe(agent, direction, distance, bounds, world) {
    const to = contain(agent.position.clone().addScaledVector(direction, distance), bounds, agent.radius);
    if (to.distanceTo(agent.position) < distance * .75) return null;
    if (!world) return { position: to, collided: false };
    return world.moveSphere(agent.position, to, agent.radius + .035);
  }

  function detour(THREE, agent, direction, bounds, world, normal) {
    const side = agent._depthSign;
    const directions = [
      new THREE.Vector3(direction.x * .25, direction.y * .2, side),
      new THREE.Vector3(direction.x * .25, direction.y * .2, -side),
      new THREE.Vector3(direction.x * .2, 1, direction.z * .3),
      new THREE.Vector3(direction.x * .2, -1, direction.z * .3),
      new THREE.Vector3(direction.x * .25, .7, side * .7),
      new THREE.Vector3(direction.x * .25, -.7, -side * .7),
      direction.clone().negate(),
    ];
    if (normal) directions.unshift(direction.clone().addScaledVector(normal, 1.5));
    let best = null, bestScore = -Infinity;
    for (let i = 0; i < directions.length; i++) {
      const candidate = directions[i].normalize();
      const contact = probe(agent, candidate, 1.35, bounds, world);
      if (!contact || contact.collided) continue;
      const score = candidate.dot(direction) + candidate.z * side * .15 + candidate.y * .04 - i * .003;
      if (score > bestScore) { best = contact.position; bestScore = score; }
    }
    if (best) {
      agent._avoidTarget = best.clone();
      agent._avoidUntil = agent._time + 6;
      return best.clone().sub(agent.position).normalize();
    }
    chooseTarget(THREE, agent, bounds);
    agent._avoidTarget = null;
    return agent.target.clone().sub(agent.position).normalize();
  }

  function socialSteering(THREE, agent, others) {
    const separation = new THREE.Vector3(), center = new THREE.Vector3();
    let neighbors = 0;
    for (const other of others) {
      if (other.agent === agent) continue;
      const away = agent.position.clone().sub(other.position), distance = away.length();
      if (distance < 5) { center.add(other.position); neighbors++; }
      if (distance >= .95) continue;
      if (distance < .0001) {
        const sign = agent._seed < other.agent._seed ? -1 : 1;
        away.set(sign, .3 * sign, .5 * sign).normalize();
      } else away.divideScalar(distance);
      separation.addScaledVector(away, (1 - distance / .95) * 2.8);
    }
    if (neighbors) {
      center.divideScalar(neighbors).sub(agent.position);
      if (center.length() > 1.6) separation.addScaledVector(center.normalize(), .13);
    }
    return separation;
  }

  function updateFacing(agent, elapsed) {
    if (Math.abs(agent.velocity.x) < .065) { agent._faceTime = 0; return; }
    const facing = agent.velocity.x < 0 ? -1 : 1;
    if (facing === agent.facing) { agent._faceTime = 0; return; }
    if (agent._faceCandidate !== facing) { agent._faceCandidate = facing; agent._faceTime = 0; }
    agent._faceTime += elapsed;
    if (agent._faceTime >= .24) { agent.facing = facing; agent._faceTime = 0; }
  }

  function advance(THREE, agent, others, elapsed, bounds, world, foodPositions, environment) {
    agent._time += elapsed;
    const illumination=Number.isFinite(environment?.illumination)?Math.max(0,Math.min(1,environment.illumination)):1,previous=agent._illumination;
    if(previous!==undefined&&Math.abs(illumination-previous)>.30){
      agent._startleUntil=agent._time+1.4+(agent._seed%5)*.08;
      agent.target=contain(agent.position.clone().add(new THREE.Vector3(agent._seed%2?1.5:-1.5,-.8,agent._depthSign*.9)),bounds,agent.radius+.08);agent._avoidTarget=null;
    }else if(previous!==undefined&&previous>=.18&&illumination<.18)agent.target=null;
    agent._illumination=illumination;agent._shelters=environment?.shelters||[];
    const startled=agent._time<(agent._startleUntil||0),dark=illumination<.18;
    agent.lightState=startled?'startle':dark?'sheltered':'active';
    if (!agent.target || agent._time >= agent._targetUntil || agent.position.distanceTo(agent.target) < .3) chooseTarget(THREE, agent, bounds);
    if (agent.state === 'pause' && agent._time >= agent._pauseUntil) {
      agent.state = 'cruise';
      agent._nextPause = agent._time + 6 + random(agent) * 13;
      chooseTarget(THREE, agent, bounds);
    } else if (agent.state === 'cruise' && agent._time >= agent._nextPause) {
      agent.state = 'pause';
      agent._pauseUntil = agent._time + .7 + random(agent) * 1.6;
    }
    if (agent._avoidTarget && (agent._time >= agent._avoidUntil || agent.position.distanceTo(agent._avoidTarget) < .25)) agent._avoidTarget = null;

    let target = agent._avoidTarget || agent.target;
    if (!startled && !agent._avoidTarget && agent.hungry !== false) {
      let nearestDistance = 1.8;
      for (const food of foodPositions) {
        if (!food || !Number.isFinite(food.x + food.y + food.z) || food.y < bounds.bedLevel + .7 || food.y > bounds.waterLevel - .4) continue;
        const distance = agent.position.distanceTo(food);
        if (distance > .35 && distance < nearestDistance) { nearestDistance = distance; target = food; }
      }
    }
    const social = socialSteering(THREE, agent, others);
    let direction = target.clone().sub(agent.position).normalize().add(social).normalize();
    const speed = startled ? MAX_SPEED : agent.state === 'pause' ? 0 : agent.speed * (dark?.28:.65+.35*illumination) * (.91 + .09 * Math.sin(agent._time * .8 + agent._phase));
    let desired = direction.clone().multiplyScalar(speed);
    if (agent.state === 'pause'&&!startled) desired = social.multiplyScalar(.2).clampLength(0, .25);

    if (desired.lengthSq() > .0001) {
      direction.copy(desired).normalize();
      const ahead = probe(agent, direction, .75 + agent.velocity.length() * .4, bounds, world);
      if (!ahead || ahead.collided) {
        direction = detour(THREE, agent, direction, bounds, world, ahead && ahead.normal);
        desired.copy(direction).multiplyScalar(speed);
      }
    }
    agent.velocity.lerp(desired, 1 - Math.exp(-elapsed * 3)).clampLength(0, MAX_SPEED);
    const from = agent.position, next = contain(from.clone().addScaledVector(agent.velocity, elapsed), bounds, agent.radius);
    const contact = world ? world.moveSphere(from, next, agent.radius) : { position: next, collided: false };
    if (contact.collided) {
      // A mesh contact can contain a depenetration offset; never turn it into a visual jump.
      if (contact.position.distanceTo(from) <= MAX_SPEED * elapsed + 1e-8) agent.position.copy(contain(contact.position, bounds, agent.radius));
      if (contact.normal) agent.velocity.addScaledVector(contact.normal, -Math.min(0, agent.velocity.dot(contact.normal)));
      chooseTarget(THREE, agent, bounds);
      agent._avoidTarget = null;
      detour(THREE, agent, direction, bounds, world, contact.normal);
    } else agent.position.copy(next);
    updateFacing(agent, elapsed);
  }

  function step(THREE, agents, dt, clock, bounds, collisionWorld, foodPositions = [], environment = {}) {
    if (!Number.isFinite(dt) || dt <= 0) return agents;
    let remaining = Math.min(MAX_FRAME, dt);
    while (remaining > 1e-9) {
      const elapsed = Math.min(SUBSTEP, remaining);
      const others = agents.map(agent => ({ agent, position: agent.position.clone() }));
      for (const agent of agents) advance(THREE, agent, others, elapsed, bounds, collisionWorld, foodPositions, environment);
      remaining -= elapsed;
    }
    return agents;
  }

  const api = { createAgent, step };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.AquariumFishMotion = api;
})(typeof window === 'object' ? window : globalThis);
