using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using FocusDesk.Windows.Core;

namespace FocusDesk.Windows.UI;

/// <summary>
/// The parts of «Hoy» that the first Windows port left out: the «Tu siguiente paso» card and the day drawn by hours,
/// where a block is dragged to move it and its lower edge to change how long it lasts (macOS: NextUpHero and
/// DayTimeline in Views.swift).
/// </summary>
public partial class MainWindow
{
    private const double TimelineGutter = 64;
    private const double PixelsPerMinute = 1.1;
    private double? _timelineOffset;
    private DateTime _timelineDay;

    /// <summary>The tasks of a day: the real ones, and the coming occurrences of recurring tasks (drawn, not stored).</summary>
    private (List<FocusTask> Real, List<FocusTask> Projected) TasksForDay(DateTime day)
    {
        var real = _engine.Workspace.Tasks
            .Where(t => t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == day)
            .OrderBy(t => t.ScheduledAt).ToList();
        var projected = new List<FocusTask>();
        var dayStart = FocusRules.FromLocal(day);
        var dayEnd = FocusRules.FromLocal(day.AddDays(1)).AddSeconds(-1);
        foreach (var series in _engine.Workspace.Tasks.Where(t => !t.Completed && t.IsScheduled && t.RepeatRule != RepeatRule.Never))
        {
            var key = series.SeriesId ?? series.Id;
            foreach (var occurrence in series.UpcomingOccurrences(dayStart, dayEnd, _engine.Workspace.Settings.Workdays))
            {
                if (real.Any(r => r.Id != series.Id && r.SeriesId == key)) continue;
                projected.Add(occurrence);
            }
        }
        return (real, projected.OrderBy(t => t.ScheduledAt).ToList());
    }

    /// <summary>The recurring task a drawn occurrence belongs to.</summary>
    private FocusTask? SeriesOf(FocusTask occurrence)
    {
        var key = occurrence.SeriesId ?? occurrence.Id;
        return _engine.Workspace.Tasks.FirstOrDefault(t => t.Id == key && t.RepeatRule != RepeatRule.Never)
            ?? _engine.Workspace.Tasks.FirstOrDefault(t => t.SeriesId == key && t.RepeatRule != RepeatRule.Never);
    }

    /// <summary>Opens the editor of a drawn occurrence: it asks whether the change is for that day or for the series.</summary>
    private void EditOccurrence(FocusTask occurrence)
    {
        if (SeriesOf(occurrence) is { } series) Dialogs.ShowTaskEditor(_engine, series, this, occurrenceDate: occurrence.ScheduledAt);
    }

    private static string DayTitle(DateTime day)
    {
        var today = DateTime.Now.Date;
        if (day.Date == today) return "Hoy";
        if (day.Date == today.AddDays(1)) return "Mañana";
        if (day.Date == today.AddDays(-1)) return "Ayer";
        return day.ToString("ddd d MMM", Spanish);
    }

    /// <summary>«Antes de 25 nov, 18:00»: amber when it is close, red when it has passed.</summary>
    private static Border DueChip(DateTimeOffset due, DateTimeOffset now)
    {
        var late = due < now;
        var soon = !late && due < now.AddHours(24);
        var text = (late ? "Venció el " : "Antes de ") + due.LocalDateTime.ToString("d MMM, H:mm", Spanish);
        return Chip(text, late ? "#FF8080" : soon ? "#FAC74D" : "#99A6AD", late ? "#2A161B" : soon ? "#2E2614" : "#22262C", "");
    }

    // MARK: - Tu siguiente paso

    /// <summary>With nothing running: the next task and one button to start it, or the way in to the first task.</summary>
    private Border NextStepCard(DateTimeOffset now)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        var eyebrow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var spark = Glyph("", 12.5, "#38A169");
        spark.Margin = new Thickness(0, 0, 8, 0);
        eyebrow.Children.Add(spark);
        eyebrow.Children.Add(new TextBlock { Text = Spaced("Tu siguiente paso"), FontSize = 12, FontWeight = FontWeights.Bold, Foreground = BrushHex("#38A169") });
        left.Children.Add(eyebrow);

