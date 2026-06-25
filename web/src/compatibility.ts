/**
 * Compatibility page entry.
 *
 * Renders the full, honest per-app caret compatibility matrix into the
 * foundation's <main id="compatibility"> placeholder, then mounts shared chrome.
 *
 * The matrix turns typer's internal caret fallback ladder
 * (docs/research/caret-placement.md §2 + docs/overhaul-spec.md §B) into a public,
 * per-app table — exactly the trust instrument positioning.md §6 asks for.
 *
 * Honesty contract (positioning §6): "approximate" stays "approximate" until the
 * caret is actually fixed. Status tokens reuse the shared design system:
 *   green  = solid · blue = approximate · red = known issue.
 *
 * Anti-drift contract (keep these two): import the shared CSS + mountChrome.
 */
import "./styles.css";
import "./compatibility.css";
import { mountChrome } from "./shell";

mountChrome("compatibility");

const GITHUB = "https://github.com/frgmt0/typer";

type Status = "solid" | "approx" | "issue";
const STATUS_LABEL: Record<Status, string> = {
  solid: "solid",
  approx: "approximate",
  issue: "known issue",
};

type Row = {
  app: string;
  apps: string;
  method: string;
  quality: string;
  quirks: string;
  status: Status;
};

/* ---- the fallback ladder (docs/overhaul-spec.md §B.1) ---------------------- */
const LADDER: { n: string; method: string; covers: string }[] = [
  { n: "1", method: "AX text-marker bounds", covers: "Chromium · WebKit · Electron" },
  { n: "2", method: "AX bounds-for-range (5-step)", covers: "native AppKit · AX terminals" },
  { n: "3", method: "TextKit mirror (font-exact)", covers: "Google Docs · web canvas · no-inline fields" },
  { n: "4", method: "screenshot / OCR caret", covers: "GPU terminals · custom editors — our edge" },
  { n: "5", method: "click-anchor + host-font width", covers: "single-line fields with no caret API" },
  { n: "6", method: "focused-element frame centre", covers: "last resort" },
];

/* ---- matrix groups (caret-placement.md §2; honest status per positioning §6) */
const GROUPS: { heading: string; blurb: string; rows: Row[] }[] = [
  {
    heading: "native macOS",
    blurb: "AppKit / NSTextView fields. the inline ghost sits on the real caret with no drift.",
    rows: [
      {
        app: "TextEdit",
        apps: "com.apple.TextEdit",
        method: "AX bounds-for-range",
        quality: "full inline ghost",
        quirks: "—",
        status: "solid",
      },
      {
        app: "Notes",
        apps: "com.apple.Notes",
        method: "AX bounds-for-range",
        quality: "full inline ghost",
        quirks: "—",
        status: "solid",
      },
      {
        app: "Mail",
        apps: "com.apple.mail",
        method: "AX bounds-for-range",
        quality: "full inline ghost",
        quirks: "—",
        status: "solid",
      },
      {
        app: "system text fields",
        apps: "Spotlight · search bars · Safari address bar",
        method: "AX bounds-for-range",
        quality: "full inline ghost",
        quirks: "short fields suppress mid-line",
        status: "solid",
      },
    ],
  },
  {
    heading: "web & Electron",
    blurb: "Chromium-backed apps and web inputs. caret comes from AX text-marker bounds; we read the host font over AX so the ghost is the right size in the right typeface.",
    rows: [
      {
        app: "Slack",
        apps: "Electron",
        method: "AX text-marker bounds",
        quality: "full inline ghost",
        quirks: "—",
        status: "solid",
      },
      {
        app: "VS Code",
        apps: "Electron · web view",
        method: "AX text-marker bounds",
        quality: "inline ghost in inputs",
        quirks: "the editor itself is suppressed by default — VS Code has its own completion; flip it on per-app",
        status: "solid",
      },
      {
        app: "Chrome inputs",
        apps: "org.chromium.Chromium",
        method: "AX text-marker bounds",
        quality: "full inline ghost",
        quirks: "—",
        status: "solid",
      },
      {
        app: "Discord · Obsidian · Notion",
        apps: "Electron",
        method: "AX text-marker bounds → TextKit mirror",
        quality: "inline ghost; mirror where no inline caret",
        quirks: "a few custom editors fall back to the mirror box",
        status: "approx",
      },
    ],
  },
  {
    heading: "terminals",
    blurb: "where typer has an edge competitors lack: a ScreenCaptureKit + Vision OCR caret locator reads the caret straight off the screen. AX-capable terminals also get bounds-for-range. placement is approximate on a moving prompt until it re-anchors.",
    rows: [
      {
        app: "Terminal",
        apps: "com.apple.Terminal",
        method: "AX text-area + screenshot/OCR",
        quality: "inline ghost on the prompt line",
        quirks: "approximate placement on fast scroll-back; re-anchors on the next keystroke",
        status: "approx",
      },
      {
        app: "iTerm2",
        apps: "com.googlecode.iterm2",
        method: "AX text-area + screenshot/OCR",
        quality: "inline ghost on the prompt line",
        quirks: "same as Terminal; needs Screen Recording for the OCR path",
        status: "approx",
      },
      {
        app: "Warp",
        apps: "dev.warp.Warp-Stable",
        method: "screenshot / OCR caret",
        quality: "ghost at the OCR'd caret",
        quirks: "no AX text; read from the screen — Cotypist declares this unsupported, typer does not",
        status: "approx",
      },
      {
        app: "Ghostty",
        apps: "com.mitchellh.ghostty",
        method: "screenshot / OCR caret",
        quality: "ghost at the OCR'd caret",
        quirks: "GPU-drawn, no AX; empty-line caret (nothing to OCR) can be missed",
        status: "approx",
      },
    ],
  },
  {
    heading: "web canvas",
    blurb: "apps that draw their own text on a canvas expose no inline caret. typer rebuilds the line in an off-screen TextKit mirror and shows the suggestion in a small box near the field.",
    rows: [
      {
        app: "Google Docs",
        apps: "docs.google.com",
        method: "TextKit mirror (a11y on)",
        quality: "mirror box near the caret line",
        quirks: "needs Docs' own screen-reader mode (Tools → Accessibility) so it exposes text",
        status: "approx",
      },
    ],
  },
  {
    heading: "suppressed by default",
    blurb: "apps that ship their own autocomplete are off by default so typer never fights the editor you already trust. every one is overridable per-app from the menu.",
    rows: [
      {
        app: "Xcode",
        apps: "com.apple.dt.Xcode",
        method: "AX bounds-for-range",
        quality: "off by default · works if enabled",
        quirks: "has its own completion; flip typer on per-app if you want both",
        status: "issue",
      },
      {
        app: "JetBrains IDEs",
        apps: "IntelliJ · PyCharm · WebStorm",
        method: "AX bounds-for-range",
        quality: "off by default · approximate if enabled",
        quirks: "custom-drawn editor surface; enable per-app at your own risk",
        status: "issue",
      },
      {
        app: "password managers",
        apps: "1Password · Bitwarden · Proton Pass · …",
        method: "—",
        quality: "hard-suppressed, always",
        quirks: "never a setting you can flip — completions are blocked here by design, not preference",
        status: "issue",
      },
    ],
  },
];

