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

    func sample(maxChars: Int, relevantTo context: String = "") -> String {
        guard maxChars > 0 else { return "" }
        let ctxWords = Set(context.lowercased().split { !$0.isLetter && !$0.isNumber }
            .map(String.init).filter { $0.count >= 4 })
        let recent = contents().split(separator: "\n").map(String.init).reversed()
        var ranked: [(score: Int, recency: Int, line: String)] = []
        for (i, line) in recent.enumerated() {
            let words = Set(line.lowercased().split { !$0.isLetter && !$0.isNumber }
                .map(String.init).filter { $0.count >= 4 })
            let overlap = ctxWords.isEmpty ? 0 : words.intersection(ctxWords).count
            // Relevance first, recency second. Keep recent lines eligible even with
            // zero overlap so the model still hears the user's current voice.
            ranked.append((overlap * 100 - min(i, 60), i, line))
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
