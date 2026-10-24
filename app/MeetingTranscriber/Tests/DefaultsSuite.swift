import Foundation

/// Named preferences for tests, backed entirely by process-local memory.
///
/// `UserDefaults(suiteName:)` delegates to `cfprefsd`, which can write named
/// test domains to the user's real `~/Library/Preferences` even when `HOME` is
/// redirected. These tests need UserDefaults' value API and named-domain
/// semantics, not the daemon or disk persistence. This factory preserves the
/// typed `UserDefaults` interface while keeping the backing store in this test
/// process. Production code continues to use the real standard defaults store.
enum DefaultsSuite {
    /// Creates an isolated test domain. The optional return type mirrors
    /// `UserDefaults(suiteName:)`; generated suite names are valid, so callers
    /// should treat nil as a test setup failure rather than falling back to
    /// `.standard`.
    static func make(_ name: String) -> UserDefaults? {
        MemoryUserDefaults(suiteName: name)
    }

    /// Empties a named test domain. No preferences daemon or host file is
    /// involved, and the name can be reused safely after teardown.
    static func remove(_ name: String) {
        MemoryUserDefaults.removeDomain(named: name)
    }

    private final class MemoryUserDefaults: UserDefaults {
        private let domainName: String

        private static let lock = NSLock()
        nonisolated(unsafe) private static var domains: [String: [String: Any]] = [:]

        required override init?(suiteName: String?) {
            guard let suiteName, !suiteName.isEmpty else { return nil }
            domainName = suiteName
            super.init(suiteName: suiteName)
        }

        override func object(forKey defaultName: String) -> Any? {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.domains[domainName]?[defaultName]
        }

        override func set(_ value: Any?, forKey defaultName: String) {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            guard let value else {
                Self.domains[domainName]?.removeValue(forKey: defaultName)
                return
            }
            Self.domains[domainName, default: [:]][defaultName] = value
        }

        override func set(_ value: Bool, forKey defaultName: String) {
            set(value as Any, forKey: defaultName)
        }

        override func set(_ value: Int, forKey defaultName: String) {
            set(value as Any, forKey: defaultName)
        }

        override func set(_ value: Float, forKey defaultName: String) {
            set(value as Any, forKey: defaultName)
        }

        override func set(_ value: Double, forKey defaultName: String) {
            set(value as Any, forKey: defaultName)
        }

        override func set(_ value: URL?, forKey defaultName: String) {
            set(value as Any?, forKey: defaultName)
        }

        override func removeObject(forKey defaultName: String) {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.domains[domainName]?.removeValue(forKey: defaultName)
        }

        override func dictionaryRepresentation() -> [String: Any] {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.domains[domainName] ?? [:]
        }

        override func persistentDomain(forName domainName: String) -> [String: Any]? {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.domains[domainName]
        }

        override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.domains[domainName] = domain
        }

        override func removePersistentDomain(forName domainName: String) {
            Self.removeDomain(named: domainName)
        }

        override func synchronize() -> Bool {
            true
        }

        static func removeDomain(named name: String) {
            lock.lock()
            defer { lock.unlock() }
            domains.removeValue(forKey: name)
        }
    }
}
