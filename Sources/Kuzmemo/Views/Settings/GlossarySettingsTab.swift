import AppKit
import KuzmemoCore
import SwiftUI
import UniformTypeIdentifiers

/// The glossary: the words the recognizer tends to get wrong (brand and people names), how they are written, and how a
/// voice should say them. It lives in the app's database; this is where it is edited.
struct GlossarySettingsTab: View {
    let env: AppEnvironment
    @State private var terms: [GlossaryTerm] = []
    @State private var editing: TermEditorRequest?
    @State private var probe = "проверить доступ Нотиона и фигмы"
    @State private var message: String?

    struct TermEditorRequest: Identifiable {
        var term: GlossaryTerm
        var isNew: Bool
        var id: String { isNew ? "new" : "\(term.id ?? 0)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Слова, которые часто искажаются").font(.headline)
                Hint("Распознавание слышит «нотиона», а нужно «Notion». Каждое слово здесь исправляется в вашей фразе до того, как её увидит Claude, а голос произносит его так, как вы указали.")
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Divider()
            if terms.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "character.book.closed").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Глоссарий пуст").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(terms) { term in
                            TermRow(
                                term: term, edit: { editing = TermEditorRequest(term: term, isNew: false) },
                                toggle: { enabled in save(term, enabled: enabled) }, delete: { remove(term) },
                                speak: { speak(term) }
                            )
                            Divider().padding(.leading, 20)
                        }
                    }
                }
            }
            Divider()
            probeSection
            Divider()
            footer
        }
        .sheet(item: $editing) { request in
            GlossaryTermEditor(request: request, env: env) { saved in
                editing = nil
                if saved { Task { await reload() } }
            }
        }
        .task { await reload() }
    }

    // MARK: Pieces

    private var probeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Проверка").font(.subheadline.weight(.semibold))
            TextField("Фраза, как её услышало распознавание", text: $probe)
            let fixed = Glossary.applyAliases(to: probe, terms: terms)
            HStack(alignment: .firstTextBaseline) {
                Text("Станет:").foregroundStyle(.secondary)
                Text(verbatim: fixed).textSelection(.enabled)
                Spacer()
                Button { env.voice.previewSpeech(Glossary.spokenForm(of: fixed, terms: terms)) } label: { Label("Как прозвучит", systemImage: "play.fill") }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { editing = TermEditorRequest(term: GlossaryTerm(canonical: ""), isNew: true) } label: { Label("Добавить слово", systemImage: "plus") }
                Button("Экспорт…", action: exportTerms)
                Button("Импорт…", action: importTerms)
                Spacer()
                if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                Hint("Хранится в базе данных приложения, не в файле:")
                Button("показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([env.paths.database]) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    // MARK: Data

    private func reload() async {
        terms = (try? await env.store.glossary()) ?? []
    }

    private func save(_ term: GlossaryTerm, enabled: Bool) {
        var updated = term
        updated.enabled = enabled
        Task { _ = try? await env.store.save(term: updated); await reload() }
    }

    private func remove(_ term: GlossaryTerm) {
        guard let id = term.id else { return }
        Task { try? await env.store.deleteTerm(id: id); await reload() }
    }

    private func speak(_ term: GlossaryTerm) {
        env.voice.previewSpeech((term.spoken?.isEmpty == false ? term.spoken : nil) ?? term.canonical)
    }

    private struct ExportedTerm: Codable {
        var canonical: String
        var kind: String?
        var aliases: [String]
        var spoken: String?
        var enabled: Bool
    }

    private func exportTerms() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Kuzmemo-glossary.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let items = terms.map { ExportedTerm(canonical: $0.canonical, kind: $0.kind, aliases: $0.aliases, spoken: $0.spoken, enabled: $0.enabled) }
        do {
            try encoder.encode(items).write(to: url, options: .atomic)
            message = "Сохранено: \(items.count)"
        } catch {
            message = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    private func importTerms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let items = try JSONDecoder().decode([ExportedTerm].self, from: Data(contentsOf: url))
            Task {
                var added = 0, updated = 0
                for item in items where !item.canonical.trimmingCharacters(in: .whitespaces).isEmpty {
                    var term = terms.first { $0.canonical.lowercased() == item.canonical.lowercased() }
                    if term == nil { added += 1 } else { updated += 1 }
                    term = GlossaryTerm(
                        id: term?.id, canonical: item.canonical, kind: item.kind, aliases: item.aliases, spoken: item.spoken, enabled: item.enabled
                    )
                    if let term { _ = try? await env.store.save(term: term) }
                }
                await reload()
                message = "Добавлено: \(added), обновлено: \(updated)"
            }
        } catch {
            message = "Не удалось прочитать файл: \(error.localizedDescription)"
        }
    }
}

private struct TermRow: View {
    let term: GlossaryTerm
    let edit: () -> Void
    let toggle: (Bool) -> Void
    let delete: () -> Void
    let speak: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { term.enabled }, set: { toggle($0) })).labelsHidden().toggleStyle(.switch).controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: term.canonical).fontWeight(.medium).foregroundStyle(term.enabled ? .primary : .secondary)
                Text(verbatim: term.aliases.isEmpty ? "нет вариантов написания" : "слышится как: " + term.aliases.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                if let spoken = term.spoken, !spoken.isEmpty {
                    Text(verbatim: "читается: \(spoken)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: speak) { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless).help("Как звучит")
            Button("Изменить…", action: edit).controlSize(.small)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Удалить")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .confirmationDialog("Удалить «\(term.canonical)» из глоссария?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive, action: delete)
        }
    }
}

/// Adding or changing one glossary word.
private struct GlossaryTermEditor: View {
    let request: GlossarySettingsTab.TermEditorRequest
    let env: AppEnvironment
    let done: (_ saved: Bool) -> Void
    @State private var canonical: String
    @State private var aliasesText: String
    @State private var spoken: String
    @State private var problem: String?

    init(request: GlossarySettingsTab.TermEditorRequest, env: AppEnvironment, done: @escaping (Bool) -> Void) {
        self.request = request
        self.env = env
        self.done = done
        _canonical = State(initialValue: request.term.canonical)
        _aliasesText = State(initialValue: request.term.aliases.joined(separator: "\n"))
        _spoken = State(initialValue: request.term.spoken ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.isNew ? "Новое слово" : "Изменить слово").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Как писать").font(.subheadline.weight(.semibold))
                TextField("Например: Notion", text: $canonical)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Как это слышит распознавание").font(.subheadline.weight(.semibold))
                TextEditor(text: $aliasesText)
                    .font(.body)
                    .frame(height: 78)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                Hint("Каждый вариант с новой строки или через запятую: «нотион», «ношн», «нотиона».")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Как произносить голосом").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("Например: Нотион", text: $spoken)
                    Button { env.voice.previewSpeech(spoken.isEmpty ? canonical : spoken) } label: { Image(systemName: "speaker.wave.2") }
                        .help("Прослушать")
                }
                Hint("Оставьте пустым, если голос и так читает слово правильно.")
            }
            if let problem { Text(verbatim: problem).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let name = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { problem = "Напишите слово."; return }
        let aliases = aliasesText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var term = request.term
        term.canonical = name
        term.aliases = aliases
        let voice = spoken.trimmingCharacters(in: .whitespaces)
        term.spoken = voice.isEmpty ? nil : voice
        Task {
            do {
                _ = try await env.store.save(term: term)
                done(true)
            } catch {
                problem = "Такое слово уже есть в глоссарии."
            }
        }
    }
}
