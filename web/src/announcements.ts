// The announcements feed comes from ANNOUNCEMENTS.md at the repo root — that
// file is the single source of truth (format spec lives in a comment at its
// top). The page fetches it live from GitHub on every load, so pushing to main
// publishes; the copy Vite inlines at build time renders instantly and covers
// fetch failures (offline, rate-limited, GitHub down).
import baked from "../../ANNOUNCEMENTS.md?raw";

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

const feed = document.getElementById("feed")!;

function render(entries: Entry[]): void {
  if (!entries.length) {
    feed.innerHTML = `<p class="empty">nothing announced yet — check the <a href="https://github.com/frgmt0/typer/blob/main/CHANGELOG.md">changelog</a>.</p>`;
    return;
  }
  const [latest, ...older] = entries;
  feed.innerHTML = `
    <article class="featured">
      <p class="meta"><span class="tag">latest</span><time datetime="${latest.date}">${prettyDate(latest.date)}</time></p>
      <h2>${inline(latest.title)}</h2>
      <div class="body">${latest.bodyHtml}</div>
    </article>
    ${older
      .map(
        (e) => `
    <details class="entry">
      <summary>
        <time datetime="${e.date}">${prettyDate(e.date)}</time>
        <span class="entry-title">${inline(e.title)}</span>
        <span class="chev" aria-hidden="true">▸</span>
      </summary>
      <div class="body">${e.bodyHtml}</div>
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
