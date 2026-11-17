using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace FocusDesk.Windows.Core;

/// <summary>More of FocusRules: the same checks macOS makes when someone adds an exception to a block.</summary>
public static partial class FocusRules
{
    private static readonly HashSet<string> BroadTopLevelDomains = new(StringComparer.OrdinalIgnoreCase)
    {
        "com", "org", "net", "es", "io", "ai", "co", "tv", "gg", "app", "dev", "me", "edu", "gov", "uk", "de", "fr"
    };

    /// <summary>Rejects overly broad entries (`*`, `*.com`, one letter…) that would open the whole web. Null when it is fine.</summary>
    public static string? IsAllowEntryTooBroad(string raw)
    {
        var trimmed = (raw ?? "").Trim().ToLowerInvariant();
        if (trimmed.Length == 0) return "Escribe un dominio concreto.";
        if (trimmed is "*" or "*.*" or "http://*" or "https://*" or "/.*/")
            return $"«{raw}» es demasiado amplio y abriría cualquier web.";
        var normalized = NormalizeDomainEntry(trimmed);
        if (normalized == null) return $"«{raw}» no es un dominio válido.";
        var slash = normalized.IndexOf('/');
        var hostPart = slash >= 0 ? normalized[..slash] : normalized;
        var withoutWildcards = hostPart.Replace("*", "").Replace("?", "").Trim('.');
        if (withoutWildcards.Length == 0 || BroadTopLevelDomains.Contains(withoutWildcards) || withoutWildcards.Length < 3)
            return $"«{raw}» es demasiado genérico para una excepción o lista blanca.";
        var labels = hostPart.Split('.', StringSplitOptions.RemoveEmptyEntries);
        if (labels.Length == 2 && (labels[0] == "*" || labels[0] == "?" || labels[0].Length <= 1))
            return $"«{raw}» abriría todos los dominios de «.{labels[1]}».";
        return null;
    }

    private static int EditDistance(string a, string b)
    {
        if (a.Length == 0) return b.Length;
        if (b.Length == 0) return a.Length;
        var previous = new int[b.Length + 1];
        for (var j = 0; j <= b.Length; j++) previous[j] = j;
        for (var i = 0; i < a.Length; i++)
        {
            var current = new int[b.Length + 1];
            current[0] = i + 1;
            for (var j = 0; j < b.Length; j++)
            {
                var cost = a[i] == b[j] ? 0 : 1;
                current[j + 1] = Math.Min(Math.Min(current[j] + 1, previous[j + 1] + 1), previous[j] + cost);
            }
            previous = current;
        }
        return previous[b.Length];
    }

    /// <summary>Why `allowCandidate` cannot be authorised against the blocked domains at this similarity level, or null.</summary>
    public static string? CheckSimilarityRestriction(string allowCandidate, string blockedDomains, SimilarityProtectionLevel level)
    {
        var broad = IsAllowEntryTooBroad(allowCandidate);
        if (broad != null) return broad;
        if (level == SimilarityProtectionLevel.Off) return null;
        var normCandidate = NormalizeDomainEntry(allowCandidate);
        if (normCandidate == null) return null;
        var slash = normCandidate.IndexOf('/');
        var candidateHost = slash >= 0 ? normCandidate[..slash] : normCandidate;
        var candidateHasSubpath = slash >= 0 && slash < normCandidate.Length - 1;

        foreach (var blocked in ParseDomains(blockedDomains).Valid)
        {
            var blockedSlash = blocked.IndexOf('/');
            var blockedHost = blockedSlash >= 0 ? blocked[..blockedSlash] : blocked;
            var sameOrSubdomain = candidateHost == blockedHost || candidateHost.EndsWith("." + blockedHost, StringComparison.Ordinal);
            if (sameOrSubdomain)
            {
                if (level == SimilarityProtectionLevel.SpecificPagesOnly && !candidateHasSubpath)
                    return $"La protección de similitud impide autorizar el dominio entero «{candidateHost}». Indica una subruta concreta (p. ej. «{candidateHost}/curso»).";
                if (level == SimilarityProtectionLevel.NearDuplicates && !candidateHasSubpath && normCandidate == blocked)
                    return $"«{normCandidate}» coincide exactamente con el dominio bloqueado «{blocked}».";
            }
            var candidateName = candidateHost.Split('.')[0];
            var blockedName = blockedHost.Split('.')[0];
            if (candidateName != blockedName && blockedName.Length >= 4 && EditDistance(candidateName, blockedName) == 1)
                return $"«{candidateHost}» es casi idéntico a «{blockedHost}» (protección contra dominios parecidos activa).";
        }
        return null;
    }
}

/// <summary>Looks at the task's result folder before and after a session to tell which files changed (macOS: FileScanner).</summary>
public static class FolderEvidence
{
    private static readonly HashSet<string> SkippedFolders = new(StringComparer.OrdinalIgnoreCase)
    {
        ".git", "node_modules", "$RECYCLE.BIN", "System Volume Information", ".vs", "bin", "obj"
    };

