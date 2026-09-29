import KuzmemoCore
import KuzmemoSTT
import SwiftUI

/// Speech recognition: which model, which language, how long it stays in memory, and a check with the microphone.
struct RecognitionSettingsTab: View {
    let env: AppEnvironment
    @State private var installed = RecognitionSettingsTab.installedNow()
    @State private var installing: String?
    @State private var installError: String?
    @State private var tester = RecognitionTester()

    var body: some View {
        @Bindable var settings = env.settings
        Form {
            Section("Модель распознавания речи") {
                ForEach(ModelCatalog.variants) { variant in
                    ModelRow(
                        variant: variant, selected: settings.recognition.modelVariant == variant.id,
                        installed: installed.contains(variant.id), canInstall: ModelCatalog.canInstall(variant),
                        installing: installing == variant.id,
                        select: { settings.recognition.modelVariant = variant.id },
                        install: { install(variant) }
                    )
                }
                LabeledContent("Сейчас") { Text(verbatim: env.voice.modelSummary).foregroundStyle(.secondary) }
                if let installError { Text(verbatim: installError).font(.caption).foregroundStyle(.red) }
                Hint("Первая загрузка новой модели на этом Mac занимает до пары минут (Core ML готовит её один раз), потом около секунды. Устанавливается копированием из папки «Документы/huggingface»: macOS один раз спросит доступ к «Документам».")
            }
            Section("Проверка") {
                HStack {
                    Button { Task { await tester.run(env: env) } } label: { Label("Проверить микрофон и распознавание", systemImage: "mic.fill") }
                        .disabled(tester.isBusy)
                    Spacer()
                    Text("5 секунд").font(.caption).foregroundStyle(.secondary)
                }
                testOutput
            }
            Section("Язык") {
                Picker("Язык речи", selection: Binding(
                    get: { settings.recognition.language ?? "auto" },
                    set: { settings.recognition.language = $0 == "auto" ? nil : $0 }
                )) {
                    Text("Русский").tag("ru")
                    Text("Определять автоматически").tag("auto")
                }
                Hint("Русский надёжнее: при автоопределении короткие фразы иногда принимаются за английские.")
            }
            Section("Память") {
                Picker("Выгружать модель после простоя", selection: $settings.recognition.idleUnloadMinutes) {
                    Text("5 минут").tag(5)
                    Text("15 минут").tag(15)
                    Text("30 минут").tag(30)
                    Text("1 час").tag(60)
                    Text("Никогда").tag(0)
                }
                Hint("Загруженная модель занимает около 1,5 ГБ памяти. Следующая запись после выгрузки начнётся как обычно: модель загрузится, пока вы говорите.")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    @ViewBuilder private var testOutput: some View {
        switch tester.state {
        case .idle:
            Hint("Скажите что-нибудь после нажатия: покажу, что услышала модель и сколько это заняло.")
        case let .recording(elapsed, total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: elapsed, total: total)
                ProgressView(value: Double(min(1, tester.level * 10)), total: 1).tint(.red)
                Hint("Говорите…")
            }
        case .recognizing:
            HStack { ProgressView().controlSize(.small); Text("Распознаю…") }
        case let .done(text, audioSeconds, milliseconds):
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "«\(text)»").textSelection(.enabled)
                Hint("Запись \(Self.seconds(audioSeconds)), распознано за \(Self.seconds(Double(milliseconds) / 1000)).")
            }
        case let .nothingHeard(reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Речь не услышана", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Hint("Проверьте, какой микрофон выбран в Системных настройках → Звук → Ввод. (\(reason))")
            }
        case let .failed(message):
            Text(verbatim: message).font(.callout).foregroundStyle(.red)
        }
    }

    private static func seconds(_ value: Double) -> String {
        String(format: "%.1f с", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func installedNow() -> Set<String> {
        Set(ModelCatalog.variants.filter { ModelCatalog.isInstalled($0) }.map(\.id))
    }

    private func refresh() {
        installed = Self.installedNow()
    }

    private func install(_ variant: ModelVariant) {
        installing = variant.id
        installError = nil
        Task {
            let failure = await Task.detached { () -> String? in
                do { try ModelCatalog.install(variant); return nil } catch { return "\(error)" }
            }.value
            installing = nil
            refresh()
            if let failure { installError = "Не удалось установить модель: \(failure)" }
        }
    }
}

private struct ModelRow: View {
    let variant: ModelVariant
    let selected: Bool
    let installed: Bool
    let canInstall: Bool
    let installing: Bool
    let select: () -> Void
    let install: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(installed ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!installed)
            .accessibilityLabel(selected ? "Выбрана" : "Выбрать")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(variant.title) · \(Self.size(variant.sizeMB))").fontWeight(selected ? .semibold : .regular)
                Text(verbatim: variant.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installing {
                ProgressView().controlSize(.small)
                Text("Копирую…").font(.caption).foregroundStyle(.secondary)
            } else if installed {
                Text(selected ? "Используется" : "Установлена").font(.caption).foregroundStyle(.secondary)
            } else if canInstall {
                Button("Установить", action: install)
            } else {
                Text("нет копии для установки").font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if installed { select() } }
    }

    private static func size(_ megabytes: Int) -> String {
        megabytes >= 1000 ? String(format: "%.1f ГБ", Double(megabytes) / 1000).replacingOccurrences(of: ".", with: ",") : "\(megabytes) МБ"
    }
}
