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

    private void BuildTodayPage()
    {
        var selected = _engine.SelectedDate.LocalDateTime.Date;
        var isToday = selected == DateTime.Now.Date;

        var header = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        header.Children.Add(SmallButton("◀", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(-1)));
        if (!isToday) header.Children.Add(SmallButton("Hoy", () => _engine.SelectedDate = DateTimeOffset.Now));
        header.Children.Add(SmallButton("▶", () => _engine.SelectedDate = _engine.SelectedDate.AddDays(1)));
        header.Children.Add(SmallButton("Deshacer", () => _engine.UndoAgenda(), _engine.CanUndo));
        header.Children.Add(SmallButton("Rehacer", () => _engine.RedoAgenda(), _engine.CanRedo, 12));
        var addBtn = PrimaryButton("+ Nueva tarea");
        addBtn.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, null, this);
        header.Children.Add(addBtn);
        PageContent.Children.Add(PageHeader(
            $"{(isToday ? "Hoy" : "Agenda")} · {selected:dddd d MMM}",
            "Haz espacio para lo importante.",
            header));

        // A scheduled break (lunch…) that is running now
        if (_engine.ActiveBreak() is { } activeBreak)
        {
            _shownScheduledBreak = activeBreak;
            var row = new DockPanel();
            var hide = SmallButton("Ocultar este descanso", () => _engine.DismissActiveBreak(activeBreak.Period), true, 0);
            DockPanel.SetDock(hide, Dock.Right);
            row.Children.Add(hide);
            _liveScheduledBreakText = new TextBlock
            {
                Text = $"{activeBreak.Period.Title} · quedan {FocusRules.Clock(activeBreak.Remaining)}",
                FontSize = 14,
                FontWeight = FontWeights.SemiBold,
                Foreground = BrushHex("#FAC74D"),
                VerticalAlignment = VerticalAlignment.Center
            };
            row.Children.Add(_liveScheduledBreakText);
            PageContent.Children.Add(Card(row, "#4A3A1E"));
        }

        // Rest of the eyes (continuous use)
        if (_engine.ActiveContinuousBreakDeadline != null && _engine.Workspace.Settings.ContinuousBreakEnabled)
        {
            var row = new DockPanel();
            var skip = SmallButton($"Posponer ({_engine.ContinuousBreakSkipsLeft})", () => _engine.SkipContinuousBreak(), _engine.ContinuousBreakSkipsLeft > 0, 0);
            DockPanel.SetDock(skip, Dock.Right);
            row.Children.Add(skip);
            _liveContinuousBreakText = new TextBlock
            {
                Text = $"Descanso de vista · {FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot())} · {_engine.ActiveContinuousBreakMessage}",
                FontSize = 13,
                Foreground = BrushHex("#38A169"),
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center
            };
            row.Children.Add(_liveContinuousBreakText);
            PageContent.Children.Add(Card(row, "#2A5A3F"));
        }

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
                Foreground = BrushHex(s.Paused ? "#FAC74D" : "#38A169")
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
                    Foreground = BrushHex("#FAC74D"),
                    FontSize = 12.5,
                    Margin = new Thickness(0, 0, 0, 10)
                };
                sp.Children.Add(_livePomodoroText);
            }

            // Checklist: tick the steps as you go (the same steps the task was written with)
            var steps = AppEngine.ChecklistSteps(s.Task.Checklist);
            if (steps.Count > 0)
            {
                sp.Children.Add(SectionLabel("CHECKLIST", 4));
                for (var i = 0; i < steps.Count; i++)
                {
                    var key = i.ToString();
                    var box = new System.Windows.Controls.CheckBox { Content = steps[i], IsChecked = s.Checked.Contains(key), Margin = new Thickness(0, 3, 0, 0) };
                    box.Click += (_, _) => _engine.SetCheck(key, box.IsChecked == true);
                    sp.Children.Add(box);
                }
            }

            var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
            var pauseBtn = new System.Windows.Controls.Button { Content = s.Paused ? "Reanudar" : "Pausar", Margin = new Thickness(0, 0, 8, 0) };
            pauseBtn.Click += (_, _) =>
            {
                if (!s.Paused && !Dialogs.RequestSessionStop("pausar", s, this)) return;
                if (s.Paused) _engine.ResumeSession(); else _engine.PauseSession();
            };
            var add10 = new System.Windows.Controls.Button { Content = "+10 min", Margin = new Thickness(0, 0, 8, 0) };
            add10.Click += (_, _) => _engine.AddSessionMinutes(10);
            var fin = PrimaryButton("He terminado");
            fin.Margin = new Thickness(0, 0, 8, 0);
            fin.Click += (_, _) =>
            {
                if (!Dialogs.RequestSessionStop("terminar antes", s, this)) return;
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
            PageContent.Children.Add(Card(sp, s.Paused ? "#4A3A1E" : "#2A5A3F"));
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
            var titleBlock = new TextBlock { Text = $"{gr.Game?.Name ?? gr.Name} · {st.Text}", FontWeight = FontWeights.SemiBold, FontSize = 14, Foreground = BrushHex(st.Warning ? "#FAC74D" : "#38A169") };
            var subBlock = new TextBlock { Text = $"Estudio hoy: {FocusRules.Clock(_engine.EffectiveWorkedSeconds(gr))} · {_engine.Workspace.MatchesToday(gr.Id)}/{gr.MaxDailyMatches} {gr.MatchUnitPlural}", Foreground = BrushHex("#99A6AD"), FontSize = 12, Margin = new Thickness(0, 4, 0, 0) };
            info.Children.Add(titleBlock);
            info.Children.Add(subBlock);
            dock.Children.Add(info);
            _liveGameStrips.Add((gr, titleBlock, subBlock));
            PageContent.Children.Add(Card(dock));
        }

        // Quick capture into the inbox
        var captureBox = new System.Windows.Controls.TextBox { MinWidth = 320, Margin = new Thickness(0, 0, 8, 0) };
        void Capture()
        {
            var text = captureBox.Text;
            captureBox.Text = "";
            _engine.QuickCapture(text);
        }
        captureBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) Capture();
        };
        var captureRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        captureRow.Children.Add(captureBox);
        captureRow.Children.Add(SmallButton("Apuntar en la bandeja", Capture, true, 0));
        PageContent.Children.Add(SectionLabel("APUNTAR EN LA BANDEJA", 4));
        PageContent.Children.Add(captureRow);

        // Scheduled tasks of the chosen day
        var dayTasks = _engine.Workspace.Tasks
            .Where(t => !t.Completed && t.IsScheduled && t.ScheduledAt.LocalDateTime.Date == selected)
            .OrderBy(t => t.ScheduledAt)
            .ToList();

        PageContent.Children.Add(SectionLabel($"AGENDA ({dayTasks.Count})", 14));
        if (dayTasks.Count == 0)
        {
            PageContent.Children.Add(Card(new TextBlock
            {
                Text = "Sin tareas programadas este día. Pulsa «+ Nueva tarea» para crear tu primer bloque.",
                Foreground = BrushHex("#99A6AD"),
                FontSize = 13
            }));
        }
        foreach (var t in dayTasks) PageContent.Children.Add(TaskRow(t, scheduled: true));

        // Overdue: an occurrence of an earlier day that was not completed (also what a series leaves behind when it rolls forward)
        var sessionTaskId = _engine.Workspace.Session?.Task.Id;
        var overdue = _engine.Workspace.Tasks
            .Where(t => !t.Completed && t.IsScheduled && t.Id != sessionTaskId && t.ScheduledAt.LocalDateTime.Date < DateTime.Now.Date)
            .OrderBy(t => t.ScheduledAt)
            .ToList();
        if (overdue.Count > 0)
        {
            PageContent.Children.Add(SectionLabel($"ATRASADAS ({overdue.Count})", 14, "#FAC74D"));
            foreach (var t in overdue) PageContent.Children.Add(OverdueRow(t));
        }

        // Inbox
        var inbox = _engine.Workspace.Tasks.Where(t => !t.Completed && !t.IsScheduled).ToList();
        if (inbox.Count > 0)
        {
            PageContent.Children.Add(SectionLabel($"BANDEJA SIN HORA ({inbox.Count})", 14));
            foreach (var t in inbox) PageContent.Children.Add(TaskRow(t, scheduled: false));
        }
    }

    /// <summary>One task of the agenda (or of the inbox) with what can be done to it.</summary>
    private Border TaskRow(FocusTask t, bool scheduled)
    {
        var dock = new DockPanel();
        var right = new WrapPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 430, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        var start = PrimaryButton("Iniciar");
        start.Margin = new Thickness(0, 0, 6, 4);
        start.Click += (_, _) => StartOrHandoffSession(t);
        right.Children.Add(start);
        if (scheduled)
        {
            var snooze = new System.Windows.Controls.Button { Content = "+10m", Margin = new Thickness(0, 0, 6, 4) };
            snooze.Click += (_, _) => ConfirmAndSnoozeTask(t);
            right.Children.Add(snooze);
            var tomorrow = new System.Windows.Controls.Button { Content = "Mañana", Margin = new Thickness(0, 0, 6, 4) };
            tomorrow.Click += (_, _) => ApplyTaskChange(t, $"mover a mañana «{t.Title}»", bypass => _engine.MoveToTomorrowSameTime(t, bypass));
            right.Children.Add(tomorrow);
            var inboxButton = new System.Windows.Controls.Button { Content = "Bandeja", Margin = new Thickness(0, 0, 6, 4) };
            inboxButton.Click += (_, _) => ApplyTaskChange(t, $"pasar a la bandeja «{t.Title}»", bypass => _engine.MoveToInbox(t, bypass));
            right.Children.Add(inboxButton);
        }
        else
        {
            var todayButton = new System.Windows.Controls.Button { Content = "Programar hoy", Margin = new Thickness(0, 0, 6, 4) };
            todayButton.Click += (_, _) => ApplyTaskChange(t, $"programar «{t.Title}»", bypass => _engine.ScheduleInFirstFreeSlot(t, bypass));
            right.Children.Add(todayButton);
        }
        var edit = new System.Windows.Controls.Button { Content = "Editar", Margin = new Thickness(0, 0, 6, 4) };
        edit.Click += (_, _) => Dialogs.ShowTaskEditor(_engine, t, this);
        right.Children.Add(edit);
        var del = new System.Windows.Controls.Button { Content = "Borrar", Margin = new Thickness(0, 0, 0, 4) };
        del.Click += (_, _) => ConfirmAndDeleteTask(t);
        right.Children.Add(del);
        DockPanel.SetDock(right, Dock.Right);
        dock.Children.Add(right);

        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = t.Title, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        var meta = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        if (scheduled) meta.Children.Add(PillBadge($"{t.ScheduledAt.LocalDateTime:HH:mm}–{t.End.LocalDateTime:HH:mm}", "#38A169", "#16291F"));
        meta.Children.Add(PillBadge(FocusRules.DurationText(t.Minutes)));
        meta.Children.Add(PillBadge(t.Category));
        if (t.RepeatRule != RepeatRule.Never) meta.Children.Add(PillBadge("↻ " + t.RepeatRule.Label()));
        if (t.Protection != SessionProtection.None)
            meta.Children.Add(PillBadge(_engine.IsTaskProtected(t) ? $"Ya protegida · {t.Protection.Label()}" : t.Protection.Label(), "#FAC74D", "#251D10"));
        if (t.Enforces && t.Protection == SessionProtection.None) meta.Children.Add(PillBadge(t.BlockingSummary, "#99A6AD", "#1D2229"));
        left.Children.Add(meta);
        dock.Children.Add(left);
        return Card(dock);
    }

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
