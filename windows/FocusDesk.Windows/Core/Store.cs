using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FocusDesk.Windows.Core;

/// <summary>
/// Atomic JSON store for FocusDesk Windows in %APPDATA%\FocusDesk\workspace.json,
/// keeping history in workspace.history.json plus rolling & daily backups.
/// </summary>
public sealed class WorkspaceStore
{
    public string FilePath { get; }
    public string DirectoryPath => Path.GetDirectoryName(FilePath)!;
    public string BackupPath => Path.Combine(DirectoryPath, "workspace.backup.json");
    public string HistoryPath => Path.Combine(DirectoryPath, "workspace.history.json");
    public string HistoryBackupPath => Path.Combine(DirectoryPath, "workspace.history.backup.json");
    public string BackupsDirectoryPath => Path.Combine(DirectoryPath, "backups");

    private byte[]? _lastMainHash;
    private byte[]? _lastHistoryHash;
    private readonly object _sync = new();

    public static readonly JsonSerializerOptions JsonOptions = CreateOptions(indented: false);
    public static readonly JsonSerializerOptions PrettyJsonOptions = CreateOptions(indented: true);

    private static JsonSerializerOptions CreateOptions(bool indented)
    {
        var opts = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            WriteIndented = indented,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
        };
        opts.Converters.Add(new FlexibleDateTimeOffsetConverter());
        opts.Converters.Add(new FlexibleSimilarityConverter());
        opts.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return opts;
    }

    public WorkspaceStore(string? customDirectory = null)
    {
        var dir = customDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "FocusDesk"
        );
        FilePath = Path.Combine(dir, "workspace.json");
    }

    public Workspace Load()
    {
        var ws = File.Exists(FilePath) ? ValidateBackup(FilePath) : new Workspace();
        AttachHistory(ws);
        return ws;
    }

    public Workspace LoadWithoutHistory()
    {
        if (!File.Exists(FilePath)) return new Workspace();
        return ValidateBackup(FilePath);
    }

    public Workspace ValidateBackup(string path)
    {
        var bytes = File.ReadAllBytes(path);
        var ws = JsonSerializer.Deserialize<Workspace>(bytes, JsonOptions)
            ?? throw new InvalidDataException("El archivo está vacío.");
        if (ws.Schema is < 1 or > 1)
            throw new NotSupportedException("Versión de archivo no compatible con FocusDesk.");
        return ws;
    }

    private sealed class HistoryFile
    {
        public int Version { get; set; } = 1;
        [JsonConverter(typeof(LossyListConverter<SessionRecord>))]
        public List<SessionRecord> Records { get; set; } = new();
    }

    /// <summary>
    /// Keeps the file on disk exactly as it is, in backups/, before anything is written over it. Used when the data could
    /// not be read (or only partly): the original is what lets a person recover what the app could not.
    /// </summary>
    public string? KeepOriginalCopy(string prefix)
    {
        try
        {
            if (!File.Exists(FilePath)) return null;
            Directory.CreateDirectory(BackupsDirectoryPath);
            var target = Path.Combine(BackupsDirectoryPath, $"{prefix}-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.Copy(FilePath, target, overwrite: false);
            if (File.Exists(HistoryPath))
            {
                try { File.Copy(HistoryPath, Path.Combine(BackupsDirectoryPath, $"{prefix}-{DateTime.Now:yyyyMMdd-HHmmss}.history.json"), overwrite: false); }
                catch { }
            }
            return target;
        }
        catch { return null; }
    }

    private void AttachHistory(Workspace ws)
    {
        if (ws.History.Count > 0) return;
        foreach (var path in new[] { HistoryPath, HistoryBackupPath })
        {
            if (!File.Exists(path)) continue;
            try
            {
                var hf = JsonSerializer.Deserialize<HistoryFile>(File.ReadAllBytes(path), JsonOptions);
                if (hf != null)
                {
                    ws.History = hf.Records;
                    if (ws.Session != null && ws.History.Any(h => h.Id == ws.Session.Id))
                        ws.Session = null;
                    return;
                }
            }
            catch { }
        }
    }

    public void Save(Workspace workspace, bool rollingBackup = true)
    {
        lock (_sync)
        {
            Directory.CreateDirectory(DirectoryPath);
            if (!rollingBackup)
            {
                var exportBytes = JsonSerializer.SerializeToUtf8Bytes(workspace, PrettyJsonOptions);
                WriteAtomic(exportBytes, FilePath);
                return;
            }

            var historyBytes = JsonSerializer.SerializeToUtf8Bytes(
                new HistoryFile { Records = workspace.History }, JsonOptions);
            WriteIfChanged(historyBytes, HistoryPath, HistoryBackupPath, ref _lastHistoryHash);

            var savedHistory = workspace.History;
            try
            {
                workspace.History = new List<SessionRecord>();
                var mainBytes = JsonSerializer.SerializeToUtf8Bytes(workspace, JsonOptions);
                WriteIfChanged(mainBytes, FilePath, BackupPath, ref _lastMainHash);
            }
            finally
            {
                workspace.History = savedHistory;
            }
        }
    }

    public string? CreateDailySnapshotIfNeeded(DateTimeOffset? now = null, int keeping = 14)
    {
        if (!File.Exists(FilePath)) return null;
        var t = (now ?? DateTimeOffset.Now).LocalDateTime;
        var target = Path.Combine(BackupsDirectoryPath, $"daily-{t:yyyy-MM-dd}.json");
        if (File.Exists(target)) return null;

        var full = Load();
        Directory.CreateDirectory(BackupsDirectoryPath);
        WriteAtomic(JsonSerializer.SerializeToUtf8Bytes(full, PrettyJsonOptions), target);
        _ = ValidateBackup(target);
        PruneDailySnapshots(keeping);
        return target;
    }

    private void PruneDailySnapshots(int keeping)
    {
        if (!Directory.Exists(BackupsDirectoryPath)) return;
        var files = Directory.GetFiles(BackupsDirectoryPath, "daily-*.json")
            .OrderByDescending(f => f, StringComparer.OrdinalIgnoreCase)
            .ToList();
        foreach (var old in files.Skip(keeping))
        {
            try { File.Delete(old); } catch { }
        }
    }

    public Workspace RecoverFromRollingBackup()
    {
        if (!File.Exists(BackupPath))
            throw new FileNotFoundException("No hay copia automática previa disponible.");
        var ws = ValidateBackup(BackupPath);
        AttachHistory(ws);
        if (ws.Session != null)
        {
            ws.Session.RunningSince = null;
            ws.Session.RunningUptime = null;
        }
        _lastMainHash = null;
        _lastHistoryHash = null;
        Save(ws);
        return ws;
    }

    private static void WriteIfChanged(byte[] data, string target, string mirror, ref byte[]? lastHash)
    {
        var hash = SHA256.HashData(data);
        if (lastHash != null && File.Exists(target) && CryptographicOperations.FixedTimeEquals(lastHash, hash))
            return;
        WriteAtomic(data, target);
        lastHash = hash;
        try { WriteAtomic(data, mirror); } catch { }
    }

    private static void WriteAtomic(byte[] data, string target)
    {
        var temp = target + ".tmp." + Guid.NewGuid().ToString("N")[..8];
        File.WriteAllBytes(temp, data);
        File.Move(temp, target, overwrite: true);
    }
}

