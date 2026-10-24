/// Scans Sawti's output folders and preserves the display metadata needed for
/// a searchable recording history after the short-lived processing job expires.
import Foundation

enum RecordingSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case meeting
    case microphone
    case app
    case imported

    var id: Self { self }

    var label: String {
        switch self {
        case .meeting: "Meeting"
        case .microphone: "Microphone"
        case .app: "App recording"
        case .imported: "Imported file"
        }
    }

    var symbolName: String {
        switch self {
        case .meeting: "person.3"
        case .microphone: "mic"
        case .app: "app"
        case .imported: "square.and.arrow.down"
        }
    }

    static func inferred(appName: String?) -> Self {
        switch appName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "microphone": .microphone
        case "file", "import", "imported": .imported
        default: .meeting
        }
    }

    static func captured(trigger: RecordingSidecar.Trigger?, appName: String?) -> Self {
        if inferred(appName: appName) == .microphone { return .microphone }
        return switch trigger {
        case .auto: .meeting
        case .manual: .app
        case nil: inferred(appName: appName)
        }
    }
}

/// Private descriptive metadata kept beside Sawti's processed audio. The
/// recording library can still rebuild its index from the files if a sidecar
/// is missing or unreadable.
struct RecordingLibraryMetadata: Codable, Sendable {
    static let filenameSuffix = "_library.json"
    static let currentVersion = 1

    let version: Int
    let title: String
    let appName: String
    let recordedAt: Date
    let participants: [String]
    /// Legacy free-text organizer, read to migrate older recordings into a
    /// workspace catalog.
    let category: String?
    let customTitle: String?
    let workspaceID: UUID?
    let editedAudio: [RecordingEditedAudio]?
    let audioFilename: String?
    /// The immutable audio that was current when the first edit replaced the
    /// default recording. Stored inside recordings/ so imported sources remain
    /// available even if their original external path changes.
    let originalAudioFilename: String?
    /// Human-editable transcript paired with the immutable original audio.
    let originalTranscriptFilename: String?
    /// Raw ASR transcript paired with the immutable original audio.
    let originalRawTranscriptFilename: String?
    /// Generated protocol/notes paired with the immutable original audio.
    let originalProtocolFilename: String?
    /// True when the active library audio is an edited or imported single-file
    /// source and should be transcribed by itself instead of merging the old
    /// dual-source capture tracks from a recording sidecar.
    let audioIsEdited: Bool?
    let recordingSource: RecordingSourceKind?
    let assistantConversationID: UUID?

    private enum CodingKeys: String, CodingKey {
        case version, title, appName, recordedAt, participants, category, course
        case customTitle, workspaceID, editedAudio, audioFilename
        case originalAudioFilename, originalTranscriptFilename, originalRawTranscriptFilename
        case originalProtocolFilename
        case audioIsEdited, recordingSource, assistantConversationID
    }

