import Foundation
import KuzmemoCore
import KuzmemoSTT
import Observation

/// Puts speech models in place: a download from Hugging Face, or a copy of another app's. It belongs to the app and not to the
/// settings tab. A download goes on when the person leaves the tab or closes the window, coming back shows it still running
/// instead of an offer to download again, and a second press on a model that is on its way cannot start a second download
/// into the same folder.
@Observable
final class ModelInstaller {
    struct Progress: Equatable {
        /// 0...1 while a download reports it; `nil` for a copy, or before the first bytes arrive.
        var fraction: Double?
        var copying: Bool
    }

    /// The models that are in place.
    private(set) var installed: Set<String> = []
    /// The models another app already has, which are copied instead of downloaded (found by `probeSources`).
    private(set) var copyable: Set<String> = []
    /// What is being installed now, by model.
    private(set) var running: [String: Progress] = [:]
    /// Why the last install failed.
    private(set) var failure: String?

    init() {
        refresh()
    }

    /// Looks at the app's own models folder.
    func refresh() {
        installed = Set(ModelCatalog.variants.filter { ModelCatalog.isInstalled($0) }.map(\.id))
    }

    /// Looks for models another app keeps. That reads `~/Documents`, which macOS asks the person to allow the first time, so it
    /// is done when the person looks at the model list and not at launch.
    func probeSources() {
        copyable = Set(ModelCatalog.variants.filter { ModelCatalog.canInstall($0) }.map(\.id))
    }

    func install(_ variant: ModelVariant) {
        guard running[variant.id] == nil, !installed.contains(variant.id) else { return }
        failure = nil
        let copy = copyable.contains(variant.id)
        running[variant.id] = Progress(fraction: nil, copying: copy)
        Task {
            var problem: String?
            if copy {
                problem = await Task.detached { () -> String? in
                    do { try ModelCatalog.install(variant); return nil } catch { return "\(error)" }
                }.value
            } else {
                do {
                    try await ModelCatalog.download(variant) { fraction in
                        Task { @MainActor in self.running[variant.id]?.fraction = fraction }
                    }
                } catch {
                    problem = "\(error)"
                }
            }
            running[variant.id] = nil
            refresh()
            if let problem { failure = tr("Could not install the model: %1$@", problem) }
        }
    }
}
