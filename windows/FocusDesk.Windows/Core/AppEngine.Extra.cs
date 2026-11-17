using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.Core;

/// <summary>What the unlock dialogs need from the engine to keep a wait («Espera») alive between presses.</summary>
public interface IStopGateHost
{
    /// <summary>True when the wait for `key` has finished (and is consumed). Otherwise starts or reports it and returns false.</summary>
    bool EvaluateDelay(string key, int delayMinutes);
    /// <summary>Shows a message in the banner of the main window.</summary>
    void Say(string message);
}

/// <summary>Parts of the engine that mirror macOS AppModel+Enforcement (strict mode, waits, distraction notices).</summary>
public sealed partial class AppEngine
{
    private StrictRedirectTracker _strictTracker = new();
    private int _strictLaunchAttempts;
    private DateTimeOffset _lastDistractionNotifyAt = DateTimeOffset.MinValue;
    private readonly HashSet<string> _stopWaitNotified = new();

    // MARK: - Strict mode («solo estas apps») with its safety valve

    private AppBlockAction SessionBlockAction(WorkSession s, double cont) =>
        s.Task.PunisherEnabled && s.Punisher.IsActive(cont) ? s.Task.BlockAction.Escalated() : s.Task.BlockAction;

    /// <summary>Counts one applied block. Returns the message to show when the punisher has just switched on, otherwise null.</summary>
    private string? RegisterSessionBlock(WorkSession s, double cont)
    {
        s.BlocksApplied++;
        if (!s.Task.PunisherEnabled || !s.Punisher.Register(cont)) return null;
        return $"Van {s.Punisher.MaxAttempts} intentos seguidos. Durante {FocusRules.Clock(s.Punisher.Remaining(cont))} FocusDesk cerrará las apps que distraen en vez de minimizarlas.";
    }

    private void ResetStrictState()
    {
        _strictTracker = new StrictRedirectTracker();
        _strictLaunchAttempts = 0;
    }

    private void NotifyDistraction(string body, WorkSession s)
    {
        // «Vuelve a tu tarea» sounds at most every 3 minutes.
        if ((DateTimeOffset.Now - _lastDistractionNotifyAt).TotalSeconds < 180) return;
        _lastDistractionNotifyAt = DateTimeOffset.Now;
        NotificationRequested?.Invoke("Vuelve a tu tarea", body);
    }

    private static ForegroundAppInfo? FindRunningAllowedWindow(IReadOnlyCollection<AllowedApp> apps, int excludePid)
    {
        foreach (var win in WindowsActivity.VisibleWindows())
        {
            if (win.ProcessId == excludePid || FocusRules.IsOwnProcess(win.ProcessId)) continue;
            var clean = FocusRules.CleanAppId(win.ProcessName);
            if (FocusRules.SystemExemptProcesses.Contains(clean)) continue;
            if (FocusRules.AppAllowed(clean, apps, AppListMode.AllowListed)) return win;
        }
        return null;
    }