    init(
        title: String,
        appName: String,
        recordedAt: Date,
        participants: [String],
        category: String? = nil,
        customTitle: String? = nil,
        workspaceID: UUID? = nil,
        editedAudio: [RecordingEditedAudio]? = nil,
        audioFilename: String? = nil,
        originalAudioFilename: String? = nil,
        originalTranscriptFilename: String? = nil,
        originalRawTranscriptFilename: String? = nil,
        originalProtocolFilename: String? = nil,
        audioIsEdited: Bool? = nil,
        recordingSource: RecordingSourceKind? = nil,
        assistantConversationID: UUID? = nil,
    ) {
        version = Self.currentVersion
        self.title = title
        self.appName = appName
        self.recordedAt = recordedAt
        self.participants = participants
        self.category = category
        self.customTitle = customTitle
        self.workspaceID = workspaceID
        self.editedAudio = editedAudio
        self.audioFilename = audioFilename
        self.originalAudioFilename = originalAudioFilename
        self.originalTranscriptFilename = originalTranscriptFilename
        self.originalRawTranscriptFilename = originalRawTranscriptFilename
        self.originalProtocolFilename = originalProtocolFilename
        self.audioIsEdited = audioIsEdited
        self.recordingSource = recordingSource
        self.assistantConversationID = assistantConversationID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        title = try container.decode(String.self, forKey: .title)
        appName = try container.decode(String.self, forKey: .appName)
        recordedAt = try container.decode(Date.self, forKey: .recordedAt)
        participants = try container.decode([String].self, forKey: .participants)
        category = try container.decodeIfPresent(String.self, forKey: .category)
            ?? container.decodeIfPresent(String.self, forKey: .course)
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        workspaceID = try container.decodeIfPresent(UUID.self, forKey: .workspaceID)
        editedAudio = try container.decodeIfPresent([RecordingEditedAudio].self, forKey: .editedAudio)
        audioFilename = try container.decodeIfPresent(String.self, forKey: .audioFilename)
        originalAudioFilename = try container.decodeIfPresent(String.self, forKey: .originalAudioFilename)
        originalTranscriptFilename = try container.decodeIfPresent(String.self, forKey: .originalTranscriptFilename)
        originalRawTranscriptFilename = try container.decodeIfPresent(String.self, forKey: .originalRawTranscriptFilename)
        originalProtocolFilename = try container.decodeIfPresent(String.self, forKey: .originalProtocolFilename)
        audioIsEdited = try container.decodeIfPresent(Bool.self, forKey: .audioIsEdited)
        recordingSource = try container.decodeIfPresent(RecordingSourceKind.self, forKey: .recordingSource)
        assistantConversationID = try container.decodeIfPresent(UUID.self, forKey: .assistantConversationID)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(appName, forKey: .appName)
        try container.encode(recordedAt, forKey: .recordedAt)
        try container.encode(participants, forKey: .participants)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(editedAudio, forKey: .editedAudio)
        try container.encodeIfPresent(audioFilename, forKey: .audioFilename)
        try container.encodeIfPresent(originalAudioFilename, forKey: .originalAudioFilename)
        try container.encodeIfPresent(originalTranscriptFilename, forKey: .originalTranscriptFilename)
        try container.encodeIfPresent(originalRawTranscriptFilename, forKey: .originalRawTranscriptFilename)
        try container.encodeIfPresent(originalProtocolFilename, forKey: .originalProtocolFilename)
        try container.encodeIfPresent(audioIsEdited, forKey: .audioIsEdited)
        try container.encodeIfPresent(recordingSource, forKey: .recordingSource)
        try container.encodeIfPresent(assistantConversationID, forKey: .assistantConversationID)
    }

    func write(toDirectory directory: URL, basename: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = directory.appendingPathComponent("\(basename)\(Self.filenameSuffix)")
        try data.write(to: url, options: .atomic)
        try FileManager.default.restrictToOwner(url)
    }

    static func read(fromDirectory directory: URL, basename: String) -> Self? {
        let url = directory.appendingPathComponent("\(basename)\(filenameSuffix)")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let metadata = try? decoder.decode(Self.self, from: data),
              metadata.version == currentVersion,
              !metadata.title.isEmpty else { return nil }
        return metadata
    }
}

