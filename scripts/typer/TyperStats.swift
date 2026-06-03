import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import IOKit.ps
import NaturalLanguage
import ScreenCaptureKit
import Vision

// Lightweight persisted acceptance stats — how often shown suggestions are taken
// vs. typed past. Surfaced in the menu; foundation for tuning behavior over time.
struct TyperStats: Codable {
    var shown = 0
    var accepted = 0
    var ignored = 0
    var wordsCompleted = 0          // words actually inserted via Tab/backtick (saved typing)
    var charsCompleted = 0
    var activeDays = 0
    var currentStreak = 0
    var longestStreak = 0
    var lastActiveDay = ""          // "yyyy-MM-dd" of the last day a completion was taken
    var acceptRate: Int { shown > 0 ? Int((Double(accepted) / Double(shown)) * 100) : 0 }

    // Tolerate older stats.json files that predate the new fields.
    enum CodingKeys: String, CodingKey {
        case shown, accepted, ignored, wordsCompleted, charsCompleted
        case activeDays, currentStreak, longestStreak, lastActiveDay
    }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        shown = try c.decodeIfPresent(Int.self, forKey: .shown) ?? 0
        accepted = try c.decodeIfPresent(Int.self, forKey: .accepted) ?? 0
        ignored = try c.decodeIfPresent(Int.self, forKey: .ignored) ?? 0
        wordsCompleted = try c.decodeIfPresent(Int.self, forKey: .wordsCompleted) ?? 0
        charsCompleted = try c.decodeIfPresent(Int.self, forKey: .charsCompleted) ?? 0
        activeDays = try c.decodeIfPresent(Int.self, forKey: .activeDays) ?? 0
        currentStreak = try c.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        longestStreak = try c.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0
        lastActiveDay = try c.decodeIfPresent(String.self, forKey: .lastActiveDay) ?? ""
    }

    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/typer/stats.json")
    }
    static func load() -> TyperStats {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(TyperStats.self, from: d) else { return TyperStats() }
        return s
    }
    func save() {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: TyperStats.url) }
    }
}
