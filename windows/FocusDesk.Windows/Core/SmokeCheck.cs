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
                Check(!engine.Workspace.Settings.RelaunchGuard, "Vigilante de relanzado apagado por defecto en Ajustes (como en Mac)");
                Check(!engine.Workspace.Settings.ProtectClipboard, "Protección de portapapeles apagada por defecto en Ajustes (como en Mac)");

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

                // Simulate 25 minutes worked and SAVED (checkpoint) right before the force-kill (Task Manager / taskkill)
                var s = engine1.Workspace.Session!;
                s.Accumulated = 25 * 60;
                s.RunningSince = now;
                s.RunningUptime = TrustedClock.ContinuousSeconds();
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

            // 3b. Paridad con Mac (auditoría 17-nov-2026): cada comprobación corresponde a un fallo ya corregido.
            // W-03: el tiempo con FocusDesk cerrado NO cuenta como trabajado.
            var downtimeDir = Path.Combine(tempDir, "downtime-sim");
            Directory.CreateDirectory(downtimeDir);
            using (var engineA = new AppEngine(downtimeDir, enablePlatformWatchers: false))
            {
                var plainTask = new FocusTask { Title = "Sin protección", IsScheduled = false, Minutes = 120 };
                engineA.SaveTask(plainTask);
                engineA.StartSession(plainTask);
                var sessionA = engineA.Workspace.Session!;
                sessionA.Accumulated = 10 * 60;
                sessionA.RunningSince = now.AddHours(-3);
                sessionA.RunningUptime = TrustedClock.ContinuousSeconds() - 3 * 3600;
                engineA.Persist();
            }
            using (var engineB = new AppEngine(downtimeDir, enablePlatformWatchers: false))
            {
                var back = engineB.Workspace.Session;
                var backMinutes = (back?.Elapsed(DateTimeOffset.Now) ?? 0) / 60.0;
                Check(back != null && back.Paused && backMinutes is >= 9.5 and <= 10.5,
                    $"Tras 3 h con FocusDesk cerrado la sesión conserva solo lo guardado, no las 3 h ({backMinutes:F1} min)");
            }

            // W-01: un elemento ilegible no tira el resto, y si no se puede leer NADA no se sobrescribe el archivo.
            var lossyDir = Path.Combine(tempDir, "lossy-sim");
            Directory.CreateDirectory(lossyDir);
            File.WriteAllText(Path.Combine(lossyDir, "workspace.json"),
                """{"schema":1,"tasks":[{"title":"Buena","minutes":30},{"title":"Rota","minutes":"no es un número"}],"generalRules":[]}""");
            using (var lossy = new AppEngine(lossyDir, enablePlatformWatchers: false))
            {
                Check(!lossy.DataUnreadable && lossy.Workspace.Tasks.Count == 1 && lossy.Workspace.Tasks[0].Title == "Buena",
                    "Una tarea dañada no hace perder las demás");
            }
            var unreadableDir = Path.Combine(tempDir, "unreadable-sim");
            Directory.CreateDirectory(unreadableDir);
            var unreadablePath = Path.Combine(unreadableDir, "workspace.json");
            const string brokenJson = "{ esto no es un archivo de FocusDesk";
            File.WriteAllText(unreadablePath, brokenJson);
            using (var unreadable = new AppEngine(unreadableDir, enablePlatformWatchers: false))
            {
                unreadable.Workspace.Tasks.Add(new FocusTask { Title = "Nueva", IsScheduled = false });
                var saved = unreadable.Persist();
                Check(unreadable.DataUnreadable && !saved && File.ReadAllText(unreadablePath) == brokenJson,
                    "Si los datos no se pueden leer, FocusDesk no escribe encima del archivo");
            }

            // W-02: FocusDesk se reconoce a sí mismo con el nombre que tenga el .exe.
            Check(FocusRules.SystemExemptProcesses.Contains(FocusRules.OwnProcessName) &&
                  FocusRules.NeverTerminateProcesses.Contains(FocusRules.OwnProcessName) &&
                  FocusRules.IsOwnProcess(Environment.ProcessId),
                  "FocusDesk nunca se bloquea ni se cierra a sí mismo (sea cual sea el nombre del .exe)");

            // W-05: los juegos no confunden otros programas con el juego.
            var warzoneGame = GameCatalog.Find("warzone")!;
            var minecraftGame = GameCatalog.Find("minecraft")!;
            Check(!warzoneGame.Matches("Code", @"C:\Users\x\AppData\Local\Programs\Microsoft VS Code\Code.exe", "proyecto - Visual Studio Code") &&
                  warzoneGame.Matches("cod", null, null),
                  "Warzone no confunde VS Code («code») con el juego («cod»)");
            Check(!minecraftGame.Matches("chrome", @"C:\Program Files\Google\Chrome\Application\chrome.exe", "Minecraft - Wikipedia") &&
                  minecraftGame.Matches("javaw", null, "Minecraft 1.20.4"),
                  "Minecraft no cierra un navegador cuyo título dice «minecraft», pero reconoce javaw");

            // W-07 / W-09: las repeticiones avanzan solas y mantienen la hora de reloj.
            var overdueSeries = new List<FocusTask>
            {
                new() { Title = "Diaria atrasada", ScheduledAt = now.AddDays(-3), Minutes = 30, RepeatRule = RepeatRule.Daily }
            };
            var rolled = SeriesRoller.Roll(overdueSeries, null, now);
            Check(rolled == 1 && overdueSeries.Count == 2 &&
                  overdueSeries[0].ScheduledAt.LocalDateTime.Date >= now.LocalDateTime.Date &&
                  overdueSeries.Count(t => t.RepeatRule == RepeatRule.Never && t.ScheduledAt < now) == 1,
                  "Una serie atrasada avanza a hoy y deja la ocurrencia perdida como tarea atrasada");
            var nineAm = new FocusTask
            {
                Title = "A las 9",
                ScheduledAt = FocusRules.FromLocal(new DateTime(2026, 10, 20, 9, 0, 0)),
                RepeatRule = RepeatRule.Daily
            };
            var nextNine = nineAm.NextOccurrence(FocusRules.FromLocal(new DateTime(2026, 11, 3, 0, 0, 0)));
            Check(nextNine != null && nextNine.ScheduledAt.LocalDateTime.TimeOfDay == TimeSpan.FromHours(9),
                "Una repetición diaria mantiene las 09:00 aunque cambie el horario de verano");
            var customDaysTask = new FocusTask { Title = "Lunes y jueves", RepeatRule = RepeatRule.CustomDays, RepeatDays = new HashSet<int> { 2, 5 } };
            Check(customDaysTask.Valid, "«Días concretos» con días elegidos es una tarea válida");

            // W-08: reiniciar un bloqueo protegido en marcha no puede acortarlo sin código.
            using (var restartEngine = new AppEngine(Path.Combine(tempDir, "restart-sim"), enablePlatformWatchers: false))
            {
                var longBlock = new GeneralBlockRule
                {
                    Name = "Bloqueo largo",
                    Kind = GeneralRuleKind.Countdown,
                    Enabled = true,
                    Domains = "youtube.com",
                    Protection = SessionProtection.Challenge
                };
                longBlock.StartCountdown(180);
                longBlock.CountdownMinutes = 60;
                Check(restartEngine.RestartLoosening(longBlock, GeneralRuleKind.Countdown) != null,
                    "«Activar» otra vez un bloqueo protegido con más tiempo del elegido pide código (no lo acorta gratis)");
            }

            // W-10..W-30: más paridad con Mac (castigo, buscadores, espera persistente, horario, strict, URLs, palabras).
            var punisher = new DistractionPunisher();
            var earlyAttempts = punisher.Register(10) | punisher.Register(11) | punisher.Register(12);
            Check(!earlyAttempts && punisher.Register(13) && punisher.IsActive(14),
                "El castigo salta al 4.º intento seguido (no al 3.º), como en Mac");

            Check(SearchMediaRules.Matches("www.google.com", "/search?q=gatos&udm=2") == "Google Imágenes" &&
                  SearchMediaRules.Matches("search.brave.com", "/images?q=gatos") == "Brave Imágenes" &&
                  SearchMediaRules.Matches("www.bing.com", "/videos/search?q=x") == "Bing Vídeos" &&
                  SearchMediaRules.Matches("www.google.com", "/search?q=udm%3D2") == null,
                "Imágenes y vídeos de buscadores: mismos buscadores y rutas que en Mac, sin falsos positivos");

            Check(FocusRules.MatchesTitleKeyword("Vídeo de gatos", "video", false) != null &&
                  FocusRules.MatchesTitleKeyword("C++ y mucho más", "C++", true) != null &&
                  FocusRules.MatchesTitleKeyword("Shortstop", "Shorts", true) == null,
                "Palabras de título: ignoran tildes y respetan «palabra completa»");

            Check(FocusRules.NormalizeDomainEntry("https://www.reddit.com/r/programming") == "reddit.com" &&
                  FocusRules.NormalizedRedirectUrl("notion.so")?.Host == "notion.so",
                "Una URL pegada con ruta se queda en el dominio y la redirección sin https:// se normaliza, como en Mac");

            Check(!FocusRules.AppAllowed("codeblocks", new[] { new AllowedApp("code", "VS Code", "") }, AppListMode.AllowListed) &&
                  FocusRules.AppAllowed("code", new[] { new AllowedApp("code", "VS Code", "") }, AppListMode.AllowListed),
                "Una app permitida es esa app, no «cualquiera que contenga el nombre»");

            var nightRule = new GeneralBlockRule
            {
                Name = "Noche",
                Kind = GeneralRuleKind.Schedule,
                Enabled = true,
                StartMinutes = 22 * 60 + 30,
                EndMinutes = 7 * 60 + 30,
                Domains = "youtube.com"
            };
            var elevenPm = FocusRules.FromLocal(new DateTime(2026, 11, 18, 23, 0, 0));
            Check(Math.Abs(nightRule.RemainingLockSeconds(elevenPm) - 8.5 * 3600) < 1,
                "Una regla por horario dice cuánto falta para que acabe su tramo (no «hasta medianoche»)");

            using (var waitEngine = new AppEngine(Path.Combine(tempDir, "wait-sim"), enablePlatformWatchers: false))
            {
                var firstPress = waitEngine.EvaluateDelay("pausar «Prueba»", 5);
                var secondPress = waitEngine.EvaluateDelay("pausar «Prueba»", 5);
                Check(!firstPress && !secondPress && waitEngine.Workspace.PendingStopWaits.Count == 1,
                    "La espera empieza al pedirla y sigue en marcha (guardada) al repetirla antes de tiempo");
                waitEngine.Workspace.PendingStopWaits[0].Request.Deadline = new TrustedDeadline(0);
                Check(waitEngine.EvaluateDelay("pausar «Prueba»", 5) && waitEngine.Workspace.PendingStopWaits.Count == 0,
                    "Terminada la espera, repetir la acción la deja pasar");
            }

            var strict = new StrictRedirectTracker();
            var noAllowedOpen = strict.EvaluateUnallowed(false, DateTimeOffset.UtcNow);
            Check(noAllowedOpen.Kind == StrictDecisionKind.PauseSession,
                "Modo estricto sin ninguna app permitida abierta: se rinde en vez de cerrar todo lo que enfocas");

            var weeklyHead = new FocusTask
            {
                Title = "Semanal",
                ScheduledAt = FocusRules.FromLocal(new DateTime(2026, 11, 2, 10, 0, 0)),
                RepeatRule = RepeatRule.Weekly
            };
            var coming = weeklyHead.UpcomingOccurrences(FocusRules.FromLocal(new DateTime(2026, 11, 20, 0, 0, 0)), FocusRules.FromLocal(new DateTime(2026, 12, 10, 0, 0, 0)));
            Check(coming.Count == 3 && coming.All(t => t.ScheduledAt.LocalDateTime.TimeOfDay == TimeSpan.FromHours(10)),
                "Las repeticiones futuras se calculan a la misma hora de reloj (3 lunes entre el 20-nov y el 10-dic)");

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
            Check(SystemSettingsGuard.CheckGuardedPane(new ForegroundAppInfo(101, "SystemSettings", null, "Configuración - Aplicaciones instaladas", IntPtr.Zero)) != null,
                "SystemSettingsGuard bloquea Configuración de Windows (SystemSettings)");
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
            Check(defTask.AppListMode == AppListMode.AllowListed && defTask.WebListMode == WebListMode.AllowListed,
                "Nueva tarea usa «solo las de la lista» por defecto, igual que en Mac");
            Check(FocusProfile.Defaults().All(p => p.WebBlockAction == WebBlockAction.Warn && p.Protection == SessionProtection.None && !p.BlockGameLibraries),
                "Perfiles por defecto arrancan sin bloqueo ni protección (versión pública, como en Mac)");

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

            // 8. Parity with macOS (24-nov): moving and resizing from the agenda, one occurrence of a series,
            //    saving a task as a profile, deleting a category, importing rules and the interface preferences.
            using (var engine4 = new AppEngine(Path.Combine(tempDir, "parity-sim"), enablePlatformWatchers: false))
            {
                var baseDay = DateTime.Now.Date.AddDays(2);
                var plain = new FocusTask { Title = "Mover y alargar", Minutes = 30, ScheduledAt = FocusRules.FromLocal(baseDay.AddHours(10)) };
                engine4.SaveTask(plain);
                FocusTask Current(Guid id) => engine4.Workspace.Tasks.First(t => t.Id == id);

                engine4.ShiftTask(Current(plain.Id), 15);
                Check(Current(plain.Id).ScheduledAt.LocalDateTime == baseDay.AddHours(10).AddMinutes(15),
                    "«Retrasar 15 minutos» mueve la tarea un cuarto de hora");
                engine4.ResizeTask(Current(plain.Id), 15);
                Check(Current(plain.Id).Minutes == 45, "«Alargar 15 minutos» deja la tarea de 30 en 45 min");
                engine4.MoveTaskTo(Current(plain.Id), baseDay.AddDays(1).AddHours(9));
                Check(Current(plain.Id).ScheduledAt.LocalDateTime == baseDay.AddDays(1).AddHours(9),
                    "Arrastrar una tarea a otro día la deja ese día a la hora elegida");
                Check(engine4.NextTask() != null, "Con tareas pendientes hay «Tu siguiente paso»");

                var series = new FocusTask { Title = "Estudiar Álgebra", Minutes = 45, RepeatRule = RepeatRule.Daily, ScheduledAt = FocusRules.FromLocal(baseDay.AddHours(22)) };
                engine4.SaveTask(series);
                var workdays = engine4.Workspace.Settings.Workdays;
                var second = series.NextOccurrence(series.ScheduledAt, workdays)!;
                var editedDay = series.Clone();
                editedDay.ScheduledAt = second.ScheduledAt;
                editedDay.Title = "Estudiar Álgebra (repaso)";
                editedDay.Minutes = 20;
                engine4.SaveOccurrenceOnly(Current(series.Id), editedDay, second.ScheduledAt);
                var head = Current(series.Id);
                var single = engine4.Workspace.Tasks.FirstOrDefault(t => t.Title == "Estudiar Álgebra (repaso)");
                Check(single != null && single.RepeatRule == RepeatRule.Never && single.SeriesId == series.Id && single.Minutes == 20,
                    "«Solo esta ocurrencia» crea una tarea suelta para ese día");
                Check(head.Title == "Estudiar Álgebra" && head.Minutes == 45 && head.ScheduledAt == series.ScheduledAt &&
                      head.SkippedDates.Contains(FocusRules.DayKey(second.ScheduledAt)),
                    "…y el resto de la serie sigue igual, saltándose ese día");
                var afterSkip = head.NextOccurrence(head.ScheduledAt, workdays);
                Check(afterSkip != null && afterSkip.ScheduledAt.LocalDateTime.Date == baseDay.AddDays(2),
                    "La serie continúa al día siguiente del que se editó suelto");
                var todayOnly = head.Clone();
                todayOnly.Title = "Estudiar Álgebra (solo hoy)";
                engine4.SaveOccurrenceOnly(head, todayOnly, head.ScheduledAt);
                Check(Current(series.Id).ScheduledAt.LocalDateTime.Date == baseDay.AddDays(2),
                    "Editar suelto el día en que está la serie la hace avanzar a su siguiente fecha");

                var withBlock = new FocusTask { Title = "Programar", Minutes = 50, Domains = "github.com", WebBlockAction = WebBlockAction.Redirect, Checklist = "Uno\nDos" };
                var profilesBefore = engine4.Workspace.Profiles.Count;
                engine4.SaveProfileFromTask(withBlock, "Programación de prueba");
                var savedProfile = engine4.Workspace.Profiles.FirstOrDefault(p => p.Name == "Programación de prueba");
                Check(savedProfile != null && savedProfile.Minutes == 50 && savedProfile.Domains == "github.com" &&
                      savedProfile.WebBlockAction == WebBlockAction.Redirect && engine4.Workspace.Profiles.Count == profilesBefore + 1,
                    "«Guardar como perfil» conserva duración, webs y acción de la tarea");

                engine4.AddCategory("Categoría de prueba", 0.4, 0.78, 0.9);
                var categoriesBefore = engine4.Workspace.Settings.Categories.Count;
                engine4.DeleteCategory("Categoría de prueba");
                Check(engine4.Workspace.Settings.Categories.Count == categoriesBefore - 1, "Una categoría se puede borrar en Ajustes");

                engine4.LaunchQuickBlock(30, SessionProtection.Challenge);
                var guarded = engine4.Workspace.GeneralRules.First(r => r.Kind == GeneralRuleKind.Countdown);
                var rulesFile = Path.Combine(tempDir, "reglas-exportadas.json");
                engine4.ExportRules(rulesFile);
                using (var engine5 = new AppEngine(Path.Combine(tempDir, "import-sim"), enablePlatformWatchers: false))
                {
                    engine5.ImportRules(rulesFile);
                    Check(engine5.Workspace.GeneralRules.Any(r => r.Id == guarded.Id), "«Importar reglas» añade las reglas de un archivo exportado");
                }
                var loosened = guarded.Clone();
                loosened.Protection = SessionProtection.None;
                File.WriteAllBytes(rulesFile, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new List<GeneralBlockRule> { loosened }, WorkspaceStore.PrettyJsonOptions));
                engine4.ImportRules(rulesFile);
                Check(engine4.Workspace.GeneralRules.First(r => r.Id == guarded.Id).Protection == SessionProtection.Challenge,
                    "Importar no afloja una regla protegida que está activa (trinquete)");

                engine4.Prefs.HourlyLayout = false;
                engine4.Prefs.Save();
                Check(!UiPreferences.Load(engine4.Store.DirectoryPath).HourlyLayout, "La vista elegida en «Hoy» (horas o lista) se recuerda entre arranques");
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