struct RecordingLibraryItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
    let recordedAt: Date
    let appName: String?
    let participants: [String]
    let workspaceID: UUID?
    let legacyCategory: String?
    let recordingSource: RecordingSourceKind
    let bookmarks: [RecordingBookmark]
    let editedAudio: [RecordingEditedAudio]
    let isEditedAudio: Bool
    let transcriptURL: URL?
    let liveTranscriptURL: URL?
    let originalTranscriptURL: URL?
    let originalAudioURL: URL?
    let originalTranscriptVersionURL: URL?
    let originalProtocolURL: URL?
    let protocolURL: URL?
    let audioURL: URL?
    let pipelineStatus: String?
    let error: String?
    let assistantConversationID: UUID?

    var statusLabel: String {
        if let pipelineStatus { return pipelineStatus }
        if protocolURL != nil { return "Transcript and AI notes ready" }
        if transcriptURL != nil, liveTranscriptURL != nil { return "Transcript ready · live draft saved" }
        if transcriptURL != nil { return "Transcript ready" }
        if liveTranscriptURL != nil { return "Live draft saved" }
        if originalTranscriptURL != nil { return "Original transcript saved" }
        return "Recording only"
    }

    /// Prefer the original paired tracks when they still exist. A recording
    /// saved in record-only mode can then be transcribed with the same
    /// app/microphone separation as its first live run.
    func transcriptionURLs(outputDirectory: URL) -> [URL] {
        let directory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let fileManager = FileManager.default
        func existing(_ filename: String?) -> URL? {
            guard let filename else { return nil }
            let url = directory.appendingPathComponent(filename)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        if isEditedAudio, let audioURL, fileManager.fileExists(atPath: audioURL.path) {
            return [audioURL]
        }

        if let sidecar = RecordingSidecar.read(fromDirectory: directory, basename: id) {
            let sourceURLs = [sidecar.files.mix, sidecar.files.app, sidecar.files.mic].compactMap(existing)
            if !sourceURLs.isEmpty { return sourceURLs }
        }

        let mix = existing("\(id)\(RecordingFileSuffix.mix)")
        let app = existing("\(id)\(RecordingFileSuffix.app)")
        let mic = existing("\(id)\(RecordingFileSuffix.mic)")
        if let mix { return [mix] + [app, mic].compactMap(\.self) }
        if app != nil, mic != nil { return [app, mic].compactMap(\.self) }
        if let convertedMix = existing("\(id)_16k.wav") { return [convertedMix] }
        return audioURL.flatMap { fileManager.fileExists(atPath: $0.path) ? [$0] : nil } ?? []
    }

    func reflecting(_ job: PipelineJob) -> Self {
        Self(
            id: id,
            title: title,
            sourceTitle: sourceTitle,
            recordedAt: recordedAt,
            appName: appName,
            participants: participants,
            workspaceID: workspaceID,
            legacyCategory: legacyCategory,
            recordingSource: recordingSource,
            bookmarks: bookmarks,
            editedAudio: editedAudio,
            isEditedAudio: isEditedAudio,
            transcriptURL: job.transcriptPath ?? transcriptURL,
            liveTranscriptURL: job.liveTranscriptPath ?? liveTranscriptURL,
            originalTranscriptURL: originalTranscriptURL,
            originalAudioURL: originalAudioURL,
            originalTranscriptVersionURL: originalTranscriptVersionURL,
            originalProtocolURL: originalProtocolURL,
            protocolURL: job.protocolPath ?? protocolURL,
            audioURL: audioURL ?? job.mixPath,
            pipelineStatus: job.state.label,
            error: job.error,
            assistantConversationID: job.assistantConversationID ?? assistantConversationID,
        )
    }

    static func inFlight(_ job: PipelineJob) -> Self {
        Self(
            id: job.namingSlug ?? "job-\(job.id.uuidString)",
            title: job.meetingTitle,
            sourceTitle: job.meetingTitle,
            recordedAt: job.artifactStartTime,
            appName: job.appName,
            participants: job.participants,
            workspaceID: nil,
            legacyCategory: nil,
            recordingSource: job.recordingSource ?? .inferred(appName: job.appName),
            bookmarks: job.bookmarks ?? [],
            editedAudio: [],
            isEditedAudio: false,
            transcriptURL: job.transcriptPath,
            liveTranscriptURL: job.liveTranscriptPath,
            originalTranscriptURL: job.rawTranscriptPath,
            originalAudioURL: nil,
            originalTranscriptVersionURL: nil,
            originalProtocolURL: nil,
            protocolURL: job.protocolPath,
            audioURL: job.mixPath,
            pipelineStatus: job.state.label,
            error: job.error,
            assistantConversationID: job.assistantConversationID,
        )
    }
}

