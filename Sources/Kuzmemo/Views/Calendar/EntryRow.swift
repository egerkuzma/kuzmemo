import KuzmemoCore
import SwiftUI

/// One entry of a day: a done checkbox, the time, what it is, and quick actions in a context menu.
struct EntryRow: View {
    let entry: AgendaEntry
    let env: AppEnvironment
    /// Shown for entries from another day (overdue) instead of the time.
    var showsDate = false
    var isSelected = false
    /// A click on the row (the day list uses it for keyboard control).
    var onSelect: () -> Void = {}
    @State private var hovering = false
    @State private var moving = false
    @State private var moveTarget = Date()

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        HStack(spacing: 10) {
            Button { env.act { try await calendar.toggleDone(entry) } } label: {
                Image(systemName: entry.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isDone ? tr("Reopen") : tr("Mark as done"))

            Text(verbatim: whenText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)

            Image(systemName: symbol).font(.callout).foregroundStyle(.secondary).frame(width: 18)
                .accessibilityLabel(entry.item.kind.displayName)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: entry.item.title)
                    .strikethrough(entry.isDone)
                    .foregroundStyle(entry.isDone ? .secondary : .primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            badges
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { env.editorRequest = .edit(entry.item) }
        .onTapGesture { onSelect() }
        .contextMenu { menu }
        .popover(isPresented: $moving, arrowEdge: .trailing) { movePicker }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: tr("Edit")) { env.editorRequest = .edit(entry.item) }
    }

    // MARK: Pieces

    private var whenText: String {
        if entry.item.date == nil { return tr("no date") }
        if showsDate { return Wording.date(entry.date) }
        return entry.time.map { "\($0)" } ?? tr("all day")
    }

    private var symbol: String {
        switch entry.item.kind {
        case .reminder: "bell"
        case .event: "calendar"
        case .task: "checklist"
        case .note: "note.text"
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let rule = entry.item.recurrence { parts.append(Wording.recurrence(rule).capitalizedFirst) }
        if entry.wasMoved { parts.append(tr("moved")) }
        if showsDate, let time = entry.time { parts.append("\(time)") }
        if let details = entry.item.details, let line = details.split(whereSeparator: \.isNewline).first {
            parts.append(String(line.prefix(80)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 6) {
            if entry.item.approximate {
                Text(verbatim: "≈").font(.callout).foregroundStyle(.secondary).help(tr("Approximate date"))
            }
            if entry.isRecurring {
                Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary).accessibilityLabel(tr("Repeats"))
            }
            if entry.item.source == .voice {
                Image(systemName: "mic.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel(tr("Voice entry"))
            }
        }
    }

    @ViewBuilder private var menu: some View {
        Button(tr("Edit…")) { env.editorRequest = .edit(entry.item) }
        Button(entry.isDone ? tr("Reopen") : tr("Mark done")) { env.act { try await calendar.toggleDone(entry) } }
        Divider()
        Button(tr("Move to tomorrow")) { env.act { try await calendar.moveToTomorrow(entry) } }
        Button(tr("Move to date…")) {
            moveTarget = DateBridge.date(entry.date)
            moving = true
        }
        if entry.isRecurring {
            Button(tr("Skip this occurrence")) { env.act { try await calendar.skip(entry) } }
            Divider()
            Button(tr("Delete the whole series"), role: .destructive) { env.act { try await calendar.delete(entry.item) } }
        } else {
            Divider()
            Button(tr("Delete"), role: .destructive) { env.act { try await calendar.delete(entry.item) } }
        }
    }

    private var movePicker: some View {
        VStack(spacing: 10) {
            DatePicker("", selection: $moveTarget, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.locale, DateBridge.locale)
            HStack {
                Button(tr("Cancel")) { moving = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(tr("Move")) {
                    moving = false
                    let target = DateBridge.localDate(moveTarget)
                    env.act { try await calendar.move(entry, to: target) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
