import Foundation
import HealthKit

struct HealthPage {
    let samples: [HKSample]
    let deletedIDs: [String]
    let anchor: Data
    var count: Int { samples.count + deletedIDs.count }
}

@MainActor
final class HealthReader {
    let store = HKHealthStore()
    private var activeQuery: HKQuery?
    private var pending: CheckedContinuation<HealthPage, Error>?
    private var queryID: UUID?
    private var observers: [HKObserverQuery] = []
    func authorize() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw RelayError.healthUnavailable }
        try await store.requestAuthorization(toShare: [], read: HealthCatalog.readTypes)
    }
    func page(entry: HealthEntry, anchor data: Data?, limit: Int) async throws -> HealthPage {
        try Task.checkCancellation()
        let anchor = try data.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) } ?? nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                queryID = id
                pending = continuation
                let query = HKAnchoredObjectQuery(type: entry.type, predicate: nil, anchor: anchor, limit: limit) { [weak self] _, samples, deleted, next, error in
                    Task { @MainActor in
                        guard let self, self.queryID == id, let continuation = self.pending else { return }
                        self.pending = nil; self.activeQuery = nil; self.queryID = nil
                        if let error { continuation.resume(throwing: error); return }
                        guard let next else { continuation.resume(throwing: RelayError.invalidHealthPage); return }
                        do {
                            let data = try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true)
                            continuation.resume(returning: HealthPage(samples: samples ?? [], deletedIDs: (deleted ?? []).map { $0.uuid.uuidString }, anchor: data))
                        } catch { continuation.resume(throwing: error) }
                    }
                }
                activeQuery = query; store.execute(query)
                if Task.isCancelled { cancelQuery() }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancelQuery() } }
    }
    func cancelQuery() {
        if let activeQuery { store.stop(activeQuery) }
        activeQuery = nil
        queryID = nil
        pending?.resume(throwing: CancellationError()); pending = nil
    }
    func observe(onChange: @escaping (@escaping () -> Void) -> Void) {
        guard observers.isEmpty else { return }
        for entry in HealthCatalog.entries {
            let query = HKObserverQuery(sampleType: entry.type, predicate: nil) { _, complete, error in
                guard error == nil else { complete(); return }
                Task { @MainActor in onChange(complete) }
            }
            observers.append(query); store.execute(query)
            store.enableBackgroundDelivery(for: entry.type, frequency: .immediate) { _, _ in }
        }
    }
    func stopObserving() {
        observers.forEach(store.stop); observers = []
        for entry in HealthCatalog.entries { store.disableBackgroundDelivery(for: entry.type) { _, _ in } }
    }
}
