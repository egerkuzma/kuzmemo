import AppKit
import KuzmemoCore
import SwiftUI

/// The right side of the window for a selected day: its title, the entries (overdue ones above, on today), and the
/// quick-add field.
struct DayListView: View {
    let env: AppEnvironment
    @State private var quickText = ""
    @State private var selection: String?
    @FocusState private var quickFocused: Bool
    @FocusState private var listFocused: Bool

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !calendar.overdueEntries.isEmpty {
                        sectionTitle(tr("Overdue"), tint: .red)
                        ForEach(calendar.overdueEntries) { row($0, showsDate: true) }
                        if !calendar.dayEntries.isEmpty { sectionTitle(tr("Today"), tint: .secondary) }
                    }
                    if calendar.dayEntries.isEmpty && calendar.overdueEntries.isEmpty {
                        empty
                    } else {
                        ForEach(calendar.dayEntries) { row($0) }
                    }
                }
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in handle(press) }
            .onChange(of: calendar.selectedDate) { selection = nil }
            Divider()
            quickAdd
        }
    }

    private func row(_ entry: AgendaEntry, showsDate: Bool = false) -> some View {
        EntryRow(entry: entry, env: env, showsDate: showsDate, isSelected: selection == entry.id) {
            selection = entry.id
            listFocused = true
        }
    }

    /// Everything on the list in the order it is shown.
    private var visibleEntries: [AgendaEntry] { calendar.overdueEntries + calendar.dayEntries }

    private var selectedEntry: AgendaEntry? { visibleEntries.first { $0.id == selection } }

    /// Keys for the selected entry: arrows move, space marks done, return edits, delete removes.
    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.isEmpty else { return .ignored }
        let entries = visibleEntries
        switch press.key {
        case .upArrow, .downArrow:
            guard !entries.isEmpty else { return .ignored }
            let step = press.key == .downArrow ? 1 : -1
            let current = entries.firstIndex { $0.id == selection }
            let next = current.map { min(max($0 + step, 0), entries.count - 1) } ?? (step > 0 ? 0 : entries.count - 1)
            selection = entries[next].id
            return .handled
        case .space:
            guard let entry = selectedEntry else { return .ignored }
            env.act { try await calendar.toggleDone(entry) }
            return .handled
        case .return:
            guard let entry = selectedEntry else { return .ignored }
            env.editorRequest = .edit(entry.item)
            return .handled
        case .delete, .deleteForward:
            guard let entry = selectedEntry else { return .ignored }
            let index = entries.firstIndex { $0.id == entry.id } ?? 0
            selection = entries.indices.contains(index + 1) ? entries[index + 1].id : (index > 0 ? entries[index - 1].id : nil)
            env.act { try await calendar.delete(entry.item) }
            return .handled
        default:
            return .ignored
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Wording.dayTitle(calendar.selectedDate)).font(.title2.weight(.semibold))
                Text(verbatim: subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { env.newItem(on: calendar.selectedDate) } label: { Label(tr("New entry"), systemImage: "plus") }
                .help(tr("New entry (⌘N)"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let relative = Wording.relativeDay(calendar.selectedDate, today: calendar.today)
        let count = Wording.entryCount(calendar.dayEntries.count)
        switch calendar.today.days(until: calendar.selectedDate) {
        case 0 ... 6 where calendar.selectedDate >= calendar.today && relative != Wording.date(calendar.selectedDate):
            return "\(relative.capitalizedFirst) · \(count)"
        default:
            return count.capitalizedFirst
        }
    }

    private func sectionTitle(_ text: String, tint: Color) -> some View {
        Text(verbatim: text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar").font(.largeTitle).foregroundStyle(.tertiary)
            Text(tr("Nothing on this day")).foregroundStyle(.secondary)
            Text(tr("Say “remind me…” or add an entry below")).font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
            TextField(tr("Add an entry: “team sync tomorrow at 11”"), text: $quickText)
                .textFieldStyle(.plain)
                .focused($quickFocused)
                .onSubmit { submit(asTyped: false) }
                .onKeyPress(.return, phases: .down) { press in
                    // Option-Return does not reach onSubmit in a single-line field, so it is caught here.
                    guard press.modifiers.contains(.option) else { return .ignored }
                    submit(asTyped: true)
                    return .handled
                }
                .disabled(env.status == .thinking)
            if env.status == .thinking { ProgressView().controlSize(.small) }
            Text(tr("⏎ — ask Claude · ⌥⏎ — add as is")).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func submit(asTyped: Bool) {
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickText = ""
        if asTyped {
            env.act { try await calendar.quickAdd(text) }
        } else {
            Task { await env.submit(text: text) }
        }
    }
}
