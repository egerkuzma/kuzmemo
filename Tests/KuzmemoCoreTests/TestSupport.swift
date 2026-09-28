import Foundation
import Synchronization
@testable import KuzmemoCore

/// Lets a test hold a fake engine or provider in the middle of a call until it opens the gate.
actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Answers like `inner`, but only after the gate opens.
final class GatedProvider: LLMProvider, Sendable {
    let gate = Gate()
    private let inner: ScriptedProvider
    private let calls = Mutex(0)

    init(_ inner: ScriptedProvider) { self.inner = inner }

    var callCount: Int { calls.withLock { $0 } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        calls.withLock { $0 += 1 }
        await gate.wait()
        return try await inner.complete(request)
    }
}
