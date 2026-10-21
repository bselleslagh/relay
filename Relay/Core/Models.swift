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

/// A Relay Hub device token. The MCP token and server secrets never reach the iPhone.
struct Credentials: Codable {
    let server: ServerAddress
    let deviceID: String
    let token: String
    let name: String
}

enum RelayError: LocalizedError, Equatable {
    case invalidServer, invalidCode, notConnected, expiredSession, healthUnavailable, pendingUpload
    case server(Int), invalidResponse, refused(String), rateLimited, storage, incompatibleUnit(String)
    case invalidHealthPage, unsupportedNutrient(String), invalidValue(String)
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS address with no path, query, or password."
        case .invalidCode: return "This pairing code is invalid, expired or already used. Create a new one with relay-hub pair-device."
        case .notConnected: return "Connect your Relay Hub first."
        case .expiredSession: return "Relay Hub no longer accepts this iPhone. Create a new pairing code and pair again."
        case .healthUnavailable: return "Apple Health is unavailable on this device. Use your iPhone to enable health access."
        case .pendingUpload: return "Send the waiting batch before rescanning history. Its saved progress will be preserved."
        case .server(let code): return "Relay Hub returned HTTP \(code). Your pending data is kept for retry."
        case .invalidResponse: return "Relay Hub returned an unexpected response. No sync progress was discarded."
        case .refused(let message): return message
        case .rateLimited: return "Too many incorrect codes. Create a new code on your server and try again."
        case .storage: return "Relay could not safely save its sync progress. Try again after unlocking your iPhone."
        case .incompatibleUnit(let name): return "The unit for \(name) could not be converted safely. This record has not been sent."
        case .invalidHealthPage: return "Apple Health did not return a sync checkpoint. Relay will retry this type without advancing its progress."
        case .unsupportedNutrient(let key): return "Relay cannot write \(key) to Apple Health."
        case .invalidValue(let key): return "The value for \(key) is not a valid amount."
        }
    }
}

enum HealthGroup: String, Codable, CaseIterable, Identifiable {
    case activity = "Activity", vitals = "Heart & vitals", sleep = "Sleep", workouts = "Workouts"
    case nutrition = "Nutrition", body = "Body", environment = "Environment", other = "Other measurements"
    var id: String { rawValue }
    /// Stable lowercase name used by Relay Hub.
    var key: String {
        switch self {
        case .vitals: "vitals"
        case .other: "other"
        default: rawValue.lowercased()
        }
    }
    var symbol: String {
        switch self {
        case .activity: "figure.walk"
        case .vitals: "heart"
        case .sleep: "moon"
        case .workouts: "figure.run"
        case .nutrition: "fork.knife"
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
    var deletions = 0
    /// Local days whose HealthKit daily statistics change once this batch is accepted.
    var statsDays: [String] = []
}

/// The outcome of a queued Apple Health write, shown under AI meal logging.
struct WriteActivity: Codable, Identifiable {
    enum Outcome: String, Codable { case saved, removed, failed, waiting }
    let id: String
    var title: String
    var detail: String
    var outcome: Outcome
    var date: Date
}

enum HistoryWindow: Int, CaseIterable, Identifiable {
    case month = 30, year = 365, all = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .month: "Last 30 days"
        case .year: "Last year"
        case .all: "All history"
        }
    }
    func start(at now: Date) -> Date? {
        self == .all ? nil : now.addingTimeInterval(-Double(rawValue) * 24 * 60 * 60)
    }
}

