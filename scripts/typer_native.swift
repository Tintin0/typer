import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import ScreenCaptureKit
import Vision

let typerLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Typer.log")

func log(_ message: String) {
    let line = "\(Date()) \(message)\n"
    if !FileManager.default.fileExists(atPath: typerLogURL.path) {
        FileManager.default.createFile(atPath: typerLogURL.path, contents: nil)
    }
    if let handle = try? FileHandle(forWritingTo: typerLogURL) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

struct TyperConfig {
    var enabled = true
    var completionEnabled = true
    var typoEnabled = false
    var grammarEnabled = false
    var modelPath = ""   // explicit .gguf path; empty = auto-pick first in Models dir
    var maxCompletionWords = 7
    var minContextChars = 6
    var debounceMs = 25   // low: the first suggestion should appear without stopping
    var activeTypingWindowMs = 3000
    var idleResetSeconds = 20
    var temperature = 0.0
    // Broader-context sources. All on-device. Each degrades gracefully if its data
    // is unavailable (e.g. AX-hostile apps, or Screen Recording not granted).
    var windowContextEnabled = true   // read surrounding text in the focused window via AX
    var styleMemoryEnabled = true     // bias completions toward the user's own recent writing
    var clipboardContextEnabled = true
    var screenContextEnabled = false  // screenshot OCR as prompt context — off by default (noisy)
    var backgroundRefreshSeconds = 4.0
    var maxImmediateForBackground = 220 // only fold in background when the field itself is sparse

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
            case "grammar_correction_enabled": cfg.grammarEnabled = value == "true"
            case "model_path": cfg.modelPath = (value as NSString).expandingTildeInPath
            case "max_completion_words": cfg.maxCompletionWords = Int(value) ?? cfg.maxCompletionWords
            case "min_context_chars": cfg.minContextChars = Int(value) ?? cfg.minContextChars
            case "debounce_ms": cfg.debounceMs = Int(value) ?? cfg.debounceMs
            case "active_typing_window_ms": cfg.activeTypingWindowMs = Int(value) ?? cfg.activeTypingWindowMs
            case "idle_reset_seconds": cfg.idleResetSeconds = Int(value) ?? cfg.idleResetSeconds
            case "temperature": cfg.temperature = Double(value) ?? cfg.temperature
            case "window_context_enabled": cfg.windowContextEnabled = value == "true"
            case "style_memory_enabled": cfg.styleMemoryEnabled = value == "true"
            case "clipboard_context_enabled": cfg.clipboardContextEnabled = value == "true"
            case "screen_context_enabled": cfg.screenContextEnabled = value == "true"
            case "background_refresh_seconds": cfg.backgroundRefreshSeconds = Double(value) ?? cfg.backgroundRefreshSeconds
            default: break
            }
        }
        return cfg
    }
}

struct MLXRequest: Codable {
    let task: String
    let context: String
    let max_words: Int
}

struct MLXSuggestion: Codable {
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
    let suggestion: MLXSuggestion?
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

final class MLXClient {
    private let cfg: TyperConfig
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
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
        guard let model = MLXClient.findModel(cfg) else {
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
    }

    // Sends one request and reads the streaming response. `onPartial` is invoked
    // (on this background thread) for each partial completion; the final suggestion
    // is returned.
    func request(task: String, context: String, maxWords: Int, onPartial: ((String) -> Void)? = nil) throws -> MLXSuggestion? {
        lock.lock(); defer { lock.unlock() }
        try start()
        let req = MLXRequest(task: task, context: context, max_words: maxWords)
        log("request task=\(task) chars=\(context.count) suffix=\(String(context.suffix(40)).replacingOccurrences(of: "\n", with: "\\n"))")
        let data = try JSONEncoder().encode(req) + Data([0x0A])
        try input?.write(contentsOf: data)
        let decoder = JSONDecoder()
        while true {
            guard let line = try output?.readLine(), !line.isEmpty else {
                process = nil
                throw NSError(domain: "Typer", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper exited"])
            }
            let res = try decoder.decode(StreamLine.self, from: line)
            if let p = res.p { onPartial?(p); continue }      // partial token update
            if res.ok == false {
                throw NSError(domain: "Typer", code: 2, userInfo: [NSLocalizedDescriptionKey: res.error ?? "Unknown error"])
            }
            log("response kind=\(res.suggestion?.kind ?? "nil") text=\((res.suggestion?.text ?? res.suggestion?.replacement ?? "nil").prefix(80))")
            return res.suggestion                              // final line
        }
    }
}

extension FileHandle {
    func readLine() throws -> Data? {
        var data = Data()
        while true {
            let chunk = try read(upToCount: 1)
            guard let chunk, !chunk.isEmpty else { return data.isEmpty ? nil : data }
            if chunk[0] == 0x0A { return data }
            data.append(chunk)
        }
    }
}

final class SuggestionOverlay: NSPanel {
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 38),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        label.frame = NSRect(x: 0, y: 0, width: 420, height: 38)
        label.isBezeled = false
        label.drawsBackground = false
        label.backgroundColor = .clear
        label.lineBreakMode = .byTruncatingTail
        contentView = label
        orderOut(nil)
    }

