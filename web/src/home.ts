/**
 * The homepage writes itself.
 *
 * The whole page is one plain monospace document that types its own content the way
 * a person using typr would: ghost suggestions accepted with TAB / `, a typo caught
 * and corrected (red strikethrough, green suggestion above the word), uneven rhythm,
 * a block highlighted and moved, and the demo video dragged in and nudged into place.
 * The view stays locked and follows the caret; the last frame is the finished page,
 * which you can then scroll to re-read.
 *
 * Everything is a small interpreter over a script of `Step`s (see SCRIPT, bottom).
 */

const doc = document.getElementById("doc")!;
const caret = el("span"); caret.id = "caret";
const ghost = el("span"); ghost.className = "ghost";
const chip = document.getElementById("chip")!;
const keyTab = document.getElementById("key-tab")!;
const keyAll = document.getElementById("key-all")!;
const fixpop = document.getElementById("fixpop")!;
const skipBtn = document.getElementById("skip") as HTMLButtonElement;
const replayBtn = document.getElementById("replay") as HTMLButtonElement;

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

let active: { el: HTMLElement; done: HTMLElement } | null = null;
class SkipSignal {}
let skipping = false;
const pendingTimers: ReturnType<typeof setTimeout>[] = [];

function el<K extends keyof HTMLElementTagNameMap>(tag: K) { return document.createElement(tag); }

function sleep(ms: number): Promise<void> {
  if (skipping) return Promise.reject(new SkipSignal());
  return new Promise((res, rej) => {
    const t = setTimeout(() => (skipping ? rej(new SkipSignal()) : res()), ms);
    pendingTimers.push(t);
  });
}

// keep the caret comfortably in view as the document grows
function follow() {
  const r = caret.getBoundingClientRect();
  const target = innerHeight * 0.62;
  const dy = r.top - target;
  if (Math.abs(dy) > 24) scrollTo({ top: scrollY + dy, behavior: reduce ? "auto" : "smooth" });
}

// ---- rhythm: typing never lands on a metronome ----
let burst = 0;
let fast = false;
function charDelay(ch: string): number {
  const k = fast ? 0.42 : 1;
  if (burst > 0) { burst--; return (15 + Math.random() * 12) * k; }
  if (Math.random() < 0.06) burst = 3 + Math.floor(Math.random() * 5);
  let d = (33 + Math.random() * 44) * k;
  if (".,!?".includes(ch)) d += (200 + Math.random() * 170) * k;
  else if (ch === " ") d += Math.random() < 0.25 ? 110 : 16;
  if (Math.random() < 0.04) d += 220;
  return d;
}

// ---- block scaffolding ----
const TAGS: Record<string, keyof HTMLElementTagNameMap> = {
  brand: "div", h1: "h1", p: "p", h2: "div", cap: "div", code: "pre", list: "pre",
  matrix: "pre", note: "div", tiers: "div", foot: "div",
};

function openBlock(kind: keyof typeof TAGS, html = ""): HTMLElement {
  const block = el(TAGS[kind]);
  block.className = `blk ${kind}`;
  const done = el("span"); done.className = "done"; done.innerHTML = html;
  block.append(done, caret, ghost);
  ghost.textContent = "";
  caret.classList.remove("hide");
  doc.append(block);
  active = { el: block, done };
  return block;
}

function put(target: HTMLElement, ch: string) {
  if (ch === "\n") target.append(el("br"));
  else target.append(ch);
}
async function typeInto(target: HTMLElement, text: string) {
  for (const ch of text) {
    put(target, ch);
    if (ch === "\n") follow();
    await sleep(charDelay(ch));
  }
  follow();
}

// ---- key-hint chip, placed just below the caret line ----
function placeChip() {
  const r = caret.getBoundingClientRect();
  chip.style.left = `${r.left}px`;
  chip.style.top = `${r.bottom + 6}px`;
}
function showChip(which: "tab" | "all" | "both") {
  keyTab.style.display = which === "all" ? "none" : "";
  keyAll.style.display = which === "tab" ? "none" : "";
  placeChip();
  chip.classList.add("show");
}
function hideChip() { chip.classList.remove("show"); keyTab.classList.remove("fire"); keyAll.classList.remove("fire"); }

// ---- steps ----
type Step =
  | { t: "block"; kind: keyof typeof TAGS; html?: string }
  | { t: "type"; text: string }
  | { t: "ghost"; text: string; take: "tab" | "all" }
  | { t: "typo"; bad: string; good: string; tail?: string }
  | { t: "mark"; id: string; text: string }
  | { t: "moveEnd"; id: string; as: string }
  | { t: "video" }
  | { t: "snap"; kind: keyof typeof TAGS; html: string }
  | { t: "fast"; on: boolean }
  | { t: "pause"; ms: number };

