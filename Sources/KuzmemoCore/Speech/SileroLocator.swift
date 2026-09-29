import Foundation

/// The pieces the Silero voice needs on this Mac: a Python interpreter with torch, and the model file.
public struct SileroInstallation: Equatable, Sendable {
    public var python: URL
    public var model: URL
    /// Where it was found, worded for the settings screen.
    public var source: String

    public init(python: URL, model: URL, source: String) {
        self.python = python
        self.model = model
        self.source = source
    }
}

/// Finds a Python with torch and the Silero model. It looks at the files only (no process is started), so it is quick
/// enough to run whenever the settings screen is drawn.
public enum SileroLocator {
    public static let modelFileName = "v4_ru.pt"

    public enum Problem: Error, Equatable, Sendable {
        case noPython
        case pythonMissing(String)
        case noTorch(URL)
        case noModel(python: URL)

        /// What to tell the person.
        public var message: String {
            switch self {
            case .noPython: "Не найден Python с torch."
            case let .pythonMissing(path): "Указанный Python не найден: \(path)"
            case let .noTorch(python): "В этом окружении нет torch: \(python.path)"
            case .noModel: "Не найден файл модели \(SileroLocator.modelFileName) (около 40 МБ)."
            }
        }
    }

    /// `~/Library/Application Support/Kuzmemo/silero`, where `scripts/install_silero.sh` puts its own environment and
    /// a copy of the model.
    public static func ownDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Kuzmemo/silero", isDirectory: true)
    }

    /// An interpreter chosen by hand wins; otherwise the app's own environment, then the one of the another project
    /// project (which already speaks with this voice). The model is looked for next to the app's data and in the
    /// torch hub cache.
    public static func find(
        override: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default
    ) -> Result<SileroInstallation, Problem> {
        var candidates: [(python: URL, source: String)]
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard fileManager.isExecutableFile(atPath: url.path) else { return .failure(.pythonMissing(override)) }
            candidates = [(url, "указан вручную")]
        } else {
            candidates = [
                (ownDirectory(home: home).appendingPathComponent("venv/bin/python"), "окружение Kuzmemo"),
                (home.appendingPathComponent("Projects/another project/venv/bin/python"), "окружение проекта another project"),
            ]
        }
        var withoutTorch: URL?
        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate.python.path) {
            guard hasTorch(candidate.python, fileManager: fileManager) else { withoutTorch = withoutTorch ?? candidate.python; continue }
            guard let model = findModel(home: home, fileManager: fileManager) else { return .failure(.noModel(python: candidate.python)) }
            return .success(SileroInstallation(python: candidate.python, model: model, source: candidate.source))
        }
        return .failure(withoutTorch.map(Problem.noTorch) ?? .noPython)
    }

    /// A virtual environment is checked for a `torch` folder; any other interpreter is given the benefit of the doubt
    /// (the helper reports it if the import fails).
    static func hasTorch(_ python: URL, fileManager: FileManager) -> Bool {
        let root = python.deletingLastPathComponent().deletingLastPathComponent()
        guard fileManager.fileExists(atPath: root.appendingPathComponent("pyvenv.cfg").path) else { return true }
        let lib = root.appendingPathComponent("lib")
        let versions = (try? fileManager.contentsOfDirectory(atPath: lib.path)) ?? []
        return versions.contains { fileManager.fileExists(atPath: lib.appendingPathComponent($0).appendingPathComponent("site-packages/torch").path) }
    }

    static func findModel(home: URL, fileManager: FileManager) -> URL? {
        let hub = home.appendingPathComponent(".cache/torch/hub")
        let candidates = [
            ownDirectory(home: home).appendingPathComponent(modelFileName),
            hub.appendingPathComponent("snakers4_silero-models_master/src/silero/model/\(modelFileName)"),
            hub.appendingPathComponent("checkpoints/\(modelFileName)"),
        ]
        return candidates.first { url in
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return size > 1_000_000
        }
    }
}
