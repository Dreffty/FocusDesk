using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using FocusDesk.Windows.Core;

namespace FocusDesk.Windows.UI;

/// <summary>
/// The frame around every page, drawn like FocusDesk for macOS: the sidebar sections with their icons and counters,
/// the running-session card, and the fixed page header (date in small capitals + one headline).
/// </summary>
public partial class MainWindow
{
    private const string IconFont = "Segoe Fluent Icons, Segoe MDL2 Assets";
    private static readonly System.Globalization.CultureInfo Spanish = new("es-ES");

    /// <summary>The same headlines as the Mac app (DesignSystem.swift › headline).</summary>
    private static readonly Dictionary<string, string> Headlines = new()
    {
        ["Hoy"] = "Haz espacio para lo importante.",
        ["Semana"] = "Una semana con intención.",
        ["Historial"] = "Lo que has hecho cuenta.",
        ["Bloquear"] = "Corta las distracciones ahora mismo.",
        ["Reglas"] = "Tus límites, también fuera de las tareas.",
        ["Descansos"] = "Descansa antes de necesitarlo.",
        ["Ajustes"] = "A tu manera."
    };

    private sealed record NavItem(string Tag, System.Windows.Controls.Button Button, TextBlock Icon, TextBlock Label, Border Badge, TextBlock BadgeText);
    private readonly List<NavItem> _navItems = new();

    /// <summary>Per-second refresh of whatever the current page shows live (e.g. the continuous-use counter).</summary>
    private Action<DateTimeOffset>? _livePageTick;

    /// <summary>Small capitals with the wide letter spacing of the Mac labels (WPF has no tracking for TextBlock).</summary>
    private static string Spaced(string text) =>
        string.Join(" ", text.ToUpper(Spanish).Replace(" ", " ").ToCharArray().Select(c => c.ToString()));

    private static TextBlock SidebarSection(string text, double top) => new()
    {
        Text = Spaced(text),
        FontSize = 10.5,
        FontWeight = FontWeights.SemiBold,
        Foreground = BrushHex("#7C868C"),
        Margin = new Thickness(10, top, 0, 6)
    };

    private void BuildNavigation()
    {
        NavStack.Children.Clear();
        _navItems.Clear();
        NavStack.Children.Add(SidebarSection("Agenda", 0));
        AddNav("Hoy", "Hoy", "");
        AddNav("Semana", "Semana", "");
        AddNav("Historial", "Historial", "");
        NavStack.Children.Add(SidebarSection("Antidistracción", 16));
        AddNav("Bloquear", "Bloquear ahora", "");
        AddNav("Reglas", "Reglas y límites", "");
        AddNav("Descansos", "Descansos", "");
        NavStack.Children.Add(new Border { Height = 1, Background = BrushHex("#1C1F24"), Margin = new Thickness(8, 12, 8, 8) });
        AddNav("Ajustes", "Ajustes", "");
    }

    private void AddNav(string tag, string label, string glyph)
    {
        var icon = new TextBlock
        {
            Text = glyph,
            FontFamily = new System.Windows.Media.FontFamily(IconFont),
            FontSize = 15,
            Width = 22,
            VerticalAlignment = VerticalAlignment.Center
        };
        var text = new TextBlock { Text = label, FontSize = 14, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 6, 0) };
        var badgeText = new TextBlock { FontSize = 11, FontWeight = FontWeights.SemiBold };
        var badge = new Border
        {
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(6, 1, 6, 1),
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            Child = badgeText
        };
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(text, 1);
        Grid.SetColumn(badge, 2);
        grid.Children.Add(icon);
        grid.Children.Add(text);
        grid.Children.Add(badge);

