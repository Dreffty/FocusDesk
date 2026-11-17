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
            Width = 560,
            SizeToContent = SizeToContent.Height,
            MaxHeight = 760,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            ResizeMode = ResizeMode.NoResize,
            Background = BrushHex("#0B0E14"),
            Foreground = BrushHex("#F2F5FA")
        };

        var root = new StackPanel { Margin = new Thickness(24) };
        AnimateModalIn(root);
        root.Children.Add(new TextBlock
        {
            Text = $"Sesión terminada: {session.Task.Title}",
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap
        });
        root.Children.Add(new TextBlock
        {
            Text = $"Tiempo trabajado: {FocusRules.Clock(session.Elapsed(DateTimeOffset.Now))} · Interrupciones: {session.InterruptionCount}",
            Foreground = BrushHex("#94A3B8"),
            FontSize = 12.5,
            Margin = new Thickness(0, 6, 0, 12)
        });

        // The checklist can be ticked here too: work done in another app is ticked off at the end.
        var steps = AppEngine.ChecklistSteps(session.Task.Checklist);
        if (steps.Count > 0)
        {
            root.Children.Add(new TextBlock { Text = "CHECKLIST", FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 0, 0, 5) });
            for (var i = 0; i < steps.Count; i++)
            {
                var key = i.ToString();
                var box = new System.Windows.Controls.CheckBox { Content = steps[i], IsChecked = session.Checked.Contains(key), Margin = new Thickness(0, 2, 0, 0) };
                box.Click += (_, _) => engine.SetCheck(key, box.IsChecked == true);
                root.Children.Add(box);
            }
        }

        // Files of the result folder that changed during the session
        var selectedFiles = new HashSet<string>(session.SelectedFiles);
        var manualFiles = new List<string>(session.ManualFiles);
        var filesPanel = new StackPanel();
        void RebuildFiles()
        {
            filesPanel.Children.Clear();
            var changed = session.FinalChangedFiles ?? new List<string>();
            foreach (var file in changed.Concat(manualFiles).Distinct())
            {
                var captured = file;
                var fileBox = new System.Windows.Controls.CheckBox
                {
                    Content = captured,
                    IsChecked = selectedFiles.Contains(captured),
                    Margin = new Thickness(0, 2, 0, 0),
                    ToolTip = captured
                };
                fileBox.Click += (_, _) =>
                {
                    if (fileBox.IsChecked == true) selectedFiles.Add(captured); else selectedFiles.Remove(captured);
                };
                filesPanel.Children.Add(fileBox);
            }
        }
        if (!string.IsNullOrWhiteSpace(session.Task.Folder) || manualFiles.Count > 0)
        {
            root.Children.Add(new TextBlock { Text = "ARCHIVOS DEL RESULTADO", FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 12, 0, 5) });
            if (!string.IsNullOrWhiteSpace(session.FinalEvidenceMessage))
                root.Children.Add(new TextBlock { Text = session.FinalEvidenceMessage, FontSize = 12, Foreground = BrushHex("#94A3B8"), TextWrapping = TextWrapping.Wrap });
            if ((session.FinalChangedFiles?.Count ?? 0) == 0)
                root.Children.Add(new TextBlock { Text = "No se ha detectado ningún archivo cambiado en la carpeta. Puedes adjuntar uno a mano.", FontSize = 12, Foreground = BrushHex("#94A3B8"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0) });
            RebuildFiles();
            root.Children.Add(new ScrollViewer { MaxHeight = 120, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = filesPanel });
            var attach = new System.Windows.Controls.Button { Content = "Adjuntar archivo…", Margin = new Thickness(0, 6, 0, 0), HorizontalAlignment = System.Windows.HorizontalAlignment.Left };
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
            root.Children.Add(attach);
        }

        var noteBox = MakeTextBox("", multiline: true, height: 80);
        root.Children.Add(LabeledField("Nota de resultado (opcional)", noteBox, 12));

        var nextChoice = MakeCombo(new[]
        {
            new ComboOption<NextTransition>(NextTransition.KeepSchedule, "Nada: la siguiente conserva su horario"),
            new ComboOption<NextTransition>(NextTransition.StartNextNow, "Empezar la siguiente ahora"),
            new ComboOption<NextTransition>(NextTransition.Rest10Min, "Descansar 10 minutos antes de seguir")
        }, NextTransition.KeepSchedule);
        root.Children.Add(LabeledField("Después", nextChoice, 10));

        var btns = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new Thickness(0, 18, 0, 0)
        };
        var reopen = new System.Windows.Controls.Button { Content = "Reabrir la sesión", Margin = new Thickness(0, 0, 10, 0) };
        reopen.Click += (_, _) =>
        {
            saved = true;   // nothing to save: the session simply runs again
            engine.ReopenSession();
            win.Close();
        };
        var pending = new System.Windows.Controls.Button { Content = "Sigue pendiente", Margin = new Thickness(0, 0, 10, 0) };
        pending.Click += (_, _) =>
        {
            saved = true;
            engine.ConfirmSession(false, noteBox.Text, selectedFiles, manualFiles, GetComboValue(nextChoice, NextTransition.KeepSchedule));
            win.Close();
        };
        var done = MakePrimaryButton("Completada");
        done.Click += (_, _) =>
        {
            saved = true;
            engine.ConfirmSession(true, noteBox.Text, selectedFiles, manualFiles, GetComboValue(nextChoice, NextTransition.KeepSchedule));
            win.Close();
        };
        btns.Children.Add(reopen);
        btns.Children.Add(pending);
        btns.Children.Add(done);
        root.Children.Add(btns);

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
            Background = BrushHex("#0B0E14"),
            Foreground = BrushHex("#F2F5FA")
        };

        var shell = new Grid();
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new StackPanel { Margin = new Thickness(24, 18, 24, 18) };
        scroll.Content = root;
        Grid.SetRow(scroll, 0);
        shell.Children.Add(scroll);

        var inlineErrorText = new TextBlock { Foreground = BrushHex("#F26D6D"), FontSize = 12.5, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12), Visibility = Visibility.Collapsed };
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
            Background = BrushHex("#131822"),
            BorderBrush = BrushHex("#242E40"),
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
}
