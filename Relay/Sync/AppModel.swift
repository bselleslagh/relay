import Foundation
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
    @ObservationIgnored let health = HealthReader()
    @ObservationIgnored let client = WearablesClient()
    @ObservationIgnored private let vault = KeychainStore()
    @ObservationIgnored private var disk: SyncStore?
    @ObservationIgnored private var work: Task<Bool, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var credentialFailure = false
    @ObservationIgnored private var observerBackgroundTask = UIBackgroundTaskIdentifier.invalid

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        isDemo = demo
        if demo {
            serverText = "https://health.example.com"
            connected = true; healthRequested = true; serverReachable = true
            state.sentToday = 1284; state.totalSent = 1284; state.lastAccepted = Date()
            state.sentByGroup = [.activity: 684, .vitals: 348, .sleep: 28, .workouts: 1, .body: 223]
            state.initialScanCompleted = Set(HealthCatalog.entries.map(\.id))
            return
        }
        automatic = defaults.object(forKey: "automatic") as? Bool ?? true
        wifiOnly = defaults.bool(forKey: "wifiOnly")
        healthRequested = defaults.bool(forKey: "healthRequested")
        serverText = defaults.string(forKey: "server") ?? ""
        restore()
    }
    var sentToday: Int { Calendar.current.isDateInToday(state.day) ? state.sentToday : 0 }
    var pendingCount: Int { state.pending?.recordCount ?? 0 }
    var historyComplete: Bool { Set(HealthCatalog.entries.map(\.id)).isSubset(of: state.initialScanCompleted) }
    var heading: String {
        if isDemo { return "In sync." }
        if !connected { return "A home for\nyour health." }
        if !healthRequested { return "Your next step." }
        if busy { return "On its way." }
        if errorMessage != nil || !typeIssues.isEmpty { return "Needs a moment." }
        if !automatic { return "Taking a pause." }
        if state.lastAccepted != nil { return "Sent home." }
        return "Ready when you are."
    }
    var subtitle: String {
        if isDemo { return "Your health data, safely home." }
        if !connected { return "Connect Apple Health to your own server." }
        if !healthRequested { return "Choose what Relay can read in Apple Health." }
        if busy { return "Sending \(currentType.lowercased())…" }
        if errorMessage != nil { return "Sync paused. Your saved progress is kept for retry." }
        if !typeIssues.isEmpty { return "Some health types need attention. Other data can still sync." }
        if !automatic { return "Automatic sync is paused. Manual sync is available." }
        if state.lastAccepted != nil { return "Your latest upload is queued on your server." }
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
                serverText = credentials.server.url.absoluteString; connected = true
            }
            credentialFailure = false
        } catch { credentialFailure = true; errorMessage = error.localizedDescription }
    }
    func foreground() async {
        guard !isDemo else { return }
        if credentialFailure { restore(); configureAutomatic() }
        if connected && automatic && healthRequested { _ = await sync() }
    }
    func pair(address: String, code: String) async {
        guard !pairing, !isDemo, !connected else { return }
        pairing = true; errorMessage = nil
        defer { pairing = false }
        do {
            let server = try ServerAddress(address)
            try await client.check(server: server)
            let credentials = try await client.pair(server: server, code: code)
            disk = try SyncStore(account: credentials); state = try disk!.load()
            serverText = server.url.absoluteString; defaults.set(serverText, forKey: "server")
            connected = true; serverReachable = true
            configureAutomatic()
        } catch { errorMessage = friendly(error) }
    }
    func authorize() async {
        guard !isDemo else { return }
        errorMessage = nil
        do {
            try await health.authorize()
            // Completion means the permission sheet completed, not that read access was granted.
            healthRequested = true; defaults.set(true, forKey: "healthRequested")
            configureAutomatic()
            _ = await sync()
        } catch { errorMessage = friendly(error) }
    }
    func checkConnection() async {
        guard !isDemo else { return }
        do {
            try await client.check(server: ServerAddress(serverText)); serverReachable = true
            lastCheck = Date(); errorMessage = nil
        } catch { serverReachable = false; errorMessage = friendly(error) }
    }
    func setAutomatic(_ value: Bool) {
        automatic = value
        guard !isDemo else { return }
        defaults.set(value, forKey: "automatic")
        if !value { work?.cancel(); health.cancelQuery() }
        configureAutomatic()
    }
    func setWiFiOnly(_ value: Bool) {
        wifiOnly = value
        guard !isDemo else { return }
        defaults.set(value, forKey: "wifiOnly")
        work?.cancel(); health.cancelQuery()
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
                        Task { @MainActor in self?.cancelWork() }
                    }
                }
                Task { @MainActor in
                    _ = await self.sync(background: true)
                    completion()
                    if self.observerBackgroundTask != .invalid {
                        UIApplication.shared.endBackgroundTask(self.observerBackgroundTask)
                        self.observerBackgroundTask = .invalid
                    }
                }
            }
        } else { health.stopObserving() }
        BackgroundCoordinator.schedule(enabled: enabled)
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
        let sessionID = UUID().uuidString
        var finished = Set<String>()
        do {
            while Date() < deadline && finished.count < entries.count {
                try Task.checkCancellation()
                if let pending = state.pending {
                    currentType = entries.first(where: { $0.id == pending.typeID })?.title ?? "saved records"
                    state = try await PendingDelivery.deliver(state, upload: { batch in
                        try await self.client.upload(batch, wifiOnly: self.wifiOnly)
                        self.serverReachable = true
                    }, persist: disk.save)
                }
                let index = state.nextTypeIndex % entries.count
                let entry = entries[index]
                state.nextTypeIndex = (index + 1) % entries.count
                if finished.contains(entry.id) { continue }
                currentType = entry.title
                let page: HealthPage
                do { page = try await health.page(entry: entry, anchor: state.anchors[entry.id], limit: 200) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    typeIssues[entry.id] = "Unavailable or not readable right now. Relay will try again."
                    finished.insert(entry.id); continue
                }
                try Task.checkCancellation()
                var next = state
                let prepared = next.preparePage(page, entry: entry, sessionID: sessionID,
                                                historical: !state.initialScanCompleted.contains(entry.id))
                // Persist both batches and per-type issues before continuing.
                try disk.save(next); state = next
                guard prepared else {
                    typeIssues[entry.id] = state.preparationIssues?[entry.id]
                    finished.insert(entry.id)
                    continue
                }
                typeIssues[entry.id] = nil
                if page.count < 200 {
                    finished.insert(entry.id)
                    // This means this query reached the end of visible data, not that access was granted.
                    state.initialScanCompleted.insert(entry.id)
                }
            }
            // Drain the final collected page even when all types reached their end.
            if state.pending != nil, !Task.isCancelled, Date() < deadline {
                state = try await PendingDelivery.deliver(state, upload: { batch in
                    try await self.client.upload(batch, wifiOnly: self.wifiOnly)
                    self.serverReachable = true
                }, persist: disk.save)
            }
            if finished.count == entries.count && typeIssues.isEmpty && state.pending == nil { state.lastScan = Date() }
            try disk.save(state)
            BackgroundCoordinator.schedule(enabled: automatic)
            return typeIssues.isEmpty && state.pending == nil
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = friendly(error)
            if (error as NSError).domain == NSURLErrorDomain { serverReachable = false }
            BackgroundCoordinator.schedule(enabled: automatic)
            return false
        }
    }
    func disconnectLocally() {
        guard !isDemo else { return }
        cancelWork()
        // Called only when no upload is running; retained checkpoints are isolated by account and host.
        guard !busy else { return }
        do {
            try vault.clear(); connected = false; disk = nil; state = SyncState()
            healthRequested = false; defaults.set(false, forKey: "healthRequested")
            serverReachable = nil; errorMessage = nil; configureAutomatic()
        } catch { errorMessage = friendly(error) }
    }
    func rescanHistory() async {
        guard !busy, !isDemo, let disk else { return }
        do {
            var next = state
            try next.prepareFullRescan()
            try disk.save(next); state = next
            _ = await sync()
        } catch { errorMessage = friendly(error) }
    }
    private func friendly(_ error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Your server couldn’t be reached. Check your network connection. Pending uploads stay on this iPhone."
        }
        return error.localizedDescription
    }
}