const STATUS_LEGEND: { status: Status; text: string }[] = [
  { status: "solid", text: "inline ghost on the real caret, no drift" },
  { status: "approx", text: "lands close — approximate on movement or via a nearby mirror box" },
  { status: "issue", text: "suppressed by default, or a known rough edge — overridable, honest" },
];

const FAQ: { q: string; a: string }[] = [
  {
    q: "why is anything “approximate”?",
    a: "because it honestly is — and this page says so until it's fixed. a dishonest matrix is worse than none. some apps don't hand us a caret rectangle, so typer reads the caret off the screen (OCR) or rebuilds the line in an off-screen TextKit mirror. that lands close, but it can drift on a moving prompt or a wrapping paragraph until the next keystroke re-anchors it.",
  },
  {
    q: "what makes terminals work at all?",
    a: "a ScreenCaptureKit + Vision OCR caret locator that finds the caret in a screenshot of the focused element. it's the capability the closed competitors don't have — Cotypist declares Warp and Ghostty unsupported; typer places a ghost in them. it runs entirely on your Mac and needs the optional Screen Recording permission.",
  },
  {
    q: "why are my IDE and Google Docs different from everything else?",
    a: "IDEs ship their own autocomplete, so typer is off there by default rather than fighting an editor you already trust — flip it back on per-app from the menu. Google Docs draws text on a canvas with no inline caret, so it needs its own screen-reader mode on (Tools → Accessibility) before typer can read the text and mirror it.",
  },
  {
    q: "my app isn't here — what now?",
    a: `the matrix tracks the caret ladder in <code>docs/overhaul-spec.md</code> §B and grows as support lands. if your app is rough, that's the file and the fix — open an issue or send a PR on <a href="${GITHUB}" target="_blank" rel="noopener">GitHub</a>. each app we add is a small, honest update here.`,
  },
];

function statusCell(s: Status): string {
  return `<span class="status--${s}">${STATUS_LABEL[s]}</span>`;
}

