using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using FocusDesk.Windows.Core;

namespace FocusDesk.Windows.UI;

/// <summary>
/// The building blocks of the macOS look, so every page is made of the same pieces as on the Mac: chips, icon
/// buttons, group cards with a small-capitals title, inner rows, and the ring that counts down a session.
/// </summary>
public partial class MainWindow
{
    private static TextBlock Glyph(string glyph, double size = 14, string color = "#99A6AD") => new()
    {
        Text = glyph,
        FontFamily = new System.Windows.Media.FontFamily(IconFont),
        FontSize = size,
        Foreground = BrushHex(color),
        VerticalAlignment = VerticalAlignment.Center
    };

    /// <summary>A rounded label («Contenido», «Foco · bloque 1», «Bloqueando ahora»), optionally with an icon.</summary>
    private static Border Chip(string text, string fg = "#99A6AD", string bg = "#1D2229", string? glyph = null)
    {
        var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        if (glyph != null)
        {
            var g = Glyph(glyph, 13, fg);
            g.Margin = new Thickness(0, 0, 7, 0);
            row.Children.Add(g);
        }
        row.Children.Add(new TextBlock { Text = text, FontSize = 13.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(fg), VerticalAlignment = VerticalAlignment.Center });
        return new Border
        {
            Background = BrushHex(bg),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(11, 5, 11, 5),
            Margin = new Thickness(0, 0, 6, 6),
            Child = row
        };
    }

