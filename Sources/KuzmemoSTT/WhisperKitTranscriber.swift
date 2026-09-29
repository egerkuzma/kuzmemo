import Foundation
import KuzmemoCore
import WhisperKit

public struct WhisperKitConfiguration: Sendable {
    /// The model folder (Core ML bundles plus tokenizer) that this app owns.
    public var modelFolder: URL
    /// A Hugging Face style base folder (`models/openai/whisper-large-v3` holds the tokenizer).
    public var downloadBase: URL
    /// "ru", or `nil` to let the model detect the language.
    public var language: String?
    /// Prewarming halves the peak memory during loading at the cost of a slower load.
    public var prewarm: Bool
    /// The model is unloaded after this long without use.
    public var idleUnloadSeconds: TimeInterval
    public var modelName: String

    public init(
        modelFolder: URL, downloadBase: URL, language: String? = "ru", prewarm: Bool = true,
        idleUnloadSeconds: TimeInterval = 900, modelName: String
    ) {
        self.modelFolder = modelFolder
        self.downloadBase = downloadBase
        self.language = language
        self.prewarm = prewarm
        self.idleUnloadSeconds = idleUnloadSeconds
        self.modelName = modelName
    }

    public static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"

    /// `~/Library/Application Support/Kuzmemo/huggingface`, the folder the model installer (Settings → Recognition) fills.
    public static var defaultModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kuzmemo/huggingface", isDirectory: true)
    }

    public static func standard(
        modelsRoot: URL = WhisperKitConfiguration.defaultModelsRoot, variant: String = defaultVariant, language: String? = "ru"
    ) -> WhisperKitConfiguration {
        WhisperKitConfiguration(
            modelFolder: modelsRoot.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)", isDirectory: true),
            downloadBase: modelsRoot, language: language, modelName: variant
        )
    }
}

/// WhisperKit large-v3-turbo on the Neural Engine. The model loads lazily (about 1.4 s once the Core ML
/// cache is warm), stays loaded while it is being used and is released after `idleUnloadSeconds`.
public actor WhisperKitTranscriber: Transcriber {
    private var configuration: WhisperKitConfiguration
    private var pipe: WhisperKit?
    private var isLoading = false
    private var idleTask: Task<Void, Never>?
    /// Bumped when the configuration changes, so a load that started with the old one is thrown away.
    private var generation = 0

    public init(configuration: WhisperKitConfiguration) {
        self.configuration = configuration
    }

    public var isLoaded: Bool { pipe != nil }
    public var modelName: String { configuration.modelName }

    public func setLanguage(_ language: String?) { configuration.language = language }

    /// Switches to another model, language or idle time. A different model is unloaded here and loads on the
    /// next `prepare()` or recognition.
    public func reconfigure(_ new: WhisperKitConfiguration) async {
        let modelChanged = new.modelFolder != configuration.modelFolder || new.downloadBase != configuration.downloadBase
            || new.prewarm != configuration.prewarm
        configuration = new
        if modelChanged {
            generation += 1
            await unload()
        } else if pipe != nil {
            scheduleIdleUnload()
        }
    }

    public func prepare() async throws {
        _ = try await loadedPipe()
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput {
        let pipe = try await loadedPipe()
        idleTask?.cancel()
        let started = Date()
        let language = configuration.language
        let options = DecodingOptions(
            task: .transcribe, language: language, temperature: 0, temperatureFallbackCount: 3,
            detectLanguage: language == nil, skipSpecialTokens: true, withoutTimestamps: true, wordTimestamps: false,
            suppressBlank: true, concurrentWorkerCount: 1
        )
        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        } catch {
            scheduleIdleUnload()
            throw TranscriberError.transcriptionFailed("\(error)")
        }
        scheduleIdleUnload()
        let text = results.map(\.text).joined(separator: " ")
        return TranscriptionOutput(
            text: Self.stripSpecialTokens(text), language: results.first?.language,
            audioSeconds: Double(samples.count) / 16000, processingSeconds: Date().timeIntervalSince(started),
            model: configuration.modelName
        )
    }

    public func unload() async {
        idleTask?.cancel()
        idleTask = nil
        await pipe?.unloadModels()
        pipe = nil
    }

    // MARK: - Internals

    private func loadedPipe() async throws -> WhisperKit {
        if let pipe { return pipe }
        // Actors interleave at awaits: a second caller waits for the first load instead of starting another.
        while isLoading {
            try await Task.sleep(for: .milliseconds(50))
            if let pipe { return pipe }
        }
        guard FileManager.default.fileExists(atPath: configuration.modelFolder.path) else {
            throw TranscriberError.modelMissing(configuration.modelFolder.path)
        }
        isLoading = true
        defer { isLoading = false }
        let started = generation
        let settings = configuration
        do {
            let loaded = try await WhisperKit(WhisperKitConfig(
                downloadBase: settings.downloadBase, modelFolder: settings.modelFolder.path,
                verbose: false, logLevel: .error, prewarm: settings.prewarm, load: true, download: false
            ))
            if started != generation {
                // The model was switched while this one was loading: drop it and load the current one.
                await loaded.unloadModels()
                isLoading = false
                return try await loadedPipe()
            }
            pipe = loaded
            return loaded
        } catch {
            throw TranscriberError.loadFailed("\(error)")
        }
    }

    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard configuration.idleUnloadSeconds > 0 else { return } // 0: keep the model loaded
        let seconds = configuration.idleUnloadSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    /// Removes Whisper control tokens such as `<|startoftranscript|>` that can leak into the text.
    static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
