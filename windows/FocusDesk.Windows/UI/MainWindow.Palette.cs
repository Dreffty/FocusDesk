using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using FocusDesk.Windows.Core;

namespace FocusDesk.Windows.UI;

/// <summary>
/// «Buscar función» (Ctrl+K), «Novedades» and the list of shortcuts: the ways in to everything FocusDesk can do, as in
/// macOS FeatureFinder.swift. Every entry lands where the feature lives.
/// </summary>
public partial class MainWindow
{
    // MARK: - Entry points for the notification-area panel and the global shortcuts

    public void OpenCommandPalette() => ShowCommandPalette();

    public void RequestPauseResume() => SidebarPauseClick(this, new RoutedEventArgs());

    public void RequestFinish()
    {
        if (_engine.Workspace.Session is not { } s) return;
        if (s.EndedAt != null)
        {
            // The result sheet may already be open: bring it forward instead of opening a second one.
            if (OwnedWindows.Count > 0) { OwnedWindows[0].Activate(); return; }
            Dialogs.ShowCompletionDialog(_engine, s, this);
            return;
        }
        SidebarFinishClick(this, new RoutedEventArgs());
    }

    public void RequestCancelSession() => CancelRunningSession();

    public void OpenWhatsNew() => ShowWhatsNew();

    public void OpenShortcutsHelp() => ShowShortcutsHelp();

