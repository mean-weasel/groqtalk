import XCTest
@testable import GroqTalk

final class PasteQueueTests: XCTestCase {
    private let target = PasteTarget(windowElement: nil, windowID: nil, pid: 1, appName: "A")

    func testEnqueueAndDrain() async {
        var pastedTexts: [String] = []

        let queue = PasteQueue { text, _, _ in
            pastedTexts.append(text)
            return .asyncQueued
        }

        let first = await queue.enqueue(text: "hello", target: PasteTarget(windowElement: nil, windowID: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        let second = await queue.enqueue(text: "world", target: PasteTarget(windowElement: nil, windowID: nil, pid: 2, appName: "B"), keepOnClipboard: false)

        XCTAssertEqual(pastedTexts, ["hello", "world"])
        XCTAssertEqual(first, .asyncQueued)
        XCTAssertEqual(second, .asyncQueued)
    }

    func testSerializesExecution() async {
        var order: [Int] = []
        let expectation = XCTestExpectation(description: "all pastes complete")
        expectation.expectedFulfillmentCount = 3

        let queue = PasteQueue { text, _, _ in
            let index = Int(text)!
            // Simulate variable paste durations
            try? await Task.sleep(for: .milliseconds(50 - index * 10))
            order.append(index)
            expectation.fulfill()
            return .asyncQueued
        }

        // Enqueue sequentially — each must execute in the order submitted
        // (serialization prevents the shortest-sleep item from winning the race).
        await queue.enqueue(text: "1", target: PasteTarget(windowElement: nil, windowID: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        await queue.enqueue(text: "2", target: PasteTarget(windowElement: nil, windowID: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        await queue.enqueue(text: "3", target: PasteTarget(windowElement: nil, windowID: nil, pid: 1, appName: "A"), keepOnClipboard: false)

        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testConcurrentEnqueuesWaitForActivePaste() async {
        let gate = AsyncGate()
        let recorder = PasteRecorder()
        let firstStarted = XCTestExpectation(description: "first paste started")
        let laterPasteStartedEarly = XCTestExpectation(description: "later paste started before first completed")
        laterPasteStartedEarly.isInverted = true

        let queue = PasteQueue { text, _, _ in
            let index = Int(text)!
            await recorder.recordStart(index)
            if index == 1 {
                firstStarted.fulfill()
                await gate.wait()
            } else {
                laterPasteStartedEarly.fulfill()
            }
            await recorder.recordFinish(index)
            return .asyncQueued
        }

        async let first = queue.enqueue(text: "1", target: target, keepOnClipboard: false)
        await fulfillment(of: [firstStarted], timeout: 1)

        async let second = queue.enqueue(text: "2", target: target, keepOnClipboard: false)
        async let third = queue.enqueue(text: "3", target: target, keepOnClipboard: false)

        await fulfillment(of: [laterPasteStartedEarly], timeout: 0.2)
        await gate.open()

        let results = await [first, second, third]
        let startOrder = await recorder.startOrder
        let finishOrder = await recorder.finishOrder

        XCTAssertEqual(results, [.asyncQueued, .asyncQueued, .asyncQueued])
        XCTAssertEqual(startOrder.first, 1)
        XCTAssertEqual(Set(startOrder), Set([1, 2, 3]))
        XCTAssertEqual(finishOrder, startOrder)
    }

    func testInvalidTargetSkips() async {
        var called = false

        let queue = PasteQueue { _, _, _ in
            called = true
            return .asyncQueued
        }

        let invalidTarget = PasteTarget(windowElement: nil, windowID: nil, pid: 0, appName: "")
        let result = await queue.enqueue(text: "skip me", target: invalidTarget, keepOnClipboard: false)

        XCTAssertFalse(called)
        XCTAssertNil(result)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private actor PasteRecorder {
    private(set) var startOrder: [Int] = []
    private(set) var finishOrder: [Int] = []

    func recordStart(_ index: Int) {
        startOrder.append(index)
    }

    func recordFinish(_ index: Int) {
        finishOrder.append(index)
    }
}
