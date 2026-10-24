/// Non-destructive audio trimming and splitting for a Library recording.
import AVFoundation
import SwiftUI

struct RecordingAudioEditorSheet: View {
    let item: RecordingLibraryItem
    let sourceURL: URL
    let outputDirectory: URL
    let onSave: ([RecordingEditedAudio], RecordingAudioEditSaveMode) -> Bool

    @Environment(\.dismiss) private var dismiss
    @StateObject private var preview = RecordingAudioEditorPreview()
    @State private var waveform: [Float] = []
    @State private var duration: TimeInterval = 0
    @State private var startOffset: TimeInterval = 0
    @State private var endOffset: TimeInterval = 0
    @State private var playhead: TimeInterval = 0
    @State private var zoomCenter: TimeInterval = 0
    @State private var zoomWindowDuration: TimeInterval = 12
    @State private var isPreparing = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var saveMode: RecordingAudioEditSaveMode = .replaceOriginal

    private var mainRange: ClosedRange<TimeInterval> {
        let visibleDuration = min(duration, zoomWindowDuration)
        let start = min(max(0, zoomCenter - visibleDuration / 2), max(0, duration - visibleDuration))
        return start ... (start + visibleDuration)
    }

    private var validTrim: Bool {
        startOffset >= 0 && endOffset <= duration && endOffset - startOffset >= 0.25
    }

    private var validSplit: Bool {
        validTrim && playhead > startOffset + 0.1 && playhead < endOffset - 0.1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading
            if isPreparing {
                ProgressView("Preparing waveform…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                editorContent
            }
        }
        .padding(22)
        .frame(minWidth: 900, minHeight: 650)
        .task { await loadAudio() }
        .onDisappear { preview.stop() }
        .onChange(of: preview.currentTime) { _, time in
            playhead = time
            zoomCenter = time
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Edit Recording Audio")
                .font(.title2.weight(.semibold))
            Text("Drag the handles to select audio. Sawti saves edits as copies and keeps the original unchanged.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            waveformSection
            rangeControls
            playbackControls
            saveModePicker
            if let message = preview.error ?? errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if isWorking {
                ProgressView("Creating edited audio…")
            }
            actionButtons
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var waveformSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Waveform")
                    .font(.headline)
                Spacer()
                Button("Zoom In", systemImage: "minus.magnifyingglass") {
                    zoomWindowDuration = max(3, zoomWindowDuration / 1.5)
                }
                .disabled(zoomWindowDuration <= 3)
                .help("Zoom in for more precise trimming")
                Text("\(Int(zoomWindowDuration)) sec view")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 78)
                Button("Zoom Out", systemImage: "plus.magnifyingglass") {
                    zoomWindowDuration = min(duration, zoomWindowDuration * 1.5)
                }
                .disabled(zoomWindowDuration >= duration)
                .help("Zoom out to see more of the recording")
            }

            AudioTrimTimeline(
                peaks: waveform,
                duration: duration,
                visibleRange: mainRange,
                viewportCenter: zoomCenter,
                viewportDuration: zoomWindowDuration,
                trimStart: startOffset,
                trimEnd: endOffset,
                playhead: playhead,
                isOverview: false,
                onSeek: seek,
                onMoveStart: moveStart,
                onMoveEnd: moveEnd,
                onMoveViewport: { zoomCenter = $0 },
            )
            .frame(height: 245)
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            HStack {
                Text(clock(mainRange.lowerBound))
                Spacer()
                Text(clock(mainRange.upperBound))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            AudioTrimTimeline(
                peaks: waveform,
                duration: duration,
                visibleRange: 0 ... duration,
                viewportCenter: zoomCenter,
                viewportDuration: zoomWindowDuration,
                trimStart: startOffset,
                trimEnd: endOffset,
                playhead: playhead,
                isOverview: true,
                onSeek: seek,
                onMoveStart: moveStart,
                onMoveEnd: moveEnd,
                onMoveViewport: { zoomCenter = $0 },
            )
            .frame(height: 62)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.quaternary, lineWidth: 1)
                    .allowsHitTesting(false)
            }

