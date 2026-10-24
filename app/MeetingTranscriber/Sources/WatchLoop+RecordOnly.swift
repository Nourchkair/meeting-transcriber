import Foundation
import os.log

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "WatchLoop")

/// The record-only output branch, split out of `WatchLoop.swift` to keep that
/// file under the line cap. An extension of a globally `@MainActor`-isolated
/// type inherits that isolation, so the moved methods need no annotation.
/// Pure I/O: failures propagate to `enqueueRecording`, which owns the state
/// mutation and the user-facing notification.
extension WatchLoop {
    func writeRecordOnlySidecar(
        title: String,
        appName: String,
        recording: RecordingResult,
        trigger: RecordingSidecar.Trigger,
        participants: [String],
        activeSpeakerIntervals: [ActiveSpeakerInterval]? = nil,
        bookmarks: [RecordingBookmark] = [],
        liveTranscript: String? = nil,
        assistantConversationID: UUID? = nil,
    ) throws {
        let startedAt = recording.recordingStartDate
        // Guard the sidecar's startedAt <= stoppedAt invariant against a
        // backward wall-clock step between start and stop (e.g. NTP correcting a
        // fast clock): never emit a negative interval for downstream fleet
        // consumers that compute a duration from the pair.
        let stoppedAt = max(Date(), startedAt)

        let mixName = recording.mixPath.lastPathComponent
        let basename = RecordingFileSuffix.stripSuffix(from: mixName)?.stem
            ?? recording.mixPath.deletingPathExtension().lastPathComponent

        let destination = recordOnlyDestination()
        // start/stopAccessingSecurityScopedResource MUST be called on the
        // URL that resolved from the bookmark (App Store sandboxed build,
        // or any custom Output Folder pick) — calling it on a child path
        // silently fails. We then write into the `recordings/` subfolder
        // beneath that scope.
        let accessing = destination.scope.startAccessingSecurityScopedResource()
        defer { if accessing { destination.scope.stopAccessingSecurityScopedResource() } }

        let destDir = destination.writeDir
        try FileManager.default.createDirectory(
            at: destDir, withIntermediateDirectories: true,
        )
        let movedMix = try Self.move(recording.mixPath, into: destDir)
        let movedApp = try recording.appPath.map { try Self.move($0, into: destDir) }
        let movedMic = try recording.micPath.map { try Self.move($0, into: destDir) }

        var liveTranscriptFilename: String?
        if let liveTranscript,
           !liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let filename = "\(basename)_live.txt"
            let url = destDir.appendingPathComponent(filename)
            try liveTranscript.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.restrictToOwner(url)
            liveTranscriptFilename = filename
        }

        let sidecar = RecordingSidecar(
            title: title,
            appName: appName,
            startedAt: startedAt,
            stoppedAt: stoppedAt,
            participants: participants,
            micDelaySeconds: recording.micDelay,
            trigger: trigger,
            mixFilename: movedMix.lastPathComponent,
            appFilename: movedApp?.lastPathComponent,
            micFilename: movedMic?.lastPathComponent,
            activeSpeakerIntervals: activeSpeakerIntervals,
            liveTranscriptFilename: liveTranscriptFilename,
            assistantConversationID: assistantConversationID,
        )
        try sidecar.write(toDirectory: destDir, basename: basename)
        do {
            try RecordingBookmarksStore.write(bookmarks, to: destDir, basename: basename)
        } catch {
            logger.warning("Record-only bookmarks could not be saved: \(error.localizedDescription, privacy: .private)")
        }
        logger.info("Record-only: wrote sidecar + WAVs to \(destDir.path) for \(title, privacy: .private)")
    }

    /// Move a file into `destDir`, returning its new URL. If a file with the
    /// same name already exists at the destination it is overwritten.
    private static func move(_ source: URL, into destDir: URL) throws -> URL {
        let dest = destDir.appendingPathComponent(source.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: source, to: dest)
        return dest
    }
}
