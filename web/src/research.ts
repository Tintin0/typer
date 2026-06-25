// The research section is the single source of truth for academic posts. Every post
// is one Markdown file in web/research/posts/*.md with YAML-ish front-matter
// (slug, title, date, authors, abstract) followed by GitHub-flavored Markdown that may
// contain inline math $...$, block math $$...$$, ```chart fenced JSON blocks, tables,
// and fenced code. Dropping a new .md file into that directory publishes a new post —
// no code change is required, because the directory is globbed at build time.
//
// One entry script serves two routes:
//   /research          -> a newest-first index of every post
//   /research/<slug>   -> the full rendered post for that slug
// The route is decided from location.pathname so the same bundle works whether it was
// reached via research.html (the index) or the SPA fallback (a nested slug path).

import "./styles.css";
import { mountChrome } from "./shell.ts";
import { marked } from "marked";
import katex from "katex";
import "katex/dist/katex.min.css";

mountChrome("research");

// Eagerly glob every post as raw text. Vite inlines these at build time, so the set of
// posts is fixed in the bundle and adding a file is the only step needed to publish.
const rawPosts = import.meta.glob("../research/posts/*.md", {
  query: "?raw",
  import: "default",
  eager: true,
}) as Record<string, string>;

type Post = {
  slug: string;
  title: string;
  date: string;
  authors: string;
  abstract: string;
  body: string;
};

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December",
];

function prettyDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  if (!y || !m || !d) return iso;
  return `${MONTHS[m - 1]} ${d}, ${y}`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Parse the leading `---` front-matter. Values are simple `key: value`, with support
// for YAML folded scalars (`>` then an indented block) used by `abstract`.
function parseFrontMatter(raw: string): { meta: Record<string, string>; body: string } {
  const text = raw.replace(/^﻿/, "");
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { meta: {}, body: text };

  const meta: Record<string, string> = {};
  const lines = m[1].split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const kv = line.match(/^([A-Za-z0-9_-]+):\s?(.*)$/);
    if (!kv) continue;
    const key = kv[1];
    let value = kv[2];

    // Folded (`>`) or literal (`|`) scalar: consume the following indented lines.
    if (value === ">" || value === "|" || value === ">-" || value === "|-") {
      const collected: string[] = [];
      while (i + 1 < lines.length && /^\s+\S/.test(lines[i + 1])) {
        collected.push(lines[++i].replace(/^\s+/, ""));
      }
      value = value.startsWith(">") ? collected.join(" ") : collected.join("\n");
    }
    meta[key] = value.trim();
  }
  return { meta, body: m[2] };
}

function loadPosts(): Post[] {
  const posts: Post[] = [];
  for (const [path, raw] of Object.entries(rawPosts)) {
    const { meta, body } = parseFrontMatter(raw);
    const fallbackSlug = path.split("/").pop()!.replace(/\.md$/, "");
    posts.push({
      slug: meta.slug || fallbackSlug,
      title: meta.title || fallbackSlug,
      date: meta.date || "",
      authors: meta.authors || "",
      abstract: meta.abstract || "",
      body,
    });
  }
  // Newest first; fall back to slug for stable ordering when dates tie or are absent.
  posts.sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : a.slug < b.slug ? 1 : -1));
  return posts;
}

// ---- chart rendering -------------------------------------------------------
// Lightweight hand-rolled responsive SVG bars. Two shapes are supported:
//   single-series: { data:[{label,value,highlight?}] }
//   grouped:       { series:[...], data:[{label,values:[...]}] }
// No charting dependency; the SVG scales with its container via viewBox.

type ChartSpec = {
  type?: string;
  title?: string;
  unit?: string;
  note?: string;
  series?: string[];
  data: Array<{ label: string; value?: number; values?: number[]; highlight?: boolean }>;
};

const SERIES_FILLS = ["var(--blue)", "var(--green)", "var(--ink-3)", "var(--ghost)"];

