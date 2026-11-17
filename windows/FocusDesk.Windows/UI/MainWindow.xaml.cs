using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

public partial class MainWindow : Window
{
    private readonly AppEngine _engine;
    private readonly Action _onQuitRequested;
    private bool _auditView;
    private bool _allowClose;
    private string _lastAnimatedPage = "";

    // Live UI handles updated every 1s by TickUpdated without wiping PageContent.
    private TextBlock? _liveClockText;
    private TextBlock? _livePomodoroText;
    private TextBlock? _liveBreakText;
    private readonly List<(GeneralBlockRule Rule, TextBlock TitleBlock, TextBlock SubBlock)> _liveGameStrips = new();

    [DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    private const int HOTKEY_SHOW = 9001;
    private const int HOTKEY_PAUSE = 9002;
    private const int HOTKEY_FINISH = 9003;
    private const uint MOD_ALT = 0x0001;
    private const uint MOD_CONTROL = 0x0002;
    private const uint MOD_WIN = 0x0008;

    public MainWindow(AppEngine engine, Action onQuitRequested)
    {
        InitializeComponent();
        _engine = engine;
        BuildNavigation();
        _onQuitRequested = onQuitRequested;
        _engine.StateRefreshed += RefreshUI;
        _engine.TickUpdated += UpdateLiveReadouts;
        _engine.SessionCompletionRequested += s => Dialogs.ShowCompletionDialog(_engine, s, this);
        PreviewKeyDown += OnWindowKeyDown;
        Loaded += (_, _) => RefreshUI();
    }

    public void AllowClose() => _allowClose = true;

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var helper = new WindowInteropHelper(this);
        var source = HwndSource.FromHwnd(helper.Handle);
        source?.AddHook(WndProc);
        var mods = MOD_CONTROL | MOD_ALT | MOD_WIN;
        ApplyHotKeys();                                           // Ctrl+Alt+Win+F (changeable in Ajustes)
        RegisterHotKey(helper.Handle, HOTKEY_PAUSE, mods, 0x50);  // Ctrl+Alt+Win+P
        RegisterHotKey(helper.Handle, HOTKEY_FINISH, mods, 0x54); // Ctrl+Alt+Win+T
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (_allowClose) return;
        // Closing window minimizes to tray so background blocking and watchers stay alive.
        e.Cancel = true;
        Hide();
    }

