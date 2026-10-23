import AppKit
import Carbon.HIToolbox
import Foundation
import FocusCore

/// Opt-in integration check inside the real app bundle, using temporary data only.
@MainActor
enum SmokeCheck {
    static func run(_ model: AppModel, statusVisible: Bool) async -> String {
        do {
            guard model.preview else { throw Failure.message("Smoke check requires --preview") }
            guard NSApp.activationPolicy() == .regular else { throw Failure.message("Dock activation policy") }
            guard statusVisible else { throw Failure.message("Status item not visible") }

            // 1. Reusable Profile creation & application (Item 9) and Domain Normalization (Item 15)
            let customProfile = FocusProfile(
                name: "Grabar vídeo Pro",
                category: "Contenido",
                minutes: 45,
                leadMinutes: 10,
                strict: false,
                domains: "https://claude.ai/chat, https://www.chatgpt.com/",
                checklist: "Preparar guion\nExportar MP4"
            )
            model.saveProfile(customProfile)
            guard model.workspace.profiles.contains(where: { $0.id == customProfile.id && $0.domains == "claude.ai, chatgpt.com" }) else {
                throw Failure.message("Profile creation or domain normalization")
            }

            // 2. Overdue task snoozing produces a future time (Item 2) & Notification actions (Item 1)
            let overdueTask = FocusTask(title: "Tarea atrasada 2h", scheduledAt: Date().addingTimeInterval(-7200), minutes: 30)
            model.saveTask(overdueTask)
            model.handleNotificationAction(identifier: ReminderService.actionSnooze, userInfo: ["taskID": overdueTask.id.uuidString])
            guard let snoozed = model.workspace.tasks.first(where: { $0.id == overdueTask.id }),
                  snoozed.scheduledAt > Date().addingTimeInterval(500) else {
                throw Failure.message("Overdue snooze did not move to future")
            }
            model.deleteTask(snoozed)

            // 3. Unscheduled task with independent deadline (Item 11)
            let inboxTask = FocusTask(title: "Preparar guion", isScheduled: false, dueDate: Date().addingTimeInterval(86400 * 3), minutes: 30)
            model.saveTask(inboxTask)
            guard model.unscheduledTasks.contains(where: { $0.id == inboxTask.id }) else {
                throw Failure.message("Unscheduled inbox task")
            }
            model.deleteTask(inboxTask)

            // 4. Main workflow: start via notification action, pause, resume, extend, evidence selection, manual attachment, finish, confirm, recurrence
            let folder = model.store.url.deletingLastPathComponent().appendingPathComponent("results")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Temp file must be ignored by scanner (Item 16)
            try Data("temp".utf8).write(to: folder.appendingPathComponent("parcial.tmp"))

            var task = FocusTask(
                title: "Prueba automática aislada",
                scheduledAt: Date().addingTimeInterval(600),
                minutes: 1,
                folder: folder.path,
                checklist: "Guardar resultado",
                repeatRule: .daily
            )
            task.apply(customProfile)
            task.minutes = 1
            model.saveTask(task)
            model.handleNotificationAction(identifier: ReminderService.actionStart, userInfo: ["taskID": task.id.uuidString])
            try await idle(model)
            guard model.session?.task.id == task.id else { throw Failure.message("Start session from notification action") }

            model.pause()
            guard model.session?.paused == true else { throw Failure.message("Pause") }
            let elapsed = model.session!.accumulated
            try await Task.sleep(nanoseconds: 100_000_000)
            guard model.session!.elapsed(at: Date(), uptime: model.uptime) == elapsed else { throw Failure.message("Paused clock advanced") }

            model.resume()
            model.addTime()
            model.setCheck("0", value: true)
            guard model.session?.budget == 660 else { throw Failure.message("Extend budget") }

            let deliverableURL = folder.appendingPathComponent("resultado-final.mov")
            try Data("video exportado".utf8).write(to: deliverableURL)
            try Data("ignorar".utf8).write(to: folder.appendingPathComponent("borrador.tmp"))

            model.finish()
            try await idle(model)
            guard model.showCompletion,
                  model.session?.endedAt != nil,
                  model.changedFiles.count == 1,
                  model.changedFiles[0].hasSuffix("resultado-final.mov"),
                  model.selectedDeliverables.count == 1 else {
                throw Failure.message("Finish or selective file evidence")
            }

            let manualFile = model.store.url.deletingLastPathComponent().appendingPathComponent("nota-adjunta.txt")
            try Data("adjunto".utf8).write(to: manualFile)
            model.attachManualFile(manualFile.path)

            model.confirm(completed: true, note: "Comprobación automática")
            let restored = try model.store.load()
            guard restored.session == nil,
                  restored.history.count == 1,
                  restored.history[0].completed,
                  !restored.history[0].cancelled,
                  restored.history[0].changedFiles.count == 1,
                  restored.history[0].confirmedFiles.count == 2,
                  restored.history[0].manualFiles.contains(manualFile.path),
                  restored.tasks.count == 2,
                  restored.tasks.filter({ !$0.completed }).first!.scheduledAt > Date() else {
                throw Failure.message("Completion persistence, deliverables, or recurrence")
            }

            // 4b. One timer at a time: starting a second task asks for an explicit hand-off instead of doing nothing,
            // and the queued task starts only after the running one's result is confirmed.
            let taskA = FocusTask(title: "Relevo A", scheduledAt: Date().addingTimeInterval(300), minutes: 30)
            let taskB = FocusTask(title: "Relevo B", scheduledAt: Date().addingTimeInterval(3600), minutes: 30)
            model.saveTask(taskA)
            model.saveTask(taskB)
            model.start(taskA)
            try await idle(model)
            guard model.session?.task.id == taskA.id else { throw Failure.message("Hand-off: first session did not start") }

            // With a session, pause and finish must be registered system-wide (they only reached FocusDesk when it was
            // in front). Only acceptable failure: another FocusDesk instance with its own session holds the keys.
            let otherInstance = NSRunningApplication.runningApplications(withBundleIdentifier: "local.focusdesk.app")
                .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            try? await settle(until: { model.sessionHotKeysActive })
            guard model.sessionHotKeysActive || otherInstance else {
                throw Failure.message("Session shortcuts ⌃⌥⌘P/⌃⌥⌘T were not registered system-wide")
            }
            let hotKeyStatus = model.sessionHotKeysActive ? "registered" : "held by another FocusDesk instance"

            // Starting B asks instead of silently refusing, and A keeps running meanwhile.
            model.handoffRequest = nil
            model.handleNotificationAction(identifier: ReminderService.actionStart, userInfo: ["taskID": taskB.id.uuidString])
            try await idle(model)
            guard model.handoffRequest?.id == taskB.id, model.session?.task.id == taskA.id, model.session?.endedAt == nil else {
                throw Failure.message("Hand-off was not offered when starting a second task")
            }

            // Declining keeps the running session untouched.
            model.cancelHandoff()
            guard model.handoffRequest == nil, model.session?.task.id == taskA.id, model.session?.endedAt == nil else {
                throw Failure.message("Declining the hand-off disturbed the running session")
            }

            // Accepting stops A, queues B behind A's confirmation, and never loses A's worked time.
            model.start(taskB)
            guard model.handoffRequest?.id == taskB.id else { throw Failure.message("Hand-off not re-offered") }
            model.acceptHandoff()
            try await idle(model)
            guard model.session?.task.id == taskA.id,
                  model.session?.endedAt != nil,
                  model.queuedStartTask?.id == taskB.id,
                  model.showCompletion else {
                throw Failure.message("Accepted hand-off did not stop the session and queue the new task")
            }
            model.confirm(completed: true, note: "Relevo", transition: .startNextNow)
            try await idle(model)
            guard model.session?.task.id == taskB.id,
                  model.queuedStartTask == nil,
                  model.workspace.history.contains(where: { $0.session.task.id == taskA.id && $0.completed }) else {
                throw Failure.message("Queued task did not start after confirming the previous result")
            }
            // Starting the task already running must resume it rather than open a hand-off question.
            model.pause()
            model.start(taskB)
            guard model.handoffRequest == nil, model.session?.paused == false else {
                throw Failure.message("Starting the running task should resume it")
            }
            model.resume()

            // 4c. A session paused by the Mac must be offered back on unlock, not left silently stopped.
            // The handlers are called directly: posting a fake «screen locked» to the whole system paused the real
            // FocusDesk's session if one was running, and locked other apps that listen for it.
            model.screenLocked()
            try await settle(until: { model.session?.paused == true })
            guard model.session?.paused == true, model.session?.endedAt == nil else {
                throw Failure.message("Locking the screen did not pause the session")
            }
            let pausedAt = model.session?.accumulated ?? 0
            model.screenUnlocked()
            try await settle(until: { model.resumePrompt != nil })
            guard let prompt = model.resumePrompt, prompt.contains(taskB.title) else {
                throw Failure.message("Unlocking did not offer the paused session back")
            }
            guard model.session?.accumulated == pausedAt else {
                throw Failure.message("Locked time was counted as worked time")
            }
            model.resume()
            guard model.resumePrompt == nil, model.session?.paused == false else {
                throw Failure.message("Resuming from the prompt did not restart the session")
            }
            // A pause the user asked for must not raise the prompt on the next unlock.
            model.pause()
            model.screenUnlocked()
            try await Task.sleep(nanoseconds: 300_000_000)
            guard model.resumePrompt == nil else {
                throw Failure.message("A user pause should not be reported as a system pause")
            }

            model.cancelSession(note: "Cierre tras prueba de relevo")
            model.deleteTask(taskB)
            // Without a session they are released, so ⌃⌥⌘P and ⌃⌥⌘T stay free for other apps.
            try await settle(until: { !model.sessionHotKeysActive })

            // 4d. Recurring series: agenda edits act on one occurrence, the editor's choice is honoured, and a missed
            // day does not freeze the series in the past.
            let cal = Calendar.current
            let seriesStart = Date().addingTimeInterval(1800)
            let series = FocusTask(title: "Serie diaria", scheduledAt: seriesStart, minutes: 30, repeatRule: .daily)
            model.saveTask(series)
            let countBefore = model.workspace.tasks.count

            // Snoozing the series' current occurrence must not move the series.
            model.snoozeTask(series, minutes: 10)
            guard let headAfterSnooze = model.workspace.tasks.first(where: { $0.id == series.id }),
                  let snoozedSingle = model.workspace.tasks.first(where: { $0.seriesID == series.id && $0.repeatRule == .never }),
                  model.workspace.tasks.count == countBefore + 1,
                  headAfterSnooze.repeatRule == .daily,
                  cal.isDate(headAfterSnooze.scheduledAt, inSameDayAs: seriesStart.addingTimeInterval(86400)),
                  cal.component(.hour, from: headAfterSnooze.scheduledAt) == cal.component(.hour, from: seriesStart),
                  cal.component(.minute, from: headAfterSnooze.scheduledAt) == cal.component(.minute, from: seriesStart),
                  abs(snoozedSingle.scheduledAt.timeIntervalSince(seriesStart.addingTimeInterval(600))) < 2 else {
                throw Failure.message("Snoozing an occurrence moved the whole series")
            }

            // Editing a future (projected) occurrence as "toda la serie" keeps the series' own start date.
            let headDate = headAfterSnooze.scheduledAt
            let farDay = cal.date(byAdding: .day, value: 3, to: headDate)!
            guard var projected = model.tasksForDay(farDay).projected.first(where: { $0.seriesID == series.id }) else {
                throw Failure.message("Series occurrence was not projected")
            }
            let projectedDate = projected.scheduledAt
            projected.title = "Serie diaria renombrada"
            model.saveEdited(projected, originalOccurrenceDate: projectedDate, onlyThisOccurrence: false)
            guard let renamedHead = model.workspace.tasks.first(where: { $0.id == series.id }),
                  renamedHead.title == "Serie diaria renombrada",
                  abs(renamedHead.scheduledAt.timeIntervalSince(headDate)) < 1,
                  renamedHead.repeatRule == .daily else {
                throw Failure.message("Editing the series from an occurrence moved its start or lost its rule")
            }

            // Moving that occurrence by one hour as "toda la serie" moves the series by one hour, same day.
            projected = model.tasksForDay(farDay).projected.first(where: { $0.seriesID == series.id })!
            let movedProjectedDate = projected.scheduledAt
            projected.scheduledAt = projected.scheduledAt.addingTimeInterval(3600)
            model.saveEdited(projected, originalOccurrenceDate: movedProjectedDate, onlyThisOccurrence: false)
            // Exactly one hour later (across midnight too, when the test runs late in the evening).
            guard let shiftedHead = model.workspace.tasks.first(where: { $0.id == series.id }),
                  abs(shiftedHead.scheduledAt.timeIntervalSince(headDate.addingTimeInterval(3600))) < 1 else {
                throw Failure.message("Moving the series from an occurrence did not move it consistently")
            }

            // "Solo esta ocurrencia" after changing its date skips the ORIGINAL day, not the new one.
            projected = model.tasksForDay(farDay).projected.first(where: { $0.seriesID == series.id })!
            let originalDay = projected.scheduledAt
            projected.scheduledAt = cal.date(byAdding: .day, value: 1, to: originalDay)!
            model.saveEdited(projected, originalOccurrenceDate: originalDay, onlyThisOccurrence: true)
            guard let skippingHead = model.workspace.tasks.first(where: { $0.id == series.id }),
                  skippingHead.skippedDates.contains(FocusRules.dayKey(for: originalDay)),
                  !model.tasksForDay(originalDay).projected.contains(where: { $0.seriesID == series.id }) else {
                throw Failure.message("Detaching a moved occurrence left the original day projected")
            }

            // A detached occurrence edited as "toda la serie" never turns the series into "No repetir" or duplicates it.
            var single = model.workspace.tasks.first(where: { $0.id == snoozedSingle.id })!
            single.title = "Serie diaria final"
            let countBeforeDetachedEdit = model.workspace.tasks.count
            model.saveEdited(single, originalOccurrenceDate: single.scheduledAt, onlyThisOccurrence: false)
            guard let finalHead = model.workspace.tasks.first(where: { $0.id == series.id }),
                  finalHead.repeatRule == .daily,
                  finalHead.title == "Serie diaria final",
                  model.workspace.tasks.count == countBeforeDetachedEdit,
                  model.workspace.tasks.first(where: { $0.id == snoozedSingle.id })?.title == "Serie diaria final" else {
                throw Failure.message("Editing a detached occurrence broke or duplicated the series")
            }
            model.saveEdited(single, originalOccurrenceDate: single.scheduledAt, onlyThisOccurrence: true)
            guard model.workspace.tasks.count == countBeforeDetachedEdit else {
                throw Failure.message("'Solo esta' on a detached occurrence duplicated it")
            }

            // A series left on an earlier day is rolled to today and the missed day stays as one overdue task.
            let yesterday = cal.date(byAdding: .day, value: -1, to: Date())!
            let missedSeries = FocusTask(title: "Serie saltada", scheduledAt: cal.date(bySettingHour: 8, minute: 0, second: 0, of: yesterday)!, minutes: 20, repeatRule: .daily)
            model.saveTask(missedSeries)
            guard model.rollMissedSeries(),
                  let rolledHead = model.workspace.tasks.first(where: { $0.id == missedSeries.id }),
                  cal.isDateInToday(rolledHead.scheduledAt) || rolledHead.scheduledAt > Date(),
                  model.workspace.tasks.filter({ $0.seriesID == missedSeries.id && $0.repeatRule == .never }).count == 1 else {
                throw Failure.message("A missed day froze the series in the past")
            }
            for leftover in model.workspace.tasks where leftover.id == series.id || leftover.seriesID == series.id ||
                leftover.id == missedSeries.id || leftover.seriesID == missedSeries.id {
                model.deleteTask(leftover)
            }

            // 4e. Reminders that cannot reach the user are announced on Hoy instead of failing silently.
            let reminderProbe = FocusTask(title: "Aviso futuro", scheduledAt: Date().addingTimeInterval(7200), minutes: 15)
            model.saveTask(reminderProbe)
            let realStatus = model.reminders.status
            model.notificationBannerDismissed = false
            model.reminders.status = .denied
            let deniedNeedsAttention = model.notificationsNeedAttention
            model.reminders.status = .notDetermined
            let undecidedNeedsAttention = model.notificationsNeedAttention
            model.reminders.status = .authorized
            let authorizedNeedsAttention = model.notificationsNeedAttention
            model.reminders.status = .denied
            model.notificationBannerDismissed = true
            let dismissedNeedsAttention = model.notificationsNeedAttention
            model.notificationBannerDismissed = false
            model.reminders.status = realStatus
            model.deleteTask(reminderProbe)
            let nothingToRemind = model.notificationsNeedAttention && !model.workspace.tasks.contains { !$0.completed && $0.isScheduled && $0.scheduledAt > Date() }
            guard deniedNeedsAttention, undecidedNeedsAttention, !authorizedNeedsAttention, !dismissedNeedsAttention, !nothingToRemind else {
                throw Failure.message("Disabled-reminders warning shows at the wrong time")
            }

            // 4f. An accidental «He terminado» can be undone, and an unfinished session found at launch is offered back.
            let reopenTask = FocusTask(title: "Volver atrás", scheduledAt: Date().addingTimeInterval(3600), minutes: 30)
            model.saveTask(reopenTask)
            model.start(reopenTask)
            try await idle(model)
            try await Task.sleep(nanoseconds: 300_000_000)
            model.finish()
            try await idle(model)
            let workedBeforeReopen = model.session?.accumulated ?? -1
            guard model.showCompletion, model.session?.endedAt != nil else { throw Failure.message("Finish before reopen") }
            model.reopenSession()
            guard model.session?.endedAt == nil, model.session?.paused == false, !model.showCompletion,
                  abs((model.session?.accumulated ?? 0) - workedBeforeReopen) < 0.5 else {
                throw Failure.message("Reopening the session did not bring the countdown back with the worked time")
            }
            // Simulate an unexpected quit: a second model opening the same files finds the running session.
            _ = model.persist()
            let recoveryDir = model.store.url.deletingLastPathComponent().appendingPathComponent("recovery")
            try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: recoveryDir.appendingPathComponent("workspace.json"))
            try FileManager.default.copyItem(at: model.store.url, to: recoveryDir.appendingPathComponent("workspace.json"))
            let recovered = AppModel(directory: recoveryDir, preview: true)
            guard let recoveryPrompt = recovered.resumePrompt, recoveryPrompt.contains("Volver atrás"),
                  recovered.session?.paused == true else {
                throw Failure.message("A session interrupted by a quit was not offered back with a lasting prompt")
            }
            model.cancelSession(note: "Cierre tras prueba de volver atrás")
            model.deleteTask(reopenTask)

            // 4g. A task marked to start on its own does so at its time (only once, and not on top of a session).
            let autoTask = FocusTask(title: "Empieza sola", scheduledAt: Date().addingTimeInterval(-2), minutes: 20, autoStart: true)
            model.saveTask(autoTask)
            try await settle(until: { model.session?.task.id == autoTask.id }, tries: 200)
            try await idle(model)
            model.cancelSession(note: "Cierre tras prueba de inicio automático")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            guard model.session == nil else { throw Failure.message("An auto-start task started a second time") }
            model.deleteTask(autoTask)

            // 4g'. «Sigue pendiente» with «Empezar la siguiente» starts another task, not the one just worked on
            // (still pending and the most imminent, it used to start all over again).
            let pendingWork = FocusTask(title: "Sigue pendiente", scheduledAt: Date().addingTimeInterval(-1800), minutes: 45)
            let afterIt = FocusTask(title: "La de después", scheduledAt: Date().addingTimeInterval(3000), minutes: 30)
            model.saveTask(pendingWork)
            model.saveTask(afterIt)
            model.start(pendingWork)
            try await settle(until: { model.session?.task.id == pendingWork.id }, tries: 200)
            model.finish()
            try await idle(model)
            model.confirm(completed: false, note: "", transition: .startNextNow)
            try await idle(model)
            guard let startedNext = model.session, startedNext.task.id != pendingWork.id else {
                throw Failure.message("«Sigue pendiente» + «Empezar la siguiente» started the same task again")
            }
            model.cancelSession(note: "Cierre tras prueba de la siguiente")
            model.deleteTask(pendingWork)
            model.deleteTask(afterIt)

            // 4g''. Completing an occurrence keeps the days detached from the series in it: editing one still offers
            // «toda la serie», and changing the whole series from it reaches the new head.
            let keyCal = Calendar.current
            let keySeries = FocusTask(title: "Serie con clave", scheduledAt: Date().addingTimeInterval(-600), minutes: 20, repeatRule: .daily)
            model.saveTask(keySeries)
            let laterDay = keyCal.date(byAdding: .day, value: 3, to: keySeries.scheduledAt)!
            var laterDraft = keySeries
            laterDraft.seriesID = keySeries.id
            laterDraft.scheduledAt = laterDay
            model.saveTask(laterDraft, detachFromSeriesID: keySeries.id, occurrenceDate: laterDay)
            guard let keyDetached = model.workspace.tasks.first(where: { $0.seriesID == keySeries.id && $0.repeatRule == .never }) else {
                throw Failure.message("Detaching a later day of a series failed")
            }
            model.start(keySeries)
            try await settle(until: { model.session?.task.id == keySeries.id }, tries: 200)
            model.finish()
            try await idle(model)
            model.confirm(completed: true, note: "", transition: .keepSchedule)
            try await idle(model)
            guard let newHead = model.workspace.tasks.first(where: { $0.seriesID == keySeries.id && $0.repeatRule == .daily && !$0.completed }),
                  case .detached(let headID) = model.seriesEditKind(for: keyDetached), headID == newHead.id else {
                throw Failure.message("After completing an occurrence, a detached day no longer belonged to its series")
            }
            var renamed = keyDetached
            renamed.title = "Serie con clave renombrada"
            model.saveEdited(renamed, originalOccurrenceDate: keyDetached.scheduledAt, onlyThisOccurrence: false)
            guard model.workspace.tasks.first(where: { $0.id == newHead.id })?.title == "Serie con clave renombrada" else {
                throw Failure.message("«Toda la serie» from a detached day did not reach the series after a completion")
            }
            for leftover in model.workspace.tasks where leftover.id == keySeries.id || leftover.seriesID == keySeries.id {
                model.deleteTask(leftover)
            }

            // 4g'''. «Programar en el día seleccionado» lands on the 5-minute grid and after the day's tasks.
            let inboxItem = FocusTask(title: "De la bandeja", isScheduled: false, minutes: 25)
            model.saveTask(inboxItem)
            let planDay = keyCal.date(byAdding: .day, value: 2, to: keyCal.startOfDay(for: Date()))!
            model.scheduleInFirstFreeSlot(inboxItem, on: planDay)
            guard let planned = model.workspace.tasks.first(where: { $0.id == inboxItem.id }), planned.isScheduled,
                  keyCal.isDate(planned.scheduledAt, inSameDayAs: planDay),
                  Int(planned.scheduledAt.timeIntervalSinceReferenceDate) % 300 == 0 else {
                throw Failure.message("Scheduling an inbox task did not land on the day's 5-minute grid")
            }
            model.deleteTask(planned)

            // 4h. Agenda: one-step undo that never reverts a later edit, quick actions for slipped tasks, worked time,
            // and new tasks proposed in the first free slot.
            let calB = Calendar.current
            let movable = FocusTask(title: "Mover y deshacer", scheduledAt: Date().addingTimeInterval(5400), minutes: 30)
            model.saveTask(movable)
            model.undoManager.removeAllActions()
            model.shift(movable, to: movable.scheduledAt.addingTimeInterval(1800))
            try await nextEvent()
            guard model.canUndoAgenda, model.undoManager.undoActionName.contains("Mover") else {
                throw Failure.message("Undo not offered (with its name) after moving a task")
            }
            model.undoAgendaChange()
            try await nextEvent()
            guard let undone = model.workspace.tasks.first(where: { $0.id == movable.id }),
                  abs(undone.scheduledAt.timeIntervalSince(movable.scheduledAt)) < 1, model.undoManager.canRedo else {
                throw Failure.message("Undo did not put the task back")
            }
            // Rehacer brings the move back.
            model.redoAgendaChange()
            try await nextEvent()
            guard let redone = model.workspace.tasks.first(where: { $0.id == movable.id }),
                  abs(redone.scheduledAt.timeIntervalSince(movable.scheduledAt.addingTimeInterval(1800))) < 1 else {
                throw Failure.message("Redo did not apply the move again")
            }
            // A later, unrelated edit is never reverted by an older undo step: the step is refused instead.
            var other = FocusTask(title: "Otra edición", scheduledAt: Date().addingTimeInterval(9000), minutes: 15)
            model.saveTask(other)
            other.title = "Otra edición cambiada"
            model.saveTask(other)
            try await nextEvent()
            model.undoAgendaChange()
            try await nextEvent()
            guard model.workspace.tasks.contains(where: { $0.id == other.id && $0.title == "Otra edición cambiada" }),
                  let stillMoved = model.workspace.tasks.first(where: { $0.id == movable.id }),
                  abs(stillMoved.scheduledAt.timeIntervalSince(movable.scheduledAt.addingTimeInterval(1800))) < 1 else {
                throw Failure.message("An old undo step reverted an unrelated later edit")
            }
            // Deleting can be undone.
            model.deleteTask(other)
            try await nextEvent()
            guard model.canUndoAgenda else { throw Failure.message("Undo not offered after deleting") }
            model.undoAgendaChange()
            try await nextEvent()
            guard model.workspace.tasks.contains(where: { $0.id == other.id && $0.title == "Otra edición cambiada" }) else {
                throw Failure.message("Undo did not restore the deleted task")
            }
            // Undoing a snooze of a series removes the detached copy and restores the series exactly.
            let undoSeries = FocusTask(title: "Serie deshacer", scheduledAt: Date().addingTimeInterval(4000), minutes: 20, repeatRule: .daily)
            model.saveTask(undoSeries)
            let tasksBeforeSnooze = model.workspace.tasks.count
            model.snoozeTask(undoSeries, minutes: 10)
            try await nextEvent()
            model.undoAgendaChange()
            try await nextEvent()
            guard model.workspace.tasks.count == tasksBeforeSnooze,
                  let seriesBack = model.workspace.tasks.first(where: { $0.id == undoSeries.id }),
                  abs(seriesBack.scheduledAt.timeIntervalSince(undoSeries.scheduledAt)) < 1 else {
                throw Failure.message("Undoing a series snooze left the detached copy or moved the series")
            }
            // Slipped task: back today in the first free slot, or tomorrow at the same time.
            let slipped = FocusTask(title: "Atrasada", scheduledAt: calB.date(byAdding: .day, value: -2, to: Date())!, minutes: 25)
            model.saveTask(slipped)
            model.moveToFirstFreeSlotToday(slipped)
            guard let today = model.workspace.tasks.first(where: { $0.id == slipped.id }),
                  calB.isDateInToday(today.scheduledAt) || today.scheduledAt > Date(), today.scheduledAt > Date() else {
                throw Failure.message("Overdue task was not placed in today's first free slot")
            }
            model.moveToTomorrowSameTime(today)
            guard let tomorrow = model.workspace.tasks.first(where: { $0.id == slipped.id }), calB.isDateInTomorrow(tomorrow.scheduledAt),
                  calB.component(.hour, from: tomorrow.scheduledAt) == calB.component(.hour, from: today.scheduledAt) else {
                throw Failure.message("Overdue task was not moved to tomorrow at the same time")
            }
            // New task for a busy day: right after its last task, not on top of it.
            let busyDay = calB.date(byAdding: .day, value: 3, to: calB.startOfDay(for: Date()))!
            let morning = FocusTask(title: "Mañana ocupada", scheduledAt: calB.date(bySettingHour: model.workspace.settings.workStartHour, minute: 0, second: 0, of: busyDay)!, minutes: 45)
            model.saveTask(morning)
            guard model.newTaskDraft(for: busyDay).scheduledAt >= morning.end else {
                throw Failure.message("New task draft was not placed after the day's last task")
            }
            // Worked time today includes the confirmed sessions of today.
            guard model.workedSeconds(on: Date()) > 0 else { throw Failure.message("Worked time today is zero after sessions") }
            for leftover in [movable.id, other.id, undoSeries.id, slipped.id, morning.id] {
                if let task = model.workspace.tasks.first(where: { $0.id == leftover }) { model.deleteTask(task) }
            }

            // 4i. Quick capture from the panel files an inbox task; the checklist can be ticked while confirming.
            guard model.quickCapture("Llamar al gestor"),
                  let captured = model.workspace.tasks.first(where: { $0.title == "Llamar al gestor" }), !captured.isScheduled else {
                throw Failure.message("Quick capture did not file an inbox task")
            }
            guard !model.quickCapture("   ") else { throw Failure.message("Quick capture accepted an empty title") }
            model.deleteTask(captured)
            let checklistTask = FocusTask(title: "Pasos al confirmar", scheduledAt: Date().addingTimeInterval(7200), minutes: 30, checklist: "Uno\nDos")
            model.saveTask(checklistTask)
            model.start(checklistTask)
            try await idle(model)
            model.finish()
            try await idle(model)
            model.setCheck("1", value: true)
            guard model.session?.checked.contains("1") == true else { throw Failure.message("Checklist could not be ticked while confirming") }
            model.confirm(completed: true, note: "")
            guard model.workspace.history.first?.checklistSteps.map(\.done) == [false, true] else {
                throw Failure.message("Ticked steps were not kept in the history")
            }

            // 4j. Keyboard: ↑↓ walk the tasks in on-screen order, ⌥↑↓ move the chosen one, ⌥⇧↑↓ change its length.
            let calK = Calendar.current
            model.selectedDate = Date()
            let keyA = FocusTask(title: "Teclado A", scheduledAt: Date().addingTimeInterval(3 * 3600), minutes: 30)
            let keyB = FocusTask(title: "Teclado B", scheduledAt: Date().addingTimeInterval(4 * 3600), minutes: 30)
            model.saveTask(keyA)
            model.saveTask(keyB)
            if calK.isDateInToday(keyA.scheduledAt) && calK.isDateInToday(keyB.scheduledAt) {
                model.selectedTaskID = nil
                let order = model.keyboardTasks.map(\.id)
                guard let indexA = order.firstIndex(of: keyA.id), let indexB = order.firstIndex(of: keyB.id), indexA < indexB else {
                    throw Failure.message("Keyboard order does not follow the agenda")
                }
                model.selectedTaskID = keyA.id
                model.moveSelection(by: indexB - indexA)
                guard model.selectedTaskID == keyB.id else { throw Failure.message("Arrow keys did not reach the next task") }
                model.nudgeSelected(minutes: 5)
                model.resizeSelected(by: 5)
                guard let movedB = model.workspace.tasks.first(where: { $0.id == keyB.id }),
                      abs(movedB.scheduledAt.timeIntervalSince(keyB.scheduledAt) - 300) < 1, movedB.minutes == 35,
                      model.selectedTaskID == keyB.id else {
                    throw Failure.message("Option-arrows did not move or resize the selected task")
                }
            }
            model.selectedTaskID = nil
            model.deleteTask(model.workspace.tasks.first { $0.id == keyA.id }!)
            model.deleteTask(model.workspace.tasks.first { $0.id == keyB.id }!)

            // 4k. A file with one unreadable task opens anyway, after keeping the original in backups/.
            let damagedDir = model.store.url.deletingLastPathComponent().appendingPathComponent("damaged")
            try FileManager.default.createDirectory(at: damagedDir, withIntermediateDirectories: true)
            var damaged = Workspace()
            damaged.tasks = [FocusTask(title: "Sana", minutes: 20)]
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(damaged)) as! [String: Any]
            json["tasks"] = (json["tasks"] as! [[String: Any]]) + [["title": 7]]
            try JSONSerialization.data(withJSONObject: json).write(to: damagedDir.appendingPathComponent("workspace.json"))
            let tolerant = AppModel(directory: damagedDir, preview: true)
            let kept = (try? FileManager.default.contentsOfDirectory(atPath: damagedDir.appendingPathComponent("backups").path)) ?? []
            guard !tolerant.readOnly, tolerant.workspace.tasks.map(\.title) == ["Sana"],
                  tolerant.error?.contains("no se podía leer") == true,
                  kept.contains(where: { $0.hasPrefix("lectura-parcial") }) else {
                throw Failure.message("One unreadable task locked the agenda or the original was not kept")
            }

