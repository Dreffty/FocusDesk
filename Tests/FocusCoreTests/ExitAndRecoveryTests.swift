import XCTest
@testable import FocusCore

/// Both halves of a block that can be trusted: every way out that should cost something does, and the ways out
/// that must always exist — a restart, the emergency exit, the end of the time — always do.
final class ExitAndRecoveryTests: XCTestCase {
    let zero = Date(timeIntervalSince1970: 1_000_000)

    private func task(_ protection: SessionProtection, minutes: Int = 60) -> FocusTask {
        FocusTask(title: "Escribir", minutes: minutes, protection: protection)
    }

    // MARK: - The ratchet and the messages

    func testTheRatchetKeepsThePunisherOnOnceASessionRuns() {
        let current = task(.challenge)
        var softer = current
        softer.punisherEnabled = false
        XCTAssertFalse(Ratchet.judge(current: current, proposed: softer).isAccepted)

        var off = current
        off.punisherEnabled = false
        var on = off
        on.punisherEnabled = true
        XCTAssertTrue(Ratchet.judge(current: off, proposed: on).isAccepted, "switching it on only makes it harder")
    }

    func testEveryRefusalOfHastaElFinalSaysWhereTheEmergencyExitIs() {
        for reason in [StopReason.pause, .cancel, .finishEarly] {
            let decision = StopGate.decide(protection: .forced, reason: reason, timeLeft: 600, unlockChars: 24, stopDelayMinutes: 5, pending: nil)
            guard case .refused(let text) = decision else { return XCTFail("«hasta el final» must refuse \(reason)") }
            XCTAssertTrue(text.contains("Emergencia"), text)
        }
        XCTAssertEqual(
            StopGate.decide(protection: .forced, reason: .cancel, timeLeft: 0, unlockChars: 24, stopDelayMinutes: 5, pending: nil),
            .allowed,
            "with the time up, nothing is protected any more"
        )
    }

    func testEachProtectionNamesItsWayOut() {
        XCTAssertTrue(SessionProtection.none.wayOut.isEmpty)
        for level in [SessionProtection.challenge, .delay, .forced] {
            XCTAssertFalse(level.wayOut.isEmpty, "\(level) must say how to stop it")
        }
        XCTAssertTrue(SessionProtection.forced.wayOut.contains("Emergencia"))
    }

    // MARK: - A restart is never refused

    func testOnlyTheReasonsMacOSUsesWhenShuttingDownCountAsASystemQuit() {
        for code in ["shut", "rest", "rlgo", "logo", "rrst", "rsdn", "quia"] {
            XCTAssertTrue(SystemQuit.isSystemQuit(reasonCode: SystemQuit.fourCharCode(code)), code)
        }
        XCTAssertFalse(SystemQuit.isSystemQuit(reasonCode: nil), "⌘Q and the Dock carry no reason")
        XCTAssertFalse(SystemQuit.isSystemQuit(reasonCode: SystemQuit.fourCharCode("quit")))
        XCTAssertFalse(SystemQuit.isSystemQuit(reasonCode: 0))
        XCTAssertEqual(SystemQuit.fourCharCode("shut"), 0x7368_7574)
    }

    // MARK: - Coming back after FocusDesk went away

