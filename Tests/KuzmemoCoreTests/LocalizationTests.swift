import Foundation
import Testing
@testable import KuzmemoCore

private let today = LocalDate("2026-09-28")! // a Monday

private func date(_ text: String) -> LocalDate { LocalDate(text)! }

private func entry(_ title: String, _ day: String, _ time: String? = nil, kind: ItemKind = .reminder) -> AgendaEntry {
    let item = Item(id: title, kind: kind, title: title, date: LocalDate(day), time: time.flatMap(LocalTime.init))
    return AgendaEntry(item: item, date: LocalDate(day)!, time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false)
}

private func change(_ kind: AppliedChange.Kind, _ item: Item, newDate: String? = nil, newTime: String? = nil) -> AppliedChange {
    AppliedChange(kind: kind, item: item, occurrenceDate: nil, newDate: newDate.flatMap(LocalDate.init), newTime: newTime.flatMap(LocalTime.init))
}

@Suite("Localization")
struct LocalizationTests {
    @Test func aTextIsTranslatedAndAnUnknownOneIsShownAsItIs() {
        #expect(Localization.with(.english) { tr("Today") } == "Today")
        #expect(Localization.with(.russian) { tr("Today") } == "Сегодня")
        #expect(Localization.with(.russian) { tr("A sentence nobody translated") } == "A sentence nobody translated")
    }

    /// The size of a file was written by the system formatter in the system's language: an English interface on a Mac set to
    /// Russian showed "МБ".
    @Test func fileSizesAreWrittenInTheInterfaceLanguage() {
        func plain(_ text: String) -> String {
            text.unicodeScalars.map { $0.properties.isWhitespace ? " " : String($0) }.joined()
        }
        #expect(plain(Localization.with(.english) { Wording.fileSize(bytes: 1_500_000) }) == "1.5 MB")
        #expect(plain(Localization.with(.russian) { Wording.fileSize(bytes: 1_500_000) }) == "1,5 МБ")
        #expect(plain(Localization.with(.english) { Wording.fileSize(bytes: 0) }) == "0 bytes")
    }

    @Test func argumentsAreFilledIn() {
        #expect(Localization.with(.english) { tr("Could not save: %1$@", "disk full") } == "Could not save: disk full")
        #expect(Localization.with(.russian) { tr("Could not save: %1$@", "диск полон") } == "Не удалось сохранить: диск полон")
        #expect(Localization.with(.russian) { tr("Times: %1$lld", numbers: 3) } == "Повторений: 3")
    }

