/// Local recordings dashboard: search saved sessions, review transcripts, and
/// play the audio associated with a library entry.
import AVFoundation
import Combine
import SwiftUI

struct RecordingLibraryWindow: View {
    let outputDirectory: URL
    let jobs: [PipelineJob]
    let onOpenTranscript: (URL) -> Void
    let onOpenAssistant: (RecordingLibraryItem, URL) -> Void
    let onOpenProtocolsFolder: () -> Void
    let onImportMedia: () -> Void
    let onTranscribe: (String, [URL]) -> Void

    @State private var recordings: [RecordingLibraryItem] = []
    @State private var workspaces: [RecordingLibraryWorkspace] = []
    @State private var selectedID: String?
    @State private var searchText = ""
    @State private var workspaceFilter = WorkspaceLibraryFilter.all
    @State private var sourceFilter = RecordingSourceFilter.all
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var activeReloadID: UUID?
    @State private var transcriptSearchIndex: [String: String] = [:]
    @State private var itemPendingDelete: RecordingLibraryItem?
    @State private var isShowingDeleteConfirmation = false
    @State private var workspaceEditor: WorkspaceEditorMode?
    @State private var workspacePendingDelete: RecordingLibraryWorkspace?
    @State private var isShowingWorkspaceDeleteConfirmation = false
    @State private var deletedEntryIDs: Set<String> = []

    private var entries: [RecordingLibraryItem] {
        var combined = recordings
        for job in jobs {
            let stableID = job.libraryRecordingID ?? job.namingSlug
            let jobEntryID = stableID ?? "job-\(job.id.uuidString)"
            guard !deletedEntryIDs.contains(jobEntryID) else { continue }
            if let index = combined.firstIndex(where: { $0.id == stableID }) {
                combined[index] = combined[index].reflecting(job)
            } else {
                combined.append(.inFlight(job))
            }
        }
        return combined.sorted { $0.recordedAt > $1.recordedAt }
    }

    private var filteredEntries: [RecordingLibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { item in
            let workspaceMatches: Bool
            switch workspaceFilter {
            case .all: workspaceMatches = true
            case .unassigned: workspaceMatches = item.workspaceID == nil
            case let .workspace(id): workspaceMatches = item.workspaceID == id
            }
            guard workspaceMatches, sourceFilter.matches(item.recordingSource) else { return false }
            guard !query.isEmpty else { return true }
            let metadata = [item.title, item.appName ?? "", item.participants.joined(separator: " "),
                            workspaceName(for: item.workspaceID) ?? "", item.statusLabel]
                .joined(separator: " ").lowercased()
            return metadata.contains(query) || (transcriptSearchIndex[item.id] ?? "").contains(query)
        }
    }

    private var selectedEntry: RecordingLibraryItem? {
        guard let selectedID else { return nil }
        return filteredEntries.first { $0.id == selectedID }
    }

    private var reloadKey: String {
        let jobKey = jobs.map { job in
            [job.id.uuidString, job.state.rawValue, job.libraryRecordingID ?? "", job.namingSlug ?? "", job.transcriptPath?.path ?? "", job.liveTranscriptPath?.path ?? ""]
                .joined(separator: ":")
        }.joined(separator: "|")
        return "\(outputDirectory.path)|\(jobKey)"
    }

    private func isTranscribing(_ item: RecordingLibraryItem) -> Bool {
        let sourcePaths = Set(item.transcriptionURLs(outputDirectory: outputDirectory).map {
            $0.standardizedFileURL.path
        })
        return jobs.contains { job in
            guard !job.state.isTerminal else { return false }
            return [job.mixPath, job.appPath, job.micPath].compactMap(\.self).contains {
                sourcePaths.contains($0.standardizedFileURL.path)
            } || job.libraryRecordingID == item.id || job.namingSlug == item.id
        }
    }

