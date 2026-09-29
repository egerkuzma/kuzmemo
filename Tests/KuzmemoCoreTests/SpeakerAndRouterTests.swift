import Foundation
import Testing
@testable import KuzmemoCore

private let today = LocalDate("2026-09-28")!

private func entry(_ title: String, _ date: String, _ time: String? = nil) -> AgendaEntry {
    let item = Item(id: title, kind: .reminder, title: title, date: LocalDate(date), time: time.flatMap(LocalTime.init))
    return AgendaEntry(item: item, date: LocalDate(date)!, time: item.time, isDone: false, occurrenceDate: nil, wasMoved: false)
}

private func result(_ target: QueryPlan.Target, _ entries: [AgendaEntry], detail: QueryDetail = .digest, passed: Int = 0) -> QueryResult {
    QueryResult(plan: QueryPlan(target: target, detail: detail), entries: entries, title: "", passedToday: passed)
}

private func day(_ offset: Int) -> QueryPlan.Target {
    let d = today.adding(days: offset)
    return .days(d ... d)
}

@Suite("AgendaSpeaker")
struct AgendaSpeakerTests {
    private let speaker = AgendaSpeaker()

    @Test func anEmptyDay() {
        #expect(speaker.speech(for: result(day(0), []), today: today) == "На сегодня у вас ничего не запланировано.")
        #expect(speaker.speech(for: result(day(1), []), today: today) == "На завтра у вас ничего не запланировано.")
    }

    @Test func whenOnlyPassedThingsRemainTheDayIsDoneNotEmpty() {
        #expect(speaker.speech(for: result(day(0), [], passed: 2), today: today) == "На сегодня у вас больше ничего.")
        #expect(speaker.speech(for: result(day(0), [], detail: .count, passed: 1), today: today) == "На сегодня у вас больше ничего.")
        #expect(speaker.speech(for: result(day(0), [], detail: .count), today: today) == "На сегодня у вас ничего нет.")
        Localization.with(.english) {
            #expect(speaker.speech(for: result(day(0), [], passed: 2), today: today) == "Today you have nothing left.")
            #expect(speaker.speech(for: result(day(0), []), today: today) == "Today you have nothing planned.")
        }
    }

    @Test func oneAndSeveralEntriesReadTimesAsWords() {
        let one = speaker.speech(for: result(day(0), [entry("Созвон с Акме", "2026-09-28", "11:00")]), today: today)
        #expect(one == "На сегодня у вас одно дело: в одиннадцать часов, Созвон с Акме.")
        let several = speaker.speech(for: result(day(0), [
            entry("Планёрка", "2026-09-28", "09:00"), entry("Встреча", "2026-09-28", "16:30"), entry("Оплатить инвойс", "2026-09-28"),
        ]), today: today)
        #expect(several == "На сегодня у вас три дела: в девять часов, Планёрка. в шестнадцать тридцать, Встреча. без времени, Оплатить инвойс.")
    }

    @Test func rangesMentionTheDayOfEachEntry() {
        let text = speaker.speech(for: result(.days(today ... today.adding(days: 6)), [
            entry("Созвон", "2026-09-29", "11:00"), entry("Оплатить инвойс", "2026-10-02"),
        ]), today: today)
        #expect(text == "С 28 сентября по 4 октября у вас два дела: завтра, в одиннадцать часов, Созвон. в пятницу, 2 октября, Оплатить инвойс.")
    }

    @Test func longListsAreCutOffWithACount() {
        let entries = (1 ... 9).map { entry("Дело \($0)", "2026-09-28", String(format: "%02d:00", 8 + $0)) }
        let text = speaker.speech(for: result(day(0), entries), today: today)
        #expect(text.hasPrefix("На сегодня у вас девять дел:"))
        #expect(text.hasSuffix("И ещё три записи."))
        #expect(text.components(separatedBy: "Дело").count == 7) // six read
    }

    @Test func glossarySpokenFormsReplaceBrandNames() {
        let speaker = AgendaSpeaker(glossary: [GlossaryTerm(canonical: "Notion", aliases: [], spoken: "Нотион")])
        let text = speaker.speech(for: result(day(0), [entry("Проверить доступ Notion", "2026-09-28")]), today: today)
        #expect(text == "На сегодня у вас одно дело: без времени, Проверить доступ Нотион.")
    }

