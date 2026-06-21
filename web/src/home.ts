/**
 * The homepage writes itself.
 *
 * The whole page is a single locked screen that types its own content the way a
 * person using typr would: ghost suggestions accepted with TAB / `, a typo caught
 * and corrected (red strikethrough, green suggestion above the word), uneven rhythm,
 * and one block highlighted and moved. The last frame is the finished page.
 *
 * Everything here is a small interpreter over a script of `Step`s (see SCRIPT at the
 * bottom). The engine owns a caret, a ghost span, a key-hint chip, and a correction
 * popover; the script just says what to type and which gesture to perform.
 */

const doc = document.getElementById("doc")!;
const caret = el("span"); caret.id = "caret";
const ghost = el("span"); ghost.className = "ghost";
const chip = document.getElementById("chip")!;
const keyTab = document.getElementById("key-tab")!;
const keyAll = document.getElementById("key-all")!;
const fixpop = document.getElementById("fixpop")!;
const corner = document.getElementById("corner")!;
const skipBtn = document.getElementById("skip") as HTMLButtonElement;
const replayBtn = document.getElementById("replay") as HTMLButtonElement;

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

/** Active block being typed into, and its committed-text container. */
let active: { el: HTMLElement; done: HTMLElement } | null = null;
/** Set when the user hits skip; aborts the run and jumps to the final frame. */
class SkipSignal {}
let skipping = false;

function el<K extends keyof HTMLElementTagNameMap>(tag: K) {
  return document.createElement(tag);
}

/** A cancellable sleep. Resolves early (and flags the abort) once skipping. */
function sleep(ms: number): Promise<void> {
  if (skipping) return Promise.reject(new SkipSignal());
  return new Promise((res, rej) => {
    const t = setTimeout(() => (skipping ? rej(new SkipSignal()) : res()), ms);
    pendingTimers.push(t);
  });
}
const pendingTimers: ReturnType<typeof setTimeout>[] = [];

// ---- rhythm: typing never lands on a metronome ----
let burst = 0; // remaining chars in a fast run
function charDelay(ch: string): number {
  if (burst > 0) { burst--; return 16 + Math.random() * 14; }
  if (Math.random() < 0.06) burst = 3 + Math.floor(Math.random() * 5); // occasional fast run
  let d = 34 + Math.random() * 46;
  if (".,!?".includes(ch)) d += 220 + Math.random() * 180;             // think after punctuation
  else if (ch === " ") d += Math.random() < 0.25 ? 120 : 18;
  if (Math.random() < 0.04) d += 240;                                  // a small hesitation
  return d;
}

// ---- block scaffolding ----
const TAGS: Record<string, keyof HTMLElementTagNameMap> = {
  brand: "div", h1: "h1", p: "p", code: "pre", foot: "div",
};

function openBlock(kind: keyof typeof TAGS, html = ""): HTMLElement {
  const block = el(TAGS[kind]);
  block.className = `blk ${kind}`;
  const done = el("span"); done.className = "done"; done.innerHTML = html;
  block.append(done, caret, ghost);
  ghost.textContent = "";
  doc.append(block);
  active = { el: block, done };
  return block;
}

/** Append one character into a target (committed text or a sub-span). */
function put(target: HTMLElement, ch: string) {
  if (ch === "\n") target.append(el("br"));
  else target.append(ch);
}

async function typeInto(target: HTMLElement, text: string) {
  for (const ch of text) { put(target, ch); await sleep(charDelay(ch)); }
}

// ---- key-hint chip, positioned at the caret ----
function placeChip() {
  const r = caret.getBoundingClientRect();
  chip.style.left = `${r.right + 8}px`;
  chip.style.top = `${r.top + r.height / 2 - 11}px`;
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
  | { t: "ghost"; text: string; take: "tab" | "all" }   // suggestion -> accept
  | { t: "typo"; bad: string; good: string; tail?: string }
  | { t: "mark"; id: string; text: string }             // type into a referenceable span
  | { t: "moveEnd"; id: string; as: string }            // cut that span, drop text at block end
  | { t: "pause"; ms: number };

const marks = new Map<string, HTMLElement>();

async function ghostStep(text: string, take: "tab" | "all") {
  if (!active) return;
  ghost.textContent = "";
  // stream the suggestion in word by word
  for (const part of text.split(/(\s+)/)) { ghost.textContent += part; await sleep(48); }
  showChip(take === "all" ? "all" : "both");
  await sleep(820);
  (take === "all" ? keyAll : keyTab).classList.add("fire");
  await sleep(260);
  if (take === "all") {
    await typeInto(active.done, text);            // commit the whole suggestion
  } else {
    const m = text.match(/^\s*\S+/);              // commit the first word only
    await typeInto(active.done, (m ? m[0] : text));
  }
  ghost.textContent = "";
  hideChip();
  await sleep(160);
}

async function typoStep(bad: string, good: string, tail = "") {
  if (!active) return;
  const span = el("span"); span.className = "wp"; active.done.append(span);
  await typeInto(span, bad);
  await sleep(360);
  span.classList.add("bad");                       // red strikethrough
  // green suggestion floats above the word
  const r = span.getBoundingClientRect();
  fixpop.innerHTML = `<span class="chk">✓</span>${good}`;
  fixpop.style.left = `${r.left + r.width / 2}px`;
  fixpop.style.top = `${r.top - 6}px`;
  fixpop.classList.add("show");
  await sleep(700);
  span.classList.remove("bad"); span.classList.add("fixed");
  span.textContent = good;                         // accept the correction
  fixpop.classList.remove("show");
  await sleep(420);
  span.classList.remove("fixed"); span.className = "";  // settle to normal text
  if (tail) await typeInto(active.done, tail);
}

async function moveEndStep(id: string, as: string) {
  if (!active) return;
  const span = marks.get(id);
  if (!span) return;
  span.classList.add("sel");                        // highlight the block
  await sleep(620);
  span.classList.add("lift");                       // lift it out
  await sleep(340);
  span.remove();                                    // the gap closes (reflow)
  await sleep(220);
  const dropped = el("span"); dropped.className = "drop"; dropped.textContent = as;
  active.done.append(dropped);                      // it lands at the end
  await sleep(480);
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
    case "pause": await sleep(step.ms); break;
  }
}

