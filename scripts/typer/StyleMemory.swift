import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Persistent, on-device record of the user's own writing. A small rolling sample
// is fed into the prompt so completions adopt the user's tone and vocabulary.
// Entirely local: ~/Library/Application Support/typer/style.txt, capped in size.
//
// Each line is stored as "category\ttext" where category is the kind of app the
// writing came from (chat/email/docs/code/browser/other) — the same person writes
// very differently in Messages than in a design doc, and sampling should prefer
// the voice that matches where they're typing NOW. Legacy lines without a tab are
// treated as uncategorized and remain eligible everywhere.
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

    // Split a stored line into (category, text). Legacy lines have no tab → ("", line).
    private func parse(_ line: String) -> (category: String, text: String) {
        guard let tab = line.firstIndex(of: "\t") else { return ("", line) }
        return (String(line[..<tab]), String(line[line.index(after: tab)...]))
    }

    func record(_ text: String, category: String = "") {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\t", with: " ")   // tab is the format delimiter
        // Only keep substantive, sentence-like writing — not stray words.
        guard t.split(separator: " ").count >= 4 else { return }
        lock.lock()
        var existing = cached ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        // Dedupe: skip if this exact text is among the most recent entries (the
        // same buffer is flushed on both app-switch and Return).
        if existing.split(separator: "\n").suffix(8).map({ self.parse(String($0)).text }).contains(t) { lock.unlock(); return }
        existing += "\n" + category + "\t" + t
        if existing.utf8.count > maxBytes { existing = String(existing.suffix(maxBytes / 2)) }
        cached = existing
        lock.unlock()
        queue.async {
            try? existing.write(to: self.url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }

    func sample(maxChars: Int, relevantTo context: String = "", category: String = "") -> String {
        guard maxChars > 0 else { return "" }
        let ctxWords = Set(context.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 4 })
        let recent = contents().split(separator: "\n").map(String.init).reversed()
        var ranked: [(score: Int, recency: Int, line: String)] = []
        for (i, raw) in recent.enumerated() {
            let (cat, line) = parse(raw)
            let words = Set(line.lowercased().split { !$0.isLetter && !$0.isNumber }
                .map(String.init).filter { $0.count >= 4 })
            let overlap = ctxWords.isEmpty ? 0 : words.intersection(ctxWords).count
            // Topical overlap dominates; matching the current app's register (chat
            // voice in chat apps, doc voice in editors) outweighs pure recency but
            // never beats actual topic relevance. Uncategorized legacy lines stay
            // neutral, and recent lines remain eligible even with zero overlap.
            let voiceBonus = (!category.isEmpty && cat == category) ? 35 : 0
            ranked.append((overlap * 100 + voiceBonus - min(i, 60), i, line))
        }
        ranked.sort { $0.score == $1.score ? $0.recency < $1.recency : $0.score > $1.score }
        var chosen: [(Int, String)] = []
        var budget = maxChars
        for item in ranked {
            if budget <= 0 { break }
            chosen.append((item.recency, item.line))
            budget -= item.line.count + 1
        }
        // Restore chronological order inside the sample so it reads like natural writing.
        return chosen.sorted { $0.0 > $1.0 }.map { $0.1 }.joined(separator: "\n")
    }

    func sentenceCount() -> Int {
        contents().split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    func clear() {
        lock.lock(); cached = ""; lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }
}
