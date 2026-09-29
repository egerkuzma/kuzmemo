import Foundation
import Testing
@testable import KuzmemoCore

@Suite("SpeechText (text for the Silero voice)")
struct SpeechTextTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var input: String
        var expected: String
        var testDescription: String { input }
    }

    @Test func numbersAreSpelledOut() {
        let cases: [(Int, String)] = [
            (0, "ноль"), (1, "один"), (2, "два"), (12, "двенадцать"), (21, "двадцать один"), (25, "двадцать пять"),
            (340, "триста сорок"), (1000, "тысяча"), (1001, "тысяча один"), (2000, "две тысячи"),
            (2026, "две тысячи двадцать шесть"), (21_000, "двадцать одна тысяча"), (1_000_000, "один миллион"),
            (5_500_000, "пять миллионов пятьсот тысяч"), (12_345, "двенадцать тысяч триста сорок пять"),
        ]
        for (number, words) in cases { #expect(RussianNumberWords.cardinal(number) == words, "\(number)") }
        #expect(RussianNumberWords.cardinal(2, gender: .feminine) == "две" && RussianNumberWords.cardinal(21, gender: .feminine) == "двадцать одна")
        #expect(RussianNumberWords.cardinal(1, gender: .neuter) == "одно")
    }

    @Test func datesUseTheGenitiveOrdinal() {
        #expect(RussianNumberWords.ordinalGenitive(1) == "первого" && RussianNumberWords.ordinalGenitive(25) == "двадцать пятого")
        #expect(RussianNumberWords.ordinalGenitive(30) == "тридцатого" && RussianNumberWords.ordinalGenitive(31) == "тридцать первого")
        #expect(RussianNumberWords.ordinalGenitive(4) == "четвёртого" && RussianNumberWords.ordinalGenitive(13) == "тринадцатого")
    }

    @Test(arguments: [
        Case(input: "Оплатить хостинг: 340 долларов", expected: "Оплатить хостинг: триста сорок долларов"),
        Case(input: "Встреча в 15:30", expected: "Встреча в пятнадцать тридцать"),
        Case(input: "созвон в 10:00", expected: "созвон в десять часов"),
        Case(input: "в 9:05", expected: "в девять ноль пять"),
        Case(input: "в 1:00", expected: "в один час"),
        Case(input: "в 22:00", expected: "в двадцать два часа"),
        Case(input: "20%", expected: "двадцать процентов"),
        Case(input: "1%", expected: "один процент"),
        Case(input: "3,5%", expected: "три запятая пять процента"),
        Case(input: "$340", expected: "триста сорок долларов"),
        Case(input: "340$", expected: "триста сорок долларов"),
        Case(input: "15 €", expected: "пятнадцать евро"),
        Case(input: "500 ₽", expected: "пятьсот рублей"),
        Case(input: "1 $", expected: "один доллар"),
        Case(input: "25 сентября", expected: "двадцать пятого сентября"),
        Case(input: "1 октября", expected: "первого октября"),
        Case(input: "оплатить 25 числа", expected: "оплатить двадцать пятого числа"),
        Case(input: "до 25-го", expected: "до двадцать пятого"),
        Case(input: "1 минута", expected: "одна минута"),
        Case(input: "2 недели", expected: "две недели"),
        Case(input: "2 часа", expected: "два часа"),
        Case(input: "21 день", expected: "двадцать один день"),
        Case(input: "1 окно", expected: "одно окно"),
        Case(input: "5 минут", expected: "пять минут"),
        Case(input: "5 мин", expected: "пять минут"),
        Case(input: "2 ч", expected: "два часа"),
        Case(input: "10 сек.", expected: "десять секунд"),
        Case(input: "10 000 долларов", expected: "десять тысяч долларов"),
        Case(input: "1 000 000", expected: "один миллион"),
        Case(input: "0,05", expected: "ноль запятая ноль пять"),
        Case(input: "1234567890123", expected: "один два три четыре пять шесть семь восемь девять ноль один два три"),
    ])
    func numbersInText(c: Case) {
        #expect(SpeechText.forNeuralVoice(c.input) == c.expected)
    }

    @Test(arguments: [
        Case(input: "Встреча с Notion", expected: "Встреча с нотион"),
        Case(input: "Zoom", expected: "зум"),
        Case(input: "Slack", expected: "слак"),
        Case(input: "Q4", expected: "кью четыре"),
        Case(input: "3D и 5G", expected: "три ди и пять джи"),
        Case(input: "план B", expected: "план би"),
        Case(input: "API", expected: "эй пи ай"),
        Case(input: "смотри CPM и CTR", expected: "смотри си пи эм и си ти ар"),
        Case(input: "Tom & Jerry", expected: "том и джерри"),
    ])
    func latinIsTransliterated(c: Case) {
        #expect(SpeechText.forNeuralVoice(c.input) == c.expected)
    }

    @Test func aWholePhraseComesOutInCyrillicOnly() {
        #expect(SpeechText.forNeuralVoice("Встреча с Notion в 15:00.") == "Встреча с нотион в пятнадцать часов.")
        let messy = "Напомнить (срочно!) про **Notion** — 3 раза за 2 дня 🙂 https://example.com/x/y"
        let spoken = SpeechText.forNeuralVoice(messy)
        #expect(spoken == "Напомнить, срочно! про нотион — три раза за два дня ссылка")
        #expect(spoken.unicodeScalars.allSatisfy { !($0.properties.isEmoji && $0.value > 0x2000) })
    }

    @Test func cyrillicTextIsLeftAlone() {
        let phrase = "Сегодня у тебя три дела: планёрка, созвон и статистика."
        #expect(SpeechText.forNeuralVoice(phrase) == phrase)
    }

    @Test func silenceStaysSilence() {
        #expect(SpeechText.forNeuralVoice("  🙂 ** ").isEmpty)
    }

    @Test func theSpeakingRateMapsToTheNearestSileroStep() {
        typealias Rate = SileroVoice.Rate
        #expect(Rate(speechRate: 0.5) == .medium && Rate(speechRate: 0.3) == .extraSlow && Rate(speechRate: 0.4) == .slow)
        #expect(Rate(speechRate: 0.56) == .fast && Rate(speechRate: 0.65) == .extraFast)
    }

    @Test func engineSettingsAreReadForgivingly() throws {
        let decode = { (json: String) throws -> SpeechSettings in try JSONDecoder().decode(SpeechSettings.self, from: Data(json.utf8)) }
        #expect(try decode("{}").engine == .system && decode("{}").sileroSpeaker == "eugene")
        #expect(try decode(#"{"engine":"silero","sileroSpeaker":"xenia","sileroPython":"/opt/py/bin/python"}"#).engine == .silero)
        #expect(try decode(#"{"engine":"warp-drive"}"#).engine == .system)
        #expect(try decode(#"{"sileroSpeaker":"  "}"#).sileroSpeaker == "eugene")
        #expect(try decode(#"{"sileroPython":""}"#).sileroPython == nil)
        // an older saved value (before the engine existed) keeps working
        #expect(try decode(#"{"rate":0.4,"speakAnswers":false}"#).rate == 0.4)
    }

    @Test func theCloneEngineAndItsStepsAreReadForgivingly() throws {
        let decode = { (json: String) throws -> SpeechSettings in try JSONDecoder().decode(SpeechSettings.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"engine":"clone"}"#).engine == .clone)
        #expect(try decode("{}").cloneSteps == 16)
        #expect(try decode(#"{"cloneSteps":12}"#).cloneSteps == 12)
        #expect(try decode(#"{"cloneSteps":1}"#).cloneSteps == 8 && decode(#"{"cloneSteps":500}"#).cloneSteps == 32) // kept in range
    }
}

extension SpeechTextTests {
    @Test func bracketsBecomePausesWithoutStrayCommas() {
        #expect(SpeechText.forNeuralVoice("Напомнить (срочно)") == "Напомнить, срочно")
        #expect(SpeechText.forNeuralVoice("Позвонить (в банк). Потом отчёт.") == "Позвонить, в банк. Потом отчёт.")
    }
}
