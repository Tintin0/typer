# Cotypist Stability & Robustness — Reverse-Engineering Notes

Scope: how Cotypist stays stable inside arbitrary host apps and avoids breaking them.
Target binary: `/Applications/Cotypist.app/Contents/MacOS/Cotypist`.
Method: `ipsw class-dump`, `ipsw swift-dump`, `ipsw macho info --strings/--symbols`,
`ipsw macho disass`, `nm`. typer comparison files: `scripts/typer/TyperApp+AXObserver.swift`,
`TyperApp+EventTap.swift`, `TyperApp+Input.swift`, `PowerState.swift`, `TyperApp.swift`,
`TyperConfig.swift`.

Convention: **VERIFIED** = read directly out of the binary (quoted). **INFERRED** =
deduced from symbol/string shape + standard macOS API behavior; not byte-proven.

---

## 1. Verified Findings (with evidence)

### 1.1 AX call set — what Cotypist links, and what it conspicuously does NOT

`nm` import table (VERIFIED):

```
U _AXUIElementSetMessagingTimeout      <-- bounds every AX round-trip
U _AXUIElementCreateApplication
U _AXUIElementCreateSystemWide
U _AXObserverCreate
U _AXObserverAddNotification
U _AXObserverGetRunLoopSource
U _CFRunLoopAddSource
U _CFRunLoopRemoveSource
U _AXIsProcessTrustedWithOptions
... (AXUIElementCopyAttributeValue, CopyParameterizedAttributeValue,
     SetAttributeValue, PerformAction, AXTextMarker* family, etc.)
```

Two absences are load-bearing:

- **`AXObserverRemoveNotification` is NOT imported.** Cotypist never explicitly
  un-registers individual notifications. (Calling `AXObserverRemoveNotification` on an
  element whose owning process has died is a known crash/hang vector.)
- **`AXObserverInvalidate` is NOT imported.** It tears the observer down purely by
  releasing the `AXObserver` CF object (ARC), after first removing only the run-loop
  source (`CFRunLoopRemoveSource` IS imported).

So Cotypist's teardown is: remove the run-loop source, then *drop the reference and let
the object die* — and it makes that drop happen later, off the AX callback stack. See 1.3.

### 1.2 `AXUIElementSetMessagingTimeout` is used (VERIFIED, big one)

The symbol is imported and `setMessagingTimeout:` appears in the string table. This is the
single most important robustness primitive Cotypist has that typer does not: it caps how
long any AX read/write may block. A host app that is busy/hung (Electron mid-layout,
a spinning IDE) cannot stall Cotypist's main thread on an AX call — the call returns
`kAXErrorCannotComplete` instead. typer has **zero** calls to this API anywhere.

### 1.3 `AXObserverDeferredRelease` — the "defer release" wrapper (VERIFIED mechanism)

`swift-dump` of the class:

```
class Cotypist.AXObserverDeferredRelease {
  var value: __C.AXObserver?
  func value.getter / value.setter / value.modify
  func sub_1001b2394   // == value.setter (instance)
}
```

It is used as the storage type for *every* observer slot in the two monitor classes:

```
CompletionAccessibilityMonitor {
  AXObserverDeferredRelease _applicationObserverForFocusedUIElement
  AXObserverDeferredRelease _textFieldObserverForStarting
}
AppOverridesStore-adjacent monitor {
  AXObserverDeferredRelease _textFieldObserverForCompletion
  AXObserverDeferredRelease _applicationObserverForResetting
  AXObserverDeferredRelease _layoutChangeObserver
}
```

Disassembly of the setter `sub_1001b2394` (VERIFIED — quoting the salient ops):

```
0x1001b2424  ldr  x24, [x20, #0x10]      ; old = self.value
0x1001b2428  str  x25, [x20, #0x10]      ; self.value = new
0x1001b242c  cbz  x24, loc_...           ; if old == nil, done (no release)
...                                       ; old != nil:
0x1001b248c  ldr  __NSConcreteStackBlock ; build a heap block capturing `old`
0x1001b24b8  bl   __Block_copy
0x1001b245c  bl   ...DispatchE4mainABvgZ ; DispatchQueue.main
0x1001b2498  ldr  d0, [x8, #0xad0]       ; a delay constant -> asyncAfter
```

