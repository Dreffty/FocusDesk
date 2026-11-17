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
    private static extern bool EnumChildWindows(IntPtr hWndParent, EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    private const int SW_RESTORE = 9;

    /// <summary>Brings a window to the front (an allowed app the person is sent back to).</summary>
    public static void ActivateWindow(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
    }

    /// <summary>
    /// Store apps (Netflix, Xbox, Calculator…) live inside «ApplicationFrameHost»: the window belongs to the host and the
    /// real app is a child window with another process. Without this every Store app looked exempt.
    /// </summary>
    private static int FindHostedAppPid(IntPtr frameHwnd, int framePid)
    {
        var found = 0;
        EnumChildWindows(frameHwnd, (child, _) =>
        {
            GetWindowThreadProcessId(child, out var childPid);
            if (childPid != 0 && (int)childPid != framePid)
            {
                found = (int)childPid;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc enumProc, IntPtr lParam);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private const int SW_MINIMIZE = 6;
    private const uint WM_CLOSE = 0x0010;

    private static readonly object _cacheLock = new();
    private static readonly Dictionary<(int Pid, string Name), string?> _exePathCache = new();
    private static List<(int Pid, string Name, string? ExePath, string Title)> _cachedProcesses = new();
    private static long _procSnapshotTick = -10_000;

    private static string? QueryExePath(int pid, string processName)
    {
        lock (_cacheLock)
        {
            if (_exePathCache.TryGetValue((pid, processName), out var cached))
                return cached;
        }

        string? resolved = null;
        var handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, (uint)pid);
        if (handle != IntPtr.Zero)
        {
            try
            {
                var sb = new StringBuilder(1024);
                var size = (uint)sb.Capacity;
                if (QueryFullProcessImageName(handle, 0, sb, ref size))
                    resolved = sb.ToString();
            }
            catch { }
            finally { CloseHandle(handle); }
        }

        lock (_cacheLock)
        {
            if (_exePathCache.Count > 1024) _exePathCache.Clear();
            _exePathCache[(pid, processName)] = resolved;
        }
        return resolved;
    }

    public static void InvalidateProcessCache()
    {
        lock (_cacheLock)
        {
            _procSnapshotTick = -10_000;
        }
    }

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
            var name = p.ProcessName;
            if (name.Equals("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase))
            {
                var hostedPid = FindHostedAppPid(hwnd, (int)pid);
                if (hostedPid != 0)
                {
                    try
                    {
                        using var hosted = Process.GetProcessById(hostedPid);
                        name = hosted.ProcessName;
                        pid = (uint)hostedPid;
                    }
                    catch { }
                }
            }
            var exe = QueryExePath((int)pid, name);
            return new ForegroundAppInfo((int)pid, name, exe, sb.ToString(), hwnd);
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
                var name = p.ProcessName;
                var realPid = (int)pid;
                if (name.Equals("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase))
                {
                    var hostedPid = FindHostedAppPid(hwnd, realPid);
                    if (hostedPid != 0)
                    {
                        using var hosted = Process.GetProcessById(hostedPid);
                        name = hosted.ProcessName;
                        realPid = hostedPid;
                    }
                }
                var exe = QueryExePath(realPid, name);
                result.Add(new ForegroundAppInfo(realPid, name, exe, sb.ToString(), hwnd));
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        return result;
    }

    public static string ApplyBlockAction(ForegroundAppInfo app, AppBlockAction action)
    {
        // Never act on FocusDesk itself, whatever the file is called or a rule says.
        if (FocusRules.IsOwnProcess(app.ProcessId)) return "ignorada (es FocusDesk)";
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
                    InvalidateProcessCache();
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

    public static void MinimizeWindow(IntPtr hwnd) => ShowWindow(hwnd, SW_MINIMIZE);

    public static List<(int Pid, string Name, string? ExePath, string Title)> RunningProcesses()
    {
        var nowTick = Environment.TickCount64;
        lock (_cacheLock)
        {
            if (nowTick - _procSnapshotTick < 1200 && _cachedProcesses.Count > 0)
                return _cachedProcesses;
        }

        var list = new List<(int, string, string?, string)>();
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                var pid = p.Id;
                var name = p.ProcessName;
                var exe = QueryExePath(pid, name);
                var title = p.MainWindowHandle != IntPtr.Zero ? p.MainWindowTitle : "";
                list.Add((pid, name, exe, title));
            }
            catch { }
            finally { p.Dispose(); }
        }

        lock (_cacheLock)
        {
            _cachedProcesses = list;
            _procSnapshotTick = nowTick;
        }
        return list;
    }

    public static void TerminateProcesses(IEnumerable<int> pids)
    {
        var killed = false;
        foreach (var pid in pids)
        {
            if (FocusRules.IsOwnProcess(pid)) continue;
            try
            {
                using var p = Process.GetProcessById(pid);
                if (!p.HasExited)
                {
                    p.Kill(entireProcessTree: true);
                    killed = true;
                }
            }
            catch { }
        }
        if (killed) InvalidateProcessCache();
    }
}

public static class BrowserInspector
{
    private const int MaxVisitedNodes = 480;
    private const int MaxTreeDepth = 9;

    private static (AutomationElement? Edit, string? Url) FindAddressBar(IntPtr hwnd)
    {
        var root = AutomationElement.FromHandle(hwnd);
        if (root == null) return (null, null);

        var walker = TreeWalker.ControlViewWalker;
        var queue = new Queue<(AutomationElement Element, int Depth)>();
        queue.Enqueue((root, 0));
        var visited = 0;

        AutomationElement? fallbackEdit = null;
        string? fallbackRaw = null;

        while (queue.Count > 0 && visited < MaxVisitedNodes)
        {
            var (cur, depth) = queue.Dequeue();
            visited++;

            ControlType? ct = null;
            try { ct = cur.Current.ControlType; } catch { continue; }

            // Never descend into rendered webpage DOM subtrees (slow and can match in-page text boxes).
            if (ct == ControlType.Document) continue;

            if (ct == ControlType.Edit && depth > 0)
            {
                try
                {
                    if (cur.TryGetCurrentPattern(ValuePattern.Pattern, out var patObj) && patObj is ValuePattern vp && !vp.Current.IsReadOnly)
                    {
                        var val = vp.Current.Value?.Trim() ?? "";
                        var name = (cur.Current.Name ?? "").ToLowerInvariant();
                        var aid = (cur.Current.AutomationId ?? "").ToLowerInvariant();
                        var isNamedAddressBar =
                            name.Contains("address") || name.Contains("direcci") || name.Contains("url") ||
                            name.Contains("omnibox") || name.Contains("location") || name.Contains("búsqueda") ||
                            aid.Contains("urlbar") || aid.Contains("address") || aid.Contains("omnibox");

                        var hasFocus = cur.Current.HasKeyboardFocus;
                        var isUrl = LooksLikeUrl(val);
                        if (isNamedAddressBar)
                        {
                            // If the bar already holds a valid URL, never hide it just because the user clicked the omnibox.
                            return (cur, isUrl ? val : (hasFocus ? null : val));
                        }
                        if (fallbackEdit == null && isUrl)
                        {
                            fallbackEdit = cur;
                            fallbackRaw = val;
                        }
                    }
                }
                catch { }
            }

            if (depth >= MaxTreeDepth) continue;
            try
            {
                var child = walker.GetFirstChild(cur);
                while (child != null && visited + queue.Count < MaxVisitedNodes)
                {
                    queue.Enqueue((child, depth + 1));
                    child = walker.GetNextSibling(child);
                }
            }
            catch { }
        }

        return (fallbackEdit, fallbackRaw);
    }

    private static bool LooksLikeUrl(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw) || raw.Contains(' ')) return false;
        var candidate = raw.Contains("://", StringComparison.Ordinal) ? raw : "https://" + raw;
        return Uri.TryCreate(candidate, UriKind.Absolute, out var uri) &&
               uri.Scheme is "http" or "https" &&
               !string.IsNullOrEmpty(uri.Host) &&
               uri.Host.Contains('.');
    }

    public static (string Host, string Path)? ReadActiveUrl(IntPtr hwnd, string processName)
    {
        if (!StudyActivityVerifier.IsBrowser(processName)) return null;
        try
        {
            var (_, raw) = FindAddressBar(hwnd);
            if (string.IsNullOrWhiteSpace(raw) || raw.Contains(' ')) return null;
            if (raw.StartsWith("file://", StringComparison.OrdinalIgnoreCase)) return null;
            var candidate = raw.Contains("://", StringComparison.Ordinal) ? raw : "https://" + raw;
            if (Uri.TryCreate(candidate, UriKind.Absolute, out var uri) &&
                uri.Scheme is "http" or "https" &&
                !string.IsNullOrEmpty(uri.Host) &&
                uri.Host.Contains('.'))
            {
                return (uri.Host.ToLowerInvariant(), uri.AbsolutePath + uri.Query);
            }
        }
        catch { }
        return null;
    }

    /// <summary>
    /// Blocks the page in front: closes its tab, or writes the block page in the address bar. Never closes the last
    /// tab — that closes the whole browser window and throws the person out of the browser — so a lone tab gets the
    /// block page instead. Returns what was done («cerrada», «redirigida», «minimizada») or null when nothing was.
    /// </summary>
    public static string? RedirectOrCloseTab(IntPtr hwnd, bool closeTab, string? redirectUrl, string? expectedPageKey = null)
    {
        try
        {
            var current = WindowsActivity.GetForegroundApp();
            if (current == null || current.Hwnd != hwnd) return null;
            // The address was read a moment ago. If the person changed tab since, do not touch the new one:
            // Ctrl+W would close a page that was never blocked.
            if (!string.IsNullOrEmpty(expectedPageKey))
            {
                var now = ReadActiveUrl(hwnd, current.ProcessName.ToLowerInvariant());
                if (!now.HasValue || $"{now.Value.Host}{now.Value.Path}" != expectedPageKey) return null;
            }
            if (closeTab && CountTabs(hwnd) >= 2)
            {
                System.Windows.Forms.SendKeys.SendWait("^w");
                return "cerrada";
            }
            if (!string.IsNullOrEmpty(redirectUrl))
            {
                try
                {
                    var (edit, _) = FindAddressBar(hwnd);
                    if (edit != null && edit.TryGetCurrentPattern(ValuePattern.Pattern, out var patObj) && patObj is ValuePattern vp)
                    {
                        edit.SetFocus();
                        vp.SetValue(redirectUrl);
                        System.Windows.Forms.SendKeys.SendWait("{ENTER}");
                        return "redirigida";
                    }
                }
                catch { }
            }
            // No address bar to write in (full screen, kiosk…): close the tab if there are others, otherwise put the
            // window away. The blocked page never stays in front, and the browser is never closed.
            if (CountTabs(hwnd) >= 2)
            {
                System.Windows.Forms.SendKeys.SendWait("^w");
                return "cerrada";
            }
            WindowsActivity.MinimizeWindow(hwnd);
            return "minimizada";
        }
        catch { }
        return null;
    }

    /// <summary>Number of tabs in a browser window (UI Automation «TabItem»s), or -1 when it cannot be read.</summary>
    public static int CountTabs(IntPtr hwnd)
    {
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            if (root == null) return -1;
            var walker = TreeWalker.ControlViewWalker;
            var queue = new Queue<(AutomationElement Element, int Depth)>();
            queue.Enqueue((root, 0));
            var visited = 0;
            var tabs = 0;
            while (queue.Count > 0 && visited < 700)
            {
                var (cur, depth) = queue.Dequeue();
                visited++;
                ControlType? ct;
                try { ct = cur.Current.ControlType; } catch { continue; }
                if (ct == ControlType.Document) continue;
                if (ct == ControlType.TabItem) { tabs++; continue; }
                if (depth >= 14) continue;
                try
                {
                    var child = walker.GetFirstChild(cur);
                    while (child != null && visited + queue.Count < 700)
                    {
                        queue.Enqueue((child, depth + 1));
                        child = walker.GetNextSibling(child);
                    }
                }
                catch { }
            }
            return tabs;
        }
        catch { return -1; }
    }
}

public static class FolderGuard
{
    public static string? ProblemWithFolder(string rawPath)
    {
        var clean = (rawPath ?? "").Trim().Trim('"').Replace('/', '\\').TrimEnd('\\');
        if (string.IsNullOrEmpty(clean)) return "Escribe una ruta de carpeta válida.";
        if (clean.Length <= 3 && clean.EndsWith(':'))
            return $"«{clean}\\» es una unidad completa y no se puede bloquear.";

        var lower = clean.ToLowerInvariant();
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile).TrimEnd('\\').ToLowerInvariant();
        var windowsDir = Environment.GetFolderPath(Environment.SpecialFolder.Windows).TrimEnd('\\').ToLowerInvariant();
        var progFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles).TrimEnd('\\').ToLowerInvariant();
        var progFilesX86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86).TrimEnd('\\').ToLowerInvariant();
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData).TrimEnd('\\').ToLowerInvariant();
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData).TrimEnd('\\').ToLowerInvariant();

        var vital = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            @"c:", @"c:\windows", @"c:\users", @"c:\program files", @"c:\program files (x86)",
            userProfile, windowsDir, progFiles, progFilesX86, appData, localAppData
        };
        if (vital.Contains(lower))
            return $"«{clean}» es una carpeta esencial de Windows y no se puede bloquear.";
        if (!string.IsNullOrEmpty(userProfile) && userProfile.StartsWith(lower + "\\", StringComparison.Ordinal))
            return $"«{clean}» contiene tu carpeta de usuario: bloquearla cerraría todo el Explorador.";
        return null;
    }

    public static List<string> EnforceBlockedExplorerFolders(IEnumerable<string> blockedFolders)
    {
        var hits = new List<string>();
        var list = blockedFolders
            .Select(f => f.Trim().Trim('"').Replace('/', '\\').TrimEnd('\\').ToLowerInvariant())
            .Where(f => !string.IsNullOrEmpty(f) && ProblemWithFolder(f) == null)
            .ToList();
        if (list.Count == 0) return hits;

        // Avoid waking COM Shell.Application when no Explorer window is even open.
        if (!WindowsActivity.VisibleWindows().Any(w => w.ProcessName.Equals("explorer", StringComparison.OrdinalIgnoreCase)))
            return hits;

        object? shellObj = null;
        object? windowsObj = null;
        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType == null) return hits;
            shellObj = Activator.CreateInstance(shellType);
            if (shellObj == null) return hits;
            dynamic shell = shellObj;
            windowsObj = shell.Windows();
            if (windowsObj == null) return hits;
            foreach (dynamic win in (System.Collections.IEnumerable)windowsObj)
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
                finally
                {
                    try { if (Marshal.IsComObject(win)) Marshal.FinalReleaseComObject(win); } catch { }
                }
            }
        }
        catch { }
        finally
        {
            try { if (windowsObj != null && Marshal.IsComObject(windowsObj)) Marshal.FinalReleaseComObject(windowsObj); } catch { }
            try { if (shellObj != null && Marshal.IsComObject(shellObj)) Marshal.FinalReleaseComObject(shellObj); } catch { }
        }
        return hits;
    }
}

