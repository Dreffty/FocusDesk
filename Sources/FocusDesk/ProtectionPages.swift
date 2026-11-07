import AppKit
import FocusCore
import SwiftUI

// The Antidistracción half of the window: «Bloquear ahora» (⌘4), «Reglas y límites» (⌘5) and «Descansos» (⌘6).
// They used to share one long «Bloqueo» page where most of them sat below the fold; each now has its own place in
// the sidebar, a command in the menu bar and an entry in ⌘K.

// MARK: - Rule kinds, told the way people say them

extension GeneralRuleKind {
    var galleryTitle: String {
        switch self {
        case .dailyLimit: return "Presupuesto de uso"
        case .pomodoro: return "Pomodoro"
        case .workGoal: return "Primero el trabajo"
        case .launchLimit: return "Visitas contadas"
        case .countdown: return "Cuenta atrás"
        case .schedule: return "Horario"
        case .alwaysOn: return "Siempre activa"
        }
    }

    var galleryExample: String {
        switch self {
        case .dailyLimit: return "20 min al día de YouTube y Shorts; luego, bloqueado."
        case .pomodoro: return "25 min de foco y 5 de descanso; si te distraes, vuelve a empezar."
        case .workGoal: return "Tras 60 min de tareas, 20 min de ocio de premio."
        case .launchLimit: return "4 visitas al día de 5 min, con 30 min de enfriamiento."
        case .countdown: return "Una cuenta atrás guardada que lanzas cuando quieras."
        case .schedule: return "De 22:30 a 7:30 todos los días, o en varios tramos."
        case .alwaysOn: return "Bloqueadas a todas horas mientras esté encendida."
        }
    }

    /// The most common first: the gallery, the «Nueva regla» pop-up, the menu bar and ⌘K all list them this way.
    static let galleryOrder: [GeneralRuleKind] = [.dailyLimit, .pomodoro, .workGoal, .launchLimit, .countdown, .schedule, .alwaysOn]
}

extension GeneralBlockRule {
    /// A starting point for each kind. It opens in the editor, so nothing is saved until the user agrees.
    static func template(_ kind: GeneralRuleKind) -> GeneralBlockRule {
        func domains(_ presets: [DistractionPreset]) -> String { presets.flatMap(\.domains).joined(separator: ", ") }
        func titles(_ presets: [DistractionPreset]) -> String { presets.flatMap(\.titleKeywords).joined(separator: ", ") }
        let noise: [DistractionPreset] = [.social, .shortVideos]
        switch kind {
        case .dailyLimit:
            return GeneralBlockRule(name: "Presupuesto diario", kind: .dailyLimit, dailyLimitMinutes: 20, webListMode: .blockListed,
                                    domains: domains([.shortVideos]), blockedTitleKeywords: titles([.shortVideos]))
        case .pomodoro:
            return GeneralBlockRule(name: "Pomodoro de enfoque", kind: .pomodoro, pomodoroWorkMinutes: 25, pomodoroShortBreakMinutes: 5,
                                    pomodoroLongBreakMinutes: 15, pomodoroLongBreakEvery: 4, pomodoroTotalCycles: 4, pomodoroPenaltyReset: true,
                                    webListMode: .blockListed, domains: domains(noise), blockedTitleKeywords: titles(noise))
        case .workGoal:
            return GeneralBlockRule(name: "Primero el trabajo, luego el ocio", kind: .workGoal, goalMinutesRequired: 60, goalRewardMinutes: 20,
                                    webListMode: .blockListed, domains: domains([.social, .streaming]), blockedTitleKeywords: titles([.social, .streaming]))
        case .launchLimit:
            return GeneralBlockRule(name: "Visitas contadas", kind: .launchLimit, maxDailyLaunches: 4, maxLaunchDurationMinutes: 5,
                                    launchCooldownMinutes: 30, webListMode: .blockListed, domains: domains([.social]))
        case .countdown:
            return GeneralBlockRule(name: "Cuenta atrás", kind: .countdown, countdownMinutes: 60, webListMode: .blockListed,
                                    domains: domains(noise), blockedTitleKeywords: titles(noise))
        case .schedule:
            return GeneralBlockRule(name: "Noche sin pantallas", kind: .schedule, startMinutes: 22 * 60 + 30, endMinutes: 7 * 60 + 30,
                                    webListMode: .blockListed, domains: domains([.social, .shortVideos, .streaming]),
                                    blockedTitleKeywords: titles([.social, .shortVideos, .streaming]))
        case .alwaysOn:
            return GeneralBlockRule(name: "Siempre bloqueadas", kind: .alwaysOn, webListMode: .blockListed,
                                    domains: domains([.shortVideos]), blockedTitleKeywords: titles([.shortVideos]))
        }
    }
}

// MARK: - Shared state for the Antidistracción pages

extension AppModel {
    static let quickBlockProtectionKey = "FocusDesk.quickBlockProtection"
    static let quickBlockPresetKey = "FocusDesk.quickBlockPreset"

    /// What «Bloquear ahora» blocks and how hard, remembered so the page, the menu bar and ⌘K start the same block.
    var quickBlockProtection: SessionProtection {
        SessionProtection(rawValue: AppPreferences.current.string(forKey: Self.quickBlockProtectionKey) ?? "") ?? .challenge
    }

    var quickBlockPreset: DistractionPreset? {
        DistractionPreset(rawValue: AppPreferences.current.string(forKey: Self.quickBlockPresetKey) ?? "")
    }

    func startQuickBlockWithSavedChoice(minutes: Int) {
        startQuickBlock(minutes: minutes, preset: quickBlockPreset, protection: quickBlockProtection)
    }

