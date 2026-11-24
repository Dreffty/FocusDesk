using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

public static partial class Dialogs
{
    // MARK: - Result of a finished session (macOS: the completion sheet)

    public static void ShowCompletionDialog(AppEngine engine, WorkSession session, Window? owner)
    {
        var saved = false;
        var win = new Window
        {
            Title = "Confirmar resultado · FocusDesk",
            Width = 660,
            SizeToContent = SizeToContent.Height,
            MaxHeight = 800,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            ResizeMode = ResizeMode.NoResize,
            Background = BrushHex("#0D1014"),
            Foreground = BrushHex("#EDF2F5")
        };
        const string iconFont = "Segoe Fluent Icons, Segoe MDL2 Assets";
        TextBlock Icon(string glyph, double size, string color) => new()
        {
            Text = glyph,
            FontFamily = new System.Windows.Media.FontFamily(iconFont),
            FontSize = size,
            Foreground = BrushHex(color),
            VerticalAlignment = VerticalAlignment.Center
        };
        TextBlock Caps(string glyph, string text)
        {
            var block = new TextBlock { Margin = new Thickness(0, 16, 0, 8) };
            block.Inlines.Add(new System.Windows.Documents.Run(glyph + "  ") { FontFamily = new System.Windows.Media.FontFamily(iconFont), FontSize = 13, Foreground = BrushHex("#38A169") });
            block.Inlines.Add(new System.Windows.Documents.Run(Spaced(text)) { FontSize = 12.5, FontWeight = FontWeights.Bold, Foreground = BrushHex("#B7C0C5") });
            return block;
        }

        var root = new StackPanel { Margin = new Thickness(26) };
        AnimateModalIn(root);

        // Header: the seal, the question and what it means
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
        var sealIcon = Icon("\uE73E", 20, "#38A169");
        sealIcon.HorizontalAlignment = System.Windows.HorizontalAlignment.Center;
        var seal = new Border { Width = 48, Height = 48, CornerRadius = new CornerRadius(14), Background = BrushHex("#15291F"), Child = sealIcon, Margin = new Thickness(0, 0, 16, 0), VerticalAlignment = VerticalAlignment.Top };
        DockPanel.SetDock(seal, Dock.Left);
        header.Children.Add(seal);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = "¿Qué has conseguido?", FontSize = 25, FontWeight = FontWeights.SemiBold, FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI") });
        titles.Children.Add(new TextBlock { Text = "La sesión ha terminado y las restricciones están desactivadas. Tú confirmas el resultado.", FontSize = 13.5, Foreground = BrushHex("#99A6AD"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 3, 0, 0) });
        header.Children.Add(titles);
        root.Children.Add(header);

        // Files of the result folder that changed during the session, and the ones attached by hand
        var selectedFiles = new HashSet<string>(session.SelectedFiles);
        var manualFiles = new List<string>(session.ManualFiles);
        List<string> AllFiles() => (session.FinalChangedFiles ?? new List<string>()).Concat(manualFiles).Distinct().ToList();
        var steps = AppEngine.ChecklistSteps(session.Task.Checklist);

        // The session in one card: its name and four numbers
        var filesPill = new TextBlock { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#38A169") };
        void SyncFilesPill() => filesPill.Text = $"{selectedFiles.Count}/{AllFiles().Count} entregables";
        Border Pill(string? glyph, UIElement text, bool accent)
        {
            var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            if (glyph != null)
            {
                var icon = Icon(glyph, 12.5, accent ? "#38A169" : "#99A6AD");
                icon.Margin = new Thickness(0, 0, 7, 0);
                row.Children.Add(icon);
            }
            row.Children.Add(text);
            return new Border { Background = BrushHex(accent ? "#15291F" : "#22262C"), CornerRadius = new CornerRadius(9), Padding = new Thickness(11, 5, 11, 5), Margin = new Thickness(0, 0, 8, 0), Child = row };
        }
        TextBlock PillText(string text, bool accent) => new() { Text = text, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = BrushHex(accent ? "#38A169" : "#99A6AD") };
        var minutes = (int)Math.Round(session.Elapsed(session.EndedAt ?? DateTimeOffset.Now) / 60);
        var summary = new StackPanel();
        summary.Children.Add(new TextBlock { Text = session.Task.Title, FontSize = 18, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
        var pills = new WrapPanel();
        pills.Children.Add(Pill("\uE823", PillText($"{minutes} min de sesión", true), true));
        pills.Children.Add(Pill("\uE8BD", PillText(session.InterruptionCount == 1 ? "1 interrupción" : $"{session.InterruptionCount} interrupciones", true), true));
        if (steps.Count > 0) pills.Children.Add(Pill("\uE8FD", PillText(steps.Count == 1 ? "1 paso" : $"{steps.Count} pasos", false), false));
        pills.Children.Add(Pill(null, filesPill, true));
        summary.Children.Add(pills);
        root.Children.Add(new Border { Background = BrushHex("#161B21"), BorderBrush = BrushHex("#262A30"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(16), Padding = new Thickness(20, 16, 20, 16), Child = summary });

        // The checklist can be ticked here too: work done in another app is ticked off at the end.
        if (steps.Count > 0)
        {
            var checklistTitle = Caps("\uE8FD", "Checklist");
            void SyncChecklistTitle()
            {
                var done = Enumerable.Range(0, steps.Count).Count(i => session.Checked.Contains(i.ToString()));
                ((System.Windows.Documents.Run)checklistTitle.Inlines.LastInline).Text = Spaced($"Checklist · {done} de {steps.Count}");
            }
            SyncChecklistTitle();
            root.Children.Add(checklistTitle);
            for (var i = 0; i < steps.Count; i++)
            {
                var key = i.ToString();
                var box = new System.Windows.Controls.CheckBox { Content = steps[i], IsChecked = session.Checked.Contains(key), Margin = new Thickness(0, 3, 0, 0), FontSize = 14.5 };
                box.Click += (_, _) =>
                {
                    engine.SetCheck(key, box.IsChecked == true);
                    SyncChecklistTitle();
                };
                root.Children.Add(box);
            }
        }

        // Evidence
        if (!string.IsNullOrWhiteSpace(session.FinalEvidenceMessage))
            root.Children.Add(new TextBlock { Text = session.FinalEvidenceMessage, FontSize = 12.5, Foreground = BrushHex("#FAC74D"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0) });
        var evidenceHead = new DockPanel();
        var attach = new System.Windows.Controls.Button { Margin = new Thickness(0, 10, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        var attachRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        var clip = Icon("\uE723", 13.5, "#EDF2F5");
        clip.Margin = new Thickness(0, 0, 9, 0);
        attachRow.Children.Add(clip);
        attachRow.Children.Add(new TextBlock { Text = "Adjuntar archivo manualmente…", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        attach.Content = attachRow;
        DockPanel.SetDock(attach, Dock.Right);
        evidenceHead.Children.Add(attach);
        evidenceHead.Children.Add(Caps("\uE8B7", "Evidencias y entregables"));
        root.Children.Add(evidenceHead);
        var filesPanel = new StackPanel();
        void RebuildFiles()
        {
            filesPanel.Children.Clear();
            var changed = session.FinalChangedFiles ?? new List<string>();
            var all = AllFiles();
            if (all.Count == 0)
                filesPanel.Children.Add(new TextBlock
                {
                    Text = string.IsNullOrWhiteSpace(session.Task.Folder)
                        ? "Esta tarea no tiene carpeta de resultados. Puedes adjuntar el resultado manualmente o confirmar con una nota."
                        : "No se han detectado archivos nuevos en la carpeta. Puedes adjuntar el resultado manualmente o confirmar con una nota.",
                    FontSize = 13,
                    Foreground = BrushHex("#99A6AD"),
                    TextWrapping = TextWrapping.Wrap
                });
            foreach (var file in all)
            {
                var captured = file;
                var label = new StackPanel();
                label.Children.Add(new TextBlock { Text = System.IO.Path.GetFileName(captured), FontSize = 14, TextTrimming = TextTrimming.CharacterEllipsis });
                label.Children.Add(new TextBlock { Text = changed.Contains(captured) ? "Señal automática" : "Adjunto manual", FontSize = 12, Foreground = BrushHex("#99A6AD") });
                var fileBox = new System.Windows.Controls.CheckBox { Content = label, IsChecked = selectedFiles.Contains(captured), Margin = new Thickness(0, 4, 0, 0), ToolTip = captured };
                fileBox.Click += (_, _) =>
                {
                    if (fileBox.IsChecked == true) selectedFiles.Add(captured); else selectedFiles.Remove(captured);
                    SyncFilesPill();
                };
                filesPanel.Children.Add(fileBox);
            }
            SyncFilesPill();
        }
        RebuildFiles();
        root.Children.Add(new ScrollViewer { MaxHeight = 130, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = filesPanel });
        root.Children.Add(new TextBlock { Text = "Señal automática ≠ trabajo demostrado: marca cuál corresponde al entregable real.", FontSize = 12.5, Foreground = BrushHex("#99A6AD"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 10, 0, 12) });
        attach.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Multiselect = true };
            if (dialog.ShowDialog() != true) return;
            foreach (var file in dialog.FileNames)
            {
                if (!manualFiles.Contains(file)) manualFiles.Add(file);
                selectedFiles.Add(file);
            }
            RebuildFiles();
        };

        // The note
        var noteBox = MakeTextBox("", multiline: true, height: 76);
        var noteHint = new TextBlock { Text = "Resultado o próximo paso (opcional)", FontSize = 14.5, Foreground = BrushHex("#7C868C"), Margin = new Thickness(15, 10, 0, 0), IsHitTestVisible = false };
        noteBox.TextChanged += (_, _) => noteHint.Visibility = string.IsNullOrEmpty(noteBox.Text) ? Visibility.Visible : Visibility.Collapsed;
        var noteHost = new Grid();
        noteHost.Children.Add(noteBox);
        noteHost.Children.Add(noteHint);
        root.Children.Add(noteHost);

        // What comes next, and what to do with it when this one is confirmed
        var transition = NextTransition.KeepSchedule;
        var nextTask = FocusRules.NextSuggestedTask(engine.Workspace.Tasks, session.Task.Id, DateTimeOffset.Now);
        if (nextTask != null)
        {
            var nextBody = new StackPanel();
            var nextHead = new DockPanel();
            if (nextTask.IsScheduled)
            {
                var when = new TextBlock { Text = nextTask.ScheduledAt.LocalDateTime.ToString("H:mm"), FontSize = 13, Foreground = BrushHex("#99A6AD"), FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), VerticalAlignment = VerticalAlignment.Center };
                DockPanel.SetDock(when, Dock.Right);
                nextHead.Children.Add(when);
            }
            nextHead.Children.Add(new TextBlock { Text = $"SIGUIENTE TAREA SUGERIDA: {nextTask.Title}", FontSize = 12.5, FontWeight = FontWeights.Bold, Foreground = BrushHex("#38A169"), TextTrimming = TextTrimming.CharacterEllipsis });
            nextBody.Children.Add(nextHead);
            var choiceRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
            choiceRow.Children.Add(new TextBlock { Text = "Al confirmar", FontSize = 14.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 12, 0) });
            var strip = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            var options = new (NextTransition Value, string Label)[]
            {
                (NextTransition.KeepSchedule, "Mantener su horario"),
                (NextTransition.StartNextNow, "Empezar la siguiente"),
                (NextTransition.Rest10Min, "Descansar 10 min")
            };
            var optionButtons = new List<System.Windows.Controls.Button>();
            void PaintOptions()
            {
                for (var i = 0; i < options.Length; i++)
                {
                    var on = options[i].Value == transition;
                    optionButtons[i].Background = on ? BrushHex("#38A169") : System.Windows.Media.Brushes.Transparent;
                    optionButtons[i].BorderBrush = on ? BrushHex("#38A169") : System.Windows.Media.Brushes.Transparent;
                    ((TextBlock)optionButtons[i].Content).Foreground = BrushHex(on ? "#0D1014" : "#D5DBDF");
                    ((TextBlock)optionButtons[i].Content).FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
                }
            }
            foreach (var option in options)
            {
                var value = option.Value;
                var button = new System.Windows.Controls.Button { Content = new TextBlock { Text = option.Label, FontSize = 14 }, Padding = new Thickness(14, 0, 14, 0), MinHeight = 32, Margin = new Thickness(0) };
                button.Click += (_, _) => { transition = value; PaintOptions(); };
                optionButtons.Add(button);
                strip.Children.Add(button);
            }
            PaintOptions();
            choiceRow.Children.Add(new Border { Background = BrushHex("#22262C"), CornerRadius = new CornerRadius(10), Padding = new Thickness(2), Child = strip });
            nextBody.Children.Add(choiceRow);
            root.Children.Add(new Border { Background = BrushHex("#161B21"), CornerRadius = new CornerRadius(14), Padding = new Thickness(16, 12, 16, 12), Margin = new Thickness(0, 14, 0, 0), Child = nextBody });
        }

        // Cancel and go back on the left; «still pending» and «done» on the right
        var buttons = new DockPanel { Margin = new Thickness(0, 20, 0, 0) };
        var done = MakePrimaryButton("Sí, he terminado");
        done.IsDefault = true;
        done.Click += (_, _) =>
        {
            saved = true;
            engine.ConfirmSession(true, noteBox.Text, selectedFiles, manualFiles, transition);
            win.Close();
        };
        DockPanel.SetDock(done, Dock.Right);
        buttons.Children.Add(done);
        var pending = new System.Windows.Controls.Button { Content = "Sigue pendiente", Margin = new Thickness(0, 0, 10, 0), ToolTip = "Guardar la sesión sin dar la tarea por terminada" };
        pending.Click += (_, _) =>
        {
            saved = true;
            engine.ConfirmSession(false, noteBox.Text, selectedFiles, manualFiles, transition);
            win.Close();
        };
        DockPanel.SetDock(pending, Dock.Right);
        buttons.Children.Add(pending);
        var cancelSession = new System.Windows.Controls.Button
        {
            Content = new TextBlock { Text = "Cancelar sesión", Foreground = BrushHex("#FF8080"), FontWeight = FontWeights.SemiBold },
            Background = BrushHex("#2A161B"),
            BorderBrush = BrushHex("#5C262B"),
            Margin = new Thickness(0, 0, 10, 0)
        };
        cancelSession.Click += (_, _) =>
        {
            var answer = System.Windows.MessageBox.Show(win,
                "¿Cancelar esta sesión? La tarea seguirá pendiente y la sesión quedará registrada como cancelada.",
                "Cancelar sesión · FocusDesk", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) return;
            saved = true;
            engine.CancelSession();
            win.Close();
        };
        DockPanel.SetDock(cancelSession, Dock.Left);
        buttons.Children.Add(cancelSession);
        var reopen = new System.Windows.Controls.Button
        {
            Content = "Volver a la sesión",
            HorizontalAlignment = System.Windows.HorizontalAlignment.Left,
            Background = System.Windows.Media.Brushes.Transparent,
            BorderBrush = System.Windows.Media.Brushes.Transparent,
            ToolTip = "Deshace «He terminado» y sigue con el tiempo que te quedaba"
        };
        reopen.Click += (_, _) =>
        {
            saved = true;   // nothing to save: the session simply runs again
            engine.ReopenSession();
            win.Close();
        };
        buttons.Children.Add(reopen);
        root.Children.Add(buttons);

        // If dismissed with X or Alt+F4, save as pending so the finished session never remains stuck in Workspace.Session.
        win.Closed += (_, _) =>
        {
            if (!saved) engine.ConfirmSession(false, noteBox.Text, selectedFiles, manualFiles);
        };

        win.Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = root };
        win.Loaded += (_, _) => noteBox.Focus();
        win.ShowDialog();
    }

    // MARK: - Profile editor (macOS: «Perfiles» in Ajustes)

    public static void ShowProfileEditor(AppEngine engine, FocusProfile? existing, Window? owner)
    {
        var draft = existing ?? new FocusProfile { Name = "Nuevo perfil" };
        var win = new Window
        {
            Title = existing == null ? "Nuevo perfil · FocusDesk" : "Editar perfil · FocusDesk",
            Width = 640,
            Height = 720,
            MinWidth = 560,
            MinHeight = 520,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            Background = BrushHex("#0D1014"),
            Foreground = BrushHex("#EDF2F5")
        };

        var shell = new Grid();
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new StackPanel { Margin = new Thickness(24, 18, 24, 18) };
        scroll.Content = root;
        Grid.SetRow(scroll, 0);
        shell.Children.Add(scroll);

        var inlineErrorText = new TextBlock { Foreground = BrushHex("#FF8080"), FontSize = 13.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12), Visibility = Visibility.Collapsed };
        root.Children.Add(inlineErrorText);

        var nameBox = MakeTextBox(draft.Name);
        var categories = engine.Workspace.Settings.Categories.Select(c => c.Name).ToList();
        if (!categories.Contains(draft.Category)) categories.Add(draft.Category);
        var catCombo = MakeCombo(categories.Select(c => new ComboOption<string>(c, c)), draft.Category);
        var minutesBox = MakeTextBox(draft.Minutes.ToString(CultureInfo.InvariantCulture));
        var strictCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear las apps que distraen", IsChecked = draft.Strict, Margin = new Thickness(0, 12, 0, 0) };
        var appModeCombo = MakeCombo(Enum.GetValues<AppListMode>().Select(m => new ComboOption<AppListMode>(m, m.Label())), draft.AppListMode);
        var appsBox = MakeTextBox(string.Join(", ", draft.Apps.Select(a => a.Id)));
        var webModeCombo = MakeCombo(Enum.GetValues<WebListMode>().Select(m => new ComboOption<WebListMode>(m, m.Label())), draft.WebListMode);
        var webActionCombo = MakeCombo(Enum.GetValues<WebBlockAction>().Select(a => new ComboOption<WebBlockAction>(a, a.Label())), draft.WebBlockAction);
        var domainsBox = MakeTextBox(draft.Domains);
        var keywordsBox = MakeTextBox(draft.BlockedTitleKeywords);
        var folderBox = MakeTextBox(draft.Folder ?? "");
        var autoStartCheck = new System.Windows.Controls.CheckBox { Content = "Empezar sola a su hora", IsChecked = draft.AutoStart, Margin = new Thickness(0, 12, 0, 0) };
        var checklistBox = MakeTextBox(draft.Checklist, multiline: true, height: 80);
        var protCombo = MakeCombo(Enum.GetValues<SessionProtection>().Select(p => new ComboOption<SessionProtection>(p, p.Label())), draft.Protection);
        var protParamBox = MakeTextBox(draft.Protection == SessionProtection.Delay
            ? draft.StopDelayMinutes.ToString(CultureInfo.InvariantCulture)
            : draft.UnlockChars.ToString(CultureInfo.InvariantCulture));

        root.Children.Add(TwoColGrid(LabeledField("Nombre del perfil", nameBox, 0), LabeledField("Categoría", catCombo, 0), 0, "185"));
        root.Children.Add(LabeledField("Duración (minutos)", minutesBox, 12));
        root.Children.Add(strictCheck);
        root.Children.Add(TwoColGrid(LabeledField("Puedes usar", appModeCombo, 0), LabeledField("Apps (.exe separados por coma)", appsBox, 0), 10));
        root.Children.Add(BuildRunningAppChips(appsBox, strictCheck));
        root.Children.Add(TwoColGrid(LabeledField("Puedes abrir", webModeCombo, 0), LabeledField("Si abres una web no permitida", webActionCombo, 0), 12));
        root.Children.Add(BuildPresetChips(domainsBox, keywordsBox));
        root.Children.Add(LabeledField("Dominios o rutas (ej. youtube.com/shorts, claude.ai)", domainsBox, 6));
        root.Children.Add(LabeledField("Palabras bloqueadas en el título (ej. Shorts, Reels, Netflix)", keywordsBox, 10));

        var pickFolder = new System.Windows.Controls.Button { Content = "Carpeta…", Margin = new Thickness(8, 0, 0, 0) };
        pickFolder.Click += (_, _) =>
        {
            using var dialog = new System.Windows.Forms.FolderBrowserDialog { Description = "Carpeta donde esperas ver el resultado" };
            if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK) folderBox.Text = dialog.SelectedPath;
        };
        var folderRow = new DockPanel();
        DockPanel.SetDock(pickFolder, Dock.Right);
        folderRow.Children.Add(pickFolder);
        folderRow.Children.Add(folderBox);
        root.Children.Add(LabeledField("Carpeta del resultado (opcional)", folderRow, 10));
        root.Children.Add(autoStartCheck);
        root.Children.Add(LabeledField("Checklist de pasos (uno por línea)", checklistBox, 12));
        root.Children.Add(TwoColGrid(LabeledField("Protección si intentas parar antes", protCombo, 0),
            LabeledField("Longitud del código (8–64) o espera (min)", protParamBox, 0), 12));

        var footer = new Border
        {
            Background = BrushHex("#161B21"),
            BorderBrush = BrushHex("#262A30"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(24, 14, 24, 14)
        };
        var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        var cancel = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0) };
        cancel.Click += (_, _) => win.Close();
        var save = MakePrimaryButton("Guardar perfil");
        buttons.Children.Add(cancel);
        buttons.Children.Add(save);
        footer.Child = buttons;
        Grid.SetRow(footer, 1);
        shell.Children.Add(footer);

        save.Click += (_, _) =>
        {
            void Fail(string message)
            {
                inlineErrorText.Text = message;
                inlineErrorText.Visibility = Visibility.Visible;
                scroll.ScrollToTop();
            }
            var name = nameBox.Text.Trim();
            if (name.Length == 0) { Fail("Escribe un nombre para el perfil."); return; }
            if (!int.TryParse(minutesBox.Text.Trim(), out var minutes) || minutes is < 1 or > 720)
            {
                Fail("La duración debe ser un número entre 1 y 720 minutos.");
                return;
            }
            var apps = appsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(id => new AllowedApp(FocusRules.CleanAppId(id), id, ""))
                .Where(a => !string.IsNullOrEmpty(a.Id))
                .ToList();
            if (strictCheck.IsChecked == true && apps.Count == 0)
            {
                Fail("Para bloquear apps indica al menos una app.");
                return;
            }
            var webAction = GetComboValue(webActionCombo, WebBlockAction.Warn);
            var parsedDomains = FocusRules.ParseDomains(domainsBox.Text);
            if (parsedDomains.Invalid.Count > 0)
            {
                Fail($"Estas webs no son válidas: {string.Join(", ", parsedDomains.Invalid)}.");
                return;
            }
            if (webAction != WebBlockAction.Warn && GetComboValue(webModeCombo, WebListMode.AllowListed) != WebListMode.BlockAll && parsedDomains.Valid.Count == 0)
            {
                Fail("Para bloquear webs indica al menos una (o elige «Bloquear todas las webs»).");
                return;
            }

            draft.Name = name;
            draft.Category = GetComboValue(catCombo, "Personal");
            draft.Minutes = minutes;
            draft.Strict = strictCheck.IsChecked == true;
            draft.AppListMode = GetComboValue(appModeCombo, AppListMode.AllowListed);
            draft.Apps = apps;
            draft.WebListMode = GetComboValue(webModeCombo, WebListMode.AllowListed);
            draft.WebBlockAction = webAction;
            draft.Domains = FocusRules.NormalizeDomains(domainsBox.Text);
            draft.BlockedTitleKeywords = FocusRules.NormalizeTitleKeywords(keywordsBox.Text);
            draft.Folder = string.IsNullOrWhiteSpace(folderBox.Text) ? null : folderBox.Text.Trim();
            draft.AutoStart = autoStartCheck.IsChecked == true;
            draft.Checklist = checklistBox.Text;
            draft.Protection = GetComboValue(protCombo, SessionProtection.None);
            if (int.TryParse(protParamBox.Text.Trim(), out var param))
            {
                if (draft.Protection == SessionProtection.Delay) draft.StopDelayMinutes = Math.Clamp(param, 1, 120);
                else if (draft.Protection == SessionProtection.Challenge) draft.UnlockChars = UnlockChallenge.ClampedLength(param);
            }
            engine.SaveProfile(draft);
            win.Close();
        };

        win.Content = shell;
        win.Loaded += (_, _) => nameBox.Focus();
        win.ShowDialog();
    }

