# typer — marketing site design system

Status: **authoritative, buildable.** This is the concrete spec the implementation agents follow.
It operationalizes `docs/marketing/design-reference.md` (the brief) and `positioning.md` (the copy
voice) into exact tokens, components, and an architecture. If the brief and this file ever disagree,
the brief wins on *intent*; this file wins on *the hex value / the class name / the px*. Do not
re-decide anything specified here.

Grounding: greptile gives us the **rigor** — blueprint-grid background, hairline rules, sharp
corners, bordered cells, mono labels, a geometric footer. typer keeps its **identity** — the live
blue caret and the green "accept", an honest open-core voice, all-lowercase terse copy. Two accents
maximum. We do **not** copy greptile's lime+pink candy palette.

---

## 0. Design principles (the filter for every decision)

1. **Technical, not decorative.** Sharp 2px corners, 1px hairline rules, a faint blueprint grid.
   Whitespace and structure do the work; no gradients-as-decoration, no drop shadows except the
   one functional CTA lift.
2. **Two accents, used like punctuation.** Blue = the live caret / motion / links. Green =
   accept / success / "free, forever". Everything else is ink on base. If a third color shows up,
   it's a bug.
3. **Honesty is a visual primitive.** `now` (green), `planned`/`approximate` (blue), `known issue`
   (a desaturated red used *only* in the matrix). Status is always color **plus** a text label —
   never color alone (accessibility + honesty).
4. **The product is the hero.** The blue ghost-text caret motif appears in the hero and recurs as
   the site's signature. Lowercase, terse, builder-voice copy throughout (see positioning §8).
5. **Reduced-motion is a first-class path,** not an afterthought. Every animated element has a
   defined static state that is the *complete* experience.

---

## 1. Color tokens

Light theme is primary (greptile-grounded, near-white base). Dark theme is a real toggle, persisted
to `localStorage` and respecting `prefers-color-scheme` on first visit. The blue caret and green
accept are **identity colors**: their hex is tuned to read on both themes, not flipped.

### 1.1 The two accents (identity — same hue family both themes)

| Token | Light | Dark | Use |
|---|---|---|---|
| `--blue` | `#2f6bff` | `#6ea8ff` | live caret, motion, links, "planned"/"approximate" status, focus ring |
| `--blue-soft` | `#e8efff` | `#16233f` | blue tint fills (active nav cell, link hover bg) |
| `--green` | `#0f9d58` → use `#12a45c` | `#5fd081` | accept key, success, "now / free forever" status, primary CTA |
| `--green-soft` | `#e3f7ec` | `#10301f` | green tint fills (CTA hover, "now" badge bg) |

Notes:
- Dark `--blue #6ea8ff` and dark `--green #5fd081` are the **exact tokens the current site already
  ships** (web/index.html `:root`) — keep them so the brand doesn't shift.
- Light `--blue #2f6bff` / `--green #12a45c` are darkened for AA contrast on the near-white base
  (both clear 4.5:1 on `#fafaf8` for normal text; `--green` is for large text / fills / borders,
  pair green CTA text with `--ink-on-green`, see buttons).

### 1.2 Ink / base / rule (neutrals)

| Token | Light | Dark | Use |
|---|---|---|---|
| `--base` | `#fafaf8` | `#0b0b0d` | page background (warm near-white / near-black, matches current dark `#0b0b0d`) |
| `--base-2` | `#f2f1ec` | `#121215` | raised cell fill, code block bg, table header row |
| `--ink` | `#16161a` | `#e7e7ea` | primary text, display headings |
| `--ink-2` | `#3d3b44` | `#aeaeb6` | body text, secondary |
| `--ink-3` | `#6b6975` | `#8a8a92` | captions, labels, mono eyebrows, footer links |
| `--ghost` | `#b8b6bd` | `#55555e` | the literal ghost-text color (dim suggestion in the demo) |
| `--rule` | `#e2e0da` | `#26262c` | hairline borders, grid lines, table rules, card borders |
| `--rule-strong` | `#cbc9c1` | `#34343c` | emphasized borders (hovered card, active cell) |
| `--red` | `#c0392b` | `#ff7a7a` | **matrix "known issue" status only** — never a CTA, never decoration |
| `--ink-on-green` | `#ffffff` | `#06160d` | text/icon sitting on a green fill (CTA label) |

