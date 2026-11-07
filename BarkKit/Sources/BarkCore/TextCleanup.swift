import Foundation
import os

/// Dictation text clean-up: the shipping TextPostProcessor plus segment joining, special-token
/// stripping and no capitalisation after abbreviations.
public enum TextCleanup {
    private static let fillerRegex = try! NSRegularExpression(
        pattern: #"\b(um|uh|uhh|uhm|erm|hmm|mhm)\b[,.]?"#, options: .caseInsensitive)
    private static let whitespaceRegex = try! NSRegularExpression(pattern: #"\s+"#)
    // \p{Ll}: any Unicode lowercase letter; [a-z] misses å/ä/ö.
    private static let sentenceStartRegex = try! NSRegularExpression(pattern: #"(^|[.!?]\s+)(\p{Ll})"#)
    private static let specialTokenRegex = try! NSRegularExpression(pattern: #"<\|[^<>|]*\|>|<\|"#)
    private static let vocabRegexCache = OSAllocatedUnfairLock(initialState: [String: NSRegularExpression]())

    /// Lower-cased, as written. A sentence that ends on one of these is not capitalised after it.
    public static let abbreviations: Set<String> = [
        "bl.a.", "t.ex.", "m.m.", "o.s.v.", "d.v.s.", "e.g.", "i.e.", "etc.", "vs.", "ca.",
    ]

    /// Joins segment texts with single spaces and cleans the result. Fillers are English only:
    /// "um" is a word in German and Portuguese.
    public static func process(_ segments: [String], cleanup: Bool = true, language: String? = nil,
                               vocabulary: [String: String] = [:]) -> String {
        var text = segments.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        text = replace(specialTokenRegex, in: text, with: "")
        if cleanup {
            if language == "en" { text = replace(fillerRegex, in: text, with: "") }
            // Trim before capitalising: a stripped sentence-initial filler ("Um, testing") leaves a
            // leading space that would keep the ^ anchor from seeing the new first word.
            text = collapseWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines)
            text = capitalizeSentences(text)
        }
        if !vocabulary.isEmpty {
            text = applyVocabulary(text, dict: vocabulary)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        replace(whitespaceRegex, in: text, with: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
    }

    private static func capitalizeSentences(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        var offset = 0
        sentenceStartRegex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let terminal = match.range(at: 1)
            if terminal.length > 0 {
                let before = ns.substring(to: terminal.location + 1)
                let word = before.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                if abbreviations.contains(word.trimmingCharacters(in: CharacterSet(charactersIn: "(\"'«“")).lowercased()) {
                    return
                }
            }
            let letterRange = match.range(at: 2)
            let adjusted = NSRange(location: letterRange.location + offset, length: letterRange.length)
            let lower = (result as NSString).substring(with: adjusted)
            let upper = lower.uppercased()
            result = (result as NSString).replacingCharacters(in: adjusted, with: upper)
            // NSRange offsets are UTF-16 units; Character counts diverge (ß becomes SS).
            offset += (upper as NSString).length - (lower as NSString).length
        }
        return result
    }

    private static func vocabRegex(for term: String) -> NSRegularExpression? {
        if let cached = vocabRegexCache.withLock({ $0[term] }) { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: term)
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + escaped + #"\b"#, options: .caseInsensitive) else {
            return nil
        }
        vocabRegexCache.withLock { cache in
            if cache.count > 256 { cache.removeAll(keepingCapacity: true) } // vocab edits are rare; cap defensively
            cache[term] = regex
        }
        return regex
    }

    private static func applyVocabulary(_ text: String, dict: [String: String]) -> String {
        var result = text
        // Longest first so overlapping rules resolve the same way every run (specific beats prefix).
        let ordered = dict.sorted {
            if $0.key.count != $1.key.count { return $0.key.count > $1.key.count }
            return $0.key < $1.key
        }
        for (from, to) in ordered {
            guard !from.isEmpty, let regex = vocabRegex(for: from) else { continue }
            // escapedTemplate: a replacement containing $ or \ must stay literal.
            result = replace(regex, in: result, with: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }
}
