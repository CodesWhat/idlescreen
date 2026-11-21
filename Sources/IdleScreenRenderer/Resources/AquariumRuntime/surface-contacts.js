(function(root) {
  'use strict';

  function create(THREE, options) {
    const {world, bedLevel, halfWidth, backZ = -2.6, frontZ = 4, anchors = []} = options;
    const spacing = options.spacing ?? .28, offset = options.offset ?? .12;
    const radius = options.radius ?? .045, stepHeight = options.stepHeight ?? .10;
    const maxTriangles = options.maxTriangles ?? 40000, maxNodes = options.maxNodes ?? 4096;
    const maxAnchors = 512, maxEntries = 350000, maxCell = 2048, maxBuildTests = 18000000;
    const minX = -halfWidth + radius + .005, maxX = halfWidth - radius - .005;
    const minZ = backZ + radius + .005, maxZ = frontZ - radius - .005;
    const floorY = bedLevel + offset, maxEdge = spacing * 1.65;
    if (![bedLevel, halfWidth, backZ, frontZ, spacing, offset, radius, stepHeight].every(Number.isFinite) ||
        halfWidth <= 0 || backZ >= frontZ || spacing < .12 || spacing > .5 || radius <= 0 ||
        offset <= radius || stepHeight < 0 || stepHeight > .16 || minX >= maxX || minZ >= maxZ) {
      throw new Error('Finite, ordered contact bounds and valid sampling dimensions required');
    }
    if (![maxTriangles,maxNodes].every(n => Number.isSafeInteger(n) && n > 0) || anchors.length > maxAnchors) {
      throw new Error('Surface contact construction budget exceeded');
    }
    const triangles = [], triangleCells = new Map(), nodes = [], nodeCells = new Map();
    const anchorIds = new Map(), anchorEdges = [], agents = new WeakMap();
    const counters = {triangles:0,nodes:0,edges:0,bucketEntries:0,buildTriangleTests:0,queryTriangleTests:0,plans:0,maxExpanded:0};
    const normalScratch = new THREE.Vector3(), pointScratch = new THREE.Vector3(), closest = new THREE.Vector3();
    const ray = new THREE.Ray(), rayDirection = new THREE.Vector3(), rayHit = new THREE.Vector3();
    let building = true;
    const finite = p => p && [p.x,p.y,p.z].every(Number.isFinite);
    const vector = p => new THREE.Vector3(p.x,p.y,p.z);
    const key = (x,z) => x + ',' + z;
    const cell = x => Math.floor(x / spacing);
    const inBounds = p => p.x >= minX-1e-8 && p.x <= maxX+1e-8 && p.z >= minZ-1e-8 && p.z <= maxZ+1e-8 && p.y >= floorY-1e-7;
    function visit() {
      if (building) {
        if (++counters.buildTriangleTests > maxBuildTests) throw new Error('Surface contact construction work budget exceeded');
      } else counters.queryTriangleTests++;
    }
    function heightAt(t,x,z) {
      const dx=x-t.a.x,dz=z-t.a.z;
      const u=(dx*t.cz-dz*t.cx)/t.determinant,v=(t.bx*dz-t.bz*dx)/t.determinant;
      return u>=-1e-7 && v>=-1e-7 && u+v<=1+1e-7 ? t.a.y+u*t.by+v*t.cy : null;
    }
    function localTriangles(x,z) { return triangleCells.get(key(cell(x),cell(z))) || []; }
    function candidates(a,b,padding=0) {
      const ids = new Set();
      for(let x=cell(Math.min(a.x,b.x)-padding);x<=cell(Math.max(a.x,b.x)+padding);x++) {
        for(let z=cell(Math.min(a.z,b.z)-padding);z<=cell(Math.max(a.z,b.z)+padding);z++) {
          for(const id of triangleCells.get(key(x,z))||[]) ids.add(id);
        }
      }
      return ids;
    }
    const meshes = world?.meshes || [];
    let total = 0;
    for(const mesh of meshes) {
      const p=mesh.geometry?.attributes?.position,indices=mesh.geometry?.index;
      if(!p)continue;
      total+=(indices?.count??p.count)/3;
      if(total>maxTriangles)throw new Error('Surface triangle budget exceeded; captured blockers cannot be omitted');
    }
    for(let meshId=0;meshId<meshes.length;meshId++) {
      const mesh=meshes[meshId],positions=mesh.geometry?.attributes?.position,indices=mesh.geometry?.index;
      if(!positions)continue;
      const count=indices?.count??positions.count, mirrored=mesh.matrixWorld.determinant()<0;
      for(let i=0;i+2<count;i+=3) {
        const vertices=[0,1,2].map(j=>new THREE.Vector3().fromBufferAttribute(positions,indices?indices.getX(i+j):i+j).applyMatrix4(mesh.matrixWorld));
        if(!vertices.every(finite))throw new Error('Finite surface geometry required');
        const [a,b,c]=vertices,triangle=new THREE.Triangle(a,b,c),normal=triangle.getNormal(new THREE.Vector3());
        if(normal.lengthSq()<.5)continue;
        if(mirrored)normal.negate();
        const bounds=new THREE.Box3().setFromPoints(vertices);
        if(bounds.max.x<minX-radius||bounds.min.x>maxX+radius||bounds.max.z<minZ-radius||bounds.min.z>maxZ+radius)continue;
        const t={a,b,c,triangle,normal,bounds,meshId,bx:b.x-a.x,by:b.y-a.y,bz:b.z-a.z,cx:c.x-a.x,cy:c.y-a.y,cz:c.z-a.z};
        t.determinant=t.bx*t.cz-t.bz*t.cx;
        t.up=!!(mesh.userData.hardscape||mesh.userData.climbable)&&normal.y>=.45&&Math.abs(t.determinant)>1e-10;
        const id=triangles.push(t)-1;
        for(let x=cell(Math.max(minX-radius,bounds.min.x));x<=cell(Math.min(maxX+radius,bounds.max.x));x++) {
          for(let z=cell(Math.max(minZ-radius,bounds.min.z));z<=cell(Math.min(maxZ+radius,bounds.max.z));z++) {
            const k=key(x,z),bucket=triangleCells.get(k)||[];
            bucket.push(id);triangleCells.set(k,bucket);
            if(++counters.bucketEntries>maxEntries||bucket.length>maxCell)throw new Error('Surface spatial index budget exceeded');
          }
        }
      }
    }
    counters.triangles=triangles.length;

    function pointClear(p) {
      if(!inBounds(p))return false;
      const firstAbove=new Map();
      for(const id of localTriangles(p.x,p.z)) {
        visit();const t=triangles[id];if(Math.abs(t.determinant)<1e-10)continue;
        const y=heightAt(t,p.x,p.z);
        if(y!==null&&y>p.y+1e-7&&(!firstAbove.has(t.meshId)||firstAbove.get(t.meshId).y>y))firstAbove.set(t.meshId,{y,normal:t.normal.y});
      }
      for(const hit of firstAbove.values())if(hit.normal>1e-6)return false;
      for(const id of candidates(p,p,radius)) {
        visit();const t=triangles[id];
        if(t.bounds.distanceToPoint(p)>radius)continue;
        t.triangle.closestPointToPoint(p,closest);
        if((p.x-closest.x)**2+(p.y-closest.y)**2+(p.z-closest.z)**2<radius*radius-1e-9)return false;
      }
      return true;
    }
    function supports(x,z) {
      const found=[{x,y:floorY,z,normal:new THREE.Vector3(0,1,0),kind:'floor'}];
      for(const id of localTriangles(x,z)) {
        visit();const t=triangles[id];if(!t.up)continue;
        const y=heightAt(t,x,z);
        if(y!==null&&y>=bedLevel-1e-7&&!found.some(p=>Math.abs(p.y-y-offset)<1e-6)) {
          found.push({x,y:y+offset,z,normal:t.normal.clone(),kind:'hardscape'});
        }
      }
      return found.filter(pointClear);
    }
    function sampleSupport(x,z,previousY=floorY) {
      if(![x,z,previousY].every(Number.isFinite))return null;
      let nearest=null,best=.20+1e-8;
      for(const p of supports(x,z)) {
        const d=Math.abs(p.y-previousY);if(d<best){best=d;nearest=p;}
      }
      return nearest;
    }
    function segmentDistanceSq(a,b,c,d) {
      const ux=b.x-a.x,uy=b.y-a.y,uz=b.z-a.z,vx=d.x-c.x,vy=d.y-c.y,vz=d.z-c.z;
      const wx=a.x-c.x,wy=a.y-c.y,wz=a.z-c.z;
      const aa=ux*ux+uy*uy+uz*uz,bb=ux*vx+uy*vy+uz*vz,cc=vx*vx+vy*vy+vz*vz;
      const dd=ux*wx+uy*wy+uz*wz,ee=vx*wx+vy*wy+vz*wz,den=aa*cc-bb*bb;
      let sn=den<1e-12?0:bb*ee-cc*dd,sd=den<1e-12?1:den,tn=den<1e-12?ee:aa*ee-bb*dd,td=den<1e-12?cc:den;
      if(sn<0){sn=0;tn=ee;td=cc;}else if(sn>sd){sn=sd;tn=ee+bb;td=cc;}
      if(tn<0){tn=0;if(-dd<0)sn=0;else if(-dd>aa)sn=sd;else{sn=-dd;sd=aa;}}
      else if(tn>td){tn=td;if(-dd+bb<0)sn=0;else if(-dd+bb>aa)sn=sd;else{sn=-dd+bb;sd=aa;}}
      const s=Math.abs(sn)<1e-12?0:sn/sd,t=Math.abs(tn)<1e-12?0:tn/td;
      return (wx+s*ux-t*vx)**2+(wy+s*uy-t*vy)**2+(wz+s*uz-t*vz)**2;
    }
    function segmentClear(a,b) {
      if(!inBounds(a)||!inBounds(b))return false;
      const length=a.distanceTo(b);if(length<1e-9)return true;
      rayDirection.copy(b).sub(a).divideScalar(length);ray.set(a,rayDirection);
      const lowX=Math.min(a.x,b.x)-radius,highX=Math.max(a.x,b.x)+radius;
      const lowY=Math.min(a.y,b.y)-radius,highY=Math.max(a.y,b.y)+radius;
      const lowZ=Math.min(a.z,b.z)-radius,highZ=Math.max(a.z,b.z)+radius;
      const threshold=radius*radius-1e-9;
      for(const id of candidates(a,b,radius)) {
        visit();const t=triangles[id],bounds=t.bounds;
        if(bounds.max.x<lowX||bounds.min.x>highX||bounds.max.y<lowY||bounds.min.y>highY||bounds.max.z<lowZ||bounds.min.z>highZ)continue;
        if(ray.intersectTriangle(t.a,t.b,t.c,false,rayHit)&&rayHit.distanceTo(a)<=length+1e-8)return false;
        t.triangle.closestPointToPoint(a,closest);if(a.distanceToSquared(closest)<threshold)return false;
        t.triangle.closestPointToPoint(b,closest);if(b.distanceToSquared(closest)<threshold)return false;
        if(segmentDistanceSq(a,b,t.a,t.b)<threshold||segmentDistanceSq(a,b,t.b,t.c)<threshold||segmentDistanceSq(a,b,t.c,t.a)<threshold)return false;
      }
      return true;
    }
    function supported(p) {
      const tolerance=stepHeight*.65+1e-6;
      if(Math.abs(p.y-floorY)<=tolerance)return true;
      for(const id of localTriangles(p.x,p.z)) {
        visit();const t=triangles[id];if(!t.up)continue;
        const y=heightAt(t,p.x,p.z);
        if(y!==null&&Math.abs(p.y-y-offset)<=tolerance)return true;
      }
      return false;
    }
    function surfaceSegment(a,b) {
      const horizontal=Math.hypot(a.x-b.x,a.z-b.z);
      if(Math.abs(a.y-b.y)>horizontal*1.95+stepHeight||!segmentClear(a,b))return false;
      const count=Math.max(1,Math.ceil(a.distanceTo(b)/.035));
      for(let i=0;i<=count;i++)if(!supported(pointScratch.copy(a).lerp(b,i/count)))return false;
      return true;
    }
    function nearby(p,distance) {
      const found=[];
      for(let x=cell(p.x-distance);x<=cell(p.x+distance);x++)for(let z=cell(p.z-distance);z<=cell(p.z+distance);z++) {
        for(const id of nodeCells.get(key(x,z))||[])if(nodes[id].p.distanceTo(p)<=distance+1e-7)found.push(id);
      }
      return found;
    }
    function addNode(p,kind,normal,id=null) {
      if(nodes.length>=maxNodes)throw new Error('Surface node budget exceeded');
      const node={p:vector(p),kind,normal:normal.clone(),id,edges:[]},index=nodes.push(node)-1,k=key(cell(p.x),cell(p.z));
      const bucket=nodeCells.get(k)||[];bucket.push(index);nodeCells.set(k,bucket);
      return index;
    }
    const nx=Math.ceil((maxX-minX)/spacing),nz=Math.ceil((maxZ-minZ)/spacing);
    if((nx+1)*(nz+1)>maxNodes)throw new Error('Floor sampling budget exceeded');
    for(let x=0;x<=nx;x++)for(let z=0;z<=nz;z++) {
      for(const p of supports(minX+(maxX-minX)*x/nx,minZ+(maxZ-minZ)*z/nz))addNode(p,p.kind,p.normal);
    }
    // Thin branches can miss the floor grid; retain separated real face centers.
    for(const t of triangles)if(t.up) {
      const p=t.triangle.getMidpoint(new THREE.Vector3());p.y+=offset;
      if(!inBounds(p)||nearby(p,spacing*.6).length||!pointClear(p))continue;
      addNode(p,'hardscape',t.normal);
    }
    function link(a,b) {
      if(a===b||nodes[a].edges.some(edge=>edge.id===b))return;
      const cost=nodes[a].p.distanceTo(nodes[b].p);
      nodes[a].edges.push({id:b,cost});nodes[b].edges.push({id:a,cost});counters.edges++;
    }
    const surfaceCount=nodes.length;
    for(let i=0;i<surfaceCount;i++)for(const j of nearby(nodes[i].p,maxEdge)) {
      if(j>i&&surfaceSegment(nodes[i].p,nodes[j].p))link(i,j);
    }
    for(const anchor of anchors) {
      if(typeof anchor.id!=='string'||anchorIds.has(anchor.id)||!finite(anchor.position)||!Array.isArray(anchor.links))throw new Error('Unique anchor ids, finite contact positions and explicit links required');
      if(anchor.normal&&(!finite(anchor.normal)||vector(anchor.normal).lengthSq()<1e-12))throw new Error('Finite nonzero anchor normals required');
      const normal=anchor.normal?vector(anchor.normal).normalize():new THREE.Vector3(0,1,0);
      const p=vector(anchor.position).addScaledVector(normal,offset);
      if(!pointClear(p))throw new Error('Anchor '+anchor.id+' intersects a hard solid or tank boundary');
      const index=addNode(p,anchor.kind==='hardscape'?'hardscape':'foliage',normal,anchor.id);
      nodes[index].contact=vector(anchor.position);anchorIds.set(anchor.id,index);
    }
    for(const anchor of anchors) {
      const a=anchorIds.get(anchor.id);
      for(const id of anchor.links) {
        const b=anchorIds.get(id);
        if(b===undefined)throw new Error('Unknown anchor link '+id);
        if(a===b||nodes[a].p.distanceTo(nodes[b].p)>.65)throw new Error('Anchor links must trace short, distinct physical contacts');
        if(segmentClear(nodes[a].p,nodes[b].p)) {
          link(a,b);if(!anchorEdges.some(e=>e[0]===b&&e[1]===a))anchorEdges.push([a,b]);
        }
      }
      for(const b of nearby(nodes[a].p,maxEdge))if(b<surfaceCount&&surfaceSegment(nodes[a].p,nodes[b].p))link(a,b);
    }
    counters.nodes=nodes.length;
    const grounded=new Set(),queue=[];
    for(let i=0;i<nodes.length;i++)if(nodes[i].kind==='floor'){grounded.add(i);queue.push(i);}
    for(let i=0;i<queue.length;i++)for(const edge of nodes[queue[i]].edges)if(!grounded.has(edge.id)){grounded.add(edge.id);queue.push(edge.id);}
    building=false;

    function onAnchorSegment(p,nodeId) {
      for(const [a,b] of anchorEdges)if(a===nodeId||b===nodeId) {
        const start=nodes[a].p,end=nodes[b].p;
        normalScratch.copy(end).sub(start);
        const t=THREE.MathUtils.clamp(pointScratch.copy(p).sub(start).dot(normalScratch)/normalScratch.lengthSq(),0,1);
        pointScratch.copy(start).addScaledVector(normalScratch,t);
        if(pointScratch.distanceTo(p)<1e-5)return true;
      }
      return false;
    }
    function connectors(p) {
      return nearby(p,Math.max(maxEdge,.65)).sort((a,b)=>nodes[a].p.distanceToSquared(p)-nodes[b].p.distanceToSquared(p)).filter(id=>
        p.distanceTo(nodes[id].p)<1e-7 || (onAnchorSegment(p,id)&&segmentClear(p,nodes[id].p)) ||
        (p.distanceTo(nodes[id].p)<=maxEdge&&surfaceSegment(p,nodes[id].p))
      ).slice(0,16).map(id=>({id,cost:nodes[id].p.distanceTo(p)}));
    }
    function projectGoal(to) {
      let p=sampleSupport(to.x,to.z,to.y),best=p?Math.abs(p.y-to.y):Infinity;
      for(const id of anchorIds.values()) {
        const node=nodes[id],distance=Math.min(node.p.distanceTo(to),node.contact.distanceTo(to));
        if(distance<.12&&distance<best){p={...node.p,kind:node.kind,contactId:node.id};best=distance;}
      }
      if(!p)return null;
      const result=vector(p);result.kind=p.kind;result.contactId=p.contactId??null;return result;
    }
    function plan(from,to) {
      counters.plans++;
      if(!finite(from)||!finite(to))return null;
      const start=vector(from),end=projectGoal(to);
      if(!end||!pointClear(start))return null;
      if(start.distanceTo(end)<1e-8)return[end];
      if(start.distanceTo(end)<=maxEdge&&surfaceSegment(start,end))return[start,end];
      const initial=connectors(start),final=connectors(end);
      if(!initial.length||!final.length)return null;
      const endCosts=new Map(final.map(e=>[e.id,e.cost]));
      const distances=new Float64Array(nodes.length);distances.fill(Infinity);
      const previous=new Int32Array(nodes.length);previous.fill(-1);
      const closed=new Uint8Array(nodes.length),heap=[];
      function push(id,score) {
        let i=heap.length;heap.push({id,score});
        while(i>0){const p=(i-1)>>1;if(heap[p].score<=score)break;heap[i]=heap[p];i=p;}heap[i]={id,score};
      }
      function pop() {
        const head=heap[0],tail=heap.pop();if(!heap.length)return head;
        let i=0;while(i*2+1<heap.length){let child=i*2+1;if(child+1<heap.length&&heap[child+1].score<heap[child].score)child++;if(heap[child].score>=tail.score)break;heap[i]=heap[child];i=child;}heap[i]=tail;return head;
      }
      for(const edge of initial){distances[edge.id]=edge.cost;push(edge.id,edge.cost+nodes[edge.id].p.distanceTo(end));}
      let chosen=-1,best=Infinity,expanded=0;
      while(heap.length) {
        const next=pop(),id=next.id;if(next.score>=best)break;if(closed[id])continue;
        closed[id]=1;expanded++;
        if(endCosts.has(id)&&distances[id]+endCosts.get(id)<best){best=distances[id]+endCosts.get(id);chosen=id;}
        for(const edge of nodes[id].edges) {
          const cost=distances[id]+edge.cost;
          if(!closed[edge.id]&&cost<distances[edge.id]){distances[edge.id]=cost;previous[edge.id]=id;push(edge.id,cost+nodes[edge.id].p.distanceTo(end));}
        }
      }
      counters.maxExpanded=Math.max(counters.maxExpanded,expanded);
      if(chosen<0)return null;
      const route=[end];
      for(let id=chosen;id>=0;id=previous[id]){const p=nodes[id].p.clone();p.kind=nodes[id].kind;p.contactId=nodes[id].id;route.push(p);}
      route.push(start);route.reverse();
      return route.filter((p,i)=>!i||p.distanceTo(route[i-1])>1e-8);
    }
    function step(agent,dt,target,state='forage') {
      agent.walking=false;
      if(!Number.isFinite(dt)||dt<=0||!finite(agent.position)||!finite(target)||['recover','premolt','dead','eat','graze'].includes(state))return false;
      let cached=agents.get(agent);
      if(!cached||cached.target.distanceTo(target)>.08||cached.expected.distanceTo(agent.position)>.025) {
        cached={target:vector(target),route:plan(agent.position,target),next:1,expected:agent.position.clone()};agents.set(agent,cached);
      }
      if(!cached.route)return false;
      if(cached.route.length===1)agent.contactId=cached.route[0].contactId??null;
      const speed=Number.isFinite(agent.speed)?Math.max(0,agent.speed):.1;
      let remaining=speed*Math.min(1,dt),iterations=0;
      const before=agent.position.clone();
      while(remaining>1e-10&&cached.next<cached.route.length&&iterations++<64) {
        const destination=cached.route[cached.next],distance=agent.position.distanceTo(destination);
        if(distance<=remaining+1e-10){agent.position.copy(destination);remaining-=distance;cached.next++;agent.contactId=destination.contactId??null;}
        else{agent.position.lerp(destination,remaining/distance);remaining=0;agent.contactId=null;}
        if(destination.kind)agent.contactKind=destination.kind;
      }
      cached.expected.copy(agent.position);
      agent.walking=agent.position.distanceToSquared(before)>1e-14;
      if(Math.abs(agent.position.x-before.x)>1e-8)agent.facing=agent.position.x<before.x?-1:1;
      return agent.walking;
    }
    return {
      sampleSupport,plan,step,
      get stats(){return{...counters};},
      get sites(){return nodes.flatMap((node,id)=>grounded.has(id)&&node.kind!=='floor'?[{id:node.id,kind:node.kind,position:node.p.clone()}]:[]);},
    };
  }
  const api={create};
  if(typeof module==='object'&&module.exports)module.exports=api;else root.AquariumSurfaceContacts=api;
})(typeof window==='object'?window:globalThis);
