/**
 * Interactive hero demo — the ghost-text "dance" across four Mac apps.
 *
 * The blue caret tours Notes → Messages → Mail → Terminal on a ~20s loop: text
 * sits, the suggestion streams in faint, the tab/backtick keycaps press, words
 * solidify one-by-one with a green accept-flash, then the window cross-dissolves
 * to the next app. Deterministic timeline (one render(t)); requestAnimationFrame
 * drives playback, IntersectionObserver pauses it offscreen, and reduced-motion
 * gets a static composed frame. Namespaced .td-* markup (see demo.css).
 *
 * mountDemo(root) builds everything inside `root`. No external deps; pulls all
 * colors/fonts from the shared design tokens in styles.css.
 */

type Scene = {
  app: string;
  title: string;
  cap: string;
  base: string;
  ghost: string;
  field: (inner: string) => string;
};

const SCENES: Scene[] = [
  {
    app: "notes", title: "New Note",
    cap: "native field — the ghost lands on your real caret.",
    base: "just tried that ramen place on 5th, totally ", ghost: "worth the wait.",
    field: (h) => `<div class="td-line">${h}</div>`,
  },
  {
    app: "messages", title: "Mio",
    cap: "electron & web chat — same inline caret.",
    base: "want me to grab you ", ghost: "a coffee on the way?",
    field: (h) =>
      `<div class="td-bubbles"><div class="td-bub them">heading out?</div><div class="td-bub me">yeah, 5 min</div><div class="td-bub them">no rush!</div></div><div class="td-composer">${h}</div>`,
  },
  {
    app: "mail", title: "Drafts — Re: launch",
    cap: "long-form — tab a word, backtick the rest.",
    base: "Thanks so much for ", ghost: "your patience on this — shipping tomorrow.",
    field: (h) =>
      `<div class="td-mailrow"><b>To</b><span class="td-muted">team@typr.app</span></div><div class="td-mailrow"><b>Subject</b><span class="td-muted">Re: launch</span></div><div class="td-mailbody td-line">${h}</div>`,
  },
  {
    app: "terminal", title: "zsh — typer",
    cap: "even terminals — caret found by reading the screen.",
    base: 'git commit -m "', ghost: 'fix caret drift on retina"',
    field: (h) =>
      `<div class="td-term"><span class="cm"># on-device. nothing leaves your mac.</span><div class="td-line mono"><span class="pr">$ </span>${h}</div></div>`,
  },
];

const ENTER = 520, READ = 620, PER_CHAR = 42, BEAT = 560, PER_WORD = 330, HOLD = 1150, EXIT = 460, OVERLAP = 300;
const clamp = (x: number, a: number, b: number) => Math.max(a, Math.min(b, x));
const ease = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const easeOut = (t: number) => 1 - Math.pow(1 - t, 3);
const wordsOf = (g: string) => g.match(/\S+\s*/g) || [g];

