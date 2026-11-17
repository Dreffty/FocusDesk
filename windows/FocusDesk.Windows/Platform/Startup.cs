using System;
using Microsoft.Win32;

namespace FocusDesk.Windows.Platform;

/// <summary>«Abrir FocusDesk al iniciar sesión» (macOS: login item). Not the same as the relaunch watcher.</summary>
public static class LaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "FocusDesk";

    public static bool IsEnabled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(ValueName) is string value && value.Length > 0;
        }
        catch { return false; }
    }

    public static void Set(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath);
            if (key == null) return;
            var exe = Environment.ProcessPath;
            if (enabled && !string.IsNullOrEmpty(exe)) key.SetValue(ValueName, $"\"{exe}\"");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        catch { }
    }
}
