import XCTest
@testable import AlmostResetCore

final class SessionCollectionTests: XCTestCase {
    func testOneOwnerBarrierFailureDoesNotAbortOtherOwners() {
        enum Unresponsive: Error { case timeout }
        let result = DesktopOwnerSynchronization.collect(owners: ["a":"good-a", "b":"bad", "b2":"bad", "c":"good-c"]) { _, owner in
            if owner == "bad" { throw Unresponsive.timeout }
        }
        XCTAssertEqual(Set(result.ready.keys), ["a", "c"])
        XCTAssertEqual(Set(result.issues.keys), ["b", "b2"])
    }
    func testPaginationDuplicatesKeepLatestCatalogEntry() {
        let rows = CodexService.uniqueCatalog([
            ["id":"a", "updatedAt":10, "name":"old"],
            ["id":"b", "updatedAt":15],
            ["id":"a", "updatedAt":20, "name":"new"], ["updatedAt":30]
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["name"] as? String, "new")
        XCTAssertEqual(rows[1]["id"] as? String, "b")
    }

    func testDiscoveryDistinguishesUnownedAndUnansweredAndPreservesOtherOwners() {
        var batch = DesktopOwnerDiscovery(pending: ["one":"a", "two":"b", "three":"c", "four":"d"])
        batch.receive(["requestId":"one", "method":"thread-owner-discovery", "resultType":"success", "handledByClientId":"owner-a"])
        batch.receive(["requestId":"two", "resultType":"error", "error":"unsupported-version"])
        batch.receive(["requestId":"three", "resultType":"error", "error":"no-client-found"])
        batch.finish()
        XCTAssertEqual(batch.owners, ["a":"owner-a"])
        XCTAssertNotNil(batch.issues["b"])
        XCTAssertNotNil(batch.issues["d"])
        XCTAssertNil(batch.issues["c"])
    }
    func testLateOwnerReplyBeforeDeadlineIsRetainedAndUnrelatedRepliesIgnored() {
        var batch = DesktopOwnerDiscovery(pending: ["new":"a"])
        batch.receive(["requestId":"old", "method":"thread-owner-discovery", "resultType":"success", "handledByClientId":"old-owner"])
        XCTAssertEqual(batch.pending.count, 1)
        batch.receive(["requestId":"new", "method":"thread-owner-discovery", "resultType":"success", "handledByClientId":"owner"])
        batch.finish()
        XCTAssertEqual(batch.owners["a"], "owner")
        XCTAssertTrue(batch.issues.isEmpty)
    }
    func testFourPreviousMatchesRemainAuditableWhenOnlyTwoLiveSnapshotsArrive() {
        let now = Date()
        let rule = AutomationRule(selector: .conditions(match: .all, conditions: [
            SessionCondition(field: .model, values: ["gpt-6-astra"]),
            SessionCondition(field: .speed, values: ["fast", "ultrafast"])
        ]), action: .stop)
        let previous = (0..<4).map { i in
            Session(id: "s\(i)", title: "session", projectPath: "", model: "gpt-6-astra", reasoning: .high,
                    speed: .fast, status: .running, activeTurnID: "turn", updatedAt: now.addingTimeInterval(-3600),
                    control: SessionControl(canInterrupt: true))
        }
        let unknown = SessionCollection.unavailable(Session(id: "s2", title: "session", projectPath: "", updatedAt: now), previous: previous[2], reason: "Timed out")
        let current = [previous[0], previous[1], unknown]
        let audit = SessionCollection.auditCandidates(rules: [rule], previous: previous, current: current, now: now)
        XCTAssertEqual(audit, Set(previous.map(\.id)))
        XCTAssertEqual(unknown.model, "gpt-6-astra")
        XCTAssertEqual(unknown.speed, .fast)
        XCTAssertEqual(unknown.status, .unknown)
        XCTAssertFalse(unknown.control.canInterrupt)
        XCTAssertNil(unknown.activeTurnID)
        XCTAssertEqual(RuleEngine.plan(rules: [rule], sessions: current).count, 2)
        XCTAssertEqual(RuleEngine.plan(rules: [rule], sessions: previous).count, 4)
    }
}
