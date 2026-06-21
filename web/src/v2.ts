/**
 * /v2 — the Alpha 2 takeover, entirely in the terminal.
 *
 * A button reveals it. The page's brand mark detaches into a field of ASCII and,
 * rendered as a Bayer-dithered character surface, spins through 3D forms (a sphere,
 * a torus) before assembling into a rotating "typer-writer" wordmark that settles
 * facing you. Then the field disperses and the launch page writes itself.
 *
 * No images, no WebGL: a real 3D point cloud is shaded with a light, depth-cued,
 * and quantized through an ASCII ramp with ordered dithering onto a <pre> grid.
 */

// ---------- elements ----------
const intro = document.getElementById("intro")!;
const revealBtn = document.getElementById("reveal") as HTMLButtonElement;
const grid = document.getElementById("grid")!;
const gridpre = document.getElementById("gridpre")!;
const content = document.getElementById("content")!;
const skipBtn = document.getElementById("skip") as HTMLButtonElement;
const ckey = document.getElementById("ckey")!;
const ckeyTab = document.getElementById("ckey-tab")!;
const ckeyAll = document.getElementById("ckey-all")!;

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ---------- ascii 3D renderer ----------
const N = 4200;                                  // points in the cloud
const RAMP = " .,-~:;=!*oc#%@";                  // dark -> bright
const BAYER = [
  [0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5],
];
const DITHER = 1.35;
const ASPECT = 0.6;                              // char width / height
const LIGHT = norm([-0.4, 0.65, 0.78]);

type Shape = { pos: Float32Array; nor: Float32Array };

let C = 0, R = 0;
let lum = new Float32Array(0);

function sizeGrid() {
  const fontPx = Math.max(7, Math.min(13, innerHeight / 64));
  gridpre.style.fontSize = `${fontPx}px`;
  gridpre.style.lineHeight = "1";
  const cellH = fontPx, cellW = fontPx * ASPECT;
  R = Math.max(24, Math.floor(innerHeight / cellH));
  C = Math.max(40, Math.floor(innerWidth / cellW));
  lum = new Float32Array(C * R);
}

function norm(v: number[]): number[] {
  const m = Math.hypot(v[0], v[1], v[2]) || 1;
  return [v[0] / m, v[1] / m, v[2] / m];
}

// --- shape generators (each returns N points + normals) ---
function sphere(rad = 1): Shape {
  const pos = new Float32Array(N * 3), nor = new Float32Array(N * 3);
  const golden = Math.PI * (3 - Math.sqrt(5));
  for (let i = 0; i < N; i++) {
    const y = 1 - (i / (N - 1)) * 2;
    const r = Math.sqrt(Math.max(0, 1 - y * y));
    const phi = i * golden;
    const x = Math.cos(phi) * r, z = Math.sin(phi) * r;
    pos[i * 3] = x * rad; pos[i * 3 + 1] = y * rad; pos[i * 3 + 2] = z * rad;
    nor[i * 3] = x; nor[i * 3 + 1] = y; nor[i * 3 + 2] = z;
  }
  return { pos, nor };
}

function torus(Rt = 0.78, rt = 0.34): Shape {
  const pos = new Float32Array(N * 3), nor = new Float32Array(N * 3);
  const g1 = 0.61803398875, g2 = 0.38196601125;
  for (let i = 0; i < N; i++) {
    const u = 2 * Math.PI * ((i * g1) % 1);
    const v = 2 * Math.PI * ((i * g2) % 1);
    const cu = Math.cos(u), su = Math.sin(u), cv = Math.cos(v), sv = Math.sin(v);
    pos[i * 3] = (Rt + rt * cv) * cu;
    pos[i * 3 + 1] = (Rt + rt * cv) * su;
    pos[i * 3 + 2] = rt * sv;
    nor[i * 3] = cv * cu; nor[i * 3 + 1] = cv * su; nor[i * 3 + 2] = sv;
  }
  return { pos, nor };
}

