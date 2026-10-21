import AppKit
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
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.apple.screenIsLocked"), object: nil, userInfo: nil, deliverImmediately: true
            )
            try await settle(until: { model.session?.paused == true })
            guard model.session?.paused == true, model.session?.endedAt == nil else {
                throw Failure.message("Locking the screen did not pause the session")
            }
            let pausedAt = model.session?.accumulated ?? 0
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, userInfo: nil, deliverImmediately: true
            )
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
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, userInfo: nil, deliverImmediately: true
            )
            try await Task.sleep(nanoseconds: 300_000_000)
            guard model.resumePrompt == nil else {
                throw Failure.message("A user pause should not be reported as a system pause")
            }

            model.cancelSession(note: "Cierre tras prueba de relevo")
            model.deleteTask(taskB)

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

            // 8. Auto-backup recovery when primary file is corrupted (Item 6 & Item 18)
            try Data("corrupt-json".utf8).write(to: model.store.url)
            model.recoverFromAutoBackup()
            guard !model.readOnly, model.error == nil, !model.workspace.tasks.isEmpty else {
                throw Failure.message("Auto-backup recovery after corruption")
            }

            return "PASS: Dock regular; status item visible; profiles & domain normalization; notification actions; overdue snooze; unscheduled inbox; start/pause/resume/extend; single-timer hand-off (offer, decline, accept, queued start, resume-same-task); lock pauses & unlock offers resume without counting locked time; selective & manual evidence; confirm & recurrence; cancel session; save-failure session pause & in-memory retention; deleted-task pending queue cleanup; auto-backup recovery."
        } catch {
            return "FAIL: \(error.localizedDescription)"
        }
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