    // Match the app's text size from the caret line height so the ghost sits inline.
    private func fontSize(for lineHeight: CGFloat) -> CGFloat {
        min(max(lineHeight * 0.62, 11), 30)
    }

    func showCompletion(_ text: String, at point: NSPoint, lineHeight: CGFloat) {
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize(for: lineHeight)),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.5)
            ]
        )
        placeInline(at: point, lineHeight: lineHeight)
    }

    func showTypo(original: String, replacement: String, at point: NSPoint, lineHeight: CGFloat) {
        let fs = fontSize(for: lineHeight)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: original, attributes: [
            .font: NSFont.systemFont(ofSize: fs),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .foregroundColor: NSColor.systemRed.withAlphaComponent(0.7)
        ]))
        s.append(NSAttributedString(string: " → " + replacement, attributes: [
            .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
            .foregroundColor: NSColor.systemGreen.withAlphaComponent(0.95)
        ]))
        label.attributedStringValue = s
        placeInline(at: point, lineHeight: lineHeight)
    }

    func showGrammar(original: String, replacement: String, at point: NSPoint, lineHeight: CGFloat) {
        label.attributedStringValue = NSAttributedString(string: replacement, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize(for: lineHeight), weight: .medium),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: NSColor.systemYellow,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.9)
        ])
        placeInline(at: point, lineHeight: lineHeight)
    }

    // `point` is the caret's right edge (x) and bottom (y). The panel is exactly the
    // caret line height, so the single-line label is vertically centered on the
    // caret line — the suggestion renders inline with the user's text.
    private func placeInline(at point: NSPoint, lineHeight: CGFloat) {
        let h = max(lineHeight, 14)
        let w = min(max(label.intrinsicContentSize.width + 6, 30), 760)
        let textH = label.intrinsicContentSize.height
        // Center the text vertically within the caret-line-height panel.
        label.frame = NSRect(x: 3, y: (h - textH) / 2, width: w - 6, height: textH)
        var frame = NSRect(x: point.x, y: point.y, width: w, height: h)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main {
            let v = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.origin.x, v.minX), v.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, v.minY), v.maxY - frame.height)
        }
        setFrame(frame, display: true)
        if !isVisible { orderFrontRegardless() }   // avoid a re-order flash on every update
    }
}

// Persistent, on-device record of the user's own writing. A small rolling sample
// is fed into the prompt so completions adopt the user's tone and vocabulary.
// Entirely local: ~/Library/Application Support/typer/style.txt, capped in size.
final class StyleMemory {
    private let url: URL
    private let maxBytes = 40_000
    private let queue = DispatchQueue(label: "typer.style", qos: .utility)

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("style.txt")
    }

    func record(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only keep substantive, sentence-like writing — not stray words.
        guard t.split(separator: " ").count >= 4 else { return }
        queue.async {
            var existing = (try? String(contentsOf: self.url, encoding: .utf8)) ?? ""
            // Dedupe: skip if this exact line is among the most recent entries (the
            // same buffer is flushed on both app-switch and Return).
            let recent = existing.split(separator: "\n").suffix(8).map(String.init)
            if recent.contains(t) { return }
            existing += "\n" + t
            if existing.utf8.count > self.maxBytes { existing = String(existing.suffix(self.maxBytes / 2)) }
            try? existing.write(to: self.url, atomically: true, encoding: .utf8)
        }
    }

    func sample(maxChars: Int) -> String {
        guard maxChars > 0, let raw = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        // Most-recent writing is most representative of current voice.
        let lines = raw.split(separator: "\n").map(String.init).reversed()
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
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return raw.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    func clear() { queue.async { try? FileManager.default.removeItem(at: self.url) } }
}

