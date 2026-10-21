import Foundation
import Security

/// Keychain storage for the Relay Hub device token, separate from the Open Wearables connection.
struct HubVault {
    var read: () throws -> HubCredentials?
    var save: (HubCredentials) throws -> Void
    var clear: () throws -> Void

    static let keychain: HubVault = {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentity.bundleID, kSecAttrAccount as String: "relay-hub"]
        return HubVault(read: {
            var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = item as? Data else { throw RelayError.storage }
            return try JSONDecoder().decode(HubCredentials.self, from: data)
        }, save: { credentials in
            let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(credentials),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw RelayError.storage }
        }, clear: {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayError.storage }
        })
    }()
}

struct HubDeviceStatus: Decodable {
    let name: String
    let timeZone: String
    let actionableWrites: Int
    enum CodingKeys: String, CodingKey { case name, timeZone = "time_zone", actionableWrites = "actionable_writes" }
}

struct NutritionReceipt: Decodable {
    struct Rejection: Decodable { let collection: String; let index: Int; let reason: String }
    let rejected: [Rejection]
}

@MainActor
final class HubClient {
    private let vault: HubVault
    private let injectedSession: URLSession?
    private var sessions: [Bool: URLSession] = [:]
    private let delegate = NoRedirectDelegate()
    init(vault: HubVault = .keychain, session: URLSession? = nil) {
        self.vault = vault; injectedSession = session
    }
    private func session(wifiOnly: Bool) -> URLSession {
        if let injectedSession { return injectedSession }
        if let session = sessions[wifiOnly] { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 40
        config.allowsCellularAccess = !wifiOnly; config.allowsExpensiveNetworkAccess = !wifiOnly
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        sessions[wifiOnly] = session
        return session
    }
    func pair(server: ServerAddress, code: String, deviceName: String) async throws -> HubCredentials {
        let code = try WearablesClient.normalizedCode(code)
        let body = try JSONEncoder().encode(["code": code, "device_name": deviceName])
        let (data, status) = try await send(server: server, path: "v1/pair", method: "POST", body: body, token: nil, wifiOnly: false)
        if status == 403 { throw Self.message(data).map(HubError.refused) ?? HubError.invalidCode }
        if status == 429 { throw Self.message(data).map(HubError.refused) ?? HubError.rateLimited }
        guard status == 201 else { throw HubError.server(status) }
        struct Paired: Decodable { let device_id: String; let token: String; let name: String }
        let paired = try JSONDecoder().decode(Paired.self, from: data)
        guard !paired.token.isEmpty else { throw HubError.invalidResponse }
        let credentials = HubCredentials(server: server, deviceID: paired.device_id, token: paired.token, name: paired.name)
        try vault.save(credentials)
        return credentials
    }
    func status() async throws -> HubDeviceStatus {
        try JSONDecoder().decode(HubDeviceStatus.self, from: await authorized("v1/device", method: "GET", body: nil, wifiOnly: false))
    }
    func pull(writeAccess: String, appVersion: String, wifiOnly: Bool) async throws -> [HubWrite] {
        let body = try JSONSerialization.data(withJSONObject: ["kinds": ["meal"], "write_access": ["meal": writeAccess], "app_version": appVersion])
        // Entries are decoded one by one, so a single unreadable entry cannot block the rest of the queue.
        struct Entry: Decodable { let write: HubWrite?; init(from decoder: Decoder) { write = try? HubWrite(from: decoder) } }
        struct Pulled: Decodable { let writes: [Entry] }
        return try JSONDecoder().decode(Pulled.self, from: await authorized("v1/writes/pull", method: "POST", body: body, wifiOnly: wifiOnly)).writes.compactMap(\.write)
    }
    /// Returns the entry's status on the hub. A cancellation that raced the write comes back as `delete_requested`.
    func ack(_ id: String, result: String, healthKitIDs: [String] = [], error: String? = nil, wifiOnly: Bool) async throws -> String {
        var object: [String: Any] = ["result": result, "healthkit_ids": healthKitIDs]
        if let error { object["error"] = error }
        struct Acked: Decodable { let status: String }
        let data = try await authorized("v1/writes/\(id)/ack", method: "POST", body: JSONSerialization.data(withJSONObject: object), wifiOnly: wifiOnly)
        return try JSONDecoder().decode(Acked.self, from: data).status
    }
    func upload(_ batch: NutritionBatch, wifiOnly: Bool) async throws -> NutritionReceipt {
        try JSONDecoder().decode(NutritionReceipt.self, from: await authorized("v1/nutrition", method: "POST", body: batch.body, wifiOnly: wifiOnly))
    }
    /// Tells the hub every nutrition type was read to the end, even when nothing changed.
    func markCaughtUp(wifiOnly: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["batch_id": UUID().uuidString, "complete": true])
        _ = try await authorized("v1/nutrition", method: "POST", body: body, wifiOnly: wifiOnly)
    }
    private func authorized(_ path: String, method: String, body: Data?, wifiOnly: Bool) async throws -> Data {
        guard let credentials = try vault.read() else { throw HubError.notPaired }
        let (data, status) = try await send(server: credentials.server, path: path, method: method, body: body, token: credentials.token, wifiOnly: wifiOnly)
        if status == 401 { throw HubError.unpaired }
        if status == 403 { throw HubError.refused(Self.message(data) ?? "Relay Hub refused this request.") }
        guard (200...299).contains(status) else { throw HubError.server(status) }
        return data
    }
    private static func message(_ data: Data) -> String? {
        struct Failure: Decodable { let error: String }
        return try? JSONDecoder().decode(Failure.self, from: data).error
    }
    private func send(server: ServerAddress, path: String, method: String, body: Data?, token: String?, wifiOnly: Bool) async throws -> (Data, Int) {
        var request = URLRequest(url: server.endpoint(path)); request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Relay/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session(wifiOnly: wifiOnly).data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw HubError.invalidResponse }
        return (data, status)
    }
}
