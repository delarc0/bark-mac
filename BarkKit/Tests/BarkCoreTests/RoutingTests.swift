import BarkCore
import Testing

struct RoutingTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let choice: LanguageChoice
        let detection: Detection?
        let remembered: String?
        let expected: Route
        var testDescription: String { name }
    }

    static func detected(_ language: String, _ probability: Double, _ seconds: Double) -> Detection {
        Detection(language: language, probability: probability, audioSeconds: seconds)
    }

    static let cases: [Case] = [
        Case(name: "explicit sv routes to KB without detection", choice: .explicit("sv"), detection: nil, remembered: nil,
             expected: Route(model: .swedish, language: "sv", remembered: nil)),
        Case(name: "explicit sv on short audio still routes to KB", choice: .explicit("sv"), detection: detected("en", 0.99, 0.3),
             remembered: "en", expected: Route(model: .swedish, language: "sv", remembered: "en")),
        Case(name: "explicit en stays general and leaves memory alone", choice: .explicit("en"), detection: nil, remembered: "sv",
             expected: Route(model: .general, language: "en", remembered: "sv")),
        Case(name: "fresh confident Swedish routes to KB", choice: .auto, detection: detected("sv", 0.97, 2.0), remembered: nil,
             expected: Route(model: .swedish, language: "sv", remembered: "sv")),
        Case(name: "Swedish at exactly 1 s and 0.85 routes to KB", choice: .auto, detection: detected("sv", 0.85, 1.0), remembered: nil,
             expected: Route(model: .swedish, language: "sv", remembered: "sv")),
        Case(name: "Swedish under 0.85 is remembered but stays general", choice: .auto, detection: detected("sv", 0.84, 3.0), remembered: "en",
             expected: Route(model: .general, language: "sv", remembered: "sv")),
        Case(name: "Swedish under 1 s never routes, even at 0.99", choice: .auto, detection: detected("sv", 0.99, 0.99), remembered: "sv",
             expected: Route(model: .general, language: "sv", remembered: "sv")),
        Case(name: "short English after Swedish never routes to KB", choice: .auto, detection: detected("en", 0.6, 0.6), remembered: "sv",
             expected: Route(model: .general, language: "sv", remembered: "sv")),
        Case(name: "short confident English after Swedish uses English", choice: .auto, detection: detected("en", 0.95, 0.6), remembered: "sv",
             expected: Route(model: .general, language: "en", remembered: "sv")),
        Case(name: "long confident English stays general and is remembered", choice: .auto, detection: detected("en", 0.98, 4.0), remembered: "sv",
             expected: Route(model: .general, language: "en", remembered: "en")),
        Case(name: "long weak detection under 0.5 falls back to memory", choice: .auto, detection: detected("no", 0.45, 4.0), remembered: "sv",
             expected: Route(model: .general, language: "sv", remembered: "sv")),
        Case(name: "weak detection with no memory uses the detection", choice: .auto, detection: detected("da", 0.3, 0.5), remembered: nil,
             expected: Route(model: .general, language: "da", remembered: nil)),
        Case(name: "failed detection prefills the remembered language", choice: .auto, detection: nil, remembered: "sv",
             expected: Route(model: .general, language: "sv", remembered: "sv")),
        Case(name: "failed detection with no memory has no language", choice: .auto, detection: nil, remembered: nil,
             expected: Route(model: .general, language: nil, remembered: nil)),
        Case(name: "a remembered sv never routes on its own", choice: .auto, detection: detected("sv", 0.7, 0.4), remembered: "sv",
             expected: Route(model: .general, language: "sv", remembered: "sv")),
    ]

    @Test(arguments: cases)
    func route(_ c: Case) {
        #expect(Routing.route(c.choice, detection: c.detection, remembered: c.remembered) == c.expected)
    }
}
