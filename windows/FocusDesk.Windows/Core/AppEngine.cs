using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows.Threading;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.Core;

public sealed partial class AppEngine : INotifyPropertyChanged, IDisposable, IStopGateHost
{
    public WorkspaceStore Store { get; }
    public Workspace Workspace { get; private set; }

    private string _notice = "";
    private string _error = "";
    private DateTimeOffset _selectedDate = DateTimeOffset.Now;
    private string _activePage = "Hoy";
    private bool _hourlyLayout = true;
    private readonly DispatcherTimer _timer;
    private DateTime _lastPrunedDay = DateTime.Now.Date;
    private DateTimeOffset? _lastPassiveStudyAt;
    private DateTimeOffset? _lastQuotaAt;
    private DateTimeOffset _lastWebReadAt = DateTimeOffset.MinValue;
    private bool _webReadBusy;
    private string _lastWebBlockHost = "";
    private DateTimeOffset _lastWebBlockAt = DateTimeOffset.MinValue;
    private int _ticks;
    private bool _valorantPollBusy;
    private string _lastClipboardText = "";
    private bool _disposed;

    // True when workspace.json existed but could not be read: the app is read-only until a copy is recovered or imported.
    private bool _loadFailed;
    public bool DataUnreadable => _loadFailed;

    // Pauses caused by the computer (locked screen, sleep, other user), which are not an escape attempt and need no code.
    private Guid? _pausedBySystemSessionId;
    private bool _screenLocked;
    private DateTimeOffset? _lastTickAt;
    private double? _lastTickElapsed;
    private Microsoft.Win32.SessionSwitchEventHandler? _sessionSwitchHandler;
    private Microsoft.Win32.PowerModeChangedEventHandler? _powerModeHandler;

    private Guid? _sessionFinishedNotifiedId;
    private string? _lastTaskPomodoroKey;

    private readonly Dictionary<string, (string Host, string Path, DateTimeOffset At)> _lastBrowserPages = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<Guid, DateTimeOffset> _timedMatchLastSeen = new();
    private readonly HashSet<Guid> _timedMatchOvertimeWarned = new();
    private readonly HashSet<Guid> _postMatchGraceArmed = new();
    private readonly HashSet<string> _studyUnlockedNotified = new();
    private readonly HashSet<string> _autoStartHandled = new();

    private double? _lolMatchStartedCont;
    private bool _valorantInMatch;
    private double? _valorantMatchStartedCont;
    public ValorantMatchPhase LastValorantPhase { get; private set; } = ValorantMatchPhase.Unknown;

    private ValveGsiServer? _valveServer;
    private readonly Dictionary<string, DateTimeOffset> _valveLastEventAt = new();
    private readonly Dictionary<string, bool> _valveMatchActive = new();
    private readonly Dictionary<string, double> _valveMatchStartedCont = new();
    private readonly Dictionary<Guid, DateTimeOffset> _valveUnconnectedSince = new();

    public double ContinuousActiveWorkSeconds { get; private set; }
    public TrustedDeadline? ActiveContinuousBreakDeadline { get; private set; }
    public string ActiveContinuousBreakMessage { get; private set; } = "";

    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? StateRefreshed;
    public event Action? TickUpdated;
    public event Action<string, string>? NotificationRequested;
    public event Action<WorkSession>? SessionCompletionRequested;

    public string Notice
    {
        get => _notice;
        set { _notice = value; OnPropertyChanged(); }
    }

    public string Error
    {
        get => _error;
        set { _error = value; OnPropertyChanged(); }
    }

    public DateTimeOffset SelectedDate
    {
        get => _selectedDate;
        set { _selectedDate = value; OnPropertyChanged(); StateRefreshed?.Invoke(); }
    }

    public string ActivePage
    {
        get => _activePage;
        set { _activePage = value; OnPropertyChanged(); StateRefreshed?.Invoke(); }
    }

    public bool HourlyLayout
    {
        get => _hourlyLayout;
        set { _hourlyLayout = value; OnPropertyChanged(); StateRefreshed?.Invoke(); }
    }

    private readonly bool _enablePlatformWatchers;

    public AppEngine(string? customDir = null, bool enablePlatformWatchers = true)
    {
        _enablePlatformWatchers = enablePlatformWatchers;
        Store = new WorkspaceStore(customDir);

        // 1) Reading. If the data cannot be read, the app starts EMPTY BUT READ-ONLY: it never writes over the file it
        //    could not read (it used to save an empty agenda on top of it a minute later). The original is also kept in
        //    backups/ before anything else happens.
        var loadedOk = false;
        try
        {
            LossyReadStats.Reset();
            Workspace = Store.Load();
            loadedOk = true;
        }
        catch (Exception ex)
        {
            Workspace = new Workspace();
            _loadFailed = true;
            var kept = Store.KeepOriginalCopy("lectura-fallida");
            Error = $"No se pudieron leer tus datos ({ex.Message}). No se guarda nada hasta que lo resuelvas: tu archivo está intacto" +
                    (kept != null ? $" (copia en {Path.GetFileName(kept)} dentro de «backups»)" : "") +
                    ". En Ajustes puedes «Recuperar copia automática» o importar una copia.";
        }

        // 2) The rest of the start-up. A failure here must never throw away data that did load.
        if (loadedOk)
        {
            try
            {
                var skipped = LossyReadStats.Skipped;
                if (skipped > 0)
                {
                    var kept = Store.KeepOriginalCopy("lectura-parcial");
                    Error = $"{(skipped == 1 ? "Un elemento" : $"{skipped} elementos")} de tus datos no se {(skipped == 1 ? "podía" : "podían")} leer y se {(skipped == 1 ? "ha" : "han")} dejado fuera. El resto funciona con normalidad; el archivo original está en {(kept != null ? Path.GetFileName(kept) : "«backups»")}.";
                }
                Workspace.Prune(DateTimeOffset.Now);
                Workspace.ClosedBySystemAt = null;
                if (Workspace.Session != null)
                {
                    var now = DateTimeOffset.Now;
                    var shouldResume = Workspace.Session.ShouldResumeAfterRelaunch(now);
                    Workspace.Session.RecoverAfterUncleanExit(now);
                    if (shouldResume)
                    {
                        Workspace.Session.Resume(now);
                        Notice = $"«{Workspace.Session.Task.Title}» está protegida y continúa donde estaba.";
                    }
                    else
                    {
                        Notice = $"«{Workspace.Session.Task.Title}» quedó en pausa al cerrarse FocusDesk. Puedes reanudarla cuando quieras.";
                    }
                }
                // Series skipped while the app was closed get their next occurrence back (after the daily copy, so it keeps the old state).
                Store.CreateDailySnapshotIfNeeded();
                SeriesRoller.Roll(Workspace.Tasks, Workspace.Session?.Task.Id, DateTimeOffset.Now, Workspace.Settings.Workdays);
                if (_enablePlatformWatchers) CheckWitnessTamper();
                Persist();
            }
            catch (Exception ex)
            {
                Error = $"El arranque no terminó del todo ({ex.Message}). Tus datos están cargados.";
            }
        }

        if (Workspace.GeneralRules.Any(r => r.Enabled && r.AlwaysProtected && r.Protection != SessionProtection.None))
            Workspace.Settings.RelaunchGuard = true;

        EnsureWatcherIfNeeded();
        if (_enablePlatformWatchers) RefreshValveServer();

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += (_, _) => Tick();
        if (_enablePlatformWatchers)
        {
            _timer.Start();
            HookSystemEvents();
        }
    }

    // MARK: - Locked screen, sleep and user switch (macOS: pauseForSystem / offerResumeAfterSystemPause)

