import KuzmemoCore
import SwiftUI

struct AgendaRow: View {
    let entry: AgendaEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: entry.time.map { "\($0)" } ?? "весь день")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(verbatim: entry.item.title)
                .strikethrough(entry.isDone)
                .foregroundStyle(entry.isDone ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if entry.isRecurring {
                Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Повторяется")
            }
            if entry.item.source == .voice {
                Image(systemName: "mic.fill").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("Голосовая запись")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
