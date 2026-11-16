using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Windows.Automation;
using Microsoft.Win32;
using FocusDesk.Windows.Core;

namespace FocusDesk.Windows.Platform;

public sealed record ForegroundAppInfo(int ProcessId, string ProcessName, string? ExecutablePath, string WindowTitle, IntPtr Hwnd);

public static class WindowsActivity
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    private const int SW_MINIMIZE = 6;
    private const uint WM_CLOSE = 0x0010;

    public static double IdleSeconds()
    {
        var lii = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref lii)) return 0;
        var elapsedMs = unchecked((uint)Environment.TickCount - lii.dwTime);
        return elapsedMs / 1000.0;
    }

    public static ForegroundAppInfo? GetForegroundApp()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return null;
        GetWindowThreadProcessId(hwnd, out var pid);
        if (pid == 0) return null;
        try
        {
            using var p = Process.GetProcessById((int)pid);
            var sb = new StringBuilder(512);
            GetWindowText(hwnd, sb, sb.Capacity);
            string? exe = null;
            try { exe = p.MainModule?.FileName; } catch { }
            return new ForegroundAppInfo((int)pid, p.ProcessName, exe, sb.ToString(), hwnd);
        }
        catch { return null; }
    }

    public static bool HasVisibleWindow(int processId)
    {
        var found = false;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == (uint)processId)
            {
                found = true;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static List<ForegroundAppInfo> VisibleWindows()
    {
        var result = new List<ForegroundAppInfo>();
        var seen = new HashSet<int>();
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            var sb = new StringBuilder(256);
            if (GetWindowText(hwnd, sb, sb.Capacity) <= 0) return true;
            GetWindowThreadProcessId(hwnd, out var pid);
            if (pid == 0 || !seen.Add((int)pid)) return true;
            try
            {
                using var p = Process.GetProcessById((int)pid);
                string? exe = null;
                try { exe = p.MainModule?.FileName; } catch { }
                result.Add(new ForegroundAppInfo((int)pid, p.ProcessName, exe, sb.ToString(), hwnd));
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static string ApplyBlockAction(ForegroundAppInfo app, AppBlockAction action)
    {
        var safe = FocusRules.SafeAction(action, app.ProcessName);
        switch (safe)
        {
            case AppBlockAction.Hide:
                ShowWindow(app.Hwnd, SW_MINIMIZE);
                return "minimizada";
            case AppBlockAction.Close:
                PostMessage(app.Hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                return "cerrada";
            case AppBlockAction.ForceQuit:
                try
                {
                    using var p = Process.GetProcessById(app.ProcessId);
                    p.Kill(entireProcessTree: true);
                }
                catch
                {
                    PostMessage(app.Hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
                }
                return "cerrada a la fuerza";
            default:
                return "minimizada";
        }
    }

    public static void CloseWindow(IntPtr hwnd) => PostMessage(hwnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);

    public static List<(int Pid, string Name, string? ExePath, string Title)> RunningProcesses()
    {
        var list = new List<(int, string, string?, string)>();
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                string? exe = null;
                try { exe = p.MainModule?.FileName; } catch { }
                list.Add((p.Id, p.ProcessName, exe, p.MainWindowTitle));
            }
            catch { }
            finally { p.Dispose(); }
        }
        return list;
    }

    public static void TerminateProcesses(IEnumerable<int> pids)
    {
        foreach (var pid in pids)
        {
            try
            {
                using var p = Process.GetProcessById(pid);
                if (!p.HasExited) p.Kill(entireProcessTree: true);
            }
            catch { }
        }
    }
}

public static class BrowserInspector
{
    public static (string Host, string Path)? ReadActiveUrl(IntPtr hwnd, string processName)
    {
        if (!StudyActivityVerifier.IsBrowser(processName)) return null;
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            if (root == null) return null;
            var editCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
            var edits = root.FindAll(TreeScope.Descendants, editCond);
            foreach (AutomationElement edit in edits)
            {
                if (!edit.TryGetCurrentPattern(ValuePattern.Pattern, out var patObj) || patObj is not ValuePattern vp)
                    continue;
                var raw = vp.Current.Value?.Trim();
                if (string.IsNullOrEmpty(raw)) continue;
                var candidate = raw.Contains("://", StringComparison.Ordinal) ? raw : "https://" + raw;
                if (Uri.TryCreate(candidate, UriKind.Absolute, out var uri) && !string.IsNullOrEmpty(uri.Host) && uri.Host.Contains('.'))
                    return (uri.Host.ToLowerInvariant(), uri.AbsolutePath + uri.Query);
            }
        }
        catch { }
        return null;
    }

    public static bool RedirectOrCloseTab(IntPtr hwnd, bool closeTab, string? redirectUrl)
    {
        try
        {
            var current = WindowsActivity.GetForegroundApp();
            if (current == null || current.Hwnd != hwnd) return false;
            if (closeTab)
            {
                System.Windows.Forms.SendKeys.SendWait("^w");
                return true;
            }
            if (!string.IsNullOrEmpty(redirectUrl))
            {
                var root = AutomationElement.FromHandle(hwnd);
                var editCond = new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit);
                var edits = root?.FindAll(TreeScope.Descendants, editCond);
                if (edits != null)
                {
                    foreach (AutomationElement edit in edits)
                    {
                        if (edit.TryGetCurrentPattern(ValuePattern.Pattern, out var patObj) && patObj is ValuePattern vp)
                        {
                            vp.SetValue(redirectUrl);
                            edit.SetFocus();
                            System.Windows.Forms.SendKeys.SendWait("{ENTER}");
                            return true;
                        }
                    }
                }
            }
        }
        catch { }
        return false;
    }
}

