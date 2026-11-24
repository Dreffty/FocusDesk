using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace FocusDesk.Windows.Core;

public record AllowedApp(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("path")] string Path
);

public enum RepeatRule
{
    Never,
    Daily,
    Weekly,
    Weekdays,
    CustomDays
}

public static class RepeatRuleExtensions
{
    public static string Label(this RepeatRule rule) => rule switch
    {
        RepeatRule.Never => "No repetir",
        RepeatRule.Daily => "Cada día",
        RepeatRule.Weekly => "Cada semana",
        RepeatRule.Weekdays => "Días laborables",
        RepeatRule.CustomDays => "Días concretos",
        _ => "No repetir"
    };
}

public enum SessionProtection
{
    None,
    Delay,
    Challenge,
    Forced
}

public static class SessionProtectionExtensions
{
    public static int Strength(this SessionProtection p) => p switch
    {
        SessionProtection.None => 0,
        SessionProtection.Challenge => 1,
        SessionProtection.Delay => 2,
        SessionProtection.Forced => 3,
        _ => 0
    };

    public static string Label(this SessionProtection p) => p switch
    {
        SessionProtection.None => "Sin protección",
        SessionProtection.Delay => "Espera",
        SessionProtection.Challenge => "Código de desbloqueo",
        SessionProtection.Forced => "Hasta el final",
        _ => "Sin protección"
    };

    public static string Explanation(this SessionProtection p) => p switch
    {
        SessionProtection.None => "Puedes pausar, editar o parar en cualquier momento.",
        SessionProtection.Delay => "Pide esperar unos minutos antes de detener o suavizar el bloqueo.",
        SessionProtection.Challenge => "Pide escribir un código aleatorio sin copiar y pegar para detener o suavizar el bloqueo.",
        SessionProtection.Forced => "Sin salida anticipada: solo permite código de emergencia de 60 caracteres y queda registrado.",
        _ => ""
    };

    public static string WayOut(this SessionProtection p) => p switch
    {
        SessionProtection.None => "",
        SessionProtection.Delay => "Para salir antes, inicia la espera en la regla o sesión.",
        SessionProtection.Challenge => "Para salir antes, escribe el código de desbloqueo.",
        SessionProtection.Forced => "Para salir antes, teclea el código de emergencia de 60 caracteres (queda anotado).",
        _ => ""
    };
}

public enum AppBlockAction
{
    Hide,
    Close,
    ForceQuit
}

public static class AppBlockActionExtensions
{
    public static int Strength(this AppBlockAction a) => a switch
    {
        AppBlockAction.Hide => 0,
        AppBlockAction.Close => 1,
        AppBlockAction.ForceQuit => 2,
        _ => 0
    };

    public static AppBlockAction Escalated(this AppBlockAction a) => a switch
    {
        AppBlockAction.Hide => AppBlockAction.Close,
        AppBlockAction.Close => AppBlockAction.ForceQuit,
        AppBlockAction.ForceQuit => AppBlockAction.ForceQuit,
        _ => AppBlockAction.Close
    };

    public static string Label(this AppBlockAction a) => a switch
    {
        AppBlockAction.Hide => "Minimizar",
        AppBlockAction.Close => "Cerrar ventana",
        AppBlockAction.ForceQuit => "Forzar cierre",
        _ => "Minimizar"
    };
}

public enum WebBlockAction
{
    Warn,
    Redirect,
    CloseTab
}

public static class WebBlockActionExtensions
{
    public static int Strength(this WebBlockAction a) => a switch
    {
        WebBlockAction.Warn => 0,
        WebBlockAction.Redirect => 1,
        WebBlockAction.CloseTab => 2,
        _ => 0
    };

    public static string Label(this WebBlockAction a) => a switch
    {
        WebBlockAction.Warn => "Solo avisar",
        WebBlockAction.Redirect => "Redirigir a página de bloqueo",
        WebBlockAction.CloseTab => "Cerrar pestaña",
        _ => "Redirigir a página de bloqueo"
    };
}

public enum AppListMode
{
    AllowListed,
    BlockListed
}

public static class AppListModeExtensions
{
    public static string Label(this AppListMode m) => m switch
    {
        AppListMode.AllowListed => "Permitir solo las apps de la lista",
        AppListMode.BlockListed => "Bloquear las apps de la lista",
        _ => "Bloquear las apps de la lista"
    };
}

public enum WebListMode
{
    AllowListed,
    BlockListed,
    BlockAll
}

public static class WebListModeExtensions
{
    public static string Label(this WebListMode m) => m switch
    {
        WebListMode.AllowListed => "Permitir solo las webs de la lista",
        WebListMode.BlockListed => "Bloquear las webs de la lista",
        WebListMode.BlockAll => "Bloquear todas las webs",
        _ => "Bloquear las webs de la lista"
    };
}

public enum SimilarityProtectionLevel
{
    Off = 0,
    NearDuplicates = 1,
    SpecificPagesOnly = 2
}

public static class TrustedClock
{
    public static double ContinuousSeconds() => Environment.TickCount64 / 1000.0;

    /// <summary>
    /// Names this start of the computer (macOS: kern.bootsessionuuid). It lives in a VOLATILE registry key, which Windows
    /// deletes on restart, shutdown (also «Inicio rápido») and log-off, so it cannot be wound back like the clock.
    /// The tick counter alone cannot tell a restart once it has grown past its old value.
    /// </summary>
    public static readonly string? BootId = ReadBootId();

    private static string? ReadBootId()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(
                @"Software\FocusDesk\BootSession", true, Microsoft.Win32.RegistryOptions.Volatile);
            if (key == null) return null;
            if (key.GetValue("id") is string existing && existing.Length > 0) return existing;
            var created = Guid.NewGuid().ToString("N");
            key.SetValue("id", created);
            return created;
        }
        catch { return null; }
    }
}

public sealed class TrustedDeadline
{
    public DateTimeOffset EndsAt { get; set; }
    public DateTimeOffset WallAnchor { get; set; }
    public double ContinuousAnchor { get; set; }
    public double DurationSeconds { get; set; }
    /// <summary>The start of the computer this deadline was set in (missing in data saved before it existed).</summary>
    public string? AnchorBootId { get; set; }

    public TrustedDeadline() { }

    public TrustedDeadline(double seconds, DateTimeOffset? wall = null, double? continuous = null)
    {
        var now = wall ?? DateTimeOffset.UtcNow;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        DurationSeconds = Math.Max(0, seconds);
        WallAnchor = now;
        ContinuousAnchor = cont;
        EndsAt = now.AddSeconds(DurationSeconds);
        AnchorBootId = TrustedClock.BootId;
    }

    /// <summary>The computer was restarted since this deadline was set: the tick counter started again and its anchor means nothing.</summary>
    public bool Rebooted(double? continuous = null, string? bootId = null)
    {
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        var boot = bootId ?? TrustedClock.BootId;
        if (AnchorBootId != null && boot != null && AnchorBootId != boot) return true;
        return cont < ContinuousAnchor;
    }

    /// <summary>Seconds since this deadline passed (0 while it has not).</summary>
    public double ElapsedSincePassed(DateTimeOffset? wall = null, double? continuous = null)
    {
        var now = wall ?? DateTimeOffset.UtcNow;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        if (Rebooted(cont)) return Math.Max(0, (now - EndsAt).TotalSeconds);
        return Math.Max(0, cont - (ContinuousAnchor + DurationSeconds));
    }

    public double RemainingSeconds(DateTimeOffset? wall = null, double? continuous = null)
    {
        var now = wall ?? DateTimeOffset.UtcNow;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        var elapsedCont = cont - ContinuousAnchor;
        if (elapsedCont >= 0 && cont >= ContinuousAnchor && elapsedCont <= (now - WallAnchor).TotalSeconds + 600)
        {
            return Math.Max(0, DurationSeconds - elapsedCont);
        }
        return Math.Max(0, (EndsAt - now).TotalSeconds);
    }

    public double RemainingAfterPossibleReboot(DateTimeOffset? wall = null, double? continuous = null)
    {
        var now = wall ?? DateTimeOffset.UtcNow;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        // If the computer restarted, TickCount64 started again and the anchor means nothing.
        if (Rebooted(cont))
        {
            return Math.Max(0, (EndsAt - now).TotalSeconds);
        }
        return RemainingSeconds(now, cont);
    }
}

public sealed class CategoryItem
{
    public string Name { get; set; } = "Personal";
    public double Red { get; set; } = 0.70;
    public double Green { get; set; } = 0.78;
    public double Blue { get; set; } = 0.87;

    public static List<CategoryItem> Defaults() => new()
    {
        new() { Name = "Personal", Red = 0.70, Green = 0.78, Blue = 0.87 },
        new() { Name = "Estudio", Red = 0.65, Green = 0.69, Blue = 0.98 },
        new() { Name = "Trabajo", Red = 1.00, Green = 0.65, Blue = 0.48 },
        new() { Name = "Proyecto", Red = 0.40, Green = 0.78, Blue = 0.90 }
    };
}

public sealed class BreakPeriod
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "Descanso";
    public int StartHour { get; set; } = 14;
    public int StartMinute { get; set; } = 0;
    public int DurationMinutes { get; set; } = 60;

    public bool IsActive(DateTimeOffset now)
    {
        var local = now.LocalDateTime;
        var start = new DateTime(local.Year, local.Month, local.Day, Math.Clamp(StartHour, 0, 23), Math.Clamp(StartMinute, 0, 59), 0);
        var end = start.AddMinutes(Math.Clamp(DurationMinutes, 5, 240));
        return local >= start && local < end;
    }

    public double RemainingSeconds(DateTimeOffset now)
    {
        var local = now.LocalDateTime;
        var start = new DateTime(local.Year, local.Month, local.Day, Math.Clamp(StartHour, 0, 23), Math.Clamp(StartMinute, 0, 59), 0);
        var end = start.AddMinutes(Math.Clamp(DurationMinutes, 5, 240));
        if (local < start || local >= end) return 0;
        return Math.Max(0, (end - local).TotalSeconds);
    }
}