        var next = _engine.NextTask(now);
        if (next != null)
        {
            left.Children.Add(new TextBlock
            {
                Text = next.Title,
                FontSize = 26,
                FontWeight = FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI"),
                Margin = new Thickness(0, 8, 0, 10)
            });
            var chips = new WrapPanel();
            chips.Children.Add(Chip(next.Category, CategoryHex(next.Category), "#22262C"));
            chips.Children.Add(Chip(FocusRules.DurationText(next.Minutes), "#99A6AD", "#22262C", ""));
            chips.Children.Add(next.IsScheduled
                ? Chip($"{DayTitle(next.ScheduledAt.LocalDateTime)} · {next.ScheduledAt.LocalDateTime:H:mm}", "#99A6AD", "#22262C", "")
                : Chip("Sin hora", "#99A6AD", "#22262C", ""));
            if (next.DueDate is { } due) chips.Children.Add(DueChip(due, now));
            left.Children.Add(chips);

            var buttons = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
            var start = GlyphButton("", "Empezar ahora", () => StartOrHandoffSession(next), primary: true);
            start.ToolTip = "Empezar (Ctrl+Alt+Win+S)";
            buttons.Children.Add(start);
            buttons.Children.Add(GlyphButton("", "Posponer 10 min", () => ConfirmAndSnoozeTask(next)));
            buttons.Children.Add(GlyphButton("", "Editar", () => Dialogs.ShowTaskEditor(_engine, next, this), plain: true));
            left.Children.Add(buttons);
        }
        else
        {
            left.Children.Add(new TextBlock
            {
                Text = "Una cosa cada vez.",
                FontSize = 26,
                FontWeight = FontWeights.SemiBold,
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI"),
                Margin = new Thickness(0, 8, 0, 6)
            });
            left.Children.Add(MutedText("Prepara tu primera tarea o aplica un perfil reutilizable. Te ayudamos a volver a ella.", 14.5, 0));
            var create = GlyphButton("", "Crear una tarea", () => Dialogs.ShowTaskEditor(_engine, null, this), primary: true);
            create.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            create.Margin = new Thickness(0, 14, 0, 0);
            left.Children.Add(create);
        }
        grid.Children.Add(left);

        // The target on the right; in the last minutes before the task it becomes «EMPIEZA EN 04:59».
        var target = new Grid { Width = 116, Height = 116, Margin = new Thickness(24, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
        target.Children.Add(new System.Windows.Shapes.Ellipse { Stroke = BrushHex("#1B2A22"), StrokeThickness = 1 });
        target.Children.Add(new System.Windows.Shapes.Ellipse { Stroke = BrushHex("#213529"), StrokeThickness = 1, Width = 88, Height = 88 });
        target.Children.Add(new System.Windows.Shapes.Ellipse { Fill = BrushHex("#14211B"), Width = 58, Height = 58 });
        var scope = Glyph("", 24, "#38A169");
        scope.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        var countdown = new StackPanel { HorizontalAlignment = System.Windows.HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };
        countdown.Children.Add(new TextBlock { Text = Spaced("Empieza en"), FontSize = 9.5, FontWeight = FontWeights.Bold, Foreground = BrushHex("#38A169"), HorizontalAlignment = System.Windows.HorizontalAlignment.Center });
        var clock = new TextBlock { FontSize = 20, FontWeight = FontWeights.Medium, Foreground = BrushHex("#38A169"), FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), HorizontalAlignment = System.Windows.HorizontalAlignment.Center };
        countdown.Children.Add(clock);
        target.Children.Add(scope);
        target.Children.Add(countdown);
        void Tick(DateTimeOffset at)
        {
            var until = next is { IsScheduled: true } ? (next.ScheduledAt - at).TotalSeconds : -1;
            var close = next != null && until > 0 && until <= Math.Max(10, next.LeadMinutes) * 60.0;
            countdown.Visibility = close ? Visibility.Visible : Visibility.Collapsed;
            scope.Visibility = close ? Visibility.Collapsed : Visibility.Visible;
            if (close) clock.Text = FocusRules.Clock(until);
        }
        Tick(now);
        _liveNextStepTick = Tick;
        Grid.SetColumn(target, 1);
        grid.Children.Add(target);
        return Card(grid);
    }

    private Action<DateTimeOffset>? _liveNextStepTick;
    private Action<DateTimeOffset>? _liveTimelineTick;

    // MARK: - Por horas