            HStack {
                Text("0:00")
                Spacer()
                Text(clock(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var rangeControls: some View {
        HStack(spacing: 18) {
            preciseTimeField(title: "Start", value: $startOffset)
            preciseTimeField(title: "End", value: $endOffset)
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(clock(max(0, endOffset - startOffset)))
                    .font(.body.monospacedDigit())
                    .frame(width: 100, alignment: .leading)
            }
            Spacer()
            Button("Set Start to Playhead") { moveStart(playhead) }
                .help("Set the selected audio start to the current time")
            Button("Set End to Playhead") { moveEnd(playhead) }
                .help("Set the selected audio end to the current time")
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 14) {
            Button("Back 15 Seconds", systemImage: "gobackward.15") {
                preview.skip(by: -15, start: startOffset, end: endOffset)
                seek(preview.currentTime)
            }
            .help("Move the playhead back 15 seconds")

            Button {
                preview.togglePlayback(
                    url: sourceURL,
                    outputDirectory: outputDirectory,
                    start: startOffset,
                    end: endOffset,
                )
            } label: {
                Label(preview.isPlaying ? "Pause Preview" : "Play Preview", systemImage: preview.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 118)
            }
            .keyboardShortcut(.space, modifiers: [])
            .help("Preview the selected audio")

            Button("Forward 15 Seconds", systemImage: "goforward.15") {
                preview.skip(by: 15, start: startOffset, end: endOffset)
                seek(preview.currentTime)
            }
            .help("Move the playhead forward 15 seconds")

            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(clock(playhead))
                    .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                Text("of \(clock(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }

    private var actionButtons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isWorking)
            Spacer()
            Button(
                saveMode == .replaceOriginal ? "Replace with Part 1" : "Save Both Separately",
                systemImage: "scissors",
            ) {
                Task { await splitAtPlayhead() }
            }
            .disabled(isWorking || !validSplit)
            .help(saveMode == .replaceOriginal
                ? "Use Part 1 as the recording and save Part 2 as a separate recording"
                : "Create two separate recordings from the selected range")
            Button(
                saveMode == .replaceOriginal ? "Replace Recording" : "Save as Separate Recording",
                systemImage: "waveform.badge.minus",
            ) {
                Task { await saveTrimmedCopy() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking || !validTrim || (startOffset <= 0 && endOffset >= duration))
            .help(saveMode == .replaceOriginal
                ? "Make this edited audio the default and transcribe it again"
                : "Create a new recording from only the selected range")
        }
        .buttonStyle(.bordered)
    }

    private var saveModePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("Save edited audio", selection: $saveMode) {
                ForEach(RecordingAudioEditSaveMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(saveMode == .replaceOriginal
                ? "The original audio and transcript stay available under See Original Audio."
                : "The current recording remains unchanged; each edited clip gets its own transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if saveMode == .replaceOriginal && validSplit {
                Text("For a split, Part 1 replaces the current recording and Part 2 becomes a separate recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func preciseTimeField(title: String, value: Binding<TimeInterval>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onSubmit { normalizeRange() }
                .help("Enter a precise time in seconds")
        }
    }

    private func loadAudio() async {
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        do {
            let audio = try await RecordingWaveformReader.load(url: sourceURL)
            waveform = audio.peaks
            duration = audio.duration
            endOffset = audio.duration
            playhead = 0
            zoomCenter = 0
            zoomWindowDuration = min(12, audio.duration)
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }

    private func seek(_ time: TimeInterval) {
        let clamped = min(max(0, time), duration)
        playhead = clamped
        zoomCenter = clamped
        preview.seek(to: clamped)
    }

    private func moveStart(_ time: TimeInterval) {
        startOffset = min(max(0, time), max(0, endOffset - 0.1))
    }

    private func moveEnd(_ time: TimeInterval) {
        endOffset = max(min(duration, time), min(duration, startOffset + 0.1))
    }

    private func normalizeRange() {
        startOffset = min(max(0, startOffset), max(0, duration - 0.1))
        endOffset = min(max(startOffset + 0.1, endOffset), duration)
    }

    private func saveTrimmedCopy() async {
        isWorking = true
        errorMessage = nil
        let editID = UUID()
        let filename = "\(item.id)_edit_\(editID.uuidString).m4a"
        let outputURL = outputDirectory
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(filename)
        let edit = RecordingEditedAudio(
            id: editID,
            title: "Trimmed Copy",
            filename: filename,
            kind: .trimmed,
            startOffset: startOffset,
            endOffset: endOffset,
        )

        do {
            try await export(start: startOffset, end: endOffset, to: outputURL)
            guard onSave([edit], saveMode) else {
                try? FileManager.default.removeItem(at: outputURL)
                throw RecordingAudioEditorError.couldNotSave
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func splitAtPlayhead() async {
        isWorking = true
        errorMessage = nil
        let firstID = UUID()
        let secondID = UUID()
        let firstName = "\(item.id)_edit_\(firstID.uuidString).m4a"
        let secondName = "\(item.id)_edit_\(secondID.uuidString).m4a"
        let recordingsDirectory = outputDirectory.appendingPathComponent("recordings", isDirectory: true)
        let firstURL = recordingsDirectory.appendingPathComponent(firstName)
        let secondURL = recordingsDirectory.appendingPathComponent(secondName)
        let first = RecordingEditedAudio(
            id: firstID,
            title: "Part 1",
            filename: firstName,
            kind: .splitPart,
            startOffset: startOffset,
            endOffset: playhead,
        )
        let second = RecordingEditedAudio(
            id: secondID,
            title: "Part 2",
            filename: secondName,
            kind: .splitPart,
            startOffset: playhead,
            endOffset: endOffset,
        )

        do {
            try await export(start: first.startOffset, end: first.endOffset, to: firstURL)
            try await export(start: second.startOffset, end: second.endOffset, to: secondURL)
            guard onSave([first, second], saveMode) else {
                throw RecordingAudioEditorError.couldNotSave
            }
            dismiss()
        } catch {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    private func export(start: TimeInterval, end: TimeInterval, to outputURL: URL) async throws {
        guard end > start else { throw RecordingAudioEditorError.invalidRange }
        let openedScope = outputDirectory.startAccessingSecurityScopedResource()
        defer { if openedScope { outputDirectory.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecordingAudioEditorError.exportUnavailable
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600),
        )

        let session = RecordingExportSessionBox(exporter)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.value.exportAsynchronously {
                switch session.value.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: RecordingAudioEditorError.cancelled)
                case .failed:
                    continuation.resume(throwing: session.value.error ?? RecordingAudioEditorError.exportFailed)
                default:
                    continuation.resume(throwing: RecordingAudioEditorError.exportFailed)
                }
            }
        }
        try FileManager.default.restrictToOwner(outputURL)
    }

    private func clock(_ time: TimeInterval) -> String {
        let hundredths = max(0, Int((time * 100).rounded()))
        let minutes = hundredths / 6000
        let seconds = (hundredths / 100) % 60
        let fraction = hundredths % 100
        return String(format: "%02d:%02d.%02d", minutes, seconds, fraction)
    }
}

private struct AudioTrimTimeline: View {
    let peaks: [Float]
    let duration: TimeInterval
    let visibleRange: ClosedRange<TimeInterval>
    let viewportCenter: TimeInterval
    let viewportDuration: TimeInterval
    let trimStart: TimeInterval
    let trimEnd: TimeInterval
    let playhead: TimeInterval
    let isOverview: Bool
    let onSeek: (TimeInterval) -> Void
    let onMoveStart: (TimeInterval) -> Void
    let onMoveEnd: (TimeInterval) -> Void
    let onMoveViewport: (TimeInterval) -> Void

    @State private var dragTarget: TimelineDragTarget?
    @State private var dragRange: ClosedRange<TimeInterval>?
    @State private var initialViewportStart: TimeInterval?

    private var shownRange: ClosedRange<TimeInterval> {
        dragRange ?? visibleRange
    }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawTimeline(context: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(width: geometry.size.width))
            .accessibilityElement()
            .accessibilityLabel(isOverview ? "Full recording waveform overview" : "Zoomed recording waveform")
            .accessibilityValue("Playhead at \(playhead.formatted(.number.precision(.fractionLength(1)))) seconds")
            .accessibilityAdjustableAction { direction in
                let step = max(0.01, (shownRange.upperBound - shownRange.lowerBound) / 100)
                switch direction {
                case .increment: onSeek(min(duration, playhead + step))
                case .decrement: onSeek(max(0, playhead - step))
                @unknown default: break
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func drawTimeline(context: inout GraphicsContext, size: CGSize) {
        var background = Path()
        background.addRoundedRect(in: CGRect(origin: .zero, size: size), cornerSize: CGSize(width: 9, height: 9))
        context.fill(background, with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.78)))
        drawSelection(in: &context, size: size)
        drawWaveform(in: &context, size: size)
        drawViewport(in: &context, size: size)
        drawMarkers(in: &context, size: size)
    }

    private func drawSelection(in context: inout GraphicsContext, size: CGSize) {
        let lower = max(trimStart, shownRange.lowerBound)
        let upper = min(trimEnd, shownRange.upperBound)
        guard upper > lower else { return }
        let rect = CGRect(
            x: xPosition(for: lower, width: size.width),
            y: 0,
            width: max(0, xPosition(for: upper, width: size.width) - xPosition(for: lower, width: size.width)),
            height: size.height,
        )
        context.fill(Path(rect), with: .color(.yellow.opacity(isOverview ? 0.22 : 0.15)))
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        guard !peaks.isEmpty, duration > 0 else { return }
        let startIndex = max(0, min(peaks.count - 1, Int(shownRange.lowerBound / duration * Double(peaks.count))))
        let endIndex = max(startIndex + 1, min(peaks.count, Int(ceil(shownRange.upperBound / duration * Double(peaks.count)))))
        let visibleCount = max(1, endIndex - startIndex)
        let barStep: CGFloat = isOverview ? 2.1 : 3.2
        let barCount = max(1, Int(size.width / barStep))
        let centerY = size.height / 2
        let maxHeight = size.height * (isOverview ? 0.68 : 0.72)
        let barWidth = max(1, barStep * 0.54)

        for bar in 0 ..< barCount {
            let first = startIndex + bar * visibleCount / barCount
            let after = max(first + 1, startIndex + (bar + 1) * visibleCount / barCount)
            let last = min(endIndex, after)
            var peak: Float = 0
            if first < peaks.count {
                for index in first ..< last where index < peaks.count {
                    peak = max(peak, peaks[index])
                }
            }
            let normalized = max(0.035, min(1, CGFloat(peak)))
            let height = max(2, normalized * maxHeight)
            let x = CGFloat(bar) * barStep + (barStep - barWidth) / 2
            let time = shownRange.lowerBound + (Double(bar) + 0.5) / Double(barCount)
                * (shownRange.upperBound - shownRange.lowerBound)
            let inSelection = time >= trimStart && time <= trimEnd
            let color = inSelection ? Color.primary.opacity(0.88) : Color.secondary.opacity(0.52)
            let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
        }
    }

    private func drawViewport(in context: inout GraphicsContext, size: CGSize) {
        guard isOverview, duration > 0 else { return }
        let start = max(0, viewportCenter - viewportDuration / 2)
        let end = min(duration, start + viewportDuration)
        let left = xPosition(for: start, width: size.width)
        let right = xPosition(for: end, width: size.width)
        let rect = CGRect(x: left, y: 1, width: max(2, right - left), height: size.height - 2)
        context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.blue), lineWidth: 2)
    }

    private func drawMarkers(in context: inout GraphicsContext, size: CGSize) {
        if trimStart >= shownRange.lowerBound, trimStart <= shownRange.upperBound {
            drawHandle(in: &context, x: xPosition(for: trimStart, width: size.width), size: size, color: .yellow)
        }
        if trimEnd >= shownRange.lowerBound, trimEnd <= shownRange.upperBound {
            drawHandle(in: &context, x: xPosition(for: trimEnd, width: size.width), size: size, color: .yellow)
        }
        if playhead >= shownRange.lowerBound, playhead <= shownRange.upperBound {
            let x = xPosition(for: playhead, width: size.width)
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: 0))
            marker.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(marker, with: .color(.blue), lineWidth: 2)
            let dot = CGRect(x: x - 4, y: 1, width: 8, height: 8)
            context.fill(Path(ellipseIn: dot), with: .color(.blue))
        }
    }

    private func drawHandle(in context: inout GraphicsContext, x: CGFloat, size: CGSize, color: Color) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(color), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: x - 4, y: 1, width: 8, height: 8)), with: .color(color))
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragTarget == nil {
                    dragTarget = target(at: value.startLocation.x, width: width)
                    dragRange = visibleRange
                    initialViewportStart = max(0, viewportCenter - viewportDuration / 2)
                }
                updateDrag(location: value.location.x, startLocation: value.startLocation.x, translation: value.translation.width, width: width)
            }
            .onEnded { _ in
                dragTarget = nil
                dragRange = nil
                initialViewportStart = nil
            }
    }

    private func target(at x: CGFloat, width: CGFloat) -> TimelineDragTarget {
        let range = visibleRange
        let startX = trimStart >= range.lowerBound && trimStart <= range.upperBound
            ? xPosition(for: trimStart, width: width) : nil
        let endX = trimEnd >= range.lowerBound && trimEnd <= range.upperBound
            ? xPosition(for: trimEnd, width: width) : nil
        if let startX, abs(startX - x) < 22 { return .start }
        if let endX, abs(endX - x) < 22 { return .end }

        if isOverview {
            let viewportStart = max(0, viewportCenter - viewportDuration / 2)
            let viewportEnd = min(duration, viewportStart + viewportDuration)
            if xPosition(for: viewportStart, width: width) <= x,
               x <= xPosition(for: viewportEnd, width: width) { return .viewport }
        }
        return .playhead
    }

    private func updateDrag(location: CGFloat, startLocation _: CGFloat, translation: CGFloat, width: CGFloat) {
        guard let dragTarget else { return }
        let range = dragRange ?? visibleRange
        let time = timeAt(location: location, width: width, in: range)
        switch dragTarget {
        case .start:
            onMoveStart(time)
        case .end:
            onMoveEnd(time)
        case .playhead:
            onSeek(time)
            if isOverview { onMoveViewport(time) }
        case .viewport:
            let original = initialViewportStart ?? max(0, viewportCenter - viewportDuration / 2)
            let offset = Double(translation / max(1, width)) * duration
            onMoveViewport(min(max(0, original + offset + viewportDuration / 2), duration))
        }
    }

    private func xPosition(for time: TimeInterval, width: CGFloat) -> CGFloat {
        let span = max(0.001, shownRange.upperBound - shownRange.lowerBound)
        return CGFloat((time - shownRange.lowerBound) / span) * width
    }

    private func timeAt(location: CGFloat, width: CGFloat, in range: ClosedRange<TimeInterval>) -> TimeInterval {
        let fraction = min(1, max(0, Double(location / max(1, width))))
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
}