### 1.3 CSS variable block (paste-ready)

```css
:root {
  --base: #fafaf8;  --base-2: #f2f1ec;
  --ink: #16161a;   --ink-2: #3d3b44;  --ink-3: #6b6975;
  --ghost: #b8b6bd;
  --rule: #e2e0da;  --rule-strong: #cbc9c1;
  --blue: #2f6bff;  --blue-soft: #e8efff;
  --green: #12a45c; --green-soft: #e3f7ec;
  --red: #c0392b;
  --ink-on-green: #ffffff;
  color-scheme: light;
}
:root[data-theme="dark"] {
  --base: #0b0b0d;  --base-2: #121215;
  --ink: #e7e7ea;   --ink-2: #aeaeb6;  --ink-3: #8a8a92;
  --ghost: #55555e;
  --rule: #26262c;  --rule-strong: #34343c;
  --blue: #6ea8ff;  --blue-soft: #16233f;
  --green: #5fd081; --green-soft: #10301f;
  --red: #ff7a7a;
  --ink-on-green: #06160d;
  color-scheme: dark;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) { /* same overrides as [data-theme="dark"] */ }
}
```
Implementer note: rather than duplicate the dark block in the media query, set
`:root` default = light, and have the theme toggle script write `data-theme` on `<html>`; the
media-query default is resolved once on first load by the inline `<head>` script (§7.4) so there is
no flash. Theme color meta: update `<meta name="theme-color">` to `--base` on toggle.

### 1.4 Status color → meaning (locked)

| Status word | Token | Where |
|---|---|---|
| `now` / `free, forever` / `solid` | `--green` | offerings ladder, matrix |
| `planned` / `later` / `approximate` | `--blue` | offerings ladder, matrix |
| `known issue` | `--red` | matrix only |

---

## 2. Typography

### 2.1 Families

Self-host via the Vite `web/public/fonts/` dir (preferred — no network dependency, matches the
local-first ethos and avoids FOUT/privacy leak). If self-hosting slips, Google Fonts `<link>` with
`display=swap` is the accepted fallback. All three are on Google Fonts under open licenses.

| Role | Family | Weights | Fallback stack |
|---|---|---|---|
| **display** | **Space Grotesk** | 500, 700 | `"Space Grotesk", "Arial Narrow", system-ui, sans-serif` |
| **body** | **DM Sans** | 400, 500, 700 | `"DM Sans", system-ui, -apple-system, sans-serif` |
| **mono** | **Space Mono** | 400, 700 | `"Space Mono", ui-monospace, "SF Mono", Menlo, monospace` |

Rationale: the brief names the Anybody/Space-Grotesk family for display, DM Sans for body, Space
Mono for mono/labels. **Space Grotesk** is the free, widely-available stand-in for greptile's paid
"Anybody" — same bold, slightly-condensed technical grotesque feel. No Nanum Pen handwriting accent
(that's greptile's, not ours).

```css
:root {
  --font-display: "Space Grotesk", "Arial Narrow", system-ui, sans-serif;
  --font-body: "DM Sans", system-ui, -apple-system, sans-serif;
  --font-mono: "Space Mono", ui-monospace, "SF Mono", Menlo, monospace;
}
```

Self-host plan (concrete):
- Drop woff2 in `web/public/fonts/` — `space-grotesk-{500,700}.woff2`,
  `dm-sans-{400,500,700}.woff2`, `space-mono-{400,700}.woff2`.
- `@font-face` blocks in the shared stylesheet with `font-display: swap` and matching `local()`
  first. Subset to `latin` to keep payload small.
- `<link rel="preload" as="font" type="font/woff2" crossorigin href="/fonts/space-grotesk-700.woff2">`
  for the hero display weight only.

