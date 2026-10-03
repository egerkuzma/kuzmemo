import Foundation
import KuzmemoCore
import Observation

/// Stored settings are used only after their group has loaded. Failed writes stay dirty until a retry succeeds.
@MainActor
@Observable
final class AppSettings {
    enum Group: CaseIterable { case speech, recognition, recording, notifications }

    var speech = SpeechSettings() { didSet { changed(.speech) } }
    var recognition = RecognitionSettings() { didSet { changed(.recognition) } }
    var recording = RecordingSettings() { didSet { changed(.recording) } }
    var notifications = NotificationSettings() { didSet { changed(.notifications) } }
    private(set) var loadedGroups: Set<Group> = []
    var loaded: Bool { loadedGroups.count == Group.allCases.count }
    private var readErrors: [Group: String] = [:]
    private var saveErrors: [Group: String] = [:]
    var lastReadError: String? { Group.allCases.compactMap { readErrors[$0] }.first }
    var lastSaveError: String? { Group.allCases.compactMap { saveErrors[$0] }.first }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var applyingStoredValue = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var dirty: Set<Group> = []
    @ObservationIgnored private var generations: [Group: Int] = [:]
    @ObservationIgnored private var saves: [Group: Task<Void, Never>] = [:]
    @ObservationIgnored private var observers: [(Group) -> Void] = []
    @ObservationIgnored private var retry: Task<Void, Never>?

    init(store: Store) { self.store = store }

    func isLoaded(_ group: Group) -> Bool { loadedGroups.contains(group) }
    func observe(_ handler: @escaping (Group) -> Void) { observers.append(handler) }
    private func notify(_ group: Group) { for handler in observers { handler(group) } }

    func load() async {
        await read(Set(Group.allCases).subtracting(loadedGroups))
        scheduleRetryIfNeeded()
    }

    private func read(_ groups: Set<Group>) async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        for group in Group.allCases where groups.contains(group) {
            do {
                // Do not suppress UI changes to already loaded groups while waiting for another group's database read.
                switch group {
                case .speech:
                    let value = try await store.loadSettings(SpeechSettings.self)
                    applyingStoredValue = true; speech = value; applyingStoredValue = false
                case .recognition:
                    let firstLaunch = try await store.setting(RecognitionSettings.storageKey) == nil
                    var value = try await store.loadSettings(RecognitionSettings.self)
                    if firstLaunch, AppLanguage.best() == .english { value.language = "en" }
                    applyingStoredValue = true; recognition = value; applyingStoredValue = false
                case .recording:
                    let value = try await store.loadSettings(RecordingSettings.self)
                    applyingStoredValue = true; recording = value; applyingStoredValue = false
                case .notifications:
                    let value = try await store.loadSettings(NotificationSettings.self)
                    applyingStoredValue = true; notifications = value; applyingStoredValue = false
                }
                loadedGroups.insert(group)
                readErrors[group] = nil
                notify(group)
            } catch {
                readErrors[group] = "\(error)"
            }
        }
    }

    private func changed(_ group: Group) {
        guard !applyingStoredValue, isLoaded(group) else { return }
        generations[group, default: 0] += 1
        let generation = generations[group]!
        dirty.insert(group)
        notify(group)
        saves[group]?.cancel()
        guard !flushing else { return }
        saves[group] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self else { return }
            await self.save(group)
            // A save can suspend: it must not remove the task installed by a newer edit.
            if self.generations[group] == generation { self.saves[group] = nil }
            if !Task.isCancelled { self.scheduleRetryIfNeeded() }
        }
    }

    private func save(_ group: Group) async {
        guard dirty.contains(group), isLoaded(group) else { return }
        let generation = generations[group, default: 0]
        do {
            switch group {
            case .speech: try await store.save(settings: speech)
            case .recognition: try await store.save(settings: recognition)
            case .recording: try await store.save(settings: recording)
            case .notifications: try await store.save(settings: notifications)
            }
            if generations[group] == generation { dirty.remove(group); saveErrors[group] = nil }
        } catch {
            if generations[group] == generation { saveErrors[group] = "\(error)" }
        }
    }

    private func scheduleRetryIfNeeded() {
        guard !flushing, (!loaded || !dirty.isEmpty), retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            var delay: Duration = .seconds(5)
            while let self, !self.loaded || !self.dirty.isEmpty {
                do { try await Task.sleep(for: delay) } catch { break }
                await self.read(Set(Group.allCases).subtracting(self.loadedGroups))
                for group in Group.allCases where self.dirty.contains(group) { await self.save(group) }
                delay = min(delay * 2, .seconds(300))
            }
            self?.retry = nil
        }
    }

    /// A quit must know whether edits reached the database. Waiting for cancelled tasks prevents an older in-flight write
    /// from landing after the final save. Dirty groups and errors remain available if the person cancels the quit.
    func flush() async -> Bool {
        guard !flushing else { return false }
        flushing = true
        defer { flushing = false }
        let pending = Array(saves.values) + (retry.map { [$0] } ?? [])
        for task in pending { task.cancel() }
        for task in pending { await task.value }
        saves = [:]
        retry = nil
        for group in Group.allCases where dirty.contains(group) { await save(group) }
        return dirty.isEmpty
    }

    func resumeSaving() { scheduleRetryIfNeeded() }
}