// =====================================================================
// THE SCRIPT — what typr types, and the gestures it performs along the way.
// =====================================================================
const SCRIPT: Step[] = [
  { t: "block", kind: "brand", html: `typr<span class="pulse">_</span>` },
  { t: "pause", ms: 500 },

  // headline, finished with the tool itself
  { t: "block", kind: "h1" },
  { t: "type",  text: "you type the first " },
  { t: "ghost", text: "half,", take: "tab" },
  { t: "type",  text: "\n" },
  { t: "type",  text: "it shows you the " },
  { t: "ghost", text: "rest.", take: "all" },
  { t: "pause", ms: 500 },

  // value paragraph: a typo correction, a tab-accept, and a block move
  { t: "block", kind: "p" },
  { t: "type",  text: "local " },
  { t: "typo",  bad: "autocaomplete", good: "autocomplete", tail: " for macOS. " },
  { t: "mark",  id: "loc", text: "your data never leaves. " },
  { t: "type",  text: "a dim suggestion appears at your " },
  { t: "ghost", text: "caret", take: "tab" },
  { t: "type",  text: " in almost any app" },
  { t: "pause", ms: 360 },
  { t: "moveEnd", id: "loc", as: ", on your Mac and nowhere else." },
  { t: "pause", ms: 500 },

  // the install line, completed in one keystroke
  { t: "block", kind: "code", html: `<span class="pr">$ </span>` },
  { t: "type",  text: "git clone " },
  { t: "ghost", text: "https://github.com/frgmt0/typer.git && ./install.sh", take: "all" },
  { t: "pause", ms: 420 },

  // footer
  { t: "block", kind: "foot" },
  { t: "type",  text: "free, forever · MIT · runs on llama.cpp · macOS 14+" },
];

// ---- final frame (skip / reduced motion): build the page instantly ----
function renderFinal() {
  hideChip();
  fixpop.classList.remove("show");
  marks.clear();
  doc.innerHTML = `
    <div class="blk brand">typr<span class="pulse">_</span></div>
    <h1 class="blk h1">you type the first half,<br>it shows you the rest.</h1>
    <p class="blk p">local autocomplete for macOS. a dim suggestion appears at your caret in almost any app, on your Mac and nowhere else.</p>
    <pre class="blk code"><span class="pr">$ </span>git clone https://github.com/frgmt0/typer.git && ./install.sh</pre>
    <div class="blk foot">free, forever · MIT · runs on llama.cpp · macOS 14+</div>`;
  finish();
}

function finish() {
  corner.classList.add("show");
  corner.removeAttribute("aria-hidden");
  skipBtn.hidden = true;
  replayBtn.hidden = false;
}

async function play() {
  doc.innerHTML = "";
  marks.clear();
  skipping = false;
  replayBtn.hidden = true;
  skipBtn.hidden = false;
  corner.classList.remove("show");
  try {
    for (const step of SCRIPT) await run(step);
    // leave the caret resting at the end of the footer for a beat
    await sleep(600);
    caret.remove();
    finish();
  } catch (e) {
    if (e instanceof SkipSignal) renderFinal();
    else throw e;
  }
}

function doSkip() {
  if (replayBtn.hidden === false) return;
  skipping = true;
  pendingTimers.forEach(clearTimeout);
  pendingTimers.length = 0;
  renderFinal();
}

skipBtn.addEventListener("click", doSkip);
replayBtn.addEventListener("click", () => play());
addEventListener("keydown", (e) => {
  if ((e.key === "Escape" || e.key === " ") && skipBtn.hidden === false) { e.preventDefault(); doSkip(); }
});
addEventListener("resize", () => { if (chip.classList.contains("show")) placeChip(); });

if (reduce) renderFinal();
else play();
