// The announcements feed comes from ANNOUNCEMENTS.md at the repo root — that
// file is the single source of truth (format spec lives in a comment at its
// top). The page fetches it live from GitHub on every load, so pushing to main
// publishes; the copy Vite inlines at build time renders instantly and covers
// fetch failures (offline, rate-limited, GitHub down).
import "./styles.css";
import { mountChrome } from "./shell.ts";
import baked from "../../ANNOUNCEMENTS.md?raw";

mountChrome("announcements");

const LIVE_URL = "https://raw.githubusercontent.com/frgmt0/typer/main/ANNOUNCEMENTS.md";

type Entry = { date: string; title: string; bodyHtml: string };

const MONTHS = [
  "jan", "feb", "mar", "apr", "may", "jun",
  "jul", "aug", "sep", "oct", "nov", "dec",
];

function prettyDate(iso: string): string {
  const [y, m, d] = iso.split("-").map(Number);
  return `${MONTHS[m - 1]} ${d}, ${y}`;
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Inline markdown subset: ``code``, `code`, **bold**, [text](url).
function inline(s: string): string {
  return escapeHtml(s)
    .replace(/``\s?(.+?)\s?``/g, "<code>$1</code>")
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>');
}

// Block structure: paragraphs separated by blank lines; consecutive "- " lines
// form a list. Anything else in the spec is disallowed, so this is the whole grammar.
function blocks(body: string): string {
  const out: string[] = [];
  let list: string[] = [];
  const flushList = () => {
    if (list.length) out.push(`<ul>${list.map((li) => `<li>${inline(li)}</li>`).join("")}</ul>`);
    list = [];
  };
  for (const para of body.split(/\n{2,}/)) {
    const lines = para.split("\n").map((l) => l.trim()).filter(Boolean);
    if (!lines.length) continue;
    for (const line of lines) {
      if (line.startsWith("- ")) {
        list.push(line.slice(2));
      } else {
        flushList();
        out.push(`<p>${inline(line)}</p>`);
      }
    }
    flushList();
  }
  return out.join("");
}

function parse(md: string): Entry[] {
  const entries: Entry[] = [];
  // Strip the HTML comment holding the format spec, then split on H2s.
  const clean = md.replace(/<!--[\s\S]*?-->/g, "");
  const sections = clean.split(/^## /m).slice(1);
  for (const section of sections) {
    const nl = section.indexOf("\n");
    const header = section.slice(0, nl).trim();
    const m = header.match(/^(\d{4}-\d{2}-\d{2}) — (.+)$/);
    if (!m) continue; // not an entry per the spec — ignored
    entries.push({ date: m[1], title: m[2], bodyHtml: blocks(section.slice(nl + 1).trim()) });
  }
  return entries;
}

// Page-local styles for the rendered feed. These compose the shared design tokens
// (defined in styles.css) — no new colors/fonts are decided here. Injected once.
const FEED_STYLES = `
  #feed { max-width: var(--maxw-prose); }
  #feed .empty { color: var(--ink-3); font-family: var(--font-mono); }
  #feed .ann-body p { color: var(--ink-2); margin: 0 0 var(--sp-4); line-height: 1.7; }
  #feed .ann-body p:last-child { margin-bottom: 0; }
  #feed .ann-body strong { color: var(--ink); font-weight: 700; }
  #feed .ann-body ul { margin: 0 0 var(--sp-4); padding-left: 0; list-style: none; }
  #feed .ann-body li { color: var(--ink-2); margin-bottom: var(--sp-2); padding-left: 1.5ch; position: relative; line-height: 1.65; }
  #feed .ann-body li::before { content: "—"; position: absolute; left: 0; color: var(--blue); }
  #feed .ann-body code {
    font-family: var(--font-mono); font-size: 0.9em; color: var(--ink);
    background: var(--base-2); border: 1px solid var(--rule); border-radius: var(--radius);
    padding: 0.05em 0.4ch;
  }

  /* featured (latest) entry — bordered card with the green accept-rail */
  #feed .ann-featured {
    border: 1px solid var(--rule);
    border-left: 2px solid var(--green);
    border-radius: var(--radius);
    padding: var(--sp-6);
    background: var(--base);
    margin-bottom: var(--sp-6);
  }
  #feed .ann-meta { display: flex; align-items: center; gap: var(--sp-3); margin: 0 0 var(--sp-4); flex-wrap: wrap; }
  #feed .ann-featured h2 { font-size: var(--t-h3); line-height: 1.3; margin: 0 0 var(--sp-4); }
  #feed time {
    font-family: var(--font-mono); font-size: var(--t-label); text-transform: uppercase;
    letter-spacing: 0.06em; color: var(--ink-3);
  }

  /* collapsed history — ruled rows that open in place */
  #feed .ann-entry { border-bottom: 1px solid var(--rule); }
  #feed .ann-entry:first-of-type { border-top: 1px solid var(--rule); }
  #feed .ann-entry > summary {
    display: flex; align-items: baseline; gap: var(--sp-4);
    cursor: pointer; padding: var(--sp-4) 0; list-style: none;
  }
  #feed .ann-entry > summary::-webkit-details-marker { display: none; }
  #feed .ann-entry > summary time { flex-shrink: 0; width: 12ch; }
  #feed .ann-entry-title { font-family: var(--font-display); font-weight: 700; color: var(--ink-2); letter-spacing: -0.01em; }
  #feed .ann-entry > summary:hover .ann-entry-title { color: var(--ink); }
  #feed .ann-entry[open] .ann-entry-title { color: var(--ink); }
  #feed .ann-chev { margin-left: auto; color: var(--ink-3); font-family: var(--font-mono); transition: transform 150ms ease; }
  #feed .ann-entry[open] .ann-chev { transform: rotate(90deg); display: inline-block; }
  #feed .ann-entry .ann-body { padding: 0 0 var(--sp-5); }
  @media (min-width: 560px) { #feed .ann-entry .ann-body { padding-left: calc(12ch + var(--sp-4)); } }
  @media (prefers-reduced-motion: reduce) { #feed .ann-chev { transition: none; } }
`;

const feedStyleEl = document.createElement("style");
feedStyleEl.textContent = FEED_STYLES;
document.head.appendChild(feedStyleEl);

const feed = document.getElementById("feed")!;

function render(entries: Entry[]): void {
  if (!entries.length) {
    feed.innerHTML = `<p class="empty">nothing announced yet — check the <a href="https://github.com/frgmt0/typer/blob/main/CHANGELOG.md" target="_blank" rel="noopener">changelog</a>.</p>`;
    return;
  }
  const [latest, ...older] = entries;
  feed.innerHTML = `
    <article class="ann-featured">
      <p class="ann-meta"><span class="badge badge--now">latest</span><time datetime="${latest.date}">${prettyDate(latest.date)}</time></p>
      <h2>${inline(latest.title)}</h2>
      <div class="ann-body">${latest.bodyHtml}</div>
    </article>
    ${older
      .map(
        (e) => `
    <details class="ann-entry">
      <summary>
        <time datetime="${e.date}">${prettyDate(e.date)}</time>
        <span class="ann-entry-title">${inline(e.title)}</span>
        <span class="ann-chev" aria-hidden="true">▸</span>
      </summary>
      <div class="ann-body">${e.bodyHtml}</div>
    </details>`,
      )
      .join("")}
  `;
}

// Paint the baked copy immediately, then swap in the live file if it differs.
render(parse(baked));

(async () => {
  try {
    const res = await fetch(LIVE_URL, { cache: "no-store" });
    if (!res.ok) return;
    const live = await res.text();
    if (live === baked) return;
    const entries = parse(live);
    if (entries.length) render(entries); // an unparseable live file never blanks the page
  } catch {
    // offline / blocked — the baked copy is already on screen
  }
})();
