import Foundation
import HealthKit

enum PayloadBuilder {
    static func build(page: HealthPage, entry: HealthEntry, sessionID: String, historical: Bool) throws -> SyncBatch {
        var records: [[String: Any]] = [], sleep: [[String: Any]] = [], workouts: [[String: Any]] = []
        for sample in page.samples {
            var row = common(sample)
            if let quantity = sample as? HKQuantitySample {
                guard let metric = HealthCatalog.metrics.first(where: { $0.id == entry.id }),
                      quantity.quantity.is(compatibleWith: metric.hkUnit) else { throw RelayError.incompatibleUnit(entry.title) }
                let value = quantity.quantity.doubleValue(for: metric.hkUnit) * metric.scale
                guard value.isFinite else { continue }
                row["type"] = entry.id; row["value"] = value; row["unit"] = metric.unit
                records.append(row)
            } else if let category = sample as? HKCategorySample {
                row["stage"] = [0: "in_bed", 1: "sleeping", 2: "awake", 3: "light", 4: "deep", 5: "rem"][category.value] ?? "unknown"
                sleep.append(row)
            } else if let workout = sample as? HKWorkout {
                guard workout.duration.isFinite else { continue }
                row["type"] = workoutName(workout.workoutActivityType)
                var values: [[String: Any]] = [["type": "duration", "value": workout.duration, "unit": "s"]]
                let stats: [(HKQuantityTypeIdentifier, String, HKUnit, String)] = [
                    (.activeEnergyBurned, "activeEnergyBurned", .kilocalorie(), "kcal"),
                    (.distanceWalkingRunning, "distance", .meter(), "m"),
                    (.distanceCycling, "distance", .meter(), "m"),
                    (.distanceSwimming, "distance", .meter(), "m")]
                for (id, name, unit, label) in stats {
                    if let type = HKObjectType.quantityType(forIdentifier: id), let sum = workout.statistics(for: type)?.sumQuantity() {
                        let value = sum.doubleValue(for: unit)
                        if value.isFinite { values.append(["type": name, "value": value, "unit": label]) }
                    }
                }
                if let type = HKObjectType.quantityType(forIdentifier: .heartRate), let stats = workout.statistics(for: type) {
                    for (name, quantity) in [("minHeartRate", stats.minimumQuantity()), ("averageHeartRate", stats.averageQuantity()), ("maxHeartRate", stats.maximumQuantity())] {
                        if let quantity {
                            let value = quantity.doubleValue(for: .count().unitDivided(by: .minute()))
                            if value.isFinite { values.append(["type": name, "value": value, "unit": "bpm"]) }
                        }
                    }
                }
                row["values"] = values
                row["laps"] = (workout.workoutEvents ?? []).compactMap { event -> [String: Any]? in
                    guard event.dateInterval.duration.isFinite else { return nil }
                    return ["type": event.type.rawValue, "startDate": iso(event.dateInterval.start), "endDate": iso(event.dateInterval.end), "duration": event.dateInterval.duration, "metadata": metadata(event.metadata)]
                }
                workouts.append(row)
            }
        }
        let payload: [String: Any] = ["provider": "apple", "sdkVersion": "relay-1.0",
            "syncTimestamp": iso(Date()), "syncSessionId": sessionID, "syncType": historical ? "historical" : "live",
            "data": ["records": records, "sleep": sleep, "workouts": workouts]]
        return SyncBatch(typeID: entry.id, group: entry.group, body: try JSONSerialization.data(withJSONObject: payload),
                         nextAnchor: page.anchor, recordCount: records.count + sleep.count + workouts.count, deletedIDs: page.deletedIDs)
    }
    private static func common(_ sample: HKSample) -> [String: Any] {
        let source = sample.sourceRevision
        var info: [String: Any] = ["name": source.source.name, "bundleIdentifier": source.source.bundleIdentifier,
            "appId": source.source.bundleIdentifier, "version": source.version ?? "", "productType": source.productType ?? "",
            "deviceManufacturer": sample.device?.manufacturer ?? "Apple", "deviceModel": sample.device?.model ?? "",
            "deviceName": sample.device?.name ?? "", "deviceSoftwareVersion": sample.device?.softwareVersion ?? ""]
        info["recordingMethod"] = (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) == true ? "manual" : "automatic"
        var row: [String: Any] = ["id": sample.uuid.uuidString, "startDate": iso(sample.startDate), "endDate": iso(sample.endDate),
            "source": info, "metadata": metadata(sample.metadata)]
        if let zone = sample.metadata?[HKMetadataKeyTimeZone] as? String, let timeZone = TimeZone(identifier: zone) {
            let seconds = timeZone.secondsFromGMT(for: sample.startDate)
            row["zoneOffset"] = String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds)/3600, abs(seconds)%3600/60)
        }
        return row
    }
    private static func metadata(_ values: [String: Any]?) -> [String: String] {
        (values ?? [:]).mapValues { String(describing: $0) }
    }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

extension SyncState {
    /// Isolate a page that cannot be encoded without committing its HealthKit anchor.
    /// The caller persists this state before continuing with another data type.
    mutating func preparePage(_ page: HealthPage, entry: HealthEntry, sessionID: String, historical: Bool) -> Bool {
        precondition(pending == nil, "Deliver the saved batch before preparing another page")
        do {
            pending = try PayloadBuilder.build(page: page, entry: entry, sessionID: sessionID, historical: historical)
            preparationIssues?[entry.id] = nil
            return true
        } catch {
            if preparationIssues == nil { preparationIssues = [:] }
            preparationIssues?[entry.id] = error.localizedDescription
            return false
        }
    }
}
