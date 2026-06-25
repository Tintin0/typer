import Compression
import Foundation

// Emoji completion data + lookup (#7, spec E §7 / feature-mechanics §5).
//
// Three public data sets, derived from the public gemoji database
// (github.com/github/gemoji, MIT-licensed — itself built on the Unicode CLDR emoji
// data), the same family of data Cotypist ships:
//   • shortcode → emoji        (e.g. "smile" → "😄"; ~1.9k aliases)
//   • emoticon  → emoji        (e.g. ":)" → "🙂"; the well-known ASCII set)
//   • modifiable-base set      (emoji that accept a Fitzpatrick skin-tone modifier)
//   • neutral → gender forms   (e.g. "🧑‍⚕️" → male "👨‍⚕️", female "👩‍⚕️")
//
// The data is embedded directly in the binary as a raw-DEFLATE-compressed,
// base64-encoded JSON blob (so it rides in `scripts/typer/*.swift`, the single compile
// unit, with no Resources copy step or build.sh change). It is decoded ONCE, lazily, on
// first use and held in a singleton — never per keystroke.

// A neutral emoji's gendered variants. Either may be absent (some forms only have one).
struct EmojiGenderForms: Equatable {
    var male: String?
    var female: String?
}

final class EmojiData {
    static let shared = EmojiData()

    // shortcode (WITHOUT surrounding colons) → emoji.
    private(set) var shortcodes: [String: String] = [:]
    // literal ASCII emoticon token (e.g. ":)", "<3") → emoji.
    private(set) var emoticons: [String: String] = [:]
    // base emoji that accept a skin-tone modifier (U+1F3FB…U+1F3FF).
    private(set) var modifiableBase: Set<String> = []
    // neutral emoji → its male/female forms.
    private(set) var genders: [String: EmojiGenderForms] = [:]
    // The longest emoticon token, so the matcher knows how far back to look.
    private(set) var maxEmoticonLength = 0

    // The five Fitzpatrick skin-tone modifiers, indexed 1…5 (0 = none).
    static let skinToneModifiers: [Character] = ["\u{1F3FB}", "\u{1F3FC}", "\u{1F3FD}", "\u{1F3FE}", "\u{1F3FF}"]

    private var loaded = false

    private init() {}

    // Decode the embedded blob once. Idempotent and cheap after the first call.
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = EmojiData.decodeBlob() else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let sc = obj["shortcodes"] as? [String: String] { shortcodes = sc }
        if let em = obj["emoticons"] as? [String: String] {
            emoticons = em
            maxEmoticonLength = em.keys.map(\.count).max() ?? 0
        }
        if let mod = obj["modifiable"] as? [String] { modifiableBase = Set(mod) }
        if let g = obj["genders"] as? [String: [String]] {
            for (neutral, forms) in g {
                let male = forms.count > 0 && !forms[0].isEmpty ? forms[0] : nil
                let female = forms.count > 1 && !forms[1].isEmpty ? forms[1] : nil
                genders[neutral] = EmojiGenderForms(male: male, female: female)
            }
        }
    }

    // MARK: - Lookup

    // Resolve a bare shortcode (no colons) to a single emoji, applying the user's skin-tone
    // preference (1…5) when the base supports it. Returns nil when the shortcode is unknown.
    func emoji(forShortcode name: String, skinTone: Int = 0) -> String? {
        loadIfNeeded()
        guard let base = shortcodes[name.lowercased()] else { return nil }
        return applySkinTone(base, tone: skinTone)
    }

    // Resolve a literal emoticon token (e.g. ":)") to its emoji, or nil if unknown.
    func emoji(forEmoticon token: String) -> String? {
        loadIfNeeded()
        return emoticons[token]
    }

    // The shortcodes whose name begins with `prefix` (case-insensitive), capped at `limit`
    // and sorted shortest-name-first then alphabetically so the closest match leads. Each
    // result carries the (possibly skin-toned) emoji and the canonical shortcode name.
    func search(prefix: String, skinTone: Int = 0, limit: Int = 8) -> [(name: String, emoji: String)] {
        loadIfNeeded()
        let p = prefix.lowercased()
        guard !p.isEmpty else { return [] }
        let matches = shortcodes.keys.filter { $0.hasPrefix(p) }
            .sorted { a, b in a.count != b.count ? a.count < b.count : a < b }
            .prefix(limit)
        return matches.compactMap { name in
            guard let base = shortcodes[name] else { return nil }
            return (name, applySkinTone(base, tone: skinTone))
        }
    }

    // Append the Fitzpatrick modifier for `tone` (1…5) when the base accepts one. A base
    // is modifiable only if it is in the shipped modifiable-base set; everything else (and
    // tone 0) is returned unchanged. Inserts the modifier after the first scalar so ZWJ
    // sequences still render (the modifier must follow the human-figure scalar).
    func applySkinTone(_ emoji: String, tone: Int) -> String {
        guard tone >= 1, tone <= EmojiData.skinToneModifiers.count else { return emoji }
        guard modifiableBase.contains(emoji) else { return emoji }
        let modifier = EmojiData.skinToneModifiers[tone - 1]
        var scalars = Array(emoji.unicodeScalars)
        guard !scalars.isEmpty, let mod = modifier.unicodeScalars.first else { return emoji }
        // Drop any variation selector immediately after the base before inserting the
        // modifier (a base + VS16 + modifier is not a valid sequence).
        if scalars.count > 1, scalars[1] == "\u{FE0F}" { scalars.remove(at: 1) }
        scalars.insert(mod, at: 1)
        return String(String.UnicodeScalarView(scalars))
    }

    // Map a neutral emoji to its gendered form (1 = male, 2 = female; 0 = neutral).
    func applyGender(_ emoji: String, gender: Int) -> String {
        loadIfNeeded()
        guard gender != 0, let forms = genders[emoji] else { return emoji }
        if gender == 1, let m = forms.male { return m }
        if gender == 2, let f = forms.female { return f }
        return emoji
    }

    // MARK: - Embedded blob

    // The raw-DEFLATE-compressed, base64 JSON payload (gemoji-derived). Split across
    // string literals to stay well under any single-literal limits; joined at decode.
    private static let blob: String = [
        "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"
    ].joined()

    private static func decodeBlob() -> Data? {
        guard let compressed = Data(base64Encoded: blob) else { return nil }
        // The payload was produced with raw DEFLATE (Apple's COMPRESSION_ZLIB), so it
        // decodes directly through the Compression framework's zlib codec.
        return compressed.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // Generous output cap; the decoded JSON is ~47 KB. Grow once if needed.
            var capacity = max(compressed.count * 8, 131_072)
            while true {
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
                defer { dst.deallocate() }
                let n = compression_decode_buffer(dst, capacity, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
                if n == 0 { return nil }
                if n < capacity { return Data(bytes: dst, count: n) }
                capacity *= 2   // output filled the buffer exactly — retry larger to be safe
                if capacity > 4_000_000 { return nil }
            }
        }
    }
}
