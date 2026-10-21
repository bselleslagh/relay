import XCTest
import HealthKit
@testable import Relay

final class HubVaultBox {
    var credentials: HubCredentials?
    init(_ credentials: HubCredentials? = nil) { self.credentials = credentials }
    var vault: HubVault {
        HubVault(read: { self.credentials }, save: { self.credentials = $0 }, clear: { self.credentials = nil })
    }
}

@MainActor
final class HubTests: XCTestCase {
    private let writeID = "6F1C2E5A-8B7D-4C3E-9A1B-2D3E4F5A6B7C"
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
    private func credentials() throws -> HubCredentials {
        HubCredentials(server: try ServerAddress("https://hub.example.test:8443"), deviceID: "device-1", token: "rh_test-token", name: "iPhone")
    }
    private func meal(_ nutrients: String = #"{"energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44}"#,
                      timeZone: String? = "Europe/Brussels", offset: String = "+02:00") throws -> MealWrite {
        let zone = timeZone.map { "\"\($0)\"" } ?? "null"
        let json = #"{"consumed_at": "2026-10-21T12:30:00\#(offset)", "utc_offset": "\#(offset)", "time_zone": \#(zone), "name": "Chicken salad", "meal_type": "lunch", "nutrients": \#(nutrients)}"#
        return try JSONDecoder().decode(MealWrite.self, from: Data(json.utf8))
    }