// sample a string into points by rendering it offscreen and reading dark pixels
function textShape(text: string, targetW = 2.7): Shape {
  const cw = 1000, ch = 280;
  const oc = document.createElement("canvas"); oc.width = cw; oc.height = ch;
  const g = oc.getContext("2d")!;
  g.fillStyle = "#000"; g.fillRect(0, 0, cw, ch);
  g.fillStyle = "#fff";
  g.textAlign = "center"; g.textBaseline = "middle";
  g.font = `700 150px "JetBrains Mono", ui-monospace, Menlo, monospace`;
  g.fillText(text, cw / 2, ch / 2);
  const data = g.getImageData(0, 0, cw, ch).data;
  const pts: number[][] = [];
  let minX = cw, maxX = 0, minY = ch, maxY = 0;
  for (let y = 0; y < ch; y += 3) {
    for (let x = 0; x < cw; x += 3) {
      if (data[(y * cw + x) * 4] > 110) {
        pts.push([x, y]);
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
    }
  }
  const bw = Math.max(1, maxX - minX), bh = Math.max(1, maxY - minY);
  const cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
  const k = bw / targetW;                         // px per world unit
  const M = pts.length || 1;
  const pos = new Float32Array(N * 3), nor = new Float32Array(N * 3);
  for (let i = 0; i < N; i++) {
    const p = pts[i % M];
    const x = (p[0] - cx) / k;
    const y = -(p[1] - cy) / k;
    const z = (((i * 2654435761) % 100) / 100 - 0.5) * 0.06;  // tiny depth jitter
    pos[i * 3] = x; pos[i * 3 + 1] = y; pos[i * 3 + 2] = z;
    const n = norm([x * 0.32, y * 0.32, 1]);
    nor[i * 3] = n[0]; nor[i * 3 + 1] = n[1]; nor[i * 3 + 2] = n[2];
    void bh;
  }
  return { pos, nor };
}

function scatter(spread: number, drop = 0): Shape {
  const pos = new Float32Array(N * 3), nor = new Float32Array(N * 3);
  for (let i = 0; i < N; i++) {
    // deterministic pseudo-random from index (no Math.random needed)
    const a = (Math.sin(i * 12.9898) * 43758.5453) % 1;
    const b = (Math.sin(i * 78.233) * 12543.331) % 1;
    const c = (Math.sin(i * 39.425) * 24634.633) % 1;
    pos[i * 3] = (a - 0.5) * spread;
    pos[i * 3 + 1] = (b - 0.5) * spread - drop;
    pos[i * 3 + 2] = (c - 0.5) * spread;
    const n = norm([a - 0.5, b - 0.5, c - 0.5]);
    nor[i * 3] = n[0]; nor[i * 3 + 1] = n[1]; nor[i * 3 + 2] = n[2];
  }
  return { pos, nor };
}

// --- animation state ---
let SHAPES: Record<string, Shape> = {};
let fromS: Shape, toS: Shape;
let mix = 1;
let ay = 0, ax = 0, spin = 0.01, settle = false, fade = 1;
let running = false;

function splat(col: number, row: number, b: number) {
  if (col < 0 || col >= C || row < 0 || row >= R) return;
  const i = row * C + col;
  if (b > lum[i]) lum[i] = b;
}

function frame(now: number) {
  if (!running) return;
  // rotation
  if (settle) {
    ay = Math.atan2(Math.sin(ay), Math.cos(ay)); ay += (0 - ay) * 0.08;
    ax += (0 - ax) * 0.08;
  } else {
    ay += spin;
    ax = 0.34 * Math.sin(now * 0.0006);
  }
  // ease the morph
  mix += (1 - mix) * 0.055;
  const e = mix * mix * (3 - 2 * mix);

  lum.fill(0);
  const cay = Math.cos(ay), say = Math.sin(ay), cax = Math.cos(ax), sax = Math.sin(ax);
  const D = 3.2;
  const s = R * 0.34;
  const xScale = s / ASPECT, yScale = s, cx = C / 2, cy = R / 2;
  const fp = fromS.pos, fn = fromS.nor, tp = toS.pos, tn = toS.nor;

  for (let i = 0; i < N; i++) {
    const j = i * 3;
    // interpolate point + normal
    let px = fp[j] + (tp[j] - fp[j]) * e;
    let py = fp[j + 1] + (tp[j + 1] - fp[j + 1]) * e;
    let pz = fp[j + 2] + (tp[j + 2] - fp[j + 2]) * e;
    let nx = fn[j] + (tn[j] - fn[j]) * e;
    let ny = fn[j + 1] + (tn[j + 1] - fn[j + 1]) * e;
    let nz = fn[j + 2] + (tn[j + 2] - fn[j + 2]) * e;
    // rotate Y then X (point)
    let X = px * cay + pz * say, Z = -px * say + pz * cay, Y = py;
    let Y2 = Y * cax - Z * sax, Z2 = Y * sax + Z * cax;
    // rotate normal the same way
    let NX = nx * cay + nz * say, NZ = -nx * say + nz * cay, NY = ny;
    let NY2 = NY * cax - NZ * sax, NZ2 = NY * sax + NZ * cax;

    const persp = D / (D - Z2);
    const col = Math.round(cx + X * xScale * persp);
    const row = Math.round(cy - Y2 * yScale * persp);

    const lamb = Math.max(0, NX * LIGHT[0] + NY2 * LIGHT[1] + NZ2 * LIGHT[2]);
    const depth = Math.min(1, Math.max(0, (persp - 0.7) / 1.1));
    let b = (0.16 + 0.84 * lamb) * (0.45 + 0.55 * depth) * fade;
    if (b <= 0.02) continue;

    splat(col, row, b);
    splat(col + 1, row, b * 0.6); splat(col - 1, row, b * 0.6);
    splat(col, row + 1, b * 0.6); splat(col, row - 1, b * 0.6);
  }

  // quantize the brightness buffer to dithered ASCII
  const L = RAMP.length - 1;
  let out = "";
  for (let r = 0; r < R; r++) {
    const brow = BAYER[r & 3];
    let line = "";
    for (let c = 0; c < C; c++) {
      const v = lum[r * C + c];
      if (v <= 0.02) { line += " "; continue; }
      const d = (brow[c & 3] + 0.5) / 16 - 0.5;
      let li = Math.round(v * L + d * DITHER);
      if (li < 0) li = 0; else if (li > L) li = L;
      line += RAMP[li];
    }
    out += r ? "\n" + line : line;
  }
  gridpre.textContent = out;
  requestAnimationFrame(frame);
}

function morphTo(name: string) { fromS = toS; toS = SHAPES[name]; mix = 0; }

// ---------- the takeover timeline ----------
let aborted = false;

async function takeover() {
  sizeGrid();
  SHAPES = {
    brand: textShape("typr_", 2.2),
    sphere: sphere(1.05),
    torus: torus(),
    word: textShape("typer-writer", 3.0),
    dust: scatter(3.4, 1.6),
  };
  fromS = scatter(2.8);
  toS = SHAPES.brand;
  mix = 0; ay = 0; ax = 0; spin = 0.012; settle = false; fade = 1;
  running = true;
  grid.classList.add("on");
  skipBtn.classList.add("on");
  requestAnimationFrame(frame);

  if (await waited(1100)) return;     // brand forms
  morphTo("sphere"); spin = 0.026;
  if (await waited(2500)) return;
  morphTo("torus"); spin = 0.03;
  if (await waited(2700)) return;
  morphTo("word"); spin = 0.022;
  if (await waited(900)) return;
  settle = true;                       // face the camera and hold
  if (await waited(2300)) return;
  morphTo("dust"); settle = false; spin = 0.01; fade = 0.0; // disperse + fade out
  if (await waited(1100)) return;

  endTakeover();
  await writeContent();
}

/** resolve true if the run was aborted (skip) during the wait */
async function waited(ms: number): Promise<boolean> {
  await sleep(ms);
  return aborted;
}

function endTakeover() {
  running = false;
  grid.classList.remove("on");
  skipBtn.classList.remove("on");
  gridpre.textContent = "";
}

function startTakeover() {
  intro.classList.add("gone");
  if (reduce) { endTakeover(); renderContentFinal(); return; }
  setTimeout(() => takeover(), 480);
}

function doSkip() {
  if (aborted) return;
  aborted = true;
  endTakeover();
  renderContentFinal();
}

// ---------- the launch content (self-writing) ----------
const ccaret = el("span"); ccaret.id = "ccaret";
const cghost = el("span"); cghost.className = "ghost";
let cActive: { done: HTMLElement } | null = null;
let cburst = 0;

function el<K extends keyof HTMLElementTagNameMap>(t: K) { return document.createElement(t); }

function cDelay(ch: string): number {
  if (cburst > 0) { cburst--; return 14 + Math.random() * 12; }
  if (Math.random() < 0.06) cburst = 3 + Math.floor(Math.random() * 5);
  let d = 22 + Math.random() * 34;
  if (".,!?".includes(ch)) d += 180 + Math.random() * 140;
  else if (ch === " ") d += Math.random() < 0.2 ? 90 : 12;
  return d;
}

const CTAGS: Record<string, keyof HTMLElementTagNameMap> = {
  brand: "div", h1: "h1", sub: "div", p: "p", h2: "div", list: "pre", foot: "div",
};

function cOpen(kind: keyof typeof CTAGS, html = ""): HTMLElement {
  const b = el(CTAGS[kind]); b.className = `blk ${kind}`;
  const done = el("span"); done.className = "done"; done.innerHTML = html;
  b.append(done, ccaret, cghost); cghost.textContent = "";
  content.append(b); cActive = { done };
  return b;
}
function cPut(t: HTMLElement, ch: string) { ch === "\n" ? t.append(el("br")) : t.append(ch); }
async function cType(t: HTMLElement, text: string) {
  for (const ch of text) { cPut(t, ch); await sleep(cDelay(ch)); }
}
function placeCkey() {
  const r = ccaret.getBoundingClientRect();
  ckey.style.left = `${r.left}px`; ckey.style.top = `${r.bottom + 6}px`;
}
async function cGhost(text: string, take: "tab" | "all") {
  if (!cActive) return;
  cghost.textContent = "";
  for (const part of text.split(/(\s+)/)) { cghost.textContent += part; await sleep(40); }
  ckeyTab.style.display = take === "all" ? "none" : "";
  ckeyAll.style.display = take === "tab" ? "none" : "";
  placeCkey(); ckey.classList.add("show");
  await sleep(750);
  (take === "all" ? ckeyAll : ckeyTab).classList.add("fire");
  await sleep(240);
  const commit = take === "all" ? text : (text.match(/^\s*\S+/)?.[0] ?? text);
  await cType(cActive.done, commit);
  cghost.textContent = "";
  ckey.classList.remove("show"); ckeyTab.classList.remove("fire"); ckeyAll.classList.remove("fire");
  await sleep(140);
}

const LINKS = `arrives in <b style="color:var(--accent);font-weight:400">Typer Alpha 2</b>    <a href="/">back to typr</a>    <a href="/announcements">announcements</a>`;

async function writeContent() {
  content.classList.add("on");
  content.innerHTML = "";
  cActive = null; ccaret.classList.remove("hide");

  cOpen("brand", `typr<span class="g">_</span> <span class="a2">/ alpha 2</span>`);
  await sleep(350);
  cOpen("h1"); await cType(cActive!.done, "typer-writer");
  cOpen("sub"); await cType(cActive!.done, "the one you call on purpose.");
  await sleep(250);

  cOpen("p");
  await cType(cActive!.done, "the ambient autocomplete stays out of your way. sometimes you want the opposite: something you summon, hand a paragraph, and ask to make ");
  await cGhost("it better.", "all");

  cOpen("h2"); await cType(cActive!.done, "what it is");
  cOpen("p");
  await cType(cActive!.done, "a local model for rewriting and drafting, 4 to 8B. because you call it on purpose, it is allowed to take a second. ");
  await cType(cActive!.done, "ambient autocomplete it is not.");

  cOpen("h2"); await cType(cActive!.done, "how it differs");
  cOpen("list");
  await cType(cActive!.done,
    "  ambient   typer-1      finishes your line     under 100ms   always on\n" +
    "  invoked   typer-writer rewrites a paragraph   takes a beat  summoned, 4-8B");

  cOpen("h2"); await cType(cActive!.done, "what you can ask");
  cOpen("list");
  await cType(cActive!.done, "  rewrite this    tighten it    change the tone    draft from a note");

  cOpen("p");
  await cType(cActive!.done, "still local. still on your Mac. still free. it never phones home.");

  cOpen("foot", LINKS);
  await sleep(500);
  ccaret.remove();
}

function renderContentFinal() {
  content.classList.add("on");
  ckey.classList.remove("show");
  content.innerHTML = `
    <div class="blk brand">typr<span class="g">_</span> <span class="a2">/ alpha 2</span></div>
    <h1 class="blk h1">typer-writer</h1>
    <div class="blk sub">the one you call on purpose.</div>
    <p class="blk p">the ambient autocomplete stays out of your way. sometimes you want the opposite: something you summon, hand a paragraph, and ask to make it better.</p>
    <div class="blk h2">what it is</div>
    <p class="blk p">a local model for rewriting and drafting, 4 to 8B. because you call it on purpose, it is allowed to take a second. ambient autocomplete it is not.</p>
    <div class="blk h2">how it differs</div>
    <pre class="blk list">  ambient   typer-1      finishes your line     under 100ms   always on
  invoked   typer-writer rewrites a paragraph   takes a beat  summoned, 4-8B</pre>
    <div class="blk h2">what you can ask</div>
    <pre class="blk list">  rewrite this    tighten it    change the tone    draft from a note</pre>
    <p class="blk p">still local. still on your Mac. still free. it never phones home.</p>
    <div class="blk foot">${LINKS}</div>`;
}

// ---------- wiring ----------
revealBtn.addEventListener("click", startTakeover);
skipBtn.addEventListener("click", doSkip);
addEventListener("keydown", (e) => {
  if (e.key === " " && !intro.classList.contains("gone")) { e.preventDefault(); startTakeover(); }
  else if ((e.key === "Escape" || e.key === " ") && skipBtn.classList.contains("on")) { e.preventDefault(); doSkip(); }
});
addEventListener("resize", () => { if (running) sizeGrid(); if (ckey.classList.contains("show")) placeCkey(); });

export {};
