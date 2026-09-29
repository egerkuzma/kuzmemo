import Foundation

/// The speakers of Silero's Russian model (v4_ru) and how the app's speaking rate maps to its SSML prosody.
public enum SileroVoice {
    public struct Speaker: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// The voice another project uses.
    public static let defaultSpeaker = "eugene"

    public static let speakers: [Speaker] = [
        Speaker(id: "eugene", title: "eugene · мужской"), Speaker(id: "aidar", title: "aidar · мужской"),
        Speaker(id: "xenia", title: "xenia · женский"), Speaker(id: "kseniya", title: "kseniya · женский"),
        Speaker(id: "baya", title: "baya · женский"),
    ]

    /// SSML `prosody rate` values, slowest first.
    public enum Rate: String, CaseIterable, Sendable {
        case extraSlow = "x-slow", slow, medium, fast, extraFast = "x-fast"

        /// The app's rate (0.2...0.7, 0.5 is normal) as the nearest Silero step.
        public init(speechRate: Double) {
            switch speechRate {
            case ..<0.36: self = .extraSlow
            case ..<0.45: self = .slow
            case ..<0.54: self = .medium
            case ..<0.62: self = .fast
            default: self = .extraFast
            }
        }
    }
}
