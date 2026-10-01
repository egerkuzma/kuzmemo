import Foundation
import KuzmemoCore

/// The app's clock. Normally the system time; the dev control channel can pin it to a wall-clock reading
/// (`POST /clock`) so end-to-end runs are reproducible.
nonisolated final class AdjustableNow: NowProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var pinned: Date?
    private let zone: TimeZone

    /// The zone follows the system setting while the app runs (a Mac that flies from Moscow to Lisbon): `.current` is a
    /// snapshot taken at launch, and alerts, "today" and the anchor of every phrase would stay in the old zone.
    init(timeZone: TimeZone = .autoupdatingCurrent) { zone = timeZone }

    var timeZone: TimeZone { zone }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return pinned ?? Date()
    }

    /// Pins to a local reading like "2026-09-28 14:30"; `nil` returns to the system clock. Returns false on bad input.
    @discardableResult
    func pin(local: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let local else { pinned = nil; return true }
        guard let fixed = FixedNow(local: local, in: zone) else { return false }
        pinned = fixed.now()
        return true
    }

    var isPinned: Bool {
        lock.lock(); defer { lock.unlock() }
        return pinned != nil
    }
}
