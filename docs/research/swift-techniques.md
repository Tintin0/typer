# Swift / AppKit best-practice techniques for typer

A precise, implementable reference for the macOS plumbing behind a caret-anchored,
inline ghost-text autocomplete app. Each section states what was **verified** from the
Cotypist binary (`/Applications/Cotypist.app/Contents/MacOS/Cotypist`) vs. what is
**inferred** or is **best-practice** guidance, and where typer already implements the
technique vs. where it has a gap.

Evidence convention:
- `[VERIFIED]` — string, imported symbol, or class name extracted from the Cotypist binary.
- `[INFER]` — reasoned from the binary plus API knowledge, not directly proven.
- `[BEST-PRACTICE]` — Apple-recommended approach where Cotypist is opaque.
- `[typer: …]` — current state of typer's source in `scripts/typer/`.

Tooling used: `ipsw macho info --strings`, `ipsw macho info --symbols`,
`ipsw class-dump`, `ipsw swift-dump`, `plutil -p Info.plist`.

---

## 1. Caret rect via Accessibility (`kAXBoundsForRangeParameterizedAttribute`)

**Evidence.** Cotypist imports both the C and AppKit constants:

```
(undefined) external  _AXUIElementCopyParameterizedAttributeValue   (ApplicationServices)
(undefined) external  _AXValueCreate                                 (ApplicationServices)
(undefined) external  _NSAccessibilityBoundsForRangeParameterizedAttribute (AppKit)
```
`[VERIFIED]` It uses the parameterized AX API with a `CFRange` packed into an `AXValue`,
exactly the technique below. (The AX attribute *names* are framework constants, so they
do **not** appear as literal strings — absence of a `"kAXBoundsForRange…"` string is
expected, not evidence against.)

`[typer: implemented]` — `TyperApp+Caret.swift` already does this well, including a
5-step fallback ladder (selection rect → zero-length caret → previous-glyph anchor →
next-glyph anchor → paragraph back-scan) and a separate WebKit/Chromium
`AXSelectedTextMarkerRange` + `AXBoundsForTextMarkerRange` path. This section documents
the canonical form so the technique is captured and the gotchas are explicit.

### Canonical caret-rect read

```swift
import ApplicationServices

/// Caret rect for the focused element, in AX coordinates (global, TOP-LEFT origin).
func axCaretRect(_ element: AXUIElement) -> CGRect? {
    // 1. Read the selected range (an AXValue wrapping a CFRange).
    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rangeVal = rangeRef else { return nil }
    var sel = CFRange(location: 0, length: 0)
    guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &sel), sel.location >= 0
    else { return nil }

    // 2. For a collapsed caret, ask for the bounds of a ZERO-LENGTH range at the caret.
    //    Many apps answer; some return (0,0,0,0) — fall back to the previous glyph.
    var probe = CFRange(location: sel.location, length: 0)
    guard let rangeAX = AXValueCreate(.cfRange, &probe) else { return nil }
    var boundsRef: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeAX, &boundsRef) == .success,
          let boundsVal = boundsRef else { return nil }
    var rect = CGRect.zero
    guard AXValueGetValue(boundsVal as! AXValue, .cgRect, &rect) else { return nil }
    return rect   // top-left, global; convert before handing to AppKit (see §1.2)
}
```

**Failure handling that matters** (all of these are real in the wild and typer handles them):
- `(0,0,0,0)` / NaN origin → reject, try the previous-glyph anchor at `location-1, len 1`
  and use that rect's `maxX` as the caret x.
- Whole-text-view bounds (width > ~2000) → reject; it's the field, not the caret.
- Zero-width caret (collapsed) → synthesize width 1 at the rect's `minX`.
- Validate the rect is on *some* `NSScreen` before trusting it.

### 1.2 AX → borderless overlay coordinate conversion (the critical part)

AX (and CGEvent / `CGDisplayBounds`) report **global, top-left origin** anchored at the
top-left of the **primary** display. AppKit (`NSWindow.setFrame`, `NSScreen.frame`) uses
**bottom-left origin** anchored at the bottom-left of that same primary display. The flip
must use the **primary screen's height**, never the local screen the rect lands on —
using the local screen's `maxY` is the classic multi-monitor bug.

```swift
func axRectToAppKit(_ rect: CGRect) -> CGRect {
    // Primary = the screen whose origin is (0,0).
    let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
    let primaryMaxY = primary?.frame.maxY ?? rect.maxY
    return CGRect(x: rect.origin.x,
                  y: primaryMaxY - rect.origin.y - rect.height,
                  width: rect.width, height: rect.height)
}
```

