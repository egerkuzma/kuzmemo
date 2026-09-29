import KuzmemoCore
import SwiftUI

/// Search results. A click takes you to the day (or the Inbox) where the entry lives.
struct SearchResultsView: View {
    let env: AppEnvironment

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Search")).font(.title2.weight(.semibold))
                Text(verbatim: summary).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if calendar.searchResults.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(calendar.searchText.isEmpty ? tr("Enter a query") : tr("Nothing found")).foregroundStyle(.secondary)
                    if !calendar.searchText.isEmpty { Text(tr("Searches titles, details and keywords")).font(.caption).foregroundStyle(.tertiary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(calendar.searchResults) { item in
                            SearchRow(item: item, env: env)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var summary: String {
        let query = calendar.searchText.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { return tr("Find an entry by title or keyword") }
        return "«\(query)» — \(Wording.entryCount(calendar.searchResults.count))"
    }
}

private struct SearchRow: View {
    let item: Item
    let env: AppEnvironment
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Text(verbatim: dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: item.title).strikethrough(item.status == .done).foregroundStyle(item.status == .done ? .secondary : .primary).lineLimit(2)
                    if let details = item.details, let line = details.split(whereSeparator: \.isNewline).first {
                        Text(verbatim: String(line.prefix(90))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if item.recurrence != nil { Image(systemName: "repeat").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(hovering ? Color.primary.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tr("Open day")) { open() }
            Button(tr("Edit…")) { env.editorRequest = .edit(item) }
        }
        .accessibilityElement(children: .combine)
    }

    private var dateText: String {
        guard let date = item.date else { return tr("No date") }
        let base = Wording.date(date)
        return item.time.map { "\(base), \($0)" } ?? base
    }

    private var symbol: String {
        switch item.kind {
        case .reminder: "bell"
        case .event: "calendar"
        case .task: "checklist"
        case .note: "note.text"
        }
    }

    private func open() {
        if let date = item.date { env.calendar.select(date) } else { env.calendar.show(.inbox) }
    }
}
