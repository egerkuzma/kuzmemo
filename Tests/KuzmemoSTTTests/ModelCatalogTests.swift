import Foundation
import Testing
@testable import KuzmemoSTT

@Suite("ModelCatalog")
struct ModelCatalogTests {
    private func makeRoot(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kuzmemo-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fake external copy of a model: the Core ML parts with a file each, a config, plus the tokenizer.
    private func populate(_ root: URL, _ variant: ModelVariant, tokenizer: Bool = true, parts: [String] = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]) throws {
        let model = ModelCatalog.modelFolder(variant, in: root)
        for part in parts {
            try FileManager.default.createDirectory(at: model.appendingPathComponent("\(part).mlmodelc"), withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: model.appendingPathComponent("\(part).mlmodelc/weight.bin"))
        }
        try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
        guard tokenizer else { return }
        let tok = ModelCatalog.tokenizerFolder(variant, in: root)
        try FileManager.default.createDirectory(at: tok, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] { try Data("{}".utf8).write(to: tok.appendingPathComponent(name)) }
    }

    @Test func theCatalogKnowsTheThreeModelsAndTheDefaultIsTheTurbo() {
        #expect(ModelCatalog.variants.count == 3)
        #expect(ModelCatalog.variants.first?.id == WhisperKitConfiguration.defaultVariant)
        #expect(ModelCatalog.variant(id: "openai_whisper-small")?.tokenizerRepo == "openai/whisper-small")
        #expect(ModelCatalog.variant(id: "nope") == nil)
    }

    @Test func aModelCountsAsInstalledOnlyWithItsTokenizer() throws {
        let root = try makeRoot("installed"); defer { try? FileManager.default.removeItem(at: root) }
        let small = try #require(ModelCatalog.variant(id: "openai_whisper-small"))
        #expect(!ModelCatalog.isInstalled(small, in: root))
        try populate(root, small, tokenizer: false)
        #expect(!ModelCatalog.isInstalled(small, in: root))
        try populate(root, small)
        #expect(ModelCatalog.isInstalled(small, in: root))
    }

    @Test func aDownloadThatStoppedHalfwayIsNotInstalled() throws {
        let root = try makeRoot("partial"); defer { try? FileManager.default.removeItem(at: root) }
        let small = try #require(ModelCatalog.variant(id: "openai_whisper-small"))
        try populate(root, small, parts: ["AudioEncoder", "MelSpectrogram"]) // the text decoder never arrived
        #expect(!ModelCatalog.isInstalled(small, in: root))
        #expect(!ModelCatalog.canInstall(small, from: root))
        try populate(root, small)
        #expect(ModelCatalog.isInstalled(small, in: root))
    }

    @Test func installingClonesTheModelAndTheTokenizerAndLeavesTheSourceAlone() throws {
        let source = try makeRoot("source"), root = try makeRoot("root")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        let small = try #require(ModelCatalog.variant(id: "openai_whisper-small"))
        try populate(source, small)
        #expect(ModelCatalog.canInstall(small, from: source))
        try ModelCatalog.install(small, from: source, into: root)
        #expect(ModelCatalog.isInstalled(small, in: root))
        let copied = ModelCatalog.modelFolder(small, in: root).appendingPathComponent("AudioEncoder.mlmodelc/weight.bin")
        #expect(try Data(contentsOf: copied) == Data("weights".utf8))
        #expect(ModelCatalog.isInstalled(small, in: source)) // the original stays
        try ModelCatalog.install(small, from: source, into: root) // installing again is harmless
    }

    @Test func installingWithoutASourceFailsClearly() throws {
        let source = try makeRoot("empty"), root = try makeRoot("root")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: root) }
        let small = try #require(ModelCatalog.variant(id: "openai_whisper-small"))
        #expect(!ModelCatalog.canInstall(small, from: source))
        #expect(throws: ModelCatalog.InstallError.self) { try ModelCatalog.install(small, from: source, into: root) }
        #expect(!ModelCatalog.isInstalled(small, in: root))
    }
}