public sealed class FocusProfile
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Category { get; set; } = "Personal";
    public int Minutes { get; set; } = 60;
    public int LeadMinutes { get; set; } = 10;
    public bool Strict { get; set; }
    public List<AllowedApp> Apps { get; set; } = new();
    public string Domains { get; set; } = "";
    public string? Folder { get; set; }
    public string Checklist { get; set; } = "";
    public bool AutoStart { get; set; }
    public SessionProtection Protection { get; set; } = SessionProtection.None;
    public int UnlockChars { get; set; } = 24;
    public int StopDelayMinutes { get; set; } = 5;
    public AppBlockAction BlockAction { get; set; } = AppBlockAction.Hide;
    public WebBlockAction WebBlockAction { get; set; } = WebBlockAction.Warn;
    public bool GuardSystemPanes { get; set; } = true;
    public bool PunisherEnabled { get; set; } = true;
    public List<string> BlockedFolders { get; set; } = new();
    public AppListMode AppListMode { get; set; } = AppListMode.AllowListed;
    public WebListMode WebListMode { get; set; } = WebListMode.AllowListed;
    public string BlockedTitleKeywords { get; set; } = "";
    public bool WholeWordKeywords { get; set; }
    public string CustomRedirectURL { get; set; } = "";
    public string MotivationalMessage { get; set; } = "";
    public bool BlockSearchMedia { get; set; }
    public bool BlockGameLibraries { get; set; }
    public SimilarityProtectionLevel SimilarityProtection { get; set; } = SimilarityProtectionLevel.Off;

    public static List<FocusProfile> Defaults() => new()
    {
        new()
        {
            Id = Guid.Parse("11111111-1111-1111-1111-111111111101"),
            Name = "Programar / Trabajo",
            Category = "Trabajo",
            Minutes = 60,
            LeadMinutes = 10,
            Domains = "github.com, stackoverflow.com, claude.ai, chatgpt.com",
            Checklist = "Definir el objetivo del bloque\nCompletar la implementación\nVerificar el resultado"
        },
        new()
        {
            Id = Guid.Parse("11111111-1111-1111-1111-111111111102"),
            Name = "Estudiar",
            Category = "Estudio",
            Minutes = 45,
            LeadMinutes = 10,
            Checklist = "Repasar el tema\nResolver ejercicios\nAnotar las dudas"
        },
        new()
        {
            Id = Guid.Parse("11111111-1111-1111-1111-111111111103"),
            Name = "Lectura y escritura",
            Category = "Proyecto",
            Minutes = 45,
            LeadMinutes = 10,
            Checklist = "Leer y subrayar ideas clave\nRedactar el borrador\nRevisar el texto"
        }
    };
}

public sealed record TaskPomodoroPhase(bool IsBreak, bool IsLongBreak, int Cycle, double RemainingInPhase)
{
    public string Label => IsBreak ? (IsLongBreak ? "Descanso largo" : "Descanso") : "Foco";
}

public sealed class FocusTask
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string Category { get; set; } = "Personal";
    public DateTimeOffset ScheduledAt { get; set; } = DateTimeOffset.Now.AddMinutes(10);
    public bool IsScheduled { get; set; } = true;
    public DateTimeOffset? DueDate { get; set; }
    public int Minutes { get; set; } = 60;
    public int LeadMinutes { get; set; } = 10;
    public bool Strict { get; set; }
    public List<AllowedApp> Apps { get; set; } = new();
    public string Domains { get; set; } = "";
    public string? Folder { get; set; }
    public string Checklist { get; set; } = "";
    public RepeatRule RepeatRule { get; set; } = RepeatRule.Never;
    public HashSet<int> RepeatDays { get; set; } = new();
    public HashSet<string> SkippedDates { get; set; } = new();
    [JsonPropertyName("seriesID")] public Guid? SeriesId { get; set; }
    [JsonPropertyName("profileID")] public Guid? ProfileId { get; set; }
    public bool IsFixedAppointment { get; set; }
    public bool Completed { get; set; }
    public bool AutoStart { get; set; }
    public SessionProtection Protection { get; set; } = SessionProtection.None;
    public int UnlockChars { get; set; } = 24;
    public int StopDelayMinutes { get; set; } = 5;
    public AppBlockAction BlockAction { get; set; } = AppBlockAction.Hide;
    public WebBlockAction WebBlockAction { get; set; } = WebBlockAction.Warn;
    public bool GuardSystemPanes { get; set; } = true;
    public bool PunisherEnabled { get; set; } = true;
    public List<string> BlockedFolders { get; set; } = new();
    public AppListMode AppListMode { get; set; } = AppListMode.AllowListed;
    public WebListMode WebListMode { get; set; } = WebListMode.AllowListed;
    public string BlockedTitleKeywords { get; set; } = "";
    public bool WholeWordKeywords { get; set; }
    public string CustomRedirectURL { get; set; } = "";
    public string MotivationalMessage { get; set; } = "";
    public bool BlockSearchMedia { get; set; }
    public bool BlockGameLibraries { get; set; }
    public SimilarityProtectionLevel SimilarityProtection { get; set; } = SimilarityProtectionLevel.Off;
    public int PomodoroWorkMinutes { get; set; }
    public int PomodoroBreakMinutes { get; set; } = 5;
    public int PomodoroLongBreakMinutes { get; set; } = 15;
    public int PomodoroLongBreakEvery { get; set; } = 4;

    [JsonIgnore]
    public DateTimeOffset End => ScheduledAt.AddMinutes(Minutes);

    [JsonIgnore]
    public bool UsesPomodoro => PomodoroWorkMinutes > 0;

    [JsonIgnore]
    public bool Enforces =>
        Strict || BlockGameLibraries || WebBlockAction != WebBlockAction.Warn || BlockSearchMedia ||
        Protection != SessionProtection.None || BlockedFolders.Count > 0 ||
        FocusRules.ParseTitleKeywords(BlockedTitleKeywords).Count > 0;

    [JsonIgnore]
    public bool BlockingIsIncomplete
    {
        get
        {
            var appsMissing = Strict && Apps.Count == 0 && !BlockGameLibraries;
            var websMissing = WebBlockAction != WebBlockAction.Warn && WebListMode != WebListMode.BlockAll &&
                              !BlockSearchMedia && FocusRules.ParseDomains(Domains).Valid.Count == 0;
            return appsMissing || websMissing;
        }
    }

    [JsonIgnore]
    public string BlockingSummary
    {
        get
        {
            var parts = new List<string>();
            if (Strict) parts.Add(AppListMode == AppListMode.AllowListed ? $"Solo {Apps.Count} app(s)" : $"Bloq. {Apps.Count} app(s)");
            if (BlockGameLibraries) parts.Add("Juegos");
            if (WebBlockAction != WebBlockAction.Warn)
            {
                var wc = FocusRules.ParseDomains(Domains).Valid.Count;
                parts.Add(WebListMode switch
                {
                    WebListMode.BlockAll => "Ninguna web",
                    WebListMode.AllowListed => $"Solo {wc} web(s)",
                    _ => $"Bloq. {wc} web(s)"
                });
            }
            if (Protection != SessionProtection.None) parts.Add(Protection.Label());
            return parts.Count == 0 ? "Sin bloqueo" : string.Join(" · ", parts);
        }
    }

    [JsonIgnore]
    public bool Valid
    {
        get
        {
            var hasTitle = !string.IsNullOrWhiteSpace(Title);
            var validDuration = Minutes is >= 1 and <= 720 && LeadMinutes is >= 0 and <= 60;
            var validStrict = !Strict || Apps.Count > 0 || BlockGameLibraries;
            var validRepeat = RepeatRule != RepeatRule.CustomDays || RepeatDays.Count > 0;
            var validWeb = WebBlockAction == WebBlockAction.Warn || WebListMode == WebListMode.BlockAll ||
                           BlockSearchMedia || FocusRules.ParseDomains(Domains).Valid.Count > 0;
            return hasTitle && validDuration && validStrict && validRepeat && validWeb;
        }
    }

    public TaskPomodoroPhase? PomodoroPhase(double elapsed)
    {
        if (!UsesPomodoro) return null;
        var work = PomodoroWorkMinutes * 60.0;
        var left = Math.Max(0, elapsed);
        var cycle = 1;
        while (cycle <= 500)
        {
            if (left < work) return new TaskPomodoroPhase(false, false, cycle, work - left);
            left -= work;
            var isLong = cycle % Math.Max(2, PomodoroLongBreakEvery) == 0;
            var pause = (isLong ? PomodoroLongBreakMinutes : PomodoroBreakMinutes) * 60.0;
            if (left < pause) return new TaskPomodoroPhase(true, isLong, cycle, pause - left);
            left -= pause;
            cycle++;
        }
        return new TaskPomodoroPhase(false, false, cycle, work);
    }

    public void Apply(FocusProfile profile)
    {
        if (string.IsNullOrWhiteSpace(Title)) Title = profile.Name;
        Category = profile.Category;
        Minutes = profile.Minutes;
        LeadMinutes = profile.LeadMinutes;
        Strict = profile.Strict;
        if (profile.Apps.Count > 0) Apps = profile.Apps.ToList();
        Domains = profile.Domains;
        if (profile.Folder != null) Folder = profile.Folder;
        Checklist = profile.Checklist;
        AutoStart = profile.AutoStart;
        Protection = profile.Protection;
        UnlockChars = profile.UnlockChars;
        StopDelayMinutes = profile.StopDelayMinutes;
        BlockAction = profile.BlockAction;
        WebBlockAction = profile.WebBlockAction;
        GuardSystemPanes = profile.GuardSystemPanes;
        PunisherEnabled = profile.PunisherEnabled;
        BlockedFolders = profile.BlockedFolders.ToList();
        AppListMode = profile.AppListMode;
        WebListMode = profile.WebListMode;
        BlockedTitleKeywords = profile.BlockedTitleKeywords;
        WholeWordKeywords = profile.WholeWordKeywords;
        CustomRedirectURL = profile.CustomRedirectURL;
        MotivationalMessage = profile.MotivationalMessage;
        BlockSearchMedia = profile.BlockSearchMedia;
        BlockGameLibraries = profile.BlockGameLibraries;
        SimilarityProtection = profile.SimilarityProtection;
        ProfileId = profile.Id;
    }

    public FocusTask? NextOccurrence(DateTimeOffset? after = null, HashSet<int>? workdays = null)
    {
        if (RepeatRule == RepeatRule.Never || !IsScheduled) return null;
        var wd = workdays is { Count: > 0 } ? workdays : new HashSet<int> { 2, 3, 4, 5, 6 };
        var reference = after.HasValue && after.Value > ScheduledAt ? after.Value : ScheduledAt;
        DateTimeOffset? candidate = null;

        // All the arithmetic is done on the WALL CLOCK of the head («09:00») and each result gets the offset that applies
        // on its own date. Adding days to a DateTimeOffset kept the old offset, so after the clock change a 09:00
        // task moved to 08:00 or 10:00.
        var headLocal = ScheduledAt.LocalDateTime;
        var timeOfDay = headLocal.TimeOfDay;

        if (RepeatRule is RepeatRule.Weekdays or RepeatRule.CustomDays)
        {
            var allowed = RepeatRule == RepeatRule.Weekdays
                ? wd
                : (RepeatDays.Count > 0 ? RepeatDays : new HashSet<int> { FocusRules.AppleWeekday(ScheduledAt) });
            var day = reference.LocalDateTime.Date;
            for (var i = 0; i < 400; i++)
            {
                var dateOnDay = FocusRules.FromLocal(day.Add(timeOfDay));
                var key = FocusRules.DayKey(dateOnDay);
                if (dateOnDay > ScheduledAt && dateOnDay > reference && allowed.Contains(FocusRules.AppleWeekday(dateOnDay)) && !SkippedDates.Contains(key))
                {
                    candidate = dateOnDay;
                    break;
                }
                day = day.AddDays(1);
            }
        }
        else
        {
            var unitDays = RepeatRule == RepeatRule.Daily ? 1 : 7;
            // Jump close to `reference` instead of walking from the first date: a long-neglected series still finds its next one.
            var daysAhead = (int)Math.Max(0, (reference.LocalDateTime.Date - headLocal.Date).TotalDays);
            var steps = Math.Max(1, daysAhead / unitDays);
            for (var n = 0; n < 400; n++, steps++)
            {
                var date = FocusRules.FromLocal(headLocal.Date.AddDays((double)steps * unitDays).Add(timeOfDay));
                var key = FocusRules.DayKey(date);
                if (date > reference && !SkippedDates.Contains(key))
                {
                    candidate = date;
                    break;
                }
            }
        }

        if (!candidate.HasValue) return null;
        var copy = Clone();
        copy.Id = Guid.NewGuid();
        copy.SeriesId = SeriesId ?? Id;
        copy.ScheduledAt = candidate.Value;
        if (DueDate.HasValue)
        {
            copy.DueDate = candidate.Value + (DueDate.Value - ScheduledAt);
        }
        copy.Completed = false;
        return copy;
    }

    /// <summary>Future occurrences of this series between `from` and `to`, for the agenda preview. Nothing is stored.</summary>
    public List<FocusTask> UpcomingOccurrences(DateTimeOffset from, DateTimeOffset to, HashSet<int>? workdays = null, int maxCount = 60)
    {
        var results = new List<FocusTask>();
        if (RepeatRule == RepeatRule.Never || !IsScheduled || Completed) return results;
        var cursor = NextOccurrence(from.AddSeconds(-1), workdays);
        var safety = 0;
        while (cursor != null && results.Count < maxCount && safety++ < 366)
        {
            if (cursor.ScheduledAt > to) break;
            if (cursor.ScheduledAt >= from)
            {
                cursor.SeriesId = SeriesId ?? Id;
                results.Add(cursor);
            }
            cursor = cursor.NextOccurrence(cursor.ScheduledAt, workdays);
        }
        return results;
    }

    public FocusTask Clone()
    {
        var json = JsonSerializer.Serialize(this, WorkspaceStore.JsonOptions);
        return JsonSerializer.Deserialize<FocusTask>(json, WorkspaceStore.JsonOptions)!;
    }
}

