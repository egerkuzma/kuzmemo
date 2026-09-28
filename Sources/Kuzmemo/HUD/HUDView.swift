import KuzmemoCore
import SwiftUI

struct HUDView: View {
    let model: HUDModel
    var actions = HUDActions()

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minWidth: 280, maxWidth: 520, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.10)))
            .onHover { model.hovering = $0 }
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()
        case .preparingModel:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Подготовка распознавания…").font(.callout.weight(.semibold))
                    Text("Первый запуск: один раз, до пары минут").font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .recording(handsFree):
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 10, height: 10)
                LevelBars(level: model.level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.clock(model.elapsed)).font(.callout.monospacedDigit().weight(.semibold))
                    Text(handsFree ? "Идёт запись. Нажмите Fn, чтобы закончить" : "Говорите… отпустите Fn, когда закончите")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: actions.cancel) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Отменить запись")
                    .accessibilityLabel("Отменить запись")
            }
        case .transcribing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Распознаю…").font(.callout.weight(.semibold))
            }
        case let .interpreting(text):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Думаю…").font(.callout.weight(.semibold))
                }
                Text(verbatim: "«\(text)»").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        case let .result(toast):
            ResultContent(toast: toast, actions: actions)
        case let .note(text, style):
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(style)).foregroundStyle(Self.tint(style))
                Text(verbatim: text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func symbol(_ style: AppEnvironment.Toast.Style) -> String {
        switch style {
        case .success: "checkmark.circle.fill"
        case .question: "questionmark.circle.fill"
        case .answer: "text.bubble.fill"
        case .warning: "exclamationmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    static func tint(_ style: AppEnvironment.Toast.Style) -> Color {
        switch style {
        case .success: .green
        case .question: .blue
        case .answer: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct LevelBars: View {
    let level: Float
    private static let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.5]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(Self.weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(.red.opacity(0.85))
                    .frame(width: 3, height: 5 + CGFloat(min(1, level * 10)) * 20 * weight)
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

private struct ResultContent: View {
    let toast: AppEnvironment.Toast
    let actions: HUDActions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: HUDView.symbol(toast.style)).foregroundStyle(HUDView.tint(toast.style)).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(toast.lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !toast.options.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(toast.options, id: \.self) { option in
                            Button(option) { actions.choose(option) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                if let opID = toast.undoOpID {
                    Button("Отменить") { actions.undo(opID) }.buttonStyle(.link).font(.callout)
                }
            }
        }
    }
}
