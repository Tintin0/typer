/* ==========================================================================
   typer — shared site chrome (nav + footer + theme + mobile menu)
   The single anti-drift source: every page calls mountChrome(active).
   Spec: docs/marketing/design-system.md §5.5, §5.6, §6.1, §7.4.
   ========================================================================== */

export type ActivePage = "home" | "compatibility" | "research" | "announcements" | "";

const GITHUB_URL = "https://github.com/frgmt0/typer";

/* ---- the geometric caret/cursor-block logo mark (typer's "cube") ---------- */
/* a filled cursor block + a thin blinking caret bar, in --blue. Reused at all
   sizes; pass a class for sizing. The bar carries the brand's "live caret". */
export function logoMark(cls = "mark"): string {
  return `<svg class="${cls}" viewBox="0 0 32 32" fill="none" aria-hidden="true" focusable="false">
  <rect x="3" y="6" width="16" height="20" rx="1" fill="var(--blue)"/>
  <rect x="23" y="3" width="3" height="26" rx="1" fill="var(--blue)"/>
  <rect x="7.5" y="11" width="7" height="2" rx="1" fill="var(--base)"/>
  <rect x="7.5" y="15" width="7" height="2" rx="1" fill="var(--base)"/>
  <rect x="7.5" y="19" width="4" height="2" rx="1" fill="var(--base)"/>
</svg>`;
}

/* ---- icons ---------------------------------------------------------------- */
const iconMoon = `<svg class="icon-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>`;
const iconSun = `<svg class="icon-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M19 5l-1.5 1.5M6.5 17.5 5 19"/></svg>`;
const iconBurger = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M3 6h18M3 12h18M3 18h18"/></svg>`;

/* ---- nav links (single source) -------------------------------------------- */
const NAV_LINKS: { key: ActivePage; label: string; href: string; external?: boolean }[] = [
  { key: "compatibility", label: "compatibility", href: "/compatibility" },
  { key: "research", label: "research", href: "/research" },
  { key: "announcements", label: "announcements", href: "/announcements" },
  { key: "", label: "github", href: GITHUB_URL, external: true },
];

export function renderNav(active: ActivePage = ""): string {
  const links = NAV_LINKS.map((l) => {
    const cur = l.key && l.key === active ? ` aria-current="page"` : "";
    const ext = l.external ? ` target="_blank" rel="noopener"` : "";
    return `<li><a class="nav__link" href="${l.href}"${cur}${ext}>${l.label}</a></li>`;
  }).join("");

  return `<nav class="nav" aria-label="primary">
  <div class="nav__inner">
    <a class="nav__brand" href="/" aria-label="typer home">${logoMark("mark")}<span>typer</span></a>
    <ul class="nav__links" id="nav-links">
      ${links}
      <li class="nav__cta--menu"><a class="btn btn--primary" href="/#install">install</a></li>
    </ul>
    <div class="nav__right">
      <a class="btn btn--primary nav__cta--inline" href="/#install">install</a>
      <button class="nav__theme" id="theme-toggle" type="button" aria-label="toggle color theme">${iconMoon}${iconSun}</button>
      <button class="nav__burger" id="nav-burger" type="button" aria-label="toggle menu" aria-expanded="false" aria-controls="nav-links">${iconBurger}</button>
    </div>
  </div>
</nav>`;
}

/* ---- footer --------------------------------------------------------------- */
const FOOTER_COLS: { head: string; links: { label: string; href: string; external?: boolean }[] }[] = [
  {
    head: "product",
    links: [
      { label: "home", href: "/" },
      { label: "compatibility", href: "/compatibility" },
      { label: "install", href: "/#install" },
      { label: "announcements", href: "/announcements" },
    ],
  },
  {
    head: "open source",
    links: [
      { label: "github", href: GITHUB_URL, external: true },
      { label: "contributing", href: `${GITHUB_URL}/blob/main/CONTRIBUTING.md`, external: true },
      { label: "changelog", href: `${GITHUB_URL}/blob/main/CHANGELOG.md`, external: true },
      { label: "license · mit", href: `${GITHUB_URL}/blob/main/LICENSE`, external: true },
    ],
  },
  {
    head: "resources",
    links: [
      { label: "research", href: "/research" },
      { label: "readme", href: `${GITHUB_URL}#readme`, external: true },
      { label: "llama.cpp", href: "https://github.com/ggml-org/llama.cpp", external: true },
    ],
  },
  {
    head: "the keys",
    links: [
      { label: "tab · next word", href: "/#keys" },
      { label: "` · whole line", href: "/#keys" },
      { label: "esc · dismiss", href: "/#keys" },
    ],
  },
];