const marks = new Map<string, HTMLElement>();

async function ghostStep(text: string, take: "tab" | "all") {
  if (!active) return;
  ghost.textContent = "";
  for (const part of text.split(/(\s+)/)) { ghost.textContent += part; await sleep(46); }
  follow();
  showChip(take === "all" ? "all" : "both");
  await sleep(800);
  (take === "all" ? keyAll : keyTab).classList.add("fire");
  await sleep(210);
  // accept: the whole suggestion (or just its first word, for tab) snaps in at
  // once on the keystroke — not retyped — with a brief highlight so you see it land.
  const commit = take === "all" ? text : (text.match(/^\s*\S+/)?.[0] ?? text);
  ghost.textContent = "";
  commitFlash(active.done, commit);
  follow();
  hideChip();
  await sleep(280);
}

function commitFlash(doneEl: HTMLElement, str: string) {
  const sp = el("span"); sp.className = "accepted"; sp.textContent = str;
  doneEl.append(sp);
  requestAnimationFrame(() => sp.classList.add("settle"));
  setTimeout(() => sp.classList.remove("accepted", "settle"), 650);
}

async function typoStep(bad: string, good: string, tail = "") {
  if (!active) return;
  const span = el("span"); span.className = "wp"; active.done.append(span);
  await typeInto(span, bad);
  await sleep(340);
  span.classList.add("bad");
  const r = span.getBoundingClientRect();
  fixpop.innerHTML = `✓ ${good}`;
  fixpop.style.left = `${r.left + r.width / 2}px`;
  fixpop.style.top = `${r.top - 4}px`;
  fixpop.classList.add("show");
  await sleep(680);
  span.classList.remove("bad"); span.classList.add("fixed");
  span.textContent = good;
  fixpop.classList.remove("show");
  await sleep(400);
  span.classList.remove("fixed"); span.className = "";
  if (tail) await typeInto(active.done, tail);
}

async function moveEndStep(id: string, as: string) {
  if (!active) return;
  const span = marks.get(id);
  if (!span) return;
  span.classList.add("sel");
  await sleep(600);
  span.classList.add("lift");
  await sleep(320);
  span.remove();
  await sleep(200);
  const dropped = el("span"); dropped.className = "drop"; dropped.textContent = as;
  active.done.append(dropped);
  follow();
  await sleep(460);
}

// a dense block (the matrix, the offerings) snaps in whole with the accept-flash —
// the same gesture as taking a full suggestion, since you wouldn't hand-type a table.
async function snapStep(kind: keyof typeof TAGS, html: string) {
  const block = openBlock(kind);
  caret.classList.add("hide");
  await sleep(220);
  const flash = el("span"); flash.className = "accepted"; flash.innerHTML = html;
  active!.done.append(flash);
  requestAnimationFrame(() => flash.classList.add("settle"));
  setTimeout(() => flash.classList.remove("accepted", "settle"), 650);
  follow();
  caret.remove(); block.append(caret); caret.classList.remove("hide");
  await sleep(360);
}

// drag the demo recording in, fiddle with placement, then drop it into the flow
async function videoStep() {
  caret.classList.add("hide");
  const fig = el("figure"); fig.className = "blk demo fly grab";
  fig.innerHTML =
    `<video src="/demo/typer-demo-dark.mp4" poster="/demo/poster-dark.png" autoplay muted loop playsinline preload="metadata"></video>`;
  // start it offset, as if held by the cursor mid-drag
  fig.style.transform = "translate(120px, -34px) rotate(-2.5deg) scale(0.96)";
  fig.style.opacity = "0.9";
  doc.append(fig);
  active = null;
  fig.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
  await sleep(420);
  fig.style.transform = "translate(-90px, 14px) rotate(1.5deg) scale(0.97)"; // fiddle
  await sleep(560);
  fig.style.transform = "translate(48px, -6px) rotate(-1deg) scale(0.985)";  // fiddle again
  await sleep(520);
  fig.style.opacity = "1";
  fig.style.transform = "none";                                             // settle into place
  await sleep(260);
  fig.classList.remove("grab");
  await sleep(360);
}

async function run(step: Step) {
  switch (step.t) {
    case "block": openBlock(step.kind, step.html); break;
    case "type":  await typeInto(active!.done, step.text); break;
    case "ghost": await ghostStep(step.text, step.take); break;
    case "typo":  await typoStep(step.bad, step.good, step.tail); break;
    case "mark": {
      const span = el("span"); active!.done.append(span);
      marks.set(step.id, span);
      await typeInto(span, step.text);
      break;
    }
    case "moveEnd": await moveEndStep(step.id, step.as); break;
    case "video": await videoStep(); break;
    case "snap":  await snapStep(step.kind, step.html); break;
    case "fast":  fast = step.on; break;
    case "pause": await sleep(step.ms); break;
  }
}