### 2.2 Type scale (rem, fluid where it earns it)

Base body = 16px = 1rem. Display sizes use `clamp()` so the hero scales without breakpoints.

| Token | Size | Line-height | Weight | Family | Use |
|---|---|---|---|---|---|
| `--t-hero` | `clamp(2.6rem, 7vw, 5.5rem)` | 0.98 | 700 | display | hero h1 (UPPERCASE optional) |
| `--t-h2` | `clamp(1.8rem, 3.5vw, 2.75rem)` | 1.05 | 700 | display | section headings |
| `--t-h3` | `1.35rem` | 1.2 | 700 | display | card titles, sub-headings |
| `--t-h4` | `1.05rem` | 1.3 | 700 | display | small headings, table heads |
| `--t-body` | `1rem` (16px) | 1.65 | 400 | body | paragraphs |
| `--t-body-lg` | `1.2rem` | 1.55 | 400 | body | hero sub-line, lead paragraph |
| `--t-small` | `0.875rem` | 1.5 | 400 | body | captions, footnotes |
| `--t-label` | `0.75rem` | 1.4 | 700 | mono | eyebrows, kicker labels (UPPERCASE, `letter-spacing: 0.08em`) |
| `--t-code` | `0.875rem` | 1.7 | 400 | mono | code blocks, matrix, kbd |

Heading letter-spacing: display headings `letter-spacing: -0.02em`. Mono labels `+0.08em`,
UPPERCASE. Body never tracked.

Copy rule (from positioning): headings and UI copy are **all-lowercase** *except* the kicker/eyebrow
mono labels which are UPPERCASE for the technical-blueprint feel. The hero h1 may be UPPERCASE
display (greptile does this) — that's the one allowed exception, decide per-implementation but be
consistent.

---

## 3. Spacing, radius, layout

### 3.1 Spacing scale (4px base)

```css
--sp-1: 0.25rem;  --sp-2: 0.5rem;   --sp-3: 0.75rem;  --sp-4: 1rem;
--sp-5: 1.5rem;   --sp-6: 2rem;     --sp-7: 3rem;     --sp-8: 4rem;
--sp-9: 6rem;     --sp-10: 8rem;
```
Section vertical rhythm: `padding-block: var(--sp-9)` desktop, `var(--sp-8)` mobile. Cell/card
padding: `var(--sp-5)` to `var(--sp-6)`. Inline gaps in grids: `0` (cells share hairline borders,
greptile-style) — see §3.4.

### 3.2 Radius (sharp — locked)

```css
--radius: 2px;        /* default — cards, buttons, inputs, badges */
--radius-sm: 1px;     /* hairline chips, kbd */
```
No radius above 2px anywhere. This is non-negotiable per the brief ("sharp, ~2px").

### 3.3 Container & grid columns

```css
--maxw: 1200px;            /* outer content max width */
--maxw-prose: 68ch;        /* long-form text (research posts, announcements body) */
--gutter: clamp(1rem, 4vw, 2.5rem);  /* page side padding */
```
- Outer container: `max-width: var(--maxw); margin-inline: auto; padding-inline: var(--gutter)`.
- The site reads as a **12-column blueprint** conceptually; in practice most sections are 1 / 2 / 3
  -column CSS grids of bordered cells. Standard responsive cell grid:
  `grid-template-columns: repeat(auto-fit, minmax(min(100%, 18rem), 1fr))`.

### 3.4 Bordered-cell pattern (greptile signature)

Cells sit flush with **shared hairline borders** (no gaps), so a row of cards reads as a single
ruled table, not floating cards. Technique: the grid container draws top+left rules; each cell draws
bottom+right. This avoids double borders and collapses cleanly responsively.

```css
.cell-grid { display: grid; border-top: 1px solid var(--rule); border-left: 1px solid var(--rule); }
.cell { border-right: 1px solid var(--rule); border-bottom: 1px solid var(--rule);
        padding: var(--sp-6); background: var(--base); }
.cell:hover { background: var(--base-2); }
```

---

