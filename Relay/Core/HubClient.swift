import Foundation

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // The device token and health payloads are only sent to the exact paired origin.
        completionHandler(nil)
    }
}

struct HubDeviceStatus: Decodable {
    let name: String
    let timeZone: String
    let actionableWrites: Int
    enum CodingKeys: String, CodingKey { case name, timeZone = "time_zone", actionableWrites = "actionable_writes" }
}

/// Client for Relay Hub's device API: pairing, type registration, uploads and the Apple Health write queue.
@MainActor
final class HubClient {
    private let vault: CredentialStore
    private let injectedSession: URLSession?
    private var sessions: [Bool: URLSession] = [:]
    private let delegate = NoRedirectDelegate()
    init(vault: CredentialStore = KeychainStore(), session: URLSession? = nil) {
        self.vault = vault; injectedSession = session
    }
    private func session(wifiOnly: Bool) -> URLSession {
        if let injectedSession { return injectedSession }
        if let session = sessions[wifiOnly] { return session }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        config.allowsCellularAccess = !wifiOnly; config.allowsExpensiveNetworkAccess = !wifiOnly
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        sessions[wifiOnly] = session
        return session
    }
    static func normalizedCode(_ input: String) throws -> String {
        let code = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard code.range(of: "^[A-Z2-9]{8}$", options: .regularExpression) != nil else { throw RelayError.invalidCode }
        return code
    }
    /// Confirms the address answers like a Relay Hub before a pairing code is sent to it.
    func check(server: ServerAddress) async throws {
        let (data, status) = try await send(server: server, path: "healthz", method: "GET", body: nil, token: nil, wifiOnly: false)
        struct Health: Decodable { let status: String }
        guard status == 200, (try? JSONDecoder().decode(Health.self, from: data))?.status == "ok" else { throw RelayError.invalidResponse }
    }
    func pair(server: ServerAddress, code: String, deviceName: String) async throws -> Credentials {
        let code = try Self.normalizedCode(code)
        let body = try JSONEncoder().encode(["code": code, "device_name": deviceName])
        let (data, status) = try await send(server: server, path: "v1/pair", method: "POST", body: body, token: nil, wifiOnly: false)
        if status == 403 { throw Self.message(data).map(RelayError.refused) ?? RelayError.invalidCode }
        if status == 429 { throw Self.message(data).map(RelayError.refused) ?? RelayError.rateLimited }
        guard status == 201 else { throw RelayError.server(status) }
        struct Paired: Decodable { let device_id: String; let token: String; let name: String }
        let paired = try JSONDecoder().decode(Paired.self, from: data)
        guard !paired.token.isEmpty else { throw RelayError.invalidResponse }
        let credentials = Credentials(server: server, deviceID: paired.device_id, token: paired.token, name: paired.name)
        try vault.save(credentials)
        return credentials
    }
    func status() async throws -> HubDeviceStatus {
        try JSONDecoder().decode(HubDeviceStatus.self, from: await authorized("v1/device", method: "GET", body: nil, wifiOnly: false))
    }
    /// Tells the hub which HealthKit types exist and the unit each is sent in.
    func registerTypes(_ types: [[String: Any]], wifiOnly: Bool) async throws {
        _ = try await authorized("v1/types", method: "POST", body: JSONSerialization.data(withJSONObject: ["types": types]), wifiOnly: wifiOnly)
    }
    func upload(_ body: Data, wifiOnly: Bool) async throws -> UploadReceipt {
        try JSONDecoder().decode(UploadReceipt.self, from: await authorized("v1/health", method: "POST", body: body, wifiOnly: wifiOnly))
    }
    /// Tells the hub every type was read to the end, so it can report the data as current even when nothing changed.
    func markCaughtUp(wifiOnly: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["batch_id": UUID().uuidString, "complete": true])
        _ = try await authorized("v1/health", method: "POST", body: body, wifiOnly: wifiOnly)
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
    private func authorized(_ path: String, method: String, body: Data?, wifiOnly: Bool) async throws -> Data {
        guard let credentials = try vault.read() else { throw RelayError.notConnected }
        let (data, status) = try await send(server: credentials.server, path: path, method: method, body: body, token: credentials.token, wifiOnly: wifiOnly)
        if status == 401 { throw RelayError.expiredSession }
        if status == 403 { throw RelayError.refused(Self.message(data) ?? "Relay Hub refused this request.") }
        guard (200...299).contains(status) else { throw RelayError.server(status) }
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
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw RelayError.invalidResponse }
        return (data, status)
    }
}
