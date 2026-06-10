import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

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
    // Personalization & quality gate.
    var lexiconEnabled = true         // learn the user's vocabulary; bias sampling toward it
    var adaptiveSuggestions = true    // adapt suggestion length + gate strictness to accept history
    // Suggestions whose mean token probability falls below this are not shown at
    // all — "show less, but right" is most of what makes inline completion feel
    // intentional rather than random. 0 disables the gate.
    var minConfidence = 0.34
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
            case "lexicon_enabled": cfg.lexiconEnabled = value == "true"
            case "adaptive_suggestions": cfg.adaptiveSuggestions = value == "true"
            case "min_confidence": cfg.minConfidence = Double(value) ?? cfg.minConfidence
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
