using System;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Windows;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;
using FocusDesk.Windows.UI;
using Forms = System.Windows.Forms;

namespace FocusDesk.Windows;

public partial class App : System.Windows.Application
{
    private Mutex? _singleInstanceMutex;
    private EventWaitHandle? _showWindowEvent;
    private RegisteredWaitHandle? _waitHandle;
    private AppEngine? _engine;
    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _trayIcon;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        if (e.Args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase))
        {
            var exitCode = SmokeCheck.Run();
            Environment.Exit(exitCode);
            return;
        }

        if (e.Args.Contains(RelaunchGuard.WatcherArg, StringComparer.OrdinalIgnoreCase))
        {
            RelaunchGuard.RunWatcherLoop();
            Shutdown();
            return;
        }

        _singleInstanceMutex = new Mutex(true, @"Local\FocusDesk_Articdia_SingleInstance", out var created);
        _showWindowEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\FocusDesk_Articdia_ShowWindow");

        if (!created)
        {
            try { _showWindowEvent.Set(); } catch { }
            try { _showWindowEvent.Dispose(); } catch { }
            try { _singleInstanceMutex.Dispose(); } catch { }
            Shutdown();
            return;
        }

        _waitHandle = ThreadPool.RegisterWaitForSingleObject(_showWindowEvent, (_, _) =>
        {
            Dispatcher.BeginInvoke(ShowMainWindow);
        }, null, -1, false);

        _engine = new AppEngine();
        _engine.NotificationRequested += (title, body) =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                _trayIcon?.ShowBalloonTip(4000, title, body, Forms.ToolTipIcon.Info);
            });
        };

        SessionEnding += (_, _) =>
        {
            if (_engine != null)
            {
                _engine.Workspace.ClosedBySystemAt = DateTimeOffset.UtcNow;
                if (_engine.Workspace.Session is { Paused: false, EndedAt: null } sess)
                {
                    // Save exactly what was worked up to this moment: the time Windows stays off must not count.
                    sess.Checkpoint(DateTimeOffset.Now);
                    if (sess.Task.Protection != SessionProtection.None)
                    {
                        var rem = Math.Max(0, sess.Remaining(DateTimeOffset.Now));
                        sess.ResumeOnLaunchUntil = DateTimeOffset.UtcNow.AddSeconds(rem);
                    }
                }
                _engine.Persist();
                _engine.Dispose();
            }
            _trayIcon?.Dispose();
        };

        SetupTrayIcon();
        ShowMainWindow();
    }

    private void SetupTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Abrir FocusDesk", null, (_, _) => Dispatcher.BeginInvoke(ShowMainWindow));
        menu.Items.Add("Pausar / Reanudar sesión", null, (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (_engine?.Workspace.Session is not { EndedAt: null } s) return;
            if (s.Paused)
            {
                _engine.ResumeSession();
                return;
            }
            if (s.Task.Protection != SessionProtection.None && s.Remaining(DateTimeOffset.Now) > 0)
            {
                ShowMainWindow();
                if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"pausar «{s.Task.Title}»", _mainWindow))
                    return;
                if (s.Task.Protection == SessionProtection.Forced)
                    _engine.Workspace.RecordAudit("Salida de emergencia", $"Pausa anticipada de «{s.Task.Title}» desde bandeja.");
            }
            _engine.PauseSession();
        }));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Salir", null, (_, _) => Dispatcher.BeginInvoke(TryQuitApp));

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "FocusDesk",
            Visible = true,
            ContextMenuStrip = menu
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(ShowMainWindow);
    }

    public void ShowMainWindow()
    {
        if (_engine == null) return;
        if (_mainWindow == null)
        {
            _mainWindow = new MainWindow(_engine, TryQuitApp);
        }
        _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
            _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    private void TryQuitApp()
    {
        if (_engine == null) { Shutdown(); return; }
        ShowMainWindow();

        if (_engine.Workspace.Session is { EndedAt: null } s &&
            s.Task.Protection != SessionProtection.None &&
            s.Remaining(DateTimeOffset.Now) > 0)
        {
            if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"cerrar FocusDesk mientras «{s.Task.Title}» está protegida", _mainWindow))
                return;
            if (s.Task.Protection == SessionProtection.Forced)
                _engine.Workspace.RecordAudit("Salida de emergencia", $"Cierre de FocusDesk con «{s.Task.Title}» en modo Hasta el final.");
        }

        var armedTask = _engine.Workspace.Tasks.FirstOrDefault(t =>
            !t.Completed && t.Id != _engine.Workspace.Session?.Task.Id && _engine.IsTaskProtected(t));
        if (armedTask != null)
        {
            if (!Dialogs.RequestUnlock(armedTask.Protection, armedTask.UnlockChars, armedTask.StopDelayMinutes, $"cerrar FocusDesk antes de «{armedTask.Title}»", _mainWindow))
                return;
        }

        var protectedRule = _engine.Workspace.GeneralRules.FirstOrDefault(r => _engine.IsRuleProtected(r));
        if (protectedRule != null)
        {
            if (!Dialogs.RequestUnlock(protectedRule.Protection, protectedRule.UnlockChars, protectedRule.StopDelayMinutes, $"cerrar FocusDesk mientras la regla «{protectedRule.Name}» está protegida", _mainWindow))
                return;
            if (protectedRule.Protection == SessionProtection.Forced)
                _engine.Workspace.RecordAudit("Salida de emergencia", $"Cierre de FocusDesk con regla «{protectedRule.Name}» protegida.");
        }

        if (_engine.Workspace.Session is { Paused: false, EndedAt: null } runningSess)
            runningSess.Pause(DateTimeOffset.Now);

        _engine.Workspace.ClosedBySystemAt = DateTimeOffset.UtcNow;
        _engine.Persist();
        RelaunchGuard.StopWatcherProcess();
        _mainWindow?.AllowClose();
        _mainWindow?.Close();
        _trayIcon?.Dispose();
        _waitHandle?.Unregister(null);
        try { _showWindowEvent?.Dispose(); } catch { }
        try { _singleInstanceMutex?.ReleaseMutex(); _singleInstanceMutex?.Dispose(); } catch { }
        _engine.Dispose();
        Shutdown();
    }
}
