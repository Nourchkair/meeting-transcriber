import Foundation

struct LiveAssistantMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let text: String
    var hasSavedScreenCapture: Bool

    init(id: UUID = UUID(), role: Role, text: String, hasSavedScreenCapture: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.hasSavedScreenCapture = hasSavedScreenCapture
    }
}

struct LiveAssistantConversationDocument: Codable, Sendable {
    let id: UUID
    var messages: [LiveAssistantMessage]
    var updatedAt: Date

    init(id: UUID, messages: [LiveAssistantMessage] = [], updatedAt: Date = .now) {
        self.id = id
        self.messages = messages
        self.updatedAt = updatedAt
    }
}

/// Stores assistant chats and explicitly saved screen captures under the
/// recording output folder. Conversation IDs are attached to Library metadata
/// or the record-only sidecar so deleting a recording can delete its chat too.
enum LiveAssistantConversationStore {
    private static let directoryName = "assistant-conversations"
    private static let documentSuffix = ".json"

    static func load(id: UUID, outputDirectory: URL) -> LiveAssistantConversationDocument? {
        withOutputScope(outputDirectory) {
            let file = conversationDirectory(outputDirectory: outputDirectory)
                .appendingPathComponent(id.uuidString.lowercased())
                .appendingPathComponent("conversation\(documentSuffix)")
            guard let data = try? Data(contentsOf: file) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(LiveAssistantConversationDocument.self, from: data)
        }
    }

    static func save(
        _ document: LiveAssistantConversationDocument,
        outputDirectory: URL,
    ) throws {
        try withOutputScope(outputDirectory) {
            let folder = conversationDirectory(outputDirectory: outputDirectory)
                .appendingPathComponent(document.id.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(document)
            let file = folder.appendingPathComponent("conversation\(documentSuffix)")
            try data.write(to: file, options: .atomic)
            try FileManager.default.restrictToOwner(file)
        }
    }

    static func saveScreenCapture(
        _ data: Data,
        conversationID: UUID,
        messageID: UUID,
        outputDirectory: URL,
    ) throws {
        try withOutputScope(outputDirectory) {
            let folder = conversationDirectory(outputDirectory: outputDirectory)
                .appendingPathComponent(conversationID.uuidString.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("\(messageID.uuidString.lowercased()).jpg")
            try data.write(to: file, options: .atomic)
            try FileManager.default.restrictToOwner(file)
        }
    }

    static func loadScreenCapture(
        conversationID: UUID,
        messageID: UUID,
        outputDirectory: URL,
    ) -> Data? {
        withOutputScope(outputDirectory) {
            let file = conversationDirectory(outputDirectory: outputDirectory)
                .appendingPathComponent(conversationID.uuidString.lowercased())
                .appendingPathComponent("\(messageID.uuidString.lowercased()).jpg")
            return try? Data(contentsOf: file)
        }
    }

    static func delete(id: UUID, outputDirectory: URL) throws {
        try withOutputScope(outputDirectory) {
            let folder = conversationDirectory(outputDirectory: outputDirectory)
                .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
            guard FileManager.default.fileExists(atPath: folder.path) else { return }
            try FileManager.default.removeItem(at: folder)
        }
    }

    private static func conversationDirectory(outputDirectory: URL) -> URL {
        outputDirectory
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func withOutputScope<T>(_ outputDirectory: URL, _ action: () throws -> T) rethrows -> T {
        let accessing = outputDirectory.startAccessingSecurityScopedResource()
        defer { if accessing { outputDirectory.stopAccessingSecurityScopedResource() } }
        return try action()
    }
}
