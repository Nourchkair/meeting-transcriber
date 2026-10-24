import Foundation
import Observation
#if !APPSTORE
    import Sparkle
#endif

private struct SemanticReleaseVersion: Comparable {
    private enum Identifier: Equatable {
        case number(Int)
        case text(String)
    }

    private let major: Int
    private let minor: Int
    private let patch: Int
    private let prerelease: [Identifier]?

    var isPreRelease: Bool {
        prerelease != nil
    }

    static func parse(_ value: String) -> Self? {
        var version = value
        if version.hasPrefix("v") { version.removeFirst() }
        version = String(version.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0])

        let sections = version.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = sections[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3,
              let major = Int(core[0]), let minor = Int(core[1]), let patch = Int(core[2])
        else { return nil }

        var prerelease: [Identifier]?
        if sections.count == 2 {
            let rawIdentifiers = sections[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !rawIdentifiers.isEmpty else { return nil }
            var identifiers: [Identifier] = []
            for rawIdentifier in rawIdentifiers {
                let identifier = String(rawIdentifier)
                guard !identifier.isEmpty,
                      identifier.utf8.allSatisfy({
                          (48 ... 57).contains($0) || (65 ... 90).contains($0) ||
                              (97 ... 122).contains($0) || $0 == 45
                      })
                else { return nil }
                if identifier.allSatisfy(\.isNumber) {
                    guard identifier == "0" || !identifier.hasPrefix("0"),
                          let number = Int(identifier)
                    else { return nil }
                    identifiers.append(.number(number))
                } else {
                    identifiers.append(.text(identifier))
                }
            }
            prerelease = identifiers
        }
        return Self(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, .some(_)):
            return false
        case (.some(_), nil):
            return true
        case let (.some(left), .some(right)):
            for (leftIdentifier, rightIdentifier) in zip(left, right) {
                switch (leftIdentifier, rightIdentifier) {
                case let (.number(leftNumber), .number(rightNumber)):
                    if leftNumber != rightNumber { return leftNumber < rightNumber }
                case (.number, .text):
                    return true
                case (.text, .number):
                    return false
                case let (.text(leftText), .text(rightText)):
                    if leftText != rightText { return leftText < rightText }
                }
            }
            return left.count < right.count
        }
    }
}

#if !APPSTORE
    @MainActor
    private final class SparkleUpdateConfiguration {
        var includePreReleases = false
        var isPreReleaseBuild = false
        var isSafeToInstall: () -> Bool = { true }

        var usesBetaFeed: Bool {
            includePreReleases || isPreReleaseBuild
        }

        func requireSafeInstall() throws {
            guard !isSafeToInstall() else { return }
            throw NSError(
                domain: "com.nourchkair.sawti.updates",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Sawti pauses updates while recording or processing audio. Try again when it is idle."],
            )
        }
    }

    @MainActor
    private final class SawtiSparkleUpdaterDelegate: NSObject, SPUUpdaterDelegate {
        private let configuration: SparkleUpdateConfiguration
        private let betaFeedURL = "https://raw.githubusercontent.com/Nourchkair/Sawti/beta-feed/appcast.xml"

        init(configuration: SparkleUpdateConfiguration) {
            self.configuration = configuration
        }

        func feedURLString(for _: SPUUpdater) -> String? {
            configuration.usesBetaFeed ? betaFeedURL : nil
        }

        func allowedChannels(for _: SPUUpdater) -> Set<String> {
            configuration.usesBetaFeed ? ["beta"] : []
        }

        func updater(_: SPUUpdater, mayPerform _: SPUUpdateCheck) throws {
            try configuration.requireSafeInstall()
        }

        func updater(
            _: SPUUpdater,
            shouldProceedWithUpdate _: SUAppcastItem,
            updateCheck _: SPUUpdateCheck,
        ) throws {
            try configuration.requireSafeInstall()
        }
    }
#endif

// MARK: - Models

struct ReleaseInfo: Equatable {
    let tagName: String
    let name: String
    let prerelease: Bool
    let htmlURL: URL
    let dmgURL: URL?

    var version: (Int, Int, Int)? {
        UpdateChecker.parseVersion(tagName)
    }
}

// MARK: - Protocol

protocol UpdateProviding: Sendable {
    func latestRelease() async throws -> ReleaseInfo
    func allReleases() async throws -> [ReleaseInfo]
}

// MARK: - GitHub Release Provider

struct GitHubReleaseProvider: UpdateProviding {
    /// Not `private` — `AboutSettingsView`'s GitHub link is built from the same
    /// two constants, so the repo identity has a single home.
    static let owner = "Nourchkair"
    static let repo = "Sawti"

    private struct GitHubRelease: Codable {
        let tagName: String
        let name: String?
        let prerelease: Bool
        let htmlURL: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case prerelease
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Codable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    func latestRelease() async throws -> ReleaseInfo {
        let release: GitHubRelease = try await fetchJSON(path: "releases/latest")
        return mapRelease(release)
    }

    func allReleases() async throws -> [ReleaseInfo] {
        let releases: [GitHubRelease] = try await fetchJSON(path: "releases")
        return releases.map { mapRelease($0) }
    }

    private func fetchJSON<T: Decodable>(path: String) async throws -> T {
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/\(path)")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateCheckerError.networkError(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)",
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func mapRelease(_ release: GitHubRelease) -> ReleaseInfo {
        let dmgAsset = release.assets.first { $0.name.hasSuffix(".dmg") }
        return ReleaseInfo(
            tagName: release.tagName,
            name: release.name ?? release.tagName,
            prerelease: release.prerelease,
            // swiftlint:disable:next force_unwrapping
            htmlURL: URL(string: release.htmlURL)!,
            dmgURL: dmgAsset.flatMap { URL(string: $0.browserDownloadURL) },
        )
    }
}

// MARK: - Errors

enum UpdateCheckerError: LocalizedError {
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case let .networkError(detail): "Network error: \(detail)"
        }
    }
}

