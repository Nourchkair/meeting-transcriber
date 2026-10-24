@testable import MeetingTranscriber
import XCTest

final class ActiveSpeakerMatchingTests: XCTestCase {
    func testParsesExplicitSpeakingLabels() {
        XCTAssertEqual(
            ActiveSpeakerCueParser.name(from: ["Alice Johnson is currently speaking"]),
            "Alice Johnson",
        )
        XCTAssertEqual(
            ActiveSpeakerCueParser.name(from: ["Active speaker", "Alice Johnson"]),
            "Alice Johnson",
        )
        XCTAssertEqual(
            ActiveSpeakerCueParser.name(from: ["Hassan ist aktiv", "Active speaker: Hassan"]),
            "Hassan",
        )
    }

    func testParsesUnicodeNamesWithoutShiftingSpeakingMarkerRanges() {
        XCTAssertEqual(ActiveSpeakerCueParser.name(from: ["İpek is speaking"]), "İpek")
        XCTAssertEqual(ActiveSpeakerCueParser.name(from: ["İSMAİL is currently speaking"]), "İSMAİL")
        XCTAssertEqual(
            ActiveSpeakerCueParser.name(from: ["İpek mentions active speaker: Bob Singh"]),
            "Bob Singh",
        )
        XCTAssertEqual(ActiveSpeakerCueParser.name(from: ["İpek active speaker"]), "İpek")
    }

    func testDoesNotTreatFocusOrRosterPresenceAsSpeakingEvidence() {
        XCTAssertNil(ActiveSpeakerCueParser.name(from: ["Alice Johnson", "Bob Singh"]))
        XCTAssertNil(ActiveSpeakerCueParser.name(from: ["Alice Johnson", "Focused"]))
        XCTAssertNil(ActiveSpeakerCueParser.name(from: ["Alice is speaking", "Bob is speaking"]))
    }

    func testMapsSpeakersWhenDisplayedIdentityDominatesTheirAudioTimeline() {
        let segments = [
            segment(0, 3, "SPEAKER_00"),
            segment(3, 6, "SPEAKER_01"),
            segment(6, 9, "SPEAKER_00"),
            segment(9, 12, "SPEAKER_01"),
        ]
        let intervals = [
            interval(0, 3, "Alice Johnson"),
            interval(3, 6, "Bob Singh"),
            interval(6, 9, "Alice Johnson"),
            interval(9, 12, "Bob Singh"),
        ]

        let result = ActiveSpeakerNameMatcher.applying(
            intervals,
            to: ["SPEAKER_00": "SPEAKER_00", "SPEAKER_01": "SPEAKER_01"],
            segments: segments,
            speakingTimes: ["SPEAKER_00": 6, "SPEAKER_01": 6],
        )

        XCTAssertEqual(result["SPEAKER_00"], "Alice Johnson")
        XCTAssertEqual(result["SPEAKER_01"], "Bob Singh")
    }

    func testKeepsExistingNameWhenEvidenceIsSplitOrTooShort() {
        let split = ActiveSpeakerNameMatcher.applying(
            [interval(0, 2, "Alice Johnson"), interval(2, 4, "Bob Singh")],
            to: ["SPEAKER_00": "Known voice"],
            segments: [segment(0, 4, "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 4],
        )
        XCTAssertEqual(split["SPEAKER_00"], "Known voice")

        let tooShort = ActiveSpeakerNameMatcher.applying(
            [interval(0, 1.5, "Alice Johnson")],
            to: ["SPEAKER_00": "SPEAKER_00"],
            segments: [segment(0, 4, "SPEAKER_00")],
            speakingTimes: ["SPEAKER_00": 4],
        )
        XCTAssertEqual(tooShort["SPEAKER_00"], "SPEAKER_00")
    }

    func testDoesNotAssignOneDisplayedNameToTwoDiarizedSpeakers() {
        let intervals = [interval(0, 5, "Alice Johnson")]
        let segments = [segment(0, 5, "SPEAKER_00"), segment(0, 5, "SPEAKER_01")]
        let result = ActiveSpeakerNameMatcher.applying(
            intervals,
            to: ["SPEAKER_00": "SPEAKER_00", "SPEAKER_01": "SPEAKER_01"],
            segments: segments,
            speakingTimes: ["SPEAKER_00": 5, "SPEAKER_01": 5],
        )
        XCTAssertEqual(result["SPEAKER_00"], "SPEAKER_00")
        XCTAssertEqual(result["SPEAKER_01"], "SPEAKER_01")
    }

    func testTimelineClosesIntervalsOnSpeakerChangeAndFinish() {
        let timeline = ActiveSpeakerTimeline()
        timeline.observe(name: "Alice Johnson", at: 1)
        timeline.observe(name: "Alice Johnson", at: 2)
        timeline.observe(name: "Bob Singh", at: 3)
        timeline.observe(name: nil, at: 5)
        let expected = [
            interval(1, 3, "Alice Johnson"),
            interval(3, 5, "Bob Singh"),
        ]

        XCTAssertEqual(timeline.finish(at: 6), expected)
        timeline.observe(name: "Carol Lee", at: 7)
        XCTAssertEqual(timeline.finish(at: 8), expected)
    }

    func testPipelineJobWithoutActiveSpeakerDataStillDecodes() throws {
        let job = PipelineJob(
            meetingTitle: "Retro",
            appName: "Zoom",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
        )
        let encoded = try JSONEncoder().encode(job)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "activeSpeakerIntervals")
        let oldSnapshot = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(PipelineJob.self, from: oldSnapshot)
        XCTAssertNil(decoded.activeSpeakerIntervals)
    }

    private func segment(_ start: Double, _ end: Double, _ speaker: String) -> PipelineQueue.SpeakerNamingData.Segment {
        .init(start: start, end: end, speaker: speaker)
    }

    private func interval(_ start: Double, _ end: Double, _ name: String) -> ActiveSpeakerInterval {
        .init(start: start, end: end, name: name)
    }
}
