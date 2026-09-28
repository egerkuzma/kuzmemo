import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// The recording chord. It is a Carbon hot key, so it needs no permissions and works when the Fn key cannot
    /// be watched (no Input Monitoring, Secure Input). The person can record another one in settings.
    static let recordVoice = KeyboardShortcuts.Name("recordVoice", initial: .init(.m, modifiers: [.control, .option]))
}
