import Foundation
import KuzmemoCore
import Observation

/// Every preference the settings window edits. It is loaded from the database at launch and each change is saved a
/// moment later; whoever needs to act on a change (the voice path, for instance) listens through `onChange`.
@Observable
final class AppSettings {
    enum Group: CaseIterable { case speech, recognition, recording }

    var speech = SpeechSettings() { didSet { changed(.speech) } }
    var recognition = RecognitionSettings() { didSet { changed(.recognition) } }
    var recording = RecordingSettings() { didSet { changed(.recording) } }
    private(set) var loaded = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var saves: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored var onChange: ((Group) -> Void)?

    init(store: Store) {
        self.store = store
    }

    func load() async {
        loading = true
        speech = await store.settings(SpeechSettings.self)
        recognition = await store.settings(RecognitionSettings.self)
        recording = await store.settings(RecordingSettings.self)
        loading = false
        loaded = true
        for group in Group.allCases { onChange?(group) }
    }

    private func changed(_ group: Group) {
        guard !loading else { return }
        onChange?(group)
        let index = Group.allCases.firstIndex(of: group) ?? 0
        saves[index]?.cancel()
        saves[index] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            switch group {
            case .speech: try? await store.save(settings: speech)
            case .recognition: try? await store.save(settings: recognition)
            case .recording: try? await store.save(settings: recording)
            }
        }
    }
}
