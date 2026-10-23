import XCTest
@testable import FocusCore

/// The rules that decide whether a session can be escaped from. Every one of these is a shortcut someone would
/// actually take at 11:30 in the morning, so each gets a test.
final class EnforcementTests: XCTestCase {
    let zero = Date(timeIntervalSince1970: 1_000_000)

    private func protectedTask(
        protection: SessionProtection = .challenge,
        minutes: Int = 60,
        apps: [AllowedApp] = [AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")],
        domains: String = "github.com",
        web: WebBlockAction = .warn
    ) -> FocusTask {
        FocusTask(
            title: "Programar",
            minutes: minutes,
            strict: true,
            apps: apps,
            domains: domains,
            protection: protection,
            webBlockAction: web
        )
    }

    // MARK: - The ratchet

    func testRatchetRefusesEveryWayOfLooseningARunningSession() {
        let current = protectedTask(protection: .delay, minutes: 60, web: .redirect)

        var unblocked = current
        unblocked.strict = false
        XCTAssertFalse(Ratchet.judge(current: current, proposed: unblocked).isAccepted)

        var weaker = current
        weaker.protection = .challenge
        XCTAssertFalse(Ratchet.judge(current: current, proposed: weaker).isAccepted)

        var shorter = current
        shorter.minutes = 20
        XCTAssertFalse(Ratchet.judge(current: current, proposed: shorter).isAccepted)

        var shorterCode = current
        shorterCode.unlockChars = 8
        XCTAssertFalse(Ratchet.judge(current: current, proposed: shorterCode).isAccepted)

        var shorterWait = current
        shorterWait.stopDelayMinutes = 1
        XCTAssertFalse(Ratchet.judge(current: current, proposed: shorterWait).isAccepted)

        var moreApps = current
        moreApps.apps.append(AllowedApp(id: "com.brave.Browser", name: "Brave", path: "/Applications/Brave.app"))
        XCTAssertFalse(Ratchet.judge(current: current, proposed: moreApps).isAccepted)

        var moreDomains = current
        moreDomains.domains = "github.com, youtube.com"
        XCTAssertFalse(Ratchet.judge(current: current, proposed: moreDomains).isAccepted)

        var softerWeb = current
        softerWeb.webBlockAction = .warn
        XCTAssertFalse(Ratchet.judge(current: current, proposed: softerWeb).isAccepted)

        var unguarded = current
        unguarded.guardSystemPanes = false
        XCTAssertFalse(Ratchet.judge(current: current, proposed: unguarded).isAccepted)
    }

    func testRatchetAcceptsHardeningAndNeutralEdits() {
        let current = protectedTask(protection: .challenge, minutes: 60)

        var longer = current
        longer.minutes = 90
        XCTAssertTrue(Ratchet.judge(current: current, proposed: longer).isAccepted)

        var stronger = current
        stronger.protection = .forced
        XCTAssertTrue(Ratchet.judge(current: current, proposed: stronger).isAccepted)

        var fewerApps = current
        fewerApps.apps = [AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")]
        XCTAssertTrue(Ratchet.judge(current: current, proposed: fewerApps).isAccepted)

        var renamed = current
        renamed.title = "Programar el parser"
        renamed.checklist = "Uno\nDos"
        XCTAssertTrue(Ratchet.judge(current: current, proposed: renamed).isAccepted)

        var harderAction = current
        harderAction.blockAction = .forceQuit
        XCTAssertTrue(Ratchet.judge(current: current, proposed: harderAction).isAccepted)
    }

    func testRatchetRefusesLeavingAStrictSessionWithNoAllowedApp() {
        let current = protectedTask()
        var empty = current
        empty.apps = []
        XCTAssertFalse(Ratchet.judge(current: current, proposed: empty).isAccepted)
    }

    // MARK: - Asking to stop

    func testUnprotectedSessionStopsWithoutAsking() {
        let decision = StopGate.decide(
            protection: .none, reason: .pause, timeLeft: 1800,
            unlockChars: 24, stopDelayMinutes: 5, pending: nil
        )
        XCTAssertEqual(decision, .allowed)
    }

    func testNothingIsProtectedOnceTheTimeIsUp() {
        for level in SessionProtection.allCases {
            let decision = StopGate.decide(
                protection: level, reason: .finishEarly, timeLeft: 0,
                unlockChars: 24, stopDelayMinutes: 5, pending: nil
            )
            XCTAssertEqual(decision, .allowed, "\(level) should not hold a session whose time is up")
        }
    }

    func testChallengeGivesACodeOfTheChosenLength() {
        guard case .challenge(let code) = StopGate.decide(
            protection: .challenge, reason: .cancel, timeLeft: 600,
            unlockChars: 32, stopDelayMinutes: 5, pending: nil
        ) else { return XCTFail("expected a challenge") }
        XCTAssertEqual(code.count, 32)
    }

    func testDelayArmsTheWaitThenLetsGoWhenItIsOver() {
        let first = StopGate.decide(
            protection: .delay, reason: .pause, timeLeft: 3600,
            unlockChars: 24, stopDelayMinutes: 10, pending: nil
        )
        XCTAssertEqual(first, .waitStarted(600))

        let pending = StopRequest(reason: .pause, minutes: 10, wall: zero, continuous: 1000)
        let midway = StopGate.decide(
            protection: .delay, reason: .pause, timeLeft: 3600,
            unlockChars: 24, stopDelayMinutes: 10, pending: pending,
            wall: zero.addingTimeInterval(120), continuous: 1120
        )
        XCTAssertEqual(midway, .waiting(480))

        let after = StopGate.decide(
            protection: .delay, reason: .pause, timeLeft: 3600,
            unlockChars: 24, stopDelayMinutes: 10, pending: pending,
            wall: zero.addingTimeInterval(601), continuous: 1601
        )
        XCTAssertEqual(after, .waitFinished)
    }

    func testAPendingWaitForOneReasonDoesNotUnlockAnother() {
        let pending = StopRequest(reason: .pause, minutes: 10, wall: zero, continuous: 1000)
        let decision = StopGate.decide(
            protection: .delay, reason: .cancel, timeLeft: 3600,
            unlockChars: 24, stopDelayMinutes: 10, pending: pending,
            wall: zero.addingTimeInterval(601), continuous: 1601
        )
        XCTAssertEqual(decision, .waitStarted(600))
    }

    func testForcedRefusesEveryEarlyStop() {
        for reason in [StopReason.pause, .cancel, .finishEarly] {
            let decision = StopGate.decide(
                protection: .forced, reason: reason, timeLeft: 1800,
                unlockChars: 24, stopDelayMinutes: 5, pending: nil
            )
            guard case .refused = decision else { return XCTFail("forced should refuse \(reason)") }
        }
    }

    // MARK: - The clock

    func testMovingTheMacClockForwardDoesNotShortenAWait() {
        let request = StopRequest(reason: .cancel, minutes: 10, wall: zero, continuous: 5000)
        // The Mac's clock jumps two hours ahead; only 60 real seconds have passed.
        let remaining = request.remaining(wall: zero.addingTimeInterval(7200), continuous: 5060)
        XCTAssertEqual(remaining, 540)
        XCTAssertFalse(request.ready(wall: zero.addingTimeInterval(7200), continuous: 5060))
    }

    func testDriftSeesTheClockJumpAndIgnoresNormalTime() {
        let honest = TrustedClock.drift(wall: zero.addingTimeInterval(300), continuous: 1300, anchorWall: zero, anchorContinuous: 1000)
        XCTAssertEqual(honest, 0, accuracy: 0.001)
        let cheated = TrustedClock.drift(wall: zero.addingTimeInterval(7200), continuous: 1300, anchorWall: zero, anchorContinuous: 1000)
        XCTAssertEqual(cheated, 6900, accuracy: 0.001)
        XCTAssertGreaterThan(cheated, TrustedClock.suspiciousDrift)
    }

    func testAfterARebootTheDeadlineFallsBackToTheWallClock() {
        let deadline = TrustedDeadline(seconds: 600, wall: zero, continuous: 90_000)
        // The Mac restarted: the continuous clock starts over, so it is below the anchor.
        XCTAssertTrue(deadline.rebooted(continuous: 42))
        let remaining = deadline.remainingAfterPossibleReboot(wall: zero.addingTimeInterval(300), continuous: 42)
        XCTAssertEqual(remaining, 300, accuracy: 0.001)
    }

    // MARK: - The punisher

    func testPunisherFiresAfterRepeatedAttemptsAndCalmsDown() {
        var punisher = DistractionPunisher(maxAttempts: 4, window: 180, duration: 600)
        XCTAssertFalse(punisher.register(at: 100))
        XCTAssertFalse(punisher.register(at: 110))
        XCTAssertFalse(punisher.register(at: 120))
        XCTAssertTrue(punisher.register(at: 130), "the fourth attempt inside the window should fire it")
        XCTAssertTrue(punisher.isActive(at: 200))
        XCTAssertEqual(punisher.remaining(at: 330), 400, accuracy: 0.001)
        XCTAssertFalse(punisher.isActive(at: 731))
        XCTAssertEqual(punisher.timesTriggered, 1)
    }

    func testAttemptsSpreadOutDoNotFireThePunisher() {
        var punisher = DistractionPunisher(maxAttempts: 4, window: 180, duration: 600)
        for instant in stride(from: 0.0, through: 1200.0, by: 200) {
            XCTAssertFalse(punisher.register(at: instant))
        }
        XCTAssertFalse(punisher.isActive(at: 1200))
    }

    func testPunisherHardensTheActionOnlyWhileItIsOn() {
        var session = WorkSession(task: protectedTask(), now: zero)
        XCTAssertEqual(session.activeBlockAction(at: 10), .hide)
        for instant in [10.0, 11, 12, 13] { session.punisher.register(at: instant) }
        XCTAssertEqual(session.activeBlockAction(at: 20), .close)
        XCTAssertEqual(session.activeBlockAction(at: 10_000), .hide)
    }

    func testPunisherCanBeTurnedOffPerTask() {
        var task = protectedTask()
        task.punisherEnabled = false
        var session = WorkSession(task: task, now: zero)
        for _ in 0..<8 { XCTAssertFalse(session.registerBlock(at: 100)) }
        XCTAssertEqual(session.blocksApplied, 8)
        XCTAssertEqual(session.activeBlockAction(at: 100), .hide)
    }

    // MARK: - The code to type

    func testChallengeCodeHasNoCharactersYouCannotTellApart() {
        let code = UnlockChallenge.make(length: 60)
        XCTAssertEqual(code.count, 60)
        for forbidden in ["0", "O", "1", "l", "I"] {
            XCTAssertFalse(code.contains(forbidden), "\(forbidden) is too easy to mistype blind")
        }
    }

    func testChallengeLengthStaysInsideTheOfferedRange() {
        XCTAssertEqual(UnlockChallenge.make(length: 2).count, UnlockChallenge.lengthRange.lowerBound)
        XCTAssertEqual(UnlockChallenge.make(length: 5000).count, UnlockChallenge.lengthRange.upperBound)
    }

    func testTypedCodeMustMatchExactly() {
        XCTAssertTrue(UnlockChallenge.matches(typed: "AbC9", expected: "AbC9"))
        XCTAssertFalse(UnlockChallenge.matches(typed: "abc9", expected: "AbC9"))
        XCTAssertFalse(UnlockChallenge.matches(typed: "AbC", expected: "AbC9"))
        XCTAssertFalse(UnlockChallenge.matches(typed: "", expected: ""))
        XCTAssertEqual(UnlockChallenge.correctPrefix(typed: "AbX9", expected: "AbC9"), 2)
    }

    // MARK: - The witness

    func testWitnessNoticesWhenItsOwnFieldsAreChanged() {
        let witness = SessionWitness(
            sessionID: UUID(),
            taskTitle: "Programar",
            protection: .forced,
            deadline: TrustedDeadline(seconds: 1800, wall: zero, continuous: 1000)
        )
        XCTAssertTrue(witness.intact)
        XCTAssertTrue(witness.live(wall: zero.addingTimeInterval(60), continuous: 1060))

        var edited = witness
        edited.protection = .none
        XCTAssertFalse(edited.intact, "weakening the stored protection has to break the digest")

        var retitled = witness
        retitled.taskTitle = "Otra cosa"
        XCTAssertFalse(retitled.intact)
    }

    func testWitnessStopsMatteringOnceItsTimeIsUp() {
        let witness = SessionWitness(
            sessionID: UUID(),
            taskTitle: "Programar",
            protection: .challenge,
            deadline: TrustedDeadline(seconds: 600, wall: zero, continuous: 1000)
        )
        XCTAssertFalse(witness.live(wall: zero.addingTimeInterval(601), continuous: 1601))
    }

    func testWitnessSurvivesEncodingRoundTrip() throws {
        let witness = SessionWitness(
            sessionID: UUID(),
            taskTitle: "Programar",
            protection: .delay,
            deadline: TrustedDeadline(seconds: 900, wall: zero, continuous: 1000)
        )
        let decoded = try JSONDecoder().decode(SessionWitness.self, from: JSONEncoder().encode(witness))
        XCTAssertEqual(decoded, witness)
        XCTAssertTrue(decoded.intact)
    }

    // MARK: - What may be acted on

    func testCriticalSystemAppsAreOnlyEverHidden() {
        XCTAssertEqual(FocusRules.safeAction(.forceQuit, for: "com.apple.finder"), .hide)
        XCTAssertEqual(FocusRules.safeAction(.close, for: "com.apple.dock"), .hide)
        XCTAssertEqual(FocusRules.safeAction(.forceQuit, for: "local.focusdesk.app"), .hide)
        XCTAssertEqual(FocusRules.safeAction(.forceQuit, for: "com.riotgames.RiotClient"), .forceQuit)
    }

    func testChromiumWebAppsAreRecognisedAndRealAppsAreNot() {
        XCTAssertTrue(WebRules.looksLikeChromiumWebApp(bundleID: "com.google.Chrome.app.agimnkijcaahngcdmfeangaknmldooml"))
        XCTAssertTrue(WebRules.looksLikeChromiumWebApp(bundleID: "com.brave.Browser.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"))
        XCTAssertFalse(WebRules.looksLikeChromiumWebApp(bundleID: "com.google.Chrome"))
        XCTAssertFalse(WebRules.looksLikeChromiumWebApp(bundleID: "com.apple.Safari"))
    }

    func testBrowsersAreRecognisedWithTheRightFlavour() {
        XCTAssertEqual(WebRules.browserKind(for: "com.apple.Safari"), .safari)
        XCTAssertEqual(WebRules.browserKind(for: "com.brave.Browser"), .chromium)
        XCTAssertEqual(WebRules.browserKind(for: "company.thebrowser.Browser"), .chromium)
        XCTAssertNil(WebRules.browserKind(for: "com.apple.dt.Xcode"))
    }

    func testGuardedPanesMatchInBothLanguagesAndWithoutAccents() {
        XCTAssertEqual(GuardedSettingsPane.match(selectedRow: "Privacidad y seguridad"), .privacy)
        XCTAssertEqual(GuardedSettingsPane.match(selectedRow: "privacidad y seguridad"), .privacy)
        XCTAssertEqual(GuardedSettingsPane.match(selectedRow: "Privacy & Security"), .privacy)
        XCTAssertEqual(GuardedSettingsPane.match(selectedRow: "Fecha y hora"), .dateTime)
        XCTAssertEqual(GuardedSettingsPane.match(selectedRow: "Date & Time"), .dateTime)
        XCTAssertEqual(GuardedSettingsPane.match(selectedRow: "Usuarios y grupos"), .users)
        XCTAssertNil(GuardedSettingsPane.match(selectedRow: "Wi-Fi"))
        XCTAssertNil(GuardedSettingsPane.match(selectedRow: "Sonido"))
        XCTAssertNil(GuardedSettingsPane.match(selectedRow: ""))
    }

    // MARK: - Saving and reading tasks back

    func testBlockingWebsitesNeedsAListOfWhatStaysOpen() {
        var task = protectedTask(domains: "", web: .redirect)
        XCTAssertFalse(task.valid, "blocking every site including the ones you need is never what was meant")
        task.domains = "github.com"
        XCTAssertTrue(task.valid)
        task.webBlockAction = .warn
        task.domains = ""
        XCTAssertTrue(task.valid)
    }

    func testOlderTasksWithoutTheNewFieldsStillRead() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Antigua","minutes":45,"strict":true,
         "apps":[{"id":"com.apple.dt.Xcode","name":"Xcode","path":"/Applications/Xcode.app"}]}
        """
        let task = try JSONDecoder().decode(FocusTask.self, from: Data(json.utf8))
        XCTAssertEqual(task.protection, .none)
        XCTAssertEqual(task.blockAction, .hide)
        XCTAssertEqual(task.webBlockAction, .warn)
        XCTAssertEqual(task.unlockChars, 24)
        XCTAssertTrue(task.guardSystemPanes)
        XCTAssertTrue(task.punisherEnabled)
        XCTAssertFalse(task.enforces == false && task.strict, "a strict task enforces something")
    }

    func testNewFieldsSurviveSavingAndLoading() throws {
        let task = protectedTask(protection: .delay, web: .closeTab)
        let decoded = try JSONDecoder().decode(FocusTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded.protection, .delay)
        XCTAssertEqual(decoded.webBlockAction, .closeTab)
        XCTAssertEqual(decoded.stopDelayMinutes, task.stopDelayMinutes)
    }

    func testProfilesCarryTheProtectionSettingsToTheTask() {
        let profile = FocusProfile(
            name: "Cerrado",
            strict: true,
            apps: [AllowedApp(id: "com.apple.dt.Xcode", name: "Xcode", path: "/Applications/Xcode.app")],
            domains: "github.com",
            protection: .forced,
            unlockChars: 40,
            stopDelayMinutes: 15,
            blockAction: .close,
            webBlockAction: .redirect,
            punisherEnabled: false
        )
        var task = FocusTask(title: "Sin nombre")
        task.apply(profile)
        XCTAssertEqual(task.protection, .forced)
        XCTAssertEqual(task.unlockChars, 40)
        XCTAssertEqual(task.stopDelayMinutes, 15)
        XCTAssertEqual(task.blockAction, .close)
        XCTAssertEqual(task.webBlockAction, .redirect)
        XCTAssertFalse(task.punisherEnabled)
    }

    func testASessionOnlyEnforcesWhileItIsRunningWithTimeLeft() {
        var session = WorkSession(task: protectedTask(minutes: 1), now: zero, uptime: 100)
        XCTAssertTrue(session.enforcing(at: zero, uptime: 100))
        session.pause(at: zero.addingTimeInterval(10), uptime: 110)
        XCTAssertFalse(session.enforcing(at: zero.addingTimeInterval(10), uptime: 110))
        session.resume(at: zero.addingTimeInterval(10), uptime: 110)
        XCTAssertFalse(session.enforcing(at: zero.addingTimeInterval(120), uptime: 220), "no time left, nothing to enforce")
    }

    func testAnUnprotectedTaskThatBlocksNothingEnforcesNothing() {
        let plain = FocusTask(title: "Leer", minutes: 30)
        XCTAssertFalse(plain.enforces)
        XCTAssertTrue(protectedTask().enforces)
        XCTAssertTrue(FocusTask(title: "Solo código", protection: .challenge).enforces)
    }
}