/// Reads the durable output tree. The user-picked output root is the security
/// scoped URL; child URLs are accessed only while that root is open.
enum RecordingLibraryIndex {
    private struct Builder {
        let id: String
        var title: String
        var customTitle: String?
        var recordedAt: Date
        var appName: String?
        var participants: [String] = []
        var workspaceID: UUID?
        var legacyCategory: String?
        var recordingSource: RecordingSourceKind = .imported
        var bookmarks: [RecordingBookmark] = []
        var editedAudio: [RecordingEditedAudio] = []
        var isEditedAudio = false
        var assistantConversationID: UUID?
        var transcriptURL: URL?
        var liveTranscriptURL: URL?
        var originalTranscriptURL: URL?
        var originalAudioURL: URL?
        var originalTranscriptVersionURL: URL?
        var originalProtocolURL: URL?
        var protocolURL: URL?
        var audioURL: URL?
        var hasPreferredAudioURL = false

        func item() -> RecordingLibraryItem {
            RecordingLibraryItem(
                id: id,
                title: customTitle ?? title,
                sourceTitle: title,
                recordedAt: recordedAt,
                appName: appName,
                participants: participants,
                workspaceID: workspaceID,
                legacyCategory: legacyCategory,
                recordingSource: recordingSource,
                bookmarks: bookmarks,
                editedAudio: editedAudio,
                isEditedAudio: isEditedAudio,
                transcriptURL: transcriptURL,
                liveTranscriptURL: liveTranscriptURL,
                originalTranscriptURL: originalTranscriptURL,
                originalAudioURL: originalAudioURL,
                originalTranscriptVersionURL: originalTranscriptVersionURL,
                originalProtocolURL: originalProtocolURL,
                protocolURL: protocolURL,
                audioURL: audioURL,
                pipelineStatus: nil,
                error: nil,
                assistantConversationID: assistantConversationID,
            )
        }
    }

