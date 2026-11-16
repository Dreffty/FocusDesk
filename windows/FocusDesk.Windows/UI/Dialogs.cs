using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

public static class Dialogs
{
    private static SolidColorBrush BrushHex(string hex) =>
        new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));

    public static bool RequestUnlock(SessionProtection protection, int unlockChars, int delayMinutes, string actionLabel, Window? owner)
    {
        if (protection == SessionProtection.None) return true;

        var win = new Window
        {
            Title = "Desbloqueo requerido · FocusDesk",
            Width = 520,
            Height = protection == SessionProtection.Challenge ? 340 : 250,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            ResizeMode = ResizeMode.NoResize,
            Background = BrushHex("#0F1218"),
            Foreground = BrushHex("#F2F5FA")
        };

        var root = new StackPanel { Margin = new Thickness(24) };
        root.Children.Add(new TextBlock
        {
            Text = $"Para {actionLabel}",
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#F2F5FA"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 10)
        });

        var unlocked = false;

        if (protection == SessionProtection.Challenge)
        {
            var expected = UnlockChallenge.Make(unlockChars);
            root.Children.Add(new TextBlock
            {
                Text = $"Escribe exactamente este código de {expected.Length} caracteres (no se permite pegar):",
                Foreground = BrushHex("#94A3B8"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 10)
            });

            var codeBorder = new Border
            {
                Background = BrushHex("#171C24"),
                BorderBrush = BrushHex("#283140"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(12),
                Margin = new Thickness(0, 0, 0, 12)
            };
            codeBorder.Child = new TextBlock
            {
                Text = expected,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                FontSize = 15,
                Foreground = BrushHex("#64E3A1"),
                TextWrapping = TextWrapping.Wrap
            };
            root.Children.Add(codeBorder);

            var input = new System.Windows.Controls.TextBox
            {
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                FontSize = 14,
                Padding = new Thickness(8),
                Background = BrushHex("#1F2631"),
                Foreground = BrushHex("#F2F5FA"),
                BorderBrush = BrushHex("#283140")
            };
            DataObject.AddPastingHandler(input, (_, e) => e.CancelCommand());
            root.Children.Add(input);

            var progress = new TextBlock
            {
                Text = $"0 / {expected.Length} caracteres correctos",
                Foreground = BrushHex("#94A3B8"),
                Margin = new Thickness(0, 8, 0, 14)
            };
            root.Children.Add(progress);

            var confirmBtn = new System.Windows.Controls.Button
            {
                Content = "Desbloquear",
                IsEnabled = false,
                Background = BrushHex("#64E3A1"),
                Foreground = BrushHex("#0F1218"),
                FontWeight = FontWeights.SemiBold,
                HorizontalAlignment = System.Windows.HorizontalAlignment.Right
            };

            input.TextChanged += (_, _) =>
            {
                var ok = UnlockChallenge.Matches(input.Text, expected);
                var prefix = UnlockChallenge.CorrectPrefix(input.Text, expected);
                progress.Text = $"{prefix} / {expected.Length} caracteres correctos";
                progress.Foreground = BrushHex(ok ? "#64E3A1" : "#F5B95F");
                confirmBtn.IsEnabled = ok;
            };
            confirmBtn.Click += (_, _) => { unlocked = true; win.Close(); };

            var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
            var cancel = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0) };
            cancel.Click += (_, _) => win.Close();
            btns.Children.Add(cancel);
            btns.Children.Add(confirmBtn);
            root.Children.Add(btns);
        }
        else
        {
            var secondsLeft = Math.Clamp(delayMinutes, 1, 120) * 60;
            var label = new TextBlock
            {
                Text = $"Espera obligatoria: {FocusRules.Clock(secondsLeft)}",
                FontSize = 22,
                FontWeight = FontWeights.Bold,
                Foreground = BrushHex("#F5B95F"),
                Margin = new Thickness(0, 8, 0, 18)
            };
            root.Children.Add(label);

            var confirmBtn = new System.Windows.Controls.Button
            {
                Content = "Desbloquear",
                IsEnabled = false,
                Background = BrushHex("#64E3A1"),
                Foreground = BrushHex("#0F1218"),
                FontWeight = FontWeights.SemiBold
            };
            confirmBtn.Click += (_, _) => { unlocked = true; win.Close(); };

            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (_, _) =>
            {
                secondsLeft--;
                if (secondsLeft <= 0)
                {
                    timer.Stop();
                    label.Text = "Espera completada. Ya puedes continuar.";
                    label.Foreground = BrushHex("#64E3A1");
                    confirmBtn.IsEnabled = true;
                }
                else
                {
                    label.Text = $"Espera obligatoria: {FocusRules.Clock(secondsLeft)}";
                }
            };
            timer.Start();
            win.Closed += (_, _) => timer.Stop();

            var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
            var cancel = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0) };
            cancel.Click += (_, _) => win.Close();
            btns.Children.Add(cancel);
            btns.Children.Add(confirmBtn);
            root.Children.Add(btns);
        }

        win.Content = root;
        win.ShowDialog();
        return unlocked;
    }

    public static void ShowTaskEditor(AppEngine engine, FocusTask? existing, Window? owner)
    {
        var draft = existing?.Clone() ?? new FocusTask { ScheduledAt = DateTimeOffset.Now.AddMinutes(10) };
        var win = new Window
        {
            Title = existing == null ? "Nueva tarea · FocusDesk" : "Editar tarea · FocusDesk",
            Width = 540,
            Height = 640,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = owner,
            Background = BrushHex("#0F1218"),
            Foreground = BrushHex("#F2F5FA")
        };

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new StackPanel { Margin = new Thickness(22) };
        scroll.Content = root;

        System.Windows.Controls.TextBox AddField(string caption, string initial)
        {
            root.Children.Add(new TextBlock { Text = caption, Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
            var tb = new System.Windows.Controls.TextBox
            {
                Text = initial,
                Padding = new Thickness(8, 6, 8, 6),
                Background = BrushHex("#1F2631"),
                Foreground = BrushHex("#F2F5FA"),
                BorderBrush = BrushHex("#283140")
            };
            root.Children.Add(tb);
            return tb;
        }

        var titleBox = AddField("TÍTULO", draft.Title);
        var catBox = new System.Windows.Controls.ComboBox
        {
            ItemsSource = engine.Workspace.Settings.Categories.Select(c => c.Name).ToList(),
            SelectedItem = draft.Category,
            Margin = new Thickness(0, 4, 0, 6)
        };
        root.Children.Add(new TextBlock { Text = "CATEGORÍA", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        root.Children.Add(catBox);

        var schedCheck = new System.Windows.Controls.CheckBox { Content = "Reservar horario en agenda", IsChecked = draft.IsScheduled, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 8, 0, 4) };
        root.Children.Add(schedCheck);
        var dateBox = AddField("FECHA Y HORA (yyyy-MM-dd HH:mm)", draft.ScheduledAt.LocalDateTime.ToString("yyyy-MM-dd HH:mm"));
        var minBox = AddField("DURACIÓN (minutos)", draft.Minutes.ToString());
        var pomoBox = AddField("POMODORO (0 = continuo, ej. 25)", draft.PomodoroWorkMinutes.ToString());
        var strictCheck = new System.Windows.Controls.CheckBox { Content = "Modo estricto (bloquear apps fuera de lista)", IsChecked = draft.Strict, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 8, 0, 4) };
        root.Children.Add(strictCheck);
        var appsBox = AddField("APPS PERMITIDAS O BLOQUEADAS (nombres .exe separados por coma)", string.Join(", ", draft.Apps.Select(a => a.Id)));
        var domainsBox = AddField("WEBS (dominios separados por coma)", draft.Domains);
        var webActionCombo = new System.Windows.Controls.ComboBox
        {
            ItemsSource = Enum.GetValues<WebBlockAction>().ToList(),
            SelectedItem = draft.WebBlockAction
        };
        root.Children.Add(new TextBlock { Text = "ACCIÓN WEB", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        root.Children.Add(webActionCombo);

        var protCombo = new System.Windows.Controls.ComboBox
        {
            ItemsSource = Enum.GetValues<SessionProtection>().ToList(),
            SelectedItem = draft.Protection
        };
        root.Children.Add(new TextBlock { Text = "PROTECCIÓN", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        root.Children.Add(protCombo);

        var checklistBox = AddField("CHECKLIST (una línea por paso)", draft.Checklist);
        checklistBox.AcceptsReturn = true;
        checklistBox.Height = 72;

        var saveBtn = new System.Windows.Controls.Button
        {
            Content = "Guardar tarea",
            Background = BrushHex("#64E3A1"),
            Foreground = BrushHex("#0F1218"),
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 18, 0, 0),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };
        saveBtn.Click += (_, _) =>
        {
            draft.Title = titleBox.Text.Trim();
            draft.Category = catBox.SelectedItem as string ?? "Personal";
            draft.IsScheduled = schedCheck.IsChecked == true;
            if (DateTime.TryParse(dateBox.Text, out var parsedDt))
                draft.ScheduledAt = new DateTimeOffset(parsedDt, DateTimeOffset.Now.Offset);
            if (int.TryParse(minBox.Text, out var m)) draft.Minutes = Math.Clamp(m, 1, 720);
            if (int.TryParse(pomoBox.Text, out var pm)) draft.PomodoroWorkMinutes = Math.Clamp(pm, 0, 120);
            draft.Strict = strictCheck.IsChecked == true;
            draft.Apps = appsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(id => new AllowedApp(id, id, "")).ToList();
            draft.Domains = domainsBox.Text;
            draft.WebBlockAction = webActionCombo.SelectedItem is WebBlockAction wba ? wba : WebBlockAction.Warn;
            draft.Protection = protCombo.SelectedItem is SessionProtection sp ? sp : SessionProtection.None;
            draft.Checklist = checklistBox.Text;
            engine.SaveTask(draft);
            if (string.IsNullOrEmpty(engine.Error)) win.Close();
            else System.Windows.MessageBox.Show(win, engine.Error, "Revisa la tarea");
        };
        root.Children.Add(saveBtn);

        win.Content = scroll;
        win.ShowDialog();
    }

    public static void ShowRuleEditor(AppEngine engine, GeneralBlockRule? existing, GeneralBlockRule? template, Window? owner)
    {
        var source = existing ?? template ?? new GeneralBlockRule();
        var json = System.Text.Json.JsonSerializer.Serialize(source);
        var draft = System.Text.Json.JsonSerializer.Deserialize<GeneralBlockRule>(json)!;
        if (existing == null && template == null) draft.Id = Guid.NewGuid();

        var win = new Window
        {
            Title = existing == null ? "Nueva regla · FocusDesk" : "Editar regla · FocusDesk",
            Width = 580,
            Height = 700,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = owner,
            Background = BrushHex("#0F1218"),
            Foreground = BrushHex("#F2F5FA")
        };

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new StackPanel { Margin = new Thickness(22) };
        scroll.Content = root;

        System.Windows.Controls.TextBox AddField(string caption, string initial)
        {
            root.Children.Add(new TextBlock { Text = caption, Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
            var tb = new System.Windows.Controls.TextBox
            {
                Text = initial,
                Padding = new Thickness(8, 6, 8, 6),
                Background = BrushHex("#1F2631"),
                Foreground = BrushHex("#F2F5FA"),
                BorderBrush = BrushHex("#283140")
            };
            root.Children.Add(tb);
            return tb;
        }

        var nameBox = AddField("NOMBRE DE LA REGLA", draft.Name);

        root.Children.Add(new TextBlock { Text = "MODO", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        var kindCombo = new System.Windows.Controls.ComboBox { ItemsSource = Enum.GetValues<GeneralRuleKind>().ToList(), SelectedItem = draft.Kind };
        root.Children.Add(kindCombo);

        var gameChoices = new List<string> { "(Ninguno: meta normal)" };
        gameChoices.AddRange(GameCatalog.All.Select(g => $"{g.Id}: {g.Name} ({g.Detection.Label()})"));
        var gameCombo = new System.Windows.Controls.ComboBox { ItemsSource = gameChoices };
        gameCombo.SelectedIndex = string.IsNullOrEmpty(draft.GameId) ? 0 : Math.Max(0, GameCatalog.All.ToList().FindIndex(g => g.Id == draft.GameId) + 1);
        root.Children.Add(new TextBlock { Text = "JUEGO (para Primero el trabajo → partida)", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        root.Children.Add(gameCombo);

        var gameInfo = new TextBlock { Foreground = BrushHex("#64E3A1"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 4) };
        root.Children.Add(gameInfo);

        var goalMinBox = AddField("MINUTOS DE ESTUDIO / PRESUPUESTO", (draft.Kind == GeneralRuleKind.WorkGoal ? draft.GoalMinutesRequired : draft.DailyLimitMinutes).ToString());
        var maxMatchesBox = AddField("MÁXIMO PARTIDAS AL DÍA (0 = ilimitado)", draft.MaxDailyMatches.ToString());
        var matchMinBox = AddField("DURACIÓN TÍPICA PARTIDA (min, modo por tiempo)", draft.MatchMinutes.ToString());
        var overtimeBox = AddField("PRÓRROGA PARA ACABAR (min)", draft.MatchOvertimeMinutes.ToString());
        var onePerGoalCheck = new System.Windows.Controls.CheckBox { Content = "Cada partida cuesta un bloque de estudio (1 h → 1 partida → se bloquea)", IsChecked = draft.OneMatchPerGoalBlock, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 6, 0, 2) };
        var verifyStudyCheck = new System.Windows.Controls.CheckBox { Content = "Solo contar estudio activo verificado (Ajustes › Qué cuenta como estudio)", IsChecked = draft.VerifyActiveStudy, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 2, 0, 6) };
        root.Children.Add(onePerGoalCheck);
        root.Children.Add(verifyStudyCheck);

        gameCombo.SelectionChanged += (_, _) =>
        {
            if (gameCombo.SelectedIndex <= 0)
            {
                draft.GameId = null;
                gameInfo.Text = "";
                return;
            }
            var g = GameCatalog.All[gameCombo.SelectedIndex - 1];
            draft.ApplyGame(g);
            kindCombo.SelectedItem = GeneralRuleKind.WorkGoal;
            matchMinBox.Text = draft.MatchMinutes.ToString();
            maxMatchesBox.Text = draft.MaxDailyMatches.ToString();
            gameInfo.Text = $"{g.Detection.Label()}: {g.Detection.Explanation()}";
        };
        if (draft.Game is { } curGame)
            gameInfo.Text = $"{curGame.Detection.Label()}: {curGame.Detection.Explanation()}";

        var blockAppsCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear apps (.exe)", IsChecked = draft.BlockApps, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 8, 0, 2) };
        var blockLibCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear bibliotecas de juegos (Steam, Epic, Riot…)", IsChecked = draft.BlockGameLibraries, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 2, 0, 4) };
        root.Children.Add(blockAppsCheck);
        root.Children.Add(blockLibCheck);

        var appsBox = AddField("PROCESOS / APPS BLOQUEADAS (ej. LeagueClientUx, discord)", string.Join(", ", draft.Apps.Select(a => a.Id)));
        var domainsBox = AddField("WEBS BLOQUEADAS O PERMITIDAS (ej. youtube.com/shorts, tiktok.com)", draft.Domains);
        var keywordsBox = AddField("PALABRAS EN TÍTULO DE VENTANA (ej. Shorts, Twitch)", draft.BlockedTitleKeywords);
        var foldersBox = AddField("CARPETAS BLOQUEADAS DEL EXPLORADOR (rutas separadas por coma)", string.Join(", ", draft.BlockedFolders));

        var webModeCombo = new System.Windows.Controls.ComboBox { ItemsSource = Enum.GetValues<WebListMode>().ToList(), SelectedItem = draft.WebListMode };
        root.Children.Add(new TextBlock { Text = "MODO LISTA WEB", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        root.Children.Add(webModeCombo);

        var protCombo = new System.Windows.Controls.ComboBox { ItemsSource = Enum.GetValues<SessionProtection>().ToList(), SelectedItem = draft.Protection };
        root.Children.Add(new TextBlock { Text = "PROTECCIÓN ANTI-TRAMPAS", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 10, 0, 4) });
        root.Children.Add(protCombo);

        var charsBox = AddField("LONGITUD DEL CÓDIGO (8–64 caracteres)", draft.UnlockChars.ToString());
        var alwaysProtCheck = new System.Windows.Controls.CheckBox { Content = "Protegida 24/7 (incluso antes de empezar)", IsChecked = draft.AlwaysProtected, Foreground = BrushHex("#F2F5FA"), Margin = new Thickness(0, 6, 0, 4) };
        root.Children.Add(alwaysProtCheck);

        var saveBtn = new System.Windows.Controls.Button
        {
            Content = "Guardar regla",
            Background = BrushHex("#64E3A1"),
            Foreground = BrushHex("#0F1218"),
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 18, 0, 0),
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };
        saveBtn.Click += (_, _) =>
        {
            draft.Name = nameBox.Text.Trim();
            draft.Kind = kindCombo.SelectedItem is GeneralRuleKind k ? k : GeneralRuleKind.DailyLimit;
            if (int.TryParse(goalMinBox.Text, out var gm))
            {
                if (draft.Kind == GeneralRuleKind.WorkGoal) draft.GoalMinutesRequired = Math.Clamp(gm, 5, 720);
                else draft.DailyLimitMinutes = Math.Clamp(gm, 1, 720);
            }
            if (int.TryParse(maxMatchesBox.Text, out var mm)) draft.MaxDailyMatches = Math.Clamp(mm, 0, 20);
            if (int.TryParse(matchMinBox.Text, out var tm)) draft.MatchMinutes = Math.Clamp(tm, 5, 180);
            if (int.TryParse(overtimeBox.Text, out var om)) draft.MatchOvertimeMinutes = Math.Clamp(om, 0, 30);
            draft.OneMatchPerGoalBlock = onePerGoalCheck.IsChecked == true;
            draft.VerifyActiveStudy = verifyStudyCheck.IsChecked == true;
            draft.BlockApps = blockAppsCheck.IsChecked == true;
            draft.BlockGameLibraries = blockLibCheck.IsChecked == true;
            draft.Apps = appsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(id => new AllowedApp(id, id, "")).ToList();
            draft.Domains = domainsBox.Text;
            draft.BlockedTitleKeywords = keywordsBox.Text;
            draft.BlockedFolders = foldersBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            draft.WebListMode = webModeCombo.SelectedItem is WebListMode wm ? wm : WebListMode.BlockListed;
            draft.Protection = protCombo.SelectedItem is SessionProtection sp ? sp : SessionProtection.Challenge;
            if (int.TryParse(charsBox.Text, out var ch)) draft.UnlockChars = UnlockChallenge.ClampedLength(ch);
            draft.AlwaysProtected = alwaysProtCheck.IsChecked == true;

            var bypass = false;
            if (existing != null && engine.IsRuleProtected(existing))
            {
                var reason = GeneralBlockRule.Loosening(existing, draft);
                if (reason != null)
                {
                    if (!RequestUnlock(existing.Protection, existing.UnlockChars, existing.StopDelayMinutes, reason, win))
                        return;
                    bypass = true;
                }
            }
            engine.SaveGeneralRule(draft, bypassProtection: bypass);
            if (string.IsNullOrEmpty(engine.Error)) win.Close();
            else System.Windows.MessageBox.Show(win, engine.Error, "Revisa la regla");
        };
        root.Children.Add(saveBtn);

        win.Content = scroll;
        win.ShowDialog();
    }

    public static void ShowCompletionDialog(AppEngine engine, WorkSession session, Window? owner)
    {
        var win = new Window
        {
            Title = "Confirmar resultado · FocusDesk",
            Width = 460,
            Height = 320,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = owner,
            Background = BrushHex("#0F1218"),
            Foreground = BrushHex("#F2F5FA")
        };

        var root = new StackPanel { Margin = new Thickness(22) };
        root.Children.Add(new TextBlock { Text = $"Sesión terminada: {session.Task.Title}", FontSize = 17, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
        root.Children.Add(new TextBlock
        {
            Text = $"Tiempo trabajado: {FocusRules.Clock(session.Elapsed(DateTimeOffset.Now))} · Interrupciones: {session.InterruptionCount}",
            Foreground = BrushHex("#94A3B8"),
            Margin = new Thickness(0, 6, 0, 14)
        });
        root.Children.Add(new TextBlock { Text = "NOTA DE RESULTADO (opcional)", Foreground = BrushHex("#94A3B8"), FontSize = 11, Margin = new Thickness(0, 0, 0, 4) });
        var noteBox = new System.Windows.Controls.TextBox
        {
            Height = 80,
            AcceptsReturn = true,
            Background = BrushHex("#1F2631"),
            Foreground = BrushHex("#F2F5FA"),
            BorderBrush = BrushHex("#283140"),
            Padding = new Thickness(8)
        };
        root.Children.Add(noteBox);

        var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var pending = new System.Windows.Controls.Button { Content = "Sigue pendiente", Margin = new Thickness(0, 0, 10, 0) };
        pending.Click += (_, _) => { engine.ConfirmSession(false, noteBox.Text); win.Close(); };
        var done = new System.Windows.Controls.Button
        {
            Content = "Completada",
            Background = BrushHex("#64E3A1"),
            Foreground = BrushHex("#0F1218"),
            FontWeight = FontWeights.SemiBold
        };
        done.Click += (_, _) => { engine.ConfirmSession(true, noteBox.Text); win.Close(); };
        btns.Children.Add(pending);
        btns.Children.Add(done);
        root.Children.Add(btns);

        win.Content = root;
        win.ShowDialog();
    }
}
