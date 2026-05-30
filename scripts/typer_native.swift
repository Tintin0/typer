import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

let typerLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Typer.log")

// When false (default), content-bearing logs (typed text, buffer/context/suggestion
// snippets) are suppressed so the log is not a plaintext keystroke transcript.
var debugLoggingEnabled = false

// A single long-lived handle written on a serial queue, so logging never re-opens the
// file or blocks the (often main-thread) caller — the old open/seek/write/close per
// call ran several times per keystroke on the hot path.
let typerLogQueue = DispatchQueue(label: "typer.log", qos: .utility)
private let typerLogHandle: FileHandle? = {
    if !FileManager.default.fileExists(atPath: typerLogURL.path) {
        FileManager.default.createFile(atPath: typerLogURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
    }
    let h = try? FileHandle(forWritingTo: typerLogURL)
    _ = try? h?.seekToEnd()
    return h
}()

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    typerLogQueue.async {
        guard let h = typerLogHandle else { return }
        try? h.write(contentsOf: Data(line.utf8))
    }
}

// Content-bearing log: only written when debug logging is explicitly enabled, so the
// log never becomes a plaintext record of what the user typed.
func dlog(_ message: @autoclosure () -> String) {
    if debugLoggingEnabled { log(message()) }
}

// Power-source awareness so we can throttle the (GPU-heavy) model when running on
// battery. Polling IOKit on every keystroke is wasteful, so the battery state is
// cached and refreshed lazily (no idle timer — checked only when we're about to
// generate). On a desktop with no battery this always reports AC, so nothing is
// throttled there.
final class PowerState {
    static let shared = PowerState()
    private var cachedOnBattery = false
    private var checkedAt = Date.distantPast

    func onBattery() -> Bool {
        if Date().timeIntervalSince(checkedAt) > 5 {
            // kIOPSTimeRemainingUnlimited is returned only when on AC power.
            cachedOnBattery = IOPSGetTimeRemainingEstimate() != kIOPSTimeRemainingUnlimited
            checkedAt = Date()
        }
        return cachedOnBattery
    }

    // Low Power Mode OR running on battery → back off to save energy.
    var saving: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled || onBattery() }
}

struct TyperConfig {
    var enabled = true
    var completionEnabled = true
    var typoEnabled = false
    var modelPath = ""   // explicit .gguf path; empty = auto-pick first in Models dir
    var maxCompletionWords = 7
    var minContextChars = 6
    // Trailing debounce before a generation fires. Must be longer than the gap
    // between keystrokes (~80–200ms) so we generate once per *pause* rather than
    // once per *key* — at 25ms we fired a full model inference on nearly every
    // character, which is the main battery drain.
    var debounceMs = 110
    var idleResetSeconds = 20
    // Battery / energy.
    var prefetchEnabled = true    // speculatively fetch the next chunk (≈2× inference)
    var batterySaver = true       // throttle on battery / Low Power Mode
    var batteryDebounceMs = 300   // debounce used while battery-saving (prefetch off too)
    // Broader-context sources. All on-device. Each degrades gracefully if its data
    // is unavailable (e.g. AX-hostile apps, or Screen Recording not granted).
    var windowContextEnabled = true   // read surrounding text in the focused window via AX
    var styleMemoryEnabled = true     // bias completions toward the user's own recent writing
    var clipboardContextEnabled = true
    var screenContextEnabled = false  // screenshot OCR as prompt context — off by default (noisy)
    // Screenshot+OCR caret locator for apps with no AX/text-marker caret (terminals,
    // custom editors). OFF by default: a full ScreenCaptureKit capture + Vision OCR
    // per caret update is very battery-heavy (it ran on the Neural Engine every ~1.2s
    // while typing in a terminal). Native and Electron/WebKit apps don't need it.
    var screenshotCaretEnabled = false
    // Ambient "topic memory": periodically OCR the focused window, distill the salient
    // entities/topics (not raw text), and resurface them later only when you type about
    // one. Off by default (needs Screen Recording). topic_capture_seconds is the period.
    var topicMemoryEnabled = false
    var topicCaptureSeconds = 180.0
    var backgroundRefreshSeconds = 4.0
    var maxImmediateForBackground = 220 // only fold in background when the field itself is sparse
    var debugLogging = false            // when true, logs include typed text/snippets
    var disabledApps: Set<String> = []  // bundle IDs where Typer stays silent
    var disableInTerminals = false      // skip terminal apps entirely

    static func load() -> TyperConfig {
        var cfg = TyperConfig()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/config.toml")
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return cfg }
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0]
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "enabled": cfg.enabled = value == "true"
            case "completion_enabled": cfg.completionEnabled = value == "true"
            case "typo_correction_enabled": cfg.typoEnabled = value == "true"
            case "model_path": cfg.modelPath = (value as NSString).expandingTildeInPath
            case "max_completion_words": cfg.maxCompletionWords = Int(value) ?? cfg.maxCompletionWords
            case "min_context_chars": cfg.minContextChars = Int(value) ?? cfg.minContextChars
            case "debounce_ms": cfg.debounceMs = Int(value) ?? cfg.debounceMs
            case "idle_reset_seconds": cfg.idleResetSeconds = Int(value) ?? cfg.idleResetSeconds
            case "prefetch_enabled": cfg.prefetchEnabled = value == "true"
            case "battery_saver": cfg.batterySaver = value == "true"
            case "battery_debounce_ms": cfg.batteryDebounceMs = Int(value) ?? cfg.batteryDebounceMs
            case "window_context_enabled": cfg.windowContextEnabled = value == "true"
            case "style_memory_enabled": cfg.styleMemoryEnabled = value == "true"
            case "clipboard_context_enabled": cfg.clipboardContextEnabled = value == "true"
            case "screen_context_enabled": cfg.screenContextEnabled = value == "true"
            case "screenshot_caret_enabled": cfg.screenshotCaretEnabled = value == "true"
            case "topic_memory_enabled": cfg.topicMemoryEnabled = value == "true"
            case "topic_capture_seconds": cfg.topicCaptureSeconds = Double(value) ?? cfg.topicCaptureSeconds
            case "background_refresh_seconds": cfg.backgroundRefreshSeconds = Double(value) ?? cfg.backgroundRefreshSeconds
            case "debug_logging": cfg.debugLogging = value == "true"
            case "disable_in_terminals": cfg.disableInTerminals = value == "true"
            case "disabled_apps": cfg.disabledApps = Set(value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            default: break
            }
        }
        return cfg
    }
}

struct HelperRequest: Codable {
    let task: String
    let context: String
    let max_words: Int
}

struct HelperSuggestion: Codable {
    let kind: String
    let text: String?
    let original: String?
    let replacement: String?
}

// One line of the helper's streaming response: either a partial ({"p":...}) or the
// final result ({"ok":..., "suggestion":...}).
struct StreamLine: Codable {
    let p: String?
    let ok: Bool?
    let error: String?
    let suggestion: HelperSuggestion?
}

// An inline completion the user can "type into". As the user types characters that
// match the prediction (or presses Tab), `consumed` advances and the displayed
// ghost text shrinks — no regeneration happens until they deviate or exhaust it.
struct ActiveCompletion {
    let chars: [Character]
    var consumed: Int = 0
    var remainder: String { consumed >= chars.count ? "" : String(chars[consumed...]) }
    var done: Bool { consumed >= chars.count }
    // Next word slice (leading whitespace + the word) starting at `consumed`.
    func nextWordEnd() -> Int {
        var i = consumed
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        while i < chars.count && !chars[i].isWhitespace { i += 1 }
        return i
    }
}

final class LlamaClient {
    private let cfg: TyperConfig
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()   // leftover bytes past the last newline (chunked reads)
    private let lock = NSLock()

    init(cfg: TyperConfig) { self.cfg = cfg }

