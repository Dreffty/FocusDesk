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
    private AppEngine? _engine;
    private MainWindow? _mainWindow;
    private Forms.NotifyIcon? _trayIcon;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

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
            Shutdown();
            return;
        }

        ThreadPool.RegisterWaitForSingleObject(_showWindowEvent, (_, _) =>
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

        SetupTrayIcon();
        ShowMainWindow();
    }

    private void SetupTrayIcon()
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Abrir FocusDesk", null, (_, _) => Dispatcher.BeginInvoke(ShowMainWindow));
        menu.Items.Add("Pausar / Reanudar sesión", null, (_, _) => Dispatcher.BeginInvoke(() =>
        {
            if (_engine?.Workspace.Session is { } s)
            {
                if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
            }
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
        if (_engine.Workspace.Session is { EndedAt: null } s && s.Task.Protection != SessionProtection.None)
        {
            if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"cerrar FocusDesk mientras «{s.Task.Title}» está protegida", _mainWindow))
                return;
        }
        var protectedRule = _engine.Workspace.GeneralRules.FirstOrDefault(r => _engine.IsRuleProtected(r));
        if (protectedRule != null)
        {
            if (!Dialogs.RequestUnlock(protectedRule.Protection, protectedRule.UnlockChars, protectedRule.StopDelayMinutes, $"cerrar FocusDesk mientras la regla «{protectedRule.Name}» está protegida", _mainWindow))
                return;
        }
        _engine.Workspace.ClosedBySystemAt = DateTimeOffset.UtcNow;
        _engine.Persist();
        _trayIcon?.Dispose();
        _engine.Dispose();
        Shutdown();
    }
}