    static func load(outputDirectory: URL) throws -> [RecordingLibraryItem] {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer {
            if openedScope { outputDirectory.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        let protocolsDirectory = outputDirectory.appendingPathComponent("protocols", isDirectory: true)
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let transcriptFiles = try files(in: protocolsDirectory, fileManager: fileManager)
        let recordingFiles = try files(in: recordingsDirectory, fileManager: fileManager)
        var builders: [String: Builder] = [:]

        func builder(for id: String, source: URL?) -> Builder {
            if let existing = builders[id] { return existing }
            let sourceDate = (try? source?.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            let parsed = dateFromFilename(id)
            return Builder(
                id: id,
                title: fallbackTitle(for: id),
                recordedAt: parsed ?? sourceDate ?? .distantPast,
            )
        }

        for file in transcriptFiles {
            let stem = file.deletingPathExtension().lastPathComponent
            if file.pathExtension.lowercased() == "txt" {
                if stem.hasSuffix("_live") {
                    let base = String(stem.dropLast("_live".count))
                    var entry = builder(for: base, source: file)
                    entry.liveTranscriptURL = file
                    builders[base] = entry
                } else if let originalBase = originalTranscriptBase(stem) {
                    var entry = builder(for: originalBase, source: file)
                    entry.originalTranscriptURL = file
                    builders[originalBase] = entry
                } else {
                    var entry = builder(for: stem, source: file)
                    entry.transcriptURL = file
                    builders[stem] = entry
                }
            } else if file.pathExtension.lowercased() == "md" {
                var entry = builder(for: stem, source: file)
                entry.protocolURL = file
                builders[stem] = entry
            }
        }

        for file in recordingFiles {
            let name = file.lastPathComponent
            if name.hasSuffix(RecordingLibraryMetadata.filenameSuffix) {
                let id = String(name.dropLast(RecordingLibraryMetadata.filenameSuffix.count))
                guard let metadata = RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: id)
                else { continue }
                var entry = builder(for: id, source: file)
                entry.title = metadata.title
                entry.customTitle = metadata.customTitle
                entry.appName = metadata.appName
                entry.recordedAt = metadata.recordedAt
                entry.participants = metadata.participants
                entry.workspaceID = metadata.workspaceID
                entry.legacyCategory = metadata.category
                entry.editedAudio = metadata.editedAudio ?? []
                entry.isEditedAudio = metadata.audioIsEdited ?? false
                entry.assistantConversationID = metadata.assistantConversationID ?? entry.assistantConversationID
                if let filename = metadata.audioFilename {
                    entry.audioURL = recordingsDirectory.appendingPathComponent(filename)
                    entry.hasPreferredAudioURL = true
                }
                if let filename = metadata.originalAudioFilename {
                    entry.originalAudioURL = recordingsDirectory.appendingPathComponent(filename)
                }
                if let filename = metadata.originalTranscriptFilename {
                    entry.originalTranscriptVersionURL = recordingsDirectory.appendingPathComponent(filename)
                }
                if let filename = metadata.originalProtocolFilename {
                    entry.originalProtocolURL = recordingsDirectory.appendingPathComponent(filename)
                }
                if let filename = metadata.originalRawTranscriptFilename {
                    entry.originalTranscriptURL = recordingsDirectory.appendingPathComponent(filename)
                }
                if let sidecar = RecordingSidecar.read(fromDirectory: recordingsDirectory, basename: id),
                   let filename = sidecar.liveTranscriptFilename {
                    entry.liveTranscriptURL = recordingsDirectory.appendingPathComponent(filename)
                }
                entry.recordingSource = metadata.recordingSource ?? .inferred(appName: metadata.appName)
                builders[id] = entry
            } else if name.hasSuffix(RecordingBookmarksStore.filenameSuffix) {
                let id = String(name.dropLast(RecordingBookmarksStore.filenameSuffix.count))
                var entry = builder(for: id, source: file)
                entry.bookmarks = RecordingBookmarksStore.read(from: recordingsDirectory, basename: id)
                builders[id] = entry
            } else if name.hasSuffix(RecordingSidecar.filenameSuffix) {
                let id = String(name.dropLast(RecordingSidecar.filenameSuffix.count))
                guard let metadata = RecordingSidecar.read(fromDirectory: recordingsDirectory, basename: id)
                else { continue }
                var entry = builder(for: id, source: file)
                entry.title = metadata.title
                entry.appName = metadata.appName
                entry.recordedAt = metadata.startedAt
                entry.participants = metadata.participants
                entry.assistantConversationID = metadata.assistantConversationID ?? entry.assistantConversationID
                entry.recordingSource = RecordingSourceKind.captured(
                    trigger: metadata.trigger,
                    appName: metadata.appName,
                )
                if !entry.hasPreferredAudioURL {
                    entry.audioURL = recordingsDirectory.appendingPathComponent(metadata.files.mix)
                }
                if let filename = metadata.liveTranscriptFilename {
                    entry.liveTranscriptURL = recordingsDirectory.appendingPathComponent(filename)
                }
                builders[id] = entry
            } else if let (id, audioURL) = audioFile(file) {
                var entry = builder(for: id, source: file)
                if !entry.hasPreferredAudioURL,
                   entry.audioURL == nil || audioURL.lastPathComponent.hasSuffix("_mix.wav") {
                    entry.audioURL = audioURL
                }
                builders[id] = entry
            }
        }

        return builders.values
            .map { $0.item() }
            .filter {
                $0.transcriptURL != nil || $0.liveTranscriptURL != nil || $0.originalTranscriptURL != nil
                    || $0.protocolURL != nil || $0.audioURL != nil
            }
            .sorted {
                if $0.recordedAt == $1.recordedAt { return $0.id > $1.id }
                return $0.recordedAt > $1.recordedAt
            }
    }

    static func assistantConversationID(for item: RecordingLibraryItem, outputDirectory: URL) -> UUID? {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        return RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: item.id)?.assistantConversationID
            ?? RecordingSidecar.read(fromDirectory: recordingsDirectory, basename: item.id)?.assistantConversationID
    }

    static func assign(
        workspaceID: UUID?,
        to item: RecordingLibraryItem,
        outputDirectory: URL,
    ) throws {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let old = RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: item.id)
        try RecordingLibraryMetadata(
            title: old?.title ?? item.sourceTitle,
            appName: old?.appName ?? item.appName ?? "Unknown",
            recordedAt: item.recordedAt,
            participants: item.participants,
            customTitle: old?.customTitle,
            workspaceID: workspaceID,
            editedAudio: old?.editedAudio ?? item.editedAudio,
            audioFilename: old?.audioFilename,
            originalAudioFilename: old?.originalAudioFilename,
            originalTranscriptFilename: old?.originalTranscriptFilename,
            originalRawTranscriptFilename: old?.originalRawTranscriptFilename,
            originalProtocolFilename: old?.originalProtocolFilename,
            audioIsEdited: old?.audioIsEdited,
            recordingSource: item.recordingSource,
            assistantConversationID: old?.assistantConversationID ?? item.assistantConversationID,
        ).write(toDirectory: recordingsDirectory, basename: item.id)
    }