    /// <summary>Square icon button (▶, ⟲, ⋯, ✕…) like the ones on the Mac rows.</summary>
    private static System.Windows.Controls.Button IconButton(string glyph, string tooltip, Action onClick, string fg = "#D5DBDF", string bg = "#1D2229")
    {
        var button = new System.Windows.Controls.Button
        {
            Content = Glyph(glyph, 15, fg),
            ToolTip = tooltip,
            Width = 40,
            MinHeight = 38,
            Padding = new Thickness(0),
            Margin = new Thickness(6, 0, 0, 0),
            Background = BrushHex(bg),
            BorderBrush = BrushHex(bg)
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>A button with an icon and a label: «+ Nueva tarea», «✓ He terminado», «‖ Pausar».</summary>
    private static System.Windows.Controls.Button GlyphButton(string glyph, string label, Action onClick, bool primary = false, bool plain = false)
    {
        var fg = primary ? "#0D1014" : "#EDF2F5";
        var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var g = Glyph(glyph, 15, fg);
        g.Margin = new Thickness(0, 0, 9, 0);
        row.Children.Add(g);
        row.Children.Add(new TextBlock { Text = label, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(fg), VerticalAlignment = VerticalAlignment.Center });
        var button = new System.Windows.Controls.Button
        {
            Content = row,
            Padding = new Thickness(18, 0, 18, 0),
            MinHeight = 40,
            Margin = new Thickness(0, 0, 8, 0)
        };
        if (primary)
        {
            button.Background = BrushHex("#38A169");
            button.BorderBrush = BrushHex("#38A169");
        }
        else if (plain)
        {
            button.Background = System.Windows.Media.Brushes.Transparent;
            button.BorderBrush = System.Windows.Media.Brushes.Transparent;
        }
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>A card whose first line is an icon and a small-capitals title (the Mac «ANTIDISTRACCIÓN HOY», «POR HORAS»…).</summary>
    private Border GroupCard(string title, string glyph, UIElement content, string titleColor = "#99A6AD", UIElement? trailing = null, string? accentBorder = null)
    {
        var stack = new StackPanel();
        var head = new DockPanel { Margin = new Thickness(0, 0, 0, 12), LastChildFill = true };
        if (trailing != null)
        {
            DockPanel.SetDock(trailing, Dock.Right);
            head.Children.Add(trailing);
        }
        // Icon + title in two columns so a long title wraps inside a narrow card instead of being cut off.
        var titleRow = new Grid { VerticalAlignment = VerticalAlignment.Center };
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var g = Glyph(glyph, 17, titleColor == "#99A6AD" ? "#38A169" : titleColor);
        g.Margin = new Thickness(0, 0, 12, 0);
        titleRow.Children.Add(g);
        // 14.5 bold capitals in a bright grey: clearly above the 13.5 descriptions and chips below it.
        var titleText = new TextBlock { Text = Spaced(title), FontSize = 14.5, FontWeight = FontWeights.Bold, Foreground = BrushHex(titleColor == "#99A6AD" ? "#C9D1D6" : titleColor), VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        Grid.SetColumn(titleText, 1);
        titleRow.Children.Add(titleText);
        head.Children.Add(titleRow);
        stack.Children.Add(head);
        stack.Children.Add(content);
        return Card(stack, accentBorder);
    }

    /// <summary>A rounded row inside a card (a task of the agenda, a rule), a shade lighter than the card.</summary>
    private static Border InnerRow(UIElement child, double bottom = 8) => new()
    {
        Background = BrushHex("#1A1E24"),
        BorderBrush = BrushHex("#2A2E34"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(12),
        Padding = new Thickness(18, 14, 16, 14),
        Margin = new Thickness(0, 0, 0, bottom),
        Child = child
    };

    /// <summary>The colour of an area («Trabajo», «Estudio»…), as chosen in the categories.</summary>
    private string CategoryHex(string name)
    {
        var c = _engine.Workspace.Settings.Categories.FirstOrDefault(x => string.Equals(x.Name, name, StringComparison.OrdinalIgnoreCase));
        if (c == null) return "#99A6AD";
        static int B(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255);
        return $"#{B(c.Red):X2}{B(c.Green):X2}{B(c.Blue):X2}";
    }

    /// <summary>The countdown ring of the running session (time left in the middle, «RESTANTE» under it).</summary>
    private (Grid View, Action<double, string, bool> Update) SessionRing(double size = 150)
    {
        const double thickness = 8;
        var radius = (size - thickness) / 2;
        var grid = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
        grid.Children.Add(new Ellipse { Stroke = BrushHex("#1D2229"), StrokeThickness = thickness });
        var arc = new System.Windows.Shapes.Path
        {
            Stroke = BrushHex("#38A169"),
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round
        };
        grid.Children.Add(arc);
        var center = new StackPanel { HorizontalAlignment = System.Windows.HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var time = new TextBlock
        {
            FontSize = 30,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#38A169"),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Center,
            FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI")
        };
        center.Children.Add(time);
        center.Children.Add(new TextBlock { Text = Spaced("Restante"), FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#99A6AD"), HorizontalAlignment = System.Windows.HorizontalAlignment.Center });
        grid.Children.Add(center);

        void Update(double fraction, string text, bool paused)
        {
            time.Text = text;
            time.Foreground = BrushHex(paused ? "#99A6AD" : "#38A169");
            arc.Stroke = BrushHex(paused ? "#4A5058" : "#38A169");
            var f = Math.Clamp(fraction, 0, 1);
            var c = size / 2;
            if (f >= 0.999)
            {
                arc.Data = new EllipseGeometry(new System.Windows.Point(c, c), radius, radius);
                return;
            }
            if (f <= 0.001) { arc.Data = Geometry.Empty; return; }
            var angle = f * 2 * Math.PI;
            var start = new System.Windows.Point(c, c - radius);
            var end = new System.Windows.Point(c + radius * Math.Sin(angle), c - radius * Math.Cos(angle));
            var figure = new PathFigure { StartPoint = start, IsClosed = false };
            figure.Segments.Add(new ArcSegment(end, new System.Windows.Size(radius, radius), 0, f > 0.5, SweepDirection.Clockwise, true));
            arc.Data = new PathGeometry(new[] { figure });
        }
        return (grid, Update);
    }

    /// <summary>One task as the Mac draws it: hour and length on the left, the area's colour bar, title with chips,
    /// and round actions (start, postpone, more) on the right.</summary>
    private Border MacTaskRow(FocusTask t, bool scheduled, bool overdue = false)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(scheduled ? 74 : 0) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (scheduled)
        {
            var when = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            when.Children.Add(new TextBlock
            {
                Text = overdue ? t.ScheduledAt.LocalDateTime.ToString("d MMM", Spanish) : t.ScheduledAt.LocalDateTime.ToString("H:mm"),
                FontSize = 19,
                FontWeight = FontWeights.SemiBold,
                FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
                Foreground = BrushHex(overdue ? "#FAC74D" : "#EDF2F5")
            });
            when.Children.Add(new TextBlock { Text = overdue ? t.ScheduledAt.LocalDateTime.ToString("H:mm") + " · " + FocusRules.DurationText(t.Minutes) : FocusRules.DurationText(t.Minutes), FontSize = 13, Foreground = BrushHex("#99A6AD"), Margin = new Thickness(0, 2, 0, 0) });
            grid.Children.Add(when);
        }

        var bar = new Border { Width = 3, CornerRadius = new CornerRadius(2), Background = BrushHex(CategoryHex(t.Category)), Margin = new Thickness(0, 2, 16, 2) };
        Grid.SetColumn(bar, 1);
        grid.Children.Add(bar);

        var middle = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        middle.Children.Add(new TextBlock { Text = t.Title, FontSize = 16.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Foreground = BrushHex("#EDF2F5") });
        var chips = new WrapPanel { Margin = new Thickness(0, 7, 0, -6) };
        var cat = CategoryHex(t.Category);
        chips.Children.Add(Chip(t.Category, cat, "#22262C"));
        if (t.RepeatRule != RepeatRule.Never) chips.Children.Add(Chip(t.RepeatRule.Label(), "#99A6AD", "#22262C", ""));
        if (t.Protection != SessionProtection.None)
            chips.Children.Add(Chip(_engine.IsTaskProtected(t) ? $"Ya protegida · {t.Protection.Label()}" : t.Protection.Label(), "#FAC74D", "#2E2614", ""));
        else if (t.Enforces) chips.Children.Add(Chip(t.BlockingSummary, "#99A6AD", "#22262C", ""));
        middle.Children.Add(chips);
        Grid.SetColumn(middle, 2);
        grid.Children.Add(middle);

        var actions = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(12, 0, 0, 0) };
        actions.Children.Add(IconButton("", "Empezar ahora", () => StartOrHandoffSession(t), "#38A169"));
        if (scheduled) actions.Children.Add(IconButton("", "Posponer 10 min", () => ConfirmAndSnoozeTask(t)));
        var more = IconButton("", "Más acciones", () => { });
        var menu = new ContextMenu();
        void Item(string text, Action act)
        {
            var mi = new MenuItem { Header = text };
            mi.Click += (_, _) => act();
            menu.Items.Add(mi);
        }
        if (scheduled)
        {
            Item("Mañana a la misma hora", () => ApplyTaskChange(t, $"mover a mañana «{t.Title}»", bypass => _engine.MoveToTomorrowSameTime(t, bypass)));
            Item("Pasar a la bandeja", () => ApplyTaskChange(t, $"pasar a la bandeja «{t.Title}»", bypass => _engine.MoveToInbox(t, bypass)));
        }
        else Item("Programar hoy en el primer hueco", () => ApplyTaskChange(t, $"programar «{t.Title}»", bypass => _engine.ScheduleInFirstFreeSlot(t, bypass)));
        Item("Editar…", () => Dialogs.ShowTaskEditor(_engine, t, this));
        menu.Items.Add(new Separator());
        Item("Borrar…", () => ConfirmAndDeleteTask(t));
        more.ContextMenu = menu;
        more.Click += (_, _) => { menu.PlacementTarget = more; menu.IsOpen = true; };
        actions.Children.Add(more);
        Grid.SetColumn(actions, 3);
        grid.Children.Add(actions);

        return InnerRow(grid);
    }
}
