import XCTest
import HealthKit
@testable import Relay

@MainActor
final class HubTests: XCTestCase {
    private let writeID = "6F1C2E5A-8B7D-4C3E-9A1B-2D3E4F5A6B7C"
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
    private func credentials() throws -> Credentials {
        Credentials(server: try ServerAddress("https://hub.example.test:8443"), deviceID: "device-1", token: "rh_test-token", name: "iPhone")
    }
    private func meal(_ nutrients: String = #"{"energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44}"#,
                      timeZone: String? = "Europe/Brussels", offset: String = "+02:00") throws -> MealWrite {
        let zone = timeZone.map { "\"\($0)\"" } ?? "null"
        let json = #"{"consumed_at": "2026-10-21T12:30:00\#(offset)", "utc_offset": "\#(offset)", "time_zone": \#(zone), "name": "Chicken salad", "meal_type": "lunch", "nutrients": \#(nutrients)}"#
        return try JSONDecoder().decode(MealWrite.self, from: Data(json.utf8))
    }

    func testMealBecomesOneTraceableFoodCorrelation() throws {
        let correlation = try meal().correlation(id: writeID, revision: 3)
        XCTAssertEqual(correlation.correlationType, HKCorrelationType(.food))
        XCTAssertEqual(correlation.startDate, ISO8601DateFormatter().date(from: "2026-10-21T10:30:00Z"))
        XCTAssertEqual(correlation.startDate, correlation.endDate)
        XCTAssertEqual(correlation.metadata?[HKMetadataKeySyncIdentifier] as? String, "relay-hub.\(writeID)")
        XCTAssertEqual(correlation.metadata?[HKMetadataKeySyncVersion] as? Int, 3)
        XCTAssertEqual(correlation.metadata?[HKMetadataKeyFoodType] as? String, "Chicken salad")
        XCTAssertEqual(correlation.metadata?[HubMetadata.mealType] as? String, "lunch")
        XCTAssertEqual(correlation.metadata?[HKMetadataKeyTimeZone] as? String, "Europe/Brussels")
        let samples = correlation.objects.compactMap { $0 as? HKQuantitySample }
        XCTAssertEqual(samples.count, 4)
        let values = Dictionary(uniqueKeysWithValues: samples.map { sample in
            let nutrient = NutritionCatalog.nutrients.first { $0.identifier.rawValue == sample.quantityType.identifier }!
            return (nutrient.key, sample.quantity.doubleValue(for: nutrient.unit))
        })
        XCTAssertEqual(values, ["energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44])
        for sample in samples {
            let key = NutritionCatalog.nutrients.first { $0.identifier.rawValue == sample.quantityType.identifier }!.key
            XCTAssertEqual(sample.metadata?[HubMetadata.writeID] as? String, writeID)
            XCTAssertEqual(sample.metadata?[HKMetadataKeySyncIdentifier] as? String, "relay-hub.\(writeID).\(key)")
            XCTAssertEqual(sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool, true)
        }
    }
    func testMealWithUnsupportedOrMissingNutrientIsNotWritten() throws {
        XCTAssertThrowsError(try meal(#"{"energy_kcal": 100, "sodium_mg": 5}"#).correlation(id: writeID, revision: 1)) {
            XCTAssertEqual($0 as? RelayError, .unsupportedNutrient("sodium_mg"))
        }
        XCTAssertThrowsError(try meal(#"{"energy_kcal": -1}"#).correlation(id: writeID, revision: 1))
        XCTAssertThrowsError(try meal(#"{"protein_g": 10}"#).correlation(id: writeID, revision: 1))
    }
    func testTimeZoneFallsBackToTheEntryOffset() throws {
        XCTAssertEqual(try meal(timeZone: nil, offset: "-04:00").zone.secondsFromGMT(), -4 * 3600)
        XCTAssertEqual(try meal(timeZone: "America/New_York", offset: "-04:00").zone.identifier, "America/New_York")
    }
    func testOnlyRecurringFailuresAreReportedAsFailed() {
        XCTAssertTrue(HealthWriter.isPermanent(RelayError.invalidValue("energy_kcal")))
        XCTAssertTrue(HealthWriter.isPermanent(HKError(.errorInvalidArgument)))
        XCTAssertFalse(HealthWriter.isPermanent(HKError(.errorHealthDataUnavailable)), "May already be saved; retry instead")
        XCTAssertFalse(HealthWriter.isPermanent(URLError(.timedOut)))
        XCTAssertFalse(HealthWriter.isPermanent(RelayError.storage))
    }
    func testDietaryPayloadsKeepMealContextAndCanonicalUnits() throws {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        func sample(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, metadata: [String: Any]? = nil) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: date, end: date, metadata: metadata)
        }
        let traced: [String: Any] = [HubMetadata.writeID: writeID, HKMetadataKeyFoodType: "Chicken salad", HKMetadataKeyTimeZone: "Europe/Brussels", HubMetadata.mealType: "lunch"]
        let energy = sample(.dietaryEnergyConsumed, .kilocalorie(), 610, metadata: traced)
        let energyEntry = HealthEntry(type: HKQuantityType(.dietaryEnergyConsumed), title: "Energy Consumed", group: .nutrition)
        let rows = try records(PayloadBuilder.build(page: HealthPage(samples: [energy], deletedIDs: [], anchor: Data([1])), entry: energyEntry), "quantities")
        XCTAssertEqual(rows[0]["unit"] as? String, "kcal"); XCTAssertEqual(rows[0]["write_id"] as? String, writeID)
        XCTAssertEqual(rows[0]["food_name"] as? String, "Chicken salad"); XCTAssertEqual(rows[0]["meal_type"] as? String, "lunch")
        XCTAssertEqual(rows[0]["utc_offset"] as? String, "+02:00", "Brussels in October")
        let caffeine = sample(.dietaryCaffeine, .gram(), 0.08, metadata: [HKMetadataKeyTimeZone: TimeZone(secondsFromGMT: -4 * 3600)!.identifier,
                                                                               HKMetadataKeyFoodType: String(repeating: "🇧🇪", count: 150)])
        let caffeineEntry = HealthEntry(type: HKQuantityType(.dietaryCaffeine), title: "Caffeine", group: .nutrition)
        let travelling = try records(PayloadBuilder.build(page: HealthPage(samples: [caffeine], deletedIDs: [], anchor: Data([1])), entry: caffeineEntry), "quantities")[0]
        XCTAssertEqual(travelling["unit"] as? String, "mg"); XCTAssertEqual(travelling["value"] as! Double, 80, accuracy: 0.001)
        XCTAssertEqual(travelling["time_zone"] as? String, "GMT-0400")
        XCTAssertEqual(travelling["utc_offset"] as? String, "-04:00", "Offset-only zones still give the hub the right local day")
        XCTAssertEqual((travelling["food_name"] as? String)?.unicodeScalars.count, 200)
        XCTAssertNil(travelling["write_id"])
        let food = HKCorrelation(type: HealthCatalog.food, start: date, end: date, objects: [energy], metadata: traced)
        let foodEntry = HealthEntry(type: HealthCatalog.food, title: "Food entries", group: .nutrition)
        let meals = try records(PayloadBuilder.build(page: HealthPage(samples: [food], deletedIDs: [], anchor: Data([1])), entry: foodEntry), "meals")
        XCTAssertEqual(meals[0]["sample_uuids"] as? [String], [energy.uuid.uuidString])
        XCTAssertEqual(meals[0]["write_id"] as? String, writeID); XCTAssertNil(meals[0]["metadata"])
    }
    private func records(_ batch: SyncBatch, _ key: String) throws -> [[String: Any]] {
        try XCTUnwrap((try JSONSerialization.jsonObject(with: batch.body) as? [String: Any])?[key] as? [[String: Any]])
    }
    func testPulledWritesDecodeByKindAndAction() throws {
        let json = #"""
        {"writes": [
          {"id": "a", "kind": "meal", "action": "write", "revision": 1, "created_at": "2026-10-21T10:00:00.000+00:00",
           "data": {"consumed_at": "2026-10-21T12:30:00+02:00", "utc_offset": "+02:00", "time_zone": null, "name": null, "meal_type": null, "nutrients": {"energy_kcal": 90}}},
          {"id": "b", "kind": "meal", "action": "delete", "revision": 1, "created_at": "2026-10-21T10:00:00.000+00:00",
           "data": {"consumed_at": "2026-10-21T12:30:00+02:00", "utc_offset": "+02:00", "nutrients": {"energy_kcal": 90}}},
          {"id": "c", "kind": "workout", "action": "write", "revision": 1, "created_at": "2026-10-21T10:00:00.000+00:00", "data": {}}
        ]}
        """#
        struct Pulled: Decodable { let writes: [HubWrite] }
        let writes = try JSONDecoder().decode(Pulled.self, from: Data(json.utf8)).writes
        XCTAssertEqual(writes.map(\.action), [.write, .delete, .write])
        XCTAssertEqual(writes[0].meal?.summary, "Meal · 90 kcal")
        XCTAssertNil(writes[2].meal, "Unknown kinds are left for a newer app version")
    }
    func testPairingChecksTheHubAndStoresOnlyTheDeviceToken() async throws {
        let vault = MemoryVault(); let client = HubClient(vault: vault, session: session())
        StubProtocol.handler = { request in
            if request.url!.path == "/healthz" { return (200, Data(#"{"status": "ok"}"#.utf8)) }
            XCTAssertEqual(request.url?.absoluteString, "https://hub.example.test:8443/v1/pair")
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: String]
            XCTAssertEqual(body["code"], "ABCD23EF"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (201, Data(#"{"device_id": "device-1", "token": "rh_secret", "name": "iPhone", "time_zone": "Europe/Brussels"}"#.utf8))
        }
        let server = try ServerAddress("https://hub.example.test:8443")
        try await client.check(server: server)
        let paired = try await client.pair(server: server, code: "abcd-23ef", deviceName: "iPhone")
        XCTAssertEqual(paired.token, "rh_secret"); XCTAssertEqual(vault.credentials?.deviceID, "device-1")
        let cases: [(Int, String, RelayError)] = [(403, "{}", .invalidCode), (429, "", .rateLimited),
            (403, #"{"error": "This Relay Hub only accepts requests from allowed tailnet users."}"#, .refused("This Relay Hub only accepts requests from allowed tailnet users."))]
        for (status, body, expected) in cases {
            StubProtocol.handler = { _ in (status, Data(body.utf8)) }
            do { _ = try await client.pair(server: server, code: "ABCD23EF", deviceName: "x"); XCTFail("Expected \(expected)") }
            catch { XCTAssertEqual(error as? RelayError, expected) }
        }
        StubProtocol.handler = { _ in (200, Data("<html>Open Wearables</html>".utf8)) }
        do { try await client.check(server: server); XCTFail("Only a Relay Hub may receive a pairing code") } catch {}
    }
    func testDeviceRequestsCarryTheTokenAndReportRevocation() async throws {
        let vault = MemoryVault(try credentials()); let client = HubClient(vault: vault, session: session())
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rh_test-token")
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: Any]
            switch request.url!.path {
            case "/v1/types":
                XCTAssertEqual((body["types"] as? [[String: Any]])?.count, 1)
                return (200, Data(#"{"registered": 1, "rejected": []}"#.utf8))
            case "/v1/writes/pull":
                XCTAssertEqual(body["kinds"] as? [String], ["meal"])
                XCTAssertEqual(body["write_access"] as? [String: String], ["meal": "authorized"])
                // One unreadable entry must not block the rest of the queue.
                let bad = #"{"id": "bad", "kind": "meal", "action": "write", "revision": 1, "data": {}}"#
                let good = #"{"id": "good", "kind": "meal", "action": "delete", "revision": 1, "data": {"consumed_at": "2026-10-21T12:30:00+02:00", "utc_offset": "+02:00", "nutrients": {"energy_kcal": 1}}}"#
                return (200, Data("{\"writes\": [\(bad), \(good)]}".utf8))
            case "/v1/health":
                if body["complete"] as? Bool == true { return (200, Data(#"{"batch_id": "x", "accepted": {}, "rejected": []}"#.utf8)) }
                XCTAssertEqual(body["batch_id"] as? String, "b")
                return (200, Data(#"{"batch_id": "b", "accepted": {}, "rejected": [{"collection": "quantities", "index": 0, "reason": "unit"}]}"#.utf8))
            default:
                XCTAssertEqual(body["result"] as? String, "written"); XCTAssertEqual(body["healthkit_ids"] as? [String], ["A", "B"])
                return (200, Data(#"{"id": "w1", "status": "delete_requested"}"#.utf8))
            }
        }
        try await client.registerTypes([["id": "HKQuantityTypeIdentifierStepCount"]], wifiOnly: false)
        let writes = try await client.pull(writeAccess: "authorized", appVersion: "1.0", wifiOnly: false)
        XCTAssertEqual(writes.map(\.id), ["good"])
        let status = try await client.ack("w1", result: "written", healthKitIDs: ["A", "B"], wifiOnly: false)
        XCTAssertEqual(status, "delete_requested")
        let receipt = try await client.upload(Data(#"{"batch_id": "b"}"#.utf8), wifiOnly: false)
        XCTAssertEqual(receipt.rejected.count, 1)
        try await client.markCaughtUp(wifiOnly: false)
        XCTAssertEqual(paths, ["/v1/types", "/v1/writes/pull", "/v1/writes/w1/ack", "/v1/health", "/v1/health"])
        StubProtocol.handler = { _ in (403, Data(#"{"error": "Not on the allowlist."}"#.utf8)) }
        do { _ = try await client.status(); XCTFail("Expected refusal") } catch { XCTAssertEqual(error as? RelayError, .refused("Not on the allowlist.")) }
        StubProtocol.handler = { _ in (401, Data()) }
        do { _ = try await client.status(); XCTFail("Expected expiry") } catch { XCTAssertEqual(error as? RelayError, .expiredSession) }
        vault.credentials = nil
        do { _ = try await client.status(); XCTFail("Expected notConnected") } catch { XCTAssertEqual(error as? RelayError, .notConnected) }
    }
    func testWriteActivityKeepsTheLatestTwentyEntries() {
        var state = SyncState()
        for index in 0..<25 { state.record(WriteActivity(id: "\(index % 22)", title: "t", detail: "d", outcome: .saved, date: Date())) }
        XCTAssertEqual(state.activity.count, 20); XCTAssertEqual(state.activity.first?.id, "2")
    }
    func testNutrientsMatchTheServerAndTheCatalog() throws {
        XCTAssertEqual(NutritionCatalog.writable.map(\.key), ["energy_kcal", "protein_g", "carbohydrates_g", "fat_g", "fiber_g", "sugar_g"])
        for nutrient in NutritionCatalog.nutrients {
            XCTAssertTrue(nutrient.type.is(compatibleWith: nutrient.unit), nutrient.key)
            XCTAssertEqual(HealthCatalog.metric(nutrient.identifier.rawValue)?.unit, nutrient.unitLabel, "Uploads and writes must agree on units")
        }
        let server = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("server/relay_hub/nutrients.py")
        guard let source = try? String(contentsOf: server, encoding: .utf8) else { throw XCTSkip("Server source is not readable from this test host") }
        let pattern = try NSRegularExpression(pattern: #"Nutrient\("(\w+)", "(\w+)", "(\w+)", "[^"]+"(, writable=True)?\)"#)
        let rows = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
            (1...4).map { Range(match.range(at: $0), in: source).map { String(source[$0]) } ?? "" }
        }
        XCTAssertEqual(rows.map { $0[0] }, NutritionCatalog.nutrients.map(\.key))
        XCTAssertEqual(rows.map { $0[1] }, NutritionCatalog.nutrients.map(\.identifier.rawValue))
        XCTAssertEqual(rows.map { $0[2] }, NutritionCatalog.nutrients.map(\.unitLabel))
        XCTAssertEqual(rows.map { !$0[3].isEmpty }, NutritionCatalog.nutrients.map(\.writable))
    }
}

extension URLRequest {
    /// URLProtocol receives uploads as a body stream rather than `httpBody`.
    var bodyData: Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
