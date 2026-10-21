import Foundation
import HealthKit
import Observation
import CryptoKit
import UIKit

/// Protected on-disk checkpoint for Relay Hub, isolated per hub address and paired device.
final class HubStore {
    private let file: URL
    init(credentials: HubCredentials, directory: URL? = nil) throws {
        let hash = SHA256.hash(data: Data((credentials.server.url.absoluteString + "/" + credentials.deviceID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        file = directory.appendingPathComponent("hub-" + hash + ".json")
    }
    func load() throws -> HubState {
        guard FileManager.default.fileExists(atPath: file.path) else { return HubState() }
        return try JSONDecoder().decode(HubState.self, from: Data(contentsOf: file))
    }
    func save(_ state: HubState) throws {
        try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Relay Hub sync: apply queued Apple Health writes, then upload nutrition. Independent of the Open Wearables sync.
@MainActor @Observable
final class HubModel {
    static let shared = HubModel()
    var isDemo = false
    var paired = false
    var serverText = ""
    var deviceName = ""
    var accessRequested = false
    var writeAccess = WriteAccess.notDetermined
    var busy = false
    var pairing = false
    var reachable: Bool?
    var errorMessage: String?
    var waitingForAccess = 0
    var typeIssues: [String: String] = [:]
    var lastSync: Date?
    var state = HubState()
    @ObservationIgnored let health = NutritionHealth()
    @ObservationIgnored let client = HubClient()
    @ObservationIgnored private let vault = HubVault.keychain
    @ObservationIgnored private var disk: HubStore?
    @ObservationIgnored private var work: Task<Bool, Never>?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var restoreFailed = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    static let historyPages = 500
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0" }

    init(demo: Bool = ProcessInfo.processInfo.arguments.contains("--demo")) {
        isDemo = demo
        guard !demo else { return }
        accessRequested = defaults.bool(forKey: "hubHealthRequested")
        restore()
    }
    var statusText: String {
        if !paired { return "Not paired" }
        if !accessRequested || writeAccess != .authorized { return "Allow access" }
        if errorMessage != nil || waitingForAccess > 0 || !typeIssues.isEmpty { return "Needs attention" }
        return reachable == false ? "Unreachable" : "Connected"
    }
    var wantsBackground: Bool { paired && accessRequested && AppModel.shared.automatic }
    private func restore() {
        do {
            restoreFailed = false
            guard let credentials = try vault.read() else { return }
            disk = try HubStore(credentials: credentials); state = try disk!.load()
            serverText = credentials.server.url.absoluteString; deviceName = credentials.name; paired = true
            writeAccess = health.writeAccess
        } catch { restoreFailed = true; errorMessage = error.localizedDescription }
    }
    /// The Keychain or checkpoint can be unreadable before first unlock; retry instead of looking unpaired.
    private func recoverIfNeeded() {
        guard restoreFailed else { return }
        restore()
        if paired { errorMessage = nil; configureAutomatic() }
    }
    func start() {
        guard !isDemo else { return }
        if !paired { restore() }
        configureAutomatic()
    }
    func pair(address: String, code: String) async {
        guard !pairing, !isDemo, !paired else { return }
        pairing = true; errorMessage = nil
        defer { pairing = false }
        do {
            let credentials = try await client.pair(server: try ServerAddress(address), code: code, deviceName: UIDevice.current.name)
            disk = try HubStore(credentials: credentials); state = try disk!.load()
            serverText = credentials.server.url.absoluteString; deviceName = credentials.name
            paired = true; reachable = true
            configureAutomatic()
        } catch { errorMessage = friendly(error) }
    }
    func requestAccess() async {
        guard !isDemo else { return }
        errorMessage = nil
        do {
            try await health.requestAccess()
            accessRequested = true; defaults.set(true, forKey: "hubHealthRequested")
            writeAccess = health.writeAccess
            configureAutomatic()
            becameActive()
        } catch { errorMessage = friendly(error) }
    }
    func disconnect() {
        guard !isDemo, !busy else { return }
        poller?.cancel(); work?.cancel()
        do {
            try vault.clear(); paired = false; disk = nil; state = HubState()
            reachable = nil; errorMessage = nil; waitingForAccess = 0
            configureAutomatic()
        } catch { errorMessage = friendly(error) }
    }
    func configureAutomatic() {
        guard !isDemo else { return }
        if wantsBackground {
            health.observe { [weak self] completion in
                guard let self else { completion(); return }
                if self.backgroundTask == .invalid {
                    self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Relay Hub delivery") { [weak self] in
                        // Called on the main thread; the task must end before this handler returns.
                        MainActor.assumeIsolated { self?.work?.cancel(); self?.endBackgroundTask() }
                    }
                }
                Task { @MainActor in
                    _ = await self.sync(background: true)
                    completion()
                    self.endBackgroundTask()
                }
            }
        } else { health.stopObserving() }
        BackgroundCoordinator.schedule(enabled: AppModel.shared.connected && AppModel.shared.automatic && AppModel.shared.healthRequested)
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
    }
    /// While Relay is open, check for new entries every 90 seconds so logged meals appear quickly.
    func becameActive() {
        guard !isDemo else { return }
        recoverIfNeeded()
        guard paired else { return }
        writeAccess = health.writeAccess
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.sync()
                try? await Task.sleep(for: .seconds(90))
            }
        }
    }
    func enteredBackground() { poller?.cancel(); poller = nil; work?.cancel() }
    func cancelWork() { work?.cancel() }
    func sync(background: Bool = false) async -> Bool {
        if isDemo { return true }
        if let work { return await work.value }
        recoverIfNeeded()
        guard paired, accessRequested else { return false }
        let app = AppModel.shared
        if background && !app.automatic { return false }
        guard app.networkAvailable, !app.wifiOnly || app.onWiFi else { return false }
        let task = Task { await run(deadline: Date().addingTimeInterval(background ? 20 : 120), wifiOnly: app.wifiOnly) }
        work = task
        let result = await task.value
        work = nil
        return result
    }
    private func run(deadline: Date, wifiOnly: Bool) async -> Bool {
        guard let disk else { return false }
        busy = true; errorMessage = nil
        defer { busy = false }
        writeAccess = health.writeAccess
        do {
            try await applyWrites(wifiOnly: wifiOnly, disk: disk)
            try await uploadNutrition(until: deadline, wifiOnly: wifiOnly, disk: disk)
            reachable = true; lastSync = Date()
            return state.pending == nil
        } catch is CancellationError {
            return false
        } catch let error as URLError where error.code == .cancelled {
            // Leaving the foreground cancels requests in flight. That is not a connection problem.
            return false
        } catch {
            errorMessage = friendly(error)
            if (error as NSError).domain == NSURLErrorDomain { reachable = false }
            return false
        }
    }
    private func applyWrites(wifiOnly: Bool, disk: HubStore) async throws {
        // A cancellation that races a write comes back as a removal; a second round applies it right away.
        for _ in 0..<2 {
            let writes = try await client.pull(writeAccess: writeAccess.rawValue, appVersion: Self.appVersion, wifiOnly: wifiOnly)
            state.lastPull = Date(); waitingForAccess = 0
            var raced = false
            for write in writes {
                try Task.checkCancellation()
                let title = write.meal.map { meal in meal.energy.map { "\(meal.title) · \(Int($0.rounded())) kcal" } ?? meal.title } ?? "Entry"
                switch write.action {
                case .delete:
                    do { try await health.delete(writeID: write.id) }
                    catch let error as HKError where [.errorAuthorizationDenied, .errorAuthorizationNotDetermined].contains(error.code) {
                        waitingForAccess += 1
                        state.record(HubActivity(id: write.id, title: title, detail: "Waiting for write access to remove it", outcome: .waiting, date: Date()))
                        continue
                    }
                    _ = try await client.ack(write.id, result: "deleted", wifiOnly: wifiOnly)
                    state.record(HubActivity(id: write.id, title: title, detail: "Removed from Apple Health", outcome: .removed, date: Date()))
                case .write:
                    guard let meal = write.meal else { continue }
                    guard health.canWrite(meal) else {
                        waitingForAccess += 1
                        state.record(HubActivity(id: write.id, title: title, detail: "Waiting for Apple Health write access", outcome: .waiting, date: Date()))
                        continue
                    }
                    let ids: [String]
                    do { ids = try await health.save(meal, id: write.id, revision: write.revision) }
                    catch let error as HKError where error.code == .errorDatabaseInaccessible { throw error }
                    catch is CancellationError { throw CancellationError() }
                    catch let error as HKError where [.errorAuthorizationDenied, .errorAuthorizationNotDetermined].contains(error.code) {
                        // Not permitted: keep the entry queued on the hub until access is granted.
                        waitingForAccess += 1
                        state.record(HubActivity(id: write.id, title: title, detail: "Waiting for Apple Health write access", outcome: .waiting, date: Date()))
                        continue
                    } catch where Self.isPermanent(error) {
                        _ = try await client.ack(write.id, result: "failed", error: error.localizedDescription, wifiOnly: wifiOnly)
                        state.record(HubActivity(id: write.id, title: title, detail: error.localizedDescription, outcome: .failed, date: Date()))
                        continue
                    } catch {
                        // Possibly transient, and the entry may already be saved: leave it queued and retry.
                        state.record(HubActivity(id: write.id, title: title, detail: "Will retry: \(error.localizedDescription)", outcome: .waiting, date: Date()))
                        continue
                    }
                    let status = try await client.ack(write.id, result: "written", healthKitIDs: ids, wifiOnly: wifiOnly)
                    state.record(HubActivity(id: write.id, title: title, detail: "Saved to Apple Health", outcome: .saved, date: Date()))
                    raced = raced || status == "delete_requested"
                }
            }
            try disk.save(state)
            if !raced { return }
        }
    }
    private func uploadNutrition(until deadline: Date, wifiOnly: Bool, disk: HubStore) async throws {
        if state.historyStart == nil {
            state.historyStart = Calendar.current.date(byAdding: .day, value: -HubState.historyDays, to: Date())
            try disk.save(state)
        }
        guard let start = state.historyStart else { return }
        try await deliverPending(wifiOnly: wifiOnly, disk: disk)
        typeIssues = [:]
        var caughtUp = true
        for type in NutritionCatalog.syncTypes {
            var finished = false
            while Date() < deadline {
                try Task.checkCancellation()
                let page: HealthPage
                do { page = try await health.page(type: type, from: start, anchor: state.anchors[type.identifier], limit: Self.historyPages) }
                catch let error as HKError where error.code == .errorDatabaseInaccessible { throw error }
                catch is CancellationError { throw CancellationError() }
                catch { typeIssues[type.identifier] = error.localizedDescription; break }
                var next = state; next.pending = NutritionPayload.batch(page: page, typeID: type.identifier)
                try disk.save(next); state = next
                try await deliverPending(wifiOnly: wifiOnly, disk: disk)
                if page.count < Self.historyPages { finished = true; break }
            }
            caughtUp = caughtUp && finished
        }
        // Lets the hub tell "nothing new" apart from "not synced recently".
        if caughtUp { try await client.markCaughtUp(wifiOnly: wifiOnly) }
    }
    /// Only failures that would recur are reported; anything else stays queued for another attempt.
    static func isPermanent(_ error: Error) -> Bool {
        if error is HubError { return true }
        return (error as? HKError)?.code == .errorInvalidArgument
    }
    /// The saved batch stays on disk until the hub accepts it; only then does its HealthKit anchor advance.
    private func deliverPending(wifiOnly: Bool, disk: HubStore) async throws {
        guard let batch = state.pending else { return }
        var next = state
        if batch.recordCount > 0 || batch.deletions > 0 {
            next.rejected += try await client.upload(batch, wifiOnly: wifiOnly).rejected.count
        }
        next.commitPending()
        try disk.save(next); state = next
    }
    private func friendly(_ error: Error) -> String {
        if (error as NSError).domain == NSURLErrorDomain {
            return "Relay Hub couldn’t be reached. Check that this iPhone is on your tailnet. Nothing was lost."
        }
        if let error = error as? HKError, error.code == .errorDatabaseInaccessible {
            return "Apple Health is locked. Relay continues after you unlock your iPhone."
        }
        return error.localizedDescription
    }
}