/// <summary>
/// A recurring task is ONE task whose date is its current occurrence; it only advances when that occurrence is
/// completed. Skip a day (not started, «Sigue pendiente», cancelled) and it stayed in the past for good, vanishing from
/// the agenda. Rolling moves the series to its first occurrence from today on and leaves the missed one behind as an
/// ordinary overdue task, so nothing silently disappears (port of `SeriesRoller` in macOS Planning.swift).
/// </summary>
public static class SeriesRoller
{
    /// <summary>Returns how many series moved forward. Mutates `tasks` (heads move, overdue copies are appended).</summary>
    public static int Roll(List<FocusTask> tasks, Guid? sessionTaskId, DateTimeOffset now, HashSet<int>? workdays = null)
    {
        var today = now.LocalDateTime.Date;
        var startOfToday = FocusRules.FromLocal(today);
        var rolled = 0;
        var overdueCopies = new List<FocusTask>();

        foreach (var head in tasks.ToList())
        {
            if (head.RepeatRule == RepeatRule.Never || !head.IsScheduled || head.Completed || head.Id == sessionTaskId) continue;
            if (head.ScheduledAt.LocalDateTime.Date >= today) continue;
            var next = head.NextOccurrence(startOfToday.AddSeconds(-1), workdays);
            if (next == null) continue;

            // One overdue reminder per series is enough: a week of missed daily tasks must not bury the day in copies.
            var seriesKey = head.SeriesId ?? head.Id;
            var alreadyOverdue = tasks.Concat(overdueCopies).Any(o =>
                o.RepeatRule == RepeatRule.Never && !o.Completed && o.IsScheduled &&
                (o.SeriesId == seriesKey || o.SeriesId == head.Id) &&
                o.ScheduledAt.LocalDateTime.Date < today);
            if (!alreadyOverdue)
            {
                var missed = head.Clone();
                missed.Id = Guid.NewGuid();
                missed.RepeatRule = RepeatRule.Never;
                missed.RepeatDays = new HashSet<int>();
                missed.SkippedDates = new HashSet<string>();
                missed.SeriesId = seriesKey;
                overdueCopies.Add(missed);
            }

            head.ScheduledAt = next.ScheduledAt;
            head.DueDate = next.DueDate;
            rolled++;
        }

        tasks.AddRange(overdueCopies);
        return rolled;
    }
}

public sealed class Activity
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset At { get; set; } = DateTimeOffset.UtcNow;
    [JsonPropertyName("appID")] public string AppId { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Title { get; set; }
    public string? Domain { get; set; }
    public bool Interruption { get; set; }
    public double Duration { get; set; }
}

public sealed class StopRequest
{
    public const double DefaultConfirmWindowSeconds = 180;

    public string Reason { get; set; } = "cancel";
    public DateTimeOffset AvailableAt { get; set; }
    public TrustedDeadline? Deadline { get; set; }
    /// <summary>Once the wait is over, how long the person has to confirm before the request expires and the lock re-arms.</summary>
    public double ConfirmWindowSeconds { get; set; } = DefaultConfirmWindowSeconds;

    public StopRequest() { }
    public StopRequest(string reason, int delayMinutes, DateTimeOffset? now = null)
    {
        Reason = reason;
        var sec = Math.Clamp(delayMinutes, 1, 120) * 60.0;
        var t = now ?? DateTimeOffset.UtcNow;
        AvailableAt = t.AddSeconds(sec);
        Deadline = new TrustedDeadline(sec, t);
    }

    public double RemainingSeconds(DateTimeOffset? now = null)
    {
        if (Deadline != null) return Deadline.RemainingAfterPossibleReboot(now);
        return Math.Max(0, (AvailableAt - (now ?? DateTimeOffset.UtcNow)).TotalSeconds);
    }

    /// <summary>The wait finished and the confirmation window ran out without the person doing it.</summary>
    public bool IsExpired(DateTimeOffset? now = null)
    {
        if (RemainingSeconds(now) > 0) return false;
        var since = Deadline != null
            ? Deadline.ElapsedSincePassed(now)
            : Math.Max(0, ((now ?? DateTimeOffset.UtcNow) - AvailableAt).TotalSeconds);
        return since > Math.Max(30, ConfirmWindowSeconds);
    }

    public bool IsReady(DateTimeOffset? now = null) => RemainingSeconds(now) <= 0 && !IsExpired(now);

    public double ConfirmWindowRemaining(DateTimeOffset? now = null)
    {
        if (RemainingSeconds(now) > 0) return Math.Max(30, ConfirmWindowSeconds);
        var since = Deadline != null ? Deadline.ElapsedSincePassed(now) : 0;
        return Math.Max(0, Math.Max(30, ConfirmWindowSeconds) - since);
    }
}

/// <summary>A wait for a protected change that is running (kept on disk, so closing the app does not clear it).</summary>
public sealed class PendingStopWait
{
    public string Key { get; set; } = "";
    public StopRequest Request { get; set; } = new();
}

public sealed class DistractionPunisher
{
    /// <summary>Attempts inside `Window` that set it off.</summary>
    public int MaxAttempts { get; set; } = 4;
    public double Window { get; set; } = 180;
    /// <summary>How long the harder block lasts.</summary>
    public double Duration { get; set; } = 600;
    /// <summary>Continuous-clock instants of the recent attempts.</summary>
    public List<double> Recent { get; set; } = new();
    public double? ActiveUntil { get; set; }
    /// <summary>How many times it has gone off (for the history).</summary>
    public int TimesTriggered { get; set; }

    public bool IsActive(double? continuous = null)
    {
        if (ActiveUntil == null) return false;
        var c = continuous ?? TrustedClock.ContinuousSeconds();
        // A value saved before a restart can lie far in the future: it never outlasts its own duration.
        return c < ActiveUntil.Value && ActiveUntil.Value - c <= Duration + 1;
    }

    public double Remaining(double? continuous = null)
    {
        if (!IsActive(continuous)) return 0;
        var c = continuous ?? TrustedClock.ContinuousSeconds();
        return Math.Max(0, ActiveUntil!.Value - c);
    }

    /// <summary>Records one blocked attempt. Returns true the moment the punisher switches on.</summary>
    public bool Register(double? continuous = null)
    {
        var c = continuous ?? TrustedClock.ContinuousSeconds();
        Recent.RemoveAll(x => c - x > Window || x > c);
        Recent.Add(c);
        if (Recent.Count > 50) Recent.RemoveRange(0, Recent.Count - 50);
        if (IsActive(c) || Recent.Count < Math.Max(2, MaxAttempts)) return false;
        ActiveUntil = c + Math.Max(60, Duration);
        TimesTriggered++;
        Recent.Clear();
        return true;
    }

    public void Clear()
    {
        Recent.Clear();
        ActiveUntil = null;
    }
}

public enum StrictDecisionKind { None, Cooldown, Redirect, PauseSession }