public static class FolderGuard
{
    public static List<string> EnforceBlockedExplorerFolders(IEnumerable<string> blockedFolders)
    {
        var hits = new List<string>();
        var list = blockedFolders.Select(f => f.Trim().TrimEnd('\\', '/').ToLowerInvariant()).Where(f => !string.IsNullOrEmpty(f)).ToList();
        if (list.Count == 0) return hits;

        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType == null) return hits;
            dynamic? shell = Activator.CreateInstance(shellType);
            if (shell == null) return hits;
            foreach (dynamic win in shell.Windows())
            {
                try
                {
                    string url = win.LocationURL ?? "";
                    if (!url.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) continue;
                    var localPath = Uri.UnescapeDataString(new Uri(url).LocalPath).TrimEnd('\\', '/').ToLowerInvariant();
                    var matched = list.FirstOrDefault(b => localPath == b || localPath.StartsWith(b + "\\", StringComparison.Ordinal));
                    if (matched != null)
                    {
                        hits.Add(Path.GetFileName(matched));
                        win.Quit();
                    }
                }
                catch { }
            }
        }
        catch { }
        return hits;
    }
}

public static class SystemSettingsGuard
{
    private static readonly string[] GuardedTokens =
    {
        "aplicaciones", "apps", "hora", "fecha", "time", "date", "inicio", "startup", "privacidad", "privacy"
    };

    public static string? CheckGuardedPane(ForegroundAppInfo app)
    {
        var proc = app.ProcessName.ToLowerInvariant().Replace(".exe", "");
        if (proc == "taskmgr") return "Administrador de tareas";
        if (proc == "regedit") return "Editor del Registro";
        if (proc == "systemsettings")
        {
            var title = app.WindowTitle.ToLowerInvariant();
            if (GuardedTokens.Any(t => title.Contains(t))) return "Configuración de Windows";
        }
        return null;
    }
}

