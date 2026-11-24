using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace FocusDesk.Windows.Core;

/// <summary>
/// What macOS does in AppModel and Windows still lacked after the first ports: importing rules, moving and resizing a
/// task from the agenda, editing one occurrence of a series, saving a task as a profile and deleting a category.
/// </summary>
public sealed partial class AppEngine
{
    // MARK: - The next task

    /// <summary>The task FocusDesk would start next (macOS: `model.next`). Null with nothing pending.</summary>
    public FocusTask? NextTask(DateTimeOffset? at = null) =>
        FocusRules.NextSuggestedTask(Workspace.Tasks, Workspace.Session?.Task.Id, at ?? DateTimeOffset.Now);

    // MARK: - Moving and resizing from the agenda

    /// <summary>Puts a task at a given local date and time (dragging it to another day or hour).</summary>
    public void MoveTaskTo(FocusTask task, DateTime localStart, bool bypassProtection = false)
    {
        var updated = task.Clone();
        updated.IsScheduled = true;
        updated.ScheduledAt = FocusRules.FromLocal(localStart);
        SaveTask(updated, bypassProtection);
        if (string.IsNullOrEmpty(Error))
            Notice = $"«{updated.Title}» pasa al {updated.ScheduledAt.LocalDateTime:d MMM} a las {updated.ScheduledAt.LocalDateTime:HH:mm}.";
    }

    /// <summary>Moves a task earlier or later by some minutes («Adelantar 15 minutos», «Retrasar 15 minutos»).</summary>
    public void ShiftTask(FocusTask task, int minutes, bool bypassProtection = false)
    {
        if (!task.IsScheduled || minutes == 0) return;
        MoveTaskTo(task, task.ScheduledAt.LocalDateTime.AddMinutes(minutes), bypassProtection);
    }

    /// <summary>Makes a task longer or shorter («Alargar 15 minutos», «Acortar 15 minutos»), from 5 min to 12 h.</summary>
    public void ResizeTask(FocusTask task, int deltaMinutes, bool bypassProtection = false)
    {
        var minutes = Math.Clamp(task.Minutes + deltaMinutes, 5, 720);
        if (minutes == task.Minutes) return;
        var updated = task.Clone();
        updated.Minutes = minutes;
        SaveTask(updated, bypassProtection);
        if (string.IsNullOrEmpty(Error)) Notice = $"«{updated.Title}» dura ahora {FocusRules.DurationText(minutes)}.";
    }

    // MARK: - One occurrence of a series

    /// <summary>
    /// Saves `edited` as a task of its own for one day of a recurring series and leaves the rest of the series as it
    /// was (macOS: `saveTask(_:detachFromSeriesID:occurrenceDate:)`). The series skips that day; when the day is the
    /// one the series is standing on, the series moves on to its next date.
    /// </summary>
    public void SaveOccurrenceOnly(FocusTask series, FocusTask edited, DateTimeOffset occurrenceDate, bool bypassProtection = false)
    {
        var index = Workspace.Tasks.FindIndex(t => t.Id == series.Id);
        if (index < 0) { SaveTask(edited, bypassProtection); return; }
        edited.Title = edited.Title.Trim();
        edited.Domains = FocusRules.NormalizeDomains(edited.Domains);
        edited.BlockedTitleKeywords = FocusRules.NormalizeTitleKeywords(edited.BlockedTitleKeywords);
        if (!edited.Valid) { Error = "La tarea necesita título y configuración válida."; return; }

        var now = DateTimeOffset.Now;
        var head = Workspace.Tasks[index];
        if (!bypassProtection && IsTaskProtected(head, now))
        {
            var reason = FocusRules.TaskLoosening(head, edited, now, Workspace.Session?.Task.Id == head.Id);
            if (reason != null) { Error = $"Protegida: no se puede {reason} sin desbloquear."; return; }
        }

        RememberUndo();
        var updatedSeries = head.Clone();
        updatedSeries.SkippedDates.Add(FocusRules.DayKey(occurrenceDate));
        if (occurrenceDate.LocalDateTime.Date == head.ScheduledAt.LocalDateTime.Date &&
            updatedSeries.NextOccurrence(head.ScheduledAt, Workspace.Settings.Workdays) is { } advanced)
        {
            updatedSeries.ScheduledAt = advanced.ScheduledAt;
            updatedSeries.DueDate = advanced.DueDate;
        }
        Workspace.Tasks[index] = updatedSeries;

        var single = edited.Clone();
        single.Id = Guid.NewGuid();
        single.RepeatRule = RepeatRule.Never;
        single.RepeatDays = new HashSet<int>();
        single.SkippedDates = new HashSet<string>();
        single.SeriesId = head.SeriesId ?? head.Id;
        single.Completed = false;
        Workspace.Tasks.Add(single);

        Error = "";
        Persist();
        Notice = $"Solo cambia «{single.Title}» del {single.ScheduledAt.LocalDateTime:d MMM}. El resto de la serie sigue igual.";
    }