/// <summary>
/// Strict mode «solo estas apps»: how often to send the person back to an allowed app and when to give up (port of
/// `StrictRedirectTracker`). Without it the block fought forever, closing every app that was focused.
/// </summary>
public sealed class StrictRedirectTracker
{
    public int ConsecutiveFailures { get; set; }
    public DateTimeOffset LastRedirectAt { get; set; } = DateTimeOffset.MinValue;
    public int MaxConsecutiveFailures { get; set; } = 3;
    public double CooldownSeconds { get; set; } = 1.5;

    public void RegisterAllowedAppObserved() => ConsecutiveFailures = 0;

    public (StrictDecisionKind Kind, string? Reason) EvaluateUnallowed(bool hasRunningAllowedApp, DateTimeOffset now)
    {
        if (!hasRunningAllowedApp)
        {
            ConsecutiveFailures = 0;
            return (StrictDecisionKind.PauseSession, "Sesión pausada: no hay ninguna app permitida abierta. Abre una y reanuda.");
        }
        if (ConsecutiveFailures >= MaxConsecutiveFailures)
        {
            ConsecutiveFailures = 0;
            return (StrictDecisionKind.PauseSession, "Sesión pausada: no se pudo volver a la app permitida tras varios intentos. Así conservas siempre el control.");
        }
        if ((now - LastRedirectAt).TotalSeconds < CooldownSeconds) return (StrictDecisionKind.Cooldown, null);
        LastRedirectAt = now;
        return (StrictDecisionKind.Redirect, null);
    }

    /// <summary>Counts even when Windows says it worked: only seeing an allowed app really in front brings it back to 0.</summary>
    public void RecordRedirectAttempt() => ConsecutiveFailures++;
}

public sealed class AppUsageSummary
{
    public string AppId { get; set; } = "";
    public string Name { get; set; } = "";
    public double Seconds { get; set; }
}

/// <summary>A file as it was when a session started (to tell afterwards what changed in the result folder).</summary>
public sealed class FileStamp
{
    public DateTimeOffset Modified { get; set; }
    public long Bytes { get; set; }
}

public sealed class WorkSession
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public FocusTask Task { get; set; } = new();
    public DateTimeOffset StartedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? RunningSince { get; set; }
    public double? RunningUptime { get; set; }
    public double Accumulated { get; set; }
    public double Budget { get; set; }
    public List<Activity> Activities { get; set; } = new();
    public int InterruptionCount { get; set; }
    public bool InDistractionEpisode { get; set; }
    public DateTimeOffset? LastActivityAt { get; set; }
    public double? LastActivityUptime { get; set; }
    public HashSet<string> Checked { get; set; } = new();
    public DateTimeOffset? EndedAt { get; set; }
    public StopRequest? StopRequest { get; set; }
    public DistractionPunisher Punisher { get; set; } = new();
    public int BlocksApplied { get; set; }
    public DateTimeOffset? ResumeOnLaunchUntil { get; set; }

    // Evidence in the task's result folder (macOS: baseline + finalChangedFiles + selectedFiles + manualFiles).
    public Dictionary<string, FileStamp> Baseline { get; set; } = new();
    public bool BaselineValid { get; set; }
    public List<string>? FinalChangedFiles { get; set; }
    public string? FinalEvidenceMessage { get; set; }
    public List<string> SelectedFiles { get; set; } = new();
    public List<string> ManualFiles { get; set; } = new();

    public WorkSession() { }
    public WorkSession(FocusTask task, DateTimeOffset? now = null, double? uptime = null)
    {
        var t = now ?? DateTimeOffset.UtcNow;
        Task = task.Clone();
        StartedAt = t;
        RunningSince = t;
        RunningUptime = uptime ?? TrustedClock.ContinuousSeconds();
        Budget = Math.Max(60, task.Minutes * 60.0);
        if (Task.Protection != SessionProtection.None)
            ResumeOnLaunchUntil = t.AddSeconds(Budget);
    }

    [JsonIgnore] public bool Paused => RunningSince == null;

    public double Elapsed(DateTimeOffset now, double? uptime = null)
    {
        if (!RunningSince.HasValue) return Accumulated;
        var up = uptime ?? TrustedClock.ContinuousSeconds();
        if (RunningUptime.HasValue && up >= RunningUptime.Value)
        {
            return Accumulated + Math.Max(0, up - RunningUptime.Value);
        }
        return Accumulated + Math.Max(0, (now - RunningSince.Value).TotalSeconds);
    }

    public double Remaining(DateTimeOffset now, double? uptime = null) => Budget - Elapsed(now, uptime);

    public bool Enforcing(DateTimeOffset now, double? uptime = null) =>
        !Paused && EndedAt == null && Task.Enforces && Remaining(now, uptime) > 0;

    public bool ShouldResumeAfterRelaunch(DateTimeOffset? now = null)
    {
        if (EndedAt != null || Task.Protection == SessionProtection.None || Budget - Accumulated <= 0) return false;
        var t = now ?? DateTimeOffset.UtcNow;
        var deadline = ResumeOnLaunchUntil ?? RunningSince?.AddSeconds(Budget - Accumulated);
        return deadline.HasValue && t < deadline.Value;
    }

    public void Checkpoint(DateTimeOffset now, double? uptime = null)
    {
        if (Paused || EndedAt != null) return;
        CloseOpenActivity(now, uptime);
        Accumulated = Elapsed(now, uptime);
        RunningSince = now;
        RunningUptime = uptime ?? TrustedClock.ContinuousSeconds();
        LastActivityAt = now;
        LastActivityUptime = RunningUptime;
        if (Task.Protection != SessionProtection.None)
            ResumeOnLaunchUntil = now.AddSeconds(Math.Max(0, Budget - Accumulated));
    }

    /// <summary>
    /// A session read from disk never keeps running on its own. Only what was saved before the app went away counts
    /// (the last checkpoint, at most a few seconds old): the time FocusDesk was closed is NOT work. Crediting it let a
    /// shutdown or a force-quit turn into hours of "study" (macOS clears `runningSince` here for the same reason).
    /// </summary>
    public void RecoverAfterUncleanExit(DateTimeOffset now)
    {
        RunningSince = null;
        RunningUptime = null;
        LastActivityAt = null;
        LastActivityUptime = null;
        InDistractionEpisode = false;
    }

    public void Pause(DateTimeOffset now, double? uptime = null)
    {
        if (!Paused) CloseOpenActivity(now, uptime);
        Accumulated = Elapsed(now, uptime);
        RunningSince = null;
        RunningUptime = null;
        ResumeOnLaunchUntil = null;
        LastActivityAt = null;
        LastActivityUptime = null;
        InDistractionEpisode = false;
    }

    public void Resume(DateTimeOffset now, double? uptime = null)
    {
        if (RunningSince != null || EndedAt != null) return;
        RunningSince = now;
        RunningUptime = uptime ?? TrustedClock.ContinuousSeconds();
        ResumeOnLaunchUntil = Task.Protection != SessionProtection.None
            ? now.AddSeconds(Math.Max(0, Budget - Accumulated))
            : null;
        LastActivityAt = now;
        LastActivityUptime = RunningUptime;
        InDistractionEpisode = false;
    }

    public void Finish(DateTimeOffset now, double? uptime = null)
    {
        if (EndedAt != null) return;
        Pause(now, uptime);
        EndedAt = now;
    }

    /// <summary>Undoes «He terminado»: the session runs again from where it stopped. Worked time is kept.</summary>
    public void Reopen(DateTimeOffset now, double? uptime = null)
    {
        if (EndedAt == null) return;
        EndedAt = null;
        FinalChangedFiles = null;
        FinalEvidenceMessage = null;
        SelectedFiles = new List<string>();
        Resume(now, uptime);
    }

    public void AddMinutes(int minutes) => Budget += Math.Max(0, minutes) * 60.0;

    public bool ObserveForeground(string appId, string name, string? title, bool allowed, DateTimeOffset now, double? uptime = null)
    {
        if (Paused || EndedAt != null) return false;
        bool isNew;
        if (allowed)
        {
            InDistractionEpisode = false;
            isNew = false;
        }
        else
        {
            isNew = !InDistractionEpisode;
            InDistractionEpisode = true;
        }
        var last = Activities.LastOrDefault();
        if (isNew || last == null || last.AppId != appId || last.Title != title)
        {
            CloseOpenActivity(now, uptime);
            if (isNew) InterruptionCount++;
            Activities.Add(new Activity { At = now, AppId = appId, Name = name, Title = title, Interruption = isNew });
            LastActivityAt = now;
            LastActivityUptime = uptime ?? TrustedClock.ContinuousSeconds();
            if (Activities.Count > 2000) Activities.RemoveRange(0, Activities.Count - 2000);
        }
        else
        {
            CloseOpenActivity(now, uptime);
        }
        return isNew;
    }

    public void RecordVisit(string appId, string name, string domain, bool interruption, DateTimeOffset now, double? uptime = null)
    {
        if (Paused || EndedAt != null) return;
        var last = Activities.LastOrDefault();
        if (last != null && last.AppId == appId && (last.Domain == domain || (last.Domain == null && (now - last.At).TotalSeconds <= 8)))
        {
            CloseOpenActivity(now, uptime);
            last.Domain = domain;
            if (interruption)
            {
                if (!last.Interruption) InterruptionCount++;
                last.Interruption = true;
            }
            return;
        }
        CloseOpenActivity(now, uptime);
        if (interruption) InterruptionCount++;
        Activities.Add(new Activity { At = now, AppId = appId, Name = name, Domain = domain, Interruption = interruption });
        LastActivityAt = now;
        LastActivityUptime = uptime ?? TrustedClock.ContinuousSeconds();
    }

    private void CloseOpenActivity(DateTimeOffset now, double? uptime)
    {
        if (Activities.Count == 0) return;
        var up = uptime ?? TrustedClock.ContinuousSeconds();
        double delta = 0;
        if (LastActivityUptime.HasValue && up >= LastActivityUptime.Value)
            delta = up - LastActivityUptime.Value;
        else if (LastActivityAt.HasValue)
            delta = Math.Max(0, (now - LastActivityAt.Value).TotalSeconds);
        Activities[^1].Duration += delta;
        LastActivityAt = now;
        LastActivityUptime = up;
    }
}

