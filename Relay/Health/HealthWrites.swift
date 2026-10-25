import Foundation
import HealthKit

/// Metadata Relay attaches to everything it writes, so samples trace back to their Relay Hub queue entry.
enum HubMetadata {
    static let writeID = "RelayWriteID"
    static let mealType = "RelayMealType"
    static func syncIdentifier(_ writeID: String, nutrient: String? = nil) -> String {
        ["relay-hub", writeID, nutrient].compactMap { $0 }.joined(separator: ".")
    }
}

/// A queued Apple Health change, as returned by `POST /v1/writes/pull`.
struct HubWrite: Decodable, Identifiable {
    enum Action: String, Decodable { case write, delete }
    let id: String
    let kind: String
    let action: Action
    let revision: Int
    let meal: MealWrite?
    private enum Keys: String, CodingKey { case id, kind, action, revision, data }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        action = try container.decode(Action.self, forKey: .action)
        revision = try container.decode(Int.self, forKey: .revision)
        meal = kind == "meal" ? try container.decode(MealWrite.self, forKey: .data) : nil
    }
}

struct MealWrite: Decodable {
    let consumedAt: Date
    let utcOffset: String
    let timeZone: String?
    let name: String?
    let mealType: String?
    let nutrients: [String: Double]
    private enum Keys: String, CodingKey {
        case consumedAt = "consumed_at", utcOffset = "utc_offset", timeZone = "time_zone", name, mealType = "meal_type", nutrients
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let text = try container.decode(String.self, forKey: .consumedAt)
        guard let date = ISO8601DateFormatter().date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: .consumedAt, in: container, debugDescription: "Not ISO 8601")
        }
        consumedAt = date
        utcOffset = try container.decode(String.self, forKey: .utcOffset)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        mealType = try container.decodeIfPresent(String.self, forKey: .mealType)
        nutrients = try container.decode([String: Double].self, forKey: .nutrients)
    }
    var zone: TimeZone {
        if let timeZone, let zone = TimeZone(identifier: timeZone) { return zone }
        let sign = utcOffset.hasPrefix("-") ? -1 : 1
        let parts = utcOffset.dropFirst().split(separator: ":").compactMap { Int($0) }
        let seconds = parts.count == 2 ? sign * (parts[0] * 3600 + parts[1] * 60) : 0
        return TimeZone(secondsFromGMT: seconds) ?? .current
    }
    var title: String { name ?? mealType?.capitalized ?? "Meal" }
    var energy: Double? { nutrients["energy_kcal"] }
    var summary: String { energy.map { "\(title) · \(Int($0.rounded())) kcal" } ?? title }

    /// One Apple Health food entry per meal. Every object carries the queue entry's ID and a stable sync identifier,
    /// so a retried save replaces rather than duplicates, and Relay Hub can trace each sample.
    func correlation(id: String, revision: Int) throws -> HKCorrelation {
        var shared: [String: Any] = [HKMetadataKeyTimeZone: zone.identifier, HKMetadataKeyWasUserEntered: true, HubMetadata.writeID: id]
        if let name { shared[HKMetadataKeyFoodType] = name }
        if let mealType { shared[HubMetadata.mealType] = mealType }
        var samples = Set<HKSample>()
        for (key, value) in nutrients.sorted(by: { $0.key < $1.key }) {
            guard let nutrient = NutritionCatalog.nutrient(key: key), nutrient.writable else { throw RelayError.unsupportedNutrient(key) }
            guard value.isFinite, value >= 0 else { throw RelayError.invalidValue(key) }
            var metadata = shared
            metadata[HKMetadataKeySyncIdentifier] = HubMetadata.syncIdentifier(id, nutrient: key)
            metadata[HKMetadataKeySyncVersion] = revision
            samples.insert(HKQuantitySample(type: nutrient.type, quantity: HKQuantity(unit: nutrient.unit, doubleValue: value),
                                            start: consumedAt, end: consumedAt, metadata: metadata))
        }
        guard energy != nil else { throw RelayError.invalidValue("energy_kcal") }
        var metadata = shared
        metadata[HKMetadataKeySyncIdentifier] = HubMetadata.syncIdentifier(id)
        metadata[HKMetadataKeySyncVersion] = revision
        return HKCorrelation(type: HealthCatalog.food, start: consumedAt, end: consumedAt, objects: samples, metadata: metadata)
    }
}

enum WriteAccess: String { case authorized, partial, denied, notDetermined = "not_determined" }

/// Writes queued meals to Apple Health. Relay only ever writes the six nutrients in `NutritionCatalog.writable`.
@MainActor
final class HealthWriter {
    let store = HKHealthStore()
    /// Apple reports write permission truthfully, unlike read permission.
    func canWrite(_ nutrient: Nutrient) -> Bool { store.authorizationStatus(for: nutrient.type) == .sharingAuthorized }
    var access: WriteAccess {
        let statuses = NutritionCatalog.writable.map { store.authorizationStatus(for: $0.type) }
        if statuses.allSatisfy({ $0 == .sharingAuthorized }) { return .authorized }
        if statuses.allSatisfy({ $0 == .notDetermined }) { return .notDetermined }
        return statuses.contains(.sharingAuthorized) ? .partial : .denied
    }
    func canWrite(_ meal: MealWrite) -> Bool {
        meal.nutrients.keys.allSatisfy { key in NutritionCatalog.nutrient(key: key).map(canWrite) ?? true }
    }
    /// Saves a queued meal at most once and returns its HealthKit UUIDs, including those of an earlier save.
    func save(_ meal: MealWrite, id: String, revision: Int) async throws -> [String] {
        let existing = try await written(id)
        if !existing.isEmpty { return uuids(existing) }
        let correlation = try meal.correlation(id: id, revision: revision)
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
        return try await HKSampleQueryDescriptor(predicates: [.correlation(type: HealthCatalog.food, predicate: predicate)],
                                                 sortDescriptors: []).result(for: store)
    }
    private func uuids(_ correlations: [HKCorrelation]) -> [String] {
        correlations.flatMap { [$0.uuid.uuidString] + $0.objects.map(\.uuid.uuidString).sorted() }
    }
    /// Only failures that would recur are reported to Relay Hub; anything else stays queued for another attempt.
    static func isPermanent(_ error: Error) -> Bool {
        switch error as? RelayError {
        case .unsupportedNutrient, .invalidValue: return true
        default: return (error as? HKError)?.code == .errorInvalidArgument
        }
    }
}
