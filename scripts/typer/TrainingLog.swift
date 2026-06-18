import Foundation

// Opt-in, on-device corpus of (context → shown suggestion, accepted?) examples,
// captured straight from the live completion loop. This is the seed dataset for a
// future local autocomplete model AND its accept/reject reward signal: every shown
// suggestion eventually resolves as accepted (≥1 word taken via Tab/backtick/typing
// through) or rejected (typed away / Esc), and we record that outcome alongside the
// context the model was continuing.
//
// OFF by default. Stored at ~/Library/Application Support/typer/training.jsonl, 0600,
// and wiped by "Reset All Data". One self-contained JSON object per line (JSONL), so
// the file is append-only and trivially streamable by the training pipeline.
//
// Privacy: `context` and `suggestion` are text the user actually typed/was shown —
// the same sensitivity as style.txt, which Typer already keeps locally. Nothing here
// ever leaves the machine; this only writes a local file the user can inspect, hand
// to the training pipeline, or clear. Capture is skipped during macOS secure input
// and in disabled apps (the caller never shows a suggestion there, so no example is
// produced), and the context is bounded to a short trailing window.
final class TrainingLog {
    struct Record: Codable {
        let schema_version: Int
        let ts: Double            // unix seconds when the suggestion resolved
        let context: String       // trailing text the model was asked to continue
        let suggestion: String    // the full suggestion that was shown
        let accepted: Bool        // at least one word taken
        let words_accepted: Int   // words taken (Tab / backtick / typed-through)
        let words_shown: Int      // words in the full suggestion
        let confidence: Double    // mean token probability the model reported
        let max_words: Int        // words requested for this generation
        let app_category: String  // chat / email / docs / code / browser / other
        let source: String        // "generate" | "prefetch"
        let reason: String        // how it ended: "resolved" | "dismissed"
    }

    private let url: URL
    private let queue = DispatchQueue(label: "typer.training", qos: .utility)
    private let encoder = JSONEncoder()
    private let maxBytes = 8_000_000      // ~8 MB rolling cap (keeps the recent half)
    private let lock = NSLock()
    private var countCache = -1           // lazily counted; -1 = unknown

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("training.jsonl")
    }

    func record(_ r: Record) {
        guard let line = try? encoder.encode(r) else { return }
        lock.lock(); if countCache >= 0 { countCache += 1 }; lock.unlock()
        queue.async { self.append(line) }
    }

    private func append(_ jsonLine: Data) {
        var data = jsonLine
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } else if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
        // Roll the file when it grows past the cap: keep the most recent half so the
        // log stays bounded without a per-write rewrite.
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxBytes,
           let whole = try? String(contentsOf: url, encoding: .utf8) {
            let lines = whole.split(separator: "\n", omittingEmptySubsequences: true)
            let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
            if let keptData = kept.data(using: .utf8) {
                try? keptData.write(to: url, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                lock.lock(); countCache = lines.count / 2; lock.unlock()
            }
        }
    }

    // Number of examples recorded (for the menu). Cached; recomputed by scanning the
    // file only the first time after launch or a roll.
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        if countCache >= 0 { return countCache }
        guard let data = try? Data(contentsOf: url) else { countCache = 0; return 0 }
        countCache = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        return countCache
    }

    func clear() {
        lock.lock(); countCache = 0; lock.unlock()
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }
}

// The context-side of a shown suggestion, held from the moment it is presented until
// it resolves (accepted or rejected), at which point a TrainingLog.Record is written.
struct PendingTrainingExample {
    let context: String
    let suggestion: String
    let conf: Double
    let maxWords: Int
    let category: String
    let source: String
}
