import KuzmemoCore
import SwiftUI

/// Placeholder for the calendar window (month grid and day agenda arrive in milestone M5).
struct MainWindowView: View {
    let env: AppEnvironment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kuzmemo").font(.largeTitle.bold())
            Text("Календарь появится на этапе M5. Пока здесь план на сегодня.").foregroundStyle(.secondary)
            Divider()
            if env.todayEntries.isEmpty {
                Text("На сегодня ничего не запланировано.").foregroundStyle(.secondary)
            } else {
                ForEach(env.todayEntries) { AgendaRow(entry: $0) }
            }
            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .task { await env.reloadToday() }
    }
}
