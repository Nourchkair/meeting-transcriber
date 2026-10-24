import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Runs both installed ASR engines against the same local recording and
/// reference text, sequentially so the comparison does not load both models at
/// once on an 8 GB machine.
struct EngineComparisonView: View {
    @Bindable var settings: AppSettings
    let whisperKitEngine: WhisperKitEngine
    let parakeetEngine: ParakeetEngine

    @State private var audioURL: URL?
    @State private var referenceURL: URL?
    @State private var referenceText = ""
    @State private var results: [EngineComparisonResult] = []
    @State private var isRunning = false
    @State private var message: String?

    var body: some View {
        Section("Engine Comparison") {
            Text(
                "Compare both engines on the same recording and a human-corrected reference containing only spoken words (no timestamps or speaker names). Use the same supported language for both. Sawti unloads each model before loading the next, then reloads your selected engine. The first run may download a model.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button(audioURL?.lastPathComponent ?? "Choose Audio…") { chooseAudio() }
                Button(referenceURL?.lastPathComponent ?? "Choose Reference…") { chooseReference() }
            }

            Button("Compare WhisperKit and Parakeet", systemImage: "chart.bar.xaxis") {
                Task { await compareEngines() }
            }
            .disabled(isRunning || audioURL == nil || referenceText.isEmpty)

            if isRunning {
                ProgressView("Running engines sequentially…")
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            ForEach(results) { result in
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.engine).font(.headline)
                    Text(
                        "Load: \(result.loadSeconds.formatted(.number.precision(.fractionLength(1)))) s\(result.modelWasWarm ? " (loaded before test)" : "")  ·  Transcribe: \(result.transcriptionSeconds.formatted(.number.precision(.fractionLength(1)))) s  ·  RTF: \(result.realTimeFactor.formatted(.number.precision(.fractionLength(2))))",
                    )
                    Text(
                        "WER \(result.wer.formatted(.percent.precision(.fractionLength(1))))  ·  CER \(result.cer.formatted(.percent.precision(.fractionLength(1))))  ·  Thermal state: \(result.thermalState)",
                    )
                    Text(result.transcript)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audioURL = url
    }

    private func chooseReference() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let openedScope = url.startAccessingSecurityScopedResource()
        defer { if openedScope { url.stopAccessingSecurityScopedResource() } }
        do {
            referenceText = try String(contentsOf: url, encoding: .utf8)
            referenceURL = url
            message = nil
        } catch {
            message = "Sawti could not read the reference transcript."
        }
    }

    @MainActor
    private func compareEngines() async {
        guard let audioURL, !referenceText.isEmpty else { return }
        isRunning = true
        message = nil
        results = []
        defer { isRunning = false }

        let whisperWasWarm = whisperKitEngine.modelState == .loaded
        let parakeetWasWarm = parakeetEngine.modelState == .loaded
        let restoreWhisper = settings.transcriptionEngine == .whisperKit
        whisperKitEngine.unloadModel()
        parakeetEngine.unloadModel()

        let openedScope = audioURL.startAccessingSecurityScopedResource()
        defer { if openedScope { audioURL.stopAccessingSecurityScopedResource() } }

        do {
            let audioDuration = try AVAudioPlayer(contentsOf: audioURL).duration
            let allowlist = settings.whisperLanguageAllowlist
            let whisperLanguageLabel = if let allowlist {
                allowlist.map { code in
                    PickerLanguages.whisperKit.first { $0.code == code }?.label ?? code
                }.joined(separator: ", ")
            } else {
                settings.whisperLanguage.isEmpty ? "auto" : settings.whisperLanguage
            }
            let result = try await compare(
                name: "WhisperKit · \(settings.whisperKitModel) · \(whisperLanguageLabel)",
                engine: whisperKitEngine,
                wasWarm: whisperWasWarm,
                audioURL: audioURL,
                audioDuration: audioDuration,
                language: settings.whisperLanguage.isEmpty ? nil : settings.whisperLanguage,
                languageAllowlist: allowlist,
            )
            results.append(result)
            whisperKitEngine.unloadModel()

            let parakeet = try await compare(
                name: "Parakeet TDT v3 · \(settings.parakeetLanguage.isEmpty ? "auto" : settings.parakeetLanguage)",
                engine: parakeetEngine,
                wasWarm: parakeetWasWarm,
                audioURL: audioURL,
                audioDuration: audioDuration,
                language: settings.parakeetLanguage.isEmpty ? nil : settings.parakeetLanguage,
                languageAllowlist: nil,
            )
            results.append(parakeet)
            message = "Load time is an unload/reload in this Sawti process; first-use downloads and clean-launch startup are not isolated. Run the same audio/reference several times on the M2/8 GB and compare WER, CER, and RTF."
        } catch {
            message = "Engine comparison stopped: \(error.localizedDescription)"
        }

        whisperKitEngine.unloadModel()
        parakeetEngine.unloadModel()
        if restoreWhisper {
            await whisperKitEngine.loadModel()
        } else {
            await parakeetEngine.loadModel()
        }
    }

    @MainActor
    private func compare(
        name: String,
        engine: any TranscribingEngine,
        wasWarm: Bool,
        audioURL: URL,
        audioDuration: TimeInterval,
        language: String?,
        languageAllowlist: [String]?,
    ) async throws -> EngineComparisonResult {
        if let whisper = engine as? WhisperKitEngine {
            whisper.applyModelVariant(settings.whisperKitModel)
            whisper.languageAllowlist = languageAllowlist
            whisper.language = languageAllowlist.map { $0.count == 1 ? $0[0] : nil } ?? language
            whisper.customVocabularyPath = settings.customVocabularyPath
            whisper.customVocabularyBookmark = settings.customVocabularyBookmark
            whisper.vocabularyPromptEnabled = settings.whisperKitVocabularyPromptEnabled
        } else if let parakeet = engine as? ParakeetEngine {
            parakeet.language = language
            parakeet.customVocabularyPath = settings.customVocabularyPath
            parakeet.customVocabularyBookmark = settings.customVocabularyBookmark
        }

        let loadStart = ContinuousClock.now
        await engine.loadModel()
        let loadSeconds = seconds(from: loadStart)
        guard engine.modelState == .loaded else {
            throw EngineComparisonError.modelUnavailable(name)
        }

        let transcriptionStart = ContinuousClock.now
        let segments = try await engine.transcribeSegments(audioPath: audioURL)
        let transcriptionSeconds = seconds(from: transcriptionStart)
        let transcript = segments.map(\.text).joined(separator: " ")
        return EngineComparisonResult(
            engine: name,
            loadSeconds: loadSeconds,
            transcriptionSeconds: transcriptionSeconds,
            realTimeFactor: audioDuration > 0 ? transcriptionSeconds / audioDuration : 0,
            wer: Self.errorRate(reference: referenceText, hypothesis: transcript, characterLevel: false),
            cer: Self.errorRate(reference: referenceText, hypothesis: transcript, characterLevel: true),
            transcript: transcript,
            modelWasWarm: wasWarm,
            thermalState: String(describing: ProcessInfo.processInfo.thermalState),
        )
    }

    private func seconds(from start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now)
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private static func errorRate(reference: String, hypothesis: String, characterLevel: Bool) -> Double {
        let referenceUnits = units(reference, characterLevel: characterLevel)
        let hypothesisUnits = units(hypothesis, characterLevel: characterLevel)
        guard !referenceUnits.isEmpty else { return 0 }
        var previous = Array(0 ... hypothesisUnits.count)
        for (referenceIndex, referenceUnit) in referenceUnits.enumerated() {
            var current = [referenceIndex + 1] + Array(repeating: 0, count: hypothesisUnits.count)
            for (hypothesisIndex, hypothesisUnit) in hypothesisUnits.enumerated() {
                let substitution = previous[hypothesisIndex] + (referenceUnit == hypothesisUnit ? 0 : 1)
                current[hypothesisIndex + 1] = min(
                    min(previous[hypothesisIndex + 1] + 1, current[hypothesisIndex] + 1),
                    substitution,
                )
            }
            previous = current
        }
        return Double(previous[hypothesisUnits.count]) / Double(referenceUnits.count)
    }

    private static func units(_ text: String, characterLevel: Bool) -> [String] {
        if characterLevel {
            return text.lowercased().filter { !$0.isWhitespace }.map(String.init)
        }
        return text.lowercased().split(whereSeparator: \.isWhitespace).map { token in
            token.trimmingCharacters(in: .punctuationCharacters)
        }.filter { !$0.isEmpty }
    }
}

private struct EngineComparisonResult: Identifiable {
    let id = UUID()
    let engine: String
    let loadSeconds: Double
    let transcriptionSeconds: Double
    let realTimeFactor: Double
    let wer: Double
    let cer: Double
    let transcript: String
    let modelWasWarm: Bool
    let thermalState: String
}

private enum EngineComparisonError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        if case let .modelUnavailable(engine) = self {
            return "\(engine) did not load successfully."
        }
        return nil
    }
}