    /// <summary>Side by side columns for the blocks that overlap in time (macOS: `TimelineLayout.columns`).</summary>
    private static Dictionary<Guid, (int Column, int Columns)> TimelineColumns(List<(Guid Id, DateTimeOffset Start, DateTimeOffset End)> intervals)
    {
        var result = new Dictionary<Guid, (int Column, int Columns)>();
        var cluster = new List<(Guid Id, DateTimeOffset End, int Column)>();
        var clusterEnd = DateTimeOffset.MinValue;
        void Flush()
        {
            if (cluster.Count == 0) return;
            var columns = cluster.Max(c => c.Column) + 1;
            foreach (var c in cluster) result[c.Id] = (c.Column, columns);
            cluster.Clear();
        }
        foreach (var item in intervals.OrderBy(i => i.Start).ThenBy(i => i.End))
        {
            if (cluster.Count > 0 && item.Start >= clusterEnd) Flush();
            var used = cluster.Where(c => c.End > item.Start).Select(c => c.Column).ToHashSet();
            var column = 0;
            while (used.Contains(column)) column++;
            cluster.Add((item.Id, item.End, column));
            if (cluster.Count == 1 || item.End > clusterEnd) clusterEnd = item.End;
        }
        Flush();
        return result;
    }

    /// <summary>A rounded box with a dashed outline (a break, a preview of a series, the live session).</summary>
    private static Grid DashedBox(UIElement content, string strokeHex, string fillHex, double thickness = 1)
    {
        var grid = new Grid();
        grid.Children.Add(new System.Windows.Shapes.Rectangle
        {
            RadiusX = 9,
            RadiusY = 9,
            Fill = BrushHex(fillHex),
            Stroke = BrushHex(strokeHex),
            StrokeThickness = thickness,
            StrokeDashArray = new DoubleCollection { 5, 3 }
        });
        grid.Children.Add(content);
        return grid;
    }

