@testable import MeetingTranscriber
import XCTest

/// Staging recovery repairs WAV headers, re-mixes crashed recordings, migrates
/// the processed-recordings ledger, and enqueues recovered mixes. These operations
/// must all use the folder the queue was built with, never the process-wide
/// default: a controller built against a temp staging folder reaching into the
/// real recordings folder is the hazard that injecting the folder exists to remove.
///
/// The test checks both header repair and queue recovery in the injected folder.
/// There is deliberately no probe that reverts the fix: that one would scan and
/// rewrite the real recordings folder.
@MainActor
final class StagedRecoveryFolderTests: XCTestCase {
    func testTheStagedRecoveryWorksInTheQueuesStagingFolder() async throws {
        let staging = try makeTempDirectory(prefix: "StagedRecoveryStaging")
        let output = try makeTempDirectory(prefix: "StagedRecoveryOutput")

        // Keep one old mix in the folder to exercise the legacy-ledger seed,
        // plus a fresh mic track with a crash marker. The fresh track represents
        // the helper's finalized WAV after it receives EOF from a dead parent.
        let existingMix = staging.appendingPathComponent("20260101_1100_mix.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.1, count: 16000), sampleRate: 16000, url: existingMix)
        let stem = "20260101_1200"
        let micTrack = staging.appendingPathComponent(stem + "_mic.wav")
        try AudioMixer.saveWAV(samples: [Float](repeating: 0.05, count: 16000), sampleRate: 16000, url: micTrack)
        try Data().write(to: DualSourceRecorder.inProgressMarker(stem: stem, in: staging))

        let queue = try PipelineQueue(
            engine: MockEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { nil },
            outputDir: output,
            logDir: makeTempDirectory(prefix: "StagedRecoveryLog"),
            stagingDir: staging,
        )
        let recover = try XCTUnwrap(PipelineController.QueueEnvironment.production.recoverStagedRecordings)
        recover(queue, true)

        let recoveredMix = staging.appendingPathComponent(stem + "_mix.wav")
        var remixed = false
        var recoveredJob = false
        let deadline = ContinuousClock.now + .seconds(5)
        while !remixed || !recoveredJob, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            remixed = FileManager.default.fileExists(atPath: recoveredMix.path)
            recoveredJob = queue.jobs.contains { $0.mixPath?.standardizedFileURL == recoveredMix.standardizedFileURL }
        }
        XCTAssertTrue(
            remixed,
            "the staging recovery did not remix the queue's staged mic track",
        )
        XCTAssertTrue(
            recoveredJob,
            "a newly re-mixed crash recording must not be seeded as already processed during ledger migration",
        )
        XCTAssertFalse(
            queue.jobs.contains { $0.mixPath?.standardizedFileURL == existingMix.standardizedFileURL },
            "migration must still skip mixes that predated the recovery pass",
        )
    }
}