public sealed class SessionRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public WorkSession Session { get; set; } = new();
    public bool Completed { get; set; }
    public bool Cancelled { get; set; }
    public string Note { get; set; } = "";
    public List<string> ChangedFiles { get; set; } = new();
    public List<string> ConfirmedFiles { get; set; } = new();
    public List<string> ManualFiles { get; set; } = new();
    public List<AppUsageSummary>? SavedSummaries { get; set; }
    public double? SavedObservedSeconds { get; set; }

    [JsonIgnore]
    public double ObservedSeconds => Session.Activities.Count == 0
        ? (SavedObservedSeconds ?? 0)
        : Session.Activities.Sum(a => a.Duration);

    [JsonIgnore]
    public List<AppUsageSummary> AppSummaries => Session.Activities.Count == 0
        ? (SavedSummaries ?? new())
        : Session.Activities
            .Where(a => a.Duration > 0)
            .GroupBy(a => a.AppId)
            .Select(g => new AppUsageSummary { AppId = g.Key, Name = g.First().Name, Seconds = g.Sum(x => x.Duration) })
            .OrderByDescending(x => x.Seconds)
            .ToList();

    public void PreserveSummary()
    {
        if (Session.Activities.Count == 0) return;
        SavedSummaries = AppSummaries;
        SavedObservedSeconds = ObservedSeconds;
    }
}

public sealed class StudySource
{
    public string Kind { get; set; } = "app"; // "app" or "web"
    public string Value { get; set; } = "";
    public string Name { get; set; } = "";
    public string? CountsFrom { get; set; }

    [JsonIgnore] public string Id => $"{Kind}:{Value.ToLowerInvariant()}";

    public bool Counts(string today) => string.IsNullOrEmpty(CountsFrom) || string.CompareOrdinal(CountsFrom, today) <= 0;
}

public static class StudySources
{
    private static StudySource App(string exe, string name) => new() { Kind = "app", Value = exe, Name = name };
    private static StudySource Web(string domain) => new() { Kind = "web", Value = domain, Name = domain };

    public static List<StudySource> Defaults() => new()
    {
        App("claude", "Claude"),
        App("chatgpt", "ChatGPT"),
        App("code", "Visual Studio Code"),
        App("cursor", "Cursor"),
        App("devenv", "Visual Studio"),
        App("rider64", "JetBrains Rider"),
        App("idea64", "IntelliJ IDEA"),
        App("pycharm64", "PyCharm"),
        App("obsidian", "Obsidian"),
        App("notion", "Notion"),
        App("winword", "Word"),
        App("excel", "Excel"),
        App("powerpnt", "PowerPoint"),
        App("onenote", "OneNote"),
        App("acrobat", "Adobe Acrobat"),
        App("acrord32", "Adobe Reader"),
        App("sumatrapdf", "SumatraPDF"),
        App("windowsterminal", "Windows Terminal"),
        App("powershell", "PowerShell"),
        App("pwsh", "PowerShell 7"),
        App("anki", "Anki"),
        Web("claude.ai"),
        Web("chatgpt.com"),
        Web("chat.openai.com"),
        Web("gemini.google.com"),
        Web("notebooklm.google.com"),
        Web("docs.google.com"),
        Web("drive.google.com"),
        Web("coursera.org"),
        Web("edx.org"),
        Web("office.com"),
        Web("overleaf.com"),
        Web("notion.so"),
        Web("github.com"),
        Web("stackoverflow.com"),
        Web("cppreference.com"),
        Web("wikipedia.org"),
        Web("wolframalpha.com"),
        Web("desmos.com"),
        Web("khanacademy.org")
    };

    public static (HashSet<string> Apps, string Webs) Active(IEnumerable<StudySource> sources, string today)
    {
        var live = sources.Where(s => s.Counts(today) && !string.IsNullOrWhiteSpace(s.Value)).ToList();
        var apps = live.Where(s => s.Kind == "app").Select(s => s.Value.ToLowerInvariant().Replace(".exe", "")).ToHashSet();
        var webs = string.Join(", ", live.Where(s => s.Kind == "web").Select(s => s.Value));
        return (apps, webs);
    }
}

public sealed class TemporaryAllowEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Target { get; set; } = "";
    public bool IsAppBundleId { get; set; }
    public string Label { get; set; } = "";
    public TrustedDeadline Deadline { get; set; } = new();

    public bool IsActive(DateTimeOffset now, double continuous) => Deadline.RemainingAfterPossibleReboot(now, continuous) > 0;
}

public sealed class RuleAuditEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset At { get; set; } = DateTimeOffset.UtcNow;
    public string Category { get; set; } = "";
    public string Summary { get; set; } = "";
}

public sealed class Settings
{
    public int DetailDays { get; set; } = 30;
    public List<CategoryItem> Categories { get; set; } = CategoryItem.Defaults();
    public HashSet<int> Workdays { get; set; } = new() { 2, 3, 4, 5, 6 };
    public int WorkStartHour { get; set; } = 9;
    public int WorkEndHour { get; set; } = 19;
    public List<BreakPeriod> Breaks { get; set; } = new()
    {
        new() { Title = "Descanso / Comida", StartHour = 14, StartMinute = 0, DurationMinutes = 60 }
    };
    public bool RelaunchGuard { get; set; }
    public int RunUpMinutes { get; set; } = 10;
    public bool EnforceBreaks { get; set; } = true;
    public bool PreBlockRemindersEnabled { get; set; } = true;
    public bool ContinuousBreakEnabled { get; set; }
    public int ContinuousWorkMinutes { get; set; } = 50;
    public int ContinuousBreakDurationMinutes { get; set; } = 5;
    public int ContinuousBreakMaxSkipsPerDay { get; set; } = 2;
    public List<string> BreakMessages { get; set; } = new()
    {
        "Descansa la vista 20 segundos mirando a lo lejos.",
        "Levántate, estira los hombros y bebe un vaso de agua.",
        "Respira hondo tres veces: el descanso también es parte del foco.",
        "Suelta el teclado un momento para volver con la mente despejada."
    };
    public int DayRolloverHour { get; set; }
    public bool ProtectClipboard { get; set; }
    public bool ProtectActivityHistory { get; set; }
    /// <summary>Also reads the address of the page in front during a session to list the sites visited (not only to block them).</summary>
    public bool ObserveBrowserSites { get; set; }
    /// <summary>Keeps the titles of the windows used during a session in its activity record. Off unless asked for, as on macOS.</summary>
    public bool ObserveTitles { get; set; }
    /// <summary>Programs whose window titles are never kept (password managers, messaging…).</summary>
    public List<AllowedApp> ExcludedTitleApps { get; set; } = new();
    /// <summary>Text size multiplier (1, 1.15, 1.3).</summary>
    public double TextScale { get; set; } = 1;
    /// <summary>Global shortcut Ctrl+Alt+Win + letter to open FocusDesk.</summary>
    public bool HotKeyEnabled { get; set; } = true;
    /// <summary>0 = F, 1 = Espacio, 2 = J, 3 = K (the same four that macOS offers).</summary>
    public int HotKeyChoice { get; set; }
    /// <summary>Starts FocusDesk when the user signs in to Windows.</summary>
    public bool LaunchAtLogin { get; set; }
    public List<StudySource> StudySources { get; set; } = Core.StudySources.Defaults();
}

public sealed class Workspace
{
    public int Schema { get; set; } = 1;
    // One damaged element must not make the whole file unreadable: the lossy converters skip (and count) what does not read.
    [JsonConverter(typeof(LossyListConverter<FocusTask>))]
    public List<FocusTask> Tasks { get; set; } = new();
    [JsonConverter(typeof(LossyListConverter<FocusProfile>))]
    public List<FocusProfile> Profiles { get; set; } = FocusProfile.Defaults();
    [JsonConverter(typeof(LossyObjectConverter<WorkSession>))]
    public WorkSession? Session { get; set; }
    [JsonConverter(typeof(LossyListConverter<SessionRecord>))]
    public List<SessionRecord> History { get; set; } = new();
    [JsonConverter(typeof(LossyObjectOrDefaultConverter<Settings>))]
    public Settings Settings { get; set; } = new();
    [JsonConverter(typeof(LossyListConverter<GeneralBlockRule>))]
    public List<GeneralBlockRule> GeneralRules { get; set; } = GeneralBlockRule.Defaults();
    public Dictionary<string, Dictionary<string, double>> DailyRuleUsage { get; set; } = new();
    public Dictionary<string, Dictionary<string, int>> DailyRuleLaunches { get; set; } = new();
    public Dictionary<string, Dictionary<string, int>> DailyRuleMatches { get; set; } = new();
    public Dictionary<string, double> DailyVerifiedStudySeconds { get; set; } = new();
    public Dictionary<string, Dictionary<string, int>> DailyMicroPausesUsed { get; set; } = new();
    public Dictionary<string, int> DailyContinuousBreakSkips { get; set; } = new();
    [JsonConverter(typeof(LossyListConverter<TemporaryAllowEntry>))]
    public List<TemporaryAllowEntry> TemporaryAllows { get; set; } = new();
    [JsonConverter(typeof(LossyListConverter<RuleAuditEntry>))]
    public List<RuleAuditEntry> AuditLog { get; set; } = new();
    public DateTimeOffset? ClosedBySystemAt { get; set; }
    /// <summary>Waits («Espera») for protected changes that are running; they survive closing the app.</summary>
    [JsonConverter(typeof(LossyListConverter<PendingStopWait>))]
    public List<PendingStopWait> PendingStopWaits { get; set; } = new();

    public void RecordAudit(string category, string summary, DateTimeOffset? at = null)
    {
        AuditLog.Insert(0, new RuleAuditEntry { At = at ?? DateTimeOffset.UtcNow, Category = category, Summary = summary });
        if (AuditLog.Count > 300) AuditLog.RemoveRange(300, AuditLog.Count - 300);
    }

    private LimitPeriodUnit RulePeriodUnit(Guid ruleId) =>
        GeneralRules.FirstOrDefault(r => r.Id == ruleId)?.LimitPeriodUnit ?? LimitPeriodUnit.Day;

    public double UsedSecondsToday(Guid ruleId, LimitPeriodUnit? unit = null, DateTimeOffset? now = null)
    {
        var key = FocusRules.PeriodKey(now ?? DateTimeOffset.Now, unit ?? RulePeriodUnit(ruleId), Settings.DayRolloverHour);
        return DailyRuleUsage.TryGetValue(key, out var map) && map.TryGetValue(ruleId.ToString(), out var val) ? val : 0;
    }

