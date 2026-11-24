using System;
using System.IO;
using System.Text.Json;

namespace FocusDesk.Windows.Core;

/// <summary>
/// Small choices about the interface (the layout of «Hoy», whether «Novedades» was already shown). They live in their
/// own file next to the data, like the preferences of macOS (`AppPreferences`): they are not part of the workspace
/// and must never stop it from loading.
/// </summary>
public sealed class UiPreferences
{
    /// <summary>«Hoy» drawn by hours (true) or as a list (false). macOS: `FocusDesk.dayLayoutHourly`.</summary>
    public bool HourlyLayout { get; set; } = true;

    /// <summary>The «Novedades» release that was already shown. macOS: `FocusDesk.whatsNewSeen`.</summary>
    public string WhatsNewSeen { get; set; } = "";

    private string _path = "";

    public static UiPreferences Load(string directory)
    {
        var path = Path.Combine(directory, "ui.json");
        UiPreferences? loaded = null;
        try
        {
            if (File.Exists(path)) loaded = JsonSerializer.Deserialize<UiPreferences>(File.ReadAllBytes(path));
        }
        catch { }
        loaded ??= new UiPreferences();
        loaded._path = path;
        return loaded;
    }

    public void Save()
    {
        if (string.IsNullOrEmpty(_path)) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllBytes(_path, JsonSerializer.SerializeToUtf8Bytes(this));
        }
        catch { }
    }
}

public sealed partial class AppEngine
{
    private UiPreferences? _prefs;

    /// <summary>Interface choices kept between runs (see <see cref="UiPreferences"/>).</summary>
    public UiPreferences Prefs => _prefs ??= UiPreferences.Load(Store.DirectoryPath);
}