    var body: some View {
        NavigationSplitView {
            libraryList
                .navigationTitle("Library")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Import Audio/Video…", systemImage: "tray.and.arrow.down") {
                            onImportMedia()
                        }
                        .help("Import an existing audio or video recording")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open Protocols Folder", systemImage: "folder") {
                            onOpenProtocolsFolder()
                        }
                        .help("Open the folder containing transcripts and meeting notes")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Workspace", systemImage: "folder.badge.plus") {
                            workspaceEditor = .create
                        }
                        .help("Create a workspace to organize recordings")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await reload() }
                        }
                        .disabled(isLoading)
                        .help("Refresh the Library")
                    }
                }
        } detail: {
            if let selectedEntry {
                RecordingLibraryDetail(
                    item: selectedEntry,
                    outputDirectory: outputDirectory,
                    workspaces: workspaces,
                    onOpenTranscript: onOpenTranscript,
                    onOpenAssistant: { onOpenAssistant(selectedEntry, outputDirectory) },
                    onTranscribe: onTranscribe,
                    isTranscribing: isTranscribing(selectedEntry),
                    onWorkspaceChanged: { id in updateWorkspace(for: selectedEntry, to: id) },
                    onTitleChanged: { title in updateTitle(for: selectedEntry, to: title) },
                    onEditedAudioSaved: { edits, mode in saveEditedAudio(edits, mode: mode, for: selectedEntry) },
                    onRequestDelete: {
                        itemPendingDelete = selectedEntry
                        isShowingDeleteConfirmation = true
                    },
                )
                .id(selectedEntry.id)
            } else if isLoading {
                ProgressView("Loading recordings…")
            } else if let loadError {
                ContentUnavailableView(
                    "Library Unavailable",
                    systemImage: "externaldrive",
                    description: Text(loadError),
                )
            } else {
                ContentUnavailableView(
                    "Select a Recording",
                    systemImage: "waveform",
                    description: Text("Choose a recording to view its transcript and audio."),
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task(id: reloadKey) { await reload() }
        .confirmationDialog(
            "Delete recording and related files?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Delete Recording", role: .destructive) {
                guard let item = itemPendingDelete else { return }
                delete(item)
                itemPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { itemPendingDelete = nil }
        } message: {
            if let itemPendingDelete {
                Text("This permanently deletes Sawti’s saved audio, transcripts, meeting notes, transcript edits and highlights, bookmarks, and Library metadata for “\(itemPendingDelete.title)”. The original file you imported from elsewhere is left untouched.")
            }
        }
        .confirmationDialog(
            "Delete Workspace?",
            isPresented: $isShowingWorkspaceDeleteConfirmation,
            titleVisibility: .visible,
        ) {
            Button("Delete Workspace", role: .destructive) { deletePendingWorkspace() }
            Button("Cancel", role: .cancel) { workspacePendingDelete = nil }
        } message: {
            if let workspacePendingDelete {
                Text("“\(workspacePendingDelete.name)” will be removed. Its recordings and attached transcripts will remain in the Library as unassigned.")
            }
        }
        .sheet(item: $workspaceEditor) { mode in
            RecordingWorkspaceEditorSheet(
                title: mode.title,
                initialName: mode.initialName,
                saveTitle: mode.saveTitle,
            ) { name in
                saveWorkspace(name, for: mode)
            }
            .frame(width: 390, height: 190)
        }
        .onChange(of: searchText) { _, _ in
            if !filteredEntries.contains(where: { $0.id == selectedID }) {
                selectedID = filteredEntries.first?.id
            }
        }
        .onChange(of: workspaceFilter) { _, _ in
            if !filteredEntries.contains(where: { $0.id == selectedID }) {
                selectedID = filteredEntries.first?.id
            }
        }
        .onChange(of: sourceFilter) { _, _ in
            if !filteredEntries.contains(where: { $0.id == selectedID }) {
                selectedID = filteredEntries.first?.id
            }
        }
    }

    private var libraryList: some View {
        VStack(spacing: 0) {
            TextField("Search recordings and transcripts", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            Picker("Type", selection: $sourceFilter) {
                ForEach(RecordingSourceFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .padding([.horizontal, .bottom], 8)

            workspaceNavigation

            Divider()

            HStack {
                Text("Recordings")
                    .font(.headline)
                Spacer()
                Text("\(filteredEntries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if isLoading, entries.isEmpty {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    unavailableTitle,
                    systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(unavailableDescription),
                )
            } else {
                List(selection: $selectedID) {
                    ForEach(filteredEntries) { item in
                        RecordingLibraryRow(item: item, workspaceName: workspaceName(for: item.workspaceID))
                            .tag(Optional(item.id))
                    }
                }
                .listStyle(.sidebar)
            }

            if let loadError {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding([.horizontal, .bottom], 12)
            }
        }
        .frame(minWidth: 250, idealWidth: 300)
    }

    private var workspaceNavigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            workspaceNavigationRow("All Recordings", symbol: "waveform", filter: .all)
            workspaceNavigationRow("Unassigned", symbol: "tray", filter: .unassigned)
            HStack {
                Text("Workspaces")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    workspaceEditor = .create
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Create a workspace")
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)

            if workspaces.isEmpty {
                Text("Create a workspace to organize recordings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 5)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 1) {
                        ForEach(workspaces) { workspace in
                            Button {
                                workspaceFilter = .workspace(workspace.id)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .frame(width: 16)
                                    Text(workspace.name)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text("\(entries.filter { $0.workspaceID == workspace.id }.count)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(workspaceFilter == .workspace(workspace.id) ? Color.accentColor.opacity(0.16) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename Workspace…") { workspaceEditor = .rename(workspace) }
                                Button("Delete Workspace…", role: .destructive) {
                                    workspacePendingDelete = workspace
                                    isShowingWorkspaceDeleteConfirmation = true
                                }
                            }
                            .help("Open workspace: \(workspace.name)")
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var unavailableTitle: String {
        guard searchText.isEmpty else { return "No Matches" }
        if case .workspace = workspaceFilter { return "Workspace Is Empty" }
        if workspaceFilter == .unassigned { return "No Unassigned Recordings" }
        return "Library Is Empty"
    }

    private var unavailableDescription: String {
        guard searchText.isEmpty else {
            return "Try another title, participant, workspace, or phrase from a transcript."
        }
        if case .workspace = workspaceFilter {
            return "Assign a recording to this workspace from its detail view."
        }
        if workspaceFilter == .unassigned {
            return "Every recording is already assigned to a workspace."
        }
        return "Saved meetings, microphone and app recordings, and imported media will appear here. Use Import Audio/Video to add a file."
    }

    private func workspaceNavigationRow(
        _ title: String,
        symbol: String,
        filter: WorkspaceLibraryFilter,
    ) -> some View {
        Button {
            workspaceFilter = filter
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                Text(title)
                Spacer(minLength: 0)
                if filter == .all {
                    Text("\(entries.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(workspaceFilter == filter ? Color.accentColor.opacity(0.16) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Show \(title.lowercased())")
    }

    private func reload() async {
        let reloadID = UUID()
        activeReloadID = reloadID
        isLoading = true
        loadError = nil
        do {
            let directory = outputDirectory
            let scanned = try await Task.detached(priority: .utility) {
                try RecordingLibraryIndex.load(outputDirectory: directory)
            }.value
            guard activeReloadID == reloadID else { return }
            let loadedWorkspaces = try await Task.detached(priority: .utility) {
                try RecordingLibraryWorkspaceStore.load(
                    outputDirectory: directory,
                    legacyNames: scanned.compactMap(\.legacyCategory),
                )
            }.value
            let workspaceIDs = Dictionary(
                loadedWorkspaces.map { ($0.name.lowercased(), $0.id) },
                uniquingKeysWith: { first, _ in first },
            )
            let validWorkspaceIDs = Set(loadedWorkspaces.map(\.id))
            var loaded: [RecordingLibraryItem] = []
            for item in scanned {
                let existingWorkspaceID = item.workspaceID.flatMap { validWorkspaceIDs.contains($0) ? $0 : nil }
                let workspaceID = existingWorkspaceID
                    ?? item.legacyCategory.flatMap { workspaceIDs[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] }
                guard let workspaceID else {
                    if item.workspaceID != nil || item.legacyCategory != nil {
                        try RecordingLibraryIndex.assign(workspaceID: nil, to: item, outputDirectory: directory)
                        loaded.append(RecordingLibraryIndex.assigning(item, workspaceID: nil))
                    } else {
                        loaded.append(item)
                    }
                    continue
                }
                guard item.workspaceID == nil || item.legacyCategory != nil || existingWorkspaceID == nil else {
                    loaded.append(item)
                    continue
                }
                try RecordingLibraryIndex.assign(workspaceID: workspaceID, to: item, outputDirectory: directory)
                loaded.append(RecordingLibraryIndex.assigning(item, workspaceID: workspaceID))
            }
            workspaces = loadedWorkspaces
            recordings = loaded
            transcriptSearchIndex = await Task.detached(priority: .utility) {
                let openedScope = directory.startAccessingSecurityScopedResource()
                defer { if openedScope { directory.stopAccessingSecurityScopedResource() } }
                return Dictionary(uniqueKeysWithValues: loaded.map { item in
                    let urls = [item.transcriptURL, item.originalTranscriptURL].compactMap { $0 }
                    let text = urls.compactMap { url -> String? in
                        guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                        let corrected = TranscriptEditorDocumentStore.correctedTranscript(for: url)
                        return [corrected ?? source, source].joined(separator: "\n")
                    }.joined(separator: "\n")
                    return (item.id, text.lowercased())
                })
            }.value
            if selectedID == nil || !entries.contains(where: { $0.id == selectedID }) {
                selectedID = entries.first?.id
            }
        } catch {
            guard activeReloadID == reloadID else { return }
            loadError = "Sawti could not read the selected output folder. Check its access in Settings → Output."
        }
        guard activeReloadID == reloadID else { return }
        activeReloadID = nil
        isLoading = false
    }

    private func updateWorkspace(for item: RecordingLibraryItem, to workspaceID: UUID?) {
        do {
            try RecordingLibraryIndex.assign(workspaceID: workspaceID, to: item, outputDirectory: outputDirectory)
            Task { await reload() }
        } catch {
            loadError = "Sawti could not assign this recording to a workspace: \(error.localizedDescription)"
        }
    }

    private func updateTitle(for item: RecordingLibraryItem, to title: String) {
        do {
            try RecordingLibraryIndex.rename(item, to: title, outputDirectory: outputDirectory)
            Task { await reload() }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveEditedAudio(
        _ edits: [RecordingEditedAudio],
        mode: RecordingAudioEditSaveMode,
        for item: RecordingLibraryItem,
    ) -> Bool {
        do {
            let requests = try RecordingLibraryIndex.saveAudioEdits(
                edits,
                mode: mode,
                for: item,
                outputDirectory: outputDirectory,
            )
            for request in requests {
                onTranscribe(request.recordingID, [request.audioURL])
            }
            Task { await reload() }
            return true
        } catch {
            loadError = "Sawti saved the audio copy but could not add it to this recording: \(error.localizedDescription)"
            return false
        }
    }

    private func saveWorkspace(_ name: String, for mode: WorkspaceEditorMode) {
        do {
            switch mode {
            case .create:
                let workspace = try RecordingLibraryWorkspaceStore.create(name: name, outputDirectory: outputDirectory)
                workspaces.append(workspace)
                workspaceFilter = .workspace(workspace.id)
            case let .rename(existing):
                let workspace = try RecordingLibraryWorkspaceStore.rename(
                    existing,
                    to: name,
                    outputDirectory: outputDirectory,
                )
                workspaces = workspaces.map { $0.id == workspace.id ? workspace : $0 }
            }
            workspaceEditor = nil
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func deletePendingWorkspace() {
        guard let workspace = workspacePendingDelete else { return }
        do {
            for item in recordings where item.workspaceID == workspace.id {
                try RecordingLibraryIndex.assign(workspaceID: nil, to: item, outputDirectory: outputDirectory)
            }
            try RecordingLibraryWorkspaceStore.delete(workspace, outputDirectory: outputDirectory)
            recordings = recordings.map { item in
                item.workspaceID == workspace.id ? RecordingLibraryIndex.assigning(item, workspaceID: nil) : item
            }
            workspaces.removeAll { $0.id == workspace.id }
            if workspaceFilter == .workspace(workspace.id) { workspaceFilter = .all }
            workspacePendingDelete = nil
            loadError = nil
            Task { await reload() }
        } catch {
            loadError = "Could not remove this workspace: \(error.localizedDescription)"
        }
    }

    private func workspaceName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return workspaces.first(where: { $0.id == id })?.name
    }

    private func delete(_ item: RecordingLibraryItem) {
        let directory = outputDirectory
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try RecordingLibraryIndex.delete(item: item, outputDirectory: directory)
                }.value
                deletedEntryIDs.insert(item.id)
                if selectedID == item.id { selectedID = nil }
                loadError = nil
                await reload()
            } catch {
                loadError = error.localizedDescription
                await reload()
            }
        }
    }
}

private enum WorkspaceLibraryFilter: Hashable {
    case all
    case unassigned
    case workspace(UUID)
}

private enum WorkspaceEditorMode: Identifiable {
    case create
    case rename(RecordingLibraryWorkspace)

    var id: String {
        switch self {
        case .create: "create"
        case let .rename(workspace): "rename-\(workspace.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .create: "New Workspace"
        case .rename: "Rename Workspace"
        }
    }

    var initialName: String {
        switch self {
        case .create: ""
        case let .rename(workspace): workspace.name
        }
    }

    var saveTitle: String {
        switch self {
        case .create: "Create"
        case .rename: "Save"
        }
    }
}

private struct RecordingWorkspaceEditorSheet: View {
    let title: String
    let initialName: String
    let saveTitle: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, saveTitle: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.initialName = initialName
        self.saveTitle = saveTitle
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title2.weight(.semibold))
            TextField("Workspace name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saveTitle, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
    }
}

private enum RecordingSourceFilter: String, CaseIterable, Identifiable {
    case all
    case meeting
    case microphone
    case app
    case imported

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All Types"
        case .meeting: "Meetings"
        case .microphone: "Microphone"
        case .app: "App Recordings"
        case .imported: "Imported Files"
        }
    }

    func matches(_ source: RecordingSourceKind) -> Bool {
        self == .all || rawValue == source.rawValue
    }
}

private struct RecordingLibraryRow: View {
    let item: RecordingLibraryItem
    let workspaceName: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.transcriptURL == nil ? item.recordingSource.symbolName : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.recordedAt.formatted(date: .abbreviated, time: .shortened))
                    if let appName = item.appName, !appName.isEmpty {
                        Text("·")
                        Text(appName).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(item.recordingSource.label)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                Text(item.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(item.error == nil ? Color.secondary : Color.red)
                if let workspaceName, !workspaceName.isEmpty {
                    Text(workspaceName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
        .help(item.title)
    }
}

private struct RecordingLibraryDetail: View {
    let item: RecordingLibraryItem
    let outputDirectory: URL
    let workspaces: [RecordingLibraryWorkspace]
    let onOpenTranscript: (URL) -> Void
    let onOpenAssistant: () -> Void
    let onTranscribe: (String, [URL]) -> Void
    let isTranscribing: Bool
    let onWorkspaceChanged: (UUID?) -> Void
    let onTitleChanged: (String) -> Void
    let onEditedAudioSaved: ([RecordingEditedAudio], RecordingAudioEditSaveMode) -> Bool
    let onRequestDelete: () -> Void

    @StateObject private var playback = RecordingAudioPlayback()
    @State private var transcriptText: String?
    @State private var transcriptLoadFailed = false
    @State private var titleDraft = ""
    @State private var isShowingAudioEditor = false
    @State private var isOriginalAudioExpanded = false

    private var transcriptionButtonTitle: String {
        if isTranscribing { return "Processing…" }
        return item.transcriptURL == nil ? "Transcribe" : "Transcribe Again"
    }

    private var canDelete: Bool {
        !isTranscribing && !item.id.hasPrefix("job-")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcriptBody
        }
        .task(id: item.id) {
            titleDraft = item.title
            await loadTranscript()
        }
        .onChange(of: item.title) { _, newValue in titleDraft = newValue }
        .sheet(isPresented: $isShowingAudioEditor) {
            if let audioURL = item.audioURL {
                RecordingAudioEditorSheet(
                    item: item,
                    sourceURL: audioURL,
                    outputDirectory: outputDirectory,
                    onSave: onEditedAudioSaved,
                )
            }
        }
        .onDisappear { playback.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleEditor
            recordingMetadata
            participants
            workspacePicker
            primaryActions
            artifactActions
            playbackTimeline
            originalAudioSection
            editedAudioSection
            bookmarksSection
            recordingStatus
        }
        .padding(20)
    }

    private var titleEditor: some View {
        HStack(spacing: 8) {
            TextField("Recording title", text: $titleDraft)
                .font(.title2.weight(.semibold))
                .textFieldStyle(.plain)
                .onSubmit(saveTitle)
                .help("Rename this recording")
            Button("Save Title", systemImage: "checkmark", action: saveTitle)
                .disabled(!canSaveRecording || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || titleDraft == item.title)
                .help("Save the recording title")
        }
    }

    private var recordingMetadata: some View {
        HStack(spacing: 12) {
            Label(item.recordingSource.label, systemImage: item.recordingSource.symbolName)
            Label(item.recordedAt.formatted(date: .complete, time: .shortened), systemImage: "calendar")
            if let appName = item.appName, !appName.isEmpty {
                Label(appName, systemImage: "app")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var participants: some View {
        if !item.participants.isEmpty {
            Text("Participants: \(item.participants.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var workspacePicker: some View {
        Picker("Workspace", selection: Binding(
            get: { item.workspaceID },
            set: { onWorkspaceChanged($0) },
        )) {
            Text("Unassigned").tag(nil as UUID?)
            ForEach(workspaces) { workspace in
                Text(workspace.name).tag(workspace.id as UUID?)
            }
        }
        .frame(maxWidth: 330)
        .disabled(!canSaveRecording)
        .help("Choose the workspace for this recording and its attached materials")
    }

    @ViewBuilder private var primaryActions: some View {
        HStack(spacing: 8) {
            if let audioURL = item.audioURL {
                Button {
                    onOpenAssistant()
                } label: {
                    Label(
                        item.assistantConversationID == nil ? "Ask Assistant" : "Continue Assistant",
                        systemImage: "sparkles",
                    )
                }
                .help("Ask questions about this recording and continue its saved assistant conversation")

                Button {
                    let urls = item.transcriptionURLs(outputDirectory: outputDirectory)
                    if !urls.isEmpty { onTranscribe(item.id, urls) }
                } label: {
                    Label(transcriptionButtonTitle, systemImage: "waveform")
                }
                .disabled(isTranscribing)
                .help("Create or refresh this recording’s transcript")

                Button {
                    if playback.isPlaying, playback.playingURL == audioURL {
                        playback.stop()
                    } else {
                        playback.play(audioURL, outputDirectory: outputDirectory)
                    }
                } label: {
                    let isPlayingAudio = playback.isPlaying && playback.playingURL == audioURL
                    Label(isPlayingAudio ? "Stop Audio" : "Play Recording", systemImage: isPlayingAudio ? "stop.fill" : "play.fill")
                }
                .help("Play the current version of this recording")

                Button("Edit Audio…", systemImage: "scissors") {
                    isShowingAudioEditor = true
                }
                .help("Trim the start or end, or split a copy into two clips")
            }
        }
        .buttonStyle(.bordered)
    }

    private var artifactActions: some View {
        HStack(spacing: 8) {
            if let transcriptURL = item.transcriptURL {
                Button("Open Transcript", systemImage: "arrow.up.right.square") {
                    onOpenTranscript(transcriptURL)
                }
                .help("Open the transcript editor")
            }
            if let liveTranscriptURL = item.liveTranscriptURL {
                Button("Open Live Draft", systemImage: "text.bubble") {
                    onOpenTranscript(liveTranscriptURL)
                }
                .help("Review the live draft captured during the meeting; its timestamps are approximate and the finalized transcript is the polished version")
            }
            if let protocolURL = item.protocolURL {
                Button("Open Meeting Notes", systemImage: "doc.text") {
                    onOpenTranscript(protocolURL)
                }
                .help("Open the generated meeting notes")
            }
            if let originalURL = item.originalTranscriptURL {
                Button("Original ASR", systemImage: "text.alignleft") {
                    onOpenTranscript(originalURL)
                }
                .help("View the original speech recognition text")
            }
            Button(role: .destructive, action: onRequestDelete) {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!canDelete)
            .help(canDelete ? "Delete this recording and its Sawti files" : "Wait for processing to finish before deleting")
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var originalAudioSection: some View {
        if item.originalAudioURL != nil || item.originalTranscriptVersionURL != nil
            || item.originalProtocolURL != nil {
            DisclosureGroup("See Original Audio", isExpanded: $isOriginalAudioExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let originalAudioURL = item.originalAudioURL {
                        Button {
                            if playback.isPlaying, playback.playingURL == originalAudioURL {
                                playback.stop()
                            } else {
                                playback.play(originalAudioURL, outputDirectory: outputDirectory)
                            }
                        } label: {
                            let isPlayingOriginal = playback.isPlaying && playback.playingURL == originalAudioURL
                            Label(
                                isPlayingOriginal ? "Stop Original Audio" : "Play Original Audio",
                                systemImage: isPlayingOriginal ? "stop.fill" : "play.fill",
                            )
                        }
                        .buttonStyle(.link)
                    }
                    if let transcriptURL = item.originalTranscriptVersionURL {
                        Button("Open Original Transcript", systemImage: "doc.text") {
                            onOpenTranscript(transcriptURL)
                        }
                        .buttonStyle(.link)
                    }
                    if let protocolURL = item.originalProtocolURL {
                        Button("Open Original Notes", systemImage: "doc.richtext") {
                            onOpenTranscript(protocolURL)
                        }
                        .buttonStyle(.link)
                    }
                    if let rawTranscriptURL = item.originalTranscriptURL {
                        Button("Open Original ASR Transcript", systemImage: "text.alignleft") {
                            onOpenTranscript(rawTranscriptURL)
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 6)
            }
            .help("Review audio, transcript, and notes from before the first replacement edit")
        }
    }

    @ViewBuilder private var playbackTimeline: some View {
        if playback.duration > 0 {
            HStack(spacing: 10) {
                Text(playback.currentTime.formatted(.number.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
                Slider(
                    value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                    in: 0...max(1, playback.duration),
                )
                Text(playback.duration.formatted(.number.precision(.fractionLength(0))))
                    .font(.caption.monospacedDigit())
            }
            .frame(maxWidth: 440)
        }
    }

    @ViewBuilder private var editedAudioSection: some View {
        if !item.editedAudio.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Edited Audio Copies").font(.headline)
                ForEach(item.editedAudio) { edit in
                    editedAudioRow(edit)
                }
            }
        }
    }

    private func editedAudioRow(_ edit: RecordingEditedAudio) -> some View {
        let url = outputDirectory
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(edit.filename)
        return HStack(spacing: 10) {
            Button {
                if playback.isPlaying, playback.playingURL == url {
                    playback.stop()
                } else {
                    playback.play(url, outputDirectory: outputDirectory)
                }
            } label: {
                let isPlayingCopy = playback.isPlaying && playback.playingURL == url
                Label(edit.title, systemImage: isPlayingCopy ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.link)
            .help("Play this edited audio copy")
            Text("\(edit.startOffset.formatted(.number.precision(.fractionLength(0))))–\(edit.endOffset.formatted(.number.precision(.fractionLength(0)))) sec · \(edit.kind == .trimmed ? "Trimmed" : "Split part")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var bookmarksSection: some View {
        if !item.bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bookmarks").font(.headline)
                ForEach(item.bookmarks.sorted { $0.offset < $1.offset }) { bookmark in
                    Button {
                        guard let audioURL = item.audioURL else { return }
                        playback.play(audioURL, outputDirectory: outputDirectory, at: bookmark.offset)
                    } label: {
                        Label("\(bookmark.offset.formatted(.number.precision(.fractionLength(0))))s · \(bookmark.title)", systemImage: "bookmark.fill")
                    }
                    .buttonStyle(.link)
                    .help("Play from this bookmark")
                }
            }
        }
    }

    private var recordingStatus: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(item.error == nil ? Color.accentColor : Color.red)
                .frame(width: 7, height: 7)
            Text(item.statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = item.error, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
            if let error = playback.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }

    private var canSaveRecording: Bool {
        !item.id.hasPrefix("job-")
    }

    private func saveTitle() {
        guard canSaveRecording else { return }
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != item.title else { return }
        onTitleChanged(title)
    }

    @ViewBuilder private var transcriptBody: some View {
        if transcriptLoadFailed {
            ContentUnavailableView(
                "Transcript Unavailable",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Sawti could not read this transcript file."),
            )
        } else if let transcriptText {
            ScrollView {
                Text(transcriptText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
        } else if item.transcriptURL == nil {
            ContentUnavailableView(
                "No Transcript",
                systemImage: "waveform",
                description: Text("This recording was saved without transcription."),
            )
        } else {
            ProgressView("Loading transcript…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func loadTranscript() async {
        guard let transcriptURL = item.transcriptURL else {
            transcriptText = nil
            transcriptLoadFailed = false
            return
        }
        let directory = outputDirectory
        let content = await Task.detached(priority: .utility) { () -> String? in
            let openedScope = directory.startAccessingSecurityScopedResource()
            defer {
                if openedScope { directory.stopAccessingSecurityScopedResource() }
            }
            guard let source = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
            return TranscriptEditorDocumentStore.correctedTranscript(for: transcriptURL) ?? source
        }.value
        transcriptText = content
        transcriptLoadFailed = content == nil
    }
}

@MainActor
final class RecordingAudioPlayback: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var playingURL: URL?
    @Published private(set) var error: String?
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var scopedURL: URL?
    private var finishTask: Task<Void, Never>?

    func play(_ audioURL: URL, outputDirectory: URL, at offset: TimeInterval = 0) {
        stop()
        error = nil
        let accessRoot = Self.isInside(audioURL, directory: outputDirectory) ? outputDirectory : audioURL
        let openedScope = accessRoot.startAccessingSecurityScopedResource()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: audioURL)
            newPlayer.currentTime = min(max(0, offset), newPlayer.duration)
            guard newPlayer.play() else {
                if openedScope { accessRoot.stopAccessingSecurityScopedResource() }
                error = "Sawti could not start audio playback."
                return
            }
            player = newPlayer
            playingURL = audioURL
            duration = newPlayer.duration
            currentTime = newPlayer.currentTime
            scopedURL = openedScope ? accessRoot : nil
            isPlaying = true
            finishTask = Task { [weak self] in
                while !Task.isCancelled, newPlayer.isPlaying {
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    self?.currentTime = newPlayer.currentTime
                }
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            if openedScope { accessRoot.stopAccessingSecurityScopedResource() }
            self.error = "Sawti could not open this audio file."
        }
    }

    func stop() {
        finishTask?.cancel()
        finishTask = nil
        player?.stop()
        player = nil
        playingURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    private static func isInside(_ file: URL, directory: URL) -> Bool {
        let filePath = file.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let directoryPrefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath == directoryPath || filePath.hasPrefix(directoryPrefix)
    }
}
