import Foundation

enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.example.relay"
}

struct ServerAddress: Hashable, Codable {
    let url: URL
    init(_ text: String) throws {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/", c.port.map({ (1...65535).contains($0) }) ?? true
        else { throw RelayError.invalidServer }
        c.scheme = "https"; c.host = host.lowercased(); c.path = ""
        guard let url = c.url else { throw RelayError.invalidServer }
        self.url = url
    }
    func endpoint(_ path: String) -> URL { url.appendingPathComponent(path) }
}

struct Credentials: Codable {
    let server: ServerAddress
    let userID: String
    var accessToken: String
    var refreshToken: String?
}

enum RelayError: LocalizedError {
    case invalidServer, invalidCode, notConnected, expiredSession, healthUnavailable, pendingUpload
    case server(Int), invalidResponse, rejectedRecords(Int), storage, incompatibleUnit(String)
    case invalidHealthPage
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS server address with no path, query, or password."
        case .invalidCode: return "Enter the 8-character invitation code from your Open Wearables user page."
        case .notConnected: return "Connect your server first."
        case .expiredSession: return "Your connection has expired. Pair again using a new invitation code."
        case .healthUnavailable: return "Apple Health is unavailable on this device. Use your iPhone to enable health access."
        case .pendingUpload: return "Send the waiting batch before rescanning history. Its saved progress will be preserved."
        case .server(let code): return "The server returned HTTP \(code). Your pending data is kept for retry."
        case .invalidResponse: return "The server returned an unexpected response. No sync progress was discarded."
        case .rejectedRecords(let count): return "The server rejected \(count) records. This batch is kept for review and retry."
        case .storage: return "Relay could not safely save its sync progress. Try again after unlocking your iPhone."
        case .incompatibleUnit(let name): return "The unit for \(name) could not be converted safely. This record has not been sent."
        case .invalidHealthPage: return "Apple Health did not return a sync checkpoint. Relay will retry this type without advancing its progress."
        }
    }
}

enum HealthGroup: String, Codable, CaseIterable, Identifiable {
    case activity = "Activity", vitals = "Heart & vitals", sleep = "Sleep", workouts = "Workouts"
    case body = "Body", environment = "Environment", other = "Other measurements"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .activity: "figure.walk"
        case .vitals: "heart"
        case .sleep: "moon"
        case .workouts: "figure.run"
        case .body: "figure.stand"
        case .environment: "sun.max"
        case .other: "waveform.path.ecg"
        }
    }
}

struct SyncBatch: Codable, Identifiable {
    var id: String = UUID().uuidString
    let typeID: String
    let group: HealthGroup
    let body: Data
    let nextAnchor: Data
    let recordCount: Int
    let deletedIDs: [String]
}

struct SyncState: Codable {
    var anchors: [String: Data] = [:]
    var pending: SyncBatch?
    var sentByGroup: [HealthGroup: Int] = [:]
    var day = Calendar.current.startOfDay(for: Date())
    var sentToday = 0
    var totalSent = 0
    var lastAccepted: Date?
    var lastScan: Date?
    var deletedIDs: Set<String> = []
    var nextTypeIndex = 0
    var initialScanCompleted: Set<String> = []
    var acceptedBatches = 0
    // Optional so checkpoints written by earlier versions remain readable.
    var preparationIssues: [String: String]?
    mutating func prepareFullRescan() throws {
        guard pending == nil else { throw RelayError.pendingUpload }
        anchors = [:]; initialScanCompleted = []; nextTypeIndex = 0; lastScan = nil
    }
    mutating func commitPending(at now: Date = Date()) {
        guard let batch = pending else { return }
        let today = Calendar.current.startOfDay(for: now)
        if day != today { day = today; sentToday = 0; sentByGroup = [:] }
        anchors[batch.typeID] = batch.nextAnchor
        deletedIDs.formUnion(batch.deletedIDs)
        sentToday += batch.recordCount; totalSent += batch.recordCount
        sentByGroup[batch.group, default: 0] += batch.recordCount
        if batch.recordCount > 0 { lastAccepted = now; acceptedBatches += 1 }
        pending = nil
    }
}

struct UploadReceipt: Decodable {
    let statusCode: Int
    let response: String
    let droppedCount: Int?
    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code", response, droppedCount = "dropped_count"
    }
    static func validate(data: Data, httpStatus: Int) throws -> UploadReceipt {
        guard (200...299).contains(httpStatus) else { throw RelayError.server(httpStatus) }
        guard let receipt = try? JSONDecoder().decode(Self.self, from: data),
              (200...299).contains(receipt.statusCode) else { throw RelayError.invalidResponse }
        if let dropped = receipt.droppedCount, dropped > 0 { throw RelayError.rejectedRecords(dropped) }
        return receipt
    }
}
