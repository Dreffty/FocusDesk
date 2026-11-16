using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace FocusDesk.Windows.Core;

public enum GeneralRuleKind
{
    DailyLimit,
    Schedule,
    WorkGoal,
    LaunchLimit,
    Pomodoro,
    Countdown,
    AlwaysOn
}

public static class GeneralRuleKindExtensions
{
    public static string GalleryTitle(this GeneralRuleKind k) => k switch
    {
        GeneralRuleKind.DailyLimit => "Presupuesto diario",
        GeneralRuleKind.Schedule => "Por horario",
        GeneralRuleKind.WorkGoal => "Primero el trabajo",
        GeneralRuleKind.LaunchLimit => "Límite de aperturas",
        GeneralRuleKind.Pomodoro => "Ciclo Pomodoro",
        GeneralRuleKind.Countdown => "Bloqueo rápido",
        GeneralRuleKind.AlwaysOn => "Siempre activo",
        _ => "Regla"
    };

    public static string Summary(this GeneralRuleKind k) => k switch
    {
        GeneralRuleKind.DailyLimit => "Permite X minutos por hora/día/semana; al agotarlos bloquea.",
        GeneralRuleKind.Schedule => "Bloquea en días y tramos horarios concretos.",
        GeneralRuleKind.WorkGoal => "Estudio o trabajo verificado primero; ocio o partidas después.",
        GeneralRuleKind.LaunchLimit => "Máximo N visitas cortas al día con enfriamiento entre ellas.",
        GeneralRuleKind.Pomodoro => "Alterna foco y descanso, con reinicio ante distracciones.",
        GeneralRuleKind.Countdown => "Bloqueo inmediato durante el tiempo elegido.",
        GeneralRuleKind.AlwaysOn => "Bloqueo continuo mientras la regla esté encendida.",
        _ => ""
    };
}

public enum LimitPeriodUnit
{
    Hour,
    Day,
    Week
}

public static class LimitPeriodUnitExtensions
{
    public static string Label(this LimitPeriodUnit u) => u switch
    {
        LimitPeriodUnit.Hour => "Por hora",
        LimitPeriodUnit.Day => "Al día",
        LimitPeriodUnit.Week => "A la semana",
        _ => "Al día"
    };
}

public enum PomodoroPhase
{
    Idle,
    Work,
    ShortBreak,
    LongBreak,
    WaitingForUser
}

public static class PomodoroPhaseExtensions
{
    public static bool IsBreak(this PomodoroPhase p) => p is PomodoroPhase.ShortBreak or PomodoroPhase.LongBreak;
}

public sealed class ScheduleInterval
{
    public int StartMinutes { get; set; }
    public int EndMinutes { get; set; }

    public bool IsActive(int minuteOfDay, int todayWeekday, HashSet<int> scheduleDays)
    {
        if (StartMinutes == EndMinutes) return false;
        if (StartMinutes < EndMinutes)
        {
            return scheduleDays.Contains(todayWeekday) && minuteOfDay >= StartMinutes && minuteOfDay < EndMinutes;
        }
        // Overnight window (e.g. 22:30 -> 07:30)
        if (minuteOfDay >= StartMinutes && scheduleDays.Contains(todayWeekday)) return true;
        if (minuteOfDay < EndMinutes)
        {
            var prevWeekday = todayWeekday == 1 ? 7 : todayWeekday - 1;
            return scheduleDays.Contains(prevWeekday);
        }
        return false;
    }

    public string Label => $"{StartMinutes / 60:D2}:{StartMinutes % 60:D2}–{EndMinutes / 60:D2}:{EndMinutes % 60:D2}";
}

public static class UnlockChallenge
{
    private const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";

    public static int ClampedLength(int len) => Math.Clamp(len, 8, 64);

    public static string Make(int length)
    {
        var count = ClampedLength(length);
        var chars = new char[count];
        for (var i = 0; i < count; i++)
            chars[i] = Alphabet[System.Security.Cryptography.RandomNumberGenerator.GetInt32(Alphabet.Length)];
        return new string(chars);
    }

    public static bool Matches(string typed, string expected) =>
        !string.IsNullOrEmpty(expected) && string.Equals(typed, expected, StringComparison.Ordinal);

    public static int CorrectPrefix(string typed, string expected)
    {
        var len = Math.Min(typed.Length, expected.Length);
        for (var i = 0; i < len; i++)
            if (typed[i] != expected[i]) return i;
        return len;
    }
}

public static class GameLibraryRules
{
    private static readonly string[] LauncherProcesses =
    {
        "steam", "steamwebhelper", "epicgameslauncher", "epicwebhelper", "battle.net",
        "riotclientservices", "riotclientux", "eadesktop", "upc", "ubisoftconnect",
        "galaxyclient", "playnite.desktopapp", "playnite.fullscreenapp", "robloxplayerbeta",
        "xboxpcapp", "curseforge", "prismlauncher", "multimc", "tlauncher"
    };

    private static readonly string[] LibraryFragments =
    {
        "/steamapps/common/", "/epic games/", "/riot games/", "/battle.net/",
        "/ubisoft game launcher/", "/ea games/", "/gog galaxy/games/", "/xboxgames/"
    };

    public static string? MatchesGameApp(string? processName, string? executablePath)
    {
        var proc = (processName ?? "").ToLowerInvariant().Replace(".exe", "");
        if (!string.IsNullOrEmpty(proc) && LauncherProcesses.Any(l => proc == l || proc.StartsWith(l + ".", StringComparison.Ordinal)))
            return "Lanzador de juegos";

        var path = (executablePath ?? "").ToLowerInvariant().Replace('\\', '/');
        if (!string.IsNullOrEmpty(path))
        {
            foreach (var frag in LibraryFragments)
                if (path.Contains(frag, StringComparison.Ordinal)) return "Biblioteca de juegos";
        }
        return null;
    }
}

public static class SearchMediaRules
{
    public static string? Matches(string host, string pathAndQuery)
    {
        var h = host.ToLowerInvariant().Trim('.');
        var pq = pathAndQuery.ToLowerInvariant();
        if (h.Contains("google."))
        {
            if (pq.StartsWith("/imghp", StringComparison.Ordinal)) return "Google Imágenes";
            var qIdx = pq.IndexOf('?');
            if (qIdx >= 0)
            {
                var query = pq[(qIdx + 1)..];
                var hash = query.IndexOf('#');
                if (hash >= 0) query = query[..hash];
                var pairs = query.Split('&');
                foreach (var p in pairs)
                {
                    if (p is "udm=2" or "tbm=isch") return "Google Imágenes";
                    if (p is "udm=7" or "udm=39" or "tbm=vid") return "Google Vídeos";
                }
            }
        }
        if (h.Contains("duckduckgo.com") && pq.Contains("iax=images", StringComparison.Ordinal)) return "DuckDuckGo Imágenes";
        if (h.Contains("duckduckgo.com") && pq.Contains("iax=videos", StringComparison.Ordinal)) return "DuckDuckGo Vídeos";
        if (h.Contains("bing.com") && pq.Contains("/images/search", StringComparison.Ordinal)) return "Bing Imágenes";
        if (h.Contains("bing.com") && pq.Contains("/videos/search", StringComparison.Ordinal)) return "Bing Vídeos";
        if (h.Contains("search.yahoo.com") && pq.Contains("/search/images", StringComparison.Ordinal)) return "Yahoo Imágenes";
        return null;
    }
}

