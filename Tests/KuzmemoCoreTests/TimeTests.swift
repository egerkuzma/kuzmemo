import Foundation
import Testing
@testable import KuzmemoCore

@Suite("LocalDate")
struct LocalDateTests {
    @Test func parsesAndPrints() {
        let date = LocalDate("2026-09-28")
        #expect(date?.year == 2026 && date?.month == 9 && date?.day == 28)
        #expect(date?.description == "2026-09-28")
        #expect(LocalDate("2026-02-30") == nil)
        #expect(LocalDate("2026-9-28") == nil)
        #expect(LocalDate("2026-09-28T10:00") == nil)
        #expect(LocalDate("2028-02-29") != nil)
        #expect(LocalDate("2027-02-29") == nil)
    }

    @Test func weekdays() {
        #expect(LocalDate("2026-09-28")?.weekday == .mon)
        #expect(LocalDate("1970-01-01")?.weekday == .thu)
        #expect(LocalDate("2026-10-02")?.weekday == .fri)
        #expect(LocalDate("2028-02-29")?.weekday == .tue)
        #expect(LocalDate("2026-10-04")?.weekday == .sun)
    }

    @Test func epochRoundTrip() {
        for n in stride(from: -719_000, to: 2_900_000, by: 997) {
            let date = LocalDate(epochDay: n)
            #expect(date.epochDay == n)
            #expect(LocalDate(date.description) == date)
        }
        #expect(LocalDate("1970-01-01")?.epochDay == 0)
        #expect(LocalDate("2026-09-28")?.epochDay == 20_724)
    }

    @Test func addingDaysCrossesMonthAndYearBoundaries() {
        #expect(LocalDate("2026-09-30")?.adding(days: 1) == LocalDate("2026-10-01"))
        #expect(LocalDate("2026-12-31")?.adding(days: 1) == LocalDate("2027-01-01"))
        #expect(LocalDate("2028-02-28")?.adding(days: 1) == LocalDate("2028-02-29"))
        #expect(LocalDate("2027-02-28")?.adding(days: 1) == LocalDate("2027-03-01"))
        #expect(LocalDate("2026-03-01")?.adding(days: -1) == LocalDate("2026-02-28"))
    }

    /// A number from a model or a transcript must never make a date that cannot be written down (a five-digit year) or an
    /// overflow: out-of-range days saturate at the first and the last day that can be stored.
    @Test func daysOutOfRangeSaturate() {
        #expect(LocalDate(epochDay: Int.max) == LocalDate.latest)
        #expect(LocalDate(epochDay: Int.min) == LocalDate.earliest)
        let today = LocalDate("2026-09-28")!
        #expect(today.adding(days: Int.max) == LocalDate.latest)
        #expect(today.adding(days: Int.min) == LocalDate.earliest)
        #expect(today.adding(days: 3_000_000) == LocalDate.latest)
        #expect(LocalDate(LocalDate.latest.description) == LocalDate.latest) // what is saturated can be read back
        #expect(LocalDate(LocalDate.earliest.description) == LocalDate.earliest)
        #expect(today.adding(months: Int.max).year <= 9999)
        #expect(today.adding(months: Int.min).year >= 1)
    }

