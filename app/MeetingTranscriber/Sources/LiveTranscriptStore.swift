import Foundation

/// Persists the in-meeting recognition draft beside the finalized transcript.
/// The live draft is retained as its own version because the post-meeting ASR
/// pass may correct words and speaker labels rather than editing live output.
enum LiveTranscriptStore {
    static let filenameSuffix = "_live.txt"

    @discardableResult
    static func save(_ text: String, basename: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(basename)\(filenameSuffix)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.restrictToOwner(url)
        return url
    }
}
