import KuzmemoCore
import SwiftUI

/// The month grid: title and paging, weekday row, and six rows of day cells with dots for the day's entries.
struct MonthView: View {
    let calendar: CalendarModel
    @FocusState.Binding var focused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    var body: some View {
        VStack(spacing: 8) {
            header
            weekdays
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(calendar.grid.days, id: \.self) { date in
                    DayCell(
                        date: date, isInMonth: calendar.grid.isInMonth(date), isToday: date == calendar.today,
                        isSelected: date == calendar.selectedDate && calendar.mode == .day, marker: calendar.markers[date]
                    ) {
                        focused = true
                        calendar.select(date)
                    }
                }
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.modifiers.isEmpty else { return .ignored }
            switch press.key {
            case .leftArrow: calendar.moveSelection(byDays: -1)
            case .rightArrow: calendar.moveSelection(byDays: 1)
            case .upArrow: calendar.moveSelection(byDays: -7)
            case .downArrow: calendar.moveSelection(byDays: 7)
            default: return .ignored
            }
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(verbatim: Wording.monthTitle(calendar.grid.month)).font(.title3.weight(.semibold))
            Spacer()
            Button { calendar.moveMonth(by: -1) } label: { Image(systemName: "chevron.left") }
                .help(tr("Previous month (⌘←)")).accessibilityLabel(tr("Previous month"))
            Button(tr("Today")) { calendar.goToToday() }.help(tr("Go to today (⌘T)"))
            Button { calendar.moveMonth(by: 1) } label: { Image(systemName: "chevron.right") }
                .help(tr("Next month (⌘→)")).accessibilityLabel(tr("Next month"))
        }
        .buttonStyle(.borderless)
    }

    private var weekdays: some View {
        HStack(spacing: 2) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                Text(verbatim: Wording.weekdayShortName(weekday))
                    .font(.caption)
                    .foregroundStyle(weekday.rawValue >= 6 ? .tertiary : .secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DayCell: View {
    let date: LocalDate
    let isInMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let marker: DayMarker?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(verbatim: "\(date.day)")
                    .font(.system(.callout, design: .rounded).monospacedDigit().weight(isToday ? .bold : .regular))
                    .foregroundStyle(numberColor)
                dots.frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Color.accentColor : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isToday && !isSelected ? 1.5 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(Wording.dayTitle(date)), \(Wording.entryCount(marker?.total ?? 0))"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return .accentColor }
        return isInMonth ? .primary : Color.secondary.opacity(0.5)
    }

    /// Coloured dots for one-off things still to do (three at most, then a plus), a quiet grey one for repeating
    /// entries so that a daily habit does not paint the whole month, and a grey one when everything is done.
    @ViewBuilder private var dots: some View {
        let oneOff = marker?.openOneOff ?? 0
        let repeating = marker?.openRecurring ?? 0
        let quiet = isSelected ? Color.white.opacity(0.65) : Color.secondary.opacity(0.45)
        HStack(spacing: 3) {
            ForEach(0 ..< min(oneOff, 3), id: \.self) { _ in
                Circle().fill(isSelected ? Color.white : Color.accentColor).frame(width: 5, height: 5)
            }
            if oneOff > 3 { Text(verbatim: "+").font(.system(size: 8, weight: .bold)).foregroundStyle(isSelected ? .white : Color.accentColor) }
            if repeating > 0 { Circle().fill(quiet).frame(width: 4, height: 4) }
            if oneOff == 0, repeating == 0, (marker?.done ?? 0) > 0 { Circle().fill(quiet).frame(width: 5, height: 5) }
        }
    }
}
