/**
 * Home page content (the full <main> markup).
 *
 * Kept as one pure function that returns an HTML string so the design system in
 * styles.css stays the single source of truth (no inline color/px decisions here —
 * everything routes through the shared classes + tokens). home.ts imports this,
 * injects it into the foundation's <main id="home"> placeholder, then wires the
 * small bits of progressive enhancement (copy-to-clipboard, the typed hero motif).
 *
 * Copy is lifted from docs/marketing/positioning.md + announcement-draft.md.
 * Honesty rules (positioning §2/§5): the free local core is "now, forever";
 * everything above it is "planned" / "later". The matrix marks approximate cases
 * as approximate. Numbers are the real measured ones (M2 Pro TTFT).
 */

const GITHUB = "https://github.com/frgmt0/typer";
const INSTALL_CMD = "git clone https://github.com/frgmt0/typer && cd typer && ./install.sh";

/* ---- the per-app caret compatibility matrix (preview subset for the home page;
   the full table lives on /compatibility). Status + methods are sourced from
   docs/research/caret-placement.md §2 + docs/overhaul-spec.md §B. -------------- */
type Status = "solid" | "approx" | "issue";
const STATUS_LABEL: Record<Status, string> = {
  solid: "solid",
  approx: "approximate",
  issue: "known issue",
};
const MATRIX_PREVIEW: {
  app: string;
  cls: string;
  method: string;
  status: Status;
  note: string;
}[] = [
  {
    app: "native AppKit",
    cls: "TextEdit · Notes · Mail",
    method: "AX bounds-for-range",
    status: "solid",
    note: "inline ghost on the real caret",
  },
  {
    app: "WebKit / Electron",
    cls: "Slack · Chrome inputs · VS Code",
    method: "AX text-marker bounds",
    status: "solid",
    note: "host font read over AX",
  },
  {
    app: "terminals (AX)",
    cls: "Terminal · iTerm2",
    method: "AX text-area + screenshot/OCR",
    status: "approx",
    note: "OCR caret locator — our edge",
  },
  {
    app: "GPU terminals",
    cls: "Warp · Ghostty",
    method: "screenshot/OCR caret",
    status: "approx",
    note: "no AX; read from the screen",
  },
  {
    app: "Google Docs",
    cls: "docs.google.com",
    method: "TextKit mirror (a11y on)",
    status: "approx",
    note: "needs Docs screen-reader mode",
  },
];

function matrixRow(r: (typeof MATRIX_PREVIEW)[number]): string {
  return `<tr>
    <td data-label="app"><span class="app">${r.app}</span></td>
    <td data-label="apps" class="mono">${r.cls}</td>
    <td data-label="caret method">${r.method}</td>
    <td data-label="notes">${r.note}</td>
    <td data-label="status"><span class="status--${r.status}">${STATUS_LABEL[r.status]}</span></td>
  </tr>`;
}

/* ---- the model lineup (real M2 Pro TTFT, q8 ships) ------------------------- */
const MODELS: {
  id: string;
  params: string;
  ttft: string;
  blurb: string;
  feature: boolean;
}[] = [
  {
    id: "typer-1s",
    params: "0.6B",
    ttft: "lightest",
    blurb: "the tightest machines. smallest footprint, still on-device.",
    feature: false,
  },
  {
    id: "typer-1m",
    params: "1.7B",
    ttft: "27 ms",
    blurb: "first word on screen in 27 ms — the everyday default.",
    feature: true,
  },
  {
    id: "typer-1l",
    params: "4B",
    ttft: "57 ms",
    blurb: "the most capable, still well under the ~100 ms budget.",
    feature: false,
  },
];

