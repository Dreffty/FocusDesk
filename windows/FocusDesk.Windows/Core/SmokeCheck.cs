using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using FocusDesk.Windows.Platform;

namespace FocusDesk.Windows.Core;

public static class SmokeCheck
{
    public static int Run()
    {
        var log = new List<string>();
        var failures = new List<string>();

        void Check(bool condition, string name, string? detail = null)
        {
            if (condition)
            {
                log.Add($"PASS · {name}");
            }
            else
            {
                var msg = detail == null ? $"FAIL · {name}" : $"FAIL · {name}: {detail}";
                log.Add(msg);
                failures.Add(msg);
            }
        }

        var tempDir = Path.Combine(Path.GetTempPath(), "FocusDesk-Smoke-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(tempDir);

        try
        {
            var now = DateTimeOffset.Now;

            // 1. Clean public startup & deletable rules invariant
            using (var engine = new AppEngine(tempDir, enablePlatformWatchers: false))
            {
                Check(engine.Workspace.GeneralRules.All(r => r.CanBeDeleted && !r.Enabled), "Inicio limpio: reglas de ejemplo desactivadas y borrables");
                Check(engine.Workspace.Settings.RelaunchGuard, "Vigilante de relanzado activo por defecto en Ajustes");
                Check(engine.Workspace.Settings.ProtectClipboard, "Protección de portapapeles activa por defecto en Ajustes");

                // 2. Task creation, session start, pause, resume, +10m, completion & repeat series
                var task = new FocusTask
                {
                    Title = "Estudiar Álgebra",
                    Category = "Estudio",
                    ScheduledAt = now.AddMinutes(5),
                    IsScheduled = true,
                    Minutes = 45,
                    Strict = true,
                    AppListMode = AppListMode.AllowListed,
                    Apps = new List<AllowedApp> { new("code", "VS Code", "") },
                    WebListMode = WebListMode.BlockListed,
                    WebBlockAction = WebBlockAction.Redirect,
                    Domains = "youtube.com, tiktok.com",
                    BlockedTitleKeywords = "Shorts, Reels",
                    Protection = SessionProtection.Challenge,
                    UnlockChars = 24,
                    RepeatRule = RepeatRule.Daily
                };
                engine.SaveTask(task);
                Check(engine.Workspace.Tasks.Count == 1 && string.IsNullOrEmpty(engine.Error), "Crear nueva tarea protegida con bloqueo de apps y webs");

                // Run-up protection check (task starts in 5 min, default run-up is 10 min)
                Check(engine.IsTaskProtected(task, now), "Protección previa al inicio (Run-Up) activa a 5 min de empezar");

                var softenedTask = task.Clone();
                softenedTask.Protection = SessionProtection.None;
                engine.SaveTask(softenedTask, bypassProtection: false);
                Check(!string.IsNullOrEmpty(engine.Error) && engine.Workspace.Tasks[0].Protection == SessionProtection.Challenge,
                    "Trinquete impide rebajar protección de tarea sin código");

                engine.DeleteTask(task, bypassProtection: false);
                Check(engine.Workspace.Tasks.Count == 1 && !string.IsNullOrEmpty(engine.Error),
                    "Trinquete impide borrar tarea protegida sin código");

                // Start session
                engine.StartSession(task);
                Check(engine.Workspace.Session != null && !engine.Workspace.Session.Paused, "Iniciar sesión de tarea");

                // Hardening a running session is free; shortening is blocked
                var shorterTask = task.Clone();
                shorterTask.Minutes = 20;
                engine.SaveTask(shorterTask, bypassProtection: false);
                Check(!string.IsNullOrEmpty(engine.Error) && engine.Workspace.Session!.Budget == 45 * 60,
                    "Trinquete impide acortar sesión protegida en marcha");

                var longerTask = task.Clone();
                longerTask.Minutes = 60;
                engine.SaveTask(longerTask, bypassProtection: false);
                Check(string.IsNullOrEmpty(engine.Error) && engine.Workspace.Session!.Budget == 60 * 60,
                    "Trinquete permite alargar sesión protegida en marcha sin pedir código");

                // Pause, Resume, Add +10m, Finish & Confirm
                engine.PauseSession();
                Check(engine.Workspace.Session!.Paused, "Pausar sesión tras desbloqueo");
                engine.ResumeSession();
                Check(!engine.Workspace.Session!.Paused, "Reanudar sesión");
                engine.AddSessionMinutes(10);
                Check(engine.Workspace.Session!.Budget == 70 * 60, "Ampliar sesión +10 min");

                engine.ConfirmSession(completed: true, note: "Tema 1 completado");
                Check(engine.Workspace.Session == null && engine.Workspace.History.Count == 1, "Terminar tarea y guardar en historial");
                Check(engine.Workspace.Tasks.Count(t => !t.Completed) == 1, "Tarea repetitiva diaria genera la siguiente ocurrencia al completarse");

                // Cancel / Emergency exit flow
                var forcedTask = new FocusTask
                {
                    Title = "Examen simulacro",
                    IsScheduled = false,
                    Minutes = 60,
                    Protection = SessionProtection.Forced
                };
                engine.SaveTask(forcedTask);
                engine.StartSession(forcedTask);
                engine.Workspace.RecordAudit("Salida de emergencia", "Cancelación de emergencia de «Examen simulacro».");
                engine.CancelSession();
                Check(engine.Workspace.Session == null && engine.Workspace.History.First().Cancelled, "Cancelar sesión en modo Hasta el final con salida de emergencia");
            }

            // 3. Force-Quit vs Legitimate Quit (RelaunchGuard & Crash Recovery)
            var crashDir = Path.Combine(tempDir, "crash-sim");
            Directory.CreateDirectory(crashDir);
            using (var engine1 = new AppEngine(crashDir, enablePlatformWatchers: false))
            {
                var protTask = new FocusTask
                {
                    Title = "Bloque blindado",
                    IsScheduled = false,
                    Minutes = 60,
                    Protection = SessionProtection.Challenge
                };
                engine1.SaveTask(protTask);
                engine1.StartSession(protTask);

                // Simulate 25 minutes elapsed before force-kill (Task Manager / taskkill)
                var s = engine1.Workspace.Session!;
                s.RunningSince = now.AddMinutes(-25);
                s.RunningUptime = TrustedClock.ContinuousSeconds() - 25 * 60;
                s.ResumeOnLaunchUntil = now.AddMinutes(35);
                engine1.Workspace.ClosedBySystemAt = null; // Unclean force-quit!
                engine1.Persist();

                var watcherSaysRelaunch = RelaunchGuard.ShouldRelaunch(engine1.Workspace, DateTimeOffset.UtcNow);
                Check(watcherSaysRelaunch, "Forzar salida (sin código): el vigilante detecta cierre forzoso y ordena reabrir FocusDesk");
            }

            // Reopen AppEngine after force-kill: session must auto-resume AND keep the 25 minutes already worked!
            using (var engine2 = new AppEngine(crashDir, enablePlatformWatchers: false))
            {
                var resumed = engine2.Workspace.Session;
                Check(resumed != null && !resumed.Paused, "Al reabrirse tras forzar salida, la sesión protegida continúa sola en marcha");
                var elapsedMin = (resumed?.Elapsed(DateTimeOffset.Now) ?? 0) / 60.0;
                Check(elapsedMin is >= 24.5 and <= 26.0, $"Al reabrirse tras forzar salida, conserva los ~25 min ya trabajados ({elapsedMin:F1} min)");

                // Now simulate a LEGITIMATE quit (user typed the unlock code in TryQuitApp)
                resumed!.Pause(DateTimeOffset.Now);
                engine2.Workspace.ClosedBySystemAt = DateTimeOffset.UtcNow;
                engine2.Persist();

                var watcherAfterLegitQuit = RelaunchGuard.ShouldRelaunch(engine2.Workspace, DateTimeOffset.UtcNow);
                Check(!watcherAfterLegitQuit, "Cierre legítimo con código: el vigilante respeta la salida y NO reabre FocusDesk");
            }

            // 4. Unlock Challenge & Emergency Code verification
            var code24 = UnlockChallenge.Make(24);
            var code60 = UnlockChallenge.Make(60);
            Check(code24.Length == 24 && UnlockChallenge.Matches(code24, code24), "Reto de código de 24 caracteres exacto");
            Check(code60.Length == 60 && UnlockChallenge.Matches(code60, code60), "Código de emergencia de 60 caracteres para modo Hasta el final");
            var wrong = code24[..10] + "#" + code24[11..];
            Check(!UnlockChallenge.Matches(wrong, code24) && UnlockChallenge.CorrectPrefix(wrong, code24) == 10,
                "Detección instantánea de fallo al teclear carácter incorrecto");

            // 5. All 7 General Rule kinds + Ratchet + Game detectors
            var lolGame = GameCatalog.Find(GameCatalog.LeagueId)!;
            var lolRule = GeneralBlockRule.GameTemplate(lolGame);
            Check(lolRule.Valid && lolRule.IsEnforcing(now, workedTodaySeconds: 0, matchesToday: 0),
                "Regla de League of Legends bloquea antes de completar 60 min de estudio");
            Check(!lolRule.IsEnforcing(now, workedTodaySeconds: 3600, matchesToday: 0),
                "Regla de League of Legends desbloquea la 1.ª partida tras 60 min de estudio");
            Check(lolRule.IsEnforcing(now, workedTodaySeconds: 3600, matchesToday: 1),
                "Modo bucle (1 h -> 1 partida): vuelve a bloquear tras jugar la 1.ª partida hasta estudiar la 2.ª hora");
            Check(!lolRule.IsEnforcing(now, workedTodaySeconds: 3600, matchesToday: 1, isMatchInProgress: true),
                "DeferBlockUntilMatchEnds: nunca cierra el juego a mitad de una partida en curso");
            Check(lolRule.IsProtectedNow(now, workedTodaySeconds: 3600, matchesToday: 0),
                "Modo bucle mantiene la protección activa entre ciclos");

            var singleGoalRule = GeneralBlockRule.GameTemplate(lolGame);
            singleGoalRule.OneMatchPerGoalBlock = false;
            Check(!singleGoalRule.IsProtectedNow(now, workedTodaySeconds: 3600, matchesToday: 0),
                "Modo meta única (sin bucle) permite apagar la regla al cumplir la hora de estudio");

            // Valorant local presence JSON parser
            var valB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes("{\"sessionLoopState\":\"INGAME\"}"));
            var valJson = $"{{\"presences\":[{{\"product\":\"valorant\",\"private\":\"{valB64}\"}}]}}";
            Check(ValorantMatchRules.ParsePresenceJson(valJson) == ValorantMatchPhase.InMatch,
                "Detector exacto de Valorant reconoce partida en curso (INGAME)");

            // Valve GSI parser for CS2 & Dota 2
            var cs2Event = ValveGSI.Parse("{\"provider\":{\"appid\":730},\"map\":{\"phase\":\"live\"}}");
            var dotaEvent = ValveGSI.Parse("{\"provider\":{\"appid\":570},\"map\":{\"game_state\":\"DOTA_GAMERULES_STATE_POST_GAME\"}}");
            Check(cs2Event is { GameId: "cs2", Phase: ValveGSI.MatchPhase.Live } &&
                  dotaEvent is { GameId: "dota2", Phase: ValveGSI.MatchPhase.GameOver },
                "Detector exacto Valve GSI reconoce CS2 (live) y Dota 2 (post_game)");

            // Timed match planner with overtime
            var fnGame = GameCatalog.Find("fortnite")!;
            var fnRule = GeneralBlockRule.GameTemplate(fnGame);
            var stepStart = TimedMatchPlanner.Evaluate(fnRule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 3600, matchesToday: 0, now: now);
            Check(stepStart.Kind == TimedMatchPlanner.StepKind.Start, "Detector por tiempo arranca partida al abrir el juego con estudio cumplido");

            // 6. Windows Platform Guards (SystemSettingsGuard, ClipboardGuard, StudyVerifier, BlockPage)
            Check(SystemSettingsGuard.CheckGuardedPane(new ForegroundAppInfo(100, "Taskmgr", null, "Administrador de tareas", IntPtr.Zero)) != null,
                "SystemSettingsGuard bloquea Administrador de tareas (Taskmgr)");
            Check(SystemSettingsGuard.CheckGuardedPane(new ForegroundAppInfo(101, "ApplicationFrameHost", null, "Configuración - Aplicaciones instaladas", IntPtr.Zero)) != null,
                "SystemSettingsGuard bloquea Configuración de Windows UWP (ApplicationFrameHost)");
            Check(SystemSettingsGuard.CheckGuardedPane(new ForegroundAppInfo(102, "powershell", null, "Windows PowerShell - taskkill /f /im FocusDesk.exe", IntPtr.Zero)) != null,
                "SystemSettingsGuard bloquea intento de taskkill en Terminal");

            Check(ClipboardGuardRules.Violation("taskkill /f /im FocusDesk.exe", "", WebListMode.BlockListed, WebBlockAction.Warn) != null,
                "ClipboardGuard limpia comando taskkill del portapapeles");
            Check(ClipboardGuardRules.Violation("https://www.youtube.com/shorts/abc", "youtube.com/shorts", WebListMode.BlockListed, WebBlockAction.Redirect) != null,
                "ClipboardGuard limpia enlaces bloqueados del portapapeles");

            var (studyApps, studyWebs) = StudySources.Active(StudySources.Defaults(), FocusRules.DayKey(now));
            Check(StudyActivityVerifier.IsVerifiedStudyActivity(10, "code", @"C:\Program Files\Microsoft VS Code\Code.exe", true, "Program.cs", null, null, studyApps, studyWebs),
                "StudyActivityVerifier acredita estudio activo en VS Code");
            Check(!StudyActivityVerifier.IsVerifiedStudyActivity(10, "LeagueClientUx", @"C:\Riot Games\League of Legends\LeagueClientUx.exe", true, "League of Legends", null, null, studyApps, studyWebs),
                "StudyActivityVerifier rechaza juegos como estudio");

            var blockUri = BlockPageGenerator.Write("Estudiar", "youtube.com", 1200, "Sigue con el foco", new[] { "Paso 1" }, tempDir);
            Check(blockUri.StartsWith("file://", StringComparison.OrdinalIgnoreCase) && File.Exists(Path.Combine(tempDir, "bloqueada.html")),
                "Generador de página de bloqueo web crea bloqueada.html");

            // 7. Pass 2 checks: Defaults, Quick Block, Micro-Pauses, Vital Folders, Flexible .exe matching
            var defTask = new FocusTask();
            Check(defTask.AppListMode == AppListMode.BlockListed && defTask.WebListMode == WebListMode.BlockListed,
                "Nueva tarea usa modo lista negra por defecto para evitar bloquear el PC por error");
            Check(FocusProfile.Defaults().All(p => p.WebBlockAction == WebBlockAction.Redirect && p.BlockGameLibraries),
                "Perfiles por defecto de «Bloquear ahora» tienen bloqueo real de distracciones activo");

            Check(FolderGuard.ProblemWithFolder(@"C:\") != null &&
                  FolderGuard.ProblemWithFolder(@"C:\Windows") != null &&
                  FolderGuard.ProblemWithFolder(@"C:\Juegos\Riot") == null,
                "FolderGuard protege carpetas críticas de Windows (C:\\, C:\\Windows) y permite carpetas de juegos");

            Check(!FocusRules.AppAllowed("VALORANT-Win64-Shipping.exe", new[] { new AllowedApp("valorant", "Valorant", "") }, AppListMode.BlockListed),
                "AppAllowed reconoce procesos compuestos de juegos (VALORANT-Win64-Shipping) al indicar 'valorant'");

            using (var engine3 = new AppEngine(Path.Combine(tempDir, "quick-sim"), enablePlatformWatchers: false))
            {
                engine3.LaunchQuickBlock(30, SessionProtection.Challenge);
                var qb = engine3.Workspace.GeneralRules.FirstOrDefault(r => r.Kind == GeneralRuleKind.Countdown);
                Check(qb != null && engine3.IsRuleEnforcing(qb) && engine3.IsRuleProtected(qb),
                    "Bloqueo rápido inmediato de 30 min se activa y queda protegido por código");

                engine3.UseMicroPause(qb!);
                Check(!engine3.IsRuleEnforcing(qb!) && engine3.Workspace.MicroPausesUsedToday(qb!.Id) == 1,
                    "Micro-pausa suspende temporalmente el bloqueo y descuenta del límite diario");
            }
        }
        finally
        {
            try { Directory.Delete(tempDir, recursive: true); } catch { }
        }

        var summary = failures.Count == 0
            ? $"PASS · {log.Count} comprobaciones de Windows superadas."
            : $"FAIL · {failures.Count} fallo(s) de {log.Count} comprobaciones.";
        log.Add(summary);

        var report = string.Join(Environment.NewLine, log);
        Console.WriteLine(report);
        try { File.WriteAllText("windows-smoke-report.txt", report, Encoding.UTF8); } catch { }
        return failures.Count == 0 ? 0 : 1;
    }
}
