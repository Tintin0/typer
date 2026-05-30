// Hero shader backdrop. Raw WebGL (no library) drawing a full-screen quad with
// a fragment shader: domain-warped flow ("ink in the dark") in the warm Typer
// palette, scattered glowing vertical caret-streaks that flicker, a mouse-warped
// flow field, and a pulse that fires on every keystroke in the demo — so the
// graphics are wired to the product, not just decoration.

const VERT = `
attribute vec2 a_pos;
void main() { gl_Position = vec4(a_pos, 0.0, 1.0); }
`;

const FRAG = `
precision highp float;

uniform vec2  u_res;
uniform float u_time;
uniform vec2  u_mouse;   // 0..1
uniform float u_pulse;   // decays 1 -> 0 on keystroke
uniform float u_scroll;  // 0 at top, grows as you scroll

// --- hash / noise ----------------------------------------------------------
float hash(vec2 p){
  p = fract(p * vec2(123.34, 345.45));
  p += dot(p, p + 34.345);
  return fract(p.x * p.y);
}
float noise(vec2 p){
  vec2 i = floor(p), f = fract(p);
  vec2 u = f*f*(3.0-2.0*f);
  float a = hash(i);
  float b = hash(i+vec2(1.0,0.0));
  float c = hash(i+vec2(0.0,1.0));
  float d = hash(i+vec2(1.0,1.0));
  return mix(mix(a,b,u.x), mix(c,d,u.x), u.y);
}
float fbm(vec2 p){
  float v = 0.0, amp = 0.5;
  for(int i=0;i<6;i++){
    v += amp * noise(p);
    p = p*2.02 + vec2(11.7, 3.1);
    amp *= 0.5;
  }
  return v;
}

// glowing vertical caret-streaks laid on a loose grid
float carets(vec2 uv, float t){
  float glow = 0.0;
  // a few columns of flickering bars
  for(int i=0;i<5;i++){
    float fi = float(i);
    float colX = hash(vec2(fi, 7.0)) ;                 // column position
    float speed = 0.15 + hash(vec2(fi, 3.0)) * 0.35;
    float yoff  = fract(hash(vec2(fi, 9.0)) + t * speed);
    vec2 c = vec2(colX, yoff);
    float dx = abs(uv.x - c.x);
    float dy = abs(uv.y - c.y);
    // thin vertical bar: tight in x, taller in y
    float bar = smoothstep(0.006, 0.0, dx) * smoothstep(0.10, 0.0, dy);
    // blink
    float blink = step(0.5, fract(t * (1.0 + hash(vec2(fi,1.0))) ));
    glow += bar * mix(0.35, 1.0, blink);
  }
  return glow;
}

void main(){
  vec2 uv = gl_FragCoord.xy / u_res;
  vec2 p = uv;
  p.x *= u_res.x / u_res.y;               // aspect-correct

  float t = u_time * 0.06;

  // mouse + pulse warp the flow field
  vec2 m = (u_mouse - 0.5);
  float warpAmt = 0.6 + u_pulse * 0.9;
  vec2 q = vec2(
    fbm(p * 1.4 + vec2(0.0, t) + m * 0.6),
    fbm(p * 1.4 + vec2(5.2, -t) - m * 0.6)
  );
  vec2 r = vec2(
    fbm(p * 1.4 + q * warpAmt + vec2(1.7, 9.2) + t),
    fbm(p * 1.4 + q * warpAmt + vec2(8.3, 2.8) - t)
  );
  float f = fbm(p * 1.4 + r * warpAmt);

  // warm palette: deep ink -> brown -> amber
  vec3 ink   = vec3(0.047, 0.043, 0.039);
  vec3 brown = vec3(0.20, 0.12, 0.06);
  vec3 amber = vec3(0.91, 0.64, 0.24);

  vec3 col = mix(ink, brown, smoothstep(0.25, 0.85, f));
  col = mix(col, amber, smoothstep(0.62, 0.95, f * (0.85 + 0.4*length(r))) * 0.6);

  // pulse adds a warm bloom from the lower-centre (where the editor sits)
  float d = distance(uv, vec2(0.5, 0.42));
  col += amber * u_pulse * 0.25 * smoothstep(0.8, 0.0, d);

  // caret streaks (additive amber glow)
  float cg = carets(uv, u_time * 0.5);
  col += amber * cg * (0.5 + 0.5 * u_pulse);

  // vignette
  float vig = smoothstep(1.15, 0.35, distance(uv, vec2(0.5)));
  col *= mix(0.55, 1.0, vig);

  // film grain
  float g = hash(uv * u_res.xy + fract(u_time)) - 0.5;
  col += g * 0.025;

  // fade the whole thing out as the user scrolls into the content
  float fade = clamp(1.0 - u_scroll * 1.3, 0.0, 1.0);
  col *= fade;

  gl_FragColor = vec4(col, 1.0);
}
`;