    func minutesUntilEndOfDay() -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
        return max(15, 24 * 60 - ((parts.hour ?? 0) * 60 + (parts.minute ?? 0)))
    }

    /// The countdown «Bloquear ahora» drives, while it is running.
    var runningQuickBlock: GeneralBlockRule? {
        workspace.generalRules.first { $0.name.hasPrefix("Bloqueo rápido ·") && isRuleEnforcing($0, at: now) }
    }

    /// Rules worth a line wherever «what is running» is shown: blocking, measuring use, mid-Pomodoro or paused.
    var liveGeneralRules: [GeneralBlockRule] {
        let ref = now
        return workspace.generalRules.filter { rule in
            rule.enabled && (isRuleEnforcing(rule, at: ref) || isRuleTrackingQuota(rule, at: ref) || rule.isMicroPaused(at: ref)
                || (rule.kind == .pomodoro && rule.pomodoroPhase != .idle))
        }
    }

    /// One short line on what a rule is doing now, the same in Hoy, the sidebar, «En marcha» and ⌘K.
    func liveSummary(for rule: GeneralBlockRule) -> String {
        let ref = now
        if !rule.enabled { return "Apagada" }
        if rule.isMicroPaused(at: ref) {
            return "Micro-pausa · \(FocusRules.clock(rule.activeMicroPauseDeadline?.remainingAfterPossibleReboot(wall: ref) ?? 0))"
        }
        let used = usedSecondsToday(for: rule, at: ref)
        switch rule.kind {
        case .dailyLimit:
            let left = max(0, Double(max(1, rule.dailyLimitMinutes)) * 60 - used)
            return left > 0 ? "Quedan \(FocusRules.clock(left)) de \(rule.dailyLimitMinutes) min" : "Presupuesto agotado"
        case .pomodoro:
            if rule.pomodoroPhase == .waitingForUser { return "Esperando que confirmes la siguiente fase" }
            let left = rule.activePomodoroDeadline?.remainingAfterPossibleReboot(wall: ref) ?? 0
            guard left > 0 else { return "Listo para empezar" }
            let phase = rule.pomodoroPhase.isBreak ? (rule.pomodoroPhase == .longBreak ? "Descanso largo" : "Descanso") : "Foco"
            return "\(phase) · ciclo \(rule.pomodoroCurrentCycle) de \(rule.pomodoroTotalCycles) · \(FocusRules.clock(left))"
        case .workGoal:
            let worked = effectiveWorkedSeconds(for: rule, at: ref)
            let required = Double(max(5, rule.goalMinutesRequired)) * 60
            let graceLeft = rule.postMatchGraceRemainingSeconds(at: ref)
            if graceLeft > 0 { return "Cerrando en \(Int(ceil(graceLeft))) s" }
            if isMatchInProgress(for: rule) { return "Partida en curso" }
            if worked < required { return "Faltan \(FocusRules.clock(required - worked)) de \(rule.verifyActiveStudy ? "estudio" : "trabajo")" }
            if rule.maxDailyMatches > 0 {
                let matches = matchesToday(for: rule, at: ref)
                return matches >= rule.maxDailyMatches ? "Partidas agotadas hoy" : "\(matches) de \(rule.maxDailyMatches) partidas hoy"
            }
            if rule.goalRewardMinutes <= 0 { return "Meta cumplida: libre hoy" }
            let reward = rule.remainingGoalRewardSeconds(workedTodaySeconds: worked, usedTodaySeconds: used)
            return reward > 0 ? "Premio: \(FocusRules.clock(reward))" : "Premio agotado"
        case .launchLimit:
            let visit = rule.activeLaunchDeadline?.remainingAfterPossibleReboot(wall: ref) ?? 0
            if visit > 0 { return "Visita en curso · \(FocusRules.clock(visit))" }
            let cooldown = rule.launchCooldownDeadline?.remainingAfterPossibleReboot(wall: ref) ?? 0
            if cooldown > 0 { return "Enfriamiento · \(FocusRules.clock(cooldown))" }
            let left = max(0, rule.maxDailyLaunches - launchesToday(for: rule, at: ref))
            return left > 0 ? "\(left) de \(rule.maxDailyLaunches) visitas libres hoy" : "Visitas agotadas hoy"
        case .countdown:
            let left = remainingRuleLockSeconds(rule, at: ref)
            return left > 0 ? "Quedan \(FocusRules.clock(left))" : "Lista para lanzar"
        case .schedule:
            let left = remainingRuleLockSeconds(rule, at: ref)
            return isRuleEnforcing(rule, at: ref) && left > 0 ? "Quedan \(FocusRules.clock(left)) de tramo" : rule.scheduleLabel
        case .alwaysOn:
            return "Siempre"
        }
    }

    func openRuleTemplate(_ kind: GeneralRuleKind) {
        guard !readOnly else { return }
        editingGeneralRule = .template(kind)
    }

    func showAuditLog() {
        historyShowsAudit = true
        go(to: .history)
    }
}

// MARK: - «Nueva regla»

/// The seven kinds with a line each: a pop-up from the toolbar shows what a menu could not.
struct NewRuleButton: View {
    @ObservedObject var model: AppModel
    var prominent = true
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: { Label("Nueva regla", systemImage: "plus") }
            .buttonStyle(prominent ? FocusButtonStyle(kind: .primary, compact: false) : FocusButtonStyle(kind: .secondary, compact: false))
            .disabled(model.readOnly)
            .help("Elegir qué tipo de regla crear")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(GeneralRuleKind.galleryOrder, id: \.self) { kind in
                        Button {
                            open = false
                            model.openRuleTemplate(kind)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: kind.icon).frame(width: 18).foregroundStyle(Palette.mint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(kind.galleryTitle).font(.app(13, weight: .semibold))
                                    Text(kind.galleryExample).font(.app(11)).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverHighlight()
                    }
                }
                .padding(8)
                .frame(width: 360)
            }
    }
}

// MARK: - Bloquear ahora (⌘4)

