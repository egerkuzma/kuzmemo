/// ISO weekday: Monday is 1, Sunday is 7. Encoded as the three-letter lowercase code used by the
/// Claude response schema ("mon" ... "sun").
public enum Weekday: Int, Codable, Sendable, CaseIterable, Comparable {
    case mon = 1, tue, wed, thu, fri, sat, sun

    public var code: String {
        switch self {
        case .mon: "mon"
        case .tue: "tue"
        case .wed: "wed"
        case .thu: "thu"
        case .fri: "fri"
        case .sat: "sat"
        case .sun: "sun"
        }
    }

    public init?(code: String) {
        guard let match = Weekday.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard let day = Weekday(code: code) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown weekday code '\(code)'")
        }
        self = day
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}
