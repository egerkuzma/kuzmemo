import Foundation
import KuzmemoCore

/// Control-channel access to the preferences: what the app holds now, what is saved in the database, and a way to
/// change values the way the settings window does.
enum SettingsRoutes {
    static func read(_ env: AppEnvironment) async -> HTTPResponse {
        let stored: [String: Any] = [
            "speech": object(await env.store.settings(SpeechSettings.self)),
            "recognition": object(await env.store.settings(RecognitionSettings.self)),
            "recording": object(await env.store.settings(RecordingSettings.self)),
            "notifications": object(await env.store.settings(NotificationSettings.self)),
        ]
        let live: [String: Any] = [
            "speech": object(env.settings.speech), "recognition": object(env.settings.recognition), "recording": object(env.settings.recording),
            "notifications": object(env.settings.notifications),
        ]
        return .json(["stored": stored, "live": live, "loaded": env.settings.loaded])
    }

    /// `{"speech": {"rate": 0.4}, "recording": {"maxSeconds": 90}}`: named fields replace the current values.
    static func update(_ request: HTTPRequest, _ env: AppEnvironment) async -> HTTPResponse {
        guard let json = request.jsonBody else { return .error("body must be JSON", status: 400) }
        if let patch = json["speech"] as? [String: Any] { env.settings.speech = merged(env.settings.speech, patch) }
        if let patch = json["recognition"] as? [String: Any] { env.settings.recognition = merged(env.settings.recognition, patch) }
        if let patch = json["recording"] as? [String: Any] { env.settings.recording = merged(env.settings.recording, patch) }
        if let patch = json["notifications"] as? [String: Any] { env.settings.notifications = merged(env.settings.notifications, patch) }
        try? await Task.sleep(for: .milliseconds(700)) // the settings are saved a moment after they change
        return await read(env)
    }

    private static func object<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value), let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    /// The current value with the patch's fields applied (through the same tolerant decoding that reads saved values).
    private static func merged<T: SettingsGroup>(_ current: T, _ patch: [String: Any]) -> T {
        guard let data = try? JSONEncoder().encode(current), var dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return current
        }
        for (key, value) in patch { dictionary[key] = value }
        guard let merged = try? JSONSerialization.data(withJSONObject: dictionary), let result = try? JSONDecoder().decode(T.self, from: merged) else {
            return current
        }
        return result
    }
}