struct QuickBlockPage: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppModel.quickBlockProtectionKey, store: AppPreferences.current) private var protectionRaw = SessionProtection.challenge.rawValue
    @AppStorage(AppModel.quickBlockPresetKey, store: AppPreferences.current) private var presetRaw = ""
    @State private var tempAllowDomain = ""
    @State private var tempAllowMinutes = 10

    private var protection: Binding<SessionProtection> {
        Binding(get: { SessionProtection(rawValue: protectionRaw) ?? .challenge }, set: { protectionRaw = $0.rawValue })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            quickBlockCard
            LiveRulesCard(model: model)
            HStack(alignment: .top, spacing: 14) {
                temporaryAllowCard
                BlockingOptionsCard(model: model).frame(width: 360)
            }
        }
    }

    private var quickBlockCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Bloqueo rápido", icon: "bolt") {
                    Picker("Si quiero pararlo", selection: protection) {
                        ForEach(SessionProtection.allCases, id: \.self) { mode in Text(mode.label).tag(mode) }
                    }
                    .frame(maxWidth: 300)
                    .help(protection.wrappedValue.explanation)
                }
                if let running = model.runningQuickBlock {
                    let left = model.remainingRuleLockSeconds(running, at: model.now)
                    HStack(spacing: 12) {
                        Text(FocusRules.clock(left))
                            .font(.app(30, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.mint)
                            .modifier(CountdownTransition())
                            .accessibilityLabel("Tiempo de bloqueo restante")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bloqueando \(running.name.replacingOccurrences(of: "Bloqueo rápido · ", with: "").lowercased())")
                                .font(.app(13, weight: .semibold))
                            Text("Termina a las \(model.now.addingTimeInterval(left).formatted(date: .omitted, time: .shortened)) · \(running.protection.label)")
                                .font(.app(11))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("Apagar…") { model.toggleGeneralRule(running, enabled: false) }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .disabled(model.readOnly)
                            .help(running.protection == .none ? "Quitar el bloqueo ya" : running.protection.explanation)
                    }
                    .padding(12)
                    .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text("Una cuenta atrás que bloquea al instante, aunque no tengas ninguna tarea en la agenda.")
                        .font(.app(12))
                        .foregroundStyle(Palette.muted)
                }
                HStack(spacing: 6) {
                    Text("Qué bloquear").font(.app(11, weight: .medium)).foregroundStyle(Palette.muted)
                    Button("Redes + Shorts") { presetRaw = "" }
                        .buttonStyle(SelectableChipStyle(selected: presetRaw.isEmpty))
                    ForEach(DistractionPreset.allCases) { preset in
                        Button { presetRaw = preset.rawValue } label: { Label(preset.label, systemImage: preset.icon) }
                            .buttonStyle(SelectableChipStyle(selected: presetRaw == preset.rawValue))
                    }
                }
                HStack(spacing: 8) {
                    ForEach([(15, "15 min"), (30, "30 min"), (45, "45 min"), (60, "1 hora"), (120, "2 horas")], id: \.0) { minutes, label in
                        Button { model.startQuickBlockWithSavedChoice(minutes: minutes) } label: { Label(label, systemImage: "play.fill") }
                            .buttonStyle(FocusButtonStyle(kind: minutes == 30 ? .primary : .secondary, compact: false))
                            .disabled(model.readOnly)
                    }
                    Button { model.startQuickBlockWithSavedChoice(minutes: model.minutesUntilEndOfDay()) } label: {
                        Label("Resto del día", systemImage: "moon.stars.fill")
                    }
                    .buttonStyle(.focusSecondary)
                    .disabled(model.readOnly)
                }
                .help(model.runningQuickBlock == nil ? "Empieza a bloquear ya" : "Vuelve a empezar la cuenta atrás con este tiempo")
            }
        }
    }

    private var temporaryAllowCard: some View {
        let activeAllows = model.activeTemporaryAllows(at: model.now)
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Permitir una web unos minutos", icon: "clock.badge.checkmark")
                Text("Para consultar algo puntual. Al llegar a cero se vuelve a bloquear sola.")
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
                HStack(spacing: 8) {
                    TextField("Web o ruta (docs.swift.org, youtube.com/watch)", text: $tempAllowDomain)
                        .textFieldStyle(.roundedBorder)
                        .font(.app(12))
                        .onSubmit(allow)
                    Picker("Minutos", selection: $tempAllowMinutes) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    Button("Permitir", action: allow)
                        .buttonStyle(.focus(.secondary, compact: true))
                        .disabled(tempAllowDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.readOnly)
                }
                ForEach(activeAllows) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: entry.isAppBundleID ? "app.badge.checkmark" : "globe").foregroundStyle(Palette.mint)
                        Text(entry.label.isEmpty ? entry.target : "\(entry.label) (\(entry.target))").font(.app(11, weight: .medium))
                        Spacer()
                        Text(FocusRules.clock(entry.remaining(wall: model.now)))
                            .font(.app(11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.mint)
                        Button("Cerrar ya") { model.removeTemporaryAllow(entry.id) }
                            .buttonStyle(.focus(.ghost, compact: true))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func allow() {
        guard !tempAllowDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.readOnly else { return }
        model.addTemporaryAllow(target: tempAllowDomain, isAppBundleID: false, minutes: tempAllowMinutes)
        if model.error == nil { tempAllowDomain = "" }
    }
}

/// Everything blocking or counting right now, with the one action each needs, in one place.
private struct LiveRulesCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let live = model.liveGeneralRules
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(live.isEmpty ? "En marcha ahora" : "En marcha ahora · \(live.count)", icon: "dot.radiowaves.left.and.right") {
                    Button("Todas tus reglas") { model.go(to: .rules) }
                        .buttonStyle(.focus(.ghost, compact: true))
                }
                if live.isEmpty {
                    Text("Nada bloqueando ni contando ahora. Lanza un bloqueo arriba o crea una regla en Reglas y límites (⌘5).")
                        .font(.app(12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(live) { rule in LiveRuleRow(model: model, rule: rule) }
                }
            }
        }
    }
}

struct LiveRuleRow: View {
    @ObservedObject var model: AppModel
    let rule: GeneralBlockRule

