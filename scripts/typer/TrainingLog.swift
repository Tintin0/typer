import Foundation

// Opt-in, on-device corpus of (context → shown suggestion, accepted?) examples,
// captured straight from the live completion loop. This is the seed dataset for a
// future local autocomplete model AND its accept/reject reward signal.
//
// OFF by default. Stored at ~/Library/Application Support/typer/training.jsonl, 0600,
// and wiped by "Reset All Data". One self-contained JSON object per line (JSONL).
//
// PRIVACY. `context` is ONLY the immediate before-cursor text the user typed — never
// the folded-in window/clipboard/OCR background blocks. Even so, typed text can hold
// secrets (a password in a non-secure field, a 2FA code, an API key), so before a row
// is written the context and suggestion are screened by `looksSensitive` and the whole
// example is DROPPED if anything secret-shaped appears (emails, URLs, long digit runs,
// key-like tokens, file paths). Capture is also skipped during macOS secure input, in
// disabled apps, and in known credential apps (`sensitiveAppBundles`). Nothing here
// ever leaves the machine. This corrects the earlier "same sensitivity as style.txt"
// framing — the raw buffer is strictly more sensitive, so it is filtered, not trusted.
final class TrainingLog {
    struct Record: Codable {
        let schema_version: Int   // 2
        let ts: Double            // unix seconds when the suggestion resolved
        let context: String       // immediate before-cursor text (screened, no secrets)
        let suggestion: String     // the full suggestion that was shown
        let accepted: Bool         // at least one word taken
        let accept_kind: String    // "tab" | "backtick" | "typethrough" | "none"
        let words_accepted: Int    // words taken
        let words_shown: Int       // words in the full suggestion
        let confidence: Double     // mean token probability the model reported
        let shown: Bool            // false for exploration/suppressed (never displayed)
        let exploration: Bool      // logged below the confidence gate (suppressed region)
        let min_conf: Double       // effective confidence gate at the time
        let max_words: Int         // words requested for this generation
        let app_category: String   // chat / email / docs / code / browser / other
        let source: String         // "generate" | "prefetch"
        let model: String          // gguf filename — the policy/version this came from
        let reason: String         // "resolved" | "dismissed" | "suppressed"
    }

    // Credential / secret-manager apps where suggestions must never be captured at all,
    // independent of macOS secure-input (which only covers OS-designated fields).
    static let sensitiveAppBundles: Set<String> = [
        "com.1password.1password", "com.1password.1password-launcher", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.dashlane.dashlanephonefinal", "com.callpod.keepermac",
        "com.lastpass.lastpassmacdesktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]

    // True if `s` contains anything secret-shaped. Conservative on purpose: a few
    // false positives (dropping a sentence that mentions a year or a long word) is a
    // fine price for never persisting a credential. Mirrors PersonalLexicon's intent
    // of refusing digits/URLs/emails/paths.
    static func looksSensitive(_ s: String) -> Bool {
        if s.isEmpty { return false }
        let patterns = [
            "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}",  // email
            "https?://|www\\.",                                  // url
            "[0-9]{4,}",                                         // 4+ digit run (codes, cards, ids)
            "(?:[0-9][ -]){6,}[0-9]",                            // spaced/hyphenated number (phone/card)
            "[A-Za-z0-9+/=_-]{20,}",                             // long token (keys, hashes, jwts)
            "(?:/[A-Za-z0-9._~-]+){2,}",                         // filesystem path
        ]
        for p in patterns where s.range(of: p, options: .regularExpression) != nil {
            return true
        }
        return false
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
        // Roll the file when it grows past the cap: keep the most recent half.
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

    // Block until all queued appends have been written — called on app terminate so
    // the tail of capture isn't lost to a fire-and-forget queue on quit.
    func flush() { queue.sync {} }
}

// The context-side of a shown suggestion, held from the moment it is presented until
// it resolves (accepted or rejected), at which point a TrainingLog.Record is written.
struct PendingTrainingExample {
    let context: String
    let suggestion: String
    let conf: Double
    let minConf: Double
    let maxWords: Int
    let category: String
    let source: String
    let model: String
}