function compile(gl: WebGLRenderingContext, type: number, src: string) {
  const sh = gl.createShader(type)!;
  gl.shaderSource(sh, src);
  gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(sh) || "shader compile error");
  }
  return sh;
}

export function initShader(canvas: HTMLCanvasElement): boolean {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const gl = (canvas.getContext("webgl", { antialias: false, alpha: false }) ||
    canvas.getContext("experimental-webgl")) as WebGLRenderingContext | null;
  if (!gl) return false;

  let prog: WebGLProgram;
  try {
    prog = gl.createProgram()!;
    gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return false;
  } catch {
    return false;
  }
  gl.useProgram(prog);

  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, "a_pos");
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

  const U = {
    res: gl.getUniformLocation(prog, "u_res"),
    time: gl.getUniformLocation(prog, "u_time"),
    mouse: gl.getUniformLocation(prog, "u_mouse"),
    pulse: gl.getUniformLocation(prog, "u_pulse"),
    scroll: gl.getUniformLocation(prog, "u_scroll"),
  };

  // soft, low-res render — it's a background. Keeps big displays cheap.
  const SCALE = 0.6;
  function resize() {
    const w = Math.max(1, Math.floor(window.innerWidth * SCALE));
    const h = Math.max(1, Math.floor(window.innerHeight * SCALE));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
      gl!.viewport(0, 0, w, h);
    }
  }
  resize();
  window.addEventListener("resize", resize);

  let mouseX = 0.5;
  let mouseY = 0.5;
  let tMouseX = 0.5;
  let tMouseY = 0.5;
  window.addEventListener(
    "pointermove",
    (e) => {
      tMouseX = e.clientX / window.innerWidth;
      tMouseY = 1 - e.clientY / window.innerHeight;
    },
    { passive: true },
  );

  let pulse = 0;
  document.addEventListener("typer:pulse", () => {
    pulse = Math.min(1, pulse + 0.6);
  });

  let visible = true;
  const io = new IntersectionObserver(
    (entries) => {
      visible = entries.some((en) => en.isIntersecting);
    },
    { threshold: 0 },
  );
  io.observe(canvas);

  const start = performance.now();

  function draw(time: number, scroll: number) {
    gl!.uniform2f(U.res, canvas.width, canvas.height);
    gl!.uniform1f(U.time, time);
    gl!.uniform2f(U.mouse, mouseX, mouseY);
    gl!.uniform1f(U.pulse, pulse);
    gl!.uniform1f(U.scroll, scroll);
    gl!.drawArrays(gl!.TRIANGLES, 0, 3);
  }

  if (reduce) {
    // one settled frame, no animation
    mouseX = mouseY = 0.5;
    draw(12.0, 0.0);
    return true;
  }

  // Single rAF loop. When the backdrop isn't contributing (scrolled past the
  // hero, off-screen, or tab hidden) we skip the GL work but keep the loop
  // alive — an early-returning rAF callback is effectively free, and the
  // browser already throttles rAF on hidden tabs.
  function frame(now: number) {
    requestAnimationFrame(frame);
    const scroll = Math.min(1, window.scrollY / (window.innerHeight || 1));
    if (!visible || document.hidden || scroll >= 1) {
      pulse *= 0.94; // keep decaying so it's calm when we return
      return;
    }
    const time = (now - start) / 1000;
    mouseX += (tMouseX - mouseX) * 0.05;
    mouseY += (tMouseY - mouseY) * 0.05;
    pulse *= 0.94;
    draw(time, scroll);
  }
  requestAnimationFrame(frame);

  return true;
}
