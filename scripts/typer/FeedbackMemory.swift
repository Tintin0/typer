import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Persistent record of how the user actually responds to suggestions: each shown
// completion eventually resolves as used (some words taken, by Tab/backtick or by
// typing straight through) or rejected (typed over / escaped). Two adaptive signals
// come out of it:
//   - typical accepted length -> how many words to ask the model for
//   - acceptance rate         -> how strict the confidence gate should be
// Local only: ~/Library/Application Support/typer/feedback.json, 0600, clearable.
final class FeedbackMemory {
    private struct Snapshot: Codable {
        var outcomes: [Bool]      // newest last; true = at least one word used
        var acceptWords: [Int]    // words used per accepted suggestion, newest last
    }

    private let url: URL
    private let queue = DispatchQueue(label: "typer.feedback", qos: .utility)
    private var outcomes: [Bool] = []
    private var acceptWords: [Int] = []
    private var loaded = false
    private var saveScheduled = false

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("feedback.json")
    }

    // Main-thread only (like the rest of TyperApp state).
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let d = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(Snapshot.self, from: d) else { return }
        outcomes = s.outcomes
        acceptWords = s.acceptWords
    }

    // A suggestion left the screen: `usedWords` of it had been consumed (via Tab,
    // backtick, or the user typing exactly along it).
    func recordResolution(usedWords: Int) {
        loadIfNeeded()
        outcomes.append(usedWords > 0)
        if outcomes.count > 200 { outcomes.removeFirst(outcomes.count - 200) }
        if usedWords > 0 {
            acceptWords.append(usedWords)
            if acceptWords.count > 100 { acceptWords.removeFirst(acceptWords.count - 100) }
        }
        scheduleSave()
    }

    // Acceptance rate over the recent window; nil until there is enough signal.
    func acceptanceRate() -> Double? {
        loadIfNeeded()
        let recent = outcomes.suffix(100)
        guard recent.count >= 20 else { return nil }
        return Double(recent.filter { $0 }.count) / Double(recent.count)
    }

    // Ask the model for roughly as much as the user historically takes. Someone who
    // grabs one or two words at a time gets short, dense suggestions (less screen
    // noise, less overwrite); someone who swallows whole clauses keeps the base.
    func adjustedMaxWords(base: Int) -> Int {
        loadIfNeeded()
        let recent = acceptWords.suffix(50)
        guard recent.count >= 10 else { return base }
        let sorted = recent.sorted()
        let median = sorted[sorted.count / 2]
        return max(3, min(base, median + 2))
    }

    // Raise the confidence bar when most suggestions get rejected (show less, but
    // better); relax it slightly when nearly everything shown is being used.
    func confidenceAdjustment() -> Double {
        guard let r = acceptanceRate() else { return 0 }
        if r < 0.10 { return 0.12 }
        if r < 0.20 { return 0.06 }
        if r > 0.45 { return -0.05 }
        return 0
    }

    func summary() -> String? {
        guard let r = acceptanceRate() else { return nil }
        return String(format: "%.0f%% of recent suggestions used", r * 100)
    }

    func clear() {
        outcomes = []
        acceptWords = []
        loaded = true
        queue.async { try? FileManager.default.removeItem(at: self.url) }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            // Re-read the latest state at fire time (state is main-thread-confined),
            // so updates landing inside the debounce window aren't dropped. Encode +
            // write off-main to keep the main thread light.
            DispatchQueue.main.async {
                self.saveScheduled = false
                let snap = Snapshot(outcomes: self.outcomes, acceptWords: self.acceptWords)
                self.queue.async {
                    guard let d = try? JSONEncoder().encode(snap) else { return }
                    try? d.write(to: self.url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
                }
            }
        }
    }

    // Synchronously persist the current state — used on app terminate so the last
    // debounce window of feedback survives a quit.
    func flush() {
        guard loaded else { return }
        let snap = Snapshot(outcomes: outcomes, acceptWords: acceptWords)
        guard let d = try? JSONEncoder().encode(snap) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
