using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace FocusDesk.Windows.Core;

public enum GameMatchDetection
{
    ExactLeague,
    ExactValorant,
    ExactValveGSI,
    Timed
}

public static class GameMatchDetectionExtensions
{
    public static bool IsExact(this GameMatchDetection d) =>
        d is GameMatchDetection.ExactLeague or GameMatchDetection.ExactValorant or GameMatchDetection.ExactValveGSI;

    public static string Label(this GameMatchDetection d) => d switch
    {
        GameMatchDetection.ExactLeague => "Detección exacta",
        GameMatchDetection.ExactValorant => "Detección exacta (Valorant)",
        GameMatchDetection.ExactValveGSI => "Detección exacta (Valve)",
        GameMatchDetection.Timed => "Por tiempo con prórroga",
        _ => "Por tiempo con prórroga"
    };

    public static string Explanation(this GameMatchDetection d) => d switch
    {
        GameMatchDetection.ExactLeague =>
            "FocusDesk ve cuándo empieza y cuándo acaba cada partida: nunca te saca a mitad y cierra el juego al terminar.",
        GameMatchDetection.ExactValorant =>
            "FocusDesk consulta el cliente local de Riot para saber si estás en menú o en partida: nunca te saca a mitad y cierra Valorant al terminar.",
        GameMatchDetection.ExactValveGSI =>
            "El juego avisa a FocusDesk al empezar y acabar el mapa (Game State Integration): nunca te saca a mitad y cierra el juego al terminar.",
        GameMatchDetection.Timed =>
            "Este juego no avisa de cuándo acaba la partida. Empieza a contar al abrirlo; al llegar a la duración típica te avisa, te da la prórroga para acabar y solo entonces lo cierra.",
        _ => ""
    };
}

public sealed class GameDefinition
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public GameMatchDetection Detection { get; init; }
    public int TypicalMatchMinutes { get; init; } = 30;
    public string UnitSingular { get; init; } = "partida";
    public string UnitPlural { get; init; } = "partidas";
    public string[] ProcessNames { get; init; } = Array.Empty<string>();
    public string[] PathFragments { get; init; } = Array.Empty<string>();
    public string[] TitleKeywords { get; init; } = Array.Empty<string>();
    public string[] WebEntries { get; init; } = Array.Empty<string>();
    public bool MatchesAnyGame { get; init; }
    public string Note { get; init; } = "";

    public bool Matches(string? processName, string? executablePath = null, string? windowTitle = null)
    {
        if (Detection == GameMatchDetection.ExactLeague)
            return LeagueMatchRules.IsLeagueOrRiotProcess(processName, executablePath, windowTitle);
        if (Detection == GameMatchDetection.ExactValorant)
            return ValorantMatchRules.IsValorantProcess(processName, executablePath);

        var proc = (processName ?? "").ToLowerInvariant().Replace(".exe", "");
        if (!string.IsNullOrEmpty(proc) && ProcessNames.Any(p => proc.Contains(p)))
            return true;

        var path = (executablePath ?? "").ToLowerInvariant().Replace('\\', '/');
        if (!string.IsNullOrEmpty(path) && PathFragments.Any(f => path.Contains(f)))
            return true;

        var title = (windowTitle ?? "").ToLowerInvariant();
        if (!string.IsNullOrEmpty(title) && TitleKeywords.Any(k => title.Contains(k)))
            return true;

        if (MatchesAnyGame && GameLibraryRules.MatchesGameApp(proc, executablePath) != null)
            return true;

        return false;
    }

    public bool MatchesWeb(string host, string path) =>
        WebEntries.Any(e => FocusRules.EntryMatches(host, path, e));
}

public static class GameCatalog
{
    public const string LeagueId = "lol";
    public const string ValorantId = "valorant";
    public const string CustomId = "otro";