struct SyncState: Codable {
    /// Sample start dates before this are not read. Nil reads everything Apple Health has.
    var historyStart: Date?
    var historyWindow = HistoryWindow.month.rawValue
    var anchors: [String: Data] = [:]
    var pending: SyncBatch?
    var sentByGroup: [HealthGroup: Int] = [:]
    var day = Calendar.current.startOfDay(for: Date())
    var sentToday = 0
    var totalSent = 0
    var lastAccepted: Date?
    var lastScan: Date?
    var nextTypeIndex = 0
    var initialScanCompleted: Set<String> = []
    var acceptedBatches = 0
    var preparationIssues: [String: String]?
    var rejected = 0
    /// Days per quantity type whose daily statistics still have to be sent.
    var statsDays: [String: Set<String>] = [:]
    var activity: [WriteActivity] = []
    var window: HistoryWindow { HistoryWindow(rawValue: historyWindow) ?? .month }
    init() {}
    /// Every field is optional on disk, so checkpoints written by other versions stay readable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let empty = SyncState()
        historyStart = try c.decodeIfPresent(Date.self, forKey: .historyStart)
        historyWindow = try c.decodeIfPresent(Int.self, forKey: .historyWindow) ?? empty.historyWindow
        anchors = try c.decodeIfPresent([String: Data].self, forKey: .anchors) ?? [:]
        pending = try c.decodeIfPresent(SyncBatch.self, forKey: .pending)
        sentByGroup = try c.decodeIfPresent([HealthGroup: Int].self, forKey: .sentByGroup) ?? [:]
        day = try c.decodeIfPresent(Date.self, forKey: .day) ?? empty.day
        sentToday = try c.decodeIfPresent(Int.self, forKey: .sentToday) ?? 0
        totalSent = try c.decodeIfPresent(Int.self, forKey: .totalSent) ?? 0
        lastAccepted = try c.decodeIfPresent(Date.self, forKey: .lastAccepted)
        lastScan = try c.decodeIfPresent(Date.self, forKey: .lastScan)
        nextTypeIndex = try c.decodeIfPresent(Int.self, forKey: .nextTypeIndex) ?? 0
        initialScanCompleted = try c.decodeIfPresent(Set<String>.self, forKey: .initialScanCompleted) ?? []
        acceptedBatches = try c.decodeIfPresent(Int.self, forKey: .acceptedBatches) ?? 0
        preparationIssues = try c.decodeIfPresent([String: String].self, forKey: .preparationIssues)
        rejected = try c.decodeIfPresent(Int.self, forKey: .rejected) ?? 0
        statsDays = try c.decodeIfPresent([String: Set<String>].self, forKey: .statsDays) ?? [:]
        activity = try c.decodeIfPresent([WriteActivity].self, forKey: .activity) ?? []
    }
    mutating func prepareRescan(window: HistoryWindow, at now: Date = Date()) throws {
        guard pending == nil else { throw RelayError.pendingUpload }
        historyWindow = window.rawValue; historyStart = window.start(at: now)
        anchors = [:]; initialScanCompleted = []; nextTypeIndex = 0; lastScan = nil; preparationIssues = nil
    }
    mutating func commitPending(at now: Date = Date()) {
        guard let batch = pending else { return }
        let today = Calendar.current.startOfDay(for: now)
        if day != today { day = today; sentToday = 0; sentByGroup = [:] }
        anchors[batch.typeID] = batch.nextAnchor
        if !batch.statsDays.isEmpty { statsDays[batch.typeID, default: []].formUnion(batch.statsDays) }
        sentToday += batch.recordCount; totalSent += batch.recordCount
        sentByGroup[batch.group, default: 0] += batch.recordCount
        if batch.recordCount > 0 { lastAccepted = now; acceptedBatches += 1 }
        pending = nil
    }
    /// Moves past a batch Relay Hub refuses on every retry, without counting it as sent. Returns the issue to show.
    @discardableResult
    mutating func skipPending(status: Int) -> String? {
        guard let batch = pending else { return nil }
        anchors[batch.typeID] = batch.nextAnchor; pending = nil; rejected += batch.recordCount
        let issue = "Relay Hub refused a batch (HTTP \(status)). \(batch.recordCount) records were skipped."
        if preparationIssues == nil { preparationIssues = [:] }
        preparationIssues?[batch.typeID] = issue
        return issue
    }
    /// Keeps the latest result per entry, newest first.
    mutating func record(_ item: WriteActivity) {
        activity.removeAll { $0.id == item.id }
        activity.insert(item, at: 0)
        activity = Array(activity.prefix(20))
    }
}

struct UploadReceipt: Decodable {
    struct Rejection: Decodable { let collection: String; let index: Int; let reason: String }
    let rejected: [Rejection]
    /// Local days of samples this upload deleted, per type, so their daily statistics are refreshed.
    let deletedDays: [String: [String]]?
    enum CodingKeys: String, CodingKey { case rejected, deletedDays = "deleted_days" }
}