i.e. setting `.value` (including to nil during teardown) captures the *previous*
observer in a block and schedules its release on **`DispatchQueue.main.asyncAfter`**
rather than releasing it inline.

**Why defer (INFERRED, but well-grounded):** the setter is driven from inside AX
callbacks / focus-change handling. Releasing the last reference to an `AXObserver`
*synchronously while still on the observer's own callback stack* re-enters AX framework
teardown (run-loop source removal, port invalidation) re-entrantly — a classic source of
deadlocks and use-after-free against the WindowServer/host app. Bouncing the release to a
fresh main-loop turn guarantees the callback frame has fully unwound first. This is the
"why defer release?" answer: **re-entrancy safety during observer churn on rapid focus
changes.**

### 1.4 App admissibility / suppression (VERIFIED)

Symbols/strings:

```
applicationsTemporarilyInadmissibleForAutomaticCompletion   (SD: dict [String:Date])
pollingTemporarilySuspendedForPID
allCompletionsDisabledUntil
```

`applicationsTemporarilyInadmissibleForAutomaticCompletion` is typed (swift-dump) as
`[String : Date]` — a map of **bundle-id → "suppressed until" timestamp**. This is a
*temporary, self-healing* denylist: an app that misbehaves (or the user toggles off) is
added with an expiry, not banned forever. `pollingTemporarilySuspendedForPID` is the
per-PID circuit breaker: suspend AX polling for a specific process that is being hostile,
keyed by pid not bundle so a relaunch clears it.

### 1.5 The hard-coded special-cased bundle-id lists (VERIFIED — full enumeration)