    func testAProtectedSessionKilledMidwayComesBackWhileItStillHasTime() {
        var session = WorkSession(task: task(.forced, minutes: 60), now: zero)
        session.checkpoint(at: zero.addingTimeInterval(600))
        XCTAssertTrue(session.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(900)))
        // Its hour would have run out by then: offered, not forced back.
        XCTAssertFalse(session.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(3_700)))
    }

    func testOnlyProtectedRunningSessionsComeBackOnTheirOwn() {
        let unprotected = WorkSession(task: task(.none), now: zero)
        XCTAssertFalse(unprotected.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(60)))

        var pausedOnPurpose = WorkSession(task: task(.challenge), now: zero)
        pausedOnPurpose.pause(at: zero.addingTimeInterval(60))
        XCTAssertFalse(pausedOnPurpose.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(120)),
                       "a pause paid for with the code stays a pause")

        var finished = WorkSession(task: task(.challenge), now: zero)
        finished.finish(at: zero.addingTimeInterval(60))
        XCTAssertFalse(finished.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(120)))

        var spent = WorkSession(task: task(.challenge, minutes: 1), now: zero)
        spent.checkpoint(at: zero.addingTimeInterval(90))
        XCTAssertFalse(spent.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(91)), "no time left")
    }

    func testARestartMarksTheSessionToComeBackAndResumingClearsTheMark() {
        var session = WorkSession(task: task(.delay), now: zero)
        session.pause(at: zero.addingTimeInterval(300))
        session.resumeOnLaunchUntil = zero.addingTimeInterval(300 + 3_300)
        XCTAssertTrue(session.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(400)))
        XCTAssertFalse(session.shouldResumeAfterRelaunch(now: zero.addingTimeInterval(4_000)))
        session.resume(at: zero.addingTimeInterval(400))
        XCTAssertNil(session.resumeOnLaunchUntil)
    }

    func testTheMarkSurvivesSavingAndOldFilesReadWithoutIt() throws {
        var session = WorkSession(task: task(.forced), now: zero)
        session.pause(at: zero.addingTimeInterval(60))
        session.resumeOnLaunchUntil = zero.addingTimeInterval(3_600)
        let decoded = try JSONDecoder().decode(WorkSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.resumeOnLaunchUntil, session.resumeOnLaunchUntil)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        legacy.removeValue(forKey: "resumeOnLaunchUntil")
        let old = try JSONDecoder().decode(WorkSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.resumeOnLaunchUntil)
    }

    // MARK: - The watcher

    func testTheWatcherReopensFocusDeskOnlyForALiveProtectedSession() {
        var running = WorkSession(task: task(.challenge), now: zero)
        running.checkpoint(at: zero.addingTimeInterval(60))
        let now = zero.addingTimeInterval(120)

        XCTAssertTrue(RelaunchDecision.shouldRelaunch(session: running, appRunning: false, watcherAge: 600, recentRelaunches: 0, now: now))
        XCTAssertFalse(RelaunchDecision.shouldRelaunch(session: running, appRunning: true, watcherAge: 600, recentRelaunches: 0, now: now),
                       "never a second copy")
        XCTAssertFalse(RelaunchDecision.shouldRelaunch(session: nil, appRunning: false, watcherAge: 600, recentRelaunches: 0, now: now))

        var quitProperly = running
        quitProperly.pause(at: now)
        XCTAssertFalse(RelaunchDecision.shouldRelaunch(session: quitProperly, appRunning: false, watcherAge: 600, recentRelaunches: 0, now: now),
                       "quitting with the code or the wait is respected")

        let unprotected = WorkSession(task: task(.none), now: zero)
        XCTAssertFalse(RelaunchDecision.shouldRelaunch(session: unprotected, appRunning: false, watcherAge: 600, recentRelaunches: 0, now: now))
    }

    func testTheWatcherGivesUpOnAFocusDeskThatKeepsDying() {
        var running = WorkSession(task: task(.challenge), now: zero)
        running.checkpoint(at: zero.addingTimeInterval(60))
        XCTAssertFalse(RelaunchDecision.shouldRelaunch(
            session: running, appRunning: false, watcherAge: 600,
            recentRelaunches: RelaunchDecision.maxRelaunches, now: zero.addingTimeInterval(120)
        ))
    }

    func testAfterARestartTheWatcherOnlyReopensRightAfterLoggingIn() {
        var closedByRestart = WorkSession(task: task(.forced), now: zero)
        closedByRestart.pause(at: zero.addingTimeInterval(60))
        closedByRestart.resumeOnLaunchUntil = zero.addingTimeInterval(3_600)
        let now = zero.addingTimeInterval(120)
        XCTAssertTrue(RelaunchDecision.shouldRelaunch(session: closedByRestart, appRunning: false, watcherAge: 15, recentRelaunches: 0, now: now),
                      "just logged in: bring it back")
        XCTAssertFalse(RelaunchDecision.shouldRelaunch(session: closedByRestart, appRunning: false, watcherAge: 3_000, recentRelaunches: 0, now: now),
                       "an old watcher is living through the log-out itself and must not get in its way")
    }

    // MARK: - Browsers that cannot be read

    func testBrowsersWhoseAddressCannotBeReadAreKnown() {
        XCTAssertTrue(WebRules.unreadableBrowsers.contains("org.mozilla.firefox"))
        XCTAssertFalse(WebRules.unreadableBrowsers.contains("com.google.Chrome"))
        XCTAssertTrue(WebRules.looksLikeSafariWebApp(bundleID: "com.apple.Safari.WebApp.1A2B3C"))
        XCTAssertFalse(WebRules.looksLikeSafariWebApp(bundleID: "com.apple.Safari"))
        XCTAssertTrue(FocusRules.systemExemptBundleIDs.contains("com.apple.appkit.xpc.openAndSavePanelService"))
    }
}
