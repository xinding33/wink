import XCTest
@testable import DisplaySwitchCore

final class FakeBackend: DisplayBackend {
    var available = true
    var screens = [Display(id: 1, uuid: "one", name: "First"), Display(id: 2, uuid: "two", name: "Second")]
    var disconnected: [UInt32: Display] = [:]
    var ignoreDisable = false
    var rejectEnable = false
    var beforeDisable: (() throws -> Void)?
    var changes: [(UInt32, Bool)] = []
    func displays() throws -> [Display] { screens }
    func setEnabled(_ id: UInt32, _ enabled: Bool) throws {
        changes.append((id, enabled))
        if enabled {
            if rejectEnable { throw DisplayError("Rejected") }
            if let display = disconnected.removeValue(forKey: id) { screens.append(display) }
        } else {
            try beforeDisable?()
            if ignoreDisable { return }
            disconnected[id] = screens.first { $0.id == id }
            screens.removeAll { $0.id == id }
        }
    }
}

final class DisplayControlTests: XCTestCase {
    var folder: URL!
    var backend: FakeBackend!
    var store: RecoveryStore!
    var controller: DisplayController!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        backend = FakeBackend()
        store = RecoveryStore(url: folder.appendingPathComponent("state.json"), boot: "test-boot")
        controller = DisplayController(backend: backend, store: store, wait: { _ in })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testDisableThenReconnectAndPersistBeforeMutation() throws {
        backend.beforeDisable = { XCTAssertEqual(try self.store.load().map(\.id), [2]) }
        try controller.disconnect(2)
        XCTAssertEqual(backend.screens.map(\.id), [1])
        let saved = try XCTUnwrap(controller.remembered().first)
        try controller.reconnect(saved)
        XCTAssertEqual(Set(backend.screens.map(\.id)), [1, 2])
        XCTAssertTrue(try store.load().isEmpty)
    }
    func testLastScreenCannotBeDisabled() throws {
        try controller.disconnect(2)
        XCTAssertThrowsError(try controller.disconnect(1))
        XCTAssertEqual(backend.changes.count, 1)
    }
    func testBuiltInCannotBeDisabled() {
        backend.screens[1].builtIn = true
        XCTAssertThrowsError(try controller.disconnect(2))
        XCTAssertTrue(backend.changes.isEmpty)
    }
    func testMirrorSourceAndTargetCannotBeDisabled() {
        backend.screens[1].mirrors = 1
        XCTAssertThrowsError(try controller.disconnect(1))
        XCTAssertThrowsError(try controller.disconnect(2))
        XCTAssertTrue(backend.changes.isEmpty)
    }
    func testInactiveRemainingScreenDoesNotSatisfyGuard() {
        backend.screens[0].active = false
        XCTAssertThrowsError(try controller.disconnect(2))
    }
    func testUnsupportedAPIMakesNoChanges() {
        backend.available = false
        XCTAssertThrowsError(try controller.disconnect(2))
        XCTAssertTrue(backend.changes.isEmpty)
    }
    func testNoOpDisableIsNotReportedAsSuccess() throws {
        backend.ignoreDisable = true
        XCTAssertThrowsError(try controller.disconnect(2))
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(backend.changes.last?.1 == true)
    }
    func testFailedReconnectRetainsRecoveryRecord() throws {
        try controller.disconnect(2)
        backend.rejectEnable = true
        XCTAssertFalse(controller.reconnectAll().isEmpty)
        XCTAssertEqual(try store.load().map(\.id), [2])
    }
    func testRecoveryAfterControllerRestart() throws {
        try controller.disconnect(2)
        let restarted = DisplayController(backend: backend, store: store, wait: { _ in })
        XCTAssertTrue(restarted.reconnectAll().isEmpty)
        XCTAssertEqual(backend.screens.count, 2)
    }
    func testRebootInvalidatesSavedDisplayIDs() throws {
        try controller.disconnect(2)
        let afterReboot = RecoveryStore(url: store.url, boot: "next-boot")
        XCTAssertTrue(try afterReboot.load().isEmpty)
    }
    func testReusedDisplayIDIsNotMutated() throws {
        try controller.disconnect(2)
        backend.screens.append(Display(id: 2, uuid: "replacement", name: "Replacement"))
        let priorChanges = backend.changes.count
        XCTAssertFalse(controller.reconnectAll().isEmpty)
        XCTAssertEqual(backend.changes.count, priorChanges)
    }
    func testReplugWithNewIDClearsRecoveryWithoutMutation() throws {
        try controller.disconnect(2)
        backend.screens.append(Display(id: 9, uuid: "two", name: "Second"))
        XCTAssertTrue(controller.reconnectAll().isEmpty)
        XCTAssertEqual(backend.changes.count, 1)
        XCTAssertTrue(try store.load().isEmpty)
    }
}
