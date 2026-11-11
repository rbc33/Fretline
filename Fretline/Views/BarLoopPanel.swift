import SwiftUI

/// Panel del modo «Compases»: tocar un compás para empezar y otro para terminar
/// (o arrastrar de uno a otro) y se repiten en bucle. Se puede ajustar el inicio y el fin
/// y mover el bucle entero al grupo anterior o siguiente.
struct BarLoopPanel: View {
    let engine: TabEngine
    @Binding var looping: Bool
    var onDone: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).monospacedDigit()
                Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: 300, alignment: .leading)

            Spacer()

            if let range = engine.barSelection {
                stepper(label: "Start", value: range.lowerBound + 1,
                        minus: { engine.adjustBarSelection(start: -1) },
                        plus: { engine.adjustBarSelection(start: 1) },
                        canMinus: range.lowerBound > 0,
                        canPlus: range.lowerBound < range.upperBound)

                stepper(label: "End", value: range.upperBound + 1,
                        minus: { engine.adjustBarSelection(end: -1) },
                        plus: { engine.adjustBarSelection(end: 1) },
                        canMinus: range.upperBound > range.lowerBound,
                        canPlus: engine.barCount == 0 || range.upperBound < engine.barCount - 1)

                HStack(spacing: 4) {
                    Button { engine.shiftBarSelection(-1) } label: { Image(systemName: "chevron.left.2") }
                        .help("Previous loop")
                        .disabled(range.lowerBound == 0)
                    Button { engine.shiftBarSelection(1) } label: { Image(systemName: "chevron.right.2") }
                        .help("Next loop")
                        .disabled(engine.barCount > 0 && range.upperBound >= engine.barCount - 1)
                }
                .buttonStyle(.bordered)

                Toggle(isOn: $looping) { Label("Repeat", systemImage: "repeat") }
                    .toggleStyle(.button)

                Button(role: .destructive) {
                    engine.clearSelection()
                    looping = false
                } label: { Image(systemName: "xmark.circle") }
                    .help("Clear selection")
            }

            Button("Done", action: onDone).bold()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var title: String {
        guard let r = engine.barSelection else { return "Loop bars" }
        if engine.waitingForBarEnd { return "From bar \(r.lowerBound + 1)…" }
        return r.count == 1 ? "Bar \(r.lowerBound + 1)" : "Bars \(r.lowerBound + 1)–\(r.upperBound + 1)"
    }

    private var hint: String {
        if engine.barSelection == nil {
            return "Tap the first bar, then the last one, or drag across them."
        }
        if engine.waitingForBarEnd {
            return "Tap the last bar of the loop (or press play to loop just this one)."
        }
        return "Tap another bar to start a new selection."
    }

    private func stepper(label: String, value: Int,
                         minus: @escaping () -> Void, plus: @escaping () -> Void,
                         canMinus: Bool, canPlus: Bool) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button(action: minus) { Image(systemName: "minus") }.disabled(!canMinus)
                Text("\(value)").monospacedDigit().frame(minWidth: 28)
                Button(action: plus) { Image(systemName: "plus") }.disabled(!canPlus)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