    public static (Dictionary<string, FileStamp> Files, bool Valid, string Message) Scan(string? folder, int maxFiles = 5000)
    {
        var files = new Dictionary<string, FileStamp>();
        if (string.IsNullOrWhiteSpace(folder))
            return (files, false, "Sin carpeta de resultado: confirma el resultado a mano.");
        try
        {
            if (!Directory.Exists(folder))
                return (files, false, "La carpeta de resultado no existe: confirma el resultado a mano.");
            var pending = new Stack<string>();
            pending.Push(folder);
            while (pending.Count > 0 && files.Count < maxFiles)
            {
                var dir = pending.Pop();
                try
                {
                    foreach (var file in Directory.EnumerateFiles(dir))
                    {
                        var info = new FileInfo(file);
                        files[file] = new FileStamp { Modified = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero), Bytes = info.Length };
                        if (files.Count >= maxFiles) break;
                    }
                    foreach (var sub in Directory.EnumerateDirectories(dir))
                    {
                        if (!SkippedFolders.Contains(Path.GetFileName(sub))) pending.Push(sub);
                    }
                }
                catch { }
            }
            var message = files.Count >= maxFiles
                ? "Carpeta muy grande: solo se han mirado los primeros archivos."
                : $"Revisados {files.Count} archivos.";
            return (files, true, message);
        }
        catch (Exception ex)
        {
            return (files, false, $"No se pudo leer la carpeta: {ex.Message}");
        }
    }

    public static List<string> Changed(Dictionary<string, FileStamp> before, Dictionary<string, FileStamp> after) =>
        after.Where(pair => !before.TryGetValue(pair.Key, out var old) || old.Modified != pair.Value.Modified || old.Bytes != pair.Value.Bytes)
             .Select(pair => pair.Key)
             .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
             .ToList();
}

/// <summary>An .ics file (any calendar app opens it): the nearest thing to the macOS Calendar integration.</summary>
public static class IcsExporter
{
    private static string Escape(string text) =>
        (text ?? "").Replace("\\", "\\\\").Replace(";", "\\;").Replace(",", "\\,").Replace("\r\n", "\\n").Replace("\n", "\\n");

    public static string Build(IEnumerable<FocusTask> tasks)
    {
        var sb = new StringBuilder();
        sb.Append("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Articdia//FocusDesk//ES\r\nCALSCALE:GREGORIAN\r\n");
        foreach (var task in tasks.Where(t => t.IsScheduled && !t.Completed))
        {
            var start = task.ScheduledAt.UtcDateTime;
            var end = task.End.UtcDateTime;
            sb.Append("BEGIN:VEVENT\r\n");
            sb.Append($"UID:{task.Id:N}-{start:yyyyMMddTHHmmss}@focusdesk\r\n");
            sb.Append($"DTSTAMP:{DateTime.UtcNow:yyyyMMddTHHmmss}Z\r\n");
            sb.Append($"DTSTART:{start:yyyyMMddTHHmmss}Z\r\n");
            sb.Append($"DTEND:{end:yyyyMMddTHHmmss}Z\r\n");
            sb.Append($"SUMMARY:{Escape(task.Title)}\r\n");
            if (!string.IsNullOrWhiteSpace(task.Checklist)) sb.Append($"DESCRIPTION:{Escape(task.Checklist)}\r\n");
            sb.Append($"CATEGORIES:{Escape(task.Category)}\r\n");
            sb.Append("END:VEVENT\r\n");
        }
        sb.Append("END:VCALENDAR\r\n");
        return sb.ToString();
    }
}

/// <summary>The ready-made lists of distractions (same four as macOS `DistractionPreset`).</summary>
public sealed record DistractionPreset(string Id, string Label, string[] Domains, string[] TitleKeywords)
{
    public static readonly DistractionPreset Social = new("social", "Redes sociales",
        new[] { "x.com", "twitter.com", "instagram.com", "facebook.com", "tiktok.com", "reddit.com", "threads.net", "bsky.app" },
        new[] { "Instagram", "TikTok", "Reddit" });

    public static readonly DistractionPreset ShortVideos = new("shortVideos", "Shorts y Reels",
        new[] { "youtube.com/shorts", "instagram.com/reels", "tiktok.com", "facebook.com/reel" },
        new[] { "Shorts", "Reels", "TikTok" });

    public static readonly DistractionPreset Streaming = new("streaming", "Vídeo y series",
        new[] { "youtube.com", "netflix.com", "twitch.tv", "primevideo.com", "disneyplus.com", "max.com" },
        new[] { "Netflix", "Twitch", "Prime Video", "Disney+" });

    public static readonly DistractionPreset Games = new("games", "Juegos y tiendas",
        new[] { "store.steampowered.com", "steamcommunity.com", "epicgames.com", "itch.io", "roblox.com", "chess.com" },
        new[] { "Steam", "Epic Games" });

    public static readonly IReadOnlyList<DistractionPreset> All = new[] { Social, ShortVideos, Streaming, Games };
}

public static class SimilarityProtectionLevelExtensions
{
    public static string Label(this SimilarityProtectionLevel level) => level switch
    {
        SimilarityProtectionLevel.NearDuplicates => "Bloquear dominios casi idénticos a los bloqueados",
        SimilarityProtectionLevel.SpecificPagesOnly => "Solo permitir subrutas largas y específicas",
        _ => "Desactivada"
    };
}