// Lightweight persisted acceptance stats — how often shown suggestions are taken
// vs. typed past. Surfaced in the menu; foundation for tuning behavior over time.
struct TyperStats: Codable {
    var shown = 0
    var accepted = 0
    var ignored = 0
    var acceptRate: Int { shown > 0 ? Int((Double(accepted) / Double(shown)) * 100) : 0 }

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

final class TyperApp: NSObject, NSApplicationDelegate {
    var cfg = TyperConfig.load()
    var client: MLXClient!
    var statusItem: NSStatusItem!
    let overlay = SuggestionOverlay()
    var eventTap: CFMachPort?
    var buffer = ""
    var lastInput = Date()
    var activeAppKey = "unknown"
    var buffersByApp: [String: String] = [:]
    var lastInputByApp: [String: Date] = [:]
    var debounce: Timer?
    var active: MLXSuggestion?          // typo / grammar diff suggestions
    var completion: ActiveCompletion?   // the inline completion being typed into
    var lastCaretPoint: NSPoint?
    var lastCaretHeight: CGFloat = 18   // caret line height, to match the app's font
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
    var acceptedWords = 0
    var shift = false
    var ctrl = false
    var alt = false
    var cmd = false
    var stats = TyperStats.load()       // cumulative, persisted across launches
    var statsSaveScheduled = false
    var generationSerial = 0
    // Typo state: when a misspelled word is detected we remember its exact range
    // in the focused element so acceptance can replace it precisely via AX.
    var pendingTypoElement: AXUIElement?
    var pendingTypoRange: CFRange?
    let spellTag = NSSpellChecker.uniqueSpellDocumentTag()
    // Broader context: an expensive-to-compute "background" (window scrollback +
    // screen OCR + clipboard) is cached and refreshed off the hot path, never per
    // keystroke. Style memory personalizes regardless of app.
    let styleMemory = StyleMemory()
    var cachedBackground = ""
    var backgroundRefreshedAt = Date.distantPast
    var backgroundKey = ""
    var backgroundRefreshing = false
    let backgroundQueue = DispatchQueue(label: "typer.background", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Typer launch cfg enabled=\(cfg.enabled) completion=\(cfg.completionEnabled) typo=\(cfg.typoEnabled) debounce=\(cfg.debounceMs)")
        activeAppKey = currentAppKey()
        log("initial app=\(activeAppKey)")
        client = MLXClient(cfg: cfg)
        promptAccessibility()
        if cfg.screenContextEnabled, !CGPreflightScreenCaptureAccess() {
            // Triggers the one-time Screen Recording permission prompt. OCR context
            // simply stays empty until granted; everything else keeps working.
            CGRequestScreenCaptureAccess()
            log("requested Screen Recording access (for OCR context)")
        }
        setupMenu()
        setupEventTap()
        DispatchQueue.global(qos: .utility).async { try? self.client.start() }
    }

    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("AX trusted=\(trusted)")
    }

    func setupMenu() {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌨︎"
        rebuildMenu()
    }

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
        let menu = NSMenu()
        let model = (MLXClient.findModel(cfg).map { ($0 as NSString).lastPathComponent }) ?? "no model"
        menu.addItem(disabledItem("Typer — \(cfg.enabled ? "on" : "paused")"))
        menu.addItem(disabledItem("Model: \(model)"))
        menu.addItem(disabledItem("Shown \(stats.shown) · Accepted \(stats.acceptRate)% · Ignored \(stats.ignored)"))
        menu.addItem(disabledItem("Learned style: \(styleMemory.sentenceCount()) sentences"))
        menu.addItem(.separator())

        menu.addItem(toggleItem("Enabled", key: "enabled", value: cfg.enabled))
        menu.addItem(toggleItem("Completions", key: "completion_enabled", value: cfg.completionEnabled))
        menu.addItem(toggleItem("Typo correction", key: "typo_correction_enabled", value: cfg.typoEnabled))
        menu.addItem(.separator())