**Retina gotcha.** AX rects are in **points**, not pixels — do **not** divide by
`backingScaleFactor`. (Cotypist references `backingScaleFactor` `[VERIFIED]`, but that is
for its screen-capture/OCR pixel math, not for AX caret placement.) Pixel scaling only
enters when you go through ScreenCaptureKit/Vision, where bounding boxes are normalized
0–1 and you multiply by the *captured* frame size (§3).

`[typer: implemented]` — `axRectToAppKit` in `TyperApp+Caret.swift` is exactly this, and
the off-main capture path correctly snapshots `primaryMaxY` on the main thread (NSScreen
is main-affine) so it can do the flip on a background queue without touching NSScreen.

---

## 2. Click-through, non-activating overlay `NSWindow` for ghost text

**Evidence.** `[VERIFIED]` Cotypist calls `setIgnoresMouseEvents:` and
`setCollectionBehavior:` and reads `collectionBehavior` — i.e. it uses the same panel
recipe.

`[typer: implemented]` — `SuggestionOverlay.swift` is an `NSPanel` subclass with the
correct mask and flags. Documented here as the reference recipe.

```swift
final class SuggestionOverlay: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel],   // never key/main
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true          // clicks pass straight through to the app
        level = .statusBar                  // above normal windows, below the menu bar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hidesOnDeactivate = false           // stay up while another app is frontmost
        orderOut(nil)
    }
    // Belt-and-suspenders: even if shown, refuse focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

**Showing without stealing focus.** Use `orderFrontRegardless()` (not
`makeKeyAndOrderFront:`). Combined with `.nonactivatingPanel` + `canBecomeKey=false`,
the ghost never activates typer or pulls the host app out of focus.

**Level choice.** `.statusBar` (== `NSWindow.Level.statusBar`) renders above ordinary
windows. If you need it over full-screen apps too, `.canJoinAllSpaces` +
`.fullScreenAuxiliary` in `collectionBehavior`. Avoid `.popUpMenu`/`.screenSaver` levels —
they can sit over the menu bar and system UI, which is intrusive and can trip Stage
Manager edge cases.

`[BEST-PRACTICE]` Keep one persistent panel and reposition it (`setFrame(_:display:)`),
rather than creating/destroying per keystroke — window creation churns the WindowServer
and causes flicker. typer already reuses a single panel.

---

## 3. ScreenCaptureKit single-frame sub-rect capture (macOS 14+)

**Evidence.** `[VERIFIED]` Cotypist imports `SCContentFilter`, `SCStreamConfiguration`,
`SCShareableContent` and *also* `_CGWindowListCreateImage` (kept as a fallback). The
string `"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"`
`[VERIFIED]` is its deep-link to the Screen Recording pane.

`[typer: implemented]` — `TyperApp+Context.swift` uses `SCScreenshotManager.captureImage`
with `SCContentFilter(desktopIndependentWindow:)`, `sourceRect`, and a `scale` knob.
This is the modern, correct approach. Reference + the specific efficiency levers:

```swift
@available(macOS 14.0, *)
func captureWindowRegion(pid: pid_t, clip: CGRect?, scale: CGFloat) async -> CGImage? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true) else { return nil }
    guard let win = content.windows
            .filter({ $0.isOnScreen && $0.owningApplication?.processID == pid })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    else { return nil }

    let filter = SCContentFilter(desktopIndependentWindow: win)   // one window only
    let cfg = SCStreamConfiguration()
    cfg.showsCursor = false
    if let clip {                                  // capture ONLY a sub-rect:
        let local = clip.intersection(win.frame)   // window-local coords for sourceRect
        cfg.sourceRect = CGRect(x: local.minX - win.frame.minX,
                                y: local.minY - win.frame.minY,
                                width: local.width, height: local.height)
        cfg.width  = max(8, Int(local.width  * scale))   // output pixel dims
        cfg.height = max(8, Int(local.height * scale))
    }
    return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}
