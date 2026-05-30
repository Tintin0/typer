import "./style.css";
import { initScene } from "./scene3d";

const CMD = "git clone https://github.com/frgmt0/typer.git && cd typer && ./install.sh";

const canvas = document.getElementById("scene") as HTMLCanvasElement;
const reveal = document.getElementById("reveal") as HTMLElement;
const cmd = document.getElementById("cmd") as HTMLElement;
const cmdLine = document.getElementById("cmdLine") as HTMLElement;
const copyBtn = document.getElementById("copyBtn") as HTMLButtonElement;
const rebuildBtn = document.getElementById("rebuild") as HTMLButtonElement;

const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
let genToken = 0; // cancels an in-flight generation if the user rebuilds

const GLYPHS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/:.-_&@#";

// "diffusion" text reveal: the line churns through random glyphs and resolves
// left-to-right into the real command, matching the cubes denoising into place.
function generate(text: string, dur = 1500): Promise<void> {
  const token = ++genToken;
  cmd.classList.remove("lit");
  cmdLine.classList.add("typing");
  if (reduce) {
    cmdLine.textContent = text;
    cmdLine.classList.remove("typing");
    cmd.classList.add("lit");
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    const start = performance.now();
    const tick = () => {
      if (token !== genToken) return; // cancelled
      const p = Math.min(1, (performance.now() - start) / dur);
      const locked = Math.floor(p * text.length);
      let out = "";
      for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (i < locked || ch === " ") out += ch;
        else out += GLYPHS[(Math.random() * GLYPHS.length) | 0];
      }
      cmdLine.textContent = out;
      if (p < 1) {
        requestAnimationFrame(tick);
      } else {
        cmdLine.textContent = text;
        cmdLine.classList.remove("typing");
        cmd.classList.add("lit"); // kick off the border shimmer
        resolve();
      }
    };
    tick();
  });
}

const scene = initScene(
  canvas,
  // onReveal: the word has shattered to the floor
  () => {
    reveal.hidden = false;
    requestAnimationFrame(() => {
      reveal.classList.add("show");
      generate(CMD);
    });
  },
  // onRebuilt: the word flew back together
  () => {
    genToken++; // stop any in-flight generation
    reveal.classList.remove("show");
    cmd.classList.remove("lit");
    cmdLine.textContent = "";
    reveal.hidden = true;
  },
);

if (!scene) {
  // no WebGL — just show the command
  document.body.classList.add("no-webgl");
  reveal.hidden = false;
  reveal.classList.add("show");
  cmdLine.textContent = CMD;
  cmd.classList.add("lit");
}

canvas.addEventListener("pointerdown", () => scene?.shatter());

rebuildBtn?.addEventListener("click", (e) => {
  e.stopPropagation();
  scene?.rebuild();
});

copyBtn?.addEventListener("click", async (e) => {
  e.stopPropagation();
  try {
    await navigator.clipboard.writeText(CMD);
    const prev = copyBtn.textContent;
    copyBtn.textContent = "Copied ✓";
    copyBtn.classList.add("copied");
    setTimeout(() => {
      copyBtn.textContent = prev;
      copyBtn.classList.remove("copied");
    }, 1600);
  } catch {
    copyBtn.textContent = "⌘C";
  }
});