    @Test func countAndFirstDetails() {
        let entries = (1 ... 3).map { entry("Дело \($0)", "2026-09-29", "1\($0):00") }
        #expect(speaker.speech(for: result(day(1), entries, detail: .count), today: today) == "На завтра у вас три дела.")
        #expect(speaker.speech(for: result(day(1), [], detail: .count), today: today) == "На завтра у вас ничего нет.")
        #expect(speaker.speech(for: result(.upcoming(limit: 1), [entries[0]], detail: .first), today: today)
            == "Ближайшее: завтра, в одиннадцать часов, Дело 1.")
    }

    @Test func emptyAnswersForOtherTargets() {
        #expect(speaker.speech(for: result(.overdue, []), today: today) == "Просроченных дел нет.")
        #expect(speaker.speech(for: result(.upcoming(limit: 5), []), today: today) == "Ближайших дел нет.")
        #expect(speaker.speech(for: result(.search("x"), []), today: today) == "Ничего не нашёл.")
        #expect(speaker.speech(for: result(.inbox, []), today: today) == "Записей без даты нет.")
        #expect(speaker.speech(for: result(.overdue, [entry("Позвонить", "2026-09-20")]), today: today)
            == "Просрочено одно дело: 20 сентября, Позвонить.")
    }

    @Test(arguments: [
        ("09:00", "в девять часов"), ("01:00", "в один час"), ("02:00", "в два часа"), ("05:00", "в пять часов"),
        ("12:00", "в двенадцать часов"), ("16:30", "в шестнадцать тридцать"), ("09:05", "в девять ноль пять"),
        ("21:00", "в двадцать один час"), ("22:00", "в двадцать два часа"), ("23:45", "в двадцать три сорок пять"),
        ("00:00", "в полночь"), ("00:15", "в ноль пятнадцать"),
    ])
    func spokenTimes(time: String, expected: String) {
        #expect(AgendaSpeaker.spokenTime(LocalTime(time)!) == expected)
    }

    @Test func numberWords() {
        #expect(NumberWords.say(0, feminine: false) == "ноль")
        #expect(NumberWords.say(1, feminine: true) == "одна" && NumberWords.say(1, feminine: false) == "один" && NumberWords.say(1, feminine: false, neuter: true) == "одно")
        #expect(NumberWords.say(2, feminine: true) == "две" && NumberWords.say(2, feminine: false) == "два")
        #expect(NumberWords.say(14, feminine: false) == "четырнадцать")
        #expect(NumberWords.say(21, feminine: true) == "двадцать одна")
        #expect(NumberWords.say(99, feminine: false) == "девяносто девять")
    }
}

@Suite("LocalIntentRouter")
struct LocalIntentRouterTests {
    private let router = LocalIntentRouter()

    @Test(arguments: [
        "скажи что на сегодня", "что на сегодня", "Что у меня на сегодня?", "какие планы на сегодня", "что сегодня",
        "что у меня сегодня", "расскажи что на сегодня", "покажи что на сегодня", "скажи, что у меня сегодня запланировано",
        "сегодня", "дела на сегодня", "мои дела на сегодня", "пожалуйста, скажи что на сегодня", "ну что там на сегодня",
        "что у меня сегодня по плану",
    ])
    func todayQuestions(phrase: String) {
        #expect(router.route(phrase, today: today) == QueryPlan(target: day(0)), "phrase '\(phrase)'")
    }

    @Test(arguments: [
        "что у меня завтра", "что на завтра", "скажи что на завтра", "какие планы на завтра", "завтра", "Что завтра?",
        "покажи дела на завтра", "какие у меня дела завтра",
    ])
    func tomorrowQuestions(phrase: String) {
        #expect(router.route(phrase, today: today) == QueryPlan(target: day(1)), "phrase '\(phrase)'")
    }

    @Test func dayAfterTomorrowWeekAndNextWeek() {
        #expect(router.route("что у меня послезавтра", today: today) == QueryPlan(target: day(2)))
        #expect(router.route("что на этой неделе", today: today) == QueryPlan(target: .days(today ... LocalDate("2026-10-04")!)))
        #expect(router.route("какие планы на неделе", today: today) == QueryPlan(target: .days(today ... LocalDate("2026-10-04")!)))
        #expect(router.route("что на следующей неделе", today: today) == QueryPlan(target: .days(LocalDate("2026-10-05")! ... LocalDate("2026-10-11")!)))
    }

    @Test func upcomingAndOverdue() {
        for phrase in ["что дальше", "что у меня дальше", "дальше", "что потом", "какое следующее"] {
            #expect(router.route(phrase, today: today) == QueryPlan(target: .upcoming(limit: 5)), "phrase '\(phrase)'")
        }
        for phrase in ["что просрочено", "какие просроченные", "просрочено"] {
            #expect(router.route(phrase, today: today) == QueryPlan(target: .overdue), "phrase '\(phrase)'")
        }
    }

    @Test(arguments: [
        "напомни мне завтра позвонить", "завтра в 11 созвон", "перенеси встречу на завтра", "что у меня завтра с Дмитрием",
        "удали всё на завтра", "что делать завтра", "сегодня вечером позвонить маме", "запиши идею", "найди всё про Акме",
        "отметь выполненным на сегодня", "что на сегодня по Notion", "скажи что на сегодня и завтра и послезавтра тоже пожалуйста",
        "", "э-э ну", "в пятницу", "что нового",
    ])
    func everythingElseGoesToTheModel(phrase: String) {
        #expect(router.route(phrase, today: today) == nil, "phrase '\(phrase)'")
    }
}