export function renderFooter(): string {
  const cols = FOOTER_COLS.map((c) => {
    const links = c.links
      .map((l) => {
        const ext = l.external ? ` target="_blank" rel="noopener"` : "";
        return `<li><a class="footer__link" href="${l.href}"${ext}>${l.label}</a></li>`;
      })
      .join("");
    return `<div class="footer__col">
      <div class="footer__col-head">${c.head}</div>
      <ul class="footer__links">${links}</ul>
    </div>`;
  }).join("");

  const year = new Date().getFullYear();

  return `<footer class="footer">
  <div class="footer__motif" aria-hidden="true"></div>
  <div class="footer__inner">
    <div class="footer__grid">
      <div class="footer__col">
        <div class="footer__brand">
          ${logoMark("mark")}
          <span class="footer__brand-name">typer</span>
          <p class="footer__link" style="font-family:var(--font-body)">autocomplete that never leaves your Mac.</p>
        </div>
      </div>
      ${cols}
    </div>
  </div>
  <div class="footer__base">
    <span class="footer__tagline">free, forever · MIT · runs on llama.cpp · macOS 14+</span>
    <span class="footer__tagline">© ${year} typer · on your Mac, nowhere else</span>
  </div>
</footer>`;
}

/* ---- theme: early init (call inline in <head> to avoid FOUC) --------------- */
const THEME_KEY = "typer-theme";

export function initThemeEarly(): void {
  try {
    const stored = localStorage.getItem(THEME_KEY);
    if (stored === "dark" || stored === "light") {
      document.documentElement.setAttribute("data-theme", stored);
    }
    // else: leave unset → CSS prefers-color-scheme media query decides.
  } catch {
    /* localStorage unavailable; fall back to media query */
  }
}

function currentTheme(): "dark" | "light" {
  const attr = document.documentElement.getAttribute("data-theme");
  if (attr === "dark" || attr === "light") return attr;
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyTheme(theme: "dark" | "light"): void {
  document.documentElement.setAttribute("data-theme", theme);
  try {
    localStorage.setItem(THEME_KEY, theme);
  } catch {
    /* ignore */
  }
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) {
    const bg = getComputedStyle(document.documentElement).getPropertyValue("--base").trim();
    if (bg) meta.setAttribute("content", bg);
  }
}

/* ---- mount + wire interactions -------------------------------------------- */
export function mountChrome(active: ActivePage = ""): void {
  const navHost = document.getElementById("nav");
  const footerHost = document.getElementById("footer");
  if (navHost) navHost.innerHTML = renderNav(active);
  if (footerHost) footerHost.innerHTML = renderFooter();

  // sync the theme meta with whatever theme is live on first mount
  applyTheme(currentTheme());

  const toggle = document.getElementById("theme-toggle");
  toggle?.addEventListener("click", () => {
    applyTheme(currentTheme() === "dark" ? "light" : "dark");
  });

  const burger = document.getElementById("nav-burger");
  const links = document.getElementById("nav-links");
  burger?.addEventListener("click", () => {
    const open = links?.classList.toggle("open") ?? false;
    burger.setAttribute("aria-expanded", String(open));
  });
  // close the mobile menu after navigating to an in-page anchor
  links?.addEventListener("click", (e) => {
    const t = e.target as HTMLElement;
    if (t.closest("a")) {
      links.classList.remove("open");
      burger?.setAttribute("aria-expanded", "false");
    }
  });
}
