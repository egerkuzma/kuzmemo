import AppKit
import KuzmemoCore
import SwiftUI

/// Where the data lives, whether it is sound, the copies kept of it, and a way to start over.
struct DataSettingsTab: View {
    let env: AppEnvironment
    @State private var confirmErase = false

    private var data: DataMaintenance { env.data }
    private var busyWithPhrase: Bool { env.status == .recording || env.status == .thinking }

    /// How many copies the list shows before "and N older ones".
    private static let shownCopies = 8

    var body: some View {
        Form {
            if let attention = data.attention {
                Section {
                    Label {
                        Text(verbatim: attention).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }
            }
            Section(tr("Database")) {
                LabeledContent(tr("Location")) {
                    HStack {
                        Text(verbatim: env.paths.database.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button(tr("Show")) { NSWorkspace.shared.activateFileViewerSelecting([env.paths.database]) }
                    }
                }
                LabeledContent(tr("Contents")) {
                    Text(verbatim: contents).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                LabeledContent(tr("Size")) {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: data.databaseBytes, countStyle: .file)).foregroundStyle(.secondary)
                }
                LabeledContent(tr("Integrity")) {
                    HStack {
                        health
                        Button(tr("Check now")) { Task { await data.check() } }.disabled(data.isWorking)
                    }
                }
                if data.integrity?.searchIndexRebuilt == true {
                    Hint(tr("The search index did not match the entries and was rebuilt. Nothing was lost."))
                }
                Hint(tr("The database is checked shortly after every launch. Entries, the glossary and settings are stored on this Mac only. Audio is deleted right after transcription; only the text of the phrase is sent to Anthropic."))
            }
            Section(tr("Backups")) {
                Hint(tr("A copy of the database is saved once a day and the last %1$lld are kept. Copies made by hand, and the one made before an erase, are kept separately.", numbers: BackupService.dailyKeep))
                if data.copies.isEmpty {
                    Text(tr("No copies yet")).foregroundStyle(.secondary)
                } else {
                    ForEach(data.copies.prefix(Self.shownCopies)) { copy in
                        LabeledContent {
                            Text(verbatim: ByteCountFormatter.string(fromByteCount: copy.bytes, countStyle: .file)).foregroundStyle(.secondary)
                        } label: {
                            HStack(spacing: 6) {
                                Text(verbatim: DataMaintenance.describe(copy))
                                Text(verbatim: DataMaintenance.title(of: copy.reason)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if data.copies.count > Self.shownCopies {
                        Hint(tr("and %1$lld older ones", numbers: data.copies.count - Self.shownCopies))
                    }
                }
                HStack {
                    Button(tr("Back up now")) { Task { await data.backUpNow() } }.disabled(data.isWorking)
                    Button(tr("Show in Finder")) { data.showBackups() }
                    if data.isBackingUp { ProgressView().controlSize(.small) }
                }
                if let notice = data.notice {
                    Text(verbatim: notice.text).font(.caption).foregroundStyle(notice.style == .failure ? Color.red : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Hint(tr("To go back to a copy: quit Kuzmemo, replace kuzmemo.sqlite with the copy and delete kuzmemo.sqlite-wal and kuzmemo.sqlite-shm next to it."))
            }
            Section(tr("Start over")) {
                HStack {
                    Button(role: .destructive) { confirmErase = true } label: { Text(tr("Erase all entries and history…")) }
                        .disabled(data.isWorking || busyWithPhrase)
                    if data.isErasing { ProgressView().controlSize(.small) }
                }
                Hint(tr("Removes every entry, saved phrase and undo step. Settings and the glossary stay. A copy of the database is saved first, so this can be taken back from the backups folder."))
            }
        }
        .formStyle(.grouped)
        .task { await data.refresh() }
        .onAppear { data.markRecoverySeen() }
        .onDisappear { data.clearNotice() }
        .confirmationDialog(tr("Erase all entries and history?"), isPresented: $confirmErase, titleVisibility: .visible) {
            Button(tr("Erase"), role: .destructive) { Task { _ = await env.eraseEntriesAndHistory() } }
            Button(tr("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: tr(
                "This removes %1$@ and %2$@, and the undo history. Settings and the glossary stay. A copy of the database is saved first.",
                trCount("%lld entries", data.overview?.entries ?? 0), trCount("%lld saved phrases", data.overview?.memos ?? 0)
            ))
        }
    }

    // MARK: Pieces

    private var contents: String {
        guard let overview = data.overview else { return "…" }
        return tr(
            "%1$@, %2$@, %3$@",
            trCount("%lld entries", overview.entries), trCount("%lld saved phrases", overview.memos),
            trCount("%lld glossary words", overview.glossaryTerms)
        )
    }

    @ViewBuilder private var health: some View {
        if data.isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(tr("Checking…")).foregroundStyle(.secondary)
            }
        } else if data.checkCouldNotRun {
            Label(tr("Could not check just now"), systemImage: "questionmark.circle").foregroundStyle(.secondary)
        } else if let report = data.integrity {
            if report.isHealthy {
                let time = Wording.time(LocalDateTime(date: report.checkedAt, in: env.clock.timeZone).time)
                Label(tr("No problems, checked at %1$@", time), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label(tr("Problems found"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
        } else {
            Text(tr("Not checked yet")).foregroundStyle(.secondary)
        }
    }
}
