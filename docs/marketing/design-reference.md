# Web revamp — design reference (greptile-grounded, typer-owned)

Goal: rebuild typr.frgmt.xyz to feel like a **professional, modern dev-tool SaaS site** in the
spirit of greptile.com — but it is typer's site, not a greptile clone. Adapt the *structure,
polish, and rigor*; keep typer's own identity and honesty (open-source, local-first).

## What was extracted from greptile.com (verified from their live CSS + a rendered screenshot)
- **Type:** display = `Anybody` (bold, slightly condensed grotesque, often UPPERCASE for headings);
  body = `DM Sans`; mono/labels = `Space Mono` / `Geist Mono`; a `Nanum Pen Script` handwritten
  accent used sparingly. Big hero type (clamp up to ~6rem).
- **Color:** near-white base `#EEEEEE`/`#FFFFFF`; ink `#3D3B4F` / `#555368` / black; bright accents
  used sparingly — green `#28E99F` (primary CTA), lime `#DAFF01`, mint `#C5FFD6`, pink `#FFCFFE`,
  blue `#5882FF`, coral `#FF7F59`. Light theme primary with a dark-mode toggle.
- **Shape:** very small radius (`2px`–`.25rem`) → sharp, technical. Thin 1px rules everywhere.
- **Signature layout:** a faint **blueprint grid** — hairline vertical + horizontal rules dividing
  the page into columns/cells — sits behind everything. Content is bordered cards/cells on that grid.
- **Footer:** geometric cube logo + an isometric keycap/3D pattern motif; dense link columns in mono.
- **Pricing:** two clean bordered cards (a fixed price + "Custom"), bullet lists, green CTAs, FAQ
  accordion below.

## typer adaptation rules (do NOT just recolor greptile)
- **Keep typer's signature:** the live-caret **blue** and the green "accept" remain typer's identity.
  Use a restrained palette: ink + off-white base, ONE primary accent for CTAs, blue for the
  caret/live motif, green for "accept/success". Avoid the full candy rainbow — pick 2 accents max so
  it reads premium, not busy. Do not copy greptile's exact lime+pink combo verbatim.
- **Adopt the structure:** blueprint-grid background, bold display headings (a free Google font in the
  Anybody/Space-Grotesk family + DM Sans body + a mono), sharp 2px corners, thin rules, bordered
  cells, generous whitespace, a real nav and a real footer.
- **Honesty stays:** the offerings/pricing section marks `free local core = now, forever` and
  everything else `planned`/`later` (see the just-shipped homepage). Never present a paid tier as
  available. The compatibility matrix labels approximate cases as approximate.
- **Lightweight stack:** keep it a static Vite multi-page site (no React/Next). Self-host or Google-
  Fonts the typefaces. Respect `prefers-reduced-motion` and keep a static fallback (the current site
  does this well — preserve that discipline).

## Content & positioning (reuse, don't reinvent)
Pull copy/positioning from `docs/marketing/positioning.md`, `docs/overhaul-spec.md` §I, `README.md`,
and the just-written `docs/marketing/announcement-draft.md`. Sections the home page should have:
hero (one-line value prop + install CTA + demo video), how-it-works/privacy, the model lineup
(typer-1s/1m/1l with TTFT), per-app caret **compatibility matrix**, the QoL feature highlights, the
open-core **offerings** ladder (honest now/planned/later), and a footer.

## Reference assets on disk
- Screenshot: `scratchpad/greptile/greptile-pricing.png` (rendered) — study the grid + cards + footer.
- Raw CSS tokens: `scratchpad/greptile/all.css`; raw home markup: `scratchpad/greptile/home.html`.

## Preserve (do NOT delete — only the presentation layer is being rebuilt)
- `web/wrangler.jsonc`, `web/package.json`, `web/vite.config.ts`, `web/tsconfig*.json` (build+deploy)
- `web/public/**` (demo videos `typer-demo-*.mp4`, posters, favicon)
- `web/research/posts/*.md` (research content) and the research-page rendering pipeline
- the announcements pipeline that reads the repo-root `ANNOUNCEMENTS.md`
Rebuild/replace: `web/index.html`, `web/src/home.ts`, and the page shells/styles for
`announcements` + `research` so all pages share ONE new design system (nav, footer, grid, tokens).
Leave `web/v2.html` + `web/src/v2.ts` (the unlinked /v2 campaign page) untouched unless trivially
restyling the nav/footer to match.