    public double AddUsedSeconds(double delta, Guid ruleId, LimitPeriodUnit? unit = null, DateTimeOffset? now = null)
    {
        var key = FocusRules.PeriodKey(now ?? DateTimeOffset.Now, unit ?? RulePeriodUnit(ruleId), Settings.DayRolloverHour);
        if (!DailyRuleUsage.TryGetValue(key, out var map))
        {
            map = new();
            DailyRuleUsage[key] = map;
        }
        var k = ruleId.ToString();
        var updated = Math.Max(0, (map.TryGetValue(k, out var cur) ? cur : 0) + Math.Max(0, delta));
        map[k] = updated;
        return updated;
    }

    public int LaunchesToday(Guid ruleId, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        return DailyRuleLaunches.TryGetValue(key, out var map) && map.TryGetValue(ruleId.ToString(), out var val) ? val : 0;
    }

    public int IncrementLaunches(Guid ruleId, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        if (!DailyRuleLaunches.TryGetValue(key, out var map)) { map = new(); DailyRuleLaunches[key] = map; }
        var k = ruleId.ToString();
        var updated = (map.TryGetValue(k, out var cur) ? cur : 0) + 1;
        map[k] = updated;
        return updated;
    }

    public int MatchesToday(Guid ruleId, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        return DailyRuleMatches.TryGetValue(key, out var map) && map.TryGetValue(ruleId.ToString(), out var val) ? val : 0;
    }

    public int IncrementMatches(Guid ruleId, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        if (!DailyRuleMatches.TryGetValue(key, out var map)) { map = new(); DailyRuleMatches[key] = map; }
        var k = ruleId.ToString();
        var updated = (map.TryGetValue(k, out var cur) ? cur : 0) + 1;
        map[k] = updated;
        return updated;
    }

    public double VerifiedStudySecondsToday(DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        return DailyVerifiedStudySeconds.TryGetValue(key, out var val) ? val : 0;
    }

    public double AddVerifiedStudySeconds(double delta, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        var cur = DailyVerifiedStudySeconds.TryGetValue(key, out var val) ? val : 0;
        var updated = Math.Max(0, cur + Math.Max(0, delta));
        DailyVerifiedStudySeconds[key] = updated;
        return updated;
    }

    public int MicroPausesUsedToday(Guid ruleId, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        return DailyMicroPausesUsed.TryGetValue(key, out var map) && map.TryGetValue(ruleId.ToString(), out var val) ? val : 0;
    }

    public int IncrementMicroPauses(Guid ruleId, DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        if (!DailyMicroPausesUsed.TryGetValue(key, out var map)) { map = new(); DailyMicroPausesUsed[key] = map; }
        var k = ruleId.ToString();
        var updated = (map.TryGetValue(k, out var cur) ? cur : 0) + 1;
        map[k] = updated;
        return updated;
    }

    public int ContinuousBreakSkipsToday(DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        return DailyContinuousBreakSkips.TryGetValue(key, out var val) ? val : 0;
    }

    public int IncrementContinuousBreakSkips(DateTimeOffset? now = null)
    {
        var key = FocusRules.DayKey(now ?? DateTimeOffset.Now, Settings.DayRolloverHour);
        var updated = (DailyContinuousBreakSkips.TryGetValue(key, out var cur) ? cur : 0) + 1;
        DailyContinuousBreakSkips[key] = updated;
        return updated;
    }

    public bool IsTemporarilyAllowed(string host, string path, DateTimeOffset now, double continuous) =>
        TemporaryAllows.Any(e => !e.IsAppBundleId && e.IsActive(now, continuous) && FocusRules.EntryMatches(host, path, e.Target));

    public bool IsTemporarilyAllowedApp(string appId, DateTimeOffset now, double continuous) =>
        TemporaryAllows.Any(e => e.IsAppBundleId && e.IsActive(now, continuous) &&
            string.Equals(e.Target, appId, StringComparison.OrdinalIgnoreCase));

    public void Prune(DateTimeOffset now)
    {
        var cutoff = now.AddDays(-Math.Max(1, Settings.DetailDays));
        foreach (var rec in History)
        {
            if ((rec.Session.EndedAt ?? now) < cutoff)
            {
                rec.PreserveSummary();
                rec.Session.Activities.Clear();
            }
        }
        var minDay = FocusRules.DayKey(cutoff, Settings.DayRolloverHour);
        foreach (var k in DailyRuleUsage.Keys.Where(k => string.CompareOrdinal(k, minDay) < 0).ToList()) DailyRuleUsage.Remove(k);
        foreach (var k in DailyRuleLaunches.Keys.Where(k => string.CompareOrdinal(k, minDay) < 0).ToList()) DailyRuleLaunches.Remove(k);
        foreach (var k in DailyRuleMatches.Keys.Where(k => string.CompareOrdinal(k, minDay) < 0).ToList()) DailyRuleMatches.Remove(k);
        foreach (var k in DailyVerifiedStudySeconds.Keys.Where(k => string.CompareOrdinal(k, minDay) < 0).ToList()) DailyVerifiedStudySeconds.Remove(k);
        foreach (var k in DailyMicroPausesUsed.Keys.Where(k => string.CompareOrdinal(k, minDay) < 0).ToList()) DailyMicroPausesUsed.Remove(k);
        foreach (var k in DailyContinuousBreakSkips.Keys.Where(k => string.CompareOrdinal(k, minDay) < 0).ToList()) DailyContinuousBreakSkips.Remove(k);
        var cont = TrustedClock.ContinuousSeconds();
        TemporaryAllows.RemoveAll(e => !e.IsActive(now, cont));
    }
}

public static partial class FocusRules
{
    /// <summary>
    /// Name of THIS process. The released file is called «FocusDesk-Windows-x64.exe», and a Windows process is named after
    /// its file, so comparing with the literal text «focusdesk» left FocusDesk blocking (or killing) itself.
    /// </summary>
    public static readonly string OwnProcessName = ReadOwnProcessName();

    private static string ReadOwnProcessName()
    {
        try
        {
            using var me = System.Diagnostics.Process.GetCurrentProcess();
            var name = me.ProcessName;
            return string.IsNullOrWhiteSpace(name) ? "focusdesk" : name.ToLowerInvariant();
        }
        catch { return "focusdesk"; }
    }

    private static HashSet<string> WithOwnProcess(params string[] names)
    {
        var set = new HashSet<string>(names, StringComparer.OrdinalIgnoreCase) { OwnProcessName };
        return set;
    }

    /// <summary>True when `pid` is FocusDesk itself (whatever its file is called).</summary>
    public static bool IsOwnProcess(int pid) => pid == Environment.ProcessId;

    public static readonly HashSet<string> SystemExemptProcesses = WithOwnProcess(
        "focusdesk", "explorer", "shellexperiencehost", "startmenuexperiencehost", "searchhost",
        "searchui", "applicationframehost", "lockapp", "logonui", "dwm", "csrss", "lsass",
        "winlogon", "svchost", "taskhostw", "sihost", "ctfmon", "narrator", "magnify",
        "osk", "securityhealthsystray");

    public static readonly HashSet<string> NeverTerminateProcesses = WithOwnProcess(
        "focusdesk", "explorer", "dwm", "csrss", "lsass", "winlogon", "svchost", "smss",
        "services", "taskhostw", "sihost", "shellexperiencehost", "startmenuexperiencehost",
        "searchhost", "narrator", "cmd", "windowsterminal", "powershell", "pwsh");

    /// <summary>A wall-clock time (no zone) as an instant, with the offset that applies on THAT date (daylight saving included).</summary>
    public static DateTimeOffset FromLocal(DateTime wallClock)
    {
        var unspecified = DateTime.SpecifyKind(wallClock, DateTimeKind.Unspecified);
        return new DateTimeOffset(unspecified, TimeZoneInfo.Local.GetUtcOffset(unspecified));
    }

    public static AppBlockAction SafeAction(AppBlockAction action, string processName)
    {
        var clean = processName.Replace(".exe", "", StringComparison.OrdinalIgnoreCase);
        return NeverTerminateProcesses.Contains(clean) ? AppBlockAction.Hide : action;
    }

    public static int AppleWeekday(DateTimeOffset dt) => ((int)dt.LocalDateTime.DayOfWeek) + 1;

    public static string DayKey(DateTimeOffset dt, int rolloverHour = 0)
    {
        var adjusted = dt.LocalDateTime.AddHours(-Math.Clamp(rolloverHour, 0, 8));
        return adjusted.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    }