    // Locate the GGUF model: an explicit config path if set, otherwise the first
    // .gguf found in the Models directory (so the exact filename doesn't matter).
    static func findModel(_ cfg: TyperConfig) -> String? {
        let fm = FileManager.default
        if !cfg.modelPath.isEmpty, fm.fileExists(atPath: cfg.modelPath) { return cfg.modelPath }
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/typer/Models")
        let ggufs = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".gguf") }.sorted()
        return ggufs?.first.map { dir.appendingPathComponent($0).path }
    }

    func start() throws {
        if process?.isRunning == true { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let llamaHelper = home + "/.local/share/typer/typer-llama-server"
        guard FileManager.default.isExecutableFile(atPath: llamaHelper) else {
            throw NSError(domain: "Typer", code: 3, userInfo: [NSLocalizedDescriptionKey: "helper not found at \(llamaHelper); run install.sh"])
        }
        guard let model = LlamaClient.findModel(cfg) else {
            throw NSError(domain: "Typer", code: 4, userInfo: [NSLocalizedDescriptionKey: "no .gguf model found in Models directory; run install.sh"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: llamaHelper)
        p.arguments = ["--model-path", model]
        log("starting GGUF helper: \(llamaHelper) model=\((model as NSString).lastPathComponent)")
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        try p.run()
        log("helper pid=\(p.processIdentifier)")
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
    }

    // Reads one '\n'-terminated line from the helper, reading in CHUNKS (not a syscall
    // per byte) and buffering any bytes past the newline for the next call. macOS
    // energy impact is dominated by CPU wakeups, so the old byte-at-a-time poll/read
    // (≈2 syscalls per character of a streamed response) was a real, avoidable drain.
    private func readResponseLine(timeoutMs: Int32 = 8000) throws -> Data? {
        guard let fd = output?.fileDescriptor else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return line
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            let r = poll(&pfd, 1, remaining)
            if r == 0 { throw NSError(domain: "Typer", code: 5, userInfo: [NSLocalizedDescriptionKey: "helper read timeout"]) }
            if r < 0 { if errno == EINTR { continue }; throw NSError(domain: "Typer", code: 6, userInfo: [NSLocalizedDescriptionKey: "poll failed"]) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; throw NSError(domain: "Typer", code: 7, userInfo: [NSLocalizedDescriptionKey: "read failed"]) }
            if n == 0 { return readBuffer.isEmpty ? nil : { let d = readBuffer; readBuffer.removeAll(); return d }() }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    // Sends one request and reads the streaming response. `onPartial` is invoked
    // (on this background thread) for each partial completion; the final suggestion
    // is returned.
    // `lowPriority` (speculative prefetch) yields the helper instead of waiting: if a
    // foreground request already holds the lock, the prefetch is skipped rather than
    // queued, so it can never delay real input.
    func request(task: String, context: String, maxWords: Int, lowPriority: Bool = false,
                 onPartial: ((String) -> Void)? = nil) throws -> HelperSuggestion? {
        if lowPriority {
            guard lock.try() else { return nil }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        try start()
        let req = HelperRequest(task: task, context: context, max_words: maxWords)
        dlog("request task=\(task) chars=\(context.count) suffix=\(String(context.suffix(40)).replacingOccurrences(of: "\n", with: "\\n"))")
        let data = try JSONEncoder().encode(req) + Data([0x0A])
        let decoder = JSONDecoder()
        do {
            try input?.write(contentsOf: data)
            while true {
                guard let line = try readResponseLine(), !line.isEmpty else {
                    throw NSError(domain: "Typer", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper exited"])
                }
                let res = try decoder.decode(StreamLine.self, from: line)
                if let p = res.p { onPartial?(p); continue }      // partial token update
                if res.ok == false {
                    throw NSError(domain: "Typer", code: 2, userInfo: [NSLocalizedDescriptionKey: res.error ?? "Unknown error"])
                }
                dlog("response kind=\(res.suggestion?.kind ?? "nil") text=\((res.suggestion?.text ?? res.suggestion?.replacement ?? "nil").prefix(80))")
                return res.suggestion                              // final line
            }
        } catch {
            // On exit/timeout/parse error, kill the (possibly hung) helper so the next
            // request spawns a fresh one instead of blocking on a dead pipe.
            process?.terminate()
            process = nil; input = nil; output = nil
            throw error
        }
    }

    // Lock-safe warm-up so the launch-time start() can't double-spawn against the
    // first real request().
    func warmUp() { lock.lock(); defer { lock.unlock() }; try? start() }
}

// Layer-based ghost renderer: SF system font, a soft trailing taper (the text fades
// at its right edge), and a one-shot shimmer sweep + fade-in when a fresh suggestion
// appears (but not while typing through it).
final class GhostView: NSView {
    private let textLayer = CATextLayer()
    private let shimmer = CAGradientLayer()
    private let shimmerMask = CATextLayer()
    private let taper = CAGradientLayer()
    private let inset: CGFloat = 3

    override init(frame: NSRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {
        wantsLayer = true
        let root = CALayer()
        layer = root
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for tl in [textLayer, shimmerMask] {
            tl.contentsScale = scale; tl.truncationMode = .none; tl.isWrapped = false; tl.alignmentMode = .left
        }
        root.addSublayer(textLayer)

        shimmer.startPoint = CGPoint(x: 0, y: 0.5); shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [NSColor.clear.cgColor, NSColor.white.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        shimmer.mask = shimmerMask
        shimmer.isHidden = true
        root.addSublayer(shimmer)

        // Trailing taper: a gradient mask that softens the last ~20px of the ghost.
        taper.startPoint = CGPoint(x: 0, y: 0.5); taper.endPoint = CGPoint(x: 1, y: 0.5)
        taper.colors = [NSColor.white.cgColor, NSColor.white.cgColor, NSColor.white.withAlphaComponent(0.35).cgColor]
        root.mask = taper
    }

    func render(_ attr: NSAttributedString, fontSize fs: CGFloat, taperWidth: CGFloat, shimmer doShimmer: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)   // no implicit anim on text/move
        let h = ceil(attr.size().height)
        let f = CGRect(x: inset, y: (bounds.height - h) / 2, width: max(0, bounds.width - inset), height: h)
        textLayer.string = attr
        textLayer.frame = f
        taper.frame = bounds
        let fadeStart = bounds.width > taperWidth ? (bounds.width - taperWidth) / bounds.width : 0.55
        taper.locations = [0, NSNumber(value: Double(fadeStart)), 1.0]
        CATransaction.commit()
        if doShimmer { runShimmer(text: attr.string, fontSize: fs, frame: f) } else { shimmer.isHidden = true }
    }

    private func runShimmer(text: String, fontSize fs: CGFloat, frame f: CGRect) {
        shimmer.isHidden = false
        shimmer.frame = bounds
        shimmerMask.string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fs), .foregroundColor: NSColor.white])
        shimmerMask.frame = f
        shimmer.locations = [1.0, 1.0, 1.0]   // settle: band swept off the right edge
        let band = CABasicAnimation(keyPath: "locations")
        band.fromValue = [-0.6, -0.3, 0.0]
        band.toValue = [1.0, 1.3, 1.6]
        band.duration = 0.6
        band.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.shimmer.isHidden = true }
        shimmer.add(band, forKey: "shimmer")
        CATransaction.commit()
    }

    func fadeIn() {
        guard let root = layer else { return }
        let group = CAAnimationGroup()
        let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0.0; op.toValue = 1.0
        let mv = CABasicAnimation(keyPath: "transform.translation.y"); mv.fromValue = -2.0; mv.toValue = 0.0
        group.animations = [op, mv]; group.duration = 0.14
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        root.add(group, forKey: "in")
    }
}

final class SuggestionOverlay: NSPanel {
    private let ghost = GhostView(frame: NSRect(x: 0, y: 0, width: 420, height: 38))

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        contentView = ghost
        orderOut(nil)
    }

    private func fontSize(for lineHeight: CGFloat) -> CGFloat { min(max(lineHeight * 0.62, 11), 30) }

    func showCompletion(_ text: String, at point: NSPoint, lineHeight: CGFloat, animate: Bool) {
        let fs = fontSize(for: lineHeight)
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fs), .foregroundColor: NSColor.labelColor.withAlphaComponent(0.5)])
        place(attr, fontSize: fs, at: point, lineHeight: lineHeight, shimmer: animate)
    }

    func showTypo(original: String, replacement: String, at point: NSPoint, lineHeight: CGFloat) {
        let fs = fontSize(for: lineHeight)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: original, attributes: [
            .font: NSFont.systemFont(ofSize: fs),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7)]))
        s.append(NSAttributedString(string: " → " + replacement, attributes: [
            .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
            .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95)]))
        place(s, fontSize: fs, at: point, lineHeight: lineHeight, shimmer: true)
    }

    // `point` is the caret's right edge (x) and bottom (y). The panel is the caret
    // line height, so the text is vertically centered on the caret line (inline).
    private func place(_ attr: NSAttributedString, fontSize fs: CGFloat, at point: NSPoint, lineHeight: CGFloat, shimmer: Bool) {
        let textW = ceil(attr.size().width)
        let taperW: CGFloat = 20
        let w = min(textW + 8, 760)
        let h = max(lineHeight, 14)
        var frame = NSRect(x: point.x, y: point.y, width: w, height: h)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let v = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, v.minX), v.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, v.minY), v.maxY - frame.height)
        }
        let wasVisible = isVisible
        setFrame(frame, display: true)
        ghost.frame = NSRect(origin: .zero, size: frame.size)
        // Shimmer only on a genuinely fresh appearance — never while streaming updates
        // or shrinking as the user types through it.
        ghost.render(attr, fontSize: fs, taperWidth: taperW, shimmer: shimmer && !wasVisible)
        if !wasVisible {
            ghost.fadeIn()
            orderFrontRegardless()
        }
    }
}

// Persistent, on-device record of the user's own writing. A small rolling sample
// is fed into the prompt so completions adopt the user's tone and vocabulary.
// Entirely local: ~/Library/Application Support/typer/style.txt, capped in size.
final class StyleMemory {
    private let url: URL
    private let maxBytes = 40_000
    private let queue = DispatchQueue(label: "typer.style", qos: .utility)
    // In-RAM mirror of style.txt, guarded by `lock`. `sample()`/`sentenceCount()` run
    // on the main thread on the generation hot path, so they must never touch disk.
    private let lock = NSLock()
    private var cached: String?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("style.txt")
    }

    // Lazy-load the file once, then serve from RAM.
    private func contents() -> String {
        lock.lock(); defer { lock.unlock() }
        if cached == nil { cached = (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return cached!
    }

    func record(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only keep substantive, sentence-like writing — not stray words.
        guard t.split(separator: " ").count >= 4 else { return }
        lock.lock()
        var existing = cached ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Dedupe: skip if this exact line is among the most recent entries (the
        // same buffer is flushed on both app-switch and Return).
        if existing.split(separator: "\n").suffix(8).map(String.init).contains(t) { lock.unlock(); return }
        existing += "\n" + t
        if existing.utf8.count > maxBytes { existing = String(existing.suffix(maxBytes / 2)) }
        cached = existing
        lock.unlock()
        queue.async {
            try? existing.write(to: self.url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }

    func sample(maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        // Most-recent writing is most representative of current voice.
        let lines = contents().split(separator: "\n").map(String.init).reversed()
        var out: [String] = []
        var budget = maxChars
        for line in lines {
            if budget <= 0 { break }
            out.append(line)
            budget -= line.count + 1
        }
        return out.reversed().joined(separator: "\n")
    }

    func sentenceCount() -> Int {
        contents().split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    func clear() {
        lock.lock(); cached = ""; lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }
}

// One distilled thing the user looked at on screen: the salient names/keywords plus a
// short snippet to resurface, NOT the raw page text.
struct TopicEntry: Codable {
    let at: Double          // epoch seconds
    let app: String
    let title: String
    let keys: [String]      // lowercased match keys (distinctive entity tokens)
    let note: String        // short human-readable snippet to fold back into a prompt
}

// Ambient topic memory: a small, on-device, distilled record of what the user has
// recently viewed (periodic OCR → entity extraction). Resurfaced into a prompt only
// when the user later types about one of the stored entities. Capped, 0600, clearable.
final class TopicMemory {
    private let url: URL
    private let maxEntries = 60
    private let queue = DispatchQueue(label: "typer.topics", qos: .utility)
    private let lock = NSLock()
    private var cached: [TopicEntry]?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("topics.json")
    }

    private func entries() -> [TopicEntry] {
        lock.lock(); defer { lock.unlock() }
        if cached == nil {
            cached = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TopicEntry].self, from: $0) } ?? []
        }
        return cached!
    }

    func record(_ e: TopicEntry) {
        guard !e.keys.isEmpty else { return }
        lock.lock()
        var all = cached ?? (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([TopicEntry].self, from: $0) } ?? []
        // Replace any prior capture of the same view (same app + title) so we keep the
        // freshest snapshot rather than piling up duplicates of a page left open.
        all.removeAll { $0.app == e.app && $0.title == e.title }
        all.append(e)
        if all.count > maxEntries { all.removeFirst(all.count - maxEntries) }
        cached = all
        lock.unlock()
        persist(all)
    }

    // The note for the most recent entry whose keys appear in `text`, or nil. This is
    // the "only when there's a clear entity match" gate.
    func relevant(to text: String) -> String? {
        let hay = " " + text.lowercased() + " "
        for e in entries().reversed() {
            if e.keys.contains(where: { hay.contains($0) }) { return e.note }
        }
        return nil
    }

    func count() -> Int { entries().count }

    func clear() {
        lock.lock(); cached = []; lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    private func persist(_ all: [TopicEntry]) {
        queue.async {
            guard let d = try? JSONEncoder().encode(all) else { return }
            try? d.write(to: self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
}

// Common/UI words that slip past entity + noun extraction and would cause spurious
// "you read about X" matches. Small on purpose.
private let topicStopWords: Set<String> = [
    "the","and","for","with","this","that","your","you","from","are","was","were","has",
    "have","had","will","would","can","could","more","most","here","there","what","when",
    "where","which","their","them","they","our","out","about","into","over","than","then",
    "review","reviews","home","page","menu","sign","search","login","settings","help",
    "terms","privacy","cookie","cookies","accept","share","follow","subscribe","news",
    "available","rated","support","click","button","close","open","loading",
]

// Distill OCR'd screen text + a window title into (match keys, resurfacing note) using
// Apple's on-device NaturalLanguage. Keys are the distinctive things the user is likely
// to mention later: named-entity tokens (brands/products/people/places) plus repeated
// content nouns (the topic/category). The note is the title plus the most informative
// sentence or two — what gets folded back into a prompt when a key is later typed.
func distillTopics(text raw: String, title rawTitle: String) -> (keys: [String], note: String) {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = raw.replacingOccurrences(of: "\r", with: "\n")
    guard text.count >= 60 || title.count >= 6 else { return ([], "") }

    var keys = Set<String>()
    var phrases = Set<String>()   // entity phrases, for note sentence selection

    // 1) Named entities (people / places / orgs / products), joined.
    let nt = NLTagger(tagSchemes: [.nameType]); nt.string = text
    nt.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                     options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
        if let tag, [.personalName, .placeName, .organizationName].contains(tag) {
            let s = String(text[range]).trimmingCharacters(in: .whitespaces)
            if s.count >= 3, s.count <= 40 {
                phrases.insert(s)
                for tok in s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where tok.count >= 4 {
                    let l = tok.lowercased(); if !topicStopWords.contains(l) { keys.insert(l) }
                }
                if s.contains(" "), s.count <= 24 { keys.insert(s.lowercased()) }
            }
        }
        return keys.count < 30
    }
    // 2) Repeated content nouns — the topic/category words ("headphones", "mortgage").
    var freq: [String: Int] = [:]
    let lt = NLTagger(tagSchemes: [.lexicalClass]); lt.string = text
    lt.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                     options: [.omitWhitespace, .omitPunctuation]) { tag, range in
        if tag == .noun {
            let l = String(text[range]).lowercased()
            if l.count >= 4, !topicStopWords.contains(l) { freq[l, default: 0] += 1 }
        }
        return true
    }
    for (w, n) in freq where n >= 2 { keys.insert(w) }
    if !title.isEmpty { phrases.insert(title) }
    guard !keys.isEmpty else { return ([], "") }

    // Note: title + up to two informative sentences that mention an entity.
    let phraseLower = phrases.map { $0.lowercased() }
    var sentences: [String] = []
    let st = NLTokenizer(unit: .sentence); st.string = text
    st.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
        let s = text[r].trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 30, s.count <= 240, phraseLower.contains(where: { s.lowercased().contains($0) }) {
            sentences.append(s)
        }
        return sentences.count < 2
    }
    var note = title.isEmpty ? "" : title
    if !sentences.isEmpty { note += (note.isEmpty ? "" : " — ") + sentences.joined(separator: " ") }
    return (Array(keys.prefix(24)), String(note.prefix(300)))
}

// Lightweight persisted acceptance stats — how often shown suggestions are taken
// vs. typed past. Surfaced in the menu; foundation for tuning behavior over time.
struct TyperStats: Codable {
    var shown = 0
    var accepted = 0
    var ignored = 0
    var wordsCompleted = 0          // words actually inserted via Tab/backtick (saved typing)
    var charsCompleted = 0
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    var lastActiveDay = ""          // "yyyy-MM-dd" of the last day a completion was taken
    var acceptRate: Int { shown > 0 ? Int((Double(accepted) / Double(shown)) * 100) : 0 }

    // Tolerate older stats.json files that predate the new fields.
    enum CodingKeys: String, CodingKey {
        case shown, accepted, ignored, wordsCompleted, charsCompleted
        case activeDays, currentStreak, longestStreak, lastActiveDay
    }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        shown = try c.decodeIfPresent(Int.self, forKey: .shown) ?? 0
        accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
        wordsCompleted = try c.decodeIfPresent(Int.self, forKey: .wordsCompleted) ?? 0
        charsCompleted = try c.decodeIfPresent(Int.self, forKey: .charsCompleted) ?? 0
        activeDays = try c.decodeIfPresent(Int.self, forKey: .activeDays) ?? 0
        currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        longestStreak = try c.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0
        lastActiveDay = try c.decodeIfPresent(String.self, forKey: .lastActiveDay) ?? ""
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/stats.json")
    }
    static func load() -> TyperStats {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(TyperStats.self, from: d) else { return TyperStats() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: TyperStats.url) }
    }
}

