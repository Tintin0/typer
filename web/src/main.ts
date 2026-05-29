import "./style.css";
import { TyperEngine } from "./engine";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`missing #${id}`);
  return node as T;
}

// ---- hero: the live editor -------------------------------------------------
const engine = new TyperEngine({
  root: el("editor"),
  ink: el("ink"),
  ghost: el("ghost"),
  caret: el("caret"),
  hint: el("hint"),
});

// kick off the scripted demo shortly after load (cancels on first interaction)
window.setTimeout(() => engine.playDemo(), 900);

// ---- "how it feels" looping replay ----------------------------------------
// A self-contained loop that shows the ghost shrinking as the ink catches up.
const replayReduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const rInk = document.querySelector<HTMLElement>("#replay .r-ink")!;
const rGhost = document.querySelector<HTMLElement>("#replay .r-ghost")!;

const SENTENCE = "type along it and the grey ";
const SUGGESTION = "text just gets shorter, one keystroke at a time";

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

async function replayLoop() {
  if (replayReduced) {
    rInk.textContent = SENTENCE;
    rGhost.textContent = SUGGESTION;
    return;
  }
  // wait until the section is on screen to start
  await waitVisible(document.getElementById("how")!);
  while (true) {
    rInk.textContent = "";
    rGhost.textContent = "";
    await sleep(700);
    // type the lead-in
    for (const ch of SENTENCE) {
      rInk.textContent += ch;
      await sleep(ch === " " ? 60 : 42);
    }
    await sleep(420);
    // ghost appears
    rGhost.textContent = SUGGESTION;
    await sleep(900);
    // type-through: move ghost head into ink, char by char
    while (rGhost.textContent && rGhost.textContent.length > 0) {
      const g = rGhost.textContent;
      rInk.textContent += g[0];
      rGhost.textContent = g.slice(1);
      await sleep(34);
    }
    await sleep(1900);
  }
}

function waitVisible(node: Element): Promise<void> {
  return new Promise((resolve) => {
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          io.disconnect();
          resolve();
        }
      },
      { threshold: 0.35 },
    );
    io.observe(node);
  });
}

replayLoop();

// ---- copy-to-clipboard for the install block ------------------------------
const copyBtn = document.getElementById("copyBtn") as HTMLButtonElement | null;
copyBtn?.addEventListener("click", async () => {
  const cmd = "git clone https://github.com/frgmt0/typer.git && cd typer && ./install.sh";
  try {
    await navigator.clipboard.writeText(cmd);
    const prev = copyBtn.textContent;
    copyBtn.textContent = "Copied ✓";
    copyBtn.classList.add("copied");
    setTimeout(() => {
      copyBtn.textContent = prev;
      copyBtn.classList.remove("copied");
    }, 1600);
  } catch {
    copyBtn.textContent = "Press ⌘C";
  }
});

// ---- reveal-on-scroll (respects reduced motion) ---------------------------
if (!replayReduced) {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -8% 0px" },
  );
  document.querySelectorAll<HTMLElement>("[data-reveal]").forEach((n) => io.observe(n));
} else {
  document.querySelectorAll<HTMLElement>("[data-reveal]").forEach((n) => n.classList.add("in"));
}
