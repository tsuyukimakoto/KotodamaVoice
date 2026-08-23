import Foundation

@MainActor
final class ModelOperationGate {
    private var activeModelIDs = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withOperation<Value>(
        for modelID: String,
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        await acquire(modelID)
        defer { release(modelID) }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire(_ modelID: String) async {
        guard !activeModelIDs.insert(modelID).inserted else { return }
        await withCheckedContinuation { continuation in
            waiters[modelID, default: []].append(continuation)
        }
    }

    private func release(_ modelID: String) {
        guard var queued = waiters[modelID], !queued.isEmpty else {
            activeModelIDs.remove(modelID)
            waiters[modelID] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[modelID] = queued.isEmpty ? nil : queued
        next.resume()
    }
}
