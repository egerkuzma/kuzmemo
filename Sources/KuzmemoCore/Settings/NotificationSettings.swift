import Foundation

/// A sound for an alert: one of the app's own chimes, a macOS system sound, or a file the person chose.
public struct AlertSound: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case none, chime, system, file }

    public var kind: Kind
    /// The chime id ("bell"), the system sound name ("Glass") or the path of the file.
    public var name: String

    public init(kind: Kind, name: String = "") {
        self.kind = kind
        self.name = name
    }

    public static let silent = AlertSound(kind: .none)
    public static func chime(_ id: String) -> AlertSound { AlertSound(kind: .chime, name: id) }
    public static func system(_ name: String) -> AlertSound { AlertSound(kind: .system, name: name) }
    public static func file(_ path: String) -> AlertSound { AlertSound(kind: .file, name: path) }
}

/// A stretch of the day in which alerts arrive without sound (it may run past midnight).
public struct QuietHours: Codable, Equatable, Sendable {
    public var enabled = false
    public var from = LocalTime(hour: 23, minute: 0)!
    public var to = LocalTime(hour: 8, minute: 0)!

    public init() {}

    public func contains(_ time: LocalTime) -> Bool {
        guard enabled else { return false }
        if from == to { return false }
        return from < to ? (time >= from && time < to) : (time >= from || time < to)
    }
}

/// When to be told about entries, and how.
public struct NotificationSettings: SettingsGroup {
    public static let storageKey = "settings.notifications"

    /// The minutes-before values a person can pick from ("0" is the moment itself).
    public static let leadChoices = [0, 1, 5, 10, 15, 30, 60, 1440]

    public var enabled = true
    /// For events (a meeting, a call at a time): how many minutes ahead to be told; 0 is the start itself.
    public var eventLeads = [5, 0]
    /// For reminders and tasks that have a time.
    public var reminderLeads = [0]
    /// Reminders and tasks that have a day but no time are announced at each of these times, while still open.
    public var allDayTimes = [LocalTime(hour: 9, minute: 0)!]
    /// Sound of an alert ahead of an event (like Zoom's "your meeting starts soon").
    public var headsUpSound = AlertSound.system("Tink")
    /// Sound at the time itself.
    public var atTimeSound = AlertSound.system("Hero")
    /// Sound of an announcement for something due "sometime today".
    public var allDaySound = AlertSound.system("Glass")
    /// Also say the title aloud with the system voice (when the app is running).
    public var speakTitle = false
    public var quietHours = QuietHours()
    /// The "remind me again in …" buttons on a notification, minutes.
    public var snoozeMinutes = [10, 60]
    /// How many days ahead alerts are scheduled with the system.
    public var horizonDays = 7

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, eventLeads, reminderLeads, allDayTimes, headsUpSound, atTimeSound, allDaySound
        case speakTitle, quietHours, snoozeMinutes, horizonDays
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        eventLeads = Self.leads(try c.decodeIfPresent([Int].self, forKey: .eventLeads)) ?? eventLeads
        reminderLeads = Self.leads(try c.decodeIfPresent([Int].self, forKey: .reminderLeads)) ?? reminderLeads
        if let times = try c.decodeIfPresent([LocalTime].self, forKey: .allDayTimes) {
            allDayTimes = Array(Set(times)).sorted().prefix(8).map { $0 }
        }
        headsUpSound = try c.decodeIfPresent(AlertSound.self, forKey: .headsUpSound) ?? headsUpSound
        atTimeSound = try c.decodeIfPresent(AlertSound.self, forKey: .atTimeSound) ?? atTimeSound
        allDaySound = try c.decodeIfPresent(AlertSound.self, forKey: .allDaySound) ?? allDaySound
        speakTitle = try c.decodeIfPresent(Bool.self, forKey: .speakTitle) ?? speakTitle
        quietHours = try c.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? quietHours
        snoozeMinutes = Array(Set((try c.decodeIfPresent([Int].self, forKey: .snoozeMinutes) ?? snoozeMinutes).filter { (1 ... 1440).contains($0) })).sorted().prefix(3).map { $0 }
        horizonDays = min(max(try c.decodeIfPresent(Int.self, forKey: .horizonDays) ?? horizonDays, 1), 30)
    }

    /// Only sensible, distinct lead times, latest first ("15, 5, 0"); an empty list is allowed (no alerts of that kind).
    static func leads(_ values: [Int]?) -> [Int]? {
        values.map { Array(Set($0.filter { (0 ... 10_080).contains($0) })).sorted(by: >) }
    }
}