            // 5. Session cancellation distinct from completion (Item 13)
            let nextTask = model.workspace.tasks.first(where: { !$0.completed && $0.title == restored.tasks.filter({ !$0.completed }).first!.title })
                ?? restored.tasks.filter({ !$0.completed }).first!
            model.start(nextTask)
            try await idle(model)
            model.cancelSession(note: "Cancelación de prueba")
            guard model.session == nil,
                  model.workspace.history.first?.cancelled == true,
                  model.workspace.tasks.first(where: { $0.id == nextTask.id })?.completed == false else {
                throw Failure.message("Cancel session")
            }

            // 6. Save failure preserves in-memory changes, genuinely pauses active session, keeps controls usable, and recovers on retrySave
            model.start(nextTask)
            try await idle(model)
            let storeDir = model.store.url.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDir.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path) }

            let inMemoryTask = FocusTask(title: "Tarea creada sin permisos de disco", scheduledAt: Date().addingTimeInterval(1800), minutes: 25)
            model.saveTask(inMemoryTask)
            guard model.hasUnsavedChanges,
                  model.error != nil,
                  !model.readOnly,
                  model.session?.paused == true,
                  model.workspace.tasks.contains(where: { $0.id == inMemoryTask.id }) else {
                throw Failure.message("Save failure did not pause session or lost in-memory task")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path)
            guard model.retrySave(),
                  !model.hasUnsavedChanges,
                  model.error == nil,
                  try model.store.load().tasks.contains(where: { $0.id == inMemoryTask.id }) else {
                throw Failure.message("retrySave did not persist in-memory task")
            }
            model.cancelSession(note: "Cierre tras prueba de fallo de escritura")

            // 7. Deleting a task with a pending upsert and no calendarEventID clears the pending op
            model.workspace.enqueueCalendarOp(
                PendingCalendarOp(
                    taskID: inMemoryTask.id,
                    action: .upsert,
                    snapshot: CalendarSnapshot(title: inMemoryTask.title, start: inMemoryTask.scheduledAt, end: inMemoryTask.end),
                    eventID: nil
                )
            )
            model.deleteTask(inMemoryTask)
            guard !model.workspace.pendingCalendarOps.contains(where: { $0.taskID == inMemoryTask.id }) else {
                throw Failure.message("Deleted task left pending upsert op in queue")
            }

            // 8. Protected sessions: the code, the wait, «hasta el final» and the ratchet, end to end.
            let guarded = FocusTask(
                title: "Sesión con código",
                scheduledAt: Date().addingTimeInterval(300),
                minutes: 30,
                protection: .challenge,
                unlockChars: 12
            )
            model.saveTask(guarded)
            model.start(guarded)
            try await idle(model)
            guard model.session?.task.id == guarded.id else { throw Failure.message("Protected session did not start") }

            model.pause()
            guard let challenge = model.pendingStop, challenge.reason == .pause,
                  challenge.expected.count == 12, model.session?.paused == false else {
                throw Failure.message("Pausing a protected session asked for no code, or paused anyway")
            }
            // A wrong code hands out a fresh one instead of letting the attempt stand.
            model.pendingStop?.typed = String(challenge.expected.dropLast()) + "@"
            model.submitStopChallenge()
            guard let second = model.pendingStop, second.attempts == 1, second.expected != challenge.expected,
                  model.session?.paused == false else {
                throw Failure.message("A wrong code did not reset the challenge")
            }
            model.pendingStop?.typed = second.expected
            model.submitStopChallenge()
            guard model.pendingStop == nil, model.session?.paused == true else {
                throw Failure.message("The right code did not pause the session")
            }
            model.resume()

            // The ratchet: a running protected session can be made longer, never shorter or looser.
            var shorter = guarded
            shorter.minutes = 5
            model.saveTask(shorter)
            guard model.session?.task.minutes == 30 else { throw Failure.message("The ratchet let a running session be shortened") }
            var longer = guarded
            longer.minutes = 45
            model.saveTask(longer)
            guard model.session?.task.minutes == 45, model.session?.budget == 45 * 60 else {
                throw Failure.message("The ratchet refused a legitimate extension")
            }
            var looser = longer
            looser.protection = .none
            model.saveTask(looser)
            guard model.session?.task.protection == .challenge else {
                throw Failure.message("The ratchet let the protection be removed mid-session")
            }
            model.authorizedStop = .cancel
            model.cancelSession(note: "Cierre tras prueba de código")
            guard model.session == nil else { throw Failure.message("Authorized cancel did not go through") }

            // A wait instead of a code: the session keeps running while it counts down, and can be called off.
            let waited = FocusTask(
                title: "Sesión con espera",
                scheduledAt: Date().addingTimeInterval(300),
                minutes: 30,
                protection: .delay,
                stopDelayMinutes: 7
            )
            model.saveTask(waited)
            model.start(waited)
            try await idle(model)
            model.pause()
            guard let request = model.session?.stopRequest, request.reason == .pause,
                  model.session?.paused == false, request.remaining() > 6 * 60 else {
                throw Failure.message("The wait was not armed, or the session paused anyway")
            }
            model.cancelStopRequest()
            guard model.session?.stopRequest == nil, model.session?.paused == false else {
                throw Failure.message("The wait could not be called off")
            }
            model.authorizedStop = .cancel
            model.cancelSession(note: "Cierre tras prueba de espera")

            // «Hasta el final»: refused outright, with an emergency way out that costs sixty characters.
            let sealed = FocusTask(
                title: "Sesión hasta el final",
                scheduledAt: Date().addingTimeInterval(300),
                minutes: 30,
                protection: .forced
            )
            model.saveTask(sealed)
            model.start(sealed)
            try await idle(model)
            model.pause()
            guard model.session?.paused == false, model.pendingStop == nil else {
                throw Failure.message("A forced session could be paused")
            }
            guard model.notice?.contains("Emergencia") == true else {
                throw Failure.message("Refusing to pause «hasta el final» did not say where the emergency exit is")
            }
            // A hand-off refused outright neither claims the session stopped nor leaves the other task queued.
            let handoffTarget = FocusTask(title: "Otra tarea durante «hasta el final»", scheduledAt: Date().addingTimeInterval(900), minutes: 20)
            model.saveTask(handoffTarget)
            model.start(handoffTarget)
            model.acceptHandoff()
            guard model.session?.task.id == sealed.id, model.session?.endedAt == nil, model.queuedStartTask == nil else {
                throw Failure.message("A refused hand-off stopped the session or left the other task queued")
            }
            model.deleteTask(handoffTarget)
            // A restart is never refused, not even here: the session is saved to come back instead. The quit
            // events are built like the ones macOS sends; a plain ⌘Q carries no reason and still meets the gate.
            for code in [kAERestart, kAEShutDown, kAEReallyLogOut] {
                guard QuitEvent.isSystemQuit(QuitEvent.make(reason: OSType(code))),
                      QuitEvent.isSystemQuit(QuitEvent.make(reason: OSType(code), asAttribute: false)) else {
                    throw Failure.message("A restart or shutdown quit event was not recognised")
                }
            }
            guard !QuitEvent.isSystemQuit(QuitEvent.make(reason: nil)), !QuitEvent.isSystemQuit(nil) else {
                throw Failure.message("A plain quit was taken for a restart")
            }
            guard model.canQuitNow(systemQuit: true) else { throw Failure.message("A restart was refused by «hasta el final»") }
            model.quittingForSystem = false
            model.requestEmergencyExit()
            guard let escape = model.pendingStop, escape.emergency, escape.expected.count == 60 else {
                throw Failure.message("The emergency way out was not offered")
            }
            model.pendingStop?.typed = escape.expected
            model.submitStopChallenge()
            guard model.session == nil, model.workspace.settings.emergencyUses.count == 1 else {
                throw Failure.message("The emergency exit did not end the session or left no trace")
            }

            // 8b. The ways out that used to be free, closed. Locking the screen pauses a protected session — the
            // locked time does not count — and unlocking brings it back without asking.
            let lockedTask = FocusTask(
                title: "Sesión protegida y pantalla bloqueada",
                scheduledAt: Date().addingTimeInterval(300),
                minutes: 30,
                protection: .challenge
            )
            model.saveTask(lockedTask)
            model.start(lockedTask)
            try await idle(model)
            model.screenLocked()
            guard model.session?.paused == true else { throw Failure.message("Locking the screen did not pause the protected session") }
            let lockedAccumulated = model.session?.accumulated ?? 0
            model.screenUnlocked()
            guard model.session?.paused == false, model.resumePrompt == nil,
                  model.session?.accumulated == lockedAccumulated else {
                throw Failure.message("Unlocking did not resume the protected session by itself, or counted the locked time")
            }
            // Copies, the vigilance settings and the punisher stay as they are while it runs.
            let protectedID = model.session?.id
            model.recoverFromAutoBackup()
            guard model.session?.id == protectedID, model.session?.paused == false else {
                throw Failure.message("Recovering a copy ended a protected session")
            }
            model.updateBlockingSetting(turningOn: false) { $0.watchBackgroundWindows = false }
            guard model.workspace.settings.watchBackgroundWindows else {
                throw Failure.message("A vigilance setting could be switched off mid-session")
            }
            var softer = lockedTask
            softer.punisherEnabled = false
            model.saveTask(softer)
            guard model.session?.task.punisherEnabled == true else { throw Failure.message("The ratchet let the punisher be switched off") }
            model.authorizedStop = .cancel
            model.cancelSession(note: "Cierre tras prueba de pantalla bloqueada")

            // FocusDesk killed in the middle of a protected session: reopened, the session carries on by itself.
            let crashDir = FileManager.default.temporaryDirectory.appendingPathComponent("FocusDesk-smoke-crash-" + UUID().uuidString)
            let crashStore = WorkspaceStore(url: crashDir.appendingPathComponent("workspace.json"))
            var crashed = WorkSession(task: FocusTask(title: "Sesión cerrada a la fuerza", scheduledAt: Date(), minutes: 30, protection: .forced))
            crashed.checkpoint(at: Date())
            var crashWorkspace = Workspace()
            crashWorkspace.session = crashed
            try crashStore.save(crashWorkspace)
            let reopened = AppModel(directory: crashDir, preview: true)
            guard reopened.session?.id == crashed.id, reopened.session?.paused == false, reopened.resumePrompt == nil else {
                throw Failure.message("A protected session came back paused after a force-quit")
            }
            // Closed by a restart: let through, saved, and back by itself at the next launch.
            guard reopened.canQuitNow(systemQuit: true) else { throw Failure.message("A restart was refused") }
            reopened.shutdown()
            guard let savedForRestart = try crashStore.load().session, savedForRestart.paused,
                  savedForRestart.resumeOnLaunchUntil != nil else {
                throw Failure.message("A restart did not save the protected session to come back")
            }
            let afterRestart = AppModel(directory: crashDir, preview: true)
            guard afterRestart.session?.paused == false, afterRestart.session?.resumeOnLaunchUntil == nil else {
                throw Failure.message("The protected session did not come back after the restart")
            }
            // One that would have finished while FocusDesk was closed is offered back, not forced back.
            let staleDir = FileManager.default.temporaryDirectory.appendingPathComponent("FocusDesk-smoke-stale-" + UUID().uuidString)
            var staleWorkspace = Workspace()
            staleWorkspace.session = WorkSession(
                task: FocusTask(title: "Sesión de ayer", scheduledAt: Date().addingTimeInterval(-86_400), minutes: 30, protection: .forced),
                now: Date().addingTimeInterval(-86_400)
            )
            try WorkspaceStore(url: staleDir.appendingPathComponent("workspace.json")).save(staleWorkspace)
            let staleModel = AppModel(directory: staleDir, preview: true)
            guard staleModel.session?.paused == true, staleModel.resumePrompt != nil else {
                throw Failure.message("A session that would have ended long ago was forced back instead of offered")
            }

            // 9. Auto-backup recovery when primary file is corrupted (Item 6 & Item 18)
            try Data("corrupt-json".utf8).write(to: model.store.url)
            model.recoverFromAutoBackup()
            guard !model.readOnly, model.error == nil, !model.workspace.tasks.isEmpty else {
                throw Failure.message("Auto-backup recovery after corruption")
            }

            return "PASS: Dock regular; status item visible; profiles & domain normalization; notification actions; overdue snooze; unscheduled inbox; start/pause/resume/extend; single-timer hand-off (offer, decline, accept, queued start, resume-same-task); recurring series (snooze one occurrence, edit whole series or one occurrence, roll a missed day); lock pauses & unlock offers resume without counting locked time; session shortcuts system-wide only during a session (\(hotKeyStatus)); disabled-reminders warning; reopen after «He terminado»; recovery prompt after a quit; per-task auto-start; agenda undo and redo (move, delete, series snooze) that never reverts a later edit; overdue quick actions; first free slot; worked time; quick capture; checklist while confirming; keyboard selection, move and resize; tolerant reading with the original kept; selective & manual evidence; confirm & recurrence; cancel session; save-failure session pause & in-memory retention; deleted-task pending queue cleanup; auto-backup recovery; protected sessions (code with a fresh one on each miss, wait that can be called off, «hasta el final» plus emergency exit, named in every refusal) and the ratchet on a running session (punisher included); a restart never refused and the session back after it; a protected session back by itself after a force-quit, not after a day; locking the screen pauses and unlocking resumes a protected session; copies, vigilance settings and a refused hand-off cannot end it."
        } catch {
            return "FAIL: \(error.localizedDescription)"
        }
    }

    /// Lets the current event end, as it would between two user actions (AppKit closes undo groups per event).
    private static func nextEvent() async throws {
        try await Task.sleep(nanoseconds: 120_000_000)
    }

    /// Waits for a distributed notification to be delivered and handled on the main actor.
    private static func settle(until condition: @MainActor () -> Bool, tries: Int = 100) async throws {
        for _ in 0..<tries {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.message("Timed out waiting for a system notification to be handled")
    }

    private static func idle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Failure.message("Timed out waiting for file scanner")
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
