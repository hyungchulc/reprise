import RepriseCore
import SwiftUI

/// Fast mode for the chosen model. Turning it on asks first, because it costs more or uses the
/// plan's limits faster.
struct FastModeSwitch: View {
    @ObservedObject var model: AppModel
    /// The search bar's bolt button rather than the Settings row.
    var compact = false
    @State private var confirming = false

    var body: some View {
        let isOn = Binding(get: { model.fastOn }, set: { on in if on { confirming = true } else { model.setFast(false) } })
        Group {
            if compact {
                Toggle(isOn: isOn) { Label("Fast", systemImage: model.fastOn ? "bolt.fill" : "bolt") }
                    .toggleStyle(.button).help(model.fastOn ? "Fast mode is on" : "Fast mode")
            } else {
                Toggle("Fast mode", isOn: isOn)
            }
        }
        .alert("Turn on Fast mode?", isPresented: $confirming) {
            Button("Turn On") { model.setFast(true) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(model.fastWarning) }
    }
}

/// How much of the model's context window the answering request filled.
struct ContextRing: View {
    let context: AIContextUse

    var body: some View {
        HStack(spacing: 4) {
            if let fraction = context.fraction {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.03, fraction))
                        .stroke(fraction > 0.8 ? Color.orange : Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }.frame(width: 11, height: 11)
                Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            } else {
                // Without the model's window there is nothing to fill; the count alone stays honest.
                Text("\(context.tokens.formatted(.number.notation(.compactName))) tokens").monospacedDigit()
            }
        }
        .foregroundStyle(.secondary).help(label).accessibilityElement(children: .ignore).accessibilityLabel(label)
    }

    private var label: String {
        let tokens = context.tokens.formatted(.number.notation(.compactName))
        guard let window = context.window else { return "Context: \(tokens) tokens sent; the model's window is not reported" }
        return "Context: \(tokens) of \(window.formatted(.number.notation(.compactName))) tokens. Reprise sends only the last turns and fresh excerpts, so it never fills up over a conversation."
    }
}
