import Foundation
import KuzmemoCore
import Observation
import os

/// Every preference the settings window edits. It is loaded from the database at launch and each change is saved a
/// moment later; whoever needs to act on a change (the voice path, for instance) listens through `onChange`.
///
/// A group whose stored value could not be read (the database did not answer) is shown with its defaults but is not
/// "loaded": it is read again a little later, and until it has been read none of its values is written back, because that
/// would replace the person's stored choices with the defaults. "Nothing stored yet" is not a failed read: it loads as the
/// defaults and may be saved.
@Observable
final class AppSettings {
    enum Group: CaseIterable { case speech, recognition, recording, notifications }

    var speech = SpeechSettings() { didSet { changed(.speech) } }
    var recognition = RecognitionSettings() { didSet { changed(.recognition) } }
    var recording = RecordingSettings() { didSet { changed(.recording) } }
    var notifications = NotificationSettings() { didSet { changed(.notifications) } }
    /// Every group has been read from the database (the stored values, or the defaults for a group never saved).
    private(set) var loaded = false
    /// The last save that failed (the control channel reports it); cleared by the next save that works.
    private(set) var lastSaveError: String?

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var loadedGroups: Set<Group> = []
    @ObservationIgnored private var saves: [Group: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [(Group) -> Void] = []
    @ObservationIgnored private var retry: Task<Void, Never>?
    private static let log = Logger(subsystem: "app.kuzmemo", category: "settings")

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
        // On the very first launch the recognition language is the system language (Russian is the stored default). A read
        // that fails is not a first launch.
        let firstLaunch: Bool
        do { firstLaunch = try await store.setting(RecognitionSettings.storageKey) == nil } catch { firstLaunch = false }
        await read(Set(Group.allCases))
        if firstLaunch, loadedGroups.contains(.recognition), AppLanguage.best() == .english {
            loading = true
            recognition.language = "en"
            loading = false
        }
        for group in Group.allCases { notify(group) }
        scheduleRetryIfNeeded()
    }

    /// Reads the given groups; the ones that could not be read keep what they show and stay unloaded.
    private func read(_ groups: Set<Group>) async {
        loading = true
        defer { loading = false }
        for group in Group.allCases where groups.contains(group) {
            do {
                switch group {
                case .speech: speech = try await store.loadSettings(SpeechSettings.self)
                case .recognition: recognition = try await store.loadSettings(RecognitionSettings.self)
                case .recording: recording = try await store.loadSettings(RecordingSettings.self)
                case .notifications: notifications = try await store.loadSettings(NotificationSettings.self)
                }
                loadedGroups.insert(group)
            } catch {
                Self.log.error("settings \(String(describing: group), privacy: .public) could not be read: \(error, privacy: .public)")
            }
        }
        loaded = loadedGroups.count == Group.allCases.count
    }

    /// The groups that could not be read are read again, a little later and then less often, until they have been.
    private func scheduleRetryIfNeeded() {
        guard !loaded, retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            var delay: Duration = .seconds(5)
            while let self, !self.loaded, !Task.isCancelled {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                let missing = Set(Group.allCases).subtracting(self.loadedGroups)
                await self.read(missing)
                for group in missing where self.loadedGroups.contains(group) { self.notify(group) }
                delay = min(delay * 2, .seconds(300))
            }
            self?.retry = nil
        }
    }

    private func changed(_ group: Group) {
        guard !loading else { return }
        notify(group)
        saves[group]?.cancel()
        saves[group] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await save(group)
            saves[group] = nil // done (a newer change would have cancelled this task before taking its place)
        }
    }

    /// Writes one group, unless its stored value has never been read: the defaults it shows are not the person's choices.
    private func save(_ group: Group) async {
        guard loadedGroups.contains(group) else {
            Self.log.error("settings \(String(describing: group), privacy: .public) not saved: the stored value has not been read yet")
            return
        }
        do {
            switch group {
            case .speech: try await store.save(settings: speech)
            case .recognition: try await store.save(settings: recognition)
            case .recording: try await store.save(settings: recording)
            case .notifications: try await store.save(settings: notifications)
            }
            lastSaveError = nil
        } catch {
            lastSaveError = "\(error)"
            Self.log.error("settings \(String(describing: group), privacy: .public) could not be saved: \(error, privacy: .public)")
        }
    }

    /// The app is quitting: whatever was changed in the last moment and is still waiting for its save goes to the database now
    /// (a preference changed and the app quit within the delay used to be lost). Only the groups with a change waiting are
    /// written: the others hold what was read, or defaults that were never read, and neither must replace the stored values.
    func flush() async {
        let waiting = saves.keys.sorted { Group.allCases.firstIndex(of: $0)! < Group.allCases.firstIndex(of: $1)! }
        for task in saves.values { task.cancel() }
        saves = [:]
        for group in waiting { await save(group) }
    }
}
