import Foundation

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Credentials and health payloads are only sent to the exact paired origin.
        completionHandler(nil)
    }
}

@MainActor
final class WearablesClient {
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
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 45
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
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
    func pair(server: ServerAddress, code: String) async throws -> Credentials {
        let code = try Self.normalizedCode(code)
        let data = try await post(server: server, path: "api/v1/invitation-code/redeem",
                                  body: JSONEncoder().encode(["code": code]))
        struct Tokens: Decodable { let access_token: String; let refresh_token: String?; let user_id: String }
        let token = try JSONDecoder().decode(Tokens.self, from: data)
        guard UUID(uuidString: token.user_id) != nil, !token.access_token.isEmpty else { throw RelayError.invalidResponse }
        let credentials = Credentials(server: server, userID: token.user_id,
                                      accessToken: token.access_token, refreshToken: token.refresh_token)
        try vault.save(credentials)
        return credentials
    }
    func check(server: ServerAddress) async throws {
        var request = URLRequest(url: server.endpoint("openapi.json")); request.timeoutInterval = 12
        let (data, response) = try await session(wifiOnly: false).data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = root["paths"] as? [String: Any],
              paths["/api/v1/invitation-code/redeem"] != nil,
              paths["/api/v1/sdk/users/{user_id}/sync"] != nil else { throw RelayError.invalidResponse }
    }
    func upload(_ batch: SyncBatch, wifiOnly: Bool) async throws {
        guard var credentials = try vault.read() else { throw RelayError.notConnected }
        for attempt in 0...1 {
            var request = URLRequest(url: credentials.server.endpoint("api/v1/sdk/users/\(credentials.userID)/sync"))
            request.httpMethod = "POST"; request.httpBody = batch.body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(batch.id, forHTTPHeaderField: "X-Request-Id")
            request.setValue("Relay/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session(wifiOnly: wifiOnly).data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else { throw RelayError.invalidResponse }
            if status == 401 && attempt == 0 {
                credentials = try await refresh(credentials, wifiOnly: wifiOnly); continue
            }
            if status == 401 || status == 403 { throw RelayError.expiredSession }
            _ = try UploadReceipt.validate(data: data, httpStatus: status)
            return
        }
        throw RelayError.expiredSession
    }
    private func refresh(_ credentials: Credentials, wifiOnly: Bool) async throws -> Credentials {
        guard let token = credentials.refreshToken else { throw RelayError.expiredSession }
        let data = try await post(server: credentials.server, path: "api/v1/token/refresh",
                                 body: JSONEncoder().encode(["refresh_token": token]), wifiOnly: wifiOnly)
        struct Tokens: Decodable { let access_token: String; let refresh_token: String? }
        let response = try JSONDecoder().decode(Tokens.self, from: data)
        guard !response.access_token.isEmpty else { throw RelayError.invalidResponse }
        var updated = credentials; updated.accessToken = response.access_token
        updated.refreshToken = response.refresh_token ?? credentials.refreshToken
        try vault.save(updated)
        return updated
    }
    private func post(server: ServerAddress, path: String, body: Data, wifiOnly: Bool = false) async throws -> Data {
        var request = URLRequest(url: server.endpoint(path)); request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session(wifiOnly: wifiOnly).data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw RelayError.invalidResponse }
        if status == 401 || status == 403 { throw RelayError.expiredSession }
        guard (200...299).contains(status) else { throw RelayError.server(status) }
        return data
    }
}
