import XCTest
import HealthKit
@testable import Relay

final class MemoryVault: CredentialStore {
    var credentials: Credentials?
    init(_ credentials: Credentials? = nil) { self.credentials = credentials }
    func read() throws -> Credentials? { credentials }
    func save(_ credentials: Credentials) throws { self.credentials = credentials }
    func clear() throws { credentials = nil }
}

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
final class RelayTests: XCTestCase {
    private func account(_ origin: String = "https://hub.example.test:8443", device: String = "device-1") throws -> Credentials {
        Credentials(server: try ServerAddress(origin), deviceID: device, token: "rh_test-token", name: "iPhone")
    }
    private func batch(count: Int = 1, deletions: Int = 0) -> SyncBatch {
        SyncBatch(typeID: "steps", group: .activity, body: Data("{\"batch_id\":\"b\"}".utf8), nextAnchor: Data([2]),
                  recordCount: count, deletions: deletions, statsDays: ["2026-10-21"])
    }
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testOnlyHTTPSOriginCanReceiveCredentials() throws {
        for address in ["http://example.test", "https://name:password@example.test", "https://example.test/path", "https://example.test?q=secret", "https://example.test#fragment", "https://example.test:99999"] {
            XCTAssertThrowsError(try ServerAddress(address), address)
        }
        XCTAssertEqual(try ServerAddress("  https://EXAMPLE.test:9443/ ").url.absoluteString, "https://example.test:9443")
    }
    func testPairingCodeValidation() throws {
        XCTAssertEqual(try HubClient.normalizedCode("abcd-23ef"), "ABCD23EF")
        XCTAssertThrowsError(try HubClient.normalizedCode("ABC12345"))
        XCTAssertThrowsError(try HubClient.normalizedCode("ABCD"))
    }
    func testUploadFailurePreservesDurableBatchAndAnchor() async throws {
        let disk = try SyncStore(account: account(), directory: temporaryDirectory())
        var state = SyncState(); state.anchors["steps"] = Data([1]); state.pending = batch()
        try disk.save(state)
        do {
            _ = try await PendingDelivery.deliver(state, upload: { _ in throw URLError(.timedOut) }, persist: disk.save)
            XCTFail("Delivery must fail")
        } catch {}
        let restored = try disk.load()
        XCTAssertEqual(restored.anchors["steps"], Data([1]))
        XCTAssertEqual(restored.pending?.id, state.pending?.id)
        XCTAssertEqual(restored.pending?.body, state.pending?.body)
        XCTAssertEqual(restored.sentToday, 0)
        XCTAssertTrue(restored.statsDays.isEmpty, "Statistics days only count once the batch is accepted")
    }
    func testSuccessfulDeliveryCommitsAnchorAndStatisticsDaysTogether() async throws {
        var state = SyncState(); state.pending = batch(count: 7)
        var written: SyncState?
        let result = try await PendingDelivery.deliver(state, upload: { _ in }, persist: { written = $0 })
        XCTAssertEqual(written?.anchors["steps"], Data([2]))
        XCTAssertEqual(written?.statsDays["steps"], ["2026-10-21"])
        XCTAssertEqual(result.sentToday, 7)
        XCTAssertNil(result.pending)
        let again = try await PendingDelivery.deliver(result, upload: { _ in XCTFail("No batch to send") }, persist: { _ in })
        XCTAssertEqual(again.sentToday, 7)
    }
    func testStorageFailureDoesNotDiscardPendingBatch() async throws {
        var state = SyncState(); state.pending = batch()
        do {
            _ = try await PendingDelivery.deliver(state, upload: { _ in }, persist: { _ in throw RelayError.storage })
            XCTFail("Must surface persistence failure")
        } catch {}
        XCTAssertNotNil(state.pending); XCTAssertNil(state.anchors["steps"])
    }
    func testEmptyPageCommitsLocallyButDeletionsAreSent() async throws {
        var state = SyncState(); state.pending = batch(count: 0)
        let result = try await PendingDelivery.deliver(state, upload: { _ in XCTFail("No health records to upload") }, persist: { _ in })
        XCTAssertNil(result.lastAccepted); XCTAssertEqual(result.acceptedBatches, 0)
        XCTAssertEqual(result.anchors["steps"], Data([2]))
        state.pending = batch(count: 0, deletions: 2)
        var uploads = 0
        _ = try await PendingDelivery.deliver(state, upload: { _ in uploads += 1 }, persist: { _ in })
        XCTAssertEqual(uploads, 1, "Relay Hub mirrors deletions, so they are always sent")
    }
    func testCheckpointsAreIsolatedByHubAndDevice() throws {
        let directory = temporaryDirectory()
        let first = try SyncStore(account: account(), directory: directory)
        let otherHub = try SyncStore(account: account("https://second.example.test"), directory: directory)
        let otherDevice = try SyncStore(account: account(device: "device-2"), directory: directory)
        var state = SyncState(); state.pending = batch(); try first.save(state)
        XCTAssertNil(try otherHub.load().pending)
        XCTAssertNil(try otherDevice.load().pending)
    }
    func testOlderCheckpointsAreRemovedAndNewOnesKept() throws {
        let directory = temporaryDirectory()
        let current = try SyncStore(account: account(), directory: directory)
        var state = SyncState(); state.totalSent = 5; try current.save(state)
        for legacy in ["0f0e.json", "hub-0f0e.json"] { try Data("{}".utf8).write(to: directory.appendingPathComponent(legacy)) }
        SyncStore.removeLegacyCheckpoints(directory: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 1); XCTAssertTrue(names[0].hasPrefix("sync-"))
        XCTAssertEqual(try current.load().totalSent, 5)
    }
    func testCheckpointWithMissingFieldsStaysReadable() throws {
        let restored = try JSONDecoder().decode(SyncState.self, from: Data(#"{"totalSent": 76487, "anchors": {"steps": "AQ=="}}"#.utf8))
        XCTAssertEqual(restored.totalSent, 76487); XCTAssertEqual(restored.anchors["steps"], Data([1]))
        XCTAssertEqual(restored.window, .month); XCTAssertTrue(restored.statsDays.isEmpty); XCTAssertNil(restored.pending)
    }
    func testDailyCountersResetWithoutLosingLifetimeTotal() {
        var state = SyncState(); state.day = .distantPast; state.sentToday = 99; state.totalSent = 100
        state.pending = batch(count: 3); state.commitPending()
        XCTAssertEqual(state.sentToday, 3); XCTAssertEqual(state.totalSent, 103)
    }
    func testRescanNeverDiscardsAnUnsentBatchAndSetsTheWindow() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var state = SyncState(); state.anchors["steps"] = Data([3]); state.pending = batch()
        XCTAssertThrowsError(try state.prepareRescan(window: .year, at: now))
        XCTAssertEqual(state.anchors["steps"], Data([3])); XCTAssertNotNil(state.pending)
        state.pending = nil; state.totalSent = 42
        try state.prepareRescan(window: .year, at: now)
        XCTAssertTrue(state.anchors.isEmpty); XCTAssertEqual(state.totalSent, 42)
        XCTAssertEqual(state.window, .year); XCTAssertEqual(state.historyStart, now.addingTimeInterval(-365 * 86_400))
        try state.prepareRescan(window: .all, at: now)
        XCTAssertNil(state.historyStart, "All history reads without a date predicate")
    }
    func testHistoryPredicateUsesSampleStartAndNoUpperBound() throws {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let predicate = try XCTUnwrap(HealthReader.historyPredicate(startingAt: cutoff))
        func sample(_ start: Date, _ end: Date) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(.stepCount), quantity: HKQuantity(unit: .count(), doubleValue: 10), start: start, end: end)
        }
        XCTAssertFalse(predicate.evaluate(with: sample(cutoff.addingTimeInterval(-1), cutoff.addingTimeInterval(60))))
        XCTAssertTrue(predicate.evaluate(with: sample(cutoff, cutoff)))
        XCTAssertTrue(predicate.evaluate(with: sample(cutoff.addingTimeInterval(9_000_000), cutoff.addingTimeInterval(9_000_000))))
        XCTAssertNil(HealthReader.historyPredicate(startingAt: nil))
    }
    func testCatalogCoversEveryQuantityTypeWithCompatibleUnits() throws {
        XCTAssertEqual(HealthCatalog.metrics.count, 121)
        XCTAssertEqual(Set(HealthCatalog.metrics.map(\.id)).count, 121)
        XCTAssertEqual(Set(HealthCatalog.entries.map(\.id)).count, HealthCatalog.entries.count)
        for metric in HealthCatalog.metrics {
            guard let type = metric.sampleType else { continue } // Newer than this simulator's iOS.
            XCTAssertTrue(type.is(compatibleWith: metric.hkUnit), metric.id + " / " + metric.unit)
            XCTAssertEqual(type.aggregationStyle == .cumulative, metric.aggregation == "cumulative", metric.id)
            if metric.unit == "%" { XCTAssertEqual(metric.scale, 100, metric.id) }
        }
        func value(_ id: String, _ quantity: HKQuantity) throws -> Double {
            let metric = try XCTUnwrap(HealthCatalog.metric(id)); return quantity.doubleValue(for: metric.hkUnit) * metric.scale
        }
        XCTAssertEqual(try value("HKQuantityTypeIdentifierOxygenSaturation", HKQuantity(unit: .percent(), doubleValue: 0.97)), 97, accuracy: 0.001)
        XCTAssertEqual(try value("HKQuantityTypeIdentifierBodyFatPercentage", HKQuantity(unit: .percent(), doubleValue: 0.18)), 18, accuracy: 0.001)
        XCTAssertEqual(try value("HKQuantityTypeIdentifierHeartRate", HKQuantity(unit: .count().unitDivided(by: .second()), doubleValue: 1)), 60, accuracy: 0.001)
        XCTAssertEqual(try value("HKQuantityTypeIdentifierDietarySodium", HKQuantity(unit: .gram(), doubleValue: 1.2)), 1200, accuracy: 0.001)
    }
    func testRegistrationDescribesEveryType() throws {
        let registered = HealthCatalog.registration
        XCTAssertEqual(registered.count, HealthCatalog.entries.count)
        let byID = Dictionary(uniqueKeysWithValues: registered.map { ($0["id"] as! String, $0) })
        XCTAssertEqual(byID["HKQuantityTypeIdentifierStepCount"]?["unit"] as? String, "count")
        XCTAssertEqual(byID["HKQuantityTypeIdentifierStepCount"]?["aggregation"] as? String, "cumulative")
        XCTAssertEqual(byID["HKQuantityTypeIdentifierHeartRate"]?["group"] as? String, "vitals")
        XCTAssertEqual(byID["HKCategoryTypeIdentifierSleepAnalysis"]?["kind"] as? String, "category")
        XCTAssertEqual(byID["HKWorkoutTypeIdentifier"]?["kind"] as? String, "workout")
        XCTAssertEqual(byID["HKCorrelationTypeIdentifierFood"]?["kind"] as? String, "correlation")
        XCTAssertFalse(HealthCatalog.readTypes.contains(HealthCatalog.food), "Correlation types cannot be requested")
        XCTAssertEqual(HealthCatalog.writeTypes.count, 6)
    }
    func testQuantityPayloadPreservesIdentityUnitAndStatisticsDays() throws {
        let type = HKQuantityType(.heartRate)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 65), start: date, end: date,
                                      metadata: [HKMetadataKeyTimeZone: "Europe/Brussels"])
        let entry = HealthEntry(type: type, title: "Heart Rate", group: .vitals)
        let result = try PayloadBuilder.build(page: HealthPage(samples: [sample], deletedIDs: ["gone"], anchor: Data([1])), entry: entry, now: date)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        XCTAssertEqual(json["batch_id"] as? String, result.id)
        let record = try XCTUnwrap((json["quantities"] as? [[String: Any]])?.first)
        XCTAssertEqual(record["uuid"] as? String, sample.uuid.uuidString)
        XCTAssertEqual(record["type"] as? String, type.identifier)
        XCTAssertEqual(record["value"] as? Double, 65); XCTAssertEqual(record["unit"] as? String, "count/min")
        XCTAssertEqual(record["time_zone"] as? String, "Europe/Brussels"); XCTAssertNotNil(record["utc_offset"])
        XCTAssertEqual(json["deleted"] as? [String], ["gone"])
        XCTAssertEqual(result.deletions, 1)
        XCTAssertTrue(result.statsDays.contains(LocalDay.string(date)))
        XCTAssertEqual(result.statsDays.count, 7, "A deletion refreshes the last week, which here includes the sample's day")
    }
    func testUnzonedSamplesUseTheCurrentZoneAndMetadataIsBounded() throws {
        let type = HKQuantityType(.stepCount)
        var metadata: [String: Any] = [:]
        for index in 0..<60 { metadata["key\(index)"] = String(repeating: "x", count: 900) }
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: 10), start: Date(), end: Date(), metadata: metadata)
        let result = try PayloadBuilder.build(page: HealthPage(samples: [sample], deletedIDs: [], anchor: Data([1])),
                                              entry: HealthEntry(type: type, title: "Steps", group: .activity))
        let row = try XCTUnwrap(((try JSONSerialization.jsonObject(with: result.body) as? [String: Any])?["quantities"] as? [[String: Any]])?.first)
        XCTAssertEqual(row["time_zone"] as? String, TimeZone.current.identifier, "Matches the calendar HealthKit statistics use")
        XCTAssertNotNil(row["utc_offset"])
        let sent = try XCTUnwrap(row["metadata"] as? [String: String])
        XCTAssertEqual(sent.count, 40); XCTAssertTrue(sent.values.allSatisfy { $0.count == 500 })
    }
    func testRefusedBatchIsSkippedWithoutCountingAsSent() {
        var state = SyncState(); state.anchors["steps"] = Data([1]); state.pending = batch(count: 12)
        let issue = state.skipPending(status: 422)
        XCTAssertEqual(state.anchors["steps"], Data([2]), "The type moves on instead of blocking every other type")
        XCTAssertNil(state.pending); XCTAssertEqual(state.rejected, 12); XCTAssertEqual(state.totalSent, 0)
        XCTAssertTrue(state.statsDays.isEmpty)
        XCTAssertEqual(state.preparationIssues?["steps"], issue); XCTAssertTrue(issue?.contains("422") == true)
        XCTAssertNil(state.skipPending(status: 422))
    }
    func testReceiptReportsDaysOfDeletedSamples() throws {
        let receipt = try JSONDecoder().decode(UploadReceipt.self, from: Data(#"{"batch_id": "b", "accepted": {}, "rejected": [], "deleted_days": {"HKQuantityTypeIdentifierStepCount": ["2026-09-30"]}}"#.utf8))
        XCTAssertEqual(receipt.deletedDays?["HKQuantityTypeIdentifierStepCount"], ["2026-09-30"])
        XCTAssertNil(try JSONDecoder().decode(UploadReceipt.self, from: Data(#"{"rejected": []}"#.utf8)).deletedDays)
    }
    func testCategoryPayloadsCarryLabels() throws {
        let sleep = HKCategoryType(.sleepAnalysis)
        let rem = HKCategorySample(type: sleep, value: HKCategoryValueSleepAnalysis.asleepREM.rawValue, start: Date(), end: Date().addingTimeInterval(60))
        let result = try PayloadBuilder.build(page: HealthPage(samples: [rem], deletedIDs: [], anchor: Data([1])),
                                              entry: HealthEntry(type: sleep, title: "Sleep", group: .sleep))
        let rows = (try JSONSerialization.jsonObject(with: result.body) as! [String: Any])["categories"] as! [[String: Any]]
        XCTAssertEqual(rows[0]["label"] as? String, "rem"); XCTAssertEqual(rows[0]["value"] as? Int, 5)
        XCTAssertTrue(result.statsDays.isEmpty, "HealthKit statistics only exist for quantity types")
        let stand = HKCategoryType(.appleStandHour)
        let idle = HKCategorySample(type: stand, value: HKCategoryValueAppleStandHour.idle.rawValue, start: Date(), end: Date().addingTimeInterval(3600))
        let standRows = (try JSONSerialization.jsonObject(with: PayloadBuilder.build(page: HealthPage(samples: [idle], deletedIDs: [], anchor: Data([1])),
            entry: HealthEntry(type: stand, title: "Stand", group: .activity)).body) as! [String: Any])["categories"] as! [[String: Any]]
        XCTAssertEqual(standRows[0]["label"] as? String, "idle")
    }
    func testMixedPageQuietlySkipsInvalidValuesAndUploadsValidRecords() async throws {
        let type = HKQuantityType(.bodyMassIndex)
        let entry = HealthEntry(type: type, title: "Body Mass Index", group: .body)
        let samples = [Double.nan, 23.5, .infinity, -.infinity, 24].map {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: $0), start: Date(), end: Date())
        }
        let disk = try SyncStore(account: account(), directory: temporaryDirectory())
        var state = SyncState(); state.anchors[entry.id] = Data([1])
        state.preparationIssues = [entry.id: "An earlier warning"]
        XCTAssertTrue(state.preparePage(HealthPage(samples: samples, deletedIDs: [], anchor: Data([2])), entry: entry))
        try disk.save(state)
        state = try disk.load()
        XCTAssertNil(state.preparationIssues?[entry.id], "The previous warning must clear")
        XCTAssertEqual(state.anchors[entry.id], Data([1]))
        XCTAssertEqual(state.pending?.recordCount, 2)
        do {
            _ = try await PendingDelivery.deliver(state, upload: { _ in throw URLError(.timedOut) }, persist: disk.save)
            XCTFail("A failed upload must retain the valid records")
        } catch {}
        XCTAssertEqual(try disk.load().anchors[entry.id], Data([1]))
        state = try await PendingDelivery.deliver(state, upload: { batch in
            let records = (try JSONSerialization.jsonObject(with: batch.body) as! [String: Any])["quantities"] as! [[String: Any]]
            XCTAssertEqual(records.compactMap { $0["value"] as? Double }, [23.5, 24])
            XCTAssertEqual(records.compactMap { $0["uuid"] as? String }, [samples[1].uuid.uuidString, samples[4].uuid.uuidString])
        }, persist: disk.save)
        XCTAssertEqual(state.anchors[entry.id], Data([2]))
        XCTAssertEqual(state.totalSent, 2, "Skipped values must not inflate sent counts")
        XCTAssertNil(state.pending)
    }
    func testEntirelyInvalidPageAdvancesWithoutNetworkUploadOrWarning() async throws {
        let type = HKQuantityType(.bodyMassIndex)
        let entry = HealthEntry(type: type, title: "Body Mass Index", group: .body)
        let samples = (0..<200).map { _ in HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: .nan), start: Date(), end: Date()) }
        let page = HealthPage(samples: samples, deletedIDs: [], anchor: Data([2]))
        var state = SyncState(); state.anchors[entry.id] = Data([1])
        XCTAssertTrue(state.preparePage(page, entry: entry))
        XCTAssertEqual(page.count, 200, "History pagination must use the unfiltered page size")
        XCTAssertEqual(state.pending?.recordCount, 0)
        var saved: SyncState?
        state = try await PendingDelivery.deliver(state, upload: { _ in XCTFail("No valid data to upload") }, persist: { saved = $0 })
        XCTAssertEqual(saved?.anchors[entry.id], Data([2]))
        XCTAssertNil(state.pending); XCTAssertNil(state.lastAccepted); XCTAssertEqual(state.totalSent, 0)
    }
}
