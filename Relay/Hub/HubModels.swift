import Foundation
import HealthKit

/// Nutrition types shared with Relay Hub. Keys carry their unit and match the server's catalog.
struct Nutrient: Identifiable {
    let key: String
    let identifier: HKQuantityTypeIdentifier
    let unit: HKUnit
    let unitLabel: String
    let title: String
    var writable = false
    var id: String { key }
    var type: HKQuantityType { HKQuantityType(identifier) }
}

enum NutritionCatalog {
    static let nutrients: [Nutrient] = [
        Nutrient(key: "energy_kcal", identifier: .dietaryEnergyConsumed, unit: .kilocalorie(), unitLabel: "kcal", title: "Energy", writable: true),
        Nutrient(key: "protein_g", identifier: .dietaryProtein, unit: .gram(), unitLabel: "g", title: "Protein", writable: true),
        Nutrient(key: "carbohydrates_g", identifier: .dietaryCarbohydrates, unit: .gram(), unitLabel: "g", title: "Carbohydrates", writable: true),
        Nutrient(key: "fat_g", identifier: .dietaryFatTotal, unit: .gram(), unitLabel: "g", title: "Total fat", writable: true),
        Nutrient(key: "fiber_g", identifier: .dietaryFiber, unit: .gram(), unitLabel: "g", title: "Fiber", writable: true),
        Nutrient(key: "sugar_g", identifier: .dietarySugar, unit: .gram(), unitLabel: "g", title: "Sugar", writable: true),
        Nutrient(key: "saturated_fat_g", identifier: .dietaryFatSaturated, unit: .gram(), unitLabel: "g", title: "Saturated fat"),
        Nutrient(key: "sodium_mg", identifier: .dietarySodium, unit: .gramUnit(with: .milli), unitLabel: "mg", title: "Sodium"),
        Nutrient(key: "cholesterol_mg", identifier: .dietaryCholesterol, unit: .gramUnit(with: .milli), unitLabel: "mg", title: "Cholesterol"),
        Nutrient(key: "caffeine_mg", identifier: .dietaryCaffeine, unit: .gramUnit(with: .milli), unitLabel: "mg", title: "Caffeine"),
        Nutrient(key: "water_ml", identifier: .dietaryWater, unit: .literUnit(with: .milli), unitLabel: "mL", title: "Water"),
    ]
    static let food = HKCorrelationType(.food)
    static var writable: [Nutrient] { nutrients.filter(\.writable) }
    /// HealthKit grants correlation access through its member types, so only quantity types are requested.
    static var readTypes: Set<HKObjectType> { Set(nutrients.map(\.type)) }
    static var writeTypes: Set<HKSampleType> { Set(writable.map(\.type)) }
    /// Anchored queries, in upload order: every nutrient, then food entries that group them.
    static var syncTypes: [HKSampleType] { nutrients.map(\.type) + [food] }
    static func nutrient(key: String) -> Nutrient? { nutrients.first { $0.key == key } }
    static func nutrient(identifier: String) -> Nutrient? { nutrients.first { $0.identifier.rawValue == identifier } }
}

/// Metadata Relay attaches to everything it writes, so samples trace back to their queue entry.
enum HubMetadata {
    static let writeID = "RelayWriteID"
    static let mealType = "RelayMealType"
    static func syncIdentifier(_ writeID: String, nutrient: String? = nil) -> String {
        ["relay-hub", writeID, nutrient].compactMap { $0 }.joined(separator: ".")
    }
}

struct HubCredentials: Codable {
    let server: ServerAddress
    let deviceID: String
    let token: String
    let name: String
}

enum HubError: LocalizedError, Equatable {
    case notPaired, unpaired, invalidCode, rateLimited, refused(String), server(Int), invalidResponse
    case unsupportedNutrient(String), invalidValue(String), missingWriteAccess
    var errorDescription: String? {
        switch self {
        case .notPaired: return "Pair Relay Hub first."
        case .unpaired: return "Relay Hub no longer accepts this iPhone. Create a new pairing code and pair again."
        case .invalidCode: return "This pairing code is invalid, expired or already used. Create a new one with relay-hub pair-device."
        case .rateLimited: return "Too many incorrect codes. Create a new code on your server and try again."
        case .refused(let message): return message
        case .server(let code): return "Relay Hub returned HTTP \(code). Nothing was lost; Relay will retry."
        case .invalidResponse: return "Relay Hub returned an unexpected response."
        case .unsupportedNutrient(let key): return "Relay cannot write \(key) to Apple Health."
        case .invalidValue(let key): return "The value for \(key) is not a valid amount."
        case .missingWriteAccess: return "Allow Relay to write nutrition in Apple Health."
        }
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
}

/// One collected HealthKit page, kept on disk until Relay Hub accepts it.
struct NutritionBatch: Codable, Identifiable {
    var id = UUID().uuidString
    let typeID: String
    let body: Data
    let nextAnchor: Data
    let recordCount: Int
    let deletions: Int
}

struct HubActivity: Codable, Identifiable {
    enum Outcome: String, Codable { case saved, removed, failed, waiting }
    let id: String
    var title: String
    var detail: String
    var outcome: Outcome
    var date: Date
}

struct HubState: Codable {
    var historyStart: Date?
    var anchors: [String: Data] = [:]
    var pending: NutritionBatch?
    var samplesSent = 0
    var rejected = 0
    var lastUpload: Date?
    var lastPull: Date?
    var activity: [HubActivity] = []
    static let historyDays = 30
    mutating func commitPending(at now: Date = Date()) {
        guard let batch = pending else { return }
        anchors[batch.typeID] = batch.nextAnchor
        samplesSent += batch.recordCount
        if batch.recordCount > 0 { lastUpload = now }
        pending = nil
    }
    /// Keeps the latest result per entry, newest first.
    mutating func record(_ item: HubActivity) {
        activity.removeAll { $0.id == item.id }
        activity.insert(item, at: 0)
        activity = Array(activity.prefix(20))
    }
}