// =====================================================================
// CONTENT BLOCKS — dense tables/ladders that snap in whole (see snapStep).
// edited here and mirrored verbatim in renderFinal(); keep the two in sync.
// =====================================================================

// per-app caret placement, straight from docs/research/caret-placement.md §2.
// status legend: solid (green) · approximate (accent) · known gap (red).
const MATRIX = [
  "  app                       caret placement        status",
  "  ─────────────────────────────────────────────────────────────",
  '  native (textedit, notes)  <span class="col">AX bounds-for-range</span>    <span class="ok">solid</span>',
  '  webkit / electron         <span class="col">AX text-marker bounds</span>  <span class="ok">solid</span>',
  '  terminal, iterm2          <span class="col">AX text area + OCR</span>     <span class="ok">solid</span>',
  '  gpu terminals (warp…)     <span class="col">screenshot OCR caret</span>   <span class="approx">approximate</span>',
  '  google docs               <span class="col">needs docs a11y on</span>     <span class="approx">approximate</span>',
].join("\n");

// open-core offerings — honest about now vs planned. never gates the core.
const TIERS =
  '<div class="tier"><span class="what"><b>free local core.</b> every model, learned style, per-app context. MIT, build from source.</span><span class="stat now">now · free, forever</span></div>' +
  '<div class="tier"><span class="what"><b>signed builds + auto-update.</b> skip the toolchain. the source build stays free and identical.</span><span class="stat soon">planned</span></div>' +
  '<div class="tier"><span class="what"><b>cloud distillation → local LoRA.</b> opt in, train a sharper personal model off-device, download it, run it locally.</span><span class="stat soon">planned</span></div>' +
  '<div class="tier"><span class="what"><b>pro + team conveniences.</b> instruction packs, settings sync, managed denylists. settings, never your content.</span><span class="stat soon">later</span></div>';

// =====================================================================
// THE SCRIPT — what typr types, and the gestures it performs along the way.
// =====================================================================
const SCRIPT: Step[] = [
  { t: "block", kind: "brand", html: `typr<span class="pulse">_</span>` },
  { t: "pause", ms: 450 },

  // headline, finished with the tool itself
  { t: "block", kind: "h1" },
  { t: "type",  text: "you type the first " },
  { t: "ghost", text: "half,", take: "tab" },
  { t: "type",  text: " it shows you the " },
  { t: "ghost", text: "rest.", take: "all" },
  { t: "pause", ms: 450 },

  // value paragraph: a typo correction, a tab-accept, and a block move
  { t: "block", kind: "p" },
  { t: "type",  text: "local " },
  { t: "typo",  bad: "autocaomplete", good: "autocomplete", tail: " for macOS. " },
  { t: "mark",  id: "loc", text: "your data never leaves. " },
  { t: "type",  text: "a dim suggestion appears at your " },
  { t: "ghost", text: "caret", take: "tab" },
  { t: "type",  text: " in almost any app" },
  { t: "pause", ms: 320 },
  { t: "moveEnd", id: "loc", as: ", on your Mac and nowhere else." },
  { t: "pause", ms: 360 },

  // drag the demo in, fiddle with it, drop it
  { t: "video" },
  { t: "block", kind: "cap" },
  { t: "type",  text: "a real screen recording. the whole interaction model." },
  { t: "pause", ms: 360 },

  // how you use it (typed faster, like reference notes)
  { t: "block", kind: "h2" }, { t: "type", text: "how you use it" },
  { t: "fast",  on: true },
  { t: "block", kind: "list", html: "" },
  { t: "type",  text: "  tab   take one word\n  `     take the whole suggestion\n  esc   dismiss\n  …     keep typing, the ghost shrinks" },

  // it picks a model for your Mac
  { t: "block", kind: "h2" }, { t: "type", text: "it picks a model for your Mac" },
  { t: "block", kind: "list" },
  { t: "type",  text: "  typer-1s   0.6B   8GB +\n  typer-1m   1.7B   16GB    first word on screen in 27ms\n  typer-1l   4B     32GB +  longer accurate runs\n  typer-writer, for rewriting and drafting, lands in Alpha 2." },
  { t: "fast",  on: false },
  { t: "pause", ms: 300 },

  // where it works — the per-app caret matrix, snapped in like a pasted table
  { t: "block", kind: "h2" }, { t: "type", text: "where the caret lands" },
  { t: "snap",  kind: "matrix", html: MATRIX },
  { t: "block", kind: "note" },
  { t: "type",  text: "honest, not aspirational — approximate stays approximate until it isn't." },
  { t: "pause", ms: 300 },

  // what it costs — the open-core ladder. core is always free + local.
  { t: "block", kind: "h2" }, { t: "type", text: "free core, optional extras" },
  { t: "snap",  kind: "tiers", html: TIERS },
  { t: "block", kind: "note" },
  { t: "type",  text: "the engine never leaves your Mac and is never gated. everything above the core is opt-in and degrades back to fully local." },
  { t: "pause", ms: 300 },

  // install, completed in one keystroke
  { t: "block", kind: "h2" }, { t: "type", text: "install" },
  { t: "block", kind: "code", html: `<span class="pr">$ </span>` },
  { t: "type",  text: "git clone " },
  { t: "ghost", text: "https://github.com/frgmt0/typer.git && ./install.sh", take: "all" },
  { t: "pause", ms: 360 },

  // footer
  { t: "block", kind: "foot", html:
    `free, forever · MIT · runs on llama.cpp · macOS 14+<br><br>` },
];