    static func setAssistantConversationID(
        _ conversationID: UUID,
        for item: RecordingLibraryItem,
        outputDirectory: URL,
    ) throws {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let old = RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: item.id)
        try RecordingLibraryMetadata(
            title: old?.title ?? item.sourceTitle,
            appName: old?.appName ?? item.appName ?? "Unknown",
            recordedAt: item.recordedAt,
            participants: item.participants,
            category: old?.category ?? item.legacyCategory,
            customTitle: old?.customTitle,
            workspaceID: old?.workspaceID ?? item.workspaceID,
            editedAudio: old?.editedAudio ?? item.editedAudio,
            audioFilename: old?.audioFilename ?? item.audioURL?.lastPathComponent,
            originalAudioFilename: old?.originalAudioFilename ?? item.originalAudioURL?.lastPathComponent,
            originalTranscriptFilename: old?.originalTranscriptFilename ?? item.originalTranscriptVersionURL?.lastPathComponent,
            originalRawTranscriptFilename: old?.originalRawTranscriptFilename ?? item.originalTranscriptURL?.lastPathComponent,
            originalProtocolFilename: old?.originalProtocolFilename ?? item.originalProtocolURL?.lastPathComponent,
            audioIsEdited: old?.audioIsEdited ?? item.isEditedAudio,
            recordingSource: old?.recordingSource ?? item.recordingSource,
            assistantConversationID: old?.assistantConversationID ?? conversationID,
        ).write(toDirectory: recordingsDirectory, basename: item.id)
    }

    static func rename(_ item: RecordingLibraryItem, to title: String, outputDirectory: URL) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw RecordingLibraryRenameError.emptyTitle }
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let old = RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: item.id)
        try RecordingLibraryMetadata(
            title: old?.title ?? item.sourceTitle,
            appName: old?.appName ?? item.appName ?? "Unknown",
            recordedAt: item.recordedAt,
            participants: item.participants,
            customTitle: trimmedTitle == item.sourceTitle ? nil : trimmedTitle,
            workspaceID: old?.workspaceID ?? item.workspaceID,
            editedAudio: old?.editedAudio ?? item.editedAudio,
            audioFilename: old?.audioFilename,
            originalAudioFilename: old?.originalAudioFilename,
            originalTranscriptFilename: old?.originalTranscriptFilename,
            originalRawTranscriptFilename: old?.originalRawTranscriptFilename,
            originalProtocolFilename: old?.originalProtocolFilename,
            audioIsEdited: old?.audioIsEdited,
            recordingSource: item.recordingSource,
            assistantConversationID: old?.assistantConversationID ?? item.assistantConversationID,
        ).write(toDirectory: recordingsDirectory, basename: item.id)
    }

    static func assigning(_ item: RecordingLibraryItem, workspaceID: UUID?) -> RecordingLibraryItem {
        RecordingLibraryItem(
            id: item.id,
            title: item.title,
            sourceTitle: item.sourceTitle,
            recordedAt: item.recordedAt,
            appName: item.appName,
            participants: item.participants,
            workspaceID: workspaceID,
            legacyCategory: nil,
            recordingSource: item.recordingSource,
            bookmarks: item.bookmarks,
            editedAudio: item.editedAudio,
            isEditedAudio: item.isEditedAudio,
            transcriptURL: item.transcriptURL,
            liveTranscriptURL: item.liveTranscriptURL,
            originalTranscriptURL: item.originalTranscriptURL,
            originalAudioURL: item.originalAudioURL,
            originalTranscriptVersionURL: item.originalTranscriptVersionURL,
            originalProtocolURL: item.originalProtocolURL,
            protocolURL: item.protocolURL,
            audioURL: item.audioURL,
            pipelineStatus: item.pipelineStatus,
            error: item.error,
            assistantConversationID: item.assistantConversationID,
        )
    }

    /// Permanently removes Sawti's saved files for one library entry. Only
    /// direct children of this output root's `recordings` and `protocols`
    /// folders are eligible, so importing a file never makes its original
    /// source elsewhere on disk part of the deletion.
    static func delete(item: RecordingLibraryItem, outputDirectory: URL) throws {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let protocolsDirectory = outputDirectory.appendingPathComponent("protocols", isDirectory: true)
        let attachedConversationID = item.assistantConversationID
            ?? RecordingLibraryMetadata.read(fromDirectory: recordingsDirectory, basename: item.id)?.assistantConversationID
            ?? RecordingSidecar.read(fromDirectory: recordingsDirectory, basename: item.id)?.assistantConversationID
        var filesToDelete: [String: URL] = [:]

        func include(_ file: URL, directlyIn directory: URL) {
            guard file.standardizedFileURL.deletingLastPathComponent().path
                == directory.standardizedFileURL.path,
                fileManager.fileExists(atPath: file.path) else { return }
            filesToDelete[file.standardizedFileURL.path] = file
        }

        for file in try files(in: recordingsDirectory, fileManager: fileManager) {
            let name = file.lastPathComponent
            let belongsToRecording = audioFile(file)?.0 == item.id
                || name == "\(item.id)\(RecordingLibraryMetadata.filenameSuffix)"
                || name == "\(item.id)\(RecordingBookmarksStore.filenameSuffix)"
                || name == "\(item.id)\(RecordingSidecar.filenameSuffix)"
                || name == "\(item.id)\(RecordingFileSuffix.inProgress)"
                || RecordingFileSuffix.stripAppRaw(from: name) == item.id
                || name.hasPrefix("\(item.id)_source.")
                || name.hasPrefix("\(item.id)_edit_")
                || name.hasPrefix("\(item.id)_original_audio_")
                || name.hasPrefix("\(item.id)_original_transcript_")
                || name.hasPrefix("\(item.id)_original_protocol_")
                || name == "\(item.id)\(LiveTranscriptStore.filenameSuffix)"
                || name == "\(item.id)\(SpeakerNamingStore.namingJSONSuffix)"
                || name == "\(item.id)\(SpeakerNamingStore.segmentsSuffix)"
            if belongsToRecording { include(file, directlyIn: recordingsDirectory) }
        }

        // A record-only sidecar is the source of truth for paired tracks,
        // including legacy names that don't follow today's suffix convention.
        if let sidecar = RecordingSidecar.read(fromDirectory: recordingsDirectory, basename: item.id) {
            for filename in [sidecar.files.mix, sidecar.files.app, sidecar.files.mic].compactMap(\.self) {
                include(recordingsDirectory.appendingPathComponent(filename), directlyIn: recordingsDirectory)
            }
        }

        let transcriptFiles = try files(in: protocolsDirectory, fileManager: fileManager)
        for file in transcriptFiles {
            let stem = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension.lowercased()
            let isTranscript = ext == "txt" && (stem == item.id || isOriginalTranscript(stem, for: item.id))
                || ext == "txt" && stem == "\(item.id)_live"
            let isProtocol = ext == "md" && stem == item.id
            if isTranscript || isProtocol {
                include(file, directlyIn: protocolsDirectory)
                include(
                    file.deletingPathExtension().appendingPathExtension("editor.json"),
                    directlyIn: protocolsDirectory,
                )
            }
        }

        // Include the exact paths held by this Library row as well, but keep
        // them constrained to the Sawti-owned output subfolders.
        for file in [item.transcriptURL, item.liveTranscriptURL, item.originalTranscriptURL, item.protocolURL, item.originalProtocolURL].compactMap(\.self) {
            include(file, directlyIn: protocolsDirectory)
            include(file, directlyIn: recordingsDirectory)
            if ["txt", "md"].contains(file.pathExtension.lowercased()) {
                let editorFile = file.deletingPathExtension().appendingPathExtension("editor.json")
                include(editorFile, directlyIn: protocolsDirectory)
                include(editorFile, directlyIn: recordingsDirectory)
            }
        }
        if let audioURL = item.audioURL { include(audioURL, directlyIn: recordingsDirectory) }
        if let originalAudioURL = item.originalAudioURL { include(originalAudioURL, directlyIn: recordingsDirectory) }
        if let originalTranscriptVersionURL = item.originalTranscriptVersionURL {
            include(originalTranscriptVersionURL, directlyIn: recordingsDirectory)
            include(
                originalTranscriptVersionURL.deletingPathExtension().appendingPathExtension("editor.json"),
                directlyIn: recordingsDirectory,
            )
        }
        for asset in item.editedAudio {
            include(recordingsDirectory.appendingPathComponent(asset.filename), directlyIn: recordingsDirectory)
        }

        var failures = 0
        if let conversationID = attachedConversationID {
            do {
                try LiveAssistantConversationStore.delete(id: conversationID, outputDirectory: outputDirectory)
            } catch {
                failures += 1
            }
        }

        for file in filesToDelete.values {
            do {
                try fileManager.removeItem(at: file)
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                failures += 1
            }
        }
        if failures > 0 {
            throw RecordingLibraryDeletionError(failedFileCount: failures)
        }
    }

    private static func files(in directory: URL, fileManager: FileManager) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
        )
    }

    private static func originalTranscriptBase(_ stem: String) -> String? {
        guard let range = stem.range(of: "_original", options: .backwards) else { return nil }
        let version = stem[range.upperBound...]
        guard version.isEmpty || (version.first == "-" && Int(version.dropFirst()) != nil) else { return nil }
        return String(stem[..<range.lowerBound])
    }

    private static func audioFile(_ file: URL) -> (String, URL)? {
        guard file.pathExtension.lowercased() == "wav" else { return nil }
        let stem = file.deletingPathExtension().lastPathComponent
        for suffix in ["_app_16k", "_mic_16k", "_mix", "_16k", "_app", "_mic"] where stem.hasSuffix(suffix) {
            return (String(stem.dropLast(suffix.count)), file)
        }
        return nil
    }

    private static func isOriginalTranscript(_ stem: String, for basename: String) -> Bool {
        let prefix = "\(basename)_original"
        guard stem.hasPrefix(prefix) else { return false }
        let suffix = stem.dropFirst(prefix.count)
        guard !suffix.isEmpty else { return true }
        return suffix.first == "-" && Int(suffix.dropFirst()).map { $0 >= 2 } == true
    }

    private static func dateFromFilename(_ id: String) -> Date? {
        let patterns = [#"^(\d{8}_\d{6})_"#, #"^(\d{8}_\d{4})_"#]
        for pattern in patterns {
            guard let range = id.range(of: pattern, options: .regularExpression) else { continue }
            let stamp = String(id[range]).dropLast()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .autoupdatingCurrent
            formatter.dateFormat = stamp.count == 15 ? "yyyyMMdd_HHmmss" : "yyyyMMdd_HHmm"
            if let date = formatter.date(from: String(stamp)) { return date }
        }
        return nil
    }

    private static func fallbackTitle(for id: String) -> String {
        var title = id
        for pattern in [#"^\d{8}_\d{6}_"#, #"^\d{8}_\d{4}_"#] {
            title = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        title = title.replacingOccurrences(of: #"_[0-9a-fA-F]{8}$"#, with: "", options: .regularExpression)
        return title.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct RecordingLibraryDeletionError: LocalizedError {
    let failedFileCount: Int

    var errorDescription: String? {
        "Sawti could not remove \(failedFileCount) saved file(s). Some files may still be present."
    }
}

enum RecordingLibraryRenameError: LocalizedError {
    case emptyTitle

    var errorDescription: String? {
        "A recording title cannot be empty."
    }
}
