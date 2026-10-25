import Foundation
import CryptoKit
import Observation
import HealthKit
import Network
import UIKit
import BackgroundTasks

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    var isDemo = false
    var connected = false
    var serverText = ""
    var deviceName = ""
    var automatic = true
    var wifiOnly = false
    var healthRequested = false
    var busy = false
    var pairing = false
    var serverReachable: Bool?
    var errorMessage: String?
    var currentType = ""
    var state = SyncState()
    var typeIssues: [String: String] = [:]
    var lastCheck: Date?
    var networkAvailable = true
    var onWiFi = true
    var writeAccess = WriteAccess.notDetermined
    var waitingForAccess = 0
    /// Types Apple Health has not granted to Relay in this session.
    var notShared: Set<String> = []
    /// The requested types changed since the user last chose Health access, for example after an update.
    var healthNeedsReview = false
    @ObservationIgnored let health = HealthReader()
    @ObservationIgnored let writer = HealthWriter()
    @ObservationIgnored let client = HubClient()
    @ObservationIgnored private let vault = KeychainStore()
    @ObservationIgnored private var disk: SyncStore?
    @ObservationIgnored private var work: Task<Bool, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var credentialFailure = false
    @ObservationIgnored private var observerBackgroundTask = UIBackgroundTaskIdentifier.invalid
    static let pageSize = 500
    /// Workouts carry events, so their pages stay small enough for one request.
    static let workoutPageSize = 50
    static let statsBatch = 1_000
    static var healthSignature: String {
        let ids = HealthCatalog.readTypes.map(\.identifier) + HealthCatalog.writeTypes.map { "write:" + $0.identifier }
        return SHA256.hash(data: Data(ids.sorted().joined(separator: ",").utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        isDemo = demo
        if demo {
            serverText = "https://hub.example.com"; deviceName = "iPhone"
            connected = true; healthRequested = true; serverReachable = true; writeAccess = .authorized
            state.sentToday = 1284; state.totalSent = 1284; state.lastAccepted = Date()
            state.sentByGroup = [.activity: 684, .vitals: 348, .sleep: 28, .workouts: 1, .body: 223]
            state.initialScanCompleted = Set(HealthCatalog.entries.map(\.id))
            state.activity = [WriteActivity(id: "demo", title: "Chicken salad · 610 kcal", detail: "Saved to Apple Health", outcome: .saved, date: Date())]
            return
        }
        automatic = defaults.object(forKey: "automatic") as? Bool ?? true
        wifiOnly = defaults.bool(forKey: "wifiOnly")
        healthRequested = defaults.bool(forKey: "healthRequested")
        serverText = defaults.string(forKey: "server") ?? ""
        healthNeedsReview = healthRequested && defaults.string(forKey: "healthSignature") != Self.healthSignature
        KeychainStore.removeLegacyConnection()
        SyncStore.removeLegacyCheckpoints()
        restore()
    }
    var sentToday: Int { Calendar.current.isDateInToday(state.day) ? state.sentToday : 0 }
    var pendingCount: Int { state.pending?.recordCount ?? 0 }
    var historyComplete: Bool { Set(HealthCatalog.entries.map(\.id)).isSubset(of: state.initialScanCompleted) }
    var heading: String {
        if isDemo { return "In sync." }
        if !connected { return "A home for\nyour health." }
        if !healthRequested || healthNeedsReview { return "Your next step." }
        if busy { return "On its way." }
        if errorMessage != nil || !typeIssues.isEmpty { return "Needs a moment." }
        if !automatic { return "Taking a pause." }
        if state.lastAccepted != nil { return "Sent home." }
        return "Ready when you are."
    }
    var subtitle: String {
        if isDemo { return "Your health data, safely home." }
        if !connected { return "Connect Apple Health to your own Relay Hub." }
        if !healthRequested { return "Choose what Relay can read in Apple Health." }
        if healthNeedsReview { return "Relay can now read more of Apple Health. Review Health access." }
        if busy { return "Sending \(currentType.lowercased())…" }
        if errorMessage != nil { return "Sync paused. Your saved progress is kept for retry." }
        if !typeIssues.isEmpty { return "Some health types need attention. Other data can still sync." }
        if !automatic { return "Automatic sync is paused. Manual sync is available." }
        if state.lastAccepted != nil { return "Your latest records are on your Relay Hub." }
        return "Only the health data you choose is shared."
    }
    var serverStatus: String {
        guard connected else { return "Not paired" }
        if let reachable = serverReachable { return reachable ? "Available" : "Unreachable" }
        return "Not checked"
    }
    func start() {
        guard !isDemo else { return }
        let monitor = NWPathMonitor(); self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                let newlyAvailable = (!self.networkAvailable && available) || (!self.onWiFi && wifi)
                self.networkAvailable = available; self.onWiFi = wifi
                if newlyAvailable && self.automatic { _ = await self.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "\(AppIdentity.bundleID).network"))
        configureAutomatic()
    }
    private func restore() {
        do {
            if let credentials = try vault.read() {
                disk = try SyncStore(account: credentials); state = try disk!.load()
                typeIssues = state.preparationIssues ?? [:]
                serverText = credentials.server.url.absoluteString; deviceName = credentials.name; connected = true
                writeAccess = writer.access
            }
            credentialFailure = false
        } catch { credentialFailure = true; errorMessage = error.localizedDescription }
    }
    /// While Relay is open it syncs now and then every 90 seconds, so meals an assistant logs appear quickly.
    func foreground() {
        guard !isDemo else { return }
        if credentialFailure { restore(); configureAutomatic() }
        writeAccess = writer.access
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.connected && self.automatic && self.healthRequested { _ = await self.sync() }
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }
    /// A foreground sync yields to system-scheduled delivery.
    func enteredBackground() {
        poller?.cancel(); poller = nil
        cancelWork()
    }
    func pair(address: String, code: String) async {
        guard !pairing, !isDemo, !connected else { return }
        pairing = true; errorMessage = nil
        defer { pairing = false }
        do {
            let server = try ServerAddress(address)
            try await client.check(server: server)
            let credentials = try await client.pair(server: server, code: code, deviceName: UIDevice.current.name)
            disk = try SyncStore(account: credentials); state = try disk!.load()
            serverText = server.url.absoluteString; deviceName = credentials.name; defaults.set(serverText, forKey: "server")
            connected = true; serverReachable = true
            configureAutomatic()
            if healthRequested { _ = await sync() }
        } catch { errorMessage = friendly(error) }
    }
    func authorize() async {
        guard !isDemo else { return }
        errorMessage = nil
        do {
            try await health.authorize()
            // Completion means the permission sheet completed, not that read access was granted.
            healthRequested = true; defaults.set(true, forKey: "healthRequested")
            healthNeedsReview = false; defaults.set(Self.healthSignature, forKey: "healthSignature")
            writeAccess = writer.access
            configureAutomatic()
            _ = await sync()
        } catch { errorMessage = friendly(error) }
    }
    func checkConnection() async {
        guard !isDemo else { return }
        do {
            _ = try await client.status(); serverReachable = true
            lastCheck = Date(); errorMessage = nil
        } catch { serverReachable = false; errorMessage = friendly(error) }
    }
    func setAutomatic(_ value: Bool) {
        automatic = value
        guard !isDemo else { return }
        defaults.set(value, forKey: "automatic")
        if !value { cancelWork() }
        configureAutomatic()
    }
    func setWiFiOnly(_ value: Bool) {
        wifiOnly = value
        guard !isDemo else { return }
        defaults.set(value, forKey: "wifiOnly")
        cancelWork()
        BackgroundCoordinator.schedule(enabled: connected && automatic && healthRequested)
    }
    func configureAutomatic() {
        guard !isDemo else { return }
        let enabled = connected && automatic && healthRequested
        if enabled {
            health.observe { [weak self] completion in
                guard let self else { completion(); return }
                if self.observerBackgroundTask == .invalid {
                    self.observerBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Relay health delivery") { [weak self] in
                        // Called on the main thread; the task must end before this handler returns.
                        MainActor.assumeIsolated { self?.cancelWork(); self?.endObserverTask() }
                    }
                }
                Task { @MainActor in
                    _ = await self.sync(background: UIApplication.shared.applicationState != .active)
                    completion()
                    self.endObserverTask()
                }
            }
        } else { health.stopObserving() }
        BackgroundCoordinator.schedule(enabled: enabled)
    }
    private func endObserverTask() {
        guard observerBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(observerBackgroundTask); observerBackgroundTask = .invalid
    }
    func cancelWork() { work?.cancel(); health.cancelQuery() }
    func sync(background: Bool = false) async -> Bool {
        if isDemo { return true }
        if let work { return await work.value }
        guard connected, healthRequested, !credentialFailure else { return false }
        if background && !automatic { return false }
        guard networkAvailable, !wifiOnly || onWiFi else {
            errorMessage = wifiOnly && !onWiFi ? "Waiting for Wi-Fi. Your progress is saved." : "Waiting for a connection. Your progress is saved."
            return false
        }
        let task = Task { await runSync(background: background) }
        work = task
        let result = await task.value
        work = nil
        return result
    }
    private func runSync(background: Bool) async -> Bool {
        guard let disk else { return false }
        busy = true; errorMessage = nil; typeIssues = state.preparationIssues ?? [:]
        defer { busy = false; currentType = "" }
        let deadline = background ? Date().addingTimeInterval(20) : Date.distantFuture
        let entries = HealthCatalog.entries
        var finished = Set<String>()
        do {
            try await client.registerTypes(HealthCatalog.registration, wifiOnly: wifiOnly)
            serverReachable = true
            try await applyWrites(disk: disk)
            if state.historyStart == nil, let start = state.window.start(at: Date()) {
                state.historyStart = start; try disk.save(state)
            }
            while Date() < deadline && finished.count < entries.count {
                try Task.checkCancellation()
                if state.pending != nil {
                    currentType = entries.first(where: { $0.id == state.pending?.typeID })?.title ?? "saved records"
                    try await deliverPending(disk: disk)
                }
                let index = state.nextTypeIndex % entries.count
                let entry = entries[index]
                state.nextTypeIndex = (index + 1) % entries.count
                if finished.contains(entry.id) { continue }
                currentType = entry.title
                notShared.remove(entry.id)
                let limit = entry.type is HKWorkoutType ? Self.workoutPageSize : Self.pageSize
                let page: HealthPage
                do { page = try await health.page(entry: entry, startingAt: state.historyStart, anchor: state.anchors[entry.id], limit: limit) }
                catch is CancellationError { throw CancellationError() }
                catch let error as HKError where [.errorAuthorizationNotDetermined, .errorAuthorizationDenied].contains(error.code) {
                    // Apple Health has not granted this type. That is the user's choice, not a sync failure.
                    notShared.insert(entry.id); finished.insert(entry.id); state.initialScanCompleted.insert(entry.id); continue
                } catch {
                    typeIssues[entry.id] = "Unavailable or not readable right now. Relay will try again."
                    finished.insert(entry.id); continue
                }
                try Task.checkCancellation()
                var next = state
                let prepared = next.preparePage(page, entry: entry)
                // Persist both batches and per-type issues before continuing.
                try disk.save(next); state = next
                guard prepared else {
                    typeIssues[entry.id] = state.preparationIssues?[entry.id]
                    finished.insert(entry.id)
                    continue
                }
                typeIssues[entry.id] = nil
                // Long imports send statistics as they go, so the saved checkpoint stays small.
                if state.statsDays.values.reduce(0, { $0 + $1.count }) > 2 * Self.statsBatch {
                    try await uploadStatistics(until: deadline, disk: disk)
                }
                if page.count < limit {
                    finished.insert(entry.id)
                    // This means this query reached the end of visible data, not that access was granted.
                    state.initialScanCompleted.insert(entry.id)
                }
            }
            // Drain the final collected page even when all types reached their end.
            if state.pending != nil, !Task.isCancelled, Date() < deadline { try await deliverPending(disk: disk) }
            try await uploadStatistics(until: deadline, disk: disk)
            if finished.count == entries.count && typeIssues.isEmpty && state.pending == nil && state.statsDays.isEmpty {
                state.lastScan = Date()
                // Lets the hub tell "nothing new" apart from "not synced recently".
                try await client.markCaughtUp(wifiOnly: wifiOnly)
            }
            try disk.save(state)
            BackgroundCoordinator.schedule(enabled: automatic)
            return typeIssues.isEmpty && state.pending == nil
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            // Leaving the foreground cancels requests in flight. That is not a connection problem.
            return false
        } catch {
            errorMessage = friendly(error)
            if (error as NSError).domain == NSURLErrorDomain { serverReachable = false }
            BackgroundCoordinator.schedule(enabled: automatic)
            return false
        }
    }
    private func deliverPending(disk: SyncStore) async throws {
        var receipt: UploadReceipt?
        do {
            state = try await PendingDelivery.deliver(state, upload: { batch in
                receipt = try await self.client.upload(batch.body, wifiOnly: self.wifiOnly)
                self.serverReachable = true
            }, persist: disk.save)
        } catch RelayError.server(let code) where [400, 413, 422].contains(code) {
            // The hub will refuse this batch on every retry. Skip it rather than block every other type.
            var next = state
            guard let type = next.pending?.typeID, let issue = next.skipPending(status: code) else { return }
            try disk.save(next); state = next; typeIssues[type] = issue
            return
        }
        guard let receipt else { return }
        // Deleted samples carry no date on the iPhone; the hub reports which days they belonged to.
        for (type, days) in receipt.deletedDays ?? [:] where HealthCatalog.metric(type) != nil {
            state.statsDays[type, default: []].formUnion(days)
        }
        if !receipt.rejected.isEmpty { state.rejected += receipt.rejected.count }
        if receipt.deletedDays?.isEmpty == false || !receipt.rejected.isEmpty { try disk.save(state) }
    }
    /// HealthKit merges overlapping sources in its statistics, so the hub receives correct daily totals
    /// for every day touched by new or deleted samples.
    private func uploadStatistics(until deadline: Date, disk: SyncStore) async throws {
        var rows: [[String: Any]] = [], covered: [String: Set<String>] = [:]
        func flush() async throws {
            guard !rows.isEmpty else { return }
            let body = try JSONSerialization.data(withJSONObject: ["batch_id": UUID().uuidString, "daily": rows])
            _ = try await client.upload(body, wifiOnly: wifiOnly)
            for (type, days) in covered {
                state.statsDays[type]?.subtract(days)
                if state.statsDays[type]?.isEmpty == true { state.statsDays[type] = nil }
            }
            try disk.save(state)
            rows = []; covered = [:]
        }
        for (type, days) in state.statsDays.sorted(by: { $0.key < $1.key }) where Date() < deadline {
            try Task.checkCancellation()
            guard let metric = HealthCatalog.metric(type), metric.sampleType != nil else {
                state.statsDays[type] = nil; continue
            }
            currentType = "\(metric.title) totals"
            let stats: [DailyStat]
            do { stats = try await health.dailyStatistics(metric: metric, days: days) }
            catch is CancellationError { throw CancellationError() }
            catch { typeIssues[type] = "Daily totals are unavailable right now. Relay will try again."; continue }
            let zone = TimeZone.current.identifier
            for stat in stats {
                rows.append(["type": type, "date": stat.day, "time_zone": zone, "sum": stat.sum ?? NSNull(), "average": stat.average ?? NSNull(),
                             "minimum": stat.minimum ?? NSNull(), "maximum": stat.maximum ?? NSNull()])
                covered[type, default: []].insert(stat.day)
                if rows.count >= Self.statsBatch { try await flush() }
            }
        }
        try await flush()
    }
    private func applyWrites(disk: SyncStore) async throws {
        writeAccess = writer.access
        // A cancellation that races a write comes back as a removal; a second round applies it right away.
        for _ in 0..<2 {
            let writes = try await client.pull(writeAccess: writeAccess.rawValue, appVersion: Self.appVersion, wifiOnly: wifiOnly)
            waitingForAccess = 0
            var raced = false
            for write in writes {
                try Task.checkCancellation()
                let title = write.meal?.summary ?? "Entry"
                func record(_ detail: String, _ outcome: WriteActivity.Outcome) {
                    state.record(WriteActivity(id: write.id, title: title, detail: detail, outcome: outcome, date: Date()))
                }
                switch write.action {
                case .delete:
                    do { try await writer.delete(writeID: write.id) }
                    catch let error as HKError where [.errorAuthorizationDenied, .errorAuthorizationNotDetermined].contains(error.code) {
                        waitingForAccess += 1; record("Waiting for write access to remove it", .waiting); continue
                    }
                    _ = try await client.ack(write.id, result: "deleted", wifiOnly: wifiOnly)
                    record("Removed from Apple Health", .removed)
                case .write:
                    guard let meal = write.meal else { continue }
                    guard writer.canWrite(meal) else { waitingForAccess += 1; record("Waiting for Apple Health write access", .waiting); continue }
                    let ids: [String]
                    do { ids = try await writer.save(meal, id: write.id, revision: write.revision) }
                    catch let error as HKError where error.code == .errorDatabaseInaccessible { throw error }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as HKError where [.errorAuthorizationDenied, .errorAuthorizationNotDetermined].contains(error.code) {
                        // Not permitted: keep the entry queued on the hub until access is granted.
                        waitingForAccess += 1; record("Waiting for Apple Health write access", .waiting); continue
                    } catch where HealthWriter.isPermanent(error) {
                        _ = try await client.ack(write.id, result: "failed", error: error.localizedDescription, wifiOnly: wifiOnly)
                        record(error.localizedDescription, .failed); continue
                    } catch {
                        // Possibly transient, and the entry may already be saved: leave it queued and retry.
                        record("Will retry: \(error.localizedDescription)", .waiting); continue
                    }
                    let status = try await client.ack(write.id, result: "written", healthKitIDs: ids, wifiOnly: wifiOnly)
                    record("Saved to Apple Health", .saved)
                    raced = raced || status == "delete_requested"
                }
            }
            try disk.save(state)
            if !raced { return }
        }
    }
    func disconnectLocally() async {
        guard !isDemo else { return }
        poller?.cancel(); cancelWork()
        _ = await work?.value
        do {
            try vault.clear(); connected = false; disk = nil; state = SyncState()
            healthRequested = false; defaults.set(false, forKey: "healthRequested")
            serverReachable = nil; errorMessage = nil; waitingForAccess = 0; configureAutomatic()
        } catch { errorMessage = friendly(error) }
    }
    func rescanHistory(window: HistoryWindow) async {
        guard !busy, !isDemo, let disk else { return }
        do {
            var next = state
            try next.prepareRescan(window: window)
            try disk.save(next); state = next
            _ = await sync()
        } catch { errorMessage = friendly(error) }
    }
    private func friendly(_ error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Your Relay Hub couldn’t be reached. Check that this iPhone is on your tailnet. Pending uploads stay on this iPhone."
        }
        if let error = error as? HKError, error.code == .errorDatabaseInaccessible {
            return "Apple Health is locked. Relay continues after you unlock your iPhone."
        }
        return error.localizedDescription
    }
}
