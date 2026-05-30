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
let typeToken = 0; // cancels an in-flight typewriter if the user rebuilds

function typewriter(text: string): Promise<void> {
  const token = ++typeToken;
  cmd.classList.remove("lit");
  cmdLine.textContent = "";
  cmdLine.classList.add("typing");
  if (reduce) {
    cmdLine.textContent = text;
    cmdLine.classList.remove("typing");
    cmd.classList.add("lit");
    return Promise.resolve();
  }
  return new Promise((resolve) => {
    let i = 0;
    const tick = () => {
      if (token !== typeToken) return; // cancelled
      cmdLine.textContent = text.slice(0, i);
      i++;
      if (i <= text.length) {
        // a touch faster through the long URL, slight human jitter
        setTimeout(tick, 14 + Math.random() * 26);
      } else {
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
      typewriter(CMD);
    });
  },
  // onRebuilt: the word flew back together
  () => {
    typeToken++; // stop any typing
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
