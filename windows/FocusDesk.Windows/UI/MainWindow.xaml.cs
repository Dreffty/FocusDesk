using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

public partial class MainWindow : Window
{
    private readonly AppEngine _engine;
    private readonly Action _onQuitRequested;
    private bool _auditView;

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
        _engine.SessionCompletionRequested += s => Dialogs.ShowCompletionDialog(_engine, s, this);
        Loaded += (_, _) => RefreshUI();
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var helper = new WindowInteropHelper(this);
        var source = HwndSource.FromHwnd(helper.Handle);
        source?.AddHook(WndProc);
        var mods = MOD_CONTROL | MOD_ALT | MOD_WIN;
        RegisterHotKey(helper.Handle, HOTKEY_SHOW, mods, 0x46);   // F
        RegisterHotKey(helper.Handle, HOTKEY_PAUSE, mods, 0x50);  // P
        RegisterHotKey(helper.Handle, HOTKEY_FINISH, mods, 0x54); // T
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Closing window minimizes to tray so background blocking and watchers stay alive.
        e.Cancel = true;
        Hide();
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == 0x0312)
        {
            switch (wParam.ToInt32())
            {
                case HOTKEY_SHOW: Show(); Activate(); handled = true; break;
                case HOTKEY_PAUSE:
                    if (_engine.Workspace.Session is { } s)
                    {
                        if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
                    }
                    handled = true;
                    break;
                case HOTKEY_FINISH:
                    if (_engine.Workspace.Session != null) _engine.FinishSession();
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
        RefreshUI();
    }

    private void RefreshUI()
    {
        if (!Dispatcher.CheckAccess()) { Dispatcher.BeginInvoke(RefreshUI); return; }

        var msg = !string.IsNullOrEmpty(_engine.Error) ? _engine.Error : _engine.Notice;
        if (!string.IsNullOrEmpty(msg))
        {
            NoticeBanner.Visibility = Visibility.Visible;
            NoticeText.Text = msg;
            NoticeText.Foreground = BrushHex(!string.IsNullOrEmpty(_engine.Error) ? "#F26D6D" : "#64E3A1");
        }
        else
        {
            NoticeBanner.Visibility = Visibility.Collapsed;
        }

        SidebarStudyText.Text = $"Estudio hoy: {FocusRules.Clock(_engine.Workspace.VerifiedStudySecondsToday())}";
        SidebarGuardText.Text = $"Vigilante: {(RelaunchGuard.IsInstalled() ? "activo" : "apagado")}";

        foreach (var child in NavStack.Children.OfType<System.Windows.Controls.Button>())
        {
            var active = string.Equals(child.Tag as string, _engine.ActivePage, StringComparison.Ordinal);
            child.Background = BrushHex(active ? "#64E3A1" : "#1F2631");
            child.Foreground = BrushHex(active ? "#0F1218" : "#F2F5FA");
            child.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
        }

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
    }

    private Border Card(UIElement child) => new()
    {
        Background = BrushHex("#171C24"),
        BorderBrush = BrushHex("#283140"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(12),
        Padding = new Thickness(16),
        Margin = new Thickness(0, 0, 0, 12),
        Child = child
    };

    private TextBlock Header(string text) => new()
    {
        Text = text,
        FontSize = 22,
        FontWeight = FontWeights.Bold,
        Margin = new Thickness(0, 0, 0, 14)
    };

    private void BuildTodayPage()
    {
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var addBtn = new System.Windows.Controls.Button
        {
            Content = "+ Nueva tarea",
            Background = BrushHex("#64E3A1"),
            Foreground = BrushHex("#0F1218"),
            FontWeight = FontWeights.SemiBold
        };
        addBtn.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, null, this);
        DockPanel.SetDock(addBtn, Dock.Right);
        top.Children.Add(addBtn);
        top.Children.Add(new TextBlock { Text = $"Hoy · {_engine.SelectedDate.LocalDateTime:dddd d MMM}", FontSize = 22, FontWeight = FontWeights.Bold });
        PageContent.Children.Add(top);

        // Active session card
        if (_engine.Workspace.Session is { } s)
        {
            var sp = new StackPanel();
            var rem = s.Remaining(DateTimeOffset.Now);
            sp.Children.Add(new TextBlock { Text = $"EN MARCHA · {s.Task.Title}", FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#64E3A1") });
            sp.Children.Add(new TextBlock { Text = FocusRules.Clock(rem), FontSize = 36, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 6, 0, 6) });
            if (s.Task.PomodoroPhase(s.Elapsed(DateTimeOffset.Now)) is { } phase)
            {
                sp.Children.Add(new TextBlock { Text = $"Pomodoro · {phase.Label} (ciclo {phase.Cycle}) · {FocusRules.Clock(phase.RemainingInPhase)}", Foreground = BrushHex("#F5B95F"), Margin = new Thickness(0, 0, 0, 8) });
            }
            var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            var pauseBtn = new System.Windows.Controls.Button { Content = s.Paused ? "Reanudar" : "Pausar", Margin = new Thickness(0, 0, 8, 0) };
            pauseBtn.Click += (_, _) =>
            {
                if (!s.Paused && s.Task.Protection != SessionProtection.None &&
                    !Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"pausar «{s.Task.Title}»", this))
                    return;
                if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
            };
            var add10 = new System.Windows.Controls.Button { Content = "+10 min", Margin = new Thickness(0, 0, 8, 0) };
            add10.Click += (_, _) => _engine.AddSessionMinutes(10);
            var fin = new System.Windows.Controls.Button { Content = "He terminado", Background = BrushHex("#64E3A1"), Foreground = BrushHex("#0F1218"), FontWeight = FontWeights.SemiBold };
            fin.Click += (_, _) =>
            {
                if (s.Remaining(DateTimeOffset.Now) > 0 && s.Task.Protection != SessionProtection.None &&
                    !Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"terminar antes «{s.Task.Title}»", this))
                    return;
                _engine.FinishSession();
            };
            btns.Children.Add(pauseBtn);
            btns.Children.Add(add10);
            btns.Children.Add(fin);
            sp.Children.Add(btns);
            PageContent.Children.Add(Card(sp));
        }

        // Game rules live strip
        foreach (var gr in _engine.Workspace.GeneralRules.Where(r => r.Enabled && r.Kind == GeneralRuleKind.WorkGoal && r.MaxDailyMatches > 0))
        {
            var st = _engine.GameRuleStatus(gr);
            var dock = new DockPanel();
            if (st.CanFinish)
            {
                var endMatch = new System.Windows.Controls.Button { Content = "He terminado", Margin = new Thickness(10, 0, 0, 0) };
                endMatch.Click += (_, _) => _engine.FinishTimedMatch(gr, TimedMatchPlanner.FinishReason.UserFinished);
                DockPanel.SetDock(endMatch, Dock.Right);
                dock.Children.Add(endMatch);
            }
            var info = new StackPanel();
            info.Children.Add(new TextBlock { Text = $"{gr.Game?.Name ?? gr.Name} · {st.Text}", FontWeight = FontWeights.SemiBold, Foreground = BrushHex(st.Warning ? "#F5B95F" : "#64E3A1") });
            info.Children.Add(new TextBlock { Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(gr))} · {_engine.Workspace.MatchesToday(gr.Id)}/{gr.MaxDailyMatches} {gr.MatchUnitPlural}", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 4, 0, 0) });
            dock.Children.Add(info);
            PageContent.Children.Add(Card(dock));
        }

        // Tasks for today + inbox
        var todayTasks = _engine.Workspace.Tasks
            .Where(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == _engine.SelectedDate.LocalDateTime.Date)
            .OrderBy(t => t.ScheduledAt)
            .ToList();

        PageContent.Children.Add(new TextBlock { Text = $"Agenda ({todayTasks.Count})", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 6, 0, 8) });
        if (todayTasks.Count == 0)
        {
            PageContent.Children.Add(Card(new TextBlock { Text = "Sin tareas programadas para hoy.", Foreground = BrushHex("#94A3B8") }));
        }
        foreach (var t in todayTasks)
        {
            var dock = new DockPanel();
            var right = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            var start = new System.Windows.Controls.Button { Content = "Iniciar", Background = BrushHex("#64E3A1"), Foreground = BrushHex("#0F1218"), FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 6, 0) };
            start.Click += (_, _) => _engine.StartSession(t);
            var edit = new System.Windows.Controls.Button { Content = "Editar", Margin = new Thickness(0, 0, 6, 0) };
            edit.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, t, this);
            var del = new System.Windows.Controls.Button { Content = "Borrar" };
            del.Click += (_, _) => _engine.DeleteTask(t);
            right.Children.Add(start);
            right.Children.Add(edit);
            right.Children.Add(del);
            DockPanel.SetDock(right, Dock.Right);
            dock.Children.Add(right);

            var left = new StackPanel();
            left.Children.Add(new TextBlock { Text = t.Title, FontSize = 15, FontWeight = FontWeights.SemiBold });
            left.Children.Add(new TextBlock { Text = $"{t.ScheduledAt.LocalDateTime:HH:mm}–{t.End.LocalDateTime:HH:mm} · {t.Minutes} min · {t.Category}", Foreground = BrushHex("#94A3B8"), FontSize = 12 });
            dock.Children.Add(left);
            PageContent.Children.Add(Card(dock));
        }

        var inbox = _engine.Workspace.Tasks.Where(t => !t.Completed && !t.IsScheduled).ToList();
        if (inbox.Count > 0)
        {
            PageContent.Children.Add(new TextBlock { Text = $"Bandeja sin hora ({inbox.Count})", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 8) });
            foreach (var t in inbox)
            {
                var dock = new DockPanel();
                var start = new System.Windows.Controls.Button { Content = "Iniciar", Margin = new Thickness(8, 0, 0, 0) };
                start.Click += (_, _) => _engine.StartSession(t);
                DockPanel.SetDock(start, Dock.Right);
                dock.Children.Add(start);
                dock.Children.Add(new TextBlock { Text = $"{t.Title} · {t.Minutes} min", VerticalAlignment = VerticalAlignment.Center });
                PageContent.Children.Add(Card(dock));
            }
        }
    }

    private void BuildWeekPage()
    {
        PageContent.Children.Add(Header("Semana"));
        var startOfWeek = _engine.SelectedDate.LocalDateTime.Date.AddDays(-(((int)_engine.SelectedDate.LocalDateTime.DayOfWeek + 6) % 7));
        for (var i = 0; i < 7; i++)
        {
            var day = startOfWeek.AddDays(i);
            var dayTasks = _engine.Workspace.Tasks
                .Where(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == day)
                .OrderBy(t => t.ScheduledAt).ToList();
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = day.ToString("dddd d MMM"), FontWeight = FontWeights.SemiBold, Foreground = BrushHex(day == DateTime.Now.Date ? "#64E3A1" : "#F2F5FA") });
            if (dayTasks.Count == 0)
                sp.Children.Add(new TextBlock { Text = "Libre", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 4, 0, 0) });
            foreach (var t in dayTasks)
                sp.Children.Add(new TextBlock { Text = $"• {t.ScheduledAt.LocalDateTime:HH:mm} {t.Title} ({t.Minutes} min)", Foreground = BrushHex("#CBD5E1"), Margin = new Thickness(0, 3, 0, 0) });
            PageContent.Children.Add(Card(sp));
        }
    }

    private void BuildRulesPage()
    {
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var createBtn = new System.Windows.Controls.Button
        {
            Content = "+ Regla personalizada",
            Background = BrushHex("#64E3A1"),
            Foreground = BrushHex("#0F1218"),
            FontWeight = FontWeights.SemiBold
        };
        createBtn.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, null, this);
        DockPanel.SetDock(createBtn, Dock.Right);
        top.Children.Add(createBtn);
        top.Children.Add(new TextBlock { Text = "Reglas y juegos", FontSize = 22, FontWeight = FontWeights.Bold });
        PageContent.Children.Add(top);

        // Game templates gallery
        PageContent.Children.Add(new TextBlock { Text = "Juegos: primero estudio, luego partida", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 2, 0, 8) });
        var wrap = new WrapPanel { Margin = new Thickness(0, 0, 0, 16) };
        foreach (var game in GameCatalog.All)
        {
            var btn = new System.Windows.Controls.Button
            {
                Width = 205,
                Margin = new Thickness(0, 0, 8, 8),
                HorizontalContentAlignment = System.Windows.HorizontalAlignment.Left,
                Padding = new Thickness(12, 10, 12, 10)
            };
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = game.Name, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#F2F5FA") });
            sp.Children.Add(new TextBlock
            {
                Text = game.Detection.IsExact() ? game.Detection.Label() : $"{game.TypicalMatchMinutes} min + prórroga",
                FontSize = 11,
                Foreground = BrushHex("#64E3A1")
            });
            btn.Content = sp;
            btn.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, GeneralBlockRule.GameTemplate(game), this);
            wrap.Children.Add(btn);
        }
        PageContent.Children.Add(wrap);

        PageContent.Children.Add(new TextBlock { Text = $"Tus reglas ({_engine.Workspace.GeneralRules.Count})", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 4, 0, 8) });
        foreach (var rule in _engine.Workspace.GeneralRules)
        {
            var sp = new StackPanel();
            var header = new DockPanel();
            var actions = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };

            if (rule.Kind == GeneralRuleKind.Pomodoro)
            {
                var startP = new System.Windows.Controls.Button { Content = "Iniciar Pomodoro", Margin = new Thickness(0, 0, 6, 0) };
                startP.Click += (_, _) => { rule.StartPomodoro(); _engine.Persist(); };
                actions.Children.Add(startP);
            }
            if (rule.Kind == GeneralRuleKind.Countdown)
            {
                var startC = new System.Windows.Controls.Button { Content = $"Activar {rule.CountdownMinutes}m", Margin = new Thickness(0, 0, 6, 0) };
                startC.Click += (_, _) => { rule.StartCountdown(); _engine.Persist(); };
                actions.Children.Add(startC);
            }

            var toggle = new System.Windows.Controls.Button { Content = rule.Enabled ? "Apagar" : "Activar", Margin = new Thickness(0, 0, 6, 0) };
            toggle.Click += (_, _) =>
            {
                if (rule.Enabled && _engine.IsRuleProtected(rule) &&
                    !Dialogs.RequestUnlock(rule.Protection, rule.UnlockChars, rule.StopDelayMinutes, $"apagar «{rule.Name}»", this))
                    return;
                rule.Enabled = !rule.Enabled;
                _engine.Persist();
            };

            var edit = new System.Windows.Controls.Button { Content = "Editar", Margin = new Thickness(0, 0, 6, 0) };
            edit.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, rule, null, this);

            var del = new System.Windows.Controls.Button { Content = "Borrar" };
            del.Click += (_, _) =>
            {
                if (_engine.IsRuleProtected(rule) &&
                    !Dialogs.RequestUnlock(rule.Protection, rule.UnlockChars, rule.StopDelayMinutes, $"borrar «{rule.Name}»", this))
                    return;
                _engine.DeleteGeneralRule(rule);
            };

            actions.Children.Add(toggle);
            actions.Children.Add(edit);
            actions.Children.Add(del);
            DockPanel.SetDock(actions, Dock.Right);
            header.Children.Add(actions);

            var titleStack = new StackPanel();
            var enforcing = _engine.IsRuleEnforcing(rule);
            titleStack.Children.Add(new TextBlock { Text = rule.Name, FontSize = 15, FontWeight = FontWeights.SemiBold });
            titleStack.Children.Add(new TextBlock
            {
                Text = $"{rule.Kind.GalleryTitle()} · {(enforcing ? "Bloqueando ahora" : rule.Enabled ? "Activa" : "Apagada")} · {rule.Protection.Label()}",
                Foreground = BrushHex(enforcing ? "#64E3A1" : "#94A3B8"),
                FontSize = 12,
                Margin = new Thickness(0, 2, 0, 0)
            });
            header.Children.Add(titleStack);
            sp.Children.Add(header);

            if (rule.Kind == GeneralRuleKind.WorkGoal && rule.MaxDailyMatches > 0)
            {
                var st = _engine.GameRuleStatus(rule);
                var gRow = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
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

            PageContent.Children.Add(Card(sp));
        }
    }

    private void BuildBlockingPage()
    {
        PageContent.Children.Add(Header("Perfiles y bloqueo rápido"));
        foreach (var profile in _engine.Workspace.Profiles)
        {
            var dock = new DockPanel();
            var launch = new System.Windows.Controls.Button
            {
                Content = $"Empezar {profile.Minutes} min",
                Background = BrushHex("#64E3A1"),
                Foreground = BrushHex("#0F1218"),
                FontWeight = FontWeights.SemiBold
            };
            launch.Click += (_, _) =>
            {
                var t = new FocusTask { Title = profile.Name, ScheduledAt = DateTimeOffset.Now };
                t.Apply(profile);
                _engine.SaveTask(t);
                _engine.StartSession(t);
                _engine.ActivePage = "Hoy";
            };
            DockPanel.SetDock(launch, Dock.Right);
            dock.Children.Add(launch);
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = profile.Name, FontSize = 15, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(new TextBlock { Text = $"{profile.Category} · {profile.Minutes} min · {(string.IsNullOrEmpty(profile.Domains) ? "sin lista web" : profile.Domains)}", Foreground = BrushHex("#94A3B8"), FontSize = 12 });
            dock.Children.Add(sp);
            PageContent.Children.Add(Card(dock));
        }
    }

    private void BuildBreaksPage()
    {
        PageContent.Children.Add(Header("Descansos"));
        var s = _engine.Workspace.Settings;
        var sp = new StackPanel();
        var contCheck = new System.Windows.Controls.CheckBox
        {
            Content = $"Descanso continuo de vista ({s.ContinuousWorkMinutes} min de trabajo → {s.ContinuousBreakDurationMinutes} min de descanso)",
            IsChecked = s.ContinuousBreakEnabled,
            Foreground = BrushHex("#F2F5FA")
        };
        contCheck.Click += (_, _) => { s.ContinuousBreakEnabled = contCheck.IsChecked == true; _engine.Persist(); };
        sp.Children.Add(contCheck);
        if (_engine.ActiveContinuousBreakDeadline != null)
        {
            sp.Children.Add(new TextBlock
            {
                Text = $"Descanso activo: {FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot())} · {_engine.ActiveContinuousBreakMessage}",
                Foreground = BrushHex("#64E3A1"),
                Margin = new Thickness(0, 8, 0, 0)
            });
        }
        PageContent.Children.Add(Card(sp));

        foreach (var br in s.Breaks)
        {
            PageContent.Children.Add(Card(new TextBlock { Text = $"{br.Title} · {br.StartHour:D2}:{br.StartMinute:D2} ({br.DurationMinutes} min)" }));
        }
    }

    private void BuildHistoryPage()
    {
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var switchBtn = new System.Windows.Controls.Button { Content = _auditView ? "Ver sesiones" : "Registro de auditoría" };
        switchBtn.Click += (_, _) => { _auditView = !_auditView; RefreshUI(); };
        DockPanel.SetDock(switchBtn, Dock.Right);
        top.Children.Add(switchBtn);
        top.Children.Add(new TextBlock { Text = _auditView ? "Registro de auditoría" : "Historial de sesiones", FontSize = 22, FontWeight = FontWeights.Bold });
        PageContent.Children.Add(top);

        if (_auditView)
        {
            foreach (var item in _engine.Workspace.AuditLog.Take(60))
                PageContent.Children.Add(Card(new TextBlock { Text = $"{item.At.LocalDateTime:g} · [{item.Category}] {item.Summary}", TextWrapping = TextWrapping.Wrap }));
            if (_engine.Workspace.AuditLog.Count == 0)
                PageContent.Children.Add(Card(new TextBlock { Text = "Sin eventos registrados todavía.", Foreground = BrushHex("#94A3B8") }));
            return;
        }

        foreach (var rec in _engine.Workspace.History.Take(50))
        {
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = $"{rec.Session.Task.Title} · {(rec.Completed ? "Completada" : rec.Cancelled ? "Cancelada" : "Pendiente")}", FontWeight = FontWeights.SemiBold });
            sp.Children.Add(new TextBlock { Text = $"{rec.Session.StartedAt.LocalDateTime:g} · Trabajado: {FocusRules.Clock(rec.Session.Elapsed(rec.Session.EndedAt ?? rec.Session.StartedAt))} · Interrupciones: {rec.Session.InterruptionCount}", Foreground = BrushHex("#94A3B8"), FontSize = 12 });
            PageContent.Children.Add(Card(sp));
        }
        if (_engine.Workspace.History.Count == 0)
            PageContent.Children.Add(Card(new TextBlock { Text = "Todavía no has completado ninguna sesión.", Foreground = BrushHex("#94A3B8") }));
    }

    private void BuildSettingsPage()
    {
        PageContent.Children.Add(Header("Ajustes"));

        // Protection & watcher
        var guardPanel = new StackPanel();
        guardPanel.Children.Add(new TextBlock { Text = "Protección en Windows", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 8) });
        var guardCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Vigilante de relanzado (--watcher al iniciar Windows: vuelve a abrir FocusDesk si se cierra a la fuerza durante una regla/sesión protegida)",
            IsChecked = _engine.Workspace.Settings.RelaunchGuard,
            Foreground = BrushHex("#F2F5FA")
        };
        guardCheck.Click += (_, _) => _engine.SetRelaunchGuard(guardCheck.IsChecked == true);
        guardPanel.Children.Add(guardCheck);

        var clipCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Proteger portapapeles (limpia comandos taskkill / enlaces bloqueados)",
            IsChecked = _engine.Workspace.Settings.ProtectClipboard,
            Foreground = BrushHex("#F2F5FA"),
            Margin = new Thickness(0, 6, 0, 0)
        };
        clipCheck.Click += (_, _) => { _engine.Workspace.Settings.ProtectClipboard = clipCheck.IsChecked == true; _engine.Persist(); };
        guardPanel.Children.Add(clipCheck);

        var quitBtn = new System.Windows.Controls.Button { Content = "Salir de FocusDesk", Margin = new Thickness(0, 12, 0, 0), HorizontalAlignment = System.Windows.HorizontalAlignment.Left };
        quitBtn.Click += (_, _) => _onQuitRequested();
        guardPanel.Children.Add(quitBtn);
        PageContent.Children.Add(Card(guardPanel));

        // Study sources
        var studyPanel = new StackPanel();
        studyPanel.Children.Add(new TextBlock { Text = "Qué cuenta como estudio activo", FontSize = 15, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 6) });
        studyPanel.Children.Add(new TextBlock { Text = "Lo que añadas hoy empieza a contar mañana para evitar atajos de último minuto.", Foreground = BrushHex("#94A3B8"), FontSize = 12, Margin = new Thickness(0, 0, 0, 8) });

        var addRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        var webInput = new System.Windows.Controls.TextBox { Width = 220, Background = BrushHex("#1F2631"), Foreground = BrushHex("#F2F5FA"), BorderBrush = BrushHex("#283140"), Padding = new Thickness(6), Margin = new Thickness(0, 0, 8, 0) };
        var addWebBtn = new System.Windows.Controls.Button { Content = "Añadir web", Margin = new Thickness(0, 0, 12, 0) };
        addWebBtn.Click += (_, _) => { _engine.AddStudyWeb(webInput.Text); webInput.Text = ""; };
        var appInput = new System.Windows.Controls.TextBox { Width = 160, Background = BrushHex("#1F2631"), Foreground = BrushHex("#F2F5FA"), BorderBrush = BrushHex("#283140"), Padding = new Thickness(6), Margin = new Thickness(0, 0, 8, 0) };
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
            var pill = new System.Windows.Controls.Button { Content = $"{src.Name} ({src.Kind}) ×", Margin = new Thickness(0, 0, 6, 6), Padding = new Thickness(8, 4, 8, 4) };
            pill.Click += (_, _) => _engine.RemoveStudySource(src);
            wrap.Children.Add(pill);
        }
        studyPanel.Children.Add(wrap);
        PageContent.Children.Add(Card(studyPanel));

        // Backups
        var backupRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var expBtn = new System.Windows.Controls.Button { Content = "Exportar copia (.json)", Margin = new Thickness(0, 0, 8, 0) };
        expBtn.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { FileName = "FocusDesk-backup.json", Filter = "JSON (*.json)|*.json" };
            if (dlg.ShowDialog() == true) _engine.ExportBackup(dlg.FileName);
        };
        var impBtn = new System.Windows.Controls.Button { Content = "Importar copia (.json)" };
        impBtn.Click += (_, _) =>
        {
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "JSON (*.json)|*.json" };
            if (dlg.ShowDialog() == true) _engine.ImportBackup(dlg.FileName);
        };
        backupRow.Children.Add(expBtn);
        backupRow.Children.Add(impBtn);
        PageContent.Children.Add(Card(backupRow));
    }
}
