import Foundation

// Progressive A/B rollout of our own "typer-1" model against the default (Gemma).
//
// The router owns one LlamaClient per model and, on each generation, sends a fraction of
// requests — the *share* — to the candidate (typer-1) instead of the default. The share is
// not fixed: it ratchets UP while the candidate's real accept rate keeps pace with the
// default, and backs OFF (bringing the default back) when it regresses — the RLHF-style
// loop the user asked for, where accept/reject feedback drives the policy (the share).
//
// Bootstrap: with only the default model in Models/, `candidateAvailable` is false and the
// app behaves exactly as before (100% default). Drop a `typer-1*.gguf` in and the router
// starts routing at `typer1ShareStart`. The candidate helper process spawns lazily on its
// first pick, so it costs no RAM until it's actually used.
final class ModelRouter {
    enum Pick: String, Codable { case fallback, candidate }

    private let cfg: TyperConfig
    let fallbackClient: LlamaClient
    let candidateClient: LlamaClient?   // nil when no typer-1 model is present / disabled
    let fallbackName: String
    let candidateName: String?
    private let mem: RouterMemory

    init(cfg: TyperConfig) {
        self.cfg = cfg
        let (fb, cand) = ModelRouter.resolveModels(cfg)
        fallbackName = fb.map { ($0 as NSString).lastPathComponent } ?? "unknown"
        fallbackClient = LlamaClient(cfg: cfg, modelPath: fb)
        if cfg.typer1Enabled, let candPath = cand {
            candidateName = (candPath as NSString).lastPathComponent
            candidateClient = LlamaClient(cfg: cfg, modelPath: candPath)
        } else {
            candidateName = nil
            candidateClient = nil
        }
        mem = RouterMemory(cfg: cfg)
    }

    var candidateAvailable: Bool { candidateClient != nil }
    var currentShare: Double { candidateAvailable ? mem.share : 0 }

    // Warm only the default at launch; the candidate spawns on its first pick so a
    // low-share rollout doesn't pay its memory until it's actually serving.
    func warmUp() { fallbackClient.warmUp() }

    // Decide which model serves this generation. The chosen model serves the whole
    // generation (and its prefetch continuations) so a single suggestion is never a mix.
    func pick() -> (client: LlamaClient, pick: Pick, name: String) {
        if let c = candidateClient, Double.random(in: 0..<1) < mem.share {
            return (c, .candidate, candidateName ?? fallbackName)
        }
        return (fallbackClient, .fallback, fallbackName)
    }

    func client(for pick: Pick) -> LlamaClient {
        (pick == .candidate ? candidateClient : nil) ?? fallbackClient
    }

    func modelName(for pick: Pick) -> String {
        (pick == .candidate ? candidateName : nil) ?? fallbackName
    }

    // Feed one resolved suggestion back into the ratchet. "good" counts only REAL gain —
    // a Tab/backtick accept or a long (≥3-word) type-through — matching
    // build_dataset.classify(), so the live rollout and the offline trainer agree on what
    // a win is (a short type-through is a word the user would have typed anyway).
    func record(pick: Pick, accepted: Bool, kind: String, words: Int) {
        guard candidateAvailable else { return }
        let good = accepted && (kind == "tab" || kind == "backtick" || words >= 3)
        mem.record(candidate: pick == .candidate, good: good)
    }

    // One line for the status-bar menu, nil when there is no candidate to report on.
    func statusSummary() -> String? {
        guard candidateAvailable else { return nil }
        return mem.summary(candidateName: candidateName ?? "typer-1", fallbackName: fallbackName)
    }

    // Wipe the rollout state (share + windows) — also called by "Reset All Data".
    func reset() { mem.reset() }

    // fallback = the default (Gemma) model; candidate = the first Models/ file whose name
    // begins with typer1ModelGlob. candidate is nil unless it is distinct from the
    // fallback (so a lone typer-1 install just serves directly, with no routing).
    static func resolveModels(_ cfg: TyperConfig) -> (fallback: String?, candidate: String?) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/Models")
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".gguf") }.sorted()
        let glob = cfg.typer1ModelGlob.lowercased()
        let candidateName = glob.isEmpty ? nil : names.first { $0.lowercased().hasPrefix(glob) }
        let candidatePath = candidateName.map { dir.appendingPathComponent($0).path }

        var fallbackPath: String?
        if !cfg.modelPath.isEmpty, fm.fileExists(atPath: cfg.modelPath), cfg.modelPath != candidatePath {
            fallbackPath = cfg.modelPath
        } else {
            fallbackPath = names.first { $0 != candidateName }
                .map { dir.appendingPathComponent($0).path }
        }
        // No distinct default → the candidate is the only model; serve it, don't route.
        if fallbackPath == nil { return (candidatePath, nil) }
        return (fallbackPath, candidatePath)
    }
}

