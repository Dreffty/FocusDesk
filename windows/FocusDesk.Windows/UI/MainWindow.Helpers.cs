using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FocusDesk.Windows.Core;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.UI;

/// <summary>Small building blocks shared by the pages (buttons, number boxes, toggles, choices).</summary>
public partial class MainWindow
{
    // Live readouts of the extra pages (updated every second without rebuilding the page).
    private TextBlock? _liveScheduledBreakText;
    private TextBlock? _liveContinuousBreakText;
    private (BreakPeriod Period, double Remaining)? _shownScheduledBreak;

    private void ResetExtraLiveHandles()
    {
        _liveScheduledBreakText = null;
        _liveContinuousBreakText = null;
        _shownScheduledBreak = null;
    }

    private void UpdateExtraLiveReadouts(DateTimeOffset now)
    {
        if (_liveScheduledBreakText != null && _shownScheduledBreak is { } shown)
        {
            var remaining = Math.Max(0, shown.Period.RemainingSeconds(now));
            _liveScheduledBreakText.Text = $"{shown.Period.Title} · quedan {FocusRules.Clock(remaining)}";
        }
        if (_liveContinuousBreakText != null && _engine.ActiveContinuousBreakDeadline != null)
        {
            var left = _engine.ActiveContinuousBreakDeadline.RemainingAfterPossibleReboot(now);
            _liveContinuousBreakText.Text = $"Descanso de vista · {FocusRules.Clock(left)} · {_engine.ActiveContinuousBreakMessage}";
        }
    }

    private static System.Windows.Controls.Button SmallButton(string text, Action onClick, bool enabled = true, double rightMargin = 6)
    {
        var button = new System.Windows.Controls.Button
        {
            Content = text,
            Margin = new Thickness(0, 0, rightMargin, 0),
            IsEnabled = enabled
        };
        button.Click += (_, _) => onClick();
        return button;
    }

    private static TextBlock SectionLabel(string text, double top = 14, string color = "#94A3B8") => new()
    {
        Text = text,
        FontSize = 11,
        FontWeight = FontWeights.SemiBold,
        Foreground = BrushHex(color),
        Margin = new Thickness(0, top, 0, 8)
    };

