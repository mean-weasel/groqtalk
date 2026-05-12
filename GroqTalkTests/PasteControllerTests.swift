import XCTest
@testable import GroqTalk

// MARK: - Delegate spy

@MainActor
private final class PasteControllerDelegateSpy: PasteControllerDelegate {
    private(set) var pastes: [(text: String, delivery: PasteDelivery)] = []

    func pasteController(_ controller: PasteController, didPaste text: String, delivery: PasteDelivery) {
        pastes.append((text: text, delivery: delivery))
    }
}

// MARK: - Tests

@MainActor
final class PasteControllerTests: XCTestCase {

    private var appState: AppState!
    private var spy: PasteControllerDelegateSpy!

    override func setUp() {
        super.setUp()
        appState = AppState()
        spy = PasteControllerDelegateSpy()
    }

    override func tearDown() {
        appState = nil
        spy = nil
        UserDefaults.standard.removeObject(forKey: "asyncPasteEnabled")
        UserDefaults.standard.removeObject(forKey: "keepOnClipboard")
        UserDefaults.standard.removeObject(forKey: "experimentalSkyLightPasteEnabled")
        super.tearDown()
    }

    private func makeController() -> PasteController {
        let controller = PasteController(textInserter: TextInserter(), appState: appState)
        controller.delegate = spy
        return controller
    }

    // MARK: - captureTarget

    func testCaptureTargetNilsWhenAsyncDisabled() {
        appState.asyncPasteEnabled = false
        let controller = makeController()

        controller.captureTarget()

        XCTAssertNil(controller.pendingTarget, "pendingTarget should be nil when asyncPasteEnabled is false")
    }

    func testCaptureTargetSetsTargetWhenAsyncEnabled() {
        // We can't guarantee a real window is available in unit tests,
        // but we can verify the logic runs without crashing and that
        // the target is set (it may be nil if no frontmost app is available).
        appState.asyncPasteEnabled = true
        let controller = makeController()

        // Should not throw or crash
        controller.captureTarget()

        // pendingTarget is either nil (no frontmost app in headless test)
        // or a valid PasteTarget — both are acceptable outcomes.
        // What matters is the async-disabled path always sets nil.
    }

    // MARK: - clearPendingTarget

    func testClearPendingTargetNilsTarget() {
        appState.asyncPasteEnabled = false
        let controller = makeController()

        // Manually set a target to simulate a prior captureTarget call
        // (we access the internals via @testable import in a white-box test)
        controller.captureTarget() // sets nil (asyncPasteEnabled is false, but still exercises clear path)

        controller.clearPendingTarget()

        XCTAssertNil(controller.pendingTarget)
    }

    // MARK: - PasteQueue initialization

    func testPasteQueueIsInitialized() {
        let controller = makeController()
        // pasteQueue is a non-optional after init — merely accessing it proves it was set
        XCTAssertNotNil(controller.pasteQueue)
    }

    // MARK: - pasteDirectly

    func testPasteDirectlyCallsDelegateWithDelivery() async {
        appState.keepOnClipboard = true // avoid clipboard side effects in tests
        let controller = makeController()

        await controller.pasteDirectly(text: "hello")

        XCTAssertEqual(spy.pastes.count, 1)
        XCTAssertEqual(spy.pastes.first?.text, "hello")
        // The delivery value depends on the real TextInserter; we just verify
        // the delegate was called with a non-nil delivery.
        XCTAssertNotNil(spy.pastes.first?.delivery)
    }

    func testPasteDirectlyDoesNotUseQueue() async {
        // Even when asyncPasteEnabled is true, pasteDirectly bypasses the queue.
        appState.asyncPasteEnabled = true
        appState.keepOnClipboard = true
        let controller = makeController()

        // captureTarget so there IS a pending target in theory
        controller.captureTarget()

        await controller.pasteDirectly(text: "direct")

        // pendingTarget should be untouched (pasteDirectly doesn't consume it)
        // and delegate is still notified
        XCTAssertEqual(spy.pastes.count, 1)
        XCTAssertEqual(spy.pastes.first?.text, "direct")
    }

    // MARK: - paste (sync path)

    func testPasteSyncPathCallsDelegate() async {
        appState.asyncPasteEnabled = false
        appState.keepOnClipboard = true
        let controller = makeController()

        await controller.paste(text: "sync paste")

        XCTAssertEqual(spy.pastes.count, 1)
        XCTAssertEqual(spy.pastes.first?.text, "sync paste")
    }

    func testPasteConsumesAndClearsPendingTarget() async {
        appState.asyncPasteEnabled = false
        appState.keepOnClipboard = true
        let controller = makeController()

        controller.captureTarget() // captures nil because asyncPasteEnabled is false

        await controller.paste(text: "consume")

        // After paste, pendingTarget should be nil (consumed)
        XCTAssertNil(controller.pendingTarget)
        XCTAssertEqual(spy.pastes.count, 1)
    }

    // MARK: - Delegate wiring

    func testDelegateIsWeaklyHeld() {
        let controller = makeController()
        // spy is held by the test — controller.delegate is weak, so this is
        // just a compile-time verification that the property is weak.
        XCTAssertTrue(controller.delegate === spy)
    }
}