/* ---- QoL feature highlights ----------------------------------------------- */
const QOL: { kicker: string; title: string; body: string }[] = [
  {
    kicker: "per app",
    title: "custom instructions",
    body: "typer writes one way in your terminal and another in your email. set a tone per app.",
  },
  {
    kicker: "room to think",
    title: "snooze",
    body: "turn completions off for the next few minutes — or just in the front app — when you need quiet.",
  },
  {
    kicker: "control",
    title: "completion length",
    body: "a single word, a phrase, or a full thought. one dial, your call.",
  },
  {
    kicker: "yours",
    title: "personalization",
    body: "a strength dial biases suggestions toward the words you actually use — computed locally, nothing leaves your disk.",
  },
  {
    kicker: "shortcodes",
    title: "emoji completion",
    body: "complete emoji from shortcodes, with skin-tone and gender variants.",
  },
  {
    kicker: "typos",
    title: "suggested fixes",
    body: "a likely typo is flagged distinctly from a normal suggestion, with a gate so it can't quietly become a wrong completion.",
  },
  {
    kicker: "models",
    title: "model catalog",
    body: "pick by your machine. disk-aware downloads won't start a pull you don't have room for.",
  },
  {
    kicker: "macOS",
    title: "inline-prediction guidance",
    body: "one-click opt-in for macOS's own inline prediction, recorded so you can always undo.",
  },
];

/* ---- the open-core offerings ladder (positioning §5) ----------------------- */
const OFFERINGS: {
  rung: string;
  title: string;
  body: string;
  badge: "now" | "planned";
  badgeLabel: string;
}[] = [
  {
    rung: "rung 0",
    title: "free local core",
    body: "the completion engine, every model, learned style, per-app context, typo correction, the whole compatibility ladder. MIT, build from source. never gated, never degraded, never sunset.",
    badge: "now",
    badgeLabel: "now · forever",
  },
  {
    rung: "rung 1",
    title: "signed, notarized builds",
    body: "an opt-in notarized download + auto-update feed, so you skip the Xcode CLI + Homebrew build. turn it off and you're back to ./install.sh — the identical app.",
    badge: "planned",
    badgeLabel: "planned",
  },
  {
    rung: "rung 2",
    title: "cloud distillation → local LoRA",
    body: "local personalization always works offline. opt in and you can train a sharper personal LoRA in the cloud, then download it back and run it locally. the oven is faster; the bread is still baked on your machine.",
    badge: "planned",
    badgeLabel: "planned",
  },
  {
    rung: "rung 3 · 4",
    title: "pro & team conveniences",
    body: "per-app instruction management, multi-candidate polish, shared instruction packs and managed settings for orgs. we manage settings, never content — no keystrokes pass through us.",
    badge: "planned",
    badgeLabel: "later",
  },
];