public static class DpapiWitness
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DATA_BLOB
    {
        public int cbData;
        public IntPtr pbData;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DATA_BLOB pDataIn,
        string? szDataDescr,
        IntPtr pOptionalEntropy,
        IntPtr pvReserved,
        IntPtr pPromptStruct,
        int dwFlags,
        out DATA_BLOB pDataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DATA_BLOB pDataIn,
        StringBuilder? ppszDataDescr,
        IntPtr pOptionalEntropy,
        IntPtr pvReserved,
        IntPtr pPromptStruct,
        int dwFlags,
        out DATA_BLOB pDataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr hMem);

    private static byte[] ProtectBytes(byte[] raw)
    {
        var inBlob = new DATA_BLOB { cbData = raw.Length, pbData = Marshal.AllocHGlobal(raw.Length) };
        try
        {
            Marshal.Copy(raw, 0, inBlob.pbData, raw.Length);
            if (!CryptProtectData(ref inBlob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out var outBlob))
                throw new InvalidOperationException("CryptProtectData failed.");
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally { LocalFree(outBlob.pbData); }
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); }
    }

    private static byte[] UnprotectBytes(byte[] cipher)
    {
        var inBlob = new DATA_BLOB { cbData = cipher.Length, pbData = Marshal.AllocHGlobal(cipher.Length) };
        try
        {
            Marshal.Copy(cipher, 0, inBlob.pbData, cipher.Length);
            if (!CryptUnprotectData(ref inBlob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out var outBlob))
                throw new InvalidOperationException("CryptUnprotectData failed.");
            try
            {
                var result = new byte[outBlob.cbData];
                Marshal.Copy(outBlob.pbData, result, 0, outBlob.cbData);
                return result;
            }
            finally { LocalFree(outBlob.pbData); }
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); }
    }

    public sealed class WitnessPayload
    {
        public Guid? ActiveSessionId { get; set; }
        public string? ActiveTaskTitle { get; set; }
        public SessionProtection SessionProtection { get; set; }
        public TrustedDeadline? SessionDeadline { get; set; }
        public int ProtectedRuleCount { get; set; }
        public string RulesFingerprint { get; set; } = "";
        public DateTimeOffset SavedAt { get; set; }
    }

    private static string WitnessPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FocusDesk", "witness.dat"
    );

    public static void Save(WitnessPayload payload)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(WitnessPath)!);
            var json = JsonSerializer.SerializeToUtf8Bytes(payload, WorkspaceStore.JsonOptions);
            File.WriteAllBytes(WitnessPath, ProtectBytes(json));
        }
        catch { }
    }

    public static WitnessPayload? Load()
    {
        try
        {
            if (!File.Exists(WitnessPath)) return null;
            var raw = UnprotectBytes(File.ReadAllBytes(WitnessPath));
            return JsonSerializer.Deserialize<WitnessPayload>(raw, WorkspaceStore.JsonOptions);
        }
        catch { return null; }
    }

    public static string Fingerprint(IEnumerable<GeneralBlockRule> rules)
    {
        var sig = string.Join("|", rules.Where(r => r.Enabled && r.Protection != SessionProtection.None)
            .OrderBy(r => r.Id)
            .Select(r => $"{r.Id}:{r.Kind}:{r.Protection}:{r.UnlockChars}:{r.Domains}:{string.Join(",", r.Apps.Select(a => a.Id))}"));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sig)));
    }
}

public static class RelaunchGuard
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "FocusDeskWatcher";
    public const string WatcherArg = "--watcher";

    public static bool IsInstalled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(ValueName) is string s && !string.IsNullOrEmpty(s);
        }
        catch { return false; }
    }

    public static void Install()
    {
        try
        {
            var exe = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exe)) return;
            using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath);
            key.SetValue(ValueName, $"\"{exe}\" {WatcherArg}");
            StartWatcherProcessIfMissing(exe);
        }
        catch { }
    }

    public static void Remove()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            key?.DeleteValue(ValueName, throwOnMissingValue: false);
        }
        catch { }
    }

    public static void StartWatcherProcessIfMissing(string? exePath = null)
    {
        var exe = exePath ?? Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return;
        try
        {
            using var m = new Mutex(false, @"Local\FocusDesk_Watcher_Running", out var created);
            if (!created) return;
        }
        catch { }
        try
        {
            Process.Start(new ProcessStartInfo(exe, WatcherArg) { UseShellExecute = false, CreateNoWindow = true });
        }
        catch { }
    }

    public static void RunWatcherLoop()
    {
        using var watcherMutex = new Mutex(true, @"Local\FocusDesk_Watcher_Running", out var acquired);
        if (!acquired) return;

        var store = new WorkspaceStore();
        var recentRelaunches = new Queue<DateTimeOffset>();

        while (true)
        {
            Thread.Sleep(2000);
            try
            {
                bool guiRunning;
                using (var m = new Mutex(false, @"Local\FocusDesk_Articdia_SingleInstance", out var free))
                {
                    guiRunning = !free;
                }
                if (guiRunning) continue;

                var now = DateTimeOffset.UtcNow;
                while (recentRelaunches.Count > 0 && (now - recentRelaunches.Peek()).TotalSeconds > 60)
                    recentRelaunches.Dequeue();
                if (recentRelaunches.Count >= 4) continue;

                var ws = store.LoadWithoutHistory();
                var cont = TrustedClock.ContinuousSeconds();
                var sessionShouldResume = ws.Session != null && ws.Session.ShouldResumeAfterRelaunch(now);
                var ruleProtected = ws.GeneralRules.Any(r =>
                {
                    var worked = r.VerifyActiveStudy ? ws.VerifiedStudySecondsToday(now) : 0;
                    return r.IsProtectedNow(now, ws.UsedSecondsToday(r.Id, now: now), worked, ws.LaunchesToday(r.Id, now), ws.MatchesToday(r.Id, now), false, ws.Settings.RunUpMinutes, cont);
                });

                if (sessionShouldResume || ruleProtected)
                {
                    var exe = Environment.ProcessPath;
                    if (!string.IsNullOrEmpty(exe))
                    {
                        recentRelaunches.Enqueue(now);
                        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
                        Thread.Sleep(6000);
                    }
                }
            }
            catch { }
        }
    }
}