        let ctx = NSMenu()
        ctx.addItem(toggleItem("Window text", key: "window_context_enabled", value: cfg.windowContextEnabled))
        ctx.addItem(toggleItem("Clipboard", key: "clipboard_context_enabled", value: cfg.clipboardContextEnabled))
        ctx.addItem(toggleItem("Screen OCR (noisy)", key: "screen_context_enabled", value: cfg.screenContextEnabled))
        ctx.addItem(toggleItem("Learn my style", key: "style_memory_enabled", value: cfg.styleMemoryEnabled))
        let ctxItem = NSMenuItem(title: "Context sources", action: nil, keyEquivalent: ""); ctxItem.submenu = ctx
        menu.addItem(ctxItem)
        menu.addItem(NSMenuItem(title: "Clear Learned Style", action: #selector(clearStyle), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Log…", action: #selector(openLog), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Typer", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.target == nil { item.target = self }
        statusItem.menu = menu
        statusItem.button?.title = cfg.enabled ? "⌨︎" : "⌨︎⏸"
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
        case "style_memory_enabled": cfg.styleMemoryEnabled = v
        default: break
        }
        writeConfig(key, v ? "true" : "false")
        log("toggle \(key)=\(v)")
        rebuildMenu()
    }

    @objc func openConfig() { NSWorkspace.shared.open(configURL()) }
    @objc func openLog() { NSWorkspace.shared.open(typerLogURL) }