## 4. The blueprint-grid background (the signature)

A faint full-bleed grid of hairline rules behind all content, fixed to the viewport so content
floats over a consistent technical plane. Implemented as a `body::before` pseudo-element with two
layered `linear-gradient`s (vertical + horizontal lines), `position: fixed`, `pointer-events: none`,
behind everything (`z-index: -1`).

```css
body::before {
  content: ""; position: fixed; inset: 0; z-index: -1; pointer-events: none;
  background-image:
    linear-gradient(to right, var(--rule) 1px, transparent 1px),
    linear-gradient(to bottom, var(--rule) 1px, transparent 1px);
  background-size: var(--grid) var(--grid);
  /* fade the grid so it's a whisper, not a cage */
  -webkit-mask-image: radial-gradient(ellipse 120% 90% at 50% 0%, #000 35%, transparent 100%);
          mask-image: radial-gradient(ellipse 120% 90% at 50% 0%, #000 35%, transparent 100%);
  opacity: 0.6;
}
:root { --grid: clamp(48px, 8vw, 96px); }  /* tile size scales with viewport */
```
Tuning: keep the grid at `--rule` opacity (already faint) — it should be barely perceptible on light,
slightly more present on dark. The radial mask keeps it densest at the top (behind the hero) and
fades it out down the page so long-form sections aren't busy. The two **strong vertical column
rules** that frame the central content (greptile's most recognizable move) are drawn separately as a
container element (`.frame`) with `border-inline: 1px solid var(--rule)` at the `--maxw` boundary —
so the page literally has visible left/right margins ruled in.

Reduced motion: the grid is static (no parallax). It never animates.

---

## 5. Component set (shared, used on every page)

All components live in the single shared stylesheet (§6). Class names below are the contract.

### 5.1 Buttons

```
.btn            base: --font-mono, --t-label sizing bumped to 0.8rem, UPPERCASE, letter-spacing
                0.06em, padding 0.7rem 1.3rem, radius --radius, border 1px solid, transition
                background/transform 120ms.
.btn--primary   bg var(--green); color var(--ink-on-green); border-color var(--green).
                hover: translateY(-1px) + subtle shadow 0 2px 0 rgba(0,0,0,.12) (the ONE functional
                lift). active: translateY(0).
.btn--ghost     bg transparent; color var(--ink); border 1px solid var(--rule-strong).
                hover: background var(--base-2); border-color var(--ink-3).
.btn--blue      bg transparent; color var(--blue); border 1px solid var(--blue).
                hover: background var(--blue-soft). (secondary "live demo" / GitHub style)
```
Primary CTA copy lowercase exception: buttons use mono UPPERCASE labels (e.g. `INSTALL`,
`VIEW SOURCE`) to read as technical keys. Icon + label allowed.

### 5.2 kbd (keycap)

Tab / backtick / esc keys are core to the product story — style them as real keycaps.
```
.kbd  display inline-block; font --font-mono; font-size 0.8em; padding 0.15em 0.5em;
      border 1px solid var(--rule-strong); border-bottom-width 2px; border-radius --radius;
      background var(--base-2); color var(--ink); line-height 1.
```
Color variants for the demo legend: `.kbd--accept` (border/text `--green`), `.kbd--blue`.

### 5.3 Card / cell

`.cell` (see §3.4) is the primitive. Variants:
```
.card           standalone bordered box: 1px solid var(--rule), radius --radius, padding --sp-6,
                background var(--base). For pricing/offering cards.
.card--feature  green left accent: border-left 2px solid var(--green) for "now" offerings.
.card--planned  blue left accent: border-left 2px solid var(--blue) for planned/later.
.card__kicker   mono UPPERCASE label (--t-label, color --ink-3).
.card__title    --t-h3, display.
.card__body     --t-body, color --ink-2.
```

### 5.4 Badge / pill (status)

```
.badge          inline mono, --t-label, padding 0.2em 0.6em, radius --radius, border 1px solid,
                UPPERCASE.
.badge--now     color var(--green); border-color var(--green); background var(--green-soft).   "NOW"
.badge--planned color var(--blue);  border-color var(--blue);  background var(--blue-soft).    "PLANNED" / "LATER"
.badge--alpha   color var(--ink-3); border-color var(--rule-strong); background var(--base-2).  "ALPHA"
```
Always include the word, never rely on color alone.

### 5.5 Nav (shared module — §7.1)

```
.nav            sticky top; height ~64px; border-bottom 1px solid var(--rule);
                background color-mix(in srgb, var(--base) 88%, transparent) + backdrop-filter blur(8px).
.nav__inner     --maxw container, flex, space-between, align center.
.nav__brand     logo mark + "typer" wordmark (display 700, lowercase). links home.
.nav__links     mono --t-label UPPERCASE links: COMPATIBILITY · RESEARCH · ANNOUNCEMENTS · GITHUB.
.nav__cta       .btn--primary "INSTALL" (or "GET TYPER"), hidden on narrow → hamburger.
.nav__theme     theme toggle button (sun/moon SVG, .btn--ghost icon-only).
```
Active page: its nav link gets `color: var(--blue)` + a 2px `--blue` underline.
Mobile: links collapse into a `<details>`/disclosure menu (no JS framework; a tiny vanilla toggle).

### 5.6 Footer (shared module — §7.2)

Greptile-style: geometric logo, a motif band, dense mono link columns, a baseline tagline.
```
.footer            border-top 1px solid var(--rule); padding-block --sp-8; background var(--base).
.footer__motif     a repeating isometric-keycap / caret-tile band (CSS, see below) above the columns,
                   height ~120px, opacity ~0.5, masked to fade. Static.
.footer__grid      cell-grid of link columns: PRODUCT · OPEN SOURCE · RESOURCES · LEGAL.
.footer__col-head  mono --t-label UPPERCASE --ink-3.
.footer__link      mono --t-small, --ink-2, hover --ink + blue underline.
.footer__brand     the geometric logo mark (large) + wordmark.
.footer__tagline   "free, forever · MIT · runs on llama.cpp · macOS 14+"  (positioning §8, verbatim).
```
The geometric logo mark: a **monospace caret + cursor block** glyph treated as a logo — render an
inline SVG of a blinking-caret block (a filled square + a thin vertical bar) in `--blue`, sized
~36px in nav, ~72px in footer. This *is* typer's "cube logo" equivalent and ties to the product.
Spec the SVG once in §7.3 and reuse.

Footer motif (CSS, no image): a tiled SVG data-URI of an isometric keycap outline OR a simpler
repeating caret-tile using `repeating-linear-gradient` at 30°/-30° to suggest an isometric keyboard
field, in `--rule`, masked with `mask-image: linear-gradient(to bottom, transparent, #000)`. Keep it
a whisper. Static; no animation.

### 5.7 Table — compatibility matrix

The matrix is a real `<table>` (not the current monospace `<pre>`), styled as a ruled blueprint
grid. Columns per positioning §6: **app · caret method · quality · known quirks · status**.
```
.matrix           width 100%; border-collapse collapse; font --font-mono; font-size --t-code.
.matrix th        text-align left; --t-label UPPERCASE; --ink-3; border-bottom 1px solid --rule-strong;
                  padding --sp-3 --sp-4; background var(--base-2); position sticky top (under nav).
.matrix td        padding --sp-3 --sp-4; border-bottom 1px solid var(--rule); color --ink-2.
.matrix tr:hover td  background var(--base-2).
.matrix .app      color --ink; font-weight 700.
```
Status cell uses a `.badge` (`--now`/`--planned`/`--alpha`) or an inline dot+word:
`.status--solid` (green), `.status--approx` (blue), `.status--issue` (red). Word always present.
Responsive: on narrow viewports the table becomes stacked cards (each row → a `.card` with
label:value pairs) via a CSS-only `display:block` reflow, OR horizontal scroll in a
`.table-scroll` wrapper with a fade hint. Pick stacked-cards for readability.

### 5.8 FAQ / accordion

Native `<details>`/`<summary>` (no JS needed; works with reduced-motion and no-JS).
```
.faq__item     border-bottom 1px solid var(--rule).
.faq summary   --t-h4 display; padding-block --sp-4; cursor pointer; list-style none;
               flex space-between with a +/− or chevron (rotates on [open], 150ms, disabled under
               reduced-motion).
.faq__answer   --t-body --ink-2; padding-bottom --sp-5; max-width --maxw-prose.
```

### 5.9 Code block

```
.code          background var(--base-2); border 1px solid var(--rule); border-radius --radius;
               padding --sp-4 --sp-5; font --font-mono; font-size --t-code; color var(--ink);
               overflow-x auto; line-height 1.7.
.code__copy    optional copy button top-right (.btn--ghost icon, vanilla clipboard JS).
.code .prompt  color var(--ink-3) (the leading $).
.code .ghost   color var(--ghost) (ghost-text demo: the predicted half).
```

### 5.10 Section scaffolding

```
.section          padding-block --sp-9 (mobile --sp-8); within .frame (the ruled container).
.section__head    margin-bottom --sp-7; max-width --maxw-prose for the intro text.
.eyebrow          mono --t-label UPPERCASE, color --blue, margin-bottom --sp-2. (kicker)
.section h2        --t-h2 display, color --ink.
.section__lead     --t-body-lg, color --ink-2.
```

### 5.11 The hero caret / ghost-text motif (signature)

The hero shows the product literally: a line of typed text + a dim blue ghost suggestion + a
blinking caret. Reuse the existing `home.ts` typewriter logic conceptually but theme it to tokens:
```
.hero__type     --font-mono or display; the user-typed text in --ink.
.hero__ghost    color var(--ghost); the predicted continuation.
.hero__caret    a 1px-wide, 1.1em-tall inline block, background var(--blue); blink animation 1s
                step-end infinite.
@media (prefers-reduced-motion: reduce) {
  .hero__caret { animation: none; }              /* solid, non-blinking */
  /* the typewriter renders its FINAL state immediately — full ghost line shown, no typing */
}
```
Static fallback is the **complete** sentence with ghost continuation visible — the reader sees
exactly what the product does, just without the keystroke animation.

---

## 6. CSS architecture (decision: ONE shared stylesheet)

**Decision: a single shared stylesheet, `web/src/styles.css`, imported by every page entry.** Not
inline-per-page.

Why: there are 3–4 pages (home, compatibility, research, announcements) that must look identical in
nav/footer/grid/tokens. Inline-per-page (the current approach) already caused drift risk. One
stylesheet = one source of truth for tokens + components; Vite hashes and caches it once; pages
import it from their TS entry (`import "./styles.css"`). Vite inlines/minifies and code-splits CSS
per entry but dedupes the shared module.

Structure of `web/src/styles.css` (in order):
```
1. @font-face blocks (self-hosted)            §2.1
2. :root + [data-theme=dark] token blocks     §1.3, §2.1, §3.1–3.3
3. reset / base (box-sizing, body, links, ::selection in --blue-soft)
4. blueprint grid (body::before, .frame)      §4
5. typography utilities (.eyebrow, h1–h4, .lead, .mono, .lowercase)
6. layout (.section, .container, .cell-grid, .cell)   §3, §5.10
7. components (.btn, .kbd, .card, .badge, .nav, .footer, .matrix, .faq, .code, hero)  §5
8. utilities (.sr-only, .stack, spacing helpers)
9. @media (prefers-reduced-motion: reduce) global block   §5.11, §0.5
```
Page-specific layout that isn't reusable (e.g. the home hero's exact grid placement) may live in a
small `home.css` also imported by `home.ts` — but **all tokens and all shared components stay in
`styles.css`.** No page redefines a color or a font.

