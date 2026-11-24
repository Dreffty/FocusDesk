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
        // FocusDesk speaks Spanish: dates («martes 17 nov.») must not come out in English on an English Windows.
        var spanish = new System.Globalization.CultureInfo("es-ES");
        System.Globalization.CultureInfo.DefaultThreadCurrentCulture = spanish;
        System.Globalization.CultureInfo.DefaultThreadCurrentUICulture = spanish;
        Thread.CurrentThread.CurrentCulture = spanish;
        Thread.CurrentThread.CurrentUICulture = spanish;
        FrameworkElement.LanguageProperty.OverrideMetadata(typeof(FrameworkElement),
            new FrameworkPropertyMetadata(System.Windows.Markup.XmlLanguage.GetLanguage(spanish.IetfLanguageTag)));

        base.OnStartup(e);

        if (e.Args.Contains("--smoke-test", StringComparer.OrdinalIgnoreCase))
        {
            var exitCode = SmokeCheck.Run();
            Environment.Exit(exitCode);
            return;
        }

        // A plain window with a given title, used by the end-to-end check as a stand-in game (a copy of this exe
        // renamed like the game's process).
        var fakeIdx = Array.FindIndex(e.Args, a => a.Equals("--e2e-ventana", StringComparison.OrdinalIgnoreCase));
        if (fakeIdx >= 0)
        {
            ShutdownMode = ShutdownMode.OnLastWindowClose;
            var title = fakeIdx + 1 < e.Args.Length ? e.Args[fakeIdx + 1] : "Ventana de prueba";
            new Window { Title = title, Width = 640, Height = 420, Background = System.Windows.Media.Brushes.Black,
                Content = new System.Windows.Controls.TextBlock { Text = title, Foreground = System.Windows.Media.Brushes.White, FontSize = 28,
                    HorizontalAlignment = System.Windows.HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } }.Show();
            return;
        }

        // Real end-to-end check with real browsers (CI). Runs on this dispatcher so the engine works as in the app.
        if (e.Args.Contains("--e2e-test", StringComparer.OrdinalIgnoreCase))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Dispatcher.InvokeAsync(async () =>
            {
                var code = 1;
                try { code = await EndToEndCheck.RunAsync(); } catch { }
                Environment.Exit(code);
            });
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
        Dialogs.Host = _engine;
        _engine.TickUpdated += UpdateTrayText;
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
        // «Novedades», once, the first time this release is opened (as on the Mac).
        Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle,
            new Action(() => _mainWindow?.ShowWhatsNewIfPending()));
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
                if (!Dialogs.RequestSessionStop("pausar", s, _mainWindow))
                    return;
                if (s.Task.Protection == SessionProtection.Forced)
                    _engine.Workspace.RecordAudit("Salida de emergencia", $"Pausa anticipada de «{s.Task.Title}» desde bandeja.");
            }
            _engine.PauseSession();
        }));
        menu.Items.Add("Añadir 10 min a la sesión", null, (_, _) => Dispatcher.BeginInvoke(() => _engine?.AddSessionMinutes(10)));
        menu.Items.Add("Terminar sesión (He terminado)", null, (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (_engine?.Workspace.Session is not { EndedAt: null } running) return;
            ShowMainWindow();
            if (!Dialogs.RequestSessionStop("terminar antes", running, _mainWindow)) return;
            _engine.FinishSession();
        }));
        menu.Items.Add("Bloqueo rápido de 30 min", null, (_, _) => Dispatcher.BeginInvoke(() => _engine?.LaunchQuickBlock(30)));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Salir", null, (_, _) => Dispatcher.BeginInvoke(TryQuitApp));

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = LoadAppIcon(),
            Text = "FocusDesk",
            Visible = true,
            ContextMenuStrip = menu
        };
        // One click opens the small panel (the menu-bar panel of macOS); a double click opens the whole window.
        _trayIcon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) Dispatcher.BeginInvoke(ToggleTrayPanel);
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.BeginInvoke(() =>
        {
            _trayPanel?.Close();
            ShowMainWindow();
        });
    }

    /// <summary>FocusDesk's own icon for the notification area (it used to be the generic Windows program icon).</summary>
    private static Icon LoadAppIcon()
    {
        try
        {
            var resource = GetResourceStream(new Uri("pack://application:,,,/FocusDesk.ico"));
            if (resource != null)
            {
                using var stream = resource.Stream;
                return new Icon(stream, Forms.SystemInformation.SmallIconSize);
            }
        }
        catch { }
        try
        {
            if (Environment.ProcessPath is { } exe && Icon.ExtractAssociatedIcon(exe) is { } own) return own;
        }
        catch { }
        return SystemIcons.Application;
    }

    private TrayPanel? _trayPanel;
    private DateTime _trayPanelClosedAt = DateTime.MinValue;

    private void ToggleTrayPanel()
    {
        if (_engine == null) return;
        if (_trayPanel != null)
        {
            _trayPanel.Close();
            return;
        }
        // Clicking the icon while the panel is open closes it first (it loses the focus): do not open it again.
        if ((DateTime.UtcNow - _trayPanelClosedAt).TotalMilliseconds < 400) return;
        _trayPanel = new TrayPanel(_engine, ShowMainWindow, page =>
        {
            ShowMainWindow();
            _engine.ActivePage = page;
        }, () =>
        {
            ShowMainWindow();
            _mainWindow?.OpenCommandPalette();
        }, TryQuitApp, () => _mainWindow);
        _trayPanel.Closed += (_, _) =>
        {
            _trayPanel = null;
            _trayPanelClosedAt = DateTime.UtcNow;
        };
        _trayPanel.Show();
        _trayPanel.Activate();
    }

    /// <summary>The icon's tooltip is the menu-bar countdown of macOS: what is running and how long is left.</summary>
    private void UpdateTrayText()
    {
        if (_trayIcon == null || _engine == null) return;
        var text = "FocusDesk";
        if (_engine.Workspace.Session is { EndedAt: null } s)
            text = $"FocusDesk · {(s.Paused ? "en pausa" : FocusRules.Clock(s.Remaining(DateTimeOffset.Now)))} · {s.Task.Title}";
        else if (_engine.Workspace.GeneralRules.FirstOrDefault(r => _engine.IsRuleEnforcing(r)) is { } rule)
            text = $"FocusDesk · bloqueando · {rule.Name}";
        if (text.Length > 63) text = text.Substring(0, 62) + "…";
        if (_trayIcon.Text != text) _trayIcon.Text = text;
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