    private void HookSystemEvents()
    {
        try
        {
            _sessionSwitchHandler = (_, e) =>
            {
                var reason = e.Reason;
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    if (_disposed) return;
                    switch (reason)
                    {
                        case Microsoft.Win32.SessionSwitchReason.SessionLock:
                        case Microsoft.Win32.SessionSwitchReason.ConsoleDisconnect:
                        case Microsoft.Win32.SessionSwitchReason.RemoteDisconnect:
                        case Microsoft.Win32.SessionSwitchReason.SessionLogoff:
                            _screenLocked = true;
                            PauseForSystem("por bloqueo de la pantalla o cambio de usuario");
                            break;
                        case Microsoft.Win32.SessionSwitchReason.SessionUnlock:
                        case Microsoft.Win32.SessionSwitchReason.ConsoleConnect:
                        case Microsoft.Win32.SessionSwitchReason.RemoteConnect:
                        case Microsoft.Win32.SessionSwitchReason.SessionLogon:
                            _screenLocked = false;
                            OfferResumeAfterSystemPause("mientras el equipo estaba bloqueado");
                            break;
                    }
                });
            };
            _powerModeHandler = (_, e) =>
            {
                var mode = e.Mode;
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    if (_disposed) return;
                    if (mode == Microsoft.Win32.PowerModes.Suspend)
                        PauseForSystem("al suspender el equipo");
                    else if (mode == Microsoft.Win32.PowerModes.Resume)
                        OfferResumeAfterSystemPause("mientras el equipo estaba suspendido");
                });
            };
            Microsoft.Win32.SystemEvents.SessionSwitch += _sessionSwitchHandler;
            Microsoft.Win32.SystemEvents.PowerModeChanged += _powerModeHandler;
        }
        catch { }
    }

    private void UnhookSystemEvents()
    {
        try
        {
            if (_sessionSwitchHandler != null) Microsoft.Win32.SystemEvents.SessionSwitch -= _sessionSwitchHandler;
            if (_powerModeHandler != null) Microsoft.Win32.SystemEvents.PowerModeChanged -= _powerModeHandler;
        }
        catch { }
    }

    /// <summary>
    /// The computer went to sleep, locked or changed user: not an escape attempt, so no code and no wait. The time away
    /// does not count. `excludeSeconds` takes out time that was already credited before the pause was noticed.
    /// </summary>
    private void PauseForSystem(string reason, double excludeSeconds = 0)
    {
        if (Workspace.Session is not { Paused: false, EndedAt: null } s) return;
        s.Pause(DateTimeOffset.Now);
        if (excludeSeconds > 0) s.Accumulated = Math.Max(0, s.Accumulated - excludeSeconds);
        _pausedBySystemSessionId = s.Id;
        _lastTickElapsed = null;
        Persist();
        Notice = $"Sesión en pausa {reason}. Ese rato no cuenta.";
    }

    private void OfferResumeAfterSystemPause(string reason)
    {
        if (_screenLocked) return; // woke up behind the lock screen: unlocking is what brings it back
        if (_pausedBySystemSessionId == null) return;
        if (Workspace.Session is not { Paused: true, EndedAt: null } s || s.Id != _pausedBySystemSessionId)
        {
            _pausedBySystemSessionId = null;
            return;
        }
        var now = DateTimeOffset.Now;
        _pausedBySystemSessionId = null;
        // A protected session does not ask (asking was a free way out: lock, unlock, say no). It simply carries on.
        if (s.Task.Protection != SessionProtection.None && s.Remaining(now) > 0)
        {
            ResumeSession();
            Notice = $"«{s.Task.Title}» sigue donde estaba: se pausó {reason} y ese rato no cuenta.";
            return;
        }
        Notice = $"«{s.Task.Title}» se pausó {reason}. Te quedan {FocusRules.Clock(Math.Max(0, s.Remaining(now)))}. Pulsa «Reanudar» cuando estés listo.";
        NotificationRequested?.Invoke($"Sesión en pausa · {s.Task.Title}", Notice);
    }

    /// <summary>
    /// Fallback when Windows does not announce the sleep (Modern Standby): the clock ticks every second, so a gap of
    /// 90 s or more in which the session was credited the whole gap means the machine was away. That time is taken out.
    /// </summary>
    private void DetectSleepGap(DateTimeOffset now)
    {
        var previousTick = _lastTickAt;
        _lastTickAt = now;
        if (Workspace.Session is not { Paused: false, EndedAt: null } s)
        {
            _lastTickElapsed = null;
            return;
        }
        var elapsedNow = s.Elapsed(now);
        var previousElapsed = _lastTickElapsed;
        _lastTickElapsed = elapsedNow;
        if (previousTick == null || previousElapsed == null) return;
        if ((now - previousTick.Value).TotalSeconds < 90) return;
        var credited = elapsedNow - previousElapsed.Value;
        if (credited < 90) return; // the clock was moved, not the machine suspended
        PauseForSystem("tras un reposo del equipo", Math.Max(0, credited - 1.0));
        if (!_screenLocked) OfferResumeAfterSystemPause("mientras el equipo estaba en reposo");
    }

    public void EnsureWatcherIfNeeded()
    {
        if (!_enablePlatformWatchers) return;
        var needsWatcher = Workspace.Settings.RelaunchGuard ||
            (Workspace.Session is { EndedAt: null } s && s.Task.Protection != SessionProtection.None) ||
            Workspace.GeneralRules.Any(r => r.Enabled && r.Protection != SessionProtection.None);

        if (Workspace.Settings.RelaunchGuard && !RelaunchGuard.IsInstalledForThisExe())
            RelaunchGuard.Install();
        else if (needsWatcher)
            RelaunchGuard.StartWatcherProcessIfMissing();
    }

    public (SessionProtection Protection, int UnlockChars, int StopDelayMinutes, string ContextLabel)? GetActiveProtectionGate(DateTimeOffset? at = null)
    {
        var t = at ?? DateTimeOffset.Now;
        if (Workspace.Session is { EndedAt: null } s && s.Task.Protection != SessionProtection.None && s.Remaining(t) > 0)
            return (s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"mientras «{s.Task.Title}» está en marcha");

        var armedTask = Workspace.Tasks.FirstOrDefault(task =>
            !task.Completed && task.Id != Workspace.Session?.Task.Id && IsTaskProtected(task, t));
        if (armedTask != null)
            return (armedTask.Protection, armedTask.UnlockChars, armedTask.StopDelayMinutes, $"antes del inicio de «{armedTask.Title}»");

        var protectedRule = Workspace.GeneralRules
            .Where(r => IsRuleProtected(r, t))
            .OrderByDescending(r => r.Protection.Strength())
            .FirstOrDefault();
        if (protectedRule != null)
            return (protectedRule.Protection, protectedRule.UnlockChars, protectedRule.StopDelayMinutes, $"mientras la regla «{protectedRule.Name}» está protegida");

        return null;
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    private void CheckWitnessTamper()
    {
        var w = DpapiWitness.Load();
        if (w == null) return;
        if (w.ActiveSessionId.HasValue && w.SessionProtection != SessionProtection.None &&
            w.SessionDeadline != null && w.SessionDeadline.RemainingAfterPossibleReboot() > 15 &&
            Workspace.Session == null)
        {
            Workspace.RecordAudit("Testigo", "El archivo de datos perdió una sesión protegida activa.");
            Notice = "Se detectó un cambio externo mientras había una sesión protegida.";
        }
        var currentFp = DpapiWitness.Fingerprint(Workspace.GeneralRules);
        if (w.ProtectedRuleCount > 0 && currentFp != w.RulesFingerprint)
        {
            Workspace.RecordAudit("Testigo", "Cambio externo detectado en reglas protegidas.");
        }

        // A protected rule that the data file lost or softened while FocusDesk was closed comes back as it was
        // (macOS: the witness in the Keychain restores it).
        if (w.ProtectedRules is { Count: > 0 })
        {
            var restored = new List<string>();
            var launchNow = DateTimeOffset.Now;
            foreach (var witnessed in w.ProtectedRules)
            {
                if (!IsRuleProtected(witnessed, launchNow)) continue;
                var index = Workspace.GeneralRules.FindIndex(r => r.Id == witnessed.Id);
                if (index < 0)
                {
                    Workspace.GeneralRules.Add(witnessed);
                    restored.Add($"«{witnessed.Name}»");
                }
                else if (GeneralBlockRule.Loosening(witnessed, Workspace.GeneralRules[index], launchNow) != null)
                {
                    Workspace.GeneralRules[index] = witnessed;
                    restored.Add($"«{witnessed.Name}»");
                }
            }
            if (restored.Count > 0)
            {
                Workspace.RecordAudit("Testigo", $"Se restauraron reglas protegidas: {string.Join(", ", restored)}.");
                Notice = $"Se {(restored.Count == 1 ? "ha restaurado la regla protegida" : "han restaurado las reglas protegidas")} {string.Join(", ", restored)} desde el testigo de seguridad.";
            }
        }
    }

    public void RefreshWitness()
    {
        if (!_enablePlatformWatchers) return;
        var s = Workspace.Session;
        var payload = new DpapiWitness.WitnessPayload
        {
            ActiveSessionId = s?.Id,
            ActiveTaskTitle = s?.Task.Title,
            SessionProtection = s?.Task.Protection ?? SessionProtection.None,
            SessionDeadline = s != null && !s.Paused && s.EndedAt == null
                ? new TrustedDeadline(Math.Max(0, s.Remaining(DateTimeOffset.Now)))
                : null,
            ProtectedRuleCount = Workspace.GeneralRules.Count(r => r.Enabled && r.Protection != SessionProtection.None),
            RulesFingerprint = DpapiWitness.Fingerprint(Workspace.GeneralRules),
            ProtectedRules = Workspace.GeneralRules.Where(r => IsRuleProtected(r)).Select(r => r.Clone()).ToList(),
            SavedAt = DateTimeOffset.UtcNow
        };
        DpapiWitness.Save(payload);
    }

    public bool Persist()
    {
        // The data on disk could not be read: never write an empty agenda over it (see the constructor).
        if (_loadFailed)
        {
            Error = "Tus datos no se pudieron leer y por eso este cambio NO se ha guardado. Tu archivo está intacto: en Ajustes usa «Recuperar copia automática» o «Importar copia».";
            StateRefreshed?.Invoke();
            return false;
        }
        try
        {
            Store.Save(Workspace);
            RefreshWitness();
            StateRefreshed?.Invoke();
            return true;
        }
        catch (Exception ex)
        {
            Error = $"No se pudo guardar: {ex.Message}";
            return false;
        }
    }

    private void RefreshValveServer()
    {
        var needsValve = Workspace.GeneralRules.Any(r => r.Enabled && r.UsesExactValveGSI);
        if (!needsValve)
        {
            _valveServer?.Dispose();
            _valveServer = null;
            return;
        }
        ValveGSI.InstallConfigIfPossible();
        if (_valveServer != null) return;
        _valveServer = new ValveGsiServer(ev =>
        {
            if (_disposed) return;
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                if (!_disposed) HandleValveEvent(ev);
            });
        });
        _valveServer.Start();
    }

    public double EffectiveWorkedSeconds(GeneralBlockRule rule, DateTimeOffset? at = null)
    {
        var t = at ?? DateTimeOffset.Now;
        if (rule.VerifyActiveStudy) return Workspace.VerifiedStudySecondsToday(t);
        var day = FocusRules.DayKey(t, Workspace.Settings.DayRolloverHour);
        var histSec = Workspace.History
            .Where(h => FocusRules.DayKey(h.Session.StartedAt, Workspace.Settings.DayRolloverHour) == day)
            .Sum(h => h.Session.Elapsed(h.Session.EndedAt ?? t));
        var curSec = Workspace.Session != null && FocusRules.DayKey(Workspace.Session.StartedAt, Workspace.Settings.DayRolloverHour) == day
            ? Workspace.Session.Elapsed(t)
            : 0;
        return histSec + curSec;
    }

    public bool IsMatchInProgress(GeneralBlockRule rule, DateTimeOffset? at = null)
    {
        var t = at ?? DateTimeOffset.Now;
        if (rule.IsInTimedMatch(t)) return true;
        if (!rule.DeferBlockUntilMatchEnds) return false;
        if (LeagueMatchRules.RuleTargetsLeague(rule)) return IsLoLMatchRunning();
        if (rule.UsesExactValorant) return _valorantInMatch;
        if (rule.UsesExactValveGSI && rule.GameId != null) return _valveMatchActive.GetValueOrDefault(rule.GameId);
        return false;
    }

    public bool IsRuleEnforcing(GeneralBlockRule rule, DateTimeOffset? at = null)
    {
        var t = at ?? DateTimeOffset.Now;
        return rule.IsEnforcing(
            t,
            Workspace.UsedSecondsToday(rule.Id, now: t),
            EffectiveWorkedSeconds(rule, t),
            Workspace.LaunchesToday(rule.Id, t),
            Workspace.MatchesToday(rule.Id, t),
            IsMatchInProgress(rule, t));
    }

    public bool IsRuleProtected(GeneralBlockRule rule, DateTimeOffset? at = null)
    {
        var t = at ?? DateTimeOffset.Now;
        return rule.IsProtectedNow(
            t,
            Workspace.UsedSecondsToday(rule.Id, now: t),
            EffectiveWorkedSeconds(rule, t),
            Workspace.LaunchesToday(rule.Id, t),
            Workspace.MatchesToday(rule.Id, t),
            IsMatchInProgress(rule, t),
            Workspace.Settings.RunUpMinutes);
    }

    public bool IsTaskProtected(FocusTask task, DateTimeOffset? at = null)
    {
        if (task.Protection == SessionProtection.None) return false;
        var t = at ?? DateTimeOffset.Now;
        if (Workspace.Session is { EndedAt: null } s && s.Task.Id == task.Id && s.Remaining(t) > 0)
            return true;
        return FocusRules.IsTaskInRunUp(task, Workspace.Settings.RunUpMinutes, t);
    }

    public (string Text, bool Warning, bool CanFinish, double Progress) GameRuleStatus(GeneralBlockRule rule, DateTimeOffset? at = null)
    {
        var t = at ?? DateTimeOffset.Now;
        var unit = rule.MatchUnitSingular;
        var plural = rule.MatchUnitPlural;
        var maxM = Math.Max(1, rule.MaxDailyMatches);
        var played = Workspace.MatchesToday(rule.Id, t);
        var next = Math.Min(maxM, played + 1);
        var worked = EffectiveWorkedSeconds(rule, t);
        var needed = rule.RequiredWorkSecondsForNextMatch(played);

        var grace = rule.PostMatchGraceRemainingSeconds(t);
        if (grace > 0)
            return ($"{Capitalize(unit)} terminada · se cierra en {(int)Math.Ceiling(grace)} s", true, false, 1);

        if (rule.IsInTimedMatch(t))
        {
            var left = rule.TimedMatchRemainingSeconds(t);
            if (rule.IsInTimedMatchOvertime(t))
                return ($"Prórroga {next}/{maxM} · se cierra en {FocusRules.Clock(left)}", true, true, 1);
            var beforeOvertime = left - rule.MatchOvertimeMinutes * 60.0;
            var extra = rule.MatchOvertimeMinutes > 0 ? $" + {rule.MatchOvertimeMinutes} min de prórroga" : "";
            return ($"{Capitalize(unit)} {next}/{maxM} en curso · {FocusRules.Clock(beforeOvertime)}{extra}", false, true, 1);
        }

        if (IsMatchInProgress(rule, t))
            return ($"{Capitalize(unit)} {next}/{maxM} en curso · sin cortes hasta que acabe", false, false, 1);

        if (played >= maxM)
            return ($"{played}/{maxM} {plural} · bloqueado hasta mañana", true, false, 1);

        if (worked < needed)
        {
            var what = rule.VerifyActiveStudy ? "estudio" : "trabajo";
            return ($"Faltan {FocusRules.Clock(needed - worked)} de {what} para la {unit} {next}/{maxM}", false, false,
                Math.Clamp(worked / Math.Max(1, needed), 0, 1));
        }

        var available = rule.EarnsMatchesPerGoalBlock ? Math.Max(1, rule.EarnedMatches(worked) - played) : maxM - played;
        var text = available == 1
            ? $"{Capitalize(unit)} {next}/{maxM} disponible"
            : $"{available} {plural} disponibles ({played}/{maxM} jugadas)";
        return (text, false, false, 1);
    }

    private void Tick()
    {
        if (_disposed) return;
        var now = DateTimeOffset.Now;
        _ticks++;

        DetectSleepGap(now);
        TickStopWaits(now);

        if (now.LocalDateTime.Date != _lastPrunedDay)
        {
            // With the app open overnight, «Hoy» kept showing the day it was started. Follow the new day only if the
            // person was looking at the day that just ended (not a date chosen on purpose).
            var previousDay = _lastPrunedDay;
            _lastPrunedDay = now.LocalDateTime.Date;
            if (_selectedDate.LocalDateTime.Date == previousDay) SelectedDate = now;
            try { Store.CreateDailySnapshotIfNeeded(now); } catch { }
            Workspace.Prune(now);
            SeriesRoller.Roll(Workspace.Tasks, Workspace.Session?.Task.Id, now, Workspace.Settings.Workdays);
            Persist();
        }

        StartDueAutoStartTasks(now);
        TickSessionEvents(now);
        TickContinuousBreak(now);
        TickPomodoroRules(now);
        TickPassiveStudyTracking(now);
        TickLeagueMatches(now);
        TickValorantMatches(now);
        TickValveGSIMatches(now);
        TickTimedGameMatches(now);

        if (_ticks % 3 == 0)
        {
            ObserveForeground(now);
            CheckClipboardGuard();
        }
        if (_ticks % 15 == 0)
        {
            if (Workspace.Session is { Paused: false, EndedAt: null } runningSess)
            {
                runningSess.Checkpoint(now);
                Persist();
            }
            EnsureWatcherIfNeeded();
        }
        if (_ticks % 60 == 0)
        {
            Persist();
        }
        TickUpdated?.Invoke();
    }

    private void TickSessionEvents(DateTimeOffset now)
    {
        if (Workspace.Session is not { Paused: false, EndedAt: null } s) return;
        var rem = s.Remaining(now);
        if (rem <= 0 && _sessionFinishedNotifiedId != s.Id)
        {
            _sessionFinishedNotifiedId = s.Id;
            Notice = $"¡Bloque terminado en «{s.Task.Title}»! Ya puedes pulsar «He terminado».";
            NotificationRequested?.Invoke("Tiempo completado · FocusDesk", Notice);
        }
        if (s.Task.PomodoroPhase(s.Elapsed(now)) is { } phase)
        {
            var key = $"{s.Id}:{phase.Cycle}:{phase.IsBreak}:{phase.IsLongBreak}";
            if (_lastTaskPomodoroKey != null && _lastTaskPomodoroKey != key)
            {
                Notice = phase.IsBreak
                    ? $"Descanso Pomodoro ({phase.Label}) en «{s.Task.Title}»."
                    : $"Vuelta al foco (ciclo {phase.Cycle}) en «{s.Task.Title}».";
                NotificationRequested?.Invoke("Pomodoro de tarea", Notice);
            }
            _lastTaskPomodoroKey = key;
        }
        else
        {
            _lastTaskPomodoroKey = null;
        }
    }

    private void StartDueAutoStartTasks(DateTimeOffset now)
    {
        if (Workspace.Session != null || _screenLocked || _loadFailed) return;
        var due = Workspace.Tasks.FirstOrDefault(t =>
            t.AutoStart && !t.Completed && t.IsScheduled &&
            t.ScheduledAt <= now && now < t.End &&
            _autoStartHandled.Add($"{t.Id}@{t.ScheduledAt.ToUnixTimeSeconds()}"));
        if (due != null) StartSession(due);
    }

    private void TickContinuousBreak(DateTimeOffset now)
    {
        if (!Workspace.Settings.ContinuousBreakEnabled) return;
        if (ActiveContinuousBreakDeadline != null)
        {
            if (ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot(now) <= 0)
            {
                ActiveContinuousBreakDeadline = null;
                ContinuousActiveWorkSeconds = 0;
                Notice = "Descanso terminado. ¡Seguimos!";
                NotificationRequested?.Invoke("Descanso terminado", Notice);
            }
            return;
        }
        var idle = WindowsActivity.IdleSeconds();
        if (idle < 120)
        {
            ContinuousActiveWorkSeconds++;
            if (ContinuousActiveWorkSeconds >= Workspace.Settings.ContinuousWorkMinutes * 60.0)
            {
                ActiveContinuousBreakDeadline = new TrustedDeadline(Workspace.Settings.ContinuousBreakDurationMinutes * 60.0, now);
                var msgs = Workspace.Settings.BreakMessages;
                ActiveContinuousBreakMessage = msgs.Count > 0 ? msgs[Random.Shared.Next(msgs.Count)] : "Descansa un momento.";
                NotificationRequested?.Invoke("Hora de descansar la vista", ActiveContinuousBreakMessage);
            }
        }
        else if (idle >= 180)
        {
            ContinuousActiveWorkSeconds = 0;
        }
    }

    private void TickPomodoroRules(DateTimeOffset now)
    {
        var idle = WindowsActivity.IdleSeconds() >= 60;
        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && r.Kind == GeneralRuleKind.Pomodoro))
        {
            if (rule.PomodoroPhase == PomodoroPhase.WaitingForUser && !idle)
            {
                Notice = rule.AdvancePomodoroPhase(false, now);
                Persist();
            }
            else if (rule.ActivePomodoroDeadline != null && rule.ActivePomodoroDeadline.RemainingAfterPossibleReboot(now) <= 0)
            {
                var msg = rule.AdvancePomodoroPhase(idle, now);
                Notice = msg;
                NotificationRequested?.Invoke($"Pomodoro · {rule.Name}", msg);
                Persist();
            }
        }
    }

    private void TickPassiveStudyTracking(DateTimeOffset now)
    {
        if (!Workspace.GeneralRules.Any(r => r.Enabled && r.Kind == GeneralRuleKind.WorkGoal && r.VerifyActiveStudy))
        {
            _lastPassiveStudyAt = null;
            return;
        }
        var delta = _lastPassiveStudyAt.HasValue ? Math.Clamp((now - _lastPassiveStudyAt.Value).TotalSeconds, 0, 3) : 1.0;
        _lastPassiveStudyAt = now;
        if (delta <= 0) return;

        var fg = WindowsActivity.GetForegroundApp();
        if (fg == null) return;
        var idle = WindowsActivity.IdleSeconds();
        var visible = WindowsActivity.HasVisibleWindow(fg.ProcessId);
        _lastBrowserPages.TryGetValue(fg.ProcessName.ToLowerInvariant(), out var recentPage);
        var validPage = (now - recentPage.At).TotalSeconds <= 25 ? recentPage : default;

        var day = FocusRules.DayKey(now, Workspace.Settings.DayRolloverHour);
        var (apps, webs) = StudySources.Active(Workspace.Settings.StudySources, day);

        if (!StudyActivityVerifier.IsVerifiedStudyActivity(
                idle, fg.ProcessName, fg.ExecutablePath, visible, fg.WindowTitle,
                validPage.Host, validPage.Path, apps, webs))
            return;

        var prev = Workspace.VerifiedStudySecondsToday(now);
        var updated = Workspace.AddVerifiedStudySeconds(delta, now);

        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && r.Kind == GeneralRuleKind.WorkGoal && r.VerifyActiveStudy))
        {
            if (rule.EarnsMatchesPerGoalBlock)
            {
                var before = rule.EarnedMatches(prev);
                var after = rule.EarnedMatches(updated);
                var key = $"{day}-{rule.Id}-u-{after}";
                if (after > before && _studyUnlockedNotified.Add(key))
                {
                    Persist();
                    var played = Workspace.MatchesToday(rule.Id, now);
                    var msg = played < after
                        ? $"¡{after} h de estudio activo! Tienes disponible la {rule.MatchUnitSingular} {played + 1}/{rule.MaxDailyMatches} de {rule.Game?.Name ?? rule.Name}."
                        : $"¡{after} h de estudio activo hoy!";
                    Notice = msg;
                    NotificationRequested?.Invoke($"Desbloqueado · {rule.Name}", msg);
                }
            }
            else if (prev < rule.GoalRequiredSeconds && updated >= rule.GoalRequiredSeconds && _studyUnlockedNotified.Add($"{day}-{rule.Id}-u"))
            {
                Persist();
                Notice = $"¡Meta de {rule.GoalMinutesRequired} min completada! «{rule.Name}» desbloqueada.";
                NotificationRequested?.Invoke($"Estudio completado · {rule.Name}", Notice);
            }
        }
    }

    private static bool IsLoLMatchRunning() =>
        WindowsActivity.RunningProcesses().Any(p => LeagueMatchRules.IsMatchGameProcess(p.Name, p.ExePath));

    private static List<int> RunningGamePids(GeneralBlockRule rule)
    {
        var game = rule.Game;
        var pids = new List<int>();
        foreach (var p in WindowsActivity.RunningProcesses())
        {
            var clean = p.Name.ToLowerInvariant().Replace(".exe", "");
            if (FocusRules.SystemExemptProcesses.Contains(clean)) continue;
            var matchAppList = rule.BlockApps && rule.Apps.Any(a =>
                string.Equals(a.Id.Replace(".exe", "", StringComparison.OrdinalIgnoreCase), clean, StringComparison.OrdinalIgnoreCase));
            var matchCatalog = game != null && game.Id != GameCatalog.CustomId && game.Matches(p.Name, p.ExePath, p.Title);
            if (matchAppList || matchCatalog) pids.Add(p.Pid);
        }
        return pids;
    }

    private string GameLockMessage(GeneralBlockRule rule, DateTimeOffset now)
    {
        var name = rule.Game?.Name ?? rule.Name;
        var played = Workspace.MatchesToday(rule.Id, now);
        if (rule.MaxDailyMatches > 0 && played >= rule.MaxDailyMatches)
            return $"{name} está bloqueado por hoy ({played}/{rule.MaxDailyMatches} {rule.MatchUnitPlural}).";
        var needed = rule.RequiredWorkSecondsForNextMatch(played);
        var worked = EffectiveWorkedSeconds(rule, now);
        var leftMin = Math.Max(1, (int)Math.Ceiling((needed - worked) / 60.0));
        return $"{name} está bloqueado: te faltan {leftMin} min de estudio para la {rule.MatchUnitSingular} {played + 1}/{Math.Max(1, rule.MaxDailyMatches)}.";
    }

    private bool IsRuleBlockingNewMatch(GeneralBlockRule rule, DateTimeOffset now, double cont) =>
        rule.IsEnforcing(
            now,
            Workspace.UsedSecondsToday(rule.Id, now: now),
            EffectiveWorkedSeconds(rule, now),
            Workspace.LaunchesToday(rule.Id, now),
            Workspace.MatchesToday(rule.Id, now),
            isMatchInProgress: false,
            continuous: cont);

    private void TickLeagueMatches(DateTimeOffset now)
    {
        var lolRules = Workspace.GeneralRules.Where(r => r.Enabled && LeagueMatchRules.RuleTargetsLeague(r)).ToList();
        if (lolRules.Count == 0) return;

        var cont = TrustedClock.ContinuousSeconds();
        var matchRunning = IsLoLMatchRunning();

        if (matchRunning)
        {
            if (!_lolMatchStartedCont.HasValue)
            {
                var blocked = lolRules.FirstOrDefault(r => IsRuleBlockingNewMatch(r, now, cont));
                if (blocked != null)
                {
                    WindowsActivity.TerminateProcesses(RunningGamePids(blocked));
                    Notice = GameLockMessage(blocked, now);
                }
                else
                {
                    _lolMatchStartedCont = cont;
                    Notice = "Partida de League of Legends en curso · FocusDesk no te sacará a mitad.";
                }
            }
        }
        else if (_lolMatchStartedCont.HasValue)
        {
            var dur = Math.Max(0, cont - _lolMatchStartedCont.Value);
            _lolMatchStartedCont = null;
            if (dur >= LeagueMatchRules.MinCountedMatchDurationSeconds)
                FinishExactMatch(r => LeagueMatchRules.RuleTargetsLeague(r), "League of Legends", now, cont);
        }

        HandleExactPostMatchGraceAndBlocks(r => LeagueMatchRules.RuleTargetsLeague(r), () => matchRunning, "League of Legends", now, cont);
    }

    private void TickValorantMatches(DateTimeOffset now)
    {
        var valRules = Workspace.GeneralRules.Where(r => r.Enabled && r.UsesExactValorant).ToList();
        if (valRules.Count == 0) return;

        var cont = TrustedClock.ContinuousSeconds();
        var procs = WindowsActivity.RunningProcesses();
        var valAnyRunning = procs.Any(p => ValorantMatchRules.IsValorantProcess(p.Name, p.ExePath));
        var valExeRunning = procs.Any(p => ValorantMatchRules.IsValorantGameExeRunning(p.Name, p.ExePath));

        if (valAnyRunning && _ticks % 3 == 0 && !_valorantPollBusy)
        {
            _valorantPollBusy = true;
            _ = Task.Run(async () =>
            {
                try
                {
                    var phase = await ValorantMatchRules.QueryLocalClientPhaseAsync();
                    if (_disposed) return;
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        if (!_disposed) ProcessValorantPhase(phase, valExeRunning);
                    });
                }
                finally { _valorantPollBusy = false; }
            });
        }
        else if (!valAnyRunning && _valorantInMatch)
        {
            ProcessValorantPhase(ValorantMatchPhase.Menu, false);
        }

        HandleExactPostMatchGraceAndBlocks(r => r.UsesExactValorant, () => _valorantInMatch, "Valorant", now, cont);
    }

    private void ProcessValorantPhase(ValorantMatchPhase phase, bool valExeRunning)
    {
        LastValorantPhase = phase;
        var now = DateTimeOffset.Now;
        var cont = TrustedClock.ContinuousSeconds();
        var active = phase == ValorantMatchPhase.InMatch;

        if (active)
        {
            if (!_valorantInMatch)
            {
                var blocked = Workspace.GeneralRules.FirstOrDefault(r =>
                    r.Enabled && r.UsesExactValorant && IsRuleBlockingNewMatch(r, now, cont));
                if (blocked != null)
                {
                    WindowsActivity.TerminateProcesses(RunningGamePids(blocked));
                    Notice = GameLockMessage(blocked, now);
                    return;
                }
                _valorantInMatch = true;
                _valorantMatchStartedCont = cont;
                Notice = "Partida de Valorant en curso · FocusDesk no te sacará a mitad.";
            }
        }
        else if (_valorantInMatch && (phase == ValorantMatchPhase.Menu || !valExeRunning))
        {
            var dur = _valorantMatchStartedCont.HasValue ? cont - _valorantMatchStartedCont.Value : 0;
            _valorantInMatch = false;
            _valorantMatchStartedCont = null;
            if (dur >= LeagueMatchRules.MinCountedMatchDurationSeconds)
                FinishExactMatch(r => r.UsesExactValorant, "Valorant", now, cont);
        }
    }

    private void HandleValveEvent(ValveGSI.Event ev)
    {
        var now = DateTimeOffset.Now;
        var cont = TrustedClock.ContinuousSeconds();
        _valveLastEventAt[ev.GameId] = now;
        foreach (var r in Workspace.GeneralRules.Where(r => r.Enabled && r.GameId == ev.GameId))
        {
            if (r.ActiveMatchDeadline != null) r.EndTimedMatch();
            _valveUnconnectedSince.Remove(r.Id);
        }

        var rules = Workspace.GeneralRules.Where(r => r.Enabled && r.UsesExactValveGSI && r.GameId == ev.GameId).ToList();
        if (rules.Count == 0) return;
        var gameName = GameCatalog.Find(ev.GameId)?.Name ?? ev.GameId;

        if (ev.Phase is ValveGSI.MatchPhase.Live or ValveGSI.MatchPhase.Intermission)
        {
            if (!_valveMatchActive.GetValueOrDefault(ev.GameId))
            {
                var blocked = rules.FirstOrDefault(r => IsRuleBlockingNewMatch(r, now, cont));
                if (blocked != null)
                {
                    WindowsActivity.TerminateProcesses(RunningGamePids(blocked));
                    Notice = GameLockMessage(blocked, now);
                    return;
                }
                _valveMatchActive[ev.GameId] = true;
                _valveMatchStartedCont[ev.GameId] = cont;
                Notice = $"Partida de {gameName} en curso · FocusDesk no te sacará a mitad.";
            }
        }
        else if (ev.Phase == ValveGSI.MatchPhase.GameOver ||
                 (ev.Phase == ValveGSI.MatchPhase.Menu && _valveMatchActive.GetValueOrDefault(ev.GameId) &&
                  _valveMatchStartedCont.TryGetValue(ev.GameId, out var st) && cont - st >= 120))
        {
            _valveMatchActive[ev.GameId] = false;
            _valveMatchStartedCont.Remove(ev.GameId);
            FinishExactMatch(r => r.UsesExactValveGSI && r.GameId == ev.GameId, gameName, now, cont);
        }
    }

    private void TickValveGSIMatches(DateTimeOffset now)
    {
        var cont = TrustedClock.ContinuousSeconds();
        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && r.UsesExactValveGSI && r.GameId != null).ToList())
        {
            var gameId = rule.GameId!;
            var name = rule.Game?.Name ?? rule.Name;
            if (rule.IsInPostMatchGrace(now, cont))
            {
                _postMatchGraceArmed.Add(rule.Id);
                continue;
            }
            if (_postMatchGraceArmed.Remove(rule.Id))
            {
                rule.ActivePostMatchGraceDeadline = null;
                Persist();
                WindowsActivity.TerminateProcesses(RunningGamePids(rule));
                Notice = $"Margen finalizado: FocusDesk ha cerrado {name}.";
                continue;
            }

            var pids = RunningGamePids(rule);
            var gsiConnected = _valveLastEventAt.TryGetValue(gameId, out var lastEv) && (now - lastEv).TotalSeconds <= 600;
            if (gsiConnected)
            {
                _valveUnconnectedSince.Remove(rule.Id);
                if (!_valveMatchActive.GetValueOrDefault(gameId) && pids.Count > 0 && IsRuleEnforcing(rule, now))
                {
                    WindowsActivity.TerminateProcesses(pids);
                    Notice = GameLockMessage(rule, now);
                }
                continue;
            }

            if (pids.Count == 0 && rule.ActiveMatchDeadline == null)
            {
                _valveUnconnectedSince.Remove(rule.Id);
                continue;
            }
            if (pids.Count > 0 && rule.ActiveMatchDeadline == null && IsRuleEnforcing(rule, now))
            {
                WindowsActivity.TerminateProcesses(pids);
                Notice = GameLockMessage(rule, now);
                continue;
            }
            if (rule.ActiveMatchDeadline == null)
            {
                if (!_valveUnconnectedSince.TryGetValue(rule.Id, out var first))
                {
                    _valveUnconnectedSince[rule.Id] = now;
                    continue;
                }
                if ((now - first).TotalSeconds < 60) continue;
            }
            StepTimedMatch(rule, allowTimedFallback: true, now, cont);
        }
    }

    private void FinishExactMatch(Func<GeneralBlockRule, bool> selector, string gameName, DateTimeOffset now, double cont)
    {
        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && selector(r)))
        {
            var newMatches = Workspace.IncrementMatches(rule.Id, now);
            var worked = EffectiveWorkedSeconds(rule, now);
            var limitHit = rule.MaxDailyMatches > 0 && newMatches >= rule.MaxDailyMatches;
            var needsWork = rule.IsWaitingForMoreWork(worked, newMatches);

            if (limitHit || needsWork)
            {
                rule.StartPostMatchGrace(now, cont);
                _postMatchGraceArmed.Add(rule.Id);
                Workspace.RecordAudit("Partida terminada", $"«{rule.Name}» · Partida {newMatches}/{Math.Max(1, rule.MaxDailyMatches)} · Margen de {rule.PostMatchGraceSeconds}s", now);
                Notice = $"Partida {newMatches}/{Math.Max(1, rule.MaxDailyMatches)} de {gameName} terminada. Tienes {rule.PostMatchGraceSeconds}s de margen antes de cerrarlo.";
                NotificationRequested?.Invoke($"Último minuto · {gameName}", Notice);
            }
            else
            {
                Notice = $"Partida {newMatches}/{rule.MaxDailyMatches} de {gameName} completada.";
            }
        }
        Persist();
    }

    private void HandleExactPostMatchGraceAndBlocks(Func<GeneralBlockRule, bool> selector, Func<bool> matchRunning, string gameName, DateTimeOffset now, double cont)
    {
        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && selector(r)))
        {
            if (rule.IsInPostMatchGrace(now, cont))
            {
                _postMatchGraceArmed.Add(rule.Id);
                continue;
            }
            if (_postMatchGraceArmed.Remove(rule.Id))
            {
                rule.ActivePostMatchGraceDeadline = null;
                Persist();
                WindowsActivity.TerminateProcesses(RunningGamePids(rule));
                Notice = $"Margen finalizado: FocusDesk ha cerrado {gameName}.";
                NotificationRequested?.Invoke($"{gameName} cerrado", Notice);
                continue;
            }
            if (!matchRunning() && IsRuleEnforcing(rule, now))
            {
                var pids = RunningGamePids(rule);
                if (pids.Count > 0)
                {
                    WindowsActivity.TerminateProcesses(pids);
                    Notice = GameLockMessage(rule, now);
                }
            }
        }
    }

    private void TickTimedGameMatches(DateTimeOffset now)
    {
        var cont = TrustedClock.ContinuousSeconds();
        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && r.UsesTimedMatches).ToList())
            StepTimedMatch(rule, allowTimedFallback: false, now, cont);
    }

    private void StepTimedMatch(GeneralBlockRule rule, bool allowTimedFallback, DateTimeOffset now, double cont)
    {
        var pids = RunningGamePids(rule);
        var webPlaying = IsPlayingGameOnWeb(rule, now);
        var running = pids.Count > 0 || webPlaying;
        if (running) _timedMatchLastSeen[rule.Id] = now;
        var since = _timedMatchLastSeen.TryGetValue(rule.Id, out var seen) ? (now - seen).TotalSeconds : double.PositiveInfinity;

        var step = TimedMatchPlanner.Evaluate(rule, running, since, EffectiveWorkedSeconds(rule, now), Workspace.MatchesToday(rule.Id, now), allowTimedFallback, now, cont);
        switch (step.Kind)
        {
            case TimedMatchPlanner.StepKind.Idle:
                if (pids.Count > 0 && IsRuleEnforcing(rule, now))
                {
                    WindowsActivity.TerminateProcesses(pids);
                    Notice = GameLockMessage(rule, now);
                }
                break;
            case TimedMatchPlanner.StepKind.Start:
                rule.StartTimedMatch(now, cont);
                _timedMatchOvertimeWarned.Remove(rule.Id);
                var num = Math.Min(Math.Max(1, rule.MaxDailyMatches), Workspace.MatchesToday(rule.Id, now) + 1);
                Workspace.RecordAudit("Partida empezada", $"«{rule.Name}» · {Capitalize(rule.MatchUnitSingular)} {num}/{rule.MaxDailyMatches}", now);
                Notice = $"{Capitalize(rule.MatchUnitSingular)} {num}/{rule.MaxDailyMatches} de {rule.Game?.Name ?? rule.Name} en marcha: {rule.MatchMinutes} min + {rule.MatchOvertimeMinutes} min de prórroga.";
                NotificationRequested?.Invoke($"{Capitalize(rule.MatchUnitSingular)} en marcha", Notice);
                Persist();
                break;
            case TimedMatchPlanner.StepKind.Overtime:
                if (_timedMatchOvertimeWarned.Add(rule.Id))
                {
                    var left = Math.Max(1, (int)Math.Ceiling(rule.TimedMatchRemainingSeconds(now, cont) / 60.0));
                    Notice = $"Se acabó el tiempo de esta {rule.MatchUnitSingular}: tienes {left} min de prórroga para acabar.";
                    NotificationRequested?.Invoke($"Prórroga · {rule.Game?.Name ?? rule.Name}", Notice);
                }
                break;
            case TimedMatchPlanner.StepKind.Finish:
                FinishTimedMatch(rule, step.Reason ?? TimedMatchPlanner.FinishReason.TimeUp, now);
                break;
        }
    }

    public void FinishTimedMatch(GeneralBlockRule rule, TimedMatchPlanner.FinishReason reason, DateTimeOffset? now = null)
    {
        if (rule.ActiveMatchDeadline == null) return;
        var t = now ?? DateTimeOffset.Now;
        rule.EndTimedMatch();
        _timedMatchOvertimeWarned.Remove(rule.Id);
        var played = Workspace.IncrementMatches(rule.Id, t);
        Workspace.RecordAudit("Partida terminada", $"«{rule.Name}» · {Capitalize(rule.MatchUnitSingular)} {played}/{rule.MaxDailyMatches}", t);
        Persist();

        var locked = IsRuleEnforcing(rule, t);
        if (locked || reason == TimedMatchPlanner.FinishReason.UserFinished)
        {
            WindowsActivity.TerminateProcesses(RunningGamePids(rule));
            Notice = $"{Capitalize(rule.MatchUnitSingular)} {played}/{rule.MaxDailyMatches} terminada. {(locked ? GameLockMessage(rule, t) : "Te queda otra disponible cuando quieras.")}";
        }
        else
        {
            Notice = $"{Capitalize(rule.MatchUnitSingular)} {played}/{rule.MaxDailyMatches} terminada. Te queda otra disponible.";
        }
        NotificationRequested?.Invoke($"Partida {played}/{rule.MaxDailyMatches} terminada", Notice);
    }

    private bool IsPlayingGameOnWeb(GeneralBlockRule rule, DateTimeOffset now)
    {
        if (rule.Game == null || rule.Game.WebEntries.Length == 0) return false;
        var fg = WindowsActivity.GetForegroundApp();
        if (fg == null || !StudyActivityVerifier.IsBrowser(fg.ProcessName)) return false;
        if (!_lastBrowserPages.TryGetValue(fg.ProcessName.ToLowerInvariant(), out var page) || (now - page.At).TotalSeconds > 25)
            return false;
        return rule.Game.MatchesWeb(page.Host, page.Path);
    }

    private void ObserveForeground(DateTimeOffset now)
    {
        // Nothing to watch (no running session, no rule switched on): do not even look at the foreground window.
        if (!(Workspace.Session is { Paused: false, EndedAt: null }) && !Workspace.GeneralRules.Any(r => r.Enabled))
        {
            _lastQuotaAt = null;
            return;
        }

        var delta = _lastQuotaAt.HasValue ? Math.Clamp((now - _lastQuotaAt.Value).TotalSeconds, 0, 8) : 0;
        _lastQuotaAt = now;

        var fg = WindowsActivity.GetForegroundApp();
        if (fg == null) return;

        var procClean = fg.ProcessName.ToLowerInvariant().Replace(".exe", "");
        var cont = TrustedClock.ContinuousSeconds();

        if (_ticks % 6 == 0)
        {
            SweepBackgroundWindows(fg.ProcessId, now, cont);
            SweepBackgroundBrowsers(fg.ProcessId);
        }

        // Guard Task Manager, Regedit, and sensitive Windows Settings panes before SystemExempt short-circuits.
        var sessionGuardsPanes = Workspace.Session is { Paused: false, EndedAt: null } gs &&
                                 gs.Task.GuardSystemPanes && gs.Task.Protection != SessionProtection.None &&
                                 gs.Remaining(now, cont) > 0;
        var ruleGuardsPanes = Workspace.GeneralRules.Any(r =>
            r.Enabled && r.GuardSystemPanes && r.Protection != SessionProtection.None && IsRuleEnforcing(r, now));
        if (sessionGuardsPanes || ruleGuardsPanes)
        {
            var hit = SystemSettingsGuard.CheckGuardedPane(fg);
            if (hit != null)
            {
                WindowsActivity.CloseWindow(fg.Hwnd);
                Notice = $"Bloqueado {hit} durante la protección activa.";
                return;
            }
        }

        // Explorer is exempt as a distraction, but not the folders a session or rule closes (macOS: guardBlockedFolders).
        EnforceBlockedFolders(now, cont);

        if (FocusRules.SystemExemptProcesses.Contains(procClean) || FocusRules.IsOwnProcess(fg.ProcessId))
            return;

        // Read browser URL off the UI thread so UIAutomation never freezes the WPF window.
        if (StudyActivityVerifier.IsBrowser(procClean) && !_webReadBusy && (now - _lastWebReadAt).TotalSeconds >= 2.5 && NeedsBrowserRead())
        {
            _lastWebReadAt = now;
            _webReadBusy = true;
            var hwnd = fg.Hwnd;
            var capturedFg = fg;
            _ = Task.Run(() =>
            {
                try
                {
                    var url = BrowserInspector.ReadActiveUrl(hwnd, procClean);
                    if (_disposed) return;
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        if (_disposed) return;
                        if (!url.HasValue)
                        {
                            _lastBrowserPages.Remove(procClean);
                            return;
                        }
                        var readAt = DateTimeOffset.Now;
                        _lastBrowserPages[procClean] = (url.Value.Host, url.Value.Path, readAt);
                        EvaluateWebRules(capturedFg, url.Value.Host, url.Value.Path, readAt);
                    });
                }
                finally { _webReadBusy = false; }
            });
        }

        if (Workspace.Session is { Paused: false, EndedAt: null } s &&
            s.Task.PomodoroPhase(s.Elapsed(now, cont))?.IsBreak != true)
        {
            var gameHit = s.Task.BlockGameLibraries ? GameLibraryRules.MatchesGameApp(procClean, fg.ExecutablePath) : null;
            var allowed = Workspace.IsTemporarilyAllowedApp(procClean, now, cont) ||
                          (gameHit == null && (s.Task.Apps.Count == 0 || FocusRules.AppAllowed(procClean, s.Task.Apps, s.Task.AppListMode)));
            if (FocusRules.MatchesTitleKeyword(fg.WindowTitle, s.Task.BlockedTitleKeywords, s.Task.WholeWordKeywords) != null)
                allowed = false;

            var isNewInterruption = s.ObserveForeground(procClean, fg.ProcessName, fg.WindowTitle, allowed, now);
            if (allowed)
            {
                _strictTracker.RegisterAllowedAppObserved();
                _strictLaunchAttempts = 0;
            }
            var titleHit = FocusRules.MatchesTitleKeyword(fg.WindowTitle, s.Task.BlockedTitleKeywords, s.Task.WholeWordKeywords);
            if (!allowed)
            {
                // A blocked word in a browser's title blocks that page only, like a blocked website:
                // hiding the whole browser threw the person out of every other tab too.
                if (titleHit != null && StudyActivityVerifier.IsBrowser(procClean))
                {
                    if (!PageBlockThrottled($"titulo:{titleHit}", now, 2.5))
                    {
                        var punisherMessage = RegisterSessionBlock(s, cont);
                        var closeTab = s.Task.WebBlockAction == WebBlockAction.CloseTab ||
                                       (s.Task.PunisherEnabled && s.Punisher.IsActive(cont) && s.Task.WebBlockAction == WebBlockAction.Redirect);
                        ActOnBlockedTab(fg.Hwnd, $"«{titleHit}»", s.Task.Title, s.Remaining(now), s.Task.MotivationalMessage, closeTab, s.Task.CustomRedirectURL, verifyPage: false);
                        if (punisherMessage != null) Notice = punisherMessage;
                    }
                }
                else if (titleHit != null || (gameHit != null && !s.Task.Strict))
                {
                    var verb = WindowsActivity.ApplyBlockAction(fg, SessionBlockAction(s, cont));
                    var punisherMessage = RegisterSessionBlock(s, cont);
                    Notice = punisherMessage ?? (titleHit != null
                        ? $"«{titleHit}» está bloqueada por título de ventana en «{s.Task.Title}»: {fg.ProcessName} {verb}."
                        : $"{fg.ProcessName} ({gameHit}) está bloqueada por la protección de juegos en «{s.Task.Title}»: {verb}.");
                }
                else if (s.Task.Strict)
                {
                    EnforceStrictApp(s, fg, isNewInterruption, now, cont);
                }
                else if (isNewInterruption)
                {
                    NotifyDistraction($"{fg.ProcessName} está fuera del perfil de esta tarea.", s);
                }
            }
        }

        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && !r.IsMicroPaused(now, cont)))
        {
            if (rule.Kind == GeneralRuleKind.LaunchLimit && rule.LaunchVisitRemainingSeconds(now, cont) <= 0 && rule.ActiveLaunchDeadline != null)
            {
                rule.EndLaunchVisitAndStartCooldown(now, cont);
                Persist();
                Notice = $"Visita agotada en «{rule.Name}». Enfriamiento activo.";
            }

            if (rule.Kind == GeneralRuleKind.LaunchLimit && !IsRuleEnforcing(rule, now) &&
                !rule.IsInLaunchVisit(now, cont) && Workspace.LaunchesToday(rule.Id, now) < rule.MaxDailyLaunches &&
                MatchesRuleAppOrTitle(rule, fg, now))
            {
                var n = Workspace.IncrementLaunches(rule.Id, now);
                rule.BeginLaunchVisit(now, cont);
                Notice = $"Visita {n}/{rule.MaxDailyLaunches} iniciada en «{rule.Name}» ({rule.MaxLaunchDurationMinutes} min).";
                Persist();
                continue;
            }

            if (rule.Kind == GeneralRuleKind.LaunchLimit && rule.ActiveLaunchDeadline != null)
            {
                var visitLeft = rule.LaunchVisitRemainingSeconds(now, cont);
                if (visitLeft > 0) CheckPreBlockWarning(rule, visitLeft, FocusRules.DayKey(now, Workspace.Settings.DayRolloverHour));
            }

            if (delta > 0 && MatchesRuleAppOrTitle(rule, fg, now))
                AccumulateUsage(rule, delta, now);

            if (!IsRuleEnforcing(rule, now)) continue;
            // An app let through on purpose for a while (temporary exception) is not blocked by any rule.
            if (Workspace.IsTemporarilyAllowedApp(procClean, now, cont)) continue;

            if (rule.GuardSystemPanes && rule.Protection != SessionProtection.None)
            {
                var sys = SystemSettingsGuard.CheckGuardedPane(fg);
                if (sys != null) { WindowsActivity.CloseWindow(fg.Hwnd); Notice = $"Cerrado {sys} mientras «{rule.Name}» está activa."; return; }
            }

            if (FocusRules.MatchesTitleKeyword(fg.WindowTitle, rule.BlockedTitleKeywords, rule.WholeWordKeywords) is string kw)
            {
                // In a browser the word blocks that page (redirect or close the tab), not the whole browser.
                if (StudyActivityVerifier.IsBrowser(procClean))
                {
                    if (PageBlockThrottled($"titulo:{kw}", now, 4)) return;
                    rule.ApplyPomodoroPenaltyIfNeeded(now);
                    var hardened = rule.RegisterBlock() || rule.Punisher.IsActive(cont);
                    var closeTab = rule.WebBlockAction == WebBlockAction.CloseTab || (hardened && rule.WebBlockAction == WebBlockAction.Redirect);
                    var rem = rule.RemainingLockSeconds(now, Workspace.UsedSecondsToday(rule.Id, now: now), EffectiveWorkedSeconds(rule, now), Workspace.LaunchesToday(rule.Id, now), Workspace.MatchesToday(rule.Id, now), IsMatchInProgress(rule, now), cont);
                    ActOnBlockedTab(fg.Hwnd, $"«{kw}»", rule.Name, rem, rule.MotivationalMessage, closeTab, rule.CustomRedirectURL, verifyPage: false);
                    return;
                }
                rule.ApplyPomodoroPenaltyIfNeeded(now);
                rule.RegisterBlock();
                var verb = WindowsActivity.ApplyBlockAction(fg, rule.ActiveBlockAction());
                Notice = $"«{kw}» bloqueado por «{rule.Name}»: {verb}.";
                return;
            }

            if (rule.BlockGameLibraries && GameLibraryRules.MatchesGameApp(procClean, fg.ExecutablePath) is string gl)
            {
                rule.ApplyPomodoroPenaltyIfNeeded(now);
                rule.RegisterBlock();
                var verb = WindowsActivity.ApplyBlockAction(fg, rule.ActiveBlockAction());
                Notice = $"{fg.ProcessName} ({gl}) bloqueado por «{rule.Name}»: {verb}.";
                return;
            }

            if (rule.Game != null && rule.Game.Matches(procClean, fg.ExecutablePath, fg.WindowTitle))
            {
                rule.RegisterBlock();
                WindowsActivity.TerminateProcesses(new[] { fg.ProcessId });
                Notice = GameLockMessage(rule, now);
                return;
            }

            if (rule.BlockApps && rule.Apps.Count > 0 && !FocusRules.AppAllowed(procClean, rule.Apps, rule.AppListMode))
            {
                rule.ApplyPomodoroPenaltyIfNeeded(now);
                rule.RegisterBlock();
                var verb = WindowsActivity.ApplyBlockAction(fg, rule.ActiveBlockAction());
                Notice = $"{fg.ProcessName} bloqueada por «{rule.Name}»: {verb}.";
                return;
            }
        }
    }

    private bool MatchesRuleAppOrTitle(GeneralBlockRule rule, ForegroundAppInfo fg, DateTimeOffset now)
    {
        var proc = fg.ProcessName.ToLowerInvariant().Replace(".exe", "");
        if (rule.BlockGameLibraries && GameLibraryRules.MatchesGameApp(proc, fg.ExecutablePath) != null) return true;
        if (rule.BlockApps && rule.Apps.Count > 0 && !FocusRules.AppAllowed(proc, rule.Apps, rule.AppListMode)) return true;
        if (FocusRules.MatchesTitleKeyword(fg.WindowTitle, rule.BlockedTitleKeywords, rule.WholeWordKeywords) != null) return true;
        if (StudyActivityVerifier.IsBrowser(proc) && _lastBrowserPages.TryGetValue(proc, out var page) && (now - page.At).TotalSeconds <= 25)
        {
            if (rule.BlockSearchMedia && SearchMediaRules.Matches(page.Host, page.Path) != null) return true;
            if (rule.WebBlockAction != WebBlockAction.Warn && !FocusRules.WebAllowed(page.Host, page.Path, rule.Domains, rule.WebListMode)) return true;
        }
        return false;
    }

    private void SweepBackgroundWindows(int foregroundPid, DateTimeOffset now, double cont)
    {
        var activeSess = Workspace.Session is { Paused: false, EndedAt: null } s &&
                         s.Task.PomodoroPhase(s.Elapsed(now, cont))?.IsBreak != true &&
                         s.Task.Strict && s.Task.Apps.Count > 0
            ? s
            : null;
        var activeAppRules = Workspace.GeneralRules
            .Where(r => r.Enabled && !r.IsMicroPaused(now, cont) && r.BlockApps && r.Apps.Count > 0 && IsRuleEnforcing(r, now))
            .ToList();
        if (activeSess == null && activeAppRules.Count == 0) return;

        foreach (var win in WindowsActivity.VisibleWindows())
        {
            if (win.ProcessId == foregroundPid || FocusRules.IsOwnProcess(win.ProcessId)) continue;
            var clean = win.ProcessName.ToLowerInvariant().Replace(".exe", "");
            if (FocusRules.SystemExemptProcesses.Contains(clean)) continue;
            if (Workspace.IsTemporarilyAllowedApp(clean, now, cont)) continue;

            var blocked = false;
            if (activeSess != null && !FocusRules.AppAllowed(clean, activeSess.Task.Apps, activeSess.Task.AppListMode))
                blocked = true;
            if (!blocked && activeAppRules.Any(r => !FocusRules.AppAllowed(clean, r.Apps, r.AppListMode)))
                blocked = true;

            if (blocked)
                WindowsActivity.MinimizeWindow(win.Hwnd);
        }
    }

    private void EvaluateWebRules(ForegroundAppInfo fg, string host, string path, DateTimeOffset now)
    {
        var cont = TrustedClock.ContinuousSeconds();
        if (Workspace.IsTemporarilyAllowed(host, path, now, cont)) return;
        var visitKey = $"{host}{path}";

        if (Workspace.Session is { Paused: false, EndedAt: null } s &&
            s.Task.PomodoroPhase(s.Elapsed(now, cont))?.IsBreak != true &&
            (s.Task.WebBlockAction != WebBlockAction.Warn || s.Task.BlockSearchMedia || Workspace.Settings.ObserveBrowserSites))
        {
            var searchHit = s.Task.BlockSearchMedia ? SearchMediaRules.Matches(host, path) : null;
            var allowed = searchHit == null && (s.Task.WebBlockAction == WebBlockAction.Warn || FocusRules.WebAllowed(host, path, s.Task.Domains, s.Task.WebListMode));
            s.RecordVisit(fg.ProcessName, fg.ProcessName, host, !allowed, now);
            if (!allowed)
            {
                if (_lastWebBlockHost == visitKey && (now - _lastWebBlockAt).TotalSeconds < 2.5) return;
                _lastWebBlockHost = visitKey;
                _lastWebBlockAt = now;
                var webPunisher = RegisterSessionBlock(s, cont);
                // Harder for a while after several attempts in a row: the tab is closed instead of redirected.
                var sessionCloseTab = s.Task.WebBlockAction == WebBlockAction.CloseTab ||
                                      (s.Task.PunisherEnabled && s.Punisher.IsActive(cont) && s.Task.WebBlockAction == WebBlockAction.Redirect);
                ActOnBlockedTab(fg.Hwnd, visitKey, s.Task.Title, s.Remaining(now), s.Task.MotivationalMessage, sessionCloseTab, s.Task.CustomRedirectURL);
                if (webPunisher != null) Notice = webPunisher;
                return;
            }
        }

        foreach (var rule in Workspace.GeneralRules.Where(r => r.Enabled && !r.IsMicroPaused(now, cont) && (r.WebBlockAction != WebBlockAction.Warn || r.BlockSearchMedia)))
        {
            var searchHit = rule.BlockSearchMedia ? SearchMediaRules.Matches(host, path) : null;
            var allowed = searchHit == null && (rule.WebBlockAction == WebBlockAction.Warn || FocusRules.WebAllowed(host, path, rule.Domains, rule.WebListMode));
            if (allowed) continue;

            if (rule.Kind == GeneralRuleKind.LaunchLimit && !IsRuleEnforcing(rule, now) &&
                !rule.IsInLaunchVisit(now, cont) && Workspace.LaunchesToday(rule.Id, now) < rule.MaxDailyLaunches)
            {
                var n = Workspace.IncrementLaunches(rule.Id, now);
                rule.BeginLaunchVisit(now, cont);
                Notice = $"Visita web {n}/{rule.MaxDailyLaunches} iniciada en «{rule.Name}» ({rule.MaxLaunchDurationMinutes} min).";
                Persist();
                continue;
            }

            if (!IsRuleEnforcing(rule, now)) continue;
            if (_lastWebBlockHost == visitKey && (now - _lastWebBlockAt).TotalSeconds < 4) return;
            _lastWebBlockHost = visitKey;
            _lastWebBlockAt = now;
            rule.ApplyPomodoroPenaltyIfNeeded(now);
            var hardened = rule.RegisterBlock() || rule.Punisher.IsActive(cont);
            var closeTab = rule.WebBlockAction == WebBlockAction.CloseTab || (hardened && rule.WebBlockAction == WebBlockAction.Redirect);
            var rem = rule.RemainingLockSeconds(now, Workspace.UsedSecondsToday(rule.Id, now: now), EffectiveWorkedSeconds(rule, now), Workspace.LaunchesToday(rule.Id, now), Workspace.MatchesToday(rule.Id, now), IsMatchInProgress(rule, now), cont);
            ActOnBlockedTab(fg.Hwnd, visitKey, rule.Name, rem, rule.MotivationalMessage, closeTab, rule.CustomRedirectURL);
            return;
        }
    }

    private bool PageBlockThrottled(string key, DateTimeOffset now, double seconds)
    {
        if (_lastWebBlockHost == key && (now - _lastWebBlockAt).TotalSeconds < seconds) return true;
        _lastWebBlockHost = key;
        _lastWebBlockAt = now;
        return false;
    }

    // verifyPage: false when the block comes from the window title just read from this same window (there is no
    // address to compare with); the address check only guards blocks decided from a URL read a moment earlier.
    private void ActOnBlockedTab(IntPtr hwnd, string host, string title, double remSeconds, string msg, bool closeTab, string customRedirect, bool verifyPage = true)
    {
        string? redirect = null;
        if (!closeTab)
        {
            var custom = FocusRules.NormalizedRedirectUrl(customRedirect);
            redirect = custom != null
                ? custom.AbsoluteUri
                : BlockPageGenerator.Write(title, host, remSeconds, msg, Array.Empty<string>(), Store.DirectoryPath);
        }
        if (BrowserInspector.RedirectOrCloseTab(hwnd, closeTab, redirect, verifyPage ? host : null))
            Notice = closeTab ? $"{host} bloqueada: pestaña cerrada." : $"{host} bloqueada: redirigida.";
    }

    private void CheckClipboardGuard()
    {
        if (!Workspace.Settings.ProtectClipboard) return;
        try
        {
            if (!System.Windows.Clipboard.ContainsText()) return;
            var text = System.Windows.Clipboard.GetText();
            if (text == _lastClipboardText || string.IsNullOrWhiteSpace(text)) return;
            _lastClipboardText = text;
            var now = DateTimeOffset.Now;

            if (Workspace.Session is { Paused: false, EndedAt: null } s && s.Remaining(now) > 0)
            {
                var hit = ClipboardGuardRules.Violation(text, s.Task.Domains, s.Task.WebListMode, s.Task.WebBlockAction);
                if (hit != null)
                {
                    System.Windows.Clipboard.Clear();
                    _lastClipboardText = "";
                    Notice = $"Portapapeles limpiado ({hit}).";
                    return;
                }
            }

            foreach (var rule in Workspace.GeneralRules.Where(r => IsRuleEnforcing(r, now)))
            {
                var hit = ClipboardGuardRules.Violation(text, rule.Domains, rule.WebListMode, rule.WebBlockAction);
                if (hit != null)
                {
                    System.Windows.Clipboard.Clear();
                    _lastClipboardText = "";
                    Notice = $"Portapapeles limpiado ({hit}).";
                    return;
                }
            }
        }
        catch { }
    }

    // MARK: - Actions for UI

    public void SaveTask(FocusTask task, bool bypassProtection = false)
    {
        task.Title = task.Title.Trim();
        task.Domains = FocusRules.NormalizeDomains(task.Domains);
        task.BlockedTitleKeywords = FocusRules.NormalizeTitleKeywords(task.BlockedTitleKeywords);
        if (!task.Valid) { Error = "La tarea necesita título y configuración válida."; return; }

        var now = DateTimeOffset.Now;
        var idx = Workspace.Tasks.FindIndex(t => t.Id == task.Id);
        if (idx >= 0 && !bypassProtection && IsTaskProtected(Workspace.Tasks[idx], now))
        {
            var running = Workspace.Session?.Task.Id == task.Id;
            var reason = FocusRules.TaskLoosening(Workspace.Tasks[idx], task, now, running);
            if (reason != null) { Error = $"Protegida: no se puede {reason} sin desbloquear."; return; }
        }

        RememberUndo();
        if (idx >= 0) Workspace.Tasks[idx] = task; else Workspace.Tasks.Add(task);
        if (Workspace.Session is { EndedAt: null } s && s.Task.Id == task.Id)
        {
            s.Task = task.Clone();
            s.Budget = Math.Max(s.Budget, task.Minutes * 60.0);
        }
        Error = "";
        Persist();
        Notice = $"Tarea «{task.Title}» guardada.";
    }

    public void DeleteTask(FocusTask task, bool bypassProtection = false)
    {
        if (Workspace.Session?.Task.Id == task.Id)
        {
            Error = "No puedes borrar una tarea mientras su sesión está en marcha.";
            return;
        }
        if (!bypassProtection && IsTaskProtected(task))
        {
            Error = $"«{task.Title}» está dentro de su margen de protección previo al inicio.";
            return;
        }
        RememberUndo();
        Workspace.Tasks.RemoveAll(t => t.Id == task.Id);
        Error = "";
        Persist();
        Notice = $"«{task.Title}» eliminada.";
    }

    public void StartSession(FocusTask task)
    {
        if (Workspace.Session is { EndedAt: null } cur)
        {
            if (cur.Task.Id == task.Id && cur.Paused)
            {
                ResumeSession();
                return;
            }
            Error = "Ya hay una sesión en marcha.";
            return;
        }
        _sessionFinishedNotifiedId = null;
        _lastTaskPomodoroKey = null;
        ResetStrictState();
        Workspace.Session = new WorkSession(task, DateTimeOffset.Now);
        BeginFolderBaseline(Workspace.Session);
        Error = "";
        Notice = $"«{task.Title}» en marcha ({task.Minutes} min).";
        Persist();
        EnsureWatcherIfNeeded();
    }

    public void SnoozeTask(FocusTask task, int minutes = 10, bool bypassProtection = false)
    {
        var now = DateTimeOffset.Now;
        var baseTime = task.IsScheduled && task.ScheduledAt > now ? task.ScheduledAt : now;
        var updated = task.Clone();
        updated.IsScheduled = true;
        updated.ScheduledAt = baseTime.AddMinutes(Math.Clamp(minutes, 1, 240));
        SaveTask(updated, bypassProtection: bypassProtection);
        if (string.IsNullOrEmpty(Error))
            Notice = $"«{updated.Title}» pospuesta a las {updated.ScheduledAt.LocalDateTime:HH:mm}.";
    }

    /// <summary>
    /// What restarting this rule's countdown (or Pomodoro) would loosen, or null. A protected block that is already
    /// running must not be shortened by pressing «Activar» again: that was a free way out with no code.
    /// </summary>
    public string? RestartLoosening(GeneralBlockRule rule, GeneralRuleKind kind)
    {
        if (!IsRuleProtected(rule)) return null;
        var proposed = rule.Clone();
        if (kind == GeneralRuleKind.Countdown) proposed.StartCountdown(); else proposed.StartPomodoro();
        return GeneralBlockRule.Loosening(rule, proposed);
    }

    public void StartRuleCountdown(GeneralBlockRule rule)
    {
        rule.StartCountdown();
        Persist();
        EnsureWatcherIfNeeded();
        Notice = $"Bloqueo «{rule.Name}» en marcha ({FocusRules.DurationText(rule.CountdownMinutes)}).";
    }

    public void StartRulePomodoro(GeneralBlockRule rule)
    {
        rule.StartPomodoro();
        Persist();
        EnsureWatcherIfNeeded();
        Notice = $"Pomodoro «{rule.Name}» iniciado: ciclo 1/{rule.PomodoroTotalCycles}.";
    }

    public void UseMicroPause(GeneralBlockRule rule)
    {
        var now = DateTimeOffset.Now;
        var used = Workspace.MicroPausesUsedToday(rule.Id, now);
        if (rule.DailyMicroPausesAllowed <= 0 || used >= rule.DailyMicroPausesAllowed)
        {
            Error = $"Ya has agotado las micro-pausas de hoy en «{rule.Name}».";
            return;
        }
        var n = Workspace.IncrementMicroPauses(rule.Id, now);
        rule.StartMicroPause(now);
        Workspace.RecordAudit("Micro-pausa", $"«{rule.Name}» ({rule.MicroPauseMinutes} min · {n}/{rule.DailyMicroPausesAllowed})", now);
        Error = "";
        Persist();
        Notice = $"Micro-pausa de {rule.MicroPauseMinutes} min activada en «{rule.Name}» ({n}/{rule.DailyMicroPausesAllowed} hoy).";
    }

    /// <summary>
    /// One-click countdown block (macOS: startQuickBlock). With no preset it blocks social networks and short videos.
    /// A quick block that already exists is only ever extended and hardened, never shortened or softened.
    /// </summary>
    public void LaunchQuickBlock(int minutes, SessionProtection protection = SessionProtection.Challenge, DistractionPreset? preset = null)
    {
        var clamped = Math.Clamp(minutes, 5, 1440);
        var presetDomains = preset != null
            ? preset.Domains.ToList()
            : DistractionPreset.Social.Domains.Concat(DistractionPreset.ShortVideos.Domains).Distinct().ToList();
        var presetKeywords = preset != null
            ? preset.TitleKeywords.ToList()
            : DistractionPreset.Social.TitleKeywords.Concat(DistractionPreset.ShortVideos.TitleKeywords).Distinct().ToList();
        var label = preset?.Label ?? "Redes y vídeos cortos";

        var existing = Workspace.GeneralRules.FirstOrDefault(r => r.Kind == GeneralRuleKind.Countdown && r.Name.StartsWith("Bloqueo rápido", StringComparison.OrdinalIgnoreCase));
        if (existing != null)
        {
            var curRem = existing.Enabled && existing.ActiveDeadline != null ? existing.ActiveDeadline.RemainingAfterPossibleReboot() : 0;
            var newSec = Math.Max(curRem, clamped * 60.0);
            existing.CountdownMinutes = Math.Clamp(Math.Max(existing.CountdownMinutes, clamped), 5, 720);
            if (protection.Strength() > existing.Protection.Strength())
                existing.Protection = protection;
            existing.Domains = FocusRules.NormalizeDomains(string.Join(", ", FocusRules.ParseDomains(existing.Domains).Valid.Concat(presetDomains)));
            existing.BlockedTitleKeywords = FocusRules.NormalizeTitleKeywords(string.Join(", ", FocusRules.ParseTitleKeywords(existing.BlockedTitleKeywords).Concat(presetKeywords)));
            existing.Enabled = true;
            existing.ActiveMicroPauseDeadline = null;
            existing.ActiveDeadline = new TrustedDeadline(newSec);
            Persist();
            EnsureWatcherIfNeeded();
            Notice = $"Bloqueo rápido activo ({FocusRules.DurationText((int)Math.Round(newSec / 60.0))}).";
            return;
        }

        var quick = new GeneralBlockRule
        {
            Name = $"Bloqueo rápido · {label}",
            Kind = GeneralRuleKind.Countdown,
            CountdownMinutes = Math.Min(720, clamped),
            Enabled = true,
            WebListMode = WebListMode.BlockListed,
            WebBlockAction = WebBlockAction.Redirect,
            Domains = string.Join(", ", presetDomains),
            BlockedTitleKeywords = string.Join(", ", presetKeywords),
            Protection = protection,
            DailyMicroPausesAllowed = 1
        };
        quick.StartCountdown(clamped);
        Workspace.GeneralRules.Insert(0, quick);
        Persist();
        EnsureWatcherIfNeeded();
        Notice = $"Bloqueo rápido de {FocusRules.DurationText(clamped)} en marcha.";
    }

    public void PauseSession()
    {
        if (Workspace.Session == null || Workspace.Session.Paused) return;
        Workspace.Session.Pause(DateTimeOffset.Now);
        Persist();
        Notice = "Sesión en pausa.";
    }

    public void ResumeSession()
    {
        if (Workspace.Session == null || !Workspace.Session.Paused) return;
        ResetStrictState();
        Workspace.Session.Resume(DateTimeOffset.Now);
        Persist();
        Notice = "Sesión reanudada.";
    }

    public void AddSessionMinutes(int min = 10)
    {
        if (Workspace.Session == null) return;
        Workspace.Session.AddMinutes(min);
        Persist();
        Notice = $"+{min} min añadidos.";
    }

    public void FinishSession()
    {
        if (Workspace.Session == null) return;
        Workspace.Session.Finish(DateTimeOffset.Now);
        Persist();
        AskResultAfterEvidence(Workspace.Session);
    }

    public void ConfirmSession(bool completed, string note, IEnumerable<string>? confirmedFiles = null,
        IEnumerable<string>? manualFiles = null, NextTransition transition = NextTransition.KeepSchedule)
    {
        var s = Workspace.Session;
        if (s == null) return;
        if (s.EndedAt == null) s.Finish(DateTimeOffset.Now);
        var changed = s.FinalChangedFiles ?? new List<string>();
        var confirmed = (confirmedFiles ?? s.SelectedFiles).Distinct().OrderBy(f => f).ToList();
        var manual = (manualFiles ?? s.ManualFiles).Distinct().ToList();
        s.Baseline = new Dictionary<string, FileStamp>();   // only needed while the session ran
        var record = new SessionRecord
        {
            Id = s.Id,
            Session = s,
            Completed = completed,
            Note = note,
            ChangedFiles = changed,
            ConfirmedFiles = confirmed,
            ManualFiles = manual
        };
        record.PreserveSummary();
        Workspace.History.Insert(0, record);
        var idx = Workspace.Tasks.FindIndex(t => t.Id == s.Task.Id);
        if (idx >= 0)
        {
            Workspace.Tasks[idx].Completed = completed;
            if (completed && Workspace.Tasks[idx].NextOccurrence(DateTimeOffset.Now, Workspace.Settings.Workdays) is FocusTask next)
                Workspace.Tasks.Add(next);
        }
        Workspace.Session = null;
        // «Sigue pendiente» on an occurrence of an earlier day must not freeze its series there.
        SeriesRoller.Roll(Workspace.Tasks, null, DateTimeOffset.Now, Workspace.Settings.Workdays);
        Persist();
        Notice = completed ? "Tarea completada y guardada en historial." : "Sesión guardada.";
        ApplyTransition(transition, s.Task.Id, completed);
    }

    public void CancelSession()
    {
        var s = Workspace.Session;
        if (s == null) return;
        s.Finish(DateTimeOffset.Now);
        Workspace.History.Insert(0, new SessionRecord { Id = s.Id, Session = s, Completed = false, Cancelled = true, Note = "Sesión cancelada" });
        Workspace.Session = null;
        SeriesRoller.Roll(Workspace.Tasks, null, DateTimeOffset.Now, Workspace.Settings.Workdays);
        Persist();
        Notice = "Sesión cancelada.";
    }

    public void SaveGeneralRule(GeneralBlockRule rule, bool bypassProtection = false)
    {
        rule.Name = rule.Name.Trim();
        rule.Domains = FocusRules.NormalizeDomains(rule.Domains);
        rule.BlockedTitleKeywords = FocusRules.NormalizeTitleKeywords(rule.BlockedTitleKeywords);
        if (rule.Apps.Count > 0 || rule.BlockGameLibraries) rule.BlockApps = true;
        if (!rule.Valid) { Error = "La regla necesita nombre y al menos un objetivo a bloquear."; return; }

        var idx = Workspace.GeneralRules.FindIndex(r => r.Id == rule.Id);
        if (idx >= 0 && !bypassProtection && IsRuleProtected(Workspace.GeneralRules[idx]))
        {
            var reason = GeneralBlockRule.Loosening(Workspace.GeneralRules[idx], rule);
            if (reason != null) { Error = $"Protegida: no se puede {reason} sin desbloquear."; return; }
        }
        if (idx >= 0) Workspace.GeneralRules[idx] = rule; else Workspace.GeneralRules.Add(rule);
        if (rule.Enabled && rule.AlwaysProtected && rule.Protection != SessionProtection.None)
            Workspace.Settings.RelaunchGuard = true;
        Error = "";
        Persist();
        EnsureWatcherIfNeeded();
        if (_enablePlatformWatchers) RefreshValveServer();
        Notice = $"Regla «{rule.Name}» guardada.";
    }

    public void DeleteGeneralRule(GeneralBlockRule rule, bool bypassProtection = false)
    {
        if (!bypassProtection && IsRuleProtected(rule))
        {
            Error = $"La regla «{rule.Name}» está protegida y requiere desbloqueo para borrarse.";
            return;
        }
        Workspace.GeneralRules.RemoveAll(r => r.Id == rule.Id);
        Error = "";
        Persist();
        if (_enablePlatformWatchers) RefreshValveServer();
        Notice = $"Regla «{rule.Name}» eliminada.";
    }

    public void SaveProfile(FocusProfile profile)
    {
        profile.Domains = FocusRules.NormalizeDomains(profile.Domains);
        var idx = Workspace.Profiles.FindIndex(p => p.Id == profile.Id);
        if (idx >= 0) Workspace.Profiles[idx] = profile; else Workspace.Profiles.Add(profile);
        Persist();
        Notice = $"Perfil «{profile.Name}» guardado.";
    }

    public void AddStudyWeb(string domainText)
    {
        var parsed = FocusRules.ParseDomains(domainText);
        if (parsed.Valid.Count == 0) { Error = "Escribe un dominio válido (ej. apuntes.ejemplo.com)."; return; }
        var domain = parsed.Valid[0];
        var tomorrow = FocusRules.DayKey(DateTimeOffset.Now.AddDays(1), Workspace.Settings.DayRolloverHour);
        var src = new StudySource { Kind = "web", Value = domain, Name = domain, CountsFrom = tomorrow };
        if (Workspace.Settings.StudySources.Any(s => s.Id == src.Id)) return;
        Workspace.Settings.StudySources.Add(src);
        Error = "";
        Persist();
        Notice = $"«{domain}» contará como estudio desde mañana.";
    }

    public void AddStudyApp(string exeName, string displayName)
    {
        var clean = exeName.Trim().Replace(".exe", "", StringComparison.OrdinalIgnoreCase);
        if (string.IsNullOrEmpty(clean)) return;
        var tomorrow = FocusRules.DayKey(DateTimeOffset.Now.AddDays(1), Workspace.Settings.DayRolloverHour);
        var src = new StudySource { Kind = "app", Value = clean, Name = string.IsNullOrWhiteSpace(displayName) ? clean : displayName, CountsFrom = tomorrow };
        if (Workspace.Settings.StudySources.Any(s => s.Id == src.Id)) return;
        Workspace.Settings.StudySources.Add(src);
        Error = "";
        Persist();
        Notice = $"«{src.Name}» contará como estudio desde mañana.";
    }

    public void RemoveStudySource(StudySource src)
    {
        Workspace.Settings.StudySources.RemoveAll(s => s.Id == src.Id);
        Persist();
    }

    public void SetRelaunchGuard(bool enabled)
    {
        Workspace.Settings.RelaunchGuard = enabled;
        if (enabled) RelaunchGuard.Install(); else RelaunchGuard.Remove();
        Persist();
        Notice = enabled ? "Vigilante de relanzado activado en Windows." : "Vigilante desactivado.";
    }

    public void ExportBackup(string filePath)
    {
        var bytes = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(Workspace, WorkspaceStore.PrettyJsonOptions);
        File.WriteAllBytes(filePath, bytes);
        Notice = $"Copia exportada en {Path.GetFileName(filePath)}.";
    }

    public void ImportBackup(string filePath)
    {
        LossyReadStats.Reset();
        var imported = Store.ValidateBackup(filePath);
        if (imported.Session != null) { imported.Session.RunningSince = null; imported.Session.RunningUptime = null; }
        // Keep what is there now before replacing it (the previous agenda would otherwise be gone for good).
        if (!_loadFailed) Store.KeepOriginalCopy("antes-de-importar");
        Workspace = imported;
        _loadFailed = false;
        Error = "";
        Persist();
        if (_enablePlatformWatchers) RefreshValveServer();
        Notice = "Copia importada correctamente.";
    }

    /// <summary>Goes back to the last automatic copy (workspace.backup.json). The way out when the data could not be read.</summary>
    public void RecoverFromAutoBackup()
    {
        try
        {
            LossyReadStats.Reset();
            if (!_loadFailed) Store.KeepOriginalCopy("antes-de-recuperar");
            var recovered = Store.RecoverFromRollingBackup();
            Workspace = recovered;
            _loadFailed = false;
            Error = "";
            Persist();
            if (_enablePlatformWatchers) RefreshValveServer();
            Notice = "Copia automática recuperada.";
        }
        catch (Exception ex)
        {
            Error = $"No se pudo recuperar la copia automática: {ex.Message}";
        }
    }

    private static string Capitalize(string s) =>
        string.IsNullOrEmpty(s) ? s : char.ToUpperInvariant(s[0]) + s[1..];

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        UnhookSystemEvents();
        _timer.Stop();
        _valveServer?.Dispose();
    }
}
