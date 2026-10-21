import Foundation
import Security
import CryptoKit

protocol CredentialStore {
    func read() throws -> Credentials?
    func save(_ credentials: Credentials) throws
    func clear() throws
}

struct KeychainStore: CredentialStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.bundleID, kSecAttrAccount as String: account]
    }
    private let query = Self.query("relay-hub")
    func read() throws -> Credentials? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw RelayError.storage }
        return try JSONDecoder().decode(Credentials.self, from: data)
    }
    func save(_ credentials: Credentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RelayError.storage }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayError.storage }
    }
    /// Earlier versions stored Open Wearables tokens under "connection". They are no longer used.
    static func removeLegacyConnection() {
        SecItemDelete(query("connection") as CFDictionary)
    }
}

final class SyncStore {
    private let file: URL
    init(account: Credentials, directory: URL? = nil) throws {
        let hash = SHA256.hash(data: Data((account.server.url.absoluteString + "/" + account.deviceID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = try Self.directory(directory)
        file = directory.appendingPathComponent("sync-" + hash + ".json")
    }
    private static func directory(_ override: URL?) throws -> URL {
        var directory = override ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }
    /// Checkpoints from earlier versions could hold unsent health records for another server; they are deleted.
    static func removeLegacyCheckpoints(directory: URL? = nil) {
        guard let directory = try? Self.directory(directory),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix("sync-") {
            try? FileManager.default.removeItem(at: file)
        }
    }
    func load() throws -> SyncState {
        guard FileManager.default.fileExists(atPath: file.path) else { return SyncState() }
        // A damaged or locked checkpoint must never silently become an empty checkpoint.
        return try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: file))
    }
    func save(_ state: SyncState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
