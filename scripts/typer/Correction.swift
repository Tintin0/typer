import ApplicationServices
import Foundation

// A pending in-place text correction the user can accept with Tab/backtick. This is
// the UI/correction state (distinct from HelperSuggestion, the llama helper's Codable
// wire type): spelling adopts it first as a pure refactor, and grammar drops in later
// as new detection plus a couple of `kind == .grammar` branches — the AX/keystroke
// replacement machinery is reused unchanged because it is already span/length-based.
struct Correction {
    enum Kind { case spelling, grammar }
    var kind: Kind
    var displayOriginal: String     // text flagged, used for the strikethrough diff
    var replacement: String?        // nil ⇒ advisory only (grammar with no machine-applicable fix)
    var message: String?            // NSGrammarUserDescription; nil for spelling
    var axRange: CFRange?           // set when the exact span is already known (grammar)
    // True only when there is a fix to apply. Advisory-only grammar (replacement == nil)
    // shows its message but lets Tab pass through (no-op accept).
    var applicable: Bool { replacement != nil }
}
