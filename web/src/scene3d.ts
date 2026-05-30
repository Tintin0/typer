import * as THREE from "three";

// A holographic, hue-shifting "typr" built from a cloud of glowing points sampled
// from the glyph shapes. It spins idly; click and it shatters — every point gets
// a velocity, gravity drags it to the floor where it bounces and settles — then
// the install command is revealed. Click rebuild and it flies back together.

const FONT = '800 340px -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif';
const WORD = "typr";
const STEP = 3; // glyph sampling stride (px) — smaller = denser word
const CAM_Z = 6;
const FOV = 50;
const GRAVITY = -16;
const RESTITUTION = 0.42;
const FRICTION = 0.78;

type Phase = "spin" | "shatter" | "fallen" | "rebuild";

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

  // --- build the point cloud from the glyphs --------------------------------
  const { pts, w, h } = sampleWord(WORD, STEP);
  const count = pts.length / 2;
  const scale = 6.4 / w; // world width of the word
  const spacingWorld = STEP * scale;

  const position = new Float32Array(count * 3);
  const base = new Float32Array(count * 3); // resting (word) positions
  const vel = new Float32Array(count * 3);
  const aRand = new Float32Array(count);

  for (let i = 0; i < count; i++) {
    const px = pts[i * 2];
    const py = pts[i * 2 + 1];
    const x = (px - w / 2) * scale;
    const y = (h / 2 - py) * scale;
    const z = (Math.random() - 0.5) * 0.4; // slab depth -> reads as 3D when spun
    base[i * 3] = x;
    base[i * 3 + 1] = y;
    base[i * 3 + 2] = z;
    position[i * 3] = x;
    position[i * 3 + 1] = y;
    position[i * 3 + 2] = z;
    aRand[i] = Math.random();
  }

  const geo = new THREE.BufferGeometry();
  const posAttr = new THREE.BufferAttribute(position, 3);
  posAttr.setUsage(THREE.DynamicDrawUsage);
  geo.setAttribute("position", posAttr);
  geo.setAttribute("aRand", new THREE.BufferAttribute(aRand, 1));

  const mat = new THREE.ShaderMaterial({
    transparent: true,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    uniforms: {
      uTime: { value: 0 },
      uSize: { value: 8 },
      uCamZ: { value: CAM_Z },
      uBright: { value: 1 },
    },
    vertexShader: `
      attribute float aRand;
      uniform float uTime;
      uniform float uSize;
      uniform float uCamZ;
      varying float vRand;
      varying vec3 vPos;
      void main() {
        vRand = aRand;
        vPos = position;
        vec4 mv = modelViewMatrix * vec4(position, 1.0);
        gl_PointSize = uSize * (uCamZ / -mv.z);
        gl_Position = projectionMatrix * mv;
      }
    `,
    fragmentShader: `
      precision highp float;
      uniform float uTime;
      uniform float uBright;
      varying float vRand;
      varying vec3 vPos;
      vec3 hsv2rgb(vec3 c){
        vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0);
        return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
      }
      void main(){
        vec2 uv = gl_PointCoord - 0.5;
        float d = length(uv);
        if (d > 0.5) discard;
        float glow = smoothstep(0.5, 0.0, d);
        // hue sweeps across the word and shifts over time = hypershift
        float hue = fract(vPos.x * 0.07 + vPos.y * 0.05 + uTime * 0.06 + vRand * 0.12);
        vec3 col = hsv2rgb(vec3(hue, 0.85, 1.0));
        col += pow(glow, 3.0) * 0.5;        // hot core
        gl_FragColor = vec4(col * uBright, glow);
      }
    `,
  });

  const word = new THREE.Points(geo, mat);
  scene.add(word);

  // --- sizing ----------------------------------------------------------------
  function resize() {
    const cw = window.innerWidth;
    const ch = window.innerHeight;
    renderer.setSize(cw, ch, false);
    camera.aspect = cw / ch;
    camera.updateProjectionMatrix();
    // self-tune point size so the glyphs read as solid regardless of viewport
    const worldViewH = 2 * Math.tan((FOV * 0.5 * Math.PI) / 180) * CAM_Z;
    const pxPerWorld = renderer.domElement.height / worldViewH;
    mat.uniforms.uSize.value = spacingWorld * pxPerWorld * 1.8;
  }
  resize();
  window.addEventListener("resize", resize);

  // floor sits just below the visible area's bottom
  const worldViewH = 2 * Math.tan((FOV * 0.5 * Math.PI) / 180) * CAM_Z;
  const floorY = -worldViewH / 2 + 0.15;

  // --- state -----------------------------------------------------------------
  let phase: Phase = "spin";
  let spin = 0;
  let fallenTimer = 0;
  let revealed = false;
  let rebuildT = 0;
  const rebuildFrom = new Float32Array(count * 3);
  const clock = new THREE.Clock();

  function bakeRotationIntoPositions() {
    // freeze the current spun orientation into the buffer, then zero rotation
    word.updateMatrixWorld(true);
    const m = word.matrix;
    const v = new THREE.Vector3();
    for (let i = 0; i < count; i++) {
      v.set(base[i * 3], base[i * 3 + 1], base[i * 3 + 2]).applyMatrix4(m);
      position[i * 3] = v.x;
      position[i * 3 + 1] = v.y;
      position[i * 3 + 2] = v.z;
    }
    word.rotation.set(0, 0, 0);
  }

  function startShatter() {
    if (phase !== "spin") return;
    bakeRotationIntoPositions();
    for (let i = 0; i < count; i++) {
      const x = position[i * 3];
      // outward burst + upward pop + randomness, then gravity takes over
      vel[i * 3] = x * 1.3 + (Math.random() - 0.5) * 3.5;
      vel[i * 3 + 1] = 1.5 + Math.random() * 3.0;
      vel[i * 3 + 2] = position[i * 3 + 2] * 2.0 + (Math.random() - 0.5) * 3.5;
    }
    posAttr.needsUpdate = true;
    phase = "shatter";
    fallenTimer = 0;
    revealed = false;
  }

  function startRebuild() {
    if (phase !== "fallen") return;
    rebuildFrom.set(position);
    rebuildT = 0;
    phase = "rebuild";
  }

  // --- loop ------------------------------------------------------------------
  let raf = 0;
  function frame() {
    raf = requestAnimationFrame(frame);
    const dt = Math.min(clock.getDelta(), 0.05);
    mat.uniforms.uTime.value += dt;

    if (phase === "spin") {
      spin += dt * 0.5;
      word.rotation.y = Math.sin(spin) * 0.7; // gentle readable rocking
      word.rotation.x = Math.sin(spin * 0.6) * 0.12;
    } else if (phase === "shatter") {
      let settled = 0;
      for (let i = 0; i < count; i++) {
        const ix = i * 3;
        vel[ix + 1] += GRAVITY * dt;
        position[ix] += vel[ix] * dt;
        position[ix + 1] += vel[ix + 1] * dt;
        position[ix + 2] += vel[ix + 2] * dt;
        if (position[ix + 1] < floorY) {
          position[ix + 1] = floorY;
          vel[ix + 1] = -vel[ix + 1] * RESTITUTION;
          vel[ix] *= FRICTION;
          vel[ix + 2] *= FRICTION;
          if (Math.abs(vel[ix + 1]) < 0.4) {
            vel[ix + 1] = 0;
            settled++;
          }
        }
      }
      posAttr.needsUpdate = true;
      fallenTimer += dt;
      // dim the rubble as it settles
      mat.uniforms.uBright.value = Math.max(0.45, 1 - fallenTimer * 0.25);
      if (!revealed && (settled > count * 0.6 || fallenTimer > 2.4)) {
        revealed = true;
        onReveal();
      }
      if (fallenTimer > 3.0) phase = "fallen";
    } else if (phase === "rebuild") {
      rebuildT = Math.min(1, rebuildT + dt * 1.4);
      const e = 1 - Math.pow(1 - rebuildT, 3); // easeOutCubic
      for (let i = 0; i < count; i++) {
        const ix = i * 3;
        position[ix] = rebuildFrom[ix] + (base[ix] - rebuildFrom[ix]) * e;
        position[ix + 1] = rebuildFrom[ix + 1] + (base[ix + 1] - rebuildFrom[ix + 1]) * e;
        position[ix + 2] = rebuildFrom[ix + 2] + (base[ix + 2] - rebuildFrom[ix + 2]) * e;
      }
      posAttr.needsUpdate = true;
      mat.uniforms.uBright.value = 0.45 + e * 0.55;
      if (rebuildT >= 1) {
        phase = "spin";
        spin = 0;
        onRebuilt();
      }
    }

    renderer.render(scene, camera);
  }

  if (reduce) {
    // static: render the word once, reveal immediately, no spin/shatter
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
