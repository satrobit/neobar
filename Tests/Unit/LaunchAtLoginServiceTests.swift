import XCTest
@testable import NeoBar

/// The old login-item path of macOS 12. `SharedFileListLoginItems`, which actually touches CoreServices, is replaced here with an in-memory list,
/// and what is tested is the backend's judgment: when it counts as on, that repeated checking doesn't insert duplicates, that unchecking cleans up fully, and how it behaves when the list can't be opened.
final class LaunchAtLoginServiceTests: XCTestCase {
    private let app = URL(fileURLWithPath: "/Applications/NeoBar.app")
    private let otherApp = URL(fileURLWithPath: "/Applications/Safari.app")

    // MARK: Reading state

    func testUnavailableListReadsUnsupportedAndRefusesToWrite() {
        let list = LoginItemListStub(urls: nil)
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        XCTAssertEqual(backend.readState(), .unsupported)
        XCTAssertThrowsError(try backend.setEnabled(true))
        XCTAssertTrue(list.inserted.isEmpty)
    }

    func testReadsOnOnlyWhenThisBundleIsListed() {
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: []), bundleURL: app).readState(),
            .off
        )
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: [otherApp]), bundleURL: app).readState(),
            .off
        )
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: [otherApp, app]), bundleURL: app).readState(),
            .on
        )
    }

    func testReadTreatsTrailingSlashVariantAsTheSameBundle() {
        // Whether the URL stored in the list has a trailing slash is unstable, so "checked" must not be read as "unchecked" because of it.
        let listed = URL(fileURLWithPath: "/Applications/NeoBar.app/")
        XCTAssertEqual(
            LegacyLoginItemBackend(list: LoginItemListStub(urls: [listed]), bundleURL: app).readState(),
            .on
        )
    }

    // MARK: Writing the switch

    func testEnableInsertsOnceAndIsIdempotent() throws {
        let list = LoginItemListStub(urls: [otherApp])
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        try backend.setEnabled(true)
        try backend.setEnabled(true)

        XCTAssertEqual(list.inserted, [app])
        XCTAssertEqual(backend.readState(), .on)
    }

    func testDisableRemovesEveryMatchingEntryAndLeavesOthersAlone() throws {
        let duplicate = URL(fileURLWithPath: "/Applications/NeoBar.app/")
        let list = LoginItemListStub(urls: [app, otherApp, duplicate])
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        try backend.setEnabled(false)

        XCTAssertEqual(list.removed, [app, duplicate])
        XCTAssertEqual(list.urls, [otherApp])
        XCTAssertEqual(backend.readState(), .off)
    }

    func testDisableWhenNotListedIsANoOp() throws {
        let list = LoginItemListStub(urls: [otherApp])
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        try backend.setEnabled(false)

        XCTAssertTrue(list.removed.isEmpty)
        XCTAssertTrue(list.inserted.isEmpty)
    }

    func testListErrorsPropagateUnchanged() {
        let list = LoginItemListStub(urls: [])
        list.error = LaunchAtLoginError.writeFailed
        let backend = LegacyLoginItemBackend(list: list, bundleURL: app)

        XCTAssertThrowsError(try backend.setEnabled(true)) { error in
            guard case LaunchAtLoginError.writeFailed = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    // MARK: URL matching

    func testMatcherIgnoresTrailingSlashAndNormalizesPath() {
        XCTAssertTrue(LoginItemURLMatcher.matches(
            URL(fileURLWithPath: "/Applications/NeoBar.app/"),
            URL(fileURLWithPath: "/Applications/NeoBar.app")
        ))
        XCTAssertTrue(LoginItemURLMatcher.matches(
            URL(fileURLWithPath: "/Applications/Utilities/../NeoBar.app"),
            URL(fileURLWithPath: "/Applications/NeoBar.app")
        ))
    }

    func testMatcherRejectsOtherBundlesAndLookalikePrefixes() {
        XCTAssertFalse(LoginItemURLMatcher.matches(app, otherApp))
        // A shared prefix doesn't make it the same bundle.
        XCTAssertFalse(LoginItemURLMatcher.matches(
            URL(fileURLWithPath: "/Applications/NeoBar.app"),
            URL(fileURLWithPath: "/Applications/NeoBar.app.bak")
        ))
    }

    // MARK: The service layer is just a background queue wrapper

    @MainActor
    func testServiceReadsAndWritesThroughTheInjectedBackend() async throws {
        let list = LoginItemListStub(urls: [app])
        let service = LaunchAtLoginService(backend: LegacyLoginItemBackend(list: list, bundleURL: app))

        let state = await service.currentState()
        XCTAssertEqual(state, .on)

        try service.setEnabled(false)
        XCTAssertEqual(list.removed, [app])
        let after = await service.currentState()
        XCTAssertEqual(after, .off)
    }
}

private final class LoginItemListStub: LoginItemListing, @unchecked Sendable {
    var urls: [URL]?
    var inserted: [URL] = []
    var removed: [URL] = []
    var error: Error?

    init(urls: [URL]?) {
        self.urls = urls
    }

    func itemURLs() -> [URL]? { urls }

    func insert(_ url: URL) throws {
        if let error { throw error }
        inserted.append(url)
        urls?.append(url)
    }

    func remove(_ url: URL) throws {
        if let error { throw error }
        removed.append(url)
        urls?.removeAll { $0 == url }
    }
}
