import SwiftUI
import FocusCore

/// How a game rule stands right now, in one line: shared by the rule card, the summary and Hoy.
struct GameRuleStatus {
    let text: String
    let icon: String
    let warning: Bool
    /// A timed match is running: «He terminado» can end it.
    let canFinish: Bool
    /// Study towards the next match (1 when nothing is pending).
    let progress: Double
}

extension AppModel {
    func gameRuleStatus(_ rule: GeneralBlockRule, at instant: Date) -> GameRuleStatus {
        let unit = rule.matchUnitSingular
        let plural = rule.matchUnitPlural
        let maxM = max(1, rule.maxDailyMatches)
        let played = matchesToday(for: rule, at: instant)
        let next = min(maxM, played + 1)
        let worked = effectiveWorkedSeconds(for: rule, at: instant)
        let needed = rule.requiredWorkSecondsForNextMatch(matchesToday: played)

        let grace = rule.postMatchGraceRemainingSeconds(at: instant)
        if grace > 0 {
            return GameRuleStatus(text: "\(unit.capitalized) terminada · se cierra en \(Int(ceil(grace))) s", icon: "timer", warning: true, canFinish: false, progress: 1)
        }
        if rule.isInTimedMatch(at: instant) {
            let left = rule.timedMatchRemainingSeconds(at: instant)
            if rule.isInTimedMatchOvertime(at: instant) {
                return GameRuleStatus(text: "Prórroga de la \(unit) \(next)/\(maxM) · se cierra en \(FocusRules.clock(left))", icon: "timer", warning: true, canFinish: true, progress: 1)
            }
            let beforeOvertime = left - Double(rule.matchOvertimeMinutes) * 60
            let extra = rule.matchOvertimeMinutes > 0 ? " + \(rule.matchOvertimeMinutes) min de prórroga" : ""
            return GameRuleStatus(text: "\(unit.capitalized) \(next)/\(maxM) en curso · \(FocusRules.clock(beforeOvertime))\(extra)", icon: "gamecontroller.fill", warning: false, canFinish: true, progress: 1)
        }
        if isMatchInProgress(for: rule) {
            return GameRuleStatus(text: "\(unit.capitalized) \(next)/\(maxM) en curso · sin cortes hasta que acabe", icon: "gamecontroller.fill", warning: false, canFinish: false, progress: 1)
        }
        if played >= maxM {
            return GameRuleStatus(text: "\(played)/\(maxM) \(plural) · bloqueado hasta mañana", icon: "lock.fill", warning: true, canFinish: false, progress: 1)
        }
        if worked < needed {
            let what = rule.verifyActiveStudy ? "estudio" : "trabajo"
            return GameRuleStatus(
                text: "Faltan \(FocusRules.clock(needed - worked)) de \(what) para la \(unit) \(next)/\(maxM)",
                icon: "book.fill",
                warning: false,
                canFinish: false,
                progress: min(1, max(0, worked / max(1, needed)))
            )
        }
        let available = rule.earnsMatchesPerGoalBlock ? max(1, rule.earnedMatches(workedTodaySeconds: worked) - played) : maxM - played
        let text = available == 1
            ? "\(unit.capitalized) \(next)/\(maxM) disponible"
            : "\(available) \(plural) disponibles (\(played)/\(maxM) jugadas)"
        return GameRuleStatus(text: text, icon: "checkmark.seal.fill", warning: false, canFinish: false, progress: 1)
    }

    /// «He terminado»: ends the timed match now and closes the game.
    func finishGameMatchNow(_ rule: GeneralBlockRule) {
        guard !readOnly else { return }
        finishTimedMatch(ruleID: rule.id, reason: .userFinished)
    }

    func openGameRuleTemplate(_ game: GameDefinition) {
        guard !readOnly else { return }
        editingGeneralRule = GeneralBlockRule.gameTemplate(game)
    }
}

/// The game part of a rule card: where the day stands and, during a timed match, «He terminado».
struct GameRuleProgress: View {
    @ObservedObject var model: AppModel
    let rule: GeneralBlockRule

