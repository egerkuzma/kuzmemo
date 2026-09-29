import Foundation

extension AppliedChange {
    /// What to say aloud after a change was made, in plain spoken Russian: times spelled out and brand names swapped
    /// for the way the user wants them pronounced. For example
    /// "Записал: событие на завтра в одиннадцать часов — Созвон с Фигма."
    public func spokenConfirmation(today: LocalDate, glossary: [GlossaryTerm] = []) -> String {
        let title = Glossary.spokenForm(of: item.title, terms: glossary)
        switch kind {
        case .created:
            return "Записал: \(spokenKind) \(spokenWhen(date: item.date, time: item.time, today: today)) — \(title)."
                .replacingOccurrences(of: "  ", with: " ")
        case .updated:
            return "Изменил: \(title)."
        case .moved:
            let day = newDate.map { RussianFormat.onDay($0, today: today) } ?? "без даты"
            let time = (newTime ?? item.time).map { " \(AgendaSpeaker.spokenTime($0))" } ?? ""
            return "Перенёс: \(title) \(day)\(time)."
        case .completed:
            return "Отметил выполненным: \(title)."
        case .reopened:
            return "Вернул в работу: \(title)."
        case .deleted:
            return "Удалил: \(title)."
        case .skipped:
            return "Пропустил повторение: \(title)."
        }
    }

    private var spokenKind: String {
        switch item.kind {
        case .reminder: "напоминание"
        case .event: "событие"
        case .task: "задачу"
        case .note: "заметку"
        }
    }

    private func spokenWhen(date: LocalDate?, time: LocalTime?, today: LocalDate) -> String {
        guard let date else { return "без даты" }
        var text = RussianFormat.onDay(date, today: today)
        if let time { text += " " + AgendaSpeaker.spokenTime(time) }
        if item.recurrence != nil, let rule = item.recurrence { text += ", " + RussianFormat.recurrence(rule) }
        return text
    }
}