    public static readonly IReadOnlyList<GameDefinition> All = new List<GameDefinition>
    {
        new()
        {
            Id = LeagueId,
            Name = "League of Legends",
            Detection = GameMatchDetection.ExactLeague,
            TypicalMatchMinutes = 35,
            Note = "También bloquea el cliente de Riot mientras no tengas partidas."
        },
        new()
        {
            Id = ValorantId,
            Name = "Valorant",
            Detection = GameMatchDetection.ExactValorant,
            TypicalMatchMinutes = 35,
            Note = "Lee el estado local del cliente de Riot (menú vs partida) y cierra Valorant al acabar."
        },
        new()
        {
            Id = "cs2",
            Name = "Counter-Strike 2",
            Detection = GameMatchDetection.ExactValveGSI,
            TypicalMatchMinutes = 40,
            ProcessNames = new[] { "cs2" },
            PathFragments = new[] { "/counter-strike global offensive/", "/cs2.exe" },
            Note = "Detecta inicio y fin de mapa automáticamente con Game State Integration de Steam."
        },
        new()
        {
            Id = "dota2",
            Name = "Dota 2",
            Detection = GameMatchDetection.ExactValveGSI,
            TypicalMatchMinutes = 45,
            ProcessNames = new[] { "dota2" },
            PathFragments = new[] { "/dota 2 beta/", "/dota2.exe" },
            Note = "Detecta inicio y fin de partida automáticamente con Game State Integration de Steam."
        },
        new()
        {
            Id = "fortnite",
            Name = "Fortnite",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 25,
            ProcessNames = new[] { "fortniteclient-win64-shipping", "fortniteclient", "fortnitelauncher" },
            PathFragments = new[] { "/fortnite/" },
            WebEntries = new[] { "play.geforcenow.com", "xbox.com/play", "xbox.com/*/play", "fortnite.com/play" },
            Note = "Incluye Fortnite nativo de Windows y juego en la nube."
        },
        new()
        {
            Id = "warzone",
            Name = "Call of Duty / Warzone",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 30,
            ProcessNames = new[] { "cod", "modernwarfare", "blackops", "warzone" },
            PathFragments = new[] { "/call of duty/" },
            WebEntries = new[] { "xbox.com/play", "xbox.com/*/play", "play.geforcenow.com" }
        },
        new()
        {
            Id = "minecraft",
            Name = "Minecraft",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 45,
            UnitSingular = "sesión",
            UnitPlural = "sesiones",
            ProcessNames = new[] { "minecraft", "minecraftlauncher", "prismlauncher", "multimc", "tlauncher" },
            PathFragments = new[] { "/.minecraft/", "/minecraft/", "prismlauncher", "tlauncher" },
            TitleKeywords = new[] { "minecraft" },
            Note = "Minecraft no tiene partidas: cuenta sesiones de juego."
        },
        new()
        {
            Id = "roblox",
            Name = "Roblox",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 30,
            UnitSingular = "sesión",
            UnitPlural = "sesiones",
            ProcessNames = new[] { "robloxplayerbeta", "robloxstudiobeta", "roblox" },
            PathFragments = new[] { "/roblox/" },
            WebEntries = new[] { "roblox.com" },
            Note = "Cuenta sesiones de juego, sea cual sea la experiencia."
        },
        new()
        {
            Id = "wow",
            Name = "World of Warcraft",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 60,
            UnitSingular = "sesión",
            UnitPlural = "sesiones",
            ProcessNames = new[] { "wow", "wowclassic" },
            PathFragments = new[] { "/world of warcraft/" }
        },
        new()
        {
            Id = "cualquiera",
            Name = "Cualquier juego",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 40,
            UnitSingular = "sesión",
            UnitPlural = "sesiones",
            WebEntries = new[] { "play.geforcenow.com", "xbox.com/play", "xbox.com/*/play" },
            MatchesAnyGame = true,
            Note = "Steam, Epic, Battle.net, Riot, Xbox, Roblox y cualquier juego en esas bibliotecas."
        },
        new()
        {
            Id = CustomId,
            Name = "Otro juego",
            Detection = GameMatchDetection.Timed,
            TypicalMatchMinutes = 30,
            Note = "Elige tú el programa del juego en «Apps» más abajo."
        }
    };

    public static GameDefinition? Find(string? id) =>
        string.IsNullOrEmpty(id) ? null : All.FirstOrDefault(g => g.Id == id);
}

public static class LeagueMatchRules
{
    public const double MinCountedMatchDurationSeconds = 120;

    public static bool IsMatchGameProcess(string? processName, string? executablePath = null)
    {
        var proc = (processName ?? "").ToLowerInvariant().Replace(".exe", "");
        var path = (executablePath ?? "").ToLowerInvariant().Replace('\\', '/');
        if (proc == "league of legends") return true;
        if (path.Contains("/game/league of legends.exe")) return true;
        return false;
    }

