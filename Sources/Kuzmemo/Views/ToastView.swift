import KuzmemoCore
import SwiftUI

/// The result of the last command: what was saved (with Undo), an answer, a question or an error.
struct ToastView: View {
    let toast: AppEnvironment.Toast
    let env: AppEnvironment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(toast.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !toast.options.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(toast.options, id: \.self) { option in
                            Button { Task { await env.voice.choose(option) } } label: {
                                Text(verbatim: option).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if toast.undoOpID != nil || toast.editItemID != nil {
                    HStack(spacing: 14) {
                        if let opID = toast.undoOpID { Button(tr("Undo")) { Task { await env.undo(opID: opID) } } }
                        if let itemID = toast.editItemID { Button(tr("Edit")) { env.openEditor(itemID: itemID) } }
                    }
                    .buttonStyle(.link).font(.callout)
                }
            }
            Spacer(minLength: 0)
            Button { env.dismissToast() } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel(tr("Dismiss"))
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var symbol: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .question: "questionmark.circle.fill"
        case .answer: "text.bubble.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .success: .green
        case .question: .blue
        case .answer: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
