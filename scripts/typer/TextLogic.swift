import AppKit
import Foundation

// Pure text helpers, kept as free functions (no TyperApp state) so they can be unit-tested
// standalone — see scripts/tests/swift_logic_test.swift. Behaviour is identical to when these
// lived as methods on TyperApp; callers invoke them unqualified and resolve here.

// The partial word the caret sits inside: the trailing run of letters/apostrophe in `s`
// (empty if it ends in whitespace or punctuation). Used to detect a mid-word position and to
// reconstruct the finished word for the dictionary check.
func trailingWordFragment(_ s: String) -> String {
    var out: [Character] = []
    for ch in s.reversed() {
        if ch.isLetter || ch == "'" { out.append(ch) } else { break }
    }
    return String(out.reversed())
}

// Is `word` a real word — either in the system dictionary or in the user's learned vocabulary
// (syncLexiconToSpellChecker teaches the shared checker their words)? Gates mid-word completion
// so a wrong subword guess is dropped, never shown. Letters/apostrophe/hyphen only; the check
// word is the letter core (leading/trailing punctuation trimmed).
func isKnownWord(_ word: String) -> Bool {
    let keep = CharacterSet.letters.union(CharacterSet(charactersIn: "'-"))
    let w = word.trimmingCharacters(in: keep.inverted)
    guard w.count >= 2, w.unicodeScalars.allSatisfy({ keep.contains($0) }) else { return false }
    return NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0).location == NSNotFound
}
