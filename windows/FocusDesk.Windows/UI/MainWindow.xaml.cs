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
        _onQuitRequested = onQuitRequested;
        _engine.StateRefreshed += RefreshUI;
        _engine.TickUpdated += UpdateLiveReadouts;
        _engine.SessionCompletionRequested += s => Dialogs.ShowCompletionDialog(_engine, s, this);
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
        RegisterHotKey(helper.Handle, HOTKEY_SHOW, mods, 0x46);   // Ctrl+Alt+Win+F
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
                            if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"pausar «{s.Task.Title}»", this))
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
                            if (!Dialogs.RequestUnlock(finSess.Task.Protection, finSess.Task.UnlockChars, finSess.Task.StopDelayMinutes, $"terminar antes «{finSess.Task.Title}»", this))
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
            NoticeText.Foreground = BrushHex(!string.IsNullOrEmpty(_engine.Error) ? "#F26D6D" : "#64E3A1");
            NoticeBanner.BorderBrush = BrushHex(!string.IsNullOrEmpty(_engine.Error) ? "#5C262B" : "#242E40");
        }
        else
        {
            NoticeBanner.Visibility = Visibility.Collapsed;
        }

        SidebarStudyText.Text = $"Estudio hoy: {FocusRules.Clock(_engine.Workspace.VerifiedStudySecondsToday())}";
        SidebarGuardText.Text = $"Vigilante: {(RelaunchGuard.IsInstalled() ? "activo" : "apagado")}";
    }

    private void UpdateLiveReadouts()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(UpdateLiveReadouts); return; }

        UpdateNoticeAndSidebar();
        var now = DateTimeOffset.Now;

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

        foreach (var (rule, titleBlock, subBlock) in _liveGameStrips)
        {
            var st = _engine.GameRuleStatus(rule, now);
            titleBlock.Text = $"{rule.Game?.Name ?? rule.Name} · {st.Text}";
            titleBlock.Foreground = BrushHex(st.Warning ? "#F5B95F" : "#64E3A1");
            subBlock.Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(rule, now))} · {_engine.Workspace.MatchesToday(rule.Id, now)}/{Math.Max(1, rule.MaxDailyMatches)} {rule.MatchUnitPlural}";
        }
    }

    private void RefreshUI()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(RefreshUI); return; }

        UpdateNoticeAndSidebar();

        foreach (var child in NavStack.Children.OfType<System.Windows.Controls.Button>())
        {
            var active = string.Equals(child.Tag as string, _engine.ActivePage, StringComparison.Ordinal);
            child.Background = BrushHex(active ? "#64E3A1" : "Transparent");
            child.BorderBrush = BrushHex(active ? "#64E3A1" : "Transparent");
            child.Foreground = BrushHex(active ? "#0B0E14" : "#CBD5E1");
            child.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
        }

        _liveClockText = null;
        _livePomodoroText = null;
        _liveBreakText = null;
        _liveGameStrips.Clear();
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
        Background = BrushHex("#131822"),
        BorderBrush = BrushHex(accentBorder ?? "#242E40"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(14),
        Padding = new Thickness(18),
        Margin = new Thickness(0, 0, 0, 12),
        Child = child
    };

    private UIElement PageHeader(string title, string subtitle, UIElement? trailingButton = null)
    {
        var dock = new DockPanel { Margin = new Thickness(0, 0, 0, 18) };
        if (trailingButton != null)
        {
            DockPanel.SetDock(trailingButton, Dock.Right);
            if (trailingButton is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
            dock.Children.Add(trailingButton);
        }
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = title, FontSize = 24, FontWeight = FontWeights.Bold, Foreground = BrushHex("#F2F5FA") });
        stack.Children.Add(new TextBlock { Text = subtitle, FontSize = 12.5, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 3, 0, 0) });
        dock.Children.Add(stack);
        return dock;
    }

    private static System.Windows.Controls.Button PrimaryButton(string label) => new()
    {
        Content = label,
        Background = BrushHex("#64E3A1"),
        Foreground = BrushHex("#0B0E14"),
        BorderBrush = BrushHex("#64E3A1"),
        FontWeight = FontWeights.SemiBold
    };

    private static Border PillBadge(string text, string fgHex = "#94A3B8", string bgHex = "#1B2230") => new()
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
                if (!Dialogs.RequestUnlock(cur.Task.Protection, cur.Task.UnlockChars, cur.Task.StopDelayMinutes, $"terminar antes «{cur.Task.Title}»", this))
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

    private void BuildTodayPage()
    {
        var addBtn = PrimaryButton("+ Nueva tarea");
        addBtn.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, null, this);
        PageContent.Children.Add(PageHeader(
            $"Hoy · {_engine.SelectedDate.LocalDateTime:dddd d MMM}",
            "Haz espacio para lo importante.",
            addBtn));

        // Active session card
        if (_engine.Workspace.Session is { EndedAt: null } s)
        {
            var now = DateTimeOffset.Now;
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock
            {
                Text = s.Paused ? $"EN PAUSA · {s.Task.Title}" : $"EN MARCHA · {s.Task.Title}",
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Foreground = BrushHex(s.Paused ? "#F5B95F" : "#64E3A1")
            });
            _liveClockText = new TextBlock
            {
                Text = FocusRules.Clock(s.Remaining(now)),
                FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
                FontSize = 38,
                FontWeight = FontWeights.Bold,
                Margin = new Thickness(0, 8, 0, 6)
            };
            sp.Children.Add(_liveClockText);

            if (s.Task.PomodoroPhase(s.Elapsed(now)) is { } phase)
            {
                _livePomodoroText = new TextBlock
                {
                    Text = $"Pomodoro · {phase.Label} (ciclo {phase.Cycle}) · {FocusRules.Clock(phase.RemainingInPhase)}",
                    Foreground = BrushHex("#F5B95F"),
                    FontSize = 12.5,
                    Margin = new Thickness(0, 0, 0, 10)
                };
                sp.Children.Add(_livePomodoroText);
            }

            var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
            var pauseBtn = new System.Windows.Controls.Button { Content = s.Paused ? "Reanudar" : "Pausar", Margin = new Thickness(0, 0, 8, 0) };
            pauseBtn.Click += (_, _) =>
            {
                if (!s.Paused && s.Task.Protection != SessionProtection.None && s.Remaining(DateTimeOffset.Now) > 0)
                {
                    if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"pausar «{s.Task.Title}»", this))
                        return;
                    if (s.Task.Protection == SessionProtection.Forced)
                        _engine.Workspace.RecordAudit("Salida de emergencia", $"Pausa anticipada de «{s.Task.Title}».");
                }
                if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
            };
            var add10 = new System.Windows.Controls.Button { Content = "+10 min", Margin = new Thickness(0, 0, 8, 0) };
            add10.Click += (_, _) => _engine.AddSessionMinutes(10);
            var fin = PrimaryButton("He terminado");
            fin.Margin = new Thickness(0, 0, 8, 0);
            fin.Click += (_, _) =>
            {
                if (s.Remaining(DateTimeOffset.Now) > 0 && s.Task.Protection != SessionProtection.None)
                {
                    if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"terminar antes «{s.Task.Title}»", this))
                        return;
                    if (s.Task.Protection == SessionProtection.Forced)
                        _engine.Workspace.RecordAudit("Salida de emergencia", $"Finalización anticipada de «{s.Task.Title}».");
                }
                _engine.FinishSession();
            };
            var cancelBtn = new System.Windows.Controls.Button
            {
                Content = s.Task.Protection == SessionProtection.Forced ? "Salida de emergencia" : "Cancelar"
            };
            cancelBtn.Click += (_, _) =>
            {
                if (s.Remaining(DateTimeOffset.Now) > 0 && s.Task.Protection != SessionProtection.None)
                {
                    if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"cancelar «{s.Task.Title}»", this))
                        return;
                    if (s.Task.Protection == SessionProtection.Forced)
                        _engine.Workspace.RecordAudit("Salida de emergencia", $"Cancelación de emergencia de «{s.Task.Title}».");
                }
                _engine.CancelSession();
            };
            btns.Children.Add(pauseBtn);
            btns.Children.Add(add10);
            btns.Children.Add(fin);
            btns.Children.Add(cancelBtn);
            sp.Children.Add(btns);
            PageContent.Children.Add(Card(sp, s.Paused ? "#4A3A1E" : "#275943"));
        }

        // Game rules live strip
        foreach (var gr in _engine.Workspace.GeneralRules.Where(r => r.Enabled && r.Kind == GeneralRuleKind.WorkGoal && r.MaxDailyMatches > 0))
        {
            var st = _engine.GameRuleStatus(gr);
            var dock = new DockPanel();
            if (st.CanFinish)
            {
                var endMatch = new System.Windows.Controls.Button { Content = "He terminado", Margin = new Thickness(12, 0, 0, 0) };
                endMatch.Click += (_, _) => _engine.FinishTimedMatch(gr, TimedMatchPlanner.FinishReason.UserFinished);
                DockPanel.SetDock(endMatch, Dock.Right);
                dock.Children.Add(endMatch);
            }
            var info = new StackPanel();
            var titleBlock = new TextBlock { Text = $"{gr.Game?.Name ?? gr.Name} · {st.Text}", FontWeight = FontWeights.SemiBold, FontSize = 14, Foreground = BrushHex(st.Warning ? "#F5B95F" : "#64E3A1") };
            var subBlock = new TextBlock { Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(gr))} · {_engine.Workspace.MatchesToday(gr.Id)}/{gr.MaxDailyMatches} {gr.MatchUnitPlural}", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 4, 0, 0) };
            info.Children.Add(titleBlock);
            info.Children.Add(subBlock);
            dock.Children.Add(info);
            _liveGameStrips.Add((gr, titleBlock, subBlock));
            PageContent.Children.Add(Card(dock));
        }

        // Scheduled tasks for today
        var todayTasks = _engine.Workspace.Tasks
            .Where(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == _engine.SelectedDate.LocalDateTime.Date)
            .OrderBy(t => t.ScheduledAt)
            .ToList();

        PageContent.Children.Add(new TextBlock { Text = $"AGENDA ({todayTasks.Count})", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 8, 0, 10) });
        if (todayTasks.Count == 0)
        {
            PageContent.Children.Add(Card(new TextBlock
            {
                Text = "Sin tareas programadas para hoy. Pulsa «+ Nueva tarea» para crear tu primer bloque.",
                Foreground = BrushHex("#94A3B8"),
                FontSize = 13
            }));
        }
        foreach (var t in todayTasks)
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

            var left = new StackPanel();
            left.Children.Add(new TextBlock { Text = t.Title, FontSize = 15, FontWeight = FontWeights.SemiBold });
            var meta = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            meta.Children.Add(PillBadge($"{t.ScheduledAt.LocalDateTime:HH:mm}–{t.End.LocalDateTime:HH:mm}", "#64E3A1", "#173228"));
            meta.Children.Add(PillBadge(FocusRules.DurationText(t.Minutes)));
            meta.Children.Add(PillBadge(t.Category));
            if (t.Protection != SessionProtection.None)
                meta.Children.Add(PillBadge(_engine.IsTaskProtected(t) ? $"Ya protegida · {t.Protection.Label()}" : t.Protection.Label(), "#F5B95F", "#251D10"));
            left.Children.Add(meta);
            dock.Children.Add(left);
            PageContent.Children.Add(Card(dock));
        }

        // Inbox tasks
        var inbox = _engine.Workspace.Tasks.Where(t => !t.Completed && !t.IsScheduled).ToList();
        if (inbox.Count > 0)
        {
            PageContent.Children.Add(new TextBlock { Text = $"BANDEJA SIN HORA ({inbox.Count})", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 12, 0, 10) });
            foreach (var t in inbox)
            {
                var dock = new DockPanel();
                var right = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var start = PrimaryButton("Iniciar");
                start.Margin = new Thickness(0, 0, 6, 0);
                start.Click += (_, _) => StartOrHandoffSession(t);
                var edit = new System.Windows.Controls.Button { Content = "Editar", Margin = new Thickness(0, 0, 6, 0) };
                edit.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, t, this);
                var del = new System.Windows.Controls.Button { Content = "Borrar" };
                del.Click += (_, _) => ConfirmAndDeleteTask(t);
                right.Children.Add(start);
                right.Children.Add(edit);
                right.Children.Add(del);
                DockPanel.SetDock(right, Dock.Right);
                dock.Children.Add(right);

                var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
                left.Children.Add(new TextBlock { Text = t.Title, FontSize = 14.5, FontWeight = FontWeights.SemiBold });
                left.Children.Add(new TextBlock { Text = $"{t.Category} · {FocusRules.DurationText(t.Minutes)}", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 3, 0, 0) });
                dock.Children.Add(left);
                PageContent.Children.Add(Card(dock));
            }
        }
    }

    private void BuildWeekPage()
    {
        var addBtn = PrimaryButton("+ Nueva tarea");
        addBtn.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, null, this);
        PageContent.Children.Add(PageHeader("Semana", "Una semana con intención.", addBtn));

        var startOfWeek = _engine.SelectedDate.LocalDateTime.Date.AddDays(-(((int)_engine.SelectedDate.LocalDateTime.DayOfWeek + 6) % 7));
        for (var i = 0; i < 7; i++)
        {
            var day = startOfWeek.AddDays(i);
            var isToday = day == DateTime.Now.Date;
            var dayTasks = _engine.Workspace.Tasks
                .Where(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == day)
                .OrderBy(t => t.ScheduledAt).ToList();
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock
            {
                Text = isToday ? $"{day:dddd d MMM} · Hoy" : day.ToString("dddd d MMM"),
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = BrushHex(isToday ? "#64E3A1" : "#F2F5FA")
            });
            if (dayTasks.Count == 0)
                sp.Children.Add(new TextBlock { Text = "Sin bloques programados", Foreground = BrushHex("#64748B"), FontSize = 12, Margin = new Thickness(0, 5, 0, 0) });
            foreach (var t in dayTasks)
                sp.Children.Add(new TextBlock { Text = $"• {t.ScheduledAt.LocalDateTime:HH:mm}–{t.End.LocalDateTime:HH:mm}  {t.Title} ({t.Minutes} min)", Foreground = BrushHex("#CBD5E1"), FontSize = 13, Margin = new Thickness(0, 5, 0, 0) });
            PageContent.Children.Add(Card(sp, isToday ? "#275943" : null));
        }
    }

    private void BuildRulesPage()
    {
        var createBtn = PrimaryButton("+ Regla personalizada");
        createBtn.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, null, this);
        PageContent.Children.Add(PageHeader("Reglas y juegos", "Tus límites automáticos, también fuera de las tareas.", createBtn));

        PageContent.Children.Add(new TextBlock { Text = "PLANTILLAS DE JUEGOS · PRIMERO ESTUDIO, LUEGO PARTIDA", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 2, 0, 10) });
        var wrap = new WrapPanel { Margin = new Thickness(0, 0, 0, 18) };
        foreach (var game in GameCatalog.All)
        {
            var btn = new System.Windows.Controls.Button
            {
                Width = 216,
                Margin = new Thickness(0, 0, 10, 10),
                HorizontalContentAlignment = System.Windows.HorizontalAlignment.Left,
                Padding = new Thickness(14, 11, 14, 11),
                Background = BrushHex("#131822"),
                BorderBrush = BrushHex("#242E40")
            };
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = game.Name, FontWeight = FontWeights.SemiBold, FontSize = 13.5, Foreground = BrushHex("#F2F5FA") });
            sp.Children.Add(new TextBlock
            {
                Text = game.Detection.IsExact() ? game.Detection.Label() : $"{game.TypicalMatchMinutes} min + prórroga",
                FontSize = 11.5,
                Foreground = BrushHex("#64E3A1"),
                Margin = new Thickness(0, 3, 0, 0)
            });
            btn.Content = sp;
            btn.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, GeneralBlockRule.GameTemplate(game), this);
            wrap.Children.Add(btn);
        }
        PageContent.Children.Add(wrap);

        PageContent.Children.Add(new TextBlock { Text = $"TUS REGLAS ({_engine.Workspace.GeneralRules.Count})", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 4, 0, 10) });
        foreach (var rule in _engine.Workspace.GeneralRules)
        {
            var sp = new StackPanel();
            var header = new DockPanel();
            var actions = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };

            if (rule.Kind == GeneralRuleKind.Pomodoro)
            {
                var startP = new System.Windows.Controls.Button { Content = "Iniciar Pomodoro", Margin = new Thickness(0, 0, 6, 0) };
                startP.Click += (_, _) => { rule.StartPomodoro(); _engine.Persist(); };
                actions.Children.Add(startP);
            }
            if (rule.Kind == GeneralRuleKind.Countdown)
            {
                var startC = new System.Windows.Controls.Button { Content = $"Activar {rule.CountdownMinutes}m", Margin = new Thickness(0, 0, 6, 0) };
                startC.Click += (_, _) => { rule.StartCountdown(); _engine.Persist(); _engine.EnsureWatcherIfNeeded(); };
                actions.Children.Add(startC);
            }
            var microLeft = Math.Max(0, rule.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(rule.Id));
            if (_engine.IsRuleEnforcing(rule) && microLeft > 0)
            {
                var microBtn = new System.Windows.Controls.Button { Content = $"Micro-pausa ({rule.MicroPauseMinutes}m · {microLeft})", Margin = new Thickness(0, 0, 6, 0) };
                microBtn.Click += (_, _) => _engine.UseMicroPause(rule);
                actions.Children.Add(microBtn);
            }

            var toggle = new System.Windows.Controls.Button { Content = rule.Enabled ? "Apagar" : "Activar", Margin = new Thickness(0, 0, 6, 0) };
            toggle.Click += (_, _) =>
            {
                if (rule.Enabled && _engine.IsRuleProtected(rule))
                {
                    if (!Dialogs.RequestUnlock(rule.Protection, rule.UnlockChars, rule.StopDelayMinutes, $"apagar «{rule.Name}»", this))
                        return;
                    if (rule.Protection == SessionProtection.Forced)
                        _engine.Workspace.RecordAudit("Salida de emergencia", $"Apagada regla protegida «{rule.Name}».");
                }
                rule.Enabled = !rule.Enabled;
                if (!rule.Enabled && rule.Kind == GeneralRuleKind.Pomodoro)
                {
                    rule.PomodoroPhase = PomodoroPhase.Idle;
                    rule.ActivePomodoroDeadline = null;
                }
                _engine.Persist();
                _engine.EnsureWatcherIfNeeded();
            };

            var edit = new System.Windows.Controls.Button { Content = "Editar", Margin = new Thickness(0, 0, 6, 0) };
            edit.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, rule, null, this);

            var del = new System.Windows.Controls.Button { Content = "Borrar" };
            del.Click += (_, _) =>
            {
                var bypass = false;
                if (_engine.IsRuleProtected(rule))
                {
                    if (!Dialogs.RequestUnlock(rule.Protection, rule.UnlockChars, rule.StopDelayMinutes, $"borrar «{rule.Name}»", this))
                        return;
                    if (rule.Protection == SessionProtection.Forced)
                        _engine.Workspace.RecordAudit("Salida de emergencia", $"Borrada regla protegida «{rule.Name}».");
                    bypass = true;
                }
                _engine.DeleteGeneralRule(rule, bypassProtection: bypass);
            };

            actions.Children.Add(toggle);
            actions.Children.Add(edit);
            actions.Children.Add(del);
            DockPanel.SetDock(actions, Dock.Right);
            header.Children.Add(actions);

            var titleStack = new StackPanel();
            var enforcing = _engine.IsRuleEnforcing(rule);
            titleStack.Children.Add(new TextBlock { Text = rule.Name, FontSize = 15, FontWeight = FontWeights.SemiBold });
            var pills = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            pills.Children.Add(PillBadge(rule.Kind.GalleryTitle()));
            pills.Children.Add(PillBadge(enforcing ? "Bloqueando" : rule.Enabled ? "Activa" : "Apagada", enforcing ? "#64E3A1" : rule.Enabled ? "#E2E8F0" : "#64748B", enforcing ? "#173228" : "#1B2230"));
            pills.Children.Add(PillBadge(rule.Protection.Label(), rule.Protection == SessionProtection.None ? "#94A3B8" : "#F5B95F", rule.Protection == SessionProtection.None ? "#1B2230" : "#251D10"));
            titleStack.Children.Add(pills);
            header.Children.Add(titleStack);
            sp.Children.Add(header);

            if (rule.Kind == GeneralRuleKind.WorkGoal && rule.MaxDailyMatches > 0)
            {
                var st = _engine.GameRuleStatus(rule);
                var gRow = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
                if (st.CanFinish)
                {
                    var finBtn = new System.Windows.Controls.Button { Content = "He terminado" };
                    finBtn.Click += (_, _) => _engine.FinishTimedMatch(rule, TimedMatchPlanner.FinishReason.UserFinished);
                    DockPanel.SetDock(finBtn, Dock.Right);
                    gRow.Children.Add(finBtn);
                }
                gRow.Children.Add(new TextBlock { Text = st.Text, Foreground = BrushHex(st.Warning ? "#F5B95F" : "#64E3A1"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
                sp.Children.Add(gRow);
            }

            PageContent.Children.Add(Card(sp, enforcing ? "#275943" : null));
        }
    }

    private void BuildBlockingPage()
    {
        PageContent.Children.Add(PageHeader("Bloquear ahora", "Activa un bloqueo inmediato o inicia un perfil reutilizable con un clic."));

        var quickStack = new StackPanel();
        quickStack.Children.Add(new TextBlock { Text = "BLOQUEO RÁPIDO INMEDIATO (REDES, VÍDEOS CORTOS Y JUEGOS)", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#64E3A1") });
        quickStack.Children.Add(new TextBlock { Text = "Activa una cuenta atrás protegida por código sin necesidad de crear una tarea en la agenda:", FontSize = 12, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 4, 0, 10) });
        var quickBtns = new WrapPanel();
        foreach (var (mins, label) in new[] { (15, "15 min"), (30, "30 min"), (45, "45 min"), (60, "1 hora"), (120, "2 horas"), (240, "4 horas") })
        {
            var captured = mins;
            var b = new System.Windows.Controls.Button { Content = $"Bloquear {label}", Margin = new Thickness(0, 0, 8, 8) };
            b.Click += (_, _) => _engine.LaunchQuickBlock(captured, SessionProtection.Challenge);
            quickBtns.Children.Add(b);
        }
        var restOfDayMins = Math.Max(15, (int)(DateTime.Now.Date.AddDays(1) - DateTime.Now).TotalMinutes);
        var restBtn = PrimaryButton("Resto del día");
        restBtn.Margin = new Thickness(0, 0, 8, 8);
        restBtn.Click += (_, _) => _engine.LaunchQuickBlock(restOfDayMins, SessionProtection.Challenge);
        quickBtns.Children.Add(restBtn);
        quickStack.Children.Add(quickBtns);
        PageContent.Children.Add(Card(quickStack, "#275943"));

        var activeRules = _engine.Workspace.GeneralRules.Where(r => _engine.IsRuleEnforcing(r)).ToList();
        if (activeRules.Count > 0)
        {
            PageContent.Children.Add(new TextBlock { Text = $"BLOQUEANDO AHORA ({activeRules.Count})", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 8, 0, 10) });
            foreach (var r in activeRules)
            {
                var dock = new DockPanel();
                var microLeft = Math.Max(0, r.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(r.Id));
                if (microLeft > 0)
                {
                    var mpBtn = new System.Windows.Controls.Button { Content = $"Micro-pausa ({r.MicroPauseMinutes}m · {microLeft})", VerticalAlignment = VerticalAlignment.Center };
                    mpBtn.Click += (_, _) => _engine.UseMicroPause(r);
                    DockPanel.SetDock(mpBtn, Dock.Right);
                    dock.Children.Add(mpBtn);
                }
                var sp = new StackPanel();
                sp.Children.Add(new TextBlock { Text = r.Name, FontSize = 14.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#64E3A1") });
                sp.Children.Add(new TextBlock { Text = $"{r.Kind.GalleryTitle()} · Protección: {r.Protection.Label()}", FontSize = 12, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 3, 0, 0) });
                dock.Children.Add(sp);
                PageContent.Children.Add(Card(dock, "#275943"));
            }
        }

        PageContent.Children.Add(new TextBlock { Text = "PERFILES REUTILIZABLES", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 8, 0, 10) });
        foreach (var profile in _engine.Workspace.Profiles)
        {
            var dock = new DockPanel();
            var launch = PrimaryButton($"Empezar {profile.Minutes} min");
            launch.VerticalAlignment = VerticalAlignment.Center;
            launch.Click += (_, _) =>
            {
                var t = new FocusTask { Title = profile.Name, ScheduledAt = DateTimeOffset.Now };
                t.Apply(profile);
                _engine.SaveTask(t);
                StartOrHandoffSession(t);
                _engine.ActivePage = "Hoy";
            };
            DockPanel.SetDock(launch, Dock.Right);
            dock.Children.Add(launch);
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = profile.Name, FontSize = 15, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(new TextBlock { Text = $"{profile.Category} · {profile.Minutes} min · {profile.Protection.Label()} · {(string.IsNullOrEmpty(profile.Domains) ? "sin lista web" : profile.Domains)}", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 4, 0, 0), TextWrapping = TextWrapping.Wrap });
            dock.Children.Add(sp);
            PageContent.Children.Add(Card(dock));
        }
    }

    private void BuildBreaksPage()
    {
        PageContent.Children.Add(PageHeader("Descansos", "Descansa la vista y la mente antes de necesitarlo."));
        var s = _engine.Workspace.Settings;
        var sp = new StackPanel();
        var contCheck = new System.Windows.Controls.CheckBox
        {
            Content = $"Descanso continuo de vista ({s.ContinuousWorkMinutes} min de trabajo → {s.ContinuousBreakDurationMinutes} min de descanso)",
            IsChecked = s.ContinuousBreakEnabled
        };
        contCheck.Click += (_, _) => { s.ContinuousBreakEnabled = contCheck.IsChecked == true; _engine.Persist(); };
        sp.Children.Add(contCheck);
        if (_engine.ActiveContinuousBreakDeadline != null)
        {
            _liveBreakText = new TextBlock
            {
                Text = $"Descanso activo: {FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot())} · {_engine.ActiveContinuousBreakMessage}",
                Foreground = BrushHex("#64E3A1"),
                FontSize = 13,
                Margin = new Thickness(0, 10, 0, 0)
            };
            sp.Children.Add(_liveBreakText);
        }
        PageContent.Children.Add(Card(sp));

        foreach (var br in s.Breaks)
        {
            PageContent.Children.Add(Card(new TextBlock { Text = $"{br.Title} · {br.StartHour:D2}:{br.StartMinute:D2} ({br.DurationMinutes} min)", FontSize = 14 }));
        }
    }

    private void BuildHistoryPage()
    {
        var switchBtn = new System.Windows.Controls.Button { Content = _auditView ? "Ver sesiones" : "Registro de auditoría" };
        switchBtn.Click += (_, _) => { _auditView = !_auditView; RefreshUI(); };
        PageContent.Children.Add(PageHeader(
            _auditView ? "Registro de auditoría" : "Historial de sesiones",
            "Lo que has hecho cuenta.",
            switchBtn));

        if (_auditView)
        {
            foreach (var item in _engine.Workspace.AuditLog.Take(60))
                PageContent.Children.Add(Card(new TextBlock { Text = $"{item.At.LocalDateTime:g} · [{item.Category}] {item.Summary}", TextWrapping = TextWrapping.Wrap, FontSize = 13 }));
            if (_engine.Workspace.AuditLog.Count == 0)
                PageContent.Children.Add(Card(new TextBlock { Text = "Sin eventos registrados todavía.", Foreground = BrushHex("#94A3B8") }));
            return;
        }

        foreach (var rec in _engine.Workspace.History.Take(50))
        {
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = $"{rec.Session.Task.Title} · {(rec.Completed ? "Completada" : rec.Cancelled ? "Cancelada" : "Pendiente")}", FontSize = 14.5, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(new TextBlock { Text = $"{rec.Session.StartedAt.LocalDateTime:g} · Trabajado: {FocusRules.Clock(rec.Session.Elapsed(rec.Session.EndedAt ?? rec.Session.StartedAt))} · Interrupciones: {rec.Session.InterruptionCount}", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 4, 0, 0) });
            PageContent.Children.Add(Card(sp));
        }
        if (_engine.Workspace.History.Count == 0)
            PageContent.Children.Add(Card(new TextBlock { Text = "Todavía no has completado ninguna sesión.", Foreground = BrushHex("#94A3B8") }));
    }

    private bool RequireProtectionGateForSettings(string actionDescription)
    {
        var gate = _engine.GetActiveProtectionGate();
        if (gate == null) return true;
        var ok = Dialogs.RequestUnlock(
            gate.Value.Protection,
            gate.Value.UnlockChars,
            gate.Value.StopDelayMinutes,
            $"{actionDescription} ({gate.Value.ContextLabel})",
            this);
        if (ok && gate.Value.Protection == SessionProtection.Forced)
            _engine.Workspace.RecordAudit("Salida de emergencia", $"Ajuste modificado: {actionDescription}.");
        return ok;
    }

    private void BuildSettingsPage()
    {
        PageContent.Children.Add(PageHeader("Ajustes", "A tu manera."));

        var guardPanel = new StackPanel();
        guardPanel.Children.Add(new TextBlock { Text = "PROTECCIÓN EN WINDOWS", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#64E3A1"), Margin = new Thickness(0, 0, 0, 10) });
        var guardCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Vigilante de relanzado (--watcher al iniciar Windows: vuelve a abrir FocusDesk si se cierra)",
            IsChecked = _engine.Workspace.Settings.RelaunchGuard
        };
        guardCheck.Click += (_, _) =>
        {
            var wantEnabled = guardCheck.IsChecked == true;
            if (!wantEnabled && !RequireProtectionGateForSettings("desactivar el vigilante de relanzado"))
            {
                guardCheck.IsChecked = true;
                return;
            }
            _engine.SetRelaunchGuard(wantEnabled);
        };
        guardPanel.Children.Add(guardCheck);

        var clipCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Proteger portapapeles (limpia comandos taskkill / enlaces bloqueados)",
            IsChecked = _engine.Workspace.Settings.ProtectClipboard,
            Margin = new Thickness(0, 10, 0, 0)
        };
        clipCheck.Click += (_, _) =>
        {
            var wantEnabled = clipCheck.IsChecked == true;
            if (!wantEnabled && !RequireProtectionGateForSettings("desactivar la protección del portapapeles"))
            {
                clipCheck.IsChecked = true;
                return;
            }
            _engine.Workspace.Settings.ProtectClipboard = wantEnabled;
            _engine.Persist();
        };
        guardPanel.Children.Add(clipCheck);

        var quitBtn = new System.Windows.Controls.Button { Content = "Salir de FocusDesk", Margin = new Thickness(0, 14, 0, 0), HorizontalAlignment = System.Windows.HorizontalAlignment.Left };
        quitBtn.Click += (_, _) => _onQuitRequested();
        guardPanel.Children.Add(quitBtn);
        PageContent.Children.Add(Card(guardPanel));

        // Study sources
        var studyPanel = new StackPanel();
        studyPanel.Children.Add(new TextBlock { Text = "QUÉ CUENTA COMO ESTUDIO ACTIVO", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#64E3A1"), Margin = new Thickness(0, 0, 0, 4) });
        studyPanel.Children.Add(new TextBlock { Text = "Lo que añadas hoy empieza a contar mañana para evitar atajos de último minuto.", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 0, 0, 12) });

        var addRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 12) };
        var webInput = new System.Windows.Controls.TextBox { Width = 220, Margin = new Thickness(0, 0, 8, 0) };
        var addWebBtn = new System.Windows.Controls.Button { Content = "Añadir web", Margin = new Thickness(0, 0, 16, 0) };
        addWebBtn.Click += (_, _) => { _engine.AddStudyWeb(webInput.Text); webInput.Text = ""; };
        var appInput = new System.Windows.Controls.TextBox { Width = 170, Margin = new Thickness(0, 0, 8, 0) };
        var addAppBtn = new System.Windows.Controls.Button { Content = "Añadir .exe" };
        addAppBtn.Click += (_, _) => { _engine.AddStudyApp(appInput.Text, appInput.Text); appInput.Text = ""; };
        addRow.Children.Add(webInput);
        addRow.Children.Add(addWebBtn);
        addRow.Children.Add(appInput);
        addRow.Children.Add(addAppBtn);
        studyPanel.Children.Add(addRow);

        var wrap = new WrapPanel();
        foreach (var src in _engine.Workspace.Settings.StudySources)
        {
            var pill = new System.Windows.Controls.Button
            {
                Content = $"{src.Name} ({src.Kind}) ×",
                Margin = new Thickness(0, 0, 6, 6),
                Padding = new Thickness(10, 4, 10, 4),
                MinHeight = 28,
                FontSize = 12
            };
            pill.Click += (_, _) => _engine.RemoveStudySource(src);
            wrap.Children.Add(pill);
        }
        studyPanel.Children.Add(wrap);
        PageContent.Children.Add(Card(studyPanel));

        // Backups
        var backupPanel = new StackPanel();
        backupPanel.Children.Add(new TextBlock { Text = "COPIAS DE SEGURIDAD (.JSON)", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#64E3A1"), Margin = new Thickness(0, 0, 0, 10) });
        var backupRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var expBtn = new System.Windows.Controls.Button { Content = "Exportar copia (.json)", Margin = new Thickness(0, 0, 10, 0) };
        expBtn.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { FileName = "FocusDesk-backup.json", Filter = "JSON (*.json)|*.json" };
            if (dlg.ShowDialog() != true) return;
            try { _engine.ExportBackup(dlg.FileName); }
            catch (Exception ex) { _engine.Error = $"No se pudo exportar la copia: {ex.Message}"; UpdateNoticeAndSidebar(); }
        };
        var impBtn = new System.Windows.Controls.Button { Content = "Importar copia (.json)" };
        impBtn.Click += (_, _) =>
        {
            if (!RequireProtectionGateForSettings("importar una copia de seguridad"))
                return;
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "JSON (*.json)|*.json" };
            if (dlg.ShowDialog() != true) return;
            try { _engine.ImportBackup(dlg.FileName); }
            catch (Exception ex) { _engine.Error = $"No se pudo importar la copia: {ex.Message}"; UpdateNoticeAndSidebar(); }
        };
        backupRow.Children.Add(expBtn);
        backupRow.Children.Add(impBtn);
        backupPanel.Children.Add(backupRow);
        PageContent.Children.Add(Card(backupPanel));
    }
}
