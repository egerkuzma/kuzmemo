import Foundation

extension AppliedChange {
    /// What to say aloud after a change was made, in plain spoken language: times said the way a voice says them and
    /// brand names swapped for the way the person wants them pronounced. For example
    /// "Saved: an event for tomorrow at 11 AM — Team sync."
    public func spokenConfirmation(today: LocalDate, glossary: [GlossaryTerm] = []) -> String {
        let title = Glossary.spokenForm(of: item.title, terms: glossary)
        switch kind {
        case .created:
            return tr("Saved: %1$@ %2$@ — %3$@.", spokenKind, spokenWhen(date: item.date, time: item.time, today: today), title)
                .replacingOccurrences(of: "  ", with: " ")
        case .updated:
            return tr("Changed: %1$@.", title)
        case .moved:
            let day = newDate.map { Wording.onDay($0, today: today) } ?? tr("with no date")
            let time = (newTime ?? item.time).map { " \(AgendaSpeaker.spokenTime($0))" } ?? ""
            return tr("Moved: %1$@ %2$@%3$@.", title, day, time)
        case .completed:
            return tr("Marked as done: %1$@.", title)
        case .reopened:
            return tr("Reopened: %1$@.", title)
        case .deleted:
            return tr("Deleted: %1$@.", title)
        case .skipped:
            return tr("Skipped the occurrence: %1$@.", title)
        }
    }

    /// The kind of entry as the object of "saved": "a reminder" in English, "напоминание" in Russian.
    private var spokenKind: String {
        switch item.kind {
        case .reminder: tr("a reminder")
        case .event: tr("an event")
        case .task: tr("a task")
        case .note: tr("a note")
        }
    }

    private func spokenWhen(date: LocalDate?, time: LocalTime?, today: LocalDate) -> String {
        guard let date else { return tr("with no date") }
        var text = Wording.onDay(date, today: today)
        if let time { text += " " + AgendaSpeaker.spokenTime(time) }
        if let rule = item.recurrence { text += ", " + Wording.recurrence(rule) }
        return text
    }
}