    @Test func minutesOutOfRangeSaturate() {
        let now = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("14:30")!)
        #expect(now.adding(minutes: Int.max).date == LocalDate.latest)
        #expect(now.adding(minutes: Int.min).date == LocalDate.earliest)
        #expect(LocalDateTime(epochMinutes: Int.max).time.minutesSinceMidnight < 1440)
        #expect(LocalDateTime(epochMinutes: Int.min).time.minutesSinceMidnight >= 0)
    }

    @Test func addingMonthsClampsTheDay() {
        #expect(LocalDate("2026-01-31")?.adding(months: 1) == LocalDate("2026-02-28"))
        #expect(LocalDate("2028-01-31")?.adding(months: 1) == LocalDate("2028-02-29"))
        #expect(LocalDate("2026-03-31")?.adding(months: -1) == LocalDate("2026-02-28"))
        #expect(LocalDate("2026-11-15")?.adding(months: 3) == LocalDate("2027-02-15"))
        #expect(LocalDate("2026-01-15")?.adding(months: -1) == LocalDate("2025-12-15"))
        #expect(LocalDate("2028-02-29")?.adding(years: 1) == LocalDate("2029-02-28"))
    }

    @Test func nextWeekdayIsStrictlyAfterToday() {
        let monday = LocalDate("2026-09-28")!
        #expect(monday.next(.mon) == LocalDate("2026-10-05"))
        #expect(monday.next(.tue) == LocalDate("2026-09-29"))
        #expect(monday.next(.fri) == LocalDate("2026-10-02"))
        #expect(monday.next(.sun) == LocalDate("2026-10-04"))
        let friday = LocalDate("2026-10-02")!
        #expect(friday.next(.thu) == LocalDate("2026-10-08"))
    }

    @Test func weekAndMonthHelpers() {
        #expect(LocalDate("2026-10-02")?.startOfWeek == LocalDate("2026-09-28"))
        #expect(LocalDate("2026-09-28")?.startOfWeek == LocalDate("2026-09-28"))
        #expect(LocalDate("2026-10-04")?.startOfWeek == LocalDate("2026-09-28"))
        #expect(LocalDate("2026-09-15")?.lastOfMonth == LocalDate("2026-09-30"))
        #expect(LocalDate("2028-02-10")?.lastOfMonth == LocalDate("2028-02-29"))
        #expect(LocalDate("2026-09-15")?.firstOfMonth == LocalDate("2026-09-01"))
        #expect(LocalDate("2026-09-28")?.days(until: LocalDate("2026-10-05")!) == 7)
    }

    @Test func codableUsesPlainString() throws {
        let data = try JSONEncoder().encode(["d": LocalDate("2026-09-30")!])
        #expect(String(data: data, encoding: .utf8) == #"{"d":"2026-09-30"}"#)
        let back = try JSONDecoder().decode([String: LocalDate].self, from: data)
        #expect(back["d"] == LocalDate("2026-09-30"))
        #expect(throws: (any Error).self) { try JSONDecoder().decode([String: LocalDate].self, from: Data(#"{"d":"nope"}"#.utf8)) }
    }
}

@Suite("LocalTime and LocalDateTime")
struct LocalTimeTests {
    @Test func parsing() {
        #expect(LocalTime("09:05")?.minutesSinceMidnight == 545)
        #expect(LocalTime("9:05")?.description == "09:05")
        #expect(LocalTime("24:00") == nil)
        #expect(LocalTime("12:60") == nil)
        #expect(LocalTime("12:5") == nil)
        #expect(LocalTime(minutesSinceMidnight: 1439).description == "23:59")
    }

    @Test func dateTimeArithmeticCrossesMidnight() {
        let late = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("23:50")!)
        #expect(late.adding(minutes: 20).description == "2026-09-29 00:10")
        let early = LocalDateTime(date: LocalDate("2026-03-01")!, time: LocalTime("00:10")!)
        #expect(early.adding(minutes: -20).description == "2026-02-28 23:50")
        #expect(late.adding(minutes: 1440 * 3).description == "2026-10-01 23:50")
    }
}

@Suite("NowProvider")
struct NowProviderTests {
    let moscow = TimeZone(identifier: "Europe/Moscow")!

    @Test func fixedClockReadsBackTheSameWallClock() throws {
        let now = try #require(FixedNow(local: "2026-09-28 14:30", in: moscow))
        #expect(now.localNow().description == "2026-09-28 14:30")
        #expect(now.now().timeIntervalSince1970 == 1_790_595_000) // 2026-09-28T11:30:00Z
    }

    @Test func wallClockRoundTripsAcrossDaylightSavingChanges() throws {
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        for text in ["2026-03-29 12:00", "2026-10-25 12:00", "2026-03-28 23:30", "2026-10-26 00:15"] {
            let now = try #require(FixedNow(local: text, in: berlin))
            #expect(now.localNow().description == text)
        }
    }
}
