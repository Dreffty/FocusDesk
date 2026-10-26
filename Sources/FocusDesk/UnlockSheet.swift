import AppKit
import FocusCore
import SwiftUI

/// The code you have to type to leave a session you asked to protect. The point is not security — it is the
/// thirty seconds of deliberate typing, which is usually longer than the urge lasts.
struct UnlockSheet: View {
    @ObservedObject var model: AppModel
    @FocusState private var fieldFocused: Bool

    private var challenge: PendingStopChallenge? { model.pendingStop }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let challenge {
                header(challenge)
                codeDisplay(challenge)
                field(challenge)
                footer(challenge)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Palette.background)
        .tint(Palette.mint)
        .onAppear { fieldFocused = true }
    }

    @ViewBuilder private func header(_ challenge: PendingStopChallenge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: challenge.emergency ? "exclamationmark.shield.fill" : "lock.shield")
                    .foregroundStyle(challenge.emergency ? Palette.warning : Palette.mint)
                Text(challenge.title).font(.app(20, weight: .semibold, design: .rounded))
            }
            if let ruleChange = challenge.generalRule {
                Text(generalRuleLine(ruleChange, challenge: challenge))
                    .font(.app(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let change = challenge.runUp {
                Text(runUpLine(change, challenge: challenge))
                    .font(.app(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let session = model.session {
                Text(remainingLine(for: session))
                    .font(.app(12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func generalRuleLine(_ change: GeneralRuleChange, challenge: PendingStopChallenge) -> String {
        let rule = change.rule
        let action = challenge.generalRuleAction.prefix(1).lowercased() + challenge.generalRuleAction.dropFirst()
        if challenge.emergency {
            return "«\(rule.name)» está activa en «Hasta el final». Para \(action) usa esta salida de emergencia, que queda anotada."
        }
        return "«\(rule.name)» está activa y protegida. Teclea el código si de verdad quieres \(action)."
    }

    private func runUpLine(_ change: RunUpChange, challenge: PendingStopChallenge) -> String {
        let task = change.task
        let time = task.scheduledAt.formatted(date: .omitted, time: .shortened)
        let action = challenge.runUpAction.prefix(1).lowercased() + challenge.runUpAction.dropFirst()
        let when = task.scheduledAt > Date() ? "empieza a las \(time)" : "era a las \(time)"
        if challenge.emergency {
            return "«\(task.title)» \(when) y está en «Hasta el final». Para \(action) queda esta salida, y queda anotada."
        }
        return "«\(task.title)» \(when) y ya está protegida. Teclea el código si de verdad quieres \(action)."
    }

    private func remainingLine(for session: WorkSession) -> String {
        let left = FocusRules.clock(max(0, model.currentRemaining(for: session)))
        if challenge?.emergency == true {
            return "«\(session.task.title)» está en «Hasta el final» y le quedan \(left). Esta salida queda anotada."
        }
        return "«\(session.task.title)» tiene \(left) por delante. Teclea el código si de verdad quieres dejarlo ahora."
    }

    /// The code itself, with what has already been typed right shown in the accent colour.
    @ViewBuilder private func codeDisplay(_ challenge: PendingStopChallenge) -> some View {
        let correct = challenge.correctSoFar
        let characters = Array(challenge.expected)
        Text(
            characters.enumerated().reduce(into: AttributedString()) { result, pair in
                var piece = AttributedString(String(pair.element))
                piece.foregroundColor = pair.offset < correct ? Palette.mint : Palette.text
                result += piece
            }
        )
        .font(.system(size: 17, weight: .regular, design: .monospaced))
        .textSelection(.disabled)
        .lineSpacing(5)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.elevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.stroke))
        .accessibilityLabel("Código a teclear")
        .accessibilityValue(challenge.expected.map(String.init).joined(separator: " "))
    }

    @ViewBuilder private func field(_ challenge: PendingStopChallenge) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Tecléalo aquí", text: Binding(
                get: { model.pendingStop?.typed ?? "" },
                set: { newValue in
                    guard var pending = model.pendingStop else { return }
                    // Pasting would defeat the whole point, so a jump of several characters at once is refused.
                    if newValue.count > pending.typed.count + 2 {
                        model.notice = "Pegar no vale: el código se teclea."
                        return
                    }
                    pending.typed = String(newValue.prefix(pending.expected.count))
                    model.pendingStop = pending
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 15, design: .monospaced))
            .focused($fieldFocused)
            .onSubmit { model.submitStopChallenge() }
            .accessibilityLabel("Escribe el código")

            HStack(spacing: 8) {
                ProgressView(value: Double(challenge.correctSoFar), total: Double(max(1, challenge.expected.count)))
                    .tint(Palette.mint)
                Text("\(challenge.correctSoFar) / \(challenge.expected.count)")
                    .font(.app(10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .monospacedDigit()
            }
            if challenge.attempts > 0 {
                Text(challenge.attempts == 1
                     ? "Fallaste una vez y el código cambió. Tómatelo con calma."
                     : "\(challenge.attempts) intentos fallidos. Cada fallo da un código nuevo.")
                    .font(.app(10))
                    .foregroundStyle(Palette.warning)
            }
        }
    }

    @ViewBuilder private func footer(_ challenge: PendingStopChallenge) -> some View {
        HStack {
            Button(challenge.generalRule != nil || challenge.runUp != nil ? "Dejarla como está" : "Seguir trabajando") {
                model.dismissStopChallenge()
            }
            .buttonStyle(.focusSecondary)
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button(challenge.quitAfter ? "Salir de FocusDesk"
                   : challenge.generalRule != nil ? challenge.generalRuleAction
                   : challenge.runUp != nil ? challenge.runUpAction
                   : buttonTitle(challenge.reason)) {
                model.submitStopChallenge()
            }
            .buttonStyle(FocusPrimaryButton())
            .disabled(!challenge.complete)
        }
    }

    private func buttonTitle(_ reason: StopReason) -> String {
        switch reason {
        case .pause: return "Pausar"
        case .cancel: return "Cancelar la sesión"
        case .finishEarly: return "Terminar ahora"
        }
    }
}
