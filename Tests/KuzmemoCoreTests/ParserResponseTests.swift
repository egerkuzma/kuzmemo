import Foundation
import Testing
@testable import KuzmemoCore

private func decode(_ json: String) throws -> ParserResponse {
    try JSONDecoder().decode(ParserResponse.self, from: Data(json.utf8))
}

@Suite("ParserResponse decoding")
struct ParserResponseTests {
    // Real answers recorded from `claude -p` during the M0 spike.
    static let create = #"{"intent":"create","confidence":0.95,"actions":[{"op":"create","item":{"kind":"reminder","title":"Сказать Дмитрию про доступ в Notion","when":{"mode":"days_from_today","days_from_today":2,"phrase":"послезавтра"}}}]}"#
    static let query = #"{"intent":"query","confidence":0.98,"query":{"scope":"day","when":{"mode":"days_from_today","days_from_today":0,"phrase":"сегодня"},"detail":"digest"}}"#
    static let clarify = #"{"intent":"clarify","confidence":0.85,"clarification":{"question":"Какую пятницу имеете в виду?","reason":"ambiguous_date","options":["Ближайшая пятница, 2 октября","Пятница следующей недели, 9 октября"]},"speech":"Какую пятницу имеете в виду?"}"#

    @Test func decodesACreateAnswer() throws {
        let response = try decode(Self.create)
        #expect(response.intent == .create && response.confidence == 0.95)
        let action = try #require(response.actions?.first)
        #expect(action.op == .create)
        let item = try #require(action.item)
        #expect(item.kind == .reminder && item.title == "Сказать Дмитрию про доступ в Notion")
        #expect(item.when?.mode == .daysFromToday && item.when?.daysFromToday == 2 && item.when?.phrase == "послезавтра")
        #expect(item.when?.time == nil)
    }

    @Test func decodesAQueryAnswer() throws {
        let response = try decode(Self.query)
        #expect(response.intent == .query && response.actions == nil)
        #expect(response.query?.scope == .day && response.query?.detail == .digest)
        #expect(response.query?.when?.daysFromToday == 0)
    }

    @Test func decodesAClarificationWithOptions() throws {
        let response = try decode(Self.clarify)
        #expect(response.intent == .clarify)
        #expect(response.clarification?.reason == .ambiguousDate)
        #expect(response.clarification?.options?.count == 2)
        #expect(response.speech == "Какую пятницу имеете в виду?")
    }

    @Test func decodesRecurringEventsAndUpdates() throws {
        let recurring = try decode(#"{"intent":"create","confidence":0.93,"actions":[{"op":"create","item":{"kind":"event","title":"Планёрка","when":{"mode":"weekday","weekday":"mon","week_offset":0,"time":"10:00","phrase":"каждый понедельник в десять"},"recurrence":{"freq":"weekly","interval":1,"by_weekday":["mon"]}}}]}"#)
        let item = try #require(recurring.actions?.first?.item)
        #expect(item.recurrence == Recurrence(freq: .weekly, interval: 1, byWeekday: [.mon]))
        #expect(item.when?.weekday == .mon && item.when?.time == LocalTime("10:00"))

        let update = try decode(#"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":3,"changes":{"when":{"mode":"weekday","weekday":"thu","week_offset":0,"phrase":"на четверг"}}}]}"#)
        let action = try #require(update.actions?.first)
        #expect(action.op == .update && action.ref == 3 && action.changes?.when?.weekday == .thu)

        let skip = try decode(#"{"intent":"delete","confidence":0.8,"actions":[{"op":"skip_occurrence","ref":1,"occurrence_date":"2026-10-12"}]}"#)
        #expect(skip.actions?.first?.op == .skipOccurrence && skip.actions?.first?.occurrenceDate == LocalDate("2026-10-12"))
    }

    @Test func decodesUnknownAndMinimalAnswers() throws {
        let unknown = try decode(#"{"intent":"unknown","confidence":0.9}"#)
        #expect(unknown.intent == .unknown && unknown.actions == nil && unknown.query == nil)
    }

    @Test func rejectsUnknownEnumValuesAndBadDates() {
        #expect(throws: (any Error).self) { try decode(#"{"intent":"schedule","confidence":0.9}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"intent":"create","confidence":0.9,"actions":[{"op":"remove"}]}"#) }
        #expect(throws: (any Error).self) { try decode(#"{"intent":"create"}"#) } // confidence is required
        #expect(throws: (any Error).self) {
            try decode(#"{"intent":"create","confidence":1,"actions":[{"op":"skip_occurrence","occurrence_date":"12.10.2026"}]}"#)
        }
    }

    @Test func schemaIsValidJSONWithTheExpectedShape() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(ResponseSchema.json.utf8)) as? [String: Any])
        #expect(object["required"] as? [String] == ["intent", "confidence"])
        #expect(object["additionalProperties"] as? Bool == false)
        let definitions = try #require(object["definitions"] as? [String: Any])
        for name in ["weekday", "when", "recurrence", "item", "changes", "action", "query", "clarification"] {
            #expect(definitions[name] != nil, "definition \(name)")
        }
        #expect(!ResponseSchema.compact.contains("\n"))
        #expect(ResponseSchema.compact.utf8.count < 4000)
    }

    @Test func schemaEnumsMatchTheSwiftEnums() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(ResponseSchema.json.utf8)) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let intent = try #require((properties["intent"] as? [String: Any])?["enum"] as? [String])
        #expect(Set(intent) == ["create", "query", "update", "delete", "clarify", "unknown"])
        let definitions = try #require(object["definitions"] as? [String: Any])
        let action = try #require(definitions["action"] as? [String: Any])
        let op = try #require(((action["properties"] as? [String: Any])?["op"] as? [String: Any])?["enum"] as? [String])
        #expect(Set(op) == ["create", "update", "complete", "reopen", "delete", "skip_occurrence"])
        let clarification = try #require(definitions["clarification"] as? [String: Any])
        let reasons = try #require(((clarification["properties"] as? [String: Any])?["reason"] as? [String: Any])?["enum"] as? [String])
        #expect(Set(reasons) == Set(ClarificationReason.allRawValues))
    }
}

extension ClarificationReason {
    static var allRawValues: [String] {
        ["missing_date", "missing_time", "ambiguous_date", "ambiguous_time", "ambiguous_target",
         "target_not_found", "unclear_speech", "destructive_confirm", "other"]
    }
}
