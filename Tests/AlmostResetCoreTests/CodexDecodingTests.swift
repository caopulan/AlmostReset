import XCTest
@testable import AlmostResetCore

final class CodexDecodingTests: XCTestCase {
    func testDesktopCollaborationSettingsAndCanonicalTurnTakePrecedence() {
        let fallback = Session(id: "fixture", title: "Session", projectPath: "/tmp")
        let state: [String: Any] = [
            "latestModel": "model-a", "latestReasoningEffort": NSNull(),
            "latestThreadSettings": ["model": "model-a", "effort": "high", "serviceTier": "priority"],
            "latestCollaborationMode": ["settings": ["model": "model-b", "reasoning_effort": "xhigh"]],
            "threadRuntimeStatus": ["type": "active"], "requests": [],
            "turnHistory": ["history": ["entitiesByKey": ["turn:1": ["turnId": "turn-1", "status": "inProgress"]]]]
        ]
        let session = CodexService.decodeDesktop(state, fallback: fallback)
        XCTAssertEqual(session.model, "model-b")
        XCTAssertEqual(session.reasoning, .xhigh)
        XCTAssertEqual(session.speed, .fast)
        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.activeTurnID, "turn-1")
    }

    func testUnknownTierDoesNotBecomeNormal() {
        XCTAssertNil(CodexService.speed(nil))
        XCTAssertNil(CodexService.speed("a-new-tier"))
        XCTAssertEqual(CodexService.speed("default"), .normal)
    }

    func testPublicWaitingFlagsAreStrings() {
        let session = CodexService.decodeThread(["id": "fixture", "status": ["type": "active", "activeFlags": ["waitingOnApproval"]]])
        XCTAssertEqual(session.status, .waiting)
    }
}