    var body: some View {
        let enforcing = model.isRuleEnforcing(rule, at: model.now)
        HStack(spacing: 12) {
            Image(systemName: rule.kind.icon)
                .foregroundStyle(enforcing ? Palette.onAccent : Palette.mint)
                .frame(width: 26, height: 26)
                .background(enforcing ? Palette.mint : Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name).font(.app(13, weight: .semibold)).lineLimit(1)
                Text("\(rule.kind.galleryTitle) · \(model.liveSummary(for: rule))")
                    .font(.app(11))
                    .monospacedDigit()
                    .foregroundStyle(enforcing ? Palette.mint : Palette.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if rule.kind == .pomodoro {
                if rule.pomodoroPhase == .waitingForUser {
                    Button("Continuar") { model.confirmNextPomodoroPhase(rule) }
                        .buttonStyle(FocusPrimaryButton(compact: true))
                        .disabled(model.readOnly)
                } else if (rule.activePomodoroDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0) > 0 {
                    Button("Saltar fase") { model.skipPomodoroPhase(rule) }
                        .buttonStyle(.focus(.ghost, compact: true))
                        .disabled(model.readOnly)
                }
            }
            if model.canStartMicroPause(for: rule, at: model.now) {
                Button("Micro-pausa \(rule.microPauseMinutes) min (\(model.remainingMicroPausesToday(for: rule, at: model.now)))") {
                    model.startMicroPause(for: rule)
                }
                .buttonStyle(.focus(.secondary, compact: true))
                .disabled(model.readOnly)
                .help("Suelta la regla \(rule.microPauseMinutes) min y vuelve a bloquear sola.")
            }
            Button("Editar") { model.editingGeneralRule = rule }
                .buttonStyle(.focus(.ghost, compact: true))
                .disabled(model.readOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The settings that change how a block behaves, next to the blocks themselves (`settings.md › Task-specific options`).
private struct BlockingOptionsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Mientras bloquea", icon: "slider.horizontal.3")
                option("Píldora flotante con la cuenta atrás", Binding(
                    get: { model.workspace.settings.showFloatingTimerPill },
                    set: { value in
                        model.updateSettings { $0.showFloatingTimerPill = value }
                        model.updateFloatingPill(at: Date())
                    }
                ))
                option("Avisarme cuando queden 5 y 1 min", Binding(
                    get: { model.workspace.settings.preBlockRemindersEnabled },
                    set: { value in model.updateSettings { $0.preBlockRemindersEnabled = value } }
                ))
                option("Vaciar el portapapeles si copio algo bloqueado", Binding(
                    get: { model.workspace.settings.protectClipboard },
                    set: { value in model.updateBlockingSetting(turningOn: value) { $0.protectClipboard = value } }
                ))
                option("No dejar borrar el historial mientras bloquea", Binding(
                    get: { model.workspace.settings.protectActivityHistory },
                    set: { value in model.updateBlockingSetting(turningOn: value) { $0.protectActivityHistory = value } }
                ))
                Text("Los mismos interruptores siguen en Ajustes › General y Privacidad.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
            }
            .disabled(model.readOnly)
        }
    }

    /// Text on the left and the switch on the right edge, so the four switches line up.
    private func option(_ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).font(.app(12)).frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
    }
}

// MARK: - Reglas y límites (⌘5)

struct RulesPage: View {
    @ObservedObject var model: AppModel
    @State private var rulePendingDeletion: GeneralBlockRule?

    private struct RuleGroup: Identifiable {
        let id: String
        let tint: Color
        let rules: [GeneralBlockRule]
    }

    var body: some View {
        let all = model.workspace.generalRules
        let ref = model.now
        let enforcing = all.filter { $0.enabled && model.isRuleEnforcing($0, at: ref) }
        let tracking = all.filter { $0.enabled && !model.isRuleEnforcing($0, at: ref) && model.isRuleTrackingQuota($0, at: ref) }
        let shown = Set((enforcing + tracking).map(\.id))
        let waiting = all.filter { $0.enabled && !shown.contains($0.id) }
        let off = all.filter { !$0.enabled }
        let groups = [
            RuleGroup(id: "BLOQUEANDO AHORA", tint: Palette.mint, rules: enforcing),
            RuleGroup(id: "MIDIENDO TU USO", tint: Palette.muted, rules: tracking),
            RuleGroup(id: "EN ESPERA", tint: Palette.muted, rules: waiting),
            RuleGroup(id: "APAGADAS", tint: Palette.muted, rules: off),
        ].filter { !$0.rules.isEmpty }

        VStack(alignment: .leading, spacing: 22) {
            RuleGallery(model: model)

            if !all.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Tus reglas · \(all.count)").font(.app(16, weight: .semibold))
                    ForEach(groups) { group in
                        Text(group.id)
                            .font(.app(10, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(group.tint)
                            .padding(.top, 4)
                        ForEach(group.rules) { rule in
                            GeneralRuleCard(model: model, rule: rule, onDelete: { rulePendingDeletion = rule })
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "list.clipboard").foregroundStyle(Palette.muted)
                Text("Cada cambio y cada desbloqueo queda apuntado en Historial › Registro de bloqueo.")
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
                Button("Ver registro") { model.showAuditLog() }
                    .buttonStyle(.focus(.ghost, compact: true))
            }
        }
        .confirmationDialog(
            "¿Eliminar la regla «\(rulePendingDeletion?.name ?? "")»?",
            isPresented: Binding(get: { rulePendingDeletion != nil }, set: { if !$0 { rulePendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Eliminar regla", role: .destructive) {
                if let rule = rulePendingDeletion { model.deleteGeneralRule(rule) }
                rulePendingDeletion = nil
            }
            Button("Cancelar", role: .cancel) { rulePendingDeletion = nil }
        }
    }
}

/// Every kind of rule at once, each with an example: what used to hide behind a picker inside the editor.
private struct RuleGallery: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Crear una regla").font(.app(16, weight: .semibold))
                Text("Elige cómo funciona; qué bloquea lo eliges en el paso siguiente.")
                    .font(.app(12))
                    .foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], spacing: 10) {
                ForEach(GeneralRuleKind.galleryOrder, id: \.self) { kind in
                    tile(icon: kind.icon, title: kind.galleryTitle, detail: kind.galleryExample, dashed: false) {
                        model.openRuleTemplate(kind)
                    }
                }
                tile(icon: "square.and.arrow.down", title: "Importar plantilla", detail: "Reglas que exportaste antes, en un archivo JSON.", dashed: true) {
                    model.importGeneralRules()
                }
            }
        }
    }

