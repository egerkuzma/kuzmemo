import KuzmemoCore
import SwiftUI

/// The editor sheet for a new or existing entry, including how it repeats. Editing a repeating item edits the whole
/// series.
struct ItemEditorView: View {
    let request: AppEnvironment.EditorRequest
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ItemDraft
    @State private var hasDate: Bool
    @State private var dateValue: Date
    @State private var hasTime: Bool
    @State private var timeValue: Date
    @State private var form: RecurrenceForm
    @State private var untilValue: Date
    @State private var countValue: Int
    @State private var problem: String?
    @State private var sourceText: String?
    @FocusState private var titleFocused: Bool

    init(request: AppEnvironment.EditorRequest, env: AppEnvironment) {
        self.request = request
        self.env = env
        let start: ItemDraft
        switch request {
        case let .new(draft): start = draft
        case let .edit(item): start = ItemDraft(item)
        }
        _draft = State(initialValue: start)
        _hasDate = State(initialValue: start.date != nil)
        _dateValue = State(initialValue: DateBridge.date(start.date ?? env.calendar.selectedDate))
        _hasTime = State(initialValue: start.time != nil)
        _timeValue = State(initialValue: DateBridge.date(start.time ?? LocalTime(hour: 9, minute: 0)!))
        let form = RecurrenceForm(start.recurrence)
        _form = State(initialValue: form)
        let base = DateBridge.date(start.date ?? env.calendar.selectedDate)
        if case let .until(date) = form.end { _untilValue = State(initialValue: DateBridge.date(date)) } else {
            _untilValue = State(initialValue: base.addingTimeInterval(86_400 * 90))
        }
        if case let .count(count) = form.end { _countValue = State(initialValue: count) } else { _countValue = State(initialValue: 10) }
    }

