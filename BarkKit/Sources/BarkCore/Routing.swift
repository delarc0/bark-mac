/// Which Whisper decodes a dictation: KB-Whisper for Swedish, large-v3 for everything else.
public enum ModelRole: String, Sendable, Codable {
    case general, swedish
}

/// The user's language setting.
public enum LanguageChoice: Sendable, Equatable {
    case auto
    case explicit(String)
}

/// Language detection on the general model, run on the audio being routed.
public struct Detection: Sendable, Equatable {
    public let language: String
    public let probability: Double
    public let audioSeconds: Double

    public init(language: String, probability: Double, audioSeconds: Double) {
        self.language = language
        self.probability = probability
        self.audioSeconds = audioSeconds
    }
}

/// A model, the language to force on it, and the language to remember for the next dictation.
public struct Route: Sendable, Equatable {
    public let model: ModelRole
    /// nil only when detection failed and nothing is remembered.
    public let language: String?
    public let remembered: String?

    public init(model: ModelRole, language: String?, remembered: String?) {
        self.model = model
        self.language = language
        self.remembered = remembered
    }
}

/// Language prefill and model routing are two decisions. A remembered language is good enough to
/// prefill the general model (a wrong guess still transcribes the words), never to pick KB, whose
/// failure on non-Swedish audio is silent translation into Swedish. KB needs an explicit "sv" or a
/// fresh detection on this audio of at least 1 s and 0.85. The other branches are the shipping
/// app's resolveAutoLanguage.
public enum Routing {
    public static let routingProbability = 0.85
    public static let minimumSeconds = 1.0
    static let rememberProbability = 0.5
    static let shortAudioProbability = 0.9

    /// `detection` is nil when there is none (auto) or it failed.
    public static func route(_ choice: LanguageChoice, detection: Detection?, remembered: String?) -> Route {
        if case .explicit(let language) = choice {
            return Route(model: language == "sv" ? .swedish : .general, language: language, remembered: remembered)
        }
        guard let detection else {
            return Route(model: .general, language: remembered, remembered: remembered)
        }
        if detection.audioSeconds >= minimumSeconds, detection.probability >= rememberProbability {
            let swedish = detection.language == "sv" && detection.probability >= routingProbability
            return Route(model: swedish ? .swedish : .general, language: detection.language, remembered: detection.language)
        }
        // Short audio that is very sure of itself beats a remembered language, but never pins or routes.
        if detection.probability >= shortAudioProbability {
            return Route(model: .general, language: detection.language, remembered: remembered)
        }
        return Route(model: .general, language: remembered ?? detection.language, remembered: remembered)
    }
}
