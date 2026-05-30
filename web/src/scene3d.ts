import * as THREE from "three";

// A holographic, hue-shifting "typr" built from a grid of small 3D cubes sampled
// from the glyph shapes. It mostly sits still and then RATTLES in bursts — like a
// Pokéball with something trying to escape. Click and it bursts: every cube gets
// linear + angular velocity, gravity drags it down, it tumbles, bounces, and
// settles on the floor. Then the install command is revealed (typed out by the
// caller). Rebuild flies the cubes back into the word.

const FONT = '800 340px -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif';
const WORD = "typr";
const STEP = 4; // glyph sampling stride (px)
const CAM_Z = 6;
const FOV = 50;
const GRAVITY = -17;
const RESTITUTION = 0.4;
const FRICTION = 0.74;

type Phase = "idle" | "shatter" | "fallen" | "rebuild";

export interface Scene3D {
  shatter(): void;
  rebuild(): void;
  dispose(): void;
}

function sampleWord(text: string, step: number) {
  const c = document.createElement("canvas");
  const ctx = c.getContext("2d")!;
  ctx.font = FONT;
  const m = ctx.measureText(text);
  const w = Math.ceil(m.width) + 40;
  const h = 460;
  c.width = w;
  c.height = h;
  ctx.font = FONT;
  ctx.fillStyle = "#fff";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, w / 2, h / 2);
  const data = ctx.getImageData(0, 0, w, h).data;
  const pts: number[] = [];
  for (let y = 0; y < h; y += step) {
    for (let x = 0; x < w; x += step) {
      if (data[(y * w + x) * 4 + 3] > 128) pts.push(x, y);
    }
  }
  return { pts, w, h };
}

