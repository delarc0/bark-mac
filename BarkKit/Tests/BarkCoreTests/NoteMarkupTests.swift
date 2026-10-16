import BarkCore
import Foundation
import Testing

private func length(_ text: String) -> Int { (text as NSString).length }

struct NoteMarkupLineTests {
    @Test func classifiesHeadingsBulletsAndCheckboxes() {
        let text = "  # Heading\r\n## Sub\n- item\n* other\n  - [x] done\n  [ ] open\nplain"
        let lines = NoteMarkup.lines(in: text)

        #expect(lines.count == 7)
        #expect(lines[0].kind == .heading(level: 1))
        #expect(lines[0].indent == 2)
        #expect(lines[0].paragraphRange.length - lines[0].range.length == 2)
        #expect(lines[1].kind == .heading(level: 2))
        #expect(lines[2].kind == .bullet)
        #expect(lines[3].kind == .bullet)
        #expect(lines[4].kind == .checkbox(checked: true))
        #expect(lines[4].checkboxRange?.location == lines[4].range.location + 4)
        #expect(lines[5].kind == .checkbox(checked: false))
        #expect(lines[6].kind == .body)
    }

    @Test func emptyAndTrailingLinesAreClassified() {
        #expect(NoteMarkup.lines(in: "").map(\.kind) == [.body])
        #expect(NoteMarkup.lines(in: "").first?.range == NSRange(location: 0, length: 0))

        let lines = NoteMarkup.lines(in: "- one\r\n")
        #expect(lines.count == 2)
        #expect(lines[1].range == NSRange(location: length("- one\r\n"), length: 0))
        #expect(lines[1].kind == .body)
    }

    @Test func unicodeBeforeALineDoesNotMoveItsUTF16Ranges() {
        let text = "🐶 notes\n  - [ ] Återkom"
        let line = NoteMarkup.lines(in: text)[1]

        #expect(line.range.location == length("🐶 notes\n"))
        #expect(line.contentRange.location == length("🐶 notes\n  - [ ] "))
        #expect((text as NSString).substring(with: line.contentRange) == "Återkom")
    }
}

struct NoteMarkupReturnTests {
    @Test func returnContinuesABulletAtLineEnd() {
        let text = "  - item"
        let edit = NoteMarkup.returnEdit(in: text, selection: NSRange(location: length(text), length: 0))

        #expect(edit?.apply(to: text) == "  - item\n  - ")
        #expect(edit?.selection.location == length("  - item\n  - "))
    }

    @Test func returnContinuesACheckboxUnchecked() {
        let text = "  - [x] done"
        let edit = NoteMarkup.returnEdit(in: text, selection: NSRange(location: length(text), length: 0))

        #expect(edit?.apply(to: text) == "  - [x] done\n  - [ ] ")
        #expect(edit?.selection.location == length("  - [x] done\n  - [ ] "))
    }

    @Test func returnUsesTheCurrentCRLFSeparator() {
        let text = "- one\r\n- two"
        let edit = NoteMarkup.returnEdit(in: text, selection: NSRange(location: length("- one"), length: 0))

        #expect(edit?.apply(to: text) == "- one\r\n- \r\n- two")
        #expect(edit?.selection.location == length("- one\r\n- "))
    }

    @Test func returnOnAnEmptyListItemEndsTheList() {
        let bullet = NoteMarkup.returnEdit(in: "- ", selection: NSRange(location: 2, length: 0))
        #expect(bullet?.apply(to: "- ") == "")
        #expect(bullet?.selection.location == 0)

        let text = "  - [ ] \r\nnext"
        let checkbox = NoteMarkup.returnEdit(in: text, selection: NSRange(location: length("  - [ ] "), length: 0))
        #expect(checkbox?.apply(to: text) == "\r\nnext")
        #expect(checkbox?.selection.location == 0)
    }

