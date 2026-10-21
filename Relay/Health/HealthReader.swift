import Foundation
import HealthKit

struct HealthPage {
    let samples: [HKSample]
    let deletedIDs: [String]
    let anchor: Data
    var count: Int { samples.count + deletedIDs.count }
}

/// "yyyy-MM-dd" in the device's current calendar and time zone, matching HealthKit's daily statistics.
enum LocalDay {
    static func string(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    static func date(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

/// HealthKit's own statistic for one local day. It merges overlapping sources such as iPhone and Apple Watch.
struct DailyStat: Equatable {
    let day: String
    var sum: Double?
    var average: Double?
    var minimum: Double?
    var maximum: Double?
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
        // Writes are limited to the nutrients an AI meal log can queue; everything else is read only.
        try await store.requestAuthorization(toShare: HealthCatalog.writeTypes, read: HealthCatalog.readTypes)
    }
    static func historyPredicate(startingAt date: Date?) -> NSPredicate? {
        date.map { HKQuery.predicateForSamples(withStart: $0, end: nil, options: .strictStartDate) }
    }
    func page(entry: HealthEntry, startingAt start: Date?, anchor data: Data?, limit: Int) async throws -> HealthPage {
        try Task.checkCancellation()
        let anchor = try data.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) } ?? nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let id = UUID()
                queryID = id
                pending = continuation
                let query = HKAnchoredObjectQuery(type: entry.type, predicate: Self.historyPredicate(startingAt: start), anchor: anchor, limit: limit) { [weak self] _, samples, deleted, next, error in
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
    /// Daily sums for cumulative types, or average/min/max for the rest, on the given local days.
    /// A day without data comes back empty, so the hub can drop a stale value.
    func dailyStatistics(metric: HealthMetric, days: Set<String>) async throws -> [DailyStat] {
        guard let type = metric.sampleType, let first = days.min().flatMap(LocalDay.date), let last = days.max().flatMap(LocalDay.date),
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return [] }
        let cumulative = type.aggregationStyle == .cumulative
        let predicate = HKQuery.predicateForSamples(withStart: first, end: end)
        let collection = try await HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax],
            anchorDate: first, intervalComponents: DateComponents(day: 1)).result(for: store)
        func value(_ quantity: HKQuantity?) -> Double? {
            guard let quantity, quantity.is(compatibleWith: metric.hkUnit) else { return nil }
            let value = quantity.doubleValue(for: metric.hkUnit) * metric.scale
            return value.isFinite ? value : nil
        }
        var stats: [String: DailyStat] = [:]
        collection.enumerateStatistics(from: first, to: end) { statistics, _ in
            let day = LocalDay.string(statistics.startDate)
            stats[day] = cumulative
                ? DailyStat(day: day, sum: value(statistics.sumQuantity()))
                : DailyStat(day: day, average: value(statistics.averageQuantity()), minimum: value(statistics.minimumQuantity()),
                            maximum: value(statistics.maximumQuantity()))
        }
        return days.sorted().map { stats[$0] ?? DailyStat(day: $0) }
    }
    func observe(onChange: @escaping (@escaping () -> Void) -> Void) {
        guard observers.isEmpty else { return }
        // Food entries change together with their nutrients, which are observed already.
        for entry in HealthCatalog.entries where !(entry.type is HKCorrelationType) {
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
        for entry in HealthCatalog.entries where !(entry.type is HKCorrelationType) { store.disableBackgroundDelivery(for: entry.type) { _, _ in } }
    }
}
