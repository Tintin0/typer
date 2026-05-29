// A small, curated "model" for the in-page demo. The real Typer runs a GGUF
// model locally via llama.cpp; this is a deterministic stand-in so the page can
// show the *behavior* (ghost text, type-through, accept keys) with zero backend
// and zero network. Sentences lean toward writing/typing so common words land a
// believable continuation.

const CORPUS: string[] = [
  "I think the hardest part of writing is starting the sentence, not finishing it.",
  "The whole point is that the suggestion shows up right at your cursor and then gets out of the way.",
  "Everything runs on your own machine, so nothing you type is ever sent anywhere.",
  "Could you send me the notes from yesterday's meeting when you get a chance?",
  "Thanks for getting back to me so quickly, I really appreciate the help.",
  "Let me know if that time works for you and I'll put it on the calendar.",
  "I wanted to follow up on the message I sent earlier this week.",
  "The model never leaves your laptop and there is no account to sign into.",
  "It watches what you type and quietly guesses the next few words.",
  "Press tab to take a single word, or the backtick to take the whole line.",
  "As long as you keep typing what it predicted, the ghost text just shrinks.",
  "It only stops to think again when you say something it did not expect.",
  "Most autocomplete tools feel like they are fighting you for control of the sentence.",
  "This one stays out of the way until the moment you actually want it.",
  "We should probably grab coffee sometime next week and catch up properly.",
  "I'm writing to ask whether the position is still open for applications.",
  "Please find the attached document and let me know if anything looks off.",
  "Honestly, I had not expected it to feel this natural after a few minutes.",
  "The faint grey text is the suggestion, and your real text stays full strength.",
  "There is no cloud, no subscription, and no telemetry phoning home in the background.",
  "I'll be out of office until Monday, but I'll reply as soon as I'm back.",
  "Looking forward to hearing your thoughts whenever you have a moment.",
  "It works in almost any text field, from your editor to your email to a chat box.",
  "The suggestion is computed in about four tenths of a second and then prefetched ahead.",
  "Sorry for the delay, things have been a little hectic on my end this week.",
  "What I like most is that it never interrupts the flow of actually typing.",
  "You can delete the style file at any time and it forgets how you write.",
  "Just keep typing and watch the grey words disappear one keystroke at a time.",
];

interface Indexed {
  words: string[];
  lower: string[];
}

const INDEX: Indexed[] = CORPUS.map((s) => {
  const words = s.split(/(\s+)/).filter((t) => t.length > 0); // keep whitespace tokens
  return { words, lower: words.map((w) => w.toLowerCase()) };
});

// Openers used when the field is empty or no context matches.
const OPENERS = [
  "the grey text ahead of your cursor is a guess",
  "I think this might be exactly what I was looking for",
  "thanks so much for taking the time to read this",
  "let me know what you think when you get a chance",
];

const MAX_WORDS = 7;

function tokenize(text: string): string[] {
  return text.split(/(\s+)/).filter((t) => t.length > 0);
}

// Only the "word" tokens (no whitespace), lowercased.
function lastWords(text: string, n: number): string[] {
  const toks = tokenize(text)
    .filter((t) => /\S/.test(t))
    .map((t) => t.toLowerCase());
  return toks.slice(Math.max(0, toks.length - n));
}

function takeWords(tokens: string[], start: number, maxWords: number): string {
  let out = "";
  let count = 0;
  for (let i = start; i < tokens.length; i++) {
    const tok = tokens[i];
    out += tok;
    if (/\S/.test(tok)) {
      count++;
      if (count >= maxWords) break;
    }
  }
  return out.replace(/\s+$/, ""); // trim trailing space; we add our own spacing
}

/**
 * Predict a continuation for `typed`.
 * Returns the ghost string to render immediately after the caret, or "".
 * Mid-word positions return "" (the real Typer suppresses mid-word completions).
 */
export function predict(typed: string): string {
  const endsAtBoundary = typed.length === 0 || /[\s.,;:!?—-]$/.test(typed);
  if (!endsAtBoundary) return "";

  const trimmed = typed.replace(/\s+$/, "");

  // Empty / near-empty: offer an opener.
  if (trimmed.length === 0) {
    return capitalizeFirst(typed, OPENERS[0]);
  }

  // Try to match the longest tail of typed against any corpus sentence.
  for (let n = Math.min(5, lastWords(typed, 5).length); n >= 1; n--) {
    const key = lastWords(typed, n);
    if (key.length < n) continue;

    for (const entry of INDEX) {
      const at = findSequence(entry.lower, key);
      if (at === -1) continue;
      // position just after the matched word tokens
      const afterIdx = at + key.length * 2 - 1; // words interleaved with spaces
      let startTok = afterIdx;
      // skip to the token right after the last matched word
      startTok = afterIdxToContinuation(entry.words, at, key.length);
      if (startTok >= entry.words.length) continue;
      const cont = takeWords(entry.words, startTok, MAX_WORDS);
      if (!cont.trim()) continue;
      const needsSpace = !/\s$/.test(typed) && !/^\s/.test(cont);
      return (needsSpace ? " " : "") + cont;
    }
  }

  // Fallback: a generic opener continuation seeded by the last word.
  const last = lastWords(typed, 1)[0] ?? "";
  const pool = OPENERS.filter((o) => !o.startsWith(last));
  const pick = pool[(last.length + trimmed.length) % pool.length] ?? OPENERS[0];
  const needsSpace = !/\s$/.test(typed);
  return (needsSpace ? " " : "") + pick;
}

// Find the index in `hayWords` (interleaved word/space tokens, lowercased)
// where the sequence of `key` words appears in order, separated by whitespace.
function findSequence(hayWords: string[], key: string[]): number {
  for (let i = 0; i < hayWords.length; i++) {
    if (!/\S/.test(hayWords[i])) continue;
    let ki = 0;
    let j = i;
    while (j < hayWords.length && ki < key.length) {
      if (/\S/.test(hayWords[j])) {
        if (stripPunct(hayWords[j]) !== stripPunct(key[ki])) break;
        ki++;
        j++;
        // skip following whitespace
        while (j < hayWords.length && !/\S/.test(hayWords[j])) j++;
      } else {
        j++;
      }
    }
    if (ki === key.length) return i;
  }
  return -1;
}

// Given the start word-token index of a match and the number of matched words,
// return the token index of the continuation (first token after the match).
function afterIdxToContinuation(words: string[], start: number, count: number): number {
  let i = start;
  let matched = 0;
  while (i < words.length && matched < count) {
    if (/\S/.test(words[i])) matched++;
    i++;
  }
  return i; // points at whitespace or next word; takeWords handles leading space
}

function stripPunct(w: string): string {
  return w.replace(/[.,;:!?—-]+$/g, "");
}

function capitalizeFirst(typed: string, s: string): string {
  if (typed.length === 0) return s.charAt(0).toUpperCase() + s.slice(1);
  return s;
}