    private var isNew: Bool { if case .new = request { true } else { false } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("", text: $draft.title, prompt: Text("Название"), axis: .vertical)
                        .labelsHidden()
                        .font(.title3)
                        .lineLimit(1 ... 3)
                        .focused($titleFocused)
                    Picker("Тип", selection: $draft.kind) {
                        ForEach([ItemKind.reminder, .event, .task, .note], id: \.self) { Text(verbatim: $0.russianName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    LabeledContent {
                        if hasDate {
                            DatePicker("", selection: $dateValue, displayedComponents: .date).labelsHidden()
                        } else {
                            Text("Во «Входящих»").foregroundStyle(.secondary)
                        }
                    } label: {
                        Toggle("Дата", isOn: $hasDate.animation())
                    }
                    if hasDate {
                        LabeledContent {
                            if hasTime {
                                DatePicker("", selection: $timeValue, displayedComponents: .hourAndMinute).labelsHidden()
                            } else {
                                Text("Весь день").foregroundStyle(.secondary)
                            }
                        } label: {
                            Toggle("Время", isOn: $hasTime.animation())
                        }
                        if hasTime {
                            if draft.kind == .event {
                                Stepper(value: durationBinding, in: 0 ... 1440, step: 15) {
                                    Text(verbatim: "Длительность: \(durationText)")
                                }
                            }
                            Picker("Напомнить заранее", selection: $draft.remindLeadMin) {
                                ForEach(Self.leadOptions(including: draft.remindLeadMin), id: \.minutes) { Text(verbatim: $0.title).tag($0.minutes) }
                            }
                            Hint("Сроки уведомлений вообще выбираются в настройках. Здесь можно добавить ещё один ранний сигнал для этой записи.")
                        }
                    }
                }
                if hasDate { repeatSection }
                Section("Подробности") {
                    TextEditor(text: $draft.details)
                        .font(.body)
                        .frame(minHeight: 50, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                }
                if let sourceText {
                    Section {
                        Label { Text(verbatim: "Из реплики: «\(sourceText)»").font(.callout) } icon: { Image(systemName: "mic.fill") }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .environment(\.locale, DateBridge.russian)
        .task {
            titleFocused = isNew
            if case let .edit(item) = request, let memoID = item.memoID {
                sourceText = try? await env.store.memo(id: memoID)?.transcriptRaw
            }
        }
    }

    // MARK: Repeat

    @ViewBuilder private var repeatSection: some View {
        Section("Повтор") {
            Picker("Повторять", selection: $form.repeatKind.animation()) {
                ForEach(RecurrenceForm.Repeat.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            if form.repeatKind != .none {
                Stepper(value: $form.interval, in: 1 ... 99) {
                    Text(verbatim: "Интервал: \(form.intervalText)")
                }
                if form.repeatKind == .weekly {
                    HStack(spacing: 4) {
                        ForEach(Weekday.allCases, id: \.self) { day in
                            WeekdayChip(day: day, isOn: weekdayBinding(day))
                        }
                    }
                    Text("Если ничего не выбрано, повторяется в день недели даты начала").font(.caption).foregroundStyle(.secondary)
                }
                if form.repeatKind == .monthly {
                    Toggle("В день месяца как у даты начала", isOn: Binding(
                        get: { form.monthday == nil }, set: { form.monthday = $0 ? nil : DateBridge.localDate(dateValue).day }
                    ))
                    if form.monthday != nil {
                        Stepper(value: Binding(get: { form.monthday ?? 1 }, set: { form.monthday = $0 }), in: 1 ... 31) {
                            Text(verbatim: "Число месяца: \(form.monthday ?? 1)")
                        }
                    }
                }
                Picker("Окончание", selection: endKindBinding) {
                    Text("Никогда").tag(EndKind.never)
                    Text("В указанный день").tag(EndKind.until)
                    Text("После числа повторений").tag(EndKind.count)
                }
                if endKind == .until { DatePicker("До", selection: $untilValue, displayedComponents: .date) }
                if endKind == .count {
                    Stepper(value: $countValue, in: 1 ... 1000) { Text(verbatim: "Повторений: \(countValue)") }
                }
                if let rule = currentRule {
                    Label { Text(verbatim: RussianFormat.recurrenceDetailed(rule)) } icon: { Image(systemName: "repeat") }
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private enum EndKind { case never, until, count }

    private var endKind: EndKind {
        switch form.end {
        case .never: .never
        case .until: .until
        case .count: .count
        }
    }

    private var endKindBinding: Binding<EndKind> {
        Binding(get: { endKind }, set: { kind in
            switch kind {
            case .never: form.end = .never
            case .until: form.end = .until(DateBridge.localDate(untilValue))
            case .count: form.end = .count(countValue)
            }
        })
    }

    private func weekdayBinding(_ day: Weekday) -> Binding<Bool> {
        Binding(
            get: { form.weekdays.contains(day) },
            set: { if $0 { form.weekdays.insert(day) } else { form.weekdays.remove(day) } }
        )
    }

    /// The form with the picker values applied to its end condition.
    private var currentForm: RecurrenceForm {
        var current = form
        switch endKind {
        case .never: current.end = .never
        case .until: current.end = .until(DateBridge.localDate(untilValue))
        case .count: current.end = .count(countValue)
        }
        return current
    }

    private var currentRule: Recurrence? { currentForm.rule(startingOn: hasDate ? DateBridge.localDate(dateValue) : nil) }

    // MARK: Duration and reminders

    private var durationBinding: Binding<Int> {
        Binding(get: { draft.durationMin ?? 0 }, set: { draft.durationMin = $0 > 0 ? $0 : nil })
    }

    private var durationText: String {
        let minutes = draft.durationMin ?? 0
        if minutes == 0 { return "не указана" }
        let hours = minutes / 60
        let rest = minutes % 60
        return [hours > 0 ? "\(hours) ч" : nil, rest > 0 ? "\(rest) мин" : nil].compactMap { $0 }.joined(separator: " ")
    }

    private static let leads: [(minutes: Int, title: String)] = [
        (0, "Как в настройках"), (5, "За 5 минут"), (10, "За 10 минут"), (15, "За 15 минут"),
        (30, "За 30 минут"), (60, "За 1 час"), (1440, "За 1 день"),
    ]

    /// The choices, plus the entry's own value when it is not one of them (an older or imported entry keeps it).
    private static func leadOptions(including current: Int) -> [(minutes: Int, title: String)] {
        guard current > 0, !leads.contains(where: { $0.minutes == current }) else { return leads }
        return (leads + [(current, RussianFormat.leadBefore(current).capitalizedFirst)]).sorted { $0.minutes < $1.minutes }
    }

    // MARK: Footer and saving

    private var footer: some View {
        VStack(spacing: 8) {
            if let problem {
                Text(verbatim: problem).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if case let .edit(item) = request {
                    Button(item.recurrence == nil ? "Удалить" : "Удалить серию", role: .destructive) {
                        env.act { try await env.calendar.delete(item) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Добавить" : "Сохранить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() {
        var out = draft
        out.date = hasDate ? DateBridge.localDate(dateValue) : nil
        out.time = hasDate && hasTime ? DateBridge.localTime(timeValue) : nil
        if !(hasDate && hasTime) { out.remindLeadMin = 0 }
        if out.kind != .event || out.time == nil { out.durationMin = nil }
        out.recurrence = hasDate ? currentRule : nil
        do { _ = try out.validated() } catch {
            problem = AppEnvironment.describe(error)
            return
        }
        switch request {
        case .new: env.act { try await env.calendar.create(out) }
        case let .edit(item): env.act { try await env.calendar.save(out, as: item.id) }
        }
        dismiss()
    }
}

/// A weekday toggle drawn explicitly, so that it is clear whether it is on whatever state the window is in.
private struct WeekdayChip: View {
    let day: Weekday
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(verbatim: RussianFormat.weekdayShortName(day))
                .font(.callout.weight(isOn ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