    var body: some View {
        let status = model.gameRuleStatus(rule, at: model.now)
        let played = model.matchesToday(for: rule, at: model.now)
        let worked = model.effectiveWorkedSeconds(for: rule, at: model.now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(status.text, systemImage: status.icon)
                    .font(.app(13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(status.warning ? Palette.warning : Palette.mint)
                Spacer()
                if status.canFinish {
                    Button("He terminado") { model.finishGameMatchNow(rule) }
                        .buttonStyle(.focus(.secondary, compact: true))
                        .help("Da por acabada esta \(rule.matchUnitSingular) y cierra el juego.")
                }
                Text("\(rule.matchUnitPlural.capitalized): \(played)/\(max(1, rule.maxDailyMatches))")
                    .font(.app(11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(status.warning ? Palette.warning : Palette.mint)
                Text("\(rule.verifyActiveStudy ? "Estudio" : "Trabajo") hoy: \(FocusRules.clock(worked))")
                    .font(.app(11))
                    .monospacedDigit()
                    .foregroundStyle(Palette.muted)
            }
            ProgressView(value: status.progress)
                .tint(status.warning ? Palette.warning : Palette.mint)
            if let game = rule.game {
                Text("\(game.name) · \(game.detection.label.lowercased())\(rule.usesTimedMatches ? ": \(rule.matchMinutes) min por \(rule.matchUnitSingular) + \(rule.matchOvertimeMinutes) de prórroga" : "") · \(rule.goalMinutesRequired) min de estudio por \(rule.matchUnitSingular)")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(10)
        .background(Palette.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Inside the rule editor: which game, how its matches are measured and how long they last.
struct GameRuleEditorSection: View {
    @Binding var draft: GeneralBlockRule

    private var selection: Binding<String> {
        Binding(
            get: { draft.gameID ?? "" },
            set: { id in
                if let game = GameCatalog.game(id: id) {
                    draft.applyGame(game)
                    if game.id == GameCatalog.customID { draft.blockApps = true }
                } else {
                    draft.gameID = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("JUEGO").fieldLabelStyle()
                Picker("Juego", selection: selection) {
                    Text("Ninguno: meta de estudio normal").tag("")
                    Divider()
                    ForEach(GameCatalog.all) { game in
                        Label(game.name, systemImage: game.icon).tag(game.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
            }
            if let game = draft.game {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: game.detection.isExact ? "scope" : "hourglass")
                        .foregroundStyle(Palette.mint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.detection.label).font(.app(12, weight: .semibold))
                        Text(game.detection.explanation)
                            .font(.app(10))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        if !game.note.isEmpty {
                            Text(game.note)
                                .font(.app(10))
                                .foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if game.detection == .timed {
                    HStack(spacing: 18) {
                        Stepper("Cada \(game.unitSingular) dura \(draft.matchMinutes) min", value: $draft.matchMinutes, in: 5...180, step: 5)
                            .font(.app(12))
                        Stepper("Prórroga para acabarla: \(draft.matchOvertimeMinutes) min", value: $draft.matchOvertimeMinutes, in: 0...30)
                            .font(.app(12))
                    }
                }
                HStack(spacing: 18) {
                    Stepper("Máximo: \(draft.maxDailyMatches) \(game.unitPlural) al día", value: $draft.maxDailyMatches, in: 1...10)
                        .font(.app(12))
                    Toggle("Cada \(game.unitSingular) cuesta \(draft.goalMinutesRequired) min de estudio", isOn: $draft.oneMatchPerGoalBlock)
                        .toggleStyle(.checkbox)
                        .font(.app(11))
                }
                Text(draft.oneMatchPerGoalBlock
                     ? "\(draft.goalMinutesRequired) min de estudio → 1 \(game.unitSingular) → se bloquea → otros \(draft.goalMinutesRequired) min → la siguiente (bucle protegido)."
                     : "\(draft.goalMinutesRequired) min de estudio desbloquean las \(draft.maxDailyMatches) \(game.unitPlural) de golpe y te dejan apagar la regla al acabar el estudio.")
                    .font(.app(10))
                    .foregroundStyle(Palette.muted)
            }
        }
    }
}

/// «Crear una regla» › Juegos: one tile per game, each opening a ready rule in the editor.
struct GameRuleGallery: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Juegos: primero estudio, luego partida").font(.app(16, weight: .semibold))
                Text("Una hora de estudio por partida y nunca te saca a mitad. Eliges el juego y ya viene preparada.")
                    .font(.app(12))
                    .foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                ForEach(GameCatalog.all) { game in
                    Button { model.openGameRuleTemplate(game) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: game.icon)
                                .font(.app(13, weight: .semibold))
                                .foregroundStyle(Palette.mint)
                                .frame(width: 28, height: 28)
                                .background(Palette.mint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.name).font(.app(13, weight: .semibold)).foregroundStyle(Palette.text)
                                Text(game.detection.isExact
                                     ? "Detección exacta de cada partida"
                                     : "\(game.typicalMatchMinutes) min por \(game.unitSingular) + prórroga")
                                    .font(.app(10))
                                    .foregroundStyle(Palette.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .disabled(model.readOnly)
                    .accessibilityLabel("Regla de \(game.name)")
                }
            }
        }
    }
}
