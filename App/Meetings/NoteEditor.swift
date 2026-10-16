import AppKit
import BarkCore
import SwiftUI

struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    let focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NoteTextView {
        let view = NoteTextView(usingTextLayoutManager: true)
        view.configure()
        view.delegate = context.coordinator
        view.onEdit = { [weak view, weak coordinator = context.coordinator] edit in
            guard let view else { return }
            coordinator?.apply(edit, to: view)
        }
        NoteStyler.style(view)
        return view
    }

    func updateNSView(_ view: NoteTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            view.undoManager?.removeAllActions()
            view.string = text
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            NoteStyler.style(view)
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                view.window?.makeFirstResponder(view)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NoteTextView, context: Context) -> CGSize? {
        let width = max(1, proposal.width ?? 320)
        view.frame.size.width = width
        view.textContainer?.containerSize = NSSize(width: max(1, width - view.textContainerInset.width * 2),
                                                   height: CGFloat.greatestFiniteMagnitude)
        guard let layout = view.textLayoutManager else {
            return CGSize(width: width, height: 160)
        }
        layout.ensureLayout(for: layout.documentRange)
        let height = layout.usageBoundsForTextContainer.height + view.textContainerInset.height * 2 + 8
        return CGSize(width: width, height: max(160, ceil(height)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        var lastFocusToken = 0
        private var applyingEdit = false

        init(_ parent: NoteEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NoteTextView else { return }
            parent.text = view.string
            NoteStyler.style(view)
            view.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard !applyingEdit else { return true }
            if replacementString == " ", let edit = NoteMarkup.checkboxCompletion(in: textView.string,
                                                                                    selection: textView.selectedRange()) {
                if let view = textView as? NoteTextView { apply(edit, to: view) }
                return false
            }
            return true
        }

        func apply(_ edit: NoteMarkup.Edit, to view: NoteTextView) {
            guard let storage = view.textStorage else { return }
            applyingEdit = true
            view.undoManager?.beginUndoGrouping()
            for change in edit.changes.sorted(by: { $0.range.location > $1.range.location }) {
                guard change.range.location >= 0, change.range.upperBound <= storage.length,
                      view.shouldChangeText(in: change.range, replacementString: change.replacement) else { continue }
                storage.replaceCharacters(in: change.range, with: change.replacement)
                view.didChangeText()
            }
            view.undoManager?.endUndoGrouping()
            applyingEdit = false
            view.setSelectedRange(edit.selection)
            parent.text = view.string
            NoteStyler.style(view)
        }
    }
}

final class NoteTextView: NSTextView {
    var onEdit: ((NoteMarkup.Edit) -> Void)?

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        backgroundColor = .clear
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 0, height: 4)
        textContainer?.lineFragmentPadding = 5
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: 320, height: CGFloat.greatestFiniteMagnitude)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    override func layout() {
        textContainer?.containerSize = NSSize(width: max(1, bounds.width - textContainerInset.width * 2),
                                               height: CGFloat.greatestFiniteMagnitude)
        super.layout()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let location = characterIndexForInsertion(at: point)
        if let edit = NoteMarkup.toggleCheckbox(in: string, at: location) {
            onEdit?(edit)
            window?.makeFirstResponder(self)
            return
        }
        super.mouseDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSTextView.insertNewline(_:)),
           let edit = NoteMarkup.returnEdit(in: string, selection: selectedRange()) {
            onEdit?(edit)
            return
        }
        if selector == #selector(NSTextView.insertTab(_:)),
           let edit = NoteMarkup.indentEdit(in: string, selection: selectedRange(), outdent: false) {
            onEdit?(edit)
            return
        }
        if selector == #selector(NSTextView.insertBacktab(_:)),
           let edit = NoteMarkup.indentEdit(in: string, selection: selectedRange(), outdent: true) {
            onEdit?(edit)
            return
        }
        super.doCommand(by: selector)
    }
}

@MainActor
private enum NoteStyler {
    static let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    static func style(_ view: NSTextView) {
        guard let storage = view.textStorage else { return }
        let source = view.string as NSString
        let bodyParagraph = paragraphStyle()
        storage.beginEditing()
        if storage.length > 0 {
            storage.setAttributes([.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraph],
                                  range: NSRange(location: 0, length: storage.length))
        }
        for line in NoteMarkup.lines(in: view.string) {
            switch line.kind {
            case .body:
                break
            case .heading(let level):
                let font = NSFont.systemFont(ofSize: level == 1 ? 22 : 17, weight: .semibold)
                storage.addAttributes([.font: font, .paragraphStyle: paragraphStyle(after: 6)], range: line.paragraphRange)
            case .bullet, .checkbox:
                let prefix = source.substring(with: NSRange(location: line.range.location,
                                                           length: line.contentRange.location - line.range.location))
                let indent = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
                storage.addAttribute(.paragraphStyle, value: paragraphStyle(headIndent: indent), range: line.paragraphRange)
            }
            if case .checkbox(let checked) = line.kind, checked {
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: line.range)
            }
            if let marker = line.markerRange {
                switch line.kind {
                case .heading:
                    storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: marker)
                case .body, .bullet, .checkbox:
                    break
                }
            }
        }
        storage.endEditing()
        view.typingAttributes = [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: bodyParagraph]
    }

    private static func paragraphStyle(headIndent: CGFloat = 0, after: CGFloat = 4) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = after
        style.firstLineHeadIndent = 0
        style.headIndent = headIndent
        return style
    }
}