    public static string PeriodKey(DateTimeOffset dt, LimitPeriodUnit unit, int rolloverHour = 0)
    {
        var adjusted = dt.LocalDateTime.AddHours(-Math.Clamp(rolloverHour, 0, 8));
        return unit switch
        {
            LimitPeriodUnit.Hour => adjusted.ToString("yyyy-MM-dd-HH", CultureInfo.InvariantCulture),
            LimitPeriodUnit.Week => $"{ISOWeek.GetYear(adjusted)}-W{ISOWeek.GetWeekOfYear(adjusted):D2}",
            _ => adjusted.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)
        };
    }

    public static string Clock(double seconds)
    {
        var val = (int)Math.Abs(seconds);
        var prefix = seconds <= -1 ? "+" : "";
        return val >= 3600
            ? $"{prefix}{val / 3600}:{val / 60 % 60:D2}:{val % 60:D2}"
            : $"{prefix}{val / 60:D2}:{val % 60:D2}";
    }

    public static string DurationText(int minutes)
    {
        var val = Math.Max(0, minutes);
        if (val < 60) return $"{val} min";
        return val % 60 == 0 ? $"{val / 60} h" : $"{val / 60} h {val % 60:D2}";
    }

    private static readonly TimeSpan RegexTimeout = TimeSpan.FromMilliseconds(150);

    public static bool IsRegexEntry(string entry) =>
        entry.Length >= 3 && entry.StartsWith('/') && entry.EndsWith('/');

    public static string? NormalizeDomainEntry(string raw)
    {
        var token = raw.Trim().Trim(',', ';');
        if (string.IsNullOrEmpty(token)) return null;
        if (IsRegexEntry(token))
        {
            var pat = token[1..^1];
            try { _ = new Regex(pat, RegexOptions.IgnoreCase, RegexTimeout); return "/" + pat + "/"; }
            catch { return null; }
        }
        if (token.StartsWith("*.", StringComparison.Ordinal)) token = token[2..];

        string hostCandidate;
        string pathCandidate = "";
        var hasQueryParam = token.Contains('?') && token.Contains('=');

        if (token.Contains("://", StringComparison.Ordinal) && Uri.TryCreate(token, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.Host))
        {
            hostCandidate = uri.Host;
        }
        else if (token.Contains('/') && !token.Contains("://", StringComparison.Ordinal))
        {
            var idx = token.IndexOf('/');
            hostCandidate = token[..idx];
            var sub = token[(idx + 1)..];
            var cut = sub.IndexOfAny(hasQueryParam ? new[] { '#', '?' } : new[] { '#' });
            if (cut >= 0) sub = sub[..cut];
            sub = sub.Trim('/').ToLowerInvariant();
            if (!string.IsNullOrEmpty(sub)) pathCandidate = "/" + sub;
        }
        else if ((token.Contains(':') || hasQueryParam) && Uri.TryCreate("https://" + token, UriKind.Absolute, out var u2) && !string.IsNullOrEmpty(u2.Host))
        {
            hostCandidate = u2.Host;
        }
        else
        {
            hostCandidate = token;
        }

        var cleaned = hostCandidate.ToLowerInvariant().Trim('.');
        if (cleaned.StartsWith("www.", StringComparison.Ordinal) && cleaned[4..].Contains('.'))
            cleaned = cleaned[4..];

        if (!cleaned.Contains('.') || cleaned.Contains(' ') || cleaned.StartsWith('-') || cleaned.EndsWith('-') ||
            !cleaned.All(c => char.IsLetterOrDigit(c) || c is '.' or '-' or '*' or '?'))
        {
            return null;
        }

        if (!string.IsNullOrEmpty(pathCandidate))
        {
            if (!pathCandidate.All(c => char.IsLetterOrDigit(c) || c is '/' or '-' or '_' or '.' or '~' or '*' or '?'))
                return null;
            return cleaned + pathCandidate;
        }
        return cleaned;
    }

    public static (List<string> Valid, List<string> Invalid) ParseDomains(string list)
    {
        var valid = new List<string>();
        var invalid = new List<string>();
        if (string.IsNullOrWhiteSpace(list)) return (valid, invalid);
        foreach (var raw in list.Split(new[] { ' ', '\t', '\r', '\n', ',', ';' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var norm = NormalizeDomainEntry(raw);
            if (norm != null)
            {
                if (!valid.Contains(norm)) valid.Add(norm);
            }
            else
            {
                invalid.Add(raw);
            }
        }
        return (valid, invalid);
    }

    public static string NormalizeDomains(string list) => string.Join(", ", ParseDomains(list).Valid);

    public static string WildcardRegexPattern(string pattern, bool anchored = true)
    {
        var sb = new System.Text.StringBuilder(anchored ? "^" : "");
        foreach (var ch in pattern)
        {
            sb.Append(ch switch
            {
                '*' => ".*",
                '?' => ".",
                '.' or '+' or '^' or '$' or '(' or ')' or '[' or ']' or '{' or '}' or '|' or '\\' => "\\" + ch,
                _ => ch.ToString()
            });
        }
        if (anchored) sb.Append('$');
        return sb.ToString();
    }

    private static bool MatchesWildcard(string text, string pattern)
    {
        try { return Regex.IsMatch(text, WildcardRegexPattern(pattern), RegexOptions.IgnoreCase, RegexTimeout); }
        catch { return false; }
    }

    public static bool EntryMatches(string host, string path, string entry)
    {
        var normHost = host.ToLowerInvariant().Trim('.');
        if (string.IsNullOrEmpty(normHost)) return false;
        if (IsRegexEntry(entry))
        {
            var urlCandidate = string.IsNullOrEmpty(path) || path == "/" ? normHost : normHost + (path.StartsWith('/') ? path : "/" + path);
            try { return Regex.IsMatch(urlCandidate, entry[1..^1], RegexOptions.IgnoreCase, RegexTimeout); }
            catch { return false; }
        }
        var slash = entry.IndexOf('/');
        var entryHost = (slash >= 0 ? entry[..slash] : entry).ToLowerInvariant();
        var entryPathPart = slash >= 0 ? entry[(slash + 1)..].ToLowerInvariant().Trim('/') : "";

        bool hostMatch;
        if (entryHost.Contains('*') || entryHost.Contains('?'))
            hostMatch = MatchesWildcard(normHost, entryHost) || MatchesWildcard(normHost, "*." + entryHost);
        else
            hostMatch = normHost == entryHost || normHost.EndsWith("." + entryHost, StringComparison.Ordinal);

        if (!hostMatch) return false;
        if (!string.IsNullOrEmpty(entryPathPart))
        {
            var entryPath = "/" + entryPathPart;
            var normPath = path.ToLowerInvariant();
            var cut = normPath.IndexOfAny(new[] { '?', '#' });
            if (cut >= 0) normPath = normPath[..cut];
            if (!normPath.StartsWith('/')) normPath = "/" + normPath;
            while (normPath.Length > 1 && normPath.EndsWith('/')) normPath = normPath[..^1];
            if (entryPath.Contains('*') || entryPath.Contains('?'))
                return MatchesWildcard(normPath, entryPath) || MatchesWildcard(normPath, entryPath + "/*");
            return normPath == entryPath || normPath.StartsWith(entryPath + "/", StringComparison.Ordinal);
        }
        return true;
    }

    public static bool DomainEntriesOverlap(string a, string b)
    {
        static bool IsPattern(string e) => e.Contains('*') || e.Contains('?') || IsRegexEntry(e);
        static (string Host, string Path) Parts(string e)
        {
            var idx = e.IndexOf('/');
            return idx >= 0 ? (e[..idx].ToLowerInvariant(), e[(idx + 1)..].ToLowerInvariant().Trim('/')) : (e.ToLowerInvariant(), "");
        }
        if (IsPattern(a) && IsPattern(b)) return true;
        if (IsRegexEntry(a) || IsRegexEntry(b)) return true;
        if (IsPattern(a) || IsPattern(b))
        {
            var (pattern, plain) = IsPattern(a) ? (a, b) : (b, a);
            var t = Parts(plain);
            return string.IsNullOrEmpty(t.Path)
                ? EntryMatches(t.Host, "", Parts(pattern).Host)
                : EntryMatches(t.Host, "/" + t.Path, pattern);
        }
        var p1 = Parts(a);
        var p2 = Parts(b);
        if (!(p1.Host == p2.Host || p1.Host.EndsWith("." + p2.Host) || p2.Host.EndsWith("." + p1.Host))) return false;
        if (string.IsNullOrEmpty(p1.Path) || string.IsNullOrEmpty(p2.Path)) return true;
        return p1.Path == p2.Path || p1.Path.StartsWith(p2.Path + "/") || p2.Path.StartsWith(p1.Path + "/");
    }

    /// <summary>«notion.so» becomes https://notion.so; anything that is not an http(s) address becomes null.</summary>
    public static Uri? NormalizedRedirectUrl(string? raw)
    {
        var trimmed = (raw ?? "").Trim();
        if (trimmed.Length == 0) return null;
        var candidate = trimmed.Contains("://", StringComparison.Ordinal) ? trimmed : "https://" + trimmed;
        if (!Uri.TryCreate(candidate, UriKind.Absolute, out var uri)) return null;
        if (uri.Scheme is not ("http" or "https") || string.IsNullOrEmpty(uri.Host)) return null;
        return uri;
    }

    public static string? IsRedirectDestinationBlocked(string? redirectUrl, string list, WebListMode mode, bool blockSearchMedia)
    {
        if (string.IsNullOrWhiteSpace(redirectUrl)) return null;
        var uri = NormalizedRedirectUrl(redirectUrl);
        if (uri == null) return $"La URL de redirección «{redirectUrl.Trim()}» no es válida.";
        if (blockSearchMedia && SearchMediaRules.Matches(uri.Host, uri.PathAndQuery) != null)
            return "La URL de redirección apunta a una búsqueda de imágenes/vídeos que esta misma regla bloquea.";
        if (!WebAllowed(uri.Host, uri.AbsolutePath, list, mode))
            return "La URL de redirección está bloqueada por esta misma regla y causaría un bucle de redirección.";
        return null;
    }

    public static bool WebListOpens(WebListMode curMode, List<string> current, WebListMode propMode, List<string> proposed)
    {
        if (propMode == WebListMode.BlockAll) return false;
        if (curMode != WebListMode.BlockAll && current.Count == 0) return false;
        return (curMode, propMode) switch
        {
            (WebListMode.BlockAll, _) or (WebListMode.AllowListed, WebListMode.BlockListed) => true,
            (WebListMode.AllowListed, _) => proposed.Count == 0 || !proposed.All(current.Contains),
            (WebListMode.BlockListed, WebListMode.BlockListed) => !current.All(proposed.Contains),
            (WebListMode.BlockListed, _) => proposed.Count == 0 || proposed.Any(a => current.Any(c => DomainEntriesOverlap(a, c))),
            _ => false
        };
    }

    public static bool AppListOpens(AppListMode curMode, HashSet<string> current, AppListMode propMode, HashSet<string> proposed)
    {
        if (current.Count == 0) return false;
        return (curMode, propMode) switch
        {
            (AppListMode.AllowListed, AppListMode.BlockListed) => true,
            (AppListMode.AllowListed, AppListMode.AllowListed) => proposed.Count == 0 || !proposed.IsSubsetOf(current),
            (AppListMode.BlockListed, AppListMode.BlockListed) => !current.IsSubsetOf(proposed),
            (AppListMode.BlockListed, AppListMode.AllowListed) => proposed.Count == 0 || current.Overlaps(proposed),
            _ => false
        };
    }

    public static bool WebAllowed(string host, string path, string list, WebListMode mode)
    {
        if (mode == WebListMode.BlockAll) return false;
        var parsed = ParseDomains(list).Valid;
        if (parsed.Count == 0) return true;
        var hit = parsed.Any(e => EntryMatches(host, path, e));
        return mode == WebListMode.AllowListed ? hit : !hit;
    }

    public static string CleanAppId(string raw) =>
        (raw ?? "").Trim().Replace(".exe", "", StringComparison.OrdinalIgnoreCase).ToLowerInvariant();

    public static bool AppAllowed(string processName, IReadOnlyCollection<AllowedApp> apps, AppListMode mode)
    {
        var clean = CleanAppId(processName);
        if (SystemExemptProcesses.Contains(clean)) return true;
        var inList = apps.Any(a =>
        {
            var id = CleanAppId(a.Id);
            if (string.IsNullOrEmpty(id)) return false;
            // The same program, or the same name followed by a separator («chrome» and «chrome_proxy»); never a plain
            // «contains»: «code» used to let through «codeblocks».
            return string.Equals(id, clean, StringComparison.OrdinalIgnoreCase) ||
                   (clean.Length > id.Length && clean.StartsWith(id, StringComparison.OrdinalIgnoreCase) &&
                    clean[id.Length] is '.' or '-' or '_' or ' ');
        });
        return mode == AppListMode.AllowListed ? inList : !inList;
    }

    /// <summary>Lower-cased and without accents («Vídeo» and «video» are the same word).</summary>
    public static string Fold(string text)
    {
        var decomposed = (text ?? "").Normalize(System.Text.NormalizationForm.FormD);
        var sb = new System.Text.StringBuilder(decomposed.Length);
        foreach (var ch in decomposed)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) != UnicodeCategory.NonSpacingMark) sb.Append(ch);
        }
        return sb.ToString().Normalize(System.Text.NormalizationForm.FormC).ToLowerInvariant();
    }

    public static List<string> ParseTitleKeywords(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return new();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (var part in raw.Split(new[] { ',', ';', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var t = part.Trim();
            if (!string.IsNullOrEmpty(t) && seen.Add(Fold(t))) result.Add(t);
        }
        return result;
    }

    public static string NormalizeTitleKeywords(string raw) => string.Join(", ", ParseTitleKeywords(raw));

    public static string? MatchesTitleKeyword(string? title, string keywords, bool wholeWord = false)
    {
        if (string.IsNullOrWhiteSpace(title)) return null;
        var list = ParseTitleKeywords(keywords);
        if (list.Count == 0) return null;
        foreach (var kw in list)
        {
            if (kw.Length > 2 && kw.StartsWith('/') && kw.EndsWith('/'))
            {
                try
                {
                    if (Regex.IsMatch(title, kw[1..^1], RegexOptions.IgnoreCase, RegexTimeout)) return kw;
                }
                catch { }
                continue;
            }
            var foldedTitle = Fold(title);
            var foldedKw = Fold(kw);
            if (foldedKw.Length == 0) continue;
            if (foldedKw.Contains('*') || foldedKw.Contains('?'))
            {
                try
                {
                    if (Regex.IsMatch(foldedTitle, WildcardRegexPattern(foldedKw, anchored: false), RegexOptions.IgnoreCase, RegexTimeout)) return kw;
                }
                catch { }
                continue;
            }
            if (wholeWord)
            {
                // Whole word: not glued to a letter, digit or underscore on either side (also for words like «C++»).
                var pattern = @"(?:^|[^\p{L}\p{N}_])" + Regex.Escape(foldedKw) + @"(?:$|[^\p{L}\p{N}_])";
                try
                {
                    if (Regex.IsMatch(foldedTitle, pattern, RegexOptions.IgnoreCase, RegexTimeout)) return kw;
                }
                catch { }
            }
            else if (foldedTitle.Contains(foldedKw, StringComparison.Ordinal))
            {
                return kw;
            }
        }
        return null;
    }

    public static bool IsTaskInRunUp(FocusTask task, int runUpMinutes, DateTimeOffset now)
    {
        var lead = Math.Clamp(runUpMinutes, 0, 120);
        if (lead <= 0 || task.Protection == SessionProtection.None || !task.IsScheduled || task.Completed) return false;
        var from = task.ScheduledAt.AddMinutes(-lead);
        return task.End > from && now >= from && now < task.End;
    }

    public static string? TaskLoosening(FocusTask current, FocusTask? proposed, DateTimeOffset now, bool isRunningSession = false)
    {
        if (proposed == null) return $"borrar «{current.Title}»";
        if (isRunningSession && proposed.Minutes < current.Minutes) return $"acortar «{current.Title}» mientras está en marcha";
        if (!isRunningSession)
        {
            if (!proposed.IsScheduled && current.IsScheduled) return $"pasar a la bandeja «{current.Title}»";
            if (proposed.Completed && !current.Completed) return $"marcar como completada «{current.Title}» sin hacerla";
            if (proposed.ScheduledAt > current.ScheduledAt.AddSeconds(30)) return $"retrasar «{current.Title}»";
            if (proposed.ScheduledAt < current.ScheduledAt.AddSeconds(-30) &&
                (proposed.End <= now || proposed.ScheduledAt < now.AddMinutes(-5)))
                return $"sacar de su hora «{current.Title}»";
            if (current.AutoStart && !proposed.AutoStart) return $"quitar el inicio automático de «{current.Title}»";
            if (proposed.Minutes < current.Minutes) return $"acortar «{current.Title}»";
        }
        if (proposed.Protection.Strength() < current.Protection.Strength()) return $"rebajar la protección de «{current.Title}»";
        if (proposed.UnlockChars < current.UnlockChars) return $"acortar el código de «{current.Title}»";
        if (proposed.StopDelayMinutes < current.StopDelayMinutes) return $"acortar la espera de «{current.Title}»";
        if (current.Strict && !proposed.Strict) return $"quitar el bloqueo de apps en «{current.Title}»";
        if (proposed.BlockAction.Strength() < current.BlockAction.Strength()) return $"suavizar el cierre de apps en «{current.Title}»";
        if (proposed.WebBlockAction.Strength() < current.WebBlockAction.Strength()) return $"suavizar el bloqueo web en «{current.Title}»";
        if (current.Strict && AppListOpens(
                current.AppListMode, current.Apps.Select(a => CleanAppId(a.Id)).Where(x => !string.IsNullOrEmpty(x)).ToHashSet(),
                proposed.AppListMode, proposed.Apps.Select(a => CleanAppId(a.Id)).Where(x => !string.IsNullOrEmpty(x)).ToHashSet()))
            return $"suavizar la lista de apps en «{current.Title}»";
        if (current.WebBlockAction != WebBlockAction.Warn)
        {
            if (WebListOpens(current.WebListMode, ParseDomains(current.Domains).Valid, proposed.WebListMode, ParseDomains(proposed.Domains).Valid))
                return $"suavizar las webs bloqueadas en «{current.Title}»";
            if (current.BlockSearchMedia && !proposed.BlockSearchMedia)
                return $"quitar el bloqueo de imágenes/vídeos en buscadores en «{current.Title}»";
        }
        var curKw = ParseTitleKeywords(current.BlockedTitleKeywords).Select(k => k.ToLowerInvariant()).ToHashSet();
        var nextKw = ParseTitleKeywords(proposed.BlockedTitleKeywords).Select(k => k.ToLowerInvariant()).ToHashSet();
        if (!curKw.IsSubsetOf(nextKw)) return $"quitar palabras bloqueadas en «{current.Title}»";
        if (curKw.Count > 0 && !current.WholeWordKeywords && proposed.WholeWordKeywords)
            return $"suavizar palabras bloqueadas en «{current.Title}»";
        if (current.BlockGameLibraries && !proposed.BlockGameLibraries) return $"quitar el bloqueo de juegos en «{current.Title}»";
        if (current.GuardSystemPanes && !proposed.GuardSystemPanes) return $"quitar protección de ajustes en «{current.Title}»";
        if (current.PunisherEnabled && !proposed.PunisherEnabled) return $"quitar endurecimiento en «{current.Title}»";
        var curFolders = current.BlockedFolders.Select(f => f.Trim().TrimEnd('\\', '/').ToLowerInvariant()).ToHashSet();
        var nextFolders = proposed.BlockedFolders.Select(f => f.Trim().TrimEnd('\\', '/').ToLowerInvariant()).ToHashSet();
        if (!curFolders.IsSubsetOf(nextFolders)) return $"desbloquear carpetas en «{current.Title}»";
        return null;
    }

    public static bool Overlaps(FocusTask a, FocusTask b) =>
        a.Id != b.Id && !a.Completed && !b.Completed && a.IsScheduled && b.IsScheduled &&
        a.ScheduledAt < b.End && b.ScheduledAt < a.End;

    public static FocusTask? NextSuggestedTask(IEnumerable<FocusTask> tasks, Guid? sessionTaskId, DateTimeOffset now)
    {
        var pending = tasks.Where(t => !t.Completed && t.Id != sessionTaskId).ToList();
        if (pending.Count == 0) return null;
        var scheduled = pending.Where(t => t.IsScheduled).ToList();
        var unscheduled = pending.Where(t => !t.IsScheduled).ToList();

        // 1. Imminent or recently due scheduled tasks (from 2 hours ago up to 90 minutes ahead)
        var imminent = scheduled
            .Where(t => t.ScheduledAt >= now.AddHours(-2) && t.ScheduledAt <= now.AddMinutes(90))
            .OrderBy(t => t.ScheduledAt)
            .FirstOrDefault();
        if (imminent != null) return imminent;

        // 2. Other tasks scheduled for today (future today first, then earlier today)
        var todayScheduled = scheduled.Where(t => t.ScheduledAt.LocalDateTime.Date == now.LocalDateTime.Date).ToList();
        var nextToday = todayScheduled.Where(t => t.ScheduledAt > now).OrderBy(t => t.ScheduledAt).FirstOrDefault();
        if (nextToday != null) return nextToday;
        var earlierToday = todayScheduled.OrderByDescending(t => t.ScheduledAt).FirstOrDefault();
        if (earlierToday != null) return earlierToday;

        // 3. Unscheduled tasks with a due date today or overdue
        var endOfToday = FromLocal(now.LocalDateTime.Date.AddDays(1));
        var urgent = unscheduled
            .Where(t => t.DueDate.HasValue && t.DueDate.Value < endOfToday)
            .OrderBy(t => t.DueDate)
            .FirstOrDefault();
        if (urgent != null) return urgent;

        // 4. Future scheduled tasks within the next 24 hours
        var upcoming = scheduled
            .Where(t => t.ScheduledAt > now && t.ScheduledAt <= now.AddHours(24))
            .OrderBy(t => t.ScheduledAt)
            .FirstOrDefault();
        if (upcoming != null) return upcoming;

        // 5. Fallback: earliest scheduled task or first unscheduled task
        var earliest = scheduled.OrderBy(t => t.ScheduledAt).FirstOrDefault();
        if (earliest != null) return earliest;
        return unscheduled.OrderBy(t => t.DueDate ?? DateTimeOffset.MaxValue).FirstOrDefault();
    }

}