/// <summary>
/// Accepts both standard ISO-8601 strings and Apple CFAbsoluteTime numbers (seconds since 2001-01-01)
/// so macOS backups can be imported seamlessly on Windows.
/// </summary>
public sealed class FlexibleDateTimeOffsetConverter : JsonConverter<DateTimeOffset>
{
    private static readonly DateTimeOffset AppleEpoch = new(2001, 1, 1, 0, 0, 0, TimeSpan.Zero);

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetDouble(out var sec))
            return AppleEpoch.AddSeconds(sec);
        if (reader.TokenType == JsonTokenType.String && DateTimeOffset.TryParse(reader.GetString(), out var dt))
            return dt;
        return DateTimeOffset.UtcNow;
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value.ToString("O"));
}

/// <summary>
/// Reads SimilarityProtectionLevel as either integer (0/1/2, matching macOS Codable) or string name,
/// and writes integer for full JSON parity with macOS.
/// </summary>
public sealed class FlexibleSimilarityConverter : JsonConverter<SimilarityProtectionLevel>
{
    public override SimilarityProtectionLevel Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt32(out var num) && Enum.IsDefined(typeof(SimilarityProtectionLevel), num))
            return (SimilarityProtectionLevel)num;
        if (reader.TokenType == JsonTokenType.String && Enum.TryParse<SimilarityProtectionLevel>(reader.GetString(), ignoreCase: true, out var parsed))
            return parsed;
        return SimilarityProtectionLevel.Off;
    }

    public override void Write(Utf8JsonWriter writer, SimilarityProtectionLevel value, JsonSerializerOptions options) =>
        writer.WriteNumberValue((int)value);
}

