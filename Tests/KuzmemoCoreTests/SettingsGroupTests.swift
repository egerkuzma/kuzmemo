import Foundation
import GRDB
import Testing
@testable import KuzmemoCore

@Suite("Settings groups")
struct SettingsGroupTests {
    @Test func aFreshStoreGivesTheDefaults() async throws {
        let store = try makeStore()
        #expect(await store.settings(SpeechSettings.self) == SpeechSettings())
        #expect(await store.settings(RecognitionSettings.self).modelVariant == RecognitionSettings.defaultVariant)
        #expect(await store.settings(RecordingSettings.self).handsFreeSilence == 2.5)
    }

    @Test func savedValuesComeBackIncludingAnExplicitAutomaticLanguage() async throws {
        let store = try makeStore()
        var speech = SpeechSettings()
        speech.voiceIdentifier = "com.apple.voice.compact.ru-RU.Milena"; speech.rate = 0.42; speech.speakConfirmations = true
        try await store.save(settings: speech)
        #expect(await store.settings(SpeechSettings.self) == speech)

        var recognition = RecognitionSettings()
        recognition.language = nil; recognition.idleUnloadMinutes = 0; recognition.modelVariant = "openai_whisper-small"
        try await store.save(settings: recognition)
        let back = await store.settings(RecognitionSettings.self)
        #expect(back == recognition && back.language == nil) // nil must not turn back into "ru"
    }

    @Test func anExplicitNullLanguageMeansDetectAutomatically() async throws {
        let store = try makeStore()
        try await store.setSetting(#"{"language":null}"#, for: RecognitionSettings.storageKey)
        #expect(await store.settings(RecognitionSettings.self).language == nil)
        try await store.setSetting(#"{"idleUnloadMinutes":30}"#, for: RecognitionSettings.storageKey) // no language key: the default stays
        #expect(await store.settings(RecognitionSettings.self).language == "ru")
    }

    @Test func aValueFromAnOlderVersionKeepsWhatItHasAndDefaultsTheRest() async throws {
        let store = try makeStore()
        try await store.setSetting(#"{"rate":0.4}"#, for: SpeechSettings.storageKey)
        let speech = await store.settings(SpeechSettings.self)
        #expect(speech.rate == 0.4 && speech.speakAnswers && speech.confirmationSound && !speech.speakConfirmations)
    }

    @Test func nonsenseIsClampedAndDamageFallsBackToDefaults() async throws {
        let store = try makeStore()
        try await store.setSetting(#"{"rate":9,"holdThreshold":0}"#, for: SpeechSettings.storageKey)
        #expect(await store.settings(SpeechSettings.self).rate == 0.7)
        try await store.setSetting(#"{"holdThreshold":0,"handsFreeSilence":99,"maxSeconds":1}"#, for: RecordingSettings.storageKey)
        let recording = await store.settings(RecordingSettings.self)
        #expect(recording.holdThreshold == 0.15 && recording.handsFreeSilence == 8 && recording.maxSeconds == 20)
        try await store.setSetting("not json at all", for: RecognitionSettings.storageKey)
        #expect(await store.settings(RecognitionSettings.self) == RecognitionSettings())
    }

    /// "Nothing stored" and "a damaged value" are the defaults; "the database could not be read" is not: a caller that saves the
    /// group later would otherwise write the defaults over the person's stored choices (notifications switched back on, say).
    @Test func aReadThatFailsIsAnErrorNotTheDefaults() async throws {
        let store = try makeStore()
        var off = NotificationSettings()
        off.enabled = false
        try await store.save(settings: off)
        #expect(try await store.loadSettings(NotificationSettings.self).enabled == false)
        #expect(try await store.loadSettings(SpeechSettings.self) == SpeechSettings()) // nothing stored: the defaults, no error
        try await store.setSetting("not json at all", for: SpeechSettings.storageKey)
        #expect(try await store.loadSettings(SpeechSettings.self) == SpeechSettings()) // damaged: the defaults, no error

        try await store.writer.write { db in try db.execute(sql: "ALTER TABLE kv RENAME TO kv_gone") } // the read fails
        await #expect(throws: (any Error).self) { try await store.loadSettings(NotificationSettings.self) }
        #expect(await store.settings(NotificationSettings.self).enabled == true) // the forgiving read still answers for a display
        try await store.writer.write { db in try db.execute(sql: "ALTER TABLE kv_gone RENAME TO kv") }
        #expect(try await store.loadSettings(NotificationSettings.self).enabled == false) // and the stored choice was never touched
    }
}
