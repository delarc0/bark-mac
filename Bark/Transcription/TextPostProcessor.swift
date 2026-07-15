import Foundation
import os

enum TextPostProcessor {
    // Compiled once; recompiling on every paste (plus one per vocab entry) is
    // pure waste on the hot path between transcription and paste.
    private static let fillerRegex = try? NSRegularExpression(
        pattern: #"\b(um|uh|uhh|uhm|erm|hmm|mhm)\b[,.]?"#, options: .caseInsensitive)
    private static let whitespaceRegex = try? NSRegularExpression(pattern: #"\s+"#)
    private static let sentenceStartRegex = try? NSRegularExpression(pattern: #"(^|[.!?]\s+)([a-z])"#)
    private static let vocabRegexCache = OSAllocatedUnfairLock(initialState: [String: NSRegularExpression]())

    static func process(_ raw: String, cleanup: Bool, vocabulary: [String: String]) -> String {
        var text = raw
        if cleanup {
            text = stripFillers(text)
            // Trim before capitalizing: a stripped sentence-initial filler
            // ("Um, testing") leaves a leading space that would otherwise keep
            // the ^ anchor from seeing the new first word.
            text = collapseWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines)
            text = capitalizeSentences(text)
        }
        if !vocabulary.isEmpty {
            text = applyVocabulary(text, dict: vocabulary)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFillers(_ text: String) -> String {
        guard let regex = fillerRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func collapseWhitespace(_ text: String) -> String {
        guard let regex = whitespaceRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let singleSpaced = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        return singleSpaced.replacingOccurrences(of: " ,", with: ",")
                           .replacingOccurrences(of: " .", with: ".")
                           .replacingOccurrences(of: " ?", with: "?")
                           .replacingOccurrences(of: " !", with: "!")
    }

    private static func capitalizeSentences(_ text: String) -> String {
        guard let regex = sentenceStartRegex else { return text }
        let ns = text as NSString
        var result = text
        var offset = 0
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let letterRange = match.range(at: 2)
            let adjusted = NSRange(location: letterRange.location + offset, length: letterRange.length)
            let before = (result as NSString).substring(with: adjusted)
            let upper = before.uppercased()
            result = (result as NSString).replacingCharacters(in: adjusted, with: upper)
            offset += upper.count - before.count
        }
        return result
    }

    private static func vocabRegex(for term: String) -> NSRegularExpression? {
        let cached = vocabRegexCache.withLock { $0[term] }
        if let cached { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#,
                                                   options: .caseInsensitive) else { return nil }
        vocabRegexCache.withLock { cache in
            if cache.count > 256 { cache.removeAll(keepingCapacity: true) }  // vocab edits are rare; cap defensively
            cache[term] = regex
        }
        return regex
    }

    private static func applyVocabulary(_ text: String, dict: [String: String]) -> String {
        var result = text
        // Dictionary iteration order is nondeterministic; sort longest-first so
        // overlapping rules resolve the same way every run (specific beats prefix).
        let ordered = dict.sorted {
            if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
            return $0.key < $1.key
        }
        for (from, to) in ordered {
            guard !from.isEmpty, let regex = vocabRegex(for: from) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: to)
        }
        return result
    }
}