    func testMealBecomesOneTraceableFoodCorrelation() throws {
        let correlation = try NutritionPayload.correlation(for: meal(), id: writeID, revision: 3)
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
            let nutrient = NutritionCatalog.nutrient(identifier: sample.quantityType.identifier)!
            return (nutrient.key, sample.quantity.doubleValue(for: nutrient.unit))
        })
        XCTAssertEqual(values, ["energy_kcal": 610, "protein_g": 42, "carbohydrates_g": 12, "fat_g": 44])
        for sample in samples {
            let key = NutritionCatalog.nutrient(identifier: sample.quantityType.identifier)!.key
            XCTAssertEqual(sample.metadata?[HubMetadata.writeID] as? String, writeID)
            XCTAssertEqual(sample.metadata?[HKMetadataKeySyncIdentifier] as? String, "relay-hub.\(writeID).\(key)")
            XCTAssertEqual(sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool, true)
            XCTAssertEqual(sample.startDate, correlation.startDate)
        }
    }
    func testMealWithUnsupportedOrMissingNutrientIsNotWritten() throws {
        XCTAssertThrowsError(try NutritionPayload.correlation(for: meal(#"{"energy_kcal": 100, "sodium_mg": 5}"#), id: writeID, revision: 1)) {
            XCTAssertEqual($0 as? HubError, .unsupportedNutrient("sodium_mg"))
        }
        XCTAssertThrowsError(try NutritionPayload.correlation(for: meal(#"{"energy_kcal": -1}"#), id: writeID, revision: 1))
        XCTAssertThrowsError(try NutritionPayload.correlation(for: meal(#"{"protein_g": 10}"#), id: writeID, revision: 1))
    }
    func testTimeZoneFallsBackToTheEntryOffset() throws {
        XCTAssertEqual(try meal(timeZone: nil, offset: "-04:00").zone.secondsFromGMT(), -4 * 3600)
        XCTAssertEqual(try meal(timeZone: "America/New_York", offset: "-04:00").zone.identifier, "America/New_York")
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
        XCTAssertEqual(writes[0].meal?.title, "Meal"); XCTAssertEqual(writes[0].meal?.energy, 90)
        XCTAssertNil(writes[2].meal, "Unknown kinds are left for a newer app version")
    }
    func testNutritionBatchUsesCanonicalUnitsAndKeepsTraceability() throws {
        let date = Date(timeIntervalSince1970: 1_792_000_000)
        func sample(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, metadata: [String: Any]? = nil) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: date, end: date, metadata: metadata)
        }
        let traced: [String: Any] = [HubMetadata.writeID: writeID, HKMetadataKeyFoodType: "Chicken salad", HKMetadataKeyTimeZone: "Europe/Brussels", HubMetadata.mealType: "lunch"]
        let travelling = sample(.dietaryCaffeine, .gramUnit(with: .milli), 80,
                                metadata: [HKMetadataKeyTimeZone: TimeZone(secondsFromGMT: -4 * 3600)!.identifier, HKMetadataKeyFoodType: String(repeating: "🇧🇪", count: 150)])
        let energy = sample(.dietaryEnergyConsumed, .kilocalorie(), 610, metadata: traced)
        let sodium = sample(.dietarySodium, .gram(), 1.2)
        let water = sample(.dietaryWater, .liter(), 0.25)
        let broken = sample(.dietaryProtein, .gram(), .nan)
        let food = HKCorrelation(type: NutritionCatalog.food, start: date, end: date, objects: [energy], metadata: traced)
        let page = HealthPage(samples: [energy, sodium, water, broken, travelling, food], deletedIDs: ["gone"], anchor: Data([7]))
        let batch = NutritionPayload.batch(page: page, typeID: "mixed")
        XCTAssertEqual(batch.recordCount, 5); XCTAssertEqual(batch.deletions, 1); XCTAssertEqual(batch.nextAnchor, Data([7]))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: batch.body) as? [String: Any])
        let rows = try XCTUnwrap(root["samples"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["unit"] as? String }, ["kcal", "mg", "mL", "mg"])
        XCTAssertEqual(rows[0]["utc_offset"] as? String, "+02:00", "Brussels in October")
        XCTAssertEqual(rows[3]["time_zone"] as? String, "GMT-0400")
        XCTAssertEqual(rows[3]["utc_offset"] as? String, "-04:00", "Offset-only zones still give the hub the right local day")
        XCTAssertEqual((rows[3]["food_name"] as? String)?.unicodeScalars.count, 200)
        XCTAssertEqual(rows[1]["value"] as! Double, 1200, accuracy: 0.001)
        XCTAssertEqual(rows[2]["value"] as! Double, 250, accuracy: 0.001)
        XCTAssertEqual(rows[0]["uuid"] as? String, energy.uuid.uuidString)
        XCTAssertEqual(rows[0]["type"] as? String, "HKQuantityTypeIdentifierDietaryEnergyConsumed")
        XCTAssertEqual(rows[0]["write_id"] as? String, writeID)
        XCTAssertEqual(rows[0]["food_name"] as? String, "Chicken salad")
        XCTAssertEqual(rows[0]["time_zone"] as? String, "Europe/Brussels")
        XCTAssertNil(rows[1]["write_id"]); XCTAssertNotNil(rows[0]["source"] as? [String: Any])
        let meals = try XCTUnwrap(root["meals"] as? [[String: Any]])
        XCTAssertEqual(meals.first?["sample_uuids"] as? [String], [energy.uuid.uuidString])
        XCTAssertEqual(meals.first?["meal_type"] as? String, "lunch")
        XCTAssertEqual(root["deleted"] as? [String], ["gone"])
    }
    func testPairingStoresOnlyTheDeviceToken() async throws {
        let box = HubVaultBox(); let client = HubClient(vault: box.vault, session: session())
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://hub.example.test:8443/v1/pair")
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: String]
            XCTAssertEqual(body["code"], "ABCD23EF"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (201, Data(#"{"device_id": "device-1", "token": "rh_secret", "name": "iPhone", "time_zone": "Europe/Brussels"}"#.utf8))
        }
        let paired = try await client.pair(server: try ServerAddress("https://hub.example.test:8443"), code: "abcd-23ef", deviceName: "iPhone")
        XCTAssertEqual(paired.token, "rh_secret"); XCTAssertEqual(box.credentials?.deviceID, "device-1")
        let cases: [(Int, String, HubError)] = [(403, "{}", .invalidCode), (429, "", .rateLimited),
            (403, #"{"error": "This Relay Hub only accepts requests from allowed tailnet users."}"#, .refused("This Relay Hub only accepts requests from allowed tailnet users."))]
        for (status, body, expected) in cases {
            StubProtocol.handler = { _ in (status, Data(body.utf8)) }
            do { _ = try await client.pair(server: try ServerAddress("https://hub.example.test"), code: "ABCD23EF", deviceName: "x"); XCTFail("Expected \(expected)") }
            catch { XCTAssertEqual(error as? HubError, expected) }
        }
        do { _ = try await client.pair(server: try ServerAddress("https://hub.example.test"), code: "short", deviceName: "x"); XCTFail("Code format") } catch {}
    }
    func testDeviceRequestsCarryTheTokenAndReportRevocation() async throws {
        let box = HubVaultBox(try credentials()); let client = HubClient(vault: box.vault, session: session())
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rh_test-token")
            let body = try JSONSerialization.jsonObject(with: request.bodyData) as! [String: Any]
            if request.url!.path.hasSuffix("pull") {
                XCTAssertEqual(body["kinds"] as? [String], ["meal"])
                XCTAssertEqual(body["write_access"] as? [String: String], ["meal": "authorized"])
                // One unreadable entry must not block the rest of the queue.
                let bad = #"{"id": "bad", "kind": "meal", "action": "write", "revision": 1, "data": {}}"#
                let good = #"{"id": "good", "kind": "meal", "action": "delete", "revision": 1, "data": {"consumed_at": "2026-10-21T12:30:00+02:00", "utc_offset": "+02:00", "nutrients": {"energy_kcal": 1}}}"#
                return (200, Data("{\"writes\": [\(bad), \(good)]}".utf8))
            }
            if request.url!.path.hasSuffix("nutrition") {
                XCTAssertEqual(body["complete"] as? Bool, true)
                return (200, Data(#"{"batch_id": "x", "accepted": {}, "rejected": []}"#.utf8))
            }
            XCTAssertEqual(body["result"] as? String, "written"); XCTAssertEqual(body["healthkit_ids"] as? [String], ["A", "B"])
            return (200, Data(#"{"id": "w1", "status": "delete_requested"}"#.utf8))
        }
        let writes = try await client.pull(writeAccess: "authorized", appVersion: "1.0", wifiOnly: false)
        XCTAssertEqual(writes.map(\.id), ["good"])
        let status = try await client.ack("w1", result: "written", healthKitIDs: ["A", "B"], wifiOnly: false)
        XCTAssertEqual(status, "delete_requested")
        try await client.markCaughtUp(wifiOnly: false)
        XCTAssertEqual(paths, ["/v1/writes/pull", "/v1/writes/w1/ack", "/v1/nutrition"])
        StubProtocol.handler = { _ in (403, Data(#"{"error": "Not on the allowlist."}"#.utf8)) }
        do { _ = try await client.status(); XCTFail("Expected refusal") } catch { XCTAssertEqual(error as? HubError, .refused("Not on the allowlist.")) }
        StubProtocol.handler = { _ in (401, Data()) }
        do { _ = try await client.pull(writeAccess: "authorized", appVersion: "1.0", wifiOnly: false); XCTFail("Expected unpaired") }
        catch { XCTAssertEqual(error as? HubError, .unpaired) }
        box.credentials = nil
        do { _ = try await client.status(); XCTFail("Expected notPaired") } catch { XCTAssertEqual(error as? HubError, .notPaired) }
    }
    func testOnlyRecurringFailuresAreReportedAsFailed() {
        XCTAssertTrue(HubModel.isPermanent(HubError.invalidValue("energy_kcal")))
        XCTAssertTrue(HubModel.isPermanent(HKError(.errorInvalidArgument)))
        XCTAssertFalse(HubModel.isPermanent(HKError(.errorHealthDataUnavailable)), "May already be saved; retry instead")
        XCTAssertFalse(HubModel.isPermanent(URLError(.timedOut)))
    }
    func testNutritionAnchorAdvancesOnlyAfterTheHubAcceptsTheBatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try HubStore(credentials: credentials(), directory: directory)
        var state = HubState(); state.anchors["energy"] = Data([1])
        state.pending = NutritionBatch(typeID: "energy", body: Data("{}".utf8), nextAnchor: Data([2]), recordCount: 3, deletions: 0)
        try disk.save(state)
        var restored = try disk.load()
        XCTAssertEqual(restored.anchors["energy"], Data([1])); XCTAssertEqual(restored.pending?.recordCount, 3)
        restored.commitPending(at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(restored.anchors["energy"], Data([2])); XCTAssertNil(restored.pending)
        XCTAssertEqual(restored.samplesSent, 3); XCTAssertEqual(restored.lastUpload, Date(timeIntervalSince1970: 0))
        for index in 0..<25 { restored.record(HubActivity(id: "\(index % 22)", title: "t", detail: "d", outcome: .saved, date: Date())) }
        XCTAssertEqual(restored.activity.count, 20); XCTAssertEqual(restored.activity.first?.id, "2")
    }
    func testCatalogMatchesTheServerAndHealthKitUnits() throws {
        XCTAssertEqual(NutritionCatalog.writable.map(\.key), ["energy_kcal", "protein_g", "carbohydrates_g", "fat_g", "fiber_g", "sugar_g"])
        for nutrient in NutritionCatalog.nutrients {
            XCTAssertTrue(nutrient.type.is(compatibleWith: nutrient.unit), nutrient.key)
            XCTAssertEqual(HKUnit(from: nutrient.unitLabel), nutrient.unit, nutrient.key)
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

private extension URLRequest {
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