    protected override void OnClosed(EventArgs e)
    {
        _engine.StateRefreshed -= RefreshUI;
        _engine.TickUpdated -= UpdateLiveReadouts;
        var handle = new WindowInteropHelper(this).Handle;
        if (handle != IntPtr.Zero)
        {
            UnregisterHotKey(handle, HOTKEY_SHOW);
            UnregisterHotKey(handle, HOTKEY_PAUSE);
            UnregisterHotKey(handle, HOTKEY_FINISH);
        }
        base.OnClosed(e);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x0312)
        {
            switch (wParam.ToInt32())
            {
                case HOTKEY_SHOW:
                    Show();
                    if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
                    Activate();
                    handled = true;
                    break;

                case HOTKEY_PAUSE:
                    if (_engine.Workspace.Session is { EndedAt: null } s)
                    {
                        if (!s.Paused && s.Task.Protection != SessionProtection.None && s.Remaining(DateTimeOffset.Now) > 0)
                        {
                            Show();
                            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
                            Activate();
                            if (!Dialogs.RequestSessionStop("pausar", s, this))
                            {
                                handled = true;
                                break;
                            }
                            if (s.Task.Protection == SessionProtection.Forced)
                                _engine.Workspace.RecordAudit("Salida de emergencia", $"Pausa con atajo de «{s.Task.Title}».");
                        }
                        if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
                    }
                    handled = true;
                    break;

                case HOTKEY_FINISH:
                    if (_engine.Workspace.Session is { EndedAt: null } finSess)
                    {
                        if (finSess.Remaining(DateTimeOffset.Now) > 0 && finSess.Task.Protection != SessionProtection.None)
                        {
                            Show();
                            if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
                            Activate();
                            if (!Dialogs.RequestSessionStop("terminar antes", finSess, this))
                            {
                                handled = true;
                                break;
                            }
                            if (finSess.Task.Protection == SessionProtection.Forced)
                                _engine.Workspace.RecordAudit("Salida de emergencia", $"Cierre anticipado con atajo de «{finSess.Task.Title}».");
                        }
                        _engine.FinishSession();
                    }
                    handled = true;
                    break;
            }
        }
        return IntPtr.Zero;
    }

    private static SolidColorBrush BrushHex(string hex) =>
        new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));

    private void NavClick(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button b && b.Tag is string tag)
            _engine.ActivePage = tag;
    }

    private void DismissNoticeClick(object sender, RoutedEventArgs e)
    {
        _engine.Notice = "";
        _engine.Error = "";
        UpdateNoticeAndSidebar();
    }

    private void UpdateNoticeAndSidebar()
    {
        var msg = !string.IsNullOrEmpty(_engine.Error) ? _engine.Error : _engine.Notice;
        if (!string.IsNullOrEmpty(msg))
        {
            NoticeBanner.Visibility = Visibility.Visible;
            NoticeText.Text = msg;
            NoticeText.Foreground = BrushHex(!string.IsNullOrEmpty(_engine.Error) ? "#FF8080" : "#38A169");
            NoticeBanner.BorderBrush = BrushHex(!string.IsNullOrEmpty(_engine.Error) ? "#5C262B" : "#262A30");
        }
        else
        {
            NoticeBanner.Visibility = Visibility.Collapsed;
        }

        SidebarStudyText.Text = $"Estudio hoy: {FocusRules.Clock(_engine.Workspace.VerifiedStudySecondsToday())}";
        SidebarGuardText.Text = $"Vigilante: {(RelaunchGuard.IsInstalled() ? "activo" : "apagado")}";
        var keys = _engine.Workspace.Settings;
        HotKeyChipText.Text = keys.HotKeyEnabled ? HotKeyNames[Math.Clamp(keys.HotKeyChoice, 0, HotKeyNames.Length - 1)] : "apagado";
    }

    private void UpdateLiveReadouts()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(UpdateLiveReadouts); return; }

        UpdateNoticeAndSidebar();
        var now = DateTimeOffset.Now;
        UpdateSidebarSession(now);
        UpdateNavBadges(now);

        if (_liveClockText != null && _engine.Workspace.Session is { EndedAt: null } s)
        {
            _liveClockText.Text = FocusRules.Clock(s.Remaining(now));
            if (_livePomodoroText != null && s.Task.PomodoroPhase(s.Elapsed(now)) is { } phase)
            {
                _livePomodoroText.Text = $"Pomodoro · {phase.Label} (ciclo {phase.Cycle}) · {FocusRules.Clock(phase.RemainingInPhase)}";
            }
        }

        if (_liveBreakText != null && _engine.ActiveContinuousBreakDeadline != null)
        {
            _liveBreakText.Text = $"Descanso activo: {FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot(now))} · {_engine.ActiveContinuousBreakMessage}";
        }

        UpdateExtraLiveReadouts(now);

        foreach (var (rule, titleBlock, subBlock) in _liveGameStrips)
        {
            var st = _engine.GameRuleStatus(rule, now);
            titleBlock.Text = $"{rule.Game?.Name ?? rule.Name} · {st.Text}";
            titleBlock.Foreground = BrushHex(st.Warning ? "#FAC74D" : "#38A169");
            subBlock.Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(rule, now))} · {_engine.Workspace.MatchesToday(rule.Id, now)}/{Math.Max(1, rule.MaxDailyMatches)} {rule.MatchUnitPlural}";
        }
    }

    private void RefreshUI()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(RefreshUI); return; }

        UpdateNoticeAndSidebar();

        UpdateNav();
        UpdateNavBadges(DateTimeOffset.Now);
        UpdateSidebarSession(DateTimeOffset.Now);

        _liveClockText = null;
        _livePomodoroText = null;
        _liveBreakText = null;
        _liveGameStrips.Clear();
        ResetExtraLiveHandles();
        PageContent.Children.Clear();

        switch (_engine.ActivePage)
        {
            case "Hoy": BuildTodayPage(); break;
            case "Semana": BuildWeekPage(); break;
            case "Reglas": BuildRulesPage(); break;
            case "Bloquear": BuildBlockingPage(); break;
            case "Descansos": BuildBreaksPage(); break;
            case "Historial": BuildHistoryPage(); break;
            case "Ajustes": BuildSettingsPage(); break;
        }

        ApplyTextScale();

        if (_lastAnimatedPage != _engine.ActivePage)
        {
            _lastAnimatedPage = _engine.ActivePage;
            PageScroll.ScrollToTop();
            AnimatePageEnter();
        }
    }

    private void AnimatePageEnter()
    {
        PageContent.Opacity = 0;
        var shift = new TranslateTransform(0, 6);
        PageContent.RenderTransform = shift;
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        var dur = TimeSpan.FromMilliseconds(160);
        PageContent.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, dur) { EasingFunction = ease });
        shift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(6, 0, dur) { EasingFunction = ease });
    }

    private Border Card(UIElement child, string? accentBorder = null) => new()
    {
        Background = BrushHex("#161B21"),
        BorderBrush = BrushHex(accentBorder ?? "#262A30"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(16),
        Padding = new Thickness(20),
        Margin = new Thickness(0, 0, 0, 14),
        Child = child
    };

    private static System.Windows.Controls.Button PrimaryButton(string label) => new()
    {
        Content = label,
        Background = BrushHex("#38A169"),
        Foreground = BrushHex("#0D1014"),
        BorderBrush = BrushHex("#38A169"),
        FontWeight = FontWeights.SemiBold
    };

    private static Border PillBadge(string text, string fgHex = "#99A6AD", string bgHex = "#1D2229") => new()
    {
        Background = BrushHex(bgHex),
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(8, 3, 8, 3),
        Margin = new Thickness(0, 0, 6, 0),
        Child = new TextBlock { Text = text, FontSize = 11, FontWeight = FontWeights.Medium, Foreground = BrushHex(fgHex) }
    };

    private void ConfirmAndDeleteTask(FocusTask task)
    {
        if (_engine.Workspace.Session?.Task.Id == task.Id)
        {
            _engine.Error = "Termina o cancela la sesión en marcha antes de borrar esta tarea.";
            UpdateNoticeAndSidebar();
            return;
        }
        var bypass = false;
        if (_engine.IsTaskProtected(task))
        {
            if (!Dialogs.RequestUnlock(task.Protection, task.UnlockChars, task.StopDelayMinutes, $"borrar «{task.Title}»", this))
                return;
            if (task.Protection == SessionProtection.Forced)
                _engine.Workspace.RecordAudit("Salida de emergencia", $"Borrada tarea protegida «{task.Title}».");
            bypass = true;
        }
        _engine.DeleteTask(task, bypassProtection: bypass);
    }

    private void StartOrHandoffSession(FocusTask task)
    {
        if (_engine.Workspace.Session is { EndedAt: null } cur)
        {
            if (cur.Task.Id == task.Id)
            {
                if (cur.Paused) _engine.ResumeSession();
                return;
            }
            var confirm = System.Windows.MessageBox.Show(
                this,
                $"Tienes «{cur.Task.Title}» en marcha. ¿Quieres terminarla ahora y empezar «{task.Title}»?",
                "Cambiar de tarea · FocusDesk",
                MessageBoxButton.YesNo,
                MessageBoxImage.Question);
            if (confirm != MessageBoxResult.Yes) return;

            if (cur.Remaining(DateTimeOffset.Now) > 0 && cur.Task.Protection != SessionProtection.None)
            {
                if (!Dialogs.RequestSessionStop("terminar antes", cur, this))
                    return;
                if (cur.Task.Protection == SessionProtection.Forced)
                    _engine.Workspace.RecordAudit("Salida de emergencia", $"Cambio anticipado de «{cur.Task.Title}» a «{task.Title}».");
            }
            _engine.FinishSession();
            if (_engine.Workspace.Session != null) return;
        }
        _engine.StartSession(task);
    }

    private void ConfirmAndSnoozeTask(FocusTask task)
    {
        var bypass = false;
        if (_engine.IsTaskProtected(task))
        {
            if (!Dialogs.RequestUnlock(task.Protection, task.UnlockChars, task.StopDelayMinutes, $"posponer «{task.Title}»", this))
                return;
            if (task.Protection == SessionProtection.Forced)
                _engine.Workspace.RecordAudit("Salida de emergencia", $"Pospuesta tarea protegida «{task.Title}».");
            bypass = true;
        }
        _engine.SnoozeTask(task, 10, bypassProtection: bypass);
    }

    private Border OverdueRow(FocusTask t)
    {
        var dock = new DockPanel();
        var right = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var start = PrimaryButton("Iniciar");
        start.Margin = new Thickness(0, 0, 6, 0);
        start.Click += (_, _) => StartOrHandoffSession(t);
        var snooze = new System.Windows.Controls.Button { Content = "+10m", Margin = new Thickness(0, 0, 6, 0) };
        snooze.Click += (_, _) => ConfirmAndSnoozeTask(t);
        var edit = new System.Windows.Controls.Button { Content = "Editar", Margin = new Thickness(0, 0, 6, 0) };
        edit.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, t, this);
        var del = new System.Windows.Controls.Button { Content = "Borrar" };
        del.Click += (_, _) => ConfirmAndDeleteTask(t);
        right.Children.Add(start);
        right.Children.Add(snooze);
        right.Children.Add(edit);
        right.Children.Add(del);
        DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(right);

        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = t.Title, FontSize = 14.5, FontWeight = FontWeights.SemiBold });
        var meta = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        meta.Children.Add(PillBadge($"{t.ScheduledAt.LocalDateTime:ddd d MMM · HH:mm}", "#FAC74D", "#251D10"));
        meta.Children.Add(PillBadge(FocusRules.DurationText(t.Minutes)));
        meta.Children.Add(PillBadge(t.Category));
        left.Children.Add(meta);
        dock.Children.Add(left);
        return Card(dock, "#4A3A1E");
    }

    /// <summary>
    /// Like macOS `refuseWhileProtected`: while something is protected, settings that would let it be escaped
    /// (turning watchers off, restoring or importing a copy) are simply not available. Returns true when it is OK to go on.
    /// </summary>
    private bool RequireProtectionGateForSettings(string actionDescription)
    {
        var gate = _engine.GetActiveProtectionGate();
        if (gate == null) return true;
        _engine.Notice = $"No se puede {actionDescription} {gate.Value.ContextLabel}.";
        UpdateNoticeAndSidebar();
        return false;
    }
}