    public static bool IsLeagueOrRiotProcess(string? processName, string? executablePath = null, string? windowTitle = null)
    {
        if (IsMatchGameProcess(processName, executablePath)) return true;
        var proc = (processName ?? "").ToLowerInvariant().Replace(".exe", "");
        if (proc is "leagueclient" or "leagueclientux" or "leagueclientuxrender" or "riotclientservices" or "riotclientux" or "riot client")
            return true;
        var path = (executablePath ?? "").ToLowerInvariant().Replace('\\', '/');
        if (path.Contains("/league of legends/") || path.Contains("/riot client/"))
            return true;
        return false;
    }

    public static bool RuleTargetsLeague(GeneralBlockRule rule) =>
        rule.Kind == GeneralRuleKind.WorkGoal && rule.GameId == GameCatalog.LeagueId;
}

public enum ValorantMatchPhase { Unknown, Menu, InMatch }

public static class ValorantMatchRules
{
    private static readonly HttpClient RiotClient = new(new HttpClientHandler
    {
        ServerCertificateCustomValidationCallback = (_, _, _, _) => true
    })
    {
        Timeout = TimeSpan.FromMilliseconds(800)
    };

    public static bool IsValorantProcess(string? processName, string? executablePath = null)
    {
        var proc = (processName ?? "").ToLowerInvariant().Replace(".exe", "");
        if (proc is "valorant" or "valorant-win64-shipping" or "riotclientservices" or "riotclientux")
            return true;
        var path = (executablePath ?? "").ToLowerInvariant().Replace('\\', '/');
        return path.Contains("/valorant/") || path.Contains("/riot client/");
    }

    public static bool IsValorantGameExeRunning(string? processName, string? executablePath = null)
    {
        var proc = (processName ?? "").ToLowerInvariant().Replace(".exe", "");
        if (proc is "valorant" or "valorant-win64-shipping") return true;
        var path = (executablePath ?? "").ToLowerInvariant().Replace('\\', '/');
        return path.Contains("valorant-win64-shipping.exe");
    }

    private static string? ExtractLoopState(JsonElement root)
    {
        if (root.TryGetProperty("sessionLoopState", out var loopEl) && loopEl.ValueKind == JsonValueKind.String)
            return loopEl.GetString();
        if (root.TryGetProperty("matchPresenceData", out var mpd) && mpd.ValueKind == JsonValueKind.Object &&
            mpd.TryGetProperty("sessionLoopState", out var nestedEl) && nestedEl.ValueKind == JsonValueKind.String)
            return nestedEl.GetString();
        return null;
    }

    /// <summary>
    /// Parses Riot Client's local `/chat/v4/presences` JSON payload for Valorant's `sessionLoopState`.
    /// </summary>
    public static ValorantMatchPhase ParsePresenceJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("presences", out var presences) || presences.ValueKind != JsonValueKind.Array)
                return ValorantMatchPhase.Unknown;

            foreach (var entry in presences.EnumerateArray())
            {
                var product = entry.TryGetProperty("product", out var prodEl) ? prodEl.GetString() : null;
                if (!string.Equals(product, "valorant", StringComparison.OrdinalIgnoreCase)) continue;
                if (!entry.TryGetProperty("private", out var privEl) || privEl.ValueKind != JsonValueKind.String)
                    continue;

                var b64 = privEl.GetString();
                if (string.IsNullOrEmpty(b64)) continue;
                var decoded = Encoding.UTF8.GetString(Convert.FromBase64String(b64));
                using var privDoc = JsonDocument.Parse(decoded);
                var rawState = ExtractLoopState(privDoc.RootElement);
                if (!string.IsNullOrEmpty(rawState))
                {
                    var state = rawState.ToUpperInvariant();
                    if (state is "INGAME" or "PREGAME") return ValorantMatchPhase.InMatch;
                    if (state == "MENUS") return ValorantMatchPhase.Menu;
                }
            }
        }
        catch { }
        return ValorantMatchPhase.Unknown;
    }

    public static async Task<ValorantMatchPhase> QueryLocalClientPhaseAsync()
    {
        try
        {
            var lockfilePath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Riot Games", "Riot Client", "Config", "lockfile"
            );
            if (!File.Exists(lockfilePath)) return ValorantMatchPhase.Unknown;
            using var fs = new FileStream(lockfilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var sr = new StreamReader(fs);
            var parts = (await sr.ReadToEndAsync()).Trim().Split(':');
            if (parts.Length < 5) return ValorantMatchPhase.Unknown;

            var port = parts[2];
            var password = parts[3];
            var protocol = parts[4];

            using var req = new HttpRequestMessage(HttpMethod.Get, $"{protocol}://127.0.0.1:{port}/chat/v4/presences");
            var auth = Convert.ToBase64String(Encoding.ASCII.GetBytes($"riot:{password}"));
            req.Headers.Authorization = new AuthenticationHeaderValue("Basic", auth);

            using var resp = await RiotClient.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return ValorantMatchPhase.Unknown;
            var json = await resp.Content.ReadAsStringAsync();
            return ParsePresenceJson(json);
        }
        catch
        {
            return ValorantMatchPhase.Unknown;
        }
    }
}

