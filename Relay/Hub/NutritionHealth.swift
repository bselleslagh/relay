import Foundation
import HealthKit

enum WriteAccess: String { case authorized, partial, denied, notDetermined = "not_determined" }

/// HealthKit access for Relay Hub: nutrition reads, and writes of queued meals only.
@MainActor
final class NutritionHealth {
    let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw RelayError.healthUnavailable }
        try await store.requestAuthorization(toShare: NutritionCatalog.writeTypes, read: NutritionCatalog.readTypes)
    }
    /// Apple reports write permission truthfully, unlike read permission.
    func canWrite(_ nutrient: Nutrient) -> Bool { store.authorizationStatus(for: nutrient.type) == .sharingAuthorized }
    var writeAccess: WriteAccess {
        let statuses = NutritionCatalog.writable.map { store.authorizationStatus(for: $0.type) }
        if statuses.allSatisfy({ $0 == .sharingAuthorized }) { return .authorized }
        if statuses.allSatisfy({ $0 == .notDetermined }) { return .notDetermined }
        return statuses.contains(.sharingAuthorized) ? .partial : .denied
    }
    func canWrite(_ meal: MealWrite) -> Bool {
        meal.nutrients.keys.allSatisfy { key in NutritionCatalog.nutrient(key: key).map(canWrite) ?? true }
    }
    func page(type: HKSampleType, from start: Date, anchor data: Data?, limit: Int) async throws -> HealthPage {
        let anchor = try data.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        let samples: [HKSample], deleted: [HKDeletedObject], next: HKQueryAnchor
        if let quantity = type as? HKQuantityType {
            let result = try await HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: quantity, predicate: predicate)],
                                                                   anchor: anchor, limit: limit).result(for: store)
            (samples, deleted, next) = (result.addedSamples, result.deletedObjects, result.newAnchor)
        } else if let correlation = type as? HKCorrelationType {
            let result = try await HKAnchoredObjectQueryDescriptor(predicates: [.correlation(type: correlation, predicate: predicate)],
                                                                   anchor: anchor, limit: limit).result(for: store)
            (samples, deleted, next) = (result.addedSamples, result.deletedObjects, result.newAnchor)
        } else { throw RelayError.invalidHealthPage }
        return HealthPage(samples: samples, deletedIDs: deleted.map(\.uuid.uuidString),
                          anchor: try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true))
    }
    /// Saves a queued meal at most once and returns its HealthKit UUIDs, including those of an earlier save.
    func save(_ meal: MealWrite, id: String, revision: Int) async throws -> [String] {
        let existing = try await written(id)
        if !existing.isEmpty { return uuids(existing) }
        let correlation = try NutritionPayload.correlation(for: meal, id: id, revision: revision)
        try await store.save(correlation)
        return uuids([correlation])
    }
    /// Removes everything Relay wrote for a queue entry. Apps can only delete their own samples.
    func delete(writeID id: String) async throws {
        let correlations = try await written(id)
        if !correlations.isEmpty { try await store.delete(correlations + correlations.flatMap(\.objects)) }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HubMetadata.writeID, allowedValues: [id])
        for nutrient in NutritionCatalog.writable where canWrite(nutrient) {
            do { _ = try await store.deleteObjects(of: nutrient.type, predicate: predicate) }
            catch let error as HKError where error.code == .errorNoData {}
        }
    }
    private func written(_ id: String) async throws -> [HKCorrelation] {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HubMetadata.writeID, allowedValues: [id])
        return try await HKSampleQueryDescriptor(predicates: [.correlation(type: NutritionCatalog.food, predicate: predicate)],
                                                 sortDescriptors: []).result(for: store)
    }
    private func uuids(_ correlations: [HKCorrelation]) -> [String] {
        correlations.flatMap { [$0.uuid.uuidString] + $0.objects.map(\.uuid.uuidString).sorted() }
    }
    func observe(onChange: @escaping (@escaping () -> Void) -> Void) {
        guard observers.isEmpty else { return }
        for nutrient in NutritionCatalog.nutrients {
            let query = HKObserverQuery(sampleType: nutrient.type, predicate: nil) { _, complete, error in
                guard error == nil else { complete(); return }
                Task { @MainActor in onChange(complete) }
            }
            observers.append(query); store.execute(query)
            store.enableBackgroundDelivery(for: nutrient.type, frequency: .immediate) { _, _ in }
        }
    }
    func stopObserving() {
        observers.forEach(store.stop); observers = []
        for nutrient in NutritionCatalog.nutrients { store.disableBackgroundDelivery(for: nutrient.type) { _, _ in } }
    }
}
