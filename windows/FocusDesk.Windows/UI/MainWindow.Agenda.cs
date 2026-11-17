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
    private int _historyState;      // 0 todas, 1 completadas, 2 canceladas, 3 pendientes
    private int _historyPeriod;     // 0 todo, 1 esta semana, 2 este mes
    private int _historyVisible = 25;
    private readonly HashSet<Guid> _historyOpen = new();

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
                FontSize = 15,
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
                FontSize = 14,
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
            sp.Children.Add(new TextBlock { Text = s.Task.Title, FontSize = 25, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 14),
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
            var cancel = IconButton("", s.Task.Protection == SessionProtection.Forced ? "Salida de emergencia" : "Cancelar la sesión", () =>
            {
                if (s.Remaining(DateTimeOffset.Now) > 0 && s.Task.Protection != SessionProtection.None)
                {
                    if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"cancelar «{s.Task.Title}»", this))
                        return;
                    if (s.Task.Protection == SessionProtection.Forced)
                        _engine.Workspace.RecordAudit("Salida de emergencia", $"Cancelación de emergencia de «{s.Task.Title}».");
                }
                _engine.CancelSession();
            }, "#FF8080", "#2A161B");
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
            var titleBlock = new TextBlock { Text = $"{gr.Game?.Name ?? gr.Name} · {st.Text}", FontWeight = FontWeights.SemiBold, FontSize = 14.5, Foreground = BrushHex(st.Warning ? "#FAC74D" : "#38A169") };
            var subBlock = new TextBlock { Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(gr))} · {_engine.Workspace.MatchesToday(gr.Id)}/{gr.MaxDailyMatches} {gr.MatchUnitPlural}", Foreground = BrushHex("#99A6AD"), FontSize = 12.5, Margin = new Thickness(0, 4, 0, 0) };
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

        // Day navigation and the day's summary, then the agenda
        var dayTasks = _engine.Workspace.Tasks
            .Where(t => t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == selected)
            .OrderBy(t => t.ScheduledAt)
            .ToList();
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
        PageContent.Children.Add(MutedText($"{pending.Count} por hacer · previsto {FocusRules.DurationText(planned)} · {dayTasks.Count(t => t.Completed)} hecha{(dayTasks.Count(t => t.Completed) == 1 ? "" : "s")}", 12.5, 2));
        PageContent.Children.Add(new Border { Height = 14 });

        var agenda = new StackPanel();
        if (pending.Count == 0)
            agenda.Children.Add(MutedText("Sin tareas programadas este día. Pulsa «Nueva tarea» para crear tu primer bloque.", 13, 0));
        foreach (var t in pending) agenda.Children.Add(MacTaskRow(t, scheduled: true));
        PageContent.Children.Add(GroupCard(isToday ? "Agenda de hoy" : $"Agenda · {selected.ToString("dddd d 'de' MMMM", Spanish)}", "", agenda));

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
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(14, 0, 8, 0)
        });
        nav.Children.Add(IconButton("", "Semana siguiente", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(7)));
        var thisWeek = GlyphButton("", "Esta semana", () => _engine.SelectedDate = DateTimeOffset.Now, plain: true);
        thisWeek.Margin = new Thickness(8, 0, 0, 0);
        nav.Children.Add(thisWeek);
        bar.Children.Add(nav);
        PageContent.Children.Add(bar);

        // Seven columns, one per day, as on the Mac
        var columns = new System.Windows.Controls.Primitives.UniformGrid { Columns = 7, Margin = new Thickness(0, 0, -8, 0) };
        string[] abbreviations = { "LUN", "MAR", "MIÉ", "JUE", "VIE", "SÁB", "DOM" };
        for (var i = 0; i < 7; i++)
        {
            var day = startOfWeek.AddDays(i);
            var isToday = day == DateTime.Now.Date;
            var weekend = i >= 5;
            var real = _engine.Workspace.Tasks
                .Where(t => t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == day)
                .OrderBy(t => t.ScheduledAt).ToList();
            // Future occurrences of recurring tasks, drawn (not stored) so the week shows what is coming.
            var projected = new List<FocusTask>();
            var windowStart = FocusRules.FromLocal(day);
            var windowEnd = FocusRules.FromLocal(day.AddDays(1)).AddSeconds(-1);
            foreach (var series in _engine.Workspace.Tasks.Where(t => !t.Completed && t.IsScheduled && t.RepeatRule != RepeatRule.Never))
            {
                var seriesKey = series.SeriesId ?? series.Id;
                foreach (var occ in series.UpcomingOccurrences(windowStart, windowEnd, _engine.Workspace.Settings.Workdays))
                {
                    var alreadyReal = real.Any(r => r.Id != series.Id && r.SeriesId == seriesKey);
                    if (!alreadyReal) projected.Add(occ);
                }
            }
            var blocks = real.Select(t => (Task: t, Projected: false))
                .Concat(projected.Select(t => (Task: t, Projected: true)))
                .OrderBy(x => x.Task.ScheduledAt).ToList();

            var col = new StackPanel();
            var head = new Grid { Margin = new Thickness(4, 2, 2, 10) };
            head.Children.Add(new TextBlock { Text = Spaced(abbreviations[i]), FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(weekend ? "#FAC74D" : "#99A6AD"), VerticalAlignment = VerticalAlignment.Center });
            var number = new TextBlock { Text = day.Day.ToString(), FontSize = 20, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(isToday ? "#0D1014" : "#EDF2F5"), HorizontalAlignment = System.Windows.HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            UIElement numberView = isToday
                ? new Border { Width = 34, Height = 34, CornerRadius = new CornerRadius(17), Background = BrushHex("#38A169"), Child = number, HorizontalAlignment = System.Windows.HorizontalAlignment.Right }
                : new Border { Child = number, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
            head.Children.Add(numberView);
            col.Children.Add(head);
            col.Children.Add(new Border { Height = 1, Background = BrushHex("#262A30"), Margin = new Thickness(2, 0, 2, 10) });

            foreach (var (t, isProjected) in blocks)
            {
                var color = CategoryHex(t.Category);
                var inner = new StackPanel();
                var top = new DockPanel();
                if (isProjected || t.RepeatRule != RepeatRule.Never)
                {
                    var rep = Glyph("", 10.5, "#38A169");
                    DockPanel.SetDock(rep, Dock.Right);
                    top.Children.Add(rep);
                }
                top.Children.Add(new TextBlock { Text = t.ScheduledAt.LocalDateTime.ToString("HH:mm"), FontSize = 11.5, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), Foreground = BrushHex("#99A6AD") });
                inner.Children.Add(top);
                var title = new TextBlock { Text = t.Title, FontSize = 13, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 3), Foreground = BrushHex(t.Completed ? "#99A6AD" : "#EDF2F5") };
                if (t.Completed) title.TextDecorations = TextDecorations.Strikethrough;
                inner.Children.Add(title);
                inner.Children.Add(new TextBlock { Text = FocusRules.DurationText(t.Minutes), FontSize = 11.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(color) });
                var block = new System.Windows.Controls.Button
                {
                    Content = new Border { BorderBrush = BrushHex(color), BorderThickness = new Thickness(3, 0, 0, 0), Padding = new Thickness(8, 6, 6, 6), Child = inner },
                    Padding = new Thickness(0),
                    Margin = new Thickness(0, 0, 0, 8),
                    HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch,
                    Background = BrushHex(isProjected ? "#161B21" : Tint(color, 0.14)),
                    BorderBrush = BrushHex(isProjected ? "#3A3F46" : Tint(color, 0.28)),
                    Opacity = isProjected ? 0.85 : 1,
                    ToolTip = isProjected ? "Repetición prevista (se crea al llegar el día)" : "Editar la tarea"
                };
                var captured = t;
                var capturedDay = day;
                block.Click += (_, _) =>
                {
                    if (isProjected)
                    {
                        _engine.SelectedDate = FocusRules.FromLocal(capturedDay);
                        _engine.ActivePage = "Hoy";
                    }
                    else Dialogs.ShowTaskEditor(_engine, captured, this);
                };
                col.Children.Add(block);
            }

            var add = new System.Windows.Controls.Button
            {
                Content = Glyph("", 13, "#99A6AD"),
                Background = System.Windows.Media.Brushes.Transparent,
                BorderBrush = System.Windows.Media.Brushes.Transparent,
                MinHeight = 30,
                ToolTip = "Ver y planificar este día"
            };
            var dayForAdd = day;
            add.Click += (_, _) =>
            {
                _engine.SelectedDate = FocusRules.FromLocal(dayForAdd);
                _engine.ActivePage = "Hoy";
            };
            col.Children.Add(add);

            columns.Children.Add(new Border
            {
                Background = BrushHex("#13171C"),
                BorderBrush = BrushHex(isToday ? "#2A5A3F" : "#22262C"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(8, 10, 8, 8),
                Margin = new Thickness(0, 0, 8, 0),
                MinHeight = 420,
                Child = col
            });
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
        var started = record.Session.StartedAt.LocalDateTime;
        if (_historyPeriod == 1 && started < DateTime.Now.Date.AddDays(-(((int)DateTime.Now.DayOfWeek + 6) % 7))) return false;
        if (_historyPeriod == 2 && (started.Year != DateTime.Now.Year || started.Month != DateTime.Now.Month)) return false;
        var query = FocusRules.Fold(_historySearch.Trim());
        if (query.Length == 0) return true;
        var haystack = FocusRules.Fold($"{record.Session.Task.Title} {record.Session.Task.Category} {record.Note} {string.Join(" ", record.ConfirmedFiles)}");
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
        var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var tile = IconTile(glyph, false, 36);
        tile.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(tile);
        var text = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = value, FontSize = 20, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#EDF2F5") });
        text.Children.Add(new TextBlock { Text = label, FontSize = 12, Foreground = BrushHex("#99A6AD"), TextWrapping = TextWrapping.Wrap });
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
                var when = new TextBlock { Text = item.At.LocalDateTime.ToString("d MMM · HH:mm", Spanish), FontSize = 12.5, Foreground = BrushHex("#99A6AD"), Width = 110, VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(when, Dock.Left);
                line.Children.Add(when);
                var chip = Chip(item.Category, "#FAC74D", "#2E2614");
                chip.Margin = new Thickness(0, 0, 10, 0);
                DockPanel.SetDock(chip, Dock.Left);
                line.Children.Add(chip);
                line.Children.Add(new TextBlock { Text = item.Summary, TextWrapping = TextWrapping.Wrap, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
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
        var searchBox = new System.Windows.Controls.TextBox { Text = _historySearch, Padding = new Thickness(34, 8, 12, 8), MinHeight = 42, FontSize = 14 };
        searchBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            _historySearch = searchBox.Text;
            _historyVisible = 25;
            RefreshUI();
        };
        searchRow.Children.Add(searchBox);
        var lens = Glyph("", 13, "#99A6AD");
        lens.Margin = new Thickness(13, 0, 0, 0);
        lens.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
        lens.IsHitTestVisible = false;
        searchRow.Children.Add(lens);
        var hint = new TextBlock { Text = "Buscar por tarea, nota, área o archivo… (Intro)", Foreground = BrushHex("#7C868C"), FontSize = 14, Margin = new Thickness(35, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, IsHitTestVisible = false,
            Visibility = string.IsNullOrEmpty(_historySearch) ? Visibility.Visible : Visibility.Collapsed };
        searchBox.TextChanged += (_, _) => hint.Visibility = string.IsNullOrEmpty(searchBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        searchRow.Children.Add(hint);
        filterStack.Children.Add(searchRow);

        var filters = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        filters.Children.Add(new TextBlock { Text = "Estado", FontSize = 13.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 10, 0) });
        var state = ChoiceBox(new[]
        {
            new ComboOption<int>(0, "Todas"), new ComboOption<int>(1, "Completadas"),
            new ComboOption<int>(2, "Canceladas"), new ComboOption<int>(3, "Pendientes")
        }, _historyState, v => { _historyState = v; _historyVisible = 25; RefreshUI(); }, 160);
        state.Margin = new Thickness(0, 0, 22, 0);
        filters.Children.Add(state);
        filters.Children.Add(new TextBlock { Text = "Periodo", FontSize = 13.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        filters.Children.Add(Segmented(new[] { "Todo", "Esta semana", "Este mes" }, _historyPeriod, i => { _historyPeriod = i; _historyVisible = 25; RefreshUI(); }));
        filterStack.Children.Add(filters);

        var tools = new WrapPanel { Margin = new Thickness(0, 12, 0, 0) };
        var clearFilters = GlyphButton("", "Quitar filtros", () => { _historySearch = ""; _historyState = 0; _historyPeriod = 0; _historyVisible = 25; RefreshUI(); }, plain: true);
        clearFilters.IsEnabled = _historySearch.Length > 0 || _historyState != 0 || _historyPeriod != 0;
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
        stats.Children.Add(StatTile("", FocusRules.DurationText((int)Math.Round(all.Sum(Worked) / 60)), "Tiempo de sesión"));
        stats.Children.Add(StatTile("", all.Sum(r => r.Session.InterruptionCount).ToString(), "Interrupciones"));
        PageContent.Children.Add(stats);

        // Sessions grouped by day («Hoy  1 sesión · 1 completada · 25 min»)
        foreach (var group in all.Take(_historyVisible).GroupBy(r => r.Session.StartedAt.LocalDateTime.Date))
        {
            var day = group.Key;
            var name = day == DateTime.Today ? "Hoy" : day == DateTime.Today.AddDays(-1) ? "Ayer" : day.ToString("dddd d 'de' MMMM", Spanish);
            var dayAll = all.Where(r => r.Session.StartedAt.LocalDateTime.Date == day).ToList();
            var title = new TextBlock { Margin = new Thickness(0, 10, 0, 10) };
            title.Inlines.Add(new System.Windows.Documents.Run(char.ToUpper(name[0]) + name[1..]) { FontSize = 17, FontWeight = FontWeights.SemiBold });
            title.Inlines.Add(new System.Windows.Documents.Run($"   {dayAll.Count} {(dayAll.Count == 1 ? "sesión" : "sesiones")} · {dayAll.Count(r => r.Completed)} completada{(dayAll.Count(r => r.Completed) == 1 ? "" : "s")} · {FocusRules.DurationText((int)Math.Round(dayAll.Sum(Worked) / 60))}") { FontSize = 13.5, Foreground = BrushHex("#99A6AD") });
            PageContent.Children.Add(title);
            foreach (var rec in group) PageContent.Children.Add(HistoryCard(rec, Worked(rec)));
        }
        if (all.Count > _historyVisible)
        {
            var more = GlyphButton("", $"Mostrar {Math.Min(50, all.Count - _historyVisible)} sesiones más", () => { _historyVisible += 50; RefreshUI(); }, plain: true);
            PageContent.Children.Add(more);
        }
        if (_engine.Workspace.History.Count == 0)
            PageContent.Children.Add(Card(MutedText("Todavía no has completado ninguna sesión.", 13, 0)));
        else if (all.Count == 0)
            PageContent.Children.Add(Card(MutedText("Ninguna sesión coincide con estos filtros.", 13, 0)));
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
        titleRow.Children.Add(new TextBlock { Text = rec.Session.Task.Title, FontSize = 17, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        var chip = Chip(label, rec.Completed ? "#38A169" : fg, rec.Completed ? "#15291F" : bg);
        chip.Margin = new Thickness(0, 2, 0, 0);
        titleRow.Children.Add(chip);
        sp.Children.Add(titleRow);
        var start = rec.Session.StartedAt.LocalDateTime;
        var end = (rec.Session.EndedAt ?? rec.Session.StartedAt).LocalDateTime;
        sp.Children.Add(MutedText($"{start:HH:mm}–{end:HH:mm} · {FocusRules.DurationText((int)Math.Round(worked / 60))} · {rec.Session.Task.Category}", 12.5, 6));
        if (!string.IsNullOrWhiteSpace(rec.Note))
            sp.Children.Add(new TextBlock { Text = rec.Note, FontSize = 13.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) });
        if (open)
        {
            var apps = rec.AppSummaries.Take(6).ToList();
            if (apps.Count > 0)
            {
                sp.Children.Add(SectionLabel("Dónde estuvo el tiempo", 12));
                foreach (var app in apps)
                    sp.Children.Add(new TextBlock { Text = $"{app.Name} · {FocusRules.Clock(app.Seconds)}", FontSize = 12.5, Foreground = BrushHex("#D5DBDF"), Margin = new Thickness(0, 2, 0, 0) });
            }
            var steps = AppEngine.ChecklistSteps(rec.Session.Task.Checklist);
            if (steps.Count > 0)
            {
                sp.Children.Add(SectionLabel("Checklist", 12));
                for (var i = 0; i < steps.Count; i++)
                    sp.Children.Add(new TextBlock { Text = (rec.Session.Checked.Contains(i.ToString()) ? "☑ " : "☐ ") + steps[i], FontSize = 12.5, Foreground = BrushHex("#D5DBDF"), Margin = new Thickness(0, 2, 0, 0) });
            }
            if (rec.ConfirmedFiles.Count > 0 || rec.ManualFiles.Count > 0)
            {
                sp.Children.Add(SectionLabel("Archivos del resultado", 12));
                foreach (var file in rec.ConfirmedFiles.Concat(rec.ManualFiles).Distinct().Take(12))
                    sp.Children.Add(new TextBlock { Text = file, FontSize = 12, Foreground = BrushHex("#D5DBDF"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
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
        rightCol.Children.Add(new TextBlock { Text = FocusRules.DurationText((int)Math.Round(worked / 60)), FontSize = 22, FontWeight = FontWeights.SemiBold, HorizontalAlignment = System.Windows.HorizontalAlignment.Right });
        rightCol.Children.Add(new TextBlock { Text = $"de {rec.Session.Task.Minutes} previstos", FontSize = 12.5, Foreground = BrushHex("#99A6AD"), HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 4, 0, 0) });
        rightCol.Children.Add(new TextBlock { Text = $"{rec.Session.InterruptionCount} interrupciones", FontSize = 12.5, Foreground = BrushHex("#99A6AD"), HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 2, 0, 8) });
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
