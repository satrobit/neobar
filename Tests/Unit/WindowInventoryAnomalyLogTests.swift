import ApplicationServices
import Foundation
import XCTest

final class WindowInventoryAnomalyLogTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        roots.forEach { try? FileManager.default.removeItem(at: $0) }
        roots.removeAll()
        super.tearDown()
    }

    func testEnablementDefaultsOffAndEnvironmentOverridesDefaults() {
        let suite = "WindowInventoryAnomalyLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(WindowInventoryLogConfiguration.resolvedEnabled(environment: [:], defaults: defaults))
        defaults.set(false, forKey: WindowInventoryLogConfiguration.defaultsKey)
        XCTAssertFalse(WindowInventoryLogConfiguration.resolvedEnabled(environment: [:], defaults: defaults))
        defaults.set(true, forKey: WindowInventoryLogConfiguration.defaultsKey)
        XCTAssertTrue(WindowInventoryLogConfiguration.resolvedEnabled(environment: [:], defaults: defaults))
        XCTAssertFalse(WindowInventoryLogConfiguration.resolvedEnabled(
            environment: ["DOCK_INVENTORY_LOG": "0"], defaults: defaults
        ))
        defaults.set(false, forKey: WindowInventoryLogConfiguration.defaultsKey)
        XCTAssertTrue(WindowInventoryLogConfiguration.resolvedEnabled(
            environment: ["DOCK_INVENTORY_LOG": "1"], defaults: defaults
        ))
        XCTAssertFalse(WindowInventoryLogConfiguration.resolvedEnabled(
            environment: ["DOCK_INVENTORY_LOG": "other"], defaults: defaults
        ))
    }

    func testDisabledLoggerCreatesNoDirectory() {
        let root = makeRoot()
        let directory = root.appendingPathComponent("logs")
        let log = makeLogger(directory: directory, enabled: false)

        log.record(.sessionStart(sessionPayload()))
        log.flush()

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAppendsParseableJSONLinesWithMonotonicSequence() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)

        log.record(.sessionStart(sessionPayload()))
        log.record(.sessionStart(sessionPayload()))
        log.flush()

        let records = try jsonRecords(at: log.currentFileURL)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.compactMap { $0["seq"] as? Int }, [1, 2])
        XCTAssertEqual(records.compactMap { $0["schemaVersion"] as? Int }, [1, 1])
        XCTAssertEqual(records.compactMap { $0["event"] as? String }, ["sessionStart", "sessionStart"])
        XCTAssertEqual(Set(records.compactMap { $0["sessionID"] as? String }).count, 1)
    }

    func testConcurrentWritersDoNotInterleaveLines() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let first = makeLogger(directory: directory, maxFileSize: 1_000_000)
        let second = makeLogger(directory: directory, maxFileSize: 1_000_000)
        let group = DispatchGroup()
        let payload = sessionPayload()

        for index in 0..<80 {
            group.enter()
            DispatchQueue.global().async {
                (index.isMultiple(of: 2) ? first : second).record(.sessionStart(payload))
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        first.flush()
        second.flush()

        XCTAssertEqual(try jsonRecords(at: first.currentFileURL).count, 80)
    }

    func testRepairsPartialTailBeforeAppending() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("window-inventory.jsonl")
        try Data("{partial".utf8).write(to: file)
        let log = makeLogger(directory: directory)

        log.record(.sessionStart(sessionPayload()))
        log.flush()

        XCTAssertEqual(try jsonRecords(at: file).count, 1)
    }

    func testExactThresholdDoesNotRotateAndNextLineDoes() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let seed = makeLogger(directory: directory, maxFileSize: 1_000_000)
        seed.record(.sessionStart(sessionPayload()))
        seed.flush()
        let lineSize = try fileSize(seed.currentFileURL)

        let boundary = makeLogger(directory: directory, maxFileSize: lineSize * 2)
        boundary.record(.sessionStart(sessionPayload()))
        boundary.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: boundary.archiveURL(1).path))
        XCTAssertEqual(try fileSize(boundary.currentFileURL), lineSize * 2)

        boundary.record(.sessionStart(sessionPayload()))
        boundary.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.archiveURL(1).path))
        XCTAssertEqual(try jsonRecords(at: boundary.currentFileURL).count, 1)
    }

    func testRotationKeepsCurrentAndFourArchives() {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory, maxFileSize: 1)

        for _ in 0..<8 { log.record(.sessionStart(sessionPayload())) }
        log.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.currentFileURL.path))
        for index in 1...4 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: log.archiveURL(index).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.archiveURL(5).path))
    }

    func testPermissionsArePrivate() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        log.record(.sessionStart(sessionPayload()))
        log.flush()

        let directoryMode = try posixPermissions(directory)
        let fileMode = try posixPermissions(log.currentFileURL)
        let lockMode = try posixPermissions(log.lockFileURL)
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(lockMode & 0o777, 0o600)
    }

    func testFirstWriteFailureDisablesSessionAndReportsOnce() throws {
        let root = makeRoot()
        let blocker = root.appendingPathComponent("blocker")
        try Data("file".utf8).write(to: blocker)
        let badDirectory = blocker.appendingPathComponent("logs")
        let lock = NSLock()
        var failures = 0
        let log = makeLogger(directory: badDirectory, failureReporter: { _ in
            lock.lock()
            failures += 1
            lock.unlock()
        })

        log.record(.sessionStart(sessionPayload()))
        log.record(.sessionStart(sessionPayload()))
        log.flush()

        XCTAssertEqual(failures, 1)
    }

    func testAbsenceEpisodeUsesAbsentSinceBoundary() {
        var absentSince: Date?
        var episodeID: UUID?
        let firstID = UUID()
        let secondID = UUID()
        let now = Date(timeIntervalSince1970: 100)

        InventoryAbsenceEpisode.beginIfNeeded(
            absentSince: &absentSince, episodeID: &episodeID, now: now, makeID: { firstID }
        )
        XCTAssertEqual(absentSince, now)
        XCTAssertEqual(episodeID, firstID)

        InventoryAbsenceEpisode.beginIfNeeded(
            absentSince: &absentSince, episodeID: &episodeID,
            now: now.addingTimeInterval(5), makeID: { XCTFail("must preserve episode"); return secondID }
        )
        XCTAssertEqual(absentSince, now)
        XCTAssertEqual(episodeID, firstID)

        InventoryAbsenceEpisode.clear(absentSince: &absentSince, episodeID: &episodeID)
        XCTAssertNil(absentSince)
        XCTAssertNil(episodeID)

        InventoryAbsenceEpisode.beginIfNeeded(
            absentSince: &absentSince, episodeID: &episodeID,
            now: now.addingTimeInterval(20), makeID: { secondID }
        )
        XCTAssertEqual(episodeID, secondID)
    }

    func testPhantomHeldDeduplicatorRecordsReasonChangesAndNewEpisodes() {
        var deduplicator = InventoryPhantomHeldDeduplicator()
        let first = UUID()
        let second = UUID()
        let visible: Set<PhantomSeatDecision.HoldReason> = [.everSeenVisible]
        let twoReasons: Set<PhantomSeatDecision.HoldReason> = [.everSeenVisible, .noAXPresentSibling]

        XCTAssertTrue(deduplicator.shouldRecord(pid: 1, seatToken: "seat-a", episodeID: first, reasons: visible))
        XCTAssertFalse(deduplicator.shouldRecord(pid: 1, seatToken: "seat-a", episodeID: first, reasons: visible))
        XCTAssertTrue(deduplicator.shouldRecord(pid: 1, seatToken: "seat-a", episodeID: first, reasons: twoReasons))
        XCTAssertTrue(deduplicator.shouldRecord(pid: 1, seatToken: "seat-a", episodeID: second, reasons: visible))
        XCTAssertTrue(deduplicator.shouldRecord(pid: 1, seatToken: "seat-b", episodeID: first, reasons: visible))
        XCTAssertTrue(deduplicator.shouldRecord(pid: 2, seatToken: "seat-a", episodeID: first, reasons: visible))
        deduplicator.clear(pid: 1, seatToken: "seat-a", episodeID: first)
        XCTAssertTrue(deduplicator.shouldRecord(pid: 1, seatToken: "seat-a", episodeID: first, reasons: visible))
    }

    func testTitleRelationIsNormalizedWithoutPersistingTitle() {
        XCTAssertTrue(WindowInventoryDiagnosticRelations.normalizedTitlesMatch(
            " Review\u{200B} Window ", "review window"
        ))
        XCTAssertFalse(WindowInventoryDiagnosticRelations.normalizedTitlesMatch("", ""))
        XCTAssertFalse(WindowInventoryDiagnosticRelations.normalizedTitlesMatch("One", "Two"))
    }

    func testAllSeatCreationReasons() {
        XCTAssertEqual(
            InventorySeatCreationReason.classify(
                hasPlacedSeat: false, isTearOut: false, isMinimized: true, isOnScreen: false
            ),
            .firstSeat
        )
        XCTAssertEqual(
            InventorySeatCreationReason.classify(
                hasPlacedSeat: true, isTearOut: true, isMinimized: false, isOnScreen: true
            ),
            .tearOut
        )
        XCTAssertEqual(
            InventorySeatCreationReason.classify(
                hasPlacedSeat: true, isTearOut: false, isMinimized: true, isOnScreen: false
            ),
            .minimizedFoldMiss
        )
        XCTAssertEqual(
            InventorySeatCreationReason.classify(
                hasPlacedSeat: true, isTearOut: false, isMinimized: false, isOnScreen: false
            ),
            .offscreenNonMinimized
        )
        XCTAssertEqual(
            InventorySeatCreationReason.classify(
                hasPlacedSeat: true, isTearOut: false, isMinimized: false, isOnScreen: true
            ),
            .visibleUnclaimed
        )
    }

    func testPhantomOwnerRequiresExactlyOneCandidate() {
        let first = InventoryPhantomOwner(seatToken: "seat-a", activeCgID: 10)
        let second = InventoryPhantomOwner(seatToken: "seat-b", activeCgID: 20)

        XCTAssertNil(InventoryPhantomOwnerResolution.uniqueOwner(from: []))
        XCTAssertEqual(InventoryPhantomOwnerResolution.uniqueOwner(from: [first]), first)
        XCTAssertNil(InventoryPhantomOwnerResolution.uniqueOwner(from: [first, second]))
    }

    // MARK: - processGone batch seat-release log

    func testProcessGonePayloadsPreserveOrderAndCount() {
        let snapshot = InventorySeatReleaseSnapshot(
            pid: 1234,
            bundleID: "com.test.app",
            appHidden: false,
            seats: [
                .init(seatToken: "tabgrp-1234-s0", activeCgID: 100, isMinimized: false, isFocused: true, everSeenVisible: true, bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
                .init(seatToken: "tabgrp-1234-s1", activeCgID: 200, isMinimized: true, isFocused: false, everSeenVisible: true, bounds: CGRect(x: 10, y: 10, width: 400, height: 300)),
                .init(seatToken: "tabgrp-1234-s2", activeCgID: 300, isMinimized: false, isFocused: false, everSeenVisible: false, bounds: nil),
            ]
        )

        let payloads = InventorySeatReleasePlan.processGonePayloads(for: snapshot)
        XCTAssertEqual(payloads.count, 3)
        XCTAssertEqual(payloads.map { $0.seatToken }, ["tabgrp-1234-s0", "tabgrp-1234-s1", "tabgrp-1234-s2"])
        XCTAssertEqual(payloads.map { $0.activeCgID }, [100, 200, 300])
        for payload in payloads {
            XCTAssertEqual(payload.reason, .processGone)
            XCTAssertEqual(payload.pid, 1234)
            XCTAssertEqual(payload.bundleID, "com.test.app")
            XCTAssertEqual(payload.appHidden, false)
        }
        XCTAssertEqual(payloads[0].isFocused, true)
        XCTAssertEqual(payloads[1].isMinimized, true)
        XCTAssertNil(payloads[2].bounds)
        XCTAssertEqual(payloads[2].everSeenVisible, false)
    }

    func testProcessGonePayloadsEmptyEntryProducesZero() {
        let snapshot = InventorySeatReleaseSnapshot(
            pid: 9999,
            bundleID: nil,
            appHidden: false,
            seats: []
        )
        XCTAssertTrue(InventorySeatReleasePlan.processGonePayloads(for: snapshot).isEmpty)
    }

    func testSeatReleasedJSONLDecodesCorrectly() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)

        let snapshot = InventorySeatReleaseSnapshot(
            pid: 5555,
            bundleID: "com.example.app",
            appHidden: true,
            seats: [
                .init(seatToken: "tabgrp-5555-s0", activeCgID: 42, isMinimized: false, isFocused: false, everSeenVisible: true, bounds: CGRect(x: 1, y: 2, width: 3, height: 4)),
            ]
        )
        for payload in InventorySeatReleasePlan.processGonePayloads(for: snapshot) {
            log.record(.seatReleased(payload))
        }
        log.flush()

        let records = try jsonRecords(at: log.currentFileURL)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["event"] as? String, "seatReleased")

        // Verify the payload fields
        let payload = try XCTUnwrap(records[0]["payload"] as? [String: Any])
        XCTAssertEqual(payload["reason"] as? String, "processGone")
        XCTAssertEqual(payload["pid"] as? Int, 5555)
        XCTAssertEqual(payload["bundleID"] as? String, "com.example.app")
        XCTAssertEqual(payload["seatToken"] as? String, "tabgrp-5555-s0")
        XCTAssertEqual(payload["activeCgID"] as? Int, 42)
        XCTAssertEqual(payload["isMinimized"] as? Bool, false)
        XCTAssertEqual(payload["isFocused"] as? Bool, false)
        XCTAssertEqual(payload["appHidden"] as? Bool, true)
        XCTAssertEqual(payload["everSeenVisible"] as? Bool, true)

        let bounds = try XCTUnwrap(payload["bounds"] as? [String: Any])
        XCTAssertEqual(bounds["x"] as? Double, 1.0)
        XCTAssertEqual(bounds["y"] as? Double, 2.0)
        XCTAssertEqual(bounds["width"] as? Double, 3.0)
        XCTAssertEqual(bounds["height"] as? Double, 4.0)
    }

    func testReleasePlanCarriesExplicitReasonAndReconcileContext() throws {
        let context = InventoryReconcileContext(
            roundID: 9,
            appReconcileOrdinal: 2,
            source: .periodicReconcile,
            gapMs: 5000,
            usedPreloadedAX: false,
            axReadOutcome: .success(count: 1)
        )
        let snapshot = InventorySeatReleaseSnapshot(
            pid: 77,
            bundleID: "com.example",
            appHidden: false,
            seats: [.init(
                seatToken: "tabgrp-77-s1",
                activeCgID: 8,
                isMinimized: false,
                isFocused: true,
                everSeenVisible: true,
                bounds: nil
            )]
        )
        for reason in [
            InventorySeatReleasedReason.leftCGList,
            .absentBeyondGrace,
            .phantomHealed,
            .mergedIntoTabbedWindow,
        ] {
            let payload = try XCTUnwrap(InventorySeatReleasePlan.payloads(
                for: snapshot,
                reason: reason,
                context: context
            ).first)
            XCTAssertEqual(payload.reason, reason)
            XCTAssertEqual(payload.context, context)
            XCTAssertEqual(payload.seatToken, "tabgrp-77-s1")
        }
    }

    func testOrderEventsUseOneSessionAndStrictlyIncreasingSequence() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        log.record(.orderProjectionChanged(.init(
            previousLiveIDs: [],
            currentLiveIDs: ["chip"],
            absorbedMessagingMainIDs: [],
            visibleMessagingBundleIDs: [],
            drawerBundleIDs: [],
            appKeyByChipID: ["chip": "com.example"]
        )))
        log.record(.orderChipPlaced(.init(
            chipID: "chip",
            appKey: "com.example",
            index: 0,
            reason: StripOrdering.PlacementReason.tail.rawValue
        )))
        log.record(.orderMemoryDropped(.init(
            chipID: "old",
            appKey: "com.example",
            previousIndex: 0,
            absentForMs: 5001
        )))
        log.flush()

        let records = try jsonRecords(at: log.currentFileURL)
        XCTAssertEqual(records.compactMap { $0["seq"] as? Int }, [1, 2, 3])
        XCTAssertEqual(Set(records.compactMap { $0["sessionID"] as? String }).count, 1)
        XCTAssertEqual(records.compactMap { $0["event"] as? String }, [
            "orderProjectionChanged", "orderChipPlaced", "orderMemoryDropped",
        ])
    }

    func testAdmissionProbePersistsModeGenerationCountsAndVerdict() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        log.record(.admissionProbe(.init(
            source: .scan,
            pid: 40474,
            bundleID: "com.kingsoft.wpsoffice.mac",
            processStartTimeSec: 1_700_000_000,
            processStartTimeUsec: 123_456,
            readMode: .timed,
            messagingTimeoutMs: 100,
            maxAttempts: 1,
            readResult: .success,
            errorCode: nil,
            rawWindowCount: 3,
            eligibleWindowCount: 2,
            verdict: .admit
        )))
        log.flush()

        let payload = try XCTUnwrap(jsonRecords(at: log.currentFileURL).first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["source"] as? String, "scan")
        XCTAssertEqual(payload["pid"] as? Int, 40474)
        XCTAssertEqual(payload["readMode"] as? String, "timed")
        XCTAssertEqual(payload["messagingTimeoutMs"] as? Int, 100)
        XCTAssertEqual(payload["maxAttempts"] as? Int, 1)
        XCTAssertEqual(payload["rawWindowCount"] as? Int, 3)
        XCTAssertEqual(payload["eligibleWindowCount"] as? Int, 2)
        XCTAssertEqual(payload["verdict"] as? String, "admit")
    }

    func testUnreadAdmissionProbeOmitsUnsampledCounts() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        log.record(.admissionProbe(.init(
            source: .seed,
            pid: 47258,
            bundleID: "com.kingsoft.wpsoffice.mac",
            processStartTimeSec: 1_700_000_001,
            processStartTimeUsec: 654_321,
            readMode: .untimed,
            messagingTimeoutMs: nil,
            maxAttempts: 2,
            readResult: .unread,
            errorCode: -25204,
            rawWindowCount: nil,
            eligibleWindowCount: nil,
            verdict: .skipUnread
        )))
        log.flush()

        let payload = try XCTUnwrap(jsonRecords(at: log.currentFileURL).first?["payload"] as? [String: Any])
        XCTAssertEqual(payload["readResult"] as? String, "unread")
        XCTAssertEqual(payload["errorCode"] as? Int, -25204)
        XCTAssertNil(payload["messagingTimeoutMs"])
        XCTAssertNil(payload["rawWindowCount"])
        XCTAssertNil(payload["eligibleWindowCount"])
    }

    func testReconcileUnreadJSONLDecodesSourceModeAndPreloadedStatus() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        log.record(.reconcileUnread(.init(
            pid: 4242,
            bundleID: "com.example.slow-app",
            source: .focusChanged,
            readMode: .timed,
            usedPreloadedAX: true,
            errorCode: AXError.cannotComplete.rawValue
        )))
        log.flush()

        let record = try XCTUnwrap(jsonRecords(at: log.currentFileURL).first)
        XCTAssertEqual(record["event"] as? String, "reconcileUnread")
        let payload = try XCTUnwrap(record["payload"] as? [String: Any])
        XCTAssertEqual(payload["pid"] as? Int, 4242)
        XCTAssertEqual(payload["bundleID"] as? String, "com.example.slow-app")
        XCTAssertEqual(payload["source"] as? String, "focusChanged")
        XCTAssertEqual(payload["readMode"] as? String, "timed")
        XCTAssertEqual(payload["usedPreloadedAX"] as? Bool, true)
        XCTAssertEqual(payload["errorCode"] as? Int, Int(AXError.cannotComplete.rawValue))
    }

    func testTitleHeldJSONLOmitsTitleText() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        let context = InventoryReconcileContext(
            roundID: 9,
            appReconcileOrdinal: 3,
            source: .frontmostPoll,
            gapMs: 500,
            usedPreloadedAX: true,
            axReadOutcome: .success(count: 2)
        )
        log.record(.titleHeld(.init(
            context: context,
            pid: 4242,
            bundleID: "com.example.slow-app",
            seatToken: "tabgrp-4242-s1",
            activeCgID: 77,
            errorCode: AXError.cannotComplete.rawValue
        )))
        log.flush()

        let record = try XCTUnwrap(jsonRecords(at: log.currentFileURL).first)
        XCTAssertEqual(record["event"] as? String, "titleHeld")
        let payload = try XCTUnwrap(record["payload"] as? [String: Any])
        XCTAssertEqual(payload["pid"] as? Int, 4242)
        XCTAssertEqual(payload["bundleID"] as? String, "com.example.slow-app")
        XCTAssertEqual(payload["seatToken"] as? String, "tabgrp-4242-s1")
        XCTAssertEqual(payload["activeCgID"] as? Int, 77)
        XCTAssertEqual(payload["errorCode"] as? Int, Int(AXError.cannotComplete.rawValue))
        XCTAssertNil(payload["title"])
        XCTAssertNil(payload["previousTitle"])
    }

    func testWindowSubscriptionEventsEncode() throws {
        let directory = makeRoot().appendingPathComponent("logs")
        let log = makeLogger(directory: directory)
        log.record(.windowSubscription(InventoryWindowSubscriptionPayload(
            event: .attempt, context: nil, flushID: 3, pid: 4242, bundleID: "com.example.app",
            cgWindowID: 77, instanceID: 5, previousInstanceID: 4, kind: .renewal,
            results: ["destroyed": AXError.success.rawValue, "miniaturized": AXError.cannotComplete.rawValue],
            stop: .timeoutSkippedRest, covered: false, durationMs: 101.5
        )))
        log.record(.subscriptionRetryFlush(InventorySubscriptionRetryFlushPayload(
            flushID: 3,
            candidates: [.init(pid: 4242, cgWindowID: 77), .init(pid: 99, cgWindowID: 12)],
            skippedInvalid: 1, executedPID: 4242, executedCgWindowID: 77, durationMs: 0.4
        )))
        log.flush()

        let records = try jsonRecords(at: log.currentFileURL)
        XCTAssertEqual(records.map { $0["event"] as? String }, ["windowSubscription", "subscriptionRetryFlush"])
        let attempt = try XCTUnwrap(records[0]["payload"] as? [String: Any])
        XCTAssertEqual(attempt["event"] as? String, "attempt")
        XCTAssertEqual(attempt["kind"] as? String, "renewal")
        XCTAssertEqual(attempt["stop"] as? String, "timeoutSkippedRest")
        XCTAssertEqual(attempt["instanceID"] as? Int, 5)
        XCTAssertEqual(attempt["previousInstanceID"] as? Int, 4)
        let results = try XCTUnwrap(attempt["results"] as? [String: Int])
        XCTAssertEqual(results["miniaturized"], Int(AXError.cannotComplete.rawValue))
        XCTAssertNil(results["titleChanged"])
        let flush = try XCTUnwrap(records[1]["payload"] as? [String: Any])
        XCTAssertEqual(flush["skippedInvalid"] as? Int, 1)
        XCTAssertEqual((flush["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(flush["executedCgWindowID"] as? Int, 77)
    }

    private func makeLogger(
        directory: URL,
        enabled: Bool = true,
        maxFileSize: Int = 1_000_000,
        archiveCount: Int = 4,
        failureReporter: ((String) -> Void)? = nil
    ) -> WindowInventoryAnomalyLog {
        WindowInventoryAnomalyLog(
            configuration: WindowInventoryLogConfiguration(
                enabled: enabled,
                directoryURL: directory,
                maxFileSize: maxFileSize,
                archiveCount: archiveCount
            ),
            failureReporter: failureReporter
        )
    }

    private func sessionPayload() -> InventorySessionStartPayload {
        InventorySessionStartPayload(
            version: "1.0", build: "1", processID: 42, operatingSystem: "test"
        )
    }

    private func makeRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WindowInventoryAnomalyLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    private func jsonRecords(at url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    private func fileSize(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    private func posixPermissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}
