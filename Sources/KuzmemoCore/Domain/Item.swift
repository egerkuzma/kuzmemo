import Foundation
import GRDB

/// A calendar entry: reminder, event, task or note. Wall-clock dates are floating; elapsed-time requests also keep their instant.
public struct Item: Codable, Hashable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "items"

    public var id: String
    public var kind: ItemKind
    public var title: String
    public var details: String?
    public var keywords: String
    /// `nil` puts the item in the Inbox (undated).
    public var date: LocalDate?
    /// `nil` means all-day / date-only.
    public var time: LocalTime?
    /// Epoch milliseconds for an elapsed-time request (for example "in 30 minutes"); otherwise nil.
    public var scheduledAt: Int64?
    public var durationMin: Int?
    /// IANA identifier when pinned to a zone; `nil` means floating (device time zone).
    public var tz: String?
    public var approximate: Bool
    public var recurrence: Recurrence?
    public var remindLeadMin: Int
    public var status: ItemStatus
    public var doneAt: Int64?
    public var source: ItemSource
    public var memoID: String?
    public var version: Int
    /// Epoch milliseconds (UTC).
    public var createdAt: Int64
    public var updatedAt: Int64
    public var deletedAt: Int64?

    public init(
        id: String, kind: ItemKind, title: String, details: String? = nil, keywords: String = "",
        date: LocalDate? = nil, time: LocalTime? = nil, durationMin: Int? = nil, tz: String? = nil,
        approximate: Bool = false, recurrence: Recurrence? = nil, remindLeadMin: Int = 0,
        status: ItemStatus = .open, doneAt: Int64? = nil, source: ItemSource = .manual, memoID: String? = nil,
        version: Int = 1, createdAt: Int64 = 0, updatedAt: Int64 = 0, deletedAt: Int64? = nil, scheduledAt: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.details = details
        self.keywords = keywords
        self.date = date
        self.time = time
        self.scheduledAt = scheduledAt
        self.durationMin = durationMin
        self.tz = tz
        self.approximate = approximate
        self.recurrence = recurrence
        self.remindLeadMin = remindLeadMin
        self.status = status
        self.doneAt = doneAt
        self.source = source
        self.memoID = memoID
        self.version = version
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, details, keywords, date, time
        case scheduledAt = "scheduled_at"
        case durationMin = "duration_min"
        case tz, approximate
        case recurrence = "recurrence_json"
        case remindLeadMin = "remind_lead_min"
        case status
        case doneAt = "done_at"
        case source
        case memoID = "memo_id"
        case version
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public var isDeleted: Bool { deletedAt != nil }
    public var isRecurring: Bool { recurrence != nil }

    func shown(in zone: TimeZone) -> Item {
        guard let scheduledAt, date != nil, time != nil else { return self }
        var shown = self
        let moment = LocalDateTime(date: Date(timeIntervalSince1970: TimeInterval(scheduledAt) / 1000), in: zone)
        shown.date = moment.date
        shown.time = moment.time
        return shown
    }
}

/// A per-occurrence override for a recurring item (done, skipped or moved).
public struct ItemException: Codable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "item_exceptions"

    public enum Action: String, Codable, Sendable, DatabaseValueConvertible {
        case done, skip, moved
    }

    public var itemID: String
    public var occDate: LocalDate
    public var action: Action
    public var movedDate: LocalDate?
    public var movedTime: LocalTime?
    /// nil/false inherits the series time; true explicitly makes this occurrence all-day.
    public var timeCleared: Bool?
    public var scheduledAt: Int64?

    public init(itemID: String, occDate: LocalDate, action: Action, movedDate: LocalDate? = nil, movedTime: LocalTime? = nil, timeCleared: Bool? = nil, scheduledAt: Int64? = nil) {
        self.itemID = itemID
        self.occDate = occDate
        self.action = action
        self.movedDate = movedDate
        self.movedTime = movedTime
        self.timeCleared = timeCleared
        self.scheduledAt = scheduledAt
    }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case occDate = "occ_date"
        case action
        case movedDate = "moved_date"
        case movedTime = "moved_time"
        case timeCleared = "time_cleared"
        case scheduledAt = "scheduled_at"
    }
}
