// Unit tests for Typer's pure Swift logic. Compiled standalone with the extracted
// TextLogic.swift and HelperProtocol.swift (see scripts/run_tests.sh) — no TyperApp, no
// event taps, no model. Deterministic; the dictionary check pins the language to English.
// (SourceKit may flag the free functions as unresolved when it analyses this file alone;
// they resolve at the multi-file compile in run_tests.sh.)
import AppKit
import Foundation

@main
struct SwiftLogicTest {
    static var pass = 0, fail = 0
    static func check(_ cond: Bool, _ msg: String) {
        if cond { pass += 1 } else { fail += 1; print("  FAIL: \(msg)") }
    }
    static func eq(_ a: String, _ b: String, _ msg: String) {
        check(a == b, "\(msg): got \"\(a)\" want \"\(b)\"")
    }

    static func main() {
        NSSpellChecker.shared.setLanguage("en")   // deterministic dictionary on any machine

        print("== trailingWordFragment ==")
        eq(trailingWordFragment("I need the assis"), "assis", "mid-word tail")
        eq(trailingWordFragment("hello world "), "", "ends in space -> empty")
        eq(trailingWordFragment("word."), "", "ends in punctuation -> empty")
        eq(trailingWordFragment("don't"), "don't", "apostrophe kept")
        eq(trailingWordFragment(""), "", "empty input")

        print("== isKnownWord (gate for mid-word completion) ==")
        check(isKnownWord("assistance"), "real word -> true")
        check(isKnownWord("government"), "real word -> true")
        check(!isKnownWord("docuement"), "misspelling -> false")   // the model's wrong subword join
        check(!isKnownWord("xqzptvwlk"), "gibberish -> false")
        check(!isKnownWord("a"), "too short (<2) -> false")
        check(!isKnownWord("ab3cd"), "contains a digit -> false")
        check(!isKnownWord(""), "empty -> false")

        print("== looksLikeProse (screenshot-OCR chrome filter, #2) ==")
        check(looksLikeProse("Please find the attached contract"), "EN prose -> keep")
        check(looksLikeProse("Ich melde mich nächste Woche."), "DE prose (ends '.') -> keep")
        check(looksLikeProse("Vielen Dank für Ihre Nachricht"), "DE prose (function word 'für') -> keep")
        check(!looksLikeProse("Aptos"), "lone font name -> drop")
        check(!looksLikeProse("File Edit View Insert Format"), "menu bar -> drop")
        check(!looksLikeProse("Inbox Sent Drafts Junk Trash"), "sidebar labels -> drop")
        check(!looksLikeProse("Send Reply Forward"), "toolbar (short) -> drop")

        print("== ActiveCompletion (word-by-word accept, behind the ^ key) ==")
        let c = ActiveCompletion(chars: Array("tance"))
        check(c.nextWordEnd() == 5, "nextWordEnd finishes the whole word 'tance'")
        eq(c.remainder, "tance", "remainder at start")
        check(!c.done, "not done at start")

        var c2 = ActiveCompletion(chars: Array("tance")); c2.consumed = 2
        eq(c2.remainder, "nce", "remainder after consuming 2")

        let c3 = ActiveCompletion(chars: Array(" hello world"))
        check(c3.nextWordEnd() == 6, "nextWordEnd skips leading space then one word (' hello')")

        var c4 = ActiveCompletion(chars: Array("done")); c4.consumed = 4
        check(c4.done, "done when fully consumed")

        print("\n\(pass) passed, \(fail) failed")
        exit(fail == 0 ? 0 : 1)
    }
}
