import AppKit
import KuzmemoCore
import SwiftUI

/// The menu-bar popover: today's plan, the last result and a text box that goes through the same pipeline
/// as a spoken phrase.
struct PopoverView: View {
    let env: AppEnvironment
    @State private var text = ""
    @FocusState private var focused: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            agenda
            if let toast = env.toast { ToastView(toast: toast, env: env) }
            VoiceStatusView(voice: env.voice)
            input
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 380)
        .task { await env.reloadToday() }
    }

    private var header: some View {
        let today = env.clock.localNow().date
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: env.queryResult.map { $0.title.capitalizedFirst } ?? "Сегодня")
                    .font(.headline)
                Text(verbatim: "\(RussianFormat.weekdayName(today.weekday).capitalizedFirst), \(RussianFormat.date(today))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if env.status == .thinking { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder private var agenda: some View {
        let entries = env.queryResult?.entries ?? env.todayEntries
        if entries.isEmpty {
            Text(env.queryResult == nil ? "На сегодня ничего не запланировано." : "Ничего не найдено.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { AgendaRow(entry: $0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
    }

    private var input: some View {
        TextField("Что записать? Например: завтра в 11 созвон", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .disabled(env.status == .thinking)
            .onSubmit {
                let phrase = text
                text = ""
                Task { await env.submit(text: phrase) }
            }
            .task { focused = true }
    }

    private var footer: some View {
        HStack {
            Button("Открыть Kuzmemo") {
                openWindow(id: "main")
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Выйти") { NSApp.terminate(nil) }
        }
        .buttonStyle(.link)
        .font(.callout)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