// MARK: - UpdateChecker

@MainActor
@Observable
final class UpdateChecker {
    var availableUpdate: ReleaseInfo?
    var isChecking = false
    var lastCheckDate: Date?
    var lastError: String?
    let isPreReleaseBuild: Bool

    private let provider: any UpdateProviding
    private let currentVersionTag: String
    private var checkTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    #if !APPSTORE
        private let updaterController: SPUStandardUpdaterController?
        @ObservationIgnored private var sparkleConfiguration: SparkleUpdateConfiguration?
        @ObservationIgnored private var sparkleDelegate: SawtiSparkleUpdaterDelegate?
    #endif

    init(provider: any UpdateProviding = GitHubReleaseProvider()) {
        self.provider = provider
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.currentVersionTag = version
        self.isPreReleaseBuild = SemanticReleaseVersion.parse(version)?.isPreRelease ?? false
        #if !APPSTORE
            let info = Bundle.main.infoDictionary ?? [:]
            if (info["SUFeedURL"] as? String)?.isEmpty == false,
               (info["SUPublicEDKey"] as? String)?.isEmpty == false {
                let configuration = SparkleUpdateConfiguration()
                configuration.isPreReleaseBuild = isPreReleaseBuild
                let delegate = SawtiSparkleUpdaterDelegate(configuration: configuration)
                self.sparkleConfiguration = configuration
                self.sparkleDelegate = delegate
                self.updaterController = SPUStandardUpdaterController(
                    startingUpdater: true,
                    updaterDelegate: delegate,
                    userDriverDelegate: nil,
                )
            } else {
                // Developer builds have no appcast or update-signing key. Keep the
                // release updater disabled rather than pointing a local build at a
                // feed it cannot safely install from.
                self.updaterController = nil
            }
        #endif
    }

    var canInstallUpdates: Bool {
        #if APPSTORE
            false
        #else
            updaterController != nil
        #endif
    }

    /// Opens Sparkle's native download, install, and relaunch flow. This is
    /// used by both the settings button and the menu-bar update notification.
    func installAvailableUpdate() {
        #if !APPSTORE
            updaterController?.checkForUpdates(nil)
        #endif
    }

    func setAutomaticChecksEnabled(_ enabled: Bool) {
        #if !APPSTORE
            updaterController?.updater.automaticallyChecksForUpdates = enabled
            updaterController?.updater.automaticallyDownloadsUpdates = enabled
        #endif
    }

    func setIncludePreReleases(_ enabled: Bool) {
        #if !APPSTORE
            sparkleConfiguration?.includePreReleases = enabled
        #endif
    }

    func setUpdateSafetyCheck(_ isSafeToInstall: @escaping () -> Bool) {
        #if !APPSTORE
            sparkleConfiguration?.isSafeToInstall = isSafeToInstall
        #endif
    }

    func checkNow(includePreReleases: Bool = false) {
        // Deduplicate concurrent calls
        guard checkTask == nil else { return }

        let shouldIncludePreReleases = includePreReleases || isPreReleaseBuild
        setIncludePreReleases(shouldIncludePreReleases)

        isChecking = true
        lastError = nil

        checkTask = Task {
            defer {
                isChecking = false
                checkTask = nil
            }

            do {
                let release: ReleaseInfo?
                if shouldIncludePreReleases {
                    let all = try await provider.allReleases()
                    release = all.first { r in
                        Self.isNewer(r.tagName, than: currentVersionTag)
                    }
                } else {
                    let latest = try await provider.latestRelease()
                    if Self.isNewer(latest.tagName, than: currentVersionTag) {
                        release = latest
                    } else {
                        release = nil
                    }
                }
                availableUpdate = release
                lastCheckDate = Date()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func startPeriodicChecks(settings: AppSettings) {
        periodicTask?.cancel()
        setIncludePreReleases(settings.includePreReleases || isPreReleaseBuild)
        setAutomaticChecksEnabled(settings.checkForUpdates)

        periodicTask = Task {
            // Initial delay
            try? await Task.sleep(for: .seconds(30))

            while !Task.isCancelled {
                if settings.checkForUpdates {
                    checkNow(includePreReleases: settings.includePreReleases)
                }
                try? await Task.sleep(for: .seconds(86400)) // 24 hours
            }
        }
    }

    // MARK: - Version Utilities

    nonisolated static func parseVersion(_ string: String) -> (Int, Int, Int)? {
        var s = string
        if s.hasPrefix("v") { s = String(s.dropFirst()) }
        // Strip pre-release suffix (e.g. "1.2.3-beta" → "1.2.3")
        if let dash = s.firstIndex(of: "-") {
            s = String(s[s.startIndex ..< dash])
        }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    nonisolated static func isNewer(
        _ remote: (Int, Int, Int), than local: (Int, Int, Int),
    ) -> Bool {
        if remote.0 != local.0 { return remote.0 > local.0 }
        if remote.1 != local.1 { return remote.1 > local.1 }
        return remote.2 > local.2
    }

    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        guard let remoteVersion = SemanticReleaseVersion.parse(remote),
              let localVersion = SemanticReleaseVersion.parse(local)
        else { return false }
        return remoteVersion > localVersion
    }
}
