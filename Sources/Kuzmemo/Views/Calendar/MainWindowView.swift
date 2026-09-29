import KuzmemoCore
import SwiftUI

/// The calendar window: search, the month grid and the mode list on the left, and on the right the selected day,
/// the Inbox, search results or the repeating items.
struct MainWindowView: View {
    @Bindable var env: AppEnvironment
    @FocusState private var gridFocused: Bool
    @FocusState private var searchFocused: Bool

    private var calendar: CalendarModel { env.calendar }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 316)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) { toastBar }
        .frame(minWidth: 860, minHeight: 560)
        .sheet(item: $env.editorRequest) { request in
            ItemEditorView(request: request, env: env)
        }
        .onChange(of: env.searchFocusRequest) { searchFocused = true }
        .task {
            await calendar.reload()
            gridFocused = true
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchField
            MonthView(calendar: calendar, focused: $gridFocused)
            Divider()
            VStack(spacing: 2) {
                SidebarRow(title: "Календарь", symbol: "calendar", badge: 0, selected: calendar.mode == .day) {
                    calendar.select(calendar.selectedDate)
                }
                SidebarRow(title: "Входящие", symbol: "tray", badge: calendar.inboxCount, selected: calendar.mode == .inbox) {
                    calendar.show(.inbox)
                }
                SidebarRow(title: "Повторяющиеся", symbol: "repeat", badge: 0, selected: calendar.mode == .recurring) {
                    calendar.show(.recurring)
                }
            }
            Spacer(minLength: 0)
            VoiceStatusView(voice: env.voice)
        }
        .padding(14)
        .background(.background.secondary)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск по записям", text: Binding(get: { calendar.searchText }, set: { calendar.setSearchText($0) }))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { calendar.setSearchText(calendar.searchText) }
            if !calendar.searchText.isEmpty {
                Button {
                    calendar.setSearchText("")
                    calendar.select(calendar.selectedDate)
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.primary.opacity(0.10)))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch calendar.mode {
        case .day: DayListView(env: env)
        case .inbox: InboxView(env: env)
        case .search: SearchResultsView(env: env)
        case .recurring: RecurringView(env: env)
        }
    }

    @ViewBuilder private var toastBar: some View {
        if let toast = env.toast {
            ToastView(toast: toast, env: env)
                .frame(maxWidth: 560)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .padding(16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let badge: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20)
                Text(verbatim: title)
                Spacer()
                if badge > 0 {
                    Text(verbatim: "\(badge)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(selected ? 0.0 : 0.16), in: Capsule())
                        .foregroundStyle(selected ? Color.white : Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
