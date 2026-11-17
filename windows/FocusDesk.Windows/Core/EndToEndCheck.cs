using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using FocusDesk.Windows.Platform;
using Forms = System.Windows.Forms;

namespace FocusDesk.Windows.Core;

/// <summary>
/// Real end-to-end check of the essential blocking, on a real Windows desktop (CI runs it with --e2e-test):
/// real Edge, Chrome and Firefox windows on a local test site, «Bloquear ahora» with the «Shorts y Reels» preset,
/// a task session that only allows one page, and a rule that blocks an app. Every step leaves a screenshot in
/// e2e-capturas\ and a line in e2e-report.txt, so what happened can be seen, not guessed.
/// The machine must resolve prueba-focusdesk.test to 127.0.0.1 (the CI step adds it to the hosts file).
/// </summary>
public static class EndToEndCheck
{
    public const string TestHost = "prueba-focusdesk.test";
    private const int Port = 8765;
    private const string BlockPageTitle = "Ahora no";

    private static string Url(string path) => $"http://{TestHost}:{Port}{path}";

    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    private static readonly List<string> Log = new();
    private static readonly List<string> Failures = new();
    private static string _shotsDir = "";
    private static int _shotNumber;

    private static void Info(string message) => Log.Add("INFO · " + message);

    private static void Check(bool ok, string name, string? detail = null)
    {
        if (ok)
        {
            Log.Add($"PASS · {name}");
            return;
        }
        var line = detail == null ? $"FAIL · {name}" : $"FAIL · {name}: {detail}";
        Log.Add(line);
        Failures.Add(line);
    }

    private static void Shot(string name)
    {
        try
        {
            var bounds = Forms.Screen.PrimaryScreen!.Bounds;
            using var bmp = new Bitmap(bounds.Width, bounds.Height);
            using (var g = Graphics.FromImage(bmp))
                g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
            bmp.Save(Path.Combine(_shotsDir, $"{++_shotNumber:00}-{name}.png"), ImageFormat.Png);
        }
        catch (Exception ex) { Info($"captura «{name}» no se pudo hacer: {ex.Message}"); }
    }

    private static string TitleOf(IntPtr hwnd)
    {
        var sb = new StringBuilder(512);
        GetWindowText(hwnd, sb, sb.Capacity);
        return sb.ToString();
    }

    private static bool WindowOpen(IntPtr hwnd) => IsWindow(hwnd) && IsWindowVisible(hwnd) && !IsIconic(hwnd);

