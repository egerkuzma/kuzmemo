import KuzmemoCore
import SwiftUI

/// Everything that needs the person: phrases that could not be processed, and entries without a date.
struct InboxView: View {
    let env: AppEnvironment
    @State private var quickText = ""

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Входящие").font(.title2.weight(.semibold))
                Text("Записи без даты и фразы, которые не удалось обработать").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !calendar.failedMemos.isEmpty {
                        title("Не обработано")
                        ForEach(calendar.failedMemos) { MemoCard(memo: $0, env: env).padding(.horizontal, 16) }
                    }
                    title("Без даты")
                    if calendar.inboxItems.isEmpty {
                        Text("Записей без даты нет").foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 8)
                    } else {
                        ForEach(calendar.inboxItems) { item in
                            EntryRow(entry: AgendaEntry(item: item, date: calendar.today, time: nil, isDone: false, occurrenceDate: nil, wasMoved: false), env: env)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").foregroundStyle(.secondary)
                TextField("Добавить запись без даты", text: $quickText).textFieldStyle(.plain).onSubmit {
                    let text = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    quickText = ""
                    env.act { try await calendar.quickAdd(text) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func title(_ text: String) -> some View {
        Text(verbatim: text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
    }
}

/// A phrase that failed: what was said, why, and what can be done about it.
private struct MemoCard: View {
    let memo: Memo
    let env: AppEnvironment
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: memo.inputKind == .voice ? "mic.fill" : "keyboard").foregroundStyle(.orange).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: memo.transcriptRaw.map { "«\($0)»" } ?? "Запись без текста").font(.callout)
                    Text(verbatim: MemoFailure.explanation(for: memo)).font(.caption).foregroundStyle(.secondary)
                    if let retry = retryText { Text(verbatim: retry).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            if editing {
                TextField("Исправьте текст", text: $text, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                HStack {
                    Button("Отмена") { editing = false }
                    Button("Повторить с этим текстом") {
                        editing = false
                        env.editAndRetry(memo: memo, text: text)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                HStack {
                    Button("Повторить") { env.retry(memo: memo) }
                    if memo.transcriptRaw != nil {
                        Button("Править текст…") {
                            text = memo.transcriptRaw ?? ""
                            editing = true
                        }
                        Button("Сохранить как заметку") { env.keepAsNote(memo: memo) }
                    }
                    Spacer()
                    Button("Отбросить", role: .destructive) { env.discard(memo: memo) }
                }
            }
        }
        .controlSize(.small)
        .padding(12)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }

    private var retryText: String? {
        guard let next = memo.nextRetryAt else { return nil }
        let date = Date(timeIntervalSince1970: Double(next) / 1000)
        let time = date.formatted(.dateTime.hour().minute().locale(DateBridge.russian))
        return date > Date() ? "Повторю автоматически в \(time)" : "Скоро повторю автоматически"
    }
}