### 6.1 Shared nav + footer module (so all pages match)

Because this is a static multi-page site (no component framework), the nav and footer markup must be
**generated from one shared TS module**, not copy-pasted into each HTML file. Create
`web/src/chrome.ts`:
```ts
export function renderNav(active: "home"|"compatibility"|"research"|"announcements"): string
export function renderFooter(): string
export function mountChrome(active): void  // injects into <header id="nav"> and <footer id="footer">
```
Each page's HTML has `<header id="nav"></header>` and `<footer id="footer"></footer>` placeholders;
each page's TS entry calls `mountChrome("research")` etc. The theme toggle + mobile menu vanilla JS
also lives in `chrome.ts` so it's defined once. This is the single most important anti-drift
mechanism — **implementers must use it; do not inline nav/footer per page.**

(If an agent prefers fully static HTML for SEO of nav links, the alternative is a tiny build-time
partial-include; but the runtime `chrome.ts` approach is the spec because the site already boots TS
on every page and nav links are not primary SEO surfaces — the page `<title>`/`<h1>`/content are.)

---

## 7. Home page section list + order (the contract)

Pull all copy from `positioning.md` (§8 cheat-sheet, verbatim where listed), `announcement-draft.md`,
and `README.md`. All-lowercase, terse, builder voice. One exclamation max across the whole page.

