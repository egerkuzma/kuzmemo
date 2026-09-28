import Foundation
import Testing
@testable import KuzmemoCore

/// Anchor used by the golden set: Monday 2026-09-28, 14:30 (Europe/Moscow).
private func resolver(_ anchor: String = "2026-09-28 14:30") -> RelativeDateResolver {
    let parts = anchor.split(separator: " ")
    return RelativeDateResolver(anchor: LocalDateTime(date: LocalDate(String(parts[0]))!, time: LocalTime(String(parts[1]))!))
}

private func date(_ string: String) -> LocalDate { LocalDate(string)! }

@Suite("RelativeDateResolver")
struct ResolverTests {
    @Test func dayAfterTomorrowIsAllDay() {
        let r = resolver().resolve(When(mode: .daysFromToday, phrase: "послезавтра", daysFromToday: 2))
        #expect(r.date == date("2026-09-30") && r.time == nil && r.issues.isEmpty)
    }

    @Test func tomorrowWithExactTime() {
        let r = resolver().resolve(When(mode: .daysFromToday, daysFromToday: 1, time: LocalTime("11:00")))
        #expect(r.date == date("2026-09-29") && r.time == LocalTime("11:00"))
    }

    @Test func weekdayIsStrictlyInTheFutureEvenOnThatWeekday() {
        // Said on a Monday: "в понедельник" means next Monday, "в пятницу" this Friday.
        let monday = resolver().resolve(When(mode: .weekday, weekday: .mon, weekOffset: 0, time: LocalTime("10:00")))
        #expect(monday.date == date("2026-10-05") && monday.time == LocalTime("10:00"))
        #expect(resolver().resolve(When(mode: .weekday, weekday: .fri, weekOffset: 0)).date == date("2026-10-02"))
        #expect(resolver().resolve(When(mode: .weekday, weekday: .fri, weekOffset: 1)).date == date("2026-10-09"))
        #expect(resolver().resolve(When(mode: .weekday, weekday: .sun)).date == date("2026-10-04"))
    }

    @Test func weekOffsetCountsCalendarWeeks() {
        // Wednesday 2026-09-30: Monday of this week is behind us, so offset 0 rolls to next week.
        let wed = resolver("2026-09-30 10:00")
        #expect(wed.resolve(When(mode: .weekday, weekday: .mon, weekOffset: 0)).date == date("2026-10-05"))
        #expect(wed.resolve(When(mode: .weekday, weekday: .mon, weekOffset: 1)).date == date("2026-10-05")) // "на следующей неделе"
        #expect(wed.resolve(When(mode: .weekday, weekday: .fri, weekOffset: 0)).date == date("2026-10-02"))
        #expect(wed.resolve(When(mode: .weekday, weekday: .fri, weekOffset: 1)).date == date("2026-10-09"))
        #expect(wed.resolve(When(mode: .weekday, weekday: .fri, weekOffset: 2)).date == date("2026-10-16"))
        #expect(wed.resolve(When(mode: .weekday, weekday: .wed, weekOffset: 0)).date == date("2026-10-07")) // today rolls over
        // Sunday 2026-10-04: everything with offset 0 that is not later than today rolls
        let sun = resolver("2026-10-04 10:00")
        #expect(sun.resolve(When(mode: .weekday, weekday: .mon, weekOffset: 0)).date == date("2026-10-05"))
        #expect(sun.resolve(When(mode: .weekday, weekday: .sun, weekOffset: 0)).date == date("2026-10-11"))
        // From Monday, "на следующей неделе" (mon, 1) is the coming Monday, not the one after
        #expect(resolver().resolve(When(mode: .weekday, weekday: .mon, weekOffset: 1)).date == date("2026-10-05"))
        // negative offsets point into the past and are flagged
        #expect(resolver().resolve(When(mode: .weekday, weekday: .fri, weekOffset: -1)).issues == [.inThePast])
    }

