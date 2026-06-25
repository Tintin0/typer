/**
 * Home page entry.
 *
 * Renders the full home <main> (see home-content.ts) into the foundation's
 * <main id="home"> placeholder, mounts the shared nav + footer, then layers on
 * small, optional progressive enhancement:
 *   - copy-to-clipboard on the install command(s)
 *   - a typed hero motif ("the rest." writes itself once), reduced-motion safe
 *   - a theme-aware, play-on-visible demo video (lazy, no autoplay churn)
 *
 * Anti-drift contract (keep these two): import the shared CSS + mountChrome.
 */
import "./styles.css";
import "./home.css";
import "./demo.css";
import { mountChrome } from "./shell";
import { homeMarkup } from "./home-content";
import { mountDemo } from "./demo";

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ---- render content into the foundation placeholder ----------------------- */
const main = document.getElementById("home");
if (main) main.innerHTML = homeMarkup();

mountChrome("home");

/* ---- copy-to-clipboard on install commands -------------------------------- */
function wireCopyButtons(): void {
  document.querySelectorAll<HTMLButtonElement>(".code__copy").forEach((btn) => {
    btn.addEventListener("click", async () => {
      const text = btn.dataset.copy ?? "";
      if (!text) return;
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // clipboard blocked (insecure context / permission) — select-fallback
        const sel = window.getSelection();
        const range = document.createRange();
        const pre = btn.parentElement;
        if (pre && sel) {
          range.selectNodeContents(pre);
          sel.removeAllRanges();
          sel.addRange(range);
        }
      }
      const prev = btn.textContent;
      btn.textContent = "copied";
      btn.classList.add("is-copied");
      window.setTimeout(() => {
        btn.textContent = prev;
        btn.classList.remove("is-copied");
      }, 1400);
    });
  });
}

/* ---- typed hero motif: "the rest." writes itself once ---------------------
   True ghost-text autocomplete: the suggestion ("the rest.") starts as faint
   ghost, and as the solid "typed" half grows the ghost half shrinks by the same
   character — so the two spans always sum to "the rest." and the line never
   reflows. The caret sits at the insertion point between them (markup order:
   type, caret, ghost). Purely additive: with JS off the static ghost reads
   correctly ("…it shows you the rest."). */
function playHeroType(): void {
  const typeEl = document.getElementById("hero-type");
  const ghostEl = document.getElementById("hero-ghost");
  if (!typeEl || !ghostEl) return;

  const full = "the rest.";
  if (reduceMotion) {
    // no animation: show the suggestion fully accepted (solid), no ghost.
    typeEl.textContent = full;
    ghostEl.textContent = "";
    return;
  }

  let i = 0;
  const tick = () => {
    typeEl.textContent = full.slice(0, i); // solid, accepted
    ghostEl.textContent = full.slice(i); // faint, remaining — shrinks as we type
    if (i < full.length) {
      i += 1;
      window.setTimeout(tick, 70 + Math.random() * 60);
    }
  };
  // small beat before it starts, so the line reads first
  window.setTimeout(tick, 650);
}

/* ---- the interactive demo (theme-aware via CSS tokens; see demo.ts) -------- */
function wireDemo(): void {
  const el = document.getElementById("typer-demo");
  if (el) mountDemo(el);
}

wireCopyButtons();
playHeroType();
wireDemo();