1. **nav** (shared). brand + links + INSTALL CTA + theme toggle.
2. **hero.** eyebrow `LOCAL · ON-DEVICE · macOS`. h1 (display, may be UPPERCASE):
   **"you type the first half, it shows you the rest."** sub-line (`--t-body-lg`):
   *"autocomplete that never leaves your Mac."* + supporting line from positioning §1
   (*"a dim suggestion appears at your caret in almost any app, on your Mac and nowhere else."*).
   Primary CTA `INSTALL` (anchors to install block), secondary `.btn--blue` `VIEW SOURCE` → GitHub.
   The **live caret/ghost-text motif** (§5.11) renders the demo line here. A `.badge--alpha` near
   the heading ("ALPHA").
3. **the demo video.** the `web/public/demo/*.mp4` in a bordered `.card`, with `prefers-reduced-
   motion` → poster image, `autoplay muted loop playsinline` otherwise. Caption mono.
4. **how it works / privacy.** 3–4 `.cell`s on a `.cell-grid`: "everything on-device" (llama.cpp +
   GGUF), "password fields skipped" (denylist + secure-field), "the log is not a keylogger",
   "your files are yours". Each = kicker + title + 1–2 lines. Pull from positioning §4 (pair every
   privacy claim with its mechanism).
5. **the keys.** the Tab / backtick / esc / keep-typing legend as styled `.kbd` keycaps with one
   line each (from README table). Small, scannable, product-forward.