    // MARK: - Profiles and categories

    /// <summary>«Guardar como perfil»: the blocking set-up of a task, kept to reuse it in one click.</summary>
    public void SaveProfileFromTask(FocusTask task, string name)
    {
        var clean = (name ?? "").Trim();
        if (clean.Length == 0) { Error = "Escribe un nombre para el perfil."; return; }
        var profile = Workspace.Profiles.FirstOrDefault(p => string.Equals(p.Name, clean, StringComparison.OrdinalIgnoreCase)) ?? new FocusProfile();
        profile.Name = clean;
        profile.Category = task.Category;
        profile.Minutes = task.Minutes;
        profile.LeadMinutes = task.LeadMinutes;
        profile.Strict = task.Strict;
        profile.Apps = task.Apps.ToList();
        profile.Domains = FocusRules.NormalizeDomains(task.Domains);
        profile.Folder = task.Folder;
        profile.Checklist = task.Checklist;
        profile.AutoStart = task.AutoStart;
        profile.Protection = task.Protection;
        profile.UnlockChars = task.UnlockChars;
        profile.StopDelayMinutes = task.StopDelayMinutes;
        profile.BlockAction = task.BlockAction;
        profile.WebBlockAction = task.WebBlockAction;
        profile.GuardSystemPanes = task.GuardSystemPanes;
        profile.PunisherEnabled = task.PunisherEnabled;
        profile.BlockedFolders = task.BlockedFolders.ToList();
        profile.AppListMode = task.AppListMode;
        profile.WebListMode = task.WebListMode;
        profile.BlockedTitleKeywords = FocusRules.NormalizeTitleKeywords(task.BlockedTitleKeywords);
        profile.WholeWordKeywords = task.WholeWordKeywords;
        profile.CustomRedirectURL = task.CustomRedirectURL;
        profile.MotivationalMessage = task.MotivationalMessage;
        profile.BlockSearchMedia = task.BlockSearchMedia;
        profile.BlockGameLibraries = task.BlockGameLibraries;
        profile.SimilarityProtection = task.SimilarityProtection;
        SaveProfile(profile);
        Error = "";
        Notice = $"Perfil «{clean}» guardado. Lo tienes en Ajustes › Perfiles y al crear una tarea.";
    }

    /// <summary>Deletes an area. Tasks that used it keep their name and are drawn in grey until you pick another.</summary>
    public void DeleteCategory(string name)
    {
        if (Workspace.Settings.Categories.Count <= 1)
        {
            Error = "Tiene que quedar al menos una categoría.";
            return;
        }
        var removed = Workspace.Settings.Categories.RemoveAll(c => string.Equals(c.Name, name, StringComparison.OrdinalIgnoreCase));
        if (removed == 0) return;
        Error = "";
        Persist();
        Notice = $"Categoría «{name}» borrada. Las tareas que la usaban conservan su nombre.";
    }

    // MARK: - Importing rules

    /// <summary>
    /// Adds the rules of a JSON file exported from FocusDesk (Mac or Windows). A rule that already exists is replaced,
    /// unless it is protected right now and the file would loosen it (macOS: `importGeneralRules`).
    /// </summary>
    public void ImportRules(string filePath)
    {
        List<GeneralBlockRule>? imported;
        try
        {
            imported = JsonSerializer.Deserialize<List<GeneralBlockRule>>(File.ReadAllBytes(filePath), WorkspaceStore.JsonOptions);
        }
        catch (Exception ex)
        {
            Error = $"No se pudo leer el archivo de reglas: {ex.Message}";
            return;
        }
        var valid = (imported ?? new List<GeneralBlockRule>()).Where(r => r != null && r.Valid).ToList();
        if (valid.Count == 0)
        {
            Error = "El archivo no contiene reglas generales válidas.";
            return;
        }
        int added = 0, updated = 0, kept = 0;
        var now = DateTimeOffset.Now;
        foreach (var item in valid)
        {
            item.StopRequest = null;
            var index = Workspace.GeneralRules.FindIndex(r => r.Id == item.Id);
            if (index >= 0)
            {
                var current = Workspace.GeneralRules[index];
                if (IsRuleProtected(current, now) && current.Protection != SessionProtection.None &&
                    GeneralBlockRule.Loosening(current, item, now) != null)
                {
                    kept++;
                    continue;
                }
                Workspace.GeneralRules[index] = item;
                updated++;
            }
            else
            {
                Workspace.GeneralRules.Add(item);
                added++;
            }
        }
        Workspace.RecordAudit("Importación de reglas", $"{Path.GetFileName(filePath)} · {added} nuevas, {updated} actualizadas", now);
        Error = "";
        Persist();
        RefreshWitness();
        EnsureWatcherIfNeeded();
        Notice = $"Reglas importadas: {added} nuevas y {updated} actualizadas." +
                 (kept > 0 ? $" {kept} protegida{(kept == 1 ? "" : "s")} no se ha{(kept == 1 ? "" : "n")} tocado." : "");
    }
}