public static class ClipboardGuardRules
{
    private static readonly string[] DangerousTokens =
    {
        "taskkill /im focusdesk", "taskkill /f /im focusdesk", "stop-process -name focusdesk",
        "stop-process focusdesk", "killall focusdesk", "pkill focusdesk"
    };

    public static string? Violation(string text, string domains, WebListMode webMode, WebBlockAction webAction)
    {
        var trimmed = text.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed.Length > 2048) return null;
        var lower = trimmed.ToLowerInvariant();
        foreach (var tok in DangerousTokens)
            if (lower.Contains(tok, StringComparison.Ordinal))
                return $"comando protegido («{tok}»)";

        if (webAction != WebBlockAction.Warn &&
            (lower.StartsWith("http://", StringComparison.Ordinal) || lower.StartsWith("https://", StringComparison.Ordinal)) &&
            !trimmed.Contains(' ') &&
            Uri.TryCreate(trimmed, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.Host))
        {
            if (!FocusRules.WebAllowed(uri.Host, uri.AbsolutePath, domains, webMode))
                return $"enlace bloqueado ({uri.Host})";
        }
        return null;
    }
}

public static class StudyActivityVerifier
{
    public const double MaxIdleSeconds = 300;

    private static readonly string[] BrowserProcesses =
    {
        "chrome", "brave", "msedge", "firefox", "zen", "opera", "vivaldi", "arc"
    };

    public static bool IsBrowser(string processName)
    {
        var clean = processName.ToLowerInvariant().Replace(".exe", "");
        return BrowserProcesses.Contains(clean);
    }

    public static bool IsVerifiedStudyActivity(
        double idleSeconds,
        string frontProcessName,
        string? frontExecutablePath,
        bool hasVisibleWindow,
        string? windowTitle,
        string? browserHost,
        string? browserPath,
        HashSet<string> studyApps,
        string studyWebEntries)
    {
        if (idleSeconds is < 0 or >= MaxIdleSeconds || !hasVisibleWindow) return false;
        var proc = frontProcessName.Trim().ToLowerInvariant().Replace(".exe", "");
        if (string.IsNullOrEmpty(proc)) return false;

        if (LeagueMatchRules.IsLeagueOrRiotProcess(proc, frontExecutablePath, windowTitle)) return false;
        if (ValorantMatchRules.IsValorantProcess(proc, frontExecutablePath)) return false;
        if (GameLibraryRules.MatchesGameApp(proc, frontExecutablePath) != null) return false;

        if (IsBrowser(proc))
        {
            var host = (browserHost ?? "").Trim().ToLowerInvariant();
            var path = (browserPath ?? "/").Trim();
            if (!string.IsNullOrEmpty(host))
            {
                if (path.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) return true;
                if (FocusRules.ParseDomains(studyWebEntries).Valid.Count == 0) return false;
                return FocusRules.WebAllowed(host, path, studyWebEntries, WebListMode.AllowListed);
            }
            var title = (windowTitle ?? "").Trim().ToLowerInvariant();
            return title.EndsWith(".pdf", StringComparison.Ordinal) || title.Contains(".pdf ", StringComparison.Ordinal);
        }

        return studyApps.Contains(proc);
    }
}

