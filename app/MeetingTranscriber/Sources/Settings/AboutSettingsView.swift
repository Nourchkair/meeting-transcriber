import AppKit
import SwiftUI

struct AboutSettingsView: View {
    @Bindable var settings: AppSettings
    var updateChecker: UpdateChecker?

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: Self.versionString)
                    .textSelection(.enabled)
                LabeledContent("Identifier", value: Bundle.main.bundleID)
                    .textSelection(.enabled)
                LabeledContent("Build Date", value: Self.buildDate)
                    .textSelection(.enabled)
                LabeledContent("ffmpeg") {
                    Label(
                        FFmpegHelper.isAvailable ? "Available" : "Not installed",
                        systemImage: FFmpegHelper.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill",
                    )
                    .foregroundStyle(FFmpegHelper.isAvailable ? .green : .secondary)
                    .font(.caption)
                }
                Link("GitHub", destination: Self.githubURL)
            }

            if let updateChecker {
                updatesSection(updateChecker: updateChecker)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.checkForUpdates) { _, enabled in
            updateChecker?.setAutomaticChecksEnabled(enabled)
        }
        .onChange(of: settings.includePreReleases) { _, enabled in
            updateChecker?.setIncludePreReleases(enabled)
        }
    }

    // swiftlint:disable:next force_unwrapping
    private static let githubURL = URL(string: "https://github.com/\(GitHubReleaseProvider.owner)/\(GitHubReleaseProvider.repo)")!

    private static let versionString: String = {
        let version = Bundle.main.appVersion
        let commit = Bundle.main.gitCommitHash
        #if APPSTORE
            let variant = "App Store"
        #else
            let variant = "Homebrew"
        #endif
        return "\(version) (\(commit)) · \(variant)"
    }()

    private static let buildDate: String = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date
        else { return "unknown" }
        return fmt.string(from: date)
    }()

    private func updatesSection(updateChecker: UpdateChecker) -> some View {
        // swiftlint:disable:next closure_body_length
        Section("Updates") {
            Toggle("Automatic Updates", isOn: $settings.checkForUpdates)

            Text("Sawti checks for updates and downloads them in the background. Sparkle installs a downloaded update when you quit Sawti, then relaunches it. Updates pause while recording or processing audio. Use Check Now for a manual update.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.checkForUpdates, !updateChecker.isPreReleaseBuild {
                Toggle("Include Pre-Releases", isOn: $settings.includePreReleases)
            } else if settings.checkForUpdates {
                Text("This beta build checks the beta update feed automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    updateChecker.checkNow(
                        includePreReleases: settings.includePreReleases,
                    )
                } label: {
                    HStack(spacing: 4) {
                        if updateChecker.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Check Now")
                    }
                }
                .disabled(updateChecker.isChecking)

                if let error = updateChecker.lastError {
                    Label(error, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                } else if let update = updateChecker.availableUpdate {
                    Label(
                        "Update available: \(update.tagName)",
                        systemImage: "arrow.down.circle.fill",
                    )
                    .foregroundStyle(.blue)
                    .font(.caption)
                } else if updateChecker.lastCheckDate != nil {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }

            if let update = updateChecker.availableUpdate, updateChecker.canInstallUpdates {
                Button {
                    updateChecker.installAvailableUpdate()
                } label: {
                    Label(
                        "Install & Restart to \(update.tagName)",
                        systemImage: "arrow.down.circle",
                    )
                }
            }
        }
    }
}