public static class ValveGSI
{
    public const int Port = 47923;
    public const string ConfigFilename = "gamestate_integration_focusdesk.cfg";

    public enum MatchPhase { Menu, Live, Intermission, GameOver }
    public record Event(string GameId, MatchPhase Phase);

    public static string ConfigContents => $$"""
        "FocusDesk Game State Integration"
        {
            "uri" "http://127.0.0.1:{{Port}}"
            "timeout" "5.0"
            "buffer" "0.1"
            "throttle" "0.5"
            "heartbeat" "5.0"
            "data"
            {
                "provider" "1"
                "map" "1"
            }
        }
        """;

    public static Event? Parse(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("provider", out var provider)) return null;

            int? appId = provider.TryGetProperty("appid", out var appEl) && appEl.TryGetInt32(out var idVal) ? idVal : null;
            var name = provider.TryGetProperty("name", out var nameEl) ? (nameEl.GetString() ?? "").ToLowerInvariant() : "";

            string? gameId = null;
            if (appId == 730 || name.Contains("counter-strike") || name.Contains("cs2") || name.Contains("csgo"))
                gameId = "cs2";
            else if (appId == 570 || name.Contains("dota"))
                gameId = "dota2";

            if (gameId == null) return null;
            if (!root.TryGetProperty("map", out var map)) return new Event(gameId, MatchPhase.Menu);

            var rawPhase = "";
            if (map.TryGetProperty("phase", out var ph)) rawPhase = (ph.GetString() ?? "").ToLowerInvariant();
            else if (map.TryGetProperty("game_state", out var gs)) rawPhase = (gs.GetString() ?? "").ToLowerInvariant();

            if (rawPhase.Contains("gameover") || rawPhase.Contains("post_game"))
                return new Event(gameId, MatchPhase.GameOver);
            if (rawPhase.Contains("intermission"))
                return new Event(gameId, MatchPhase.Intermission);
            if (rawPhase.Contains("live") || rawPhase.Contains("warmup") || rawPhase.Contains("game_in_progress") ||
                rawPhase.Contains("pre_game") || rawPhase.Contains("hero_selection") || rawPhase.Contains("strategy_time"))
                return new Event(gameId, MatchPhase.Live);

            return new Event(gameId, MatchPhase.Menu);
        }
        catch { return null; }
    }

    public static void InstallConfigIfPossible()
    {
        try
        {
            var roots = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var defaultSteam = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
            if (Directory.Exists(defaultSteam)) roots.Add(Path.Combine(defaultSteam, "steamapps"));

            try
            {
                using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
                if (key?.GetValue("SteamPath") is string sp && Directory.Exists(sp))
                    roots.Add(Path.Combine(sp, "steamapps"));
            }
            catch { }

            var vdfRoots = roots.ToList();
            foreach (var r in vdfRoots)
            {
                var vdf = Path.Combine(r, "libraryfolders.vdf");
                if (!File.Exists(vdf)) continue;
                foreach (var line in File.ReadAllLines(vdf))
                {
                    var trimmed = line.Trim();
                    if (!trimmed.StartsWith("\"path\"", StringComparison.OrdinalIgnoreCase)) continue;
                    var parts = trimmed.Split('"');
                    if (parts.Length >= 4)
                    {
                        var lib = parts[3].Replace("\\\\", "\\");
                        var sa = Path.Combine(lib, "steamapps");
                        if (Directory.Exists(sa)) roots.Add(sa);
                    }
                }
            }

            var relDirs = new[]
            {
                Path.Combine("common", "Counter-Strike Global Offensive", "game", "csgo", "cfg"),
                Path.Combine("common", "Counter-Strike Global Offensive", "csgo", "cfg"),
                Path.Combine("common", "dota 2 beta", "game", "dota", "cfg")
            };

            foreach (var root in roots)
            {
                foreach (var rel in relDirs)
                {
                    var cfgDir = Path.Combine(root, rel);
                    if (!Directory.Exists(cfgDir)) continue;
                    var file = Path.Combine(cfgDir, ConfigFilename);
                    if (!File.Exists(file) || File.ReadAllText(file) != ConfigContents)
                        File.WriteAllText(file, ConfigContents, Encoding.UTF8);
                }
            }
        }
        catch { }
    }
}

