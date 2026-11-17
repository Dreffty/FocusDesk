using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

public sealed record ComboOption<T>(T Value, string Label)
{
    public override string ToString() => Label;
}

public static partial class Dialogs
{
    /// <summary>Set by the app at start-up: keeps waits («Espera») alive between presses and shows messages.</summary>
    public static IStopGateHost? Host { get; set; }

    private static SolidColorBrush BrushHex(string hex) =>
        new((System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(hex));

    private static void AnimateModalIn(FrameworkElement root)
    {
        root.Opacity = 0;
        var scale = new ScaleTransform(0.96, 0.96);
        root.RenderTransform = scale;
        root.RenderTransformOrigin = new System.Windows.Point(0.5, 0.5);

        root.Loaded += (_, _) =>
        {
            var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
            var dur = TimeSpan.FromMilliseconds(160);
            root.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, dur) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.96, 1.0, dur) { EasingFunction = ease });
            scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.96, 1.0, dur) { EasingFunction = ease });
        };
    }

    private static UIElement BuildSectionCard(string heading, string? subtitle, UIElement content)
    {
        var inner = new StackPanel();
        inner.Children.Add(new TextBlock
        {
            Text = heading.ToUpperInvariant(),
            FontSize = 10.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#38A169"),
            Margin = new Thickness(0, 0, 0, subtitle == null ? 10 : 3)
        });
        if (!string.IsNullOrEmpty(subtitle))
        {
            inner.Children.Add(new TextBlock
            {
                Text = subtitle,
                FontSize = 11.5,
                Foreground = BrushHex("#94A3B8"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 12)
            });
        }
        inner.Children.Add(content);
        return new Border
        {
            Background = BrushHex("#131822"),
            BorderBrush = BrushHex("#242E40"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(18),
            Margin = new Thickness(0, 0, 0, 14),
            Child = inner
        };
    }

    private static UIElement LabeledField(string label, UIElement control, double topMargin = 10)
    {
        var panel = new StackPanel { Margin = new Thickness(0, topMargin, 0, 0) };
        panel.Children.Add(new TextBlock
        {
            Text = label.ToUpperInvariant(),
            FontSize = 10.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#94A3B8"),
            Margin = new Thickness(0, 0, 0, 5)
        });
        panel.Children.Add(control);
        return panel;
    }

    private static System.Windows.Controls.TextBox MakeTextBox(string initial = "", bool multiline = false, double height = double.NaN)
    {
        var tb = new System.Windows.Controls.TextBox { Text = initial };
        if (multiline)
        {
            tb.AcceptsReturn = true;
            tb.TextWrapping = TextWrapping.Wrap;
            tb.VerticalContentAlignment = VerticalAlignment.Top;
            if (!double.IsNaN(height)) tb.Height = height;
        }
        return tb;
    }

    private static System.Windows.Controls.ComboBox MakeCombo<T>(IEnumerable<ComboOption<T>> options, T selected)
    {
        var list = options.ToList();
        var cb = new System.Windows.Controls.ComboBox { ItemsSource = list };
        var idx = list.FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, selected));
        cb.SelectedIndex = idx >= 0 ? idx : 0;
        return cb;
    }

    private static T GetComboValue<T>(System.Windows.Controls.ComboBox cb, T fallback) =>
        cb.SelectedItem is ComboOption<T> opt ? opt.Value : fallback;

    private static Grid TwoColGrid(UIElement left, UIElement right, double topMargin = 10, string rightWidth = "*")
    {
        var grid = new Grid { Margin = new Thickness(0, topMargin, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(14) });
        grid.ColumnDefinitions.Add(new ColumnDefinition
        {
            Width = rightWidth == "*"
                ? new GridLength(1, GridUnitType.Star)
                : new GridLength(double.Parse(rightWidth, CultureInfo.InvariantCulture))
        });
        Grid.SetColumn(left, 0);
        Grid.SetColumn(right, 2);
        grid.Children.Add(left);
        grid.Children.Add(right);
        return grid;
    }

    private static Grid ThreeColGrid(UIElement c1, UIElement c2, UIElement c3, double topMargin = 10)
    {
        var grid = new Grid { Margin = new Thickness(0, topMargin, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(12) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(c1, 0);
        Grid.SetColumn(c2, 2);
        Grid.SetColumn(c3, 4);
        grid.Children.Add(c1);
        grid.Children.Add(c2);
        grid.Children.Add(c3);
        return grid;
    }

    private static System.Windows.Controls.Button MakeChipButton(string text, Action onClick)
    {
        var btn = new System.Windows.Controls.Button
        {
            Content = text,
            Padding = new Thickness(10, 4, 10, 4),
            MinHeight = 26,
            FontSize = 11.5,
            Margin = new Thickness(0, 6, 6, 0),
            Background = BrushHex("#1B2230"),
            Foreground = BrushHex("#E2E8F0"),
            BorderBrush = BrushHex("#2E3A4F")
        };
        btn.Click += (_, _) => onClick();
        return btn;
    }

    private static System.Windows.Controls.Button MakePrimaryButton(string text)
    {
        var btn = new System.Windows.Controls.Button
        {
            Content = text,
            Background = BrushHex("#38A169"),
            Foreground = BrushHex("#0B0E14"),
            BorderBrush = BrushHex("#38A169"),
            FontWeight = FontWeights.SemiBold,
            Padding = new Thickness(16, 8, 16, 8)
        };
        return btn;
    }

    private static string CleanCsvMerge(string existing, IEnumerable<string> additions, bool domainMode = false)
    {
        var cur = domainMode
            ? FocusRules.ParseDomains(existing).Valid
            : FocusRules.ParseTitleKeywords(existing);
        var seen = cur.Select(x => x.ToLowerInvariant()).ToHashSet();
        var merged = new List<string>(cur);
        foreach (var item in additions)
        {
            if (seen.Add(item.ToLowerInvariant()))
                merged.Add(item);
        }
        return string.Join(", ", merged);
    }

    private static WrapPanel BuildPresetChips(System.Windows.Controls.TextBox domainsBox, System.Windows.Controls.TextBox keywordsBox, Action? onPresetApplied = null)
    {
        var wrap = new WrapPanel { Margin = new Thickness(0, 2, 0, 6) };
        foreach (var preset in DistractionPreset.All)
        {
            var captured = preset;
            wrap.Children.Add(MakeChipButton("+ " + captured.Label, () =>
            {
                domainsBox.Text = CleanCsvMerge(domainsBox.Text, captured.Domains, domainMode: true);
                keywordsBox.Text = CleanCsvMerge(keywordsBox.Text, captured.TitleKeywords, domainMode: false);
                onPresetApplied?.Invoke();
            }));
        }
        return wrap;
    }

    private static WrapPanel BuildRunningAppChips(System.Windows.Controls.TextBox appsBox, System.Windows.Controls.CheckBox? autoCheck = null)
    {
        var wrap = new WrapPanel { Margin = new Thickness(0, 4, 0, 2) };
        try
        {
            var openApps = WindowsActivity.VisibleWindows()
                .Select(w => FocusRules.CleanAppId(w.ProcessName))
                .Where(n => !string.IsNullOrEmpty(n) && !FocusRules.SystemExemptProcesses.Contains(n))
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .Take(10)
                .ToList();
            foreach (var proc in openApps)
            {
                var captured = proc;
                wrap.Children.Add(MakeChipButton($"+ {captured}", () =>
                {
                    var cur = appsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                        .Select(FocusRules.CleanAppId)
                        .Where(x => !string.IsNullOrEmpty(x))
                        .ToList();
                    if (!cur.Contains(captured, StringComparer.OrdinalIgnoreCase))
                        cur.Add(captured);
                    appsBox.Text = string.Join(", ", cur);
                    if (autoCheck != null) autoCheck.IsChecked = true;
                }));
            }
        }
        catch { }
        return wrap;
    }

    public static bool RequestUnlock(SessionProtection protection, int unlockChars, int delayMinutes, string actionLabel, Window? owner)
    {
        if (protection == SessionProtection.None) return true;

        // «Espera»: not a window you have to keep open. The wait is stored (it survives closing the app) and the
        // action is repeated when it is over, as on macOS.
        if (protection == SessionProtection.Delay && Host != null)
            return Host.EvaluateDelay(actionLabel, delayMinutes);

        var isChallenge = protection is SessionProtection.Challenge or SessionProtection.Forced;
        var win = new Window
        {
            Title = "Desbloqueo requerido · FocusDesk",
            Width = 540,
            Height = isChallenge ? 375 : 265,
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
            Text = $"Para {actionLabel}",
            FontSize = 18,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#F2F5FA"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 8)
        });

        var unlocked = false;

        if (isChallenge)
        {
            var len = protection == SessionProtection.Forced ? 60 : unlockChars;
            var expected = UnlockChallenge.Make(len);
            var intro = protection == SessionProtection.Forced
                ? $"Modo «Hasta el final»: escribe este código de emergencia de {expected.Length} caracteres (quedará anotado en auditoría, sin pegar):"
                : $"Escribe exactamente este código de {expected.Length} caracteres (no se permite pegar):";

            root.Children.Add(new TextBlock
            {
                Text = intro,
                Foreground = BrushHex(protection == SessionProtection.Forced ? "#F5B95F" : "#94A3B8"),
                TextWrapping = TextWrapping.Wrap,
                FontSize = 12.5,
                Margin = new Thickness(0, 0, 0, 12)
            });

            var codeBorder = new Border
            {
                Background = BrushHex("#131822"),
                BorderBrush = BrushHex("#242E40"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(14),
                Margin = new Thickness(0, 0, 0, 12)
            };
            var codeText = new TextBlock
            {
                Text = expected,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                FontSize = 15,
                Foreground = BrushHex("#38A169"),
                TextWrapping = TextWrapping.Wrap
            };
            codeBorder.Child = codeText;
            root.Children.Add(codeBorder);

            var input = new System.Windows.Controls.TextBox
            {
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                FontSize = 14,
                ContextMenu = null
            };
            System.Windows.DataObject.AddPastingHandler(input, (_, e) => e.CancelCommand());
            CommandManager.AddPreviewExecutedHandler(input, (_, e) =>
            {
                if (e.Command == ApplicationCommands.Paste) e.Handled = true;
            });
            root.Children.Add(input);

            var progress = new TextBlock
            {
                Text = $"0 / {expected.Length} caracteres correctos",
                Foreground = BrushHex("#94A3B8"),
                FontSize = 12,
                Margin = new Thickness(0, 8, 0, 16)
            };
            root.Children.Add(progress);

            var confirmBtn = MakePrimaryButton("Desbloquear");
            confirmBtn.IsEnabled = false;
            var resetting = false;

            input.TextChanged += (_, _) =>
            {
                if (resetting) return;
                var prefix = UnlockChallenge.CorrectPrefix(input.Text, expected);
                if (prefix < input.Text.Length)
                {
                    resetting = true;
                    expected = UnlockChallenge.Make(len);
                    codeText.Text = expected;
                    input.Text = "";
                    resetting = false;
                    progress.Text = $"Carácter incorrecto · código nuevo generado (0 / {expected.Length})";
                    progress.Foreground = BrushHex("#F26D6D");
                    confirmBtn.IsEnabled = false;
                    return;
                }
                var ok = UnlockChallenge.Matches(input.Text, expected);
                progress.Text = $"{prefix} / {expected.Length} caracteres correctos";
                progress.Foreground = BrushHex(ok ? "#38A169" : "#F5B95F");
                confirmBtn.IsEnabled = ok;
            };
            input.KeyDown += (_, e) =>
            {
                if (e.Key == Key.Enter && confirmBtn.IsEnabled)
                {
                    unlocked = true;
                    win.Close();
                }
            };
            confirmBtn.Click += (_, _) => { unlocked = true; win.Close(); };

            var btns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
            var cancel = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0) };
            cancel.Click += (_, _) => win.Close();
            btns.Children.Add(cancel);
            btns.Children.Add(confirmBtn);
            root.Children.Add(btns);
            win.Loaded += (_, _) => input.Focus();
        }
        else
        {
            var waitSeconds = Math.Clamp(delayMinutes, 1, 120) * 60.0;
            var waitDeadline = new TrustedDeadline(waitSeconds);
            TrustedDeadline? confirmDeadline = null;

            root.Children.Add(new TextBlock
            {
                Text = "Mantén esta ventana abierta hasta completar el tiempo de espera:",
                Foreground = BrushHex("#94A3B8"),
                FontSize = 12.5,
                Margin = new Thickness(0, 0, 0, 10)
            });

            var label = new TextBlock
            {
                Text = $"Espera obligatoria: {FocusRules.Clock(waitSeconds)}",
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                FontSize = 22,
                FontWeight = FontWeights.Bold,
                Foreground = BrushHex("#F5B95F"),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 4, 0, 20)
            };
            root.Children.Add(label);

            var confirmBtn = MakePrimaryButton("Desbloquear");
            confirmBtn.IsEnabled = false;
            confirmBtn.Click += (_, _) => { unlocked = true; win.Close(); };

            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            timer.Tick += (_, _) =>
            {
                var left = waitDeadline.RemainingAfterPossibleReboot();
                if (left <= 0)
                {
                    confirmDeadline ??= new TrustedDeadline(120);
                    var confirmLeft = confirmDeadline.RemainingAfterPossibleReboot();
                    if (confirmLeft <= 0)
                    {
                        timer.Stop();
                        unlocked = false;
                        win.Close();
                        return;
                    }
                    label.Text = $"Espera completada · confirma en {FocusRules.Clock(confirmLeft)}";
                    label.Foreground = BrushHex("#38A169");
                    confirmBtn.IsEnabled = true;
                }
                else
                {
                    label.Text = $"Espera obligatoria: {FocusRules.Clock(left)}";
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

    /// <summary>
    /// Pausing or finishing early a protected session. «Hasta el final» refuses both (only the emergency exit, which
    /// ends the session, gets through); the code or the wait apply to the rest. Time-up is never protected.
    /// </summary>
    public static bool RequestSessionStop(string verb, WorkSession s, Window? owner)
    {
        if (s.Task.Protection == SessionProtection.None || s.Remaining(DateTimeOffset.Now) <= 0) return true;
        if (s.Task.Protection == SessionProtection.Forced)
        {
            Host?.Say($"«Hasta el final»: no se puede {verb} esta sesión. Le quedan {FocusRules.Clock(s.Remaining(DateTimeOffset.Now))}. Si de verdad pasa algo, usa «Salida de emergencia» (60 caracteres y queda anotada).");
            return false;
        }
        return RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"{verb} «{s.Task.Title}»", owner);
    }

    public static void ShowTaskEditor(AppEngine engine, FocusTask? existing, Window? owner)
    {
        var draft = existing?.Clone() ?? new FocusTask { ScheduledAt = DateTimeOffset.Now.AddMinutes(10) };
        var win = new Window
        {
            Title = existing == null ? "Nueva tarea · FocusDesk" : "Editar tarea · FocusDesk",
            Width = 680,
            Height = 760,
            MinWidth = 600,
            MinHeight = 600,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            Background = BrushHex("#0B0E14"),
            Foreground = BrushHex("#F2F5FA")
        };

        var shell = new Grid();
        AnimateModalIn(shell);
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Header
        var headerBorder = new Border
        {
            BorderBrush = BrushHex("#242E40"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(24, 18, 24, 14)
        };
        var headerStack = new StackPanel();
        headerStack.Children.Add(new TextBlock
        {
            Text = existing == null ? "Dale un espacio." : $"Editar «{existing.Title}»",
            FontSize = 21,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#F2F5FA")
        });
        headerStack.Children.Add(new TextBlock
        {
            Text = "Un objetivo claro, un tiempo concreto y reglas opcionales de bloqueo.",
            FontSize = 12,
            Foreground = BrushHex("#94A3B8"),
            Margin = new Thickness(0, 3, 0, 0)
        });
        headerBorder.Child = headerStack;
        Grid.SetRow(headerBorder, 0);
        shell.Children.Add(headerBorder);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new StackPanel { Margin = new Thickness(24, 18, 24, 18) };
        scroll.Content = root;
        Grid.SetRow(scroll, 1);
        shell.Children.Add(scroll);

        var inlineError = new Border
        {
            Background = BrushHex("#2A161B"),
            BorderBrush = BrushHex("#F26D6D"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 9, 12, 9),
            Margin = new Thickness(0, 0, 0, 14),
            Visibility = Visibility.Collapsed
        };
        var inlineErrorText = new TextBlock { Foreground = BrushHex("#F26D6D"), FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
        inlineError.Child = inlineErrorText;
        root.Children.Add(inlineError);

        if (existing != null && engine.IsTaskProtected(existing))
        {
            var protNote = new Border
            {
                Background = BrushHex("#251D10"),
                BorderBrush = BrushHex("#F5B95F"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 9, 12, 9),
                Margin = new Thickness(0, 0, 0, 14),
                Child = new TextBlock
                {
                    Text = "Esta tarea está protegida (en marcha o cerca de empezar). Alargarla o endurecerla es libre; retrasarla o suavizarla pedirá desbloqueo.",
                    Foreground = BrushHex("#F5B95F"),
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap
                }
            };
            root.Children.Add(protNote);
        }

        // Essential fields
        var titleBox = MakeTextBox(draft.Title);
        var categories = engine.Workspace.Settings.Categories.Select(c => c.Name).ToList();
        if (!categories.Contains(draft.Category)) categories.Add(draft.Category);
        var catCombo = MakeCombo(categories.Select(c => new ComboOption<string>(c, c)), draft.Category);

        var schedCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Reservar horario en agenda",
            IsChecked = draft.IsScheduled,
            Margin = new Thickness(0, 12, 0, 0)
        };
        var dateBox = MakeTextBox(draft.ScheduledAt.LocalDateTime.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
        var minBox = MakeTextBox(draft.Minutes.ToString(CultureInfo.InvariantCulture));

        var timeQuickWrap = new WrapPanel();
        timeQuickWrap.Children.Add(MakeChipButton("Ahora +10m", () =>
        {
            schedCheck.IsChecked = true;
            dateBox.Text = DateTime.Now.AddMinutes(10).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        }));
        timeQuickWrap.Children.Add(MakeChipButton("+1 hora", () =>
        {
            var baseDt = DateTime.TryParseExact(dateBox.Text.Trim(), "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed)
                ? parsed
                : DateTime.Now;
            dateBox.Text = baseDt.AddHours(1).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        }));

        var durQuickWrap = new WrapPanel();
        foreach (var m in new[] { 15, 30, 45, 60, 90 })
        {
            var captured = m;
            durQuickWrap.Children.Add(MakeChipButton($"{captured}m", () => minBox.Text = captured.ToString(CultureInfo.InvariantCulture)));
        }

        var dateFieldStack = new StackPanel();
        dateFieldStack.Children.Add(LabeledField("Inicio (aaaa-MM-dd HH:mm)", dateBox, 0));
        dateFieldStack.Children.Add(timeQuickWrap);

        var durFieldStack = new StackPanel();
        durFieldStack.Children.Add(LabeledField("Duración (minutos)", minBox, 0));
        durFieldStack.Children.Add(durQuickWrap);

        void SyncScheduleState()
        {
            dateFieldStack.Opacity = schedCheck.IsChecked == true ? 1.0 : 0.45;
            dateBox.IsEnabled = schedCheck.IsChecked == true;
        }
        schedCheck.Checked += (_, _) => SyncScheduleState();
        schedCheck.Unchecked += (_, _) => SyncScheduleState();
        SyncScheduleState();

        var essentialsBody = new StackPanel();
        essentialsBody.Children.Add(TwoColGrid(
            LabeledField("¿Qué vas a hacer?", titleBox, 0),
            LabeledField("Área", catCombo, 0),
            topMargin: 0,
            rightWidth: "185"));
        essentialsBody.Children.Add(schedCheck);
        essentialsBody.Children.Add(TwoColGrid(dateFieldStack, durFieldStack, topMargin: 10));

        // Repeat + Pomodoro options
        var repeatCombo = MakeCombo(Enum.GetValues<RepeatRule>().Select(r => new ComboOption<RepeatRule>(r, r.Label())), draft.RepeatRule);
        var pomoBox = MakeTextBox(draft.PomodoroWorkMinutes.ToString(CultureInfo.InvariantCulture));
        var autoStartCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Empezar sola automáticamente a su hora",
            IsChecked = draft.AutoStart,
            Margin = new Thickness(0, 12, 0, 0)
        };
        var fixedCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Cita fija (no desplazar automáticamente)",
            IsChecked = draft.IsFixedAppointment,
            Margin = new Thickness(0, 8, 0, 0)
        };
        var leadBox = MakeTextBox(draft.LeadMinutes.ToString(CultureInfo.InvariantCulture));
        var dueBox = MakeTextBox(draft.DueDate.HasValue ? draft.DueDate.Value.LocalDateTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : "");
        var folderBox = MakeTextBox(draft.Folder ?? "");
        var wholeWordCheck = new System.Windows.Controls.CheckBox { Content = "Exigir palabra completa en las palabras bloqueadas (admite * y /regex/)", IsChecked = draft.WholeWordKeywords, Margin = new Thickness(0, 8, 0, 0) };
        var guardPanesCheck = new System.Windows.Controls.CheckBox { Content = "Cerrar los paneles de Windows que acabarían con el bloqueo (Hora, Privacidad, Cuentas…)", IsChecked = draft.GuardSystemPanes, Margin = new Thickness(0, 8, 0, 0) };
        var punisherCheck = new System.Windows.Controls.CheckBox { Content = "Endurecer el bloqueo tras varios intentos seguidos", IsChecked = draft.PunisherEnabled, Margin = new Thickness(0, 8, 0, 0) };
        var similarityCombo = MakeCombo(Enum.GetValues<SimilarityProtectionLevel>().Select(l => new ComboOption<SimilarityProtectionLevel>(l, l.Label())), draft.SimilarityProtection);

        // «Días concretos» had no way to choose the days, so it could never be saved.
        var repeatDays = new HashSet<int>(draft.RepeatDays);
        var repeatDaysWrap = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var (dayNum, dayLabel) in new[] { (2, "Lun"), (3, "Mar"), (4, "Mié"), (5, "Jue"), (6, "Vie"), (7, "Sáb"), (1, "Dom") })
        {
            var dayBtn = new System.Windows.Controls.Button
            {
                Content = dayLabel,
                Padding = new Thickness(11, 5, 11, 5),
                MinHeight = 30,
                FontSize = 12,
                Margin = new Thickness(0, 4, 6, 0)
            };
            void RefreshRepeatDayStyle()
            {
                var on = repeatDays.Contains(dayNum);
                dayBtn.Background = BrushHex(on ? "#38A169" : "#1B2230");
                dayBtn.Foreground = BrushHex(on ? "#0B0E14" : "#E2E8F0");
                dayBtn.BorderBrush = BrushHex(on ? "#38A169" : "#2E3A4F");
                dayBtn.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
            }
            RefreshRepeatDayStyle();
            dayBtn.Click += (_, _) =>
            {
                if (!repeatDays.Add(dayNum)) repeatDays.Remove(dayNum);
                RefreshRepeatDayStyle();
            };
            repeatDaysWrap.Children.Add(dayBtn);
        }
        var repeatDaysPanel = new StackPanel();
        repeatDaysPanel.Children.Add(new TextBlock { Text = "DÍAS DE LA SEMANA", FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 12, 0, 0) });
        repeatDaysPanel.Children.Add(repeatDaysWrap);
        void SyncRepeatDays()
        {
            var custom = GetComboValue(repeatCombo, RepeatRule.Never) == RepeatRule.CustomDays;
            repeatDaysPanel.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
            if (custom && repeatDays.Count == 0)
            {
                // Start from the weekday of the chosen start so the first save works.
                var baseDay = DateTime.TryParseExact(dateBox.Text.Trim(), "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var startDt)
                    ? startDt
                    : draft.ScheduledAt.LocalDateTime;
                repeatDays.Add(((int)baseDay.DayOfWeek) + 1);
                foreach (var child in repeatDaysWrap.Children.OfType<System.Windows.Controls.Button>())
                {
                    var label = child.Content as string ?? "";
                    var num = label switch { "Lun" => 2, "Mar" => 3, "Mié" => 4, "Jue" => 5, "Vie" => 6, "Sáb" => 7, _ => 1 };
                    var on = repeatDays.Contains(num);
                    child.Background = BrushHex(on ? "#38A169" : "#1B2230");
                    child.Foreground = BrushHex(on ? "#0B0E14" : "#E2E8F0");
                    child.BorderBrush = BrushHex(on ? "#38A169" : "#2E3A4F");
                    child.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
                }
            }
        }
        repeatCombo.SelectionChanged += (_, _) => SyncRepeatDays();

        var optionsBody = new StackPanel();
        optionsBody.Children.Add(TwoColGrid(
            LabeledField("Repetición", repeatCombo, 0),
            LabeledField("Pomodoro · min foco (0 = continuo)", pomoBox, 0),
            topMargin: 0));
        optionsBody.Children.Add(repeatDaysPanel);
        SyncRepeatDays();
        optionsBody.Children.Add(TwoColGrid(
            LabeledField("Avisar antes (minutos, 0–60)", leadBox, 0),
            LabeledField("Fecha límite (aaaa-MM-dd; vacío = ninguna)", dueBox, 0),
            topMargin: 10));
        optionsBody.Children.Add(autoStartCheck);
        optionsBody.Children.Add(fixedCheck);

        // Blocking card
        var strictCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear aplicaciones durante la tarea", IsChecked = draft.Strict };
        var gameLibCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear lanzadores y bibliotecas de juegos (Steam, Epic, Riot…)", IsChecked = draft.BlockGameLibraries, Margin = new Thickness(0, 8, 0, 0) };
        var appModeCombo = MakeCombo(Enum.GetValues<AppListMode>().Select(m => new ComboOption<AppListMode>(m, m.Label())), draft.AppListMode);
        var appActionCombo = MakeCombo(Enum.GetValues<AppBlockAction>().Select(a => new ComboOption<AppBlockAction>(a, a.Label())), draft.BlockAction);
        var appsBox = MakeTextBox(string.Join(", ", draft.Apps.Select(a => a.Id)));

        var webModeCombo = MakeCombo(Enum.GetValues<WebListMode>().Select(m => new ComboOption<WebListMode>(m, m.Label())), draft.WebListMode);
        var webActionCombo = MakeCombo(Enum.GetValues<WebBlockAction>().Select(a => new ComboOption<WebBlockAction>(a, a.Label())), draft.WebBlockAction);
        var domainsBox = MakeTextBox(draft.Domains);
        var keywordsBox = MakeTextBox(draft.BlockedTitleKeywords);
        var searchMediaCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear pestañas de Imágenes y Vídeos en buscadores", IsChecked = draft.BlockSearchMedia, Margin = new Thickness(0, 10, 0, 0) };
        var foldersBox = MakeTextBox(string.Join(", ", draft.BlockedFolders));
        var motBox = MakeTextBox(draft.MotivationalMessage);
        var redirectBox = MakeTextBox(draft.CustomRedirectURL);

        var protCombo = MakeCombo(Enum.GetValues<SessionProtection>().Select(p => new ComboOption<SessionProtection>(p, p.Label())), draft.Protection);
        var protParamLabel = new TextBlock { FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 0, 0, 5) };
        var protParamBox = MakeTextBox();
        var protParamWrap = new StackPanel();
        protParamWrap.Children.Add(protParamLabel);
        protParamWrap.Children.Add(protParamBox);

        void SyncTaskProtParam(bool writeBackCurrent)
        {
            var prot = GetComboValue(protCombo, SessionProtection.None);
            if (prot == SessionProtection.Challenge)
            {
                protParamWrap.Visibility = Visibility.Visible;
                protParamLabel.Text = "LONGITUD DEL CÓDIGO (8–64)";
                if (!writeBackCurrent) protParamBox.Text = draft.UnlockChars.ToString(CultureInfo.InvariantCulture);
            }
            else if (prot == SessionProtection.Delay)
            {
                protParamWrap.Visibility = Visibility.Visible;
                protParamLabel.Text = "ESPERA OBLIGATORIA (min)";
                if (!writeBackCurrent) protParamBox.Text = draft.StopDelayMinutes.ToString(CultureInfo.InvariantCulture);
            }
            else
            {
                protParamWrap.Visibility = Visibility.Collapsed;
            }
        }
        SyncTaskProtParam(writeBackCurrent: false);
        protCombo.SelectionChanged += (_, _) => SyncTaskProtParam(writeBackCurrent: false);

        var blockingBody = new StackPanel();
        blockingBody.Children.Add(strictCheck);
        blockingBody.Children.Add(gameLibCheck);
        blockingBody.Children.Add(TwoColGrid(
            LabeledField("Modo lista de apps", appModeCombo, 0),
            LabeledField("Acción con apps", appActionCombo, 0),
            topMargin: 10));
        blockingBody.Children.Add(LabeledField("Apps (.exe separados por coma, ej. discord, spotify)", appsBox, 10));
        blockingBody.Children.Add(BuildRunningAppChips(appsBox, strictCheck));
        blockingBody.Children.Add(TwoColGrid(
            LabeledField("Modo lista web", webModeCombo, 0),
            LabeledField("Si abres web no permitida", webActionCombo, 0),
            topMargin: 12));
        blockingBody.Children.Add(new TextBlock { Text = "LOTES RÁPIDOS PARA BLOQUEAR", FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 12, 0, 2) });
        blockingBody.Children.Add(BuildPresetChips(domainsBox, keywordsBox, () =>
        {
            if (GetComboValue(webActionCombo, WebBlockAction.Warn) == WebBlockAction.Warn)
                webActionCombo.SelectedIndex = webActionCombo.Items.OfType<ComboOption<WebBlockAction>>().ToList().FindIndex(o => o.Value == WebBlockAction.Redirect);
        }));
        blockingBody.Children.Add(LabeledField("Webs, subrutas o comodines (ej. youtube.com/shorts, github.com)", domainsBox, 6));
        blockingBody.Children.Add(searchMediaCheck);
        blockingBody.Children.Add(LabeledField("Palabras en título de ventana (ej. Shorts, Reels)", keywordsBox, 10));
        blockingBody.Children.Add(wholeWordCheck);
        blockingBody.Children.Add(LabeledField("Carpetas bloqueadas del Explorador (rutas separadas por coma)", foldersBox, 10));
        blockingBody.Children.Add(TwoColGrid(
            LabeledField("Frase motivadora al bloquear (opcional)", motBox, 0),
            LabeledField("URL de redirección personalizada (opcional)", redirectBox, 0),
            topMargin: 10));
        blockingBody.Children.Add(LabeledField("Protección de similitud para las excepciones", similarityCombo, 10));
        blockingBody.Children.Add(guardPanesCheck);
        blockingBody.Children.Add(punisherCheck);
        blockingBody.Children.Add(TwoColGrid(
            LabeledField("Protección si intentas parar antes", protCombo, 0),
            protParamWrap,
            topMargin: 12));

        // Checklist card
        var checklistBox = MakeTextBox(draft.Checklist, multiline: true, height: 86);
        var pickFolderButton = new System.Windows.Controls.Button { Content = "Carpeta…", Margin = new Thickness(8, 0, 0, 0) };
        pickFolderButton.Click += (_, _) =>
        {
            using var folderDialog = new System.Windows.Forms.FolderBrowserDialog { Description = "Carpeta donde esperas ver el resultado de esta tarea" };
            if (folderDialog.ShowDialog() == System.Windows.Forms.DialogResult.OK) folderBox.Text = folderDialog.SelectedPath;
        };
        var folderRow = new DockPanel();
        DockPanel.SetDock(pickFolderButton, Dock.Right);
        folderRow.Children.Add(pickFolderButton);
        folderRow.Children.Add(folderBox);
        var resultBody = new StackPanel();
        resultBody.Children.Add(LabeledField("Checklist de pasos (uno por línea)", checklistBox, 0));
        resultBody.Children.Add(LabeledField("Carpeta del resultado (se miran los archivos que cambian durante la sesión)", folderRow, 12));

        // Quick Profile Strip (top card)
        if (engine.Workspace.Profiles.Count > 0)
        {
            var profileWrap = new WrapPanel();
            foreach (var prof in engine.Workspace.Profiles)
            {
                var captured = prof;
                profileWrap.Children.Add(MakeChipButton($"{captured.Name} ({captured.Minutes}m)", () =>
                {
                    if (string.IsNullOrWhiteSpace(titleBox.Text)) titleBox.Text = captured.Name;
                    catCombo.SelectedItem = catCombo.Items.OfType<ComboOption<string>>().FirstOrDefault(o => o.Value == captured.Category) ?? catCombo.SelectedItem;
                    minBox.Text = captured.Minutes.ToString(CultureInfo.InvariantCulture);
                    strictCheck.IsChecked = captured.Strict;
                    gameLibCheck.IsChecked = captured.BlockGameLibraries;
                    appsBox.Text = string.Join(", ", captured.Apps.Select(a => a.Id));
                    domainsBox.Text = captured.Domains;
                    keywordsBox.Text = captured.BlockedTitleKeywords;
                    checklistBox.Text = captured.Checklist;
                    searchMediaCheck.IsChecked = captured.BlockSearchMedia;
                    autoStartCheck.IsChecked = captured.AutoStart;
                    appModeCombo.SelectedIndex = appModeCombo.Items.OfType<ComboOption<AppListMode>>().ToList().FindIndex(o => o.Value == captured.AppListMode);
                    webModeCombo.SelectedIndex = webModeCombo.Items.OfType<ComboOption<WebListMode>>().ToList().FindIndex(o => o.Value == captured.WebListMode);
                    webActionCombo.SelectedIndex = webActionCombo.Items.OfType<ComboOption<WebBlockAction>>().ToList().FindIndex(o => o.Value == captured.WebBlockAction);
                    draft.UnlockChars = captured.UnlockChars;
                    draft.StopDelayMinutes = captured.StopDelayMinutes;
                    protCombo.SelectedIndex = protCombo.Items.OfType<ComboOption<SessionProtection>>().ToList().FindIndex(o => o.Value == captured.Protection);
                    draft.ProfileId = captured.Id;
                }));
            }
            root.Children.Add(BuildSectionCard("Perfiles rápidos", "Rellena la tarea con un clic según lo que vayas a hacer:", profileWrap));
        }

        root.Children.Add(BuildSectionCard("Lo esencial", null, essentialsBody));
        root.Children.Add(BuildSectionCard("Agenda y Pomodoro", null, optionsBody));
        root.Children.Add(BuildSectionCard("Bloqueo de distracciones y protección", null, blockingBody));
        root.Children.Add(BuildSectionCard("Resultado esperado", null, resultBody));

        // Footer Bar
        var footer = new Border
        {
            Background = BrushHex("#131822"),
            BorderBrush = BrushHex("#242E40"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(24, 14, 24, 14)
        };
        var footerDock = new DockPanel();
        var cancelBtn = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0) };
        cancelBtn.Click += (_, _) => win.Close();
        var saveBtn = MakePrimaryButton("Guardar tarea");

        var btnRight = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        btnRight.Children.Add(cancelBtn);
        btnRight.Children.Add(saveBtn);
        DockPanel.SetDock(btnRight, Dock.Right);
        footerDock.Children.Add(btnRight);
        footerDock.Children.Add(new TextBlock
        {
            Text = existing == null ? "Se añadirá a tu agenda de hoy." : "Los cambios se guardan al instante.",
            Foreground = BrushHex("#94A3B8"),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center
        });
        footer.Child = footerDock;
        Grid.SetRow(footer, 2);
        shell.Children.Add(footer);

        void ShowInlineError(string message)
        {
            inlineErrorText.Text = message;
            inlineError.Visibility = Visibility.Visible;
            scroll.ScrollToTop();
        }

        saveBtn.Click += (_, _) =>
        {
            inlineError.Visibility = Visibility.Collapsed;
            var title = titleBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(title))
            {
                ShowInlineError("Escribe un título para la tarea.");
                return;
            }
            if (schedCheck.IsChecked == true)
            {
                if (!DateTime.TryParseExact(dateBox.Text.Trim(), new[] { "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm", "dd/MM/yyyy HH:mm" }, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsedDt) &&
                    !DateTime.TryParse(dateBox.Text.Trim(), out parsedDt))
                {
                    ShowInlineError("Fecha y hora no válidas. Usa el formato aaaa-MM-dd HH:mm (ej. 2026-11-16 17:30).");
                    return;
                }
                // The offset that applies on the chosen DATE (daylight saving included), not today's.
                draft.ScheduledAt = FocusRules.FromLocal(parsedDt);
            }
            if (!int.TryParse(minBox.Text.Trim(), out var parsedMin) || parsedMin is < 1 or > 720)
            {
                ShowInlineError("La duración debe ser un número entre 1 y 720 minutos.");
                return;
            }

            draft.Title = title;
            draft.Category = GetComboValue(catCombo, "Personal");
            draft.IsScheduled = schedCheck.IsChecked == true;
            draft.Minutes = parsedMin;
            draft.RepeatRule = GetComboValue(repeatCombo, RepeatRule.Never);
            if (draft.RepeatRule == RepeatRule.CustomDays)
            {
                if (repeatDays.Count == 0)
                {
                    ShowInlineError("Elige al menos un día de la semana para la repetición «Días concretos».");
                    return;
                }
                draft.RepeatDays = new HashSet<int>(repeatDays);
            }
            draft.PomodoroWorkMinutes = int.TryParse(pomoBox.Text.Trim(), out var pm) ? Math.Clamp(pm, 0, 120) : 0;
            draft.AutoStart = autoStartCheck.IsChecked == true;
            draft.IsFixedAppointment = fixedCheck.IsChecked == true;
            draft.LeadMinutes = int.TryParse(leadBox.Text.Trim(), out var leadParsed) ? Math.Clamp(leadParsed, 0, 60) : draft.LeadMinutes;
            if (string.IsNullOrWhiteSpace(dueBox.Text))
            {
                draft.DueDate = null;
            }
            else if (DateTime.TryParseExact(dueBox.Text.Trim(), "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var dueParsed))
            {
                draft.DueDate = FocusRules.FromLocal(dueParsed.Date.AddHours(23).AddMinutes(59));
            }
            else
            {
                ShowInlineError("La fecha límite debe tener el formato aaaa-MM-dd (ej. 2026-12-01) o quedar vacía.");
                return;
            }
            draft.Folder = string.IsNullOrWhiteSpace(folderBox.Text) ? null : folderBox.Text.Trim();
            draft.WholeWordKeywords = wholeWordCheck.IsChecked == true;
            draft.GuardSystemPanes = guardPanesCheck.IsChecked == true;
            draft.PunisherEnabled = punisherCheck.IsChecked == true;
            draft.SimilarityProtection = GetComboValue(similarityCombo, SimilarityProtectionLevel.Off);

            draft.Strict = strictCheck.IsChecked == true;
            draft.BlockGameLibraries = gameLibCheck.IsChecked == true;
            draft.AppListMode = GetComboValue(appModeCombo, AppListMode.BlockListed);
            draft.BlockAction = GetComboValue(appActionCombo, AppBlockAction.Hide);
            draft.Apps = appsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(id => new AllowedApp(FocusRules.CleanAppId(id), id, ""))
                .Where(a => !string.IsNullOrEmpty(a.Id))
                .ToList();

            draft.WebListMode = GetComboValue(webModeCombo, WebListMode.BlockListed);
            draft.WebBlockAction = GetComboValue(webActionCombo, WebBlockAction.Warn);
            draft.Domains = domainsBox.Text;
            draft.BlockSearchMedia = searchMediaCheck.IsChecked == true;
            if ((FocusRules.ParseDomains(draft.Domains).Valid.Count > 0 || draft.BlockSearchMedia) && draft.WebBlockAction == WebBlockAction.Warn && existing == null)
                draft.WebBlockAction = WebBlockAction.Redirect;
            draft.BlockedTitleKeywords = keywordsBox.Text;
            draft.BlockedFolders = foldersBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            foreach (var f in draft.BlockedFolders)
            {
                if (FolderGuard.ProblemWithFolder(f) is string folderProb)
                {
                    ShowInlineError(folderProb);
                    return;
                }
            }
            draft.MotivationalMessage = motBox.Text.Trim();
            draft.CustomRedirectURL = redirectBox.Text.Trim();

            draft.Protection = GetComboValue(protCombo, SessionProtection.None);
            if (draft.Protection == SessionProtection.Challenge && int.TryParse(protParamBox.Text.Trim(), out var ch))
                draft.UnlockChars = UnlockChallenge.ClampedLength(ch);
            else if (draft.Protection == SessionProtection.Delay && int.TryParse(protParamBox.Text.Trim(), out var dl))
                draft.StopDelayMinutes = Math.Clamp(dl, 1, 120);

            draft.Checklist = checklistBox.Text;

            var redirectLoopMsg = FocusRules.IsRedirectDestinationBlocked(draft.CustomRedirectURL, draft.Domains, draft.WebListMode, draft.BlockSearchMedia);
            if (draft.WebBlockAction == WebBlockAction.Redirect && redirectLoopMsg != null)
            {
                ShowInlineError(redirectLoopMsg);
                return;
            }

            if (!draft.Valid)
            {
                ShowInlineError("Revisa los objetivos: si activas bloqueo de apps o webs debes indicar al menos un destino válido.");
                return;
            }

            var bypass = false;
            if (existing != null && engine.IsTaskProtected(existing))
            {
                var running = engine.Workspace.Session?.Task.Id == existing.Id;
                var reason = FocusRules.TaskLoosening(existing, draft, DateTimeOffset.Now, running);
                if (reason != null)
                {
                    if (!RequestUnlock(existing.Protection, existing.UnlockChars, existing.StopDelayMinutes, reason, win))
                        return;
                    if (existing.Protection == SessionProtection.Forced)
                        engine.Workspace.RecordAudit("Salida de emergencia", $"Modificada tarea «{existing.Title}» en modo Hasta el final.");
                    bypass = true;
                }
            }

            engine.SaveTask(draft, bypassProtection: bypass);
            if (string.IsNullOrEmpty(engine.Error)) win.Close();
            else ShowInlineError(engine.Error);
        };

        win.Content = shell;
        win.Loaded += (_, _) => titleBox.Focus();
        win.ShowDialog();
    }

    public static void ShowRuleEditor(AppEngine engine, GeneralBlockRule? existing, GeneralBlockRule? template, Window? owner)
    {
        var source = existing ?? template ?? new GeneralBlockRule();
        var draft = source.Clone();
        if (existing == null && template == null) draft.Id = Guid.NewGuid();
        var startImmediateOnSave = existing == null;

        var win = new Window
        {
            Title = existing == null ? "Nueva regla o temporizador · FocusDesk" : $"Editar regla · {existing.Name}",
            Width = 720,
            Height = 790,
            MinWidth = 620,
            MinHeight = 620,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            Owner = owner,
            Background = BrushHex("#0B0E14"),
            Foreground = BrushHex("#F2F5FA")
        };

        var shell = new Grid();
        AnimateModalIn(shell);
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var headerBorder = new Border
        {
            BorderBrush = BrushHex("#242E40"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(24, 18, 24, 14)
        };
        var headerStack = new StackPanel();
        headerStack.Children.Add(new TextBlock
        {
            Text = existing == null ? "Nueva regla de bloqueo" : "Editar regla de bloqueo",
            FontSize = 21,
            FontWeight = FontWeights.SemiBold,
            Foreground = BrushHex("#F2F5FA")
        });
        headerStack.Children.Add(new TextBlock
        {
            Text = "Funciona en segundo plano aunque no tengas una tarea iniciada en tu agenda.",
            FontSize = 12,
            Foreground = BrushHex("#94A3B8"),
            Margin = new Thickness(0, 3, 0, 0)
        });
        headerBorder.Child = headerStack;
        Grid.SetRow(headerBorder, 0);
        shell.Children.Add(headerBorder);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var root = new StackPanel { Margin = new Thickness(24, 18, 24, 18) };
        scroll.Content = root;
        Grid.SetRow(scroll, 1);
        shell.Children.Add(scroll);

        var inlineError = new Border
        {
            Background = BrushHex("#2A161B"),
            BorderBrush = BrushHex("#F26D6D"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 9, 12, 9),
            Margin = new Thickness(0, 0, 0, 14),
            Visibility = Visibility.Collapsed
        };
        var inlineErrorText = new TextBlock { Foreground = BrushHex("#F26D6D"), FontSize = 12.5, TextWrapping = TextWrapping.Wrap };
        inlineError.Child = inlineErrorText;
        root.Children.Add(inlineError);

        if (existing != null && engine.IsRuleProtected(existing))
        {
            root.Children.Add(new Border
            {
                Background = BrushHex("#12261A"),
                BorderBrush = BrushHex("#2A5A3F"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 9, 12, 9),
                Margin = new Thickness(0, 0, 0, 14),
                Child = new TextBlock
                {
                    Text = $"Regla activa y protegida («{existing.Protection.Label()}»). Endurecerla es inmediato; ablandarla pedirá desbloqueo al guardar.",
                    Foreground = BrushHex("#38A169"),
                    FontSize = 12,
                    TextWrapping = TextWrapping.Wrap
                }
            });
        }

        // Fields held at top level for clean save & state transitions
        var nameBox = MakeTextBox(draft.Name);
        var kindCombo = MakeCombo(Enum.GetValues<GeneralRuleKind>().Select(k => new ComboOption<GeneralRuleKind>(k, k.GalleryTitle())), draft.Kind);
        var kindSummary = new TextBlock { FontSize = 12, Foreground = BrushHex("#94A3B8"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };

        // Daily Limit controls
        var dailyLimitBox = MakeTextBox(draft.DailyLimitMinutes.ToString(CultureInfo.InvariantCulture));
        var dailyUnitCombo = MakeCombo(Enum.GetValues<LimitPeriodUnit>().Select(u => new ComboOption<LimitPeriodUnit>(u, u.Label())), draft.LimitPeriodUnit);
        var dailyChips = new WrapPanel();
        foreach (var m in new[] { 15, 20, 30, 45, 60, 90 })
        {
            var cap = m;
            dailyChips.Children.Add(MakeChipButton($"{cap}m", () => dailyLimitBox.Text = cap.ToString(CultureInfo.InvariantCulture)));
        }

        // WorkGoal & Game controls
        var gameOptions = new List<ComboOption<string?>> { new(null, "(Ninguno · meta normal de estudio/trabajo)") };
        gameOptions.AddRange(GameCatalog.All.Select(g => new ComboOption<string?>(g.Id, $"{g.Name} ({g.Detection.Label()})")));
        var gameCombo = MakeCombo(gameOptions, draft.GameId);
        var gameBanner = new Border
        {
            Background = BrushHex("#15241B"),
            BorderBrush = BrushHex("#244A36"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(12, 9, 12, 9),
            Margin = new Thickness(0, 10, 0, 0),
            Visibility = Visibility.Collapsed
        };
        var gameBannerText = new TextBlock { Foreground = BrushHex("#38A169"), FontSize = 12, TextWrapping = TextWrapping.Wrap };
        gameBanner.Child = gameBannerText;

        var goalMinBox = MakeTextBox(draft.GoalMinutesRequired.ToString(CultureInfo.InvariantCulture));
        var goalRewardBox = MakeTextBox(draft.GoalRewardMinutes.ToString(CultureInfo.InvariantCulture));
        var maxMatchesBox = MakeTextBox(draft.MaxDailyMatches.ToString(CultureInfo.InvariantCulture));
        var matchMinBox = MakeTextBox(draft.MatchMinutes.ToString(CultureInfo.InvariantCulture));
        var overtimeBox = MakeTextBox(draft.MatchOvertimeMinutes.ToString(CultureInfo.InvariantCulture));
        var postGraceBox = MakeTextBox(draft.PostMatchGraceSeconds.ToString(CultureInfo.InvariantCulture));
        var onePerGoalCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Bucle por partida (1 h → 1 partida → se bloquea; sin marcar = 1 h desbloquea todo y deja apagar)",
            IsChecked = draft.OneMatchPerGoalBlock,
            Margin = new Thickness(0, 10, 0, 0)
        };
        var verifyStudyCheck = new System.Windows.Controls.CheckBox
        {
            Content = "Contar estudio activo verificado (sin necesidad de pulsar «Empezar»)",
            IsChecked = draft.VerifyActiveStudy,
            Margin = new Thickness(0, 8, 0, 0)
        };
        var deferMatchCheck = new System.Windows.Controls.CheckBox
        {
            Content = "No sacar nunca a mitad de partida (esperar a que acabe)",
            IsChecked = draft.DeferBlockUntilMatchEnds,
            Margin = new Thickness(0, 8, 0, 0)
        };
        var matchTimingRow = TwoColGrid(
            LabeledField("Duración típica partida (min)", matchMinBox, 0),
            LabeledField("Prórroga para acabar (min)", overtimeBox, 0),
            topMargin: 10);
        var rewardOrGraceRow = TwoColGrid(
            LabeledField("Recompensa ocio (min · 0 = libre)", goalRewardBox, 0),
            LabeledField("Margen al acabar partida (s)", postGraceBox, 0),
            topMargin: 10);

        // Schedule controls
        var fromBox = MakeTextBox($"{draft.StartMinutes / 60:D2}:{draft.StartMinutes % 60:D2}");
        var toBox = MakeTextBox($"{draft.EndMinutes / 60:D2}:{draft.EndMinutes % 60:D2}");
        var selectedDays = new HashSet<int>(draft.ScheduleDays);
        var daysWrap = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var (dayNum, dayLabel) in new[] { (2, "Lun"), (3, "Mar"), (4, "Mié"), (5, "Jue"), (6, "Vie"), (7, "Sáb"), (1, "Dom") })
        {
            var btn = new System.Windows.Controls.Button
            {
                Content = dayLabel,
                Padding = new Thickness(11, 5, 11, 5),
                MinHeight = 30,
                FontSize = 12,
                Margin = new Thickness(0, 4, 6, 0)
            };
            void RefreshDayStyle()
            {
                var on = selectedDays.Contains(dayNum);
                btn.Background = BrushHex(on ? "#38A169" : "#1B2230");
                btn.Foreground = BrushHex(on ? "#0B0E14" : "#E2E8F0");
                btn.BorderBrush = BrushHex(on ? "#38A169" : "#2E3A4F");
                btn.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
            }
            RefreshDayStyle();
            btn.Click += (_, _) =>
            {
                if (selectedDays.Contains(dayNum) && selectedDays.Count > 1) selectedDays.Remove(dayNum);
                else selectedDays.Add(dayNum);
                RefreshDayStyle();
            };
            daysWrap.Children.Add(btn);
        }

        // LaunchLimit controls
        var maxLaunchesBox = MakeTextBox(draft.MaxDailyLaunches.ToString(CultureInfo.InvariantCulture));
        var launchDurBox = MakeTextBox(draft.MaxLaunchDurationMinutes.ToString(CultureInfo.InvariantCulture));
        var cooldownBox = MakeTextBox(draft.LaunchCooldownMinutes.ToString(CultureInfo.InvariantCulture));

        // Pomodoro controls
        var pWorkBox = MakeTextBox(draft.PomodoroWorkMinutes.ToString(CultureInfo.InvariantCulture));
        var pShortBox = MakeTextBox(draft.PomodoroShortBreakMinutes.ToString(CultureInfo.InvariantCulture));
        var pLongBox = MakeTextBox(draft.PomodoroLongBreakMinutes.ToString(CultureInfo.InvariantCulture));
        var pCyclesBox = MakeTextBox(draft.PomodoroTotalCycles.ToString(CultureInfo.InvariantCulture));
        var pPenaltyCheck = new System.Windows.Controls.CheckBox { Content = "Reiniciar el Pomodoro actual si intento abrir una distracción", IsChecked = draft.PomodoroPenaltyReset, Margin = new Thickness(0, 10, 0, 0) };
        var pProtectBreaksCheck = new System.Windows.Controls.CheckBox { Content = "Proteger también durante los descansos", IsChecked = draft.ProtectPomodoroBreaks, Margin = new Thickness(0, 8, 0, 0) };
        var pStartCheck = new System.Windows.Controls.CheckBox { Content = "Iniciar primer ciclo Pomodoro al guardar", IsChecked = startImmediateOnSave && draft.ActivePomodoroDeadline == null, Margin = new Thickness(0, 8, 0, 0) };

        // Countdown controls
        var countBox = MakeTextBox(draft.CountdownMinutes.ToString(CultureInfo.InvariantCulture));
        var countStartCheck = new System.Windows.Controls.CheckBox { Content = "Iniciar la cuenta atrás al guardar", IsChecked = startImmediateOnSave, Margin = new Thickness(0, 10, 0, 0) };
        var countChips = new WrapPanel();
        foreach (var m in new[] { 15, 30, 60, 90, 120, 180 })
        {
            var cap = m;
            countChips.Children.Add(MakeChipButton(cap >= 60 && cap % 60 == 0 ? $"{cap / 60}h" : $"{cap}m", () => countBox.Text = cap.ToString(CultureInfo.InvariantCulture)));
        }

        // Shared Targets
        var appsBox = MakeTextBox(string.Join(", ", draft.Apps.Select(a => a.Id)));
        var domainsBox = MakeTextBox(draft.Domains);
        var keywordsBox = MakeTextBox(draft.BlockedTitleKeywords);
        var wholeWordCheck = new System.Windows.Controls.CheckBox { Content = "Exigir palabra completa (evita falsos positivos; admite * y /regex/)", IsChecked = draft.WholeWordKeywords, Margin = new Thickness(0, 8, 0, 0) };
        var foldersBox = MakeTextBox(string.Join(", ", draft.BlockedFolders));
        var blockAppsCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear apps (.exe)", IsChecked = draft.BlockApps };
        var blockLibCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear lanzadores y bibliotecas de juegos (Steam, Epic, Riot…)", IsChecked = draft.BlockGameLibraries, Margin = new Thickness(0, 8, 0, 0) };
        var appModeCombo = MakeCombo(Enum.GetValues<AppListMode>().Select(m => new ComboOption<AppListMode>(m, m.Label())), draft.AppListMode);
        var appActionCombo = MakeCombo(Enum.GetValues<AppBlockAction>().Select(a => new ComboOption<AppBlockAction>(a, a.Label())), draft.BlockAction);
        var webModeCombo = MakeCombo(Enum.GetValues<WebListMode>().Select(m => new ComboOption<WebListMode>(m, m.Label())), draft.WebListMode);
        var webActionCombo = MakeCombo(Enum.GetValues<WebBlockAction>().Select(a => new ComboOption<WebBlockAction>(a, a.Label())), draft.WebBlockAction);
        var searchMediaCheck = new System.Windows.Controls.CheckBox { Content = "Bloquear pestañas de Imágenes y Vídeos en buscadores", IsChecked = draft.BlockSearchMedia, Margin = new Thickness(0, 8, 0, 0) };
        var motBox = MakeTextBox(draft.MotivationalMessage);
        var redirectBox = MakeTextBox(draft.CustomRedirectURL);

        // Protection controls
        var protCombo = MakeCombo(Enum.GetValues<SessionProtection>().Select(p => new ComboOption<SessionProtection>(p, p.Label())), draft.Protection);
        var protParamBox = MakeTextBox();
        var protParamLabel = new TextBlock { FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 0, 0, 5) };
        var protParamWrap = new StackPanel();
        protParamWrap.Children.Add(protParamLabel);
        protParamWrap.Children.Add(protParamBox);
        var microPausesBox = MakeTextBox(draft.DailyMicroPausesAllowed.ToString(CultureInfo.InvariantCulture));
        var alwaysProtCheck = new System.Windows.Controls.CheckBox { Content = "Regla obligatoria 24/7 (siempre pide código para editarla, apagarla o cerrar FocusDesk)", IsChecked = draft.AlwaysProtected, Margin = new Thickness(0, 12, 0, 0) };
        var ruleSimilarityCombo = MakeCombo(Enum.GetValues<SimilarityProtectionLevel>().Select(l => new ComboOption<SimilarityProtectionLevel>(l, l.Label())), draft.SimilarityProtection);
        var ruleGuardCheck = new System.Windows.Controls.CheckBox { Content = "Cerrar los paneles de Windows que acabarían con el bloqueo (Hora, Privacidad, Cuentas…)", IsChecked = draft.GuardSystemPanes, Margin = new Thickness(0, 10, 0, 0) };
        var rulePunisherCheck = new System.Windows.Controls.CheckBox { Content = "Endurecer el bloqueo tras varios intentos seguidos", IsChecked = draft.PunisherEnabled, Margin = new Thickness(0, 8, 0, 0) };
        var extraIntervalsBox = MakeTextBox(string.Join(", ", draft.ExtraScheduleIntervals.Select(i => $"{i.StartMinutes / 60:D2}:{i.StartMinutes % 60:D2}-{i.EndMinutes / 60:D2}:{i.EndMinutes % 60:D2}")));

        void SyncProtParam()
        {
            var prot = GetComboValue(protCombo, SessionProtection.Challenge);
            if (prot == SessionProtection.Challenge)
            {
                protParamWrap.Visibility = Visibility.Visible;
                protParamLabel.Text = "CARACTERES CÓDIGO (8–64)";
                protParamBox.Text = draft.UnlockChars.ToString(CultureInfo.InvariantCulture);
            }
            else if (prot == SessionProtection.Delay)
            {
                protParamWrap.Visibility = Visibility.Visible;
                protParamLabel.Text = "ESPERA (min)";
                protParamBox.Text = draft.StopDelayMinutes.ToString(CultureInfo.InvariantCulture);
            }
            else
            {
                protParamWrap.Visibility = Visibility.Collapsed;
            }
        }
        SyncProtParam();
        protCombo.SelectionChanged += (_, _) => SyncProtParam();

        // Dynamic Kind Panels (built once; switching mode toggles Visibility to avoid WPF logical-parent errors)
        var dailyPanel = new StackPanel();
        dailyPanel.Children.Add(TwoColGrid(
            LabeledField("Presupuesto (min)", dailyLimitBox, 0),
            LabeledField("Se reinicia", dailyUnitCombo, 0),
            topMargin: 0));
        dailyPanel.Children.Add(dailyChips);

        var workGoalPanel = new StackPanel();
        workGoalPanel.Children.Add(LabeledField("Juego (opcional · activa contador de partidas y detección exacta)", gameCombo, 0));
        workGoalPanel.Children.Add(gameBanner);
        workGoalPanel.Children.Add(TwoColGrid(
            LabeledField("Minutos de estudio requeridos", goalMinBox, 0),
            LabeledField("Máx. partidas al día (0 = libre)", maxMatchesBox, 0),
            topMargin: 10));
        workGoalPanel.Children.Add(matchTimingRow);
        workGoalPanel.Children.Add(rewardOrGraceRow);
        workGoalPanel.Children.Add(onePerGoalCheck);
        workGoalPanel.Children.Add(verifyStudyCheck);
        workGoalPanel.Children.Add(deferMatchCheck);

        var schedulePanel = new StackPanel();
        schedulePanel.Children.Add(TwoColGrid(
            LabeledField("Desde (HH:mm)", fromBox, 0),
            LabeledField("Hasta (HH:mm · admite tramo nocturno)", toBox, 0),
            topMargin: 0));
        schedulePanel.Children.Add(new TextBlock { Text = "DÍAS ACTIVOS", FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 12, 0, 2) });
        schedulePanel.Children.Add(daysWrap);
        schedulePanel.Children.Add(LabeledField("Tramos extra (HH:mm-HH:mm separados por coma, ej. 15:30-17:00)", extraIntervalsBox, 12));

        var launchPanel = new StackPanel();
        launchPanel.Children.Add(ThreeColGrid(
            LabeledField("Aperturas / día", maxLaunchesBox, 0),
            LabeledField("Minutos / visita", launchDurBox, 0),
            LabeledField("Enfriamiento (min)", cooldownBox, 0),
            topMargin: 0));

        var pomoPanel = new StackPanel();
        pomoPanel.Children.Add(TwoColGrid(
            LabeledField("Bloque trabajo (min)", pWorkBox, 0),
            LabeledField("Descanso corto (min)", pShortBox, 0),
            topMargin: 0));
        pomoPanel.Children.Add(TwoColGrid(
            LabeledField("Descanso largo (min)", pLongBox, 0),
            LabeledField("Ciclos en la tanda", pCyclesBox, 0),
            topMargin: 10));
        pomoPanel.Children.Add(pPenaltyCheck);
        pomoPanel.Children.Add(pProtectBreaksCheck);
        pomoPanel.Children.Add(pStartCheck);

        var countdownPanel = new StackPanel();
        countdownPanel.Children.Add(LabeledField("Duración de bloqueo inmediato (min)", countBox, 0));
        countdownPanel.Children.Add(countChips);
        countdownPanel.Children.Add(countStartCheck);

        var alwaysOnPanel = new StackPanel();
        alwaysOnPanel.Children.Add(new TextBlock
        {
            Text = "Permanece bloqueando 24 horas al día mientras el interruptor de esta regla esté encendido.",
            Foreground = BrushHex("#E2E8F0"),
            FontSize = 12.5,
            TextWrapping = TextWrapping.Wrap
        });

        var dynamicKindContent = new StackPanel();
        dynamicKindContent.Children.Add(dailyPanel);
        dynamicKindContent.Children.Add(workGoalPanel);
        dynamicKindContent.Children.Add(schedulePanel);
        dynamicKindContent.Children.Add(launchPanel);
        dynamicKindContent.Children.Add(pomoPanel);
        dynamicKindContent.Children.Add(countdownPanel);
        dynamicKindContent.Children.Add(alwaysOnPanel);

        var dynamicKindBox = new Border
        {
            Background = BrushHex("#151B26"),
            BorderBrush = BrushHex("#242E40"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(14),
            Margin = new Thickness(0, 12, 0, 0),
            Child = dynamicKindContent
        };

        void UpdateGameBanner()
        {
            var gid = GetComboValue<string?>(gameCombo, null);
            var g = GameCatalog.Find(gid);
            if (g == null)
            {
                gameBanner.Visibility = Visibility.Collapsed;
                matchTimingRow.Visibility = Visibility.Collapsed;
            }
            else
            {
                gameBanner.Visibility = Visibility.Visible;
                gameBannerText.Text = $"{g.Detection.Label()} · {g.Detection.Explanation()}";
                matchTimingRow.Visibility = g.Detection.IsExact() ? Visibility.Collapsed : Visibility.Visible;
            }
        }

        void RebuildKindBox()
        {
            var k = GetComboValue(kindCombo, GeneralRuleKind.DailyLimit);
            kindSummary.Text = k.Summary();
            dailyPanel.Visibility = k == GeneralRuleKind.DailyLimit ? Visibility.Visible : Visibility.Collapsed;
            workGoalPanel.Visibility = k == GeneralRuleKind.WorkGoal ? Visibility.Visible : Visibility.Collapsed;
            schedulePanel.Visibility = k == GeneralRuleKind.Schedule ? Visibility.Visible : Visibility.Collapsed;
            launchPanel.Visibility = k == GeneralRuleKind.LaunchLimit ? Visibility.Visible : Visibility.Collapsed;
            pomoPanel.Visibility = k == GeneralRuleKind.Pomodoro ? Visibility.Visible : Visibility.Collapsed;
            countdownPanel.Visibility = k == GeneralRuleKind.Countdown ? Visibility.Visible : Visibility.Collapsed;
            alwaysOnPanel.Visibility = k == GeneralRuleKind.AlwaysOn ? Visibility.Visible : Visibility.Collapsed;
            if (k == GeneralRuleKind.WorkGoal) UpdateGameBanner();
        }

        gameCombo.SelectionChanged += (_, _) =>
        {
            var gid = GetComboValue<string?>(gameCombo, null);
            if (!string.IsNullOrEmpty(gid) && GameCatalog.Find(gid) is { } g)
            {
                draft.ApplyGame(g);
                matchMinBox.Text = draft.MatchMinutes.ToString(CultureInfo.InvariantCulture);
                maxMatchesBox.Text = draft.MaxDailyMatches.ToString(CultureInfo.InvariantCulture);
                appsBox.Text = string.Join(", ", draft.Apps.Select(a => a.Id));
                blockAppsCheck.IsChecked = draft.BlockApps;
                if (!string.IsNullOrWhiteSpace(draft.Domains)) domainsBox.Text = draft.Domains;
            }
            else
            {
                draft.GameId = null;
            }
            UpdateGameBanner();
        };

        kindCombo.SelectionChanged += (_, _) => RebuildKindBox();
        RebuildKindBox();

        var identityBody = new StackPanel();
        identityBody.Children.Add(TwoColGrid(
            LabeledField("Nombre de la regla", nameBox, 0),
            LabeledField("Modo de activación", kindCombo, 0),
            topMargin: 0,
            rightWidth: "235"));
        identityBody.Children.Add(kindSummary);
        identityBody.Children.Add(dynamicKindBox);

        var targetsBody = new StackPanel();
        targetsBody.Children.Add(new TextBlock { Text = "LOTES RÁPIDOS PARA BLOQUEAR", FontSize = 10.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#94A3B8"), Margin = new Thickness(0, 0, 0, 2) });
        targetsBody.Children.Add(BuildPresetChips(domainsBox, keywordsBox));
        targetsBody.Children.Add(TwoColGrid(
            LabeledField("Modo lista web", webModeCombo, 0),
            LabeledField("Si abres web bloqueada", webActionCombo, 0),
            topMargin: 8));
        targetsBody.Children.Add(LabeledField("Webs, subrutas, comodines (*) o /regex/", domainsBox, 10));
        targetsBody.Children.Add(searchMediaCheck);
        targetsBody.Children.Add(LabeledField("Palabras en el título de cualquier ventana", keywordsBox, 10));
        targetsBody.Children.Add(wholeWordCheck);
        targetsBody.Children.Add(blockAppsCheck);
        targetsBody.Children.Add(blockLibCheck);
        targetsBody.Children.Add(TwoColGrid(
            LabeledField("Modo de apps", appModeCombo, 0),
            LabeledField("Acción al abrir app", appActionCombo, 0),
            topMargin: 10));
        targetsBody.Children.Add(LabeledField("Procesos / ejecutables (sin ruta completa, ej. LeagueClientUx, discord)", appsBox, 10));
        targetsBody.Children.Add(BuildRunningAppChips(appsBox, blockAppsCheck));
        targetsBody.Children.Add(LabeledField("Carpetas bloqueadas del Explorador (rutas separadas por coma)", foldersBox, 10));
        targetsBody.Children.Add(TwoColGrid(
            LabeledField("Mensaje motivador (página de bloqueo)", motBox, 0),
            LabeledField("URL de redirección personalizada (opcional)", redirectBox, 0),
            topMargin: 10));

        var protectionBody = new StackPanel();
        protectionBody.Children.Add(ThreeColGrid(
            LabeledField("Protección", protCombo, 0),
            protParamWrap,
            LabeledField("Micro-pausas al día", microPausesBox, 0),
            topMargin: 0));
        protectionBody.Children.Add(alwaysProtCheck);
        protectionBody.Children.Add(LabeledField("Protección de similitud para las excepciones", ruleSimilarityCombo, 12));
        protectionBody.Children.Add(ruleGuardCheck);
        protectionBody.Children.Add(rulePunisherCheck);

        root.Children.Add(BuildSectionCard("Nombre y temporizador", null, identityBody));
        root.Children.Add(BuildSectionCard("Qué bloquea esta regla", "Puedes combinar apps, juegos, webs, palabras en título de ventana y carpetas.", targetsBody));
        root.Children.Add(BuildSectionCard("Protección anti-trampas", null, protectionBody));

        var footer = new Border
        {
            Background = BrushHex("#131822"),
            BorderBrush = BrushHex("#242E40"),
            BorderThickness = new Thickness(0, 1, 0, 0),
            Padding = new Thickness(24, 14, 24, 14)
        };
        var footerDock = new DockPanel();
        var cancelBtn = new System.Windows.Controls.Button { Content = "Cancelar", Margin = new Thickness(0, 0, 10, 0) };
        cancelBtn.Click += (_, _) => win.Close();
        var saveBtn = MakePrimaryButton("Guardar regla");
        var btnRight = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        btnRight.Children.Add(cancelBtn);
        btnRight.Children.Add(saveBtn);
        DockPanel.SetDock(btnRight, Dock.Right);
        footerDock.Children.Add(btnRight);
        footerDock.Children.Add(new TextBlock
        {
            Text = existing == null ? "Se activará automáticamente según el modo elegido." : "Los cambios cumplen el trinquete anti-trampas.",
            Foreground = BrushHex("#94A3B8"),
            FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center
        });
        footer.Child = footerDock;
        Grid.SetRow(footer, 2);
        shell.Children.Add(footer);

        void ShowInlineError(string message)
        {
            inlineErrorText.Text = message;
            inlineError.Visibility = Visibility.Visible;
            scroll.ScrollToTop();
        }

        static bool TryParseHourMinute(string raw, out int minutes)
        {
            minutes = 0;
            var parts = raw.Trim().Split(':');
            if (parts.Length != 2 || !int.TryParse(parts[0], out var h) || !int.TryParse(parts[1], out var m))
                return false;
            if (h is < 0 or > 23 || m is < 0 or > 59) return false;
            minutes = h * 60 + m;
            return true;
        }

        saveBtn.Click += (_, _) =>
        {
            inlineError.Visibility = Visibility.Collapsed;
            var name = nameBox.Text.Trim();
            if (string.IsNullOrWhiteSpace(name))
            {
                ShowInlineError("Escribe un nombre descriptivo para la regla.");
                return;
            }

            draft.Name = name;
            draft.Kind = GetComboValue(kindCombo, GeneralRuleKind.DailyLimit);
            draft.DailyLimitMinutes = int.TryParse(dailyLimitBox.Text.Trim(), out var dl) ? Math.Clamp(dl, 1, 720) : draft.DailyLimitMinutes;
            draft.LimitPeriodUnit = GetComboValue(dailyUnitCombo, LimitPeriodUnit.Day);
            draft.GameId = GetComboValue<string?>(gameCombo, null);
            draft.GoalMinutesRequired = int.TryParse(goalMinBox.Text.Trim(), out var gm) ? Math.Clamp(gm, 5, 720) : draft.GoalMinutesRequired;
            draft.GoalRewardMinutes = int.TryParse(goalRewardBox.Text.Trim(), out var gr) ? Math.Clamp(gr, 0, 360) : draft.GoalRewardMinutes;
            draft.MaxDailyMatches = int.TryParse(maxMatchesBox.Text.Trim(), out var mm) ? Math.Clamp(mm, 0, 20) : draft.MaxDailyMatches;
            draft.MatchMinutes = int.TryParse(matchMinBox.Text.Trim(), out var tm) ? Math.Clamp(tm, 5, 180) : draft.MatchMinutes;
            draft.MatchOvertimeMinutes = int.TryParse(overtimeBox.Text.Trim(), out var om) ? Math.Clamp(om, 0, 30) : draft.MatchOvertimeMinutes;
            draft.PostMatchGraceSeconds = int.TryParse(postGraceBox.Text.Trim(), out var pg) ? Math.Clamp(pg, 15, 300) : draft.PostMatchGraceSeconds;
            draft.OneMatchPerGoalBlock = onePerGoalCheck.IsChecked == true;
            draft.VerifyActiveStudy = verifyStudyCheck.IsChecked == true;
            draft.DeferBlockUntilMatchEnds = deferMatchCheck.IsChecked == true;

            if (draft.Kind == GeneralRuleKind.Schedule)
            {
                if (!TryParseHourMinute(fromBox.Text, out var sm) || !TryParseHourMinute(toBox.Text, out var em) || sm == em)
                {
                    ShowInlineError("Horario no válido: usa formato HH:mm (por ejemplo 22:30 y 07:30) y asegúrate de que inicio y fin sean distintos.");
                    return;
                }
                draft.StartMinutes = sm;
                draft.EndMinutes = em;
                draft.ScheduleDays = new HashSet<int>(selectedDays);
            }

            draft.MaxDailyLaunches = int.TryParse(maxLaunchesBox.Text.Trim(), out var ml) ? Math.Clamp(ml, 1, 50) : draft.MaxDailyLaunches;
            draft.MaxLaunchDurationMinutes = int.TryParse(launchDurBox.Text.Trim(), out var ld) ? Math.Clamp(ld, 1, 120) : draft.MaxLaunchDurationMinutes;
            draft.LaunchCooldownMinutes = int.TryParse(cooldownBox.Text.Trim(), out var lc) ? Math.Clamp(lc, 0, 360) : draft.LaunchCooldownMinutes;

            draft.PomodoroWorkMinutes = int.TryParse(pWorkBox.Text.Trim(), out var pw) ? Math.Clamp(pw, 5, 180) : draft.PomodoroWorkMinutes;
            draft.PomodoroShortBreakMinutes = int.TryParse(pShortBox.Text.Trim(), out var ps) ? Math.Clamp(ps, 1, 60) : draft.PomodoroShortBreakMinutes;
            draft.PomodoroLongBreakMinutes = int.TryParse(pLongBox.Text.Trim(), out var pl) ? Math.Clamp(pl, 5, 90) : draft.PomodoroLongBreakMinutes;
            draft.PomodoroTotalCycles = int.TryParse(pCyclesBox.Text.Trim(), out var pc) ? Math.Clamp(pc, 1, 20) : draft.PomodoroTotalCycles;
            draft.PomodoroPenaltyReset = pPenaltyCheck.IsChecked == true;
            draft.ProtectPomodoroBreaks = pProtectBreaksCheck.IsChecked == true;

            draft.CountdownMinutes = int.TryParse(countBox.Text.Trim(), out var cm) ? Math.Clamp(cm, 5, 720) : draft.CountdownMinutes;

            draft.BlockApps = blockAppsCheck.IsChecked == true;
            draft.BlockGameLibraries = blockLibCheck.IsChecked == true;
            draft.AppListMode = GetComboValue(appModeCombo, AppListMode.BlockListed);
            draft.BlockAction = GetComboValue(appActionCombo, AppBlockAction.Hide);
            draft.Apps = appsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(id => new AllowedApp(FocusRules.CleanAppId(id), id, ""))
                .Where(a => !string.IsNullOrEmpty(a.Id))
                .ToList();
            if (draft.Apps.Count > 0 || draft.BlockGameLibraries) draft.BlockApps = true;

            draft.WebListMode = GetComboValue(webModeCombo, WebListMode.BlockListed);
            draft.WebBlockAction = GetComboValue(webActionCombo, WebBlockAction.Redirect);
            draft.Domains = domainsBox.Text;
            draft.BlockSearchMedia = searchMediaCheck.IsChecked == true;
            draft.BlockedTitleKeywords = keywordsBox.Text;
            draft.WholeWordKeywords = wholeWordCheck.IsChecked == true;
            draft.BlockedFolders = foldersBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
            foreach (var f in draft.BlockedFolders)
            {
                if (FolderGuard.ProblemWithFolder(f) is string folderProb)
                {
                    ShowInlineError(folderProb);
                    return;
                }
            }
            draft.MotivationalMessage = motBox.Text.Trim();
            draft.CustomRedirectURL = redirectBox.Text.Trim();

            var loopErr = FocusRules.IsRedirectDestinationBlocked(draft.CustomRedirectURL, draft.Domains, draft.WebListMode, draft.BlockSearchMedia);
            if (draft.WebBlockAction == WebBlockAction.Redirect && loopErr != null)
            {
                ShowInlineError(loopErr);
                return;
            }

            draft.Protection = GetComboValue(protCombo, SessionProtection.Challenge);
            if (draft.Protection == SessionProtection.Challenge && int.TryParse(protParamBox.Text.Trim(), out var ch))
                draft.UnlockChars = UnlockChallenge.ClampedLength(ch);
            else if (draft.Protection == SessionProtection.Delay && int.TryParse(protParamBox.Text.Trim(), out var dlp))
                draft.StopDelayMinutes = Math.Clamp(dlp, 1, 120);
            draft.DailyMicroPausesAllowed = int.TryParse(microPausesBox.Text.Trim(), out var mp) ? Math.Clamp(mp, 0, 10) : draft.DailyMicroPausesAllowed;
            draft.AlwaysProtected = alwaysProtCheck.IsChecked == true;
            draft.SimilarityProtection = GetComboValue(ruleSimilarityCombo, SimilarityProtectionLevel.Off);
            draft.GuardSystemPanes = ruleGuardCheck.IsChecked == true;
            draft.PunisherEnabled = rulePunisherCheck.IsChecked == true;
            if (draft.Kind == GeneralRuleKind.Schedule)
            {
                var extras = new List<ScheduleInterval>();
                foreach (var piece in extraIntervalsBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    var ends = piece.Split('-', StringSplitOptions.TrimEntries);
                    if (ends.Length != 2 || !TryParseHourMinute(ends[0], out var extraStart) || !TryParseHourMinute(ends[1], out var extraEnd) || extraStart == extraEnd)
                    {
                        ShowInlineError($"El tramo extra «{piece}» no es válido: usa HH:mm-HH:mm (por ejemplo 15:30-17:00).");
                        return;
                    }
                    extras.Add(new ScheduleInterval { StartMinutes = extraStart, EndMinutes = extraEnd });
                }
                draft.ExtraScheduleIntervals = extras;
            }

            if (draft.Kind == GeneralRuleKind.Countdown && countStartCheck.IsChecked == true &&
                (draft.ActiveDeadline == null || draft.ActiveDeadline.RemainingAfterPossibleReboot() <= 0 || (existing != null && draft.CountdownMinutes > existing.CountdownMinutes)))
            {
                draft.StartCountdown(draft.CountdownMinutes);
            }
            else if (draft.Kind == GeneralRuleKind.Pomodoro && pStartCheck.IsChecked == true &&
                     (draft.ActivePomodoroDeadline == null || draft.ActivePomodoroDeadline.RemainingAfterPossibleReboot() <= 0 || draft.PomodoroPhase == PomodoroPhase.Idle))
            {
                draft.StartPomodoro();
            }

            if (!draft.Valid)
            {
                ShowInlineError("La regla necesita al menos un objetivo a controlar (web, palabra, app, juego o carpeta).");
                return;
            }

            var bypass = false;
            if (existing != null && engine.IsRuleProtected(existing))
            {
                var reason = GeneralBlockRule.Loosening(existing, draft);
                if (reason != null)
                {
                    if (!RequestUnlock(existing.Protection, existing.UnlockChars, existing.StopDelayMinutes, reason, win))
                        return;
                    if (existing.Protection == SessionProtection.Forced)
                        engine.Workspace.RecordAudit("Salida de emergencia", $"Suavizada regla «{existing.Name}» en modo Hasta el final.");
                    bypass = true;
                }
            }

            engine.SaveGeneralRule(draft, bypassProtection: bypass);
            if (string.IsNullOrEmpty(engine.Error)) win.Close();
            else ShowInlineError(engine.Error);
        };

        win.Content = shell;
        win.Loaded += (_, _) => nameBox.Focus();
        win.ShowDialog();
    }
}
