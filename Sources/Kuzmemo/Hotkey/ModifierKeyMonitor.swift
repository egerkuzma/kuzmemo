import CoreGraphics
import Foundation

/// Watches one modifier key (Fn by default) through a listen-only event tap on the main run loop. It needs
/// the Input Monitoring permission. Events are reported with monotonic timestamps so `HotkeyPolicy` can tell a
/// tap from a hold; other keys pressed while the trigger is down are reported so a chord (Fn+arrow) can be
/// told apart from a command. Nothing here consumes or alters events.
///
/// Event timestamps are nanoseconds on the same uptime clock as `ProcessInfo.systemUptime` (checked on Apple
/// Silicon, where mach ticks are not nanoseconds), so a synthesised event can use the latter.
nonisolated final class ModifierKeyMonitor: @unchecked Sendable {
    struct Key: Sendable {
        var keyCode: Int
        /// Whether the trigger is down, given the event flags after the change.
        var isDown: @Sendable (CGEventFlags) -> Bool

        static let fn = Key(keyCode: 63) { $0.contains(.maskSecondaryFn) }
        static let rightOption = Key(keyCode: 61) { $0.rawValue & 0x40 != 0 }
        static let rightCommand = Key(keyCode: 54) { $0.rawValue & 0x10 != 0 }
        static let rightControl = Key(keyCode: 62) { $0.rawValue & 0x2000 != 0 }
    }

    struct Handlers: @unchecked Sendable {
        var down: @Sendable (TimeInterval) -> Void
        var up: @Sendable (TimeInterval) -> Void
        var otherKey: @Sendable (TimeInterval) -> Void
        /// Esc was pressed (whether or not the trigger is down). Listen-only: the app in front still gets it.
        var escape: @Sendable () -> Void = {}
    }

    private let key: Key
    private let handlers: Handlers
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false

    init(key: Key = .fn, handlers: Handlers) {
        self.key = key
        self.handlers = handlers
    }

    /// The tap's callback holds this object without owning it: a tap that outlived it would call into freed memory.
    deinit { stop() }

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Creates the tap. Returns false when Input Monitoring has not been granted.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return isActive }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon { Unmanaged<ModifierKeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap) // the documented way to remove a tap: no callback can come after this
        }
        source = nil
        tap = nil
        triggerDown = false
    }

    /// Re-enables a tap the system switched off (timeout, wake from sleep). Returns whether it is running.
    @discardableResult
    func revive() -> Bool {
        guard let tap else { return start() }
        if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let time = Double(event.timestamp) / 1_000_000_000
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if triggerDown { triggerDown = false; handlers.up(time) }
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { handlers.escape() }
            if triggerDown { handlers.otherKey(time) }
        case .flagsChanged:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if code == key.keyCode {
                let down = key.isDown(event.flags)
                if down, !triggerDown { triggerDown = true; handlers.down(time) }
                else if !down, triggerDown { triggerDown = false; handlers.up(time) }
            } else if triggerDown {
                handlers.otherKey(time) // another modifier joined: Fn+Shift etc.
            }
        default:
            break
        }
    }
}