    /// <summary>
    /// Draws the whole current page (not only the part that fits on the screen) into a PNG. The end-to-end check uses
    /// it to leave pictures that can be compared with the Mac app's own snapshots.
    /// </summary>
    public bool SavePagePng(string path)
    {
        try
        {
            PageContent.UpdateLayout();
            var contentWidth = PageContent.ActualWidth;
            var contentHeight = PageContent.ActualHeight;
            if (contentWidth < 1 || contentHeight < 1) return false;
            var width = (int)Math.Ceiling(contentWidth + 64);
            var height = (int)Math.Ceiling(Math.Min(contentHeight + 48, 12000));
            var visual = new System.Windows.Media.DrawingVisual();
            using (var context = visual.RenderOpen())
            {
                context.DrawRectangle(BrushHex("#0D1014"), null, new Rect(0, 0, width, height));
                var brush = new System.Windows.Media.VisualBrush(PageContent)
                {
                    Stretch = System.Windows.Media.Stretch.None,
                    AlignmentX = System.Windows.Media.AlignmentX.Left,
                    AlignmentY = System.Windows.Media.AlignmentY.Top
                };
                context.DrawRectangle(brush, null, new Rect(32, 24, contentWidth, contentHeight));
            }
            var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(width, height, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
            bitmap.Render(visual);
            var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
            encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));
            using var stream = System.IO.File.Create(path);
            encoder.Save(stream);
            return true;
        }
        catch { return false; }
    }

    public void RequestStart(FocusTask task) => StartOrHandoffSession(task);

    public void RequestNewTask() => Dialogs.ShowTaskEditor(_engine, null, this);

    public void RequestQuickBlock(int minutes) => _engine.LaunchQuickBlock(minutes, _quickProtection, _quickPreset);

    /// <summary>«Novedades» once, the first time this release is opened (macOS: `WhatsNew.pending`).</summary>
    public void ShowWhatsNewIfPending()
    {
        if (_engine.Prefs.WhatsNewSeen == WhatsNewRelease) return;
        _engine.Prefs.WhatsNewSeen = WhatsNewRelease;
        _engine.Prefs.Save();
        ShowWhatsNew();
    }

    /// <summary>Cancels the running session: the task stays pending and the session is recorded as cancelled.</summary>
    private void CancelRunningSession()
    {
        if (_engine.Workspace.Session is not { EndedAt: null } s) return;
        if (s.Remaining(DateTimeOffset.Now) > 0 && s.Task.Protection != SessionProtection.None)
        {
            if (!Dialogs.RequestUnlock(s.Task.Protection, s.Task.UnlockChars, s.Task.StopDelayMinutes, $"cancelar «{s.Task.Title}»", this))
                return;
            if (s.Task.Protection == SessionProtection.Forced)
                _engine.Workspace.RecordAudit("Salida de emergencia", $"Cancelación de emergencia de «{s.Task.Title}».");
        }
        else
        {
            var answer = System.Windows.MessageBox.Show(this,
                "¿Cancelar esta sesión? La tarea seguirá pendiente y la sesión quedará registrada como cancelada.",
                "Cancelar sesión · FocusDesk", MessageBoxButton.YesNo, MessageBoxImage.Question);
            if (answer != MessageBoxResult.Yes) return;
        }
        _engine.CancelSession();
    }

    /// <summary>The task FocusDesk would start next when nothing is running (Ctrl+Alt+Win+S).</summary>
    private void StartNextTask()
    {
        if (_engine.Workspace.Session != null) return;
        if (_engine.NextTask() is { } next) StartOrHandoffSession(next);
        else { _engine.Notice = "No hay ninguna tarea pendiente que empezar."; UpdateNoticeAndSidebar(); }
    }

    // MARK: - The kinds of rule (shared by «Crear una regla» and the search)

    private static readonly (GeneralRuleKind Kind, string Title, string Text, Action<GeneralBlockRule> Setup)[] RuleGallery =
    {
        (GeneralRuleKind.DailyLimit, "Presupuesto de uso", "20 min al día de YouTube y Shorts; luego, bloqueado.", r => r.DailyLimitMinutes = 20),
        (GeneralRuleKind.Pomodoro, "Pomodoro", "25 min de foco y 5 de descanso; si te distraes, vuelve a empezar.", _ => { }),
        (GeneralRuleKind.WorkGoal, "Primero el trabajo", "Tras 60 min de tareas, 20 min de ocio de premio.", r => { r.GoalMinutesRequired = 60; r.GoalRewardMinutes = 20; }),
        (GeneralRuleKind.LaunchLimit, "Visitas contadas", "4 visitas al día de 5 min, con 30 min de enfriamiento.", r => { r.MaxDailyLaunches = 4; r.MaxLaunchDurationMinutes = 5; r.LaunchCooldownMinutes = 30; }),
        (GeneralRuleKind.Countdown, "Cuenta atrás", "Una cuenta atrás guardada que lanzas cuando quieras.", r => r.CountdownMinutes = 60),
        (GeneralRuleKind.Schedule, "Horario", "De 22:30 a 7:30 todos los días, o en varios tramos.", r => { r.StartMinutes = 22 * 60 + 30; r.EndMinutes = 7 * 60 + 30; }),
        (GeneralRuleKind.AlwaysOn, "Siempre activa", "Bloqueadas a todas horas mientras esté encendida.", _ => { })
    };

    private void OpenRuleTemplate(GeneralRuleKind kind)
    {
        var entry = RuleGallery.First(g => g.Kind == kind);
        var template = new GeneralBlockRule { Kind = kind, Name = entry.Title };
        entry.Setup(template);
        Dialogs.ShowRuleEditor(_engine, null, template, this);
    }

    private void ImportRulesFile()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "JSON (*.json)|*.json", Title = "Importar reglas" };
        if (dialog.ShowDialog() != true) return;
        _engine.ImportRules(dialog.FileName);
        UpdateNoticeAndSidebar();
        RefreshUI();
    }

    // MARK: - Buscar función (Ctrl+K)

    private sealed record PaletteEntry(string Group, string Glyph, string Title, string Detail, string Location, string Keywords, Action Run);

    private List<PaletteEntry> PaletteEntries()
    {
        var all = new List<PaletteEntry>();
        var now = DateTimeOffset.Now;
        var s = _engine.Workspace.Settings;
        void Add(string group, string glyph, string title, string detail, string location, string keywords, Action run) =>
            all.Add(new PaletteEntry(group, glyph, title, detail, location, keywords, run));
        Action Page(string tag) => () => _engine.ActivePage = tag;
        Action OpenSettings() => () => _engine.ActivePage = "Ajustes";

        // Agenda
        Add("Agenda", "", "Nueva tarea", "Planifica algo con hora y duración", "Ctrl+N", "crear tarea planificar", () => Dialogs.ShowTaskEditor(_engine, null, this));
        Add("Agenda", "", "Hoy", "Tu siguiente paso y la agenda del día", "Ctrl+1", "dia agenda inicio", Page("Hoy"));
        Add("Agenda", "", "Semana", "Arrastra tareas entre días", "Ctrl+2", "calendario", Page("Semana"));
        Add("Agenda", "", "Historial de sesiones", "Lo que has trabajado y sus notas", "Ctrl+3", "sesiones pasado", () => { _auditView = false; _engine.ActivePage = "Historial"; });
        if (_engine.Workspace.Session == null && _engine.NextTask(now) is { } next)
            Add("Agenda", "", $"Empezar «{next.Title}»", "La siguiente tarea de tu agenda", "Ctrl+Alt+Win+S", "empezar siguiente tarea", () => StartOrHandoffSession(next));
        Add("Agenda", "", "Deshacer el último cambio de la agenda", "Mover, borrar o editar una tarea", "Ctrl+Z", "deshacer rehacer", () => _engine.UndoAgenda());
        Add("Agenda", "", "Exportar la agenda al calendario (.ics)", "Para Outlook, Google Calendar o el Calendario de Windows", "Semana", "calendario ics exportar eventos", ExportCalendarFile);

        // Session
        if (_engine.Workspace.Session is { EndedAt: null } running)
        {
            Add("Sesión", running.Paused ? "" : "", running.Paused ? "Reanudar la sesión" : "Pausar la sesión", running.Task.Title, "Ctrl+Alt+Win+P", "pausa pausar reanudar", RequestPauseResume);
            Add("Sesión", "", "He terminado", running.Task.Title, "Ctrl+Alt+Win+T", "terminar acabar sesion", RequestFinish);
            Add("Sesión", "", "Ampliar 10 minutos", running.Task.Title, "Ctrl+Alt+Win+A", "mas tiempo alargar", () => _engine.AddSessionMinutes(10));
            Add("Sesión", "", "Cancelar la sesión", "La tarea sigue pendiente", "Hoy", "cancelar abandonar", CancelRunningSession);
        }

        // Antidistracción
        Add("Antidistracción", "", "Bloquear ahora", "Bloqueo rápido de 15 min al resto del día", "Ctrl+4", "bloqueo rapido cuenta atras temporizador distracciones", Page("Bloquear"));
        Add("Antidistracción", "", "Bloquear 30 minutos ya", $"{_quickPreset?.Label ?? "Redes y Shorts"} · {_quickProtection.Label()}", "Ctrl+Alt+Win+B", "bloquear ya media hora",
            () => _engine.LaunchQuickBlock(30, _quickProtection, _quickPreset));
        Add("Antidistracción", "", "Bloquear 1 hora ya", $"{_quickPreset?.Label ?? "Redes y Shorts"} · {_quickProtection.Label()}", "Bloquear ahora", "bloquear ya una hora",
            () => _engine.LaunchQuickBlock(60, _quickProtection, _quickPreset));
        Add("Antidistracción", "", "Permitir una web unos minutos", "Una excepción que caduca sola", "Bloquear ahora", "excepcion temporal permitir dominio web", Page("Bloquear"));
        Add("Antidistracción", "", "Reglas y límites", "Todas tus reglas y presupuestos", "Ctrl+5", "reglas limites generales", Page("Reglas"));
        foreach (var kind in RuleGallery)
        {
            var captured = kind.Kind;
            Add("Antidistracción", RuleKindGlyph(kind.Kind), $"Nueva regla: {kind.Title}", kind.Text, "Reglas y límites", kind.Kind.GalleryTitle(), () => OpenRuleTemplate(captured));
        }
        foreach (var rule in _engine.Workspace.GeneralRules)
        {
            var captured = rule;
            Add("Tus reglas", rule.Game != null ? "" : RuleKindGlyph(rule.Kind), rule.Name, $"{rule.Kind.GalleryTitle()} · {RuleInfoLine(rule)}", "Editar", "regla " + rule.Kind.GalleryTitle(),
                () => Dialogs.ShowRuleEditor(_engine, captured, null, this));
            if (rule.Kind == GeneralRuleKind.Pomodoro && rule.Enabled && rule.PomodoroPhase != PomodoroPhase.Idle && rule.PomodoroPhase != PomodoroPhase.WaitingForUser)
                Add("Tus reglas", "", $"Saltar fase de «{rule.Name}»", RuleInfoLine(rule), "Pomodoro", "pomodoro fase saltar", () =>
                {
                    if (captured.PomodoroPhase == PomodoroPhase.Work && !UnlockRuleFor(captured, $"saltar el enfoque de «{captured.Name}»")) return;
                    _engine.SkipPomodoroPhase(captured);
                });
            var microLeft = Math.Max(0, rule.DailyMicroPausesAllowed - _engine.Workspace.MicroPausesUsedToday(rule.Id));
            if (microLeft > 0 && _engine.IsRuleEnforcing(rule, now))
                Add("Tus reglas", "", $"Micro-pausa de «{rule.Name}»", $"{microLeft} disponibles hoy · {rule.MicroPauseMinutes} min", "Descansos", "micropausa pausa soltar",
                    () => _engine.UseMicroPause(captured));
        }
        Add("Antidistracción", "", "Importar reglas", "Plantillas guardadas en un archivo JSON", "Reglas y límites", "importar json plantilla", ImportRulesFile);
        if (_engine.Workspace.GeneralRules.Count > 0)
            Add("Antidistracción", "", "Exportar reglas", "Guarda tus reglas en un archivo JSON", "Reglas y límites", "exportar json copia plantilla", ExportRulesFile);
        Add("Antidistracción", "", "Listas blancas y negras, subrutas y títulos", "Dentro de cada regla o tarea, en «Qué bloquea»", "Editor de regla", "lista blanca negra permitir solo subruta titulo ventana", Page("Reglas"));
        Add("Antidistracción", "", "Comodines y /regex/", "Escribe * ? o /expresión/ en «Qué bloquea»", "Editor de regla", "regex expresion regular comodin palabra completa", Page("Reglas"));
        Add("Antidistracción", "", "Vídeos e imágenes en buscadores", "Pestañas de Google, Bing, DuckDuckGo…", "Editor de regla", "buscadores google imagenes videos", Page("Reglas"));
        Add("Antidistracción", "", "Bibliotecas de juegos", "Steam, Epic, Battle.net, Riot…", "Editor de regla", "juegos steam epic", Page("Reglas"));
        Add("Antidistracción", "", "Proteger una tarea", "Código, espera o hasta el final, al editar la tarea", "Editor de tarea", "proteccion codigo espera desbloqueo", () => Dialogs.ShowTaskEditor(_engine, null, this));
        Add("Agenda", "", "Pomodoro dentro de una tarea", "Foco y descansos en la misma tarea, al editarla", "Editor de tarea", "pomodoro descanso foco ciclos", () => Dialogs.ShowTaskEditor(_engine, null, this));
        Add("Antidistracción", "", "Carpetas que distraen", "Series o descargas que se cierran durante una tarea", "Editor de tarea", "carpeta explorador", () => Dialogs.ShowTaskEditor(_engine, null, this));

        // Descansos
        Add("Descansos", "", "Descansos", "Pausas por uso continuo, micro-pausas y Pomodoro", "Ctrl+6", "descanso pausa", Page("Descansos"));
        Add("Descansos", "", "Descansar ahora", $"{s.ContinuousBreakDurationMinutes} min para la vista y estirar", "Descansos", "descanso pausa ahora", () => _engine.StartContinuousBreakNow());
        Add("Descansos", "", "Descanso tras uso continuo", s.ContinuousBreakEnabled ? $"Activado · cada {s.ContinuousWorkMinutes} min" : "Desactivado", "Descansos", "continuo uso vista estirar", Page("Descansos"));
        Add("Descansos", "", "Descansos habituales", "Comida, paseo… con aviso y cuenta atrás", "Descansos", "comida habitual descanso fijo", Page("Descansos"));

        // Historial
        Add("Historial", "", "Registro de bloqueo", "Desbloqueos y cambios en tus reglas", "Historial", "auditoria registro log cambios desbloqueos", () => { _auditView = true; _engine.ActivePage = "Historial"; });

        // Ajustes
        Add("Ajustes", "", "Avisos a 5 y 1 min del final", "Antes de que se acabe un presupuesto o visita", "Bloquear ahora", "avisos notificaciones minutos", Page("Bloquear"));
        Add("Ajustes", "", "Vaciar el portapapeles mientras bloquea", "Si copias algo bloqueado", "Bloquear ahora", "portapapeles copiar pegar", Page("Bloquear"));
        Add("Ajustes", "", "Proteger el historial mientras bloquea", "Que no se pueda borrar en caliente", "Bloquear ahora", "historial borrar proteger", Page("Bloquear"));
        Add("Ajustes", "", "Corte de día", "A qué hora empieza tu día para los límites diarios", "Ajustes › Agenda", "medianoche hora reinicio dia", OpenSettings());
        Add("Ajustes", "", "Perfiles reutilizables", "Apps, webs y checklist en un clic", "Ajustes › Perfiles", "perfil plantilla", OpenSettings());
        Add("Ajustes", "", "Categorías y colores", "Las áreas de tus tareas", "Ajustes › Agenda", "categoria color area", OpenSettings());
        Add("Ajustes", "", "Proteger una tarea antes de empezar", "Desde unos minutos antes de su hora", "Ajustes › General", "antes empezar margen", OpenSettings());
        Add("Ajustes", "", "Tamaño del texto", "Normal, grande o muy grande", "Ajustes › General", "letra fuente accesibilidad", OpenSettings());
        Add("Ajustes", "", "Atajo global", "Abrir FocusDesk desde cualquier app", "Ajustes › General", "atajo teclado global", OpenSettings());
        Add("Ajustes", "", "Abrir FocusDesk al iniciar sesión", "Arrancar con Windows", "Ajustes › General", "inicio arranque windows", OpenSettings());
        Add("Ajustes", "", "Qué cuenta como estudio activo", "Apps y webs que suman para «primero estudio»", "Ajustes › Estudio", "estudio verificado fuentes", OpenSettings());
        Add("Ajustes", "", "Qué puede observar FocusDesk", "Títulos de ventana, webs visitadas y exclusiones", "Ajustes › Privacidad", "privacidad titulos dominio", OpenSettings());
        Add("Ajustes", "", "Volver a abrirse si la cierran", "Durante una sesión protegida", "Ajustes › Privacidad", "vigilante relanzar forzar cierre", OpenSettings());
        Add("Ajustes", "", "Datos y copias de seguridad", "Exportar, importar y recuperar", "Ajustes › Datos", "copia backup restaurar", OpenSettings());

        // Tasks of the agenda (Windows shows them here too: it is the quickest way to start one)
        foreach (var task in _engine.Workspace.Tasks.Where(t => !t.Completed).OrderBy(t => t.IsScheduled ? t.ScheduledAt : DateTimeOffset.MaxValue).Take(30))
        {
            var captured = task;
            var when = task.IsScheduled ? task.ScheduledAt.LocalDateTime.ToString("ddd d MMM · H:mm", Spanish) : "Sin hora";
            Add("Tus tareas", "", $"Empezar «{task.Title}»", $"{when} · {FocusRules.DurationText(task.Minutes)}", "Hoy", "iniciar tarea " + task.Category, () => StartOrHandoffSession(captured));
            Add("Tus tareas", "", $"Editar «{task.Title}»", $"{when} · {task.Category}", "Editor de tarea", "editar tarea " + task.Category, () => Dialogs.ShowTaskEditor(_engine, captured, this));
        }

        // Ayuda
        Add("Ayuda", "", "Novedades de FocusDesk", "Lo nuevo, con «Probar» para cada cosa", "Ayuda", "nuevo tutorial guia", ShowWhatsNew);
        Add("Ayuda", "", "Atajos de teclado", "Todos los atajos de FocusDesk", "Ayuda", "teclado shortcuts", ShowShortcutsHelp);
        return all;
    }

    /// <summary>Every word typed has to appear somewhere in the entry, ignoring case and accents; title matches first.</summary>
    private static List<PaletteEntry> SearchPalette(string query, List<PaletteEntry> entries)
    {
        var words = FocusRules.Fold(query).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (words.Length == 0) return entries;
        var inTitle = new List<PaletteEntry>();
        var elsewhere = new List<PaletteEntry>();
        foreach (var entry in entries)
        {
            var title = FocusRules.Fold(entry.Title);
            var haystack = title + " " + FocusRules.Fold($"{entry.Detail} {entry.Location} {entry.Keywords} {entry.Group}");
            if (!words.All(w => haystack.Contains(w, StringComparison.Ordinal))) continue;
            (words.All(w => title.Contains(w, StringComparison.Ordinal)) ? inTitle : elsewhere).Add(entry);
        }
        inTitle.AddRange(elsewhere);
        return inTitle;
    }

    /// <summary>A window without the Windows frame, with rounded corners, like the sheets of the Mac app.</summary>
    private Window SheetWindow(double width, double height, UIElement content)
    {
        var win = new Window
        {
            Width = width,
            Owner = IsVisible ? this : null,
            WindowStartupLocation = IsVisible ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            WindowStyle = WindowStyle.None,
            ResizeMode = ResizeMode.NoResize,
            AllowsTransparency = true,
            ShowInTaskbar = false,
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = BrushHex("#EDF2F5"),
            FontFamily = FontFamily
        };
        if (double.IsNaN(height)) win.SizeToContent = SizeToContent.Height; else win.Height = height;
        win.Content = new Border
        {
            Background = BrushHex("#161B21"),
            BorderBrush = BrushHex("#30353C"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(14),
            Child = content
        };
        win.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { e.Handled = true; win.Close(); }
        };
        return win;
    }

    private void ShowCommandPalette()
    {
        var entries = PaletteEntries();
        var shown = new List<(PaletteEntry Entry, Border Row)>();
        var selection = 0;

        var root = new DockPanel();
        var win = SheetWindow(680, 580, root);
        win.Title = "Buscar función · FocusDesk";

        // Search row
        var top = new DockPanel { Margin = new Thickness(18, 14, 14, 14) };
        var lens = Glyph("", 17, "#99A6AD");
        lens.Margin = new Thickness(0, 0, 12, 0);
        DockPanel.SetDock(lens, Dock.Left);
        top.Children.Add(lens);
        var close = SmallButton("Cerrar", () => win.Close(), true, 0);
        close.Background = System.Windows.Media.Brushes.Transparent;
        close.BorderBrush = System.Windows.Media.Brushes.Transparent;
        DockPanel.SetDock(close, Dock.Right);
        top.Children.Add(close);
        var search = new System.Windows.Controls.TextBox
        {
            FontSize = 17.5,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            VerticalContentAlignment = VerticalAlignment.Center
        };
        var hint = new TextBlock
        {
            Text = "Busca una función o un ajuste: pomodoro, portapapeles, regex…",
            FontSize = 17.5,
            Foreground = BrushHex("#7C868C"),
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
            Margin = new Thickness(14, 0, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        var searchHost = new Grid();
        searchHost.Children.Add(search);
        searchHost.Children.Add(hint);
        top.Children.Add(searchHost);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        var topLine = new Border { Height = 1, Background = BrushHex("#262A30") };
        DockPanel.SetDock(topLine, Dock.Top);
        root.Children.Add(topLine);

        // Footer: how to move, and how many
        var footer = new DockPanel { Margin = new Thickness(18, 9, 18, 10) };
        var count = new TextBlock { FontSize = 12.5, Foreground = BrushHex("#99A6AD") };
        DockPanel.SetDock(count, Dock.Right);
        footer.Children.Add(count);
        footer.Children.Add(new TextBlock { Text = "↑↓ elegir     ↵ abrir     Esc cerrar", FontSize = 12.5, Foreground = BrushHex("#99A6AD") });
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        var bottomLine = new Border { Height = 1, Background = BrushHex("#262A30") };
        DockPanel.SetDock(bottomLine, Dock.Bottom);
        root.Children.Add(bottomLine);

        var list = new StackPanel { Margin = new Thickness(8) };
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = list };
        root.Children.Add(scroll);

        void Paint()
        {
            for (var i = 0; i < shown.Count; i++)
                shown[i].Row.Background = i == selection ? BrushHex("#15291F") : System.Windows.Media.Brushes.Transparent;
        }
        void Run()
        {
            if (selection < 0 || selection >= shown.Count) return;
            var action = shown[selection].Entry.Run;
            // Close first: most entries open another window, and this one must not stay behind it.
            win.Close();
            Dispatcher.BeginInvoke(action);
        }
        void Move(int step)
        {
            if (shown.Count == 0) return;
            selection = Math.Clamp(selection + step, 0, shown.Count - 1);
            Paint();
            shown[selection].Row.BringIntoView();
        }
        void Refill()
        {
            var results = SearchPalette(search.Text.Trim(), entries);
            list.Children.Clear();
            shown.Clear();
            selection = 0;
            if (results.Count == 0)
                list.Children.Add(new TextBlock
                {
                    Text = $"Nada con «{search.Text.Trim()}». Prueba con otra palabra, como «bloquear», «descanso» o «web».",
                    FontSize = 14.5,
                    Foreground = BrushHex("#99A6AD"),
                    TextWrapping = TextWrapping.Wrap,
                    TextAlignment = TextAlignment.Center,
                    Margin = new Thickness(20, 44, 20, 44)
                });
            string? currentGroup = null;
            foreach (var entry in results)
            {
                if (entry.Group != currentGroup)
                {
                    list.Children.Add(new TextBlock
                    {
                        Text = Spaced(entry.Group),
                        FontSize = 11.5,
                        FontWeight = FontWeights.Bold,
                        Foreground = BrushHex("#99A6AD"),
                        Margin = new Thickness(10, currentGroup == null ? 6 : 14, 0, 5)
                    });
                    currentGroup = entry.Group;
                }
                var grid = new Grid();
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var tile = IconTile(entry.Glyph, false, 32);
                tile.VerticalAlignment = VerticalAlignment.Center;
                grid.Children.Add(tile);
                var text = new StackPanel { Margin = new Thickness(13, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
                text.Children.Add(new TextBlock { Text = entry.Title, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#EDF2F5"), TextTrimming = TextTrimming.CharacterEllipsis });
                text.Children.Add(new TextBlock { Text = entry.Detail, FontSize = 13, Foreground = BrushHex("#99A6AD"), TextTrimming = TextTrimming.CharacterEllipsis, Margin = new Thickness(0, 1, 0, 0) });
                Grid.SetColumn(text, 1);
                grid.Children.Add(text);
                var whereText = new TextBlock { Text = entry.Location, FontSize = 12.5, Foreground = BrushHex("#99A6AD"), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(whereText, 2);
                grid.Children.Add(whereText);
                var row = new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 7, 12, 7), Child = grid, Background = System.Windows.Media.Brushes.Transparent, Cursor = System.Windows.Input.Cursors.Hand };
                var index = shown.Count;
                row.MouseMove += (_, _) =>
                {
                    if (selection == index) return;
                    selection = index;
                    Paint();
                };
                row.MouseLeftButtonUp += (_, _) => { selection = index; Run(); };
                shown.Add((entry, row));
                list.Children.Add(row);
            }
            count.Text = search.Text.Trim().Length == 0 ? $"{entries.Count} funciones y ajustes" : $"{results.Count} de {entries.Count}";
            Paint();
            scroll.ScrollToTop();
        }

        search.TextChanged += (_, _) =>
        {
            hint.Visibility = string.IsNullOrEmpty(search.Text) ? Visibility.Visible : Visibility.Collapsed;
            Refill();
        };
        search.PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.Down) { Move(1); e.Handled = true; }
            else if (e.Key == Key.Up) { Move(-1); e.Handled = true; }
            else if (e.Key == Key.PageDown) { Move(8); e.Handled = true; }
            else if (e.Key == Key.PageUp) { Move(-8); e.Handled = true; }
            else if (e.Key == Key.Enter) { Run(); e.Handled = true; }
        };
        Refill();
        win.Loaded += (_, _) => search.Focus();
        win.ShowDialog();
    }

    // MARK: - Novedades

    /// <summary>Bump when a release adds something worth showing: the window then appears once on the next start.</summary>
    private const string WhatsNewRelease = "2026-10-antidistraccion";

    private void ShowWhatsNew()
    {
        var root = new StackPanel { Margin = new Thickness(28) };
        var win = SheetWindow(860, double.NaN, root);
        win.Title = "Novedades · FocusDesk";
        void Open(string page)
        {
            win.Close();
            _engine.ActivePage = page;
        }

        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var star = IconTile("", false, 44);
        header.Children.Add(star);
        var titles = new StackPanel { Margin = new Thickness(16, 0, 0, 0) };
        titles.Children.Add(new TextBlock { Text = Spaced("Novedades"), FontSize = 12, FontWeight = FontWeights.Bold, Foreground = BrushHex("#38A169") });
        titles.Children.Add(new TextBlock
        {
            Text = "FocusDesk ahora también te protege fuera de las tareas",
            FontSize = 25,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI"),
            Margin = new Thickness(0, 4, 0, 4)
        });
        titles.Children.Add(new TextBlock
        {
            Text = "Lo nuevo vive en Antidistracción, en la barra lateral. Pulsa «Probar» y te llevo a cada cosa.",
            FontSize = 14.5,
            Foreground = BrushHex("#99A6AD"),
            TextWrapping = TextWrapping.Wrap
        });
        Grid.SetColumn(titles, 1);
        header.Children.Add(titles);
        root.Children.Add(header);

        var areas = new (string Page, string Title, string Glyph, string Key, string[] Items)[]
        {
            ("Bloquear", "Bloquear ahora", "", "Ctrl 4", new[] { "Bloqueo en 1 clic: de 15 min al resto del día", "Permitir una web unos minutos" }),
            ("Reglas", "Reglas y límites", "", "Ctrl 5", new[] { "Presupuesto: 20 min de Shorts al día", "Pomodoro que se reinicia si te distraes", "Primero el trabajo, luego el ocio", "Visitas contadas con enfriamiento", "Horarios de varios tramos" }),
            ("Descansos", "Descansos", "", "Ctrl 6", new[] { "Un descanso tras mucho rato seguido", "Micro-pausas contadas en tus reglas", "Los descansos del Pomodoro, a la vista" })
        };
        var cards = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3, Margin = new Thickness(0, 20, -12, 0) };
        foreach (var area in areas)
        {
            var card = new DockPanel { LastChildFill = true };
            var head = new DockPanel { Margin = new Thickness(0, 0, 0, 10) };
            var keyChip = new Border { Background = BrushHex("#262B33"), CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = area.Key, FontSize = 11.5, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#99A6AD") } };
            DockPanel.SetDock(keyChip, Dock.Right);
            head.Children.Add(keyChip);
            var icon = Glyph(area.Glyph, 16, "#38A169");
            icon.Margin = new Thickness(0, 0, 10, 0);
            DockPanel.SetDock(icon, Dock.Left);
            head.Children.Add(icon);
            head.Children.Add(new TextBlock { Text = area.Title, FontSize = 16.5, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
            DockPanel.SetDock(head, Dock.Top);
            card.Children.Add(head);
            var page = area.Page;
            var tryIt = SmallButton("Probar", () => Open(page), true, 0);
            tryIt.HorizontalAlignment = System.Windows.HorizontalAlignment.Left;
            tryIt.Margin = new Thickness(0, 12, 0, 0);
            DockPanel.SetDock(tryIt, Dock.Bottom);
            card.Children.Add(tryIt);
            var items = new StackPanel();
            foreach (var item in area.Items)
            {
                var line = new DockPanel { Margin = new Thickness(0, 0, 0, 7) };
                var dot = new TextBlock { Text = "•", Foreground = BrushHex("#38A169"), FontSize = 14, Margin = new Thickness(0, 0, 8, 0) };
                DockPanel.SetDock(dot, Dock.Left);
                line.Children.Add(dot);
                line.Children.Add(new TextBlock { Text = item, FontSize = 14, TextWrapping = TextWrapping.Wrap });
                items.Children.Add(line);
            }
            card.Children.Add(items);
            cards.Children.Add(new Border
            {
                Background = BrushHex("#1D2229"),
                BorderBrush = BrushHex("#2A2E34"),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(14),
                Padding = new Thickness(16),
                Margin = new Thickness(0, 0, 12, 0),
                MinHeight = 230,
                Child = card
            });
        }
        root.Children.Add(cards);

        root.Children.Add(MutedText("Y dentro de cada regla o tarea, en «Qué bloquea»:", 12.5, 20));
        var chips = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var extra in new[] { "Listas blancas y negras", "Subrutas como youtube.com/shorts", "Comodines * ? y /regex/", "Vídeos e imágenes en buscadores",
                                      "Bibliotecas de juegos", "Portapapeles vigilado", "Edge, Chrome, Firefox, Brave y Opera", "Registro de cambios en Historial" })
            chips.Children.Add(Chip(extra, "#EDF2F5", "#262B33"));
        root.Children.Add(chips);

        root.Children.Add(new Border { Height = 1, Background = BrushHex("#262A30"), Margin = new Thickness(0, 18, 0, 16) });
        var footer = new DockPanel();
        var start = GlyphButton("", "Empezar por Bloquear ahora", () => Open("Bloquear"), primary: true);
        start.Margin = new Thickness(0);
        DockPanel.SetDock(start, Dock.Right);
        footer.Children.Add(start);
        var later = SmallButton("Ahora no", () => win.Close(), true, 10);
        later.MinHeight = 40;
        DockPanel.SetDock(later, Dock.Right);
        footer.Children.Add(later);
        footer.Children.Add(new TextBlock
        {
            Text = "Para volver a verlo: busca «Novedades» con Ctrl+K, o entra en Ajustes › General.",
            FontSize = 12.5,
            Foreground = BrushHex("#99A6AD"),
            TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 16, 0)
        });
        root.Children.Add(footer);
        win.ShowDialog();
    }

    // MARK: - Atajos de teclado

    private void ShowShortcutsHelp()
    {
        var root = new StackPanel { Margin = new Thickness(28) };
        var win = SheetWindow(600, double.NaN, root);
        win.Title = "Atajos de teclado · FocusDesk";
        root.Children.Add(new TextBlock { Text = "Atajos de teclado", FontSize = 25, FontWeight = FontWeights.SemiBold, FontFamily = new System.Windows.Media.FontFamily("Segoe UI Variable Display, Segoe UI") });
        var open = _engine.Workspace.Settings.HotKeyEnabled
            ? HotKeyNames[Math.Clamp(_engine.Workspace.Settings.HotKeyChoice, 0, HotKeyNames.Length - 1)]
            : "desactivado";
        void Section(string title, params (string Keys, string What)[] rows)
        {
            root.Children.Add(SectionLabel(title, 18));
            foreach (var (keys, what) in rows)
            {
                var line = new DockPanel { Margin = new Thickness(0, 3, 0, 3) };
                var chip = new Border { Background = BrushHex("#262B33"), CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 3, 8, 3), MinWidth = 150,
                    Child = new TextBlock { Text = keys, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = BrushHex("#D5DBDF") } };
                DockPanel.SetDock(chip, Dock.Left);
                line.Children.Add(chip);
                line.Children.Add(new TextBlock { Text = what, FontSize = 14.5, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(14, 0, 0, 0), TextWrapping = TextWrapping.Wrap });
                root.Children.Add(line);
            }
        }
        Section("Desde cualquier app",
            (open, "Abrir FocusDesk"),
            ("Ctrl+Alt+Win+S", "Empezar la siguiente tarea"),
            ("Ctrl+Alt+Win+P", "Pausar o reanudar la sesión"),
            ("Ctrl+Alt+Win+T", "He terminado"),
            ("Ctrl+Alt+Win+A", "Ampliar 10 minutos"),
            ("Ctrl+Alt+Win+B", "Bloquear 30 minutos ya"));
        Section("Dentro de FocusDesk",
            ("Ctrl+K", "Buscar cualquier función o ajuste"),
            ("Ctrl+N", "Nueva tarea"),
            ("Ctrl+1 · 2 · 3", "Hoy, Semana, Historial"),
            ("Ctrl+4 · 5 · 6", "Bloquear ahora, Reglas y límites, Descansos"),
            ("Ctrl+,", "Ajustes"),
            ("Ctrl+T", "Volver a hoy"),
            ("Ctrl+← / Ctrl+→", "Día (o semana) anterior y siguiente"),
            ("Ctrl+Z / Ctrl+Y", "Deshacer y rehacer en la agenda"));
        var close = SmallButton("Cerrar", () => win.Close(), true, 0);
        close.HorizontalAlignment = System.Windows.HorizontalAlignment.Right;
        close.Margin = new Thickness(0, 20, 0, 0);
        root.Children.Add(close);
        win.ShowDialog();
    }
}
