import Foundation

/// Builds the dynamic user message: the moment, defaults, glossary, numbered entries and the transcript.
public struct PromptBuilder: Sendable {
    public var dayParts: DayPartDefaults

    public init(dayParts: DayPartDefaults = .standard) {
        self.dayParts = dayParts
    }

    public func userMessage(
        transcript: String, anchor: LocalDateTime, timeZone: TimeZone,
        glossary: [GlossaryTerm], context: ContextPlan, followUp: FollowUp? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("<now>\(nowText(anchor, timeZone))</now>")
        lines.append("<language>\(Localization.current == .russian ? "Russian" : "English")</language>")
        lines.append("<defaults>morning=\(dayParts.morning) day=\(dayParts.day) evening=\(dayParts.evening) night=\(dayParts.night); a reminder without a time fires at \(dayParts.defaultReminder)</defaults>")
        let glossaryLine = Glossary.promptLine(terms: glossary)
        if !glossaryLine.isEmpty { lines.append("<glossary>\(Self.clean(glossaryLine))</glossary>") }
        lines.append("<items>")
        for (index, entry) in context.entries.enumerated() {
            lines.append("[\(index + 1)] \(Self.describe(entry))")
        }
        lines.append("</items>")
        if let followUp {
            lines.append("<previous>\(Self.clean(followUp.previous))</previous>")
            lines.append("<question>\(Self.clean(followUp.question))</question>")
        }
        lines.append("<transcript>\(Self.clean(transcript))</transcript>")
        return lines.joined(separator: "\n")
    }

    func nowText(_ anchor: LocalDateTime, _ timeZone: TimeZone) -> String {
        let weekday = Self.englishWeekday[anchor.date.weekday.rawValue - 1]
        let offset = timeZone.secondsFromGMT(for: anchor.instant(in: timeZone))
        let sign = offset < 0 ? "-" : "+"
        let hours = abs(offset) / 3600
        let minutes = (abs(offset) % 3600) / 60
        let utc = "UTC\(sign)\(hours < 10 ? "0" : "")\(hours):\(minutes < 10 ? "0" : "")\(minutes)"
        return "\(weekday) \(anchor.date) \(anchor.time) (\(timeZone.identifier), \(utc))"
    }

    static let englishWeekday = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// `2026-10-01 15:00 event "Meeting with Dmitry"`, with repeat and done markers.
    static func describe(_ entry: AgendaEntry) -> String {
        let item = entry.item
        var parts: [String] = []
        if item.date == nil {
            parts.append("(no date)")
        } else {
            parts.append(entry.time.map { "\(entry.date) \($0)" } ?? "\(entry.date)")
        }
        parts.append(item.kind.rawValue)
        parts.append("\"\(clean(item.title))\"")
        if let details = item.details, !details.isEmpty {
            parts.append("— \(String(clean(details).prefix(80)))")
        }
        if let recurrence = item.recurrence { parts.append("(repeats \(summary(recurrence)))") }
        if entry.isDone { parts.append("(done)") }
        return parts.joined(separator: " ")
    }

    static func summary(_ recurrence: Recurrence) -> String {
        var text: String
        let every = recurrence.interval > 1 ? "every \(recurrence.interval) " : ""
        switch recurrence.freq {
        case .daily: text = recurrence.interval > 1 ? "\(every)days" : "daily"
        case .weekly: text = recurrence.interval > 1 ? "\(every)weeks" : "weekly"
        case .monthly: text = recurrence.interval > 1 ? "\(every)months" : "monthly"
        case .yearly: text = recurrence.interval > 1 ? "\(every)years" : "yearly"
        }
        if let days = recurrence.byWeekday, !days.isEmpty { text += " on " + days.sorted().map(\.code).joined(separator: ",") }
        if let day = recurrence.byMonthday { text += " on day \(day)" }
        return text
    }

    /// One line, no angle brackets: user text must not be able to close or open the prompt's tags.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "<", with: "‹")
            .replacingOccurrences(of: ">", with: "›")
            .trimmingCharacters(in: .whitespaces)
    }
}