export function homeMarkup(): string {
  return `
  <!-- ============================ HERO ============================ -->
  <section class="section hero" id="top">
    <div class="container">
      <p class="eyebrow">local · on-device · macOS 14+</p>
      <h1 class="hero__head">
        you type the first half,<br />it shows you
        <span class="hero__rest"><span class="hero__type" id="hero-type"></span><span class="hero__caret" aria-hidden="true"></span><span class="hero__ghost" id="hero-ghost">the rest.</span></span>
      </h1>
      <p class="lead hero__lead">
        autocomplete that never leaves your Mac. a dim suggestion appears at your caret in
        almost any app — <span class="kbd kbd--accept">tab</span> takes the next word,
        <span class="kbd kbd--blue">\`</span> takes the rest — on your Mac and nowhere else.
      </p>

      <div class="hero__install" id="install">
        <div class="code" role="group" aria-label="install command">
          <button class="btn btn--ghost code__copy" type="button" data-copy="${INSTALL_CMD}" aria-label="copy install command">copy</button>
          <span class="prompt">$ </span>git clone <span class="ghost">https://github.com/frgmt0/typer</span> &amp;&amp; cd typer &amp;&amp; <span class="hero__type">./install.sh</span>
        </div>
        <div class="hero__cta">
          <a class="btn btn--primary" href="${GITHUB}" target="_blank" rel="noopener">get typer</a>
          <a class="btn btn--blue" href="${GITHUB}" target="_blank" rel="noopener">view source</a>
        </div>
      </div>

      <p class="hero__proof mono">runs on llama.cpp + a local GGUF model · no account · no cloud · password fields skipped · MIT</p>
    </div>

    <div class="container hero__demo">
      <figure class="demo">
        <video
          class="demo__video"
          id="demo-video"
          playsinline muted loop preload="none"
          poster="/demo/poster-light.png"
          aria-label="typer ghost-text demo: a dim suggestion appears at the caret and is accepted with tab">
          <source src="/demo/typer-demo-light.mp4" type="video/mp4" />
        </video>
        <figcaption class="demo__cap mono">the ghost lands on your real caret — here in a native field.</figcaption>
      </figure>
    </div>
  </section>

  <!-- ===================== HOW IT WORKS / PRIVACY ===================== -->
  <section class="section" id="how" aria-labelledby="how-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">how it works</p>
        <h2 id="how-h">on your Mac, nowhere else.</h2>
        <p class="section__lead">
          llama.cpp runs a small GGUF model on your machine. there is no account, no Apple
          Developer Program, and no network call to make a completion. the privacy isn't a
          vibe — it's mechanisms you can read in the source.
        </p>
      </div>
    </div>
    <div class="container">
      <div class="cell-grid">
        <div class="cell">
          <p class="cell__kicker">always on</p>
          <h3 class="cell__title">password-manager denylist</h3>
          <p class="cell__body">completions are hard-suppressed in 1Password, Apple Passwords, Bitwarden, Dashlane, LastPass, KeePassXC, Proton Pass and the rest — not a setting you can forget to flip.</p>
        </div>
        <div class="cell">
          <p class="cell__kicker">secure fields</p>
          <h3 class="cell__title">secure-field skip</h3>
          <p class="cell__body">role/subrole detection plus IsSecureEventInputEnabled — password fields, the login window, sudo, secure web fields: no buffering, no learning, no logging.</p>
        </div>
        <div class="cell">
          <p class="cell__kicker">no keylogger</p>
          <h3 class="cell__title">the log is not your text</h3>
          <p class="cell__body">by default the log records counts and events, never typed text. learned style and stats live under your Library at mode 0600 — clear or reset any time.</p>
        </div>
        <div class="cell">
          <p class="cell__kicker">the edge</p>
          <h3 class="cell__title">it works in your terminal</h3>
          <p class="cell__body">a ScreenCaptureKit + Vision OCR caret locator places ghost text in terminals and custom editors — a capability the closed competitors lack. all of it runs locally.</p>
        </div>
      </div>
    </div>
  </section>

  <!-- ====================== THE KEYS ====================== -->
  <section class="section keys" id="keys" aria-labelledby="keys-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">the flow</p>
        <h2 id="keys-h">type into the suggestion.</h2>
        <p class="section__lead">three keys, no menu. the ghost is dim until you take it.</p>
      </div>
      <ul class="keys__list">
        <li class="keys__item">
          <span class="kbd kbd--accept">tab</span>
          <span class="keys__desc">take the <strong>next word</strong></span>
        </li>
        <li class="keys__item">
          <span class="kbd kbd--blue">\`</span>
          <span class="keys__desc">take the <strong>whole line</strong></span>
        </li>
        <li class="keys__item">
          <span class="kbd">esc</span>
          <span class="keys__desc"><strong>dismiss</strong> the suggestion</span>
        </li>
      </ul>
    </div>
  </section>

  <!-- ====================== MODEL LINEUP ====================== -->
  <section class="section" id="models" aria-labelledby="models-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">the lineup</p>
        <h2 id="models-h">three models. pick by your machine.</h2>
        <p class="section__lead">
          time-to-first-token on an M2 Pro. q8 turned out faster than full precision and half
          the size, so that's what we ship — first word comfortably under the ~100 ms budget
          where ghost text still feels instant.
        </p>
      </div>
      <div class="models">
        ${MODELS.map(
          (m) => `<article class="card model${m.feature ? " card--feature" : ""}">
            <p class="card__kicker">${m.params}${m.feature ? " · default" : ""}</p>
            <h3 class="card__title">${m.id}</h3>
            <p class="model__ttft mono"><span class="model__ttft-num">${m.ttft}</span>${m.ttft.includes("ms") ? " <span class=\"model__ttft-lbl\">first word</span>" : ""}</p>
            <p class="card__body">${m.blurb}</p>
          </article>`,
        ).join("")}
      </div>
    </div>
  </section>

  <!-- ================== COMPATIBILITY MATRIX ================== -->
  <section class="section" id="compatibility" aria-labelledby="compat-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">caret coverage</p>
        <h2 id="compat-h">honest about where it lands.</h2>
        <p class="section__lead">
          an ordered fallback ladder places the ghost on your real caret — and we mark the
          rough edges as rough. <span class="status--solid mono">solid</span> ·
          <span class="status--approx mono">approximate</span> ·
          <span class="status--issue mono">known issue</span>.
        </p>
      </div>
      <div class="table-scroll">
        <table class="matrix">
          <thead>
            <tr>
              <th scope="col">app class</th>
              <th scope="col">apps</th>
              <th scope="col">caret method</th>
              <th scope="col">notes</th>
              <th scope="col">status</th>
            </tr>
          </thead>
          <tbody>
            ${MATRIX_PREVIEW.map(matrixRow).join("")}
          </tbody>
        </table>
      </div>
      <p class="matrix__more">
        <a class="btn btn--blue" href="/compatibility">see the full matrix</a>
      </p>
    </div>
  </section>

  <!-- ======================= QoL FEATURES ======================= -->
  <section class="section" id="features" aria-labelledby="feat-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">quality of life</p>
        <h2 id="feat-h">the stuff that makes it yours.</h2>
        <p class="section__lead">a layer of small controls on top of a completion engine that just runs.</p>
      </div>
    </div>
    <div class="container">
      <div class="cell-grid">
        ${QOL.map(
          (f) => `<div class="cell">
            <p class="cell__kicker">${f.kicker}</p>
            <h3 class="cell__title">${f.title}</h3>
            <p class="cell__body">${f.body}</p>
          </div>`,
        ).join("")}
      </div>
    </div>
  </section>

  <!-- ====================== OFFERINGS LADDER ====================== -->
  <section class="section" id="offerings" aria-labelledby="off-h">
    <div class="container">
      <div class="section__head">
        <p class="eyebrow">open core</p>
        <h2 id="off-h">we charge for convenience, never the core.</h2>
        <p class="section__lead">
          every rung is opt-in and degrades to the one below it. if our servers vanish, the app
          works exactly as before. the local build is the product — not a crippled demo of a
          paid one.
        </p>
      </div>
      <div class="ladder">
        ${OFFERINGS.map(
          (o) => `<article class="card ${o.badge === "now" ? "card--feature" : "card--planned"} ladder__rung">
            <div class="ladder__head">
              <p class="card__kicker">${o.rung}</p>
              <span class="badge badge--${o.badge}">${o.badgeLabel}</span>
            </div>
            <h3 class="card__title">${o.title}</h3>
            <p class="card__body">${o.body}</p>
          </article>`,
        ).join("")}
      </div>
    </div>
  </section>

  <!-- ========================= FINAL CTA ========================= -->
  <section class="section cta" aria-labelledby="cta-h">
    <div class="container cta__inner">
      <h2 id="cta-h" class="cta__head">autocomplete that never leaves your Mac.</h2>
      <p class="lead cta__lead">Cotypist, but open and yours. install is one line today.</p>
      <div class="code cta__code" role="group" aria-label="install command">
        <button class="btn btn--ghost code__copy" type="button" data-copy="${INSTALL_CMD}" aria-label="copy install command">copy</button>
        <span class="prompt">$ </span>${INSTALL_CMD.replace(/&/g, "&amp;")}
      </div>
      <div class="cta__row">
        <a class="btn btn--primary" href="${GITHUB}" target="_blank" rel="noopener">get typer on github</a>
        <a class="btn btn--blue" href="/compatibility">compatibility</a>
      </div>
      <p class="cta__foot mono">free, forever · MIT · runs on llama.cpp · macOS 14+</p>
    </div>
  </section>
  `;
}
