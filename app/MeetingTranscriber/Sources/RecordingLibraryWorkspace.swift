/// First-class local workspaces used to organize recordings and their attached
/// transcripts, edits, and future generated notes.
import Foundation

struct RecordingLibraryWorkspace: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct RecordingEditedAudio: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case trimmed
        case splitPart
    }

    let id: UUID
    let title: String
    let filename: String
    let kind: Kind
    /// Start and end offsets on the original recording timeline.
    let startOffset: TimeInterval
    let endOffset: TimeInterval
    let createdAt: Date

    var duration: TimeInterval {
        max(0, endOffset - startOffset)
    }

    init(
        id: UUID = UUID(),
        title: String,
        filename: String,
        kind: Kind,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        createdAt: Date = .now,
    ) {
        self.id = id
        self.title = title
        self.filename = filename
        self.kind = kind
        self.startOffset = max(0, startOffset)
        self.endOffset = max(startOffset, endOffset)
        self.createdAt = createdAt
    }
}

enum RecordingLibraryWorkspaceStore {
    private struct Catalog: Codable {
        let version: Int
        var workspaces: [RecordingLibraryWorkspace]
    }

    private static let filename = "_workspaces.json"
    private static let currentVersion = 1

    /// Loads the workspace catalog and promotes old free-text categories into
    /// real workspaces. The old field remains readable until each recording is
    /// migrated by `RecordingLibraryIndex`.
    static func load(outputDirectory: URL, legacyNames: [String] = []) throws -> [RecordingLibraryWorkspace] {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }

        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let url = recordingsDirectory.appendingPathComponent(filename)
        let existing: [RecordingLibraryWorkspace]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let catalog = try? decoder.decode(Catalog.self, from: data),
           catalog.version == currentVersion {
            existing = catalog.workspaces
        } else {
            existing = []
        }

        var workspaces = existing
        for rawName in legacyNames {
            let name = normalizedName(rawName)
            guard !name.isEmpty,
                  !workspaces.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
            else { continue }
            workspaces.append(RecordingLibraryWorkspace(name: name))
        }

        if workspaces != existing || !FileManager.default.fileExists(atPath: url.path) {
            try write(workspaces, to: recordingsDirectory)
        }
        return sorted(workspaces)
    }

    static func create(name: String, outputDirectory: URL) throws -> RecordingLibraryWorkspace {
        let normalized = normalizedName(name)
        guard !normalized.isEmpty else { throw RecordingWorkspaceStoreError.emptyName }
        var workspaces = try load(outputDirectory: outputDirectory)
        guard !workspaces.contains(where: { $0.name.localizedCaseInsensitiveCompare(normalized) == .orderedSame })
        else { throw RecordingWorkspaceStoreError.duplicateName }
        let workspace = RecordingLibraryWorkspace(name: normalized)
        workspaces.append(workspace)
        try save(workspaces, outputDirectory: outputDirectory)
        return workspace
    }

    static func rename(_ workspace: RecordingLibraryWorkspace, to name: String, outputDirectory: URL) throws
        -> RecordingLibraryWorkspace {
        let normalized = normalizedName(name)
        guard !normalized.isEmpty else { throw RecordingWorkspaceStoreError.emptyName }
        var workspaces = try load(outputDirectory: outputDirectory)
        guard !workspaces.contains(where: {
            $0.id != workspace.id && $0.name.localizedCaseInsensitiveCompare(normalized) == .orderedSame
        }) else { throw RecordingWorkspaceStoreError.duplicateName }
        let renamed = RecordingLibraryWorkspace(id: workspace.id, name: normalized, createdAt: workspace.createdAt)
        guard let index = workspaces.firstIndex(where: { $0.id == workspace.id }) else {
            throw RecordingWorkspaceStoreError.notFound
        }
        workspaces[index] = renamed
        try save(workspaces, outputDirectory: outputDirectory)
        return renamed
    }

    static func delete(_ workspace: RecordingLibraryWorkspace, outputDirectory: URL) throws {
        let workspaces = try load(outputDirectory: outputDirectory).filter { $0.id != workspace.id }
        try save(workspaces, outputDirectory: outputDirectory)
    }

    private static func save(_ workspaces: [RecordingLibraryWorkspace], outputDirectory: URL) throws {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        try write(workspaces, to: recordingsDirectory)
    }

    private static func write(_ workspaces: [RecordingLibraryWorkspace], to directory: URL) throws {
        let catalog = Catalog(version: currentVersion, workspaces: sorted(workspaces))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(filename)
        try encoder.encode(catalog).write(to: url, options: .atomic)
        try FileManager.default.restrictToOwner(url)
    }

    private static func sorted(_ workspaces: [RecordingLibraryWorkspace]) -> [RecordingLibraryWorkspace] {
        workspaces.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RecordingWorkspaceStoreError: LocalizedError {
    case emptyName
    case duplicateName
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: "Enter a workspace name."
        case .duplicateName: "A workspace with that name already exists."
        case .notFound: "This workspace no longer exists. Refresh the Library and try again."
        }
    }
}
