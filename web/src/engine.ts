import { predict } from "./corpus";

// A faithful in-browser re-creation of how Typer behaves at the caret:
//  - a faint ghost suggestion appears after a short pause
//  - typing the predicted characters just consumes the ghost (no regenerate)
//  - typing something unexpected re-thinks after a debounce
//  - Tab takes one word, backtick (`) takes the whole suggestion, Esc dismisses

const DEBOUNCE_MS = 380; // mirrors the product's ~0.4s warm latency

export interface EngineEls {
  root: HTMLElement; // focusable container
  ink: HTMLElement; // committed text
  ghost: HTMLElement; // suggestion remainder
  caret: HTMLElement;
  hint: HTMLElement; // "click and type" affordance
}

export class TyperEngine {
  private typed = "";
  private ghost = "";
  private timer: number | null = null;
  private autoRaf: number | null = null;
  private interacted = false;
  private onState?: (s: { accepted: number }) => void;
  private acceptedChars = 0;

  constructor(private els: EngineEls) {
    this.els.root.addEventListener("keydown", this.onKey);
    this.els.root.addEventListener("focus", () => this.onUserStart());
    this.els.root.addEventListener("pointerdown", () => {
      this.onUserStart();
      this.els.root.focus();
    });
    this.render();
  }

  onAccept(cb: (s: { accepted: number }) => void) {
    this.onState = cb;
  }

  // ---- input handling ---------------------------------------------------

  private onKey = (e: KeyboardEvent) => {
    // let real shortcuts through
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    this.onUserStart();

    const k = e.key;

    if (k === "Tab") {
      e.preventDefault();
      this.acceptWord();
      return;
    }
    if (k === "`") {
      e.preventDefault();
      this.acceptAll();
      return;
    }
    if (k === "Escape") {
      e.preventDefault();
      this.dismiss();
      return;
    }
    if (k === "Backspace") {
      e.preventDefault();
      if (this.typed.length > 0) {
        this.typed = this.typed.slice(0, -1);
        this.ghost = "";
        this.scheduleSuggest();
      }
      this.render();
      return;
    }
    if (k === "Enter") {
      e.preventDefault();
      this.insert("\n");
      return;
    }
    // single printable character
    if (k.length === 1) {
      e.preventDefault();
      this.insert(k);
    }
  };

  private insert(ch: string) {
    // type-through: if the char matches the head of the ghost, just consume it
    if (this.ghost.length > 0 && this.ghost[0] === ch) {
      this.typed += ch;
      this.ghost = this.ghost.slice(1);
      this.acceptedChars++;
      this.emit();
      if (this.ghost.trim().length === 0) {
        this.ghost = "";
        this.scheduleSuggest();
      }
      this.render();
      return;
    }
    // divergence: commit and re-think
    this.typed += ch;
    this.ghost = "";
    this.scheduleSuggest();
    this.render();
  }

  private acceptWord() {
    if (!this.ghost) return;
    // take leading whitespace + first word
    const m = this.ghost.match(/^(\s*\S+)(\s?)/);
    if (!m) {
      this.acceptAll();
      return;
    }
    const take = m[1] + (m[2] ?? "");
    this.typed += take;
    this.ghost = this.ghost.slice(take.length);
    this.acceptedChars += take.trim().length;
    this.emit();
    if (this.ghost.trim().length === 0) {
      this.ghost = "";
      this.scheduleSuggest();
    }
    this.render();
  }

  private acceptAll() {
    if (!this.ghost) return;
    this.acceptedChars += this.ghost.trim().length;
    this.typed += this.ghost;
    this.ghost = "";
    this.emit();
    this.scheduleSuggest();
    this.render();
  }

  private dismiss() {
    this.ghost = "";
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.render();
  }

  // ---- suggestion lifecycle --------------------------------------------

  private scheduleSuggest() {
    if (this.timer) clearTimeout(this.timer);
    this.els.root.classList.add("thinking");
    this.timer = window.setTimeout(() => {
      this.timer = null;
      this.els.root.classList.remove("thinking");
      this.ghost = predict(this.typed);
      this.render();
    }, DEBOUNCE_MS);
  }

  private emit() {
    this.onState?.({ accepted: this.acceptedChars });
  }

  // ---- rendering --------------------------------------------------------

  private render() {
    this.els.ink.textContent = this.typed;
    this.els.ghost.textContent = this.ghost;
    const empty = this.typed.length === 0 && this.ghost.length === 0;
    this.els.hint.style.opacity = empty && !this.interacted ? "1" : "0";
    this.els.root.classList.toggle("has-ghost", this.ghost.length > 0);
  }

  // ---- auto demo (plays until the user takes over) ---------------------

  private onUserStart() {
    if (this.interacted) return;
    this.interacted = true;
    if (this.autoRaf) cancelAnimationFrame(this.autoRaf);
    // clear the scripted text so the user starts fresh
    this.typed = "";
    this.ghost = "";
    if (this.timer) clearTimeout(this.timer);
    this.els.root.classList.remove("thinking");
    this.render();
  }

  /** Scripted demonstration: types a line, follows the ghost, accepts a word, then all. */
  async playDemo() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      // Show a static finished state instead of animating.
      this.typed = "Everything runs on your own machine, ";
      this.ghost = predict(this.typed);
      this.render();
      return;
    }

    const wait = (ms: number) =>
      new Promise<void>((res) => {
        this.autoRaf = window.setTimeout(res, ms) as unknown as number;
      });

    const typeSlow = async (s: string) => {
      for (const ch of s) {
        if (this.interacted) return;
        this.typed += ch;
        this.render();
        await wait(38 + (ch === " " ? 30 : Math.random() * 45));
        if (this.interacted) return;
      }
    };

    // 1. type a phrase, then pause and let a ghost appear
    await typeSlow("Everything runs on your own ");
    if (this.interacted) return;
    await wait(420);
    this.ghost = predict(this.typed);
    this.render();
    await wait(900);

    // 2. type ALONG the ghost — show it shrinking, not regenerating
    if (this.interacted) return;
    const along = "machine, ";
    for (const ch of along) {
      if (this.interacted) return;
      if (this.ghost[0] === ch) {
        this.typed += ch;
        this.ghost = this.ghost.slice(1);
      } else {
        this.typed += ch;
        this.ghost = this.ghost.replace(/^\S*/, "");
      }
      this.render();
      await wait(70);
    }
    await wait(300);
    if (this.interacted) return;
    this.ghost = predict(this.typed);
    this.render();
    await wait(950);

    // 3. accept one word with Tab
    if (this.interacted) return;
    this.flashKey("tab");
    this.acceptWordDemo();
    await wait(1100);

    // 4. accept the rest with backtick
    if (this.interacted) return;
    this.flashKey("tick");
    this.acceptAllDemo();
    await wait(2600);

    // 5. reset and idle, inviting the user
    if (this.interacted) return;
    this.typed = "";
    this.ghost = "";
    this.interacted = false; // allow hint to show again
    this.render();
  }

  private acceptWordDemo() {
    const m = this.ghost.match(/^(\s*\S+)(\s?)/);
    if (!m) return;
    const take = m[1] + (m[2] ?? "");
    this.typed += take;
    this.ghost = this.ghost.slice(take.length);
    this.render();
  }

  private acceptAllDemo() {
    this.typed += this.ghost;
    this.ghost = "";
    this.render();
  }

  private flashKey(which: "tab" | "tick") {
    const el = document.querySelector<HTMLElement>(`[data-key="${which}"]`);
    if (!el) return;
    el.classList.add("pressed");
    setTimeout(() => el.classList.remove("pressed"), 260);
  }
}