final class TyperApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var cfg = TyperConfig.load()
    var client: LlamaClient!
    var statusItem: NSStatusItem!
    let statusMenu = NSMenu()
    let overlay = SuggestionOverlay()
    var observerTap: CFMachPort?        // listen-only: never gates input delivery
    var acceptTap: CFMachPort?          // consuming: enabled only while a suggestion shows
    var acceptTapEnabled = false        // mirror of the tap's enable state (avoid redundant mach calls)
    var buffer = ""
    var lastInput = Date()
    var activeAppKey = "unknown"
    var buffersByApp: [String: String] = [:]
    var lastInputByApp: [String: Date] = [:]
    var debounce: Timer?
    // The accept tap is enabled exactly while a suggestion is on screen, so Typer is
    // out of the keystroke-consuming path the rest of the time.
    var active: HelperSuggestion? { didSet { refreshAcceptTap() } }      // typo diff
    var completion: ActiveCompletion? { didSet { refreshAcceptTap() } } // inline completion
    var lastCaretPoint: NSPoint?
    var lastCaretHeight: CGFloat = 18   // caret line height, to match the app's font
    var reanchorWork: DispatchWorkItem? // deferred AX caret re-anchor after a keystroke
    var caretHeightFloor: CGFloat?      // smallest caret height seen this focus session
    // Screenshot-based caret cache for apps without AX caret geometry. We compute it
    // occasionally (it is slow) and extrapolate horizontally as the user types.
    var shotCaretPoint: NSPoint?
    var shotCaretAt = Date.distantPast
    var shotCaretBufferLen = 0
    var shotCaretCharWidth: CGFloat = 9
    var shotCaretHeight: CGFloat = 18
    var shotCaretApp = ""
    var shotCaretComputing = false
    // Speculative prefetch: the next chunk, generated while the user finishes the
    // current one, so it can appear instantly on exhaustion.
    var prefetched: ActiveCompletion?
    var prefetchKey = ""
    var prefetchInFlight = false
    // Single-flight generation: at most one request in the helper at a time.
    var requestInFlight = false
    var rerequestNeeded = false
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
    var topicTimer: Timer?
    var topicCapturing = false
    var cachedBackground = ""
    var backgroundRefreshedAt = Date.distantPast
    var backgroundKey = ""
    var backgroundRefreshing = false
    let backgroundQueue = DispatchQueue(label: "typer.background", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLoggingEnabled = cfg.debugLogging
        // Enforce private perms even on a pre-existing log file.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: typerLogURL.path)
        // Style memory may contain personal writing — keep it private too.
        let styleURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/typer/style.txt")
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: styleURL.path)
        log("Typer launch cfg enabled=\(cfg.enabled) completion=\(cfg.completionEnabled) typo=\(cfg.typoEnabled) debounce=\(cfg.debounceMs) debugLog=\(cfg.debugLogging)")
        activeAppKey = currentAppKey()
        log("initial app=\(activeAppKey)")
        client = LlamaClient(cfg: cfg)
        promptAccessibility()
        if (cfg.screenContextEnabled || cfg.topicMemoryEnabled), !CGPreflightScreenCaptureAccess() {
            // Triggers the one-time Screen Recording permission prompt. OCR/topic capture
            // simply stays empty until granted; everything else keeps working.
            CGRequestScreenCaptureAccess()
            log("requested Screen Recording access (for screen capture)")
        }
        setupMenu()
        setupEventTap()
        startTopicTimer()
        // Only spin up the model if inline completion is actually on (typo correction
        // is local-only). If it's off, the helper stays unspawned until it's enabled.
        if cfg.enabled, cfg.completionEnabled {
            DispatchQueue.global(qos: .utility).async { self.client.warmUp() }
        }
    }

    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("AX trusted=\(trusted)")
    }

    func setupMenu() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusMenu.delegate = self           // repopulate fresh each time it opens
        statusItem.menu = statusMenu
        updateStatusTitle()
        rebuildMenu()
    }

    // The menu-bar badge: a keyboard icon (renders reliably; a text-only status item
    // can collapse to zero width / be impossible to spot) plus the running count of
    // completions taken.
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Typer")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageLeading
        }
        button.title = cfg.enabled ? " \(stats.accepted)" : " ⏸"
    }

    // NSMenuDelegate: rebuild on open so stats/toggles are always current without
    // rebuilding the whole menu on every suggestion.
    func menuNeedsUpdate(_ menu: NSMenu) { if menu === statusMenu { rebuildMenu() } }

    func disabledItem(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
    }

    func toggleItem(_ title: String, key: String, value: Bool) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        i.state = value ? .on : .off
        i.representedObject = key
        i.target = self
        return i
    }

    func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()
        let model = (LlamaClient.findModel(cfg).map { ($0 as NSString).lastPathComponent }) ?? "no model"
        menu.addItem(disabledItem("Typer — \(cfg.enabled ? "on" : "paused")"))
        menu.addItem(disabledItem("Model: \(model)"))
        menu.addItem(.separator())
        for fact in funFacts() { menu.addItem(disabledItem(fact)) }
        menu.addItem(.separator())
        menu.addItem(disabledItem("Shown \(numberFormatted(stats.shown)) · Accepted \(stats.acceptRate)% · Learned \(styleMemory.sentenceCount()) sentences"))
        menu.addItem(.separator())

        menu.addItem(toggleItem("Enabled", key: "enabled", value: cfg.enabled))
        menu.addItem(toggleItem("Completions", key: "completion_enabled", value: cfg.completionEnabled))
        menu.addItem(toggleItem("Typo correction", key: "typo_correction_enabled", value: cfg.typoEnabled))

        // Per-app disable for the app currently being typed in.
        let (curBundle, curName) = currentAppBundleAndName()
        if !curBundle.isEmpty, curBundle != "no.bundle" {
            let item = NSMenuItem(title: "Disable in \(curName)", action: #selector(toggleDisableCurrentApp), keyEquivalent: "")
            item.state = cfg.disabledApps.contains(curBundle) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(toggleItem("Skip terminal apps", key: "disable_in_terminals", value: cfg.disableInTerminals))
        let batt = toggleItem("Battery saver", key: "battery_saver", value: cfg.batterySaver)
        if cfg.batterySaver && PowerState.shared.saving { batt.title = "Battery saver (throttling now)" }
        menu.addItem(batt)
        menu.addItem(.separator())

        let ctx = NSMenu()
        ctx.addItem(toggleItem("Window text", key: "window_context_enabled", value: cfg.windowContextEnabled))
        ctx.addItem(toggleItem("Clipboard", key: "clipboard_context_enabled", value: cfg.clipboardContextEnabled))
        ctx.addItem(toggleItem("Screen OCR (noisy)", key: "screen_context_enabled", value: cfg.screenContextEnabled))
        ctx.addItem(toggleItem("Screenshot caret (terminals; battery-heavy)", key: "screenshot_caret_enabled", value: cfg.screenshotCaretEnabled))
        let topic = toggleItem("Remember what I read (\(topicMemory.count()))", key: "topic_memory_enabled", value: cfg.topicMemoryEnabled)
        ctx.addItem(topic)
        ctx.addItem(toggleItem("Learn my style", key: "style_memory_enabled", value: cfg.styleMemoryEnabled))
        let ctxItem = NSMenuItem(title: "Context sources", action: nil, keyEquivalent: ""); ctxItem.submenu = ctx
        menu.addItem(ctxItem)
        menu.addItem(NSMenuItem(title: "Clear Learned Style", action: #selector(clearStyle), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset All Data…", action: #selector(resetData), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Typer", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        updateStatusTitle()
    }

    func configURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/config.toml")
    }

    // Persist a single key=value into config.toml (replacing the line or appending).
    func writeConfig(_ key: String, _ value: String) {
        let url = configURL()
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found = false
        for i in lines.indices {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key), t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).first == "=" {
                lines[i] = "\(key) = \(value)"; found = true; break
            }
        }
        if !found { lines.append("\(key) = \(value)") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    @objc func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let v = sender.state != .on
        switch key {
        case "enabled": cfg.enabled = v; if !v { clearSuggestion() }
        case "completion_enabled": cfg.completionEnabled = v
        case "typo_correction_enabled": cfg.typoEnabled = v
        case "window_context_enabled": cfg.windowContextEnabled = v
        case "clipboard_context_enabled": cfg.clipboardContextEnabled = v
        case "screen_context_enabled": cfg.screenContextEnabled = v
        case "screenshot_caret_enabled": cfg.screenshotCaretEnabled = v
        case "style_memory_enabled": cfg.styleMemoryEnabled = v
        case "battery_saver": cfg.batterySaver = v
        case "topic_memory_enabled":
            cfg.topicMemoryEnabled = v
            if v, !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            startTopicTimer()
        default: break
        }
        writeConfig(key, v ? "true" : "false")
        log("toggle \(key)=\(v)")
        rebuildMenu()
    }

    @objc func openConfig() { NSWorkspace.shared.open(configURL()) }
    @objc func openLog() { NSWorkspace.shared.open(typerLogURL) }

    func setupEventTap() {
        let disableMask = (1 << CGEventType.tapDisabledByTimeout.rawValue) | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        // Observer: listen-only at the head. Listen-only taps do NOT gate event
        // delivery on the callback returning, so a slow main thread can never stall
        // global keystrokes in other apps. This watches typing and builds state.
        let observerMask = (1 << CGEventType.keyDown.rawValue) | disableMask
        let observerCB: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue().observe(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        observerTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: CGEventMask(observerMask),
                                        callback: observerCB, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let observerTap else {
            log("ERROR observer tap creation failed; Accessibility permission likely missing for Typer.app")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observerTap, 0), .commonModes)
        CGEvent.tapEnable(tap: observerTap, enable: true)

        // Accept tap: a consuming .defaultTap at the tail that only grabs Tab/backtick.
        // It is enabled ONLY while a suggestion is visible (refreshAcceptTap), so when
        // nothing is showing Typer consumes no keys at all.
        let acceptMask = (1 << CGEventType.keyDown.rawValue) | disableMask
        let acceptCB: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue().accept(type: type, event: event)
        }
        acceptTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                      options: .defaultTap, eventsOfInterest: CGEventMask(acceptMask),
                                      callback: acceptCB, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let acceptTap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, acceptTap, 0), .commonModes)
            CGEvent.tapEnable(tap: acceptTap, enable: false)   // off until a suggestion shows
        }
        log("event taps installed (observer + accept)")
    }

    // Enable the consuming accept tap exactly while a suggestion is on screen.
    // Idempotent: each CGEvent.tapEnable is a BLOCKING mach round-trip to the
    // WindowServer, so calling it redundantly (e.g. on every tapDisabled echo) burns a
    // whole CPU core. Only touch the tap when the desired state actually changes.
    func refreshAcceptTap() {
        guard let acceptTap else { return }
        let want = completion != nil || active != nil
        if want == acceptTapEnabled { return }
        acceptTapEnabled = want
        CGEvent.tapEnable(tap: acceptTap, enable: want)
    }

    private func reEnable(_ tap: CFMachPort?, _ label: String) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        log("\(label) tap re-enabled")
    }

    // Listen-only: observes typing, builds the buffer, drives generation. Never
    // consumes Tab/backtick (the accept tap does that).
    func observe(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { reEnable(observerTap, "observer"); return }
        if IsSecureEventInputEnabled() {                 // never capture during secure input
            if completion != nil || active != nil { clearSuggestion() }
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return }  // our own insertion
        guard type == .keyDown else { return }
        syncActiveApp()
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        // event.flags already carries the live modifier state for this keyDown, so we
        // don't track Shift/Command/Control/Option ourselves (and the observer tap no
        // longer needs keyUp events at all).
        let flags = event.flags
        let hasCommandLikeModifier = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        if code == CGKeyCode(kVK_Tab) { return }         // accept tap handles Tab
        if code == CGKeyCode(kVK_ANSI_Grave) {
            // Backtick is "accept all" while a suggestion shows (accept tap consumes
            // it); otherwise it's a literal character the user is typing.
            if completion != nil || active != nil { return }
        }
        if code == CGKeyCode(kVK_Escape) { clearSuggestion(); return }
        if code == CGKeyCode(kVK_Delete) {
            if !buffer.isEmpty { buffer.removeLast() }
            saveActiveAppState(); clearSuggestion(); scheduleGenerate(); return
        }
        if code == CGKeyCode(kVK_Return) {
            if flags.contains(.maskShift) { push("\n") } else {
                if cfg.styleMemoryEnabled { styleMemory.record(buffer) }
                buffer = ""; saveActiveAppState(); clearSuggestion()
            }
            return
        }
        if hasCommandLikeModifier { return }
        if let chars = event.keyboardString, !chars.isEmpty {
            dlog("[\(activeAppKey)] key code=\(code)")
            handleTyping(chars)
        }
    }

    // Consuming tap, enabled only while a suggestion is visible: grabs Tab/backtick.
    func accept(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-arm ONLY if a suggestion is actually showing. A tapDisabled notification
        // while nothing is up is our own tapEnable(false) echoing back — re-enabling
        // here (a blocking mach call) would spin a whole CPU core indefinitely.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if completion != nil || active != nil {
                acceptTapEnabled = true
                if let acceptTap { CGEvent.tapEnable(tap: acceptTap, enable: true) }
            } else {
                acceptTapEnabled = false
            }
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return Unmanaged.passUnretained(event) }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if code == CGKeyCode(kVK_Tab) {
            if acceptCompletionWord() { return nil }
            if acceptOneWord() { return nil }
        } else if code == CGKeyCode(kVK_ANSI_Grave) {
            if acceptCompletionAll() { return nil }
            if acceptAll() { return nil }
        }
        return Unmanaged.passUnretained(event)
    }

    // Core "type as fast as you think" path. The user's keystroke passes through to
    // the app regardless; here we decide whether it matches the live prediction
    // (keep it, just shrink the ghost) or deviates (regenerate).
    func handleTyping(_ text: String) {
        appendToBuffer(text)
        if completion != nil {
            if followAlong(text) { return }   // typed exactly what we predicted — keep it
            // deviated from the prediction: drop it and any speculative prefetch
            completion = nil
            prefetched = nil
            prefetchKey = ""
            overlay.orderOut(nil)
            // (No per-keystroke "ignored" counter — it over-counted natural typing.
            //  Accept rate is accepted/shown, which is the meaningful signal.)
        }
        if cfg.typoEnabled, text.unicodeScalars.allSatisfy({ isWordSeparator($0) }), showTypoIfMisspelled() { return }
        scheduleGenerate()
    }

    // Returns true if every character of `text` matched the next predicted
    // character, advancing the consumed prefix instead of regenerating.
    func followAlong(_ text: String) -> Bool {
        guard var comp = completion else { return false }
        for ch in text {
            guard comp.consumed < comp.chars.count, comp.chars[comp.consumed] == ch else { return false }
            comp.consumed += 1
        }
        completion = comp
        if comp.done {
            // Typed all the way through — a strong "this matched my intent" signal.
            stats.accepted += 1; statsTouched()
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate() }
        } else {
            // Move the ghost immediately by the measured width of what was typed (the
            // app hasn't applied the keystroke yet, so a synchronous AX read would be
            // stale and overlap). A coalesced deferred re-anchor then corrects drift
            // and line-wrap once the app has caught up.
            if let p = lastCaretPoint { lastCaretPoint = NSPoint(x: p.x + ghostWidth(text), y: p.y) }
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }

    // Rendered width of `s` at the current ghost font (used to advance the overlay
    // as the user types through a suggestion without re-reading the caret).
    func ghostWidth(_ s: String) -> CGFloat {
        let fs = min(max(lastCaretHeight * 0.62, 11), 30)
        return (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fs)]).width
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

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby"
    ]

    // True when Typer should stay silent in the current app (per-app disable or a
    // terminal when terminal-skip is on).
    func isAppDisabled() -> Bool {
        let (bundle, _) = currentAppBundleAndName()
        if cfg.disabledApps.contains(bundle) { return true }
        if cfg.disableInTerminals && TyperApp.terminalBundleIDs.contains(bundle) { return true }
        return false
    }

    @objc func toggleDisableCurrentApp() {
        let (bundle, _) = currentAppBundleAndName()
        guard !bundle.isEmpty, bundle != "no.bundle" else { return }
        if cfg.disabledApps.contains(bundle) { cfg.disabledApps.remove(bundle) } else { cfg.disabledApps.insert(bundle) }
        writeConfig("disabled_apps", cfg.disabledApps.sorted().joined(separator: ","))
        if isAppDisabled() { clearSuggestion() }
        rebuildMenu()
    }

    @objc func resetData() {
        let alert = NSAlert()
        alert.messageText = "Reset all Typer data?"
        alert.informativeText = "Clears your learned writing style, remembered on-screen topics, and all stats, returning Typer to a fresh state. Your settings are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        styleMemory.clear()
        topicMemory.clear()
        stats = TyperStats(); stats.save()
        buffer = ""; buffersByApp.removeAll(); lastInputByApp.removeAll()
        cachedBackground = ""; lastTrailing = ""
        clearSuggestion()
        updateStatusTitle()
        log("user reset all data")
    }

    func syncActiveApp() {
        let key = currentAppKey()
        if key == activeAppKey { return }
        // Leaving an app: keep its session buffer, and learn from what was typed
        // there (captures editors/docs that never send a Return).
        if cfg.styleMemoryEnabled { styleMemory.record(buffer) }
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
        shotCaretPoint = nil
        shotCaretApp = ""
        lastCaretPoint = nil
        caretHeightFloor = nil      // fresh font-size measurement per focus session
        log("[\(activeAppKey)] restored buffer chars=\(buffer.count)")
    }

    func saveActiveAppState() {
        buffersByApp[activeAppKey] = buffer
        lastInputByApp[activeAppKey] = lastInput
    }

    // Append typed/inserted text to the per-app buffer (no UI side effects).
    func appendToBuffer(_ text: String) {
        if Date().timeIntervalSince(lastInput) > Double(cfg.idleResetSeconds) { buffer = "" }
        buffer += text
        if buffer.count > 4000 { buffer = String(buffer.suffix(4000)) }
        lastInput = Date()
        saveActiveAppState()
    }

    // Used for non-typed buffer changes (e.g. Shift-Return newline): reset the
    // prediction and regenerate.
    func push(_ text: String) {
        appendToBuffer(text)
        clearSuggestion()
        scheduleGenerate()
    }

    func isWordSeparator(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.punctuationCharacters.contains(s)
    }

    // reanchor=true re-reads the caret from AX (fresh suggestion / new line);
    // reanchor=false reuses the cached point (already shifted by typed width) to
    // avoid per-keystroke AX jitter.
    func showCompletionRemainder(reanchor: Bool = true, animate: Bool = false) {
        guard let comp = completion, !comp.done else { overlay.orderOut(nil); return }
        let point = reanchor ? currentCaretPoint() : (lastCaretPoint ?? currentCaretPoint())
        overlay.showCompletion(comp.remainder, at: point, lineHeight: lastCaretHeight, animate: animate)
    }

    // Our tap callback runs BEFORE the host app applies the keystroke, so reading the
    // AX caret right after typing/inserting gives a stale (one-step-behind) position —
    // that's the ghost overlapping what you just typed. Move immediately by measured
    // width, then re-anchor to the real caret a beat later once the app has caught up.
    // Coalesced, so fast typing never triggers a synchronous AX read.
    func scheduleReanchor() {
        reanchorWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.showCompletionRemainder(reanchor: true)
        }
        reanchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // Tab: realize the next word of the prediction (we insert it; the user did not
    // type it) and keep the remainder showing.
    func acceptCompletionWord() -> Bool {
        guard var comp = completion, !comp.done else { return false }
        let end = comp.nextWordEnd()
        let piece = String(comp.chars[comp.consumed..<end])
        insert(piece)
        appendToBuffer(piece)
        comp.consumed = end
        stats.accepted += 1; recordCompleted(piece); statsTouched()
        if comp.done {
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate() }
        } else {
            completion = comp
            // Move immediately by the inserted word's width (the app hasn't applied
            // the insertion yet), then re-anchor precisely once it has.
            if let p = lastCaretPoint { lastCaretPoint = NSPoint(x: p.x + ghostWidth(piece), y: p.y) }
            showCompletionRemainder(reanchor: false)
            scheduleReanchor()
            maybePrefetch()
        }
        return true
    }

    // Backtick: accept the whole remaining prediction at once.
    func acceptCompletionAll() -> Bool {
        guard let comp = completion, !comp.done else { return false }
        let piece = comp.remainder
        insert(piece)
        appendToBuffer(piece)
        stats.accepted += 1; recordCompleted(piece); statsTouched()
        completion = nil
        overlay.orderOut(nil)
        scheduleGenerate()
        return true
    }

    // As the user nears the end of the current prediction, generate the NEXT chunk
    // in the background (as if they had typed through the rest) so it can appear
    // with zero perceived latency on exhaustion.
    func maybePrefetch() {
        // Prefetch roughly doubles inference; skip it entirely while saving power.
        guard cfg.prefetchEnabled, !powerSaving else { return }
        guard let comp = completion, !comp.done else { return }
        guard comp.chars.count - comp.consumed <= 12, !prefetchInFlight, !requestInFlight else { return }
        let predicted = String((buffer + comp.remainder).suffix(500))
        if predicted == prefetchKey, prefetched != nil { return }
        prefetchInFlight = true
        let promptContext = assembledContext(immediate: predicted)
        let appKey = activeAppKey
        let maxWords = cfg.maxCompletionWords
        backgroundQueue.async {
            let sug = (try? self.client.request(task: "complete", context: promptContext, maxWords: maxWords, lowPriority: true)) ?? nil
            DispatchQueue.main.async {
                self.prefetchInFlight = false
                guard appKey == self.activeAppKey, let t = sug?.text, !t.isEmpty else { return }
                self.prefetched = ActiveCompletion(chars: Array(t))
                self.prefetchKey = predicted
                log("prefetched chars=\(t.count)")
            }
        }
    }

    // If a prefetched chunk matches the current buffer state, show it instantly.
    func promotePrefetch() -> Bool {
        guard let pf = prefetched, prefetchKey == String(buffer.suffix(500)) else { return false }
        completion = pf
        prefetched = nil
        prefetchKey = ""
        stats.shown += 1; statsTouched()   // a promoted prefetch is a shown suggestion
        showCompletionRemainder(animate: true)
        log("promoted prefetch")
        return true
    }

    // True when we should trim energy use: battery-saver enabled AND on battery or in
    // Low Power Mode. Drives a longer debounce and disables speculative prefetch.
    var powerSaving: Bool { cfg.batterySaver && PowerState.shared.saving }

    func scheduleGenerate() {
        debounce?.invalidate()
        let ms = powerSaving ? max(cfg.debounceMs, cfg.batteryDebounceMs) : cfg.debounceMs
        debounce = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000.0, repeats: false) { [weak self] _ in
            self?.generate()
        }
    }

    func generate() {
        syncActiveApp()
        if isAppDisabled() { clearSuggestion(); return }    // per-app / terminal disable
        // Inline completion is the only LLM-backed feature (typo correction is local,
        // via NSSpellChecker). If it's off, never touch the model helper.
        guard cfg.enabled, cfg.completionEnabled else { clearSuggestion(); return }
        // Single-flight: only one request may be in the helper at a time. Firing one
        // per keystroke (with ~400ms latency) backlogs the helper and every result
        // comes back stale — the cause of "nothing ever shows". If a request is in
        // flight we just remember to re-run with the latest context when it returns.
        if requestInFlight { rerequestNeeded = true; return }

        let axCtx = textAroundCursor(limit: 500)
        let axContextRaw = axCtx?.before
        let keyContext = String(buffer.suffix(500))
        let axContext = (axContextRaw?.count ?? 0) >= max(cfg.minContextChars, min(20, keyContext.count / 2)) ? axContextRaw : nil
        let contextSource = axContext == nil ? "key-buffer" : "AXValue"
        let context = axContext ?? keyContext
        if axContext != nil, let after = axCtx?.after, isMidLine(after: after) {
            log("[\(activeAppKey)] generate skipped mid-line"); clearSuggestion(); return
        }
        // Remember the text right after the caret so we can drop completions that
        // just repeat it (e.g. at end of a line that already has following text).
        lastTrailing = (axContext != nil ? (axCtx?.after ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard context.count >= cfg.minContextChars else { log("[\(activeAppKey)] generate skipped context=\(context.count) source=\(contextSource)"); return }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { log("[\(activeAppKey)] generate skipped question"); clearSuggestion(); return }
        refreshBackgroundIfNeeded()

        requestInFlight = true
        let appKey = activeAppKey
        let reqBuffer = buffer            // buffer snapshot for the staleness check
        let promptContext = assembledContext(immediate: context)
        let maxWords = cfg.maxCompletionWords
        dlog("[\(activeAppKey)] generate source=\(contextSource) chars=\(context.count) promptChars=\(promptContext.count) bg=\(cachedBackground.count) suffix=\(String(context.suffix(50)).replacingOccurrences(of: "\n", with: "\\n"))")
        // Anchor (an AX caret read) only on the FIRST painted partial; the user hasn't
        // typed since the request (guard below), so the caret can't have moved while
        // the rest of the tokens stream in — reuse the cached point instead of reading
        // AX per token.
        var firstPartial = true
        DispatchQueue.global(qos: .userInitiated).async {
            // Live preview: paint partial completions as they stream in, but only
            // while the user hasn't typed since the request (else it's the final
            // line's job to reconcile via presentCompletion).
            let onPartial: (String) -> Void = { partial in
                DispatchQueue.main.async {
                    guard appKey == self.activeAppKey, self.buffer == reqBuffer, !partial.isEmpty else { return }
                    self.completion = ActiveCompletion(chars: Array(partial))
                    self.showCompletionRemainder(reanchor: firstPartial, animate: firstPartial)
                    firstPartial = false
                }
            }
            let sug = try? self.client.request(task: "complete", context: promptContext, maxWords: maxWords, onPartial: onPartial)
            DispatchQueue.main.async {
                self.requestInFlight = false
                let again = self.rerequestNeeded
                self.rerequestNeeded = false
                if appKey == self.activeAppKey {
                    self.presentCompletion((sug ?? nil)?.text, requestedBuffer: reqBuffer)
                }
                // Always converge on the latest context.
                if again { self.scheduleGenerate() }
            }
        }
    }

    // Show a freshly generated completion, tolerating that the user may have typed
    // MORE since the request was issued: if they typed along the prediction we show
    // the remaining tail; if they diverged we regenerate.
    func presentCompletion(_ text: String?, requestedBuffer: String) {
        guard let text, !text.isEmpty else {
            if completion == nil { overlay.orderOut(nil) }
            return
        }
        // Drop completions that just repeat the text after the caret (showing only a
        // partial mid-word remainder would be confusing) — regenerate instead.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if !lastTrailing.isEmpty, !trimmed.isEmpty,
           lastTrailing.hasPrefix(String(trimmed.prefix(min(trimmed.count, 12)))) {
            log("drop completion repeating trailing text"); completion = nil; overlay.orderOut(nil); return
        }
        let chars = Array(text)
        // What did the user type since the request? Robust to the 4000-char cap
        // front-truncating the buffer or an idle-reset clearing it: match on a
        // trailing anchor of the request-time buffer instead of a full hasPrefix.
        let typedSince: [Character]
        if buffer == requestedBuffer {
            typedSince = []
        } else {
            let anchor = String(requestedBuffer.suffix(80))
            if anchor.count >= 8, let r = buffer.range(of: anchor, options: .backwards) {
                typedSince = Array(buffer[r.upperBound...])
            } else if buffer.hasPrefix(requestedBuffer) {
                typedSince = Array(buffer.dropFirst(requestedBuffer.count))
            } else {
                scheduleGenerate(); return     // genuinely diverged — start over
            }
        }
        if typedSince.isEmpty {
            completion = ActiveCompletion(chars: chars)
        } else if typedSince.count < chars.count, Array(chars[0..<typedSince.count]) == typedSince {
            var comp = ActiveCompletion(chars: chars); comp.consumed = typedSince.count
            completion = comp
        } else {
            scheduleGenerate(); return         // typed off the prediction
        }
        stats.shown += 1; statsTouched()
        showCompletionRemainder(animate: true)
        maybePrefetch()
    }

    // MARK: - Typo correction (NSSpellChecker)

    // The word just before the caret, taken from the cheap keystroke buffer. This
    // runs on every word-separator keystroke, so it MUST stay cheap — reading the
    // full focused-element AXValue here would copy hundreds of KB in terminals/
    // editors on each space. The exact AX range for replacement is computed lazily,
    // only when the user actually accepts a correction (see typoRangeViaAX).
    func lastWordFromBuffer() -> String? {
        var chars: [Unicode.Scalar] = []
        for sc in buffer.unicodeScalars.reversed() {
            if isWordSeparator(sc) { if chars.isEmpty { continue } else { break } }
            chars.append(sc)
        }
        let word = String(String.UnicodeScalarView(chars.reversed()))
        return word.isEmpty ? nil : word
    }

    // Locate `word` immediately before the caret in the focused element and return
    // its exact UTF-16 range. Called only on accept, so the one big AXValue read is
    // acceptable. Returns nil for apps without a usable AXValue (keystroke fallback).
    func typoRangeViaAX(word: String) -> (AXUIElement, CFRange)? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var sel = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &sel), sel.location > 0 else { return nil }
        let utf16 = Array(value.utf16)
        let caret = min(sel.location, utf16.count)
        var end = caret
        while end > 0, let sc = Unicode.Scalar(utf16[end - 1]), isWordSeparator(sc) { end -= 1 }
        var start = end
        while start > 0, let sc = Unicode.Scalar(utf16[start - 1]), !isWordSeparator(sc) { start -= 1 }
        guard end > start else { return nil }
        let units = Array(utf16[start..<end])
        guard String(utf16CodeUnits: units, count: units.count) == word else { return nil }
        return (element, CFRange(location: start, length: end - start))
    }

    // Returns the spell-corrected form of a word, or nil if it is correct / not a
    // candidate. Uses the same engine macOS itself uses — local, instant, accurate.
    func correction(for word: String) -> String? {
        guard word.count >= 3, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return nil }
        // Skip likely-intentional all-caps acronyms (NASA, JSON, ...).
        if word.allSatisfy({ $0.isUppercase }) { return nil }
        let checker = NSSpellChecker.shared
        let lang = checker.language()
        let full = NSRange(location: 0, length: (word as NSString).length)
        // Autocorrect first: correction() returns nil for correct words (so no
        // false positives on "hello"/"NASA") but still catches common typos that
        // checkSpelling does not flag, e.g. "teh" -> "the".
        if let c = checker.correction(forWordRange: full, in: word, language: lang, inSpellDocumentWithTag: spellTag),
           c.lowercased() != word.lowercased() { return c }
        // Otherwise only offer a guess when the word is genuinely flagged.
        let mis = checker.checkSpelling(of: word, startingAt: 0)
        guard mis.location != NSNotFound, mis.length > 0 else { return nil }
        if let g = checker.guesses(forWordRange: full, in: word, language: lang, inSpellDocumentWithTag: spellTag)?.first,
           g.lowercased() != word.lowercased() { return g }
        return nil
    }

    @discardableResult
    func showTypoIfMisspelled() -> Bool {
        guard let word = lastWordFromBuffer(), let fix = correction(for: word) else { return false }
        active = HelperSuggestion(kind: "typo", text: nil, original: word, replacement: fix)
        stats.shown += 1; statsTouched()
        // Inline at the caret line, same as completions.
        let point = currentCaretPoint()
        overlay.showTypo(original: word, replacement: fix, at: point, lineHeight: lastCaretHeight)
        dlog("[\(activeAppKey)] typo '\(word)' -> '\(fix)' at=\(point)")
        return true
    }

    // Replace `original` with `text`. Prefers AX (exact range, preserves the
    // trailing separator); falls back to keystroke selection for apps without AX
    // write support. The big AXValue read happens here, only on accept.
    func replaceTypo(original: String, with text: String) {
        if let (element, range) = typoRangeViaAX(word: original), setAXText(element: element, range: range, text: text) {
            replaceLastWordInBuffer(original: original, with: text)
            log("typo replaced via AX")
        } else {
            replaceWordBeforeSeparatorViaKeys(with: text)
            replaceLastWordInBuffer(original: original, with: text)
            log("typo replaced via keystrokes")
        }
    }

    func setAXText(element: AXUIElement, range: CFRange, text: String) -> Bool {
        var r = range
        guard let rangeAx = AXValueCreate(.cfRange, &r) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeAx) == .success else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    func replaceWordBeforeSeparatorViaKeys(with text: String) {
        withPasteboard(text) {
            self.postKey(CGKeyCode(kVK_LeftArrow))                                    // step over the typed separator
            usleep(15_000)
            self.postKey(CGKeyCode(kVK_LeftArrow), flags: [.maskShift, .maskAlternate]) // select the misspelled word
            usleep(15_000)
            self.postPaste()
            usleep(20_000)
            self.postKey(CGKeyCode(kVK_RightArrow))                                   // restore caret after the separator
        }
    }

    func replaceLastWordInBuffer(original: String, with text: String) {
        if let r = buffer.range(of: original, options: .backwards) {
            buffer.replaceSubrange(r, with: text)
            saveActiveAppState()
        }
    }

    // MARK: - Broader context (window scrollback, screen OCR, clipboard, style)

    // Walk the focused window's AX subtree collecting visible text. For chat apps
    // this captures the conversation above the input box; for editors, the document.
    func windowText(limit: Int) -> String {
        guard let element = focusedElement() else { return "" }
        var rootRef: CFTypeRef?
        let root: AXUIElement
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &rootRef) == .success, let r = rootRef {
            root = (r as! AXUIElement)
        } else { root = element }

        var collected: [String] = []
        var seen = Set<String>()
        var budget = 6000
        func walk(_ el: AXUIElement, depth: Int) {
            if depth > 14 || budget <= 0 { return }
            for attr in [kAXValueAttribute, kAXTitleAttribute] {
                var vRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, attr as CFString, &vRef) == .success,
                   let s = vRef as? String {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count >= 2, t.count <= 2000, !seen.contains(t) {
                        seen.insert(t)
                        collected.append(t)
                        budget -= t.count
                    }
                }
            }
            var cRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &cRef) == .success,
               let kids = cRef as? [AXUIElement] {
                for k in kids { if budget <= 0 { break }; walk(k, depth: depth + 1) }
            }
        }
        walk(root, depth: 0)
        // Text nearest the input (typically last in reading order) is most relevant.
        return String(collected.joined(separator: "\n").suffix(limit))
    }

    func clipboardText(limit: Int, relevantTo context: String) -> String {
        let pb = NSPasteboard.general
        // Skip clipboard content password managers mark concealed/transient — never
        // feed a copied password/secret into the prompt or logs.
        let types = pb.types?.map { $0.rawValue } ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") {
            return ""
        }
        guard let s = pb.string(forType: .string) else { return "" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return "" }
        // Relevance: only fold the clipboard into the prompt if it's a short snippet
        // OR shares a meaningful word with what the user is currently writing. Stops
        // unrelated copied blobs from steering completions.
        if t.count > 60 {
            let ctxWords = Set(context.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 })
            let shares = t.lowercased().split { !$0.isLetter }.map(String.init).contains { $0.count >= 4 && ctxWords.contains($0) }
            guard shares else { return "" }
        }
        return String(t.prefix(limit))
    }

    // Capture the frontmost app's largest on-screen window via ScreenCaptureKit
    // (the modern replacement for the now-unavailable CGWindowListCreateImage).
    // Returns the image plus the window's screen frame (Quartz, top-left global),
    // which is needed to map OCR coordinates back to the screen.
    // `frontPID` is snapshotted on the main thread by the caller (NSWorkspace is
    // main-thread-affine). A class box carries the Task's result across the
    // semaphore so there's no write-after-return race on a local var.
    final class CaptureBox { var value: (image: CGImage, frame: CGRect, title: String)? }
    func captureFocusedWindow(frontPID: pid_t?) -> (image: CGImage, frame: CGRect, title: String)? {
        guard #available(macOS 14.0, *) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        let box = CaptureBox()
        Task {
            defer { sem.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            let windows = content.windows.filter {
                $0.isOnScreen && $0.frame.width > 80 && $0.frame.height > 40 &&
                $0.owningApplication?.processID == frontPID
            }
            guard let win = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let config = SCStreamConfiguration()
            config.width = Int(win.frame.width)
            config.height = Int(win.frame.height)
            config.showsCursor = false
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                box.value = (img, win.frame, win.title ?? "")
            }
        }
        // Only read box.value if the Task actually finished (semaphore = happens-after).
        return sem.wait(timeout: .now() + 1.5) == .success ? box.value : nil
    }

    func screenOCR(limit: Int, frontPID: pid_t?) -> String {
        guard CGPreflightScreenCaptureAccess() else { return "" }
        guard let cap = captureFocusedWindow(frontPID: frontPID), cap.image.width > 8, cap.image.height > 8 else { return "" }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate          // far fewer "8nd"/"htttsngtab" misreads
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return "" }
        var lines: [String] = []
        for o in obs {
            guard let cand = o.topCandidates(1).first, cand.confidence >= 0.5 else { continue }
            if isLikelyText(cand.string) { lines.append(cand.string) }
        }
        return String(lines.joined(separator: "\n").suffix(limit))
    }

    // Heuristic gate to keep OCR garbage (UI chrome, misreads, glyph soup) out of the
    // prompt: require mostly letters/spaces and at least one real word.
    func isLikelyText(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 4 else { return false }
        let letters = t.filter { $0.isLetter || $0.isWhitespace }.count
        guard Double(letters) / Double(t.count) >= 0.75 else { return false }
        return t.split(whereSeparator: { !$0.isLetter }).contains { $0.count >= 3 }
    }

    // Screenshot-based caret locator for apps that don't expose AXBoundsForRange
    // (Electron, terminals, custom editors). Captures the focused window, OCRs it,
    // finds where the user's most-recently-typed text ends on screen, and returns
    // the caret rect there. Slow (~150ms), so callers must throttle/cache it.
    func screenshotCaretRect(needle: String, frontPID: pid_t?) -> (rect: CGRect, charWidth: CGFloat)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        // `needle` and `frontPID` are snapshotted on the main thread by the caller —
        // never read self.buffer / NSWorkspace here (off-main).
        guard needle.count >= 3 else { return nil }
        guard let cap = captureFocusedWindow(frontPID: frontPID), cap.image.width > 8 else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cap.image, options: [:])
        guard (try? handler.perform([req])) != nil, let obs = req.results else { return nil }

        // Find the observation that ends with our typed tail. Prefer the lowest one
        // on screen (largest 1-minY), since that's usually the active input line.
        var best: VNRecognizedTextObservation?
        var bestLen = 0
        var bestScore = -1.0
        for o in obs {
            guard let s = o.topCandidates(1).first?.string.lowercased() else { continue }
            let hit = s.hasSuffix(needle) || s.contains(needle) || needle.hasSuffix(s.suffix(min(s.count, 8)))
            if hit {
                let score = Double(1 - o.boundingBox.minY)   // lower on screen wins
                if score > bestScore { bestScore = score; best = o; bestLen = s.count }
            }
        }
        guard let match = best else { return nil }
        // boundingBox is normalized (origin bottom-left of the image). The caret is at
        // the trailing-right edge, on that line.
        let box = match.boundingBox
        let f = cap.frame
        let quartzX = f.minX + box.maxX * f.width
        let quartzTopY = f.minY + (1 - box.maxY) * f.height        // top of the text box, Quartz top-left
        let h = max(12, box.height * f.height)
        let charWidth = bestLen > 0 ? (box.width * f.width) / CGFloat(bestLen) : 9
        return (axRectToAppKit(CGRect(x: quartzX, y: quartzTopY, width: 1, height: h)), charWidth)
    }

    // Best-effort caret point for the overlay. AX is the fast, exact path; if it
    // fails we use a cached screenshot caret extrapolated horizontally by how much
    // has been typed since, and kick off a throttled refresh in the background.
    func currentCaretPoint() -> NSPoint {
        if let ax = caretPoint() {
            shotCaretPoint = nil          // AX is authoritative; drop stale screenshot cache
            lastCaretPoint = ax
            return ax
        }
        if cfg.screenshotCaretEnabled { refreshShotCaretIfNeeded() }
        if let p = shotCaretPoint, shotCaretApp == activeAppKey,
           Date().timeIntervalSince(shotCaretAt) < 6 {
            let typedSince = max(0, buffer.count - shotCaretBufferLen)
            let extrapolated = NSPoint(x: p.x + CGFloat(typedSince) * shotCaretCharWidth, y: p.y)
            lastCaretPoint = extrapolated
            lastCaretHeight = shotCaretHeight
            return extrapolated
        }
        return lastCaretPoint ?? focusedElementPoint() ?? NSPoint(x: 400, y: 400)
    }

    func refreshShotCaretIfNeeded() {
        // Uses Screen Recording (same permission as OCR context) but is independent
        // of the OCR-context toggle — caret placement should work even with it off.
        if shotCaretComputing { return }
        // Recompute when stale or after meaningful typing since the last fix. Each
        // recompute is a screenshot + OCR, so throttle hard: extrapolate horizontally
        // between captures and only re-capture after a real pause or large drift.
        let stale = Date().timeIntervalSince(shotCaretAt) > 4.0 || shotCaretApp != activeAppKey
        let drift = abs(buffer.count - shotCaretBufferLen) > 24
        guard stale || drift else { return }
        shotCaretComputing = true
        let appKey = activeAppKey
        let bufLen = buffer.count
        // Snapshot everything off `self` ON THE MAIN THREAD; the background closure
        // must not touch self.buffer (concurrent String mutation = crash).
        let needle = String(String(buffer.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines).suffix(18)).lowercased()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        backgroundQueue.async {
            let res = self.screenshotCaretRect(needle: needle, frontPID: frontPID)
            DispatchQueue.main.async {
                self.shotCaretComputing = false
                guard appKey == self.activeAppKey, let res else { return }
                self.shotCaretPoint = NSPoint(x: res.rect.maxX + 2, y: res.rect.minY)
                self.shotCaretCharWidth = res.charWidth
                self.shotCaretHeight = res.rect.height
                self.shotCaretBufferLen = bufLen
                self.shotCaretAt = Date()
                self.shotCaretApp = appKey
                // Re-place the live suggestion now that we know where the caret is.
                if self.completion != nil { self.showCompletionRemainder() }
            }
        }
    }

    // Refresh the cached background off the hot path, throttled by time + app key.
    func refreshBackgroundIfNeeded() {
        let key = activeAppKey
        // Refresh less often while saving power (fewer AX/screenshot wakeups).
        let interval = powerSaving ? max(cfg.backgroundRefreshSeconds, 10.0) : cfg.backgroundRefreshSeconds
        let fresh = Date().timeIntervalSince(backgroundRefreshedAt) < interval && key == backgroundKey
        if fresh || backgroundRefreshing { return }
        backgroundRefreshing = true
        // Snapshot cfg flags + frontmost PID on main (cfg mutates on main; NSWorkspace
        // is main-affine).
        let wantWindow = cfg.windowContextEnabled
        let wantScreen = cfg.screenContextEnabled
        let wantClipboard = cfg.clipboardContextEnabled
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recentText = String(buffer.suffix(300))   // for clipboard relevance
        backgroundQueue.async {
            var parts: [String] = []
            // Prefer clean AX text. Only fall back to (noisier) OCR when AX gives us
            // little — typically Electron apps. This keeps OCR misreads out of the
            // prompt whenever a reliable source exists.
            var windowChars = 0
            if wantWindow {
                let w = self.windowText(limit: 1000)
                if w.count > 40 { parts.append(w); windowChars = w.count }
            }
            if wantScreen, windowChars < 120 {
                let o = self.screenOCR(limit: 600, frontPID: frontPID)
                if o.count > 40 { parts.append(o) }
            }
            if wantClipboard {
                let c = self.clipboardText(limit: 200, relevantTo: recentText)
                if !c.isEmpty { parts.append("Clipboard: " + c) }
            }
            let bg = parts.joined(separator: "\n")
            DispatchQueue.main.async {
                self.cachedBackground = bg
                self.backgroundRefreshedAt = Date()
                self.backgroundKey = key
                self.backgroundRefreshing = false
                log("background refreshed key=\(key) chars=\(bg.count)")
            }
        }
    }

    // Assemble the final prompt context. The immediate before-cursor text always
    // comes LAST so the base model continues it; style + background precede it to
    // bias tone and topic. Heavy background is only folded in when the field itself
    // is sparse (chat boxes), where it helps most and risks the least regression.
    // Ambient topic capture: periodically OCR the focused window, distill its salient
    // topics, and store them. Throttled by the timer (every topic_capture_seconds) and
    // single-flighted, so it stays cheap.
    func startTopicTimer() {
        topicTimer?.invalidate(); topicTimer = nil
        guard cfg.topicMemoryEnabled else { return }
        let period = max(60, cfg.topicCaptureSeconds)
        topicTimer = Timer.scheduledTimer(withTimeInterval: period, repeats: true) { [weak self] _ in self?.captureTopic() }
        // One capture shortly after enabling/launch so it doesn't feel inert.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.captureTopic() }
    }

    func captureTopic() {
        guard cfg.topicMemoryEnabled, !topicCapturing, cfg.enabled else { return }
        if IsSecureEventInputEnabled() || isAppDisabled() { return }     // never capture secrets / disabled apps
        // Topic memory is for content you read (sites, docs), not terminals — those are
        // noisy (code/logs) and sensitive, so always skip them regardless of the
        // terminal-completion setting.
        if TyperApp.terminalBundleIDs.contains(currentAppBundleAndName().bundle) { return }
        guard CGPreflightScreenCaptureAccess() else { return }
        if powerSaving { return }                                        // skip the screenshot+OCR burst on battery saver
        topicCapturing = true
        let appKey = activeAppKey
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        backgroundQueue.async {
            defer { DispatchQueue.main.async { self.topicCapturing = false } }
            guard let cap = self.captureFocusedWindow(frontPID: frontPID), cap.image.width > 8 else { return }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            guard (try? VNImageRequestHandler(cgImage: cap.image, options: [:]).perform([req])) != nil,
                  let obs = req.results else { return }
            let text = obs.compactMap { o -> String? in
                guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
                return c.string
            }.joined(separator: "\n")
            guard text.count >= 80 else { return }
            let (keys, note) = distillTopics(text: text, title: cap.title)
            guard !keys.isEmpty, !note.isEmpty else { return }
            let appName = appKey.split(separator: "|").last.map(String.init) ?? appKey
            self.topicMemory.record(TopicEntry(at: Date().timeIntervalSince1970, app: appName,
                                               title: cap.title, keys: keys, note: note))
            log("topic captured app=\(appName) keys=\(keys.count)")
        }
    }

    func assembledContext(immediate: String) -> String {
        var blocks: [String] = []
        if cfg.styleMemoryEnabled {
            let s = styleMemory.sample(maxChars: immediate.count < cfg.maxImmediateForBackground ? 300 : 140)
            if s.split(separator: " ").count >= 4 { blocks.append(s) }
        }
        // Resurface a recently-viewed topic ONLY when the user is now typing about it
        // (a distinctive entity/keyword from it appears in their recent text).
        if cfg.topicMemoryEnabled, let note = topicMemory.relevant(to: String(immediate.suffix(220))) {
            blocks.append("(Earlier you read — \(note))")
        }
        if immediate.count < cfg.maxImmediateForBackground, !cachedBackground.isEmpty {
            blocks.append(String(cachedBackground.suffix(700)))
        }
        blocks.append(immediate)
        return blocks.count == 1 ? immediate : blocks.joined(separator: "\n\n")
    }

    func clearSuggestion() {
        reanchorWork?.cancel()
        active = nil
        completion = nil
        prefetched = nil
        prefetchKey = ""
        overlay.orderOut(nil)
    }

    // Tab/backtick for the typo diff (completions are handled separately by
    // acceptCompletionWord / acceptCompletionAll).
    func acceptOneWord() -> Bool {
        guard let active, active.kind == "typo",
              let replacement = active.replacement, let original = active.original else { return false }
        replaceTypo(original: original, with: replacement)
        stats.accepted += 1; statsTouched()
        clearSuggestion()
        return true
    }

    func acceptAll() -> Bool {
        // The only diff-style suggestion is typo; accepting all == accepting the word.
        return acceptOneWord()
    }

    // Insert accepted text by synthesizing a single Unicode keystroke event — no
    // pasteboard involved, so the user's clipboard is never touched (no loss, no
    // leak, no races). We arm a suppression window so our own injected keystroke
    // isn't re-processed as user typing.
    func insert(_ text: String) {
        let units = Array(text.replacingOccurrences(of: "\r", with: "").utf16)
        guard !units.isEmpty else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        units.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buf.baseAddress)
        }
        // Tag so we recognize (and ignore) our own injected events exactly — never by
        // count/timing, which races a fast real keystroke into being swallowed.
        down.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // Accept text by briefly putting it on the clipboard and pasting. Safer version:
    //  - serialized (no overlapping inserts that leave the suggestion stuck on the clipboard)
    //  - snapshots/restores ALL item types (not just .string), so images/files survive
    //  - uses changeCount to NOT clobber anything the user copied during the paste window
    func withPasteboard(_ text: String, action: () -> Void) {
        let pb = NSPasteboard.general
        if pasteboardBusy { return }      // don't overlap; a dropped accept is fine
        pasteboardBusy = true

        // Deep-copy the existing items so we can restore non-text content too.
        let saved: [NSPasteboardItem] = pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let d = item.data(forType: type) { copy.setData(d, forType: type) } }
            return copy.types.isEmpty ? nil : copy
        } ?? []

        pb.clearContents()
        pb.setString(text, forType: .string)
        let afterWrite = pb.changeCount
        action()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            defer { self.pasteboardBusy = false }
            // If the user copied something during the window, leave THEIR clipboard alone.
            guard pb.changeCount == afterWrite else { return }
            pb.clearContents()
            if saved.isEmpty { pb.setString("", forType: .string) } else { pb.writeObjects(saved) }
        }
    }

    func postPaste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    func focusedElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    struct AXContext {
        var before: String
        var after: String
    }

    // Reads the text up to and after the caret from the focused element's AXValue
    // + selected range. Mirrors Cotypist's textUpToCursor / textAfterCursor split:
    // `before` drives the completion prompt; `after` lets us suppress mid-line
    // suggestions (don't autocomplete into the middle of existing text).
    func textAroundCursor(limit: Int) -> AXContext? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, !value.isEmpty else { return nil }
        // Guard the hot path: terminals and large editors expose enormous AXValues
        // (Ghostty reports ~400k chars). Copying that on every keystroke would jank
        // the event tap, so fall back to the keystroke buffer for oversized fields.
        guard value.utf16.count <= 20000 else {
            log("[\(activeAppKey)] AX value too large (\(value.count) chars); using key buffer")
            return nil
        }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        let utf16 = value.utf16
        let cut = min(range.location, utf16.count)
        let caretIdx = String.Index(utf16Offset: cut, in: value)
        let before = String(String(value[..<caretIdx]).suffix(limit))
        let after = String(String(value[caretIdx...]).prefix(limit))
        dlog("[\(activeAppKey)] AX text context valueChars=\(value.count) cursorUtf16=\(range.location) before=\(before.count) after=\(after.count)")
        return AXContext(before: before, after: after)
    }

    // True when the caret sits in the middle of a word/line of existing text, e.g.
    // editing "the qu|ick fox". Inline continuation there would be wrong, so we
    // suppress it — matching Cotypist's mid-line completion behavior.
    func isMidLine(after: String) -> Bool {
        // Suppress if ANY real text remains on the current line after the caret
        // (not just the immediately-adjacent char) — completing into "hello| world"
        // is as wrong as "the qu|ick". Trailing whitespace before a newline is fine.
        let restOfLine = after.prefix { $0 != "\n" && $0 != "\r" }
        return restOfLine.contains { !$0.isWhitespace }
    }

    // AX caret height is inconsistent — the same field yields a tight line-height on
    // one read and the whole field height on the next (when the precise BoundsForRange
    // branch fails). Since the real line height never grows within a focus session,
    // floor to the smallest seen so the ghost font never jumps comically large.
    func stabilizeCaretHeight(_ h: CGFloat) -> CGFloat {
        guard h > 0 else { return h }
        let f = min(h, caretHeightFloor ?? h)
        caretHeightFloor = f
        return f
    }

    func caretPoint() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        // Native AppKit text views answer AXBoundsForRange. Chromium/Electron and
        // WebKit (Discord, Slack, VS Code, Chrome, Safari) don't — they expose the
        // caret via the AXTextMarker API instead. Try both.
        guard let rect = boundsForSelectedRange(element: element) ?? textMarkerCaretRect(element: element) else { return nil }
        // rect is already in AppKit (bottom-left) coordinates. Return the caret's
        // right edge + bottom; the line height lets the overlay render inline.
        lastCaretHeight = stabilizeCaretHeight(rect.height)
        let point = NSPoint(x: rect.maxX + 2, y: rect.minY)
        dlog("caret point=\(point) h=\(rect.height) from rect=\(rect)")
        return point
    }

    // Caret rect via the WebKit/Chromium AXTextMarker attributes. These are private
    // string-named AX attributes (not in the public constants) but are read the same
    // way; the marker-range value is opaque and just passed straight through.
    func textMarkerCaretRect(element: AXUIElement) -> CGRect? {
        var markerRange: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &markerRange) == .success,
              let markerRange else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString, markerRange, &boundsRef) == .success,
              let boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        // A collapsed caret comes back zero-width, so validate directly here rather
        // than via isPlausibleCaretRect (which assumes a non-zero width).
        let r = axRectToAppKit(rect)
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.height >= 4, r.height <= 200, r.width <= 2000 else { return nil }
        if r.origin.x == 0 && r.origin.y == 0 { return nil }
        guard NSScreen.screens.contains(where: { $0.frame.intersects(r.insetBy(dx: -2, dy: -2)) }) else { return nil }
        dlog("[\(activeAppKey)] caret via text marker rect=\(r)")
        return r
    }

    func focusedElementPoint() -> NSPoint? {
        guard let element = focusedElement() else { return nil }
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        let rect = axRectToAppKit(CGRect(origin: point, size: size))
        let fallback = NSPoint(x: rect.minX + 12, y: rect.maxY - 24)
        dlog("fallback focused element point=\(fallback) ax=\(point) size=\(size) converted=\(rect)")
        return fallback
    }

    func axRectToAppKit(_ rect: CGRect) -> CGRect {
        // AX APIs report global coordinates with a top-left origin anchored at the
        // top-left of the PRIMARY display (the menu-bar / zero-origin screen) — the
        // same space as CGEvent / CGDisplayBounds. AppKit (NSPanel.setFrame,
        // NSScreen.frame) uses a bottom-left origin anchored at the bottom-left of
        // that same primary screen. The flip therefore must use the primary
        // screen's height, NOT the height of whatever screen the rect lands on.
        // Using the local screen's maxY breaks on multi-monitor setups.
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryMaxY = primary?.frame.maxY ?? rect.maxY
        return CGRect(x: rect.origin.x,
                      y: primaryMaxY - rect.origin.y - rect.height,
                      width: rect.width,
                      height: rect.height)
    }

    // A caret rect coming back from AX is only trustworthy if it is finite,
    // on-screen, and has a plausible line height. Many apps return (0,0,0,0),
    // the whole text view, or NaN for a zero-length caret range — reject those.
    func isPlausibleCaretRect(_ r: CGRect) -> Bool {
        guard r.origin.x.isFinite, r.origin.y.isFinite, r.width.isFinite, r.height.isFinite else { return false }
        if r.height < 4 || r.height > 200 { return false }
        if r.width > 2000 { return false } // whole-text-view bounds, not a caret
        if r.origin.x == 0 && r.origin.y == 0 { return false } // classic bogus origin
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(r.insetBy(dx: -2, dy: -2)) }
        return onScreen
    }

    func boundsForSelectedRange(element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { dlog("AX selected range unavailable"); return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

        // Returns the AX rect (top-left origin) for a character range, or nil.
        func axRect(for input: CFRange) -> CGRect? {
            var r = input
            guard let rangeAx = AXValueCreate(.cfRange, &r) else { return nil }
            var boundsRef: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeAx, &boundsRef) == .success,
                  let boundsValue = boundsRef else { return nil }
            var rect = CGRect.zero
            guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &rect) else { return nil }
            return rect
        }
        // Converts to AppKit coords and accepts only if plausible.
        func caret(from input: CFRange, anchor: (CGRect) -> CGRect) -> CGRect? {
            guard let r0 = axRect(for: input) else { return nil }
            let r = axRectToAppKit(r0)
            let c = anchor(r)
            return isPlausibleCaretRect(c) ? c : nil
        }

        // 1. Active selection: highlight the selected glyphs directly.
        if range.length > 0, let r = caret(from: range, anchor: { $0 }) {
            dlog("AX selected rect loc=\(range.location) len=\(range.length) rect=\(r)")
            return r
        }
        // 2. Zero-length caret: some apps return a valid thin caret rect here.
        if let r = caret(from: range, anchor: { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }) {
            dlog("AX caret direct loc=\(range.location) rect=\(r)")
            return r
        }
        // 3. cursorRectIsFromPreviousCharacter: anchor to the end of the prior glyph.
        if range.location > 0,
           let r = caret(from: CFRange(location: range.location - 1, length: 1),
                         anchor: { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }) {
            dlog("AX caret inferred from prev loc=\(range.location) rect=\(r)")
            return r
        }
        // 4. Anchor to the start of the next glyph.
        if let r = caret(from: CFRange(location: range.location, length: 1),
                         anchor: { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }) {
            dlog("AX caret inferred from next loc=\(range.location) rect=\(r)")
            return r
        }
        // 5. beginningOfParagraphRect: walk back to the line/paragraph start so we
        //    at least land on the correct text line when the exact glyph fails.
        // Cap the back-scan: each step is a synchronous AXBoundsForRange IPC round-trip,
        // so a deep scan can stall the main thread. 40 glyphs is plenty to recover the
        // current line; beyond that we fall back rather than block.
        var lineStart = range.location
        while lineStart > 0 && lineStart > range.location - 40 {
            if let r = caret(from: CFRange(location: lineStart - 1, length: 1),
                             anchor: { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }) {
                dlog("AX caret from paragraph scan loc=\(lineStart) rect=\(r)")
                return r
            }
            lineStart -= 1
        }
        dlog("AX bounds unavailable for range loc=\(range.location) len=\(range.length)")
        return nil
    }

    // Count text we inserted on the user's behalf (Tab/backtick) — the "saved typing".
    func recordCompleted(_ text: String) {
        stats.wordsCompleted += text.split(whereSeparator: { $0.isWhitespace }).count
        stats.charsCompleted += text.count
        markActiveToday()
    }

    func markActiveToday() {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        if stats.lastActiveDay == today { return }
        let yesterday = fmt.string(from: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        stats.activeDays += 1
        stats.currentStreak = (stats.lastActiveDay == yesterday) ? stats.currentStreak + 1 : 1
        stats.longestStreak = max(stats.longestStreak, stats.currentStreak)
        stats.lastActiveDay = today
    }

    func numberFormatted(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // Playful menu lines about how much you've tab-completed.
    func funFacts() -> [String] {
        let w = stats.wordsCompleted
        var lines = ["⌨  \(numberFormatted(w)) words tab-completed"]

        // One scaling comparison — pick the biggest milestone reached.
        let bible = 783_137.0, lotr = 481_103.0, hobbit = 95_356.0
        let hp1 = 76_944.0, novel = 90_000.0
        if w >= Int(bible) {
            lines.append(String(format: "📖 ≈ %.1f Bibles", Double(w) / bible))
        } else if w >= Int(lotr) {
            lines.append(String(format: "🧙 ≈ %.1f Lord of the Rings trilogies", Double(w) / lotr))
        } else if w >= Int(hobbit) {
            lines.append(String(format: "🧙 ≈ %.1f Hobbits' worth of words", Double(w) / hobbit))
        } else if w >= Int(hp1) {
            lines.append(String(format: "⚡️ ≈ %.0f%% of a Harry Potter book", Double(w) / hp1 * 100))
        } else if w >= 2_000 {
            lines.append(String(format: "✍️ ≈ %.1f%% of a novel · %d pages", Double(w) / novel * 100, w / 250))
        } else if w >= 200 {
            lines.append("📝 ≈ \(w / 50) tweets' worth")
        } else if w > 0 {
            lines.append("More fun facts unlock as you complete more ✨")
        }

        // Time saved (~40 wpm of typing avoided) and streak.
        let minutes = w / 40
        if minutes >= 1 { lines.append("⏳ ≈ \(numberFormatted(minutes)) min of typing saved") }
        if stats.currentStreak > 0 {
            lines.append("🔥 \(stats.currentStreak)-day streak · \(stats.activeDays) active days · best \(stats.longestStreak)")
        }
        return lines
    }

    // Persist stats at most ~once/sec (called from the hot path on accept/ignore).
    func statsTouched() {
        updateStatusTitle()              // cheap live badge; full menu rebuilds on open
        if statsSaveScheduled { return }
        statsSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.statsSaveScheduled = false
            self.stats.save()
        }
    }

    @objc func clearStyle() {
        styleMemory.clear()
        log("cleared learned style")
        rebuildMenu()
    }

    @objc func quit() { stats.save(); NSApp.terminate(nil) }
}

extension CGEvent {
    var keyboardString: String? {
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

let app = NSApplication.shared
let delegate = TyperApp()
app.delegate = delegate
app.run()