export function initScene(
  canvas: HTMLCanvasElement,
  onReveal: () => void,
  onRebuilt: () => void,
): Scene3D | null {
  let renderer: THREE.WebGLRenderer;
  try {
    renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  } catch {
    return null;
  }
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(FOV, 1, 0.1, 100);
  camera.position.z = CAM_Z;

  // --- sample the glyphs ----------------------------------------------------
  const { pts, w, h } = sampleWord(WORD, STEP);
  const count = pts.length / 2;
  const scale = 6.4 / w;
  const spacingWorld = STEP * scale;
  const cubeSize = spacingWorld * 1.25; // slight overlap -> letters read solid

  // resting state (object-local), live state (world during fall)
  const base = new Float32Array(count * 3);
  const restQuat = new Float32Array(count * 4); // small random tilt for facet variety
  const pos = new Float32Array(count * 3);
  const vel = new Float32Array(count * 3);
  const quat = new Float32Array(count * 4);
  const angvel = new Float32Array(count * 3);

  const tmpQ = new THREE.Quaternion();
  const tmpE = new THREE.Euler();
  for (let i = 0; i < count; i++) {
    const px = pts[i * 2];
    const py = pts[i * 2 + 1];
    base[i * 3] = (px - w / 2) * scale;
    base[i * 3 + 1] = (h / 2 - py) * scale;
    base[i * 3 + 2] = (Math.random() - 0.5) * 0.45; // slab depth
    tmpE.set(
      (Math.random() - 0.5) * 0.5,
      (Math.random() - 0.5) * 0.5,
      (Math.random() - 0.5) * 0.5,
    );
    tmpQ.setFromEuler(tmpE);
    restQuat[i * 4] = tmpQ.x;
    restQuat[i * 4 + 1] = tmpQ.y;
    restQuat[i * 4 + 2] = tmpQ.z;
    restQuat[i * 4 + 3] = tmpQ.w;
  }

  // --- instanced cubes ------------------------------------------------------
  const geo = new THREE.BoxGeometry(cubeSize, cubeSize, cubeSize);
  const mat = new THREE.ShaderMaterial({
    uniforms: { uTime: { value: 0 }, uBright: { value: 1 } },
    vertexShader: `
      uniform float uTime;
      varying vec3 vNormal;
      varying vec3 vView;
      varying vec3 vInst;
      void main() {
        vInst = vec3(instanceMatrix[3]); // cube centre
        vec4 mv = modelViewMatrix * instanceMatrix * vec4(position, 1.0);
        vView = -mv.xyz;
        vNormal = normalize(normalMatrix * mat3(instanceMatrix) * normal);
        gl_Position = projectionMatrix * mv;
      }
    `,
    fragmentShader: `
      precision highp float;
      uniform float uTime;
      uniform float uBright;
      varying vec3 vNormal;
      varying vec3 vView;
      varying vec3 vInst;
      vec3 hsv2rgb(vec3 c){
        vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
        return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
      }
      void main(){
        vec3 N = normalize(vNormal);
        vec3 V = normalize(vView);
        vec3 L = normalize(vec3(0.4, 0.7, 0.65));
        float diff = 0.5 + 0.5 * max(dot(N, L), 0.0);
        float fres = pow(1.0 - max(dot(N, V), 0.0), 2.5);
        // hue sweeps across the word + over time = hypershift; facets add variety
        float hue = fract(vInst.x * 0.07 + vInst.y * 0.05 + uTime * 0.06 + dot(N, vec3(0.0,0.0,1.0)) * 0.08);
        vec3 col = hsv2rgb(vec3(hue, 0.82, 1.0)) * diff;
        col += fres * 0.7;            // holographic rim sheen
        gl_FragColor = vec4(col * uBright, 1.0);
      }
    `,
  });

  const mesh = new THREE.InstancedMesh(geo, mat, count);
  mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  scene.add(mesh);

  const dummy = new THREE.Object3D();
  const cubeScale = new THREE.Vector3(1, 1, 1);

  function setRestMatrices() {
    for (let i = 0; i < count; i++) {
      dummy.position.set(base[i * 3], base[i * 3 + 1], base[i * 3 + 2]);
      dummy.quaternion.set(restQuat[i * 4], restQuat[i * 4 + 1], restQuat[i * 4 + 2], restQuat[i * 4 + 3]);
      dummy.scale.copy(cubeScale);
      dummy.updateMatrix();
      mesh.setMatrixAt(i, dummy.matrix);
    }
    mesh.instanceMatrix.needsUpdate = true;
  }
  setRestMatrices();

  // --- sizing ---------------------------------------------------------------
  function resize() {
    const cw = window.innerWidth;
    const ch = window.innerHeight;
    renderer.setSize(cw, ch, false);
    camera.aspect = cw / ch;
    camera.updateProjectionMatrix();
  }
  resize();
  window.addEventListener("resize", resize);

  const worldViewH = 2 * Math.tan((FOV * 0.5 * Math.PI) / 180) * CAM_Z;
  const floorY = -worldViewH / 2 + cubeSize;

  // --- state ----------------------------------------------------------------
  let phase: Phase = "idle";
  let idleT = 0;
  let shaking = false;
  let shakeT = 0;
  let nextShake = 1.0;
  let fallTimer = 0;
  let revealed = false;
  let rebuildT = 0;
  const rebuildFrom = new Float32Array(count * 3);
  const rebuildFromQ = new Float32Array(count * 4);
  const clock = new THREE.Clock();

  const matrix = new THREE.Matrix4();
  const vP = new THREE.Vector3();
  const vS = new THREE.Vector3();
  const qA = new THREE.Quaternion();
  const qB = new THREE.Quaternion();
  const vAxis = new THREE.Vector3();

  function bakeAndBurst() {
    mesh.updateMatrix(); // mesh.matrix from current rattle transform
    const instLocal = new THREE.Matrix4();
    const world = new THREE.Matrix4();
    for (let i = 0; i < count; i++) {
      vP.set(base[i * 3], base[i * 3 + 1], base[i * 3 + 2]);
      qA.set(restQuat[i * 4], restQuat[i * 4 + 1], restQuat[i * 4 + 2], restQuat[i * 4 + 3]);
      instLocal.compose(vP, qA, cubeScale);
      world.multiplyMatrices(mesh.matrix, instLocal);
      world.decompose(vP, qB, vS);
      pos[i * 3] = vP.x;
      pos[i * 3 + 1] = vP.y;
      pos[i * 3 + 2] = vP.z;
      quat[i * 4] = qB.x;
      quat[i * 4 + 1] = qB.y;
      quat[i * 4 + 2] = qB.z;
      quat[i * 4 + 3] = qB.w;
      // burst velocity: outward + upward pop + randomness
      vel[i * 3] = vP.x * 1.4 + (Math.random() - 0.5) * 3.8;
      vel[i * 3 + 1] = 1.8 + Math.random() * 3.2;
      vel[i * 3 + 2] = vP.z * 2.2 + (Math.random() - 0.5) * 3.8;
      // tumbling
      angvel[i * 3] = (Math.random() - 0.5) * 14;
      angvel[i * 3 + 1] = (Math.random() - 0.5) * 14;
      angvel[i * 3 + 2] = (Math.random() - 0.5) * 14;
    }
    mesh.position.set(0, 0, 0);
    mesh.rotation.set(0, 0, 0);
    mesh.updateMatrix();
  }

  function startShatter() {
    if (phase !== "idle") return;
    bakeAndBurst();
    phase = "shatter";
    fallTimer = 0;
    revealed = false;
  }

  function startRebuild() {
    if (phase !== "fallen") return;
    rebuildFrom.set(pos);
    rebuildFromQ.set(quat);
    rebuildT = 0;
    phase = "rebuild";
  }

  function writeInstance(i: number, px: number, py: number, pz: number, q: THREE.Quaternion) {
    vP.set(px, py, pz);
    matrix.compose(vP, q, cubeScale);
    mesh.setMatrixAt(i, matrix);
  }

  // --- loop -----------------------------------------------------------------
  let raf = 0;
  function frame() {
    raf = requestAnimationFrame(frame);
    const dt = Math.min(clock.getDelta(), 0.05);
    mat.uniforms.uTime.value += dt;

    if (phase === "idle") {
      idleT += dt;
      // a little constant life so it reads as 3D
      let ry = Math.sin(idleT * 0.5) * 0.22;
      let rx = Math.sin(idleT * 0.7) * 0.06;
      let rz = 0;
      let jx = 0;
      let jy = 0;
      // periodic rattle bursts
      if (!shaking && idleT >= nextShake) {
        shaking = true;
        shakeT = 0;
      }
      if (shaking) {
        shakeT += dt;
        const dur = 0.55;
        const env = Math.max(0, 1 - shakeT / dur);
        const f = 40;
        rz += Math.sin(shakeT * f) * 0.28 * env;
        rx += Math.sin(shakeT * f * 0.8 + 1.0) * 0.14 * env;
        jx = Math.sin(shakeT * f * 1.3) * 0.06 * env;
        jy = Math.sin(shakeT * f * 1.7) * 0.04 * env;
        if (shakeT >= dur) {
          shaking = false;
          nextShake = idleT + 1.4 + Math.random() * 2.4;
        }
      }
      mesh.rotation.set(rx, ry, rz);
      mesh.position.set(jx, jy, 0);
    } else if (phase === "shatter") {
      let settled = 0;
      for (let i = 0; i < count; i++) {
        const ix = i * 3;
        vel[ix + 1] += GRAVITY * dt;
        pos[ix] += vel[ix] * dt;
        pos[ix + 1] += vel[ix + 1] * dt;
        pos[ix + 2] += vel[ix + 2] * dt;
        if (pos[ix + 1] < floorY) {
          pos[ix + 1] = floorY;
          vel[ix + 1] = -vel[ix + 1] * RESTITUTION;
          vel[ix] *= FRICTION;
          vel[ix + 2] *= FRICTION;
          angvel[ix] *= FRICTION;
          angvel[ix + 1] *= FRICTION;
          angvel[ix + 2] *= FRICTION;
          if (Math.abs(vel[ix + 1]) < 0.4) {
            vel[ix + 1] = 0;
            settled++;
          }
        }
        // integrate rotation
        vAxis.set(angvel[ix], angvel[ix + 1], angvel[ix + 2]);
        const sp = vAxis.length();
        qA.set(quat[i * 4], quat[i * 4 + 1], quat[i * 4 + 2], quat[i * 4 + 3]);
        if (sp > 1e-4) {
          vAxis.multiplyScalar(1 / sp);
          qB.setFromAxisAngle(vAxis, sp * dt);
          qA.premultiply(qB).normalize();
          quat[i * 4] = qA.x;
          quat[i * 4 + 1] = qA.y;
          quat[i * 4 + 2] = qA.z;
          quat[i * 4 + 3] = qA.w;
        }
        writeInstance(i, pos[ix], pos[ix + 1], pos[ix + 2], qA);
      }
      mesh.instanceMatrix.needsUpdate = true;
      fallTimer += dt;
      mat.uniforms.uBright.value = Math.max(0.5, 1 - fallTimer * 0.22);
      if (!revealed && (settled > count * 0.55 || fallTimer > 2.2)) {
        revealed = true;
        onReveal();
      }
      if (fallTimer > 3.0) phase = "fallen";
    } else if (phase === "rebuild") {
      rebuildT = Math.min(1, rebuildT + dt * 1.3);
      const e = 1 - Math.pow(1 - rebuildT, 3);
      for (let i = 0; i < count; i++) {
        const ix = i * 3;
        const x = rebuildFrom[ix] + (base[ix] - rebuildFrom[ix]) * e;
        const y = rebuildFrom[ix + 1] + (base[ix + 1] - rebuildFrom[ix + 1]) * e;
        const z = rebuildFrom[ix + 2] + (base[ix + 2] - rebuildFrom[ix + 2]) * e;
        qA.set(rebuildFromQ[i * 4], rebuildFromQ[i * 4 + 1], rebuildFromQ[i * 4 + 2], rebuildFromQ[i * 4 + 3]);
        qB.set(restQuat[i * 4], restQuat[i * 4 + 1], restQuat[i * 4 + 2], restQuat[i * 4 + 3]);
        qA.slerp(qB, e);
        writeInstance(i, x, y, z, qA);
      }
      mesh.instanceMatrix.needsUpdate = true;
      mat.uniforms.uBright.value = 0.5 + e * 0.5;
      if (rebuildT >= 1) {
        setRestMatrices();
        mat.uniforms.uBright.value = 1;
        phase = "idle";
        idleT = 0;
        nextShake = 1.0;
        shaking = false;
        onRebuilt();
      }
    }

    renderer.render(scene, camera);
  }

  if (reduce) {
    renderer.render(scene, camera);
    onReveal();
  } else {
    raf = requestAnimationFrame(frame);
  }

  return {
    shatter: startShatter,
    rebuild: startRebuild,
    dispose() {
      cancelAnimationFrame(raf);
      window.removeEventListener("resize", resize);
      geo.dispose();
      mat.dispose();
      renderer.dispose();
    },
  };
}
