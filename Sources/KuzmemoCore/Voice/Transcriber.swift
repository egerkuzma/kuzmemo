import Foundation

public struct TranscriptionOutput: Equatable, Sendable {
    public var text: String
    public var language: String?
    public var audioSeconds: Double
    public var processingSeconds: Double
    public var model: String

    public init(text: String, language: String? = nil, audioSeconds: Double, processingSeconds: Double, model: String) {
        self.text = text
        self.language = language
        self.audioSeconds = audioSeconds
        self.processingSeconds = processingSeconds
        self.model = model
    }
}

public enum TranscriberError: Error, Equatable {
    /// The model folder is not where the app looks for it.
    case modelMissing(String)
    case loadFailed(String)
    case transcriptionFailed(String)
}

/// A speech-to-text engine. Implementations keep their heavy model inside (an actor) and accept 16 kHz mono
/// Float32 samples, so the engine behind the protocol can be swapped without touching the pipeline.
public protocol Transcriber: Sendable {
    var modelName: String { get }
    /// Loads the model if needed (idempotent, safe to call on every key-down to hide the load time).
    func prepare() async throws
    func transcribe(_ samples: [Float]) async throws -> TranscriptionOutput
    /// Frees the model's memory.
    func unload() async
}

public enum Recognition: Equatable, Sendable {
    case speech(TranscriptionOutput)
    /// Nothing worth sending on: the gate found no speech, or everything the engine returned was an invention.
    case noSpeech(reason: String)
}

/// Gate → engine → hallucination filter: the guarded path from raw audio to text.
public struct Recognizer: Sendable {
    public var transcriber: any Transcriber
    public var gate: EnergyGate

    public init(transcriber: any Transcriber, gate: EnergyGate = EnergyGate()) {
        self.transcriber = transcriber
        self.gate = gate
    }

    public func recognize(_ samples: [Float]) async throws -> Recognition {
        guard let trimmed = gate.trimmed(samples) else { return .noSpeech(reason: "no speech in the recording") }
        var output = try await transcriber.transcribe(trimmed)
        guard let clean = HallucinationFilter.clean(output.text) else {
            return .noSpeech(reason: "engine returned only invented text: «\(output.text)»")
        }
        output.text = clean
        return .speech(output)
    }
}
