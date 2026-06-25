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
import { mountChrome } from "./shell";
import { homeMarkup } from "./home-content";

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

/* ---- theme-aware, play-on-visible demo video ------------------------------ */
function currentThemeIsDark(): boolean {
  const attr = document.documentElement.getAttribute("data-theme");
  if (attr === "dark") return true;
  if (attr === "light") return false;
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

function setVideoSourceForTheme(video: HTMLVideoElement): void {
  const dark = currentThemeIsDark();
  const src = dark ? "/demo/typer-demo-dark.mp4" : "/demo/typer-demo-light.mp4";
  const poster = dark ? "/demo/poster-dark.png" : "/demo/poster-light.png";
  video.poster = poster;
  const source = video.querySelector("source");
  if (source && source.getAttribute("src") !== src) {
    source.setAttribute("src", src);
    const wasPlaying = !video.paused;
    video.load();
    if (wasPlaying && !reduceMotion) video.play().catch(() => {});
  }
}

function wireDemoVideo(): void {
  const video = document.getElementById("demo-video") as HTMLVideoElement | null;
  if (!video) return;

  setVideoSourceForTheme(video);

  // re-pick the source when the theme toggles (the toggle lives in the shared nav)
  const themeObserver = new MutationObserver(() => setVideoSourceForTheme(video));
  themeObserver.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ["data-theme"],
  });

  if (reduceMotion) {
    // static fallback: keep the poster, no autoplay; give the user a control
    video.controls = true;
    return;
  }

  // play only while on screen (and pause off-screen) to keep it cheap
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            video.play().catch(() => {
              video.controls = true; // autoplay blocked → expose controls
            });
          } else {
            video.pause();
          }
        }
      },
      { threshold: 0.35 },
    );
    io.observe(video);
  } else {
    video.controls = true;
  }
}

wireCopyButtons();
playHeroType();
wireDemoVideo();
