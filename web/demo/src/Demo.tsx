import React from "react";
import {
  AbsoluteFill,
  Sequence,
  interpolate,
  random,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { loadFont } from "@remotion/google-fonts/Inter";

const { fontFamily } = loadFont("normal", { weights: ["400", "500", "600"] });

export type Theme = "dark" | "light";

// ---------------------------------------------------------------------------
// Script: what gets typed, what the model suggests, and when.
// The full sentence is BASE (typed by the user) + GHOST (suggested).
// The user consumes the first two ghost words by typing them, takes one word
// with Tab, then the rest with backtick.
// ---------------------------------------------------------------------------
const BASE = "just tried that ramen place ";
const GHOST_WORDS = ["on ", "5th, ", "totally ", "worth ", "the ", "wait."];
const GHOST = GHOST_WORDS.join("");
const FULL = BASE + GHOST;

const CONSUME = "on 5th, "; // typed by the user, matching the ghost
const TAB_SPAN = "totally "; // accepted with Tab
const REST = "worth the wait."; // accepted with backtick

// --- timeline (seconds) ----------------------------------------------------
const TYPE_START = 0.5;
const GHOST_START = 3.1;
const GHOST_WORD_EVERY = 0.22;
const CONSUME_START = 4.9;
const TAB_T = 6.5;
const BACKTICK_T = 7.9;
const FADE_START = 10.0;
const FADE_END = 10.6;
export const DEMO_DURATION_S = 11.0;

// Per-character key times for the base sentence, with deterministic jitter so
// it reads as human typing rather than a metronome.
const baseCharTimes: number[] = (() => {
  const times: number[] = [];
  let t = TYPE_START;
  for (let i = 0; i < BASE.length; i++) {
    times.push(t);
    t += 0.045 + random(`b${i}`) * 0.055 + (BASE[i] === " " ? 0.03 : 0);
  }
  return times;
})();

const consumeCharTimes: number[] = (() => {
  const times: number[] = [];
  let t = CONSUME_START;
  for (let i = 0; i < CONSUME.length; i++) {
    times.push(t);
    t += 0.09 + random(`c${i}`) * 0.06;
  }
  return times;
})();

const countAtOrBefore = (times: number[], t: number) => {
  let n = 0;
  for (const ct of times) if (ct <= t) n++;
  return n;
};

// Number of "solid" (committed) characters of FULL at time t.
const solidChars = (t: number): number => {
  let s = countAtOrBefore(baseCharTimes, t);
  s += countAtOrBefore(consumeCharTimes, t);
  if (t >= TAB_T) s += TAB_SPAN.length;
  if (t >= BACKTICK_T) s += REST.length;
  return Math.min(s, FULL.length);
};

// End of the revealed ghost (streams in word by word) at time t.
const ghostEnd = (t: number): number => {
  if (t < GHOST_START) return 0;
  let chars = 0;
  for (let k = 0; k < GHOST_WORDS.length; k++) {
    if (GHOST_START + k * GHOST_WORD_EVERY <= t) chars += GHOST_WORDS[k].length;
  }
  return BASE.length + chars;
};

// Accept events flash a soft highlight over the span they committed.
const FLASHES = [
  { t: TAB_T, start: BASE.length + CONSUME.length, end: BASE.length + CONSUME.length + TAB_SPAN.length },
  { t: BACKTICK_T, start: BASE.length + CONSUME.length + TAB_SPAN.length, end: FULL.length },
];

const PALETTES = {
  dark: {
    page: "#0b0b0e",
    window: "#1d1d22",
    titlebar: "#26262c",
    border: "rgba(255,255,255,0.08)",
    title: "#8e8e96",
    text: "#e9e9ec",
    ghost: "#62626d",
    caret: "#5b8def",
    flashRGB: "91,141,239",
    caption: "#8e8e96",
    keycapBg: "#2a2a31",
    keycapBorder: "rgba(255,255,255,0.14)",
    keycapText: "#e9e9ec",
    pill: "#3a3a42",
    pillDot: "#34c759",
    shadow: "0 30px 80px rgba(0,0,0,0.55)",
  },
  light: {
    page: "#f4f3f1",
    window: "#ffffff",
    titlebar: "#f0efed",
    border: "rgba(0,0,0,0.08)",
    title: "#8a8a86",
    text: "#1d1d1f",
    ghost: "#b3b3b8",
    caret: "#3478f6",
    flashRGB: "52,120,246",
    caption: "#7d7d79",
    keycapBg: "#ffffff",
    keycapBorder: "rgba(0,0,0,0.18)",
    keycapText: "#1d1d1f",
    pill: "#55554f",
    pillDot: "#28a745",
    shadow: "0 30px 70px rgba(0,0,0,0.16)",
  },
} as const;

const TrafficLights: React.FC = () => (
  <div style={{ display: "flex", gap: 8, position: "absolute", left: 16, top: "50%", transform: "translateY(-50%)" }}>
    {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
      <div key={c} style={{ width: 12, height: 12, borderRadius: 6, background: c }} />
    ))}
  </div>
);

const Keycap: React.FC<{ label: string; theme: Theme; wide?: boolean }> = ({ label, theme, wide }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = PALETTES[theme];
  const pop = spring({ frame, fps, config: { damping: 18, stiffness: 240 } });
  return (
    <div
      style={{
        transform: `scale(${0.85 + 0.15 * pop}) translateY(${(1 - pop) * 8}px)`,
        opacity: pop,
        background: p.keycapBg,
        border: `1.5px solid ${p.keycapBorder}`,
        borderBottomWidth: 4,
        borderRadius: 9,
        padding: wide ? "8px 26px" : "8px 16px",
        fontFamily: "Menlo, monospace",
        fontSize: 21,
        color: p.keycapText,
        display: "inline-block",
      }}
    >
      {label}
    </div>
  );
};

