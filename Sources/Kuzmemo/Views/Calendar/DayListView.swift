import AppKit
import KuzmemoCore
import SwiftUI

/// The right side of the window for a selected day: its title, the entries (overdue ones above, on today), and the
/// quick-add field.
struct DayListView: View {
    let env: AppEnvironment
    @State private var quickText = ""
    @FocusState private var quickFocused: Bool

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !calendar.overdueEntries.isEmpty {
                        sectionTitle("Просрочено", tint: .red)
                        ForEach(calendar.overdueEntries) { EntryRow(entry: $0, env: env, showsDate: true) }
                        if !calendar.dayEntries.isEmpty { sectionTitle("Сегодня", tint: .secondary) }
                    }
                    if calendar.dayEntries.isEmpty && calendar.overdueEntries.isEmpty {
                        empty
                    } else {
                        ForEach(calendar.dayEntries) { EntryRow(entry: $0, env: env) }
                    }
                }
                .padding(.vertical, 6)
            }
            Divider()
            quickAdd
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: RussianFormat.dayTitle(calendar.selectedDate)).font(.title2.weight(.semibold))
                Text(verbatim: subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { env.newItem(on: calendar.selectedDate) } label: { Label("Новая запись", systemImage: "plus") }
                .help("Новая запись (⌘N)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        let relative = RussianFormat.relativeDay(calendar.selectedDate, today: calendar.today)
        let count = RussianFormat.entryCount(calendar.dayEntries.count)
        switch calendar.today.days(until: calendar.selectedDate) {
        case 0 ... 6 where calendar.selectedDate >= calendar.today && relative != RussianFormat.date(calendar.selectedDate):
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
            Text("На этот день ничего нет").foregroundStyle(.secondary)
            Text("Скажите «напомни…» или добавьте запись ниже").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
            TextField("Добавить запись: «завтра в 11 созвон с Figma»", text: $quickText)
                .textFieldStyle(.plain)
                .focused($quickFocused)
                .onSubmit(submit)
                .disabled(env.status == .thinking)
            if env.status == .thinking { ProgressView().controlSize(.small) }
            Text("⏎ — Claude · ⌥⏎ — как есть").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func submit() {
        let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        quickText = ""
        if NSEvent.modifierFlags.contains(.option) {
            env.act { try await calendar.quickAdd(text) }
        } else {
            Task { await env.submit(text: text) }
        }
    }
}