    @Test func minutesFromNowCrossMidnight() {
        let r1 = resolver().resolve(When(mode: .minutesFromNow, minutesFromNow: 120))
        #expect(r1.date == date("2026-09-28") && r1.time == LocalTime("16:30"))
        let r2 = resolver().resolve(When(mode: .minutesFromNow, minutesFromNow: 30))
        #expect(r2.time == LocalTime("15:00"))
        let late = resolver("2026-09-28 23:50").resolve(When(mode: .minutesFromNow, minutesFromNow: 20))
        #expect(late.date == date("2026-09-29") && late.time == LocalTime("00:10"))
    }

    @Test func absoluteDatesAndYearRollover() {
        #expect(resolver().resolve(When(mode: .absolute, date: date("2026-10-01"))).date == date("2026-10-01"))
        #expect(resolver().resolve(When(mode: .absolute, date: date("2027-01-15"))).date == date("2027-01-15"))
        let missing = resolver().resolve(When(mode: .absolute))
        #expect(missing.date == nil && missing.issues == [.incomplete("date")])
    }

    @Test func dayPartsUseConfigurableDefaults() {
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: 1, dayPart: .morning)).time == LocalTime("09:00"))
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: 1, dayPart: .evening)).time == LocalTime("19:00"))
        var custom = DayPartDefaults.standard
        custom.morning = LocalTime("07:30")!
        let r = RelativeDateResolver(anchor: resolver().anchor, dayParts: custom)
        #expect(r.resolve(When(mode: .daysFromToday, daysFromToday: 1, dayPart: .morning)).time == LocalTime("07:30"))
        // an exact time wins over the day part
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: 1, time: LocalTime("08:15"), dayPart: .evening)).time == LocalTime("08:15"))
    }

    @Test func monthParts() {
        let end = resolver().resolve(When(mode: .monthPart, monthPart: .end, monthOffset: 0))
        #expect(end.date == date("2026-09-30") && end.approximate)
        let nextStart = resolver().resolve(When(mode: .monthPart, monthPart: .start, monthOffset: 1))
        #expect(nextStart.date == date("2026-10-01"))
        #expect(resolver("2028-01-31 10:00").resolve(When(mode: .monthPart, monthPart: .end, monthOffset: 1)).date == date("2028-02-29"))
    }

    @Test func noneKeepsOnlyTheTime() {
        let r = resolver().resolve(When(mode: .none, time: LocalTime("17:00")))
        #expect(r.date == nil && r.time == LocalTime("17:00"))
    }

    @Test func pastMomentsAreFlagged() {
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: -1)).issues == [.inThePast])
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: 0, time: LocalTime("09:00"))).issues == [.inThePast])
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: 0, time: LocalTime("15:00"))).issues.isEmpty)
        #expect(resolver().resolve(When(mode: .daysFromToday, daysFromToday: 0)).issues.isEmpty) // all-day today is fine
    }

    @Test func monthAndYearBoundariesAtTheEndOfTheYear() {
        let r = resolver("2026-12-30 10:00")
        #expect(r.resolve(When(mode: .daysFromToday, daysFromToday: 3)).date == date("2027-01-02"))
        #expect(r.resolve(When(mode: .weekday, weekday: .fri)).date == date("2027-01-01"))
        #expect(resolver("2028-02-28 10:00").resolve(When(mode: .daysFromToday, daysFromToday: 1)).date == date("2028-02-29"))
    }
}

@Suite("When decoding")
struct WhenDecodingTests {
    @Test func decodesTheSchemaShape() throws {
        let json = #"{"mode":"weekday","weekday":"mon","week_offset":0,"time":"10:00","phrase":"в понедельник в десять"}"#
        let when = try JSONDecoder().decode(When.self, from: Data(json.utf8))
        #expect(when.mode == .weekday && when.weekday == .mon && when.weekOffset == 0)
        #expect(when.time == LocalTime("10:00"))
    }

