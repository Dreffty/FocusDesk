using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

/// <summary>The anti-distraction pages: Reglas y juegos, Bloquear ahora and Descansos (macOS ProtectionPages.swift).</summary>
public partial class MainWindow
{
    private SessionProtection _quickProtection = SessionProtection.Challenge;
    private DistractionPreset? _quickPreset;
    private string _exceptionTarget = "";
    private bool _exceptionIsApp;
    private int _exceptionMinutes = 15;

    // MARK: - Reglas y juegos

    private void BuildRulesPage()
    {
        var headerButtons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        headerButtons.Children.Add(SmallButton("Exportar reglas…", ExportRulesFile, _engine.Workspace.GeneralRules.Count > 0, 12));
        var createBtn = PrimaryButton("+ Regla personalizada");
        createBtn.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, null, this);
        headerButtons.Children.Add(createBtn);
        PageContent.Children.Add(PageHeader("Reglas y juegos", "Tus límites automáticos, también fuera de las tareas.", headerButtons));

        PageContent.Children.Add(SectionLabel("PLANTILLAS DE JUEGOS · PRIMERO ESTUDIO, LUEGO PARTIDA", 2));
        var wrap = new WrapPanel { Margin = new Thickness(0, 0, 0, 18) };
        foreach (var game in GameCatalog.All)
        {
            var btn = new System.Windows.Controls.Button
            {
                Width = 216,
                Margin = new Thickness(0, 0, 10, 10),
                HorizontalContentAlignment = System.Windows.HorizontalAlignment.Left,
                Padding = new Thickness(14, 11, 14, 11),
                Background = BrushHex("#161B21"),
                BorderBrush = BrushHex("#262A30")
            };
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = game.Name, FontWeight = FontWeights.SemiBold, FontSize = 13.5, Foreground = BrushHex("#EDF2F5") });
            sp.Children.Add(new TextBlock
            {
                Text = game.Detection.IsExact() ? game.Detection.Label() : $"{game.TypicalMatchMinutes} min + prórroga",
                FontSize = 11.5,
                Foreground = BrushHex("#38A169"),
                Margin = new Thickness(0, 3, 0, 0)
            });
            btn.Content = sp;
            btn.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, GeneralBlockRule.GameTemplate(game), this);
            wrap.Children.Add(btn);
        }
        PageContent.Children.Add(wrap);

        PageContent.Children.Add(SectionLabel($"TUS REGLAS ({_engine.Workspace.GeneralRules.Count})", 4));
        foreach (var rule in _engine.Workspace.GeneralRules)
        {
            var sp = new StackPanel();
            var header = new DockPanel();
            var actions = new WrapPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 520, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
            var now = DateTimeOffset.Now;
            var cont = TrustedClock.ContinuousSeconds();

            if (rule.Kind == GeneralRuleKind.Pomodoro)
            {
                actions.Children.Add(SmallButton("Iniciar Pomodoro", () =>
                {
                    var loosening = _engine.RestartLoosening(rule, GeneralRuleKind.Pomodoro);
                    if (loosening != null && !UnlockRuleFor(rule, loosening)) return;
                    _engine.StartRulePomodoro(rule);
                }));
                if (rule.PomodoroPhase == PomodoroPhase.WaitingForUser)
                    actions.Children.Add(SmallButton("Continuar a siguiente fase", () => _engine.ContinuePomodoro(rule)));
                else if (rule.Enabled && rule.PomodoroPhase != PomodoroPhase.Idle)
                    actions.Children.Add(SmallButton("Saltar fase", () =>
                    {
                        if (rule.PomodoroPhase == PomodoroPhase.Work && !UnlockRuleFor(rule, $"saltar el enfoque de «{rule.Name}»")) return;
                        _engine.SkipPomodoroPhase(rule);
                    }));
            }
            if (rule.Kind == GeneralRuleKind.Countdown)
            {
                actions.Children.Add(SmallButton($"Activar {rule.CountdownMinutes}m", () =>
                {
                    // Pressing it again on a protected block that is running must not shorten it without the code.
                    var loosening = _engine.RestartLoosening(rule, GeneralRuleKind.Countdown);
                    if (loosening != null && !UnlockRuleFor(rule, loosening)) return;
                    _engine.StartRuleCountdown(rule);
                }));
            }
            if (rule.Kind == GeneralRuleKind.LaunchLimit && rule.IsInLaunchVisit(now, cont))
                actions.Children.Add(SmallButton("Terminar visita", () => _engine.EndLaunchVisit(rule)));
            if (rule.Kind is GeneralRuleKind.DailyLimit or GeneralRuleKind.LaunchLimit or GeneralRuleKind.WorkGoal)
            {
                actions.Children.Add(SmallButton("Reiniciar contador", () =>
                {
                    if (_engine.IsRuleEnforcing(rule) && !UnlockRuleFor(rule, $"reiniciar el límite de «{rule.Name}»")) return;
                    _engine.ResetDailyQuota(rule);
                }));
            }
            var microLeft = Math.Max(0, rule.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(rule.Id));
            if (_engine.IsRuleEnforcing(rule) && microLeft > 0)
                actions.Children.Add(SmallButton($"Micro-pausa {rule.MicroPauseMinutes} min ({microLeft})", () => _engine.UseMicroPause(rule)));

            actions.Children.Add(SmallButton(rule.Enabled ? "Apagar…" : "Activar", () =>
            {
                if (rule.Enabled && _engine.IsRuleProtected(rule))
                {
                    if (!UnlockRuleFor(rule, $"apagar «{rule.Name}»")) return;
                }
                rule.Enabled = !rule.Enabled;
                if (!rule.Enabled && rule.Kind == GeneralRuleKind.Pomodoro)
                {
                    rule.PomodoroPhase = PomodoroPhase.Idle;
                    rule.ActivePomodoroDeadline = null;
                }
                else if (rule.Enabled && rule.Kind == GeneralRuleKind.Countdown &&
                         (rule.ActiveDeadline?.RemainingAfterPossibleReboot() ?? 0) <= 0)
                {
                    rule.StartCountdown();
                }
                else if (rule.Enabled && rule.Kind == GeneralRuleKind.Pomodoro && rule.PomodoroPhase == PomodoroPhase.Idle)
                {
                    rule.StartPomodoro();
                }
                _engine.Persist();
                _engine.EnsureWatcherIfNeeded();
            }));
            actions.Children.Add(SmallButton("Editar", () => Dialogs.ShowRuleEditor(_engine, rule, null, this)));
            actions.Children.Add(SmallButton("Eliminar regla", () =>
            {
                var bypass = false;
                if (_engine.IsRuleProtected(rule))
                {
                    if (!UnlockRuleFor(rule, $"borrar «{rule.Name}»")) return;
                    bypass = true;
                }
                _engine.DeleteGeneralRule(rule, bypassProtection: bypass);
            }, true, 0));
            DockPanel.SetDock(actions, Dock.Right);
            header.Children.Add(actions);

            var titleStack = new StackPanel();
            var enforcing = _engine.IsRuleEnforcing(rule);
            titleStack.Children.Add(new TextBlock { Text = rule.Name, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            var pills = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
            pills.Children.Add(PillBadge(rule.Kind.GalleryTitle()));
            pills.Children.Add(PillBadge(enforcing ? "Bloqueando" : rule.Enabled ? "Activa" : "Apagada", enforcing ? "#38A169" : rule.Enabled ? "#E4E9EC" : "#7C868C", enforcing ? "#16291F" : "#1D2229"));
            pills.Children.Add(PillBadge(rule.Protection.Label(), rule.Protection == SessionProtection.None ? "#99A6AD" : "#FAC74D", rule.Protection == SessionProtection.None ? "#1D2229" : "#251D10"));
            if (rule.AlwaysProtected) pills.Children.Add(PillBadge("Obligatoria 24/7", "#FAC74D", "#251D10"));
            titleStack.Children.Add(pills);
            titleStack.Children.Add(MutedText(RuleInfoLine(rule), 12, 6));
            header.Children.Add(titleStack);
            sp.Children.Add(header);

            if (rule.Kind == GeneralRuleKind.WorkGoal && rule.MaxDailyMatches > 0)
            {
                var st = _engine.GameRuleStatus(rule);
                if (st.CanFinish)
                {
                    var gRow = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
                    var finBtn = new System.Windows.Controls.Button { Content = "He terminado" };
                    DockPanel.SetDock(finBtn, Dock.Right);
                    finBtn.Click += (_, _) => _engine.FinishTimedMatch(rule, TimedMatchPlanner.FinishReason.UserFinished);
                    gRow.Children.Add(finBtn);
                    gRow.Children.Add(new TextBlock { Text = st.Text, Foreground = BrushHex(st.Warning ? "#FAC74D" : "#38A169"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
                    sp.Children.Add(gRow);
                }
            }

            PageContent.Children.Add(Card(sp, enforcing ? "#2A5A3F" : null));
        }

        BuildTemporaryExceptions();
    }

    private void ExportRulesFile()
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { FileName = "FocusDesk-reglas.json", Filter = "JSON (*.json)|*.json" };
        if (dialog.ShowDialog() != true) return;
        try { _engine.ExportRules(dialog.FileName); }
        catch (Exception ex)
        {
            _engine.Error = $"No se pudieron exportar las reglas: {ex.Message}";
            UpdateNoticeAndSidebar();
        }
    }

    /// <summary>Lets a site or a program through for a while, without touching the rules (macOS: «Permitir» for X min).</summary>
    private void BuildTemporaryExceptions()
    {
        PageContent.Children.Add(SectionLabel("EXCEPCIONES TEMPORALES", 10));
        var sp = new StackPanel();
        sp.Children.Add(MutedText("Deja pasar una web (docs.swift.org, youtube.com/watch) o un programa (discord) durante unos minutos. No se puede añadir mientras algo protegido esté bloqueando.", 12, 0));

        var targetBox = new System.Windows.Controls.TextBox { Text = _exceptionTarget, Width = 260 };
        targetBox.LostFocus += (_, _) => _exceptionTarget = targetBox.Text;
        var kindBox = ChoiceBox(new[] { new ComboOption<bool>(false, "Web"), new ComboOption<bool>(true, "Programa") }, _exceptionIsApp, v => _exceptionIsApp = v, 110);
        var minutesBox = ChoiceBox(new[] { 5, 10, 15, 30, 60 }.Select(m => new ComboOption<int>(m, $"{m} min")), _exceptionMinutes, v => _exceptionMinutes = v, 100);
        var addButton = PrimaryButton("Permitir");
        addButton.Margin = new Thickness(0, 22, 0, 0);
        addButton.Click += (_, _) =>
        {
            _exceptionTarget = targetBox.Text;
            var problem = _engine.AddTemporaryAllow(_exceptionTarget, _exceptionIsApp, _exceptionMinutes);
            if (problem != null)
            {
                _engine.Error = problem;
                UpdateNoticeAndSidebar();
                return;
            }
            _exceptionTarget = "";
            _engine.Error = "";
            RefreshUI();
        };
        var form = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        form.Children.Add(Labeled("Web o programa", targetBox, 6));
        form.Children.Add(Labeled("Tipo", kindBox, 6));
        form.Children.Add(Labeled("Durante", minutesBox, 6));
        form.Children.Add(addButton);
        sp.Children.Add(form);

        var now = DateTimeOffset.Now;
        var cont = TrustedClock.ContinuousSeconds();
        var active = _engine.Workspace.TemporaryAllows.Where(a => a.IsActive(now, cont)).ToList();
        if (active.Count > 0)
        {
            sp.Children.Add(SectionLabel("PERMITIDO AHORA", 12));
            foreach (var entry in active)
            {
                var left = entry.Deadline.RemainingAfterPossibleReboot(now, cont);
                var line = new DockPanel { Margin = new Thickness(0, 3, 0, 0) };
                var remove = SmallButton("Quitar", () => _engine.RemoveTemporaryAllow(entry), true, 0);
                DockPanel.SetDock(remove, Dock.Right);
                line.Children.Add(remove);
                line.Children.Add(new TextBlock
                {
                    Text = $"{(entry.IsAppBundleId ? "Programa" : "Web")} · {entry.Target} · quedan {FocusRules.Clock(left)}",
                    FontSize = 13,
                    VerticalAlignment = VerticalAlignment.Center
                });
                sp.Children.Add(line);
            }
        }
        PageContent.Children.Add(Card(sp));
    }

    // MARK: - Bloquear ahora

    private void BuildBlockingPage()
    {
        PageContent.Children.Add(PageHeader("Bloquear ahora", "Activa un bloqueo inmediato o inicia un perfil reutilizable con un clic."));

        var quickStack = new StackPanel();
        quickStack.Children.Add(new TextBlock { Text = "BLOQUEO RÁPIDO INMEDIATO", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#38A169") });
        quickStack.Children.Add(MutedText("Una cuenta atrás de bloqueo sin crear una tarea en la agenda. Elige qué cerrar y cómo parar:", 12, 4));
        var presetOptions = new List<ComboOption<DistractionPreset?>> { new(null, "Redes sociales + Shorts y Reels") };
        presetOptions.AddRange(DistractionPreset.All.Select(p => new ComboOption<DistractionPreset?>(p, p.Label)));
        var options = new WrapPanel { Margin = new Thickness(0, 0, 0, 4) };
        options.Children.Add(Labeled("Qué bloquear", ChoiceBox(presetOptions, _quickPreset, v => _quickPreset = v, 250), 6));
        options.Children.Add(Labeled("Si quiero pararlo", ChoiceBox(new[]
        {
            new ComboOption<SessionProtection>(SessionProtection.None, "Sin protección"),
            new ComboOption<SessionProtection>(SessionProtection.Challenge, "Código de desbloqueo"),
            new ComboOption<SessionProtection>(SessionProtection.Delay, "Espera"),
            new ComboOption<SessionProtection>(SessionProtection.Forced, "Hasta el final")
        }, _quickProtection, v => _quickProtection = v, 210), 6));
        quickStack.Children.Add(options);
        var quickBtns = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var (mins, label) in new[] { (15, "15 min"), (30, "30 min"), (45, "45 min"), (60, "1 hora"), (120, "2 horas"), (240, "4 horas") })
        {
            var captured = mins;
            var b = new System.Windows.Controls.Button { Content = $"Bloquear {label}", Margin = new Thickness(0, 0, 8, 8) };
            b.Click += (_, _) => _engine.LaunchQuickBlock(captured, _quickProtection, _quickPreset);
            quickBtns.Children.Add(b);
        }
        var restOfDayMins = Math.Max(15, (int)(DateTime.Now.Date.AddDays(1) - DateTime.Now).TotalMinutes);
        var restBtn = PrimaryButton("Resto del día");
        restBtn.Margin = new Thickness(0, 0, 8, 8);
        restBtn.Click += (_, _) => _engine.LaunchQuickBlock(restOfDayMins, _quickProtection, _quickPreset);
        quickBtns.Children.Add(restBtn);
        quickStack.Children.Add(quickBtns);
        PageContent.Children.Add(Card(quickStack, "#2A5A3F"));

        var activeRules = _engine.Workspace.GeneralRules.Where(r => _engine.IsRuleEnforcing(r)).ToList();
        if (activeRules.Count > 0)
        {
            PageContent.Children.Add(SectionLabel($"BLOQUEANDO AHORA ({activeRules.Count})", 8));
            foreach (var r in activeRules)
            {
                var dock = new DockPanel();
                var microLeft = Math.Max(0, r.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(r.Id));
                if (microLeft > 0)
                {
                    var mpBtn = SmallButton($"Micro-pausa {r.MicroPauseMinutes} min ({microLeft})", () => _engine.UseMicroPause(r), true, 0);
                    mpBtn.VerticalAlignment = VerticalAlignment.Center;
                    DockPanel.SetDock(mpBtn, Dock.Right);
                    dock.Children.Add(mpBtn);
                }
                var sp = new StackPanel();
                sp.Children.Add(new TextBlock { Text = r.Name, FontSize = 14.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#38A169") });
                sp.Children.Add(MutedText($"{r.Kind.GalleryTitle()} · Protección: {r.Protection.Label()} · {RuleInfoLine(r)}", 12, 3));
                dock.Children.Add(sp);
                PageContent.Children.Add(Card(dock, "#2A5A3F"));
            }
        }

        var profileHeader = new DockPanel { Margin = new Thickness(0, 8, 0, 10) };
        var newProfile = SmallButton("+ Nuevo perfil", () => Dialogs.ShowProfileEditor(_engine, null, this), true, 0);
        DockPanel.SetDock(newProfile, Dock.Right);
        profileHeader.Children.Add(newProfile);
        profileHeader.Children.Add(new TextBlock { Text = "PERFILES REUTILIZABLES", FontSize = 11, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#99A6AD"), VerticalAlignment = VerticalAlignment.Center });
        PageContent.Children.Add(profileHeader);
        foreach (var profile in _engine.Workspace.Profiles)
        {
            var dock = new DockPanel();
            var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            var launch = PrimaryButton($"Empezar {profile.Minutes} min");
            launch.Margin = new Thickness(0, 0, 6, 0);
            launch.Click += (_, _) =>
            {
                var t = new FocusTask { Title = profile.Name, ScheduledAt = DateTimeOffset.Now };
                t.Apply(profile);
                if (!t.Valid)
                {
                    _engine.Error = $"El perfil «{profile.Name}» está incompleto: revisa las apps del modo estricto o las webs.";
                    UpdateNoticeAndSidebar();
                    return;
                }
                _engine.SaveTask(t);
                if (!string.IsNullOrEmpty(_engine.Error)) { UpdateNoticeAndSidebar(); return; }
                StartOrHandoffSession(t);
                _engine.ActivePage = "Hoy";
            };
            buttons.Children.Add(launch);
            buttons.Children.Add(SmallButton("Editar", () => Dialogs.ShowProfileEditor(_engine, profile, this)));
            buttons.Children.Add(SmallButton("Borrar perfil", () =>
            {
                var answer = System.Windows.MessageBox.Show(this, $"¿Borrar el perfil «{profile.Name}»?", "Borrar perfil · FocusDesk",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _engine.DeleteProfile(profile.Id);
            }, true, 0));
            DockPanel.SetDock(buttons, Dock.Right);
            dock.Children.Add(buttons);
            var sp = new StackPanel();
            sp.Children.Add(new TextBlock { Text = profile.Name, FontSize = 15, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(MutedText($"{profile.Category} · {profile.Minutes} min · {profile.Protection.Label()} · {(string.IsNullOrEmpty(profile.Domains) ? "sin lista web" : profile.Domains)}", 12, 4));
            dock.Children.Add(sp);
            PageContent.Children.Add(Card(dock));
        }
    }

    // MARK: - Descansos

    private void BuildBreaksPage()
    {
        PageContent.Children.Add(PageHeader("Descansos", "Descansa la vista y la mente antes de necesitarlo."));
        var s = _engine.Workspace.Settings;

        // Rest of the eyes after a long time at the computer
        var eyes = new StackPanel();
        eyes.Children.Add(SectionLabel("DESCANSO CONTINUO DE VISTA", 0, "#38A169"));
        eyes.Children.Add(ToggleBox("Sugerir un descanso breve tras usar el equipo de forma continua", s.ContinuousBreakEnabled, v =>
        {
            ChangeSetting(x => x.ContinuousBreakEnabled = v);
        }, 0));
        eyes.Children.Add(WrapRow(
            Labeled("Cada (min de trabajo)", NumberBox(s.ContinuousWorkMinutes, 15, 180, v => ChangeSetting(x => x.ContinuousWorkMinutes = v)), 8),
            Labeled("Descansar (min)", NumberBox(s.ContinuousBreakDurationMinutes, 1, 30, v => ChangeSetting(x => x.ContinuousBreakDurationMinutes = v)), 8),
            Labeled("Máx. saltos al día", NumberBox(s.ContinuousBreakMaxSkipsPerDay, 0, 10, v => ChangeSetting(x => x.ContinuousBreakMaxSkipsPerDay = v)), 8)));
        if (_engine.ActiveContinuousBreakDeadline != null)
        {
            _liveContinuousBreakText = new TextBlock
            {
                Text = $"Descanso de vista · {FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot())} · {_engine.ActiveContinuousBreakMessage}",
                Foreground = BrushHex("#38A169"),
                FontSize = 13,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 10, 0, 0)
            };
            eyes.Children.Add(_liveContinuousBreakText);
            eyes.Children.Add(Row(SmallButton($"Posponer ({_engine.ContinuousBreakSkipsLeft})", () => _engine.SkipContinuousBreak(), _engine.ContinuousBreakSkipsLeft > 0)));
        }
        else
        {
            eyes.Children.Add(Row(SmallButton("Descansar ahora", () => _engine.StartContinuousBreakNow(), s.ContinuousBreakEnabled)));
        }
        eyes.Children.Add(SectionLabel("MENSAJES DE DESCANSO (UNO POR LÍNEA)", 14));
        var messagesBox = new System.Windows.Controls.TextBox
        {
            Text = string.Join(Environment.NewLine, s.BreakMessages),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 90
        };
        messagesBox.LostFocus += (_, _) =>
        {
            var lines = messagesBox.Text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            ChangeSetting(x => x.BreakMessages = lines.Count > 0 ? lines : new Settings().BreakMessages);
        };
        eyes.Children.Add(messagesBox);
        PageContent.Children.Add(Card(eyes));

        // Scheduled breaks (lunch, siesta…)
        var scheduled = new StackPanel();
        scheduled.Children.Add(SectionLabel("DESCANSOS PROGRAMADOS", 0, "#38A169"));
        scheduled.Children.Add(ToggleBox("Mostrar aviso y cuenta atrás cuando empiece un descanso", s.EnforceBreaks, v => ChangeSetting(x => x.EnforceBreaks = v), 0));
        foreach (var br in s.Breaks.ToList())
        {
            var line = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
            var remove = SmallButton("Quitar", () =>
            {
                ChangeSetting(x => x.Breaks.RemoveAll(b => b.Id == br.Id));
                RefreshUI();
            }, true, 0);
            DockPanel.SetDock(remove, Dock.Right);
            line.Children.Add(remove);
            line.Children.Add(new TextBlock { Text = $"{br.Title} · {br.StartHour:D2}:{br.StartMinute:D2} ({br.DurationMinutes} min)", FontSize = 14, VerticalAlignment = VerticalAlignment.Center });
            scheduled.Children.Add(line);
        }
        if (s.Breaks.Count == 0) scheduled.Children.Add(MutedText("Sin descansos programados.", 12.5, 8));

        var titleBox = new System.Windows.Controls.TextBox { Text = "Descanso", Width = 190 };
        var hourBox = NumberBox(14, 0, 23, _ => { }, 60);
        var minuteBox = NumberBox(0, 0, 59, _ => { }, 60);
        var durationBox = NumberBox(60, 5, 240, _ => { }, 70);
        var addBreak = PrimaryButton("Añadir descanso");
        addBreak.Margin = new Thickness(0, 22, 0, 0);
        addBreak.Click += (_, _) =>
        {
            // The boxes apply their value on losing focus: read them directly so the click always sees what is typed.
            int Read(System.Windows.Controls.TextBox box, int min, int max, int fallback) =>
                int.TryParse(box.Text.Trim(), out var parsed) ? Math.Clamp(parsed, min, max) : fallback;
            var title = string.IsNullOrWhiteSpace(titleBox.Text) ? "Descanso" : titleBox.Text.Trim();
            var period = new BreakPeriod
            {
                Title = title,
                StartHour = Read(hourBox, 0, 23, 14),
                StartMinute = Read(minuteBox, 0, 59, 0),
                DurationMinutes = Read(durationBox, 5, 240, 60)
            };
            ChangeSetting(x => x.Breaks.Add(period));
            RefreshUI();
        };
        var form = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        form.Children.Add(Labeled("Nombre", titleBox, 10));
        form.Children.Add(Labeled("Hora", hourBox, 10));
        form.Children.Add(Labeled("Minuto", minuteBox, 10));
        form.Children.Add(Labeled("Duración (min)", durationBox, 10));
        form.Children.Add(addBreak);
        scheduled.Children.Add(form);
        PageContent.Children.Add(Card(scheduled));
    }
}
