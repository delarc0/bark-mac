import Foundation

public enum NoteMarkup {
    public enum Kind: Equatable, Sendable {
        case body
        case heading(level: Int)
        case bullet
        case checkbox(checked: Bool)
    }

    public struct Line: Equatable, Sendable {
        public let range: NSRange
        public let paragraphRange: NSRange
        public let kind: Kind
        public let indent: Int
        public let markerRange: NSRange?
        public let contentRange: NSRange
        public let checkboxRange: NSRange?
    }

    public struct Change: Equatable, Sendable {
        public let range: NSRange
        public let replacement: String

        public init(range: NSRange, replacement: String) {
            self.range = range
            self.replacement = replacement
        }
    }

    public struct Edit: Equatable, Sendable {
        public let changes: [Change]
        public let selection: NSRange

        public init(changes: [Change], selection: NSRange) {
            self.changes = changes
            self.selection = selection
        }

        public func apply(to text: String) -> String {
            let result = NSMutableString(string: text)
            for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
                result.replaceCharacters(in: change.range, with: change.replacement)
            }
            return result as String
        }
    }

    public static func lines(in text: String) -> [Line] {
        let source = text as NSString
        guard source.length > 0 else {
            return [line(in: source, range: NSRange(location: 0, length: 0), paragraphRange: NSRange(location: 0, length: 0))]
        }
        var result: [Line] = []
        var start = 0
        while start < source.length {
            var lineStart = 0, end = 0, contentsEnd = 0
            source.getLineStart(&lineStart, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let range = NSRange(location: lineStart, length: contentsEnd - lineStart)
            let paragraphRange = NSRange(location: lineStart, length: end - lineStart)
            result.append(line(in: source, range: range, paragraphRange: paragraphRange))
            guard end > start else { break }
            start = end
        }
        if let last = result.last, last.paragraphRange.upperBound == source.length,
           last.paragraphRange.length > last.range.length {
            let range = NSRange(location: source.length, length: 0)
            result.append(line(in: source, range: range, paragraphRange: range))
        }
        return result
    }

    public static func returnEdit(in text: String, selection: NSRange) -> Edit? {
        guard selection.length == 0, selection.location >= 0, selection.location <= (text as NSString).length,
              let line = line(in: text, at: selection.location), isList(line.kind) else { return nil }
        let source = text as NSString
        let content = source.substring(with: line.contentRange)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return Edit(changes: [Change(range: line.range, replacement: "")],
                        selection: NSRange(location: line.range.location, length: 0))
        }
        var marker = source.substring(with: NSRange(location: line.range.location,
                                                   length: line.contentRange.location - line.range.location))
        if case .checkbox = line.kind, let checkboxRange = line.checkboxRange {
            let relative = checkboxRange.location - line.range.location
            marker = (marker as NSString).replacingCharacters(in: NSRange(location: relative + 1, length: 1), with: " ")
        }
        let separatorLength = line.paragraphRange.upperBound - line.range.upperBound
        let separator = separatorLength > 0
            ? source.substring(with: NSRange(location: line.range.upperBound, length: separatorLength))
            : "\n"
        let insertion = separator + marker
        return Edit(changes: [Change(range: NSRange(location: selection.location, length: 0), replacement: insertion)],
                    selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    public static func indentEdit(in text: String, selection: NSRange, outdent: Bool) -> Edit? {
        let source = text as NSString
        guard selection.location >= 0, selection.upperBound <= source.length else { return nil }
        let selected = lines(in: text).filter { line in
            guard isList(line.kind) else { return false }
            if selection.length == 0 {
                return selection.location >= line.range.location && selection.location <= line.range.upperBound
            }
            return selection.upperBound > line.range.location && selection.location < line.paragraphRange.upperBound
        }
        let changes = selected.compactMap { line -> Change? in
            if !outdent {
                return Change(range: NSRange(location: line.range.location, length: 0), replacement: "  ")
            }
            let prefix = source.substring(with: NSRange(location: line.range.location, length: min(2, line.range.length)))
            let count = prefix.prefix(while: { $0 == " " }).count
            guard count > 0 else { return nil }
            return Change(range: NSRange(location: line.range.location, length: count), replacement: "")
        }
        guard !changes.isEmpty else { return nil }
        let start = adjusted(selection.location, changes: changes, includingAtLocation: selection.length == 0)
        let end = adjusted(selection.upperBound, changes: changes, includingAtLocation: true)
        return Edit(changes: changes, selection: NSRange(location: start, length: max(0, end - start)))
    }

    public static func toggleCheckbox(in text: String, at location: Int) -> Edit? {
        guard location >= 0, location < (text as NSString).length else { return nil }
        for line in lines(in: text) {
            guard case .checkbox(let checked) = line.kind, let range = line.checkboxRange,
                  location >= range.location, location < range.upperBound else { continue }
            let change = Change(range: NSRange(location: range.location + 1, length: 1), replacement: checked ? " " : "x")
            return Edit(changes: [change], selection: NSRange(location: location, length: 0))
        }
        return nil
    }

    public static func checkboxCompletion(in text: String, selection: NSRange) -> Edit? {
        let source = text as NSString
        guard selection.length == 0, selection.location >= 2, selection.location <= source.length,
              let line = line(in: text, at: selection.location) else { return nil }
        let prefix = source.substring(with: NSRange(location: line.range.location,
                                                   length: selection.location - line.range.location))
        guard prefix.hasSuffix("[]"), prefix.dropLast(2).allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
        let remaining = source.substring(with: NSRange(location: selection.location,
                                                      length: line.range.upperBound - selection.location))
        guard remaining.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let change = Change(range: NSRange(location: selection.location - 2, length: 2), replacement: "[ ] ")
        return Edit(changes: [change], selection: NSRange(location: selection.location + 2, length: 0))
    }

    private static func line(in text: String, at location: Int) -> Line? {
        lines(in: text).first { location >= $0.range.location && location <= $0.range.upperBound }
    }

    private static func isList(_ kind: Kind) -> Bool {
        switch kind {
        case .bullet, .checkbox: true
        case .body, .heading: false
        }
    }

    private static func line(in source: NSString, range: NSRange, paragraphRange: NSRange) -> Line {
        var indent = 0
        while indent < range.length {
            let character = source.character(at: range.location + indent)
            guard character == 32 || character == 9 else { break }
            indent += 1
        }
        let markerStart = range.location + indent
        let remaining = source.substring(with: NSRange(location: markerStart, length: range.upperBound - markerStart))
        var kind = Kind.body
        var markerLength = 0
        var checkboxRange: NSRange?
        if remaining.hasPrefix("## ") {
            kind = .heading(level: 2)
            markerLength = 3
        } else if remaining.hasPrefix("# ") {
            kind = .heading(level: 1)
            markerLength = 2
        } else if remaining.hasPrefix("[ ] ") || remaining.hasPrefix("[x] ") || remaining.hasPrefix("[X] ") {
            let checked = !remaining.hasPrefix("[ ] ")
            kind = .checkbox(checked: checked)
            markerLength = 4
            checkboxRange = NSRange(location: markerStart, length: 3)
        } else if remaining.hasPrefix("- ") || remaining.hasPrefix("* ") {
            let afterBullet = String(remaining.dropFirst(2))
            if afterBullet.hasPrefix("[ ] ") || afterBullet.hasPrefix("[x] ") || afterBullet.hasPrefix("[X] ") {
                let checked = !afterBullet.hasPrefix("[ ] ")
                kind = .checkbox(checked: checked)
                markerLength = 6
                checkboxRange = NSRange(location: markerStart + 2, length: 3)
            } else {
                kind = .bullet
                markerLength = 2
            }
        }
        let markerRange = markerLength > 0 ? NSRange(location: markerStart, length: markerLength) : nil
        let contentStart = markerStart + markerLength
        return Line(range: range, paragraphRange: paragraphRange, kind: kind, indent: indent,
                    markerRange: markerRange,
                    contentRange: NSRange(location: contentStart, length: range.upperBound - contentStart),
                    checkboxRange: checkboxRange)
    }

    private static func adjusted(_ location: Int, changes: [Change], includingAtLocation: Bool) -> Int {
        var result = location
        for change in changes.sorted(by: { $0.range.location < $1.range.location }) {
            let delta = (change.replacement as NSString).length - change.range.length
            if change.range.upperBound < location || (includingAtLocation && change.range.upperBound == location) {
                result += delta
            } else if change.range.location < location {
                result = change.range.location + (change.replacement as NSString).length
            }
        }
        return max(0, result)
    }
}
