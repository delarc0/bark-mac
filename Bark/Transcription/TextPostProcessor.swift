import Foundation

enum TextPostProcessor {
    private static let fillers: Set<String> = ["um", "uh", "uhh", "uhm", "erm", "hmm", "mhm"]

    static func process(_ raw: String, cleanup: Bool, vocabulary: [String: String]) -> String {
        var text = raw
        if cleanup {
            text = stripFillers(text)
            text = collapseWhitespace(text)
            text = capitalizeSentences(text)
        }
        if !vocabulary.isEmpty {
            text = applyVocabulary(text, dict: vocabulary)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripFillers(_ text: String) -> String {
        let pattern = #"\b(um|uh|uhh|uhm|erm|hmm|mhm)\b[,.]?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    private static func collapseWhitespace(_ text: String) -> String {
        let pattern = #"\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let singleSpaced = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        return singleSpaced.replacingOccurrences(of: " ,", with: ",")
                           .replacingOccurrences(of: " .", with: ".")
                           .replacingOccurrences(of: " ?", with: "?")
                           .replacingOccurrences(of: " !", with: "!")
    }

    private static func capitalizeSentences(_ text: String) -> String {
        let pattern = #"(^|[.!?]\s+)([a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
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

    private static func applyVocabulary(_ text: String, dict: [String: String]) -> String {
        var result = text
        for (from, to) in dict {
            guard !from.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: from)
            let pattern = #"\b"# + escaped + #"\b"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: to)
        }
        return result
    }
}
