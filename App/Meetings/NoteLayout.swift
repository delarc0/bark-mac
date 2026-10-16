import AppKit
import BarkCore

@MainActor
final class NoteLayoutDelegate: NSObject, @preconcurrency NSTextLayoutManagerDelegate {
    weak var textView: NoteTextView?

    func textLayoutManager(_ textLayoutManager: NSTextLayoutManager,
                           textLayoutFragmentFor location: NSTextLocation,
                           in textElement: NSTextElement) -> NSTextLayoutFragment {
        guard let textView, let content = textLayoutManager.textContentManager else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        let offset = content.offset(from: content.documentRange.location, to: location)
        guard offset != NSNotFound,
              let line = NoteMarkup.lines(in: textView.string).first(where: {
                  offset >= $0.range.location && offset < max($0.range.upperBound, $0.range.location + 1)
              }) else {
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
        switch line.kind {
        case .bullet, .checkbox:
            return NoteLayoutFragment(textElement: textElement, line: line)
        case .body, .heading:
            return NSTextLayoutFragment(textElement: textElement, range: nil)
        }
    }
}

final class NoteLayoutFragment: NSTextLayoutFragment {
    private let line: NoteMarkup.Line

    init(textElement: NSTextElement, line: NoteMarkup.Line) {
        self.line = line
        super.init(textElement: textElement, range: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var renderingSurfaceBounds: CGRect {
        let bounds = super.renderingSurfaceBounds
        return CGRect(x: bounds.minX - 20, y: bounds.minY, width: bounds.width + 20, height: bounds.height)
    }

    var checkboxLocation: Int? { line.checkboxRange?.location }

    var checkboxHitRect: CGRect? {
        guard case .checkbox = line.kind, let first = textLineFragments.first else { return nil }
        let center = CGPoint(x: layoutFragmentFrame.origin.x + first.typographicBounds.minX - 10,
                             y: layoutFragmentFrame.origin.y + first.typographicBounds.midY)
        return CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        guard let first = textLineFragments.first else { return }
        let center = CGPoint(x: point.x + first.typographicBounds.minX - 10,
                             y: point.y + first.typographicBounds.midY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        switch line.kind {
        case .bullet:
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let bullet = NSString(string: "•")
            let size = bullet.size(withAttributes: attributes)
            bullet.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        case .checkbox(let checked):
            let name = checked ? "checkmark.circle.fill" : "circle"
            let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration),
                  let mask = symbol.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let color = checked ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
            let rect = CGRect(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2,
                              width: symbol.size.width, height: symbol.size.height)
            context.saveGState()
            context.clip(to: rect, mask: mask)
            context.setFillColor(color.cgColor)
            context.fill(rect)
            context.restoreGState()
        case .body, .heading:
            break
        }
    }
}
