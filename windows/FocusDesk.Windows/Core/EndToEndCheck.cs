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
            var weekday = DateTime.Now.ToString("dddd d MMM");
            Check(new[] { "lunes", "martes", "miércoles", "jueves", "viernes", "sábado", "domingo" }.Any(d => weekday.StartsWith(d)),
                "Las fechas salen en castellano aunque Windows esté en inglés", weekday);

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

            var browsers = new[] { "msedge", "chrome", "firefox", "brave", "opera" }
                .Select(name => (Name: name, Exe: FindBrowser(name)))
                .Where(b => b.Exe != null)
                .ToList();
            Info("Navegadores encontrados: " + string.Join(", ", browsers.Select(b => b.Name)));
            Check(browsers.Count > 0, "Hay al menos un navegador para probar");
            // In CI every browser must be there: a silent gap (Brave or Opera not installed) is a failure, not a pass.
            if (Environment.GetEnvironmentVariable("FOCUSDESK_E2E_REQUIRE_ALL") == "1")
                foreach (var expected in new[] { "msedge", "chrome", "firefox", "brave", "opera" })
                    Check(browsers.Any(b => b.Name == expected), $"{expected} está instalado en la máquina de pruebas");

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

            // The rest is checked with the quick block off, one rule at a time.
            quick.Enabled = false;
            if (browsers.Count > 0) await CheckSchedule(engine, browsers[0].Name, browsers[0].Exe!);
            await CheckDailyBudget(engine);
            if (browsers.Count > 0) await CheckStrict(engine, browsers[0].Name, browsers[0].Exe!);
            await CheckGame(engine);
            CheckProtections(engine, tempDir);
            await CheckRelaunch();
        }
        catch (Exception ex)
        {
            Check(false, "La prueba terminó sin excepciones", ex.ToString());
        }
        finally
        {
            try { server?.Stop(); } catch { }
            foreach (var n in new[] { "msedge", "chrome", "firefox", "brave", "opera", "notepad", "FortniteClient-Win64-Shipping" }) KillAll(n);
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

    // MARK: - Rules by time

    private static async Task CheckSchedule(AppEngine engine, string name, string exe)
    {
        Info($"—— Regla por horario ({name}) ——");
        var nowMin = DateTime.Now.Hour * 60 + DateTime.Now.Minute;
        var rule = new GeneralBlockRule
        {
            Name = "Horario de prueba", Kind = GeneralRuleKind.Schedule, Protection = SessionProtection.None, PunisherEnabled = false,
            StartMinutes = (nowMin + 1440 - 60) % 1440, EndMinutes = (nowMin + 60) % 1440,
            WebListMode = WebListMode.BlockListed, WebBlockAction = WebBlockAction.Redirect, Domains = $"{TestHost}/clips"
        };
        engine.Workspace.GeneralRules.Add(rule);
        Check(engine.IsRuleEnforcing(rule), "Una regla con un horario que incluye ahora está bloqueando");

        var hwnd = await OpenBrowser(name, exe);
        if (hwnd == IntPtr.Zero) { Check(false, $"{name}: se abre para la prueba de horario"); engine.Workspace.GeneralRules.Remove(rule); return; }
        await OpenInNewTab(Url("/clips"));
        var blocked = await PumpUntil(engine, () => TitleOf(hwnd).Contains(BlockPageTitle), 25);
        Shot("horario-1-dentro");
        Check(blocked && WindowOpen(hwnd), "Dentro del horario, la web de la regla pasa a la página de bloqueo", $"título «{TitleOf(hwnd)}»");

        rule.StartMinutes = (nowMin + 120) % 1440;
        rule.EndMinutes = (nowMin + 180) % 1440;
        Check(!engine.IsRuleEnforcing(rule), "Fuera del horario la regla no bloquea");
        Forms.SendKeys.SendWait("^l");
        await Task.Delay(500);
        Forms.SendKeys.SendWait(Url("/clips") + "{ENTER}");
        await Pump(engine, 9);
        Shot("horario-2-fuera");
        Check(TitleOf(hwnd).Contains("Clip de prueba"), "Fuera del horario la misma web se puede abrir", $"título «{TitleOf(hwnd)}»");

        engine.Workspace.GeneralRules.Remove(rule);
        KillAll(name);
        await Task.Delay(1500);
    }

    private static async Task CheckDailyBudget(AppEngine engine)
    {
        Info("—— Presupuesto diario de 1 minuto (Bloc de notas) ——");
        var rule = new GeneralBlockRule
        {
            Name = "Presupuesto de prueba", Kind = GeneralRuleKind.DailyLimit, DailyLimitMinutes = 1, Protection = SessionProtection.None,
            PunisherEnabled = false, BlockApps = true, AppListMode = AppListMode.BlockListed, BlockAction = AppBlockAction.Hide,
            Apps = new List<AllowedApp> { new("notepad", "Bloc de notas", @"C:\Windows\System32\notepad.exe") }
        };
        engine.Workspace.GeneralRules.Add(rule);
        Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true });
        var hwnd = await WaitForWindow("notepad", _ => true, 20);
        if (hwnd == IntPtr.Zero) { Check(false, "El Bloc de notas se abre para la prueba de presupuesto"); engine.Workspace.GeneralRules.Remove(rule); return; }

        // Uses it for 40 s: still allowed.
        for (var i = 0; i < 4; i++) { WindowsActivity.ActivateWindow(hwnd); await Pump(engine, 10); }
        Shot("presupuesto-1-dentro");
        Check(WindowOpen(hwnd), "Con presupuesto disponible la app se puede usar", $"usado {engine.Workspace.UsedSecondsToday(rule.Id, now: DateTimeOffset.Now):0} s");

        // Past the minute: blocked.
        var blocked = false;
        for (var i = 0; i < 6 && !blocked; i++)
        {
            if (WindowOpen(hwnd)) WindowsActivity.ActivateWindow(hwnd);
            blocked = await PumpUntil(engine, () => !WindowOpen(hwnd), 10);
        }
        Shot("presupuesto-2-agotado");
        Check(blocked, "Al gastar el minuto de presupuesto la app se bloquea",
            $"usado {engine.Workspace.UsedSecondsToday(rule.Id, now: DateTimeOffset.Now):0} s · aviso «{engine.Notice}»");
        engine.Workspace.GeneralRules.Remove(rule);
        KillAll("notepad");
    }

    // MARK: - Strict mode

    private static async Task CheckStrict(AppEngine engine, string name, string exe)
    {
        Info($"—— Modo estricto (solo Bloc de notas; abro {name}) ——");
        Process.Start(new ProcessStartInfo("notepad.exe") { UseShellExecute = true });
        var notepad = await WaitForWindow("notepad", _ => true, 20);
        if (notepad == IntPtr.Zero) { Check(false, "El Bloc de notas se abre para la prueba de modo estricto"); return; }
        var task = new FocusTask
        {
            Title = "Tarea estricta", Minutes = 30, Strict = true, PunisherEnabled = false, AppListMode = AppListMode.AllowListed,
            Apps = new List<AllowedApp> { new("notepad", "Bloc de notas", @"C:\Windows\System32\notepad.exe") }
        };
        engine.Workspace.Tasks.Add(task);
        engine.StartSession(task);
        WindowsActivity.ActivateWindow(notepad);
        await Pump(engine, 4);

        var browser = await OpenBrowser(name, exe);
        var back = await PumpUntil(engine, () =>
            WindowsActivity.GetForegroundApp()?.ProcessName.Equals("notepad", StringComparison.OrdinalIgnoreCase) == true ||
            (browser != IntPtr.Zero && !WindowOpen(browser)), 30);
        Shot("estricto");
        Check(back, "En modo estricto, abrir una app fuera de la tarea te devuelve a la app permitida",
            $"delante «{WindowsActivity.GetForegroundApp()?.ProcessName}» · aviso «{engine.Notice}»");
        engine.Workspace.Session = null;
        KillAll(name);
        KillAll("notepad");
        await Task.Delay(1500);
    }

    // MARK: - Games

    private static async Task CheckGame(AppEngine engine)
    {
        Info("—— Juego sin haber estudiado (Fortnite de prueba) ——");
        var rule = new GeneralBlockRule
        {
            Name = "Fortnite de prueba", Kind = GeneralRuleKind.WorkGoal, GameId = "fortnite", GoalMinutesRequired = 60,
            MaxDailyMatches = 2, MatchMinutes = 25, MatchOvertimeMinutes = 10, Protection = SessionProtection.None, PunisherEnabled = false
        };
        engine.Workspace.GeneralRules.Add(rule);
        Check(engine.IsRuleEnforcing(rule), "Sin haber estudiado, la regla del juego está bloqueando");

        var dir = Path.Combine(Path.GetTempPath(), "FocusDesk-E2E-juego");
        Directory.CreateDirectory(dir);
        var fake = Path.Combine(dir, "FortniteClient-Win64-Shipping.exe");
        try { File.Copy(Environment.ProcessPath!, fake, overwrite: true); }
        catch (Exception ex) { Check(false, "Se prepara un juego de prueba", ex.Message); engine.Workspace.GeneralRules.Remove(rule); return; }

        var game = Process.Start(new ProcessStartInfo(fake, "--e2e-ventana \"Fortnite (prueba)\"") { UseShellExecute = false });
        var hwnd = await WaitForWindow("FortniteClient-Win64-Shipping", _ => true, 30);
        Info($"Juego de prueba: ventana {(hwnd != IntPtr.Zero ? "abierta" : "no encontrada")}");
        if (hwnd != IntPtr.Zero) WindowsActivity.ActivateWindow(hwnd);
        var closed = await PumpUntil(engine, () => game == null || game.HasExited, 25);
        Shot("juego");
        Check(closed, "Abrir el juego sin haber estudiado lo cierra", $"aviso «{engine.Notice}»");
        try { if (game is { HasExited: false }) game.Kill(true); } catch { }
        engine.Workspace.GeneralRules.Remove(rule);
    }

    // MARK: - Protection

    private static void CheckProtections(AppEngine engine, string dataDir)
    {
        Info("—— Protección de reglas y espera que sobrevive a cerrar la app ——");
        var rule = new GeneralBlockRule
        {
            Name = "Protegida de prueba", Kind = GeneralRuleKind.Countdown, CountdownMinutes = 30, ActiveDeadline = new TrustedDeadline(1800),
            Protection = SessionProtection.Challenge, WebListMode = WebListMode.BlockListed, WebBlockAction = WebBlockAction.Redirect,
            Domains = "distraccion-de-prueba.com, otra-distraccion.com"
        };
        engine.Workspace.GeneralRules.Add(rule);
        Check(engine.IsRuleProtected(rule), "Una cuenta atrás con código está protegida mientras dura");

        engine.DeleteGeneralRule(rule);
        Check(engine.Workspace.GeneralRules.Any(r => r.Id == rule.Id) && !string.IsNullOrEmpty(engine.Error),
            "Una regla protegida no se puede borrar sin desbloquear", engine.Error);

        var off = rule.Clone();
        off.Enabled = false;
        engine.SaveGeneralRule(off);
        Check(engine.Workspace.GeneralRules.First(r => r.Id == rule.Id).Enabled, "Una regla protegida no se puede apagar sin desbloquear", engine.Error);

        var fewer = rule.Clone();
        fewer.Domains = "distraccion-de-prueba.com";
        engine.SaveGeneralRule(fewer);
        Check(engine.Workspace.GeneralRules.First(r => r.Id == rule.Id).Domains.Contains("otra-distraccion.com"),
            "A una regla protegida no se le pueden quitar webs sin desbloquear", engine.Error);

        var tighter = rule.Clone();
        tighter.Domains = "distraccion-de-prueba.com, otra-distraccion.com, una-mas.com";
        engine.SaveGeneralRule(tighter);
        Check(engine.Workspace.GeneralRules.First(r => r.Id == rule.Id).Domains.Contains("una-mas.com"),
            "A una regla protegida sí se le pueden añadir webs (endurecer no pide nada)", engine.Error);

        // «Espera»: asking to stop starts a wait; closing and reopening FocusDesk must not reset it.
        var key = "apagar la regla de prueba";
        Check(!engine.EvaluateDelay(key, 5), "Pedir parar una regla con espera no la para al momento");
        engine.Persist();
        using (var reopened = new AppEngine(dataDir, enablePlatformWatchers: false))
        {
            var allowed = reopened.EvaluateDelay(key, 5);
            var wait = reopened.Workspace.PendingStopWaits.FirstOrDefault(w => w.Key == key);
            var left = wait?.Request.RemainingSeconds(DateTimeOffset.Now) ?? 0;
            Check(!allowed && left > 240, "La espera sigue contando tras cerrar y abrir FocusDesk (no vuelve a empezar ni se salta)",
                $"permitido={allowed}, quedan {left:0} s");
        }
        engine.DeleteGeneralRule(rule, bypassProtection: true);
    }

    /// <summary>
    /// Protected rule running, FocusDesk killed from outside (as with Task Manager): the watcher must open it again.
    /// Uses the real data folder of the test machine, like a fresh installation.
    /// </summary>
    private static async Task CheckRelaunch()
    {
        Info("—— FocusDesk cerrado a la fuerza con una regla protegida ——");
        var self = Environment.ProcessId;
        var exe = Environment.ProcessPath!;
        using (var seed = new AppEngine(null, enablePlatformWatchers: false))
        {
            seed.LaunchQuickBlock(30, SessionProtection.Challenge, DistractionPreset.ShortVideos);
            seed.Persist();
        }
        var app = Process.Start(new ProcessStartInfo(exe) { UseShellExecute = false });
        if (app == null) { Check(false, "FocusDesk arranca para la prueba de vigilante"); return; }
        var window = await WaitForWindow("FocusDesk", t => t.Contains("FocusDesk"), 40);
        await Task.Delay(8000);
        var others = Process.GetProcessesByName("FocusDesk").Where(p => p.Id != self && p.Id != app.Id).Select(p => p.Id).ToList();
        Check(window != IntPtr.Zero && others.Count >= 1, "Con una regla protegida, FocusDesk arranca su vigilante",
            $"ventana={(window != IntPtr.Zero)}, procesos extra={others.Count}");
        Shot("vigilante-1-abierto");

        try { app.Kill(entireProcessTree: false); } catch { }
        var watchers = others.ToHashSet();
        var reopened = false;
        var end = DateTime.UtcNow.AddSeconds(40);
        while (DateTime.UtcNow < end && !reopened)
        {
            await Task.Delay(1500);
            reopened = WindowsActivity.VisibleWindows().Any(w =>
                w.ProcessName.Equals("FocusDesk", StringComparison.OrdinalIgnoreCase) && w.ProcessId != self && w.ProcessId != app.Id &&
                !watchers.Contains(w.ProcessId) && w.WindowTitle.Contains("FocusDesk"));
        }
        Shot("vigilante-2-reabierto");
        Check(reopened, "Si se cierra FocusDesk a la fuerza durante una regla protegida, se vuelve a abrir solo");

        RelaunchGuard.Remove();
        await Task.Delay(1500);
        foreach (var p in Process.GetProcessesByName("FocusDesk"))
        {
            if (p.Id == self) continue;
            try { p.Kill(entireProcessTree: false); } catch { }
        }
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
        var relatives = name switch
        {
            "msedge" => new[] { @"Microsoft\Edge\Application\msedge.exe" },
            "chrome" => new[] { @"Google\Chrome\Application\chrome.exe" },
            "firefox" => new[] { @"Mozilla Firefox\firefox.exe" },
            "brave" => new[] { @"BraveSoftware\Brave-Browser\Application\brave.exe" },
            "opera" => new[] { @"Programs\Opera\opera.exe", @"Opera\opera.exe" },
            _ => Array.Empty<string>()
        };
        var roots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)
        };
        var fixedPath = roots.Where(r => !string.IsNullOrEmpty(r))
            .SelectMany(r => relatives.Select(rel => Path.Combine(r, rel)))
            .FirstOrDefault(File.Exists);
        if (fixedPath != null || relatives.Length == 0) return fixedPath;
        // Installed in an unexpected sub-folder (a versioned one, for instance): look inside the vendor folder.
        foreach (var root in roots.Where(r => !string.IsNullOrEmpty(r)))
            foreach (var rel in relatives)
            {
                var dir = Path.Combine(root, Path.GetDirectoryName(rel)!);
                var leaf = Path.GetFileName(rel);
                try
                {
                    if (Directory.Exists(dir))
                    {
                        var hit = Directory.EnumerateFiles(dir, leaf, SearchOption.AllDirectories).FirstOrDefault();
                        if (hit != null) return hit;
                    }
                }
                catch { }
            }
        return null;
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
