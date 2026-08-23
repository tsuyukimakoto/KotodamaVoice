import Foundation
import Testing
@testable import KotodamaVoice

@Test @MainActor
func sameModelOperationsRunInFIFOOrder() async throws {
    let gate = ModelOperationGate()
    let firstMayFinish = AsyncSignal()
    var events: [String] = []

    let first = Task { @MainActor in
        try await gate.withOperation(for: "model-a") {
            events.append("first-start")
            await firstMayFinish.wait()
            events.append("first-end")
        }
    }
    await Task.yield()
    let second = Task { @MainActor in
        try await gate.withOperation(for: "model-a") {
            events.append("second")
        }
    }
    await Task.yield()

    #expect(events == ["first-start"])
    await firstMayFinish.signal()
    try await first.value
    try await second.value
    #expect(events == ["first-start", "first-end", "second"])
}

@Test @MainActor
func differentModelOperationsDoNotBlockEachOther() async throws {
    let gate = ModelOperationGate()
    let firstMayFinish = AsyncSignal()
    var events: [String] = []

    let first = Task { @MainActor in
        try await gate.withOperation(for: "model-a") {
            events.append("a-start")
            await firstMayFinish.wait()
            events.append("a-end")
        }
    }
    await Task.yield()
    let second = Task { @MainActor in
        try await gate.withOperation(for: "model-b") {
            events.append("b")
        }
    }
    try await second.value

    #expect(events == ["a-start", "b"])
    await firstMayFinish.signal()
    try await first.value
}

private actor AsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signalled = false

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func signal() {
        signalled = true
        continuation?.resume()
        continuation = nil
    }
}
