using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FocusDesk.Windows.Core;

namespace FocusDesk.Windows.UI;

/// <summary>
/// The small panel that opens from the notification-area icon: the menu-bar panel of FocusDesk for macOS. The running
/// session with its clock and controls, what comes next, the rules that are blocking, a quick block and a box to jot
/// a task down, without opening the whole window.
/// </summary>
public sealed class TrayPanel : Window
{
    private const string IconFont = "Segoe Fluent Icons, Segoe MDL2 Assets";
    private readonly AppEngine _engine;
    private readonly Action _showMain;
    private readonly Action<string> _openPage;
    private readonly Action _openSearch;
    private readonly Action _quit;
    private readonly Func<MainWindow?> _main;
    private readonly StackPanel _root = new() { Margin = new Thickness(18) };
    private TextBlock? _clock;
    private bool _closing;
    private string _shapeKey = "";

    public TrayPanel(AppEngine engine, Action showMain, Action<string> openPage, Action openSearch, Action quit, Func<MainWindow?> main)
    {
        _engine = engine;
        _showMain = showMain;
        _openPage = openPage;
        _openSearch = openSearch;
        _quit = quit;
        _main = main;

        Title = "FocusDesk";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Foreground = Brush("#EDF2F5");
        FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Text, Segoe UI");
        Content = new Border
        {
            Background = Brush("#0D1014"),
            BorderBrush = Brush("#2A2E34"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Child = _root
        };

        Build();
        _engine.TickUpdated += OnTick;
        _engine.StateRefreshed += OnState;
        Loaded += (_, _) => Place();
        SizeChanged += (_, _) => Place();
        Deactivated += (_, _) => CloseOnce();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) CloseOnce(); };
        Closed += (_, _) =>
        {
            _engine.TickUpdated -= OnTick;
            _engine.StateRefreshed -= OnState;
        };
    }

    private void CloseOnce()
    {
        if (_closing) return;
        _closing = true;
        try { Close(); } catch { }
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        _closing = true;
        base.OnClosing(e);
    }

    /// <summary>Bottom-right corner of the work area, just above the notification area.</summary>
    private void Place()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
    }

    private static SolidColorBrush Brush(string hex) =>
        new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));

    private static TextBlock Glyph(string glyph, double size, string color) => new()
    {
        Text = glyph,
        FontFamily = new System.Windows.Media.FontFamily(IconFont),
        FontSize = size,
        Foreground = Brush(color),
        VerticalAlignment = VerticalAlignment.Center
    };

    private static System.Windows.Controls.Button Labelled(string glyph, string label, Action onClick, bool primary = false, bool plain = false)
    {
        var fg = primary ? "#0D1014" : "#EDF2F5";
        var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        if (glyph.Length > 0)
        {
            var g = Glyph(glyph, 13.5, fg);
            g.Margin = new Thickness(0, 0, label.Length > 0 ? 8 : 0, 0);
            row.Children.Add(g);
        }
        if (label.Length > 0)
            row.Children.Add(new TextBlock { Text = label, FontSize = 14.5, FontWeight = FontWeights.SemiBold, Foreground = Brush(fg), VerticalAlignment = VerticalAlignment.Center });
        var button = new System.Windows.Controls.Button { Content = row, Padding = new Thickness(12, 0, 12, 0), MinHeight = 36, Margin = new Thickness(0, 0, 6, 6) };
        if (primary)
        {
            button.Background = Brush("#38A169");
            button.BorderBrush = Brush("#38A169");
        }
        else if (plain)
        {
            button.Background = System.Windows.Media.Brushes.Transparent;
            button.BorderBrush = System.Windows.Media.Brushes.Transparent;
        }
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>Anything that may need the code dialog runs from the main window, which stays open behind it.</summary>
    private void InMain(Action<MainWindow> act)
    {
        CloseOnce();
        _showMain();
        if (_main() is { } window) act(window);
    }

    private string ShapeKey()
    {
        var s = _engine.Workspace.Session;
        var now = DateTimeOffset.Now;
        var rules = string.Join(",", _engine.Workspace.GeneralRules.Where(r => _engine.IsRuleEnforcing(r, now)).Select(r => r.Id));
        return $"{s?.Id}|{s?.Paused}|{s?.EndedAt != null}|{_engine.NextTask(now)?.Id}|{rules}";
    }

    private void OnState() => Dispatcher.BeginInvoke(() => { if (!_closing) Build(); });

    private void OnTick() => Dispatcher.BeginInvoke(() =>
    {
        if (_closing) return;
        if (ShapeKey() != _shapeKey) { Build(); return; }
        if (_clock != null && _engine.Workspace.Session is { EndedAt: null } s)
            _clock.Text = s.Paused ? "En pausa" : FocusRules.Clock(Math.Max(0, s.Remaining(DateTimeOffset.Now)));
    });

    private void Build()
    {
        _shapeKey = ShapeKey();
        _clock = null;
        _root.Children.Clear();
        var now = DateTimeOffset.Now;

        // Header: the logo, the name and «open the window»
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 14) };
        var open = new System.Windows.Controls.Button { Content = Glyph("", 13, "#D5DBDF"), Width = 34, MinHeight = 32, Padding = new Thickness(0), ToolTip = "Abrir FocusDesk" };
        open.Click += (_, _) => { CloseOnce(); _showMain(); };
        DockPanel.SetDock(open, Dock.Right);
        header.Children.Add(open);
        var logo = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(8), Background = Brush("#38A169"), Child = Glyph("", 15, "#0D1014") };
        ((TextBlock)logo.Child).HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        DockPanel.SetDock(logo, Dock.Left);
        header.Children.Add(logo);
        header.Children.Add(new TextBlock { Text = "FocusDesk", FontSize = 17, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(11, 0, 0, 0) });
        _root.Children.Add(header);

        var next = _engine.NextTask(now);
        if (_engine.Workspace.Session is { } s)
        {
            _root.Children.Add(new TextBlock { Text = s.Task.Title, FontSize = 19, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            if (s.EndedAt != null)
            {
                _root.Children.Add(new TextBlock { Text = "Sesión terminada · confirma el resultado", FontSize = 13.5, Foreground = Brush("#FAC74D"), Margin = new Thickness(0, 6, 0, 10) });
                var confirm = Labelled("", "Confirmar el resultado…", () => InMain(w => w.RequestFinish()), primary: true);
                confirm.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
                _root.Children.Add(confirm);
            }
            else
            {
                var remaining = Math.Max(0, s.Remaining(now));
                _clock = new TextBlock
                {
                    Text = s.Paused ? "En pausa" : FocusRules.Clock(remaining),
                    FontSize = 44,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = Brush(s.Paused ? "#99A6AD" : "#38A169"),
                    FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
                    Margin = new Thickness(0, 6, 0, 10)
                };
                _root.Children.Add(_clock);
                var controls = new WrapPanel();
                controls.Children.Add(Labelled("", "He terminado", () => InMain(w => w.RequestFinish()), primary: true));
                controls.Children.Add(Labelled(s.Paused ? "" : "", s.Paused ? "Reanudar" : "Pausar", () =>
                {
                    if (s.Paused) _engine.ResumeSession(); else InMain(w => w.RequestPauseResume());
                }));
                controls.Children.Add(Labelled("", "10", () => _engine.AddSessionMinutes(10), plain: true));
                var cancel = Labelled("", "", () => InMain(w => w.RequestCancelSession()));
                cancel.ToolTip = "Cancelar la sesión sin completar la tarea";
                cancel.Background = Brush("#2A161B");
                cancel.BorderBrush = Brush("#2A161B");
                ((TextBlock)((StackPanel)cancel.Content).Children[0]).Foreground = Brush("#FF8080");
                controls.Children.Add(cancel);
                _root.Children.Add(controls);
                if (!s.Paused)
                    _root.Children.Add(new TextBlock { Text = $"Termina a las {DateTime.Now.AddSeconds(remaining):H:mm}", FontSize = 13, Foreground = Brush("#99A6AD"), Margin = new Thickness(0, 12, 0, 0) });
            }
            if (next != null)
                _root.Children.Add(new TextBlock
                {
                    Text = $"Después: {next.Title}{(next.IsScheduled ? " · " + next.ScheduledAt.LocalDateTime.ToString("H:mm") : "")}",
                    FontSize = 13,
                    Foreground = Brush("#99A6AD"),
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    Margin = new Thickness(0, 8, 0, 0)
                });
        }
        else if (next != null)
        {
            _root.Children.Add(new TextBlock { Text = "TU SIGUIENTE PASO", FontSize = 11.5, FontWeight = FontWeights.Bold, Foreground = Brush("#38A169") });
            _root.Children.Add(new TextBlock { Text = next.Title, FontSize = 19, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 5, 0, 3) });
            _root.Children.Add(new TextBlock
            {
                Text = $"{FocusRules.DurationText(next.Minutes)} · {(next.IsScheduled ? next.ScheduledAt.LocalDateTime.ToString("H:mm") : "sin hora")}",
                FontSize = 13,
                Foreground = Brush("#99A6AD"),
                Margin = new Thickness(0, 0, 0, 10)
            });
            var row = new WrapPanel();
            row.Children.Add(Labelled("", "Empezar", () => InMain(w => w.RequestStart(next)), primary: true));
            row.Children.Add(Labelled("", "Posponer 10 min", () => _engine.SnoozeTask(next, 10)));
            _root.Children.Add(row);
        }
        else
        {
            _root.Children.Add(new TextBlock { Text = "Tu agenda tiene espacio.", FontSize = 19, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 0, 0, 10) });
            var plan = Labelled("", "Planificar una tarea", () => InMain(w => w.RequestNewTask()), primary: true);
            plan.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            _root.Children.Add(plan);
        }

        // Rules that are blocking now, with what is left of the ones that count down
        var enforcing = _engine.Workspace.GeneralRules.Where(r => _engine.IsRuleEnforcing(r, now)).Take(4).ToList();
        if (enforcing.Count > 0)
        {
            var list = new StackPanel { Margin = new Thickness(0, 14, 0, 0) };
            foreach (var rule in enforcing)
            {
                var line = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                var left = rule.Kind == GeneralRuleKind.Countdown ? rule.ActiveDeadline?.RemainingAfterPossibleReboot(now) ?? 0
                    : rule.Kind == GeneralRuleKind.Pomodoro ? rule.ActivePomodoroDeadline?.RemainingAfterPossibleReboot(now) ?? 0
                    : 0;
                if (left > 0)
                {
                    var time = new TextBlock { Text = FocusRules.Clock(left), FontSize = 13.5, Foreground = Brush("#38A169"), FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center };
                    DockPanel.SetDock(time, Dock.Right);
                    line.Children.Add(time);
                }
                var shield = Glyph("", 13, "#38A169");
                shield.Margin = new Thickness(0, 0, 9, 0);
                DockPanel.SetDock(shield, Dock.Left);
                line.Children.Add(shield);
                line.Children.Add(new TextBlock { Text = rule.Name, FontSize = 14.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center });
                list.Children.Add(line);
            }
            _root.Children.Add(list);
        }

        // Quick block
        var quick = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        quick.Children.Add(new TextBlock { Text = "Bloqueo rápido:", FontSize = 13.5, Foreground = Brush("#99A6AD"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        foreach (var (minutes, label) in new[] { (15, "15m"), (30, "30m"), (60, "1 h") })
        {
            var captured = minutes;
            quick.Children.Add(Labelled("", label, () => InMain(w => w.RequestQuickBlock(captured))));
        }
        _root.Children.Add(quick);

        // Jot something down for later
        var capture = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        var tray = Glyph("", 15, "#99A6AD");
        tray.Margin = new Thickness(2, 0, 10, 0);
        DockPanel.SetDock(tray, Dock.Left);
        capture.Children.Add(tray);
        var box = new System.Windows.Controls.TextBox { ToolTip = "Apuntar en la bandeja: escribe y pulsa Intro" };
        var hint = new TextBlock { Text = "Apuntar en la bandeja…", Foreground = Brush("#7C868C"), FontSize = 14.5, Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false };
        box.TextChanged += (_, _) => hint.Visibility = string.IsNullOrEmpty(box.Text) ? Visibility.Visible : Visibility.Collapsed;
        box.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || string.IsNullOrWhiteSpace(box.Text)) return;
            _engine.QuickCapture(box.Text);
            box.Text = "";
            e.Handled = true;
        };
        var boxHost = new Grid();
        boxHost.Children.Add(box);
        boxHost.Children.Add(hint);
        capture.Children.Add(boxHost);
        _root.Children.Add(capture);

        // Footer
        _root.Children.Add(new Border { Height = 1, Background = Brush("#262A30"), Margin = new Thickness(0, 14, 0, 8) });
        var footer = new Grid();
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var planner = Labelled("", "Planificador", () => { CloseOnce(); _openPage("Hoy"); }, plain: true);
        var rulesButton = Labelled("", "Reglas", () => { CloseOnce(); _openPage("Reglas"); }, plain: true);
        var search = Labelled("", "", () => { CloseOnce(); _openSearch(); }, plain: true);
        search.ToolTip = "Buscar función (Ctrl+K)";
        var exit = Labelled("", "Salir", () => { CloseOnce(); _quit(); }, plain: true);
        exit.ToolTip = "Salir de FocusDesk (pausa la sesión activa)";
        Grid.SetColumn(rulesButton, 1);
        Grid.SetColumn(search, 2);
        Grid.SetColumn(exit, 3);
        foreach (var b in new[] { planner, rulesButton, search, exit })
        {
            b.Margin = new Thickness(0);
            b.Padding = new Thickness(8, 0, 8, 0);
            b.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            footer.Children.Add(b);
        }
        _root.Children.Add(footer);
    }
}
