import Foundation
import Testing
@testable import KuzmemoCore

@Suite("Result card timing")
struct ResultDisplayTests {
    @Test func aConfirmationWithUndoStaysTwoSecondsBecauseTheCalendarAlreadyHasIt() {
        #expect(ResultDisplay.seconds(characters: 70, lines: 1, undoable: true) == 2)
        #expect(ResultDisplay.seconds(characters: 400, lines: 1, undoable: true) == 2) // however long the line
    }

    @Test func severalChangesGetAFewMoreSecondsUpToFive() {
        #expect(ResultDisplay.seconds(characters: 120, lines: 3, undoable: true) == 4)
        #expect(ResultDisplay.seconds(characters: 900, lines: 12, undoable: true) == 5)
    }

    @Test func everythingElseStaysLongEnoughToRead() {
        #expect(ResultDisplay.seconds(characters: 10, lines: 1, undoable: false) == 4) // at least four seconds
        let medium = ResultDisplay.seconds(characters: 100, lines: 2, undoable: false)
        #expect(medium > 4 && medium < 12)
        #expect(ResultDisplay.seconds(characters: 2000, lines: 8, undoable: false) == 12) // at most twelve
    }
}