function renderChart(spec: ChartSpec): string {
  const data = spec.data || [];
  const unit = spec.unit ? escapeHtml(spec.unit) : "";
  const grouped = Array.isArray(spec.series) && spec.series.length > 0;

  // Geometry in an abstract viewBox; CSS handles responsive scaling.
  const allValues = grouped
    ? data.flatMap((d) => d.values || [])
    : data.map((d) => d.value ?? 0);
  const maxVal = Math.max(1, ...allValues);
  const niceMax = Math.ceil(maxVal / 10) * 10 || maxVal;

  const W = 720;
  const rowH = grouped ? 58 : 40;
  const padTop = 8;
  const padBottom = 28;
  const labelW = 190;
  const valueW = 52;
  const trackX = labelW;
  const trackW = W - labelW - valueW;
  const H = padTop + data.length * rowH + padBottom;

  const x = (v: number) => trackX + (v / niceMax) * trackW;

  const gridlines: string[] = [];
  for (let g = 0; g <= niceMax; g += niceMax / 4) {
    const gx = x(g);
    gridlines.push(
      `<line x1="${gx}" y1="${padTop}" x2="${gx}" y2="${H - padBottom}" class="ch-grid"/>` +
        `<text x="${gx}" y="${H - padBottom + 18}" class="ch-axis" text-anchor="middle">${Math.round(g)}${unit}</text>`,
    );
  }

  const bars: string[] = [];
  data.forEach((d, i) => {
    const rowY = padTop + i * rowH;
    const label = escapeHtml(d.label);

    if (grouped) {
      const vals = d.values || [];
      const n = vals.length || 1;
      const gap = 6;
      const barH = (rowH - 16 - gap * (n - 1)) / n;
      vals.forEach((v, s) => {
        const by = rowY + 4 + s * (barH + gap);
        const bw = Math.max(2, x(v) - trackX);
        bars.push(
          `<rect x="${trackX}" y="${by}" width="${bw}" height="${barH}" rx="3" fill="${SERIES_FILLS[s % SERIES_FILLS.length]}"/>` +
            `<text x="${trackX + bw + 8}" y="${by + barH / 2}" class="ch-val" dominant-baseline="middle">${v}${unit}</text>`,
        );
      });
      bars.push(
        `<text x="${trackX - 12}" y="${rowY + rowH / 2 - 4}" class="ch-label" text-anchor="end" dominant-baseline="middle">${label}</text>`,
      );
    } else {
      const v = d.value ?? 0;
      const by = rowY + 6;
      const barH = rowH - 16;
      const bw = Math.max(2, x(v) - trackX);
      const fill = d.highlight ? "var(--blue)" : "var(--ghost)";
      bars.push(
        `<rect x="${trackX}" y="${by}" width="${bw}" height="${barH}" rx="3" fill="${fill}"${d.highlight ? ' class="ch-hi"' : ""}/>` +
          `<text x="${trackX - 12}" y="${by + barH / 2}" class="ch-label${d.highlight ? " ch-label-hi" : ""}" text-anchor="end" dominant-baseline="middle">${label}</text>` +
          `<text x="${trackX + bw + 8}" y="${by + barH / 2}" class="ch-val${d.highlight ? " ch-val-hi" : ""}" dominant-baseline="middle">${v}${unit}</text>`,
      );
    }
  });

  let legend = "";
  if (grouped) {
    legend =
      `<div class="ch-legend">` +
      spec.series!
        .map(
          (s, i) =>
            `<span class="ch-leg"><span class="ch-swatch" style="background:${SERIES_FILLS[i % SERIES_FILLS.length]}"></span>${escapeHtml(s)}</span>`,
        )
        .join("") +
      `</div>`;
  }

  return (
    `<figure class="chart">` +
    (spec.title ? `<figcaption class="ch-title">${escapeHtml(spec.title)}</figcaption>` : "") +
    legend +
    `<svg viewBox="0 0 ${W} ${H}" role="img" preserveAspectRatio="xMidYMid meet"${spec.title ? ` aria-label="${escapeHtml(spec.title)}"` : ""}>` +
    `<line x1="${trackX}" y1="${padTop}" x2="${trackX}" y2="${H - padBottom}" class="ch-axisline"/>` +
    gridlines.join("") +
    bars.join("") +
    `</svg>` +
    (spec.note ? `<figcaption class="ch-note">${escapeHtml(spec.note)}</figcaption>` : "") +
    `</figure>`
  );
}

// ---- math ------------------------------------------------------------------
// We render KaTeX ourselves before handing text to marked, swapping each math span for
// an inert placeholder so Markdown processing can't mangle TeX (e.g. `_` or `\\`),
// then restoring the rendered HTML afterwards. Placeholders are non-Markdown tokens.

const mathStore: string[] = [];

function stashMath(html: string): string {
  mathStore.push(html);
  return `@@MATH${mathStore.length - 1}@@`;
}

