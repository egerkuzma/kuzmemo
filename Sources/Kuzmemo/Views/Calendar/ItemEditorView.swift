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
    /// The save is under way: a second press must not make a second entry.
    @State private var saving = false
    /// What the editor knows about the entry's revision. The entry and its revision are read together when the sheet opens
    /// (`Store.itemSnapshot`); the save checks the revision, so that a change that reached the entry meanwhile (a voice command, a
    /// notification's Done, an undo) is not quietly put back. Until the read has worked, Save is off: a copy whose revision is
    /// unknown is not safe to write. Only after a refused save does the person's next Save go through without the check.
    private enum Revision: Equatable {
        case loading
        case loaded(Int)
        /// The entry could not be read (or is gone): nothing is saved until a read works.
        case failed
        /// The person was told the entry changed meanwhile and pressed Save again: their decision.
        case overwriteApproved
    }

    @State private var revision = Revision.loading
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
        let fields = Self.fields(for: start, selectedDate: env.calendar.selectedDate)
        _draft = State(initialValue: start)
        _hasDate = State(initialValue: fields.hasDate)
        _dateValue = State(initialValue: fields.dateValue)
        _hasTime = State(initialValue: fields.hasTime)
        _timeValue = State(initialValue: fields.timeValue)
        _form = State(initialValue: fields.form)
        _untilValue = State(initialValue: fields.untilValue)
        _countValue = State(initialValue: fields.countValue)
    }

    private var isNew: Bool { if case .new = request { true } else { false } }

    /// The form's controls for a draft.
    private struct Fields {
        var hasDate: Bool, dateValue: Date, hasTime: Bool, timeValue: Date, form: RecurrenceForm, untilValue: Date, countValue: Int
    }

    private static func fields(for start: ItemDraft, selectedDate: LocalDate) -> Fields {
        let form = RecurrenceForm(start.recurrence)
        let base = DateBridge.date(start.date ?? selectedDate)
        var until = base.addingTimeInterval(86_400 * 90)
        if case let .until(date) = form.end { until = DateBridge.date(date) }
        var count = 10
        if case let .count(n) = form.end { count = n }
        return Fields(
            hasDate: start.date != nil, dateValue: base, hasTime: start.time != nil,
            timeValue: DateBridge.date(start.time ?? LocalTime(hour: 9, minute: 0)!), form: form, untilValue: until, countValue: count
        )
    }

    /// Shows `start` in every control (what `init` does, for an entry read after the sheet opened).
    private func show(_ start: ItemDraft) {
        let fields = Self.fields(for: start, selectedDate: env.calendar.selectedDate)
        draft = start
        hasDate = fields.hasDate; dateValue = fields.dateValue; hasTime = fields.hasTime; timeValue = fields.timeValue
        form = fields.form; untilValue = fields.untilValue; countValue = fields.countValue
    }

    /// Reads the entry and its revision together. The `Item` the sheet was opened with is a copy from the window, which may be
    /// older than the entry; the draft is replaced by the fresh copy while the person has not touched it. If they have, and
    /// the entry differs, they are told, and the next Save is their decision, as after any refused save.
    private func loadRevision(of item: Item) async {
        revision = .loading
        guard let snapshot = try? await env.store.itemSnapshot(id: item.id) else {
            revision = .failed
            problem = AppEnvironment.describe(StoreError.itemNotFound(item.id))
            return
        }
        // "Untouched" is judged on the whole form (the date, time and repeat controls live beside the draft), the same way a
        // save reads it: a date the person already moved is not put back by the fresh copy.
        let shown = ItemDraft(item)
        let untouched = normalized(composed()) == normalized(shown)
        if untouched {
            if ItemDraft(snapshot.item) != shown { show(ItemDraft(snapshot.item)) }
            revision = .loaded(snapshot.revision)
        } else if ItemDraft(snapshot.item) == shown {
            revision = .loaded(snapshot.revision) // what the person started from is what the entry is
        } else {
            problem = AppEnvironment.describe(StoreError.changedMeanwhile(item.id))
            revision = .overwriteApproved
        }
    }

    /// The draft as the controls have it: what a save writes.
    private func composed() -> ItemDraft {
        var out = draft
        out.date = hasDate ? DateBridge.localDate(dateValue) : nil
        out.time = hasDate && hasTime ? DateBridge.localTime(timeValue) : nil
        if !(hasDate && hasTime) { out.remindLeadMin = 0 }
        if out.kind != .event || out.time == nil { out.durationMin = nil }
        out.recurrence = hasDate ? currentRule : nil
        return out
    }

    /// Two drafts compare as the editor shows them (a rule is compared after the same normalisation a save applies).
    private func normalized(_ draft: ItemDraft) -> ItemDraft {
        var copy = draft
        copy.recurrence = draft.recurrence?.normalized(start: draft.date)
        if copy.date == nil { copy.time = nil; copy.recurrence = nil }
        if copy.time == nil { copy.remindLeadMin = 0 }
        if copy.kind != .event || copy.time == nil { copy.durationMin = nil }
        return copy
    }

    private var canSave: Bool {
        switch revision {
        case .loaded, .overwriteApproved: true
        case .loading, .failed: isNew
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("", text: $draft.title, prompt: Text(tr("Title")), axis: .vertical)
                        .labelsHidden()
                        .font(.title3)
                        .lineLimit(1 ... 3)
                        .focused($titleFocused)
                    Picker(tr("Type"), selection: $draft.kind) {
                        ForEach([ItemKind.reminder, .event, .task, .note], id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                Section {
                    LabeledContent {
                        if hasDate {
                            DatePicker("", selection: $dateValue, displayedComponents: .date).labelsHidden()
                        } else {
                            Text(tr("In the Inbox")).foregroundStyle(.secondary)
                        }
                    } label: {
                        Toggle(tr("Date"), isOn: $hasDate.animation())
                    }
                    if hasDate {
                        LabeledContent {
                            if hasTime {
                                DatePicker("", selection: $timeValue, displayedComponents: .hourAndMinute).labelsHidden()
                            } else {
                                Text(tr("All day")).foregroundStyle(.secondary)
                            }
                        } label: {
                            Toggle(tr("Time"), isOn: $hasTime.animation())
                        }
                        if hasTime {
                            if draft.kind == .event {
                                Stepper(value: durationBinding, in: 0 ... 1440, step: 15) {
                                    Text(verbatim: tr("Duration: %1$@", "\(durationText)"))
                                }
                            }
                            Picker(tr("Remind in advance"), selection: $draft.remindLeadMin) {
                                ForEach(Self.leadOptions(including: draft.remindLeadMin), id: \.minutes) { Text(verbatim: $0.title).tag($0.minutes) }
                            }
                            Hint(tr("Notification times are chosen in Settings. Here you can add one more early alert for this entry."))
                        }
                    }
                }
                if hasDate { repeatSection }
                Section(tr("Details")) {
                    TextEditor(text: $draft.details)
                        .font(.body)
                        .frame(minHeight: 50, maxHeight: 80)
                        .scrollContentBackground(.hidden)
                }
                if let sourceText {
                    Section {
                        Label { Text(verbatim: tr("From the phrase: “%1$@”", "\(sourceText)")).font(.callout) } icon: { Image(systemName: "mic.fill") }
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .environment(\.locale, DateBridge.locale)
        .task {
            titleFocused = isNew
            if case let .edit(item) = request {
                await loadRevision(of: item)
                if let memoID = item.memoID { sourceText = try? await env.store.memo(id: memoID)?.transcriptRaw }
            }
        }
    }

    // MARK: Repeat

    @ViewBuilder private var repeatSection: some View {
        Section(tr("Repeat")) {
            Picker(tr("Repeat rule"), selection: $form.repeatKind.animation()) {
                ForEach(RecurrenceForm.Repeat.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            if form.repeatKind != .none {
                Stepper(value: $form.interval, in: 1 ... 99) {
                    Text(verbatim: tr("Interval: %1$@", "\(form.intervalText)"))
                }
                if form.repeatKind == .weekly {
                    HStack(spacing: 4) {
                        ForEach(Weekday.allCases, id: \.self) { day in
                            WeekdayChip(day: day, isOn: weekdayBinding(day))
                        }
                    }
                    Text(tr("If none is selected, it repeats on the weekday of the start date")).font(.caption).foregroundStyle(.secondary)
                }
                if form.repeatKind == .monthly {
                    Toggle(tr("On the same day of the month as the start date"), isOn: Binding(
                        get: { form.monthday == nil }, set: { form.monthday = $0 ? nil : DateBridge.localDate(dateValue).day }
                    ))
                    if form.monthday != nil {
                        Stepper(value: Binding(get: { form.monthday ?? 1 }, set: { form.monthday = $0 }), in: 1 ... 31) {
                            Text(verbatim: tr("Day of month: %1$lld", numbers: form.monthday ?? 1))
                        }
                    }
                }
                Picker(tr("Ends"), selection: endKindBinding) {
                    Text(tr("Never")).tag(EndKind.never)
                    Text(tr("On a date")).tag(EndKind.until)
                    Text(tr("After a number of times")).tag(EndKind.count)
                }
                if endKind == .until { DatePicker(tr("Until"), selection: $untilValue, displayedComponents: .date) }
                if endKind == .count {
                    Stepper(value: $countValue, in: 1 ... 1000) { Text(verbatim: tr("Times: %1$lld", numbers: countValue)) }
                }
                if let rule = currentRule {
                    Label { Text(verbatim: Wording.recurrenceDetailed(rule)) } icon: { Image(systemName: "repeat") }
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
        if minutes == 0 { return tr("not set") }
        let hours = minutes / 60
        let rest = minutes % 60
        return [hours > 0 ? tr("%1$lld h", numbers: hours) : nil, rest > 0 ? tr("%1$lld min", numbers: rest) : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// Computed, not stored: the titles must follow the interface language when it changes.
    private static var leads: [(minutes: Int, title: String)] { [
        (0, tr("As in Settings")), (5, tr("5 minutes before")), (10, tr("10 minutes before")), (15, tr("15 minutes before")),
        (30, tr("30 minutes before")), (60, tr("1 hour before")), (1440, tr("1 day before")),
    ] }

    /// The choices, plus the entry's own value when it is not one of them (an older or imported entry keeps it).
    private static func leadOptions(including current: Int) -> [(minutes: Int, title: String)] {
        guard current > 0, !leads.contains(where: { $0.minutes == current }) else { return leads }
        return (leads + [(current, Wording.leadBefore(current).capitalizedFirst)]).sorted { $0.minutes < $1.minutes }
    }

    // MARK: Footer and saving

    private var footer: some View {
        VStack(spacing: 8) {
            if let problem {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: problem).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    if revision == .failed, case let .edit(item) = request {
                        Button(tr("Retry")) { Task { await loadRevision(of: item) } }
                    }
                }
            }
            HStack {
                if case let .edit(item) = request {
                    Button(item.recurrence == nil ? tr("Delete") : tr("Delete series"), role: .destructive) {
                        env.act { try await env.calendar.delete(item) }
                        dismiss()
                    }
                }
                Spacer()
                Button(tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? tr("Add") : tr("Save"), action: save).keyboardShortcut(.defaultAction).disabled(saving || !canSave)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func save() {
        let out = composed()
        do { _ = try out.validated() } catch {
            problem = AppEnvironment.describe(error)
            return
        }
        guard !saving, canSave else { return }
        saving = true
        problem = nil
        // The sheet closes when the entry is saved, not before: a failed save (a full disk, a locked file, an entry that was
        // deleted meanwhile) must not throw away what the person typed.
        Task { @MainActor in
            defer { saving = false }
            let failure: (any Error)?
            switch request {
            case .new: failure = await env.attempt { try await env.calendar.create(out) }
            case let .edit(item):
                var expected: Int?
                if case let .loaded(current) = revision { expected = current }
                failure = await env.attempt { try await env.calendar.save(out, as: item.id, expectingRevision: expected) }
            }
            if case StoreError.changedMeanwhile? = failure { revision = .overwriteApproved } // the next Save is the person's decision
            if let failure { problem = AppEnvironment.describe(failure) } else { dismiss() }
        }
    }
}

/// A weekday toggle drawn explicitly, so that it is clear whether it is on whatever state the window is in.
private struct WeekdayChip: View {
    let day: Weekday
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(verbatim: Wording.weekdayShortName(day))
                .font(.callout.weight(isOn ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
