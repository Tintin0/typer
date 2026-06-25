import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

final class TyperApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = TyperConfig.load()
    var router: ModelRouter!
    // Which model served the in-flight generation, so the training record and the
    // ratchet attribute the eventual accept/reject to the model that produced it.
    var routedModel: ModelRouter.Pick = .a
    var routedModelName = ""
    var statusItem: NSStatusItem!
    var popover: NSPopover?
    var popoverTargetAppKey = ""        // the app you were in when the popover opened (before
                                        // it activated Typer) — for the "Disable in <app>" row
    var updateInProgress = false        // a "Check for updates" run is mid-flight (guards re-entry)
    lazy var menuModel: MenuModel = { let m = MenuModel(); m.app = self; return m }()
    var onboarding: OnboardingController?     // first-launch onboarding window, while shown
    let overlay = SuggestionOverlay()
    var observerTap: CFMachPort?        // listen-only: never gates input delivery
    var acceptTap: CFMachPort?          // consuming: enabled only while a suggestion shows
    var acceptTapEnabled = false        // mirror of the tap's enable state (avoid redundant mach calls)
    var buffer = ""
    var lastInput = Date()
    // Timed snooze (#3). Deadline model, not a timer: a global pause-until and a per-app
    // pause-until map, both ephemeral (no persistence). `completionsAllowed(bundle:)` is the
    // chokepoint the completion path (W2B) and status title (W2A) consult.
    var allCompletionsDisabledUntil: Date?
    var perAppDisabledUntil: [String: Date] = [:]
    var activeAppKey = "unknown"
    var buffersByApp: [String: String] = [:]
    var lastInputByApp: [String: Date] = [:]
    var debounce: Timer?
    // The accept tap is enabled exactly while a suggestion is on screen, so Typer is
    // out of the keystroke-consuming path the rest of the time.
    var active: Correction? { didSet { refreshAcceptTap() } }            // typo/grammar diff
    var completion: ActiveCompletion? { didSet { refreshAcceptTap() } } // inline completion
    var lastCaretPoint: NSPoint?
    var lastCaretHeight: CGFloat = 18   // caret line height, to match the app's font
    var reanchorWork: DispatchWorkItem? // deferred AX caret re-anchor after a keystroke
    var settleWork: DispatchWorkItem?   // late authoritative re-anchor (corrects drift)
    var caretHeightFloor: CGFloat?      // smallest caret height seen this focus session
    // Which caret-geometry API the frontmost app actually answers (AXTextMarker for
    // WebKit/Chromium, AXBoundsForRange for native AppKit). Remembered per bundle so
    // every caret read doesn't pay failing IPC round-trips probing the wrong one.
    enum CaretPath { case marker, bounds }
    var caretPathByBundle: [String: CaretPath] = [:]
    // Screenshot-based caret cache for apps without AX caret geometry. We compute it
    // occasionally (it is slow) and extrapolate horizontally as the user types.
    var shotCaretPoint: NSPoint?
    var shotCaretAt = Date.distantPast
    var shotCaretBufferLen = 0
    var shotCaretCharWidth: CGFloat = 9
    var shotCaretHeight: CGFloat = 18
    var shotCaretApp = ""
    var shotCaretComputing = false
    // Click-to-anchor caret seed: a left-click places the caret where you clicked. We
    // record that screen point (AppKit coords) and extrapolate horizontally by typed
    // width, so AX-hostile fields (Electron/web) get accurate placement with no capture.
    var clickCaretPoint: NSPoint?       // the click point (line center, AppKit coords)
    var clickCaretAt = Date.distantPast
    var clickCaretApp = ""
    var clickCaretBufferLen = 0
    // Set by recordClickCaret, consumed by the deferred resync that stamps the anchor's
    // app + buffer baseline. A plain time guard mis-fired: a paste/⌘Z resync within the
    // window would re-baseline a stale anchor, and the synchronous syncActiveApp on a
    // cross-app click would clear the just-made anchor before it could be stamped. The
    // flag scopes both to an actual click.
    var clickCaretPending = false
    // Speculative prefetch: the next chunk, generated while the user finishes the
    // current one, so it can appear instantly on exhaustion.
    var prefetched: ActiveCompletion?
    var prefetchKey = ""
    var prefetchInFlight = false
    // Single-flight generation: at most one request in the helper at a time.
    var requestInFlight = false
    var rerequestNeeded = false
    // Brief window after a Tab/backtick accept exhausts the suggestion during which
    // further Tabs are swallowed (the user is asking for more, not tabbing focus away)
    // while the next chunk generates.
    var acceptGraceUntil = Date.distantPast
    // Style sample cached between generations: recomputing it per keystroke both costs
    // main-thread time and changes the prompt's middle, which would invalidate the
    // helper's KV prefix cache on every request.
    var cachedStyleSample = ""
    var styleSampleAt = Date.distantPast
    var styleSampleChars = 0
    // Monotonic invalidation token. User typing advances it; mouse/cursor placement
    // advances it too, which cancels stale in-flight completions without scheduling a
    // new one. This prevents "I only clicked in a text box and Typer suggested".
    var generationSerial: UInt64 = 0
    var lastUserTypedAt = Date.distantPast
    var lastTrailing = ""               // text right after the caret (for repeat-drop)
    var pasteboardBusy = false          // serialize clipboard save/paste/restore (typo fallback)
    let syntheticMarker: Int64 = 0x747970_725f696e   // tag on our injected events ("typr_in")
    var stats = TyperStats.load()       // cumulative, persisted across launches
    var statsSaveScheduled = false
    let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    // Broader context: an expensive-to-compute "background" (window scrollback +
    // screen OCR + clipboard) is cached and refreshed off the hot path, never per
    // keystroke. Style memory personalizes regardless of app.
    let styleMemory = StyleMemory()
    let topicMemory = TopicMemory()
    // Personalization: the user's own vocabulary (biases sampling toward their words)
    // and their accept/reject history (adapts suggestion length + confidence gate).
    let lexicon = PersonalLexicon()
    let feedback = FeedbackMemory()
    // Opt-in training-data capture (see TrainingLog). `pendingTraining` holds a shown
    // suggestion's context until it resolves (accepted/rejected), then one record is
    // written. The prefetch stash lets a promoted prefetch be logged with the context
    // it was actually generated for. All no-ops unless cfg.trainingLogEnabled.
    let trainingLog = TrainingLog()
    var pendingTraining: PendingTrainingExample?
    var prefetchTrainImmediate = ""
    var prefetchTrainConf = 0.0
    var trainingModelNameCache = ""
    // How far into each app's buffer the lexicon has already learned, so repeated
    // flushes (app switches, clicks) never double-count the same typed words.
    var lexiconWatermark: [String: Int] = [:]
    // Ghost width calibration: ratio of the host app's real text advance to our
    // SF-font estimate, learned per bundle from settled AX caret reads. 1.0 until
    // measured; this is what keeps the ghost from sitting on the word being typed
    // in apps whose font is wider than our guess.
    var widthScaleByBundle: [String: CGFloat] = [:]
    var calibAnchor: NSPoint?           // last authoritative caret fix
    var calibPredicted: CGFloat = 0     // UNSCALED predicted advance since the anchor
    // AXObserver: event-driven re-anchoring. The host app tells us the instant it
    // applied an edit, instead of us guessing with fixed timers.
    var axObserver: AXObserver?
    var axObserverPID: pid_t = 0
    var axObservedElement: AXUIElement?
    var axNotifyPending = false
    var topicTimer: Timer?
    var topicCapturing = false
    var cachedBackground = ""
    var backgroundRefreshedAt = Date.distantPast
    var backgroundKey = ""
    var backgroundRefreshing = false
    let backgroundQueue = DispatchQueue(label: "typer.background", qos: .utility)
    // Opt-in stability telemetry (spec D.6): a main-thread watchdog + a crash bundle-id
    // recorder. The watchdog increments a beat counter off the main thread and a 1 Hz
    // main-loop tick resets it; if the beat advances without a reset, the main thread is
    // stalled and we log the frontmost bundle id. Off unless cfg.debugLogging.
    var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "typer.watchdog", qos: .utility)
    private var mainBeat = 0          // bumped by the main loop; read by the watchdog
    private var watchdogLastBeat = 0  // last value the watchdog saw the main loop ack
    private var watchdogStalls = 0    // consecutive missed beats (debounces a one-off hitch)

    // Drain the learning + training stores synchronously on quit. Their normal saves
    // are debounced / fire-and-forget on utility queues, so a plain ⌘Q would otherwise
    // drop the last debounce window of feedback/router state and the tail of training
    // capture. flush() on each is synchronous and idempotent.
    func applicationWillTerminate(_ notification: Notification) {
        stats.save()
        feedback.flush()
        router?.flush()
        trainingLog.flush()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Offer to relocate into /Applications before anything else (no-op until W2C, and a
        // no-op when already in /Applications). Must run before onboarding/permission prompts.
        maybeOfferMoveToApplications()
        debugLoggingEnabled = cfg.debugLogging
        // Enforce private perms even on a pre-existing log file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: typerLogURL.path)
        // Style memory may contain personal writing — keep it private too.
        let styleURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/typer/style.txt")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: styleURL.path)
        log("Typer launch cfg enabled=\(cfg.enabled) completion=\(cfg.completionEnabled) typo=\(cfg.typoEnabled) debounce=\(cfg.debounceMs) debugLog=\(cfg.debugLogging)")
        activeAppKey = currentAppKey()
        log("initial app=\(activeAppKey)")
        router = ModelRouter(cfg: cfg)
        routedModelName = router.defaultName
        promptAccessibility()
        if (cfg.screenContextEnabled || cfg.topicMemoryEnabled), !CGPreflightScreenCaptureAccess() {
            // Triggers the one-time Screen Recording permission prompt. OCR/topic capture
            // simply stays empty until granted; everything else keeps working.
            CGRequestScreenCaptureAccess()
            log("requested Screen Recording access (for screen capture)")
        }
        setupMenu()
        // First launch: walk the user through permissions + model choice before anything else.
        if !cfg.onboardingComplete { showOnboarding() }
        setupEventTap()
        updateAXObserver()
        startTopicTimer()
        // Opt-in local hang/crash telemetry (spec D.6): no Sentry, no network — just the
        // private log. Gated on debugLogging so it's strictly opt-in. Attributes the
        // "flaky in app X" class of bugs by recording the frontmost bundle id on a
        // main-thread stall or a fatal signal.
        if cfg.debugLogging { startStabilityTelemetry() }
        // Seed the spell checker with the user's already-learned vocabulary so their
        // jargon isn't flagged from the first keystroke (off the hot path).
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.syncLexiconToSpellChecker() }
        // Only spin up the model if inline completion is actually on (typo correction
        // is local-only). If it's off, the helper stays unspawned until it's enabled.
        if cfg.enabled, cfg.completionEnabled {
            DispatchQueue.global(qos: .utility).async { self.router.warmUp() }
        }
    }

    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("AX trusted=\(trusted)")
    }

    func currentAppKey() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        let bundle = app.bundleIdentifier ?? "no.bundle"
        let name = app.localizedName ?? "Unknown"
        return "\(bundle)|\(name)"
    }

    // Parse the "bundle|name" activeAppKey back into its parts.
    func currentAppBundleAndName() -> (bundle: String, name: String) {
        let parts = activeAppKey.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : (parts.first ?? ""))
    }

    // True when OUR OWN process is frontmost (menu popover, Settings, onboarding).
    // typer must never AX-observe or context-capture its own UI: reading a SwiftUI
    // NSHostingView's accessibility tree forces SwiftUI to synchronously build its
    // entire a11y node graph on the main thread, which beachballs the app. Because
    // the target is in-process, the 50 ms AX messaging timeout (D.1) can't rescue it
    // (that only bounds cross-process XPC), so we must bail out before the read.
    var frontmostIsSelf: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby"
    ]

    // Coarse register of the frontmost app, for per-app voice in style memory: the
    // same user writes "lol yeah" in Messages and full prose in Pages, and sampling
    // should prefer the voice that matches where they are typing now.
    func appCategory() -> String {
        let (bundle, _) = currentAppBundleAndName()
        if TyperApp.terminalBundleIDs.contains(bundle) { return "code" }
        let b = bundle.lowercased()
        let table: [(String, [String])] = [
            ("chat", ["mobilesms", "slack", "discord", "telegram", "whatsapp", "signal", "teams", "messenger"]),
            ("email", ["mail", "outlook", "spark", "missive", "superhuman", "mimestream", "postbox"]),
            ("docs", ["pages", "word", "notes", "obsidian", "notion", "craft", "bear", "iawriter", "textedit", "ulysses", "scrivener"]),
            ("code", ["xcode", "vscode", "sublime", "jetbrains", "intellij", "cursor", "zed", "nova"]),
            ("browser", ["safari", "chrome", "arc", "firefox", "edge", "brave", "orion", "vivaldi"]),
        ]
        for (cat, keys) in table where keys.contains(where: { b.contains($0) }) { return cat }
        return "other"
    }

    // Flush what the user wrote into the long-term personalization stores (style
    // voice + vocabulary lexicon). Called wherever a writing session "ends": Return,
    // app switch, click elsewhere.
    func recordLearning() {
        if cfg.styleMemoryEnabled { styleMemory.record(buffer, category: appCategory()) }
        if cfg.lexiconEnabled { learnLexiconDelta() }
    }

    // Learn only the buffer text typed since the last flush — the watermark makes
    // repeated flushes of a persisting buffer (e.g. app switches back and forth)
    // count each word once.
    func learnLexiconDelta() {
        let learned = min(lexiconWatermark[activeAppKey] ?? 0, buffer.count)
        guard buffer.count > learned else { return }
        lexicon.learn(from: String(buffer.dropFirst(learned)))
        lexiconWatermark[activeAppKey] = buffer.count
        // Teach the spell checker the user's vocabulary so their jargon/names stop being
        // flagged as typos. Unconditional — it only reduces false positives.
        syncLexiconToSpellChecker()
    }

    // A focused field is "secure" when its AX role/subrole marks it as a password /
    // concealed entry (spec D.3). This catches non-secure-input password fields and
    // secure WEB fields that `IsSecureEventInputEnabled()` alone misses. Bounded reads
    // via AXSafe so a wedged host can never stall this on the keystroke path.
    func focusedFieldIsSecure(_ el: AXUIElement) -> Bool {
        // kAXSecureTextFieldRole is not surfaced in the Swift AX overlay; its value is the
        // literal "AXSecureTextField" (same string the secure subrole uses).
        if axString(el, kAXRoleAttribute as String) == "AXSecureTextField" { return true }
        return axString(el, kAXSubroleAttribute as String) == "AXSecureTextField"
    }

    // True when Typer should stay silent in the current app. Single chokepoint
    // `generate()`/`presentCompletion` consult (spec D.3/D.4). Layers, cheapest first:
    //   • user per-app disable / terminal-skip (existing behavior, preserved)
    //   • password-manager / secret-store bundles — ALWAYS suppressed, NOT overridable
    //   • IDE / own-autocomplete bundles — suppressed BY DEFAULT, overridable per app via
    //     `AppOverrides.completionsDisabled = false`
    //   • the focused field's AX role/subrole marking it secure (password/concealed)
    // The AX read is last so the common case never pays an IPC round-trip.
    func isAppDisabled() -> Bool {
        let (bundle, _) = currentAppBundleAndName()
        if cfg.disabledApps.contains(bundle) { return true }
        if cfg.disableInTerminals && TyperApp.terminalBundleIDs.contains(bundle) { return true }
        // Password managers: privacy floor, always on, never overridable.
        if Admissibility.passwordManagerBundles.contains(bundle) { return true }
        // IDEs / own-autocomplete editors: default-suppressed, per-app overridable. An
        // explicit `completionsDisabled = false` in the user's overrides opts the app back in;
        // an explicit `true` (for any app) also suppresses it here.
        let ov = OverrideStore.shared.resolved(bundle: bundle)
        if let forced = ov.completionsDisabled { if forced { return true } }
        else if Admissibility.ownAutocompleteBundles.contains(bundle) { return true }
        // Secure focused field (password/concealed) — last because it costs an AX read.
        if let el = focusedElement(), focusedFieldIsSecure(el) { return true }
        return false
    }

    // Timed-snooze gate (#3, spec E §3). True unless the given bundle is currently inside a
    // global or per-app snooze deadline. Deadlines are ephemeral; expired ones are pruned.
    func completionsAllowed(bundle: String) -> Bool {
        let now = Date()
        if let g = allCompletionsDisabledUntil {
            if g > now { return false }
            allCompletionsDisabledUntil = nil
        }
        if let a = perAppDisabledUntil[bundle] {
            if a > now { return false }
            perAppDisabledUntil[bundle] = nil
        }
        return true
    }

    func syncActiveApp() {
        let key = currentAppKey()
        if key == activeAppKey { return }
        // Leaving an app: keep its session buffer, and learn from what was typed
        // there (captures editors/docs that never send a Return).
        recordLearning()
        buffersByApp[activeAppKey] = buffer
        lastInputByApp[activeAppKey] = lastInput
        log("app switch \(activeAppKey) -> \(key) savedChars=\(buffer.count)")
        activeAppKey = key
        buffer = buffersByApp[key] ?? ""
        lastInput = lastInputByApp[key] ?? Date.distantPast
        clearSuggestion()
        // Switching apps starts fresh: drop the previous app's background context and
        // caret cache so the new app re-derives its own. Per-app buffers persist; the
        // (global) style memory intentionally carries across apps for personalization.
        cachedBackground = ""
        backgroundRefreshedAt = .distantPast
        backgroundKey = ""
        styleSampleAt = .distantPast    // re-rank the style sample for the new app's text
        shotCaretPoint = nil
        shotCaretApp = ""
        // A click into a different app's field switches apps THROUGH this path; that
        // click's anchor must survive (it's stamped to the new app moments later in the
        // deferred resync). Only drop a stale anchor from a non-click switch (⌘-Tab etc).
        if !clickCaretPending {
            clickCaretPoint = nil
            clickCaretApp = ""
        }
        lastCaretPoint = nil
        caretHeightFloor = nil      // fresh font-size measurement per focus session
        updateAXObserver()          // follow the new app's focused element
        log("[\(activeAppKey)] restored buffer chars=\(buffer.count)")
    }

    func saveActiveAppState() {
        buffersByApp[activeAppKey] = buffer
        lastInputByApp[activeAppKey] = lastInput
    }

    // Append typed/inserted text to the per-app buffer (no UI side effects).
    func appendToBuffer(_ text: String) {
        if Date().timeIntervalSince(lastInput) > Double(cfg.idleResetSeconds) {
            buffer = ""
            lexiconWatermark[activeAppKey] = 0
        }
        buffer += text
        if buffer.count > 4000 {
            // Front-truncation shifts every index; pull the lexicon watermark back by
            // the same amount so it keeps pointing at the same (kept) text.
            let over = buffer.count - 4000
            buffer = String(buffer.suffix(4000))
            lexiconWatermark[activeAppKey] = max(0, (lexiconWatermark[activeAppKey] ?? 0) - over)
        }
        lastInput = Date()
        saveActiveAppState()
    }

    // Used for non-typed buffer changes (e.g. Shift-Return newline): reset the
    // prediction and regenerate.
    func push(_ text: String, countsAsUserTyping: Bool = true) {
        if countsAsUserTyping {
            generationSerial &+= 1
            lastUserTypedAt = Date()
        }
        appendToBuffer(text)
        clearSuggestion()
        scheduleGenerate()
    }

    func isWordSeparator(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.punctuationCharacters.contains(s)
    }

    // Tail window with a STABLE start. A plain suffix(max) slides forward one character
    // per keystroke once the text exceeds `max`, so the prompt's first tokens differ on
    // every request and the helper's KV prefix cache never matches — each pause then
    // re-decodes the entire prompt instead of just the few new tokens. Snapping the
    // window start to a text boundary keeps the prompt prefix byte-identical across
    // keystrokes until that boundary scrolls out of range (~once per sentence), which is
    // the difference between incremental decode and a full prompt re-decode per pause.
    func stableTail(_ s: String, max: Int) -> String {
        guard max > 0, s.count > max else { return s }
        let tail = Array(s.suffix(max))
        // Search only the first half so the window keeps at least max/2 of context.
        var strongCut = -1   // newline or sentence end: moves rarely
        var spaceCut = -1    // any word boundary: still far better than per-character
        for i in 0..<(max / 2) {
            let c = tail[i]
            if c == "\n" || c == "\r" { strongCut = i; break }
            if i > 0, c == " ", ".!?".contains(tail[i - 1]) { strongCut = i; break }
            if spaceCut < 0, c == " " { spaceCut = i }
        }
        let cut = strongCut >= 0 ? strongCut : spaceCut
        guard cut >= 0, cut + 1 < tail.count else { return String(tail) }
        return String(tail[(cut + 1)...])
    }

    // True when we should trim energy use: battery-saver enabled AND on battery or in
    // Low Power Mode. Drives a longer debounce and disables speculative prefetch.
    var powerSaving: Bool { cfg.batterySaver && PowerState.shared.saving }

    func clearSuggestion() {
        // A suggestion that vanishes without going through resolveCompletionOutcome
        // (app switch, click, paste, disable) still has an outcome: whatever was taken
        // before it was abandoned. Any consumed words came from typing through it.
        let consumed = completion?.consumed ?? 0
        flushTrainingOutcome(consumedChars: consumed, acceptKind: consumed > 0 ? "typethrough" : "none", reason: "dismissed")
        reanchorWork?.cancel()
        settleWork?.cancel()
        // An explicit dismissal (Esc/click/app switch) must also end the post-accept
        // Tab grace window — a Tab right after Esc is a real Tab.
        acceptGraceUntil = .distantPast
        active = nil
        completion = nil
        prefetched = nil
        prefetchKey = ""
        calibAnchor = nil
        calibPredicted = 0
        overlay.orderOut(nil)
    }

    // MARK: - Stability telemetry (spec D.6, opt-in)

    // The frontmost bundle id at any instant, written from a signal handler at crash time.
    // A POSIX signal handler may only touch async-signal-safe state, so this is a fixed
    // C buffer updated in place (never an allocation) and read with `write(2)`.
    static var crashBundleBuffer = [CChar](repeating: 0, count: 256)

    func startStabilityTelemetry() {
        installCrashBundleRecorder()
        startMainThreadWatchdog()
        log("stability telemetry on (opt-in, local only)")
    }

    // Main-thread watchdog: a 1 Hz main-loop timer advances `mainBeat`; an off-main timer
    // checks whether the beat moved. A run of missed beats means the main thread is wedged,
    // so we log the frontmost bundle id (the "flaky in app X" signal). Never blocks the UI.
    private func startMainThreadWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.mainBeat &+= 1
            // Keep the crash recorder's bundle id fresh while we're alive, too.
            TyperApp.recordFrontmostBundle()
        }
        let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
        t.schedule(deadline: .now() + 2.0, repeating: 2.0)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let beat = self.mainBeat
            if beat == self.watchdogLastBeat {
                self.watchdogStalls += 1
                // Two consecutive missed checks (~4 s of no main-loop progress) before we
                // cry wolf — a single GC/IO hitch shouldn't spam the log.
                if self.watchdogStalls == 2 {
                    let id = TyperApp.currentCrashBundleString()
                    log("WATCHDOG main thread stalled >4s; frontmost=\(id)")
                }
            } else {
                self.watchdogStalls = 0
            }
            self.watchdogLastBeat = beat
        }
        t.resume()
        watchdogTimer = t
    }

    // Record the frontmost app's bundle id into the C buffer the signal handler reads.
    // Called from the main loop tick (safe context).
    static func recordFrontmostBundle() {
        let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        id.withCString { src in
            crashBundleBuffer.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                strncpy(base, src, dst.count - 1)
                base[dst.count - 1] = 0
            }
        }
    }

    static func currentCrashBundleString() -> String {
        crashBundleBuffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    // Install a signal handler for the common fatal signals that records the frontmost
    // bundle id, then re-raises with the default disposition so the OS crash report is
    // still produced. The handler only does async-signal-safe work (write(2) of a fixed
    // buffer); the bundle id is kept current by the main-loop tick above.
    private func installCrashBundleRecorder() {
        TyperApp.recordFrontmostBundle()
        let handler: @convention(c) (Int32) -> Void = { sig in
            // Async-signal-safe only: a fixed prefix, the pre-captured bundle id, and a
            // newline, all via write(2). Then restore default disposition and re-raise so
            // the OS still produces its crash report.
            "\nTYPER CRASH frontmost=".withCString { _ = write(2, $0, strlen($0)) }
            TyperApp.crashBundleBuffer.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress { _ = write(2, base, strlen(base)) }
            }
            "\n".withCString { _ = write(2, $0, strlen($0)) }
            signal(sig, SIG_DFL)
            raise(sig)
        }
        for sig in [SIGILL, SIGABRT, SIGFPE, SIGBUS, SIGSEGV, SIGTRAP] {
            signal(sig, handler)
        }
    }
}
