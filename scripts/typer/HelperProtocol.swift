import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

struct HelperRequest: Codable {
    let task: String
    let context: String
    let max_words: Int
    // Space-separated sample of the user's distinctive vocabulary (most frequent
    // first); the helper applies a mild logit bias toward these words. Empty = none.
    let lexicon: String
}

struct HelperSuggestion: Codable {
    let kind: String
    let text: String?
    let original: String?
    let replacement: String?
    // Mean model probability of the generated tokens (0..1). Low values mean the
    // model was guessing — the UI suppresses those instead of showing noise.
    let conf: Double?
}

// One line of the helper's streaming response: either a partial ({"p":...}) or the
// final result ({"ok":..., "suggestion":...}).
struct StreamLine: Codable {
    let p: String?
    let conf: Double?
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
