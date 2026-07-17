import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Token-space budgeting cache (spec C.4). Tokenizing each context block via the helper
// has a real round-trip cost, but the heavy blocks (style sample, OCR/background,
// field-meta) are largely unchanged request-to-request. An LRU keyed exactly like
// Cotypist's `TokenizationCache` (string + addBOS + allowSpecial) lets the budgeter
// reuse a count instead of re-asking the helper every keystroke.
struct TokCacheKey: Hashable {
    let string: String
    let addBOS: Bool
    let allowSpecial: Bool
}

final class TokenizationCache {
    private struct Entry { let tokens: Int; var lastUsed: Date }
    private var cache: [TokCacheKey: Entry] = [:]
    private let lock = NSLock()
    private let capacity: Int

    init(capacity: Int = 256) { self.capacity = capacity }

    func count(for key: TokCacheKey) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard var e = cache[key] else { return nil }
        e.lastUsed = Date(); cache[key] = e
        return e.tokens
    }

    func store(_ tokens: Int, for key: TokCacheKey) {
        lock.lock(); defer { lock.unlock() }
        cache[key] = Entry(tokens: tokens, lastUsed: Date())
        if cache.count > capacity {
            // Evict the least-recently-used quarter in one pass (amortized O(1) per insert).
            let drop = cache.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(cache.count - capacity * 3 / 4)
            for (k, _) in drop { cache[k] = nil }
        }
    }

    func clear() { lock.lock(); cache.removeAll(); lock.unlock() }
}

final class LlamaClient {
    private let cfg: TyperConfig
    // Per-client LRU of (block → token count). Shared by the budgeter so a stable
    // style/background block is measured once, not per keystroke.
    let tokenizationCache = TokenizationCache()
    // Off-main queue that warms the tokenization cache. The budgeter (called on the MAIN
    // thread inside generate()) must never block on helper IPC (review H1), so it only ever
    // reads the cache or char-estimates synchronously, and schedules the real tokenize here.
    private let warmQueue = DispatchQueue(label: "typer.tokenwarm", qos: .utility)
    private var warmingKeys = Set<TokCacheKey>()
    private let warmLock = NSLock()
    // When set, this client always serves this exact .gguf (the ModelRouter spawns one
    // client per model). When nil, it falls back to findModel(cfg) — the original
    // single-model behaviour.
    private let explicitModelPath: String?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()   // leftover bytes past the last newline (chunked reads)
    private let lock = NSLock()
    // Requests are serialized by `lock`, so sharing one encoder/decoder is safe and
    // avoids re-allocating both on every request (and per streamed line's decode).
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(cfg: TyperConfig, modelPath: String? = nil) {
        self.cfg = cfg
        self.explicitModelPath = modelPath
    }