    func setupEventTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let app = Unmanaged<TyperApp>.fromOpaque(refcon!).takeUnretainedValue()
            return app.handle(type: type, event: event)
        }
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: CGEventMask(mask),
                                     callback: callback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap else {
            log("ERROR event tap creation failed; Accessibility/Input Monitoring permission likely missing for Typer.app")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        log("event tap enabled")
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        syncActiveApp()
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            setModifier(code, down: false)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        setModifier(code, down: true)
        let flags = event.flags
        let hasCommandLikeModifier = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)

        if code == CGKeyCode(kVK_Tab) {
            if acceptCompletionWord() { return nil }
            if acceptOneWord() { return nil }       // typo / grammar
            return Unmanaged.passUnretained(event)
        }
        if code == CGKeyCode(kVK_ANSI_Grave) {
            if acceptCompletionAll() { return nil }
            if acceptAll() { return nil }            // typo / grammar
            return Unmanaged.passUnretained(event)
        }
        if code == CGKeyCode(kVK_Escape) {
            clearSuggestion()
            return Unmanaged.passUnretained(event)
        }
        if code == CGKeyCode(kVK_Delete) {
            if !buffer.isEmpty { buffer.removeLast() }
            saveActiveAppState()
            clearSuggestion()        // editing backward always cancels the prediction
            scheduleGenerate()
            return Unmanaged.passUnretained(event)
        }
        if code == CGKeyCode(kVK_Return) {
            // In chat/search fields Return usually submits. Reset so the next message
            // does not inherit stale context; Shift-Return still records a newline.
            if flags.contains(.maskShift) { push("\n") } else {
                if cfg.styleMemoryEnabled { styleMemory.record(buffer) }
                buffer = ""; saveActiveAppState(); clearSuggestion()
            }
            return Unmanaged.passUnretained(event)
        }
        if hasCommandLikeModifier || cmd || ctrl || alt { return Unmanaged.passUnretained(event) }
        if let chars = event.keyboardString, !chars.isEmpty {
            log("[\(activeAppKey)] key chars=\(chars.replacingOccurrences(of: "\n", with: "\\n")) code=\(code)")
            handleTyping(chars)
        } else {
            log("key nochars code=\(code)")
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
            stats.ignored += 1; statsTouched()   // shown but the user typed elsewhere
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
            // Anti-flicker: the caret advanced by exactly the width of what was typed,
            // so shift the cached point by that width instead of re-querying AX (which
            // is laggy/jittery on fast typing). Re-anchoring happens on a fresh
            // suggestion, not on every consumed character.
            if let p = lastCaretPoint {
                lastCaretPoint = NSPoint(x: p.x + ghostWidth(text), y: p.y)
            }
            showCompletionRemainder(reanchor: false)
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

    func setModifier(_ code: CGKeyCode, down: Bool) {
        switch Int(code) {
        case kVK_Shift, kVK_RightShift: shift = down
        case kVK_Command, kVK_RightCommand: cmd = down
        case kVK_Control, kVK_RightControl: ctrl = down
        case kVK_Option, kVK_RightOption: alt = down
        default: break
        }
    }

    func currentAppKey() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        let bundle = app.bundleIdentifier ?? "no.bundle"
        let name = app.localizedName ?? "Unknown"
        return "\(bundle)|\(name)"
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
        generationSerial += 1
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
    func showCompletionRemainder(reanchor: Bool = true) {
        guard let comp = completion, !comp.done else { overlay.orderOut(nil); return }
        let point = reanchor ? currentCaretPoint() : (lastCaretPoint ?? currentCaretPoint())
        overlay.showCompletion(comp.remainder, at: point, lineHeight: lastCaretHeight)
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
        stats.accepted += 1; statsTouched()
        if comp.done {
            completion = nil
            if !promotePrefetch() { overlay.orderOut(nil); scheduleGenerate() }
        } else {
            completion = comp
            showCompletionRemainder()
            maybePrefetch()
        }
        rebuildMenu()
        return true
    }

    // Backtick: accept the whole remaining prediction at once.
    func acceptCompletionAll() -> Bool {
        guard let comp = completion, !comp.done else { return false }
        let piece = comp.remainder
        insert(piece)
        appendToBuffer(piece)
        stats.accepted += 1; statsTouched()
        completion = nil
        overlay.orderOut(nil)
        rebuildMenu()
        scheduleGenerate()
        return true
    }

    // As the user nears the end of the current prediction, generate the NEXT chunk
    // in the background (as if they had typed through the rest) so it can appear
    // with zero perceived latency on exhaustion.
    func maybePrefetch() {
        guard let comp = completion, !comp.done else { return }
        guard comp.chars.count - comp.consumed <= 12, !prefetchInFlight, !requestInFlight else { return }
        let predicted = String((buffer + comp.remainder).suffix(500))
        if predicted == prefetchKey, prefetched != nil { return }
        prefetchInFlight = true
        let promptContext = assembledContext(immediate: predicted)
        let appKey = activeAppKey
        backgroundQueue.async {
            let sug = (try? self.client.request(task: "complete", context: promptContext, maxWords: self.cfg.maxCompletionWords)) ?? nil
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
        showCompletionRemainder()
        log("promoted prefetch")
        return true
    }

    func scheduleGenerate() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: Double(cfg.debounceMs) / 1000.0, repeats: false) { [weak self] _ in
            self?.generate()
        }
    }

    func generate() {
        syncActiveApp()
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
        guard cfg.enabled, context.count >= cfg.minContextChars else { log("[\(activeAppKey)] generate skipped context=\(context.count) source=\(contextSource)"); return }
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { log("[\(activeAppKey)] generate skipped question"); clearSuggestion(); return }
        refreshBackgroundIfNeeded()

        requestInFlight = true
        let appKey = activeAppKey
        let reqBuffer = buffer            // buffer snapshot for the staleness check
        let task = chooseTask(context: context)
        let promptContext = assembledContext(immediate: context)
        log("[\(activeAppKey)] generate source=\(contextSource) chars=\(context.count) promptChars=\(promptContext.count) bg=\(cachedBackground.count) suffix=\(String(context.suffix(50)).replacingOccurrences(of: "\n", with: "\\n"))")
        DispatchQueue.global(qos: .userInitiated).async {
            // Live preview: paint partial completions as they stream in, but only
            // while the user hasn't typed since the request (else it's the final
            // line's job to reconcile via presentCompletion).
            let onPartial: (String) -> Void = task == "complete" ? { partial in
                DispatchQueue.main.async {
                    guard appKey == self.activeAppKey, self.buffer == reqBuffer, !partial.isEmpty else { return }
                    self.completion = ActiveCompletion(chars: Array(partial))
                    self.showCompletionRemainder()
                }
            } : { _ in }
            let sug = try? self.client.request(task: task, context: promptContext, maxWords: self.cfg.maxCompletionWords, onPartial: onPartial)
            DispatchQueue.main.async {
                self.requestInFlight = false
                let again = self.rerequestNeeded
                self.rerequestNeeded = false
                if appKey == self.activeAppKey {
                    if task == "complete" {
                        self.presentCompletion((sug ?? nil)?.text, requestedBuffer: reqBuffer)
                    } else {
                        self.show(sug ?? nil)
                    }
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
        if buffer == requestedBuffer {
            completion = ActiveCompletion(chars: chars)
        } else if buffer.hasPrefix(requestedBuffer) {
            let typedSince = Array(buffer.dropFirst(requestedBuffer.count))
            guard typedSince.count < chars.count, Array(chars[0..<typedSince.count]) == typedSince else {
                scheduleGenerate(); return     // diverged from the prediction
            }
            var comp = ActiveCompletion(chars: chars); comp.consumed = typedSince.count
            completion = comp
        } else {
            scheduleGenerate(); return         // buffer reset / deleted — start over
        }
        stats.shown += 1; statsTouched()
        rebuildMenu()
        showCompletionRemainder()
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
        active = MLXSuggestion(kind: "typo", text: nil, original: word, replacement: fix)
        acceptedWords = 0
        stats.shown += 1; statsTouched()
        rebuildMenu()
        // Inline at the caret line, same as completions.
        let point = currentCaretPoint()
        overlay.showTypo(original: word, replacement: fix, at: point, lineHeight: lastCaretHeight)
        log("[\(activeAppKey)] typo '\(word)' -> '\(fix)' at=\(point)")
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
        pendingTypoElement = nil
        pendingTypoRange = nil
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

    func clipboardText(limit: Int) -> String {
        guard let s = NSPasteboard.general.string(forType: .string) else { return "" }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 8 else { return "" }
        return String(t.prefix(limit))
    }

    // Quartz (top-left, global) bounds of the focused window — the coordinate space
    // CGWindowListCreateImage expects, so no flipping is needed for capture.
    func focusedWindowBounds() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
              let win = winRef else { return nil }
        let w = win as! AXUIElement
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success else { return nil }
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    // Capture the frontmost app's largest on-screen window via ScreenCaptureKit
    // (the modern replacement for the now-unavailable CGWindowListCreateImage).
    // Returns the image plus the window's screen frame (Quartz, top-left global),
    // which is needed to map OCR coordinates back to the screen.
    func captureFocusedWindow() -> (image: CGImage, frame: CGRect)? {
        guard #available(macOS 14.0, *) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var result: (CGImage, CGRect)?
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
                result = (img, win.frame)
            }
        }
        _ = sem.wait(timeout: .now() + 1.5)
        return result
    }

    func screenOCR(limit: Int) -> String {
        guard CGPreflightScreenCaptureAccess() else { return "" }
        guard let cap = captureFocusedWindow(), cap.image.width > 8, cap.image.height > 8 else { return "" }
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
    func screenshotCaretRect() -> (rect: CGRect, charWidth: CGFloat)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        // The phrase we look for on screen: the tail of what was just typed.
        let typed = String(buffer.suffix(40)).trimmingCharacters(in: .whitespacesAndNewlines)
        let needle = String(typed.suffix(18)).lowercased()
        guard needle.count >= 3 else { return nil }
        guard let cap = captureFocusedWindow(), cap.image.width > 8 else { return nil }
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
        refreshShotCaretIfNeeded()
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
        // Recompute when stale or after meaningful typing since the last fix.
        let stale = Date().timeIntervalSince(shotCaretAt) > 1.2 || shotCaretApp != activeAppKey
        let drift = abs(buffer.count - shotCaretBufferLen) > 6
        guard stale || drift else { return }
        shotCaretComputing = true
        let appKey = activeAppKey
        let bufLen = buffer.count
        backgroundQueue.async {
            let res = self.screenshotCaretRect()
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
        let fresh = Date().timeIntervalSince(backgroundRefreshedAt) < cfg.backgroundRefreshSeconds && key == backgroundKey
        if fresh || backgroundRefreshing { return }
        backgroundRefreshing = true
        backgroundQueue.async {
            var parts: [String] = []
            // Prefer clean AX text. Only fall back to (noisier) OCR when AX gives us
            // little — typically Electron apps. This keeps OCR misreads out of the
            // prompt whenever a reliable source exists.
            var windowChars = 0
            if self.cfg.windowContextEnabled {
                let w = self.windowText(limit: 1000)
                if w.count > 40 { parts.append(w); windowChars = w.count }
            }
            if self.cfg.screenContextEnabled, windowChars < 120 {
                let o = self.screenOCR(limit: 600)
                if o.count > 40 { parts.append(o) }
            }
            if self.cfg.clipboardContextEnabled {
                let c = self.clipboardText(limit: 200)
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
    func assembledContext(immediate: String) -> String {
        var blocks: [String] = []
        if cfg.styleMemoryEnabled {
            let s = styleMemory.sample(maxChars: immediate.count < cfg.maxImmediateForBackground ? 300 : 140)
            if s.split(separator: " ").count >= 4 { blocks.append(s) }
        }
        if immediate.count < cfg.maxImmediateForBackground, !cachedBackground.isEmpty {
            blocks.append(String(cachedBackground.suffix(700)))
        }
        blocks.append(immediate)
        return blocks.count == 1 ? immediate : blocks.joined(separator: "\n\n")
    }

    func chooseTask(context: String) -> String {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if cfg.grammarEnabled, [".", "!", "?"].contains(trimmed.last.map(String.init) ?? "") { return "grammar" }
        return cfg.completionEnabled ? "complete" : "typo"
    }

    func show(_ sug: MLXSuggestion?) {
        guard let sug else { log("show nil suggestion"); clearSuggestion(); return }
        log("show kind=\(sug.kind)")
        stats.shown += 1; statsTouched()
        rebuildMenu()
        switch sug.kind {
        case "completion":
            guard let text = sug.text, !text.isEmpty else { completion = nil; overlay.orderOut(nil); return }
            active = nil
            completion = ActiveCompletion(chars: Array(text))
            showCompletionRemainder()
            maybePrefetch()
        case "typo":
            active = sug
            guard let original = sug.original, let replacement = sug.replacement else { overlay.orderOut(nil); return }
            overlay.showTypo(original: original, replacement: replacement, at: currentCaretPoint(), lineHeight: lastCaretHeight)
        case "grammar":
            active = sug
            guard let original = sug.original, let replacement = sug.replacement else { overlay.orderOut(nil); return }
            overlay.showGrammar(original: original, replacement: replacement, at: currentCaretPoint(), lineHeight: lastCaretHeight)
        default:
            overlay.orderOut(nil)
        }
    }

    func clearSuggestion() {
        active = nil
        completion = nil
        prefetched = nil
        prefetchKey = ""
        acceptedWords = 0
        pendingTypoElement = nil
        pendingTypoRange = nil
        overlay.orderOut(nil)
    }

    // Tab/backtick for typo & grammar diffs (completions are handled separately by
    // acceptCompletionWord / acceptCompletionAll).
    func acceptOneWord() -> Bool {
        guard let active else { return false }
        switch active.kind {
        case "typo":
            if let replacement = active.replacement, let original = active.original {
                replaceTypo(original: original, with: replacement)
                stats.accepted += 1; statsTouched()
                clearSuggestion()
                rebuildMenu()
                return true
            }
            return false
        case "grammar":
            if let replacement = active.replacement {
                insert(replacement)
                buffer += replacement
                saveActiveAppState()
                stats.accepted += 1; statsTouched()
                clearSuggestion()
                rebuildMenu()
                return true
            }
            return false
        default:
            return false
        }
    }

    func acceptAll() -> Bool {
        guard let active else { return false }
        if active.kind == "typo" {
            guard let text = active.replacement, let original = active.original, !text.isEmpty else { return false }
            replaceTypo(original: original, with: text)
            stats.accepted += 1; statsTouched()
            clearSuggestion()
            rebuildMenu()
            return true
        }
        // grammar
        let text = active.replacement ?? ""
        guard !text.isEmpty else { return false }
        insert(text)
        appendToBuffer(text)
        stats.accepted += 1; statsTouched()
        clearSuggestion()
        rebuildMenu()
        return true
    }

    func insert(_ text: String) {
        withPasteboard(text) { self.postPaste() }
    }

    func replacePreviousWord(with text: String) {
        withPasteboard(text) {
            // App-wide, AX-free replacement for the just-typed word.
            // Shift-Option-Left selects the previous word in native text fields,
            // then Cmd-V replaces that selected range.
            self.postKey(CGKeyCode(kVK_LeftArrow), flags: [.maskShift, .maskAlternate])
            usleep(25_000)
            self.postPaste()
        }
    }

    func withPasteboard(_ text: String, action: () -> Void) {
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let old { pb.clearContents(); pb.setString(old, forType: .string) }
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
        log("[\(activeAppKey)] AX text context valueChars=\(value.count) cursorUtf16=\(range.location) before=\(before.count) after=\(after.count)")
        return AXContext(before: before, after: after)
    }

    func textBeforeCursor(limit: Int) -> String? {
        textAroundCursor(limit: limit)?.before
    }

    // True when the caret sits in the middle of a word/line of existing text, e.g.
    // editing "the qu|ick fox". Inline continuation there would be wrong, so we
    // suppress it — matching Cotypist's mid-line completion behavior.
    func isMidLine(after: String) -> Bool {
        guard let first = after.first else { return false }
        if first == "\n" || first == "\r" { return false }
        // A space then end-of-text is effectively line end; a word character
        // immediately after the caret means we're inside existing text.
        return !first.isWhitespace
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
        log("caret point=\(point) h=\(rect.height) from rect=\(rect)")
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
        log("[\(activeAppKey)] caret via text marker rect=\(r)")
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
        log("fallback focused element point=\(fallback) ax=\(point) size=\(size) converted=\(rect)")
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

    func selectedOrWordRect() -> CGRect? {
        guard let element = focusedElement() else { return nil }
        return boundsForSelectedRange(element: element) ?? caretPoint().map { CGRect(x: $0.x, y: $0.y, width: 24, height: 18) }
    }

    func boundsForSelectedRange(element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef else { log("AX selected range unavailable"); return nil }
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
            log("AX selected rect loc=\(range.location) len=\(range.length) rect=\(r)")
            return r
        }
        // 2. Zero-length caret: some apps return a valid thin caret rect here.
        if let r = caret(from: range, anchor: { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }) {
            log("AX caret direct loc=\(range.location) rect=\(r)")
            return r
        }
        // 3. cursorRectIsFromPreviousCharacter: anchor to the end of the prior glyph.
        if range.location > 0,
           let r = caret(from: CFRange(location: range.location - 1, length: 1),
                         anchor: { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }) {
            log("AX caret inferred from prev loc=\(range.location) rect=\(r)")
            return r
        }
        // 4. Anchor to the start of the next glyph.
        if let r = caret(from: CFRange(location: range.location, length: 1),
                         anchor: { CGRect(x: $0.minX, y: $0.minY, width: 1, height: $0.height) }) {
            log("AX caret inferred from next loc=\(range.location) rect=\(r)")
            return r
        }
        // 5. beginningOfParagraphRect: walk back to the line/paragraph start so we
        //    at least land on the correct text line when the exact glyph fails.
        var lineStart = range.location
        while lineStart > 0 && lineStart > range.location - 400 {
            if let r = caret(from: CFRange(location: lineStart - 1, length: 1),
                             anchor: { CGRect(x: $0.maxX, y: $0.minY, width: 1, height: $0.height) }) {
                log("AX caret from paragraph scan loc=\(lineStart) rect=\(r)")
                return r
            }
            lineStart -= 1
        }
        log("AX bounds unavailable for range loc=\(range.location) len=\(range.length)")
        return nil
    }

    @objc func testCompletion() { let p = caretPoint() ?? NSPoint(x: 400, y: 400); overlay.showCompletion(" predicted words appear inline", at: p, lineHeight: lastCaretHeight) }
    @objc func testTypo() { let p = caretPoint() ?? NSPoint(x: 400, y: 400); overlay.showTypo(original: "peopel", replacement: "people", at: p, lineHeight: lastCaretHeight) }
    @objc func testGrammar() { let p = caretPoint() ?? NSPoint(x: 400, y: 400); overlay.showGrammar(original: "this are wrong", replacement: "this is wrong", at: p, lineHeight: lastCaretHeight) }
    // Persist stats at most ~once/sec (called from the hot path on accept/ignore).
    func statsTouched() {
        rebuildMenu()
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
