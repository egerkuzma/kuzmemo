import KuzmemoCore
import SwiftUI

/// Every repeating item, how it repeats and when it happens next.
struct RecurringView: View {
    let env: AppEnvironment

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Repeating")).font(.title2.weight(.semibold))
                Text(verbatim: Wording.entryCount(calendar.recurring.count)).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if calendar.recurring.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "repeat").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(tr("No repeating entries")).foregroundStyle(.secondary)
                    Text(tr("Say “every Monday at ten stand-up”")).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(calendar.recurring) { series in
                            SeriesRow(series: series, env: env)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct SeriesRow: View {
    let series: RecurringSeries
    let env: AppEnvironment
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "repeat").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: series.item.title).lineLimit(2)
                Text(verbatim: series.item.recurrence.map(Wording.recurrenceDetailed) ?? "").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(verbatim: nextText).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(hovering ? Color.primary.opacity(0.06) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { env.editorRequest = .edit(series.item) }
        .onTapGesture { if let next = series.next { env.calendar.select(next) } }
        .contextMenu {
            Button(tr("Edit…")) { env.editorRequest = .edit(series.item) }
            if let next = series.next { Button(tr("Show the next one")) { env.calendar.select(next) } }
            Divider()
            Button(tr("Delete the whole series"), role: .destructive) { env.act { try await env.calendar.delete(series.item) } }
        }
        .accessibilityElement(children: .combine)
    }

    private var nextText: String {
        guard let next = series.next else { return tr("no more") }
        let day = Wording.relativeDay(next, today: env.calendar.today)
        return tr("Next: %1$@", "\(day)") + (series.item.time.map { tr(" at %1$@", "\($0)") } ?? "")
    }
}