    // Locate the GGUF model: an explicit config path if set, otherwise the first
    // .gguf found in the Models directory (so the exact filename doesn't matter).
    static func findModel(_ cfg: TyperConfig) -> String? {
        let fm = FileManager.default
        if !cfg.modelPath.isEmpty, fm.fileExists(atPath: cfg.modelPath) { return cfg.modelPath }
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/typer/Models")
        let ggufs = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".gguf") }.sorted()
        return ggufs?.first.map { dir.appendingPathComponent($0).path }
    }

    func start() throws {
        if process?.isRunning == true { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let llamaHelper = home + "/.local/share/typer/typer-llama-server"
        guard FileManager.default.isExecutableFile(atPath: llamaHelper) else {
            throw NSError(domain: "Typer", code: 3, userInfo: [NSLocalizedDescriptionKey: "helper not found at \(llamaHelper); run install.sh"])
        }
        guard let model = explicitModelPath ?? LlamaClient.findModel(cfg) else {
            throw NSError(domain: "Typer", code: 4, userInfo: [NSLocalizedDescriptionKey: "no .gguf model found in Models directory; run install.sh"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: llamaHelper)
        p.arguments = ["--model-path", model]
        log("starting GGUF helper: \(llamaHelper) model=\((model as NSString).lastPathComponent)")
        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.standardError
        try p.run()
        log("helper pid=\(p.processIdentifier)")
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
    }

    // Reads one '\n'-terminated line from the helper, reading in CHUNKS (not a syscall
    // per byte) and buffering any bytes past the newline for the next call. macOS
    // energy impact is dominated by CPU wakeups, so the old byte-at-a-time poll/read
    // (≈2 syscalls per character of a streamed response) was a real, avoidable drain.
    private func readResponseLine(timeoutMs: Int32 = 8000) throws -> Data? {
        guard let fd = output?.fileDescriptor else { return nil }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while true {
            if let nl = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<nl)
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return line
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            let r = poll(&pfd, 1, remaining)
            if r == 0 { throw NSError(domain: "Typer", code: 5, userInfo: [NSLocalizedDescriptionKey: "helper read timeout"]) }
            if r < 0 { if errno == EINTR { continue }; throw NSError(domain: "Typer", code: 6, userInfo: [NSLocalizedDescriptionKey: "poll failed"]) }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR { continue }; throw NSError(domain: "Typer", code: 7, userInfo: [NSLocalizedDescriptionKey: "read failed"]) }
            if n == 0 { return readBuffer.isEmpty ? nil : { let d = readBuffer; readBuffer.removeAll(); return d }() }
            readBuffer.append(contentsOf: chunk[0..<n])
        }
    }

    // Sends one request and reads the streaming response. `onPartial` is invoked
    // (on this background thread) for each partial completion; the final suggestion
    // is returned.
    // `lowPriority` (speculative prefetch) yields the helper instead of waiting: if a
    // foreground request already holds the lock, the prefetch is skipped rather than
    // queued, so it can never delay real input.
    // `suffix` is the text AFTER the caret (spec §E#13). Non-empty only for mid-line
    // completions; the helper frames the request as FIM (<pre>context<suf>suffix<mid>)
    // when the loaded model exposes infill tokens, so the completion fits the gap instead
    // of duplicating/ignoring trailing text. Empty (the default) keeps the plain
    // continuation path byte-identical to before.
    func request(task: String, context: String, maxWords: Int, lexicon: String = "",
                 lexiconBias: Float? = nil,
                 suffix: String = "",
                 midword: Bool = false,
                 lowPriority: Bool = false,
                 onPartial: ((String, Double?) -> Void)? = nil) throws -> HelperSuggestion? {
        if lowPriority {
            guard lock.try() else { return nil }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        try start()
        // The wire request carries the FIM suffix only when present; an empty suffix
        // omits the field so non-mid-line requests encode exactly as before (the helper
        // treats a missing/empty "suffix" as plain continuation).
        let req = CompleteRequest(task: task, context: context, max_words: maxWords,
                                  lexicon: lexicon, lexicon_bias: lexiconBias,
                                  suffix: suffix.isEmpty ? nil : suffix,
                                  midword: midword ? 1 : nil)
        dlog("request task=\(task) chars=\(context.count) sfx=\(suffix.count) suffix=\(String(context.suffix(40)).replacingOccurrences(of: "\n", with: "\\n"))")
        let data = try encoder.encode(req) + Data([0x0A])
        do {
            try input?.write(contentsOf: data)
            while true {
                guard let line = try readResponseLine(), !line.isEmpty else {
                    throw NSError(domain: "Typer", code: 1, userInfo: [NSLocalizedDescriptionKey: "helper exited"])
                }
                let res = try decoder.decode(StreamLine.self, from: line)
                if let p = res.p { onPartial?(p, res.conf); continue }      // partial token update
                if res.ok == false {
                    throw NSError(domain: "Typer", code: 2, userInfo: [NSLocalizedDescriptionKey: res.error ?? "Unknown error"])
                }
                dlog("response kind=\(res.suggestion?.kind ?? "nil") text=\((res.suggestion?.text ?? res.suggestion?.replacement ?? "nil").prefix(80))")
                return res.suggestion                              // final line
            }
        } catch {
            // On exit/timeout/parse error, kill the (possibly hung) helper so the next
            // request spawns a fresh one instead of blocking on a dead pipe.
            process?.terminate()
            process = nil; input = nil; output = nil
            throw error
        }
    }

    // Wire type for a completion request. Mirrors HelperRequest but adds the optional
    // FIM `suffix` (spec §E#13); when nil the key is omitted entirely so the encoded
    // request is byte-identical to the old continuation-only request.
    private struct CompleteRequest: Codable {
        let task: String
        let context: String
        let max_words: Int
        let lexicon: String
        let lexicon_bias: Float?   // strength-scaled per-word logit bias; nil ⇒ helper default (0.5)
        let suffix: String?
        let midword: Int?          // 1 ⇒ finish the partial word at the caret; nil ⇒ omitted (unchanged wire)
    }

    // Wire type for the helper's tokenize endpoint (spec C.4).
    private struct TokenizeRequest: Codable {
        let mode: String
        let context: String
        let add_bos: Int
    }
    private struct TokenizeResponse: Codable {
        let ok: Bool?
        let n_tokens: Int?
    }

    // Count the tokens in `block` via the helper's tokenize endpoint, memoized in the
    // LRU. Used by the token-space budgeter so a long background block can't crowd out
    // the live line. Best-effort: on any failure it returns a char-based estimate
    // (~4 chars/token) so budgeting degrades gracefully instead of blocking input.
    // `lowPriority` skips (rather than queues) when a real request holds the lock, so
    // measurement never delays a completion.
    func tokenCount(_ block: String, addBOS: Bool = false, lowPriority: Bool = true) -> Int {
        if block.isEmpty { return 0 }
        let key = TokCacheKey(string: block, addBOS: addBOS, allowSpecial: true)
        if let cached = tokenizationCache.count(for: key) { return cached }
        let estimate = max(1, (block.count + 3) / 4)
        if lowPriority {
            guard lock.try() else { return estimate }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        do {
            try start()
            let req = TokenizeRequest(mode: "tokenize", context: block, add_bos: addBOS ? 1 : 0)
            let data = try encoder.encode(req) + Data([0x0A])
            try input?.write(contentsOf: data)
            guard let line = try readResponseLine(timeoutMs: 1500), !line.isEmpty else { return estimate }
            let res = try decoder.decode(TokenizeResponse.self, from: line)
            guard let n = res.n_tokens else { return estimate }
            tokenizationCache.store(n, for: key)
            return n
        } catch {
            // Best-effort measurement: a timeout here is often just a helper still loading the
            // model (review M3). Do NOT terminate it — that would kill a cold-starting helper
            // and force the next real request() to respawn+reload. Just use the estimate; a
            // genuinely dead pipe is detected and respawned by request().
            return estimate
        }
    }

    // Char-based token estimate (~4 chars/token). The non-blocking fallback used on the
    // main-thread budgeting path so it never waits on helper IPC.
    @inline(__always) private func estimateTokens(_ s: String) -> Int { max(1, (s.count + 3) / 4) }

    // NON-BLOCKING token count for the budgeter (review H1): returns the cached real count if
    // present, otherwise a char estimate IMMEDIATELY (no IPC), and warms the cache off-main so
    // a stable block (style/background/field-meta) converges to its real count within a couple
    // of generations. Never tokenizes synchronously on the caller's thread.
    private func tokenCountCachedOrWarm(_ block: String, addBOS: Bool = false) -> Int {
        if block.isEmpty { return 0 }
        let key = TokCacheKey(string: block, addBOS: addBOS, allowSpecial: true)
        if let cached = tokenizationCache.count(for: key) { return cached }
        // Not cached: warm it off-main (dedup so a block measured every generation only enqueues
        // one in-flight tokenize), and return the estimate now.
        warmLock.lock()
        let alreadyWarming = !warmingKeys.insert(key).inserted
        warmLock.unlock()
        if !alreadyWarming {
            warmQueue.async { [weak self] in
                guard let self else { return }
                _ = self.tokenCount(block, addBOS: addBOS, lowPriority: true)  // populates the cache
                self.warmLock.lock(); self.warmingKeys.remove(key); self.warmLock.unlock()
            }
        }
        return estimateTokens(block)
    }

    // Token-space prompt budgeting (spec C.4 / research R3). Each labeled block is
    // measured (cached) and admitted in PRIORITY order — immediate (the live line) first,
    // so it can never be starved — until the token budget is spent. The immediate block is
    // always kept whole even if it alone exceeds the budget (the model needs the line it is
    // completing); lower-priority blocks are dropped wholesale once the budget is gone,
    // keeping the surviving prefix byte-stable for llama.cpp KV reuse (a partially-trimmed
    // block would shift the prefix every keystroke and defeat the cache).
    // `blocks` is highest→lowest priority; `immediate` is the live before-cursor text and is
    // ALWAYS included as the final block. Returns the joined context the helper consumes.
    //
    // Runs on the MAIN thread (inside generate()), so it must NEVER block on helper IPC
    // (review H1): `immediate` changes every keystroke and would always miss the cache, so it
    // is always char-estimated; the stable priority blocks use the cached-or-warm count.
    func budgetedContext(blocks: [String], immediate: String, tokenBudget: Int) -> String {
        let parts = blocks.filter { !$0.isEmpty }
        var spent = estimateTokens(immediate)        // never IPC on the live line
        var kept: [String] = []
        for block in parts {
            let n = tokenCountCachedOrWarm(block)
            if spent + n > tokenBudget { continue }   // drop wholesale; keep the prefix stable
            kept.append(block)
            spent += n
        }
        kept.append(immediate)
        return kept.count == 1 ? immediate : kept.joined(separator: "\n\n")
    }

    // Lock-safe warm-up so the launch-time start() can't double-spawn against the
    // first real request().
    func warmUp() { lock.lock(); defer { lock.unlock() }; try? start() }

    // Kill the helper process (used when switching models — the next client spawns fresh).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        process?.terminate()
        process = nil; input = nil; output = nil
        // Token counts are per-model (vocab); a different model would mis-budget.
        tokenizationCache.clear()
    }
}
