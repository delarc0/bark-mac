import Foundation

// UI-observable mirror of the Transcriber actor's state, fed by
// MenuBarController's state observer. Views (onboarding, overlay) can't
// observe an actor directly.
@MainActor
final class ModelStatus: ObservableObject {
    static let shared = ModelStatus()
    @Published var state: Transcriber.State = .unloaded
}
