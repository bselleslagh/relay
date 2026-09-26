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
    private func account(_ origin: String = "https://health.example.test") throws -> Credentials {
        Credentials(server: try ServerAddress(origin), userID: "D72BFCDF-0012-4B72-9ABD-85E363816B78", accessToken: "test-access", refreshToken: "test-refresh")
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
    private func batch(count: Int = 1) -> SyncBatch {
        SyncBatch(typeID: "steps", group: .activity, body: Data("{\"provider\":\"apple\"}".utf8), nextAnchor: Data([2]), recordCount: count, deletedIDs: ["deleted-sample"])
    }
    func testOnlyHTTPSOriginCanReceiveCredentials() throws {
        for address in ["http://example.test", "https://name:password@example.test", "https://example.test/path", "https://example.test?q=secret", "https://example.test#fragment", "https://example.test:99999"] {
            XCTAssertThrowsError(try ServerAddress(address), address)
        }
        XCTAssertEqual(try ServerAddress("  https://EXAMPLE.test:9443/ ").url.absoluteString, "https://example.test:9443")
    }
    func testInvitationCodeValidation() throws {
        XCTAssertEqual(try WearablesClient.normalizedCode("abcd-23ef"), "ABCD23EF")
        XCTAssertThrowsError(try WearablesClient.normalizedCode("ABC12345"))
        XCTAssertThrowsError(try WearablesClient.normalizedCode("ABCD"))
    }
    func testReceiptRejectsHTTPErrorMalformedBodyAndDroppedRecords() {
        for (status, text) in [(503,"{}"), (202,"<html>ok</html>"), (202,"{\"status_code\":202,\"response\":\"queued\",\"dropped_count\":2}"), (202,"{\"status_code\":500,\"response\":\"failed\"}")] {
            XCTAssertThrowsError(try UploadReceipt.validate(data: Data(text.utf8), httpStatus: status))
        }
    }
    func testValidReceiptMeansAcceptedOnly() throws {
        let receipt = try UploadReceipt.validate(data: Data("{\"status_code\":202,\"response\":\"Import task queued successfully\"}".utf8), httpStatus: 202)
        XCTAssertEqual(receipt.statusCode, 202)
    }
    func testUploadFailurePreservesDurableBatchAndAnchor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try SyncStore(account: account(), directory: directory)
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
    }
    func testSuccessfulDeliveryCommitsAnchorAndDeletionJournalTogether() async throws {
        var state = SyncState(); state.pending = batch(count: 7)
        var written: SyncState?
        let result = try await PendingDelivery.deliver(state, upload: { _ in }, persist: { written = $0 })
        XCTAssertEqual(written?.anchors["steps"], Data([2]))
        XCTAssertEqual(result.sentToday, 7)
        XCTAssertEqual(result.deletedIDs, ["deleted-sample"])
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
    func testEmptyPageCommitsLocallyWithoutUploading() async throws {
        var state = SyncState(); state.pending = batch(count: 0)
        let result = try await PendingDelivery.deliver(state, upload: { _ in XCTFail("No health records to upload") }, persist: { _ in })
        XCTAssertNil(result.lastAccepted); XCTAssertEqual(result.acceptedBatches, 0)
        XCTAssertEqual(result.anchors["steps"], Data([2]))
    }
    func testCheckpointsAreIsolatedByServerAndUser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try SyncStore(account: account(), directory: directory)
        let other = try SyncStore(account: account("https://second.example.test"), directory: directory)
        var state = SyncState(); state.pending = batch(); try first.save(state)
        XCTAssertNil(try other.load().pending)
    }
    func testDailyCountersResetWithoutLosingLifetimeTotal() {
        var state = SyncState(); state.day = .distantPast; state.sentToday = 99; state.totalSent = 100
        state.pending = batch(count: 3); state.commitPending()
        XCTAssertEqual(state.sentToday, 3); XCTAssertEqual(state.totalSent, 103)
    }
    func testHistoryRescanNeverDiscardsAnUnsentBatch() throws {
        var state = SyncState(); state.anchors["steps"] = Data([3]); state.pending = batch()
        XCTAssertThrowsError(try state.prepareFullRescan())
        XCTAssertEqual(state.anchors["steps"], Data([3])); XCTAssertNotNil(state.pending)
        state.pending = nil; state.totalSent = 42
        try state.prepareFullRescan()
        XCTAssertTrue(state.anchors.isEmpty); XCTAssertEqual(state.totalSent, 42)
    }
    func testUploadRefreshesExpiredTokenAndRetriesSameBatch() async throws {
        let vault = MemoryVault(try account()); let client = WearablesClient(vault: vault, session: session())
        var uploads = 0; var requestIDs: [String] = []
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("token/refresh") {
                return (200, Data("{\"access_token\":\"new-access\",\"refresh_token\":\"rotated-refresh\"}".utf8))
            }
            uploads += 1; requestIDs.append(request.value(forHTTPHeaderField: "X-Request-Id")!)
            if uploads == 1 { return (401, Data()) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (202, Data("{\"status_code\":202,\"response\":\"queued\"}".utf8))
        }
        try await client.upload(batch(), wifiOnly: true)
        XCTAssertEqual(uploads, 2); XCTAssertEqual(Set(requestIDs).count, 1)
        XCTAssertEqual(vault.credentials?.refreshToken, "rotated-refresh")
    }
    func testTransientRefreshFailureKeepsCredentials() async throws {
        let vault = MemoryVault(try account()); let client = WearablesClient(vault: vault, session: session())
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("token/refresh") { throw URLError(.notConnectedToInternet) }
            return (401, Data())
        }
        do { try await client.upload(batch(), wifiOnly: false); XCTFail("Expected network failure") } catch {}
        XCTAssertEqual(vault.credentials?.refreshToken, "test-refresh")
    }
    func testCatalogHasUniqueAvailableTypesAndExpectedConversions() throws {
        XCTAssertEqual(HealthCatalog.metrics.count, 71)
        XCTAssertEqual(Set(HealthCatalog.entries.map(\.id)).count, HealthCatalog.entries.count)
        let oxygen = try XCTUnwrap(HealthCatalog.metrics.first { $0.id.hasSuffix("OxygenSaturation") })
        XCTAssertEqual(HKQuantity(unit: .percent(), doubleValue: 0.97).doubleValue(for: oxygen.hkUnit) * oxygen.scale, 97, accuracy: 0.001)
        let fat = try XCTUnwrap(HealthCatalog.metrics.first { $0.id.hasSuffix("BodyFatPercentage") })
        XCTAssertEqual(fat.scale, 1)
        let bmi = try XCTUnwrap(HealthCatalog.metrics.first { $0.id.hasSuffix("BodyMassIndex") })
        XCTAssertEqual(bmi.hkUnit, .count())
        for metric in HealthCatalog.metrics {
            let type = try XCTUnwrap(metric.sampleType, metric.id)
            XCTAssertTrue(type.is(compatibleWith: metric.hkUnit), metric.id + " / " + metric.unit)
        }
    }
    func testQuantityPayloadPreservesIdentityAndCanonicalUnit() throws {
        let type = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HKQuantitySample(type: type, quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: 65), start: date, end: date)
        let page = HealthPage(samples: [sample], deletedIDs: [], anchor: Data([1]))
        let entry = HealthEntry(type: type, title: "Heart rate", group: .vitals)
        let result = try PayloadBuilder.build(page: page, entry: entry, sessionID: "test-session", historical: true)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.body) as? [String: Any])
        let data = json["data"] as! [String: Any]; let record = (data["records"] as! [[String: Any]])[0]
        XCTAssertEqual(record["id"] as? String, sample.uuid.uuidString)
        XCTAssertEqual(record["value"] as? Double, 65)
        XCTAssertEqual(record["unit"] as? String, "count/min")
        XCTAssertEqual(json["syncType"] as? String, "historical")
    }
    func testSleepStagePayload() throws {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let sample = HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.asleepREM.rawValue, start: Date(), end: Date().addingTimeInterval(60))
        let result = try PayloadBuilder.build(page: HealthPage(samples: [sample], deletedIDs: [], anchor: Data([1])), entry: HealthEntry(type: type, title: "Sleep", group: .sleep), sessionID: "test", historical: false)
        let root = try JSONSerialization.jsonObject(with: result.body) as! [String: Any]
        let sleep = (root["data"] as! [String: Any])["sleep"] as! [[String: Any]]
        XCTAssertEqual(sleep[0]["stage"] as? String, "rem")
    }
    func testMixedPageQuietlySkipsInvalidValuesAndUploadsValidRecords() async throws {
        let type = HKObjectType.quantityType(forIdentifier: .bodyMassIndex)!
        let entry = HealthEntry(type: type, title: "Body Mass Index", group: .body)
        let samples = [Double.nan, 23.5, .infinity, -.infinity, 24].map {
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: $0), start: Date(), end: Date())
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try SyncStore(account: account(), directory: directory)
        var state = SyncState(); state.anchors[entry.id] = Data([1])
        state.preparationIssues = [entry.id: "Apple Health returned an invalid number for Body Mass Index. This page is kept for retry; other types can still sync."]
        XCTAssertTrue(state.preparePage(HealthPage(samples: samples, deletedIDs: [], anchor: Data([2])), entry: entry, sessionID: "test", historical: true))
        try disk.save(state)
        state = try disk.load()
        XCTAssertNil(state.preparationIssues?[entry.id], "The previous invalid-value warning must clear")
        XCTAssertEqual(state.anchors[entry.id], Data([1]))
        XCTAssertEqual(state.pending?.recordCount, 2)
        XCTAssertEqual(state.totalSent, 0)
        do {
            _ = try await PendingDelivery.deliver(state, upload: { _ in throw URLError(.timedOut) }, persist: disk.save)
            XCTFail("A failed upload must retain the valid records")
        } catch {}
        XCTAssertEqual(try disk.load().anchors[entry.id], Data([1]))
        XCTAssertEqual(try disk.load().pending?.recordCount, 2)
        state = try await PendingDelivery.deliver(state, upload: { batch in
            let root = try JSONSerialization.jsonObject(with: batch.body) as! [String: Any]
            let records = (root["data"] as! [String: Any])["records"] as! [[String: Any]]
            XCTAssertEqual(records.compactMap { $0["value"] as? Double }, [23.5, 24])
            XCTAssertEqual(records.compactMap { $0["id"] as? String }, [samples[1].uuid.uuidString, samples[4].uuid.uuidString])
        }, persist: disk.save)
        XCTAssertEqual(state.anchors[entry.id], Data([2]))
        XCTAssertEqual(state.totalSent, 2, "Skipped values must not inflate sent counts")
        XCTAssertNil(state.pending)
    }
    func testEntirelyInvalidPageAdvancesWithoutNetworkUploadOrWarning() async throws {
        let type = HKObjectType.quantityType(forIdentifier: .bodyMassIndex)!
        let entry = HealthEntry(type: type, title: "Body Mass Index", group: .body)
        let samples = (0..<200).map { _ in
            HKQuantitySample(type: type, quantity: HKQuantity(unit: .count(), doubleValue: .nan), start: Date(), end: Date())
        }
        let page = HealthPage(samples: samples, deletedIDs: [], anchor: Data([2]))
        var state = SyncState(); state.anchors[entry.id] = Data([1])
        XCTAssertTrue(state.preparePage(page, entry: entry, sessionID: "test", historical: true))
        XCTAssertEqual(page.count, 200, "History pagination must use the unfiltered page size")
        XCTAssertEqual(state.pending?.recordCount, 0)
        XCTAssertTrue(state.preparationIssues?.isEmpty ?? true)
        var saved: SyncState?
        state = try await PendingDelivery.deliver(state, upload: { _ in XCTFail("No valid data to upload") }, persist: { saved = $0 })
        XCTAssertEqual(saved?.anchors[entry.id], Data([2]))
        XCTAssertNil(state.pending)
        XCTAssertNil(state.lastAccepted)
        XCTAssertEqual(state.totalSent, 0)
        XCTAssertEqual(state.acceptedBatches, 0)
    }
    func testOlderCheckpointRemainsReadableWithPreparationIssuesAdded() throws {
        var old = SyncState(); old.totalSent = 76487; old.anchors["steps"] = Data([1])
        let encoded = try JSONEncoder().encode(old)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["preparationIssues"])
        let restored = try JSONDecoder().decode(SyncState.self, from: encoded)
        XCTAssertEqual(restored.totalSent, 76487)
        XCTAssertEqual(restored.anchors["steps"], Data([1]))
        XCTAssertNil(restored.preparationIssues)
    }
}
