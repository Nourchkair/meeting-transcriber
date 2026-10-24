import AppKit
import SwiftUI

struct LiveAssistantWindow: View {
    @Bindable var assistant: LiveAssistantController
    @Bindable var settings: AppSettings
    let isRecording: Bool

    @Environment(\.dismiss) private var dismiss
    @FocusState private var questionFocused: Bool
    @State private var saveCapturedScreenWithConversation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .frame(minWidth: 420, minHeight: 540)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Close Assistant", systemImage: "xmark") { dismiss() }
                    .help("Hide the assistant window")
            }
        }
        .onChange(of: assistant.activeConversationID) { _, _ in
            saveCapturedScreenWithConversation = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Live Assistant", systemImage: "sparkles")
                        .font(.title3.weight(.semibold))
                    Label(
                        isRecording ? "Meeting in progress" : "Ready for a meeting",
                        systemImage: isRecording ? "waveform" : "clock",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Toggle("Screen awareness during recording", isOn: $settings.continuousScreenAwarenessEnabled)
                    Divider()
                    Toggle("Hide Sawti from screen sharing", isOn: $settings.hideSawtiFromScreenSharing)
                    Divider()
                    Button("Hide Assistant") { dismiss() }
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .help("Presentation controls")
            }

            HStack(spacing: 8) {
                Image(systemName: assistant.hasLiveTranscript ? "text.bubble.fill" : "text.bubble")
                    .foregroundStyle(assistant.hasLiveTranscript ? .green : .secondary)
                Text(assistant.hasLiveTranscript ? "Using the live meeting transcript" : "Waiting for live transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(settings.protocolProvider.label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(
                "Screen awareness samples the main display every 3 seconds while recording when enabled. Sawti keeps only the latest frame on your Mac and sends it only with your question.",
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistant.messages.isEmpty {
                        emptyState
                    }
                    ForEach(assistant.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if assistant.isSending {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Thinking…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .onChange(of: assistant.messages.count) { _, _ in
                guard let last = assistant.messages.last else { return }
                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about the conversation or what’s on screen.")
                .font(.headline)
            Text(
                "Sawti uses finalized live-caption lines as meeting context. Turn on Screen awareness for an updated screen sample during a recording, or capture the screen once for help with a slide, document, chart, or error message.",
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if !assistant.hasLiveTranscript {
                Text("Start a meeting recording with live transcription enabled to give Sawti conversation context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func messageBubble(_ message: LiveAssistantMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(message.role == .user ? "You" : "Sawti")
                .font(.caption.weight(.semibold))
                .foregroundStyle(message.role == .user ? Color.accentColor : Color.secondary)
            Text(message.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if message.hasSavedScreenCapture,
               let data = assistant.savedScreenCaptures[message.id],
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 160, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Saved screen capture attached to this message")
            }
        }
        .padding(12)
        .background(
            message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12),
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let preview = assistant.capturedImagePreview {
                HStack(spacing: 10) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(assistant.screenContextLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", systemImage: "xmark.circle.fill") {
                        assistant.clearCapturedScreen()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .help("Remove captured screen")
                }
                Toggle("Save this screen capture with the conversation", isOn: $saveCapturedScreenWithConversation)
                    .font(.caption)
            }

            if let error = assistant.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask Sawti…", text: $assistant.question, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .focused($questionFocused)
                    .onSubmit { sendQuestion() }
                    .disabled(assistant.isSending)
                Button(action: sendQuestion) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 27))
                }
                .buttonStyle(.plain)
                .disabled(assistant.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isSending)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Ask Sawti")
            }

            HStack(spacing: 10) {
                Button {
                    Task { await assistant.captureScreen() }
                } label: {
                    Label(
                        assistant.isCapturingScreen ? "Capturing…" : "Capture Screen",
                        systemImage: assistant.isCapturingScreen ? "hourglass" : "viewfinder",
                    )
                }
                .disabled(!assistant.canUseScreenContext || assistant.isCapturingScreen || assistant.isSending)
                .help("Capture the current display once; it is sent only with your next question")

                if assistant.isScreenAwarenessActive {
                    Label("Screen awareness on", systemImage: "eye.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if settings.continuousScreenAwarenessEnabled && isRecording {
                    Label("Screen awareness paused", systemImage: "eye.slash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if !assistant.canUseScreenContext {
                    Text("Selected AI model may not support images.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !assistant.messages.isEmpty {
                    Button("Clear") { assistant.clearConversation() }
                        .font(.caption)
                        .disabled(assistant.isSending)
                }
            }
        }
        .padding(14)
        .background(.bar)
    }

    private func sendQuestion() {
        let saveCapture = saveCapturedScreenWithConversation
        saveCapturedScreenWithConversation = false
        Task { await assistant.ask(saveCapturedImage: saveCapture) }
    }
}
