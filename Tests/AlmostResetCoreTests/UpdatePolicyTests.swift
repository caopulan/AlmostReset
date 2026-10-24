import XCTest
@testable import AlmostResetCore
final class UpdatePolicyTests: XCTestCase {
    func testInstallOnlyWhenIdleAndStorageReady() {
        XCTAssertFalse(UpdateInstallationPolicy.canInstall(listening: false, executing: false, refreshing: false, reconnecting: false, storageReady: true, writingRules: true))
        XCTAssertTrue(UpdateInstallationPolicy.canInstall(listening: false, executing: false, refreshing: false, reconnecting: false, storageReady: true))
        XCTAssertFalse(UpdateInstallationPolicy.canInstall(listening: true, executing: false, refreshing: false, reconnecting: false, storageReady: true))
        XCTAssertFalse(UpdateInstallationPolicy.canInstall(listening: false, executing: true, refreshing: false, reconnecting: false, storageReady: true))
        XCTAssertFalse(UpdateInstallationPolicy.canInstall(listening: false, executing: false, refreshing: true, reconnecting: false, storageReady: true))
        XCTAssertFalse(UpdateInstallationPolicy.canInstall(listening: false, executing: false, refreshing: false, reconnecting: true, storageReady: true))
        XCTAssertFalse(UpdateInstallationPolicy.canInstall(listening: false, executing: false, refreshing: false, reconnecting: false, storageReady: false))
    }
}
