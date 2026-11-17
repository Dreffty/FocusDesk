using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.Core;

public enum NextTransition { KeepSchedule, StartNextNow, Rest10Min }

/// <summary>Features that macOS has in AppModel and Windows lacked: undo, inbox, checklist, evidence, breaks, exceptions…</summary>
public sealed partial class AppEngine
{
    // MARK: - Undo / redo of the agenda

    private readonly List<string> _undoStack = new();
    private readonly List<string> _redoStack = new();
    private const int UndoLimit = 30;

    private string SnapshotTasks() => JsonSerializer.Serialize(Workspace.Tasks, WorkspaceStore.JsonOptions);

    private void RememberUndo()
    {
        _undoStack.Add(SnapshotTasks());
        if (_undoStack.Count > UndoLimit) _undoStack.RemoveAt(0);
        _redoStack.Clear();
    }

    public bool CanUndo => _undoStack.Count > 0;
    public bool CanRedo => _redoStack.Count > 0;

    public void UndoAgenda() => ApplyAgendaSnapshot(_undoStack, _redoStack, "Cambio deshecho.");
    public void RedoAgenda() => ApplyAgendaSnapshot(_redoStack, _undoStack, "Cambio rehecho.");

    private void ApplyAgendaSnapshot(List<string> from, List<string> to, string message)
    {
        if (from.Count == 0) return;
        List<FocusTask>? target;
        try { target = JsonSerializer.Deserialize<List<FocusTask>>(from[^1], WorkspaceStore.JsonOptions); }
        catch { target = null; }
        if (target == null)
        {
            from.RemoveAt(from.Count - 1);
            return;
        }
        // Undoing must not be a way around a protected task: the same ratchet that judges editing judges this.
        var now = DateTimeOffset.Now;
        foreach (var current in Workspace.Tasks)
        {
            if (!IsTaskProtected(current, now)) continue;
            var wanted = target.FirstOrDefault(t => t.Id == current.Id);
            var running = Workspace.Session?.Task.Id == current.Id;
            var reason = FocusRules.TaskLoosening(current, wanted, now, running);
            if (reason != null)
            {
                Notice = $"No se puede deshacer: habría que {reason} sin desbloquear.";
                return;
            }
        }
        to.Add(SnapshotTasks());
        from.RemoveAt(from.Count - 1);
        Workspace.Tasks = target;
        Persist();
        Notice = message;
    }

    // MARK: - Inbox and quick moves

    public void QuickCapture(string title)
    {
        var clean = (title ?? "").Trim();
        if (clean.Length == 0) return;
        RememberUndo();
        Workspace.Tasks.Add(new FocusTask { Title = clean, IsScheduled = false, Minutes = 30 });
        Persist();
        Notice = $"«{clean}» apuntada en la bandeja.";
    }

    public void MoveToTomorrowSameTime(FocusTask task, bool bypassProtection = false)
    {
        var updated = task.Clone();
        var when = task.IsScheduled ? task.ScheduledAt.LocalDateTime.AddDays(1) : DateTime.Now.Date.AddDays(1).AddHours(9);
        updated.IsScheduled = true;
        updated.ScheduledAt = FocusRules.FromLocal(when);
        SaveTask(updated, bypassProtection);
        if (string.IsNullOrEmpty(Error)) Notice = $"«{updated.Title}» pasa a mañana a la misma hora.";
    }

    public void MoveToInbox(FocusTask task, bool bypassProtection = false)
    {
        var updated = task.Clone();
        updated.IsScheduled = false;
        SaveTask(updated, bypassProtection);
        if (string.IsNullOrEmpty(Error)) Notice = $"«{updated.Title}» pasa a la bandeja sin hora.";
    }