public static class SystemSettingsGuard
{
    // The panes that would end the block: date and time, privacy, accounts and the apps that start with Windows.
    private static readonly string[] GuardedTokens =
    {
        "hora e idioma", "fecha y hora", "time & language", "date & time", "privacidad", "privacy",
        "cuentas", "accounts", "aplicaciones", "apps", "inicio de sesión", "startup"
    };

    /// <summary>Name of the category selected in the left list of the Settings app (the window title does not change).</summary>
    private static string? SelectedCategory(IntPtr hwnd)
    {
        try
        {
            var root = AutomationElement.FromHandle(hwnd);
            if (root == null) return null;
            var items = root.FindAll(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem));
            foreach (AutomationElement item in items)
            {
                if (item.TryGetCurrentPattern(SelectionItemPattern.Pattern, out var pattern) &&
                    pattern is SelectionItemPattern selection && selection.Current.IsSelected)
                    return item.Current.Name;
            }
        }
        catch { }
        return null;
    }

    public static string? CheckGuardedPane(ForegroundAppInfo app)
    {
        var proc = app.ProcessName.ToLowerInvariant().Replace(".exe", "");
        if (proc == "taskmgr") return "Administrador de tareas";
        if (proc == "regedit") return "Editor del Registro";
        if (proc == "systemsettings")
        {
            var title = app.WindowTitle.ToLowerInvariant();
            if (GuardedTokens.Any(t => title.Contains(t))) return "Configuración de Windows";
            var category = SelectedCategory(app.Hwnd)?.ToLowerInvariant();
            if (category != null && GuardedTokens.Any(t => category.Contains(t))) return "Configuración de Windows";
        }
        if (proc is "cmd" or "powershell" or "pwsh" or "windowsterminal")
        {
            var title = app.WindowTitle.ToLowerInvariant();
            if (title.Contains("taskkill") || title.Contains("stop-process"))
                return "Terminal (intento de cerrar FocusDesk)";
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
        if (raw.Length == 0) return Array.Empty<byte>();
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
            finally { if (outBlob.pbData != IntPtr.Zero) LocalFree(outBlob.pbData); }
        }
        finally { Marshal.FreeHGlobal(inBlob.pbData); }
    }

    private static byte[] UnprotectBytes(byte[] cipher)
    {
        if (cipher.Length == 0) return Array.Empty<byte>();
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
            finally { if (outBlob.pbData != IntPtr.Zero) LocalFree(outBlob.pbData); }
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
        /// <summary>The rules that were protected when the data was last saved (restored if the file loses or softens them).</summary>
        public List<GeneralBlockRule> ProtectedRules { get; set; } = new();
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
            if (raw.Length == 0) return null;
            return JsonSerializer.Deserialize<WitnessPayload>(raw, WorkspaceStore.JsonOptions);
        }
        catch { return null; }
    }

    public static string Fingerprint(IEnumerable<GeneralBlockRule> rules)
    {
        var sig = string.Join("|", rules.Where(r => r.Enabled && r.Protection != SessionProtection.None)
            .OrderBy(r => r.Id)
            .Select(r =>
                $"{r.Id}:{r.Kind}:{r.Protection}:{r.UnlockChars}:{r.StopDelayMinutes}:{r.DailyLimitMinutes}:{r.GoalMinutesRequired}:{r.MaxDailyMatches}:{r.AlwaysProtected}:{r.Domains}:{r.BlockedTitleKeywords}:{string.Join(",", r.Apps.Select(a => a.Id))}:{string.Join(",", r.BlockedFolders)}"));
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sig)));
    }
}

