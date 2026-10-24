/// Persists audio edits as recording versions and keeps transcript/audio
/// attachments together when an edited clip becomes the recording's default.
import Foundation

enum RecordingAudioEditSaveMode: String, CaseIterable, Identifiable {
    case replaceOriginal
    case separateRecordings

    var id: Self { self }

    var label: String {
        switch self {
        case .replaceOriginal: "Replace Recording"
        case .separateRecordings: "Save Separately"
        }
    }
}

struct RecordingAudioEditTranscriptionRequest {
    let recordingID: String
    let audioURL: URL
}

enum RecordingLibraryAudioEditError: LocalizedError {
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .missingAudio: "Sawti could not find the audio to preserve or transcribe."
        }
    }
}

extension RecordingLibraryIndex {
    /// Saves the edit history and returns the recordings that should be
    /// transcribed. Replacing uses the first split part as the new default and
    /// keeps later parts as their own recordings; saving separately leaves the
    /// current recording and its transcript untouched.
    static func saveAudioEdits(
        _ edits: [RecordingEditedAudio],
        mode: RecordingAudioEditSaveMode,
        for item: RecordingLibraryItem,
        outputDirectory: URL,
    ) throws -> [RecordingAudioEditTranscriptionRequest] {
        guard !edits.isEmpty else { return [] }
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if openedScope { outputDirectory.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let old = RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: item.id)
        let existingEdits = old?.editedAudio ?? item.editedAudio
        let allEdits = existingEdits + edits.filter { edit in !existingEdits.contains(where: { $0.id == edit.id }) }

        var originalAudioFilename = old?.originalAudioFilename
        var originalTranscriptFilename = old?.originalTranscriptFilename
        var originalRawTranscriptFilename = old?.originalRawTranscriptFilename
        var originalProtocolFilename = old?.originalProtocolFilename
        var currentAudioFilename = old?.audioFilename
        var requests: [RecordingAudioEditTranscriptionRequest] = []

        if mode == .replaceOriginal {
            guard let currentAudioURL = item.audioURL,
                  fileManager.fileExists(atPath: currentAudioURL.path) else {
                throw RecordingLibraryAudioEditError.missingAudio
            }

            let isFirstReplacement = originalAudioFilename == nil
            if originalAudioFilename == nil {
                originalAudioFilename = try copyIntoRecordings(
                    currentAudioURL,
                    prefix: "\(item.id)_original_audio_",
                    directory: recordingsDirectory,
                )
            }
            if isFirstReplacement, originalTranscriptFilename == nil, let transcriptURL = item.transcriptURL,
               fileManager.fileExists(atPath: transcriptURL.path) {
                let backupFilename = try copyIntoRecordings(
                    transcriptURL,
                    prefix: "\(item.id)_original_transcript_",
                    directory: recordingsDirectory,
                )
                originalTranscriptFilename = backupFilename
                let editorURL = transcriptURL.deletingPathExtension().appendingPathExtension("editor.json")
                if fileManager.fileExists(atPath: editorURL.path) {
                    let backupURL = recordingsDirectory
                        .appendingPathComponent(backupFilename)
                        .deletingPathExtension()
                        .appendingPathExtension("editor.json")
                    try fileManager.copyItem(at: editorURL, to: backupURL)
                    try fileManager.restrictToOwner(backupURL)
                }
            }
            if isFirstReplacement, originalRawTranscriptFilename == nil, let rawURL = item.originalTranscriptURL,
               fileManager.fileExists(atPath: rawURL.path) {
                originalRawTranscriptFilename = try copyIntoRecordings(
                    rawURL,
                    prefix: "\(item.id)_original_transcript_",
                    directory: recordingsDirectory,
                )
            }
            if isFirstReplacement, originalProtocolFilename == nil, let protocolURL = item.protocolURL,
               fileManager.fileExists(atPath: protocolURL.path) {
                let backupFilename = try copyIntoRecordings(
                    protocolURL,
                    prefix: "\(item.id)_original_protocol_",
                    directory: recordingsDirectory,
                )
                originalProtocolFilename = backupFilename
                let editorURL = protocolURL.deletingPathExtension().appendingPathExtension("editor.json")
                if fileManager.fileExists(atPath: editorURL.path) {
                    let backupURL = recordingsDirectory
                        .appendingPathComponent(backupFilename)
                        .deletingPathExtension()
                        .appendingPathExtension("editor.json")
                    try fileManager.copyItem(at: editorURL, to: backupURL)
                    try fileManager.restrictToOwner(backupURL)
                }
            }

            currentAudioFilename = edits[0].filename
            requests.append(RecordingAudioEditTranscriptionRequest(
                recordingID: item.id,
                audioURL: recordingsDirectory.appendingPathComponent(edits[0].filename),
            ))
        }

        let updatedMetadata = RecordingLibraryMetadata(
            title: old?.title ?? item.sourceTitle,
            appName: old?.appName ?? item.appName ?? "Unknown",
            recordedAt: item.recordedAt,
            participants: item.participants,
            category: old?.category,
            customTitle: old?.customTitle,
            workspaceID: old?.workspaceID ?? item.workspaceID,
            editedAudio: allEdits,
            audioFilename: currentAudioFilename,
            originalAudioFilename: originalAudioFilename,
            originalTranscriptFilename: originalTranscriptFilename,
            originalRawTranscriptFilename: originalRawTranscriptFilename,
            originalProtocolFilename: originalProtocolFilename,
            audioIsEdited: mode == .replaceOriginal ? true : old?.audioIsEdited,
            recordingSource: item.recordingSource,
            assistantConversationID: old?.assistantConversationID ?? item.assistantConversationID,
        )

        let separateEdits = mode == .replaceOriginal ? Array(edits.dropFirst()) : edits
        var createdChildArtifacts: [URL] = []
        do {
            for edit in separateEdits {
                let newID = "\(item.id)_clip_\(edit.id.uuidString.lowercased())"
                let sourceURL = recordingsDirectory.appendingPathComponent(edit.filename)
                let filename = "\(newID)_audio.\(sourceURL.pathExtension)"
                let destinationURL = recordingsDirectory.appendingPathComponent(filename)
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                createdChildArtifacts.append(destinationURL)
                try fileManager.restrictToOwner(destinationURL)
                try RecordingLibraryMetadata(
                    title: old?.title ?? item.sourceTitle,
                    appName: old?.appName ?? item.appName ?? "Unknown",
                    recordedAt: item.recordedAt,
                    participants: item.participants,
                    customTitle: "\(item.title) — \(edit.title)",
                    workspaceID: old?.workspaceID ?? item.workspaceID,
                    audioFilename: filename,
                    audioIsEdited: true,
                    recordingSource: item.recordingSource,
                ).write(toDirectory: recordingsDirectory, basename: newID)
                createdChildArtifacts.append(recordingsDirectory.appendingPathComponent(
                    "\(newID)\(RecordingLibraryMetadata.filenameSuffix)",
                ))
                requests.append(RecordingAudioEditTranscriptionRequest(recordingID: newID, audioURL: destinationURL))
            }
            try updatedMetadata.write(toDirectory: recordingsDirectory, basename: item.id)
        } catch {
            if let old {
                try? old.write(toDirectory: recordingsDirectory, basename: item.id)
            } else {
                let metadataURL = recordingsDirectory.appendingPathComponent(
                    "\(item.id)\(RecordingLibraryMetadata.filenameSuffix)",
                )
                try? fileManager.removeItem(at: metadataURL)
            }
            for artifact in createdChildArtifacts {
                try? fileManager.removeItem(at: artifact)
            }
            throw error
        }

        if mode == .replaceOriginal {
            // The old text belongs to the audio that was just replaced. Its
            // immutable copy is safely stored in recordings/ above; removing
            // these active artifacts prevents the Library from briefly
            // presenting a stale transcript or protocol beside the new audio.
            let protocolsDirectory = outputDirectory.appendingPathComponent("protocols", isDirectory: true)
            for url in [item.transcriptURL, item.originalTranscriptURL, item.protocolURL].compactMap(\.self) {
                guard url.standardizedFileURL.deletingLastPathComponent().path
                    == protocolsDirectory.standardizedFileURL.path else { continue }
                guard fileManager.fileExists(atPath: url.path) else { continue }
                try? fileManager.removeItem(at: url)
                let editorURL = url.deletingPathExtension().appendingPathExtension("editor.json")
                if fileManager.fileExists(atPath: editorURL.path) {
                    try? fileManager.removeItem(at: editorURL)
                }
            }
        }

        return requests
    }

    private static func copyIntoRecordings(_ source: URL, prefix: String, directory: URL) throws -> String {
        let fileManager = FileManager.default
        let openedScope = source.startAccessingSecurityScopedResource()
        defer {
            if openedScope { source.stopAccessingSecurityScopedResource() }
        }
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension
        let filename = "\(prefix)\(UUID().uuidString.lowercased()).\(ext)"
        let destination = directory.appendingPathComponent(filename)
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.restrictToOwner(destination)
        return filename
    }
}
