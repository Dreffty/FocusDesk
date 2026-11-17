using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

/// <summary>Ajustes (macOS: SettingsView in Editors.swift), the keyboard shortcuts and the command palette.</summary>
public partial class MainWindow
{
    private string _newCategoryName = "";
    private int _newCategoryColor;

    private static readonly (string Name, double R, double G, double B)[] CategoryColors =
    {
        ("Azul", 0.40, 0.78, 0.90), ("Violeta", 0.65, 0.69, 0.98), ("Naranja", 1.00, 0.65, 0.48),
        ("Verde", 0.45, 0.89, 0.63), ("Rosa", 0.96, 0.60, 0.78), ("Gris", 0.70, 0.78, 0.87)
    };

    // MARK: - Shortcuts

    private static readonly uint[] HotKeyCodes = { 0x46, 0x20, 0x4A, 0x4B };
    private static readonly string[] HotKeyNames = { "Ctrl+Alt+Win+F", "Ctrl+Alt+Win+Espacio", "Ctrl+Alt+Win+J", "Ctrl+Alt+Win+K" };

    /// <summary>Registers (or removes) the global shortcut that opens FocusDesk, according to Ajustes.</summary>
    private void ApplyHotKeys()
    {
        var handle = new WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero) return;
        UnregisterHotKey(handle, HOTKEY_SHOW);
        var settings = _engine.Workspace.Settings;
        if (!settings.HotKeyEnabled) return;
        RegisterHotKey(handle, HOTKEY_SHOW, MOD_CONTROL | MOD_ALT | MOD_WIN, HotKeyCodes[Math.Clamp(settings.HotKeyChoice, 0, HotKeyCodes.Length - 1)]);
    }

    private void OnWindowKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Control) != ModifierKeys.Control) return;
        var typing = Keyboard.FocusedElement is System.Windows.Controls.TextBox;
        if (e.Key == Key.K)
        {
            e.Handled = true;
            ShowCommandPalette();
        }
        else if (e.Key == Key.N && !typing)
        {
            e.Handled = true;
            Dialogs.ShowTaskEditor(_engine, null, this);
        }
        else if (e.Key == Key.Z && !typing)
        {
            e.Handled = true;
            if ((Keyboard.Modifiers & ModifierKeys.Shift) == ModifierKeys.Shift) _engine.RedoAgenda(); else _engine.UndoAgenda();
        }
        else if (e.Key == Key.Y && !typing)
        {
            e.Handled = true;
            _engine.RedoAgenda();
        }
    }

    // MARK: - Command palette (Ctrl+K)

    private void ShowCommandPalette()
    {
        var commands = new List<(string Title, Action Run)>();
        foreach (var page in new[] { ("Hoy", "Hoy"), ("Semana", "Semana"), ("Historial", "Historial"), ("Reglas y juegos", "Reglas"),
                                     ("Bloquear ahora", "Bloquear"), ("Descansos", "Descansos"), ("Ajustes", "Ajustes") })
        {
            var tag = page.Item2;
            commands.Add(($"Ir a {page.Item1}", () => _engine.ActivePage = tag));
        }
        commands.Add(("Nueva tarea", () => Dialogs.ShowTaskEditor(_engine, null, this)));
        commands.Add(("Nueva regla", () => Dialogs.ShowRuleEditor(_engine, null, null, this)));
        commands.Add(("Nuevo perfil", () => Dialogs.ShowProfileEditor(_engine, null, this)));
        commands.Add(("Bloqueo rápido de 30 minutos", () => _engine.LaunchQuickBlock(30, _quickProtection, _quickPreset)));
        commands.Add(("Bloqueo rápido de 1 hora", () => _engine.LaunchQuickBlock(60, _quickProtection, _quickPreset)));
        if (_engine.Workspace.Session is { EndedAt: null } running)
        {
            commands.Add((running.Paused ? "Reanudar la sesión" : "Pausar la sesión", () =>
            {
                if (running.Paused) _engine.ResumeSession();
                else if (Dialogs.RequestSessionStop("pausar", running, this)) _engine.PauseSession();
            }));
            commands.Add(("Añadir 10 minutos a la sesión", () => _engine.AddSessionMinutes(10)));
            commands.Add(("Terminar la sesión (He terminado)", () =>
            {
                if (Dialogs.RequestSessionStop("terminar antes", running, this)) _engine.FinishSession();
            }));
        }
        commands.Add(("Deshacer el último cambio de la agenda", () => _engine.UndoAgenda()));
        commands.Add(("Exportar la agenda al calendario (.ics)", ExportCalendarFile));
        foreach (var task in _engine.Workspace.Tasks.Where(t => !t.Completed).OrderBy(t => t.ScheduledAt).Take(40))
        {
            var captured = task;
            commands.Add(($"Iniciar «{captured.Title}»", () => StartOrHandoffSession(captured)));
            commands.Add(($"Editar «{captured.Title}»", () => Dialogs.ShowTaskEditor(_engine, captured, this)));
        }

        var win = new Window
        {
            Title = "Buscar acción · FocusDesk",
            Width = 520,
            Height = 420,
            Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            ResizeMode = ResizeMode.NoResize,
            Background = BrushHex("#0B0E14"),
            Foreground = BrushHex("#F2F5FA")
        };
        var root = new DockPanel { Margin = new Thickness(16) };
        var search = new System.Windows.Controls.TextBox { Margin = new Thickness(0, 0, 0, 10), FontSize = 15 };
        DockPanel.SetDock(search, Dock.Top);
        var list = new System.Windows.Controls.ListBox { Background = BrushHex("#131822"), BorderBrush = BrushHex("#242E40") };
        root.Children.Add(search);
        root.Children.Add(list);

        void Refill()
        {
            var query = FocusRules.Fold(search.Text.Trim());
            list.Items.Clear();
            foreach (var command in commands)
            {
                if (query.Length > 0 && !FocusRules.Fold(command.Title).Contains(query, StringComparison.Ordinal)) continue;
                list.Items.Add(new ListBoxItem { Content = command.Title, Tag = command.Run, Foreground = BrushHex("#F2F5FA") });
            }
            if (list.Items.Count > 0) list.SelectedIndex = 0;
        }
        void RunSelected()
        {
            if (list.SelectedItem is not ListBoxItem item || item.Tag is not Action action) return;
            win.Close();
            action();
        }
        search.TextChanged += (_, _) => Refill();
        search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Down && list.SelectedIndex < list.Items.Count - 1) { list.SelectedIndex++; e.Handled = true; }
            else if (e.Key == Key.Up && list.SelectedIndex > 0) { list.SelectedIndex--; e.Handled = true; }
            else if (e.Key == Key.Enter) { RunSelected(); e.Handled = true; }
            else if (e.Key == Key.Escape) { win.Close(); e.Handled = true; }
        };
        list.MouseDoubleClick += (_, _) => RunSelected();
        Refill();
        win.Content = root;
        win.Loaded += (_, _) => search.Focus();
        win.ShowDialog();
    }

    // MARK: - Ajustes

    private void BuildSettingsPage()
    {
        PageContent.Children.Add(PageHeader("Ajustes", "A tu manera."));
        var s = _engine.Workspace.Settings;

        // General
        var general = new StackPanel();
        general.Children.Add(SectionLabel("GENERAL", 0, "#38A169"));
        general.Children.Add(Labeled("Tamaño del texto", ChoiceBox(new[]
        {
            new ComboOption<double>(1.0, "Normal"), new ComboOption<double>(1.15, "Grande"), new ComboOption<double>(1.3, "Muy grande")
        }, s.TextScale, v =>
        {
            ChangeSetting(x => x.TextScale = v);
            ApplyTextScale();
        }, 180), 0));
        general.Children.Add(ToggleBox("Atajo global para abrir FocusDesk", s.HotKeyEnabled, v =>
        {
            ChangeSetting(x => x.HotKeyEnabled = v);
            ApplyHotKeys();
        }));
        general.Children.Add(Labeled("Atajo", ChoiceBox(HotKeyNames.Select((name, index) => new ComboOption<int>(index, name)), s.HotKeyChoice, v =>
        {
            ChangeSetting(x => x.HotKeyChoice = v);
            ApplyHotKeys();
        }, 240), 8));
        general.Children.Add(MutedText("Ctrl+Alt+Win+P pausa o reanuda la sesión y Ctrl+Alt+Win+T la termina. Ctrl+K busca cualquier acción.", 12, 6));
        general.Children.Add(ToggleBox("Abrir FocusDesk al iniciar sesión en Windows", LaunchAtLogin.IsEnabled(), v => LaunchAtLogin.Set(v)));
        general.Children.Add(Labeled("Protegerla desde (antes de que empiece una tarea o regla protegida)", ChoiceBox(
            new[] { 0, 5, 10, 15, 30, 60 }.Select(m => new ComboOption<int>(m, m == 0 ? "No protegerla antes" : $"{m} min antes")),
            s.RunUpMinutes, SetRunUpMinutes, 220), 10));
        general.Children.Add(Row(SmallButton("Salir de FocusDesk", () => _onQuitRequested(), true, 0)));
        PageContent.Children.Add(Card(general));

        // Avisos
        var alerts = new StackPanel();
        alerts.Children.Add(SectionLabel("AVISOS", 0, "#38A169"));
        alerts.Children.Add(ToggleBox("Avisarme cuando queden 5 min y 1 min de un presupuesto diario o visita", s.PreBlockRemindersEnabled,
            v => ChangeSetting(x => x.PreBlockRemindersEnabled = v), 0));
        alerts.Children.Add(ToggleBox("Mostrar aviso y cuenta atrás cuando empiece un descanso programado", s.EnforceBreaks,
            v => ChangeSetting(x => x.EnforceBreaks = v)));
        PageContent.Children.Add(Card(alerts));

        // Agenda
        var agenda = new StackPanel();
        agenda.Children.Add(SectionLabel("AGENDA", 0, "#38A169"));
        agenda.Children.Add(WrapRow(
            Labeled("Inicio de jornada (hora)", NumberBox(s.WorkStartHour, 0, 23, v => ChangeSetting(x => x.WorkStartHour = v)), 0),
            Labeled("Fin de jornada (hora)", NumberBox(s.WorkEndHour, 1, 24, v => ChangeSetting(x => x.WorkEndHour = v)), 0),
            Labeled("Corte de día (0-8 h)", NumberBox(s.DayRolloverHour, 0, 8, v => ChangeSetting(x => x.DayRolloverHour = v)), 0),
            Labeled("Detalle de actividad (días)", ChoiceBox(new[] { 7, 14, 30, 60, 90 }.Select(d => new ComboOption<int>(d, $"{d} días")), s.DetailDays,
                v => ChangeSetting(x => x.DetailDays = v), 130), 0)));
        agenda.Children.Add(SectionLabel("DÍAS LABORABLES", 12));
        var days = new WrapPanel();
        foreach (var (dayNum, dayLabel) in new[] { (2, "Lun"), (3, "Mar"), (4, "Mié"), (5, "Jue"), (6, "Vie"), (7, "Sáb"), (1, "Dom") })
        {
            var num = dayNum;
            var dayButton = new System.Windows.Controls.Button { Content = dayLabel, Margin = new Thickness(0, 0, 6, 0), MinWidth = 52 };
            void Paint()
            {
                var on = _engine.Workspace.Settings.Workdays.Contains(num);
                dayButton.Background = BrushHex(on ? "#38A169" : "#1B2230");
                dayButton.Foreground = BrushHex(on ? "#0B0E14" : "#E2E8F0");
            }
            Paint();
            dayButton.Click += (_, _) =>
            {
                var set = _engine.Workspace.Settings.Workdays;
                if (!set.Remove(num)) set.Add(num);
                _engine.Persist();
                Paint();
            };
            days.Children.Add(dayButton);
        }
        agenda.Children.Add(days);
        agenda.Children.Add(SectionLabel("CATEGORÍAS", 14));
        var categoryList = new WrapPanel();
        foreach (var category in s.Categories)
        {
            var swatch = new System.Windows.Media.SolidColorBrush(System.Windows.Media.Color.FromRgb(
                (byte)Math.Round(category.Red * 255), (byte)Math.Round(category.Green * 255), (byte)Math.Round(category.Blue * 255)));
            categoryList.Children.Add(new Border
            {
                Background = BrushHex("#1B2230"),
                CornerRadius = new CornerRadius(6),
                Padding = new Thickness(10, 4, 10, 4),
                Margin = new Thickness(0, 0, 6, 6),
                Child = new TextBlock { Text = "● " + category.Name, Foreground = swatch, FontSize = 12.5 }
            });
        }
        agenda.Children.Add(categoryList);
        var categoryName = new System.Windows.Controls.TextBox { Text = _newCategoryName, Width = 170 };
        categoryName.LostFocus += (_, _) => _newCategoryName = categoryName.Text;
        var addCategory = SmallButton("Añadir categoría", () =>
        {
            var color = CategoryColors[Math.Clamp(_newCategoryColor, 0, CategoryColors.Length - 1)];
            _engine.AddCategory(categoryName.Text, color.R, color.G, color.B);
            if (string.IsNullOrEmpty(_engine.Error)) _newCategoryName = "";
            RefreshUI();
        }, true, 0);
        addCategory.Margin = new Thickness(0, 22, 0, 0);
        var categoryForm = new WrapPanel { Margin = new Thickness(0, 4, 0, 0) };
        categoryForm.Children.Add(Labeled("Nueva categoría", categoryName, 4));
        categoryForm.Children.Add(Labeled("Color", ChoiceBox(CategoryColors.Select((c, i) => new ComboOption<int>(i, c.Name)), _newCategoryColor, v => _newCategoryColor = v, 120), 4));
        categoryForm.Children.Add(addCategory);
        agenda.Children.Add(categoryForm);
        PageContent.Children.Add(Card(agenda));

        // Profiles
        var profiles = new StackPanel();
        var profileHead = new DockPanel();
        var addProfile = SmallButton("+ Nuevo perfil", () => Dialogs.ShowProfileEditor(_engine, null, this), true, 0);
        DockPanel.SetDock(addProfile, Dock.Right);
        profileHead.Children.Add(addProfile);
        profileHead.Children.Add(SectionLabel("PERFILES DE TAREA", 0, "#38A169"));
        profiles.Children.Add(profileHead);
        foreach (var profile in _engine.Workspace.Profiles)
        {
            var line = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
            var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            buttons.Children.Add(SmallButton("Editar", () => Dialogs.ShowProfileEditor(_engine, profile, this)));
            buttons.Children.Add(SmallButton("Borrar perfil", () =>
            {
                var answer = System.Windows.MessageBox.Show(this, $"¿Borrar el perfil «{profile.Name}»?", "Borrar perfil · FocusDesk",
                    MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Yes) _engine.DeleteProfile(profile.Id);
            }, true, 0));
            DockPanel.SetDock(buttons, Dock.Right);
            line.Children.Add(buttons);
            line.Children.Add(new TextBlock { Text = $"{profile.Name} · {profile.Category} · {profile.Minutes} min", FontSize = 13.5, VerticalAlignment = VerticalAlignment.Center });
            profiles.Children.Add(line);
        }
        PageContent.Children.Add(Card(profiles));

        // Study sources
        var studyPanel = new StackPanel();
        studyPanel.Children.Add(SectionLabel("QUÉ CUENTA COMO ESTUDIO ACTIVO", 0, "#38A169"));
        studyPanel.Children.Add(MutedText("Lo que añadas hoy empieza a contar mañana para evitar atajos de último minuto.", 12, 0));
        var addRow = new WrapPanel { Margin = new Thickness(0, 10, 0, 12) };
        var webInput = new System.Windows.Controls.TextBox { Width = 220, Margin = new Thickness(0, 0, 8, 0) };
        var addWebBtn = new System.Windows.Controls.Button { Content = "Añadir web", Margin = new Thickness(0, 0, 16, 0) };
        addWebBtn.Click += (_, _) => { _engine.AddStudyWeb(webInput.Text); webInput.Text = ""; };
        var appInput = new System.Windows.Controls.TextBox { Width = 170, Margin = new Thickness(0, 0, 8, 0) };
        var addAppBtn = new System.Windows.Controls.Button { Content = "Añadir programa (.exe)", Margin = new Thickness(0, 0, 8, 0) };
        addAppBtn.Click += (_, _) => { _engine.AddStudyApp(appInput.Text, appInput.Text); appInput.Text = ""; };
        var pickAppBtn = new System.Windows.Controls.Button { Content = "Elegir…" };
        pickAppBtn.Click += (_, _) =>
        {
            var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "Programas (*.exe)|*.exe" };
            if (dialog.ShowDialog() != true) return;
            _engine.AddStudyApp(Path.GetFileNameWithoutExtension(dialog.FileName), Path.GetFileNameWithoutExtension(dialog.FileName));
        };
        addRow.Children.Add(webInput);
        addRow.Children.Add(addWebBtn);
        addRow.Children.Add(appInput);
        addRow.Children.Add(addAppBtn);
        addRow.Children.Add(pickAppBtn);
        studyPanel.Children.Add(addRow);
        var wrap = new WrapPanel();
        foreach (var src in s.StudySources)
        {
            var pill = new System.Windows.Controls.Button
            {
                Content = $"{src.Name} ({src.Kind}) ×",
                Margin = new Thickness(0, 0, 6, 6),
                Padding = new Thickness(10, 4, 10, 4),
                MinHeight = 28,
                FontSize = 12
            };
            pill.Click += (_, _) => _engine.RemoveStudySource(src);
            wrap.Children.Add(pill);
        }
        studyPanel.Children.Add(wrap);
        PageContent.Children.Add(Card(studyPanel));

        // Privacy and protection
        var guardPanel = new StackPanel();
        guardPanel.Children.Add(SectionLabel("PRIVACIDAD Y PROTECCIÓN", 0, "#38A169"));
        var guardCheck = ToggleBox("Volver a abrirse si lo matan durante una sesión protegida (vigilante al iniciar Windows)", s.RelaunchGuard, v => { }, 0);
        guardCheck.Click += (_, _) =>
        {
            var wantEnabled = guardCheck.IsChecked == true;
            if (!wantEnabled && !RequireProtectionGateForSettings("apagar el vigilante"))
            {
                guardCheck.IsChecked = true;
                return;
            }
            _engine.SetRelaunchGuard(wantEnabled);
        };
        guardPanel.Children.Add(guardCheck);
        var clipCheck = ToggleBox("Vigilar y limpiar el portapapeles durante bloqueos activos", s.ProtectClipboard, v => { });
        clipCheck.Click += (_, _) =>
        {
            var wantEnabled = clipCheck.IsChecked == true;
            if (!wantEnabled && !RequireProtectionGateForSettings("apagar esta vigilancia"))
            {
                clipCheck.IsChecked = true;
                return;
            }
            ChangeSetting(x => x.ProtectClipboard = wantEnabled);
        };
        guardPanel.Children.Add(clipCheck);
        guardPanel.Children.Add(ToggleBox("Proteger el historial y el registro de actividad con bloqueos activos", s.ProtectActivityHistory,
            v => ChangeSetting(x => x.ProtectActivityHistory = v)));
        guardPanel.Children.Add(ToggleBox("Anotar las webs que visitas durante una sesión (para el historial)", s.ObserveBrowserSites,
            v => ChangeSetting(x => x.ObserveBrowserSites = v)));
        PageContent.Children.Add(Card(guardPanel));

        // Data and copies
        var backupPanel = new StackPanel();
        backupPanel.Children.Add(SectionLabel("DATOS Y COPIAS DE SEGURIDAD", 0, "#38A169"));
        var expBtn = SmallButton("Exportar copia (.json)", () =>
        {
            var dlg = new Microsoft.Win32.SaveFileDialog { FileName = "FocusDesk-backup.json", Filter = "JSON (*.json)|*.json" };
            if (dlg.ShowDialog() != true) return;
            try { _engine.ExportBackup(dlg.FileName); }
            catch (Exception ex) { _engine.Error = $"No se pudo exportar la copia: {ex.Message}"; UpdateNoticeAndSidebar(); }
        });
        var impBtn = SmallButton("Importar / restaurar copia…", () =>
        {
            if (!RequireProtectionGateForSettings("restaurar una copia")) return;
            var dlg = new Microsoft.Win32.OpenFileDialog { Filter = "JSON (*.json)|*.json" };
            if (dlg.ShowDialog() != true) return;
            try { _engine.ImportBackup(dlg.FileName); }
            catch (Exception ex) { _engine.Error = $"No se pudo importar la copia: {ex.Message}"; UpdateNoticeAndSidebar(); }
        });
        var recoverBtn = SmallButton("Recuperar copia automática", () =>
        {
            if (!RequireProtectionGateForSettings("recuperar una copia")) return;
            _engine.RecoverFromAutoBackup();
        });
        var openBtn = SmallButton("Abrir carpeta de datos", () =>
        {
            try { Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_engine.Store.DirectoryPath}\"") { UseShellExecute = true }); }
            catch { }
        }, true, 0);
        backupPanel.Children.Add(WrapRow(expBtn, impBtn, recoverBtn, openBtn));

        // The daily copies kept for 14 days
        var dailyFiles = new List<string>();
        try
        {
            if (Directory.Exists(_engine.Store.BackupsDirectoryPath))
                dailyFiles = Directory.GetFiles(_engine.Store.BackupsDirectoryPath, "daily-*.json").OrderByDescending(f => f).Take(14).ToList();
        }
        catch { }
        if (dailyFiles.Count > 0)
        {
            string chosenDaily = dailyFiles[0];
            var dailyChoice = ChoiceBox(dailyFiles.Select(f => new ComboOption<string>(f, Path.GetFileNameWithoutExtension(f).Replace("daily-", "Copia del "))),
                chosenDaily, v => chosenDaily = v, 220);
            var restoreDaily = SmallButton("Restaurar esta copia", () =>
            {
                if (!RequireProtectionGateForSettings("restaurar una copia")) return;
                var answer = System.Windows.MessageBox.Show(this,
                    "Se sustituirán tus datos actuales por esa copia (los de ahora se guardan antes en «backups»). ¿Seguro?",
                    "Restaurar copia · FocusDesk", MessageBoxButton.YesNo, MessageBoxImage.Warning);
                if (answer != MessageBoxResult.Yes) return;
                try { _engine.ImportBackup(chosenDaily); }
                catch (Exception ex) { _engine.Error = $"No se pudo restaurar la copia: {ex.Message}"; UpdateNoticeAndSidebar(); }
            }, true, 0);
            restoreDaily.Margin = new Thickness(10, 0, 0, 0);
            backupPanel.Children.Add(SectionLabel("COPIAS DIARIAS (14 DÍAS)", 12));
            backupPanel.Children.Add(Row(dailyChoice, restoreDaily));
        }
        PageContent.Children.Add(Card(backupPanel));
    }

    private void SetRunUpMinutes(int minutes)
    {
        var current = _engine.Workspace.Settings.RunUpMinutes;
        if (minutes < current)
        {
            // Shortening it while a task is already inside it would be the cheapest way out of that very task.
            var sessionTaskId = _engine.Workspace.Session?.Task.Id;
            var armedTask = _engine.Workspace.Tasks.FirstOrDefault(t => !t.Completed && t.Id != sessionTaskId && _engine.IsTaskProtected(t));
            if (armedTask != null)
            {
                _engine.Notice = $"«{armedTask.Title}» ya está protegida porque está a punto de empezar: el margen se puede acortar cuando empiece o acabe su hora.";
                UpdateNoticeAndSidebar();
                RefreshUI();
                return;
            }
            var armedRule = _engine.Workspace.GeneralRules.FirstOrDefault(r => _engine.IsRuleProtected(r));
            if (armedRule != null)
            {
                _engine.Notice = $"«{armedRule.Name}» ya está protegida: el margen se puede acortar cuando deje de estarlo.";
                UpdateNoticeAndSidebar();
                RefreshUI();
                return;
            }
        }
        ChangeSetting(x => x.RunUpMinutes = Math.Clamp(minutes, 0, 120));
    }

    /// <summary>Text size (1, 1.15 or 1.3 times), as macOS offers its own because it has no dynamic type.</summary>
    private void ApplyTextScale()
    {
        var scale = Math.Clamp(_engine.Workspace.Settings.TextScale, 1.0, 1.3);
        PageContent.LayoutTransform = new System.Windows.Media.ScaleTransform(scale, scale);
    }
}