6. **the model lineup.** typer-1s (0.6B) / typer-1m (1.7B, first word 27ms) / typer-1l (4B, 57ms) as
   three `.card`s with TTFT on M2 Pro; note "both under the ~100ms feels-instant budget." Numbers
   from announcement-draft (real, measured — do not invent).
7. **compatibility matrix (preview).** a condensed `.matrix` of the headline app classes (native /
   electron / terminal / google docs) with status badges, + a `.btn--ghost` "see full
   compatibility →" linking to `/compatibility`. Honest: approximate = blue, known issue = red.
8. **QoL highlights.** a `.cell-grid` of the quality-of-life features (per-app instructions, snooze,
   completion-length, local personalization dial, emoji, typo-fix styling) — short, from
   announcement-draft §QoL. Mark anything not shipped as `PLANNED`.
9. **open-core offerings ladder.** the honesty centerpiece. rung 0 `card--feature` with `badge--now`
   ("free local core. forever."); rungs 1–4 as `card--planned` with `badge--planned`/`LATER`. Copy
   from positioning §5. **Never present a paid tier as available.**
10. **install.** the one-line `git clone … && ./install.sh` in a `.code` block with copy button;
    requirements line (macOS 14+, Apple Silicon recommended); link to README/CONTRIBUTING.
11. **FAQ.** `<details>` accordion: "is it really free?", "does anything leave my Mac?", "how do I
    update?", "why is install a git clone?" (tease signed DMG as coming), "what apps work?". Copy
    grounded in README/positioning.
