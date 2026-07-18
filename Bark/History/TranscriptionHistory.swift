import Foundation

// Last few transcriptions, in memory only — dictated text never touches disk.
// Exists so a paste that landed in the wrong window (focus stolen mid-dictation,
// missed click) isn't lost: menu bar → Copy Recent → click an entry.
@MainActor
final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    private(set) var entries: [(date: Date, text: String)] = []
    private let cap = 10

    func add(_ text: String) {
        guard !text.isEmpty else { return }
        entries.insert((Date(), text), at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
    }
}
