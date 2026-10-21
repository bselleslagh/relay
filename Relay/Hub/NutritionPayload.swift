import Foundation
import HealthKit

enum NutritionPayload {
    /// One Apple Health food entry per meal. Every object carries the queue entry's ID and a stable sync identifier,
    /// so a retried save replaces rather than duplicates, and the hub can trace each sample.
    static func correlation(for meal: MealWrite, id: String, revision: Int) throws -> HKCorrelation {
        var shared: [String: Any] = [HKMetadataKeyTimeZone: meal.zone.identifier, HKMetadataKeyWasUserEntered: true, HubMetadata.writeID: id]
        if let name = meal.name { shared[HKMetadataKeyFoodType] = name }
        if let type = meal.mealType { shared[HubMetadata.mealType] = type }
        var samples = Set<HKSample>()
        for (key, value) in meal.nutrients.sorted(by: { $0.key < $1.key }) {
            guard let nutrient = NutritionCatalog.nutrient(key: key), nutrient.writable else { throw HubError.unsupportedNutrient(key) }
            guard value.isFinite, value >= 0 else { throw HubError.invalidValue(key) }
            var metadata = shared
            metadata[HKMetadataKeySyncIdentifier] = HubMetadata.syncIdentifier(id, nutrient: key)
            metadata[HKMetadataKeySyncVersion] = revision
            samples.insert(HKQuantitySample(type: nutrient.type, quantity: HKQuantity(unit: nutrient.unit, doubleValue: value),
                                            start: meal.consumedAt, end: meal.consumedAt, metadata: metadata))
        }
        guard meal.energy != nil else { throw HubError.invalidValue("energy_kcal") }
        var metadata = shared
        metadata[HKMetadataKeySyncIdentifier] = HubMetadata.syncIdentifier(id)
        metadata[HKMetadataKeySyncVersion] = revision
        return HKCorrelation(type: NutritionCatalog.food, start: meal.consumedAt, end: meal.consumedAt, objects: samples, metadata: metadata)
    }

    /// Converts one HealthKit page into a hub upload. Non-finite values are skipped; deletions are forwarded.
    static func batch(page: HealthPage, typeID: String) -> NutritionBatch {
        var samples: [[String: Any]] = [], meals: [[String: Any]] = []
        for sample in page.samples {
            if let quantity = sample as? HKQuantitySample, let nutrient = NutritionCatalog.nutrient(identifier: quantity.quantityType.identifier),
               quantity.quantity.is(compatibleWith: nutrient.unit) {
                let value = quantity.quantity.doubleValue(for: nutrient.unit)
                guard value.isFinite, value >= 0 else { continue }
                var row = common(sample)
                row["type"] = nutrient.identifier.rawValue; row["value"] = value; row["unit"] = nutrient.unitLabel
                samples.append(row)
            } else if let correlation = sample as? HKCorrelation {
                var row = common(sample)
                row["sample_uuids"] = correlation.objects.map(\.uuid.uuidString).sorted()
                meals.append(row)
            }
        }
        let body: [String: Any] = ["batch_id": UUID().uuidString, "samples": samples, "meals": meals, "deleted": page.deletedIDs]
        return NutritionBatch(typeID: typeID, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data(),
                              nextAnchor: page.anchor, recordCount: samples.count + meals.count, deletions: page.deletedIDs.count)
    }

    private static func common(_ sample: HKSample) -> [String: Any] {
        let metadata = sample.metadata ?? [:]
        let source = sample.sourceRevision.source
        var row: [String: Any] = ["uuid": sample.uuid.uuidString, "start": iso(sample.startDate), "end": iso(sample.endDate),
                                  "source": ["name": clip(source.name, 200), "bundle_id": clip(source.bundleIdentifier, 200)]]
        if let zone = metadata[HKMetadataKeyTimeZone] as? String {
            row["time_zone"] = clip(zone, 64)
            // Offset-only zones such as "GMT-0400" are not IANA names, so the offset travels too.
            if let timeZone = TimeZone(identifier: zone) { row["utc_offset"] = offset(timeZone.secondsFromGMT(for: sample.startDate)) }
        }
        if let name = metadata[HKMetadataKeyFoodType] as? String { row["food_name"] = clip(name, 200) }
        if let type = metadata[HubMetadata.mealType] as? String { row["meal_type"] = clip(type, 64) }
        if let id = metadata[HubMetadata.writeID] as? String, UUID(uuidString: id) != nil { row["write_id"] = id }
        return row
    }

    /// The hub limits metadata by Unicode scalars, not grapheme clusters.
    private static func clip(_ text: String, _ limit: Int) -> String {
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