        var button = new System.Windows.Controls.Button
        {
            Tag = tag,
            Content = grid,
            Padding = new Thickness(10, 0, 8, 0),
            MinHeight = 38,
            Margin = new Thickness(0, 1, 0, 1),
            HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent
        };
        button.Click += NavClick;
        var item = new NavItem(tag, button, icon, text, badge, badgeText);
        button.MouseEnter += (_, _) => { if (!IsActive(item)) button.Background = BrushHex("#14171C"); };
        button.MouseLeave += (_, _) => { if (!IsActive(item)) button.Background = System.Windows.Media.Brushes.Transparent; };
        _navItems.Add(item);
        NavStack.Children.Add(button);
    }

    private bool IsActive(NavItem item) => string.Equals(item.Tag, _engine.ActivePage, StringComparison.Ordinal);

    /// <summary>The section in view: a soft green tint with green text and icon, as on the Mac.</summary>
    private void UpdateNav()
    {
        foreach (var item in _navItems)
        {
            var active = IsActive(item);
            item.Button.Background = active ? BrushHex("#15291F") : System.Windows.Media.Brushes.Transparent;
            item.Label.Foreground = BrushHex(active ? "#38A169" : "#D5DBDF");
            item.Label.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
            item.Icon.Foreground = BrushHex(active ? "#38A169" : "#99A6AD");
        }
    }

    /// <summary>Counters next to the sections: overdue tasks, the quick block's countdown, rules blocking now.</summary>
    private void UpdateNavBadges(DateTimeOffset now)
    {
        foreach (var item in _navItems)
        {
            string? text = null;
            string fg = "#38A169", bg = "Transparent";
            switch (item.Tag)
            {
                case "Hoy":
                    var overdue = _engine.Workspace.Tasks.Count(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date < now.LocalDateTime.Date);
                    if (overdue > 0) { text = overdue.ToString(); fg = "#FAC74D"; bg = "#2E2614"; }
                    break;
                case "Bloquear":
                    var quick = _engine.Workspace.GeneralRules.FirstOrDefault(r => r.Enabled && r.Kind == GeneralRuleKind.Countdown &&
                        r.Name.StartsWith("Bloqueo rápido", StringComparison.OrdinalIgnoreCase) && r.ActiveDeadline != null);
                    var left = quick?.ActiveDeadline?.RemainingAfterPossibleReboot(now) ?? 0;
                    if (left > 0) text = FocusRules.Clock(left);
                    break;
                case "Reglas":
                    var blocking = _engine.Workspace.GeneralRules.Count(r => r.Enabled && _engine.IsRuleEnforcing(r, now));
                    if (blocking > 0) { text = blocking.ToString(); bg = "#15291F"; }
                    break;
            }
            item.Badge.Visibility = text == null ? Visibility.Collapsed : Visibility.Visible;
            if (text == null) continue;
            item.BadgeText.Text = text;
            item.BadgeText.Foreground = BrushHex(fg);
            item.Badge.Background = BrushHex(bg);
        }
    }

    /// <summary>The «En sesión» card of the sidebar: task, phase, time left and the three controls.</summary>
    private void UpdateSidebarSession(DateTimeOffset now)
    {
        if (_engine.Workspace.Session is not { EndedAt: null } s)
        {
            SidebarSessionCard.Visibility = Visibility.Collapsed;
            return;
        }
        SidebarSessionCard.Visibility = Visibility.Visible;
        SidebarSessionState.Text = Spaced(s.Paused ? "En pausa" : "En sesión");
        SidebarSessionTitle.Text = s.Task.Title;
        SidebarSessionClock.Text = FocusRules.Clock(Math.Max(0, s.Remaining(now)));
        SidebarSessionClock.Foreground = BrushHex(s.Paused ? "#99A6AD" : "#38A169");
        SidebarPauseGlyph.Text = s.Paused ? "" : "";
        if (!s.Paused && s.Task.PomodoroPhase(s.Elapsed(now)) is { } phase)
        {
            SidebarSessionPhaseChip.Visibility = Visibility.Visible;
            SidebarSessionPhase.Text = $"{phase.Label} {phase.Cycle} · {FocusRules.Clock(phase.RemainingInPhase)}";
        }
        else SidebarSessionPhaseChip.Visibility = Visibility.Collapsed;
    }

    private void SearchClick(object sender, RoutedEventArgs e) => ShowCommandPalette();

    private void SidebarNewTaskClick(object sender, RoutedEventArgs e) => Dialogs.ShowTaskEditor(_engine, null, this);

    private void SidebarOpenSessionClick(object sender, RoutedEventArgs e) => _engine.ActivePage = "Hoy";

    private void SidebarAddTimeClick(object sender, RoutedEventArgs e) => _engine.AddSessionMinutes(10);

    private void SidebarPauseClick(object sender, RoutedEventArgs e)
    {
        if (_engine.Workspace.Session is not { EndedAt: null } s) return;
        if (s.Paused) { _engine.ResumeSession(); return; }
        if (s.Task.Protection != SessionProtection.None && s.Remaining(DateTimeOffset.Now) > 0 &&
            !Dialogs.RequestSessionStop("pausar", s, this)) return;
        _engine.PauseSession();
    }

    private void SidebarFinishClick(object sender, RoutedEventArgs e)
    {
        if (_engine.Workspace.Session is not { EndedAt: null } s) return;
        if (!Dialogs.RequestSessionStop("terminar antes", s, this)) return;
        _engine.FinishSession();
    }

    /// <summary>
    /// The page header lives above the scrolling page, as on the Mac: the date in small capitals, one headline, and the
    /// page's actions on the right (they drop below the headline when the window is too narrow for both).
    /// Returns an empty placeholder for the page itself.
    /// </summary>
    private UIElement PageHeader(string title, string subtitle, UIElement? trailingButton = null)
    {
        var page = _engine.ActivePage;
        string eyebrow = page switch
        {
            "Hoy" => _engine.SelectedDate.LocalDateTime.ToString("dddd, d 'de' MMMM", Spanish),
            "Semana" => "Semana · " + (subtitle.Contains(". ") ? subtitle[..subtitle.IndexOf(". ", StringComparison.Ordinal)] : subtitle),
            _ => DateTime.Now.ToString("dddd, d 'de' MMMM", Spanish)
        };
        var headline = Headlines.TryGetValue(page, out var h) ? h : subtitle;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(new TextBlock { Text = Spaced(eyebrow), FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#99A6AD") });
        stack.Children.Add(new TextBlock
        {
            Text = headline,
            FontSize = 25,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#EDF2F5"),
            FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI"),
            Margin = new Thickness(0, 4, 0, 0),
            TextWrapping = TextWrapping.Wrap
        });
        grid.Children.Add(stack);

        if (trailingButton is FrameworkElement trailing)
        {
            if (trailing is StackPanel row && row.Orientation == System.Windows.Controls.Orientation.Horizontal)
            {
                var wrap = new WrapPanel();
                var kids = row.Children.Cast<UIElement>().ToList();
                row.Children.Clear();
                foreach (var kid in kids) wrap.Children.Add(kid);
                trailing = wrap;
            }
            grid.Children.Add(trailing);
            void Relayout()
            {
                var unbounded = new System.Windows.Size(double.PositiveInfinity, double.PositiveInfinity);
                stack.Measure(unbounded);
                trailing.Measure(unbounded);
                var fits = grid.ActualWidth <= 0 || stack.DesiredSize.Width + trailing.DesiredSize.Width + 24 <= grid.ActualWidth;
                Grid.SetRow(trailing, fits ? 0 : 1);
                Grid.SetColumn(trailing, fits ? 1 : 0);
                Grid.SetColumnSpan(trailing, fits ? 1 : 2);
                trailing.HorizontalAlignment = fits ? System.Windows.HorizontalAlignment.Right : System.Windows.HorizontalAlignment.Left;
                trailing.VerticalAlignment = VerticalAlignment.Center;
                trailing.Margin = fits ? new Thickness(0) : new Thickness(0, 12, 0, 0);
            }
            grid.SizeChanged += (_, _) => Relayout();
            grid.Loaded += (_, _) => Relayout();
            Relayout();
        }
        HeaderHost.Content = grid;
        return new Border { Height = 0 };
    }
}