function protectMathAndCharts(src: string): string {
  // Pull out ```chart blocks first (they contain JSON, not Markdown).
  src = src.replace(/```chart\s*\n([\s\S]*?)```/g, (_m, json) => {
    try {
      const spec = JSON.parse(json) as ChartSpec;
      return "\n\n" + stashMath(renderChart(spec)) + "\n\n";
    } catch {
      return "\n\n```\n" + json.trim() + "\n```\n\n";
    }
  });

  // Block math $$...$$ (may span lines). Render in display mode.
  src = src.replace(/\$\$([\s\S]+?)\$\$/g, (_m, tex) => {
    try {
      return stashMath(
        `<div class="math-block">${katex.renderToString(tex.trim(), { displayMode: true, throwOnError: false })}</div>`,
      );
    } catch {
      return _m;
    }
  });

  // Inline math $...$ — avoid matching $$ (already handled) and bare dollar amounts by
  // requiring a non-space adjacent to the delimiters and no newline inside.
  src = src.replace(/(^|[^$\\])\$(?!\s)([^\n$]+?)(?<!\s)\$(?!\$)/g, (_m, pre, tex) => {
    try {
      return pre + stashMath(katex.renderToString(tex, { displayMode: false, throwOnError: false }));
    } catch {
      return _m;
    }
  });

  return src;
}

function restoreMath(html: string): string {
  return html.replace(/@@MATH(\d+)@@/g, (_m, i) => mathStore[Number(i)] ?? "");
}

function renderMarkdown(body: string): string {
  mathStore.length = 0;
  const protectedSrc = protectMathAndCharts(body);
  marked.setOptions({ gfm: true, breaks: false });
  let html = marked.parse(protectedSrc, { async: false }) as string;
  // Wrap tables so wide ones scroll horizontally on mobile instead of overflowing.
  html = html.replace(/<table>/g, '<div class="table-wrap"><table>').replace(/<\/table>/g, "</table></div>");
  // A block placeholder (chart / display math) on its own line gets wrapped by marked as
  // <p>@@MATHn@@</p>; lift it out of the paragraph so the block element is a clean sibling.
  html = html.replace(/<p>\s*(@@MATH\d+@@)\s*<\/p>/g, "$1");
  html = restoreMath(html);
  // Drop any stray empty paragraphs marked may emit next to a block.
  html = html.replace(/<p>\s*<\/p>/g, "");
  return html;
}