    /// <summary>Puts a task in the first gap of the agenda from now on (today, or the next workday morning if today is full).</summary>
    public void ScheduleInFirstFreeSlot(FocusTask task, bool bypassProtection = false)
    {
        var now = DateTimeOffset.Now;
        var start = now.LocalDateTime.AddMinutes(5);
        start = new DateTime(start.Year, start.Month, start.Day, start.Hour, start.Minute / 15 * 15, 0).AddMinutes(15);
        var chosen = start;
        for (var i = 0; i < 96 * 3; i++)
        {
            var candidate = FocusRules.FromLocal(chosen);
            var end = candidate.AddMinutes(Math.Max(1, task.Minutes));
            var busy = Workspace.Tasks.Any(other => other.Id != task.Id && !other.Completed && other.IsScheduled &&
                                                    other.ScheduledAt < end && candidate < other.End);
            if (!busy) break;
            chosen = chosen.AddMinutes(15);
        }
        var updated = task.Clone();
        updated.IsScheduled = true;
        updated.ScheduledAt = FocusRules.FromLocal(chosen);
        SaveTask(updated, bypassProtection);
        if (string.IsNullOrEmpty(Error)) Notice = $"«{updated.Title}» programada a las {updated.ScheduledAt.LocalDateTime:HH:mm}.";
    }

    // MARK: - Checklist of the running session