function matrixGroup(g: (typeof GROUPS)[number]): string {
  const rows = g.rows
    .map(
      (r) => `<tr>
        <td data-label="app"><span class="app">${r.app}</span></td>
        <td data-label="bundle / kind" class="mono">${r.apps}</td>
        <td data-label="caret method">${r.method}</td>
        <td data-label="completion">${r.quality}</td>
        <td data-label="known quirks">${r.quirks}</td>
        <td data-label="status">${statusCell(r.status)}</td>
      </tr>`,
    )
    .join("");

  return `<div class="compat-group">
    <div class="compat-group__head">
      <h2 class="compat-group__title">${g.heading}</h2>
      <p class="compat-group__blurb">${g.blurb}</p>
    </div>
    <div class="table-scroll">
      <table class="matrix">
        <thead>
          <tr>
            <th scope="col">app</th>
            <th scope="col">bundle / kind</th>
            <th scope="col">caret method</th>
            <th scope="col">completion</th>
            <th scope="col">known quirks</th>
            <th scope="col">status</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
    </div>
  </div>`;
}

function markup(): string {
  return `
  <!-- ============================ HERO ============================ -->
  <section class="section compat-hero">
    <div class="container">
      <p class="eyebrow">honest by design</p>
      <h1 class="compat-hero__head">where the ghost lands, app by app.</h1>
      <p class="lead compat-hero__lead">
        typer places inline ghost-text on your real caret through an ordered fallback ladder.
        this is the public version of that ladder — per app, with the rough edges marked rough.
        the page is a trust instrument: <strong>approximate stays approximate until it's actually
        fixed.</strong>
      </p>
      <ul class="compat-legend" aria-label="status key">
        ${STATUS_LEGEND.map(
          (l) => `<li class="compat-legend__item">
            ${statusCell(l.status)}
            <span class="compat-legend__text">${l.text}</span>
          </li>`,
        ).join("")}
      </ul>
    </div>
  </section>

  <!-- ======================= THE LADDER ======================= -->
  <section class="section compat-ladder-sec" aria-labelledby="ladder-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">the fallback ladder</p>
        <h2 id="ladder-h">tries the precise thing first, degrades gracefully.</h2>
        <p class="section__lead">
          every completion runs down this list until one method yields a plausible caret rect;
          typer remembers which method won per app. steps 3 and 4 are why typer reaches places the
          closed competitors don't.
        </p>
      </div>
      <ol class="compat-ladder">
        ${LADDER.map(
          (s) => `<li class="compat-ladder__step">
            <span class="compat-ladder__n mono">${s.n}</span>
            <div class="compat-ladder__body">
              <span class="compat-ladder__method">${s.method}</span>
              <span class="compat-ladder__covers mono">${s.covers}</span>
            </div>
          </li>`,
        ).join("")}
      </ol>
    </div>
  </section>

  <!-- ====================== THE MATRIX ====================== -->
  <section class="section compat-matrix-sec" id="matrix" aria-labelledby="matrix-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">the matrix</p>
        <h2 id="matrix-h">per-app caret coverage.</h2>
        <p class="section__lead">
          measured on macOS 14+, Apple Silicon. some rows are approximate by construction — the app
          gives us no caret API, so we read the screen or mirror the line. that's marked, not hidden.
        </p>
      </div>
      <div class="compat-groups">
        ${GROUPS.map(matrixGroup).join("")}
      </div>
      <p class="compat-approx-note mono">
        “approximate” means the ghost lands close but can drift on movement (a scrolling prompt, a
        wrapping paragraph) until the next keystroke re-anchors it — not that it's broken.
      </p>
    </div>
  </section>

  <!-- ========================= FAQ ========================= -->
  <section class="section compat-faq-sec" aria-labelledby="faq-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">questions</p>
        <h2 id="faq-h">the honest version.</h2>
      </div>
      <div class="faq">
        ${FAQ.map(
          (f) => `<details class="faq__item">
            <summary>${f.q}</summary>
            <div class="faq__answer">${f.a}</div>
          </details>`,
        ).join("")}
      </div>
    </div>
  </section>

  <!-- ========================= CTA ========================= -->
  <section class="section compat-cta" aria-labelledby="ccta-h">
    <div class="container compat-cta__inner">
      <h2 id="ccta-h" class="compat-cta__head">found a rough edge?</h2>
      <p class="lead compat-cta__lead">
        that's the file and the fix. the matrix grows as caret support lands — open an issue or send
        a PR.
      </p>
      <div class="compat-cta__row">
        <a class="btn btn--primary" href="${GITHUB}" target="_blank" rel="noopener">get typer</a>
        <a class="btn btn--blue" href="${GITHUB}/blob/main/CONTRIBUTING.md" target="_blank" rel="noopener">contribute</a>
      </div>
      <p class="compat-cta__foot mono">free, forever · MIT · runs on llama.cpp · macOS 14+</p>
    </div>
  </section>
  `;
}

const main = document.getElementById("compatibility");
if (main) main.innerHTML = markup();