// ---- page-local styles -----------------------------------------------------
// Compose the shared design tokens (styles.css) for the research index + paper
// layout, math, tables, code, and the hand-rolled SVG charts. No new colors or
// fonts are decided here; everything references the shared :root tokens.
const RESEARCH_STYLES = `
  #research { max-width: 78ch; }
  #research .empty { color: var(--ink-3); font-family: var(--font-mono); }
  #research time {
    font-family: var(--font-mono); font-size: var(--t-label); text-transform: uppercase;
    letter-spacing: 0.06em; color: var(--ink-3);
  }
  #research .authors { font-family: var(--font-mono); font-size: var(--t-small); color: var(--ink-3); }

  /* ---- index listing ---- */
  #research .rpost-card { border-top: 1px solid var(--rule); padding: var(--sp-6) 0; }
  #research .rpost-card:last-child { border-bottom: 1px solid var(--rule); }
  #research .rpost-card .meta { display: flex; align-items: center; gap: var(--sp-3); margin: 0 0 var(--sp-3); flex-wrap: wrap; }
  #research .rpost-card h2 { font-size: var(--t-h3); line-height: 1.3; margin: 0 0 var(--sp-3); }
  #research .rpost-card h2 a { color: var(--ink); }
  #research .rpost-card h2 a:hover { color: var(--blue); text-decoration: none; }
  #research .rpost-card .abstract { color: var(--ink-2); margin: 0 0 var(--sp-3); line-height: 1.7; }
  #research .rpost-card .readlink a { font-family: var(--font-mono); font-size: var(--t-small); font-weight: 700; }

  /* ---- single paper ---- */
  #research .paper { padding-top: 0; }
  #research .backlink { margin: 0 0 var(--sp-7); }
  #research .backlink a, #research .paper-foot a { font-family: var(--font-mono); font-size: var(--t-small); color: var(--ink-3); }
  #research .backlink a:hover, #research .paper-foot a:hover { color: var(--ink); }
  #research .paper-head { margin-bottom: var(--sp-7); }
  #research .paper-head .meta { display: flex; align-items: center; gap: var(--sp-3); margin: 0 0 var(--sp-4); flex-wrap: wrap; }
  #research .paper-head h1 { font-size: var(--t-h2); line-height: 1.15; margin: 0 0 var(--sp-5); }
  #research .paper-head .abstract {
    color: var(--ink-2); line-height: 1.7; margin: 0;
    padding-left: var(--sp-4); border-left: 2px solid var(--blue);
  }
  #research .abstract-label { color: var(--ink); font-weight: 700; }

  /* long-form body */
  #research .paper-body { line-height: 1.8; color: var(--ink-2); }
  #research .paper-body h2 { font-size: var(--t-h3); margin: var(--sp-8) 0 var(--sp-4); }
  #research .paper-body h3 { font-size: var(--t-h4); margin: var(--sp-6) 0 var(--sp-3); }
  #research .paper-body h4 {
    font-family: var(--font-mono); font-size: var(--t-small); font-weight: 700;
    text-transform: uppercase; letter-spacing: 0.06em; color: var(--ink-3);
    margin: var(--sp-5) 0 var(--sp-2);
  }
  #research .paper-body p { color: var(--ink-2); margin: 0 0 var(--sp-4); }
  #research .paper-body strong { color: var(--ink); font-weight: 700; }
  #research .paper-body a { color: var(--blue); }
  #research .paper-body ul, #research .paper-body ol { color: var(--ink-2); margin: 0 0 var(--sp-4); padding-left: 2.2ch; }
  #research .paper-body li { margin-bottom: var(--sp-2); }
  #research .paper-body li::marker { color: var(--blue); }
  #research .paper-body blockquote {
    margin: var(--sp-5) 0; padding-left: var(--sp-4);
    border-left: 2px solid var(--rule-strong); color: var(--ink-3);
  }
  #research .paper-body hr { border: none; border-top: 1px solid var(--rule); margin: var(--sp-7) 0; }

  /* fenced code */
  #research .paper-body pre {
    background: var(--base-2); border: 1px solid var(--rule); border-radius: var(--radius);
    padding: var(--sp-4) var(--sp-5); overflow-x: auto; margin: var(--sp-5) 0; line-height: 1.6;
  }
  #research .paper-body pre code {
    color: var(--ink); border: none; background: none; padding: 0;
    font-family: var(--font-mono); font-size: var(--t-code); white-space: pre;
  }
  #research .paper-body :not(pre) > code {
    font-family: var(--font-mono); font-size: 0.9em; color: var(--ink);
    background: var(--base-2); border: 1px solid var(--rule); border-radius: var(--radius);
    padding: 0.05em 0.4ch; word-break: break-word;
  }

  /* tables */
  #research .paper-body .table-wrap { overflow-x: auto; margin: var(--sp-5) 0; }
  #research .paper-body table {
    border-collapse: collapse; width: 100%;
    font-family: var(--font-mono); font-size: var(--t-code); border: 1px solid var(--rule);
  }
  #research .paper-body th {
    text-align: left; font-weight: 700; color: var(--ink);
    padding: var(--sp-3) var(--sp-4); border-bottom: 1px solid var(--rule-strong);
    background: var(--base-2); white-space: nowrap;
  }
  #research .paper-body td {
    padding: var(--sp-2) var(--sp-4); color: var(--ink-2); border-bottom: 1px solid var(--rule);
  }
  #research .paper-body tbody tr:last-child td { border-bottom: none; }
  #research .paper-body td strong, #research .paper-body th strong { color: var(--ink); }

  /* math */
  #research .math-block { margin: var(--sp-5) 0; overflow-x: auto; overflow-y: hidden; padding: 0.2rem 0; }
  #research .math-block .katex-display { margin: 0; }
  #research .paper-body .katex { color: var(--ink); }

  /* charts (SVG built by the renderer) */
  #research .chart { margin: var(--sp-6) 0; padding: var(--sp-4) 0 var(--sp-3); border-top: 1px solid var(--rule); border-bottom: 1px solid var(--rule); }
  #research .ch-title { font-family: var(--font-display); font-size: var(--t-small); font-weight: 700; color: var(--ink); margin: 0 0 var(--sp-4); line-height: 1.4; }
  #research .chart svg { display: block; width: 100%; height: auto; }
  #research .ch-grid { stroke: var(--rule); stroke-width: 1; }
  #research .ch-axisline { stroke: var(--rule-strong); stroke-width: 1; }
  #research .ch-axis { fill: var(--ink-3); font-family: var(--font-mono); font-size: 11px; }
  #research .ch-label { fill: var(--ink-2); font-family: var(--font-mono); font-size: 12px; }
  #research .ch-label-hi { fill: var(--ink); font-weight: 700; }
  #research .ch-val { fill: var(--ink-3); font-family: var(--font-mono); font-size: 12px; }
  #research .ch-val-hi { fill: var(--blue); font-weight: 700; }
  #research .ch-legend { display: flex; flex-wrap: wrap; gap: var(--sp-2) var(--sp-5); margin: 0 0 var(--sp-4); }
  #research .ch-leg { display: inline-flex; align-items: center; gap: 0.5ch; font-family: var(--font-mono); font-size: 12px; color: var(--ink-2); }
  #research .ch-swatch { width: 10px; height: 10px; border-radius: var(--radius); display: inline-block; }
  #research .ch-note { font-family: var(--font-mono); font-size: 12px; color: var(--ink-3); margin: var(--sp-3) 0 0; line-height: 1.55; }

  #research .paper-foot { margin-top: var(--sp-8); padding-top: var(--sp-5); border-top: 1px solid var(--rule); }
`;

