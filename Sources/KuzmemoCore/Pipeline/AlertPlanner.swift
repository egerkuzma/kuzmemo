import Foundation

/// One notification the app wants the system to show.
public struct PlannedAlert: Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case headsUp, atTime, allDay }

    public var id: String
    public var itemID: String
    /// The original date of a repeating item's occurrence (the key of its overrides); `nil` for one-off items.
    public var occurrenceDate: LocalDate?
    /// The day the entry is on.
    public var entryDate: LocalDate
    public var kind: Kind
    public var leadMinutes: Int
    public var fireAt: Date
    public var title: String
    public var subtitle: String
    public var body: String
    public var sound: AlertSound
    /// Quiet hours: delivered, but without sound.
    public var silent: Bool
}

/// Works out which notifications to schedule from the calendar's entries. Pure: the same entries, settings and
/// moment give the same alerts, so it is tested without any notification system.
public enum AlertPlanner {
    /// Identifiers of alerts made here start with this; anything else pending with the system is not ours to touch.
    public static let idPrefix = "kz|"
    /// Identifiers of the alerts a person put off with a Snooze button. They are not planned here (a snooze is the person's own
    /// wish, and re-planning must not take it away), but they are the app's.
    public static let snoozePrefix = "kzs|"

    /// A moment that passed this recently is still worth delivering (the plan was made just after it).
    static let grace: TimeInterval = 30

    public static func plan(
        entries: [AgendaEntry], settings: NotificationSettings, now: Date, timeZone: TimeZone, limit: Int = 60
    ) -> [PlannedAlert] {
        guard settings.enabled else { return [] }
        var alerts: [PlannedAlert] = []
        for entry in entries where !entry.isDone && entry.item.kind != .note && entry.item.deletedAt == nil {
            if let time = entry.time {
                alerts += timedAlerts(for: entry, at: time, settings: settings, timeZone: timeZone)
            } else {
                alerts += allDayAlerts(for: entry, settings: settings, timeZone: timeZone)
            }
        }
        let earliest = now.addingTimeInterval(-grace)
        let upcoming = alerts.filter { $0.fireAt >= earliest }.sorted {
            $0.fireAt != $1.fireAt ? $0.fireAt < $1.fireAt : $0.id < $1.id
        }
        return Array(upcoming.prefix(limit))
    }

    // MARK: - Timed entries

    private static func timedAlerts(for entry: AgendaEntry, at time: LocalTime, settings: NotificationSettings, timeZone: TimeZone) -> [PlannedAlert] {
        var leads = entry.item.kind == .event ? settings.eventLeads : settings.reminderLeads
        if entry.item.remindLeadMin > 0, !leads.contains(entry.item.remindLeadMin) { leads.append(entry.item.remindLeadMin) }
        let start = LocalDateTime(date: entry.date, time: time)
        return leads.sorted(by: >).map { lead in
            let moment = start.adding(minutes: -lead)
            let kind: PlannedAlert.Kind = lead == 0 ? .atTime : .headsUp
            let body = "\(Wording.leadPhrase(lead)) · \(time)"
            return make(entry, kind: kind, lead: lead, at: moment, body: body, settings: settings, timeZone: timeZone)
        }
    }

    // MARK: - Entries with a day but no time

    private static func allDayAlerts(for entry: AgendaEntry, settings: NotificationSettings, timeZone: TimeZone) -> [PlannedAlert] {
        guard entry.item.kind != .event else { return [] } // an event without a time is a question for the person, not an alarm
        return settings.allDayTimes.map { time in
            make(entry, kind: .allDay, lead: 0, at: LocalDateTime(date: entry.date, time: time), body: tr("Today · all day"), settings: settings, timeZone: timeZone)
        }
    }

    // MARK: - Building one alert

    private static func make(
        _ entry: AgendaEntry, kind: PlannedAlert.Kind, lead: Int, at moment: LocalDateTime, body: String,
        settings: NotificationSettings, timeZone: TimeZone
    ) -> PlannedAlert {
        let sound: AlertSound = switch kind {
        case .headsUp: settings.headsUpSound
        case .atTime: settings.atTimeSound
        case .allDay: settings.allDaySound
        }
        let silent = settings.quietHours.contains(moment.time)
        let fireAt = moment.instant(in: timeZone)
        let subtitle = entry.item.kind.displayName
        let occurrence = entry.occurrenceDate.map { "\($0)" } ?? "-"
        let content = "\(entry.item.title)|\(subtitle)|\(body)|\(sound.kind.rawValue):\(sound.name)|\(silent)"
        let id = "\(idPrefix)\(entry.item.id)|\(occurrence)|\(kind.rawValue)|\(lead)|\(Int(fireAt.timeIntervalSince1970))|\(fingerprint(content))"
        return PlannedAlert(
            id: id, itemID: entry.item.id, occurrenceDate: entry.occurrenceDate, entryDate: entry.date, kind: kind,
            leadMinutes: lead, fireAt: fireAt, title: entry.item.title, subtitle: subtitle, body: body, sound: sound, silent: silent
        )
    }

    /// A short stable digest (FNV-1a) so that an alert whose text or sound changed gets a new identifier.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}

/// What has to change so that the system holds exactly the planned alerts. Snoozes are left alone while notifications are
/// on; with them switched off nothing of the app's may stay pending, snoozes included (a put-off alert would otherwise ring
/// after the person turned everything off).
public struct AlertDiff: Equatable, Sendable {
    public var toAdd: [PlannedAlert]
    public var toRemove: [String]

    public init(planned: [PlannedAlert], pendingIDs: Set<String>, enabled: Bool = true) {
        let ours = pendingIDs.filter { $0.hasPrefix(AlertPlanner.idPrefix) }
        let wanted = Set(planned.map(\.id))
        toAdd = planned.filter { !ours.contains($0.id) }
        let snoozes = enabled ? [] : pendingIDs.filter { $0.hasPrefix(AlertPlanner.snoozePrefix) }
        toRemove = ours.subtracting(wanted).union(snoozes).sorted()
    }
}