    @Test func returnOnBodyTextUsesTheTextViewDefault() {
        #expect(NoteMarkup.returnEdit(in: "plain", selection: NSRange(location: 5, length: 0)) == nil)
        #expect(NoteMarkup.returnEdit(in: "- item", selection: NSRange(location: 2, length: 2)) == nil)
    }
}

struct NoteMarkupIndentTests {
    @Test func tabIndentsAListLineByTwoSpaces() {
        let text = "- item"
        let edit = NoteMarkup.indentEdit(in: text, selection: NSRange(location: length(text), length: 0), outdent: false)

        #expect(edit?.apply(to: text) == "  - item")
        #expect(edit?.selection.location == length("  - item"))
    }

    @Test func tabIndentsEverySelectedListLineButNotBodyText() {
        let text = "- one\nplain\n  - [ ] two"
        let selection = NSRange(location: 0, length: length(text))
        let edit = NoteMarkup.indentEdit(in: text, selection: selection, outdent: false)

        #expect(edit?.apply(to: text) == "  - one\nplain\n    - [ ] two")
        #expect(edit?.selection.location == 0)
        #expect(edit?.selection.length == length("  - one\nplain\n    - [ ] two"))
    }

    @Test func shiftTabOutdentsNestedListsByUpToTwoSpaces() {
        let text = "    - [x] done"
        let edit = NoteMarkup.indentEdit(in: text, selection: NSRange(location: length(text), length: 0), outdent: true)

        #expect(edit?.apply(to: text) == "  - [x] done")
        #expect(edit?.selection.location == length("  - [x] done"))
    }

    @Test func indentRulesIgnoreBodyAndFlatOutdent() {
        #expect(NoteMarkup.indentEdit(in: "plain", selection: NSRange(location: 2, length: 0), outdent: false) == nil)
        #expect(NoteMarkup.indentEdit(in: "- item", selection: NSRange(location: 2, length: 0), outdent: true) == nil)
    }
}

struct NoteMarkupCheckboxTests {
    @Test func clickingANestedCheckboxTogglesOnlyItsMarker() {
        let text = "🐶\n  - [ ] Återkom"
        let line = NoteMarkup.lines(in: text)[1]
        let location = try! #require(line.checkboxRange).location + 1
        let checked = NoteMarkup.toggleCheckbox(in: text, at: location)

        #expect(checked?.apply(to: text) == "🐶\n  - [x] Återkom")
        let unchecked = NoteMarkup.toggleCheckbox(in: checked!.apply(to: text), at: location)
        #expect(unchecked?.apply(to: checked!.apply(to: text)) == text)
    }

    @Test func clickingOutsideTheMarkerDoesNotToggle() {
        let text = "[ ] task"
        #expect(NoteMarkup.toggleCheckbox(in: text, at: length(text)) == nil)
        #expect(NoteMarkup.toggleCheckbox(in: "plain", at: 2) == nil)
    }

    @Test func typingSpaceAfterBracketsCompletesACheckbox() {
        let edit = NoteMarkup.checkboxCompletion(in: "[]", selection: NSRange(location: 2, length: 0))

        #expect(edit?.apply(to: "[]") == "[ ] ")
        #expect(edit?.selection.location == 4)
    }

    @Test func checkboxCompletionSupportsIndentAndCRLF() {
        let text = "  []\r\n"
        let edit = NoteMarkup.checkboxCompletion(in: text, selection: NSRange(location: 4, length: 0))

        #expect(edit?.apply(to: text) == "  [ ] \r\n")
        #expect(edit?.selection.location == 6)
    }

    @Test func checkboxCompletionOnlyRunsAtTheLineStartWithNoFollowingText() {
        #expect(NoteMarkup.checkboxCompletion(in: "one []", selection: NSRange(location: 6, length: 0)) == nil)
        #expect(NoteMarkup.checkboxCompletion(in: "[]abc", selection: NSRange(location: 2, length: 0)) == nil)
        #expect(NoteMarkup.checkboxCompletion(in: "[]", selection: NSRange(location: 0, length: 2)) == nil)
    }
}