const researchStyleEl = document.createElement("style");
researchStyleEl.textContent = RESEARCH_STYLES;
document.head.appendChild(researchStyleEl);

// On a single-post route the page has its own paper header (date/title/abstract),
// so collapse the index hero to avoid a duplicate "research" heading.
function hideIndexHero(): void {
  const hero = document.getElementById("research-hero");
  if (hero) hero.style.display = "none";
}

// ---- views -----------------------------------------------------------------

// The slug can arrive two ways: as a clean path /research/<slug> (dev, and the SPA
// fallback before it redirects), or as /research?p=<slug> (the production deep-link
// hand-off from index.html). Either resolves to the same post.
function slugFromPath(): string | null {
  const m = location.pathname.match(/^\/research\/([^/?#]+)\/?$/);
  if (m) return decodeURIComponent(m[1]);
  const q = new URLSearchParams(location.search).get("p");
  return q || null;
}

function renderIndex(root: HTMLElement, posts: Post[]): void {
  document.title = "typr — research";
  if (!posts.length) {
    root.innerHTML = `<p class="empty">no research posts yet.</p>`;
    return;
  }
  root.innerHTML = posts
    .map(
      (p) => `
    <article class="rpost-card">
      <p class="meta">
        <time datetime="${escapeHtml(p.date)}">${prettyDate(p.date)}</time>
        ${p.authors ? `<span class="authors">${escapeHtml(p.authors)}</span>` : ""}
      </p>
      <h2><a href="/research/${encodeURIComponent(p.slug)}">${escapeHtml(p.title)}</a></h2>
      ${p.abstract ? `<p class="abstract">${escapeHtml(p.abstract)}</p>` : ""}
      <p class="readlink"><a href="/research/${encodeURIComponent(p.slug)}">read the paper →</a></p>
    </article>`,
    )
    .join("");
}

function renderPost(root: HTMLElement, post: Post): void {
  document.title = `${post.title} — typr research`;
  hideIndexHero();
  // Normalize the address bar to the canonical clean URL even when we arrived via the
  // ?p= query hand-off, so links copied from the page are the pretty form.
  if (location.search) {
    try {
      history.replaceState(null, "", `/research/${encodeURIComponent(post.slug)}`);
    } catch {
      /* sandboxed contexts may forbid replaceState; cosmetic only */
    }
  }
  const meta = document.querySelector('meta[name="description"]');
  if (meta && post.abstract) meta.setAttribute("content", post.abstract.slice(0, 300));

  root.innerHTML = `
    <article class="paper">
      <p class="backlink"><a href="/research">← all research</a></p>
      <header class="paper-head">
        <p class="meta">
          <time datetime="${escapeHtml(post.date)}">${prettyDate(post.date)}</time>
          ${post.authors ? `<span class="authors">${escapeHtml(post.authors)}</span>` : ""}
        </p>
        <h1>${escapeHtml(post.title)}</h1>
        ${post.abstract ? `<p class="abstract"><span class="abstract-label">Abstract.</span> ${escapeHtml(post.abstract)}</p>` : ""}
      </header>
      <div class="paper-body">${renderMarkdown(post.body)}</div>
      <footer class="paper-foot"><a href="/research">← all research</a></footer>
    </article>`;
}

function main(): void {
  const root = document.getElementById("research")!;
  const posts = loadPosts();
  const slug = slugFromPath();

  if (slug) {
    const post = posts.find((p) => p.slug === slug);
    if (post) {
      renderPost(root, post);
      return;
    }
    // Unknown slug: show the index with a small notice rather than a blank page.
    root.innerHTML = `<p class="empty">no post named “${escapeHtml(slug)}”. here is everything we’ve published:</p>`;
    const list = document.createElement("div");
    renderIndex(list, posts);
    root.appendChild(list);
    return;
  }

  renderIndex(root, posts);
}

main();