```

**Why this is fast (the levers):**
- `sourceRect` restricts capture to a thin band around the caret line — typer narrows the
  focused element's bounds to ~4 line-heights, a ~10× smaller image than the whole window.
- `cfg.width/height` < native = downsample in the capture itself. Vision OCR cost scales
  with pixel count, so `scale = 0.5` is ~4× cheaper with no body-text accuracy loss.
- `SCScreenshotManager.captureImage` returns a single frame — no `SCStream` lifecycle,
  no delegate, no `startCapture/stopCapture`. Use it for screenshots; reserve `SCStream`
  for continuous capture (we never need that).

**`CGWindowListCreateImage` fallback** `[VERIFIED present in Cotypist]`: it is soft-
deprecated on Sonoma+ and on recent OSes returns black/empty without Screen Recording
permission, but it still works as a pre-14 path. Gate by `if #available(macOS 14.0, *)`.

**Throttling** `[typer: implemented]`: recompute only when stale (>4 s) or after
meaningful typing drift (>24 chars), single-flight with a `computing` bool, and
extrapolate the caret x horizontally between captures using a measured char width. Never
capture on the synchronous keystroke path.

### 3.1 TCC Screen Recording permission + the re-grant-after-rebuild gotcha

```swift
import CoreGraphics
let granted = CGPreflightScreenCaptureAccess()   // non-prompting check
if !granted { CGRequestScreenCaptureAccess() }    // one-time system prompt
// Deep link if they decline:
NSWorkspace.shared.open(URL(string:
  "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
```
`[typer: implemented]` — `OnboardingWindow.swift` / `TyperApp.swift` already use
`CGPreflightScreenCaptureAccess` + `CGRequestScreenCaptureAccess` + the deep link.

**The rebuild gotcha** (both apps hit this): TCC keys the grant on the app's **code-
signing designated requirement**. An **ad-hoc** signature (`codesign -s -`) changes
identity on every rebuild, so macOS revokes Accessibility *and* Screen Recording after
each build. `[VERIFIED]` Cotypist ships onboarding copy telling users to remove and
re-add the app via the "−"/drag-icon dance. **typer's real fix is better and already in
place**: `scripts/build.sh` signs with a *stable self-signed identity* (`Typer
Self-Signed`) so the designated requirement is constant and the grant persists across
rebuilds. Keep using that; never fall back to ad-hoc for a build users keep.

---

## 4. Disabling Apple's inline text-prediction clash

**Evidence.** `[VERIFIED]` Cotypist has a whole onboarding controller for this:
```
_TtC8Cotypist33InlinePredictionDisableController
InlinePredictionDisableController.disableButtonAction
"NSAutomaticInlinePredictionEnabled"
inlinePredictionEnabledAtPresentation / inlinePredictionDisabled / inlinePredictionCheckbox
```

**The key truth for an AX-based app.** `isAutomaticInlinePredictionEnabled` is an
*instance* property of `NSTextInputContext` — an app sets it on **its own** input
context. An external, AX-driven app (typer, Cotypist) has **no API to disable another
app's inline prediction**, because it does not own that text view's input context. The
only lever is the **global** user default `NSAutomaticInlinePredictionEnabled` in
`NSGlobalDomain`, which backs *System Settings → Keyboard → Edit → "Show inline
predictive text"* (macOS 14.2+).

So Cotypist's `InlinePredictionDisableController` is exactly that: a UI that detects the
clash and **guides the user to turn the system feature off** (and re-checks the default
to confirm). It does **not** silently flip another app's setting.

`[INFER]` Detection of the current state:
```swift
let enabled = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?
    ["NSAutomaticInlinePredictionEnabled"] as? Bool ?? true
```
`[BEST-PRACTICE]` Do **not** `defaults write` this on the user's behalf — it's a global
setting and writes to managed domains are unreliable/sandbox-hostile. Show an onboarding
step (as Cotypist does) with a checkbox that reflects the live value and a button that
deep-links to the Keyboard pane.

`[typer: GAP]` typer has no inline-prediction-clash detector. **Recommendation:** add an
onboarding/menu check that reads the global default and, if inline prediction is on, shows
a one-line warning + a "Open Keyboard settings" button. This directly removes the most
visible competing-ghost-text artifact.

---

## 5. Detecting secure text fields & password-manager windows to suppress

**Evidence.** `[VERIFIED]` Cotypist embeds a hard-coded denylist of password-manager
bundle IDs (found as adjacent strings in the binary):
```
com.1password.1password          com.agilebits.onepassword
com.apple.Passwords              com.bitwarden.desktop
com.lastpass.LastPass            com.lastpass.lastpassmacdesktop
com.dashlane.Dashlane            com.dashlane.dashlanephonefinal
com.keepersecurity.passwordmanager   com.callpod.keepermac.lite
com.nordsec.nordpass             com.mseven.msecuremac
com.symantec.NortonPasswordManager.combined
com.ascendo.DataVaultMac         com.selznick.PasswordWallet
```
It also has `SecureCenteredTextFieldCell` `[VERIFIED]` (for its own secure inputs).

