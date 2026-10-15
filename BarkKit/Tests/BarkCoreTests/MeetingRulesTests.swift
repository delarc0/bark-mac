import BarkCore
import Foundation
import Testing

struct MeetingDefaultsTests {
    @Test func lastMeetingLanguageWins() {
        #expect(MeetingDefaults.language(last: "en", dictation: .explicit("sv"), swedishModel: true) == "en")
    }

    @Test func firstMeetingTakesTheDictationLanguage() {
        #expect(MeetingDefaults.language(last: nil, dictation: .explicit("de"), swedishModel: true) == "de")
        #expect(MeetingDefaults.language(last: "", dictation: .explicit("de"), swedishModel: false) == "de")
    }

    @Test func autoResolvesBySwedishModel() {
        #expect(MeetingDefaults.language(last: nil, dictation: .auto, swedishModel: true) == "sv")
        #expect(MeetingDefaults.language(last: nil, dictation: .auto, swedishModel: false) == "en")
    }
}

private func process(_ pid: Int32, _ bundleID: String, input: Bool = true) -> AudioProcess {
    AudioProcess(objectID: UInt32(pid), pid: pid, bundleID: bundleID, runningInput: input, runningOutput: true)
}

struct MeetingCapturePlanTests {
    let zoom = CallApps.app(bundleID: "us.zoom.xos")!

    @Test func automaticRecordsADetectedCallWithEveryProcessOfTheApp() {
        let processes = [process(10, "us.zoom.xos"), process(11, "us.zoom.xos.helper", input: false), process(12, "com.spotify.client")]
        #expect(MeetingCapturePlan.plan(.automatic, processes: processes) == .app(zoom, pids: [10, 11]))
    }

    @Test func automaticWithoutACallIsTheMicrophone() {
        #expect(MeetingCapturePlan.plan(.automatic, processes: [process(12, "com.spotify.client")]) == .microphone)
        #expect(MeetingCapturePlan.plan(.automatic, processes: [process(10, "us.zoom.xos", input: false)]) == .microphone)
    }

    @Test func callWithoutADetectedAppTapsAllSystemAudio() {
        #expect(MeetingCapturePlan.plan(.call, processes: []) == .allSystemAudio)
        #expect(MeetingCapturePlan.plan(.call, processes: [process(10, "us.zoom.xos")]) == .app(zoom, pids: [10]))
    }

    @Test func inPersonIgnoresACall() {
        #expect(MeetingCapturePlan.plan(.inPerson, processes: [process(10, "us.zoom.xos")]) == .microphone)
    }
}

struct CallOffersTests {
    @Test func offersACallOnceUntilItEnds() {
        var offers = CallOffers()
        let call = [process(10, "us.zoom.xos")]
        #expect(offers.observe([]) == .none)
        #expect(offers.observe(call) == .offer(CallApps.app(bundleID: "us.zoom.xos")!))
        #expect(offers.observe(call) == .none)
        #expect(offers.observe(call) == .none)
        #expect(offers.observe([]) == .withdraw)
        #expect(offers.observe([]) == .none)
        #expect(offers.observe(call) == .offer(CallApps.app(bundleID: "us.zoom.xos")!))
    }

    @Test func aNewProcessIsANewCall() {
        var offers = CallOffers()
        #expect(offers.observe([process(10, "us.zoom.xos")]) != .none)
        #expect(offers.observe([process(20, "us.zoom.xos")]) == .offer(CallApps.app(bundleID: "us.zoom.xos")!))
    }

    @Test func theSameCallGainingAProcessIsNotOfferedAgain() {
        var offers = CallOffers()
        #expect(offers.observe([process(10, "com.google.Chrome.helper")]) != .none)
        #expect(offers.observe([process(10, "com.google.Chrome.helper"), process(11, "com.google.Chrome.helper")]) == .none)
        #expect(offers.observe([process(11, "com.google.Chrome.helper")]) == .none)
    }

    @Test func aCallRecordedFromTheMenuIsNotOfferedAfterwards() {
        var offers = CallOffers()
        let call = [process(10, "us.zoom.xos")]
        offers.markHandled(call)
        #expect(offers.observe(call) == .none)
        #expect(offers.observe([]) == .withdraw)
    }

    @Test func aProcessThatOnlyPlaysIsNoCall() {
        var offers = CallOffers()
        #expect(offers.observe([process(10, "us.zoom.xos", input: false)]) == .none)
    }
}

struct AudioRetentionTests {
    @Test func storedDaysMapToChoices() {
        #expect(AudioRetention(days: nil) == .month)
        #expect(AudioRetention(days: 7) == .week)
        #expect(AudioRetention(days: 0) == .forever)
        #expect(AudioRetention(days: 45) == .month)
    }

    @Test func foreverNeverExpires() {
        #expect(AudioRetention.forever.interval == nil)
        #expect(AudioRetention.quarter.interval == TimeInterval(90 * 86_400))
    }
}

struct TranscriptTextTests {
    @Test func timestamps() {
        #expect(TranscriptText.timestamp(0) == "0:00")
        #expect(TranscriptText.timestamp(-3) == "0:00")
        #expect(TranscriptText.timestamp(65.9) == "1:05")
        #expect(TranscriptText.timestamp(3599) == "59:59")
        #expect(TranscriptText.timestamp(3723) == "1:02:03")
    }

    @Test func firstWordsAcrossSegments() {
        #expect(TranscriptText.firstWords([]) == nil)
        #expect(TranscriptText.firstWords(["", "  "]) == nil)
        #expect(TranscriptText.firstWords(["Hej, hör ni", "mig?"]) == "Hej, hör ni mig?")
        #expect(TranscriptText.firstWords(["one two three", "four five"], count: 4) == "one two three four…")
        #expect(TranscriptText.firstWords(["one two three four"], count: 4) == "one two three four")
    }

    @Test func plainSkipsEmptySegmentsAndLabelsSides() {
        let text = TranscriptText.plain([
            .init(label: "Me", start: 0.84, text: "Hej, hör ni mig?"),
            .init(label: "Them", start: 3.9, text: " "),
            .init(label: "Them", start: 65, text: "Ja. "),
            .init(label: nil, start: 3700, text: "Rummet."),
        ])
        #expect(text == "[0:00] Me: Hej, hör ni mig?\n[1:05] Them: Ja.\n[1:01:40] Rummet.")
    }
}