    private func tile(icon: String, title: String, detail: String, dashed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.app(14, weight: .semibold))
                    .foregroundStyle(dashed ? Palette.muted : Palette.mint)
                    .frame(width: 30, height: 30)
                    .background(dashed ? Palette.fill : Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.app(14, weight: .semibold)).foregroundStyle(Palette.text)
                Text(detail)
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
            .background(dashed ? Color.clear : Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(dashed ? Palette.fieldStroke : Palette.stroke, style: StrokeStyle(lineWidth: 1, dash: dashed ? [5, 3] : []))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .disabled(model.readOnly)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

// MARK: - Descansos (⌘6)

struct BreaksPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            continuousCard
            HStack(alignment: .top, spacing: 14) {
                microPausesCard
                pomodoroCard
            }
            habitualCard
        }
    }

    private var continuousCard: some View {
        let settings = model.workspace.settings
        let target = Double(max(10, settings.continuousWorkMinutes)) * 60
        let used = model.continuousActiveWorkSeconds
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Descanso tras mucho rato seguido", icon: "figure.walk") {
                    Toggle("Activado", isOn: Binding(
                        get: { model.workspace.settings.continuousBreakEnabled },
                        set: { value in model.updateSettings { $0.continuousBreakEnabled = value } }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Medir el tiempo seguido frente al Mac y proponerte una pausa")
                }
                if settings.continuousBreakEnabled {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(FocusRules.clock(used))
                            .font(.app(30, weight: .regular, design: .monospaced))
                            .foregroundStyle(Palette.mint)
                            .accessibilityLabel("Tiempo seguido frente al Mac")
                        Text("de \(settings.continuousWorkMinutes) min frente al Mac · te propondré \(settings.continuousBreakDurationMinutes) min de pausa en \(max(0, Int((target - used) / 60))) min")
                            .font(.app(12))
                            .foregroundStyle(Palette.muted)
                    }
                    ProgressView(value: min(1, used / target)).tint(Palette.mint)
                    HStack(spacing: 18) {
                        Stepper("Cada \(settings.continuousWorkMinutes) min", value: Binding(
                            get: { model.workspace.settings.continuousWorkMinutes },
                            set: { value in model.updateSettings { $0.continuousWorkMinutes = value } }
                        ), in: 15...180, step: 5)
                        Stepper("Durante \(settings.continuousBreakDurationMinutes) min", value: Binding(
                            get: { model.workspace.settings.continuousBreakDurationMinutes },
                            set: { value in model.updateSettings { $0.continuousBreakDurationMinutes = value } }
                        ), in: 1...30)
                        Spacer()
                    }
                    .font(.app(12))
                    Text("Si te levantas o dejas el teclado unos minutos, el contador vuelve a cero solo.")
                        .font(.app(10))
                        .foregroundStyle(Palette.muted)
                } else {
                    Text("Actívalo para que FocusDesk mida el rato seguido frente al Mac y te recuerde descansar la vista y estirar.")
                        .font(.app(12))
                        .foregroundStyle(Palette.muted)
                }
            }
            .disabled(model.readOnly)
        }
    }

    private var microPausesCard: some View {
        let rules = model.workspace.generalRules.filter { $0.enabled && $0.dailyMicroPausesAllowed > 0 }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Micro-pausas de tus reglas", icon: "cup.and.saucer")
                Text("Sueltan una regla unos minutos y vuelve a bloquear sola. Tienes un número contado al día.")
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if rules.isEmpty {
                    Text("Ninguna regla encendida tiene micro-pausas. Se configuran al editar una regla.")
                        .font(.app(11))
                        .foregroundStyle(Palette.muted)
                }
                ForEach(rules) { rule in
                    let left = model.remainingMicroPausesToday(for: rule, at: model.now)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.app(12, weight: .semibold)).lineLimit(1)
                            Text(rule.isMicroPaused(at: model.now)
                                 ? model.liveSummary(for: rule)
                                 : "\(left) de \(rule.dailyMicroPausesAllowed) disponibles hoy · \(rule.microPauseMinutes) min cada una")
                                .font(.app(11))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button("Tomar una") { model.startMicroPause(for: rule) }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .disabled(!model.canStartMicroPause(for: rule, at: model.now) || model.readOnly)
                            .help(model.isRuleEnforcing(rule, at: model.now) ? "Soltar la regla \(rule.microPauseMinutes) min" : "Solo mientras la regla está bloqueando")
                    }
                    .padding(10)
                    .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var pomodoroCard: some View {
        let rules = model.workspace.generalRules.filter { $0.kind == .pomodoro }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Descansos del Pomodoro", icon: "clock.arrow.2.circlepath")
                if rules.isEmpty {
                    Text("Todavía no tienes un Pomodoro: alterna ratos de foco con descansos y bloquea durante el foco.")
                        .font(.app(11))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Crear un Pomodoro") { model.openRuleTemplate(.pomodoro) }
                        .buttonStyle(.focus(.secondary, compact: true))
                        .disabled(model.readOnly)
                }
                ForEach(rules) { rule in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.app(12, weight: .semibold)).lineLimit(1)
                            Text("\(model.liveSummary(for: rule)) · descansos de \(rule.pomodoroShortBreakMinutes) min, y de \(rule.pomodoroLongBreakMinutes) min cada \(rule.pomodoroLongBreakEvery) ciclos")
                                .font(.app(11))
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if rule.pomodoroPhase == .idle {
                            Button("Iniciar") { model.startPomodoroRule(rule) }
                                .buttonStyle(.focus(.secondary, compact: true))
                                .disabled(!rule.enabled || model.readOnly)
                        } else if rule.pomodoroPhase == .waitingForUser {
                            Button("Continuar") { model.confirmNextPomodoroPhase(rule) }
                                .buttonStyle(FocusPrimaryButton(compact: true))
                                .disabled(model.readOnly)
                        } else {
                            Button("Saltar fase") { model.skipPomodoroPhase(rule) }
                                .buttonStyle(.focus(.ghost, compact: true))
                                .disabled(model.readOnly)
                        }
                    }
                    .padding(10)
                    .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var habitualCard: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Descansos habituales de tu agenda", icon: "calendar.day.timeline.left") {
                    Toggle("Avisarme y mostrar la cuenta atrás", isOn: Binding(
                        get: { model.workspace.settings.enforceBreaks },
                        set: { value in model.updateSettings { $0.enforceBreaks = value } }
                    ))
                    .toggleStyle(.switch)
                    .font(.app(12))
                    .disabled(model.readOnly)
                }
                HStack(spacing: 8) {
                    if model.workspace.settings.breaks.isEmpty {
                        Text("Sin descansos fijos todavía.").font(.app(12)).foregroundStyle(Palette.muted)
                    }
                    ForEach(model.workspace.settings.breaks) { item in
                        Chip("\(item.title) · \(String(format: "%02d:%02d", item.startHour, item.startMinute)) · \(item.durationMinutes) min", icon: "cup.and.saucer")
                    }
                    Spacer()
                    Button("Cambiarlos en Ajustes…") { model.showSettings?(.schedule) }
                        .buttonStyle(.focus(.ghost, compact: true))
                }
            }
        }
    }
}

// MARK: - Hoy: what is protecting the day

/// A single line at the top of Hoy so the blocking tools never drop out of sight. With no rules yet it becomes a
/// dismissible invitation instead (`onboarding.md › Best practices`: context-specific tips).
struct ProtectionTodayStrip: View {
    @ObservedObject var model: AppModel
    @AppStorage("FocusDesk.protectionTipDismissed", store: AppPreferences.current) private var tipDismissed = false

