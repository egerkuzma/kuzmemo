import GRDB

public enum ItemKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case reminder, event, task, note
}

public enum ItemStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case open, done
}

public enum ItemSource: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case voice, quickadd, manual, mcp
}

public enum MemoStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case recorded, transcribing, transcribed, thinking, interpreted, applied, answered, clarifying, failed, discarded
}

public enum MemoInputKind: String, Codable, Sendable, DatabaseValueConvertible {
    case voice, text
}