public sealed class GeneralBlockRule
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "Nueva regla";
    public bool Enabled { get; set; } = true;
    public GeneralRuleKind Kind { get; set; } = GeneralRuleKind.DailyLimit;
    public int DailyLimitMinutes { get; set; } = 20;
    public LimitPeriodUnit LimitPeriodUnit { get; set; } = LimitPeriodUnit.Day;
    public int GoalMinutesRequired { get; set; } = 60;
    public int GoalRewardMinutes { get; set; }
    public int MaxDailyMatches { get; set; }
    public bool DeferBlockUntilMatchEnds { get; set; }
    public int PostMatchGraceSeconds { get; set; } = 60;
    public TrustedDeadline? ActivePostMatchGraceDeadline { get; set; }
    public bool VerifyActiveStudy { get; set; }
    public bool OneMatchPerGoalBlock { get; set; }
    [JsonPropertyName("gameID")] public string? GameId { get; set; }
    public int MatchMinutes { get; set; } = 30;
    public int MatchOvertimeMinutes { get; set; } = 10;
    public TrustedDeadline? ActiveMatchDeadline { get; set; }
    public bool AlwaysProtected { get; set; }
    public int MaxDailyLaunches { get; set; } = 5;
    public int MaxLaunchDurationMinutes { get; set; } = 5;
    public int LaunchCooldownMinutes { get; set; } = 30;
    public TrustedDeadline? ActiveLaunchDeadline { get; set; }
    public TrustedDeadline? LaunchCooldownDeadline { get; set; }
    public int PomodoroWorkMinutes { get; set; } = 25;
    public int PomodoroShortBreakMinutes { get; set; } = 5;
    public int PomodoroLongBreakMinutes { get; set; } = 15;
    public int PomodoroLongBreakEvery { get; set; } = 4;
    public int PomodoroTotalCycles { get; set; } = 4;
    public bool PomodoroPenaltyReset { get; set; }
    public bool ProtectPomodoroBreaks { get; set; } = true;
    public bool PomodoroWaitForUser { get; set; } = true;
    public int PomodoroCurrentCycle { get; set; } = 1;
    public PomodoroPhase PomodoroPhase { get; set; } = PomodoroPhase.Idle;
    public TrustedDeadline? ActivePomodoroDeadline { get; set; }
    public int CountdownMinutes { get; set; } = 60;
    public TrustedDeadline? ActiveDeadline { get; set; }
    public HashSet<int> ScheduleDays { get; set; } = new() { 1, 2, 3, 4, 5, 6, 7 };
    public int StartMinutes { get; set; } = 9 * 60;
    public int EndMinutes { get; set; } = 19 * 60;
    public List<ScheduleInterval> ExtraScheduleIntervals { get; set; } = new();
    public bool BlockApps { get; set; }
    public AppListMode AppListMode { get; set; } = AppListMode.BlockListed;
    public List<AllowedApp> Apps { get; set; } = new();
    public AppBlockAction BlockAction { get; set; } = AppBlockAction.Hide;
    public bool BlockGameLibraries { get; set; }
    public WebListMode WebListMode { get; set; } = WebListMode.BlockListed;
    public string Domains { get; set; } = "";
    public WebBlockAction WebBlockAction { get; set; } = WebBlockAction.Redirect;
    public bool BlockSearchMedia { get; set; }
    public string CustomRedirectURL { get; set; } = "";
    public string MotivationalMessage { get; set; } = "";
    public string BlockedTitleKeywords { get; set; } = "";
    public bool WholeWordKeywords { get; set; } = true;
    public SimilarityProtectionLevel SimilarityProtection { get; set; } = SimilarityProtectionLevel.NearDuplicates;
    public List<string> BlockedFolders { get; set; } = new();
    public SessionProtection Protection { get; set; } = SessionProtection.Challenge;
    public int UnlockChars { get; set; } = 24;
    public int StopDelayMinutes { get; set; } = 5;
    public bool GuardSystemPanes { get; set; } = true;
    public bool PunisherEnabled { get; set; } = true;
    public int DailyMicroPausesAllowed { get; set; } = 2;
    public int MicroPauseMinutes { get; set; } = 5;
    public TrustedDeadline? ActiveMicroPauseDeadline { get; set; }
    public StopRequest? StopRequest { get; set; }
    public DistractionPunisher Punisher { get; set; } = new();

    [JsonIgnore] public bool CanBeDeleted => true;
    [JsonIgnore] public GameDefinition? Game => Kind == GeneralRuleKind.WorkGoal ? GameCatalog.Find(GameId) : null;
    [JsonIgnore] public bool UsesTimedMatches => Game is { Detection: GameMatchDetection.Timed } && MaxDailyMatches > 0;
    [JsonIgnore] public bool UsesExactValveGSI => Game is { Detection: GameMatchDetection.ExactValveGSI } && MaxDailyMatches > 0;
    [JsonIgnore] public bool UsesExactValorant => Game is { Detection: GameMatchDetection.ExactValorant } && MaxDailyMatches > 0;
    [JsonIgnore] public string MatchUnitSingular => Game?.UnitSingular ?? "partida";
    [JsonIgnore] public string MatchUnitPlural => Game?.UnitPlural ?? "partidas";

    [JsonIgnore] public double DailyBudgetSeconds => Math.Max(1, DailyLimitMinutes) * 60.0;
    [JsonIgnore] public double GoalRequiredSeconds => Math.Max(5, GoalMinutesRequired) * 60.0;
    [JsonIgnore] public bool EarnsMatchesPerGoalBlock => Kind == GeneralRuleKind.WorkGoal && OneMatchPerGoalBlock && MaxDailyMatches > 0;
    [JsonIgnore] public double TimedMatchTotalSeconds => (Math.Max(1, MatchMinutes) + Math.Max(0, MatchOvertimeMinutes)) * 60.0;

    [JsonIgnore]
    public bool HasTargets =>
        Game != null ||
        (BlockApps && Apps.Count > 0) ||
        BlockGameLibraries ||
        BlockSearchMedia ||
        (WebBlockAction != WebBlockAction.Warn && (WebListMode == WebListMode.BlockAll || FocusRules.ParseDomains(Domains).Valid.Count > 0)) ||
        FocusRules.ParseTitleKeywords(BlockedTitleKeywords).Count > 0 ||
        BlockedFolders.Count > 0;

    [JsonIgnore]
    public bool Valid =>
        !string.IsNullOrWhiteSpace(Name) &&
        (!BlockApps || Apps.Count > 0 || BlockGameLibraries) &&
        (Kind != GeneralRuleKind.Schedule || (ScheduleDays.Count > 0 && StartMinutes != EndMinutes)) &&
        HasTargets;

    public double TimedMatchRemainingSeconds(DateTimeOffset? now = null, double? continuous = null) =>
        ActiveMatchDeadline?.RemainingAfterPossibleReboot(now, continuous) ?? 0;

    public bool IsInTimedMatch(DateTimeOffset? now = null, double? continuous = null) =>
        (UsesTimedMatches || UsesExactValveGSI) && TimedMatchRemainingSeconds(now, continuous) > 0;

    public bool IsInTimedMatchOvertime(DateTimeOffset? now = null, double? continuous = null) =>
        IsInTimedMatch(now, continuous) && TimedMatchRemainingSeconds(now, continuous) <= Math.Max(0, MatchOvertimeMinutes) * 60.0;

    public double TimedMatchElapsedSeconds(DateTimeOffset? now = null, double? continuous = null) =>
        ActiveMatchDeadline == null ? 0 : Math.Max(0, TimedMatchTotalSeconds - TimedMatchRemainingSeconds(now, continuous));

    public void StartTimedMatch(DateTimeOffset? wall = null, double? continuous = null) =>
        ActiveMatchDeadline = new TrustedDeadline(TimedMatchTotalSeconds, wall, continuous);

    public void EndTimedMatch() => ActiveMatchDeadline = null;

    public int EarnedMatches(double workedTodaySeconds)
    {
        if (MaxDailyMatches <= 0 || workedTodaySeconds < GoalRequiredSeconds) return 0;
        if (!EarnsMatchesPerGoalBlock) return MaxDailyMatches;
        return Math.Min(MaxDailyMatches, (int)(workedTodaySeconds / GoalRequiredSeconds));
    }

    public double RequiredWorkSecondsForNextMatch(int matchesToday) =>
        EarnsMatchesPerGoalBlock ? GoalRequiredSeconds * Math.Max(1, matchesToday + 1) : GoalRequiredSeconds;

    public bool IsWaitingForMoreWork(double workedTodaySeconds, int matchesToday) =>
        EarnsMatchesPerGoalBlock && matchesToday < MaxDailyMatches && matchesToday >= EarnedMatches(workedTodaySeconds);

    public double? EarnedGoalBudgetSeconds(double workedTodaySeconds)
    {
        if (workedTodaySeconds < GoalRequiredSeconds) return 0;
        if (GoalRewardMinutes <= 0) return null;
        if (MaxDailyMatches > 0) return GoalRewardMinutes * 60.0;
        var blocks = Math.Max(1, (int)(workedTodaySeconds / GoalRequiredSeconds));
        return blocks * GoalRewardMinutes * 60.0;
    }

    public double RemainingGoalRewardSeconds(double workedTodaySeconds, double usedTodaySeconds)
    {
        var b = EarnedGoalBudgetSeconds(workedTodaySeconds);
        return b.HasValue ? Math.Max(0, b.Value - Math.Max(0, usedTodaySeconds)) : 0;
    }

    public double PostMatchGraceRemainingSeconds(DateTimeOffset? now = null, double? continuous = null) =>
        ActivePostMatchGraceDeadline?.RemainingAfterPossibleReboot(now, continuous) ?? 0;

    public bool IsInPostMatchGrace(DateTimeOffset? now = null, double? continuous = null) =>
        PostMatchGraceRemainingSeconds(now, continuous) > 0;

    public void StartPostMatchGrace(DateTimeOffset? wall = null, double? continuous = null) =>
        ActivePostMatchGraceDeadline = new TrustedDeadline(Math.Clamp(PostMatchGraceSeconds, 15, 300), wall, continuous);

    public bool IsMicroPaused(DateTimeOffset? now = null, double? continuous = null) =>
        (ActiveMicroPauseDeadline?.RemainingAfterPossibleReboot(now, continuous) ?? 0) > 0;

    public void StartMicroPause(DateTimeOffset? wall = null, double? continuous = null) =>
        ActiveMicroPauseDeadline = new TrustedDeadline(Math.Clamp(MicroPauseMinutes, 1, 30) * 60.0, wall, continuous);

    public double LaunchVisitRemainingSeconds(DateTimeOffset? now = null, double? continuous = null) =>
        ActiveLaunchDeadline?.RemainingAfterPossibleReboot(now, continuous) ?? 0;

    public bool IsInLaunchVisit(DateTimeOffset? now = null, double? continuous = null) => LaunchVisitRemainingSeconds(now, continuous) > 0;

    public double LaunchCooldownRemainingSeconds(DateTimeOffset? now = null, double? continuous = null)
    {
        if (LaunchCooldownDeadline == null) return 0;
        var total = LaunchCooldownDeadline.RemainingAfterPossibleReboot(now, continuous);
        return Math.Max(0, total - LaunchVisitRemainingSeconds(now, continuous));
    }

    public bool IsInLaunchCooldown(DateTimeOffset? now = null, double? continuous = null) =>
        !IsInLaunchVisit(now, continuous) && LaunchCooldownRemainingSeconds(now, continuous) > 0;

    public void BeginLaunchVisit(DateTimeOffset? wall = null, double? continuous = null)
    {
        var visitSec = Math.Max(1, MaxLaunchDurationMinutes) * 60.0;
        ActiveLaunchDeadline = new TrustedDeadline(visitSec, wall, continuous);
        LaunchCooldownDeadline = LaunchCooldownMinutes > 0
            ? new TrustedDeadline(visitSec + LaunchCooldownMinutes * 60.0, wall, continuous)
            : null;
    }

    public void EndLaunchVisitAndStartCooldown(DateTimeOffset? wall = null, double? continuous = null)
    {
        ActiveLaunchDeadline = null;
        LaunchCooldownDeadline = LaunchCooldownMinutes > 0
            ? new TrustedDeadline(LaunchCooldownMinutes * 60.0, wall, continuous)
            : null;
    }

    public bool IsScheduleActive(DateTimeOffset now)
    {
        if (ScheduleDays.Count == 0) return false;
        var local = now.LocalDateTime;
        var weekday = FocusRules.AppleWeekday(now);
        var min = local.Hour * 60 + local.Minute;
        var all = new List<ScheduleInterval> { new() { StartMinutes = StartMinutes, EndMinutes = EndMinutes } };
        all.AddRange(ExtraScheduleIntervals);
        return all.Any(i => i.IsActive(min, weekday, ScheduleDays));
    }

    public bool IsTrackingQuota(DateTimeOffset now, double usedTodaySeconds, double workedTodaySeconds = 0, int launchesToday = 0, int matchesToday = 0, bool isMatchInProgress = false, double? continuous = null)
    {
        if (!Enabled) return false;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        return Kind switch
        {
            GeneralRuleKind.DailyLimit => usedTodaySeconds < DailyBudgetSeconds,
            GeneralRuleKind.WorkGoal => IsInTimedMatch(now, cont) ||
                (workedTodaySeconds >= GoalRequiredSeconds &&
                 (IsInPostMatchGrace(now, cont) || (DeferBlockUntilMatchEnds && isMatchInProgress) ||
                  (!(MaxDailyMatches > 0 && matchesToday >= MaxDailyMatches) &&
                   !IsWaitingForMoreWork(workedTodaySeconds, matchesToday) &&
                   (EarnedGoalBudgetSeconds(workedTodaySeconds) is double b ? b > 0 && usedTodaySeconds < b : MaxDailyMatches > 0)))),
            GeneralRuleKind.LaunchLimit => IsInLaunchVisit(now, cont) || (!IsInLaunchCooldown(now, cont) && launchesToday < MaxDailyLaunches),
            _ => false
        };
    }

    public bool IsEnforcing(DateTimeOffset now, double usedTodaySeconds = 0, double workedTodaySeconds = 0, int launchesToday = 0, int matchesToday = 0, bool isMatchInProgress = false, double? continuous = null)
    {
        if (!Enabled || !HasTargets) return false;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        if (IsMicroPaused(now, cont)) return false;

        return Kind switch
        {
            GeneralRuleKind.AlwaysOn => true,
            GeneralRuleKind.Countdown => ActiveDeadline != null && ActiveDeadline.RemainingAfterPossibleReboot(now, cont) > 0,
            GeneralRuleKind.Schedule => IsScheduleActive(now),
            GeneralRuleKind.Pomodoro => PomodoroPhase == PomodoroPhase.Work &&
                (ActivePomodoroDeadline == null || ActivePomodoroDeadline.RemainingAfterPossibleReboot(now, cont) > 0),
            GeneralRuleKind.DailyLimit => usedTodaySeconds >= DailyBudgetSeconds,
            GeneralRuleKind.WorkGoal => EvaluateWorkGoalEnforcing(now, usedTodaySeconds, workedTodaySeconds, matchesToday, isMatchInProgress, cont),
            GeneralRuleKind.LaunchLimit => !IsInLaunchVisit(now, cont) && (IsInLaunchCooldown(now, cont) || launchesToday >= MaxDailyLaunches),
            _ => false
        };
    }

    private bool EvaluateWorkGoalEnforcing(DateTimeOffset now, double used, double worked, int matches, bool inMatch, double cont)
    {
        if (IsInTimedMatch(now, cont)) return false;
        if (worked < GoalRequiredSeconds) return true;
        if (IsInPostMatchGrace(now, cont)) return false;
        if (DeferBlockUntilMatchEnds && inMatch) return false;
        if (MaxDailyMatches > 0 && matches >= MaxDailyMatches) return true;
        if (IsWaitingForMoreWork(worked, matches)) return true;
        var budget = EarnedGoalBudgetSeconds(worked);
        return budget.HasValue && used >= budget.Value;
    }

    public bool IsProtectedNow(DateTimeOffset now, double usedTodaySeconds = 0, double workedTodaySeconds = 0, int launchesToday = 0, int matchesToday = 0, bool isMatchInProgress = false, int runUpMinutes = 0, double? continuous = null)
    {
        if (Protection == SessionProtection.None) return false;
        if (Enabled && AlwaysProtected) return true;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        if (IsInRunUp(now, usedTodaySeconds, workedTodaySeconds, isMatchInProgress, runUpMinutes)) return true;
        if (IsEnforcing(now, usedTodaySeconds, workedTodaySeconds, launchesToday, matchesToday, isMatchInProgress, cont)) return true;
        if (Kind == GeneralRuleKind.Pomodoro && Enabled && ProtectPomodoroBreaks && PomodoroPhase != PomodoroPhase.Idle) return true;
        return false;
    }

    public bool IsInRunUp(DateTimeOffset now, double usedTodaySeconds, double workedTodaySeconds, bool isMatchInProgress, int minutes)
    {
        var lead = Math.Clamp(minutes, 0, 60);
        if (lead <= 0 || !Enabled || !HasTargets || Protection == SessionProtection.None) return false;
        var leadSec = lead * 60.0;
        return Kind switch
        {
            GeneralRuleKind.Schedule => Enumerable.Range(0, lead + 1).Any(m => IsScheduleActive(now.AddMinutes(m))),
            GeneralRuleKind.DailyLimit => usedTodaySeconds >= DailyBudgetSeconds - leadSec,
            GeneralRuleKind.WorkGoal => workedTodaySeconds >= GoalRequiredSeconds && !isMatchInProgress &&
                EarnedGoalBudgetSeconds(workedTodaySeconds) != null &&
                RemainingGoalRewardSeconds(workedTodaySeconds, usedTodaySeconds) <= leadSec,
            _ => false
        };
    }

    public double RemainingLockSeconds(DateTimeOffset now, double usedTodaySeconds = 0, double workedTodaySeconds = 0, int launchesToday = 0, int matchesToday = 0, bool isMatchInProgress = false, double? continuous = null)
    {
        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        if (!IsEnforcing(now, usedTodaySeconds, workedTodaySeconds, launchesToday, matchesToday, isMatchInProgress, cont) &&
            !(Kind == GeneralRuleKind.Pomodoro && Enabled && ProtectPomodoroBreaks && PomodoroPhase != PomodoroPhase.Idle) &&
            !(Enabled && AlwaysProtected && Protection != SessionProtection.None))
        {
            return 0;
        }
        return Kind switch
        {
            GeneralRuleKind.Countdown => ActiveDeadline?.RemainingAfterPossibleReboot(now, cont) ?? 0,
            GeneralRuleKind.Pomodoro => ActivePomodoroDeadline?.RemainingAfterPossibleReboot(now, cont) ?? Math.Max(1, PomodoroWorkMinutes) * 60.0,
            GeneralRuleKind.LaunchLimit when LaunchCooldownRemainingSeconds(now, cont) > 0 && launchesToday < MaxDailyLaunches => LaunchCooldownRemainingSeconds(now, cont),
            _ => Math.Max(60, (now.LocalDateTime.Date.AddDays(1) - now.LocalDateTime).TotalSeconds)
        };
    }

    public void StartCountdown(int? minutes = null, DateTimeOffset? wall = null)
    {
        var chosen = Math.Clamp(minutes ?? CountdownMinutes, 1, 1440);
        if (minutes.HasValue) CountdownMinutes = Math.Clamp(chosen, 5, 720);
        Kind = GeneralRuleKind.Countdown;
        Enabled = true;
        StopRequest = null;
        ActiveMicroPauseDeadline = null;
        ActiveDeadline = new TrustedDeadline(chosen * 60.0, wall);
    }

    public void StartPomodoro(DateTimeOffset? wall = null)
    {
        Kind = GeneralRuleKind.Pomodoro;
        Enabled = true;
        StopRequest = null;
        ActiveMicroPauseDeadline = null;
        PomodoroCurrentCycle = 1;
        PomodoroPhase = PomodoroPhase.Work;
        ActivePomodoroDeadline = new TrustedDeadline(Math.Max(5, PomodoroWorkMinutes) * 60.0, wall);
    }

    public string AdvancePomodoroPhase(bool userIdle, DateTimeOffset? wall = null)
    {
        switch (PomodoroPhase)
        {
            case PomodoroPhase.Idle:
                StartPomodoro(wall);
                return $"Pomodoro 1/{PomodoroTotalCycles} en marcha ({PomodoroWorkMinutes} min).";
            case PomodoroPhase.Work:
                if (PomodoroCurrentCycle >= PomodoroTotalCycles)
                {
                    PomodoroPhase = PomodoroPhase.Idle;
                    ActivePomodoroDeadline = null;
                    Enabled = false;
                    return $"¡Tanda de {PomodoroTotalCycles} Pomodoros completada en «{Name}»!";
                }
                var isLong = PomodoroCurrentCycle % Math.Max(2, PomodoroLongBreakEvery) == 0;
                PomodoroPhase = isLong ? PomodoroPhase.LongBreak : PomodoroPhase.ShortBreak;
                var bm = isLong ? PomodoroLongBreakMinutes : PomodoroShortBreakMinutes;
                ActivePomodoroDeadline = new TrustedDeadline(Math.Max(1, bm) * 60.0, wall);
                return $"Pomodoro {PomodoroCurrentCycle}/{PomodoroTotalCycles} completado. Descanso de {bm} min.";
            case PomodoroPhase.ShortBreak:
            case PomodoroPhase.LongBreak:
                if (PomodoroWaitForUser && userIdle)
                {
                    PomodoroPhase = PomodoroPhase.WaitingForUser;
                    ActivePomodoroDeadline = null;
                    return $"Descanso terminado en «{Name}»: mueve el ratón para iniciar el siguiente bloque.";
                }
                PomodoroCurrentCycle = Math.Min(PomodoroTotalCycles, PomodoroCurrentCycle + 1);
                PomodoroPhase = PomodoroPhase.Work;
                ActivePomodoroDeadline = new TrustedDeadline(Math.Max(5, PomodoroWorkMinutes) * 60.0, wall);
                return $"Empieza el Pomodoro {PomodoroCurrentCycle}/{PomodoroTotalCycles}.";
            case PomodoroPhase.WaitingForUser:
                PomodoroCurrentCycle = Math.Min(PomodoroTotalCycles, PomodoroCurrentCycle + 1);
                PomodoroPhase = PomodoroPhase.Work;
                ActivePomodoroDeadline = new TrustedDeadline(Math.Max(5, PomodoroWorkMinutes) * 60.0, wall);
                return $"Empieza el Pomodoro {PomodoroCurrentCycle}/{PomodoroTotalCycles}.";
            default:
                return "";
        }
    }

    public bool ApplyPomodoroPenaltyIfNeeded(DateTimeOffset? wall = null)
    {
        if (Kind != GeneralRuleKind.Pomodoro || PomodoroPhase != PomodoroPhase.Work || !PomodoroPenaltyReset) return false;
        ActivePomodoroDeadline = new TrustedDeadline(Math.Max(5, PomodoroWorkMinutes) * 60.0, wall);
        return true;
    }

    public bool RegisterBlock() => PunisherEnabled && Punisher.Register();

    public AppBlockAction ActiveBlockAction() =>
        PunisherEnabled && Punisher.IsActive() ? BlockAction.Escalated() : BlockAction;

    public GeneralBlockRule Clone()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(this, WorkspaceStore.JsonOptions);
        return System.Text.Json.JsonSerializer.Deserialize<GeneralBlockRule>(json, WorkspaceStore.JsonOptions)!;
    }

    public static string? Loosening(GeneralBlockRule current, GeneralBlockRule? proposed, DateTimeOffset? now = null)
    {
        if (proposed == null) return $"borrar la regla «{current.Name}»";
        if (current.Enabled && !proposed.Enabled) return $"desactivar la regla «{current.Name}»";
        if (proposed.Protection.Strength() < current.Protection.Strength()) return $"rebajar la protección de «{current.Name}»";
        if (proposed.UnlockChars < current.UnlockChars) return $"acortar el código de «{current.Name}»";
        if (proposed.StopDelayMinutes < current.StopDelayMinutes) return $"acortar la espera de «{current.Name}»";
        if (proposed.Kind != current.Kind) return $"cambiar el modo de activación de «{current.Name}»";
        if (current.AlwaysProtected && !proposed.AlwaysProtected) return $"quitar la protección 24/7 de «{current.Name}»";

        if (current.Kind == GeneralRuleKind.DailyLimit)
        {
            if (proposed.DailyLimitMinutes > current.DailyLimitMinutes) return $"ampliar el presupuesto de «{current.Name}»";
            if (proposed.LimitPeriodUnit != current.LimitPeriodUnit) return $"cambiar el periodo del presupuesto de «{current.Name}»";
        }
        if (current.Kind == GeneralRuleKind.WorkGoal)
        {
            if (proposed.GoalMinutesRequired < current.GoalMinutesRequired) return $"rebajar la meta de «{current.Name}»";
            if (current.GoalRewardMinutes > 0 && (proposed.GoalRewardMinutes == 0 || proposed.GoalRewardMinutes > current.GoalRewardMinutes))
                return $"ampliar la recompensa de «{current.Name}»";
            if (current.MaxDailyMatches > 0 && (proposed.MaxDailyMatches == 0 || proposed.MaxDailyMatches > current.MaxDailyMatches))
                return $"ampliar el límite de partidas de «{current.Name}»";
            if (current.GameId != null && proposed.GameId != current.GameId) return $"cambiar el juego de «{current.Name}»";
            if (current.UsesTimedMatches && (proposed.MatchMinutes > current.MatchMinutes || proposed.MatchOvertimeMinutes > current.MatchOvertimeMinutes))
                return $"alargar la partida o prórroga de «{current.Name}»";
            if (current.OneMatchPerGoalBlock && !proposed.OneMatchPerGoalBlock)
                return $"dejar de exigir una hora de estudio por partida en «{current.Name}»";
            if (current.VerifyActiveStudy && !proposed.VerifyActiveStudy)
                return $"desactivar el estudio verificado en «{current.Name}»";
            if (proposed.PostMatchGraceSeconds > current.PostMatchGraceSeconds)
                return $"alargar el margen tras partida en «{current.Name}»";
        }
        if (current.Kind == GeneralRuleKind.LaunchLimit)
        {
            if (proposed.MaxDailyLaunches > current.MaxDailyLaunches) return $"aumentar el límite de aperturas de «{current.Name}»";
            if (proposed.MaxLaunchDurationMinutes > current.MaxLaunchDurationMinutes) return $"alargar la duración por visita de «{current.Name}»";
            if (proposed.LaunchCooldownMinutes < current.LaunchCooldownMinutes) return $"acortar el enfriamiento entre visitas de «{current.Name}»";
        }
        if (current.Kind == GeneralRuleKind.Pomodoro)
        {
            if (proposed.PomodoroWorkMinutes < current.PomodoroWorkMinutes) return $"acortar el bloque de enfoque Pomodoro de «{current.Name}»";
            if (proposed.PomodoroShortBreakMinutes > current.PomodoroShortBreakMinutes || proposed.PomodoroLongBreakMinutes > current.PomodoroLongBreakMinutes)
                return $"alargar los descansos Pomodoro de «{current.Name}»";
            if (current.PomodoroPenaltyReset && !proposed.PomodoroPenaltyReset) return $"quitar la penalización Pomodoro de «{current.Name}»";
            if (current.ProtectPomodoroBreaks && !proposed.ProtectPomodoroBreaks) return $"quitar la protección en descansos Pomodoro de «{current.Name}»";
        }
        if (proposed.DailyMicroPausesAllowed > current.DailyMicroPausesAllowed || proposed.MicroPauseMinutes > current.MicroPauseMinutes)
            return $"aumentar las micro-pausas de «{current.Name}»";
        if (current.Kind == GeneralRuleKind.Countdown && current.ActiveDeadline != null)
        {
            var curRem = current.ActiveDeadline.RemainingAfterPossibleReboot(now);
            var propRem = proposed.ActiveDeadline?.RemainingAfterPossibleReboot(now) ?? 0;
            if (propRem + 5 < curRem) return $"acortar el temporizador activo de «{current.Name}»";
        }
        if (current.Kind == GeneralRuleKind.Schedule)
        {
            var intervalsEqual = current.ExtraScheduleIntervals.Count == proposed.ExtraScheduleIntervals.Count &&
                                 current.ExtraScheduleIntervals.Zip(proposed.ExtraScheduleIntervals)
                                     .All(p => p.First.StartMinutes == p.Second.StartMinutes && p.First.EndMinutes == p.Second.EndMinutes);
            if (!current.ScheduleDays.SetEquals(proposed.ScheduleDays) ||
                current.StartMinutes != proposed.StartMinutes ||
                current.EndMinutes != proposed.EndMinutes ||
                !intervalsEqual)
                return $"cambiar el horario de «{current.Name}»";
        }
        if (current.BlockApps && !proposed.BlockApps) return $"quitar el bloqueo de apps en «{current.Name}»";
        if (current.BlockApps && FocusRules.AppListOpens(
                current.AppListMode, current.Apps.Select(a => a.Id.ToLowerInvariant()).ToHashSet(),
                proposed.AppListMode, proposed.Apps.Select(a => a.Id.ToLowerInvariant()).ToHashSet()))
            return $"suavizar la lista de apps de «{current.Name}»";
        if (current.BlockGameLibraries && !proposed.BlockGameLibraries)
            return $"quitar el bloqueo de bibliotecas de juegos en «{current.Name}»";
        if (proposed.BlockAction.Strength() < current.BlockAction.Strength())
            return $"suavizar el cierre de apps en «{current.Name}»";
        if (proposed.WebBlockAction.Strength() < current.WebBlockAction.Strength())
            return $"suavizar el bloqueo web en «{current.Name}»";
        if (current.WebBlockAction != WebBlockAction.Warn)
        {
            if (FocusRules.WebListOpens(
                    current.WebListMode, FocusRules.ParseDomains(current.Domains).Valid,
                    proposed.WebListMode, FocusRules.ParseDomains(proposed.Domains).Valid))
                return $"suavizar la lista de webs de «{current.Name}»";
            if (current.BlockSearchMedia && !proposed.BlockSearchMedia)
                return $"quitar el bloqueo de imágenes/vídeos en buscadores de «{current.Name}»";
        }
        var curKw = FocusRules.ParseTitleKeywords(current.BlockedTitleKeywords).Select(k => k.ToLowerInvariant()).ToHashSet();
        var nextKw = FocusRules.ParseTitleKeywords(proposed.BlockedTitleKeywords).Select(k => k.ToLowerInvariant()).ToHashSet();
        if (!curKw.IsSubsetOf(nextKw)) return $"quitar palabras bloqueadas en «{current.Name}»";
        if (curKw.Count > 0 && !current.WholeWordKeywords && proposed.WholeWordKeywords)
            return $"suavizar las palabras bloqueadas en «{current.Name}»";
        var curFolders = current.BlockedFolders.Select(f => f.Trim().TrimEnd('\\', '/').ToLowerInvariant()).ToHashSet();
        var nextFolders = proposed.BlockedFolders.Select(f => f.Trim().TrimEnd('\\', '/').ToLowerInvariant()).ToHashSet();
        if (!curFolders.IsSubsetOf(nextFolders)) return $"desbloquear carpetas en «{current.Name}»";
        if (current.GuardSystemPanes && !proposed.GuardSystemPanes)
            return $"quitar la protección de ajustes del sistema en «{current.Name}»";
        if (current.PunisherEnabled && !proposed.PunisherEnabled)
            return $"quitar el endurecimiento por reincidencia en «{current.Name}»";
        return null;
    }

    public static GeneralBlockRule GameTemplate(GameDefinition game)
    {
        var rule = new GeneralBlockRule
        {
            Name = $"1 h de estudio por {game.UnitSingular} de {game.Name} · máx. 2 al día",
            Kind = GeneralRuleKind.WorkGoal,
            GoalMinutesRequired = 60,
            GoalRewardMinutes = 0,
            MaxDailyMatches = 2,
            DeferBlockUntilMatchEnds = true,
            PostMatchGraceSeconds = 60,
            VerifyActiveStudy = true,
            OneMatchPerGoalBlock = true,
            BlockAction = AppBlockAction.ForceQuit,
            WebListMode = WebListMode.BlockListed,
            WebBlockAction = WebBlockAction.Redirect,
            MotivationalMessage = $"Cada {game.UnitSingular} de {game.Name} se gana con 60 min de estudio real.",
            Protection = SessionProtection.Challenge
        };
        rule.ApplyGame(game);
        return rule;
    }

    public void ApplyGame(GameDefinition game)
    {
        GameId = game.Id;
        MatchMinutes = game.TypicalMatchMinutes;
        if (MaxDailyMatches == 0) MaxDailyMatches = 2;
        DeferBlockUntilMatchEnds = true;
        if (game.Detection == GameMatchDetection.ExactLeague)
        {
            BlockApps = true;
            AppListMode = AppListMode.BlockListed;
            Apps = new List<AllowedApp>
            {
                new("LeagueClientUx", "League of Legends (Cliente)", ""),
                new("League of Legends", "League of Legends (Partida)", ""),
                new("RiotClientServices", "Riot Client", "")
            };
        }
        else if (game.Detection == GameMatchDetection.ExactValorant)
        {
            BlockApps = true;
            AppListMode = AppListMode.BlockListed;
            Apps = new List<AllowedApp>
            {
                new("VALORANT-Win64-Shipping", "Valorant", ""),
                new("VALORANT", "Valorant", ""),
                new("RiotClientServices", "Riot Client", "")
            };
        }
        if (game.WebEntries.Length > 0)
        {
            WebListMode = WebListMode.BlockListed;
            Domains = string.Join(", ", game.WebEntries);
        }
    }

    public static List<GeneralBlockRule> Defaults() => new()
    {
        new()
        {
            Id = Guid.Parse("22222222-2222-2222-2222-222222222201"),
            Name = "Redes y vídeos cortos · 20 min al día",
            Enabled = false,
            Kind = GeneralRuleKind.DailyLimit,
            DailyLimitMinutes = 20,
            Domains = "youtube.com/shorts, instagram.com, tiktok.com, x.com, reddit.com",
            BlockedTitleKeywords = "Shorts, Reels, TikTok",
            MotivationalMessage = "Tu atención vale más que el scroll infinito.",
            Protection = SessionProtection.Challenge
        },
        new()
        {
            Id = Guid.Parse("22222222-2222-2222-2222-222222222202"),
            Name = "Noche sin pantallas de ocio",
            Enabled = false,
            Kind = GeneralRuleKind.Schedule,
            StartMinutes = 22 * 60 + 30,
            EndMinutes = 7 * 60 + 30,
            Domains = "youtube.com, netflix.com, twitch.tv, x.com, instagram.com, tiktok.com",
            MotivationalMessage = "Hora de descansar: mañana rendirás el doble.",
            Protection = SessionProtection.Delay
        },
        new()
        {
            Id = Guid.Parse("22222222-2222-2222-2222-222222222203"),
            Name = "Primero 60 min de enfoque · luego ocio",
            Enabled = false,
            Kind = GeneralRuleKind.WorkGoal,
            GoalMinutesRequired = 60,
            GoalRewardMinutes = 30,
            Domains = "youtube.com, reddit.com, twitch.tv, x.com",
            MotivationalMessage = "Completa primero tu bloque de enfoque de hoy.",
            Protection = SessionProtection.Challenge
        },
        new()
        {
            Id = Guid.Parse("22222222-2222-2222-2222-222222222205"),
            Name = "Pomodoro estricto 25/5 · sin juegos ni vídeos",
            Enabled = false,
            Kind = GeneralRuleKind.Pomodoro,
            PomodoroPenaltyReset = true,
            BlockGameLibraries = true,
            BlockSearchMedia = true,
            Domains = "youtube.com, twitch.tv, x.com, reddit.com, tiktok.com",
            MotivationalMessage = "Ciclo Pomodoro activo: si abres una distracción, se reinicia.",
            Protection = SessionProtection.Challenge
        }
    };
}

