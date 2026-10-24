import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptViewerWindow: View {
    let fileURL: URL?
    let securityScopedRoot: URL?

    @State private var originalTranscript = ""
    @State private var transcript = ""
    @State private var highlightedLines: Set<Int> = []
    @State private var searchText = ""
    @State private var selectedMatchIndex = 0
    @State private var isEditing = false
    @State private var isLoaded = false
    @State private var isDirty = false
    @State private var loadError: String?
    @State private var saveMessage: String?
    @State private var exportError: String?
    @StateObject private var playback = RecordingAudioPlayback()

    private var lines: [TranscriptDisplayLine] {
        transcript.components(separatedBy: .newlines).enumerated().map { index, text in
            TranscriptDisplayLine(index: index, text: text)
        }
    }

    private var matchingLineIDs: [Int] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return lines.filter { $0.serializedText.localizedCaseInsensitiveContains(query) }.map(\.id)
    }

    private var audioURL: URL? {
        guard let fileURL else { return nil }
        let stem = Self.recordingStem(for: fileURL.deletingPathExtension().lastPathComponent)
        let proposedRoot = securityScopedRoot ?? fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = proposedRoot.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let root = filePath == rootPath || filePath.hasPrefix(rootPrefix)
            ? proposedRoot
            : fileURL.deletingLastPathComponent().deletingLastPathComponent()
        let recordingsDirectory = root.appendingPathComponent("recordings", isDirectory: true)
        let suffixes = ["_mix.wav", "_app.wav", "_mic.wav", "_16k.wav", "_app_16k.wav", "_mic_16k.wav"]
        return suffixes
            .map { recordingsDirectory.appendingPathComponent(stem + $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView(
                    "Transcript Unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(loadError),
                )
            } else {
                editor
            }
        }
        .task(id: fileURL) { await loadTranscript() }
        .onDisappear { playback.stop() }
        .frame(minWidth: 700, minHeight: 520)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if let saveMessage {
                Text(saveMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(lines) { line in
                            transcriptRow(line)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .onChange(of: searchText) { _, _ in
                    selectedMatchIndex = 0
                    if let first = matchingLineIDs.first { proxy.scrollTo(first, anchor: .center) }
                }
                .onChange(of: selectedMatchIndex) { _, index in
                    guard matchingLineIDs.indices.contains(index) else { return }
                    proxy.scrollTo(matchingLineIDs[index], anchor: .center)
                }
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isEditing ? "Done Editing" : "Edit") { isEditing.toggle() }
                            .disabled(!isLoaded)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Save Corrections", systemImage: "square.and.arrow.down") {
                            saveEditorDocument()
                        }
                        .disabled(!isLoaded || !hasUnsavedChanges)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Export Copy…", systemImage: "doc.badge.arrow.up") { exportCopy() }
                            .disabled(!isLoaded)
                    }
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this transcript", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Text("\(matchingLineIDs.count) matches")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Previous") { moveSearch(by: -1) }
                        .disabled(matchingLineIDs.isEmpty)
                    Button("Next") { moveSearch(by: 1) }
                        .disabled(matchingLineIDs.isEmpty)
                }
            }
            .padding(9)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if let audioURL {
                HStack(spacing: 10) {
                    Button {
                        if playback.isPlaying {
                            playback.stop()
                        } else {
                            playback.play(audioURL, outputDirectory: securityScopedRoot ?? audioURL.deletingLastPathComponent())
                        }
                    } label: {
                        Label(playback.isPlaying ? "Stop Playback" : "Play Recording", systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                    }
                    Text(playback.currentTime.formatted(.number.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                    Slider(
                        value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                        in: 0 ... max(1, playback.duration),
                    )
                    .disabled(playback.duration == 0)
                    Text(playback.duration.formatted(.number.precision(.fractionLength(0))))
                        .font(.caption.monospacedDigit())
                }
                .buttonStyle(.bordered)
            } else {
                Label("No matching recording audio was found; timestamps remain visible.", systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label("The original transcript stays unchanged. Corrections and highlights are saved in a separate local editor file.", systemImage: "lock.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    private func transcriptRow(_ line: TranscriptDisplayLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let timestamp = line.timestamp {
                Button(line.timestampLabel) {
                    guard let audioURL else { return }
                    playback.play(audioURL, outputDirectory: securityScopedRoot ?? audioURL.deletingLastPathComponent(), at: timestamp)
                }
                .buttonStyle(.link)
                .font(.caption.monospacedDigit())
                .disabled(audioURL == nil)
            }

            if isEditing {
                TextField("Transcript text", text: lineBinding(for: line))
                    .textFieldStyle(.plain)
                    .font(.body)
            } else {
                Text(line.displayText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                toggleHighlight(line.id)
            } label: {
                Image(systemName: highlightedLines.contains(line.id) ? "highlighter" : "highlighter")
                    .foregroundStyle(highlightedLines.contains(line.id) ? Color.orange : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(highlightedLines.contains(line.id) ? "Remove highlight" : "Highlight this line")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(rowColor(for: line), in: RoundedRectangle(cornerRadius: 5))
    }

    private func rowColor(for line: TranscriptDisplayLine) -> Color {
        if highlightedLines.contains(line.id) { return Color.yellow.opacity(0.25) }
        if matchingLineIDs.indices.contains(selectedMatchIndex), matchingLineIDs[selectedMatchIndex] == line.id {
            return Color.accentColor.opacity(0.24)
        }
        if matchingLineIDs.contains(line.id) { return Color.accentColor.opacity(0.12) }
        return .clear
    }

    private func lineBinding(for line: TranscriptDisplayLine) -> Binding<String> {
        Binding(
            get: { lines.indices.contains(line.id) ? lines[line.id].body : "" },
            set: { newValue in
                var updated = lines
                guard updated.indices.contains(line.id) else { return }
                updated[line.id].body = newValue
                transcript = updated.map(\.serializedText).joined(separator: "\n")
                isDirty = true
            },
        )
    }

    private var hasUnsavedChanges: Bool {
        isDirty
    }

    private func moveSearch(by delta: Int) {
        guard !matchingLineIDs.isEmpty else { return }
        selectedMatchIndex = (selectedMatchIndex + delta + matchingLineIDs.count) % matchingLineIDs.count
    }

    private func toggleHighlight(_ lineID: Int) {
        if highlightedLines.contains(lineID) {
            highlightedLines.remove(lineID)
        } else {
            highlightedLines.insert(lineID)
        }
        isDirty = true
        saveEditorDocument()
    }

    private func loadTranscript() async {
        guard let fileURL else {
            loadError = "No transcript was selected."
            return
        }
        let accessURL = accessRoot(for: fileURL)
        let loaded = await Task.detached(priority: .utility) { () -> (String?, TranscriptEditorDocument?) in
            let accessed = accessURL.startAccessingSecurityScopedResource()
            defer { if accessed { accessURL.stopAccessingSecurityScopedResource() } }
            let text = try? String(contentsOf: fileURL, encoding: .utf8)
            return (text, TranscriptEditorDocumentStore.read(for: fileURL))
        }.value
        guard let text = loaded.0 else {
            loadError = "Sawti could not read this transcript file."
            return
        }
        originalTranscript = text
        transcript = loaded.1?.correctedTranscript ?? text
        highlightedLines = Set(loaded.1?.highlightedLineIndices ?? [])
        isLoaded = true
        isDirty = false
        loadError = nil
    }

    private func saveEditorDocument() {
        guard let fileURL else { return }
        do {
            try TranscriptEditorDocumentStore.write(
                TranscriptEditorDocument(
                    correctedTranscript: transcript == originalTranscript ? nil : transcript,
                    highlightedLineIndices: Array(highlightedLines).sorted(),
                ),
                for: fileURL,
                accessRoot: accessRoot(for: fileURL),
            )
            isDirty = false
            saveMessage = "Corrections and highlights saved separately from the original."
        } catch {
            saveMessage = "Could not save editor changes. Check access to the transcript folder."
        }
    }

    private func exportCopy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = fileURL?.deletingPathExtension().lastPathComponent.appending("_edited.txt") ?? "transcript_edited.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try TranscriptExport.writeCopy(transcript, to: destination)
            exportError = nil
        } catch {
            exportError = "Could not export this transcript. Check the destination and try again."
        }
    }

    private func accessRoot(for fileURL: URL) -> URL {
        guard let securityScopedRoot else { return fileURL }
        let path = fileURL.standardizedFileURL.path
        let root = securityScopedRoot.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(prefix) ? securityScopedRoot : fileURL
    }

    private static func recordingStem(for stem: String) -> String {
        if let range = stem.range(of: #"_original(?:-\d+)?$"#, options: .regularExpression) {
            return String(stem[..<range.lowerBound])
        }
        return stem
    }
}

private struct TranscriptDisplayLine: Identifiable {
    let id: Int
    let prefix: String
    var body: String
    let timestamp: TimeInterval?

    init(index: Int, text: String) {
        id = index
        if let parsed = Self.parse(text) {
            prefix = parsed.prefix
            body = parsed.body
            timestamp = parsed.seconds
        } else {
            prefix = ""
            body = text
            timestamp = nil
        }
    }

    var timestampLabel: String {
        prefix
    }

    var displayText: String {
        prefix.isEmpty ? body : body
    }

    var serializedText: String {
        prefix.isEmpty ? body : "\(prefix) \(body)"
    }

    private static func parse(_ line: String) -> (prefix: String, body: String, seconds: TimeInterval)? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let stamp = String(line[line.index(after: line.startIndex) ..< close])
        let pieces = stamp.split(separator: ":").compactMap { Int($0) }
        guard pieces.count == 2 || pieces.count == 3 else { return nil }
        let seconds: Int = if pieces.count == 3 {
            pieces[0] * 3600 + pieces[1] * 60 + pieces[2]
        } else {
            pieces[0] * 60 + pieces[1]
        }
        let bodyStart = line.index(after: close)
        let content = String(line[bodyStart...]).trimmingCharacters(in: .whitespaces)
        return ("[\(stamp)]", content, TimeInterval(seconds))
    }
}

private struct TranscriptEditorDocument: Codable, Sendable {
    let correctedTranscript: String?
    let highlightedLineIndices: [Int]
}

enum TranscriptEditorDocumentStore {
    static func correctedTranscript(for transcriptURL: URL) -> String? {
        read(for: transcriptURL)?.correctedTranscript
    }

    fileprivate static func read(for transcriptURL: URL) -> TranscriptEditorDocument? {
        try? JSONDecoder().decode(TranscriptEditorDocument.self, from: Data(contentsOf: sidecarURL(for: transcriptURL)))
    }

    fileprivate static func write(_ document: TranscriptEditorDocument, for transcriptURL: URL, accessRoot: URL) throws {
        let accessed = accessRoot.startAccessingSecurityScopedResource()
        defer { if accessed { accessRoot.stopAccessingSecurityScopedResource() } }
        let url = sidecarURL(for: transcriptURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
        try FileManager.default.restrictToOwner(url)
    }

    private static func sidecarURL(for transcriptURL: URL) -> URL {
        transcriptURL.deletingPathExtension().appendingPathExtension("editor.json")
    }
}
