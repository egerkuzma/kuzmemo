import Foundation
import KuzmemoCore
import Observation

/// Every preference the settings window edits. It is loaded from the database at launch and each change is saved a
/// moment later; whoever needs to act on a change (the voice path, for instance) listens through `onChange`.
@Observable
final class AppSettings {
    enum Group: CaseIterable { case speech, recognition, recording, notifications }

    var speech = SpeechSettings() { didSet { changed(.speech) } }
    var recognition = RecognitionSettings() { didSet { changed(.recognition) } }
    var recording = RecordingSettings() { didSet { changed(.recording) } }
    var notifications = NotificationSettings() { didSet { changed(.notifications) } }
    private(set) var loaded = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var saves: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [(Group) -> Void] = []

    init(store: Store) {
        self.store = store
    }

    /// Calls `handler` whenever a group changes (and once per group after the saved values are loaded).
    func observe(_ handler: @escaping (Group) -> Void) {
        observers.append(handler)
    }

    private func notify(_ group: Group) {
        for handler in observers { handler(group) }
    }

    func load() async {
        // On the very first launch the recognition language is the system language (Russian is the stored default).
        let firstLaunch = (try? await store.setting(RecognitionSettings.storageKey)) == nil
        loading = true
        speech = await store.settings(SpeechSettings.self)
        recognition = await store.settings(RecognitionSettings.self)
        recording = await store.settings(RecordingSettings.self)
        notifications = await store.settings(NotificationSettings.self)
        if firstLaunch, AppLanguage.best() == .english { recognition.language = "en" }
        loading = false
        loaded = true
        for group in Group.allCases { notify(group) }
    }

    private func changed(_ group: Group) {
        guard !loading else { return }
        notify(group)
        let index = Group.allCases.firstIndex(of: group) ?? 0
        saves[index]?.cancel()
        saves[index] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await save(group)
        }
    }

    private func save(_ group: Group) async {
        switch group {
        case .speech: try? await store.save(settings: speech)
        case .recognition: try? await store.save(settings: recognition)
        case .recording: try? await store.save(settings: recording)
        case .notifications: try? await store.save(settings: notifications)
        }
    }

    /// The app is quitting: whatever was changed in the last moment and is still waiting for its save goes to the database now
    /// (a preference changed and the app quit within the delay used to be lost). Nothing is saved before the stored values
    /// have been read, or the defaults would replace them.
    func flush() async {
        guard loaded, !saves.isEmpty else { return }
        for task in saves.values { task.cancel() }
        saves = [:]
        for group in Group.allCases { await save(group) }
    }
}