    var body: some View {
        let live = model.liveGeneralRules
        if !live.isEmpty || model.runningQuickBlock != nil {
            Button { model.go(to: .blocking) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(Palette.mint)
                    Text("ANTIDISTRACCIÓN HOY").font(.app(9, weight: .bold)).tracking(1.2).foregroundStyle(Palette.muted)
                    ForEach(live.prefix(3)) { rule in
                        Text("\(rule.name.hasPrefix("Bloqueo rápido") ? "Bloqueo rápido" : rule.name) · \(model.liveSummary(for: rule))")
                            .font(.app(11, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .foregroundStyle(model.isRuleEnforcing(rule, at: model.now) ? Palette.mint : Palette.text)
                            .background(model.isRuleEnforcing(rule, at: model.now) ? Palette.mint.opacity(0.12) : Palette.fill, in: Capsule())
                    }
                    if live.count > 3 { Text("+\(live.count - 3)").font(.app(11)).foregroundStyle(Palette.muted) }
                    Spacer(minLength: 8)
                    Text("Ver").font(.app(12, weight: .semibold)).foregroundStyle(Palette.mint)
                    Image(systemName: "chevron.right").font(.app(10, weight: .semibold)).foregroundStyle(Palette.mint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.mint.opacity(0.22), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Abrir Bloquear ahora (⌘4)")
            .accessibilityLabel("Antidistracción hoy: \(live.map { "\($0.name), \(model.liveSummary(for: $0))" }.joined(separator: "; "))")
        } else if model.workspace.generalRules.isEmpty && !tipDismissed {
            HStack(spacing: 12) {
                Image(systemName: "sparkle").foregroundStyle(Palette.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nuevo: límites también fuera de las tareas").font(.app(12, weight: .semibold))
                    Text("20 min al día de YouTube, un Pomodoro o un horario sin pantallas por la noche.")
                        .font(.app(11))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Button("Ver reglas") { model.go(to: .rules) }
                    .buttonStyle(.focus(.secondary, compact: true))
                Button { tipDismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(FocusIconButtonStyle(size: 22))
                    .help("No volver a mostrar")
                    .accessibilityLabel("Ocultar la sugerencia")
            }
            .padding(12)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        }
    }
}

// MARK: - Historial › Registro de bloqueo

struct AuditLogSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let entries = model.workspace.auditLog
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Desbloqueos y cambios en tus reglas", icon: "list.clipboard") {
                    Button("Exportar reglas…") { model.exportGeneralRules() }
                        .buttonStyle(.focus(.ghost, compact: true))
                        .disabled(model.workspace.generalRules.isEmpty)
                    Button("Vaciar") { model.clearAuditLog() }
                        .buttonStyle(.focus(.ghost, compact: true))
                        .disabled(model.readOnly || entries.isEmpty)
                }
                if entries.isEmpty {
                    EmptyStateView(
                        title: "Nada apuntado todavía",
                        detail: "Cuando enciendas, apagues, edites o desbloquees una regla, quedará aquí con su hora.",
                        icon: "list.clipboard"
                    )
                } else {
                    ForEach(entries.prefix(200)) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.app(10, design: .monospaced))
                                .foregroundStyle(Palette.muted)
                                .frame(width: 128, alignment: .leading)
                            Chip(entry.category, color: Palette.mint)
                            Text(entry.summary)
                                .font(.app(12))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

// MARK: - Rule cards

private struct GeneralRuleCard: View {
    @ObservedObject var model: AppModel
    let rule: GeneralBlockRule
    let onDelete: () -> Void

    var body: some View {
        let used = model.usedSecondsToday(for: rule, at: model.now)
        let enforcing = model.isRuleEnforcing(rule, at: model.now)
        let tracking = model.isRuleTrackingQuota(rule, at: model.now)
        let microPaused = rule.isMicroPaused(at: model.now)

        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: rule.kind.icon)
                        .font(.app(18, weight: .semibold))
                        .foregroundStyle(enforcing ? Palette.onAccent : Palette.mint)
                        .frame(width: 34, height: 34)
                        .background(enforcing ? Palette.mint : Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(rule.name).font(.app(16, weight: .semibold))
                            Chip(rule.kind.label, icon: rule.kind.icon)
                            if microPaused {
                                let mpLeft = rule.activeMicroPauseDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0
                                Chip("Micro-pausa \(FocusRules.clock(mpLeft))", icon: "cup.and.saucer.fill", color: Palette.warning)
                            } else if rule.isInPostMatchGrace(at: model.now) {
                                let graceLeft = rule.postMatchGraceRemainingSeconds(at: model.now)
                                Chip("Cierre post-partida \(Int(ceil(graceLeft)))s", icon: "timer", color: Palette.warning)
                            } else if model.isMatchInProgress(for: rule) {
                                Chip("Partida en curso · Sin corte", icon: "gamecontroller.fill", color: Palette.mint)
                            } else if enforcing {
                                Chip("Bloqueando ahora", icon: "shield.fill", color: Palette.mint)
                            } else if tracking {
                                Chip("Midiendo uso hoy", icon: "hourglass", color: Palette.mint)
                            } else if !rule.enabled {
                                Chip("Apagada", color: Palette.muted)
                            } else {
                                Chip("En espera", color: Palette.muted)
                            }
                            if rule.protection != .none {
                                let protectedNow = model.isRuleProtected(rule, at: model.now)
                                let protText = rule.protection == .challenge
                                    ? "Código \(rule.unlockChars) díg.\(rule.alwaysProtected ? " · 24/7" : "")"
                                    : rule.protection.label
                                Chip(protText, icon: "lock.shield", color: protectedNow ? Palette.mint : Palette.muted)
                                    .help(rule.protection.explanation)
                            }
                        }

                        Text(selectorSummary)
                            .font(.app(11))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { value in model.toggleGeneralRule(rule, enabled: value) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.readOnly)
                    .help(rule.enabled ? "Apagar esta regla" : "Encender esta regla")
                }

                // Live timer / progress row depending on kind
                liveTimerSection(used: used, enforcing: enforcing)

                HStack(spacing: 8) {
                    if rule.kind == .countdown {
                        ForEach([15, 30, 60, 120], id: \.self) { mins in
                            Button(mins >= 60 ? "\(mins / 60) h" : "\(mins) min") {
                                model.startGeneralCountdown(for: rule, minutes: mins)
                            }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .disabled(model.readOnly)
                        }
                    } else if rule.kind == .pomodoro {
                        if (rule.pomodoroPhase == .waitingForUser) {
                            Button("Continuar a siguiente fase") {
                                model.confirmNextPomodoroPhase(rule)
                            }
                            .buttonStyle(FocusPrimaryButton(compact: true))
                            .disabled(model.readOnly)
                        } else if (rule.activePomodoroDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0) > 0 {
                            Button("Saltar fase") {
                                model.skipPomodoroPhase(rule)
                            }
                            .buttonStyle(.focus(.ghost, compact: true))
                            .disabled(model.readOnly)
                            Button("Reiniciar ciclo") {
                                model.startPomodoroRule(rule)
                            }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .disabled(model.readOnly)
                        } else {
                            Button("Iniciar Pomodoro") {
                                model.startPomodoroRule(rule)
                            }
                            .buttonStyle(.focus(.secondary, compact: true))
                            .disabled(model.readOnly)
                        }
                    } else if (rule.kind == .dailyLimit || rule.kind == .workGoal || rule.kind == .launchLimit) && (used > 0 || model.launchesToday(for: rule, at: model.now) > 0 || model.matchesToday(for: rule, at: model.now) > 0) {
                        Button("Reiniciar contador") {
                            model.resetDailyQuota(for: rule)
                        }
                        .buttonStyle(.focus(.ghost, compact: true))
                        .disabled(model.readOnly)
                    }
                    if model.canStartMicroPause(for: rule, at: model.now) {
                        let pausesLeft = model.remainingMicroPausesToday(for: rule, at: model.now)
                        Button("Micro-pausa \(rule.microPauseMinutes) min (\(pausesLeft))") {
                            model.startMicroPause(for: rule)
                        }
                        .buttonStyle(.focus(.secondary, compact: true))
                        .disabled(model.readOnly)
                        .help("Pausa temporal controlada. Al agotarse los \(rule.microPauseMinutes) min, la regla vuelve a bloquear automáticamente.")
                    }
                    Spacer()
                    Button("Editar") { model.editingGeneralRule = rule }
                        .buttonStyle(.focus(.secondary, compact: true))
                        .disabled(model.readOnly)
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(FocusIconButtonStyle(size: 26, tint: Palette.danger))
                    .disabled(model.readOnly)
                    .help("Eliminar «\(rule.name)»")
                    .accessibilityLabel("Eliminar \(rule.name)")
                }
            }
        }
    }

    @ViewBuilder private func liveTimerSection(used: TimeInterval, enforcing: Bool) -> some View {
        let lockLeft = model.remainingRuleLockSeconds(rule, at: model.now)
        switch rule.kind {
        case .dailyLimit:
            let total = Double(max(1, rule.dailyLimitMinutes)) * 60
            let left = max(0, total - used)
            let fraction = min(1.0, max(0, used / total))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(
                        left > 0
                            ? "Tiempo restante (\(rule.limitPeriodUnit.label.lowercased())): \(FocusRules.clock(left))"
                            : "Presupuesto (\(rule.limitPeriodUnit.label.lowercased())) agotado · bloqueado",
                        systemImage: left > 0 ? "hourglass" : "lock.fill"
                    )
                    .font(.app(13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(left > 0 ? Palette.mint : Palette.warning)
                    Spacer()
                    Text("Usado: \(FocusRules.clock(used)) de \(rule.dailyLimitMinutes) min")
                        .font(.app(11, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
                ProgressView(value: fraction)
                    .tint(left > 0 ? Palette.mint : Palette.warning)
            }
            .padding(10)
            .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .pomodoro:
            let rem = rule.activePomodoroDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if (rule.pomodoroPhase == .waitingForUser) {
                        Label(
                            "Fase completada (\(rule.pomodoroPhase.label)) · esperando confirmación",
                            systemImage: "hand.wave.fill"
                        )
                        .font(.app(13, weight: .semibold))
                        .foregroundStyle(Palette.warning)
                    } else if rem > 0 {
                        Label(
                            "\(rule.pomodoroPhase.label) (ciclo \(rule.pomodoroCurrentCycle)/\(rule.pomodoroTotalCycles)): quedan \(FocusRules.clock(rem))",
                            systemImage: rule.pomodoroPhase == .work ? "flame.fill" : "cup.and.saucer.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(rule.pomodoroPhase == .work ? Palette.mint : Palette.warning)
                    } else {
                        Label(
                            "Pomodoro listo (\(rule.pomodoroWorkMinutes)m trabajo / \(rule.pomodoroShortBreakMinutes)m descanso corto / \(rule.pomodoroLongBreakMinutes)m largo)",
                            systemImage: "clock.arrow.2.circlepath"
                        )
                        .font(.app(12))
                        .foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if rule.pomodoroPenaltyReset {
                        Chip("Penalización activa", icon: "arrow.counterclockwise", color: Palette.muted)
                    }
                    if rule.protectPomodoroBreaks {
                        Chip("Descansos protegidos", icon: "lock.fill", color: Palette.muted)
                    }
                }
            }
            .padding(10)
            .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .workGoal:
            let worked = model.effectiveWorkedSeconds(for: rule, at: model.now)
            let required = Double(max(5, rule.goalMinutesRequired)) * 60
            let workFraction = min(1.0, max(0, worked / required))
            let goalMet = worked >= required
            let rewardLeft = rule.remainingGoalRewardSeconds(workedTodaySeconds: worked, usedTodaySeconds: used)
            let matches = model.matchesToday(for: rule, at: model.now)
            let maxMatches = max(0, rule.maxDailyMatches)
            let matchesExhausted = maxMatches > 0 && matches >= maxMatches
            let matchInProgress = model.isMatchInProgress(for: rule)
            let postGraceLeft = rule.postMatchGraceRemainingSeconds(at: model.now)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if postGraceLeft > 0 {
                        Label(
                            "Partida terminada · cerrando League of Legends en \(Int(ceil(postGraceLeft))) s",
                            systemImage: "timer"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                    } else if matchInProgress {
                        let currentMatchNum = min(max(1, maxMatches), matches + 1)
                        Label(
                            maxMatches > 0
                                ? "Partida \(currentMatchNum)/\(maxMatches) en curso · protegida sin cortes hasta que acabe"
                                : "Partida en curso · protegida sin cortes hasta que acabe",
                            systemImage: "gamecontroller.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                    } else if !goalMet {
                        let workNeeded = max(0, required - worked)
                        Label(
                            rule.verifyActiveStudy
                                ? "Estudio activo pendiente: faltan \(FocusRules.clock(workNeeded)) (cuenta solo con ventana/pestaña de estudio y actividad real)"
                                : "Meta pendiente: faltan \(FocusRules.clock(workNeeded)) de trabajo enfocado hoy",
                            systemImage: "flag.checkered"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                    } else if matchesExhausted {
                        Label(
                            "Límite de \(matches)/\(maxMatches) partidas completado hoy · bloqueado hasta mañana",
                            systemImage: "lock.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                    } else if rule.goalRewardMinutes <= 0 {
                        Label(
                            maxMatches > 0
                                ? "Desbloqueado hoy · Partidas jugadas: \(matches)/\(maxMatches)"
                                : "Meta cumplida (\(FocusRules.clock(worked))) · desbloqueado hoy",
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                    } else if rewardLeft > 0 {
                        Label(
                            maxMatches > 0
                                ? "Desbloqueado: quedan \( max(0, maxMatches - matches) ) partida(s) (\(matches)/\(maxMatches)) · tiempo máx. \(FocusRules.clock(rewardLeft))"
                                : "Tiempo de recompensa disponible: \(FocusRules.clock(rewardLeft))",
                            systemImage: "gift.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                    } else {
                        Label(
                            "Tiempo de juego agotado hoy · bloqueado hasta mañana",
                            systemImage: "lock.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        if maxMatches > 0 {
                            Text("Partidas: \(matches)/\(maxMatches)")
                                .font(.app(11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(matchesExhausted ? Palette.warning : Palette.mint)
                        }
                        Text("\(rule.verifyActiveStudy ? "Estudio hoy" : "Trabajado hoy"): \(FocusRules.clock(worked)) / \(rule.goalMinutesRequired) min")
                            .font(.app(11, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                    }
                }
                ProgressView(value: workFraction)
                    .tint(goalMet && !matchesExhausted ? Palette.mint : Palette.warning)
            }
            .padding(10)
            .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .launchLimit:
            let launches = model.launchesToday(for: rule, at: model.now)
            let maxLaunches = max(1, rule.maxDailyLaunches)
            let visitRem = rule.activeLaunchDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0
            let cooldownRem = rule.launchCooldownDeadline?.remainingAfterPossibleReboot(wall: model.now) ?? 0
            let fraction = min(1.0, Double(launches) / Double(maxLaunches))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if visitRem > 0 {
                        Label(
                            "Visita activa: quedan \(FocusRules.clock(visitRem))",
                            systemImage: "timer"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                        Button("Terminar visita") {
                            model.endLaunchVisitEarly(for: rule)
                        }
                        .buttonStyle(.focus(.ghost, compact: true))
                        .disabled(model.readOnly)
                    } else if cooldownRem > 0 {
                        Label(
                            "En enfriamiento: faltan \(FocusRules.clock(cooldownRem)) para poder abrir de nuevo",
                            systemImage: "snowflake"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                    } else if launches >= maxLaunches {
                        Label(
                            "Límite de \(maxLaunches) aperturas agotado hoy · bloqueado hasta medianoche",
                            systemImage: "lock.fill"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.warning)
                    } else {
                        let left = maxLaunches - launches
                        Label(
                            "Quedan \(left) apertura(s) hoy · \(rule.maxLaunchDurationMinutes) min por visita",
                            systemImage: "door.left.hand.open"
                        )
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                    }
                    Spacer()
                    Text("Aperturas: \(launches)/\(maxLaunches) · pausa \(rule.launchCooldownMinutes)m")
                        .font(.app(11, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                }
                ProgressView(value: fraction)
                    .tint(launches < maxLaunches && cooldownRem <= 0 ? Palette.mint : Palette.warning)
            }
            .padding(10)
            .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .countdown:
            if enforcing && lockLeft > 0 {
                HStack {
                    Label("Cuenta atrás en marcha: quedan \(FocusRules.clock(lockLeft))", systemImage: "timer")
                        .font(.app(13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                    Spacer()
                    let ends = model.now.addingTimeInterval(lockLeft)
                    Text("Termina a las \(ends.formatted(date: .omitted, time: .shortened))")
                        .font(.app(11))
                        .foregroundStyle(Palette.muted)
                }
                .padding(10)
                .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Text("Temporizador listo (\(rule.countdownMinutes) min predeterminados). Pulsa un botón de tiempo para iniciarlo.")
                    .font(.app(11))
                    .foregroundStyle(Palette.muted)
            }

        case .schedule:
            HStack {
                Label("Horario: \(rule.scheduleLabel)", systemImage: "calendar.badge.clock")
                    .font(.app(12, weight: .medium))
                    .foregroundStyle(enforcing ? Palette.mint : Palette.muted)
                Spacer()
                if enforcing && lockLeft > 0 {
                    Text("Quedan \(FocusRules.clock(lockLeft)) de tramo")
                        .font(.app(11, design: .monospaced))
                        .foregroundStyle(Palette.mint)
                }
            }
            .padding(10)
            .background(Palette.elevated.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .alwaysOn:
            Text(rule.enabled ? "Activo de forma permanente 24/7." : "Desactivado.")
                .font(.app(11))
                .foregroundStyle(rule.enabled ? Palette.mint : Palette.muted)
        }
    }

    private var selectorSummary: String {
        var parts: [String] = []
        if rule.webListMode == .blockAll {
            parts.append("Todas las webs bloqueadas")
        } else {
            let doms = FocusRules.parseDomains(rule.domains).valid
            if !doms.isEmpty {
                let prefix = rule.webListMode == .allowListed ? "Solo webs: " : "Webs: "
                let shown = doms.prefix(5).joined(separator: ", ")
                let extra = doms.count > 5 ? " (+\(doms.count - 5))" : ""
                parts.append(prefix + shown + extra)
            }
        }
        let kws = FocusRules.parseTitleKeywords(rule.blockedTitleKeywords)
        if !kws.isEmpty {
            parts.append("Títulos: " + kws.prefix(4).joined(separator: ", "))
        }
        if !rule.apps.isEmpty {
            let prefix = rule.appListMode == .allowListed ? "Solo apps: " : "Apps: "
            parts.append(prefix + rule.apps.map(\.name).joined(separator: ", "))
        }
        if rule.blockGameLibraries {
            parts.append("Juegos (Steam, Epic, Battle.net…)")
        }
        if rule.blockSearchMedia {
            parts.append("Imágenes/Vídeos en buscadores")
        }
        if !rule.blockedFolders.isEmpty {
            parts.append("\(rule.blockedFolders.count) carpeta(s)")
        }
        return parts.isEmpty ? "Sin selectores configurados todavía · pulsa Editar para añadir webs, rutas o apps" : parts.joined(separator: " · ")
    }
}