public static class RelaunchGuard
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "FocusDeskWatcher";
    public const string WatcherArg = "--watcher";
    private const string SingleInstanceMutexName = @"Local\FocusDesk_Articdia_SingleInstance";
    private const string WatcherMutexName = @"Local\FocusDesk_Watcher_Running";
    private const string WatcherStopEventName = @"Local\FocusDesk_Watcher_Stop";

    public static bool IsInstalled()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(ValueName) is string s && !string.IsNullOrEmpty(s);
        }
        catch { return false; }
    }

    /// <summary>The start-up entry exists AND points at the .exe that is running now (moved or updated files leave a stale path).</summary>
    public static bool IsInstalledForThisExe()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            if (key?.GetValue(ValueName) is not string registered || registered.Length == 0) return false;
            var exe = Environment.ProcessPath;
            return string.IsNullOrEmpty(exe) || registered.Contains(exe, StringComparison.OrdinalIgnoreCase);
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
        StopWatcherProcess();
    }

    public static void StopWatcherProcess()
    {
        try
        {
            if (EventWaitHandle.TryOpenExisting(WatcherStopEventName, out var stopEvent))
            {
                using (stopEvent) stopEvent.Set();
            }
        }
        catch { }
    }

    public static void StartWatcherProcessIfMissing(string? exePath = null)
    {
        var exe = exePath ?? Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return;
        try
        {
            if (Mutex.TryOpenExisting(WatcherMutexName, out var existing))
            {
                existing.Dispose();
                return;
            }
        }
        catch { }
        try
        {
            Process.Start(new ProcessStartInfo(exe, WatcherArg) { UseShellExecute = false, CreateNoWindow = true });
        }
        catch { }
    }

    /// <summary>
    /// Decides whether the background watcher should reopen FocusDesk after the GUI process disappeared.
    /// Returns false when the user quit FocusDesk legitimately (after unlocking) or Windows shut down (`ClosedBySystemAt`),
    /// and true when FocusDesk was force-killed while a protected session, protected rule, or run-up task was active.
    /// </summary>
    public static bool ShouldRelaunch(Workspace ws, DateTimeOffset now, double? continuous = null)
    {
        if (ws.ClosedBySystemAt.HasValue && Math.Abs((now - ws.ClosedBySystemAt.Value).TotalSeconds) < 120)
            return false;

        var cont = continuous ?? TrustedClock.ContinuousSeconds();
        if (ws.Session != null && ws.Session.ShouldResumeAfterRelaunch(now))
            return true;

        var localNow = now.ToLocalTime();
        if (ws.Tasks.Any(t => !t.Completed && FocusRules.IsTaskInRunUp(t, ws.Settings.RunUpMinutes, localNow)))
            return true;

        return ws.GeneralRules.Any(r =>
        {
            var worked = r.VerifyActiveStudy ? ws.VerifiedStudySecondsToday(localNow) : 0;
            return r.IsProtectedNow(
                localNow,
                ws.UsedSecondsToday(r.Id, now: localNow),
                worked,
                ws.LaunchesToday(r.Id, localNow),
                ws.MatchesToday(r.Id, localNow),
                false,
                ws.Settings.RunUpMinutes,
                cont);
        });
    }

    public static void RunWatcherLoop()
    {
        using var watcherMutex = new Mutex(true, WatcherMutexName, out var acquired);
        if (!acquired) return;
        using var stopEvent = new EventWaitHandle(false, EventResetMode.ManualReset, WatcherStopEventName);

        var store = new WorkspaceStore();
        var recentRelaunches = new Queue<DateTimeOffset>();

        while (!stopEvent.WaitOne(2000))
        {
            try
            {
                var guiRunning = false;
                try
                {
                    if (Mutex.TryOpenExisting(SingleInstanceMutexName, out var existing))
                    {
                        guiRunning = true;
                        existing.Dispose();
                    }
                }
                catch { }
                if (guiRunning) continue;

                var now = DateTimeOffset.UtcNow;
                while (recentRelaunches.Count > 0 && (now - recentRelaunches.Peek()).TotalSeconds > 60)
                    recentRelaunches.Dequeue();
                if (recentRelaunches.Count >= 4) continue;

                var ws = store.LoadWithoutHistory();
                if (ShouldRelaunch(ws, now))
                {
                    var exe = Environment.ProcessPath;
                    if (!string.IsNullOrEmpty(exe))
                    {
                        recentRelaunches.Enqueue(now);
                        Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
                        if (stopEvent.WaitOne(5000)) break;
                    }
                }
            }
            catch { }
        }
    }
}
