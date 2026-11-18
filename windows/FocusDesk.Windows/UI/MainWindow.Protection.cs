using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
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

    private static string RuleKindGlyph(GeneralRuleKind kind) => kind switch
    {
        GeneralRuleKind.DailyLimit => "",
        GeneralRuleKind.Pomodoro => "",
        GeneralRuleKind.WorkGoal => "",
        GeneralRuleKind.LaunchLimit => "",
        GeneralRuleKind.Countdown => "",
        GeneralRuleKind.Schedule => "",
        GeneralRuleKind.AlwaysOn => "",
        _ => ""
    };

    /// <summary>The square icon tile of the Mac cards (tinted green when it is blocking).</summary>
    private static Border IconTile(string glyph, bool active = false, double size = 40)
    {
        var g = Glyph(glyph, size * 0.42, active ? "#0D1014" : "#38A169");
        g.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        return new Border
        {
            Width = size,
            Height = size,
            CornerRadius = new CornerRadius(size * 0.26),
            Background = BrushHex(active ? "#38A169" : "#15291F"),
            Child = g,
            VerticalAlignment = VerticalAlignment.Top
        };
    }

    /// <summary>A section title with a muted caption beside it («Crear una regla  Elige cómo funciona…»).</summary>
    private static UIElement PageSectionTitle(string title, string caption, double top = 6)
    {
        var tb = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, top, 0, 14) };
        tb.Inlines.Add(new System.Windows.Documents.Run(title) { FontSize = 21, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#EDF2F5") });
        if (!string.IsNullOrEmpty(caption))
            tb.Inlines.Add(new System.Windows.Documents.Run("   " + caption) { FontSize = 14.5, Foreground = BrushHex("#99A6AD") });
        return tb;
    }

    /// <summary>A clickable tile of the «Crear una regla» and game galleries.</summary>
    private static System.Windows.Controls.Button GalleryTile(string glyph, string title, string text, Action onClick, double width, bool dashed = false)
    {
        var sp = new StackPanel();
        var tile = IconTile(glyph, false, 36);
        tile.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
        sp.Children.Add(tile);
        sp.Children.Add(new TextBlock { Text = title, FontSize = 16.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#EDF2F5"), Margin = new Thickness(0, 12, 0, 4), TextWrapping = TextWrapping.Wrap });
        sp.Children.Add(new TextBlock { Text = text, FontSize = 13.5, FontWeight = FontWeights.Normal, Foreground = BrushHex("#99A6AD"), TextWrapping = TextWrapping.Wrap });
        var button = new System.Windows.Controls.Button
        {
            Content = sp,
            Width = width,
            Margin = new Thickness(0, 0, 12, 12),
            Padding = new Thickness(16, 16, 16, 16),
            HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
            Background = BrushHex("#161B21"),
            BorderBrush = BrushHex(dashed ? "#3A3F46" : "#262A30")
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    private void ToggleRuleEnabled(GeneralBlockRule rule)
    {
        if (rule.Enabled && _engine.IsRuleProtected(rule))
        {
            if (!UnlockRuleFor(rule, $"apagar «{rule.Name}»")) { RefreshUI(); return; }
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
        RefreshUI();
    }

    // MARK: - Reglas y juegos

    private void BuildRulesPage()
    {
        var headerButtons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var export = GlyphButton("", "Exportar…", ExportRulesFile, plain: true);
        export.IsEnabled = _engine.Workspace.GeneralRules.Count > 0;
        headerButtons.Children.Add(export);
        headerButtons.Children.Add(GlyphButton("", "Nueva regla", () => Dialogs.ShowRuleEditor(_engine, null, null, this), primary: true));
        PageContent.Children.Add(PageHeader("Reglas y límites", "Tus límites, también fuera de las tareas.", headerButtons));

        // Create: one tile per kind of rule, as on the Mac
        PageContent.Children.Add(PageSectionTitle("Crear una regla", "Elige cómo funciona; qué bloquea lo eliges en el paso siguiente."));
        var kinds = new UniformGrid { Columns = 4, Margin = new Thickness(0, 0, -12, 10) };
        void Kind(GeneralRuleKind kind, string title, string text, Action<GeneralBlockRule> setup)
        {
            kinds.Children.Add(GalleryTile(RuleKindGlyph(kind), title, text, () =>
            {
                var template = new GeneralBlockRule { Kind = kind, Name = title };
                setup(template);
                Dialogs.ShowRuleEditor(_engine, null, template, this);
            }, double.NaN));
        }
        Kind(GeneralRuleKind.DailyLimit, "Presupuesto de uso", "20 min al día de YouTube y Shorts; luego, bloqueado.", r => r.DailyLimitMinutes = 20);
        Kind(GeneralRuleKind.Pomodoro, "Pomodoro", "25 min de foco y 5 de descanso; si te distraes, vuelve a empezar.", _ => { });
        Kind(GeneralRuleKind.WorkGoal, "Primero el trabajo", "Tras 60 min de tareas, 20 min de ocio de premio.", r => { r.GoalMinutesRequired = 60; r.GoalRewardMinutes = 20; });
        Kind(GeneralRuleKind.LaunchLimit, "Visitas contadas", "4 visitas al día de 5 min, con 30 min de enfriamiento.", r => { r.MaxDailyLaunches = 4; r.MaxLaunchDurationMinutes = 5; r.LaunchCooldownMinutes = 30; });
        Kind(GeneralRuleKind.Countdown, "Cuenta atrás", "Una cuenta atrás guardada que lanzas cuando quieras.", r => r.CountdownMinutes = 60);
        Kind(GeneralRuleKind.Schedule, "Horario", "De 22:30 a 7:30 todos los días, o en varios tramos.", r => { r.StartMinutes = 22 * 60 + 30; r.EndMinutes = 7 * 60 + 30; });
        Kind(GeneralRuleKind.AlwaysOn, "Siempre activa", "Bloqueadas a todas horas mientras esté encendida.", _ => { });
        PageContent.Children.Add(kinds);

        // Games: «primero estudio, luego partida»
        PageContent.Children.Add(PageSectionTitle("Juegos: primero estudio, luego partida", "Una hora de estudio por partida y nunca te saca a mitad. Eliges el juego y ya viene preparada."));
        var games = new UniformGrid { Columns = 4, Margin = new Thickness(0, 0, -12, 10) };
        foreach (var game in GameCatalog.All)
        {
            var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            row.Children.Add(IconTile("", false, 34));
            var text = new StackPanel { Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = game.Name, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#EDF2F5"), TextWrapping = TextWrapping.Wrap });
            text.Children.Add(new TextBlock
            {
                Text = game.Detection.IsExact() ? "Detección exacta de cada partida" : $"{game.TypicalMatchMinutes} min por partida + prórroga",
                FontSize = 13,
                FontWeight = FontWeights.Normal,
                Foreground = BrushHex("#99A6AD"),
                TextWrapping = TextWrapping.Wrap,
                MaxWidth = 170
            });
            row.Children.Add(text);
            var captured = game;
            var b = new System.Windows.Controls.Button
            {
                Content = row,
                Margin = new Thickness(0, 0, 12, 12),
                Padding = new Thickness(14, 12, 14, 12),
                HorizontalContentAlignment = System.Windows.HorizontalAlignment.Left,
                Background = BrushHex("#161B21"),
                BorderBrush = BrushHex("#262A30")
            };
            b.Click += (_, _) => Dialogs.ShowRuleEditor(_engine, null, GeneralBlockRule.GameTemplate(captured), this);
            games.Children.Add(b);
        }
        PageContent.Children.Add(games);

        // Your rules: blocking now first, then the rest
        var rules = _engine.Workspace.GeneralRules.ToList();
        PageContent.Children.Add(PageSectionTitle($"Tus reglas · {rules.Count}", rules.Count == 0 ? "Todavía no tienes ninguna: empieza por una de arriba." : ""));
        var blockingNow = rules.Where(r => _engine.IsRuleEnforcing(r)).ToList();
        var others = rules.Except(blockingNow).ToList();
        if (blockingNow.Count > 0)
        {
            PageContent.Children.Add(SectionLabel("Bloqueando ahora", 0, "#38A169"));
            foreach (var rule in blockingNow) PageContent.Children.Add(RuleCard(rule, true));
        }
        if (others.Count > 0)
        {
            PageContent.Children.Add(SectionLabel(blockingNow.Count > 0 ? "El resto" : "Tus reglas", 8));
            foreach (var rule in others) PageContent.Children.Add(RuleCard(rule, false));
        }

    }

    /// <summary>One of your rules: icon, name, chips, what it is doing, its actions and the on/off switch.</summary>
    private Border RuleCard(GeneralBlockRule rule, bool enforcing)
    {
        var now = DateTimeOffset.Now;
        var cont = TrustedClock.ContinuousSeconds();
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var tile = IconTile(RuleKindGlyph(rule.Game != null ? GeneralRuleKind.WorkGoal : rule.Kind), enforcing, 44);
        if (rule.Game != null) ((TextBlock)tile.Child).Text = "";
        grid.Children.Add(tile);

        var middle = new StackPanel { Margin = new Thickness(16, 0, 12, 0) };
        middle.Children.Add(new TextBlock { Text = rule.Name, FontSize = 19, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Foreground = BrushHex(rule.Enabled ? "#EDF2F5" : "#99A6AD") });
        var chips = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        chips.Children.Add(Chip(rule.Kind.GalleryTitle(), "#99A6AD", "#22262C", RuleKindGlyph(rule.Kind)));
        if (enforcing) chips.Children.Add(Chip("Bloqueando ahora", "#38A169", "#15291F", ""));
        else if (!rule.Enabled) chips.Children.Add(Chip("Apagada", "#7C868C", "#1D2229"));
        if (rule.Protection != SessionProtection.None)
            chips.Children.Add(Chip(rule.Protection == SessionProtection.Challenge ? $"Código {rule.UnlockChars} dig." : rule.Protection.Label(), "#FAC74D", "#2E2614", ""));
        if (rule.AlwaysProtected) chips.Children.Add(Chip("Obligatoria 24/7", "#FAC74D", "#2E2614"));
        middle.Children.Add(chips);
        middle.Children.Add(MutedText(RuleInfoLine(rule), 12.5, 2));

        if (rule.Kind == GeneralRuleKind.WorkGoal && rule.MaxDailyMatches > 0)
        {
            var st = _engine.GameRuleStatus(rule);
            if (st.CanFinish)
            {
                var gRow = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
                var finBtn = SmallButton("He terminado", () => _engine.FinishTimedMatch(rule, TimedMatchPlanner.FinishReason.UserFinished), true, 0);
                DockPanel.SetDock(finBtn, Dock.Right);
                gRow.Children.Add(finBtn);
                gRow.Children.Add(new TextBlock { Text = st.Text, Foreground = BrushHex(st.Warning ? "#FAC74D" : "#38A169"), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
                middle.Children.Add(gRow);
            }
        }

        // Contextual actions under the text, like the Mac buttons next to each rule
        var actions = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        if (rule.Kind == GeneralRuleKind.Pomodoro)
        {
            if (rule.PomodoroPhase == PomodoroPhase.WaitingForUser)
                actions.Children.Add(SmallButton("Continuar a la siguiente fase", () => _engine.ContinuePomodoro(rule)));
            else if (rule.Enabled && rule.PomodoroPhase != PomodoroPhase.Idle)
                actions.Children.Add(SmallButton("Saltar fase", () =>
                {
                    if (rule.PomodoroPhase == PomodoroPhase.Work && !UnlockRuleFor(rule, $"saltar el enfoque de «{rule.Name}»")) return;
                    _engine.SkipPomodoroPhase(rule);
                }));
            else
                actions.Children.Add(SmallButton("Iniciar Pomodoro", () =>
                {
                    var loosening = _engine.RestartLoosening(rule, GeneralRuleKind.Pomodoro);
                    if (loosening != null && !UnlockRuleFor(rule, loosening)) return;
                    _engine.StartRulePomodoro(rule);
                }));
        }
        if (rule.Kind == GeneralRuleKind.Countdown)
        {
            actions.Children.Add(SmallButton($"Empezar {FocusRules.DurationText(rule.CountdownMinutes)}", () =>
            {
                // Pressing it again on a protected block that is running must not shorten it without the code.
                var loosening = _engine.RestartLoosening(rule, GeneralRuleKind.Countdown);
                if (loosening != null && !UnlockRuleFor(rule, loosening)) return;
                _engine.StartRuleCountdown(rule);
            }));
        }
        if (rule.Kind == GeneralRuleKind.LaunchLimit && rule.IsInLaunchVisit(now, cont))
            actions.Children.Add(SmallButton("Terminar visita", () => _engine.EndLaunchVisit(rule)));
        var microLeft = Math.Max(0, rule.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(rule.Id));
        if (enforcing && microLeft > 0)
            actions.Children.Add(SmallButton($"Micro-pausa {rule.MicroPauseMinutes} min ({microLeft})", () => _engine.UseMicroPause(rule)));
        actions.Children.Add(SmallButton("Editar", () => Dialogs.ShowRuleEditor(_engine, rule, null, this)));
        var more = IconButton("", "Más acciones", () => { });
        more.Margin = new Thickness(0);
        var menu = new ContextMenu();
        if (rule.Kind is GeneralRuleKind.DailyLimit or GeneralRuleKind.LaunchLimit or GeneralRuleKind.WorkGoal)
        {
            var reset = new MenuItem { Header = "Reiniciar el contador de hoy" };
            reset.Click += (_, _) =>
            {
                if (_engine.IsRuleEnforcing(rule) && !UnlockRuleFor(rule, $"reiniciar el límite de «{rule.Name}»")) return;
                _engine.ResetDailyQuota(rule);
            };
            menu.Items.Add(reset);
        }
        var delete = new MenuItem { Header = "Eliminar la regla…" };
        delete.Click += (_, _) =>
        {
            var bypass = false;
            if (_engine.IsRuleProtected(rule))
            {
                if (!UnlockRuleFor(rule, $"borrar «{rule.Name}»")) return;
                bypass = true;
            }
            _engine.DeleteGeneralRule(rule, bypassProtection: bypass);
        };
        menu.Items.Add(delete);
        more.ContextMenu = menu;
        more.Click += (_, _) => { menu.PlacementTarget = more; menu.IsOpen = true; };
        actions.Children.Add(more);
        middle.Children.Add(actions);
        Grid.SetColumn(middle, 1);
        grid.Children.Add(middle);

        var toggle = new System.Windows.Controls.CheckBox { IsChecked = rule.Enabled, VerticalAlignment = VerticalAlignment.Top, ToolTip = rule.Enabled ? "Apagar" : "Encender" };
        toggle.Style = (Style)System.Windows.Application.Current.FindResource("Switch");
        toggle.Click += (_, _) => ToggleRuleEnabled(rule);
        Grid.SetColumn(toggle, 2);
        grid.Children.Add(toggle);
        return Card(grid, enforcing ? "#2A5A3F" : null);
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
        var sp = new StackPanel();
        sp.Children.Add(MutedText("Para consultar algo puntual: una web (docs.swift.org, youtube.com/watch) o un programa (discord). Al llegar a cero se vuelve a bloquear sola. No se puede añadir mientras algo protegido esté bloqueando.", 12.5, 0));

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
            sp.Children.Add(SectionLabel("Permitido ahora", 12));
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
                    FontSize = 14,
                    VerticalAlignment = VerticalAlignment.Center
                });
                sp.Children.Add(line);
            }
        }
        PageContent.Children.Add(GroupCard("Permitir una web unos minutos", "\uE8D7", sp));
    }

    // MARK: - Bloquear ahora

    private static string PresetGlyph(DistractionPreset? p) => p?.Id switch
    {
        "social" => "",
        "shortVideos" => "",
        "streaming" => "",
        "games" => "",
        _ => ""
    };

    /// <summary>A switch row of «Mientras bloquea» and Ajustes: text on the left, Mac switch on the right.</summary>
    private static System.Windows.Controls.CheckBox SwitchRow(string text, bool on, Action<bool> onChange, double top = 10)
    {
        var box = new System.Windows.Controls.CheckBox
        {
            Content = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, FontSize = 14.5 },
            IsChecked = on,
            Margin = new Thickness(0, top, 0, 0),
            HorizontalContentAlignment = System.Windows.HorizontalAlignment.Stretch
        };
        box.Style = (Style)System.Windows.Application.Current.FindResource("Switch");
        box.Click += (_, _) => onChange(box.IsChecked == true);
        return box;
    }

    private void BuildBlockingPage()
    {
        PageContent.Children.Add(PageHeader("Bloquear ahora", "Corta las distracciones ahora mismo.",
            GlyphButton("", "Nueva regla", () => Dialogs.ShowRuleEditor(_engine, null, null, this), primary: true)));
        var now = DateTimeOffset.Now;

        // Quick block: what is running, what to block, for how long and how to stop it
        var quickStack = new StackPanel();
        var quick = _engine.Workspace.GeneralRules.FirstOrDefault(r => r.Enabled && r.Kind == GeneralRuleKind.Countdown &&
            r.Name.StartsWith("Bloqueo rápido", StringComparison.OrdinalIgnoreCase) && (r.ActiveDeadline?.RemainingAfterPossibleReboot(now) ?? 0) > 0);
        if (quick != null)
        {
            var left = quick.ActiveDeadline!.RemainingAfterPossibleReboot(now);
            var running = new DockPanel();
            var stop = SmallButton("Apagar…", () => ToggleRuleEnabled(quick), true, 0);
            stop.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(stop, Dock.Right);
            running.Children.Add(stop);
            var clock = new TextBlock { Text = FocusRules.Clock(left), FontSize = 36, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#38A169"),
                FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 20, 0) };
            DockPanel.SetDock(clock, Dock.Left);
            running.Children.Add(clock);
            var what = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            what.Children.Add(new TextBlock { Text = "Bloqueando " + quick.Name.Replace("Bloqueo rápido · ", "").ToLower(Spanish), FontSize = 16.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            what.Children.Add(MutedText($"Termina a las {DateTime.Now.AddSeconds(left):H:mm} · {(quick.Protection == SessionProtection.None ? "Se puede parar" : quick.Protection.Label())}", 12.5, 3));
            running.Children.Add(what);
            quickStack.Children.Add(new Border { Background = BrushHex("#122019"), BorderBrush = BrushHex("#24452F"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(18, 14, 14, 14), Margin = new Thickness(0, 0, 0, 16), Child = running });
        }

        var whatRow = new WrapPanel();
        var whatLabel = new TextBlock { Text = "Qué bloquear", FontSize = 14.5, Foreground = BrushHex("#99A6AD"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 6) };
        whatRow.Children.Add(whatLabel);
        var choices = new List<(DistractionPreset? Preset, string Label)> { (null, "Redes + Shorts") };
        choices.AddRange(DistractionPreset.All.Select(p => ((DistractionPreset?)p, p.Label)));
        foreach (var (preset, label) in choices)
        {
            var selectedPreset = Equals(preset, _quickPreset);
            var chip = new System.Windows.Controls.Button
            {
                Content = new StackPanel
                {
                    Orientation = System.Windows.Controls.Orientation.Horizontal,
                    Children =
                    {
                        Glyph(PresetGlyph(preset), 12, selectedPreset ? "#0D1014" : "#99A6AD"),
                        new TextBlock { Text = label, Margin = new Thickness(8, 0, 0, 0), Foreground = BrushHex(selectedPreset ? "#0D1014" : "#EDF2F5"), VerticalAlignment = VerticalAlignment.Center }
                    }
                },
                Padding = new Thickness(14, 0, 14, 0),
                MinHeight = 34,
                Margin = new Thickness(0, 0, 8, 6),
                Background = BrushHex(selectedPreset ? "#38A169" : "#1D2229"),
                BorderBrush = BrushHex(selectedPreset ? "#38A169" : "#2A2E34")
            };
            var captured = preset;
            chip.Click += (_, _) => { _quickPreset = captured; RefreshUI(); };
            whatRow.Children.Add(chip);
        }
        quickStack.Children.Add(whatRow);

        var quickBtns = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        foreach (var (mins, label) in new[] { (15, "15 min"), (30, "30 min"), (45, "45 min"), (60, "1 hora"), (120, "2 horas") })
        {
            var captured = mins;
            var b = GlyphButton("", label, () => _engine.LaunchQuickBlock(captured, _quickProtection, _quickPreset), primary: mins == 30);
            b.Margin = new Thickness(0, 0, 8, 8);
            quickBtns.Children.Add(b);
        }
        var restOfDayMins = Math.Max(15, (int)(DateTime.Now.Date.AddDays(1) - DateTime.Now).TotalMinutes);
        var restBtn = GlyphButton("", "Resto del día", () => _engine.LaunchQuickBlock(restOfDayMins, _quickProtection, _quickPreset));
        restBtn.Margin = new Thickness(0, 0, 8, 8);
        quickBtns.Children.Add(restBtn);
        quickStack.Children.Add(quickBtns);

        var stopHow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        stopHow.Children.Add(new TextBlock { Text = "Si quiero pararlo", FontSize = 14, Foreground = BrushHex("#EDF2F5"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        stopHow.Children.Add(ChoiceBox(new[]
        {
            new ComboOption<SessionProtection>(SessionProtection.None, "Sin protección"),
            new ComboOption<SessionProtection>(SessionProtection.Challenge, "Teclear un código"),
            new ComboOption<SessionProtection>(SessionProtection.Delay, "Esperar"),
            new ComboOption<SessionProtection>(SessionProtection.Forced, "Hasta el final")
        }, _quickProtection, v => _quickProtection = v, 200));
        PageContent.Children.Add(GroupCard("Bloqueo rápido", "", quickStack, trailing: stopHow));

        // Running now
        var activeRules = _engine.Workspace.GeneralRules.Where(r => _engine.IsRuleEnforcing(r)).ToList();
        if (activeRules.Count > 0)
        {
            var list = new StackPanel();
            foreach (var r in activeRules)
            {
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var tile = IconTile(r.Game != null ? "" : RuleKindGlyph(r.Kind), true, 36);
                tile.VerticalAlignment = VerticalAlignment.Center;
                row.Children.Add(tile);
                var info = new StackPanel { Margin = new Thickness(14, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
                info.Children.Add(new TextBlock { Text = r.Name, FontSize = 16.5, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
                info.Children.Add(new TextBlock { Text = $"{r.Kind.GalleryTitle()} · {RuleInfoLine(r)}", FontSize = 13.5, Foreground = BrushHex("#38A169"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) });
                Grid.SetColumn(info, 1);
                row.Children.Add(info);
                var acts = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
                var microLeft = Math.Max(0, r.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(r.Id));
                if (microLeft > 0) acts.Children.Add(SmallButton($"Micro-pausa {r.MicroPauseMinutes} min ({microLeft})", () => _engine.UseMicroPause(r)));
                acts.Children.Add(SmallButton("Editar", () => Dialogs.ShowRuleEditor(_engine, r, null, this), true, 0));
                Grid.SetColumn(acts, 2);
                row.Children.Add(acts);
                list.Children.Add(InnerRow(row));
            }
            var all = GlyphButton("", "Todas tus reglas", () => _engine.ActivePage = "Reglas", plain: true);
            all.MinHeight = 30;
            PageContent.Children.Add(GroupCard($"En marcha ahora · {activeRules.Count}", "", list, trailing: all));
        }

        // Let a site through for a while, and what happens while blocking
        BuildTemporaryExceptions();
        var s = _engine.Workspace.Settings;
        var whileBlocking = new StackPanel();
        whileBlocking.Children.Add(SwitchRow("Avisarme cuando queden 5 y 1 min", s.PreBlockRemindersEnabled, v => ChangeSetting(x => x.PreBlockRemindersEnabled = v), 0));
        var clip = SwitchRow("Vaciar el portapapeles si copio algo bloqueado", s.ProtectClipboard, _ => { });
        clip.Click += (_, _) =>
        {
            var wantEnabled = clip.IsChecked == true;
            if (!wantEnabled && !RequireProtectionGateForSettings("apagar esta vigilancia")) { clip.IsChecked = true; return; }
            ChangeSetting(x => x.ProtectClipboard = wantEnabled);
        };
        whileBlocking.Children.Add(clip);
        PageContent.Children.Add(GroupCard("Mientras bloquea", "", whileBlocking));

        // Reusable profiles
        var profiles = new StackPanel();
        if (_engine.Workspace.Profiles.Count == 0)
            profiles.Children.Add(MutedText("Guarda aquí combinaciones que repites (apps, webs, protección) y empiézalas con un clic.", 12.5, 0));
        foreach (var profile in _engine.Workspace.Profiles)
        {
            var dock = new DockPanel();
            var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            buttons.Children.Add(GlyphButton("", $"Empezar {profile.Minutes} min", () =>
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
            }, primary: true));
            buttons.Children.Add(SmallButton("Editar", () => Dialogs.ShowProfileEditor(_engine, profile, this)));
            buttons.Children.Add(IconButton("", "Borrar perfil", () =>
            {
                var answer = System.Windows.MessageBox.Show(this, $"¿Borrar el perfil «{profile.Name}»?", "Borrar perfil · FocusDesk",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _engine.DeleteProfile(profile.Id);
            }, "#FF8080", "#2A161B"));
            DockPanel.SetDock(buttons, Dock.Right);
            dock.Children.Add(buttons);
            var sp = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            sp.Children.Add(new TextBlock { Text = profile.Name, FontSize = 16.5, FontWeight = FontWeights.SemiBold });
            sp.Children.Add(MutedText($"{profile.Category} · {profile.Minutes} min · {profile.Protection.Label()} · {(string.IsNullOrEmpty(profile.Domains) ? "sin lista web" : profile.Domains)}", 12, 4));
            dock.Children.Add(sp);
            profiles.Children.Add(InnerRow(dock));
        }
        var newProfile = GlyphButton("", "Nuevo perfil", () => Dialogs.ShowProfileEditor(_engine, null, this), plain: true);
        newProfile.MinHeight = 30;
        PageContent.Children.Add(GroupCard("Perfiles reutilizables", "", profiles, trailing: newProfile));
    }

    // MARK: - Descansos

    /// <summary>A thin rounded progress bar (the Mac bar under the continuous-use counter).</summary>
    private static (Grid View, Action<double> Set) ProgressBar()
    {
        var grid = new Grid { Height = 6, Margin = new Thickness(0, 14, 0, 14) };
        grid.Children.Add(new Border { Background = BrushHex("#262A30"), CornerRadius = new CornerRadius(3) });
        var fill = new Border { Background = BrushHex("#38A169"), CornerRadius = new CornerRadius(3), HorizontalAlignment = System.Windows.HorizontalAlignment.Left, Width = 6 };
        grid.Children.Add(fill);
        void Set(double f)
        {
            var width = grid.ActualWidth > 0 ? grid.ActualWidth : 600;
            fill.Width = Math.Max(6, Math.Clamp(f, 0, 1) * width);
        }
        grid.SizeChanged += (_, _) => Set(fill.Tag is double d ? d : 0);
        return (grid, f => { fill.Tag = f; Set(f); });
    }

    /// <summary>«Cada 50 min ⌃⌄»: a value with up/down arrows, like the Mac steppers.</summary>
    private UIElement Stepper(string prefix, int value, int min, int max, int step, Action<int> onChange)
    {
        var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 26, 0) };
        row.Children.Add(new TextBlock { Text = $"{prefix} {value} min", FontSize = 15, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        var arrows = new StackPanel();
        var up = new System.Windows.Controls.Button { Content = Glyph("", 9, "#D5DBDF"), MinHeight = 16, Height = 16, Width = 26, Padding = new Thickness(0), Margin = new Thickness(0, 0, 0, 1) };
        var down = new System.Windows.Controls.Button { Content = Glyph("", 9, "#D5DBDF"), MinHeight = 16, Height = 16, Width = 26, Padding = new Thickness(0) };
        up.Click += (_, _) => onChange(Math.Min(max, value + step));
        down.Click += (_, _) => onChange(Math.Max(min, value - step));
        arrows.Children.Add(up);
        arrows.Children.Add(down);
        row.Children.Add(arrows);
        return row;
    }

    private void BuildBreaksPage()
    {
        var s = _engine.Workspace.Settings;
        var restNow = GlyphButton("", "Descansar ahora", () => _engine.StartContinuousBreakNow(), primary: true);
        restNow.IsEnabled = s.ContinuousBreakEnabled && _engine.ActiveContinuousBreakDeadline == null;
        PageContent.Children.Add(PageHeader("Descansos", "Descansa antes de necesitarlo.", restNow));

        // Rest after a long time in a row: the counter, the bar and the two steppers
        var eyes = new StackPanel();
        var counterRow = new WrapPanel();
        var counter = new TextBlock { FontSize = 40, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#38A169"), FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) };
        var counterText = new TextBlock { FontSize = 15, Foreground = BrushHex("#99A6AD"), VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 560 };
        counterRow.Children.Add(counter);
        counterRow.Children.Add(counterText);
        eyes.Children.Add(counterRow);
        var (bar, setBar) = ProgressBar();
        eyes.Children.Add(bar);
        void Refresh(DateTimeOffset now)
        {
            if (_engine.ActiveContinuousBreakDeadline != null)
            {
                counter.Text = FocusRules.Clock(_engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot(now));
                counterText.Text = $"de descanso · {_engine.ActiveContinuousBreakMessage}";
                setBar(1);
                return;
            }
            var used = _engine.ContinuousActiveWorkSeconds;
            var every = Math.Max(1, s.ContinuousWorkMinutes) * 60.0;
            counter.Text = FocusRules.Clock(used);
            counterText.Text = s.ContinuousBreakEnabled
                ? $"de {s.ContinuousWorkMinutes} min frente al ordenador · te propondré {s.ContinuousBreakDurationMinutes} min de pausa en {FocusRules.DurationText((int)Math.Ceiling(Math.Max(0, every - used) / 60))}"
                : "Apagado: actívalo con el interruptor de la derecha.";
            setBar(used / every);
        }
        Refresh(DateTimeOffset.Now);
        _livePageTick = Refresh;

        var steppers = new WrapPanel();
        steppers.Children.Add(Stepper("Cada", s.ContinuousWorkMinutes, 15, 180, 5, v => { ChangeSetting(x => x.ContinuousWorkMinutes = v); RefreshUI(); }));
        steppers.Children.Add(Stepper("Durante", s.ContinuousBreakDurationMinutes, 1, 30, 1, v => { ChangeSetting(x => x.ContinuousBreakDurationMinutes = v); RefreshUI(); }));
        steppers.Children.Add(Stepper("Saltos al día:", s.ContinuousBreakMaxSkipsPerDay, 0, 10, 1, v => { ChangeSetting(x => x.ContinuousBreakMaxSkipsPerDay = v); RefreshUI(); }));
        eyes.Children.Add(steppers);
        if (_engine.ActiveContinuousBreakDeadline != null)
        {
            var skip = SmallButton($"Posponer ({_engine.ContinuousBreakSkipsLeft})", () => _engine.SkipContinuousBreak(), _engine.ContinuousBreakSkipsLeft > 0, 0);
            skip.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            skip.Margin = new Thickness(0, 12, 0, 0);
            eyes.Children.Add(skip);
        }
        eyes.Children.Add(MutedText("Si te levantas o dejas el teclado unos minutos, el contador vuelve a cero solo.", 12.5, 12));
        eyes.Children.Add(SectionLabel("Mensajes de descanso (uno por línea)", 14));
        var messagesBox = new System.Windows.Controls.TextBox
        {
            Text = string.Join(Environment.NewLine, s.BreakMessages),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 84,
            VerticalContentAlignment = VerticalAlignment.Top
        };
        messagesBox.LostFocus += (_, _) =>
        {
            var lines = messagesBox.Text.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            ChangeSetting(x => x.BreakMessages = lines.Count > 0 ? lines : new Settings().BreakMessages);
        };
        eyes.Children.Add(messagesBox);
        var eyesSwitch = new System.Windows.Controls.CheckBox { IsChecked = s.ContinuousBreakEnabled, ToolTip = "Encender o apagar" };
        eyesSwitch.Style = (Style)System.Windows.Application.Current.FindResource("Switch");
        eyesSwitch.Click += (_, _) => { ChangeSetting(x => x.ContinuousBreakEnabled = eyesSwitch.IsChecked == true); RefreshUI(); };
        PageContent.Children.Add(GroupCard("Descanso tras mucho rato seguido", "", eyes, trailing: eyesSwitch));

        // Micro-pauses of your rules | Pomodoro breaks, side by side as on the Mac
        var two = new Grid { Margin = new Thickness(0, 0, 0, 0) };
        two.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        two.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        two.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var micro = new StackPanel();
        micro.Children.Add(MutedText("Sueltan una regla unos minutos y vuelve a bloquear sola. Tienes un número contado al día.", 12.5, 0));
        var withMicro = _engine.Workspace.GeneralRules.Where(r => r.DailyMicroPausesAllowed > 0).ToList();
        if (withMicro.Count == 0) micro.Children.Add(MutedText("Ninguna de tus reglas tiene micro-pausas.", 12.5, 10));
        foreach (var r in withMicro)
        {
            var left = Math.Max(0, r.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(r.Id));
            var line = new DockPanel();
            var take = SmallButton("Tomar una", () => _engine.UseMicroPause(r), left > 0 && _engine.IsRuleEnforcing(r), 0);
            take.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(take, Dock.Right);
            line.Children.Add(take);
            var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            info.Children.Add(new TextBlock { Text = r.Name, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            info.Children.Add(MutedText($"{left} de {r.DailyMicroPausesAllowed} disponibles hoy · {r.MicroPauseMinutes} min cada una", 12.5, 2));
            line.Children.Add(info);
            micro.Children.Add(InnerRow(line, 8));
        }
        var microCard = GroupCard("Micro-pausas de tus reglas", "", micro);
        two.Children.Add(microCard);

        var pomo = new StackPanel();
        var pomodoros = _engine.Workspace.GeneralRules.Where(r => r.Kind == GeneralRuleKind.Pomodoro).ToList();
        if (pomodoros.Count == 0) pomo.Children.Add(MutedText("No tienes reglas Pomodoro. Crea una en «Reglas y límites».", 12.5, 0));
        foreach (var r in pomodoros)
        {
            var line = new DockPanel();
            System.Windows.Controls.Button act;
            if (r.Enabled && r.PomodoroPhase != PomodoroPhase.Idle && r.PomodoroPhase != PomodoroPhase.WaitingForUser)
                act = SmallButton("Saltar fase", () =>
                {
                    if (r.PomodoroPhase == PomodoroPhase.Work && !UnlockRuleFor(r, $"saltar el enfoque de «{r.Name}»")) return;
                    _engine.SkipPomodoroPhase(r);
                }, true, 0);
            else if (r.PomodoroPhase == PomodoroPhase.WaitingForUser)
                act = SmallButton("Continuar", () => _engine.ContinuePomodoro(r), true, 0);
            else
                act = SmallButton("Iniciar", () =>
                {
                    var loosening = _engine.RestartLoosening(r, GeneralRuleKind.Pomodoro);
                    if (loosening != null && !UnlockRuleFor(r, loosening)) return;
                    _engine.StartRulePomodoro(r);
                }, true, 0);
            act.VerticalAlignment = VerticalAlignment.Center;
            DockPanel.SetDock(act, Dock.Right);
            line.Children.Add(act);
            var info = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) };
            info.Children.Add(new TextBlock { Text = r.Name, FontSize = 15, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
            info.Children.Add(MutedText($"{(r.Enabled ? RuleInfoLine(r) : "Apagada")} · descansos de {r.PomodoroShortBreakMinutes} min, y de {r.PomodoroLongBreakMinutes} min cada {r.PomodoroLongBreakEvery} ciclos", 12.5, 2));
            line.Children.Add(info);
            pomo.Children.Add(InnerRow(line, 8));
        }
        var pomoCard = GroupCard("Descansos del Pomodoro", "", pomo);
        Grid.SetColumn(pomoCard, 2);
        two.Children.Add(pomoCard);
        PageContent.Children.Add(two);

        // Habitual breaks of your agenda (lunch, siesta…)
        var scheduled = new StackPanel();
        foreach (var br in s.Breaks.ToList())
        {
            var line = new DockPanel();
            var remove = IconButton("", "Quitar", () =>
            {
                ChangeSetting(x => x.Breaks.RemoveAll(b => b.Id == br.Id));
                RefreshUI();
            }, "#FF8080", "#2A161B");
            DockPanel.SetDock(remove, Dock.Right);
            line.Children.Add(remove);
            var time = new TextBlock { Text = $"{br.StartHour:D2}:{br.StartMinute:D2}", FontSize = 17, FontWeight = FontWeights.SemiBold, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), Width = 70, VerticalAlignment = VerticalAlignment.Center };
            DockPanel.SetDock(time, Dock.Left);
            line.Children.Add(time);
            line.Children.Add(new TextBlock { Text = $"{br.Title} · {br.DurationMinutes} min", FontSize = 15, VerticalAlignment = VerticalAlignment.Center });
            scheduled.Children.Add(InnerRow(line, 8));
        }
        if (s.Breaks.Count == 0) scheduled.Children.Add(MutedText("Sin descansos programados.", 12.5, 0));

        var titleBox = new System.Windows.Controls.TextBox { Text = "Descanso", Width = 190 };
        var hourBox = NumberBox(14, 0, 23, _ => { }, 60);
        var minuteBox = NumberBox(0, 0, 59, _ => { }, 60);
        var durationBox = NumberBox(60, 5, 240, _ => { }, 70);
        var addBreak = GlyphButton("", "Añadir descanso", () =>
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
        });
        addBreak.Margin = new Thickness(0, 26, 0, 0);
        var form = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        form.Children.Add(Labeled("Nombre", titleBox, 10));
        form.Children.Add(Labeled("Hora", hourBox, 10));
        form.Children.Add(Labeled("Minuto", minuteBox, 10));
        form.Children.Add(Labeled("Duración (min)", durationBox, 10));
        form.Children.Add(addBreak);
        scheduled.Children.Add(form);
        var warn = SwitchRow("Avisarme y mostrar cuenta atrás", s.EnforceBreaks, v => ChangeSetting(x => x.EnforceBreaks = v), 0);
        PageContent.Children.Add(GroupCard("Descansos habituales de tu agenda", "", scheduled, trailing: warn));
    }
}