    private static System.Windows.Controls.Button MiniIconButton(string glyph, string tooltip, Action onClick, string fg = "#D5DBDF")
    {
        var button = new System.Windows.Controls.Button
        {
            Content = Glyph(glyph, 11.5, fg),
            ToolTip = tooltip,
            Width = 26,
            Height = 24,
            MinHeight = 24,
            Padding = new Thickness(0),
            Margin = new Thickness(4, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Top,
            Background = BrushHex("#22272E"),
            BorderBrush = BrushHex("#22272E")
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    /// <summary>The day by hours: every task where it is, the breaks, the running session and the line of «now».</summary>
    private Border BuildHourlyTimeline(DateTime day, List<FocusTask> real, List<FocusTask> projected)
    {
        var settings = _engine.Workspace.Settings;
        var now = DateTimeOffset.Now;
        var isToday = day == DateTime.Now.Date;
        var session = _engine.Workspace.Session;

        // The running session is drawn where it really is (started late, extended…), not in its planned slot.
        (DateTimeOffset Start, DateTimeOffset End)? live = null;
        if (session != null && session.StartedAt.LocalDateTime.Date == day)
        {
            var end = session.EndedAt ?? now.AddSeconds(Math.Max(0, session.Remaining(now)));
            if (end < session.StartedAt.AddMinutes(1)) end = session.StartedAt.AddMinutes(1);
            live = (session.StartedAt, end);
        }
        var liveTaskId = live != null ? session!.Task.Id : (Guid?)null;
        var visible = real.Select(t => (Task: t, Projected: false))
            .Concat(projected.Select(t => (Task: t, Projected: true)))
            .Where(x => x.Task.Id != liveTaskId)
            .ToList();

        int MinutesOfDay(DateTimeOffset moment)
        {
            var local = moment.LocalDateTime;
            return (local.Date > day ? 24 * 60 : 0) + local.Hour * 60 + local.Minute;
        }

        var startHours = visible.Select(x => x.Task.ScheduledAt.LocalDateTime.Hour).ToList();
        if (live != null) startHours.Add(live.Value.Start.LocalDateTime.Hour);
        var earliest = startHours.Count > 0 ? startHours.Min() : settings.WorkStartHour;
        var startHour = Math.Max(0, Math.Min(earliest, Math.Min(settings.WorkStartHour - 1, 7)));
        var endMinutes = visible.Select(x => MinutesOfDay(x.Task.End)).ToList();
        if (live != null) endMinutes.Add(MinutesOfDay(live.Value.End));
        var latest = endMinutes.Count > 0 ? (int)Math.Ceiling(Math.Min(24 * 60, endMinutes.Max()) / 60.0) : settings.WorkEndHour;
        var endHour = Math.Min(24, Math.Max(latest, Math.Max(settings.WorkEndHour + 1, 21)));

        var height = (endHour - startHour) * 60 * PixelsPerMinute;
        var surface = new Grid { Height = height + 34, Background = System.Windows.Media.Brushes.Transparent };

        // Hour rows
        for (var hour = startHour; hour <= endHour; hour++)
        {
            var y = (hour - startHour) * 60 * PixelsPerMinute;
            surface.Children.Add(new TextBlock
            {
                Text = $"{hour % 24:00}:00",
                FontSize = 12,
                FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
                Foreground = BrushHex("#8A949A"),
                Width = TimelineGutter - 10,
                TextAlignment = TextAlignment.Right,
                HorizontalAlignment = System.Windows.HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(0, y, 0, 0),
                IsHitTestVisible = false
            });
            surface.Children.Add(new Border
            {
                Height = 1,
                Background = BrushHex("#22262C"),
                VerticalAlignment = VerticalAlignment.Top,
                Margin = new Thickness(TimelineGutter, y + 7, 6, 0),
                IsHitTestVisible = false
            });
        }
        const double top = 7; // the hour lines sit at the middle of their labels

        // Habitual breaks (lunch…)
        foreach (var brk in settings.Breaks.Where(b => b.StartHour >= startHour && b.StartHour < endHour))
        {
            var label = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(11, 0, 8, 0), VerticalAlignment = VerticalAlignment.Center };
            var cup = Glyph("", 11.5, "#99A6AD");
            cup.Margin = new Thickness(0, 0, 8, 0);
            label.Children.Add(cup);
            label.Children.Add(new TextBlock { Text = $"{brk.Title} · {brk.StartHour:00}:{brk.StartMinute:00} · {brk.DurationMinutes} min", FontSize = 12.5, Foreground = BrushHex("#99A6AD"), VerticalAlignment = VerticalAlignment.Center });
            var box = DashedBox(label, "#343A42", "#191D23");
            box.Height = Math.Max(22, brk.DurationMinutes * PixelsPerMinute);
            box.VerticalAlignment = VerticalAlignment.Top;
            box.Margin = new Thickness(TimelineGutter + 4, top + ((brk.StartHour - startHour) * 60 + brk.StartMinute) * PixelsPerMinute, 6, 0);
            box.IsHitTestVisible = false;
            surface.Children.Add(box);
        }

        // Blocks, in columns when they overlap
        var intervals = visible.Select(x => (x.Task.Id, x.Task.ScheduledAt, x.Task.End)).ToList();
        var liveId = Guid.Parse("00000000-0000-0000-0000-00000000F0CD");
        if (live != null) intervals.Add((liveId, live.Value.Start, live.Value.End));
        var slots = TimelineColumns(intervals);
        var placed = new List<(FrameworkElement View, int Column, int Columns)>();

        void Place(FrameworkElement view, DateTimeOffset start, double minutes, Guid id)
        {
            var startMinutes = (double)MinutesOfDay(start);
            var fromTop = Math.Max(0, startMinutes - startHour * 60);
            var shown = Math.Min(minutes, Math.Max(0, 24 * 60 - startMinutes));
            view.Height = Math.Max(30, shown * PixelsPerMinute);
            view.VerticalAlignment = VerticalAlignment.Top;
            view.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            view.Margin = new Thickness(TimelineGutter + 4, top + fromTop * PixelsPerMinute, 0, 0);
            var slot = slots.TryGetValue(id, out var found) ? found : (Column: 0, Columns: 1);
            placed.Add((view, slot.Column, slot.Columns));
            surface.Children.Add(view);
        }
        void Relayout()
        {
            var lane = Math.Max(140, surface.ActualWidth - TimelineGutter - 12);
            foreach (var (view, column, columns) in placed)
            {
                var width = lane / Math.Max(1, columns);
                view.Width = Math.Max(60, width - (columns > 1 ? 3 : 0));
                view.Margin = new Thickness(TimelineGutter + 4 + width * column, view.Margin.Top, 0, 0);
            }
        }

        foreach (var (task, isProjected) in visible)
        {
            var overlaps = visible.Any(o => FocusRules.Overlaps(task, o.Task));
            var block = TimelineBlock(task, isProjected, overlaps, surface, startHour);
            Place(block, task.ScheduledAt, task.Minutes, task.Id);
        }

        if (live != null && session != null)
        {
            var state = session.EndedAt != null ? "Por confirmar" : session.Paused ? "En pausa" : "En directo";
            var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(11, 5, 8, 0), VerticalAlignment = VerticalAlignment.Top };
            row.Children.Add(new TextBlock
            {
                Text = $"{live.Value.Start.LocalDateTime:H:mm}–{live.Value.End.LocalDateTime:H:mm}",
                FontSize = 12,
                FontWeight = FontWeights.SemiBold,
                FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
                Foreground = BrushHex("#EDF2F5"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 10, 0)
            });
            row.Children.Add(new TextBlock { Text = session.Task.Title, FontSize = 14, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
            row.Children.Add(new TextBlock { Text = state, FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#38A169"), VerticalAlignment = VerticalAlignment.Center });
            var liveBox = DashedBox(row, "#38A169", "#14261D", 1.5);
            liveBox.ToolTip = $"La sesión tal y como va: empezó a las {live.Value.Start.LocalDateTime:H:mm} y, a este ritmo, acaba a las {live.Value.End.LocalDateTime:H:mm}.";
            liveBox.ClipToBounds = true;
            Place(liveBox, live.Value.Start, (live.Value.End - live.Value.Start).TotalMinutes, liveId);
        }

        // The line of «now»
        if (isToday)
        {
            var chip = new Border
            {
                Background = BrushHex("#FF8080"),
                CornerRadius = new CornerRadius(7),
                Padding = new Thickness(5, 1, 5, 1),
                HorizontalAlignment = System.Windows.HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                IsHitTestVisible = false,
                Child = new TextBlock { FontSize = 11, FontWeight = FontWeights.Bold, Foreground = BrushHex("#0D1014"), FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas") }
            };
            var line = new Border { Height = 1.5, Background = BrushHex("#FF8080"), VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false };
            surface.Children.Add(line);
            surface.Children.Add(chip);
            void MoveNow(DateTimeOffset at)
            {
                var minutes = (at.LocalDateTime.Hour - startHour) * 60 + at.LocalDateTime.Minute;
                var inside = at.LocalDateTime.Date == day && minutes >= 0 && minutes <= (endHour - startHour) * 60;
                chip.Visibility = line.Visibility = inside ? Visibility.Visible : Visibility.Collapsed;
                if (!inside) return;
                var y = top + minutes * PixelsPerMinute;
                ((TextBlock)chip.Child).Text = at.LocalDateTime.ToString("H:mm");
                chip.Margin = new Thickness(8, Math.Max(0, y - 9), 0, 0);
                line.Margin = new Thickness(TimelineGutter, y, 6, 0);
            }
            MoveNow(now);
            _liveTimelineTick = MoveNow;
        }

        // A double click on an empty stretch creates a task at that hour
        surface.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount != 2 || !ReferenceEquals(e.OriginalSource, surface)) return;
            var y = e.GetPosition(surface).Y - top;
            var minutes = startHour * 60 + (int)Math.Floor(Math.Max(0, y) / PixelsPerMinute / 15) * 15;
            e.Handled = true;
            Dialogs.ShowTaskEditor(_engine, null, this, initialStart: day.AddMinutes(Math.Min(minutes, 23 * 60 + 45)));
        };
        surface.SizeChanged += (_, _) => Relayout();
        surface.Loaded += (_, _) => Relayout();

        // The day scrolls inside its card, opened an hour before now (or before the first task)
        var initialHour = isToday ? Math.Max(startHour, DateTime.Now.Hour - 1)
            : Math.Max(startHour, (real.FirstOrDefault(t => !t.Completed) ?? real.FirstOrDefault())?.ScheduledAt.LocalDateTime.Hour - 1 ?? settings.WorkStartHour);
        var scroller = new ScrollViewer
        {
            Height = Math.Min(height + 34, 480),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = surface
        };
        var remembered = _timelineDay == day ? _timelineOffset : null;
        _timelineDay = day;
        scroller.Loaded += (_, _) => scroller.ScrollToVerticalOffset(remembered ?? Math.Max(0, (initialHour - startHour) * 60 * PixelsPerMinute - 4));
        scroller.ScrollChanged += (_, _) => _timelineOffset = scroller.VerticalOffset;
        // At its top or bottom the wheel moves the page, so the day never traps the scroll.
        scroller.PreviewMouseWheel += (_, e) =>
        {
            var atTop = e.Delta > 0 && scroller.VerticalOffset <= 0;
            var atBottom = e.Delta < 0 && scroller.VerticalOffset >= scroller.ScrollableHeight - 0.5;
            if (!atTop && !atBottom) return;
            e.Handled = true;
            PageScroll.ScrollToVerticalOffset(PageScroll.VerticalOffset - e.Delta);
        };

        var content = new StackPanel();
        content.Children.Add(MutedText("Arrastra un bloque para moverlo · su borde inferior para cambiar la duración · doble clic en un hueco para crear una tarea a esa hora · los de borde discontinuo son una vista previa de la serie", 12, 0));
        content.Children.Add(new Border { Height = 10 });
        content.Children.Add(scroller);
        return GroupCard("Por horas", "", content);
    }

    /// <summary>One task on the day by hours. Dragging moves it (5-minute steps); its lower edge changes its length.</summary>
    private FrameworkElement TimelineBlock(FocusTask task, bool isProjected, bool overlaps, Grid surface, int startHour)
    {
        var color = CategoryHex(task.Category);
        var minutesTall = task.Minutes * PixelsPerMinute;
        var compact = minutesTall < 46;
        var range = $"{task.ScheduledAt.LocalDateTime:H:mm}–{task.End.LocalDateTime:H:mm}";
        var editable = !isProjected && !task.Completed && !_engine.DataUnreadable;

        var actions = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        if (!task.Completed && !isProjected)
            actions.Children.Add(MiniIconButton("", _engine.Workspace.Session == null ? "Empezar ahora" : "Empezar esta en lugar de la que está en marcha", () => StartOrHandoffSession(task), "#38A169"));
        actions.Children.Add(MiniIconButton("", isProjected ? "Editar esta ocurrencia o la serie" : "Editar", () =>
        {
            if (isProjected) EditOccurrence(task); else Dialogs.ShowTaskEditor(_engine, task, this);
        }));

        var dock = new DockPanel { Margin = new Thickness(9, 5, 6, 4), LastChildFill = true };
        DockPanel.SetDock(actions, Dock.Right);
        dock.Children.Add(actions);
        var texts = new StackPanel { Orientation = compact ? System.Windows.Controls.Orientation.Horizontal : System.Windows.Controls.Orientation.Vertical };
        var head = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        head.Children.Add(new TextBlock
        {
            Text = range,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"),
            Foreground = BrushHex("#99A6AD"),
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 9, 0)
        });
        if (overlaps)
        {
            var warn = Glyph("", 11.5, "#FAC74D");
            warn.Margin = new Thickness(0, 0, 7, 0);
            warn.ToolTip = "Solapada con otra tarea";
            head.Children.Add(warn);
        }
        if (isProjected || task.RepeatRule != RepeatRule.Never)
        {
            var repeat = Glyph("", 11, "#38A169");
            repeat.Margin = new Thickness(0, 0, 7, 0);
            head.Children.Add(repeat);
        }
        texts.Children.Add(head);
        var title = new TextBlock
        {
            Text = task.Title,
            FontSize = 14,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex(task.Completed ? "#99A6AD" : "#EDF2F5"),
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = compact || minutesTall < 64 ? TextWrapping.NoWrap : TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, compact ? 0 : 2, 0, 0)
        };
        if (task.Completed) title.TextDecorations = TextDecorations.Strikethrough;
        texts.Children.Add(title);
        dock.Children.Add(texts);

        FrameworkElement block;
        if (isProjected)
        {
            block = DashedBox(dock, "#3F454D", "#171B21");
            block.Opacity = 0.9;
        }
        else
        {
            block = new Border
            {
                Background = BrushHex(task.Completed ? "#1A1E24" : Tint(color, 0.16)),
                BorderBrush = BrushHex(overlaps ? "#B8923A" : Tint(color, 0.34)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(9),
                ClipToBounds = true,
                Child = new Border { BorderBrush = BrushHex(color), BorderThickness = new Thickness(3, 0, 0, 0), CornerRadius = new CornerRadius(9, 0, 0, 9), Child = dock }
            };
        }
        block.ToolTip = isProjected
            ? $"{task.Title} · ocurrencia futura de la serie. Edítala para cambiar solo este día o la serie entera."
            : $"{task.Title} · {range} · arrastra para moverla, su borde inferior para la duración";

        // More actions with the right button (the same ones the Mac offers to the keyboard and VoiceOver)
        if (editable)
        {
            var menu = new ContextMenu();
            void Item(string text, Action act)
            {
                var item = new MenuItem { Header = text };
                item.Click += (_, _) => act();
                menu.Items.Add(item);
            }
            Item("Editar…", () => Dialogs.ShowTaskEditor(_engine, task, this));
            Item("Empezar ahora", () => StartOrHandoffSession(task));
            menu.Items.Add(new Separator());
            Item("Adelantar 15 minutos", () => ApplyTaskChange(task, $"mover «{task.Title}»", bypass => _engine.ShiftTask(task, -15, bypass)));
            Item("Retrasar 15 minutos", () => ApplyTaskChange(task, $"retrasar «{task.Title}»", bypass => _engine.ShiftTask(task, 15, bypass)));
            Item("Alargar 15 minutos", () => ApplyTaskChange(task, $"alargar «{task.Title}»", bypass => _engine.ResizeTask(task, 15, bypass)));
            Item("Acortar 15 minutos", () => ApplyTaskChange(task, $"acortar «{task.Title}»", bypass => _engine.ResizeTask(task, -15, bypass)));
            menu.Items.Add(new Separator());
            Item("Mañana a la misma hora", () => ApplyTaskChange(task, $"mover a mañana «{task.Title}»", bypass => _engine.MoveToTomorrowSameTime(task, bypass)));
            Item("Pasar a la bandeja", () => ApplyTaskChange(task, $"pasar a la bandeja «{task.Title}»", bypass => _engine.MoveToInbox(task, bypass)));
            Item("Borrar…", () => ConfirmAndDeleteTask(task));
            block.ContextMenu = menu;
        }

        // Dragging: 0 nothing, 1 pressed (not yet moved), 2 moving, 3 changing the length
        var mode = 0;
        var resizeZone = false;
        var origin = new System.Windows.Point();
        double startTop = 0, startHeight = 0;
        block.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount == 2)
            {
                e.Handled = true;
                if (isProjected) EditOccurrence(task); else Dialogs.ShowTaskEditor(_engine, task, this);
                return;
            }
            e.Handled = true;
            if (!editable) return;
            origin = e.GetPosition(surface);
            startTop = block.Margin.Top;
            startHeight = block.Height;
            resizeZone = e.GetPosition(block).Y >= block.ActualHeight - 8;
            mode = 1;
            block.CaptureMouse();
        };
        block.MouseMove += (_, e) =>
        {
            if (!editable) return;
            if (mode == 0)
            {
                block.Cursor = e.GetPosition(block).Y >= block.ActualHeight - 8 ? System.Windows.Input.Cursors.SizeNS : System.Windows.Input.Cursors.SizeAll;
                return;
            }
            var dy = e.GetPosition(surface).Y - origin.Y;
            if (mode == 1)
            {
                if (Math.Abs(dy) < 8) return;
                mode = resizeZone ? 3 : 2;
                block.Opacity = 0.82;
                System.Windows.Controls.Panel.SetZIndex(block, 5);
            }
            var snapped = Math.Round(dy / PixelsPerMinute / 5.0) * 5 * PixelsPerMinute;
            if (mode == 2) block.Margin = new Thickness(block.Margin.Left, Math.Max(0, startTop + snapped), 0, 0);
            else block.Height = Math.Max(5 * PixelsPerMinute, startHeight + snapped);
        };
        block.MouseLeftButtonUp += (_, e) =>
        {
            if (mode == 0) return;
            var was = mode;
            mode = 0;
            block.ReleaseMouseCapture();
            block.Opacity = 1;
            if (was == 1) return;
            var dy = e.GetPosition(surface).Y - origin.Y;
            var minutes = (int)Math.Round(dy / PixelsPerMinute / 5.0) * 5;
            if (minutes != 0)
            {
                if (was == 2) ApplyTaskChange(task, $"{(minutes > 0 ? "retrasar" : "mover")} «{task.Title}»", bypass => _engine.ShiftTask(task, minutes, bypass));
                else ApplyTaskChange(task, $"{(minutes > 0 ? "alargar" : "acortar")} «{task.Title}»", bypass => _engine.ResizeTask(task, minutes, bypass));
            }
            UpdateNoticeAndSidebar();
            RefreshUI();
        };
        block.LostMouseCapture += (_, _) =>
        {
            if (mode == 0) return;
            mode = 0;
            block.Opacity = 1;
            RefreshUI();
        };
        return block;
    }
}
