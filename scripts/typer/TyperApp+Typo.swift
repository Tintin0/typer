import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
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
    // its exact UTF-16 range plus the count of separator units between the word and
    // the caret (the space/punctuation the user just typed) so the caret can be
    // restored after them. Called only on accept, so the one big AXValue read is
    // acceptable. Returns nil for apps without a usable AXValue (keystroke fallback).
    func typoRangeViaAX(word: String) -> (element: AXUIElement, range: CFRange, trailing: Int)? {
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
        return (element, CFRange(location: start, length: end - start), caret - end)
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
        presentTypo(word: word, fix: fix)
        return true
    }

    // Show the red-strikethrough/green-replacement diff for a known misspelling.
    func presentTypo(word: String, fix: String) {
        active = HelperSuggestion(kind: "typo", text: nil, original: word, replacement: fix)
        stats.shown += 1; statsTouched()
        // Inline at the caret line, same as completions.
        let point = currentCaretPoint()
        overlay.showTypo(original: word, replacement: fix, at: point, lineHeight: lastCaretHeight)
        dlog("[\(activeAppKey)] typo '\(word)' -> '\(fix)' at=\(point)")
    }

    // Replace `original` with `text`. Prefers AX (exact range, preserves the
    // trailing separator); falls back to keystroke selection for apps without AX
    // write support. The big AXValue read happens here, only on accept.
    func replaceTypo(original: String, with text: String) {
        if let r = typoRangeViaAX(word: original) {
            // Electron/WebKit contenteditables often claim AX selection writes worked
            // but then insert at the live caret instead of replacing the selected word
            // (e.g. "this" -> "ththeis"). If the element has TextMarker caret APIs,
            // use AX only to put the caret at the known end position, then do the
            // keystroke deletion/paste path that those editors actually honor.
            let webLike = textMarkerCaretRect(element: r.element) != nil
            if !webLike,
               setAXText(element: r.element, range: r.range, text: text, trailing: r.trailing, original: original) {
                replaceLastWordInBuffer(original: original, with: text)
                log("typo replaced via AX")
                return
            }
            _ = setAXCaret(element: r.element, location: r.range.location + r.range.length + r.trailing)
            replaceWordBeforeSeparatorViaKeys(original: original, with: text, trailing: r.trailing)
            replaceLastWordInBuffer(original: original, with: text)
            log("typo replaced via keystrokes")
        } else {
            replaceWordBeforeSeparatorViaKeys(original: original, with: text)
            replaceLastWordInBuffer(original: original, with: text)
            log("typo replaced via keystrokes")
        }
    }

    // Replace `range` with `text` and leave the caret after the trailing separator.
    // Returns false (→ keystroke fallback) if the selection write didn't take: many
    // Electron/Chromium apps (Discord, Slack, VS Code) return .success for setting
    // kAXSelectedTextRange but silently ignore it, which would otherwise insert the
    // correction at the live caret instead of over the misspelled word. We read the
    // range back and only trust the AX path when the selection actually moved.
    func setAXText(element: AXUIElement, range: CFRange, text: String, trailing: Int, original: String) -> Bool {
        var r = range
        guard let rangeAx = AXValueCreate(.cfRange, &r),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeAx) == .success
        else { return false }
        var checkRef: CFTypeRef?
        var got = CFRange(location: 0, length: 0)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &checkRef) == .success,
              let checkVal = checkRef,
              AXValueGetValue(checkVal as! AXValue, .cfRange, &got),
              got.location == range.location, got.length == range.length
        else { return false }   // selection didn't actually move — fall back to keystrokes
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }

        // If AXValue is readable, verify the replacement landed exactly where it was
        // supposed to. Some editors report success while inserting at a stale caret;
        // treating that as success is what produced strings like "ththeis".
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
           let value = valueRef as? String,
           range.location >= 0,
           range.location + (text as NSString).length <= value.utf16.count {
            let start = String.Index(utf16Offset: range.location, in: value)
            let end = String.Index(utf16Offset: range.location + (text as NSString).length, in: value)
            guard String(value[start..<end]) == text else { return false }
        }

        // Caret after the replacement and the separator(s) the user typed.
        _ = setAXCaret(element: element, location: range.location + (text as NSString).length + trailing)
        return true
    }

    func setAXCaret(element: AXUIElement, location: Int) -> Bool {
        var caret = CFRange(location: max(0, location), length: 0)
        guard let caretAx = AXValueCreate(.cfRange, &caret),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caretAx) == .success
        else { return false }
        var checkRef: CFTypeRef?
        var got = CFRange(location: 0, length: 0)
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &checkRef) == .success,
              let checkVal = checkRef,
              AXValueGetValue(checkVal as! AXValue, .cfRange, &got)
        else { return false }
        return got.location == caret.location && got.length == 0
    }

    // Keystroke fallback for apps without usable AX text writes (Electron/Chromium:
    // Discord, Slack, VS Code). Deletes the misspelled word with Backspace rather
    // than selecting it — synthetic shift+arrow selection is silently dropped by
    // editors like Discord's ProseMirror, which would paste the fix at the word's
    // start instead of replacing it. Deletion and paste are both honored. `trailing`
    // defaults to 1: a single separator keystroke is what triggered the suggestion.
    func replaceWordBeforeSeparatorViaKeys(original: String, with text: String, trailing: Int = 1) {
        let sep = max(trailing, 1)
        let wordLen = max(original.count, 1)
        withPasteboard(text) {
            for _ in 0..<sep {                                           // move left of the separator(s)
                self.postKey(CGKeyCode(kVK_LeftArrow)); usleep(8_000)
            }
            usleep(18_000)
            for _ in 0..<wordLen {                                       // backspace away the misspelled word
                self.postKey(CGKeyCode(kVK_Delete)); usleep(9_000)
            }
            usleep(18_000)
            self.postPaste()                                             // insert the correction
            usleep(28_000)
            for _ in 0..<sep {                                           // caret back after the separator(s)
                self.postKey(CGKeyCode(kVK_RightArrow)); usleep(8_000)
            }
        }
    }

    func replaceLastWordInBuffer(original: String, with text: String) {
        if let r = buffer.range(of: original, options: .backwards) {
            buffer.replaceSubrange(r, with: text)
            saveActiveAppState()
        }
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
}