export function mountDemo(root: HTMLElement): void {
  root.classList.add("td-stage");
  root.innerHTML = `
    <div class="td-rail">
      ${SCENES.map((s) => `<span class="td-pill" data-app="${s.app}">${s.app}</span>`).join("")}
    </div>
    <div class="td-winwrap"></div>
    <div class="td-hint">
      <span class="td-kbd"><span class="td-key" data-k="tab">tab</span> next word</span>
      <span class="td-sep"></span>
      <span class="td-kbd"><span class="td-key" data-k="tick">\`</span> the rest</span>
      <span class="td-sep"></span>
      <span class="td-cap"></span>
    </div>`;

  const wrap = root.querySelector(".td-winwrap") as HTMLElement;
  const capEl = root.querySelector(".td-cap") as HTMLElement;
  const pills = Array.from(root.querySelectorAll<HTMLElement>(".td-pill"));
  const kTab = root.querySelector<HTMLElement>('[data-k="tab"]')!;
  const kTick = root.querySelector<HTMLElement>('[data-k="tick"]')!;

  // precompute timeline
  let cursor = 0;
  const seg = SCENES.map((s) => {
    const words = wordsOf(s.ghost);
    const TYPE = s.ghost.length * PER_CHAR;
    const ACCEPT = words.length * PER_WORD;
    const tEnter = cursor, tType = cursor + READ, tTypeEnd = tType + TYPE;
    const tAccept = tTypeEnd + BEAT, tAcceptEnd = tAccept + ACCEPT;
    const tHoldEnd = tAcceptEnd + HOLD, tExit = tHoldEnd, tExitEnd = tHoldEnd + EXIT;
    cursor = tExit - OVERLAP;
    return { s, words, TYPE, ACCEPT, tEnter, tType, tTypeEnd, tAccept, tAcceptEnd, tHoldEnd, tExit, tExitEnd };
  });
  const TOTAL = seg[seg.length - 1].tExitEnd + 200;

  const wins = seg.map((g) => {
    const el = document.createElement("section");
    el.className = "td-win";
    el.innerHTML = `<div class="td-bar"><span class="td-tl r"></span><span class="td-tl y"></span><span class="td-tl g"></span><span class="td-title">${g.s.title}</span></div><div class="td-body">${g.s.field('<span class="td-field"></span>')}</div>`;
    wrap.appendChild(el);
    return { el, field: el.querySelector(".td-field") as HTMLElement, lastHTML: "" };
  });

  function fieldHTML(g: typeof seg[number], t: number): string {
    const { s, words } = g;
    let ghostTxt = "", accepted = "", flash = false;
    if (t < g.tType) ghostTxt = "";
    else if (t < g.tTypeEnd) ghostTxt = s.ghost.slice(0, Math.floor(((t - g.tType) / g.TYPE) * s.ghost.length));
    else if (t < g.tAccept) ghostTxt = s.ghost;
    else if (t < g.tAcceptEnd) {
      const wAcc = Math.floor(((t - g.tAccept) / g.ACCEPT) * words.length);
      accepted = words.slice(0, wAcc).join("");
      ghostTxt = words.slice(wAcc).join("");
      const boundary = g.tAccept + wAcc * PER_WORD;
      flash = wAcc > 0 && t - boundary < 200;
    } else accepted = s.ghost;
    const blink = t < g.tType || t >= g.tHoldEnd ? " blink" : "";
    const accCls = flash ? "td-acc td-flash" : "td-acc";
    return `<span class="td-typed">${s.base}</span><span class="${accCls}">${accepted}</span><span class="td-caret${blink}"></span><span class="td-ghosttx">${ghostTxt}</span>`;
  }

  let lastActive = -1;
  function render(t: number): void {
    t = ((t % TOTAL) + TOTAL) % TOTAL;
    let active = 0;
    for (let i = 0; i < seg.length; i++) {
      const g = seg[i], w = wins[i];
      let op = 0, ty = 14, sc = 0.985, bl = 6;
      if (t >= g.tEnter && t <= g.tExitEnd) {
        const e = easeOut(clamp((t - g.tEnter) / ENTER, 0, 1));
        const x = ease(clamp((t - g.tExit) / EXIT, 0, 1));
        op = e * (1 - x); ty = (1 - e) * 14 - x * 12; sc = 0.985 + e * 0.015 - x * 0.006; bl = (1 - e) * 6 + x * 7;
        if (t >= g.tEnter && t < g.tExit) active = i;
      }
      w.el.style.opacity = op.toFixed(3);
      w.el.style.transform = `translateY(${ty.toFixed(2)}px) scale(${sc.toFixed(3)})`;
      w.el.style.filter = bl > 0.05 ? `blur(${bl.toFixed(2)}px)` : "none";
      if (op > 0.02) {
        const html = fieldHTML(g, t);
        if (html !== w.lastHTML) { w.field.innerHTML = html; w.lastHTML = html; }
      }
    }
    const ag = seg[active];
    if (active !== lastActive) {
      pills.forEach((p) => p.classList.toggle("is-active", p.dataset.app === ag.s.app));
      capEl.textContent = ag.s.cap;
      lastActive = active;
    }
    let tabOn = false, tickOn = false;
    if (t >= ag.tAccept && t < ag.tAcceptEnd) {
      const wAcc = Math.floor(((t - ag.tAccept) / ag.ACCEPT) * ag.words.length);
      if (t - (ag.tAccept + wAcc * PER_WORD) < 140) (wAcc >= ag.words.length - 1 ? (tickOn = true) : (tabOn = true));
    }
    kTab.classList.toggle("press", tabOn);
    kTick.classList.toggle("press", tickOn);
  }

  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduce) { render(seg[0].tHoldEnd - 50); return; }

  let start: number | null = null, running = false, raf = 0;
  const tick = (now: number) => {
    if (start == null) start = now;
    render(now - start);
    raf = requestAnimationFrame(tick);
  };
  const play = () => { if (!running) { running = true; raf = requestAnimationFrame(tick); } };
  const stop = () => { running = false; cancelAnimationFrame(raf); start = null; };

  const io = new IntersectionObserver((es) => (es[0].isIntersecting ? play() : stop()), { threshold: 0.15 });
  io.observe(root);
  render(0);
}
