using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

/// <summary>The agenda pages: Hoy, Semana and Historial (the parts that matched macOS Views.swift).</summary>
public partial class MainWindow
{
    private string _historySearch = "";
    private int _historyState;      // 0 todas, 1 completadas, 2 canceladas, 3 incompletas
    private int _historyPeriod;     // 0 todo, 1 hoy, 2 ayer, 3 siete días, 4 treinta días
    private string _historyArea = "";   // "" = todas las áreas
    private int _historyVisible = 25;
    private readonly HashSet<Guid> _historyOpen = new();
    private bool _historySearchFocused;

    // MARK: - Hoy

    private Action<double, string, bool>? _liveRingUpdate;

    private void BuildTodayPage()
    {
        var selected = _engine.SelectedDate.LocalDateTime.Date;
        var isToday = selected == DateTime.Now.Date;
        var now = DateTimeOffset.Now;

        PageContent.Children.Add(PageHeader("Hoy", "Haz espacio para lo importante.",
            GlyphButton("", "Nueva tarea", () => Dialogs.ShowTaskEditor(_engine, null, this), primary: true)));

        // «Antidistracción hoy»: what is blocking right now, at a glance (as on the Mac).
        var enforcing = _engine.Workspace.GeneralRules.Where(r => r.Enabled && _engine.IsRuleEnforcing(r, now)).ToList();
        if (enforcing.Count > 0)
        {
            var chips = new WrapPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 0, -6) };
            foreach (var r in enforcing.Take(4))
            {
                var left = r.Kind == GeneralRuleKind.Countdown && r.ActiveDeadline != null ? r.ActiveDeadline.RemainingAfterPossibleReboot(now) : 0;
                chips.Children.Add(Chip(left > 0 ? $"{r.Name} · Quedan {FocusRules.Clock(left)}" : r.Name, "#38A169", "#15291F"));
            }
            var see = GlyphButton("", "Ver", () => _engine.ActivePage = "Reglas", plain: true);
            see.MinHeight = 30;
            PageContent.Children.Add(GroupCard("Antidistracción hoy", "", chips, trailing: see));
        }

        // A scheduled break (lunch…) that is running now
        if (_engine.ActiveBreak() is { } activeBreak)
        {
            _shownScheduledBreak = activeBreak;
            _liveScheduledBreakText = new TextBlock
            {
                Text = $"{activeBreak.Period.Title} · quedan {FocusRules.Clock(activeBreak.Remaining)}",
                FontSize = 16.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = BrushHex("#FAC74D"),
                VerticalAlignment = VerticalAlignment.Center
            };
            PageContent.Children.Add(GroupCard("Descanso", "", _liveScheduledBreakText, "#FAC74D",
                SmallButton("Ocultar este descanso", () => _engine.DismissActiveBreak(activeBreak.Period), true, 0), "#4A3A1E"));
        }

        // Rest of the eyes (continuous use)
        if (_engine.ActiveContinuousBreakDeadline != null && _engine.Workspace.Settings.ContinuousBreakEnabled)
        {
            _liveContinuousBreakText = new TextBlock
            {
                Text = $"{FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot())} · {_engine.ActiveContinuousBreakMessage}",
                FontSize = 15,
                Foreground = BrushHex("#38A169"),
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center
            };
            PageContent.Children.Add(GroupCard("Descanso de vista", "", _liveContinuousBreakText, trailing:
                SmallButton($"Posponer ({_engine.ContinuousBreakSkipsLeft})", () => _engine.SkipContinuousBreak(), _engine.ContinuousBreakSkipsLeft > 0, 0)));
        }

        // The running session: «Ahora, solo esto», like the Mac card with the ring on the right.
        if (_engine.Workspace.Session is { EndedAt: null } s)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var sp = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            var chips = new WrapPanel();
            chips.Children.Add(s.Paused ? Chip(Spaced("En pausa"), "#FAC74D", "#2E2614", "") : Chip(Spaced("Ahora, solo esto"), "#38A169", "#15291F", ""));
            chips.Children.Add(Chip(s.Task.Category, CategoryHex(s.Task.Category), "#22262C"));
            if (s.Task.PomodoroPhase(s.Elapsed(now)) is { } phase)
            {
                var phaseChip = Chip($"{phase.Label} · bloque {phase.Cycle} · quedan {FocusRules.Clock(phase.RemainingInPhase)}", "#38A169", "#15291F", "");
                _livePomodoroText = (TextBlock)((StackPanel)phaseChip.Child).Children.OfType<TextBlock>().Last();
                chips.Children.Add(phaseChip);
            }
            sp.Children.Add(chips);
            sp.Children.Add(new TextBlock { Text = s.Task.Title, FontSize = 28, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 14),
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI") });

            var btns = new WrapPanel();
            btns.Children.Add(GlyphButton("", "He terminado", () =>
            {
                if (!Dialogs.RequestSessionStop("terminar antes", s, this)) return;
                _engine.FinishSession();
            }, primary: true));
            btns.Children.Add(GlyphButton(s.Paused ? "" : "", s.Paused ? "Reanudar" : "Pausar", () =>
            {
                if (!s.Paused && !Dialogs.RequestSessionStop("pausar", s, this)) return;
                if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
            }));
            btns.Children.Add(GlyphButton("", "+10 min", () => _engine.AddSessionMinutes(10), plain: true));
            var cancel = IconButton("", s.Task.Protection == SessionProtection.Forced ? "Salida de emergencia" : "Cancelar la sesión sin completar la tarea", CancelRunningSession, "#FF8080", "#2A161B");
            cancel.MinHeight = 38;
            btns.Children.Add(cancel);
            sp.Children.Add(btns);

            // Checklist: tick the steps as you go (the same steps the task was written with)
            var steps = AppEngine.ChecklistSteps(s.Task.Checklist);
            if (steps.Count > 0)
            {
                var list = new WrapPanel { Margin = new Thickness(0, 14, 0, 0) };
                for (var i = 0; i < steps.Count; i++)
                {
                    var key = i.ToString();
                    var box = new System.Windows.Controls.CheckBox { Content = steps[i], IsChecked = s.Checked.Contains(key), Margin = new Thickness(0, 0, 18, 4) };
                    box.Click += (_, _) => _engine.SetCheck(key, box.IsChecked == true);
                    list.Children.Add(box);
                }
                sp.Children.Add(list);
            }
            grid.Children.Add(sp);

            var (ring, update) = SessionRing();
            ring.Margin = new Thickness(24, 0, 4, 0);
            Grid.SetColumn(ring, 1);
            grid.Children.Add(ring);
            _liveRingUpdate = update;
            update(s.Budget > 0 ? s.Remaining(now) / s.Budget : 0, FocusRules.Clock(Math.Max(0, s.Remaining(now))), s.Paused);
            PageContent.Children.Add(Card(grid, s.Paused ? "#4A3A1E" : "#2A5A3F"));
        }
        else if (_engine.Workspace.Session == null)
        {
            PageContent.Children.Add(NextStepCard(now));
        }

        // Game rules live strip
        foreach (var gr in _engine.Workspace.GeneralRules.Where(r => r.Enabled && r.Kind == GeneralRuleKind.WorkGoal && r.MaxDailyMatches > 0))
        {
            var st = _engine.GameRuleStatus(gr);
            var row = new DockPanel();
            if (st.CanFinish)
            {
                var endMatch = SmallButton("He terminado", () => _engine.FinishTimedMatch(gr, TimedMatchPlanner.FinishReason.UserFinished), true, 0);
                DockPanel.SetDock(endMatch, Dock.Right);
                row.Children.Add(endMatch);
            }
            var icon = Glyph("", 18, "#38A169");
            icon.Margin = new Thickness(0, 0, 14, 0);
            DockPanel.SetDock(icon, Dock.Left);
            row.Children.Add(icon);
            var info = new StackPanel();
            var titleBlock = new TextBlock { Text = $"{gr.Game?.Name ?? gr.Name} · {st.Text}", FontWeight = FontWeights.SemiBold, FontSize = 15, Foreground = BrushHex(st.Warning ? "#FAC74D" : "#38A169") };
            var subBlock = new TextBlock { Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(gr))} · {_engine.Workspace.MatchesToday(gr.Id)}/{gr.MaxDailyMatches} {gr.MatchUnitPlural}", Foreground = BrushHex("#99A6AD"), FontSize = 13.5, Margin = new Thickness(0, 4, 0, 0) };
            info.Children.Add(titleBlock);
            info.Children.Add(subBlock);
            row.Children.Add(info);
            _liveGameStrips.Add((gr, titleBlock, subBlock));
            PageContent.Children.Add(Card(row));
        }

        // Overdue: an occurrence of an earlier day that was not completed (also what a series leaves behind when it rolls forward)
        var sessionTaskId = _engine.Workspace.Session?.Task.Id;
        var overdue = _engine.Workspace.Tasks
            .Where(t => !t.Completed && t.IsScheduled && t.Id != sessionTaskId && t.ScheduledAt.LocalDateTime.Date < DateTime.Now.Date)
            .OrderBy(t => t.ScheduledAt)
            .ToList();
        if (overdue.Count > 0)
        {
            var list = new StackPanel();
            foreach (var t in overdue) list.Children.Add(MacTaskRow(t, scheduled: true, overdue: true));
            PageContent.Children.Add(GroupCard($"Atrasadas de otros días · {overdue.Count}", "", list, "#FAC74D"));
        }

        // Day navigation and the day's summary, then the agenda (by hours or as a list)
        var (dayTasks, projectedTasks) = TasksForDay(selected);
        var pending = dayTasks.Where(t => !t.Completed).ToList();

        var nav = new DockPanel { Margin = new Thickness(0, 6, 0, 6) };
        var undo = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var undoBtn = IconButton("", "Deshacer (Ctrl+Z)", () => _engine.UndoAgenda());
        undoBtn.IsEnabled = _engine.CanUndo;
        var redoBtn = IconButton("", "Rehacer (Ctrl+Y)", () => _engine.RedoAgenda());
        redoBtn.IsEnabled = _engine.CanRedo;
        undo.Children.Add(undoBtn);
        undo.Children.Add(redoBtn);
        DockPanel.SetDock(undo, Dock.Right);
        nav.Children.Add(undo);
        var hourly = _engine.Prefs.HourlyLayout;
        var layoutSwitch = (FrameworkElement)Segmented(new[] { "Horas", "Lista" }, hourly ? 0 : 1, i =>
        {
            _engine.Prefs.HourlyLayout = i == 0;
            _engine.Prefs.Save();
            RefreshUI();
        });
        layoutSwitch.ToolTip = "Vista por horas (arrastrar y redimensionar) o lista";
        layoutSwitch.Margin = new Thickness(0, 0, 10, 0);
        layoutSwitch.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(layoutSwitch, Dock.Right);
        nav.Children.Add(layoutSwitch);
        var days = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var prev = IconButton("", "Día anterior", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(-1));
        prev.Margin = new Thickness(0);
        days.Children.Add(prev);
        var todayBtn = GlyphButton("", isToday ? "Hoy" : "Volver a hoy", () => _engine.SelectedDate = DateTimeOffset.Now, plain: true);
        todayBtn.Margin = new Thickness(6, 0, 0, 0);
        days.Children.Add(todayBtn);
        days.Children.Add(IconButton("", "Día siguiente", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(1)));
        var dateChip = Chip(selected.ToString("dd/MM/yyyy"), "#EDF2F5", "#1D2229");
        dateChip.Margin = new Thickness(12, 0, 0, 0);
        dateChip.VerticalAlignment = VerticalAlignment.Center;
        days.Children.Add(dateChip);
        nav.Children.Add(days);
        PageContent.Children.Add(nav);

        var planned = pending.Sum(t => t.Minutes);
        var doneCount = dayTasks.Count(t => t.Completed);
        var unscheduledCount = _engine.Workspace.Tasks.Count(t => !t.Completed && !t.IsScheduled);
        var workedSeconds = _engine.Workspace.History
            .Where(r => r.Session.StartedAt.LocalDateTime.Date == selected)
            .Sum(r => r.Session.Elapsed(r.Session.EndedAt ?? r.Session.StartedAt));
        if (_engine.Workspace.Session is { } liveSession && liveSession.StartedAt.LocalDateTime.Date == selected)
            workedSeconds += liveSession.Elapsed(liveSession.EndedAt ?? now);
        var summary = $"{pending.Count} por hacer · previsto {FocusRules.DurationText(planned)}";
        if (unscheduledCount > 0) summary += $" · {unscheduledCount} sin horario";
        summary += $" · {doneCount} hecha{(doneCount == 1 ? "" : "s")} · trabajado {FocusRules.DurationText((int)Math.Round(workedSeconds / 60))}";
        PageContent.Children.Add(MutedText(summary, 12.5, 2));
        PageContent.Children.Add(new Border { Height = 14 });

        if (hourly)
        {
            PageContent.Children.Add(BuildHourlyTimeline(selected, dayTasks, projectedTasks));
        }
        else
        {
            var agenda = new StackPanel();
            if (dayTasks.Count == 0 && projectedTasks.Count == 0)
            {
                agenda.Children.Add(new TextBlock { Text = "Un día por diseñar", FontSize = 17, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 4, 0, 4) });
                agenda.Children.Add(MutedText("Añade una tarea, aplica un perfil o programa algo desde la bandeja de pendientes.", 13.5, 0));
            }
            // Done tasks stay in their place, crossed out, as on the Mac: the day keeps its shape.
            foreach (var t in dayTasks) agenda.Children.Add(MacTaskRow(t, scheduled: true, overlapping: pending.Any(o => FocusRules.Overlaps(t, o))));
            if (projectedTasks.Count > 0)
            {
                agenda.Children.Add(SectionLabel("Próximas ocurrencias de la serie", dayTasks.Count > 0 ? 10 : 0));
                foreach (var t in projectedTasks) agenda.Children.Add(MacTaskRow(t, scheduled: true, projected: true));
            }
            PageContent.Children.Add(GroupCard(isToday ? "Agenda de hoy" : $"Agenda · {selected.ToString("dddd d 'de' MMMM", Spanish)}", "\uE8FD", agenda));
        }

        // Inbox with the quick capture box on top
        var inbox = _engine.Workspace.Tasks.Where(t => !t.Completed && !t.IsScheduled).ToList();
        var inboxStack = new StackPanel();
        var captureBox = new System.Windows.Controls.TextBox { Margin = new Thickness(0, 0, 8, 0), ToolTip = "Escribe y pulsa Intro" };
        void Capture()
        {
            var text = captureBox.Text;
            captureBox.Text = "";
            _engine.QuickCapture(text);
        }
        captureBox.KeyDown += (_, e) => { if (e.Key == Key.Enter) Capture(); };
        var captureRow = new DockPanel { Margin = new Thickness(0, 0, 0, inbox.Count > 0 ? 12 : 0) };
        var captureBtn = GlyphButton("", "Apuntar", Capture);
        captureBtn.Margin = new Thickness(0);
        DockPanel.SetDock(captureBtn, Dock.Right);
        captureRow.Children.Add(captureBtn);
        captureRow.Children.Add(captureBox);
        inboxStack.Children.Add(captureRow);
        foreach (var t in inbox) inboxStack.Children.Add(MacTaskRow(t, scheduled: false));
        PageContent.Children.Add(GroupCard(inbox.Count > 0 ? $"Bandeja sin hora · {inbox.Count}" : "Bandeja sin hora", "", inboxStack));
    }

    /// <summary>One task of the agenda (or of the inbox), drawn like the Mac rows.</summary>
    private Border TaskRow(FocusTask t, bool scheduled) => MacTaskRow(t, scheduled);

    // MARK: - Semana

    /// <summary>A colour mixed into the card background (the soft fill of a task block of that area).</summary>
    private static string Tint(string hex, double amount)
    {
        var c = (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex);
        byte Mix(byte from, byte to) => (byte)Math.Round(from + (to - from) * amount);
        return $"#{Mix(0x16, c.R):X2}{Mix(0x1B, c.G):X2}{Mix(0x21, c.B):X2}";
    }

    private void BuildWeekPage()
    {
        var startOfWeek = _engine.SelectedDate.LocalDateTime.Date.AddDays(-(((int)_engine.SelectedDate.LocalDateTime.DayOfWeek + 6) % 7));
        var endOfWeek = startOfWeek.AddDays(6);
        PageContent.Children.Add(PageHeader("Semana", $"{startOfWeek.ToString("d MMM", Spanish)} – {endOfWeek.ToString("d MMM", Spanish)}. Una semana con intención.",
            GlyphButton("", "Nueva tarea", () => Dialogs.ShowTaskEditor(_engine, null, this), primary: true)));

        // Toolbar: ‹ range › «Esta semana» … undo and calendar export on the right
        var bar = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
        var right = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var undo = IconButton("", "Deshacer (Ctrl+Z)", () => _engine.UndoAgenda());
        undo.IsEnabled = _engine.CanUndo;
        right.Children.Add(undo);
        var ics = GlyphButton("", "Exportar al calendario (.ics)", ExportCalendarFile, plain: true);
        ics.Margin = new Thickness(6, 0, 0, 0);
        right.Children.Add(ics);
        DockPanel.SetDock(right, Dock.Right);
        bar.Children.Add(right);
        var nav = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var prev = IconButton("", "Semana anterior", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(-7));
        prev.Margin = new Thickness(0);
        nav.Children.Add(prev);
        nav.Children.Add(new TextBlock
        {
            Text = $"{startOfWeek.ToString("d MMM", Spanish)} – {endOfWeek.ToString("d MMM yyyy", Spanish)}",
            FontSize = 19,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(14, 0, 8, 0)
        });
        nav.Children.Add(IconButton("", "Semana siguiente", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(7)));
        var thisWeek = GlyphButton("", "Esta semana", () => _engine.SelectedDate = DateTimeOffset.Now, plain: true);
        thisWeek.Margin = new Thickness(8, 0, 0, 0);
        nav.Children.Add(thisWeek);
        bar.Children.Add(nav);
        bar.Margin = new Thickness(0, 0, 0, 6);
        PageContent.Children.Add(bar);
        var dragHint = MutedText("Arrastra bloques entre días o a una franja horaria · pulsa «9h», «12h» o «16h» para crear una tarea a esa hora", 12, 0);
        dragHint.Margin = new Thickness(2, 0, 0, 14);
        PageContent.Children.Add(dragHint);

        // Seven columns, one per day, as on the Mac
        var columns = new System.Windows.Controls.Primitives.UniformGrid { Columns = 7, Margin = new Thickness(0, 0, -8, 0) };
        string[] abbreviations = { "LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM" };
        for (var i = 0; i < 7; i++)
        {
            var day = startOfWeek.AddDays(i);
            var isToday = day == DateTime.Now.Date;
            var weekend = i >= 5;
            var (real, projected) = TasksForDay(day);
            var blocks = real.Select(t => (Task: t, Projected: false))
                .Concat(projected.Select(t => (Task: t, Projected: true)))
                .OrderBy(x => x.Task.ScheduledAt).ToList();
            var isWorkday = _engine.Workspace.Settings.Workdays.Contains(i == 6 ? 1 : i + 2);

            var col = new StackPanel();
            var dayForColumn = day;
            var head = new Grid { Margin = new Thickness(4, 2, 2, 10) };
            head.Children.Add(new TextBlock { Text = Spaced(abbreviations[i]), FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(isWorkday ? "#99A6AD" : "#FAC74D"), VerticalAlignment = VerticalAlignment.Center });
            var number = new TextBlock { Text = day.Day.ToString(), FontSize = 22, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(isToday ? "#0D1014" : "#EDF2F5"), HorizontalAlignment = System.Windows.HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            UIElement numberView = isToday
                ? new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), Background = BrushHex("#38A169"), Child = number, HorizontalAlignment = System.Windows.HorizontalAlignment.Right }
                : new Border { Child = number, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
            head.Children.Add(numberView);
            // The header opens that day in «Hoy», by hours.
            var headButton = new System.Windows.Controls.Button
            {
                Content = head,
                Padding = new Thickness(0),
                HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch,
                Background = System.Windows.Media.Brushes.Transparent,
                BorderBrush = System.Windows.Media.Brushes.Transparent,
                ToolTip = "Abrir este día por horas"
            };
            headButton.Click += (_, _) =>
            {
                _engine.Prefs.HourlyLayout = true;
                _engine.Prefs.Save();
                _engine.SelectedDate = FocusRules.FromLocal(dayForColumn);
                _engine.ActivePage = "Hoy";
            };
            col.Children.Add(headButton);
            col.Children.Add(new Border { Height = 1, Background = BrushHex("#262A30"), Margin = new Thickness(2, 0, 2, 10) });

            foreach (var (t, isProjected) in blocks)
            {
                var color = CategoryHex(t.Category);
                var overlap = !t.Completed && blocks.Any(o => FocusRules.Overlaps(t, o.Task));
                var inner = new StackPanel();
                inner.Children.Add(new TextBlock { Text = t.ScheduledAt.LocalDateTime.ToString("HH:mm"), FontSize = 12.5, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), Foreground = BrushHex("#99A6AD") });
                var title = new TextBlock { Text = t.Title, FontSize = 14, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 3), Foreground = BrushHex(t.Completed ? "#99A6AD" : "#EDF2F5") };
                if (t.Completed) title.TextDecorations = TextDecorations.Strikethrough;
                inner.Children.Add(title);
                var bottom = new DockPanel();
                if (isProjected || t.RepeatRule != RepeatRule.Never)
                {
                    var rep = Glyph("", 10.5, "#38A169");
                    rep.Margin = new Thickness(5, 0, 0, 0);
                    DockPanel.SetDock(rep, Dock.Right);
                    bottom.Children.Add(rep);
                }
                if (overlap)
                {
                    var warn = Glyph("", 11, "#FAC74D");
                    DockPanel.SetDock(warn, Dock.Right);
                    bottom.Children.Add(warn);
                }
                bottom.Children.Add(new TextBlock { Text = FocusRules.DurationText(t.Minutes), FontSize = 12.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(color) });
                inner.Children.Add(bottom);
                var block = new System.Windows.Controls.Button
                {
                    Content = new Border { BorderBrush = BrushHex(color), BorderThickness = new Thickness(3, 0, 0, 0), Padding = new Thickness(8, 6, 6, 6), Child = inner },
                    Padding = new Thickness(0),
                    Margin = new Thickness(0, 0, 0, 8),
                    HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch,
                    Background = BrushHex(isProjected ? "#161B21" : Tint(color, 0.14)),
                    BorderBrush = BrushHex(overlap ? "#B8923A" : isProjected ? "#3A3F46" : Tint(color, 0.28)),
                    Opacity = isProjected ? 0.85 : 1,
                    ToolTip = isProjected
                        ? $"{t.Title} · ocurrencia futura de la serie. Púlsala para cambiar solo este día o la serie entera."
                        : $"{t.Title} · clic para editar, arrastra a otro día, clic derecho para más acciones{(overlap ? " · solapada con otra tarea" : "")}"
                };
                var captured = t;
                block.Click += (_, _) =>
                {
                    if (isProjected) EditOccurrence(captured);
                    else Dialogs.ShowTaskEditor(_engine, captured, this);
                };
                if (!isProjected && !t.Completed && _engine.Workspace.Session?.Task.Id != t.Id)
                {
                    // Drag to another day (or to one of its hour slots)
                    var pressedAt = new System.Windows.Point();
                    block.PreviewMouseLeftButtonDown += (_, e) => pressedAt = e.GetPosition(null);
                    block.PreviewMouseMove += (_, e) =>
                    {
                        if (e.LeftButton != System.Windows.Input.MouseButtonState.Pressed) return;
                        var at = e.GetPosition(null);
                        if (Math.Abs(at.X - pressedAt.X) < 6 && Math.Abs(at.Y - pressedAt.Y) < 6) return;
                        try { System.Windows.DragDrop.DoDragDrop(block, "focusdesk-task:" + captured.Id, System.Windows.DragDropEffects.Move); } catch { }
                    };
                    var menu = new ContextMenu();
                    void Item(string text, Action act)
                    {
                        var mi = new MenuItem { Header = text };
                        mi.Click += (_, _) => act();
                        menu.Items.Add(mi);
                    }
                    Item("Editar…", () => Dialogs.ShowTaskEditor(_engine, captured, this));
                    Item("Empezar ahora", () => StartOrHandoffSession(captured));
                    menu.Items.Add(new Separator());
                    Item("Posponer 10 minutos", () => ConfirmAndSnoozeTask(captured));
                    Item("Alargar 15 min", () => ApplyTaskChange(captured, $"alargar «{captured.Title}»", bypass => _engine.ResizeTask(captured, 15, bypass)));
                    Item("Acortar 15 min", () => ApplyTaskChange(captured, $"acortar «{captured.Title}»", bypass => _engine.ResizeTask(captured, -15, bypass)));
                    Item("Mañana a la misma hora", () => ApplyTaskChange(captured, $"mover a mañana «{captured.Title}»", bypass => _engine.MoveToTomorrowSameTime(captured, bypass)));
                    Item("Pasar a la bandeja", () => ApplyTaskChange(captured, $"pasar a la bandeja «{captured.Title}»", bypass => _engine.MoveToInbox(captured, bypass)));
                    menu.Items.Add(new Separator());
                    Item("Borrar…", () => ConfirmAndDeleteTask(captured));
                    block.ContextMenu = menu;
                }
                col.Children.Add(block);
            }

            // Drop a task here to move it to this day; on «9h», «12h» or «16h» it lands at that hour.
            void DropOn(System.Windows.DragEventArgs e, int? fixedHour)
            {
                e.Handled = true;
                if (e.Data.GetData(System.Windows.DataFormats.StringFormat) is not string raw || !raw.StartsWith("focusdesk-task:", StringComparison.Ordinal)) return;
                if (!Guid.TryParse(raw["focusdesk-task:".Length..], out var id)) return;
                var task = _engine.Workspace.Tasks.FirstOrDefault(x => x.Id == id && !x.Completed);
                if (task == null || _engine.Workspace.Session?.Task.Id == id) return;
                var hour = fixedHour ?? (task.IsScheduled ? task.ScheduledAt.LocalDateTime.Hour : _engine.Workspace.Settings.WorkStartHour);
                var minute = fixedHour != null ? 0 : task.IsScheduled ? task.ScheduledAt.LocalDateTime.Minute : 0;
                var target = dayForColumn.AddHours(Math.Clamp(hour, 0, 23)).AddMinutes(minute);
                if (task.IsScheduled && task.ScheduledAt.LocalDateTime == target) return;
                // After the drop has finished: the code dialog of a protected task must not open in the middle of it.
                Dispatcher.BeginInvoke(() =>
                {
                    ApplyTaskChange(task, $"mover «{task.Title}»", bypass => _engine.MoveTaskTo(task, target, bypass));
                    UpdateNoticeAndSidebar();
                });
            }

            var slots = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3, Margin = new Thickness(0, 2, -4, 4) };
            foreach (var (label, hour) in new[] { ("9h", 9), ("12h", 12), ("16h", 16) })
            {
                var slotHour = hour;
                var slot = new System.Windows.Controls.Button
                {
                    Content = new TextBlock { Text = label, FontSize = 12, Foreground = BrushHex("#99A6AD") },
                    Padding = new Thickness(0),
                    MinHeight = 24,
                    Margin = new Thickness(0, 0, 4, 0),
                    Background = BrushHex("#1D2229"),
                    BorderBrush = BrushHex("#1D2229"),
                    AllowDrop = true,
                    ToolTip = $"Nueva tarea a las {hour}:00 · o suelta aquí una tarea para ponerla a esa hora"
                };
                slot.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, null, this, initialStart: dayForColumn.AddHours(slotHour));
                slot.DragOver += (_, e) => { e.Effects = System.Windows.DragDropEffects.Move; e.Handled = true; slot.BorderBrush = BrushHex("#38A169"); };
                slot.DragLeave += (_, _) => slot.BorderBrush = BrushHex("#1D2229");
                slot.Drop += (_, e) => { slot.BorderBrush = BrushHex("#1D2229"); DropOn(e, slotHour); };
                slots.Children.Add(slot);
            }
            col.Children.Add(slots);

            var add = new System.Windows.Controls.Button
            {
                Content = Glyph("", 13, "#99A6AD"),
                Background = System.Windows.Media.Brushes.Transparent,
                BorderBrush = System.Windows.Media.Brushes.Transparent,
                MinHeight = 30,
                ToolTip = "Nueva tarea este día"
            };
            add.Click += (_, _) =>
            {
                var startHour = Math.Clamp(_engine.Workspace.Settings.WorkStartHour, 0, 23);
                var start = dayForColumn == DateTime.Now.Date ? DateTime.Now.AddMinutes(10) : dayForColumn.AddHours(startHour);
                Dialogs.ShowTaskEditor(_engine, null, this, initialStart: start);
            };
            col.Children.Add(add);

            var column = new Border
            {
                Background = BrushHex(isWorkday ? "#13171C" : "#101317"),
                BorderBrush = BrushHex(isToday ? "#2A5A3F" : "#22262C"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(8, 10, 8, 8),
                Margin = new Thickness(0, 0, 8, 0),
                MinHeight = 420,
                AllowDrop = true,
                Child = col
            };
            var restingBorder = column.BorderBrush;
            column.DragOver += (_, e) => { e.Effects = System.Windows.DragDropEffects.Move; e.Handled = true; column.BorderBrush = BrushHex("#38A169"); };
            column.DragLeave += (_, _) => column.BorderBrush = restingBorder;
            column.Drop += (_, e) => { column.BorderBrush = restingBorder; DropOn(e, null); };
            columns.Children.Add(column);
        }
        PageContent.Children.Add(columns);
    }

    private void ExportCalendarFile()
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { FileName = "FocusDesk-agenda.ics", Filter = "Calendario (*.ics)|*.ics" };
        if (dialog.ShowDialog() != true) return;
        try { _engine.ExportIcs(dialog.FileName); }
        catch (Exception ex)
        {
            _engine.Error = $"No se pudo exportar la agenda: {ex.Message}";
            UpdateNoticeAndSidebar();
        }
    }

    // MARK: - Historial

    private bool HistoryMatches(SessionRecord record)
    {
        if (_historyState == 1 && !record.Completed) return false;
        if (_historyState == 2 && !record.Cancelled) return false;
        if (_historyState == 3 && (record.Completed || record.Cancelled)) return false;
        if (_historyArea.Length > 0 && !string.Equals(record.Session.Task.Category, _historyArea, StringComparison.OrdinalIgnoreCase)) return false;
        var started = record.Session.StartedAt.LocalDateTime;
        if (_historyPeriod == 1 && started.Date != DateTime.Now.Date) return false;
        if (_historyPeriod == 2 && started.Date != DateTime.Now.Date.AddDays(-1)) return false;
        if (_historyPeriod == 3 && started < DateTime.Now.AddDays(-7)) return false;
        if (_historyPeriod == 4 && started < DateTime.Now.AddDays(-30)) return false;
        var query = FocusRules.Fold(_historySearch.Trim());
        if (query.Length == 0) return true;
        var haystack = FocusRules.Fold($"{record.Session.Task.Title} {record.Session.Task.Category} {record.Note} {string.Join(" ", record.ConfirmedFiles)} {string.Join(" ", record.ChangedFiles)}");
        return haystack.Contains(query, StringComparison.Ordinal);
    }

    /// <summary>A Mac segmented control: one rounded strip, the chosen part filled in green.</summary>
    private UIElement Segmented(string[] labels, int selected, Action<int> onPick)
    {
        var strip = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        for (var i = 0; i < labels.Length; i++)
        {
            var on = i == selected;
            var index = i;
            var b = new System.Windows.Controls.Button
            {
                Content = new TextBlock { Text = labels[i], Foreground = BrushHex(on ? "#0D1014" : "#D5DBDF"), FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal },
                Padding = new Thickness(16, 0, 16, 0),
                MinHeight = 32,
                Margin = new Thickness(0),
                Background = on ? BrushHex("#38A169") : System.Windows.Media.Brushes.Transparent,
                BorderBrush = on ? BrushHex("#38A169") : System.Windows.Media.Brushes.Transparent
            };
            b.Click += (_, _) => onPick(index);
            strip.Children.Add(b);
        }
        return new Border { Background = BrushHex("#1D2229"), CornerRadius = new CornerRadius(10), Padding = new Thickness(2), HorizontalAlignment = System.Windows.HorizontalAlignment.Left, Child = strip };
    }

    /// <summary>A summary tile: icon, big number, label (the four boxes over the Mac history).</summary>
    private static Border StatTile(string glyph, string value, string label)
    {
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var tile = IconTile(glyph, false, 36);
        tile.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(tile);
        var text = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(text, 1);
        text.Children.Add(new TextBlock { Text = value, FontSize = 22, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#EDF2F5") });
        text.Children.Add(new TextBlock { Text = label, FontSize = 13, Foreground = BrushHex("#99A6AD"), TextWrapping = TextWrapping.Wrap });
        row.Children.Add(text);
        return new Border
        {
            Background = BrushHex("#161B21"),
            BorderBrush = BrushHex("#262A30"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(14, 12, 14, 12),
            Margin = new Thickness(0, 0, 12, 14),
            Child = row
        };
    }

    private void BuildHistoryPage()
    {
        PageContent.Children.Add(PageHeader("Historial", "Lo que has hecho cuenta.",
            GlyphButton("", "Nueva tarea", () => Dialogs.ShowTaskEditor(_engine, null, this), primary: true)));
        var tabs = Segmented(new[] { "Sesiones", "Registro de bloqueo" }, _auditView ? 1 : 0, i => { _auditView = i == 1; RefreshUI(); });
        ((FrameworkElement)tabs).Margin = new Thickness(0, 0, 0, 16);
        PageContent.Children.Add(tabs);

        if (_auditView)
        {
            var list = new StackPanel();
            foreach (var item in _engine.Workspace.AuditLog.Take(100))
            {
                var line = new DockPanel();
                var when = new TextBlock { Text = item.At.LocalDateTime.ToString("d MMM · HH:mm", Spanish), FontSize = 13.5, Foreground = BrushHex("#99A6AD"), Width = 110, VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(when, Dock.Left);
                line.Children.Add(when);
                var chip = Chip(item.Category, "#FAC74D", "#2E2614");
                chip.Margin = new Thickness(0, 0, 10, 0);
                DockPanel.SetDock(chip, Dock.Left);
                line.Children.Add(chip);
                line.Children.Add(new TextBlock { Text = item.Summary, TextWrapping = TextWrapping.Wrap, FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
                list.Children.Add(InnerRow(line, 6));
            }
            if (_engine.Workspace.AuditLog.Count == 0)
                list.Children.Add(MutedText("Sin eventos registrados todavía.", 13, 0));
            var clear = GlyphButton("", "Vaciar registro", () =>
            {
                var answer = System.Windows.MessageBox.Show(this, "Se borrará todo el registro de auditoría. ¿Seguro?", "Vaciar registro · FocusDesk",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _engine.ClearAuditLog();
            }, plain: true);
            clear.IsEnabled = _engine.Workspace.AuditLog.Count > 0;
            clear.MinHeight = 30;
            PageContent.Children.Add(GroupCard("Registro de bloqueo", "", list, trailing: clear));
            return;
        }

        // Search and filters, in one card
        var filterStack = new StackPanel();
        var searchRow = new Grid();
        var searchBox = new System.Windows.Controls.TextBox { Text = _historySearch, Padding = new Thickness(34, 8, 12, 8), MinHeight = 42, FontSize = 15 };
        searchBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            _historySearch = searchBox.Text;
            _historyVisible = 25;
            _historySearchFocused = true;
            RefreshUI();
        };
        searchRow.Children.Add(searchBox);
        var lens = Glyph("", 13, "#99A6AD");
        lens.Margin = new Thickness(13, 0, 0, 0);
        lens.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
        lens.IsHitTestVisible = false;
        searchRow.Children.Add(lens);
        var hint = new TextBlock { Text = "Buscar por tarea, nota, área o archivo… (Intro)", Foreground = BrushHex("#7C868C"), FontSize = 15, Margin = new Thickness(35, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false,
            Visibility = string.IsNullOrEmpty(_historySearch) ? Visibility.Visible : Visibility.Collapsed };
        searchBox.TextChanged += (_, _) => hint.Visibility = string.IsNullOrEmpty(searchBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        if (_historySearchFocused)
        {
            // The page was rebuilt because of what was typed: put the caret back where it was.
            _historySearchFocused = false;
            searchBox.Loaded += (_, _) => { searchBox.Focus(); searchBox.CaretIndex = searchBox.Text.Length; };
        }
        searchBox.LostFocus += (_, _) =>
        {
            if (searchBox.Text == _historySearch) return;
            _historySearch = searchBox.Text;
            _historyVisible = 25;
            RefreshUI();
        };
        searchRow.Children.Add(hint);
        filterStack.Children.Add(searchRow);

        var filters = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        filters.Children.Add(new TextBlock { Text = "Área", FontSize = 14.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 10, 0) });
        var areaNames = _engine.Workspace.Settings.Categories.Select(c => c.Name)
            .Concat(_engine.Workspace.History.Select(r => r.Session.Task.Category))
            .Where(n => !string.IsNullOrWhiteSpace(n)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        var area = ChoiceBox(new[] { new ComboOption<string>("", "Todas") }.Concat(areaNames.Select(n => new ComboOption<string>(n, n))),
            _historyArea, v => { _historyArea = v; _historyVisible = 25; RefreshUI(); }, 160);
        area.Margin = new Thickness(0, 0, 22, 8);
        filters.Children.Add(area);
        filters.Children.Add(new TextBlock { Text = "Estado", FontSize = 14.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var state = ChoiceBox(new[]
        {
            new ComboOption<int>(0, "Todas"), new ComboOption<int>(1, "Completadas"),
            new ComboOption<int>(3, "Incompletas"), new ComboOption<int>(2, "Canceladas")
        }, _historyState, v => { _historyState = v; _historyVisible = 25; RefreshUI(); }, 160);
        state.Margin = new Thickness(0, 0, 22, 8);
        filters.Children.Add(state);
        var periodGroup = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
        periodGroup.Children.Add(new TextBlock { Text = "Periodo", FontSize = 14.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        periodGroup.Children.Add(Segmented(new[] { "Todo", "Hoy", "Ayer", "7 días", "30 días" }, _historyPeriod, i => { _historyPeriod = i; _historyVisible = 25; RefreshUI(); }));
        filters.Children.Add(periodGroup);
        filterStack.Children.Add(filters);

        var tools = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        var clearFilters = GlyphButton("", "Quitar filtros", () => { _historySearch = ""; _historyState = 0; _historyPeriod = 0; _historyArea = ""; _historyVisible = 25; RefreshUI(); }, plain: true);
        clearFilters.IsEnabled = _historySearch.Length > 0 || _historyState != 0 || _historyPeriod != 0 || _historyArea.Length > 0;
        tools.Children.Add(clearFilters);
        var csv = GlyphButton("", "Exportar CSV…", ExportHistoryFile, plain: true);
        csv.IsEnabled = _engine.Workspace.History.Count > 0;
        tools.Children.Add(csv);
        var detail = GlyphButton("", "Borrar detalle de actividad", () =>
        {
            var answer = System.Windows.MessageBox.Show(this,
                "Se borra el detalle de qué apps y webs usaste; se conservan los totales por app. ¿Seguro?",
                "Borrar detalle · FocusDesk", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (answer == MessageBoxResult.Yes) _engine.RemoveActivityDetail();
        }, plain: true);
        detail.IsEnabled = _engine.Workspace.History.Count > 0;
        tools.Children.Add(detail);
        filterStack.Children.Add(tools);
        PageContent.Children.Add(Card(filterStack));

        var all = _engine.Workspace.History.Where(HistoryMatches).ToList();
        double Worked(SessionRecord r) => r.Session.Elapsed(r.Session.EndedAt ?? r.Session.StartedAt);
        var stats = new System.Windows.Controls.Primitives.UniformGrid { Columns = 4, Margin = new Thickness(0, 0, -12, 0) };
        stats.Children.Add(StatTile("", all.Count.ToString(), "Sesiones"));
        stats.Children.Add(StatTile("", all.Count(r => r.Completed).ToString(), "Completadas"));
        stats.Children.Add(StatTile("", FocusRules.DurationText((int)Math.Round(all.Sum(Worked) / 60)), "Tiempo de sesión (reloj)"));
        stats.Children.Add(StatTile("\uE7B3", FocusRules.DurationText((int)Math.Round(all.Sum(r => r.ObservedSeconds) / 60)), "Actividad observada"));
        PageContent.Children.Add(stats);

        // Sessions grouped by day («Hoy  1 sesión · 1 completada · 25 min»)
        foreach (var group in all.Take(_historyVisible).GroupBy(r => r.Session.StartedAt.LocalDateTime.Date))
        {
            var day = group.Key;
            var name = day == DateTime.Today ? "Hoy" : day == DateTime.Today.AddDays(-1) ? "Ayer" : day.ToString("dddd d 'de' MMMM", Spanish);
            var dayAll = all.Where(r => r.Session.StartedAt.LocalDateTime.Date == day).ToList();
            var title = new TextBlock { Margin = new Thickness(0, 10, 0, 10) };
            title.Inlines.Add(new System.Windows.Documents.Run(char.ToUpper(name[0]) + name[1..]) { FontSize = 19, FontWeight = FontWeights.SemiBold });
            title.Inlines.Add(new System.Windows.Documents.Run($"   {dayAll.Count} {(dayAll.Count == 1 ? "sesión" : "sesiones")} · {dayAll.Count(r => r.Completed)} completada{(dayAll.Count(r => r.Completed) == 1 ? "" : "s")} · {FocusRules.DurationText((int)Math.Round(dayAll.Sum(Worked) / 60))}") { FontSize = 14.5, Foreground = BrushHex("#99A6AD") });
            PageContent.Children.Add(title);
            foreach (var rec in group) PageContent.Children.Add(HistoryCard(rec, Worked(rec)));
        }
        if (all.Count > _historyVisible)
        {
            var more = GlyphButton("", $"Mostrar {Math.Min(50, all.Count - _historyVisible)} sesiones más", () => { _historyVisible += 50; RefreshUI(); }, plain: true);
            PageContent.Children.Add(more);
        }
        if (_engine.Workspace.History.Count == 0)
        {
            var empty = new StackPanel();
            empty.Children.Add(new TextBlock { Text = "Aquí aparecerá tu progreso", FontSize = 17, FontWeight = FontWeights.SemiBold });
            empty.Children.Add(MutedText("Cada registro distingue el tiempo de sesión medido, la actividad observada en apps y los archivos que confirmes como resultado.", 13.5, 6));
            PageContent.Children.Add(Card(empty));
        }
        else if (all.Count == 0)
            PageContent.Children.Add(Card(MutedText("Nada coincide con los filtros.", 13.5, 0)));
    }

    /// <summary>One session of the history, as on the Mac: state icon, title and chip, details; the time on the right.</summary>
    private Border HistoryCard(SessionRecord rec, double worked)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var (glyph, fg, bg, label) = rec.Completed ? ("", "#0D1014", "#38A169", "Completada")
            : rec.Cancelled ? ("", "#FF8080", "#2A161B", "Cancelada")
            : ("", "#FAC74D", "#2E2614", "Pendiente");
        var state = Glyph(glyph, 12, fg);
        state.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        grid.Children.Add(new Border { Width = 26, Height = 26, CornerRadius = new CornerRadius(13), Background = BrushHex(bg), Child = state, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 14, 0) });

        var open = _historyOpen.Contains(rec.Id);
        var sp = new StackPanel();
        var titleRow = new WrapPanel();
        titleRow.Children.Add(new TextBlock { Text = rec.Session.Task.Title, FontSize = 19, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var chip = Chip(label, rec.Completed ? "#38A169" : fg, rec.Completed ? "#15291F" : bg);
        chip.Margin = new Thickness(0, 2, 0, 0);
        titleRow.Children.Add(chip);
        sp.Children.Add(titleRow);
        var start = rec.Session.StartedAt.LocalDateTime;
        var end = (rec.Session.EndedAt ?? rec.Session.StartedAt).LocalDateTime;
        sp.Children.Add(MutedText($"{start:HH:mm}–{end:HH:mm} · {FocusRules.DurationText((int)Math.Round(worked / 60))} · {rec.Session.Task.Category}", 12.5, 6));
        if (!string.IsNullOrWhiteSpace(rec.Note))
            sp.Children.Add(new TextBlock { Text = rec.Note, FontSize = 14.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
        if (open)
        {
            var apps = rec.AppSummaries.Take(6).ToList();
            if (apps.Count > 0)
            {
                sp.Children.Add(SectionLabel("Dónde estuvo el tiempo", 12));
                foreach (var app in apps)
                    sp.Children.Add(new TextBlock { Text = $"{app.Name} · {FocusRules.Clock(app.Seconds)}", FontSize = 13.5, Foreground = BrushHex("#D5DBDF"), Margin = new Thickness(0, 2, 0, 0) });
            }
            var steps = AppEngine.ChecklistSteps(rec.Session.Task.Checklist);
            if (steps.Count > 0)
            {
                sp.Children.Add(SectionLabel("Checklist", 12));
                for (var i = 0; i < steps.Count; i++)
                    sp.Children.Add(new TextBlock { Text = (rec.Session.Checked.Contains(i.ToString()) ? "☑ " : "☐ ") + steps[i], FontSize = 13.5, Foreground = BrushHex("#D5DBDF"), Margin = new Thickness(0, 2, 0, 0) });
            }
            if (rec.ConfirmedFiles.Count > 0 || rec.ManualFiles.Count > 0)
            {
                sp.Children.Add(SectionLabel("Archivos del resultado", 12));
                foreach (var file in rec.ConfirmedFiles.Concat(rec.ManualFiles).Distinct().Take(12))
                    sp.Children.Add(new TextBlock { Text = file, FontSize = 13, Foreground = BrushHex("#D5DBDF"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
            }
            if (rec.Session.BlocksApplied > 0)
                sp.Children.Add(MutedText($"Bloqueos aplicados: {rec.Session.BlocksApplied}", 12, 8));
        }
        var toggle = GlyphButton(open ? "" : "", open ? "Ocultar detalle" : "Ver detalle", () =>
        {
            if (!_historyOpen.Add(rec.Id)) _historyOpen.Remove(rec.Id);
            RefreshUI();
        }, plain: true);
        toggle.Margin = new Thickness(-12, 6, 0, 0);
        toggle.MinHeight = 28;
        toggle.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
        sp.Children.Add(toggle);
        Grid.SetColumn(sp, 1);
        grid.Children.Add(sp);

        var rightCol = new StackPanel { HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(12, 0, 0, 0) };
        rightCol.Children.Add(new TextBlock { Text = FocusRules.DurationText((int)Math.Round(worked / 60)), FontSize = 24, FontWeight = FontWeights.SemiBold, HorizontalAlignment = System.Windows.HorizontalAlignment.Right });
        rightCol.Children.Add(new TextBlock { Text = $"de {rec.Session.Task.Minutes} previstos", FontSize = 13.5, Foreground = BrushHex("#99A6AD"), HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 0) });
        rightCol.Children.Add(new TextBlock { Text = $"{rec.Session.InterruptionCount} interrupciones", FontSize = 13.5, Foreground = BrushHex("#99A6AD"), HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 2, 0, 8) });
        var del = IconButton("", "Borrar sesión del historial", () =>
        {
            var answer = System.Windows.MessageBox.Show(this, $"¿Borrar «{rec.Session.Task.Title}» del historial?", "Borrar sesión · FocusDesk",
                MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (answer == MessageBoxResult.Yes) _engine.DeleteHistoryRecord(rec.Id);
        }, "#FF8080", "#2A161B");
        del.HorizontalAlignment = System.Windows.HorizontalAlignment.Right;
        rightCol.Children.Add(del);
        Grid.SetColumn(rightCol, 2);
        grid.Children.Add(rightCol);
        return Card(grid);
    }

    private void ExportHistoryFile()
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { FileName = "FocusDesk-historial.csv", Filter = "CSV (*.csv)|*.csv" };
        if (dialog.ShowDialog() != true) return;
        try { _engine.ExportHistoryCsv(dialog.FileName); }
        catch (Exception ex)
        {
            _engine.Error = $"No se pudo exportar el historial: {ex.Message}";
            UpdateNoticeAndSidebar();
        }
    }
}
