import Foundation
import Testing
@testable import KuzmemoCore

@Suite("Plans cannot combine different revisions of one target")
struct SnapshotConsistencyTests {
    private func plan(_ actions: [[String: Any]], context: ContextPlan, store: Store) async throws -> MutationPlan {
        let data = try JSONSerialization.data(withJSONObject: ["intent": "update", "confidence": 0.9, "actions": actions])
        let response = try JSONDecoder().decode(ParserResponse.self, from: data)
        let result = await ActionValidator.validate(response, in: ValidationContext(
            context: context, resolver: RelativeDateResolver(anchor: store.clock.localNow()), store: store
        ))
        guard case let .mutate(plan) = result else {
            Issue.record("Expected a mutation: \(result)"); throw CocoaError(.fileReadUnknown)
        }
        return plan
    }

    @Test(arguments: [false, true]) func mixedSnapshotsRefuseTheWholePlanInEitherOrder(reverse: Bool) async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(kind: .event, title: "Встреча с Дмитрием", date: LocalDate("2026-09-29"), time: LocalTime("10:00")))
        let context = try await ContextPlanner().plan(transcript: "перенеси встречу с Дмитрием", anchor: store.clock.localNow(), store: store)
        var fresh = ItemDraft(made.item); fresh.time = LocalTime("15:00")
        try await store.save(fresh, as: made.item.id)
        let ref: [String: Any] = ["op": "update", "ref": 1, "changes": ["when": ["mode": "none", "time": "11:00"]]]
        let hint: [String: Any] = ["op": "update", "target_hint": "Дмитрием", "changes": ["title": "Встреча с Дмитрием по проекту"]]
        let mutation = try await plan(reverse ? [hint, ref] : [ref, hint], context: context, store: store)
        await #expect(throws: StoreError.changedMeanwhile(made.item.id)) {
            try await store.apply(mutation, source: .voice, memoID: nil, label: "stale plan")
        }
        let unchanged = try #require(try await store.item(id: made.item.id))
        #expect(unchanged.time == LocalTime("15:00") && unchanged.title == made.item.title)
    }

    @Test func aDiscardedActionCannotLendItsRevisionToAnOldDeletion() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(title: "Дмитрием", date: LocalDate("2026-09-29")))
        let context = try await ContextPlanner().plan(transcript: "удали Дмитрием", anchor: store.clock.localNow(), store: store)
        var fresh = ItemDraft(made.item); fresh.details = "new information"
        try await store.save(fresh, as: made.item.id)
        let mutation = try await plan([
            ["op": "delete", "ref": 1], ["op": "complete", "target_hint": "Дмитрием"],
        ], context: context, store: store)
        #expect(mutation.actions.count == 1)
        await #expect(throws: StoreError.changedMeanwhile(made.item.id)) {
            try await store.apply(mutation, source: .voice, memoID: nil, label: "stale delete")
        }
        #expect(try await store.item(id: made.item.id)?.details == "new information")
    }

    @Test func twoActionsFromTheSameRevisionStillApply() async throws {
        let store = try makeStore()
        let made = try await store.create(ItemDraft(title: "Дмитрием", date: LocalDate("2026-09-29")))
        let context = try await ContextPlanner().plan(transcript: "измени Дмитрием", anchor: store.clock.localNow(), store: store)
        let mutation = try await plan([
            ["op": "update", "ref": 1, "changes": ["details": "details"]],
            ["op": "update", "target_hint": "Дмитрием", "changes": ["title": "Новое название"]],
        ], context: context, store: store)
        _ = try await store.apply(mutation, source: .voice, memoID: nil, label: "current plan")
        let saved = try #require(try await store.item(id: made.item.id))
        #expect(saved.title == "Новое название" && saved.details == "details")
    }
}
