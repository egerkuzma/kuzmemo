import Foundation

/// Text made ready for a neural voice. Silero reads Cyrillic words only: digits, Latin letters and most symbols are
/// silently skipped (the Russian "Встреча с Notion в 15:00." would come out as "Встреча с в", "Meeting with at"). So
/// numbers, times, percentages, currencies and dates are spelled out, Latin words are transliterated (acronyms are
/// spelled letter by letter) and symbols that nobody pronounces are dropped. The system voice reads all of this by
/// itself and does not need it.
public enum SpeechText {
    public static func forNeuralVoice(_ text: String) -> String {
        var result = text
        result = result.replacingMatches(#"https?://\S+|www\.\S+"#) { _, _ in "ссылка" }
        result = result.replacingMatches(#"\bт\.\s?е\."#) { _, _ in "то есть" }
        result = result.replacingMatches(#"\bт\.\s?д\."#) { _, _ in "и так далее" }
        result = separateLatinFromDigits(result)
        result = spellTimes(result)
        result = spellMoneyAndPercent(result)
        result = spellDates(result)
        result = spellNumbers(result)
        result = spellLatin(result)
        result = result.replacingMatches(#"\s*&\s*"#) { _, _ in " и " }
        result = result.replacingMatches(#"\s\+\s"#) { _, _ in " плюс " }
        result = result.replacingMatches("№") { _, _ in " номер " }
        result = result.replacingMatches(#"[*_#~^|\\\[\]{}<>@=`"“”„«»'’]"#) { _, _ in " " }
        result = result.replacingMatches(#"\s*/\s*"#) { _, _ in " " }
        result = result.replacingMatches(#"[\p{So}\p{Sk}\p{Cs}\x{FE0F}\x{200D}]"#) { _, _ in " " } // emoji and pictographs
        result = result.replacingMatches(#"\s*\(\s*"#) { _, _ in ", " }
        result = result.replacingMatches(#"\s*\)\s*"#) { _, _ in ", " }
        result = result.replacingMatches(#"[ \t\x{00A0}]+"#) { _, _ in " " }
        result = result.replacingMatches(#"\s+([,.!?;:…])"#) { m, s in s.group(1, of: m) }
        result = result.replacingMatches(#",\s*,"#) { _, _ in "," }
        // a bracket that ends right before, or right after, a full stop leaves no stray comma: "(срочно!)" ("(urgent!)"), "(в банк)." ("(to the bank).")
        result = result.replacingMatches(#"([.!?…;:]),"#) { match, source in source.group(1, of: match) }
        result = result.replacingMatches(#",\s*([.!?…;:])"#) { match, source in source.group(1, of: match) }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.replacingMatches(#"[,;:]+$"#) { _, _ in "" }
    }

    /// "Q4" and "3D" are two words to a voice: a space goes where a Latin letter touches a digit, so the number and the
    /// letter name do not run together ("кьючетыре").
    static func separateLatinFromDigits(_ text: String) -> String {
        text.replacingMatches(#"(?<=[A-Za-z])(?=\d)|(?<=\d)(?=[A-Za-z])"#) { _, _ in " " }
    }

    // MARK: - Times: 15:30 → "пятнадцать тридцать" (fifteen thirty), 10:00 → "десять часов" (ten o'clock)

    static func spellTimes(_ text: String) -> String {
        text.replacingMatches(#"(?<![\d:.,])(\d{1,2}):(\d{2})(?![\d:])"#) { match, source in
            guard let hour = Int(source.group(1, of: match)), let minute = Int(source.group(2, of: match)),
                  hour < 24, minute < 60 else { return source.group(0, of: match) }
            let hours = RussianNumberWords.cardinal(hour)
            if minute == 0 { return "\(hours) \(RussianFormat.plural(hour, ("час", "часа", "часов")))" }
            return "\(hours) \(minute < 10 ? "ноль " : "")\(RussianNumberWords.cardinal(minute))"
        }
    }

    // MARK: - 20% · $340 · 340 $ · 5 мин

    static func spellMoneyAndPercent(_ text: String) -> String {
        var result = text
        // "$340", "€ 15"
        result = result.replacingMatches(#"([$€₽])\s?(\d+(?:[.,]\d+)?)"#) { match, source in
            words(source.group(2, of: match), unit: Self.currency(source.group(1, of: match)))
        }
        // "340$", "340 %", "15 руб."
        result = result.replacingMatches(#"(\d+(?:[.,]\d+)?)\s?([$€₽%])"#) { match, source in
            let symbol = source.group(2, of: match)
            return words(source.group(1, of: match), unit: symbol == "%" ? ("процент", "процента", "процентов") : Self.currency(symbol))
        }
        for (abbreviation, forms) in Self.abbreviations {
            result = result.replacingMatches(#"(?<![\d.,])(\d+)\s?"# + abbreviation + #"\.?(?![\p{L}])"#) { match, source in
                words(source.group(1, of: match), unit: forms)
            }
        }
        return result
    }

    private static func currency(_ symbol: String) -> (String, String, String) {
        switch symbol {
        case "$": ("доллар", "доллара", "долларов")
        case "€": ("евро", "евро", "евро")
        default: ("рубль", "рубля", "рублей")
        }
    }

    private static let abbreviations: [(String, (String, String, String))] = [
        ("мин", ("минуту", "минуты", "минут")), ("сек", ("секунду", "секунды", "секунд")), ("ч", ("час", "часа", "часов")),
        ("руб", ("рубль", "рубля", "рублей")), ("тыс", ("тысяча", "тысячи", "тысяч")), ("млн", ("миллион", "миллиона", "миллионов")),
        ("млрд", ("миллиард", "миллиарда", "миллиардов")), ("шт", ("штука", "штуки", "штук")),
    ]

    /// "340" + dollars → "триста сорок долларов" (three hundred forty dollars); "3,5" + percent → "три запятая пять
    /// процента" (three point five percent).
    private static func words(_ number: String, unit: (String, String, String)) -> String {
        let parts = number.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let whole = Int(parts[0]) else { return number }
        if parts.count == 2, !parts[1].isEmpty {
            return "\(RussianNumberWords.cardinal(whole)) запятая \(fraction(parts[1])) \(unit.1)"
        }
        return "\(RussianNumberWords.cardinal(whole)) \(RussianFormat.plural(whole, unit))"
    }

    private static func fraction(_ digits: String) -> String {
        var zeros: [String] = []
        var rest = Substring(digits)
        while rest.first == "0", rest.count > 1 { zeros.append("ноль"); rest = rest.dropFirst() }
        let value = Int(rest) ?? 0
        return (zeros + [RussianNumberWords.cardinal(value)]).joined(separator: " ")
    }

    // MARK: - Dates: "25 сентября" → "двадцать пятого сентября" (the twenty-fifth of September), "25 числа", "25-го"

    private static let monthsGenitive = "января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря"

    static func spellDates(_ text: String) -> String {
        text.replacingMatches(#"(?<![\d.,:])(\d{1,2})(?:-го)?\s+(числа|"# + monthsGenitive + #")"#) { match, source in
            guard let day = Int(source.group(1, of: match)), (1 ... 31).contains(day) else { return source.group(0, of: match) }
            return "\(RussianNumberWords.ordinalGenitive(day)) \(source.group(2, of: match))"
        }
        .replacingMatches(#"(?<![\d.,:])(\d{1,2})-го(?![\p{L}])"#) { match, source in
            guard let day = Int(source.group(1, of: match)), (1 ... 31).contains(day) else { return source.group(0, of: match) }
            return RussianNumberWords.ordinalGenitive(day)
        }
    }

    // MARK: - Plain numbers

    static func spellNumbers(_ text: String) -> String {
        // "10 000" and "1 000 000" (groups of three) are one number
        let grouped = text.replacingMatches(#"(?<![\d.,])(\d{1,3}(?:[ \x{00A0}\x{202F}]\d{3})+)(?![\d])"#) { match, source in
            source.group(1, of: match).filter(\.isNumber)
        }
        return grouped.replacingMatches(#"(?<![\d.,])(\d+)(?:[.,](\d+))?(?![\d])"#) { match, source in
            let whole = source.group(1, of: match)
            let decimals = source.group(2, of: match)
            guard whole.count <= 12, let value = Int(whole) else { return RussianNumberWords.digitByDigit(whole) }
            var out = RussianNumberWords.cardinal(value, gender: gender(for: value, following: source.word(after: match)))
            if !decimals.isEmpty { out += " запятая " + fraction(decimals) }
            return out
        }
    }

    /// The Russian numerals one and two have genders: "1 минута" → одна, "2 недели" → две, "1 окно" → одно. The gender is
    /// read from the ending of the word that follows.
    private static func gender(for value: Int, following word: String) -> RussianNumberWords.Gender {
        guard let last = word.lowercased().last else { return .masculine }
        if value % 10 == 1, value % 100 != 11 {
            if last == "а" || last == "я" { return .feminine }
            if last == "о" || last == "е" { return .neuter }
        }
        if value % 10 == 2, value % 100 != 12, last == "ы" || last == "и" { return .feminine }
        return .masculine
    }

    // MARK: - Latin letters

    static func spellLatin(_ text: String) -> String {
        text.replacingMatches(#"[A-Za-z][A-Za-z'’]*"#) { match, source in
            let word = source.group(0, of: match)
            let letters = word.filter(\.isLetter)
            if letters.count >= 1, letters.count <= 5, letters == letters.uppercased(), letters.count == word.count {
                return letters.map { Self.letterNames[$0.lowercased().first ?? " "] ?? String($0) }.joined(separator: " ")
            }
            return transliterate(word.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: ""))
        }
    }

    private static let letterNames: [Character: String] = [
        "a": "эй", "b": "би", "c": "си", "d": "ди", "e": "и", "f": "эф", "g": "джи", "h": "эйч", "i": "ай", "j": "джей",
        "k": "кей", "l": "эл", "m": "эм", "n": "эн", "o": "оу", "p": "пи", "q": "кью", "r": "ар", "s": "эс", "t": "ти",
        "u": "ю", "v": "ви", "w": "дабл ю", "x": "экс", "y": "уай", "z": "зед",
    ]

    /// A rough English-to-Russian reading: good enough to be understood, not to be correct ("notion" → "нотион").
    /// Brand names should have a spoken form in the glossary; this is the fallback for everything else.
    static func transliterate(_ word: String) -> String {
        let pairs: [(String, String)] = [
            ("sch", "ск"), ("tch", "ч"), ("igh", "ай"), ("sh", "ш"), ("ch", "ч"), ("th", "т"), ("ph", "ф"), ("kh", "х"), ("zh", "ж"),
            ("ck", "к"), ("qu", "кв"), ("ee", "и"), ("oo", "у"), ("ea", "и"), ("ai", "эй"), ("ay", "эй"), ("ou", "ау"), ("oa", "оу"),
            ("ie", "и"), ("ng", "нг"), ("wh", "в"),
        ]
        let singles: [Character: String] = [
            "a": "а", "b": "б", "d": "д", "f": "ф", "g": "г", "h": "х", "i": "и", "j": "дж", "k": "к", "l": "л", "m": "м", "n": "н",
            "o": "о", "p": "п", "q": "к", "r": "р", "s": "с", "t": "т", "u": "у", "v": "в", "w": "в", "x": "кс", "z": "з",
        ]
        let vowels = Set("aeiouy")
        let letters = Array(word)
        var out = ""
        var index = 0
        while index < letters.count {
            let rest = String(letters[index...])
            if let pair = pairs.first(where: { rest.hasPrefix($0.0) }) {
                out += pair.1
                index += pair.0.count
                continue
            }
            let letter = letters[index]
            let previous = index > 0 ? letters[index - 1] : nil
            let next = index + 1 < letters.count ? letters[index + 1] : nil
            switch letter {
            case "c": out += (next.map { "eiy".contains($0) } ?? false) ? "с" : "к"
            case "e":
                if index == letters.count - 1, letters.count > 3, let previous, !vowels.contains(previous) { break } // silent final e
                out += index == 0 ? "э" : "е"
            case "y": out += (index == 0 || (previous.map { vowels.contains($0) } ?? false)) ? "й" : "и"
            default: out += singles[letter] ?? String(letter)
            }
            index += 1
        }
        return out
    }
}

// MARK: - Russian number words

enum RussianNumberWords {
    enum Gender { case masculine, feminine, neuter }

    private static let units = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let teens = [
        "десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать",
        "восемнадцать", "девятнадцать",
    ]
    private static let tens = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"]
    private static let hundreds = ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"]

    /// Cardinal numbers up to the billions ("триста сорок", "две тысячи двадцать шесть"). `gender` is that of the
    /// noun that follows and only matters for a final 1 or 2.
    static func cardinal(_ number: Int, gender: Gender = .masculine) -> String {
        if number == 0 { return units[0] }
        guard number > 0, number < 1_000_000_000_000 else { return String(number).map { units[Int(String($0)) ?? 0] }.joined(separator: " ") }
        var parts: [String] = []
        let scales: [(divisor: Int, forms: (String, String, String), gender: Gender)] = [
            (1_000_000_000, ("миллиард", "миллиарда", "миллиардов"), .masculine),
            (1_000_000, ("миллион", "миллиона", "миллионов"), .masculine),
            (1_000, ("тысяча", "тысячи", "тысяч"), .feminine),
        ]
        var rest = number
        for scale in scales {
            let group = rest / scale.divisor
            rest %= scale.divisor
            guard group > 0 else { continue }
            // a bare thousand is "тысяча", not "одна тысяча"
            if scale.divisor == 1_000, group == 1 { parts.append(scale.forms.0); continue }
            parts.append(below1000(group, gender: scale.gender))
            parts.append(RussianFormat.plural(group, scale.forms))
        }
        if rest > 0 { parts.append(below1000(rest, gender: gender)) }
        return parts.joined(separator: " ")
    }

    private static func below1000(_ number: Int, gender: Gender) -> String {
        var parts: [String] = []
        if number >= 100 { parts.append(hundreds[number / 100]) }
        let rest = number % 100
        if rest >= 20 {
            parts.append(tens[rest / 10])
            if rest % 10 > 0 { parts.append(unit(rest % 10, gender: gender)) }
        } else if rest >= 10 {
            parts.append(teens[rest - 10])
        } else if rest > 0 {
            parts.append(unit(rest, gender: gender))
        }
        return parts.joined(separator: " ")
    }

    private static func unit(_ digit: Int, gender: Gender) -> String {
        switch (digit, gender) {
        case (1, .feminine): "одна"
        case (1, .neuter): "одно"
        case (2, .feminine): "две"
        default: units[digit]
        }
    }

    private static let ordinalUnits = ["", "первого", "второго", "третьего", "четвёртого", "пятого", "шестого", "седьмого", "восьмого", "девятого"]
    private static let ordinalTeens = [
        "десятого", "одиннадцатого", "двенадцатого", "тринадцатого", "четырнадцатого", "пятнадцатого", "шестнадцатого",
        "семнадцатого", "восемнадцатого", "девятнадцатого",
    ]

    /// The day of a month as "of the …": 1 → "первого", 25 → "двадцать пятого", 30 → "тридцатого".
    static func ordinalGenitive(_ day: Int) -> String {
        switch day {
        case 1 ... 9: ordinalUnits[day]
        case 10 ... 19: ordinalTeens[day - 10]
        case 20: "двадцатого"
        case 30: "тридцатого"
        case 21 ... 29, 31: tens[day / 10] + " " + ordinalUnits[day % 10]
        default: cardinal(day)
        }
    }

    /// A long digit string (a phone number, an id) read one digit at a time.
    static func digitByDigit(_ digits: String) -> String {
        digits.compactMap { Int(String($0)) }.map { units[$0] }.joined(separator: " ")
    }
}

// MARK: - Small regex helpers

private extension String {
    /// Replaces every match of `pattern` with what `transform` returns (it gets the match and this string).
    func replacingMatches(_ pattern: String, transform: (NSTextCheckingResult, String) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return self }
        let source = self as NSString
        var result = ""
        var last = 0
        for match in expression.matches(in: self, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform(match, self)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    /// The text of capture group `index` (empty if it did not take part in the match).
    func group(_ index: Int, of match: NSTextCheckingResult) -> String {
        let range = match.range(at: index)
        guard range.location != NSNotFound else { return "" }
        return (self as NSString).substring(with: range)
    }

    /// The first word of letters after the match ("" when there is none).
    func word(after match: NSTextCheckingResult) -> String {
        let source = self as NSString
        let tail = source.substring(from: match.range.location + match.range.length)
        guard let found = tail.range(of: #"^\s*([\p{L}]+)"#, options: .regularExpression) else { return "" }
        return tail[found].trimmingCharacters(in: .whitespaces)
    }
}