These are contiguous in `__cstring` (addresses 0x1007c71e0…0x1007c85e0). The grouping
below is inferred from address adjacency + the `app:` / `domain:` prefixes (apps tagged
`app:`/`domain:` are matched against the focused web area's URL, not just the host app).

**IDEs / terminals / editors / DB & data tools (apps with their own autocomplete →
completions suppressed; string at 0x1007d83c0 confirms intent: "Useful for apps with
their own autocomplete (e.g. IDEs), password managers…"):**

```
com.apple.dt.Xcode
com.apple.dt.IDE.Cocoa-Simulator
com.apple.InterfaceBuilder3
org.editra.Editra
com.apple.Terminal
com.googlecode.iterm2
dev.warp.Warp-Stable
com.mitchellh.ghostty
com.mrFridge.Tincta
com.sublimetext.2
com.sublimetext.3
com.microsoft.VSCode
com.microsoft.VSCodeInsiders
com.todesktop.230313mzl4w4u92        (Cursor)
com.exafunction.windsurf
com.google.android.studio
com.google.android.studio-EAP
com.jetbrains.intellij(.ce)(-EAP)
com.jetbrains.AppCode
com.jetbrains.PhpStorm(-EAP)
com.jetbrains.CLion(-EAP)
com.jetbrains.pycharm(.ce)(-EAP)
com.jetbrains.goland-EAP
com.jetbrains.rider(-EAP)
com.jetbrains.rubymine(-EAP)
com.mathworks.matlab
org.rstudio.RStudio
com.tinyapp.TablePlus(-setapp)
```

**Password managers / secret stores (always inadmissible):**

```
com.1password.1password
com.agilebits.onepassword
com.apple.Passwords
com.lastpass.lastpassmacdesktop
com.lastpass.LastPass
com.dashlane.dashlanephonefinal
com.dashlane.Dashlane
com.bitwarden.desktop
com.callpod.keepermac.lite
com.keepersecurity.passwordmanager
com.sibersystems.RoboFormMac
com.nordsec.nordpass
in.sinew.Enpass-Desktop
com.ascendo.DataVaultMac
me.proton.pass.electron
com.mseven.msecuremac
com.symantec.NortonPasswordManager.combined
org.keepassx.keepassx
org.keepassxc.keepassxc
com.selznick.PasswordWallet
com.outercorner.Secrets(-setapp / .osx / -safari)
```

**Browsers (matched so the URL-based `domain:` rules can apply, and for
secure-page handling):**

```
company.thebrowser.Browser / .browser / .dia   (Arc / Dia)
com.google.Chrome(.canary/.beta/.dev)
org.chromium.Chromium
com.vivaldi.Vivaldi
ru.yandex.desktop.yandex-browser
com.operasoftware.Opera
com.brave.Browser
com.ghostbrowser.gb1
com.microsoft.edgemac(.Beta/.Dev)
com.bookry.wavebox
com.gener8.Browser
net.imput.helium
org.mozilla.firefox / .firefoxdeveloperedition / .com.zen.browser
org.mozilla.thunderbird / org.mozilla.betterbird
com.pushplaylabs.sidekick
com.vivaldi.Vivaldi
```

**Comms / docs / misc apps with per-app or per-domain behavior (note the `app:` and
`domain:` tagged entries — these gate the URL-aware completion path):**

```
domain:github.com
app:com.tinyspeck.slackmacgap   domain:slack.com   domain:app.slack.com
app:com.hnc.Discord            domain:discord.com
domain:notion.so
com.apple.MobileSMS            app:com.apple.MobileSMS
com.microsoft.teams / teams2 (+ .helper)   app:com.microsoft.teams2
com.google.Chrome
com.smallcubed.mailmaven
com.microsoft.Outlook          app:com.microsoft.Outlook
com.openai.atlas / com.openai.atlas.web
com.google.GeminiMacOS
com.apple.finder
com.microsoft.Word / Excel
com.apple.Preview
com.figma.Desktop / .DesktopBeta
com.runningwithcrayons.Alfred
at.obdev.LaunchBar
com.apple.systempreferences
com.serato.seratodj
com.moleskine.journey
com.apple.iWork.Pages / Keynote / Numbers   com.apple.Keynote / Numbers
com.bytedance.macos.feishu (+ .iron / .helper)
com.thebrain.dekutron
app:com.lukilabs.lukiapp (+ -setapp)   (Craft)
app:com.apple.mail
com.getcleanshot.app-setapp / pl.maketheweb.cleanshotx
```

(Some apps appear in more than one functional list — e.g. browsers also carry the
per-domain rules; iWork/Office apps are in a "needs special insertion workaround" set,
see 1.6.)

### 1.6 Per-app behavior + workaround store (`AppOverrides`) — VERIFIED schema

`AppOverrides` struct (swift-dump) — these are the per-app tunables/quirk-flags:

```
struct Cotypist.AppOverrides {
  completionsDisabled: Bool?
  midLineCompletionsDisabled: Bool?
  autocorrectDisabled: Bool?
  tabShortcutsDisabled: Bool?
  smartQuotesDisabled: Bool?
  textMirroringEnabled: Bool?            // shadow-buffer mode for AX-hostile fields
  ignoreSizeThresholds: Bool?
  emojiCompletionsDisabled: Bool?
  emojiSearchDisabled: Bool?
  requiresNonBreakingSpaceWorkaround: Bool?
  requiresSpaceKeyEventWorkaround: Bool?
  requiresPasteAndMatchStyleWorkaround: Bool?
  requiresBackspaceRightAfterPaste: Bool?
  stringInjectionChunkSize: Int?         // insert text in N-char chunks
  fontSizeAdjustmentFactor: Double?
  verticalAlignmentOffset: Double?
  needsEnhancedUserInterface: Bool?      // set AXEnhancedUserInterface on the app
  trainingDataCollectionDisabled: Bool?
  customInstructions: String?
}
```

Persistence (VERIFIED storage, INFERRED column layout): `AppOverridesStore` holds a
`GRDB.DatabaseQueue?`, an in-memory `Locked<[String:AppOverrides]>` cache keyed by bundle
id, and a `Locked<[UUID:([String:AppOverrides])->()]>` observer registry (KVO-style
change fan-out). Note the prompt's `AppOverrideRecord.createTable` was not found as a
literal string — GRDB Codable record persistence doesn't emit the column names as plain
cstrings, so the exact SQL/columns are not byte-verified. The functional schema is the
`AppOverrides` struct above plus a `bundleIdentifier`/`appBundleIdentifier` key column
(both strings present). `AppOverridesManager` wraps the store; `AppOverridesSettingsViewModel`
exposes `[OverrideEntry]` to the settings UI via Combine `@Published`.

The menu surface (VERIFIED strings): "Disable Completions in Application.",
"Enable temporarily disabled completions in Application.",
"…on Domain." → confirms both per-**app** and per-**domain** enable/disable, persisted
through this store.

### 1.7 Re-entrancy / synthetic-event safety (INFERRED + partial)

Cotypist injects text and must not re-read it as user input. typer solves this with an
`eventSourceUserData == syntheticMarker` tag (VERIFIED in typer source). For Cotypist this
is INFERRED from the presence of paste/insertion workaround flags
(`requiresPasteAndMatchStyleWorkaround`, `stringInjectionChunkSize`,
`requiresBackspaceRightAfterPaste`) and `pollingTemporarilySuspendedForPID` — strongly
implying it suspends its own AX/event observation around its insertions. Not byte-proven.

### 1.8 Crash isolation & recovery — Sentry (VERIFIED)

Sentry is linked and configured for stability telemetry, not just crashes:

```
enableWatchdogTerminationTracking            (SentryOptions property)
SentryClientInternal isWatchdogTermination:isFatalEvent:
appHangTimeoutInterval                       (SentryOptions)
SentryANRTrackerV1 / SentryANRTrackingIntegration / ANRDetected / ANRStopped
_reportAppHangs / enableReportNonFullyBlockingAppHangs / _appHangEventFilePath
shouldDisableAppHangTracking
```

So Cotypist ships: **app-hang (ANR) detection**, **watchdog-termination tracking**
(0x21/jetsam-style kills), and a `shouldDisableAppHangTracking` escape hatch (so its own
heavy model work isn't reported as a false hang). This gives them field telemetry on
exactly the "it gets flaky in app X" class of bugs. typer has no crash/hang telemetry.

### 1.9 Throttling / idle (VERIFIED strings, mechanism INFERRED)

`idleTimeout`/`setIdleTimeout:`/`cancelIdleTimeout`/`hasIdleTimeout`,
`_extraDataDelay`/`_extraDataIndex`/`_extraData`, `userIsActivelyTypingMidLine`,
`midLineCompletionsDisabled`. Indicates: debounced generation gated on an idle timer, a
delayed "extra data" (richer context) fetch, and suppression while the user is actively
typing mid-line. No explicit battery/`IOPS` symbol surfaced in the strings I pulled —
Cotypist's throttling appears keystroke/idle-driven, whereas typer additionally gates on
power source (`PowerState`).

---

## 2. Cotypist's Stability Architecture (synthesis)

1. **Bounded AX I/O.** Every AX round-trip is capped by `AXUIElementSetMessagingTimeout`,
   so a hung host can never block Cotypist's main thread.
2. **Defer-release observers.** All `AXObserver`s live in `AXObserverDeferredRelease`
   slots; reassigning/clearing a slot schedules the old observer's release on
   `DispatchQueue.main.asyncAfter`, never inline, so focus-change churn cannot re-enter AX
   teardown on a live callback stack. Teardown removes only the run-loop source and lets
   ARC release the observer — it never calls `AXObserverRemoveNotification`/`Invalidate`.
3. **Two monitors, many fine-grained observers.** `CompletionAccessibilityMonitor` and the
   completion store split concerns into separate observers
   (`…ForFocusedUIElement`, `…ForStarting`, `…ForCompletion`, `…ForResetting`,
   `_layoutChangeObserver`) so each can be re-pointed independently.
4. **Layered admissibility.** Static quirk lists (1.5) → temporary self-healing
   suppression `applicationsTemporarilyInadmissibleForAutomaticCompletion` ([bundle:Date])
   → per-PID circuit breaker `pollingTemporarilySuspendedForPID` → user per-app/per-domain
   toggles persisted in GRDB.
5. **Per-app quirk overrides.** `AppOverrides` carries ~19 flags so a single misbehaving
   app is fixed with a data flag (chunked insertion, paste-and-match-style, NBSP, extra
   backspace, enhanced-UI, alignment offsets) instead of a code branch.
6. **Field telemetry.** Sentry ANR + watchdog + app-hang tracking turns "flaky in app X"
   into a reported, attributable signal.

## 3. Failure modes it guards against

- Host app hung/slow during AX read → bounded by messaging timeout (typer: can block).
- Observer released re-entrantly on focus change → deferred release (typer: releases
  inline at `teardownAXObserver`, see Gap 4.2).
- Removing a notification on a dead element → simply never does it.
- Apps with their own completion UI fighting the ghost → IDE/editor suppression list.
- Secrets capture → password-manager list + (secure-field, see 4.3).
- Per-app insertion quirks (Electron/Word/Feishu) → `AppOverrides` workaround flags.
- A specific process going hostile → per-PID polling suspension, auto-clears on relaunch.
- Self-inflicted hang reports from model work → `shouldDisableAppHangTracking`.

## 4. typer Gap Analysis

**4.1 No AX messaging timeout (highest impact).** typer calls
`AXUIElementCopyAttributeValue`/parameterized reads (Caret/Context) with **no**
`AXUIElementSetMessagingTimeout`. A hung host (Electron/IDE) can stall typer's main
thread → exactly the "flaky/freezes in some apps" gripe.

**4.2 Inline observer teardown.** `TyperApp+AXObserver.swift:teardownAXObserver()` does
`CFRunLoopRemoveSource(...)` then `axObserver = nil` — releasing the observer
**synchronously**, and it's reachable from `updateAXObserver()` which is called on
app/focus switches. Plus it *does* call `AXObserverRemoveNotification` on the previously
observed element (lines 57-58) — on a focus change that element may already be dead, the
crash/hang vector Cotypist deliberately avoids importing.

**4.3 No secure-text-field role detection.** typer guards on
`IsSecureEventInputEnabled()` only (EventTap.swift:146, Completion.swift:90). That misses
non-secure-input password fields and secure web fields. There is no read of `AXRole ==
"AXSecureTextField"` / `AXSubrole` on the focused element. Cotypist additionally maintains
a password-manager bundle denylist.

**4.4 Tiny static denylist.** typer's `cfg.disabledApps` is empty by default;
`terminalBundleIDs` is 9 entries. No password managers, no IDE/own-autocomplete
suppression, no per-domain rules, no temporary/auto-expiring suppression, no per-PID
breaker.

**4.5 No per-app quirk overrides.** typer inserts text one way for all apps
(`insert()` synthesizes Unicode key events; `withPasteboard`/`postPaste` for paste).
No per-app chunk size, NBSP, paste-and-match-style, or extra-backspace handling →
guaranteed breakage in apps that need those (Word, Feishu, some Electron fields).

**4.6 No crash/hang telemetry.** No Sentry/ANR/watchdog. "Breaks in app X" can't be
diagnosed from the field.

**4.7 typer strengths to keep.** typer is already *ahead* in places: listen-only observer
tap that never gates global key delivery; accept tap enabled only while a suggestion shows;
idempotent `tapEnable` guards against the tapDisabled-echo CPU-spin; `syntheticMarker`
tagging; pasteboard snapshot/restore with `changeCount`; `PowerState` battery throttling
(Cotypist has no battery symbol). Don't regress these.

## 5. Concrete Recommendations (implementable)

**R1 — Bound every AX call. (do first)**
On creating any app/system-wide `AXUIElement` used for reads, call
`AXUIElementSetMessagingTimeout(element, 0.05)` (50 ms; Cotypist-style). Apply in
`TyperApp+Caret.swift` and `TyperApp+Context.swift` to the element you read from, and to
the application element in `updateAXObserver()`. Treat `kAXErrorCannotComplete` as "skip
this tick," never block.

**R2 — Adopt the defer-release pattern for the observer.**
Wrap `axObserver` so teardown does: `CFRunLoopRemoveSource(...)` now, then capture the old
`AXObserver` and `DispatchQueue.main.async { _ = old }` to drop it next loop turn. And
**stop calling `AXObserverRemoveNotification` on the previously focused element** in
`refreshObservedElement()` — instead, on a focus change, tear down and recreate the
observer (release deferred), or simply leave stale per-element registrations to die with
the deferred observer. Minimal wrapper:

```swift
final class DeferredAXObserver {
    private(set) var value: AXObserver?
    func set(_ new: AXObserver?) {
        let old = value
        value = new
        if let old { DispatchQueue.main.async { _ = old } } // release off the callback stack
    }
}
```

**R3 — Secure-field detection beyond IsSecureEventInputEnabled.**
Before generating, read the focused element's role/subrole and bail if secure:

```swift
func focusedFieldIsSecure(_ el: AXUIElement) -> Bool {
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
    if (roleRef as? String) == (kAXSecureTextFieldRole as String) { return true }
    var subRef: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef)
    return (subRef as? String) == "AXSecureTextField"
}
```
Gate `scheduleGenerate`/`showCompletion` on `!focusedFieldIsSecure(...)` in addition to
`IsSecureEventInputEnabled()`.

**R4 — Ship a default admissibility denylist + per-app/temporary suppression.**
Seed `cfg.disabledApps` (or a new `inadmissibleBundles`) with, at minimum, the password
managers and own-autocomplete apps below. Add a temporary, auto-expiring map
`[bundle: Date]` (mirror `applicationsTemporarilyInadmissibleForAutomaticCompletion`) and
a per-PID suspend set that clears on app relaunch, so a single bad interaction backs off
instead of hard-failing.

Always-off (password/secret managers):
```
com.1password.1password  com.agilebits.onepassword  com.apple.Passwords
com.lastpass.LastPass    com.lastpass.lastpassmacdesktop
com.dashlane.Dashlane    com.dashlane.dashlanephonefinal
com.bitwarden.desktop    com.keepersecurity.passwordmanager  com.callpod.keepermac.lite
com.sibersystems.RoboFormMac  com.nordsec.nordpass  in.sinew.Enpass-Desktop
me.proton.pass.electron  com.ascendo.DataVaultMac  com.mseven.msecuremac
com.symantec.NortonPasswordManager.combined  org.keepassx.keepassx
org.keepassxc.keepassxc  com.selznick.PasswordWallet
com.outercorner.Secrets  com.outercorner.Secrets-setapp
```
Own-autocomplete (suppress by default, user-overridable):
```
com.apple.dt.Xcode  com.microsoft.VSCode  com.microsoft.VSCodeInsiders
com.todesktop.230313mzl4w4u92 (Cursor)  com.exafunction.windsurf
com.jetbrains.intellij(.ce)  com.jetbrains.pycharm(.ce)  com.jetbrains.PhpStorm
com.jetbrains.CLion  com.jetbrains.goland-EAP  com.jetbrains.rider  com.jetbrains.rubymine
com.jetbrains.AppCode  com.google.android.studio  com.sublimetext.3  com.sublimetext.2
com.mathworks.matlab  org.rstudio.RStudio  com.tinyapp.TablePlus
```
(typer already covers terminals via `terminalBundleIDs`.)

**R5 — Per-app quirk overrides table.**
Add a small `AppOverrides`-style struct keyed by bundle id with the high-value flags:
`stringInjectionChunkSize`, `requiresPasteAndMatchStyleWorkaround`,
`requiresNonBreakingSpaceWorkaround`, `requiresBackspaceRightAfterPaste`,
`needsEnhancedUserInterface`, `verticalAlignmentOffset`, `midLineCompletionsDisabled`.
Persist as part of `TyperConfig`. This converts future "breaks in app X" reports into a
one-line data fix.

**R6 — Set `AXEnhancedUserInterface` for apps that need it.**
For apps flagged `needsEnhancedUserInterface`, set
`AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)`
so AX exposes a usable tree (notably some Electron/Chromium and older AppKit apps).

**R7 — Lightweight hang/crash telemetry (opt-in, local-first).**
Even without Sentry, add a main-thread watchdog (a `DispatchSourceTimer` that pings a
counter the main loop resets; log if it stalls > N ms) and a signal handler that records
the frontmost bundle id at crash time. That directly attributes "flaky in app X."

---

## 6. Caveats on rigor

- Bundle-id list groupings (1.5) are by `__cstring` adjacency + `app:`/`domain:` prefixes;
  the exact list-to-behavior mapping (which list = suppress vs. which = workaround) is
  INFERRED, not traced through code. The *membership* of each string is VERIFIED.
- `AppOverrideRecord.createTable` / GRDB column names are NOT byte-verified (GRDB Codable
  hides them); the `AppOverrides` field set (1.6) IS verified from swift-dump.
- Synthetic-event re-entrancy handling in Cotypist (1.7) is INFERRED from
  `pollingTemporarilySuspendedForPID` + insertion workaround flags; not disassembled.
- The deferred-release setter, the absence of `AXObserverRemoveNotification`/`Invalidate`,
  the presence of `AXUIElementSetMessagingTimeout`, the `AppOverrides` schema, the Sentry
  ANR/watchdog symbols, and every quoted bundle id are all VERIFIED from the binary.