private enum TimelineDragTarget {
    case start
    case end
    case playhead
    case viewport
}

@MainActor
private final class RecordingAudioEditorPreview: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var error: String?

    private var player: AVAudioPlayer?
    private var playerURL: URL?
    private var scopedURL: URL?
    private var updateTask: Task<Void, Never>?

    func togglePlayback(url: URL, outputDirectory: URL, start: TimeInterval, end: TimeInterval) {
        error = nil
        if isPlaying {
            player?.pause()
            updateTask?.cancel()
            updateTask = nil
            isPlaying = false
            return
        }

        if playerURL != url || player == nil {
            stop()
            do {
                let accessRoot = Self.isInside(url, directory: outputDirectory) ? outputDirectory : url
                let openedScope = accessRoot.startAccessingSecurityScopedResource()
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                player = newPlayer
                playerURL = url
                scopedURL = openedScope ? accessRoot : nil
            } catch {
                self.error = "Sawti could not preview this audio file."
                return
            }
        }

        guard let player else { return }
        if player.currentTime < start || player.currentTime >= end {
            player.currentTime = start
            currentTime = start
        }
        guard player.play() else {
            error = "Sawti could not start audio playback."
            return
        }
        isPlaying = true
        watchPlayback(until: end)
    }

    func seek(to time: TimeInterval) {
        currentTime = max(0, time)
        player?.currentTime = currentTime
    }

    func skip(by amount: TimeInterval, start: TimeInterval, end: TimeInterval) {
        seek(to: min(end, max(start, currentTime + amount)))
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        player?.stop()
        player = nil
        playerURL = nil
        isPlaying = false
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }
    }

    private func watchPlayback(until end: TimeInterval) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if player.currentTime >= end || !player.isPlaying {
                    player.pause()
                    player.currentTime = min(player.currentTime, end)
                    self.currentTime = player.currentTime
                    self.isPlaying = false
                    self.updateTask = nil
                    return
                }
            }
        }
    }

    private static func isInside(_ file: URL, directory: URL) -> Bool {
        let filePath = file.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath == directoryPath || filePath.hasPrefix(prefix)
    }
}