    private static TextBlock MutedText(string text, double size = 12, double top = 4) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = BrushHex("#94A3B8"),
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, top, 0, 0)
    };

    private static StackPanel Row(params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    private static WrapPanel WrapRow(params UIElement[] children)
    {
        var panel = new WrapPanel { Margin = new Thickness(0, 6, 0, 0) };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    /// <summary>A label with a control under it, as in the editors.</summary>
    private static StackPanel Labeled(string label, UIElement control, double top = 10)
    {
        var panel = new StackPanel { Margin = new Thickness(0, top, 14, 0), VerticalAlignment = VerticalAlignment.Top };
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

    /// <summary>A whole-number box: the value is applied when it loses focus or Enter is pressed, clamped to its range.</summary>
    private static System.Windows.Controls.TextBox NumberBox(int value, int min, int max, Action<int> onChange, double width = 70)
    {
        var box = new System.Windows.Controls.TextBox { Text = value.ToString(CultureInfo.InvariantCulture), Width = width };
        void Apply()
        {
            if (!int.TryParse(box.Text.Trim(), out var parsed)) parsed = value;
            parsed = Math.Clamp(parsed, min, max);
            box.Text = parsed.ToString(CultureInfo.InvariantCulture);
            if (parsed != value)
            {
                value = parsed;
                onChange(parsed);
            }
        }
        box.LostFocus += (_, _) => Apply();
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter) Apply();
        };
        return box;
    }

    private static System.Windows.Controls.CheckBox ToggleBox(string text, bool on, Action<bool> onChange, double top = 8)
    {
        var box = new System.Windows.Controls.CheckBox { Content = text, IsChecked = on, Margin = new Thickness(0, top, 0, 0) };
        box.Click += (_, _) => onChange(box.IsChecked == true);
        return box;
    }

    private static System.Windows.Controls.ComboBox ChoiceBox<T>(IEnumerable<ComboOption<T>> options, T selected, Action<T> onChange, double width = 220)
    {
        var list = options.ToList();
        // Left-aligned under its label: with a fixed width it used to float in the middle of the row.
        var box = new System.Windows.Controls.ComboBox { ItemsSource = list, Width = width, HorizontalAlignment = System.Windows.HorizontalAlignment.Left };
        var index = list.FindIndex(o => EqualityComparer<T>.Default.Equals(o.Value, selected));
        box.SelectedIndex = index >= 0 ? index : 0;
        box.SelectionChanged += (_, _) =>
        {
            if (box.SelectedItem is ComboOption<T> chosen) onChange(chosen.Value);
        };
        return box;
    }

    /// <summary>Changes one setting and saves.</summary>
    private void ChangeSetting(Action<Settings> mutate)
    {
        mutate(_engine.Workspace.Settings);
        _engine.Persist();
    }

    /// <summary>
    /// Runs a change to a task. When the task is protected (running, or close to starting) it asks for the code or wait
    /// first, exactly as the buttons that edit or delete it do.
    /// </summary>
    private void ApplyTaskChange(FocusTask task, string actionLabel, Action<bool> apply)
    {
        var bypass = false;
        if (_engine.IsTaskProtected(task))
        {
            if (!Dialogs.RequestUnlock(task.Protection, task.UnlockChars, task.StopDelayMinutes, actionLabel, this)) return;
            if (task.Protection == SessionProtection.Forced)
                _engine.Workspace.RecordAudit("Salida de emergencia", $"{actionLabel} (tarea protegida «{task.Title}»).");
            bypass = true;
        }
        apply(bypass);
    }

    /// <summary>The same for a rule that is protected right now.</summary>
    private bool UnlockRuleFor(GeneralBlockRule rule, string actionLabel)
    {
        if (!_engine.IsRuleProtected(rule)) return true;
        if (!Dialogs.RequestUnlock(rule.Protection, rule.UnlockChars, rule.StopDelayMinutes, actionLabel, this)) return false;
        if (rule.Protection == SessionProtection.Forced)
            _engine.Workspace.RecordAudit("Salida de emergencia", $"{actionLabel} (regla protegida «{rule.Name}»).");
        return true;
    }

    /// <summary>One line that says what a rule is doing right now.</summary>
    private string RuleInfoLine(GeneralBlockRule rule)
    {
        var now = DateTimeOffset.Now;
        var cont = TrustedClock.ContinuousSeconds();
        switch (rule.Kind)
        {
            case GeneralRuleKind.DailyLimit:
            {
                var used = _engine.Workspace.UsedSecondsToday(rule.Id, rule.LimitPeriodUnit, now);
                return $"Usado {FocusRules.Clock(used)} de {rule.DailyLimitMinutes} min · {rule.LimitPeriodUnit.Label().ToLowerInvariant()}";
            }
            case GeneralRuleKind.Schedule:
            {
                var days = string.Join(" ", new[] { (2, "L"), (3, "M"), (4, "X"), (5, "J"), (6, "V"), (7, "S"), (1, "D") }
                    .Where(d => rule.ScheduleDays.Contains(d.Item1)).Select(d => d.Item2));
                var windows = string.Join(", ", rule.AllScheduleIntervals().Select(i => i.Label));
                return $"{windows} · {days}";
            }
            case GeneralRuleKind.WorkGoal:
            {
                var worked = _engine.EffectiveWorkedSeconds(rule, now);
                return rule.MaxDailyMatches > 0
                    ? _engine.GameRuleStatus(rule, now).Text
                    : $"Estudio {FocusRules.Clock(worked)} de {rule.GoalMinutesRequired} min";
            }
            case GeneralRuleKind.LaunchLimit:
            {
                var launches = _engine.Workspace.LaunchesToday(rule.Id, now);
                var line = $"{launches}/{rule.MaxDailyLaunches} visitas hoy de {rule.MaxLaunchDurationMinutes} min";
                if (rule.IsInLaunchVisit(now, cont)) line += $" · visita en curso: {FocusRules.Clock(rule.LaunchVisitRemainingSeconds(now, cont))}";
                else if (rule.IsInLaunchCooldown(now, cont)) line += $" · enfriamiento: {FocusRules.Clock(rule.LaunchCooldownRemainingSeconds(now, cont))}";
                return line;
            }
            case GeneralRuleKind.Pomodoro:
            {
                if (rule.PomodoroPhase == PomodoroPhase.Idle) return $"Pomodoro {rule.PomodoroWorkMinutes}/{rule.PomodoroShortBreakMinutes} · {rule.PomodoroTotalCycles} ciclos";
                var left = rule.ActivePomodoroDeadline?.RemainingAfterPossibleReboot(now, cont) ?? 0;
                return $"{AppEngine.PomodoroPhaseLabel(rule.PomodoroPhase)} · ciclo {rule.PomodoroCurrentCycle}/{rule.PomodoroTotalCycles}" +
                       (left > 0 ? $" · {FocusRules.Clock(left)}" : "");
            }
            case GeneralRuleKind.Countdown:
            {
                var left = rule.ActiveDeadline?.RemainingAfterPossibleReboot(now, cont) ?? 0;
                return left > 0 ? $"Bloqueando · quedan {FocusRules.Clock(left)}" : $"Cuenta atrás de {FocusRules.DurationText(rule.CountdownMinutes)} sin empezar";
            }
            default:
                return "Siempre activo mientras esté encendida";
        }
    }
}
