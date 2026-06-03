import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

extension TyperApp {
    // Count text we inserted on the user's behalf (Tab/backtick) — the "saved typing".
    func recordCompleted(_ text: String) {
        stats.wordsCompleted += text.split(whereSeparator: { $0.isWhitespace }).count
        stats.charsCompleted += text.count
        markActiveToday()
    }

    func markActiveToday() {
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        let today = fmt.string(from: Date())
        if stats.lastActiveDay == today { return }
        let yesterday = fmt.string(from: cal.date(byAdding: .day, value: -1, to: Date()) ?? Date())
        stats.activeDays += 1
        stats.currentStreak = (stats.lastActiveDay == yesterday) ? stats.currentStreak + 1 : 1
        stats.longestStreak = max(stats.longestStreak, stats.currentStreak)
        stats.lastActiveDay = today
    }

    func numberFormatted(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // Playful menu lines about how much you've tab-completed.
    func funFacts() -> [String] {
        let w = stats.wordsCompleted
        var lines = ["⌨  \(numberFormatted(w)) words tab-completed"]

        // One scaling comparison — pick the biggest milestone reached.
        let bible = 783_137.0, lotr = 481_103.0, hobbit = 95_356.0
        let hp1 = 76_944.0, novel = 90_000.0
        if w >= Int(bible) {
            lines.append(String(format: "📖 ≈ %.1f Bibles", Double(w) / bible))
        } else if w >= Int(lotr) {
            lines.append(String(format: "🧙 ≈ %.1f Lord of the Rings trilogies", Double(w) / lotr))
        } else if w >= Int(hobbit) {
            lines.append(String(format: "🧙 ≈ %.1f Hobbits' worth of words", Double(w) / hobbit))
        } else if w >= Int(hp1) {
            lines.append(String(format: "⚡️ ≈ %.0f%% of a Harry Potter book", Double(w) / hp1 * 100))
        } else if w >= 2_000 {
            lines.append(String(format: "✍️ ≈ %.1f%% of a novel · %d pages", Double(w) / novel * 100, w / 250))
        } else if w >= 200 {
            lines.append("📝 ≈ \(w / 50) tweets' worth")
        } else if w > 0 {
            lines.append("More fun facts unlock as you complete more ✨")
        }

        // Time saved (~40 wpm of typing avoided) and streak.
        let minutes = w / 40
        if minutes >= 1 { lines.append("⏳ ≈ \(numberFormatted(minutes)) min of typing saved") }
        if stats.currentStreak > 0 {
            lines.append("🔥 \(stats.currentStreak)-day streak · \(stats.activeDays) active days · best \(stats.longestStreak)")
        }
        return lines
    }

    // Persist stats at most ~once/sec (called from the hot path on accept/ignore).
    func statsTouched() {
        updateStatusTitle()              // cheap live badge; full menu rebuilds on open
        if statsSaveScheduled { return }
        statsSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.statsSaveScheduled = false
            self.stats.save()
        }
    }
}
