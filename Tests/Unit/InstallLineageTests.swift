import XCTest
@testable import NeoBar

final class InstallLineageTests: XCTestCase {
    func testMissingDomainIsPristine() {
        XCTAssertEqual(InstallLineage.classify(persistentDomain: nil), .pristine)
    }

    func testEmptyDomainIsPristine() {
        XCTAssertEqual(InstallLineage.classify(persistentDomain: [:]), .pristine)
    }

    func testAnyExistingKeyIsPriorUse() {
        XCTAssertEqual(InstallLineage.classify(persistentDomain: ["existing": true]), .priorUse)
    }

    func testVersion075DefaultDomainIsPriorUse() {
        let domain: [String: Any] = [
            "app.neobar.dockSize": "medium",
            "app.neobar.hoverStyle": "standard",
            "app.neobar.autoHide.nativeDock.delay": 1.0,
            "app.neobar.autoHide.nativeDock.lastEnabledDelay": 1.0,
            "app.neobar.autoHide.edge.delay": 0.1,
            "app.neobar.autoHide.edge.lastEnabledDelay": 0.1,
            "keptAppBundleIDsV3": [String](),
            "messagingBundleIDsV2": [String](),
            "messagingOptOutBundleIDsV2": [String](),
        ]

        XCTAssertEqual(InstallLineage.classify(persistentDomain: domain), .priorUse)
    }

    func testMissingBundleIdentifierFailsClosed() {
        XCTAssertEqual(InstallLineage.capture(bundleID: nil), .priorUse)
        XCTAssertEqual(InstallLineage.capture(bundleID: ""), .priorUse)
    }
}
