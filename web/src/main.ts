import "./style.css";
import { initScene } from "./scene3d";

const canvas = document.getElementById("scene") as HTMLCanvasElement;
const hint = document.getElementById("hint")!;
const reveal = document.getElementById("reveal") as HTMLElement;
const copyBtn = document.getElementById("copyBtn") as HTMLButtonElement;
const rebuildBtn = document.getElementById("rebuild") as HTMLButtonElement;

const scene = initScene(
  canvas,
  // onReveal: word has shattered to the floor
  () => {
    hint.classList.add("gone");
    reveal.hidden = false;
    // next frame so the [hidden]->visible transition animates
    requestAnimationFrame(() => reveal.classList.add("show"));
  },
  // onRebuilt: word flew back together
  () => {
    reveal.classList.remove("show");
    reveal.hidden = true;
    hint.classList.remove("gone");
  },
);

if (!scene) {
  // WebGL unavailable — fall back to just showing the command
  document.body.classList.add("no-webgl");
  hint.remove();
  reveal.hidden = false;
  reveal.classList.add("show");
}

// click anywhere on the canvas shatters the word
canvas.addEventListener("pointerdown", () => scene?.shatter());

rebuildBtn?.addEventListener("click", (e) => {
  e.stopPropagation();
  scene?.rebuild();
});

copyBtn?.addEventListener("click", async (e) => {
  e.stopPropagation();
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
    copyBtn.textContent = "⌘C";
  }
});