12. **footer** (shared). geometric caret logo + motif + link columns + tagline
    *"free, forever · MIT · runs on llama.cpp · macOS 14+"*.

Other pages reuse the chrome + tokens:
- **/compatibility** — full `.matrix` (positioning §6), intro eyebrow + lead, honesty note, footer.
- **/research** — keep the existing rendering pipeline; restyle its shell to the shared chrome +
  `--maxw-prose` body type. Do not touch `web/research/posts/*.md` or the post-render logic.
- **/announcements** — keep the `ANNOUNCEMENTS.md` pipeline; restyle shell to shared chrome.
- **/v2** — leave untouched per brief (optionally restyle only its nav/footer to match if trivial).

---

## 8. Motion & reduced-motion (global rules)

- Allowed motion: caret blink (1s step-end), nav backdrop, button hover lift (120ms), accordion
  chevron rotate (150ms), the home hero typewriter, demo video.
- `@media (prefers-reduced-motion: reduce)`: disable caret blink (solid caret), typewriter renders
  final state instantly (full ghost line shown), accordion chevron snaps with no transition, demo
  video shows poster instead of autoplaying, no hover translate. Every animated element has a
  defined complete static state — the reduced-motion site is fully usable and shows the product.
- No scroll-jacking, no parallax, no entrance-on-scroll animations (they fight the technical tone
  and reduced-motion). Keep it calm.

---

## 9. Accessibility & SEO baseline (non-negotiable)

- Color contrast: all `--ink`/`--ink-2` on `--base`/`--base-2` ≥ 4.5:1 (verified for the chosen
  hexes). Status never conveyed by color alone — always a word.
- Focus-visible: `outline: 2px solid var(--blue); outline-offset: 2px` on all interactive elements.
- Real semantic landmarks: `<header><nav>`, `<main>`, `<footer>`; one `<h1>` per page; heading order
  not skipped.
- Per-page real `<title>` + `<meta name="description">` (positioning §7 keywords:
  "local autocomplete macos", "on-device text prediction mac", "cotypist alternative",
  "<app> autocomplete macos" on the matrix page). The matrix page is the long-tail SEO surface —
  give each app row real text.
- `prefers-reduced-motion` honored (§8). `prefers-color-scheme` honored on first load (§1.3).

---

## 10. What to build vs preserve (quick map for implementers)

REBUILD to this system: `web/index.html` + `web/src/home.ts` (+ new `web/src/home.css`),
`web/announcements.html`, `web/research.html` shells, and create `web/src/styles.css` +
`web/src/chrome.ts`. Add `/compatibility` (new `web/compatibility.html` + entry; register it in
`vite.config.ts` `rollupOptions.input` and add a clean-URL rule — coordinate with the build-config
owner).

PRESERVE (do not touch): `web/wrangler.jsonc`, `web/package.json`, `web/vite.config.ts` (except the
additive compatibility entry), `web/tsconfig*.json`, `web/public/**` (demo videos, favicon),
`web/research/posts/*.md` + the research render pipeline, the `ANNOUNCEMENTS.md`-reads-root
pipeline, and `web/v2.html` + `web/src/v2.ts`.

Build gate (every agent, after every change): `cd web && npm run build`. Never `npm run deploy`.

---

## 11. Cross-agent dependencies

- **All page implementers depend on this file + `web/src/styles.css` + `web/src/chrome.ts`** (the
  shared CSS/chrome owner must land those first, or the same agent lands them with the home page).
- **Compatibility page owner** depends on the matrix component (§5.7) and the build-config owner
  registering the new Vite entry + clean-URL rule.
- **Font owner**: whoever lands `styles.css` also drops the self-hosted woff2 in
  `web/public/fonts/` (or wires the Google Fonts `<link>` fallback). Don't ship `styles.css`
  referencing fonts that aren't present.
- Identity-color contract is frozen here: do not change `--blue`/`--green` hexes without updating
  this file and the brand (dark values must stay `#6ea8ff` / `#5fd081`).
