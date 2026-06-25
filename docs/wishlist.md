# typer Wishlist / Roadmap — Deferred Features

These two items were intentionally cut from the overhaul (see `docs/impl-contract.md` "Locked
product decisions"). They are real, well-scoped features — they were deferred because each carries a
class of risk the overhaul deliberately avoided taking on in one pass, not because they're unwanted.
Each section below is written so it can be picked up later as a single focused PR: design, the exact
files/APIs it touches, why it was held back, and the acceptance criteria that say "done."

Source of truth for the underlying mechanics: `docs/overhaul-spec.md` §F (picker) and §E #6
(Sparkle), plus `docs/research/feature-mechanics.md` §4 (multi-candidate) and §10 (Sparkle).

---

## 1. Multi-candidate suggestion picker (#5) — *wishlist / future PR*

### What it is
Today typer shows exactly one inline ghost suggestion. This feature generates the model's **top-k**
alternatives and lets the user **cycle them with Option-Tab** (and/or ↑/↓), commit with Return, while
the currently-selected candidate stays rendered as the inline ghost. It's the "I don't want the first
guess, show me the next one" affordance — the same UX Cotypist ships via its
`SuggestionsTableViewController` (`docs/research/feature-mechanics.md` §4).

This was scoped as **Wave 3** in the original plan and is the single feature with the **deepest blast
radius**: it is the *only* deferred item that changes the helper wire protocol.

### Design

**1. Helper produces top-k (`llama_server.cpp`).** Today the helper streams a single completion. Add a
top-k mode: a small beam (or N independent samples with a deduplication pass) bounded by
`maxResultsToShow` (~3–5). Each candidate carries its own mean-probability confidence, exactly like the
single-suggestion `conf` field does now. Keep the existing single-suggestion path as the default so
nothing regresses when the picker is off.

**2. Wire-protocol change (`HelperProtocol.swift`).** This is the load-bearing edit. The current types
are single-valued:
```swift
struct HelperSuggestion: Codable { let kind: String; let text: String?; let original: String?
                                   let replacement: String?; let conf: Double? }
struct StreamLine: Codable { let p: String?; let conf: Double?; let ok: Bool?
                             let error: String?; let suggestion: HelperSuggestion? }
```
Extend them to carry a list **additively** (keep the old single-`suggestion` field populated with the
top candidate so an un-upgraded reader still works):
```swift
// new, optional — present only in top-k mode
struct StreamLine: Codable { /* …existing… */ let candidates: [HelperSuggestion]? }
```
The `request` path in `LlamaClient.swift` (`func request(...) -> HelperSuggestion?`, line ~148, which
decodes `StreamLine` at ~172) gains a sibling that returns `[HelperSuggestion]`, parsing `candidates`
when present and falling back to `[suggestion]`.

**3. State in `TyperApp`.** Store `[ActiveCompletion]` plus a `selectedIndex` instead of the single
`active`/`completion`. `ActiveCompletion` already models "type-into" consumption (`HelperProtocol.swift`
line 42) — the selected candidate drives the existing inline-ghost code untouched; the others sit ready.

**4. Overlay table under the caret (`SuggestionOverlay.swift` / `GhostView.swift`).** Add a borderless
`NSWindow` + `NSTableView` picker (one column, custom cell), **reusing the W1A caret anchoring** — the
overlay already takes the caret's right-edge x / bottom y and line height in
`showCompletion(_:at:lineHeight:animate:)` (line 56) and `show(correction:at:lineHeight:)` (line 69).
The picker anchors to that same caret point, dropping the table directly under the caret line. The top
(selected) candidate continues rendering as the inline ghost via the current path; the table is purely
the "alternatives" surface. Show it only while ≥2 candidates exist.

**5. Keymap (`TyperApp+EventTap.swift`).** The consuming accept tap is already enabled exactly while a
suggestion is on screen (`accept(type:event:)`, line 223) and today handles **Tab** = accept word and
**backtick** = accept all. Add, within that same gated tap:
- **Option-Tab** (and ↑/↓) → cycle `selectedIndex`, re-render the inline ghost from the new selection,
  no regeneration.
- **Return** → commit the selected candidate.
- Preserve existing semantics: plain **Tab** still accepts the next word of the selected candidate,
  **backtick** still accepts all. The accept-tap grace-window logic (`acceptGraceUntil`) stays intact.

### Why it was deferred
- **It is the only feature that changes the wire format.** Every other feature in the overhaul stays
  inside the existing helper protocol; this one re-shapes `HelperSuggestion`/`StreamLine` and the C++
  emitter, so a protocol mismatch between Swift and `llama_server.cpp` breaks completions outright. That
  coupling wants its own PR and its own build-gate (`swiftc` + `build.sh` rebuilding the helper), not a
  slot shared with four parallel agents.
- **Deepest blast radius:** helper (`llama_server.cpp`) + protocol (`HelperProtocol.swift`) + client
  parse (`LlamaClient.swift`) + app state (`TyperApp`) + overlay (`SuggestionOverlay`/`GhostView`) +
  keymap (`TyperApp+EventTap.swift`) all move together. The original plan correctly isolated it as a
  standalone Wave 3 gated **after** FIM (W2B) and overlay styling (W2D) had landed, so it builds on a
  stable protocol and a finished overlay rather than racing them.
- It is purely additive UX: shipping the rest of the overhaul first loses nothing, and a later PR can
  build the picker against a frozen, known-good single-suggestion baseline.

### Acceptance criteria
- The helper emits top-k candidates bounded by `maxResultsToShow` (~3–5), each with its own confidence;
  single-suggestion mode is unchanged when the picker is off.
- **Option-Tab cycles** candidates; **↑/↓** also cycle; **Return commits** the selected candidate.
- Plain **Tab still accepts the next word**; **backtick still accepts all**.
- The inline ghost always equals the currently-selected candidate; the table sits under the caret line
  using the existing W1A anchoring with no separate caret math.
- The picker appears only when ≥2 candidates exist and dismisses cleanly on commit/deviation, with the
  accept-tap grace window preserved (no leaked Tab/Return into the host app).
- An un-upgraded reader still works because the legacy single-`suggestion` field stays populated.
- `swiftc scripts/typer/*.swift -o /tmp/typer-check` passes **and** `bash scripts/build.sh` rebuilds the
  C++ helper (this is the one deferred feature that requires the helper rebuild).

> **Logging note (free win while you're here):** when a candidate is selected/committed, log
> `(context, shownCandidates, acceptedIndex)` to `training.jsonl`. The overhaul already wired the
> accept/reject signal; the picker just adds *which of N* was chosen — a strong KTO/personalization
> signal. Do **not** build a separate "vote" UI: per `docs/research/feature-mechanics.md` §4,
> Cotypist's `userDidVoteForSuggestion` is support-chat, not autocomplete feedback. The
> accept/select event *is* the signal.

---

## 2. Sparkle auto-update + notarized DMG distribution (#6) — *wishlist / future PR*

### What it is
A one-click in-app updater for the people who install a prebuilt typer rather than building from source:
[Sparkle](https://sparkle-project.org) checking a hosted **appcast**, with each release **Ed25519-signed**
and the app **notarized** so Gatekeeper trusts it. typer already has a home-grown git-rebuild updater in
`TyperApp+Menu.swift`; this would sit *beside* it, not replace it — source builds keep self-updating via
git, binary installs get Sparkle.

### Design (from `docs/overhaul-spec.md` §E #6 and `docs/research/feature-mechanics.md` §10)

**Info.plist keys** (Cotypist's, as a reference shape):
```
SUFeedURL                = https://<host>/appcast.xml
SUPublicEDKey            = <base64 ed25519 public key>
SUEnableAutomaticChecks  = true
SUScheduledCheckInterval = 86400        # daily-ish
```

**Wiring:**
- Add Sparkle via SPM and bundle `Sparkle.framework` in `build.sh`.
- Point the existing **"Check for updates"** menu item (currently the home-grown updater at
  `TyperApp+Menu.swift:269-390`) at `SPUStandardUpdaterController.checkForUpdates(_:)`.
- **Keep the git-rebuild path as the source-build fallback**, gated on `canUpdate` / `TyperRepoPath`:
  if typer is running from a checked-out repo, keep self-updating via git; if it's a distributed binary,
  use Sparkle. The two paths are mutually exclusive at runtime, never both.

**Signing + release flow (EdDSA):**
1. Run Sparkle's `generate_keys` **once** — the private key lives in the macOS Keychain, the public key
   goes into `SUPublicEDKey`.
2. Per release: `sign_update Typer-x.y.z.zip` (or `.dmg`) → paste the resulting `edSignature` into a
   self-hosted `appcast.xml` entry.
3. Host the appcast + the signed archive anywhere static.

**Notarization / DMG:** for public distribution the archive must be built with a **Developer ID**
identity and run through **notarization** (`notarytool` submit + `stapler staple`) and packaged as a
DMG, or Gatekeeper warns every non-builder on first launch. The Ed25519 signature is Sparkle's integrity
check on the *update*; notarization is Apple's trust check on the *app*. Both are required for a clean
one-click experience.

### Why it was deferred
- **It needs infrastructure typer doesn't own yet:** a publicly hosted appcast URL + signed archive
  storage, a real **Developer ID** certificate, and an Apple **notarization** pipeline. typer's current
  self-signed cert is fine for the from-source workflow but Gatekeeper will warn the public without
  notarization (`docs/overhaul-spec.md` §H risk #3). None of that is a code problem — it's a
  distribution-and-credentials problem, and shipping Sparkle without it would hand users a broken
  "update" button.
- **Distribution model wasn't locked.** Self-hosted-unsigned-to-public vs. notarized-DMG changes what
  `build.sh` produces. The overhaul deliberately **did not touch `build.sh` or `Info.plist` for
  updates** (locked decision in `docs/impl-contract.md`) so the foundation work couldn't break the
  existing, working build.
- The current git-rebuild updater already serves the only audience typer has today (people who built it),
  so there was no urgency to take on the cert/notarization burden mid-overhaul.

### What it unlocks
- **One-click updates for non-builders** — the prerequisite for distributing typer as a downloadable app
  to people who will never run `build.sh`. This is what turns typer from "clone and build" into
  "download and use," and per the marketing appendix (`docs/overhaul-spec.md` §I) it's an *additive
  convenience* that never gates core local function: **the from-source build stays free and always
  self-updates via git.**

### Acceptance criteria
- A **stub appcast** triggers the Sparkle update UI in a binary build (download → verify Ed25519 → relaunch).
- **Source builds still self-update via git** — the git-rebuild path is untouched and selected when
  running from a repo (`canUpdate`/`TyperRepoPath`).
- A release is **Ed25519-signed** (`sign_update`) and the signature validates against `SUPublicEDKey`;
  a tampered archive is rejected.
- For public distribution: the app is **Developer-ID signed + notarized + stapled** and a fresh
  download launches **without a Gatekeeper warning**.
- The "Check for updates" menu item routes to Sparkle in binary builds and to git-rebuild in source
  builds, never both at once.

---

### Picking either of these up
- **Picker (#5):** branch off main, do `HelperProtocol.swift` + `llama_server.cpp` *together* first
  (compile + helper rebuild gate), then `LlamaClient.swift` parse, then `TyperApp` state, then overlay,
  then keymap. Land as one PR. Gate on `swiftc … -o /tmp/typer-check` **and** `bash scripts/build.sh`.
- **Sparkle (#6):** sort the distribution decision (Developer ID + notarization + appcast host) *before*
  writing code; it's mostly `build.sh`/`Info.plist` + one menu-action rewire, but it's dead in the water
  without the hosting + certs. Keep the git-rebuild fallback intact.
