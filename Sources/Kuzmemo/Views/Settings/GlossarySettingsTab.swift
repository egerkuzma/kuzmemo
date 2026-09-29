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
    @State private var probe = tr("check the notion access")
    @State private var message: String?

    struct TermEditorRequest: Identifiable {
        var term: GlossaryTerm
        var isNew: Bool
        var id: String { isNew ? "new" : "\(term.id ?? 0)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Words that are often misheard")).font(.headline)
                Hint(tr("Speech recognition may write “git hub” where you need “GitHub”. Each word listed here is corrected in your phrase before Claude sees it, and the voice says it the way you specify."))
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Divider()
            if terms.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "character.book.closed").font(.largeTitle).foregroundStyle(.tertiary)
                    Text(tr("The glossary is empty")).foregroundStyle(.secondary)
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
            Text(tr("Try it")).font(.subheadline.weight(.semibold))
            TextField(tr("A phrase as speech recognition heard it"), text: $probe)
            let fixed = Glossary.applyAliases(to: probe, terms: terms)
            HStack(alignment: .firstTextBaseline) {
                Text(tr("Becomes:")).foregroundStyle(.secondary)
                Text(verbatim: fixed).textSelection(.enabled)
                Spacer()
                Button { env.voice.previewSpeech(Glossary.spokenForm(of: fixed, terms: terms)) } label: { Label(tr("How it will sound"), systemImage: "play.fill") }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { editing = TermEditorRequest(term: GlossaryTerm(canonical: ""), isNew: true) } label: { Label(tr("Add a word"), systemImage: "plus") }
                Button(tr("Export…"), action: exportTerms)
                Button(tr("Import…"), action: importTerms)
                Spacer()
                if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 4) {
                Hint(tr("Stored in the app’s database, not in a file:"))
                Button(tr("show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([env.paths.database]) }
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
            message = tr("Saved: %1$lld", numbers: items.count)
        } catch {
            message = tr("Could not save: %1$@", "\(error.localizedDescription)")
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
                message = tr("Added: %1$lld, updated: %2$lld", numbers: added, updated)
            }
        } catch {
            message = tr("Could not read the file: %1$@", "\(error.localizedDescription)")
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
                Text(verbatim: term.aliases.isEmpty ? tr("no spelling variants") : tr("heard as: %1$@", term.aliases.joined(separator: ", ")))
                    .font(.caption).foregroundStyle(.secondary)
                if let spoken = term.spoken, !spoken.isEmpty {
                    Text(verbatim: tr("spoken as: %1$@", "\(spoken)")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: speak) { Image(systemName: "speaker.wave.2") }.buttonStyle(.borderless).help(tr("How it sounds"))
            Button(tr("Edit…"), action: edit).controlSize(.small)
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help(tr("Delete"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .confirmationDialog(tr("Delete “%1$@” from the glossary?", "\(term.canonical)"), isPresented: $confirmDelete) {
            Button(tr("Delete"), role: .destructive, action: delete)
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
            Text(request.isNew ? tr("New word") : tr("Edit word")).font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Spelling")).font(.subheadline.weight(.semibold))
                TextField(tr("For example: GitHub"), text: $canonical)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("How recognition hears it")).font(.subheadline.weight(.semibold))
                TextEditor(text: $aliasesText)
                    .font(.body)
                    .frame(height: 78)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                Hint(tr("Put each variant on a new line or separate them with commas: “git hub”, “gethub”."))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("How the voice says it")).font(.subheadline.weight(.semibold))
                HStack {
                    TextField(tr("For example: Git Hub"), text: $spoken)
                    Button { env.voice.previewSpeech(spoken.isEmpty ? canonical : spoken) } label: { Image(systemName: "speaker.wave.2") }
                        .help(tr("Listen"))
                }
                Hint(tr("Leave empty if the voice already reads the word correctly."))
            }
            if let problem { Text(verbatim: problem).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(tr("Cancel")) { done(false) }.keyboardShortcut(.cancelAction)
                Button(tr("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        let name = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { problem = tr("Type the word."); return }
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
                problem = tr("This word is already in the glossary.")
            }
        }
    }
}