    public static List<string> ChecklistSteps(string checklist) =>
        (checklist ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

    public void SetCheck(string key, bool value)
    {
        var s = Workspace.Session;
        if (s == null) return;
        if (value) s.Checked.Add(key); else s.Checked.Remove(key);
        Persist();
    }

    // MARK: - Evidence in the result folder

    private void BeginFolderBaseline(WorkSession s)
    {
        var folder = s.Task.Folder;
        if (string.IsNullOrWhiteSpace(folder)) return;
        var id = s.Id;
        _ = Task.Run(() =>
        {
            var scan = FolderEvidence.Scan(folder);
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                if (_disposed || Workspace.Session == null || Workspace.Session.Id != id) return;
                Workspace.Session.Baseline = scan.Files;
                Workspace.Session.BaselineValid = scan.Valid;
                Persist();
            });
        });
    }

    /// <summary>Looks at the result folder again, then asks for the result (macOS: finish() scans before showing it).</summary>
    private void AskResultAfterEvidence(WorkSession s)
    {
        var folder = s.Task.Folder;
        if (string.IsNullOrWhiteSpace(folder) || !s.BaselineValid || System.Windows.Application.Current == null)
        {
            s.FinalChangedFiles = new List<string>();
            s.FinalEvidenceMessage = string.IsNullOrWhiteSpace(folder)
                ? null
                : "Sin lectura inicial válida; resultado pendiente de tu confirmación.";
            Persist();
            SessionCompletionRequested?.Invoke(s);
            return;
        }
        var id = s.Id;
        var baseline = s.Baseline;
        _ = Task.Run(() =>
        {
            var scan = FolderEvidence.Scan(folder);
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                if (_disposed || Workspace.Session == null || Workspace.Session.Id != id) return;
                var changed = scan.Valid ? FolderEvidence.Changed(baseline, scan.Files) : new List<string>();
                var session = Workspace.Session;
                session.FinalChangedFiles = changed;
                session.FinalEvidenceMessage = scan.Message;
                session.SelectedFiles = changed.Count == 1 ? new List<string> { changed[0] } : new List<string>();
                Persist();
                SessionCompletionRequested?.Invoke(session);
            });
        });
    }

    public void ReopenSession()
    {
        var s = Workspace.Session;
        if (s == null || s.EndedAt == null) return;
        var now = DateTimeOffset.Now;
        s.Reopen(now);
        ResetStrictState();
        _sessionFinishedNotifiedId = s.Remaining(now) <= 0 ? s.Id : null;
        Persist();
        Notice = $"De vuelta a «{s.Task.Title}». Te quedan {FocusRules.Clock(Math.Max(0, s.Remaining(now)))}.";
    }

    /// <summary>What to do right after confirming a result: start the next task, or rest ten minutes before it.</summary>
    private void ApplyTransition(NextTransition transition, Guid finishedTaskId, bool completed)
    {
        if (transition == NextTransition.KeepSchedule) return;
        var now = DateTimeOffset.Now;
        // Never the task just worked on: after «Sigue pendiente» it is usually still the most imminent one.
        var next = FocusRules.NextSuggestedTask(Workspace.Tasks, finishedTaskId, now);
        if (next == null)
        {
            Notice = completed ? "Tarea terminada. No hay más tareas pendientes." : "Sesión guardada.";
            return;
        }
        if (transition == NextTransition.StartNextNow)
        {
            Notice = $"Iniciando «{next.Title}».";
            StartSession(next);
            return;
        }
        if (next.IsScheduled && !next.IsFixedAppointment && next.ScheduledAt <= now.AddMinutes(10) && !IsTaskProtected(next, now))
        {
            SnoozeTask(next, 10);
            if (string.IsNullOrEmpty(Error))
                Notice = $"Descanso de 10 minutos. «{next.Title}» se ha desplazado 10 min (las citas fijas no se mueven).";
        }
        else
        {
            Notice = "Descanso de 10 minutos antes de continuar. Los horarios fijos se conservan.";
        }
    }

    // MARK: - Scheduled breaks and the continuous break

    private string? _dismissedBreakKey;

    /// <summary>The scheduled break (lunch…) that is running now, unless the person hid it.</summary>
    public (BreakPeriod Period, double Remaining)? ActiveBreak(DateTimeOffset? at = null)
    {
        if (!Workspace.Settings.EnforceBreaks) return null;
        var t = at ?? DateTimeOffset.Now;
        var workdays = Workspace.Settings.Workdays;
        if (workdays.Count > 0 && !workdays.Contains(FocusRules.AppleWeekday(t))) return null;
        var day = FocusRules.DayKey(t);
        foreach (var period in Workspace.Settings.Breaks)
        {
            if (!period.IsActive(t)) continue;
            var key = $"{day}-{period.Id}-{period.StartHour}:{period.StartMinute}";
            if (_dismissedBreakKey == key) continue;
            return (period, period.RemainingSeconds(t));
        }
        return null;
    }

    public void DismissActiveBreak(BreakPeriod period)
    {
        _dismissedBreakKey = $"{FocusRules.DayKey(DateTimeOffset.Now)}-{period.Id}-{period.StartHour}:{period.StartMinute}";
        StateRefreshed?.Invoke();
    }

    public int ContinuousBreakSkipsLeft =>
        Math.Max(0, Workspace.Settings.ContinuousBreakMaxSkipsPerDay - Workspace.ContinuousBreakSkipsToday());

    public void SkipContinuousBreak()
    {
        var max = Workspace.Settings.ContinuousBreakMaxSkipsPerDay;
        if (Workspace.ContinuousBreakSkipsToday() >= max)
        {
            Notice = $"Ya has agotado los {max} saltos de descanso permitidos hoy.";
            return;
        }
        var used = Workspace.IncrementContinuousBreakSkips();
        ActiveContinuousBreakDeadline = null;
        ContinuousActiveWorkSeconds = 0;
        Persist();
        var left = Math.Max(0, max - used);
        Notice = $"Descanso pospuesto. Te {(left == 1 ? "queda 1 salto" : $"quedan {left} saltos")} hoy.";
    }

    public void StartContinuousBreakNow()
    {
        ContinuousActiveWorkSeconds = 0;
        ActiveContinuousBreakDeadline = new TrustedDeadline(Math.Max(1, Workspace.Settings.ContinuousBreakDurationMinutes) * 60.0);
        var messages = Workspace.Settings.BreakMessages.Where(m => !string.IsNullOrWhiteSpace(m)).ToList();
        ActiveContinuousBreakMessage = messages.Count > 0 ? messages[Random.Shared.Next(messages.Count)] : "Descansa la vista y estira los hombros.";
        NotificationRequested?.Invoke("Hora de descansar", ActiveContinuousBreakMessage);
    }

    // MARK: - Warnings before a limit runs out

    private readonly HashSet<string> _quotaWarningsSent = new();

    private void CheckPreBlockWarning(GeneralBlockRule rule, double remainingSeconds, string periodKey)
    {
        if (!Workspace.Settings.PreBlockRemindersEnabled || remainingSeconds <= 0) return;
        if (remainingSeconds <= 60)
        {
            if (!_quotaWarningsSent.Add($"{periodKey}-{rule.Id}-1m")) return;
            Notice = $"Queda menos de 1 minuto disponible en «{rule.Name}» antes de que se bloquee.";
            NotificationRequested?.Invoke($"Último minuto · {rule.Name}", Notice);
        }
        else if (remainingSeconds <= 300)
        {
            if (!_quotaWarningsSent.Add($"{periodKey}-{rule.Id}-5m")) return;
            Notice = $"Quedan 5 minutos disponibles en «{rule.Name}».";
            NotificationRequested?.Invoke($"Quedan 5 min · {rule.Name}", Notice);
        }
    }

    /// <summary>Adds the seconds spent on what a limit watches, and warns when 5 min / 1 min are left or it runs out.</summary>
    private void AccumulateUsage(GeneralBlockRule rule, double delta, DateTimeOffset now)
    {
        var rollover = Workspace.Settings.DayRolloverHour;
        if (rule.Kind == GeneralRuleKind.DailyLimit)
        {
            var wasUnder = Workspace.UsedSecondsToday(rule.Id, rule.LimitPeriodUnit, now) < rule.DailyBudgetSeconds;
            var used = Workspace.AddUsedSeconds(delta, rule.Id, rule.LimitPeriodUnit, now);
            var periodKey = FocusRules.PeriodKey(now, rule.LimitPeriodUnit, rollover);
            CheckPreBlockWarning(rule, Math.Max(0, rule.DailyBudgetSeconds - used), periodKey);
            if (wasUnder && used >= rule.DailyBudgetSeconds && _quotaWarningsSent.Add($"{periodKey}-{rule.Id}-done"))
            {
                Persist();
                Notice = $"Has agotado los {rule.DailyLimitMinutes} min ({rule.LimitPeriodUnit.Label().ToLowerInvariant()}) en «{rule.Name}». Queda bloqueado.";
                NotificationRequested?.Invoke($"Presupuesto agotado · {rule.Name}", Notice);
            }
        }
        else if (rule.Kind == GeneralRuleKind.WorkGoal && rule.GoalRewardMinutes > 0)
        {
            var worked = EffectiveWorkedSeconds(rule, now);
            if (!rule.IsTrackingQuota(now, Workspace.UsedSecondsToday(rule.Id, now: now), worked)) return;
            var used = Workspace.AddUsedSeconds(delta, rule.Id, now: now);
            var remaining = rule.RemainingGoalRewardSeconds(worked, used);
            var day = FocusRules.DayKey(now, rollover);
            CheckPreBlockWarning(rule, remaining, day);
            if (remaining <= 0 && _quotaWarningsSent.Add($"{day}-{rule.Id}-goal"))
            {
                Persist();
                Notice = $"Has consumido el tiempo de juego de hoy en «{rule.Name}».";
                NotificationRequested?.Invoke($"Tiempo de juego cumplido · {rule.Name}", Notice);
            }
        }
    }

    // MARK: - Actions on rules

    public static string PomodoroPhaseLabel(PomodoroPhase phase) => phase switch
    {
        PomodoroPhase.Work => "Enfoque Pomodoro",
        PomodoroPhase.ShortBreak => "Descanso corto",
        PomodoroPhase.LongBreak => "Descanso largo",
        PomodoroPhase.WaitingForUser => "Esperando tu regreso",
        _ => "En espera"
    };

    public void SkipPomodoroPhase(GeneralBlockRule rule)
    {
        var now = DateTimeOffset.Now;
        if (rule.PomodoroPhase == PomodoroPhase.Work) rule.SkipPomodoroToBreak(now);
        else rule.AdvancePomodoroPhase(false, now);
        Persist();
        Notice = $"Fase avanzada en «{rule.Name}»: ahora {PomodoroPhaseLabel(rule.PomodoroPhase).ToLowerInvariant()} (ciclo {rule.PomodoroCurrentCycle}/{rule.PomodoroTotalCycles}).";
    }

    public void ContinuePomodoro(GeneralBlockRule rule)
    {
        Notice = rule.AdvancePomodoroPhase(false, DateTimeOffset.Now);
        Persist();
    }

    public void EndLaunchVisit(GeneralBlockRule rule)
    {
        rule.EndLaunchVisitAndStartCooldown(DateTimeOffset.Now);
        Persist();
        Notice = $"Visita terminada en «{rule.Name}». Enfriamiento activo.";
    }

    public void ResetDailyQuota(GeneralBlockRule rule)
    {
        var now = DateTimeOffset.Now;
        var rollover = Workspace.Settings.DayRolloverHour;
        var day = FocusRules.DayKey(now, rollover);
        var periodKey = FocusRules.PeriodKey(now, rule.LimitPeriodUnit, rollover);
        var id = rule.Id.ToString();
        if (Workspace.DailyRuleUsage.TryGetValue(day, out var usedToday)) usedToday[id] = 0;
        if (Workspace.DailyRuleUsage.TryGetValue(periodKey, out var usedPeriod)) usedPeriod[id] = 0;
        if (Workspace.DailyRuleLaunches.TryGetValue(day, out var launches)) launches[id] = 0;
        if (Workspace.DailyRuleMatches.TryGetValue(day, out var matches)) matches[id] = 0;
        rule.ActiveLaunchDeadline = null;
        rule.LaunchCooldownDeadline = null;
        rule.ActivePostMatchGraceDeadline = null;
        rule.ActiveMatchDeadline = null;
        _quotaWarningsSent.RemoveWhere(k => k.Contains(rule.Id.ToString()));
        Workspace.RecordAudit("Reinicio de presupuesto", $"«{rule.Name}» · {rule.LimitPeriodUnit.Label()}", now);
        Persist();
        Notice = $"Contador de «{rule.Name}» reiniciado.";
    }

    public void ExportRules(string filePath)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(Workspace.GeneralRules, WorkspaceStore.PrettyJsonOptions);
        File.WriteAllBytes(filePath, bytes);
        Notice = $"{Workspace.GeneralRules.Count} reglas exportadas en {Path.GetFileName(filePath)}.";
    }

    // MARK: - Temporary exceptions

    /// <summary>Lets a site or app through for a while. Returns why it cannot be done, or null when it was added.</summary>
    public string? AddTemporaryAllow(string rawTarget, bool isApp, int minutes)
    {
        if (GetActiveProtectionGate() != null)
            return "No se puede añadir una excepción temporal sin desbloquear la sesión o regla protegida.";
        var target = (rawTarget ?? "").Trim();
        if (isApp)
        {
            target = FocusRules.CleanAppId(target);
            if (target.Length == 0) return "Escribe el nombre del programa (por ejemplo discord).";
        }
        else
        {
            var blocked = string.Join(", ", Workspace.GeneralRules.Where(r => r.Enabled).Select(r => r.Domains)
                .Append(Workspace.Session?.Task.Domains ?? ""));
            var levels = Workspace.GeneralRules.Where(r => r.Enabled).Select(r => (int)r.SimilarityProtection)
                .Append(Workspace.Session != null ? (int)Workspace.Session.Task.SimilarityProtection : 0);
            var level = (SimilarityProtectionLevel)levels.DefaultIfEmpty(0).Max();
            var problem = FocusRules.CheckSimilarityRestriction(target, blocked, level);
            if (problem != null) return problem;
            var parsed = FocusRules.ParseDomains(target).Valid;
            if (parsed.Count == 0) return "Escribe un dominio válido (por ejemplo apuntes.ejemplo.com).";
            target = parsed[0];
        }
        var length = Math.Clamp(minutes, 1, 120);
        Workspace.TemporaryAllows.Add(new TemporaryAllowEntry
        {
            Target = target,
            IsAppBundleId = isApp,
            Label = target,
            Deadline = new TrustedDeadline(length * 60.0)
        });
        Workspace.RecordAudit("Excepción temporal", $"{target} · {length} min");
        Persist();
        Notice = $"«{target}» se permite durante {length} min.";
        return null;
    }

    public void RemoveTemporaryAllow(TemporaryAllowEntry entry)
    {
        Workspace.TemporaryAllows.Remove(entry);
        Persist();
    }

    // MARK: - Profiles, categories, history

    public void DeleteProfile(Guid id)
    {
        Workspace.Profiles.RemoveAll(p => p.Id == id);
        Persist();
        Notice = "Perfil borrado.";
    }

    public void AddCategory(string name, double red, double green, double blue)
    {
        var clean = (name ?? "").Trim();
        if (clean.Length == 0 || Workspace.Settings.Categories.Any(c => string.Equals(c.Name, clean, StringComparison.OrdinalIgnoreCase)))
        {
            Error = "Escribe un nombre de categoría que no exista ya.";
            return;
        }
        Workspace.Settings.Categories.Add(new CategoryItem { Name = clean, Red = red, Green = green, Blue = blue });
        Error = "";
        Persist();
        Notice = $"Categoría «{clean}» añadida.";
    }

    /// <summary>True when the activity records may not be touched right now (a protected block is running and the setting asks for it).</summary>
    public bool ActivityHistoryLocked => Workspace.Settings.ProtectActivityHistory && GetActiveProtectionGate() != null;

    public void DeleteHistoryRecord(Guid id)
    {
        if (ActivityHistoryLocked)
        {
            Notice = "No se puede borrar el historial mientras hay un bloqueo protegido activo.";
            return;
        }
        Workspace.History.RemoveAll(h => h.Id == id);
        Persist();
        Notice = "Sesión borrada del historial.";
    }

    public void RemoveActivityDetail()
    {
        if (ActivityHistoryLocked)
        {
            Notice = "No se puede borrar el detalle de actividad mientras hay un bloqueo protegido activo.";
            return;
        }
        foreach (var record in Workspace.History)
        {
            record.PreserveSummary();
            record.Session.Activities.Clear();
            record.Session.Baseline = new Dictionary<string, FileStamp>();
        }
        Persist();
        Notice = "Detalle de actividad borrado; se conservan los totales por app.";
    }

    public void ClearAuditLog()
    {
        if (ActivityHistoryLocked)
        {
            Notice = "No se puede vaciar el registro de auditoría mientras hay un bloqueo protegido activo.";
            return;
        }
        Workspace.AuditLog.Clear();
        Persist();
        Notice = "Registro de auditoría vaciado.";
    }

    public void ExportHistoryCsv(string filePath)
    {
        static string Cell(string text) => "\"" + (text ?? "").Replace("\"", "\"\"") + "\"";
        var sb = new StringBuilder();
        sb.AppendLine("Inicio;Tarea;Área;Estado;Minutos trabajados;Interrupciones;Nota");
        foreach (var record in Workspace.History)
        {
            var state = record.Completed ? "Completada" : record.Cancelled ? "Cancelada" : "Pendiente";
            var minutes = Math.Round(record.Session.Elapsed(record.Session.EndedAt ?? record.Session.StartedAt) / 60.0, 1);
            sb.AppendLine(string.Join(";", new[]
            {
                Cell(record.Session.StartedAt.LocalDateTime.ToString("yyyy-MM-dd HH:mm")),
                Cell(record.Session.Task.Title),
                Cell(record.Session.Task.Category),
                Cell(state),
                minutes.ToString(System.Globalization.CultureInfo.InvariantCulture),
                record.Session.InterruptionCount.ToString(),
                Cell(record.Note)
            }));
        }
        File.WriteAllText(filePath, sb.ToString(), new UTF8Encoding(true));
        Notice = $"Historial exportado en {Path.GetFileName(filePath)}.";
    }

    public void ExportIcs(string filePath)
    {
        var from = DateTimeOffset.Now.AddDays(-1);
        var to = DateTimeOffset.Now.AddDays(60);
        var list = new List<FocusTask>(Workspace.Tasks.Where(t => t.IsScheduled && !t.Completed));
        foreach (var series in Workspace.Tasks.Where(t => !t.Completed && t.IsScheduled && t.RepeatRule != RepeatRule.Never))
            list.AddRange(series.UpcomingOccurrences(from, to, Workspace.Settings.Workdays));
        File.WriteAllText(filePath, IcsExporter.Build(list), new UTF8Encoding(false));
        Notice = $"Agenda exportada en {Path.GetFileName(filePath)}: ábrelo con tu calendario.";
    }

    // MARK: - Pages in browsers that are not in front (second monitor, a window behind)

    private bool _backgroundBrowserBusy;

    private bool IsUrlBlockedNow(string host, string path, DateTimeOffset now)
    {
        var cont = TrustedClock.ContinuousSeconds();
        if (Workspace.IsTemporarilyAllowed(host, path, now, cont)) return false;
        if (Workspace.Session is { Paused: false, EndedAt: null } s &&
            s.Task.PomodoroPhase(s.Elapsed(now, cont))?.IsBreak != true &&
            (s.Task.WebBlockAction != WebBlockAction.Warn || s.Task.BlockSearchMedia))
        {
            if (s.Task.BlockSearchMedia && SearchMediaRules.Matches(host, path) != null) return true;
            if (s.Task.WebBlockAction != WebBlockAction.Warn && !FocusRules.WebAllowed(host, path, s.Task.Domains, s.Task.WebListMode)) return true;
        }
        foreach (var rule in Workspace.GeneralRules.Where(candidate => candidate.Enabled))
        {
            if (rule.IsMicroPaused(now, cont) || !IsRuleEnforcing(rule, now)) continue;
            if (rule.BlockSearchMedia && SearchMediaRules.Matches(host, path) != null) return true;
            if (rule.WebBlockAction != WebBlockAction.Warn && !FocusRules.WebAllowed(host, path, rule.Domains, rule.WebListMode)) return true;
        }
        return false;
    }

    /// <summary>Minimises browser windows that are not in front and show a blocked page (macOS: watchBackgroundWindows).</summary>
    private void SweepBackgroundBrowsers(int foregroundPid)
    {
        if (_backgroundBrowserBusy || !NeedsBrowserRead()) return;
        var targets = WindowsActivity.VisibleWindows()
            .Where(w => w.ProcessId != foregroundPid && !FocusRules.IsOwnProcess(w.ProcessId) && StudyActivityVerifier.IsBrowser(w.ProcessName))
            .ToList();
        if (targets.Count == 0) return;
        _backgroundBrowserBusy = true;
        _ = Task.Run(() =>
        {
            var pages = new List<(IntPtr Hwnd, string Host, string Path)>();
            try
            {
                foreach (var win in targets)
                {
                    var url = BrowserInspector.ReadActiveUrl(win.Hwnd, win.ProcessName.ToLowerInvariant());
                    if (url.HasValue) pages.Add((win.Hwnd, url.Value.Host, url.Value.Path));
                }
            }
            catch { }
            finally { _backgroundBrowserBusy = false; }
            if (pages.Count == 0) return;
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                if (_disposed) return;
                var now = DateTimeOffset.Now;
                foreach (var page in pages)
                {
                    if (IsUrlBlockedNow(page.Host, page.Path, now)) WindowsActivity.MinimizeWindow(page.Hwnd);
                }
            });
        });
    }
}
