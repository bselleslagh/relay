import Foundation
import HealthKit

struct HealthMetric: Identifiable, Decodable {
    let id: String
    let title: String
    private let group: String
    let unit: String
    let scale: Double
    let aggregation: String
    var category: HealthGroup {
        switch group {
        case "activity": .activity
        case "vitals": .vitals
        case "body": .body
        case "environment": .environment
        case "nutrition": .nutrition
        default: .other
        }
    }
    /// Nil when this iOS version does not offer the type.
    var sampleType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) }
    var hkUnit: HKUnit {
        switch unit {
        case "appleEffortScore": .appleEffortScore()
        case "ml/kg*min": .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute())
        case "kcal/(kg*hr)": .kilocalorie().unitDivided(by: .gramUnit(with: .kilo).unitMultiplied(by: .hour()))
        default: HKUnit(from: unit)
        }
    }
}

/// Category types beyond sleep, stored as raw values with readable labels where HealthKit defines them.
struct CategoryKind {
    let identifier: HKCategoryTypeIdentifier
    let title: String
    let group: HealthGroup
    let labels: [Int: String]
}

struct HealthEntry: Identifiable {
    let type: HKSampleType
    let title: String
    let group: HealthGroup
    var id: String { type.identifier }
}

enum HealthCatalog {
    static let metrics: [HealthMetric] = {
        guard let url = Bundle.main.url(forResource: "Catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let metrics = try? JSONDecoder().decode([HealthMetric].self, from: data)
        else { preconditionFailure("Missing reviewed health catalog") }
        return metrics
    }()
    static let categories: [CategoryKind] = [
        CategoryKind(identifier: .sleepAnalysis, title: "Sleep stages", group: .sleep,
                     labels: [0: "in_bed", 1: "asleep", 2: "awake", 3: "core", 4: "deep", 5: "rem"]),
        CategoryKind(identifier: .mindfulSession, title: "Mindful sessions", group: .other, labels: [:]),
        CategoryKind(identifier: .appleStandHour, title: "Stand hours", group: .activity, labels: [0: "stood", 1: "idle"]),
        CategoryKind(identifier: .highHeartRateEvent, title: "High heart rate notifications", group: .vitals, labels: [:]),
        CategoryKind(identifier: .lowHeartRateEvent, title: "Low heart rate notifications", group: .vitals, labels: [:]),
        CategoryKind(identifier: .irregularHeartRhythmEvent, title: "Irregular rhythm notifications", group: .vitals, labels: [:]),
    ]
    static let food = HKCorrelationType(.food)
    static var entries: [HealthEntry] {
        let quantities = metrics.compactMap { m in m.sampleType.map { HealthEntry(type: $0, title: m.title, group: m.category) } }
        let kinds = categories.map { HealthEntry(type: HKCategoryType($0.identifier), title: $0.title, group: $0.group) }
        // Food entries come last so their nutrition samples have usually been read in the same session.
        return [HealthEntry(type: HKObjectType.workoutType(), title: "Workouts", group: .workouts)] + kinds + quantities
            + [HealthEntry(type: food, title: "Food entries", group: .nutrition)]
    }
    /// HealthKit grants food entries through their nutrient types, so correlation types are never requested.
    static var readTypes: Set<HKObjectType> { Set(entries.map(\.type).filter { !($0 is HKCorrelationType) }) }
    static var writeTypes: Set<HKSampleType> { Set(NutritionCatalog.writable.map(\.type)) }
    static func metric(_ id: String) -> HealthMetric? { metrics.first { $0.id == id } }
    static func category(_ id: String) -> CategoryKind? { categories.first { $0.identifier.rawValue == id } }
    /// What Relay Hub needs to validate uploads: each type's kind, title, group, unit and aggregation.
    static var registration: [[String: Any]] {
        entries.map { entry in
            var item: [String: Any] = ["id": entry.id, "title": entry.title, "group": entry.group.key]
            switch entry.type {
            case is HKQuantityType:
                let metric = metric(entry.id)!
                item["kind"] = "quantity"; item["unit"] = metric.unit; item["aggregation"] = metric.aggregation
            case is HKCategoryType: item["kind"] = "category"
            case is HKCorrelationType: item["kind"] = "correlation"
            default: item["kind"] = "workout"
            }
            return item
        }
    }
    static let limitations = "Relay sends every quantity type in Apple Health, sleep stages, mindful sessions, stand hours, heart rate notifications, workouts and food entries. Clinical records, medications, ECG waveforms, audiograms, reproductive health, symptoms, state of mind and workout routes are not included."
}

/// Nutrients the AI meal log can write, keyed by name and unit like Relay Hub's `nutrients.py`.
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
    static var writable: [Nutrient] { nutrients.filter(\.writable) }
    static func nutrient(key: String) -> Nutrient? { nutrients.first { $0.key == key } }
}