    private static bool TryLaunchAllowedApp(IReadOnlyCollection<AllowedApp> apps)
    {
        foreach (var app in apps)
        {
            try
            {
                var target = !string.IsNullOrWhiteSpace(app.Path) && File.Exists(app.Path) ? app.Path : app.Id;
                if (string.IsNullOrWhiteSpace(target)) continue;
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(target) { UseShellExecute = true });
                return true;
            }
            catch { }
        }
        return false;
    }

    /// <summary>
    /// An app outside the task while the session blocks apps. With a blacklist only that app is dealt with; with
    /// «solo estas apps» the person is sent back to an allowed one, and when that does not work (or none is open) the
    /// block gives up instead of fighting forever (macOS `enforceApp`).
    /// </summary>
    private void EnforceStrictApp(WorkSession s, ForegroundAppInfo fg, bool isNewInterruption, DateTimeOffset now, double cont)
    {
        if (FocusRules.IsOwnProcess(fg.ProcessId)) return;

        if (s.Task.AppListMode == AppListMode.BlockListed)
        {
            var listedVerb = WindowsActivity.ApplyBlockAction(fg, SessionBlockAction(s, cont));
            var listedPunisher = RegisterSessionBlock(s, cont);
            Notice = listedPunisher ?? $"{fg.ProcessName} está bloqueada en «{s.Task.Title}»: {listedVerb}.";
            if (isNewInterruption) NotifyDistraction(Notice, s);
            return;
        }

        var target = FindRunningAllowedWindow(s.Task.Apps, fg.ProcessId);
        if (target == null && _strictLaunchAttempts < 2 && TryLaunchAllowedApp(s.Task.Apps))
        {
            _strictLaunchAttempts++;
            WindowsActivity.MinimizeWindow(fg.Hwnd);
            Notice = $"{fg.ProcessName} no está entre las apps de esta tarea: la he minimizado y abro una permitida.";
            return;
        }

        var decision = _strictTracker.EvaluateUnallowed(target != null, now);
        if (decision.Kind == StrictDecisionKind.None || decision.Kind == StrictDecisionKind.Cooldown) return;

        if (decision.Kind == StrictDecisionKind.Redirect)
        {
            var punisherMessage = RegisterSessionBlock(s, cont);
            var verb = WindowsActivity.ApplyBlockAction(fg, SessionBlockAction(s, cont));
            if (target != null) WindowsActivity.ActivateWindow(target.Hwnd);
            _strictTracker.RecordRedirectAttempt();
            Notice = punisherMessage ??
                     $"{fg.ProcessName} no está entre las apps de esta tarea: {verb} y vuelves a {(target != null ? target.ProcessName : "la app permitida")}.";
            if (isNewInterruption) NotifyDistraction(Notice, s);
            return;
        }

        // PauseSession
        if (s.Task.Protection != SessionProtection.None)
        {
            // A protected session never pauses itself: that was a free way out. The block keeps acting and says where to go.
            WindowsActivity.ApplyBlockAction(fg, SessionBlockAction(s, cont));
            Notice = target == null
                ? $"{fg.ProcessName} no entra en esta tarea y no hay ninguna app permitida abierta. Abre una: la sesión sigue."
                : $"{fg.ProcessName} no entra en esta tarea. Vuelve a {target.ProcessName}: la sesión sigue.";
            if (isNewInterruption) NotifyDistraction(Notice, s);
            return;
        }

        // Safety valve of an unprotected session: nowhere to send the person back to. Pausing needs no code.
        s.Pause(now);
        Persist();
        Notice = decision.Reason ?? "Sesión pausada.";
        NotificationRequested?.Invoke($"Sesión en pausa · {s.Task.Title}", Notice);
    }

    // MARK: - What needs reading

    /// <summary>Whether anything cares about the address of the web page in front (blocking, quota or verified study).</summary>
    private bool NeedsBrowserRead()
    {
        if (Workspace.Session is { Paused: false, EndedAt: null } s &&
            (s.Task.WebBlockAction != WebBlockAction.Warn || s.Task.BlockSearchMedia || Workspace.Settings.ObserveBrowserSites))
            return true;
        return Workspace.GeneralRules.Any(rule => rule.Enabled &&
            (rule.WebBlockAction != WebBlockAction.Warn || rule.BlockSearchMedia || rule.VerifyActiveStudy ||
             (rule.Game != null && rule.Game.WebEntries.Length > 0)));
    }

    /// <summary>Closes Explorer windows that show a folder the running session or an enforcing rule blocks.</summary>
    private void EnforceBlockedFolders(DateTimeOffset now, double cont)
    {
        var folders = new List<string>();
        if (Workspace.Session is { Paused: false, EndedAt: null } s && s.Task.BlockedFolders.Count > 0 &&
            s.Task.PomodoroPhase(s.Elapsed(now, cont))?.IsBreak != true)
        {
            folders.AddRange(s.Task.BlockedFolders);
        }
        foreach (var rule in Workspace.GeneralRules.Where(candidate => candidate.Enabled && candidate.BlockedFolders.Count > 0))
        {
            if (!rule.IsMicroPaused(now, cont) && IsRuleEnforcing(rule, now)) folders.AddRange(rule.BlockedFolders);
        }
        if (folders.Count == 0) return;
        var hits = FolderGuard.EnforceBlockedExplorerFolders(folders);
        if (hits.Count > 0) Notice = $"Carpeta bloqueada cerrada: {string.Join(", ", hits)}.";
    }

    // MARK: - Waits («Espera») that survive closing the app

    public bool EvaluateDelay(string key, int delayMinutes)
    {
        var now = DateTimeOffset.Now;
        var existing = Workspace.PendingStopWaits.FirstOrDefault(w => w.Key == key);
        if (existing != null && existing.Request.IsExpired(now))
        {
            Workspace.PendingStopWaits.Remove(existing);
            existing = null;
        }
        if (existing == null)
        {
            Workspace.PendingStopWaits.Add(new PendingStopWait { Key = key, Request = new StopRequest("stop", delayMinutes, now) });
            _stopWaitNotified.Remove(key);
            Persist();
            Notice = $"Has pedido «{key}». FocusDesk espera {FocusRules.Clock(Math.Clamp(delayMinutes, 1, 120) * 60.0)}; mientras, todo sigue protegido. Cuando termine la espera, vuelve a pulsarlo.";
            return false;
        }
        var left = existing.Request.RemainingSeconds(now);
        if (left > 0)
        {
            Notice = $"Ya pediste «{key}». Faltan {FocusRules.Clock(left)}; al cumplirse, vuelve a pulsarlo.";
            return false;
        }
        Workspace.PendingStopWaits.Remove(existing);
        _stopWaitNotified.Remove(key);
        Persist();
        return true;
    }

    public void Say(string message) => Notice = message;

    private void TickStopWaits(DateTimeOffset now)
    {
        if (Workspace.PendingStopWaits.Count == 0) return;
        var changed = false;
        foreach (var wait in Workspace.PendingStopWaits.ToList())
        {
            if (wait.Request.IsExpired(now))
            {
                Workspace.PendingStopWaits.Remove(wait);
                _stopWaitNotified.Remove(wait.Key);
                Notice = $"La ventana para confirmar «{wait.Key}» ha caducado: sigue protegido.";
                changed = true;
                continue;
            }
            if (wait.Request.IsReady(now) && _stopWaitNotified.Add(wait.Key))
            {
                Notice = $"La espera ha terminado: tienes {FocusRules.Clock(wait.Request.ConfirmWindowRemaining(now))} para repetir «{wait.Key}».";
                NotificationRequested?.Invoke("Ya puedes continuar", Notice);
            }
        }
        if (changed) Persist();
    }
}