public sealed class ValveGsiServer : IDisposable
{
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;
    private readonly Action<ValveGSI.Event> _onEvent;

    public ValveGsiServer(Action<ValveGSI.Event> onEvent) => _onEvent = onEvent;

    public void Start()
    {
        if (_listener != null) return;
        try
        {
            var listener = new HttpListener();
            listener.Prefixes.Add($"http://127.0.0.1:{ValveGSI.Port}/");
            listener.Start();
            _listener = listener;
            _cts = new CancellationTokenSource();
            _ = Task.Run(() => AcceptLoopAsync(listener, _cts.Token));
        }
        catch { }
    }

    private async Task AcceptLoopAsync(HttpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested && listener.IsListening)
        {
            HttpListenerContext? ctx = null;
            try
            {
                ctx = await listener.GetContextAsync();
            }
            catch (ObjectDisposedException) { break; }
            catch (HttpListenerException) { break; }
            catch { continue; }

            try
            {
                using var reader = new StreamReader(ctx.Request.InputStream, ctx.Request.ContentEncoding ?? Encoding.UTF8);
                var body = await reader.ReadToEndAsync(ct);
                ctx.Response.StatusCode = 200;
                ctx.Response.Close();
                var ev = ValveGSI.Parse(body);
                if (ev != null) _onEvent(ev);
            }
            catch
            {
                try { ctx.Response.Abort(); } catch { }
            }
        }
    }

    public void Dispose()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); _listener?.Close(); } catch { }
        try { _cts?.Dispose(); } catch { }
        _cts = null;
        _listener = null;
    }
}

public static class TimedMatchPlanner
{
    public enum FinishReason { TimeUp, GameClosed, UserFinished }
    public enum StepKind { Idle, Start, Playing, Overtime, Finish }
    public record Step(StepKind Kind, FinishReason? Reason = null);

    public const double ClosedToleranceSeconds = 120;
    public const double MinPlayedSecondsToEndOnClose = 300;

    public static Step Evaluate(
        GeneralBlockRule rule,
        bool gameRunning,
        double secondsSinceGameSeen,
        double workedTodaySeconds,
        int matchesToday,
        bool allowTimedFallback = false,
        DateTimeOffset? now = null,
        double? continuous = null)
    {
        if (!rule.Enabled || !(rule.UsesTimedMatches || (allowTimedFallback && rule.UsesExactValveGSI)))
            return new(StepKind.Idle);

        var t = now ?? DateTimeOffset.UtcNow;
        var cont = continuous ?? TrustedClock.ContinuousSeconds();

        if (rule.ActiveMatchDeadline != null)
        {
            var rem = rule.TimedMatchRemainingSeconds(t, cont);
            if (rem <= 0) return new(StepKind.Finish, FinishReason.TimeUp);
            if (!gameRunning && secondsSinceGameSeen >= ClosedToleranceSeconds && rule.TimedMatchElapsedSeconds(t, cont) >= MinPlayedSecondsToEndOnClose)
                return new(StepKind.Finish, FinishReason.GameClosed);
            return new(rule.IsInTimedMatchOvertime(t, cont) ? StepKind.Overtime : StepKind.Playing);
        }

        if (!gameRunning) return new(StepKind.Idle);
        var locked = rule.IsEnforcing(t, workedTodaySeconds: workedTodaySeconds, matchesToday: matchesToday, continuous: cont);
        return new(locked ? StepKind.Idle : StepKind.Start);
    }
}