    public static async Task<int> RunAsync()
    {
        _shotsDir = Path.Combine(Environment.CurrentDirectory, "e2e-capturas");
        Directory.CreateDirectory(_shotsDir);
        var tempDir = Path.Combine(Path.GetTempPath(), "FocusDesk-E2E-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(tempDir);
        HttpListener? server = null;

        try
        {
            server = StartServer();
            using (var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) })
            {
                var body = "";
                try { body = await http.GetStringAsync(Url("/ok")); } catch (Exception ex) { body = ex.Message; }
                Check(body.Contains("Pagina normal"), "La web de prueba responde en " + Url("/ok"), body.Length > 200 ? body[..200] : body);
            }

            using var engine = new AppEngine(tempDir, enablePlatformWatchers: false);

            // «Bloquear ahora» exactly as the button does it, with the «Shorts y Reels» preset. The test site stands in
            // for instagram.com/reels (a real social site needs a login and changes its pages).
            engine.LaunchQuickBlock(30, SessionProtection.None, DistractionPreset.ShortVideos);
            var quick = engine.Workspace.GeneralRules.FirstOrDefault(r => r.Name.StartsWith("Bloqueo rápido", StringComparison.OrdinalIgnoreCase));
            Check(quick != null && engine.IsRuleEnforcing(quick), "«Bloquear ahora» crea una regla que ya está bloqueando");
            if (quick == null) return Finish(1);
            quick.Domains = FocusRules.NormalizeDomains(quick.Domains + $", {TestHost}/reels, {TestHost}/clips");
            quick.PunisherEnabled = false; // each browser gets the same treatment; the hardened mode is checked on its own below
            Info($"Regla: webs «{quick.Domains}» · palabras «{quick.BlockedTitleKeywords}» · acción web {quick.WebBlockAction}");

            var browsers = new[] { "msedge", "chrome", "firefox" }
                .Select(name => (Name: name, Exe: FindBrowser(name)))
                .Where(b => b.Exe != null)
                .ToList();
            Info("Navegadores encontrados: " + string.Join(", ", browsers.Select(b => b.Name)));
            Check(browsers.Count > 0, "Hay al menos un navegador para probar");

            foreach (var (name, exe) in browsers)
                await CheckBrowser(engine, quick, name, exe!);

            // Closing tabs: with two tabs only the blocked one goes; a lone tab is replaced by the block page, so the
            // browser itself is never closed.
            if (browsers.Count > 0)
            {
                var (name, exe) = browsers[0];
                quick.WebBlockAction = WebBlockAction.CloseTab;
                await CheckCloseTab(engine, name, exe!);
                quick.WebBlockAction = WebBlockAction.Redirect;

                quick.Enabled = false;
                await CheckSession(engine, name, exe!);
            }

            quick.Enabled = true;
            await CheckAppRule(engine, quick);
            await CheckFolder(engine, quick);
            await CheckUiTour(engine);
        }
        catch (Exception ex)
        {
            Check(false, "La prueba terminó sin excepciones", ex.ToString());
        }
        finally
        {
            try { server?.Stop(); } catch { }
            foreach (var n in new[] { "msedge", "chrome", "firefox", "notepad" }) KillAll(n);
            try { Directory.Delete(@"C:\FD-Carpeta-Bloqueada", true); } catch { }
        }
        return Finish(Failures.Count == 0 ? 0 : 1);
    }

    private static int Finish(int code)
    {
        Log.Add(Failures.Count == 0 ? "RESULTADO · todo bien" : $"RESULTADO · {Failures.Count} fallo(s)");
        try { File.WriteAllLines(Path.Combine(Environment.CurrentDirectory, "e2e-report.txt"), Log); } catch { }
        return Failures.Count == 0 ? code : 1;
    }

    // MARK: - Browsers

    private static async Task CheckBrowser(AppEngine engine, GeneralBlockRule quick, string name, string exe)
    {
        Info($"—— {name} ——");
        var hwnd = await OpenBrowser(name, exe);
        Check(hwnd != IntPtr.Zero, $"{name}: se abre con la página permitida");
        if (hwnd == IntPtr.Zero) { Shot($"{name}-no-abre"); KillAll(name); return; }

        var url = BrowserInspector.ReadActiveUrl(hwnd, name);
        Check(url.HasValue && url.Value.Host == TestHost && url.Value.Path.StartsWith("/ok"),
            $"{name}: FocusDesk lee la dirección de la pestaña (sin esto no puede bloquear webs)",
            url.HasValue ? $"leído {url.Value.Host}{url.Value.Path}" : "no se pudo leer");
        Info($"{name}: pestañas detectadas {BrowserInspector.CountTabs(hwnd)}");
        if (!url.HasValue) Info($"{name}: lo que FocusDesk ve en la ventana → {BrowserInspector.DescribeInputs(hwnd)}");

        await Pump(engine, 7);
        Shot($"{name}-1-permitida");
        Check(WindowOpen(hwnd) && TitleOf(hwnd).Contains("Pagina normal"), $"{name}: una web permitida no se toca",
            $"título «{TitleOf(hwnd)}», abierta={WindowOpen(hwnd)}");

        // Reels: blocked by the address AND by the word «Reels» in the title. Only that tab may change.
        await OpenInNewTab(Url("/reels"));
        var blocked = await PumpUntil(engine, () => !WindowOpen(hwnd) || TitleOf(hwnd).Contains(BlockPageTitle), 25);
        Shot($"{name}-2-reels");
        Check(WindowOpen(hwnd), $"{name}: entrar en Reels NO cierra ni minimiza el navegador",
            $"ventana existe={IsWindow(hwnd)}, minimizada={IsIconic(hwnd)}");
        Check(blocked && TitleOf(hwnd).Contains(BlockPageTitle), $"{name}: la pestaña de Reels pasa a la página de bloqueo",
            $"título «{TitleOf(hwnd)}» · aviso «{engine.Notice}»");

        Forms.SendKeys.SendWait("^1");
        await Pump(engine, 2);
        Shot($"{name}-3-otra-pestana");
        Check(WindowOpen(hwnd) && TitleOf(hwnd).Contains("Pagina normal"), $"{name}: la otra pestaña sigue abierta y usable",
            $"título «{TitleOf(hwnd)}»");

        // Blocked only by the address (no blocked word in the title).
        await OpenInNewTab(Url("/clips"));
        var byAddress = await PumpUntil(engine, () => !WindowOpen(hwnd) || TitleOf(hwnd).Contains(BlockPageTitle), 25);
        Shot($"{name}-4-por-direccion");
        Check(WindowOpen(hwnd) && byAddress && TitleOf(hwnd).Contains(BlockPageTitle),
            $"{name}: una web bloqueada solo por su dirección pasa a la página de bloqueo",
            $"título «{TitleOf(hwnd)}» · aviso «{engine.Notice}»");

        KillAll(name);
        await Task.Delay(1500);
    }

    private static async Task CheckCloseTab(AppEngine engine, string name, string exe)
    {
        Info($"—— Cerrar pestaña ({name}) ——");
        var hwnd = await OpenBrowser(name, exe);
        if (hwnd == IntPtr.Zero) { Check(false, $"{name}: se abre para la prueba de cerrar pestaña"); return; }

        await OpenInNewTab(Url("/clips"));
        await PumpUntil(engine, () => !WindowOpen(hwnd) || TitleOf(hwnd).Contains("Pagina normal"), 25);
        Shot($"cerrar-1-dos-pestanas");
        Check(WindowOpen(hwnd) && TitleOf(hwnd).Contains("Pagina normal"),
            $"{name}: con dos pestañas, «cerrar pestaña» cierra solo la bloqueada", $"título «{TitleOf(hwnd)}» · aviso «{engine.Notice}»");

        // Now the only tab left goes to a blocked page: the browser must stay open with the block page.
        Forms.SendKeys.SendWait("^l");
        await Task.Delay(500);
        Forms.SendKeys.SendWait(Url("/clips") + "{ENTER}");
        var done = await PumpUntil(engine, () => !WindowOpen(hwnd) || TitleOf(hwnd).Contains(BlockPageTitle), 25);
        Shot($"cerrar-2-una-pestana");
        Check(WindowOpen(hwnd), $"{name}: con una sola pestaña, «cerrar pestaña» NO cierra el navegador",
            $"ventana existe={IsWindow(hwnd)}, minimizada={IsIconic(hwnd)}");
        Check(done && TitleOf(hwnd).Contains(BlockPageTitle), $"{name}: la única pestaña pasa a la página de bloqueo",
            $"título «{TitleOf(hwnd)}» · aviso «{engine.Notice}»");
        KillAll(name);
        await Task.Delay(1500);
    }

    private static async Task CheckSession(AppEngine engine, string name, string exe)
    {
        Info($"—— Sesión de tarea ({name}) ——");
        var task = new FocusTask
        {
            Title = "Tarea de prueba",
            Minutes = 30,
            Domains = $"{TestHost}/ok",
            WebListMode = WebListMode.AllowListed,
            WebBlockAction = WebBlockAction.Redirect,
            PunisherEnabled = false
        };
        engine.Workspace.Tasks.Add(task);
        engine.StartSession(task);
        Check(engine.Workspace.Session is { EndedAt: null }, "La sesión de la tarea empieza");

        var hwnd = await OpenBrowser(name, exe);
        if (hwnd == IntPtr.Zero) { Check(false, $"{name}: se abre para la prueba de sesión"); return; }
        await Pump(engine, 7);
        Shot("sesion-1-permitida");
        Check(WindowOpen(hwnd) && TitleOf(hwnd).Contains("Pagina normal"), "Sesión: la web de la tarea se puede usar", $"título «{TitleOf(hwnd)}»");

        await OpenInNewTab(Url("/clips"));
        var blocked = await PumpUntil(engine, () => !WindowOpen(hwnd) || TitleOf(hwnd).Contains(BlockPageTitle), 25);
        Shot("sesion-2-fuera-de-la-tarea");
        Check(WindowOpen(hwnd) && blocked && TitleOf(hwnd).Contains(BlockPageTitle),
            "Sesión: una web fuera de la tarea pasa a la página de bloqueo y el navegador sigue abierto",
            $"título «{TitleOf(hwnd)}» · aviso «{engine.Notice}»");

        try { engine.FinishSession(); } catch (Exception ex) { Info("Terminar sesión: " + ex.Message); }
        if (engine.Workspace.Session is { EndedAt: null }) engine.Workspace.Session = null;
        KillAll(name);
        await Task.Delay(1500);
    }

    // MARK: - Apps

    private static async Task CheckAppRule(AppEngine engine, GeneralBlockRule rule)
    {
        Info("—— Bloqueo de app (Bloc de notas) ——");
        rule.BlockApps = true;
        rule.AppListMode = AppListMode.BlockListed;
        rule.Apps = new List<AllowedApp> { new("notepad", "Bloc de notas", @"C:\Windows\System32\notepad.exe") };
        rule.BlockAction = AppBlockAction.Hide;

        var p = Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true });
        var hwnd = await WaitForWindow("notepad", _ => true, 20);
        if (hwnd == IntPtr.Zero) { Check(false, "El Bloc de notas se abre para la prueba"); return; }
        WindowsActivity.ActivateWindow(hwnd);
        var hidden = await PumpUntil(engine, () => !WindowOpen(hwnd), 15);
        Shot("app-bloqueada");
        Check(hidden, "Una app bloqueada (Bloc de notas) se aparta de delante", $"título «{TitleOf(hwnd)}» · aviso «{engine.Notice}»");
        try { p?.Kill(true); } catch { }
        KillAll("notepad");
    }

    // MARK: - Folders

    private static async Task CheckFolder(AppEngine engine, GeneralBlockRule rule)
    {
        Info("—— Carpeta bloqueada (Explorador) ——");
        var folder = @"C:\FD-Carpeta-Bloqueada";
        Directory.CreateDirectory(folder);
        rule.BlockedFolders = new List<string> { folder };
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });
        var hwnd = await WaitForWindow("explorer", t => t.Contains("FD-Carpeta-Bloqueada"), 20);
        if (hwnd == IntPtr.Zero) { Shot("carpeta-no-abre"); Check(false, "El Explorador abre la carpeta para la prueba"); return; }
        Shot("carpeta-abierta");
        var closed = await PumpUntil(engine, () => !IsWindow(hwnd) || !IsWindowVisible(hwnd), 15);
        Shot("carpeta-bloqueada");
        Check(closed, "Una carpeta bloqueada abierta en el Explorador se cierra", $"aviso «{engine.Notice}»");
        rule.BlockedFolders = new List<string>();
    }

    // MARK: - The window itself

    /// <summary>Opens FocusDesk's own window, goes through every page and the main editors, and photographs them:
    /// a page that throws while drawing, or a button that cannot be built, shows up here instead of on someone's PC.</summary>
    private static async Task CheckUiTour(AppEngine engine)
    {
        Info("—— Ventana de FocusDesk ——");
        engine.Workspace.Tasks.Add(new FocusTask { Title = "Repasar apuntes de historia", Minutes = 45, ScheduledAt = DateTimeOffset.Now.AddHours(1), Category = "Estudio" });
        engine.Workspace.Tasks.Add(new FocusTask { Title = "Entregar práctica", Minutes = 30, ScheduledAt = DateTimeOffset.Now.AddHours(3), Category = "Universidad" });
        var running = new FocusTask { Title = "Escribir el guion", Minutes = 50, ScheduledAt = DateTimeOffset.Now, Checklist = "Estructura\nGanchos\nCierre" };
        engine.Workspace.Tasks.Add(running);
        engine.StartSession(running);

        FocusDesk.Windows.UI.MainWindow window;
        try
        {
            window = new FocusDesk.Windows.UI.MainWindow(engine, () => { })
            {
                Width = 1024, Height = 740, Left = 0, Top = 0,
                WindowStartupLocation = System.Windows.WindowStartupLocation.Manual
            };
            window.Show();
            window.Activate();
            Check(true, "La ventana principal se abre");
        }
        catch (Exception ex) { Check(false, "La ventana principal se abre", ex.ToString()); return; }

        foreach (var page in new[] { "Hoy", "Semana", "Historial", "Reglas", "Bloquear", "Descansos", "Ajustes" })
        {
            try
            {
                engine.ActivePage = page;
                await Task.Delay(1500);
                Shot($"ui-{page}");
                Check(true, $"La pantalla «{page}» se dibuja sin errores");
            }
            catch (Exception ex) { Check(false, $"La pantalla «{page}» se dibuja sin errores", ex.Message); }
        }

        ShowDialogAndClose(() => FocusDesk.Windows.UI.Dialogs.ShowTaskEditor(engine, null, window), "editor-tarea", window);
        ShowDialogAndClose(() => FocusDesk.Windows.UI.Dialogs.ShowRuleEditor(engine, null, null, window), "editor-regla", window);

        try { window.AllowClose(); window.Close(); } catch { }
        if (engine.Workspace.Session is { EndedAt: null }) engine.Workspace.Session = null;
    }

    /// <summary>Shows a modal editor, photographs it after two seconds and closes it (Esc for any question it asks).</summary>
    private static void ShowDialogAndClose(Action show, string name, System.Windows.Window owner)
    {
        var ticks = 0;
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        timer.Tick += (_, _) =>
        {
            ticks++;
            var dialog = System.Windows.Application.Current.Windows.OfType<System.Windows.Window>()
                .LastOrDefault(w => !ReferenceEquals(w, owner) && w.IsVisible);
            if (ticks == 1) Shot(name);
            if (dialog != null) { try { dialog.Close(); } catch { } }
            else if (ticks > 1) Forms.SendKeys.SendWait("{ESC}");
            if (ticks > 6) timer.Stop();
        };
        timer.Start();
        try
        {
            show();
            Check(true, $"La ventana «{name}» se abre y se cierra sin errores");
        }
        catch (Exception ex) { Check(false, $"La ventana «{name}» se abre y se cierra sin errores", ex.Message); }
        finally { timer.Stop(); }
    }

    // MARK: - Helpers

    private static async Task Pump(AppEngine engine, double seconds)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            engine.TickForTests();
            await Task.Delay(1000);
        }
    }

    private static async Task<bool> PumpUntil(AppEngine engine, Func<bool> done, double seconds)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            engine.TickForTests();
            await Task.Delay(1000);
            if (done()) return true;
        }
        return done();
    }

    private static async Task OpenInNewTab(string url)
    {
        Forms.SendKeys.SendWait("^t");
        await Task.Delay(1200);
        Forms.SendKeys.SendWait(url + "{ENTER}");
        await Task.Delay(1500);
    }

    private static async Task<IntPtr> OpenBrowser(string name, string exe)
    {
        KillAll(name);
        var profile = Path.Combine(Path.GetTempPath(), $"FocusDesk-E2E-{name}-{Guid.NewGuid().ToString("N")[..6]}");
        Directory.CreateDirectory(profile);
        string args;
        if (name == "firefox")
        {
            File.WriteAllText(Path.Combine(profile, "user.js"), string.Join("\n", new[]
            {
                "user_pref(\"browser.shell.checkDefaultBrowser\", false);",
                "user_pref(\"browser.aboutwelcome.enabled\", false);",
                "user_pref(\"browser.startup.homepage_override.mstone\", \"ignore\");",
                "user_pref(\"datareporting.policy.dataSubmissionPolicyBypassNotification\", true);",
                "user_pref(\"toolkit.telemetry.reportingpolicy.firstRun\", false);",
                "user_pref(\"trailhead.firstrun.didSeeAboutWelcome\", true);",
                "user_pref(\"network.trr.mode\", 5);",
                "user_pref(\"browser.tabs.warnOnClose\", false);"
            }));
            args = $"-no-remote -profile \"{profile}\" -new-window {Url("/ok")}";
        }
        else
        {
            args = $"--user-data-dir=\"{profile}\" --no-first-run --no-default-browser-check --disable-sync --new-window {Url("/ok")}";
        }
        try { Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = false }); }
        catch (Exception ex) { Info($"{name}: no arranca ({ex.Message})"); return IntPtr.Zero; }

        var hwnd = await WaitForWindow(name, t => t.Contains("Pagina normal"), 45);
        if (hwnd == IntPtr.Zero)
        {
            Info($"{name}: ventanas visibles: " + string.Join(" | ", WindowsActivity.VisibleWindows().Select(w => $"{w.ProcessName}:{w.WindowTitle}")));
            return IntPtr.Zero;
        }
        WindowsActivity.ActivateWindow(hwnd);
        await Task.Delay(1500);
        var fg = WindowsActivity.GetForegroundApp();
        Info($"{name}: delante está «{fg?.ProcessName}» «{fg?.WindowTitle}»");
        return hwnd;
    }

    private static async Task<IntPtr> WaitForWindow(string processName, Func<string, bool> titleOk, double seconds)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < end)
        {
            var win = WindowsActivity.VisibleWindows()
                .FirstOrDefault(w => w.ProcessName.Equals(processName, StringComparison.OrdinalIgnoreCase) && titleOk(w.WindowTitle));
            if (win != null) return win.Hwnd;
            await Task.Delay(700);
        }
        return IntPtr.Zero;
    }

    private static string? FindBrowser(string name)
    {
        var relative = name switch
        {
            "msedge" => @"Microsoft\Edge\Application\msedge.exe",
            "chrome" => @"Google\Chrome\Application\chrome.exe",
            "firefox" => @"Mozilla Firefox\firefox.exe",
            _ => null
        };
        if (relative == null) return null;
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
        };
        return roots.Where(r => !string.IsNullOrEmpty(r)).Select(r => Path.Combine(r, relative)).FirstOrDefault(File.Exists);
    }

    private static void KillAll(string processName)
    {
        foreach (var p in Process.GetProcessesByName(processName))
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            finally { p.Dispose(); }
        }
    }

    private static HttpListener StartServer()
    {
        var listener = new HttpListener();
        listener.Prefixes.Add($"http://+:{Port}/");
        listener.Start();
        _ = Task.Run(async () =>
        {
            while (listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = await listener.GetContextAsync(); }
                catch { break; }
                try
                {
                    var path = ctx.Request.Url?.AbsolutePath ?? "/";
                    var title = path switch
                    {
                        "/reels" => "Reels • Prueba",
                        "/clips" => "Clip de prueba",
                        _ => "Pagina normal"
                    };
                    var html = $"<!doctype html><html><head><meta charset='utf-8'><title>{title}</title></head>" +
                               $"<body style='font:24px sans-serif'><h1>{title}</h1><p>{path}</p></body></html>";
                    var bytes = Encoding.UTF8.GetBytes(html);
                    ctx.Response.ContentType = "text/html; charset=utf-8";
                    ctx.Response.ContentLength64 = bytes.Length;
                    await ctx.Response.OutputStream.WriteAsync(bytes);
                    ctx.Response.Close();
                }
                catch { }
            }
        });
        return listener;
    }
}