public static class BlockPageGenerator
{
    public static string Write(string title, string host, double remainingSeconds, string message, IEnumerable<string> pendingSteps, string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "bloqueada.html");
        var timeText = FocusRules.Clock(Math.Max(0, remainingSeconds));
        var stepsHtml = string.Join("", pendingSteps.Take(5).Select(s => $"<li>{System.Net.WebUtility.HtmlEncode(s)}</li>"));
        var stepsSection = string.IsNullOrEmpty(stepsHtml)
            ? ""
            : $"<div class='steps'><div class='steps-title'>Siguientes pasos pendientes</div><ul>{stepsHtml}</ul></div>";
        var msgHtml = string.IsNullOrWhiteSpace(message)
            ? ""
            : $"<blockquote class='msg'>«{System.Net.WebUtility.HtmlEncode(message)}»</blockquote>";
        var initialLeft = (int)Math.Max(0, remainingSeconds);
        var html = $$"""
            <!doctype html>
            <html lang="es">
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <meta name="color-scheme" content="dark">
              <title>Ahora no · FocusDesk</title>
              <style>
                :root {
                  color-scheme: dark;
                  --bg: #0B0E14;
                  --card: #131822;
                  --elevated: #1B2230;
                  --line: #242E40;
                  --ink: #F2F5FA;
                  --muted: #94A3B8;
                  --mint: #64E3A1;
                }
                * { box-sizing: border-box; }
                body {
                  margin: 0;
                  min-height: 100vh;
                  display: grid;
                  place-items: center;
                  padding: 24px;
                  background: var(--bg);
                  color: var(--ink);
                  font-family: "Segoe UI Variable", "Segoe UI", system-ui, sans-serif;
                }
                @keyframes cardIn {
                  from { opacity: 0; transform: scale(0.96); }
                  to { opacity: 1; transform: scale(1); }
                }
                .card {
                  width: min(540px, 100%);
                  background: var(--card);
                  border: 1px solid var(--line);
                  border-radius: 18px;
                  padding: 36px 34px;
                  text-align: center;
                  box-shadow: 0 24px 64px rgba(0, 0, 0, 0.45);
                  animation: cardIn 180ms cubic-bezier(0.16, 1, 0.3, 1);
                }
                @media (prefers-reduced-motion: reduce) {
                  .card { animation: none; }
                }
                .badge {
                  display: inline-flex;
                  align-items: center;
                  gap: 6px;
                  background: rgba(100, 227, 161, 0.14);
                  color: var(--mint);
                  border: 1px solid rgba(100, 227, 161, 0.25);
                  padding: 5px 12px;
                  border-radius: 999px;
                  font-size: 11px;
                  font-weight: 700;
                  letter-spacing: 0.06em;
                  text-transform: uppercase;
                }
                h1 { margin: 18px 0 8px; font-size: 24px; letter-spacing: -0.02em; }
                .host { color: var(--muted); font-size: 14px; line-height: 1.5; margin: 0 0 18px; }
                .host-chip {
                  font-family: "Cascadia Mono", Consolas, monospace;
                  color: var(--ink);
                  background: var(--elevated);
                  padding: 2px 7px;
                  border-radius: 6px;
                  border: 1px solid var(--line);
                }
                .timer {
                  font-family: "Cascadia Mono", Consolas, monospace;
                  font-size: 44px;
                  font-weight: 700;
                  color: var(--mint);
                  font-variant-numeric: tabular-nums;
                  margin: 18px 0 4px;
                }
                .timer-label {
                  font-size: 10px;
                  letter-spacing: 0.14em;
                  text-transform: uppercase;
                  color: var(--muted);
                  margin-bottom: 12px;
                }
                .msg {
                  margin: 16px 0 0;
                  padding: 12px 16px;
                  border-radius: 12px;
                  background: rgba(100, 227, 161, 0.08);
                  border: 1px solid rgba(100, 227, 161, 0.18);
                  color: var(--ink);
                  font-style: italic;
                  font-size: 14px;
                  line-height: 1.5;
                }
                .steps {
                  margin-top: 20px;
                  padding: 14px 18px;
                  border-radius: 12px;
                  background: var(--elevated);
                  border: 1px solid var(--line);
                  text-align: left;
                }
                .steps-title {
                  font-size: 10px;
                  font-weight: 700;
                  letter-spacing: 0.12em;
                  text-transform: uppercase;
                  color: var(--muted);
                  margin-bottom: 8px;
                }
                .steps ul { margin: 0; padding-left: 18px; color: var(--ink); font-size: 13px; }
                .steps li { margin: 4px 0; line-height: 1.45; }
              </style>
            </head>
            <body>
              <main class="card">
                <span class="badge">FocusDesk</span>
                <h1>{{System.Net.WebUtility.HtmlEncode(title)}}</h1>
                <p class="host"><span class="host-chip">{{System.Net.WebUtility.HtmlEncode(host)}}</span> está bloqueado ahora</p>
                <div class="timer" id="clock">{{timeText}}</div>
                <div class="timer-label">tiempo restante</div>
                {{msgHtml}}
                {{stepsSection}}
              </main>
              <script>
                let left = {{initialLeft}};
                const node = document.getElementById("clock");
                setInterval(() => {
                  if (left <= 0) { node.textContent = "00:00"; return; }
                  left -= 1;
                  const h = Math.floor(left / 3600), m = Math.floor(left / 60) % 60, s = left % 60;
                  const pad = (n) => String(n).padStart(2, "0");
                  node.textContent = h > 0 ? h + ":" + pad(m) + ":" + pad(s) : pad(m) + ":" + pad(s);
                }, 1000);
              </script>
            </body>
            </html>
            """;
        File.WriteAllText(path, html);
        return new Uri(path).AbsoluteUri;
    }
}