    @Test func pluralFormsFollowEachLanguagesRules() {
        let english = [1: "1 minute", 2: "2 minutes", 5: "5 minutes", 21: "21 minutes"]
        for (count, text) in english { #expect(Localization.with(.english) { trCount("%lld minutes", count) } == text) }
        let russian = [1: "1 минуту", 2: "2 минуты", 5: "5 минут", 11: "11 минут", 21: "21 минуту", 22: "22 минуты", 112: "112 минут"]
        for (count, text) in russian { #expect(Localization.with(.russian) { trCount("%lld minutes", count) } == text, "\(count)") }
    }

    @Test func theSystemLanguageDecidesWhenTheChoiceIsSystem() {
        #expect(AppLanguage.best(for: ["ru-RU", "en-US"]) == .russian)
        #expect(AppLanguage.best(for: ["de-DE", "en-GB"]) == .english)
        #expect(AppLanguage.best(for: ["fr-FR"]) == .english)
        #expect(LanguagePreference.system.resolved(preferred: ["ru"]) == .russian)
        #expect(LanguagePreference.english.resolved(preferred: ["ru"]) == .english)
        #expect(LanguagePreference.russian.resolved(preferred: ["en"]) == .russian)
    }

    @Test func aPinnedLanguageDoesNotLeakToOtherTasks() async {
        async let english = Localization.with(.english) { () async -> String in
            try? await Task.sleep(for: .milliseconds(50))
            return tr("Today")
        }
        async let russian = Localization.with(.russian) { () async -> String in
            try? await Task.sleep(for: .milliseconds(20))
            return tr("Today")
        }
        let (inEnglish, inRussian) = await (english, russian)
        #expect(inEnglish == "Today")
        #expect(inRussian == "Сегодня")
    }
}

@Suite("English wording")
struct EnglishWordingTests {
    private func english<T>(_ body: () -> T) -> T { Localization.with(.english, body) }

    @Test func datesAndDays() {
        english {
            #expect(Wording.date(date("2026-09-30")) == "September 30")
            #expect(Wording.dateWithWeekday(date("2026-09-30")) == "Wed, September 30")
            #expect(Wording.dayTitle(date("2026-09-30")) == "Wednesday, September 30")
            #expect(Wording.monthTitle(date("2026-09-30")) == "September 2026")
            #expect(Wording.weekdayShortName(.mon) == "Mon")
            #expect(Wording.relativeDay(date("2026-09-28"), today: today) == "today")
            #expect(Wording.relativeDay(date("2026-09-29"), today: today) == "tomorrow")
            #expect(Wording.relativeDay(date("2026-09-30"), today: today) == "the day after tomorrow")
            #expect(Wording.relativeDay(date("2026-10-02"), today: today) == "on Friday, October 2")
            #expect(Wording.relativeDay(date("2026-10-12"), today: today) == "October 12")
        }
    }

    @Test func countsAndLists() {
        english {
            #expect(Wording.entryCount(0) == "no entries" && Wording.entryCount(1) == "1 entry" && Wording.entryCount(3) == "3 entries")
            #expect(Wording.list(["a"]) == "a" && Wording.list(["a", "b"]) == "a and b" && Wording.list(["a", "b", "c"]) == "a, b and c")
        }
    }

    @Test func leadTimes() {
        english {
            #expect(Wording.leadPhrase(0) == "Now" && Wording.leadPhrase(5) == "In 5 minutes" && Wording.leadPhrase(60) == "In 1 hour")
            #expect(Wording.leadPhrase(1440) == "In 1 day" && Wording.leadPhrase(2880) == "In 2 days")
            #expect(Wording.leadBefore(0) == "at the start" && Wording.leadBefore(5) == "5 minutes before" && Wording.leadBefore(1) == "1 minute before")
            #expect(Wording.leadChip(0) == "At start" && Wording.leadChip(5) == "5 min" && Wording.leadChip(60) == "1 hour" && Wording.leadChip(120) == "2 hours")
            #expect(Wording.leadChip(1440) == "1 day")
        }
    }

    @Test func recurrences() {
        english {
            #expect(Wording.recurrence(Recurrence(freq: .daily)) == "every day")
            #expect(Wording.recurrence(Recurrence(freq: .daily, interval: 2)) == "every 2 days")
            #expect(Wording.recurrence(Recurrence(freq: .weekly, byWeekday: [.mon, .tue, .wed, .thu, .fri])) == "on weekdays")
            #expect(Wording.recurrence(Recurrence(freq: .weekly, byWeekday: [.wed])) == "every Wednesday")
            #expect(Wording.recurrence(Recurrence(freq: .weekly, interval: 2, byWeekday: [.fri])) == "every 2 weeks on Fri")
            #expect(Wording.recurrence(Recurrence(freq: .monthly, byMonthday: 25)) == "every month, on the 25th")
            #expect(Wording.recurrence(Recurrence(freq: .monthly, byMonthday: 1)) == "every month, on the 1st")
            #expect(Wording.recurrenceDetailed(Recurrence(freq: .weekly, byWeekday: [.wed], until: date("2026-12-31"))) == "Every Wednesday, until December 31")
            #expect(Wording.recurrenceDetailed(Recurrence(freq: .daily, count: 10)) == "Every day, 10 times")
        }
    }

    @Test func spokenTimes() {
        english {
            #expect(Wording.spokenTime(LocalTime("16:30")!) == "at 4:30 PM")
            #expect(Wording.spokenTime(LocalTime("09:00")!) == "at 9 AM")
            #expect(Wording.spokenTime(LocalTime("00:00")!) == "at midnight")
            #expect(Wording.spokenTime(LocalTime("12:00")!) == "at noon")
            #expect(Wording.spokenTime(LocalTime("12:05")!) == "at 12:05 PM")
            #expect(Wording.spokenTime(LocalTime("00:15")!) == "at 12:15 AM")
        }
    }

    @Test func confirmationLinesAndSpokenConfirmations() {
        english {
            let reminder = Item(id: "1", kind: .reminder, title: "Tell Dmitry", date: date("2026-09-30"))
            #expect(change(.created, reminder).summary(today: today) == "Reminder · the day after tomorrow · “Tell Dmitry”")
            let event = Item(id: "2", kind: .event, title: "Team sync", date: date("2026-09-29"), time: LocalTime("11:00"))
            #expect(change(.created, event).summary(today: today) == "Event · tomorrow at 11:00 · “Team sync”")
            #expect(change(.created, event).spokenConfirmation(today: today) == "Saved: an event for tomorrow at 11 AM — Team sync.")
            #expect(change(.completed, event).spokenConfirmation(today: today) == "Marked as done: Team sync.")
            #expect(change(.moved, event, newDate: "2026-10-02", newTime: "16:30").spokenConfirmation(today: today)
                == "Moved: Team sync for Friday, October 2 at 4:30 PM.")
            #expect(change(.deleted, event).summary(today: today) == "Deleted · “Team sync”")
        }
    }

    @Test func spokenAgendas() {
        english {
            let speaker = AgendaSpeaker()
            func day(_ offset: Int) -> QueryPlan.Target { let d = today.adding(days: offset); return .days(d ... d) }
            func result(_ target: QueryPlan.Target, _ entries: [AgendaEntry], detail: QueryDetail = .digest) -> QueryResult {
                QueryResult(plan: QueryPlan(target: target, detail: detail), entries: entries, title: "")
            }
            #expect(speaker.speech(for: result(day(0), []), today: today) == "Today you have nothing planned.")
            #expect(speaker.speech(for: result(day(1), []), today: today) == "Tomorrow you have nothing planned.")
            let several = result(day(0), [entry("Stand-up", "2026-09-28", "09:00"), entry("Meeting", "2026-09-28", "16:30"), entry("Pay the invoice", "2026-09-28")])
            #expect(speaker.speech(for: several, today: today) == "Today you have 3 items: at 9 AM, Stand-up. at 4:30 PM, Meeting. no time, Pay the invoice.")
            #expect(speaker.speech(for: result(day(0), [entry("Stand-up", "2026-09-28", "09:00")]), today: today) == "Today you have 1 item: at 9 AM, Stand-up.")
            #expect(speaker.speech(for: result(.overdue, []), today: today) == "Nothing is overdue.")
            let overdue = result(.overdue, [entry("Old thing", "2026-09-20")])
            #expect(speaker.speech(for: overdue, today: today) == "You have 1 item overdue: September 20, Old thing.")
        }
    }

    @Test func alertsCarryTheirOwnWording() {
        english {
            let settings = NotificationSettings()
            let alerts = AlertPlanner.plan(
                entries: [entry("Team sync", "2026-09-29", "11:00", kind: .event), entry("Pay for hosting", "2026-09-30")],
                settings: settings, now: FixedNow(local: "2026-09-28 12:00", in: TimeZone(identifier: "Europe/Moscow")!)!.now(),
                timeZone: TimeZone(identifier: "Europe/Moscow")!
            )
            #expect(alerts.map(\.body) == ["In 5 minutes · 11:00", "Now · 11:00", "Today · all day"])
            #expect(alerts.map(\.kindText) == ["5 minutes before", "At the scheduled time", "All-day item"])
            #expect(alerts.map(\.subtitle) == ["Event", "Event", "Reminder"])
        }
    }
}

@Suite("English questions and phrases")
struct EnglishPhraseTests {
    @Test func theLocalRouterAnswersEnglishQuestions() {
        let router = LocalIntentRouter()
        func day(_ offset: Int) -> QueryPlan { let d = today.adding(days: offset); return QueryPlan(target: .days(d ... d)) }
        #expect(router.route("What's on today?", today: today) == day(0))
        #expect(router.route("what do I have tomorrow", today: today) == day(1))
        #expect(router.route("Anything the day after tomorrow", today: today) == day(2))
        #expect(router.route("what's next", today: today) == QueryPlan(target: .upcoming(limit: 5)))
        #expect(router.route("what's overdue", today: today) == QueryPlan(target: .overdue))
        #expect(router.route("what's on this week", today: today) == QueryPlan(target: .days(today ... today.startOfWeek.adding(days: 6))))
        #expect(router.route("remind me tomorrow to call the bank", today: today) == nil) // a command, not a question
    }

    @Test func theDateCrossCheckReadsEnglishPhrases() {
        let anchor = LocalDateTime(date: today, time: LocalTime("14:30")!)
        #expect(PhraseDateHint.date(for: "tomorrow at eleven", anchor: anchor) == today.adding(days: 1))
        #expect(PhraseDateHint.date(for: "the day after tomorrow", anchor: anchor) == today.adding(days: 2))
        #expect(PhraseDateHint.date(for: "in three days", anchor: anchor) == today.adding(days: 3))
        #expect(PhraseDateHint.date(for: "in two hours", anchor: anchor) == today)
        #expect(PhraseDateHint.date(for: "in a week", anchor: anchor) == today.adding(days: 7))
        #expect(PhraseDateHint.date(for: "on Friday", anchor: anchor) == date("2026-10-02"))
        #expect(PhraseDateHint.date(for: "next Friday", anchor: anchor) == nil) // ambiguous: nothing is overridden
    }
}
