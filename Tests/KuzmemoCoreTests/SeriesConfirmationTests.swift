import Foundation
import Testing
@testable import KuzmemoCore

@Suite("Series edits require consent even below the bulk limit")
struct SeriesConfirmationTests {
    @Test(arguments: [false, true]) func aMixedOccurrenceMoveAndSeriesEditWaitsForTheAnswer(accept: Bool) async throws {
        let store = try makeStore()
        let date = LocalDate("2026-09-29")!
        let made = try await store.create(ItemDraft(kind: .event, title: "Планёрка", date: date, time: LocalTime("10:00"), recurrence: Recurrence(freq: .daily)))
        let json = #"{"intent":"update","confidence":0.9,"actions":[{"op":"update","ref":1,"changes":{"title":"Стендап","when":{"mode":"none","time":"18:00"}}}]}"#
        let provider = ScriptedProvider([.json(json)])
        let processor = MemoProcessor(store: store, interpreter: Interpreter(store: store, provider: provider), clock: store.clock)
        let first = await processor.submit(text: "перенеси завтрашнюю планёрку на шесть", inputKind: .text)
        guard case let .clarify(question) = first.kind else { Issue.record("Expected a scope confirmation: \(first.kind)"); return }
        #expect(question.pending?.actions.count == 2)
        #expect(try await store.item(id: made.item.id)?.title == "Планёрка")
        #expect(try await store.agenda(on: date).first?.time == LocalTime("10:00"))

        let answer = await processor.submit(text: accept ? "да" : "нет", inputKind: .text,
                                            parentMemoID: first.memo.id, followupQuestion: question.question)
        if accept {
            guard case .applied = answer.kind else { Issue.record("Expected the kept plan: \(answer.kind)"); return }
            #expect(try await store.item(id: made.item.id)?.title == "Стендап")
            #expect(try await store.agenda(on: date).first?.time == LocalTime("18:00"))
        } else {
            #expect(answer.memo.status == .discarded)
            #expect(try await store.item(id: made.item.id)?.title == "Планёрка")
            #expect(try await store.agenda(on: date).first?.time == LocalTime("10:00"))
        }
        #expect(try await store.agenda(on: date.adding(days: 1)).first?.time == LocalTime("10:00"))
        #expect(provider.requests.count == 1, "The yes/no must resolve the saved plan locally")
    }
}