// the finished footer links, as real anchors (typed look, real targets)
const FOOTER_LINKS =
  `<a href="/announcements">announcements</a>   <a href="/research">research</a>   <a href="https://github.com/frgmt0/typer">github ↗</a>`;

// ---- final frame (skip / reduced motion): build the page instantly ----
function renderFinal() {
  hideChip();
  fixpop.classList.remove("show");
  marks.clear();
  doc.innerHTML = `
    <div class="blk brand">typr<span class="pulse">_</span></div>
    <h1 class="blk h1">you type the first half, it shows you the rest.</h1>
    <p class="blk p">local autocomplete for macOS. a dim suggestion appears at your caret in almost any app, on your Mac and nowhere else.</p>
    <figure class="blk demo"><video src="/demo/typer-demo-dark.mp4" poster="/demo/poster-dark.png" ${reduce ? "controls" : "autoplay muted loop"} playsinline preload="metadata"></video></figure>
    <div class="blk cap">a real screen recording. the whole interaction model.</div>
    <div class="blk h2">how you use it</div>
    <pre class="blk list">  tab   take one word
  \`     take the whole suggestion
  esc   dismiss
  …     keep typing, the ghost shrinks</pre>
    <div class="blk h2">it picks a model for your Mac</div>
    <pre class="blk list">  typer-1s   0.6B   8GB +
  typer-1m   1.7B   16GB    first word on screen in 27ms
  typer-1l   4B     32GB +  longer accurate runs
  typer-writer, for rewriting and drafting, lands in Alpha 2.</pre>
    <div class="blk h2">where the caret lands</div>
    <pre class="blk matrix">${MATRIX}</pre>
    <div class="blk note">honest, not aspirational — approximate stays approximate until it isn't.</div>
    <div class="blk h2">free core, optional extras</div>
    <div class="blk tiers">${TIERS}</div>
    <div class="blk note">the engine never leaves your Mac and is never gated. everything above the core is opt-in and degrades back to fully local.</div>
    <div class="blk h2">install</div>
    <pre class="blk code"><span class="pr">$ </span>git clone https://github.com/frgmt0/typer.git && ./install.sh</pre>
    <div class="blk foot">free, forever · MIT · runs on llama.cpp · macOS 14+<br><br>${FOOTER_LINKS}</div>`;
  finish();
}

function finish() {
  skipBtn.hidden = true;
  replayBtn.hidden = false;
}

async function play() {
  doc.innerHTML = "";
  marks.clear();
  skipping = false; fast = false;
  scrollTo({ top: 0 });
  replayBtn.hidden = true; skipBtn.hidden = false;
  try {
    for (const step of SCRIPT) await run(step);
    // append the real footer links, then rest the caret at the end
    if (active) active.done.insertAdjacentHTML("beforeend", FOOTER_LINKS);
    await sleep(600);
    caret.remove();
    finish();
  } catch (e) {
    if (e instanceof SkipSignal) renderFinal();
    else throw e;
  }
}

function doSkip() {
  if (!replayBtn.hidden) return;
  skipping = true;
  pendingTimers.forEach(clearTimeout);
  pendingTimers.length = 0;
  renderFinal();
}

skipBtn.addEventListener("click", doSkip);
replayBtn.addEventListener("click", () => { caret.classList.remove("hide"); play(); });
addEventListener("keydown", (e) => {
  if ((e.key === "Escape" || e.key === " ") && !skipBtn.hidden) { e.preventDefault(); doSkip(); }
});
addEventListener("resize", () => { if (chip.classList.contains("show")) placeChip(); });

if (reduce) renderFinal();
else play();