    @Test func toleratesLooseTimeFormats() throws {
        for (text, expected) in [("9:00", "09:00"), ("09:00:00", "09:00"), ("9", "09:00"), ("17", "17:00")] {
            let json = #"{"mode":"days_from_today","days_from_today":1,"time":"\#(text)"}"#
            let when = try JSONDecoder().decode(When.self, from: Data(json.utf8))
            #expect(when.time?.description == expected, "time \(text)")
        }
        let garbage = try JSONDecoder().decode(When.self, from: Data(#"{"mode":"none","time":"вечером"}"#.utf8))
        #expect(garbage.time == nil)
    }

    @Test func rejectsUnknownModesAndBadDates() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(When.self, from: Data(#"{"mode":"someday"}"#.utf8)) }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(When.self, from: Data(#"{"mode":"absolute","date":"2026-13-40"}"#.utf8)) }
    }

    @Test func encodesSnakeCaseKeysAndSkipsNils() throws {
        let when = When(mode: .daysFromToday, phrase: "завтра", daysFromToday: 1, time: LocalTime("11:00"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(when), as: UTF8.self)
            == #"{"days_from_today":1,"mode":"days_from_today","phrase":"завтра","time":"11:00"}"#)
    }
}

@Suite("PhraseDateHint cross-check")
struct CrossCheckTests {
    private let anchor = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("14:30")!)

    @Test(arguments: [
        ("послезавтра", "2026-09-30"),
        ("завтра в одиннадцать", "2026-09-29"),
        ("сегодня вечером", "2026-09-28"),
        ("вчера", "2026-09-27"),
        ("во вторник", "2026-09-29"),
        ("в пятницу", "2026-10-02"),
        ("в понедельник в десять", "2026-10-05"),
        ("в воскресенье", "2026-10-04"),
        ("через три дня", "2026-10-01"),
        ("через 3 дня", "2026-10-01"),
        ("через неделю", "2026-10-05"),
        ("через две недели", "2026-10-12"),
        ("через месяц", "2026-10-28"),
        ("через два часа", "2026-09-28"),
        ("через полчаса", "2026-09-28"),
        ("через двадцать пять минут", "2026-09-28"),
        ("в конце месяца", "2026-09-30"),
    ])
    func recognisesCommonPhrases(phrase: String, expected: String) {
        #expect(PhraseDateHint.date(for: phrase, anchor: anchor) == LocalDate(expected), "phrase '\(phrase)'")
    }

    @Test func ambiguousOrUnknownPhrasesGiveNoHint() {
        for phrase in ["в следующую пятницу", "на следующей неделе", "ближайшую среду", "как-нибудь потом", "", "созвон"] {
            #expect(PhraseDateHint.date(for: phrase, anchor: anchor) == nil, "phrase '\(phrase)'")
        }
    }

    @Test func hoursAcrossMidnightMoveTheDate() {
        let late = LocalDateTime(date: LocalDate("2026-09-28")!, time: LocalTime("23:00")!)
        #expect(PhraseDateHint.date(for: "через два часа", anchor: late) == LocalDate("2026-09-29"))
    }

    @Test func crossCheckDetectsWrongArithmetic() {
        let r = RelativeDateResolver(anchor: anchor)
        let good = When(mode: .daysFromToday, phrase: "послезавтра", daysFromToday: 2)
        #expect(r.crossCheck(good, resolved: r.resolve(good)) == .agrees)
        let bad = When(mode: .daysFromToday, phrase: "послезавтра", daysFromToday: 3)
        #expect(r.crossCheck(bad, resolved: r.resolve(bad)) == .disagrees(localDate: LocalDate("2026-09-30")!))
        let wrongWeek = When(mode: .weekday, phrase: "в понедельник", weekday: .mon, weekOffset: 2)
        #expect(r.crossCheck(wrongWeek, resolved: r.resolve(wrongWeek)) == .disagrees(localDate: LocalDate("2026-10-05")!))
        let ambiguous = When(mode: .weekday, phrase: "в следующую пятницу", weekday: .fri, weekOffset: 1)
        #expect(r.crossCheck(ambiguous, resolved: r.resolve(ambiguous)) == .noHint)
        let noPhrase = When(mode: .daysFromToday, daysFromToday: 2)
        #expect(r.crossCheck(noPhrase, resolved: r.resolve(noPhrase)) == .noHint)
    }
}