private struct RecordingWaveform: Sendable {
    let duration: TimeInterval
    let peaks: [Float]
}

private enum RecordingWaveformReader {
    static func load(url: URL) async throws -> RecordingWaveform {
        try await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw RecordingAudioEditorError.invalidDuration
            }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { throw RecordingAudioEditorError.noAudioTrack }
            return try readPeaks(asset: asset, track: track, duration: duration)
        }.value
    }

    private static func readPeaks(asset: AVAsset, track: AVAssetTrack, duration: TimeInterval) throws -> RecordingWaveform {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 8000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ],
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RecordingAudioEditorError.readerUnavailable }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? RecordingAudioEditorError.waveformFailed
        }

        let estimatedFrames = max(1, Int((duration * 8000).rounded()))
        let peakCount = min(500_000, max(64, Int((duration * 64).rounded(.up))))
        let framesPerPeak = max(1, Int(ceil(Double(estimatedFrames) / Double(peakCount))))
        var peaks = Array(repeating: Float.zero, count: peakCount)
        var frameIndex = 0

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var bytes = Array(repeating: UInt8.zero, count: byteCount)
            let copyStatus = bytes.withUnsafeMutableBytes { target in
                CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: target.baseAddress!.assumingMemoryBound(to: Int8.self),
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else { throw RecordingAudioEditorError.waveformFailed }

            bytes.withUnsafeBytes { rawBytes in
                let samples = rawBytes.bindMemory(to: Float.self)
                for sample in samples {
                    let peakIndex = min(peakCount - 1, frameIndex / framesPerPeak)
                    if sample.isFinite { peaks[peakIndex] = max(peaks[peakIndex], abs(sample)) }
                    frameIndex += 1
                }
            }
        }

        guard reader.status == .completed else {
            throw reader.error ?? RecordingAudioEditorError.waveformFailed
        }
        guard frameIndex > 0 else { throw RecordingAudioEditorError.noAudioTrack }
        let maximum = peaks.max() ?? 0
        if maximum > 0 {
            peaks = peaks.map { $0 / maximum }
        }
        return RecordingWaveform(duration: duration, peaks: peaks)
    }
}

/// AVFoundation calls the export completion on its export queue. The session
/// is only read after that callback signals completion.
private final class RecordingExportSessionBox: @unchecked Sendable {
    let value: AVAssetExportSession

    init(_ value: AVAssetExportSession) {
        self.value = value
    }
}

private enum RecordingAudioEditorError: LocalizedError {
    case invalidDuration
    case invalidRange
    case noAudioTrack
    case readerUnavailable
    case waveformFailed
    case exportUnavailable
    case exportFailed
    case cancelled
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .invalidDuration: "This recording has no usable audio duration."
        case .invalidRange: "Choose a valid audio range."
        case .noAudioTrack: "Sawti could not find an audio track in this file."
        case .readerUnavailable: "Sawti could not prepare the waveform reader for this file."
        case .waveformFailed: "Sawti could not read this recording’s waveform."
        case .exportUnavailable: "Sawti could not prepare an audio editor for this file."
        case .exportFailed: "Sawti could not export this audio copy."
        case .cancelled: "The audio export was cancelled."
        case .couldNotSave: "The edited copy was created, but Sawti could not attach it to the recording."
        }
    }
}
