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

    private void BuildWeekPage()
    {
        var startOfWeek = _engine.SelectedDate.LocalDateTime.Date.AddDays(-(((int)_engine.SelectedDate.LocalDateTime.DayOfWeek + 6) % 7));
        var header = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        header.Children.Add(SmallButton("◀", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(-7)));
        header.Children.Add(SmallButton("Esta semana", () => _engine.SelectedDate = DateTimeOffset.Now));
        header.Children.Add(SmallButton("▶", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(7)));
        header.Children.Add(SmallButton("Deshacer", () => _engine.UndoAgenda(), _engine.CanUndo));
        header.Children.Add(SmallButton("Exportar al calendario (.ics)", ExportCalendarFile, true, 12));
        var addBtn = PrimaryButton("+ Nueva tarea");
        addBtn.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, null, this);
        header.Children.Add(addBtn);
        PageContent.Children.Add(PageHeader("Semana", $"{startOfWeek:d MMM} – {startOfWeek.AddDays(6):d MMM}. Una semana con intención.", header));

        for (var i = 0; i < 7; i++)
        {
            var day = startOfWeek.AddDays(i);
            var isToday = day == DateTime.Now.Date;
            var dayTasks = _engine.Workspace.Tasks
                .Where(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == day)
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
                    var alreadyReal = dayTasks.Any(r => r.Id != series.Id && r.SeriesId == seriesKey);
                    if (!alreadyReal) projected.Add(occ);
                }
            }
            projected = projected.OrderBy(t => t.ScheduledAt).ToList();

            var sp = new StackPanel();
            var dayHeader = new DockPanel();
            var openDay = SmallButton("Ver el día", () =>
            {
                _engine.SelectedDate = FocusRules.FromLocal(day);
                _engine.ActivePage = "Hoy";
            }, true, 0);
            DockPanel.SetDock(openDay, Dock.Right);
            dayHeader.Children.Add(openDay);
            dayHeader.Children.Add(new TextBlock
            {
                Text = isToday ? $"{day:dddd d MMM} · Hoy" : day.ToString("dddd d MMM"),
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = BrushHex(isToday ? "#38A169" : "#EDF2F5"),
                VerticalAlignment = VerticalAlignment.Center
            });
            sp.Children.Add(dayHeader);
            if (dayTasks.Count == 0 && projected.Count == 0)
                sp.Children.Add(new TextBlock { Text = "Sin bloques programados", Foreground = BrushHex("#7C868C"), FontSize = 12, Margin = new Thickness(0, 5, 0, 0) });
            foreach (var t in dayTasks)
                sp.Children.Add(new TextBlock { Text = $"• {t.ScheduledAt.LocalDateTime:HH:mm}–{t.End.LocalDateTime:HH:mm}  {t.Title} ({t.Minutes} min) · {t.Category}", Foreground = BrushHex("#D5DBDF"), FontSize = 13, Margin = new Thickness(0, 5, 0, 0) });
            foreach (var t in projected)
                sp.Children.Add(new TextBlock { Text = $"↻ {t.ScheduledAt.LocalDateTime:HH:mm}–{t.End.LocalDateTime:HH:mm}  {t.Title} ({t.Minutes} min) · repetición", Foreground = BrushHex("#99A6AD"), FontSize = 13, Margin = new Thickness(0, 5, 0, 0) });
            PageContent.Children.Add(Card(sp, isToday ? "#2A5A3F" : null));
        }
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
            var tools = Row(
                SmallButton("Vaciar registro", () =>
                {
                    var answer = System.Windows.MessageBox.Show(this, "Se borrará todo el registro de auditoría. ¿Seguro?", "Vaciar registro · FocusDesk",
                        MessageBoxButton.YesNo, MessageBoxImage.Warning);
                    if (answer == MessageBoxResult.Yes) _engine.ClearAuditLog();
                }, _engine.Workspace.AuditLog.Count > 0));
            tools.Margin = new Thickness(0, 0, 0, 8);
            PageContent.Children.Add(tools);
            foreach (var item in _engine.Workspace.AuditLog.Take(100))
                PageContent.Children.Add(Card(new TextBlock { Text = $"{item.At.LocalDateTime:g} · [{item.Category}] {item.Summary}", TextWrapping = TextWrapping.Wrap, FontSize = 13 }));
            if (_engine.Workspace.AuditLog.Count == 0)
                PageContent.Children.Add(Card(new TextBlock { Text = "Sin eventos registrados todavía.", Foreground = BrushHex("#99A6AD") }));
            return;
        }

        // Search and filters
        var searchBox = new System.Windows.Controls.TextBox { Text = _historySearch, Width = 260, Margin = new Thickness(0, 0, 10, 0) };
        searchBox.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            _historySearch = searchBox.Text;
            _historyVisible = 25;
            RefreshUI();
        };
        var filters = new WrapPanel { Margin = new Thickness(0, 0, 0, 10) };
        filters.Children.Add(Labeled("Buscar por tarea, nota, área o archivo (Enter)", searchBox, 0));
        filters.Children.Add(Labeled("Estado", ChoiceBox(new[]
        {
            new ComboOption<int>(0, "Todas"), new ComboOption<int>(1, "Completadas"),
            new ComboOption<int>(2, "Canceladas"), new ComboOption<int>(3, "Pendientes")
        }, _historyState, v => { _historyState = v; _historyVisible = 25; RefreshUI(); }, 150), 0));
        filters.Children.Add(Labeled("Periodo", ChoiceBox(new[]
        {
            new ComboOption<int>(0, "Todo"), new ComboOption<int>(1, "Esta semana"), new ComboOption<int>(2, "Este mes")
        }, _historyPeriod, v => { _historyPeriod = v; _historyVisible = 25; RefreshUI(); }, 150), 0));
        PageContent.Children.Add(filters);

        var all = _engine.Workspace.History.Where(HistoryMatches).ToList();
        var tools2 = Row(
            SmallButton("Quitar filtros", () => { _historySearch = ""; _historyState = 0; _historyPeriod = 0; _historyVisible = 25; RefreshUI(); },
                _historySearch.Length > 0 || _historyState != 0 || _historyPeriod != 0),
            SmallButton("Exportar CSV…", ExportHistoryFile, _engine.Workspace.History.Count > 0),
            SmallButton("Borrar detalle de actividad", () =>
            {
                var answer = System.Windows.MessageBox.Show(this,
                    "Se borra el detalle de qué apps y webs usaste; se conservan los totales por app. ¿Seguro?",
                    "Borrar detalle · FocusDesk", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _engine.RemoveActivityDetail();
            }, _engine.Workspace.History.Count > 0));
        tools2.Margin = new Thickness(0, 0, 0, 8);
        PageContent.Children.Add(tools2);
        PageContent.Children.Add(MutedText($"{all.Count} sesiones · {FocusRules.Clock(all.Sum(r => r.Session.Elapsed(r.Session.EndedAt ?? r.Session.StartedAt)))} trabajadas", 12, 0));

        foreach (var rec in all.Take(_historyVisible))
        {
            var sp = new StackPanel();
            var head = new DockPanel();
            var open = _historyOpen.Contains(rec.Id);
            var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            buttons.Children.Add(SmallButton(open ? "Ocultar" : "Detalle", () =>
            {
                if (!_historyOpen.Add(rec.Id)) _historyOpen.Remove(rec.Id);
                RefreshUI();
            }));
            buttons.Children.Add(SmallButton("Borrar sesión", () =>
            {
                var answer = System.Windows.MessageBox.Show(this, $"¿Borrar «{rec.Session.Task.Title}» del historial?", "Borrar sesión · FocusDesk",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _engine.DeleteHistoryRecord(rec.Id);
            }, true, 0));
            DockPanel.SetDock(buttons, Dock.Right);
            head.Children.Add(buttons);
            head.Children.Add(new TextBlock
            {
                Text = $"{rec.Session.Task.Title} · {(rec.Completed ? "Completada" : rec.Cancelled ? "Cancelada" : "Pendiente")}",
                FontSize = 14.5,
                FontWeight = FontWeights.SemiBold,
                VerticalAlignment = VerticalAlignment.Center
            });
            sp.Children.Add(head);
            sp.Children.Add(new TextBlock
            {
                Text = $"{rec.Session.StartedAt.LocalDateTime:g} · Trabajado: {FocusRules.Clock(rec.Session.Elapsed(rec.Session.EndedAt ?? rec.Session.StartedAt))} · Interrupciones: {rec.Session.InterruptionCount} · {rec.Session.Task.Category}",
                Foreground = BrushHex("#99A6AD"),
                FontSize = 12,
                Margin = new Thickness(0, 4, 0, 0)
            });
            if (open)
            {
                if (!string.IsNullOrWhiteSpace(rec.Note)) sp.Children.Add(MutedText($"Nota: {rec.Note}", 12.5, 8));
                var apps = rec.AppSummaries.Take(6).ToList();
                if (apps.Count > 0)
                {
                    sp.Children.Add(SectionLabel("DÓNDE ESTUVO EL TIEMPO", 10));
                    foreach (var app in apps)
                        sp.Children.Add(new TextBlock { Text = $"{app.Name} · {FocusRules.Clock(app.Seconds)}", FontSize = 12.5, Foreground = BrushHex("#D5DBDF"), Margin = new Thickness(0, 2, 0, 0) });
                }
                var steps = AppEngine.ChecklistSteps(rec.Session.Task.Checklist);
                if (steps.Count > 0)
                {
                    sp.Children.Add(SectionLabel("CHECKLIST", 10));
                    for (var i = 0; i < steps.Count; i++)
                        sp.Children.Add(new TextBlock { Text = (rec.Session.Checked.Contains(i.ToString()) ? "☑ " : "☐ ") + steps[i], FontSize = 12.5, Foreground = BrushHex("#D5DBDF"), Margin = new Thickness(0, 2, 0, 0) });
                }
                if (rec.ConfirmedFiles.Count > 0 || rec.ManualFiles.Count > 0)
                {
                    sp.Children.Add(SectionLabel("ARCHIVOS DEL RESULTADO", 10));
                    foreach (var file in rec.ConfirmedFiles.Concat(rec.ManualFiles).Distinct().Take(12))
                        sp.Children.Add(new TextBlock { Text = file, FontSize = 12, Foreground = BrushHex("#D5DBDF"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
                }
                if (rec.Session.BlocksApplied > 0)
                    sp.Children.Add(MutedText($"Bloqueos aplicados: {rec.Session.BlocksApplied}", 12, 8));
            }
            PageContent.Children.Add(Card(sp));
        }
        if (all.Count > _historyVisible)
            PageContent.Children.Add(SmallButton($"Mostrar {Math.Min(50, all.Count - _historyVisible)} sesiones más", () =>
            {
                _historyVisible += 50;
                RefreshUI();
            }));
        if (_engine.Workspace.History.Count == 0)
            PageContent.Children.Add(Card(new TextBlock { Text = "Todavía no has completado ninguna sesión.", Foreground = BrushHex("#99A6AD") }));
        else if (all.Count == 0)
            PageContent.Children.Add(Card(new TextBlock { Text = "Ninguna sesión coincide con estos filtros.", Foreground = BrushHex("#99A6AD") }));
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
