import Foundation

/// A WhisperKit model the app can use, with the words the settings window shows for it.
public struct ModelVariant: Identifiable, Equatable, Sendable {
    /// The model's folder name.
    public var id: String
    public var title: String
    public var detail: String
    public var sizeMB: Int
    /// The tokenizer folder (under `models/`) the model needs next to it.
    public var tokenizerRepo: String
}

/// Which models exist, which are installed in the app's own folder, and how to install one from a copy that another
/// app already downloaded (an APFS clone, so it takes no extra disk space).
public enum ModelCatalog {
    public static let variants: [ModelVariant] = [
        ModelVariant(
            id: "openai_whisper-large-v3-v20240930_turbo", title: "Large v3 Turbo",
            detail: "Быстрая и точная. Рекомендуется.", sizeMB: 1500, tokenizerRepo: "openai/whisper-large-v3"
        ),
        ModelVariant(
            id: "openai_whisper-large-v3-v20240930", title: "Large v3",
            detail: "Полная модель: максимум точности, но заметно медленнее.", sizeMB: 1500, tokenizerRepo: "openai/whisper-large-v3"
        ),
        ModelVariant(
            id: "openai_whisper-small", title: "Small",
            detail: "Лёгкая и быстрая, но ошибается чаще.", sizeMB: 460, tokenizerRepo: "openai/whisper-small"
        ),
    ]

    public static func variant(id: String) -> ModelVariant? { variants.first { $0.id == id } }

    /// `~/Documents/huggingface`, where other apps keep the models they downloaded. Read-only for us.
    public static var externalSource: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/huggingface", isDirectory: true)
    }

    static func modelFolder(_ variant: ModelVariant, in root: URL) -> URL {
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant.id)", isDirectory: true)
    }

    static func tokenizerFolder(_ variant: ModelVariant, in root: URL) -> URL {
        root.appendingPathComponent("models/\(variant.tokenizerRepo)", isDirectory: true)
    }

    private static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    /// Installed means the model folder and its tokenizer files are both in place.
    public static func isInstalled(_ variant: ModelVariant, in root: URL = WhisperKitConfiguration.defaultModelsRoot) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFolder(variant, in: root).path) else { return false }
        let tokenizer = tokenizerFolder(variant, in: root)
        return tokenizerFiles.allSatisfy { fm.fileExists(atPath: tokenizer.appendingPathComponent($0).path) }
    }

    /// Whether another app's copy of this model is there to install from.
    public static func canInstall(_ variant: ModelVariant, from source: URL = externalSource) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelFolder(variant, in: source).path) else { return false }
        let tokenizer = tokenizerFolder(variant, in: source)
        return tokenizerFiles.allSatisfy { fm.fileExists(atPath: tokenizer.appendingPathComponent($0).path) }
    }

    public enum InstallError: Error, Equatable {
        case sourceMissing(String)
        case copyFailed(String)
    }

    /// Clones the model and its tokenizer into `root` (like `cp -c -R`). Blocking: call it off the main thread.
    /// Reading `~/Documents` makes macOS ask the person for access the first time.
    public static func install(
        _ variant: ModelVariant, from source: URL = externalSource, into root: URL = WhisperKitConfiguration.defaultModelsRoot
    ) throws {
        guard canInstall(variant, from: source) else {
            throw InstallError.sourceMissing(modelFolder(variant, in: source).path)
        }
        let fm = FileManager.default
        let destination = modelFolder(variant, in: root)
        if !fm.fileExists(atPath: destination.path) {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try clone(modelFolder(variant, in: source), to: destination)
        }
        let tokenizerTarget = tokenizerFolder(variant, in: root)
        try fm.createDirectory(at: tokenizerTarget, withIntermediateDirectories: true)
        for name in tokenizerFiles {
            let target = tokenizerTarget.appendingPathComponent(name)
            if fm.fileExists(atPath: target.path) { continue }
            try clone(tokenizerFolder(variant, in: source).appendingPathComponent(name), to: target)
        }
    }

    /// `cp -c -R`: an APFS clone where possible, a plain copy otherwise.
    private static func clone(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-c", "-R", source.path, destination.path]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            try? FileManager.default.removeItem(at: destination) // never leave a half-copied model that looks installed
            throw InstallError.copyFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