/// <summary>How many elements could not be read in the current load (so the app can keep the original file and say so).</summary>
public static class LossyReadStats
{
    [ThreadStatic] private static int _skipped;
    public static int Skipped => _skipped;
    public static void Reset() => _skipped = 0;
    internal static void Count() => _skipped++;
}

/// <summary>
/// Reads a list keeping every element that reads and skipping (and counting) the ones that do not, so one damaged task
/// does not make the whole agenda unreadable (`LossyArray` in macOS Models.swift).
/// </summary>
public sealed class LossyListConverter<T> : JsonConverter<List<T>>
{
    public override bool HandleNull => true;

    public override List<T>? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var list = new List<T>();
        if (reader.TokenType == JsonTokenType.Null) return list;
        if (reader.TokenType != JsonTokenType.StartArray)
        {
            reader.Skip();
            LossyReadStats.Count();
            return list;
        }
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.EndArray) break;
            using var doc = JsonDocument.ParseValue(ref reader);
            try
            {
                var item = doc.RootElement.Deserialize<T>(options);
                if (item != null) list.Add(item);
                else LossyReadStats.Count();
            }
            catch (Exception)
            {
                LossyReadStats.Count();
            }
        }
        return list;
    }

    public override void Write(Utf8JsonWriter writer, List<T> value, JsonSerializerOptions options)
    {
        if (value == null)
        {
            writer.WriteNullValue();
            return;
        }
        writer.WriteStartArray();
        foreach (var item in value) JsonSerializer.Serialize(writer, item, options);
        writer.WriteEndArray();
    }
}

/// <summary>An object that does not read becomes «nothing» (a damaged running session is dropped instead of blocking everything).</summary>
public sealed class LossyObjectConverter<T> : JsonConverter<T> where T : class
{
    public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        try { return doc.RootElement.Deserialize<T>(options); }
        catch (Exception)
        {
            LossyReadStats.Count();
            return null;
        }
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, value, options);
}

/// <summary>Same, for an object that must always exist (settings): what does not read falls back to the defaults.</summary>
public sealed class LossyObjectOrDefaultConverter<T> : JsonConverter<T> where T : class, new()
{
    public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var doc = JsonDocument.ParseValue(ref reader);
        try { return doc.RootElement.Deserialize<T>(options) ?? new T(); }
        catch (Exception)
        {
            LossyReadStats.Count();
            return new T();
        }
    }

    public override void Write(Utf8JsonWriter writer, T value, JsonSerializerOptions options) =>
        JsonSerializer.Serialize(writer, value, options);
}
