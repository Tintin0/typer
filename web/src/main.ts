import "./style.css";
import { TyperEngine } from "./engine";
import { initShader } from "./webgl";

function el<T extends HTMLElement>(id: string): T {
  const node = document.getElementById(id);
  if (!node) throw new Error(`missing #${id}`);
  return node as T;
}

// shader backdrop — degrades gracefully to the CSS gradient if WebGL is absent
const gfx = document.getElementById("gfx") as HTMLCanvasElement | null;
if (gfx) {
  const ok = initShader(gfx);
  if (!ok) gfx.remove();
}

// the live editor — the whole point of the page
const engine = new TyperEngine({
  root: el("editor"),
  ink: el("ink"),
  ghost: el("ghost"),
  caret: el("caret"),
  hint: el("hint"),
});

// kick off the scripted demo shortly after load (cancels on first interaction)
window.setTimeout(() => engine.playDemo(), 900);

// copy-to-clipboard for the install one-liner
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
    copyBtn.textContent = "⌘C";
  }
});

// gentle reveal for the (deliberately sparse) content below the fold
const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const revealables = document.querySelectorAll<HTMLElement>("[data-reveal]");
if (reduce) {
  revealables.forEach((n) => n.classList.add("in"));
} else {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add("in");
          io.unobserve(e.target);
        }
      }
    },
    { threshold: 0.18, rootMargin: "0px 0px -8% 0px" },
  );
  revealables.forEach((n) => io.observe(n));
}