// Persistent rollout state: the live share plus rolling accept/reject windows per model,
// in ~/Library/Application Support/typer/router.json (0600, clearable). Same debounced,
// main-thread-read / background-write shape as FeedbackMemory.
final class RouterMemory {
    private struct Snapshot: Codable {
        var share: Double
        var candidate: [Bool]       // newest last; true = real accept
        var fallback: [Bool]
        var sinceLastAdjust: Int
    }

    private let url: URL
    private let queue = DispatchQueue(label: "typer.router", qos: .utility)

    // Policy parameters (from config).
    private let startShare, minShare, maxShare, step, regression: Double
    private let minSamples: Int

    // Tunables: the comparison window, the burst-of-rejects tripwire length, and the slack
    // by which the candidate may trail the default and still earn more share.
    private let window = 100
    private let tripwireRun = 5
    private let keepTolerance = 0.02

    private var shareValue: Double
    private var candidate: [Bool] = []
    private var fallback: [Bool] = []
    private var sinceLastAdjust = 0
    private var loaded = false
    private var saveScheduled = false

    init(cfg: TyperConfig) {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("router.json")
        startShare = cfg.typer1ShareStart
        minShare = cfg.typer1ShareMin
        maxShare = cfg.typer1ShareMax
        step = cfg.typer1RatchetStep
        regression = cfg.typer1RegressionMargin
        minSamples = cfg.typer1RatchetMinSamples
        shareValue = cfg.typer1ShareStart
    }

    var share: Double { loadIfNeeded(); return shareValue }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        shareValue = min(maxShare, max(minShare, s.share))
        candidate = s.candidate
        fallback = s.fallback
        sinceLastAdjust = s.sinceLastAdjust
    }

    func record(candidate isCandidate: Bool, good: Bool) {
        loadIfNeeded()
        if isCandidate {
            candidate.append(good)
            if candidate.count > window { candidate.removeFirst(candidate.count - window) }
            sinceLastAdjust += 1
            ratchet()
        } else {
            fallback.append(good)
            if fallback.count > window { fallback.removeFirst(fallback.count - window) }
        }
        scheduleSave()
    }

    // The decision rule. Runs after every candidate resolution.
    private func ratchet() {
        // Hard tripwire: a short run of pure rejects on the candidate means it went bad
        // fast — drop straight to the floor and make it re-qualify from an empty window.
        if candidate.count >= tripwireRun, candidate.suffix(tripwireRun).allSatisfy({ !$0 }) {
            shareValue = minShare
            candidate.removeAll(keepingCapacity: true)
            sinceLastAdjust = 0
            return
        }
        // Otherwise wait for enough signal on both arms, plus a cooldown since the last
        // move, so the share doesn't thrash.
        guard candidate.count >= minSamples, fallback.count >= minSamples,
              sinceLastAdjust >= minSamples else { return }
        let ac = rate(candidate)
        let af = rate(fallback)
        if ac >= af - keepTolerance {
            shareValue = min(maxShare, shareValue + step)          // keeping pace → more traffic
        } else if ac < af - regression {
            shareValue = max(minShare, shareValue * 0.5)           // regressing → bring default back
        } else {
            return                                                 // in-between → hold, keep cooldown
        }
        sinceLastAdjust = 0
    }

    private func rate(_ xs: [Bool]) -> Double {
        xs.isEmpty ? 0 : Double(xs.filter { $0 }.count) / Double(xs.count)
    }

    func summary(candidateName: String, fallbackName: String) -> String {
        loadIfNeeded()
        let pct = Int((shareValue * 100).rounded())
        let fbShort = (fallbackName as NSString).deletingPathExtension
        func used(_ xs: [Bool]) -> String { xs.isEmpty ? "—" : "\(Int((rate(xs) * 100).rounded()))%" }
        return "typer-1: \(pct)% share · used \(used(candidate)) vs \(fbShort) \(used(fallback))"
    }

    func reset() {
        shareValue = startShare
        candidate = []
        fallback = []
        sinceLastAdjust = 0
        loaded = true
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        let snap = Snapshot(share: shareValue, candidate: candidate,
                            fallback: fallback, sinceLastAdjust: sinceLastAdjust)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.saveScheduled = false }
            guard let d = try? JSONEncoder().encode(snap) else { return }
            try? d.write(to: self.url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
}
