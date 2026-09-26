import Foundation
import HealthKit

struct HealthMetric: Identifiable, Decodable {
    let id: String
    let title: String
    private let group: String
    let unit: String
    let scale: Double
    var category: HealthGroup {
        switch group {
        case "activity": .activity
        case "vitals": .vitals
        case "body": .body
        case "environment": .environment
        default: .other
        }
    }
    var sampleType: HKQuantityType? { HKQuantityType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) }
    var hkUnit: HKUnit {
        if unit == "appleEffortScore" { return .appleEffortScore() }
        if unit == "ml/kg*min" { return .literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute()) }
        return HKUnit(from: unit)
    }
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
    static var entries: [HealthEntry] {
        let quantities = metrics.compactMap { m in m.sampleType.map { HealthEntry(type: $0, title: m.title, group: m.category) } }
        return [HealthEntry(type: HKObjectType.workoutType(), title: "Workouts", group: .workouts),
                HealthEntry(type: HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!, title: "Sleep stages", group: .sleep)] + quantities
    }
    static var readTypes: Set<HKObjectType> { Set(entries.map(\.type)) }
    static let limitations = "Open Wearables currently cannot store every Apple Health type. Nutrition, mindfulness, reproductive health, symptoms, medications, clinical records, ECGs, audiograms, workout routes and some measurements are not included. Deletions in Apple Health are recorded locally but cannot be mirrored to this server."
}