**Two complementary suppression layers — implement both:**

**(a) Per-keystroke secure-input check** — works for *any* app's password field, no
denylist needed:
```swift
import Carbon
if IsSecureEventInputEnabled() { return }   // a secure field is focused somewhere
```
This is the strongest signal: macOS sets secure event input when a password field has
focus, which also (correctly) means typer's CGEvent tap won't even see the characters.
`[typer: implemented]` — used in `TyperApp+Completion.swift` and `captureTopic()`.

**(b) Focused-element role check** — finer-grained, catches secure fields that don't
raise global secure input:
```swift
func isSecureField(_ el: AXUIElement) -> Bool {
    var role: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
    if (role as? String) == (kAXSecureTextFieldRole as String) { return true }   // "AXSecureTextField"
    // Subrole catches secure fields wrapped in generic roles:
    var sub: CFTypeRef?
    AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &sub)
    return (sub as? String) == "AXSecureTextField"
}
```

**(c) Bundle denylist** — for whole password-manager apps where even the username/notes
fields are sensitive (Cotypist's approach). Reuse typer's existing `cfg.disabledApps`
mechanism but seed it with a built-in `passwordManagerBundleIDs` set (the list above).

`[typer: GAP]` typer has `IsSecureEventInputEnabled` (a) and a user-editable
`disabledApps` set, but **not** the `kAXSecureTextFieldRole` role check (b) nor a built-in
password-manager denylist (c). **Recommendation:** add both — they're a few lines and
close real privacy gaps (e.g. a secure field that doesn't trigger global secure input,
and password managers' non-password fields).

---

## 6. Sparkle 2 integration for a non-App-Store app

**Evidence.** `[VERIFIED]` from `Info.plist`:
```
SUFeedURL                = https://cotypist.app/updates/cotypist.xml
SUPublicEDKey            = ad5nJhJt8CuRUbH3Uz/lP48d7unnj6CpKd0y9oFVyMI=
SUEnableAutomaticChecks  = true
SUScheduledCheckInterval = 7200          (2 hours)
```
Plus a bundled `Sparkle.framework`, the appcast/version-history delegate selectors
(`standardUserDriverShowVersionHistoryForAppcastItem:`, `SUAppcastItem`,
`SPUUserUpdateState`), and `http://sparkle-project.org/`. `[VERIFIED]` This is a textbook
Sparkle 2 setup with **EdDSA (Ed25519)** signing (the `SUPublicEDKey` is the base64
public key).

`[typer: GAP — has only a git-pull "check for updates"]`. typer stamps `TyperRepoPath` /
`TyperGitCommit` into Info.plist and updates by pulling the repo. For a distributed
binary, adopt Sparkle 2.

### Reference setup

```swift
import Sparkle

final class Updater {
    // Standard controller wires the UI driver + checks SUFeedURL/SUPublicEDKey from Info.plist.
    let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }
}
```

**Info.plist keys** (mirror Cotypist):
```xml
<key>SUFeedURL</key><string>https://typer.…/appcast.xml</string>
<key>SUPublicEDKey</key><string>BASE64_ED25519_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
```

**EdDSA signing flow** (Sparkle's `bin/` tools):
1. `./bin/generate_keys` once → stores the **private** key in the login Keychain and
   prints the **public** key → paste into `SUPublicEDKey`. Never commit the private key.
2. Build + zip the `.app` (or make a DMG).
3. `./bin/sign_update Typer-1.2.3.zip` → prints `sdsa:"…" length="…"`; paste into the
   `<enclosure>` of the appcast item.

**Self-hosted `appcast.xml`** (RSS + Sparkle namespace):
```xml
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
 <channel>
  <item>
   <title>Version 1.2.3</title>
   <sparkle:version>1230</sparkle:version>                  <!-- CFBundleVersion -->
   <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
   <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
   <enclosure url="https://typer.…/Typer-1.2.3.zip"
              length="12345678" type="application/octet-stream"
              sparkle:edSignature="BASE64_SIG_FROM_sign_update"/>
  </item>
 </channel>
</rss>
```
`[BEST-PRACTICE]` Sparkle requires the app to be **signed** (the stable cert from
`make_signing_cert.sh` is fine for self-distribution; notarization is needed only to
avoid Gatekeeper friction for the public). Serve appcast + zip over HTTPS.

---

## 7. AXObserver lifecycle (run-loop sources, deferred release, focus churn)

**Evidence.** `[VERIFIED]` Cotypist has a dedicated class
`_TtC8Cotypist25AXObserverDeferredRelease` — a strong signal that **releasing an
`AXObserver` synchronously inside its own callback is unsafe**, and they wrap teardown to
defer the release off the current callback frame. This is a real and subtle bug class.

`[typer: implemented, with one hardening opportunity]` — `TyperApp+AXObserver.swift`
creates the observer, adds its run-loop source on the main run loop, observes
`kAXFocusedUIElementChangedNotification` app-wide and `kAXValueChanged` /
`kAXSelectedTextChanged` per focused element, and tears down on PID change. Reference +
the deferred-release lesson:

```swift
func updateAXObserver() {
    guard AXIsProcessTrusted() else { return }
    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    guard pid != axObserverPID else { refreshObservedElement(); return }
    teardownAXObserver()
    var obs: AXObserver?
    let cb: AXObserverCallback = { _, element, note, refcon in
        let app = Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue()
        app.handleAXNotification(note as String, element: element)
    }
    guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return }
    axObserver = obs; axObserverPID = pid
    CFRunLoopAddSource(CFRunLoopGetMain(),
                       AXObserverGetRunLoopSource(obs), .defaultMode)   // schedule once
    let appEl = AXUIElementCreateApplication(pid)
    AXObserverAddNotification(obs, appEl,
        kAXFocusedUIElementChangedNotification as CFString,
        Unmanaged.passUnretained(self).toOpaque())
    refreshObservedElement()
}
```

**Best-practice rules (the leak/crash traps):**
- **Per-element subscriptions**, not app-wide, for `kAXValueChanged` /
  `kAXSelectedTextChanged` — these must be re-registered on every focus change. On focus
  churn, *remove the old element's notifications before adding the new one* (typer does
  this) or the observer accumulates dead registrations → leaks + spurious callbacks.
- **Remove the run-loop source on teardown** (`CFRunLoopRemoveSource`) before dropping
  the observer; typer does.
- **Deferred release** `[VERIFIED via Cotypist]`: never let an `AXObserver` (or the
  element refs it holds) be deallocated *inside* its own callback. If teardown can be
  triggered from a notification, dispatch the release to the next main-runloop tick:
  ```swift
  let dying = axObserver; axObserver = nil
  DispatchQueue.main.async { _ = dying }   // release after the callback frame unwinds
  ```
  typer tears down only on PID change (outside the callback), so it's currently safe — but
  if you ever call `teardownAXObserver()` from inside `handleAXNotification`, adopt the
  deferred pattern.
- **Coalesce bursts**: apps emit several notifications per keystroke. typer sets an
  `axNotifyPending` flag and re-anchors once on the next tick — keep that.
- **Always use `Unmanaged.passUnretained(self)`** as the refcon and keep `self` alive for
  the observer's lifetime (it is, since `TyperApp` is the app delegate). Do not
  `passRetained` unless you balance it — that's a guaranteed leak.

---

## 8. Vision OCR (`VNRecognizeTextRequest`) — efficient usage + caching

**Evidence.** `[VERIFIED]` `Cotypist/VNRecognizeTextRequest+Transcript.swift`,
`performOCR(on:textFieldXRange:)`, `setRecognitionLevel:`, `setUsesLanguageCorrection:`,
import of `VNRecognizeTextRequest`. `[INFER]` It tunes recognition level and language
correction per use-case (matching what typer does).

`[typer: implemented well]` — `TyperApp+Context.swift` runs two distinct OCR profiles:

```swift
// A) Reading window/screen content for prompt context — accuracy matters:
req.recognitionLevel   = .accurate
req.usesLanguageCorrection = true
req.minimumTextHeight  = 0.012        // skip tiny chrome (badges, counters)

// B) Locating the caret by matching the typed tail — speed matters, glyphs don't:
req.recognitionLevel   = .fast
req.usesLanguageCorrection = false
```

**Efficiency levers (all in use; documented for completeness):**
- **`minimumTextHeight`** (normalized) prunes sub-pixel UI chrome before recognition runs.
- **Downsample the input** (`scale 0.5` via `SCStreamConfiguration.width/height`) before
  Vision — cost is ~linear in pixels.
- **Confidence gate** (`topCandidates(1).first.confidence >= 0.5`) + a heuristic
  `isLikelyText` filter to keep glyph-soup/numeric chrome out of the prompt.
- **`recognitionLanguages`** `[BEST-PRACTICE add]`: if the user is monolingual, set
  `req.recognitionLanguages = ["en-US"]` — fewer language models loaded = faster.
- **`VNImageRequestHandler`** is single-use; create per frame. The handler/request setup
  is cheap relative to `perform`.

**Caching** `[typer: implemented]`: `cachedBackground` keyed by `activeAppKey` with a
time + drift TTL, single-flighted via `backgroundRefreshing`. The caret OCR similarly
caches `shotCaretPoint` and extrapolates between captures. `[BEST-PRACTICE]` Prefer clean
**AX text** over OCR whenever the AX value is non-trivial (typer only OCRs when AX yields
< ~120 chars) — OCR is the noisy last resort.

---

## 9. "Let's Move to /Applications" (PFMoveApplication)

**Evidence.** `[VERIFIED]` Cotypist embeds the canonical LetsMove strings verbatim:
```
"Move to Applications folder?"
"I can move myself to the Applications folder if you'd like."
"Move to Applications Folder"
"INFO -- Moving myself to the Applications folder"
"WARNING -- Could not delete application after moving it to Applications folder"
"Note that this will require an administrator password."
```
This is Andy Kim's **LetsMove / `PFMoveApplication()`** library, included to nudge users
who run the app from `~/Downloads` or a mounted DMG into `/Applications`.

`[typer: GAP]` — typer builds straight into `~/Applications/Typer.app`, so it's less
critical, but for a *distributed* DMG build it matters: running from a read-only DMG
breaks Sparkle updates and re-prompts TCC on every launch.

**Two options:**
1. **Vendor LetsMove** and call `PFMoveApplication()` from `applicationWillFinishLaunching`
   (must run *before* the first window/permission prompt).
2. **Re-implement** (no dependency):
```swift
func offerMoveToApplications() {
    let bundleURL = Bundle.main.bundleURL
    let apps = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first!
    let dest = apps.appendingPathComponent(bundleURL.lastPathComponent)
    // Already in /Applications, or running from a translocated path? Skip.
    guard !bundleURL.path.hasPrefix(apps.path) else { return }
    let a = NSAlert()
    a.messageText = "Move Typer to the Applications folder?"
    a.informativeText = "Typer works best from /Applications — updates and permissions stick."
    a.addButton(withTitle: "Move to Applications Folder")
    a.addButton(withTitle: "Do Not Move")
    guard a.runModal() == .alertFirstButtonReturn else { return }
    try? FileManager.default.moveItem(at: bundleURL, to: dest)   // may need authorization
    let cfg = NSWorkspace.OpenConfiguration(); cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
```
`[BEST-PRACTICE]` Watch **Gatekeeper App Translocation**: an unsigned/quarantined app run
from Downloads executes from a random read-only path, so `bundleURL` won't be the real
location. The stable signature (already used) plus moving to `/Applications` clears
translocation. LetsMove handles this case; the hand-rolled version should detect a
`/private/var/folders/.../AppTranslocation/` prefix and always offer the move then.

---

## Cross-cutting: what typer already nails vs. concrete gaps

Already implemented to a high standard (documented above as reference): AX caret with
fallback ladder + WebKit text-marker path (§1), correct primary-screen coordinate flip
(§1.2), non-activating click-through panel (§2), SCK sub-rect single-frame capture with
sourceRect + downscale + throttling (§3), stable-signature TCC persistence (§3.1),
secure-input gating via `IsSecureEventInputEnabled` (§5a), AXObserver with per-element
re-subscription and burst coalescing (§7), dual-profile Vision OCR with caching and
AX-preferred fallback (§8).

Concrete gaps worth closing (each is small and high-value):
1. **§4** — inline-prediction-clash detector + onboarding nudge (read global
   `NSAutomaticInlinePredictionEnabled`, deep-link to Keyboard pane). Removes the most
   visible competing ghost-text artifact.
2. **§5b/5c** — `kAXSecureTextFieldRole`/subrole check + built-in password-manager bundle
   denylist (the 15 IDs verified from Cotypist). Privacy hardening.
3. **§6** — Sparkle 2 for binary distribution (EdDSA keys, self-hosted appcast).
4. **§9** — LetsMove / `PFMoveApplication` for DMG distribution (translocation-aware).
