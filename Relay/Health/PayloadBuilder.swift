import Foundation
import HealthKit

/// Builds Relay Hub uploads from HealthKit pages. Every record keeps its HealthKit UUID, so resending is harmless.
enum PayloadBuilder {
    static func build(page: HealthPage, entry: HealthEntry, now: Date = Date()) throws -> SyncBatch {
        var quantities: [[String: Any]] = [], categories: [[String: Any]] = [], workouts: [[String: Any]] = [], meals: [[String: Any]] = []
        var days = Set<String>()
        for sample in page.samples {
            var row = common(sample)
            if let quantity = sample as? HKQuantitySample {
                guard let metric = HealthCatalog.metric(entry.id), quantity.quantity.is(compatibleWith: metric.hkUnit) else {
                    throw RelayError.incompatibleUnit(entry.title)
                }
                let value = quantity.quantity.doubleValue(for: metric.hkUnit) * metric.scale
                guard value.isFinite else { continue }
                row["type"] = entry.id; row["value"] = value; row["unit"] = metric.unit
                row.merge(food(sample)) { current, _ in current }
                quantities.append(row)
                days.insert(day(sample.startDate)); days.insert(day(sample.endDate))
            } else if let category = sample as? HKCategorySample {
                row["type"] = entry.id; row["value"] = category.value
                if let label = HealthCatalog.category(entry.id)?.labels[category.value] { row["label"] = label }
                categories.append(row)
            } else if let workout = sample as? HKWorkout {
                guard workout.duration.isFinite else { continue }
                row.merge(summary(workout)) { current, _ in current }
                workouts.append(row)
            } else if let correlation = sample as? HKCorrelation {
                row["sample_uuids"] = correlation.objects.map(\.uuid.uuidString).sorted()
                row.removeValue(forKey: "metadata")
                row.merge(food(sample)) { current, _ in current }
                meals.append(row)
            }
        }
        // Deleted samples carry no date, so recent statistics are refreshed for that type.
        if entry.type is HKQuantityType && !page.deletedIDs.isEmpty {
            for offset in 0..<7 { days.insert(day(now.addingTimeInterval(-Double(offset) * 86_400))) }
        }
        let id = UUID().uuidString
        let body: [String: Any] = ["batch_id": id, "quantities": quantities, "categories": categories, "workouts": workouts,
                                   "meals": meals, "deleted": page.deletedIDs]
        return SyncBatch(id: id, typeID: entry.id, group: entry.group, body: try JSONSerialization.data(withJSONObject: body),
                         nextAnchor: page.anchor, recordCount: quantities.count + categories.count + workouts.count + meals.count,
                         deletions: page.deletedIDs.count, statsDays: entry.type is HKQuantityType ? days.sorted() : [])
    }

    private static func common(_ sample: HKSample) -> [String: Any] {
        let source = sample.sourceRevision.source
        var info: [String: Any] = ["name": clip(source.name, 200), "bundle_id": clip(source.bundleIdentifier, 200)]
        if let device = sample.device?.name ?? sample.device?.model { info["device"] = clip(device, 200) }
        var row: [String: Any] = ["uuid": sample.uuid.uuidString, "start": iso(sample.startDate), "end": iso(sample.endDate), "source": info]
        // Without a recorded zone, the iPhone's current zone is used, matching how HealthKit dates its daily statistics.
        let zone = (sample.metadata?[HKMetadataKeyTimeZone] as? String) ?? TimeZone.current.identifier
        row["time_zone"] = clip(zone, 64)
        // Offset-only zones such as "GMT-0400" are not IANA names, so the offset travels too.
        if let timeZone = TimeZone(identifier: zone) { row["utc_offset"] = offset(timeZone.secondsFromGMT(for: sample.startDate)) }
        if let metadata = sample.metadata, !metadata.isEmpty {
            row["metadata"] = Dictionary(uniqueKeysWithValues: metadata.prefix(40).map { (clip($0.key, 100), clip(String(describing: $0.value), 500)) })
        }
        return row
    }
    /// Meal context from HealthKit food metadata, and the Relay Hub entry that wrote it, if any.
    private static func food(_ sample: HKSample) -> [String: Any] {
        let metadata = sample.metadata ?? [:]
        var row: [String: Any] = [:]
        if let name = metadata[HKMetadataKeyFoodType] as? String { row["food_name"] = clip(name, 200) }
        if let type = metadata[HubMetadata.mealType] as? String { row["meal_type"] = clip(type, 64) }
        if let id = metadata[HubMetadata.writeID] as? String, UUID(uuidString: id) != nil { row["write_id"] = id }
        return row
    }
    private static func summary(_ workout: HKWorkout) -> [String: Any] {
        var row: [String: Any] = ["activity": workoutName(workout.workoutActivityType), "duration_s": workout.duration]
        func sum(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) -> Double? {
            workout.statistics(for: HKQuantityType(id))?.sumQuantity().map { $0.doubleValue(for: unit) }.flatMap { $0.isFinite ? $0 : nil }
        }
        row["energy_kcal"] = sum(.activeEnergyBurned, .kilocalorie())
        let distances: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair,
            .distanceDownhillSnowSports, .distanceRowing, .distancePaddleSports, .distanceCrossCountrySkiing, .distanceSkatingSports]
        row["distance_m"] = distances.lazy.compactMap { sum($0, .meter()) }.first
        if let stats = workout.statistics(for: HKQuantityType(.heartRate)) {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            for (key, quantity) in [("avg_heart_rate", stats.averageQuantity()), ("min_heart_rate", stats.minimumQuantity()), ("max_heart_rate", stats.maximumQuantity())] {
                if let value = quantity?.doubleValue(for: bpm), value.isFinite { row[key] = value }
            }
        }
        row["events"] = (workout.workoutEvents ?? []).prefix(200).compactMap { event -> [String: Any]? in
            guard event.dateInterval.duration.isFinite else { return nil }
            return ["type": event.type.rawValue, "start": iso(event.dateInterval.start), "end": iso(event.dateInterval.end),
                    "duration_s": event.dateInterval.duration]
        }
        return row
    }
    static func day(_ date: Date) -> String { LocalDay.string(date) }
    /// Relay Hub limits text by Unicode scalars, not grapheme clusters.
    static func clip(_ text: String, _ limit: Int) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit)))
    }
    static func offset(_ seconds: Int) -> String {
        String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension SyncState {
    /// Isolate a page that cannot be encoded without committing its HealthKit anchor.
    /// The caller persists this state before continuing with another data type.
    mutating func preparePage(_ page: HealthPage, entry: HealthEntry) -> Bool {
        precondition(pending == nil, "Deliver the saved batch before preparing another page")
        do {
            pending = try PayloadBuilder.build(page: page, entry: entry)
            preparationIssues?[entry.id] = nil
            return true
        } catch {
            if preparationIssues == nil { preparationIssues = [:] }
            preparationIssues?[entry.id] = error.localizedDescription
            return false
        }
    }
}