// Caption + optional keycap under the window. Fades in/out within its Sequence.
const Caption: React.FC<{ text: string; theme: Theme; keycap?: string; wide?: boolean; lastsFrames: number }> = ({
  text,
  theme,
  keycap,
  wide,
  lastsFrames,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const p = PALETTES[theme];
  const opacity =
    interpolate(frame, [0, 0.25 * fps], [0, 1], { extrapolateRight: "clamp" }) *
    interpolate(frame, [lastsFrames - 0.3 * fps, lastsFrames], [1, 0], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    });
  return (
    <div
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        bottom: 56,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 16,
        opacity,
      }}
    >
      {keycap ? <Keycap label={keycap} theme={theme} wide={wide} /> : null}
      <span style={{ fontFamily, fontSize: 24, fontWeight: 500, color: p.caption }}>{text}</span>
    </div>
  );
};

export const Demo: React.FC<{ theme: Theme }> = ({ theme }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const t = frame / fps;
  const p = PALETTES[theme];

  const S = solidChars(t);
  const G = Math.max(S, ghostEnd(t));

  // Active accept-flash, if any: highlight decays over 0.45s.
  const flash = FLASHES.find((f) => t >= f.t && t < f.t + 0.45);
  const flashAlpha = flash ? 1 - (t - flash.t) / 0.45 : 0;

  // Caret blinks when idle, stays lit while keys are landing.
  const allKeyTimes = [...baseCharTimes, ...consumeCharTimes, TAB_T, BACKTICK_T];
  const typing = allKeyTimes.some((kt) => t >= kt && t - kt < 0.25);
  const caretOn = typing || Math.floor(t / 0.55) % 2 === 0;

  // Content fades out at the end so the video loops back to the empty note.
  const contentOpacity = interpolate(t, [FADE_START, FADE_END], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  const flashStart = flash ? Math.min(flash.start, S) : S;
  const solidBefore = FULL.slice(0, flash ? flashStart : S);
  const flashed = flash ? FULL.slice(flashStart, Math.min(flash.end, S)) : "";
  const ghost = FULL.slice(S, G);

  return (
    <AbsoluteFill style={{ background: p.page, fontFamily }}>
      {/* the window */}
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "50%",
          transform: "translate(-50%, -54%)",
          width: 960,
          height: 540,
          background: p.window,
          borderRadius: 14,
          border: `1px solid ${p.border}`,
          boxShadow: p.shadow,
          overflow: "hidden",
        }}
      >
        <div
          style={{
            position: "relative",
            height: 46,
            background: p.titlebar,
            borderBottom: `1px solid ${p.border}`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          <TrafficLights />
          <span style={{ fontSize: 17, fontWeight: 500, color: p.title }}>New Note</span>
        </div>

        <div style={{ padding: "44px 52px", opacity: contentOpacity }}>
          <div style={{ fontSize: 31, lineHeight: 1.55, fontWeight: 400, color: p.text, letterSpacing: 0.1 }}>
            <span>{solidBefore}</span>
            {flashed ? (
              <span style={{ backgroundColor: `rgba(${p.flashRGB}, ${(flashAlpha * 0.25).toFixed(3)})`, borderRadius: 4 }}>
                {flashed}
              </span>
            ) : null}
            <span
              style={{
                display: "inline-block",
                width: 2.5,
                height: "1.05em",
                background: p.caret,
                verticalAlign: "text-bottom",
                opacity: caretOn ? 1 : 0,
                marginRight: 1,
              }}
            />
            <span style={{ color: p.ghost }}>{ghost}</span>
          </div>
        </div>

        {/* on-device status pill, always visible */}
        <div
          style={{
            position: "absolute",
            right: 16,
            bottom: 14,
            display: "flex",
            alignItems: "center",
            gap: 8,
            fontFamily: "Menlo, monospace",
            fontSize: 14,
            color: p.title,
          }}
        >
          <span style={{ width: 7, height: 7, borderRadius: 4, background: p.pillDot, display: "inline-block" }} />
          gemma-4-E2B · on-device
        </div>
      </div>

      {/* narration captions */}
      <Sequence from={Math.round((GHOST_START - 0.1) * fps)} durationInFrames={Math.round(1.7 * fps)} premountFor={15}>
        <Caption text="a suggestion appears at your caret" theme={theme} lastsFrames={Math.round(1.7 * fps)} />
      </Sequence>
      <Sequence from={Math.round((CONSUME_START - 0.1) * fps)} durationInFrames={Math.round(1.5 * fps)} premountFor={15}>
        <Caption text="type along — it just shrinks" theme={theme} lastsFrames={Math.round(1.5 * fps)} />
      </Sequence>
      <Sequence from={Math.round((TAB_T - 0.15) * fps)} durationInFrames={Math.round(1.3 * fps)} premountFor={15}>
        <Caption text="takes one word" theme={theme} keycap="tab" wide lastsFrames={Math.round(1.3 * fps)} />
      </Sequence>
      <Sequence from={Math.round((BACKTICK_T - 0.15) * fps)} durationInFrames={Math.round(1.9 * fps)} premountFor={15}>
        <Caption text="takes the rest" theme={theme} keycap="`" lastsFrames={Math.round(1.9 * fps)} />
      </Sequence>
    </AbsoluteFill>
  );
};