    // MARK: - A one-line question («Nombre del perfil»)

    /// <summary>Asks for one line of text. Returns null when cancelled or left empty.</summary>
    public static string? AskText(string title, string prompt, string initial, Window? owner)
    {
        string? result = null;
        var win = new Window
        {
            Title = title + " · FocusDesk",
            Width = 460,
            SizeToContent = SizeToContent.Height,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            ResizeMode = ResizeMode.NoResize,
            Background = BrushHex("#0D1014"),
            Foreground = BrushHex("#EDF2F5")
        };
        var root = new StackPanel { Margin = new Thickness(24) };
        root.Children.Add(new TextBlock { Text = title, FontSize = 20, FontWeight = FontWeights.SemiBold });
        var box = MakeTextBox(initial);
        root.Children.Add(LabeledField(prompt, box, 14));
        var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 18, 0, 0) };
        var cancel = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0), IsCancel = true };
        var ok = MakePrimaryButton("Guardar");
        ok.IsDefault = true;
        void Accept()
        {
            if (string.IsNullOrWhiteSpace(box.Text)) return;
            result = box.Text.Trim();
            win.Close();
        }
        ok.Click += (_, _) => Accept();
        cancel.Click += (_, _) => win.Close();
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        root.Children.Add(buttons);
        win.Content = root;
        win.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        win.ShowDialog();
        return result;
    }
}
