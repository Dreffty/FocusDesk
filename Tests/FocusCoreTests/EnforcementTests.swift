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
        XCTAssertEqual(FocusRules.safeAction(.forceQuit, for: "com.articdia.focusdesk"), .hide)
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

    // MARK: - Blocklist modes, URL subpaths, title keywords, and GeneralBlockRule timers

    func testWebSubpathMatchingAndWebListModes() {
        let rawList = "youtube.com/shorts, instagram.com/reels, x.com"
        let list = FocusRules.parseDomains(rawList).valid
        XCTAssertEqual(list, ["youtube.com/shorts", "instagram.com/reels", "x.com"])

        // Blocklist mode: youtube.com/shorts is blocked, but youtube.com/watch is allowed
        XCTAssertFalse(FocusRules.webAllowed(host: "www.youtube.com", path: "/shorts/xyz123", list: rawList, mode: .blockListed))
        XCTAssertTrue(FocusRules.webAllowed(host: "www.youtube.com", path: "/watch", list: rawList, mode: .blockListed))
        XCTAssertFalse(FocusRules.webAllowed(host: "x.com", path: "/home", list: rawList, mode: .blockListed))
        XCTAssertTrue(FocusRules.webAllowed(host: "docs.swift.org", path: "/swift-book", list: rawList, mode: .blockListed))

        // Block all mode
        XCTAssertFalse(FocusRules.webAllowed(host: "docs.swift.org", path: "/", list: "", mode: .blockAll))

        // Allowlist mode
        let allowed = "docs.swift.org, github.com/apple"
        XCTAssertTrue(FocusRules.webAllowed(host: "docs.swift.org", path: "/guide", list: allowed, mode: .allowListed))
        XCTAssertTrue(FocusRules.webAllowed(host: "github.com", path: "/apple/swift", list: allowed, mode: .allowListed))
        XCTAssertFalse(FocusRules.webAllowed(host: "github.com", path: "/torvalds/linux", list: allowed, mode: .allowListed))
    }

    func testAppListModeAllowlistAndBlocklist() {
        let apps = [AllowedApp(id: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app")]
        XCTAssertFalse(FocusRules.appAllowed(bundleID: "com.tinyspeck.slackmacgap", apps: apps, mode: .blockListed))
        XCTAssertTrue(FocusRules.appAllowed(bundleID: "com.apple.dt.Xcode", apps: apps, mode: .blockListed))

        XCTAssertTrue(FocusRules.appAllowed(bundleID: "com.tinyspeck.slackmacgap", apps: apps, mode: .allowListed))
        XCTAssertFalse(FocusRules.appAllowed(bundleID: "com.apple.dt.Xcode", apps: apps, mode: .allowListed))
    }

    func testWindowTitleKeywordsMatching() {
        let keywords = "Shorts, Reels, Netflix"
        XCTAssertEqual(FocusRules.matchesTitleKeyword("YouTube - Shorts - Brave", keywords: keywords), "Shorts")
        XCTAssertEqual(FocusRules.matchesTitleKeyword("viendo reels en directo", keywords: keywords), "Reels")
        XCTAssertNil(FocusRules.matchesTitleKeyword("FocusDesk — Xcode", keywords: keywords))
    }

    func testDailyLimitRuleTracksQuotaAndEnforcesOnceExhausted() {
        let rule = GeneralBlockRule(
            name: "Límite diario de Shorts",
            enabled: true,
            kind: .dailyLimit,
            dailyLimitMinutes: 20,
            webListMode: .blockListed,
            domains: "youtube.com/shorts, x.com",
            blockedTitleKeywords: "Shorts"
        )

        // With 5 minutes (300s) used out of 20 minutes (1200s): tracking is active, enforcement is not yet active
        XCTAssertTrue(rule.isTrackingQuota(usedTodaySeconds: 300))
        XCTAssertFalse(rule.isEnforcing(at: zero, usedTodaySeconds: 300, continuous: 100))
        XCTAssertEqual(rule.remainingQuotaSeconds(usedTodaySeconds: 300), 900)

        // Once 20 minutes (1200s) are reached: quota is 0 and rule switches to enforcing for the rest of the day
        XCTAssertFalse(rule.isTrackingQuota(usedTodaySeconds: 1200))
        XCTAssertTrue(rule.isEnforcing(at: zero, usedTodaySeconds: 1200, continuous: 100))
        XCTAssertEqual(rule.remainingQuotaSeconds(usedTodaySeconds: 1200), 0)
    }

    func testCountdownRuleAndOvernightScheduleRule() {
        var countdown = GeneralBlockRule(
            name: "Bloqueo 30 min",
            enabled: true,
            kind: .countdown,
            countdownMinutes: 30,
            webListMode: .blockListed,
            domains: "x.com"
        )
        countdown.startCountdown(minutes: 30, wall: zero, continuous: 1000)
        XCTAssertTrue(countdown.isEnforcing(at: zero.addingTimeInterval(600), usedTodaySeconds: 0, continuous: 1600))
        let left = countdown.remainingLockSeconds(at: zero.addingTimeInterval(600), usedTodaySeconds: 0, continuous: 1600)
        XCTAssertEqual(left, 1200, accuracy: 1)
        XCTAssertFalse(countdown.isEnforcing(at: zero.addingTimeInterval(1801), usedTodaySeconds: 0, continuous: 2801))

        // Overnight schedule: 22:30 (1350) to 07:30 (450) every day
        let schedule = GeneralBlockRule(
            name: "Descanso nocturno",
            enabled: true,
            kind: .schedule,
            scheduleDays: Set(1...7),
            startMinutes: 22 * 60 + 30,
            endMinutes: 7 * 60 + 30,
            webListMode: .blockListed,
            domains: "x.com, youtube.com"
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let lateNight = cal.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 23, minute: 15))!
        let earlyMorning = cal.date(from: DateComponents(year: 2026, month: 4, day: 16, hour: 6, minute: 45))!
        let midday = cal.date(from: DateComponents(year: 2026, month: 4, day: 16, hour: 13, minute: 0))!

        XCTAssertTrue(schedule.isScheduleActive(at: lateNight, calendar: cal))
        XCTAssertTrue(schedule.isScheduleActive(at: earlyMorning, calendar: cal))
        XCTAssertFalse(schedule.isScheduleActive(at: midday, calendar: cal))
    }

    func testRatchetProtectsBlocklistedDomainsAppsAndKeywords() {
        let task = FocusTask(
            title: "Bloqueo por lista negra",
            minutes: 45,
            strict: true,
            apps: [
                AllowedApp(id: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app"),
                AllowedApp(id: "com.hnc.Discord", name: "Discord", path: "/Applications/Discord.app")
            ],
            domains: "x.com, youtube.com/shorts",
            protection: .challenge,
            webBlockAction: .closeTab,
            appListMode: .blockListed,
            webListMode: .blockListed,
            blockedTitleKeywords: "Shorts, Reels"
        )

        // Adding another blocked domain or keyword is hardening -> allowed
        var harder = task
        harder.domains = "x.com, youtube.com/shorts, tiktok.com"
        harder.blockedTitleKeywords = "Shorts, Reels, Twitch"
        XCTAssertNil(Ratchet.loosening(current: task, proposed: harder))

        // Removing a blocked domain is loosening -> caught by Ratchet
        var looserDomain = task
        looserDomain.domains = "x.com"
        XCTAssertEqual(Ratchet.loosening(current: task, proposed: looserDomain), .domainsUnblocked)

        // Removing a blocked app in blocklist mode is loosening -> caught by Ratchet
        var looserApp = task
        looserApp.apps = [AllowedApp(id: "com.tinyspeck.slackmacgap", name: "Slack", path: "/Applications/Slack.app")]
        XCTAssertEqual(Ratchet.loosening(current: task, proposed: looserApp), .appsUnblocked)

        // Removing a blocked title keyword is loosening -> caught by Ratchet
        var looserKeyword = task
        looserKeyword.blockedTitleKeywords = "Shorts"
        XCTAssertEqual(Ratchet.loosening(current: task, proposed: looserKeyword), .titleKeywordsRemoved)
    }

    func testWorkGoalRuleEnforcesUntilGoalMetAndTracksRewardBudget() {
        let unlimitedRewardRule = GeneralBlockRule(
            name: "Primero el trabajo (ilimitado tras meta)",
            enabled: true,
            kind: .workGoal,
            goalMinutesRequired: 60,
            goalRewardMinutes: 0,
            webListMode: .blockListed,
            domains: "youtube.com, reddit.com"
        )

        // Before 60 min (3600s) of focused work: blocks
        XCTAssertTrue(unlimitedRewardRule.isEnforcing(at: zero, usedTodaySeconds: 0, workedTodaySeconds: 1800, continuous: 100))
        XCTAssertFalse(unlimitedRewardRule.isTrackingQuota(at: zero, usedTodaySeconds: 0, workedTodaySeconds: 1800, continuous: 100))

        // After 60 min (3600s) of focused work: unlocked for the rest of the day
        XCTAssertFalse(unlimitedRewardRule.isEnforcing(at: zero, usedTodaySeconds: 5000, workedTodaySeconds: 3600, continuous: 100))

        // Proportional reward mode: 15 min reward per 60 min worked
        let proportionalRule = GeneralBlockRule(
            name: "15 min ocio por cada 60 min de foco",
            enabled: true,
            kind: .workGoal,
            goalMinutesRequired: 60,
            goalRewardMinutes: 15,
            webListMode: .blockListed,
            domains: "youtube.com"
        )

        // Worked 60 min -> earned 15 min (900s). Used 300s -> 600s left, tracking quota, not enforcing
        XCTAssertEqual(proportionalRule.remainingGoalRewardSeconds(workedTodaySeconds: 3600, usedTodaySeconds: 300), 600, accuracy: 0.5)
        XCTAssertTrue(proportionalRule.isTrackingQuota(at: zero, usedTodaySeconds: 300, workedTodaySeconds: 3600, continuous: 100))
        XCTAssertFalse(proportionalRule.isEnforcing(at: zero, usedTodaySeconds: 300, workedTodaySeconds: 3600, continuous: 100))

        // Used all 900s -> reward exhausted -> enforcing again
        XCTAssertEqual(proportionalRule.remainingGoalRewardSeconds(workedTodaySeconds: 3600, usedTodaySeconds: 900), 0, accuracy: 0.5)
        XCTAssertTrue(proportionalRule.isEnforcing(at: zero, usedTodaySeconds: 900, workedTodaySeconds: 3600, continuous: 100))
    }

    func testLaunchLimitRuleEnforcesVisitsCooldownsAndDailyMax() {
        var rule = GeneralBlockRule(
            name: "Correo 3 veces al día",
            enabled: true,
            kind: .launchLimit,
            maxDailyLaunches: 3,
            maxLaunchDurationMinutes: 5,
            launchCooldownMinutes: 30,
            webListMode: .blockListed,
            domains: "mail.google.com"
        )

        // Before any visit starts, with 0 launches used: allowed to open (not enforcing)
        XCTAssertFalse(rule.isEnforcing(at: zero, launchesToday: 0, continuous: 100))

        // Start visit 1 (5 min = 300s)
        rule.beginLaunchVisit(wall: zero, continuous: 100)
        XCTAssertTrue(rule.isLaunchVisitActive(at: zero.addingTimeInterval(120), continuous: 220))
        XCTAssertFalse(rule.isEnforcing(at: zero.addingTimeInterval(120), launchesToday: 1, continuous: 220))

        // Visit 1 ends at t=300s -> start 30 min (1800s) cooldown
        let visitEndWall = zero.addingTimeInterval(300)
        rule.endLaunchVisitAndStartCooldown(wall: visitEndWall, continuous: 400)
        XCTAssertTrue(rule.isInLaunchCooldown(at: visitEndWall.addingTimeInterval(600), continuous: 1000))
        XCTAssertTrue(rule.isEnforcing(at: visitEndWall.addingTimeInterval(600), launchesToday: 1, continuous: 1000))

        // Cooldown expires after 1800s -> allowed to open again while launchesToday (1) < maxDailyLaunches (3)
        let afterCooldownWall = visitEndWall.addingTimeInterval(1801)
        XCTAssertFalse(rule.isInLaunchCooldown(at: afterCooldownWall, continuous: 2201))
        XCTAssertFalse(rule.isEnforcing(at: afterCooldownWall, launchesToday: 1, continuous: 2201))

        // Once all 3 launches are exhausted and no visit is active -> enforces for the rest of the day
        XCTAssertTrue(rule.isEnforcing(at: afterCooldownWall, launchesToday: 3, continuous: 2201))
    }

    func testMicroPausesAndTemporaryAllowEntriesAutoExpire() {
        var rule = GeneralBlockRule(
            name: "Bloqueo permanente con micro-pausa",
            enabled: true,
            kind: .alwaysOn,
            webListMode: .blockListed,
            domains: "x.com",
            dailyMicroPausesAllowed: 2,
            microPauseMinutes: 2
        )

        XCTAssertTrue(rule.isEnforcing(at: zero, continuous: 100))
        rule.startMicroPause(wall: zero, continuous: 100)
        // During the 2-minute micro-pause, the rule pauses enforcement
        XCTAssertTrue(rule.isMicroPaused(at: zero.addingTimeInterval(60), continuous: 160))
        XCTAssertFalse(rule.isEnforcing(at: zero.addingTimeInterval(60), continuous: 160))
        // After 121 seconds, micro-pause expires and rule automatically enforces again
        XCTAssertFalse(rule.isMicroPaused(at: zero.addingTimeInterval(121), continuous: 221))
        XCTAssertTrue(rule.isEnforcing(at: zero.addingTimeInterval(121), continuous: 221))

        // TemporaryAllowEntry on Workspace
        var ws = Workspace()
        ws.temporaryAllows = [
            TemporaryAllowEntry(target: "stackoverflow.com", isAppBundleID: false, label: "Consulta puntual", minutes: 10, wall: zero, continuous: 100),
            TemporaryAllowEntry(target: "com.tinyspeck.slackmacgap", isAppBundleID: true, label: "Slack 5m", minutes: 5, wall: zero, continuous: 100)
        ]
        XCTAssertTrue(ws.isTemporarilyAllowed(host: "stackoverflow.com", path: "/questions/1", at: zero.addingTimeInterval(120), continuous: 220))
        XCTAssertTrue(ws.isTemporarilyAllowed(bundleID: "com.tinyspeck.slackmacgap", at: zero.addingTimeInterval(120), continuous: 220))
        // After 11 minutes (660s), both have expired
        XCTAssertFalse(ws.isTemporarilyAllowed(host: "stackoverflow.com", path: "/questions/1", at: zero.addingTimeInterval(660), continuous: 760))
        XCTAssertFalse(ws.isTemporarilyAllowed(bundleID: "com.tinyspeck.slackmacgap", at: zero.addingTimeInterval(660), continuous: 760))
    }

    func testStopRequestConfirmationWindowExpiryRestartsWait() {
        let req = StopRequest(reason: .cancel, minutes: 2, confirmWindowSeconds: 180, wall: zero, continuous: 100)
        // At t=60s: still waiting
        XCTAssertFalse(req.ready(wall: zero.addingTimeInterval(60), continuous: 160))
        XCTAssertFalse(req.expired(wall: zero.addingTimeInterval(60), continuous: 160))

        // At t=130s (10s after 2-min wait ended): ready and within 180s confirmation window
        let readyWall = zero.addingTimeInterval(130)
        XCTAssertTrue(req.ready(wall: readyWall, continuous: 230))
        XCTAssertFalse(req.expired(wall: readyWall, continuous: 230))
        XCTAssertEqual(
            StopGate.decide(protection: .delay, reason: .cancel, timeLeft: 900, unlockChars: 28, stopDelayMinutes: 2, pending: req, wall: readyWall, continuous: 230),
            .waitFinished
        )

        // At t=310s (190s after 2-min wait ended, exceeding 180s confirmation window): expired -> restarts wait
        let expiredWall = zero.addingTimeInterval(310)
        XCTAssertTrue(req.expired(wall: expiredWall, continuous: 410))
        XCTAssertEqual(
            StopGate.decide(protection: .delay, reason: .cancel, timeLeft: 900, unlockChars: 28, stopDelayMinutes: 2, pending: req, wall: expiredWall, continuous: 410),
            .waitStarted(120)
        )
    }

    func testCustomRedirectURLAndAccessibilityBrowserClassification() {
        XCTAssertNil(WebRules.normalizedRedirectURL("https:// Notion.so "))
        XCTAssertEqual(WebRules.normalizedRedirectURL("https://www.notion.so/mi-panel")?.absoluteString, "https://www.notion.so/mi-panel")
        XCTAssertEqual(WebRules.normalizedRedirectURL("notion.so")?.absoluteString, "https://notion.so")
        XCTAssertNil(WebRules.normalizedRedirectURL("javascript:alert(1)"))
        XCTAssertNil(WebRules.normalizedRedirectURL("   "))

        XCTAssertEqual(WebRules.browserKind(for: "org.mozilla.firefox"), .accessibility)
        XCTAssertEqual(WebRules.browserKind(for: "app.zen-browser.zen"), .accessibility)
        XCTAssertEqual(WebRules.browserKind(for: "com.duckduckgo.macos.browser"), .accessibility)
        XCTAssertTrue(WebRules.isBrowser("org.mozilla.firefox"))
    }

    func testProtectedRulesWitnessDetectsTampering() {
        let protectedRule = GeneralBlockRule(
            name: "Regla Blindada",
            enabled: true,
            kind: .alwaysOn,
            webListMode: .blockListed,
            domains: "x.com, tiktok.com",
            protection: .challenge
        )
        let witness = ProtectedRulesWitness(rules: [protectedRule], savedAt: zero)
        XCTAssertFalse(witness.isEmpty)

        // If workspace.json is wiped externally while closed, witness detects missing protected rule
        let tamperedEmpty: [GeneralBlockRule] = []
        XCTAssertFalse(tamperedEmpty.contains(where: { $0.id == protectedRule.id }))
        XCTAssertEqual(witness.rules.first?.id, protectedRule.id)
    }

    func testPomodoroCyclesPenaltyBreakProtectionAndWaitForUser() {
        var rule = GeneralBlockRule(
            name: "Pomodoro 25/5",
            enabled: false,
            kind: .pomodoro,
            pomodoroWorkMinutes: 25,
            pomodoroShortBreakMinutes: 5,
            pomodoroLongBreakMinutes: 15,
            pomodoroLongBreakEvery: 2,
            pomodoroTotalCycles: 2,
            pomodoroPenaltyReset: true,
            protectPomodoroBreaks: true,
            pomodoroWaitForUser: true,
            webListMode: .blockListed,
            domains: "youtube.com, x.com",
            protection: .challenge
        )

        // Start Pomodoro -> enters work cycle 1 (25 min = 1500s)
        rule.startPomodoro(wall: zero, continuous: 100)
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.pomodoroPhase, .work)
        XCTAssertEqual(rule.pomodoroCurrentCycle, 1)
        XCTAssertTrue(rule.isEnforcing(at: zero.addingTimeInterval(600), continuous: 700))

        // At t=600s (10 min in), user attempts a distraction -> pomodoroPenaltyReset resets work timer back to full 25m (1500s)
        XCTAssertTrue(rule.applyPomodoroPenaltyIfNeeded(wall: zero.addingTimeInterval(600), continuous: 700))
        XCTAssertEqual(rule.pomodoroPhaseRemainingSeconds(at: zero.addingTimeInterval(600), continuous: 700), 1500, accuracy: 1)

        // Work cycle 1 finishes -> transitions to shortBreak (5 min = 300s)
        let afterWork1 = zero.addingTimeInterval(2101)
        rule.advancePomodoroPhase(userIsIdle: false, wall: afterWork1, continuous: 2201)
        XCTAssertEqual(rule.pomodoroPhase, .shortBreak)
        // During shortBreak, rule does not block websites, BUT because protectPomodoroBreaks == true, it is still protected!
        XCTAssertFalse(rule.isEnforcing(at: afterWork1.addingTimeInterval(60), continuous: 2261))
        XCTAssertTrue(rule.isProtectedNow(at: afterWork1.addingTimeInterval(60), continuous: 2261))

        // Short break finishes while user is away (userIsIdle: true) and pomodoroWaitForUser == true -> enters .waitingForUser
        let afterShortBreak = afterWork1.addingTimeInterval(301)
        rule.advancePomodoroPhase(userIsIdle: true, wall: afterShortBreak, continuous: 2502)
        XCTAssertEqual(rule.pomodoroPhase, .waitingForUser)
        XCTAssertFalse(rule.isEnforcing(at: afterShortBreak, continuous: 2502))
        XCTAssertTrue(rule.isProtectedNow(at: afterShortBreak, continuous: 2502))

        // User returns (userIsIdle: false) -> starts work cycle 2
        let userBack = afterShortBreak.addingTimeInterval(120)
        rule.advancePomodoroPhase(userIsIdle: false, wall: userBack, continuous: 2622)
        XCTAssertEqual(rule.pomodoroPhase, .work)
        XCTAssertEqual(rule.pomodoroCurrentCycle, 2)
        XCTAssertTrue(rule.isEnforcing(at: userBack.addingTimeInterval(60), continuous: 2682))

        // Work cycle 2 finishes -> since pomodoroTotalCycles == 2 and cycle 2 is done, transitions to .idle and disables rule
        let afterWork2 = userBack.addingTimeInterval(1501)
        rule.advancePomodoroPhase(userIsIdle: false, wall: afterWork2, continuous: 4123)
        XCTAssertEqual(rule.pomodoroPhase, .idle)
        XCTAssertFalse(rule.enabled)
    }

    func testWholeWordWildcardAndRegexMatching() {
        // 1. WholeWord keyword matching: "X" matches "Post on X" and "X / Home", but NOT "Xcode" or "Texto"
        XCTAssertNotNil(FocusRules.matchesTitleKeyword("Xcode — Enforcement.swift", keywords: "X", wholeWord: false))
        XCTAssertNil(FocusRules.matchesTitleKeyword("Xcode — Enforcement.swift", keywords: "X", wholeWord: true))
        XCTAssertEqual(FocusRules.matchesTitleKeyword("Home / X — Mozilla Firefox", keywords: "X, Reddit", wholeWord: true), "X")

        // 2. Wildcard title matching (`*`, `?`)
        XCTAssertEqual(FocusRules.matchesTitleKeyword("Watch Free Slots & Poker Online", keywords: "*poker*"), "*poker*")
        XCTAssertNil(FocusRules.matchesTitleKeyword("Xcode Project", keywords: "*poker*"))

        // 3. Regex title matching (`/pattern/`)
        XCTAssertEqual(FocusRules.matchesTitleKeyword("Episodio 12 - Temporada 3", keywords: "/episodio\\s+\\d+/"), "/episodio\\s+\\d+/")
        XCTAssertNil(FocusRules.matchesTitleKeyword("Documentación técnica", keywords: "/episodio\\s+\\d+/"))

        // 4. Wildcard domain and subpath matching
        XCTAssertEqual(FocusRules.normalizeDomainEntry("*poker*.com"), "*poker*.com")
        XCTAssertEqual(FocusRules.normalizeDomainEntry("reddit.com/r/*"), "reddit.com/r/*")
        XCTAssertTrue(FocusRules.entryMatches(host: "play-poker-now.com", path: "/", entry: "*poker*.com"))
        XCTAssertTrue(FocusRules.entryMatches(host: "www.reddit.com", path: "/r/gaming/comments/1", entry: "reddit.com/r/*"))
        XCTAssertFalse(FocusRules.entryMatches(host: "www.reddit.com", path: "/settings", entry: "reddit.com/r/*"))
    }

    func testSimilarityProtectionBroadTargetsAndRedirectLoopCheck() {
        // 1. Overly broad allowlist targets rejected
        XCTAssertNotNil(FocusRules.isAllowEntryTooBroad("*"))
        XCTAssertNotNil(FocusRules.isAllowEntryTooBroad("*.com"))
        XCTAssertNotNil(FocusRules.isAllowEntryTooBroad("com"))
        XCTAssertNil(FocusRules.isAllowEntryTooBroad("developer.apple.com"))

        // 2. SimilarityProtectionLevel
        let blocked = "youtube.com, reddit.com"
        // Near-duplicate / typo-squat ("youtubee.com" has edit distance 1 from "youtube")
        XCTAssertNotNil(FocusRules.checkSimilarityRestriction(allowCandidate: "youtubee.com", blockedDomains: blocked, level: .nearDuplicates))
        // SpecificPagesOnly rejects whole blocked domain "youtube.com" but allows specific path "youtube.com/watch"
        XCTAssertNotNil(FocusRules.checkSimilarityRestriction(allowCandidate: "youtube.com", blockedDomains: blocked, level: .specificPagesOnly))
        XCTAssertNil(FocusRules.checkSimilarityRestriction(allowCandidate: "youtube.com/watch", blockedDomains: blocked, level: .specificPagesOnly))

        // 3. Redirect destination loop check (`ControllerPlanWizard::redirectDestinationBlocked`)
        XCTAssertNotNil(FocusRules.isRedirectDestinationBlocked(redirectURL: "https://youtube.com", list: "youtube.com, x.com", mode: .blockListed))
        XCTAssertNil(FocusRules.isRedirectDestinationBlocked(redirectURL: "https://notion.so", list: "youtube.com, x.com", mode: .blockListed))
        XCTAssertNotNil(FocusRules.isRedirectDestinationBlocked(redirectURL: "https://www.google.com/search?q=cats&tbm=isch", list: "", mode: .blockListed, blockSearchMedia: true))
    }

    func testSearchMediaRulesAndGameLibraryRulesAndClipboardGuard() {
        // 1. SearchMediaRules blocks image/video tabs on search engines while allowing text search
        XCTAssertNotNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=swift&tbm=isch"))
        XCTAssertNotNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=swift&udm=2"))
        XCTAssertNotNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=swift&udm=7"))
        XCTAssertNil(SearchMediaRules.matches(host: "www.google.com", pathAndQuery: "/search?q=swift+concurrency"))
        XCTAssertNotNil(SearchMediaRules.matches(host: "www.bing.com", pathAndQuery: "/images/search?q=mac"))
        XCTAssertNotNil(SearchMediaRules.matches(host: "duckduckgo.com", pathAndQuery: "/?q=test&iax=videos&ia=videos"))
        XCTAssertNil(SearchMediaRules.matches(host: "duckduckgo.com", pathAndQuery: "/?q=test&ia=web"))

        // 2. GameLibraryRules detects known launchers AND executables inside game library paths
        XCTAssertNotNil(GameLibraryRules.matchesGameApp(bundleID: "com.valvesoftware.steam", appPath: "/Applications/Steam.app"))
        XCTAssertNotNil(GameLibraryRules.matchesGameApp(bundleID: "com.unknown.indiegame", appPath: "/Users/luis/Library/Application Support/Steam/steamapps/common/Hades/Hades.app"))
        XCTAssertNotNil(GameLibraryRules.matchesGameApp(bundleID: "com.unknown.epicgame", appPath: "/Users/Shared/Epic Games/Fortnite/Fortnite.app"))
        XCTAssertNil(GameLibraryRules.matchesGameApp(bundleID: "com.apple.dt.Xcode", appPath: "/Applications/Xcode.app"))

        // 3. ClipboardGuardRules detects tamper commands and blocked URLs in clipboard
        XCTAssertNotNil(ClipboardGuardRules.violation(in: "sudo killall focusdesk", domains: "", webListMode: .blockListed, webBlockAction: .warn))
        XCTAssertNotNil(ClipboardGuardRules.violation(in: "launchctl unload ~/Library/LaunchAgents/com.articdia.focusdesk.guard.plist", domains: "", webListMode: .blockListed, webBlockAction: .warn))
        XCTAssertNotNil(ClipboardGuardRules.violation(in: "https://www.youtube.com/shorts/abc123", domains: "youtube.com/shorts", webListMode: .blockListed, webBlockAction: .redirect))
        XCTAssertNil(ClipboardGuardRules.violation(in: "struct ContentView: View {}", domains: "youtube.com", webListMode: .blockListed, webBlockAction: .redirect))
    }

    func testMultipleScheduleIntervalsDayRolloverAndLimitPeriodUnits() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!

        // 1. ScheduleInterval merge and multi-window schedule rule
        let merged = ScheduleInterval.merge([
            ScheduleInterval(startMinutes: 9 * 60, endMinutes: 12 * 60),
            ScheduleInterval(startMinutes: 11 * 60 + 30, endMinutes: 14 * 60),
            ScheduleInterval(startMinutes: 16 * 60, endMinutes: 19 * 60)
        ])
        XCTAssertEqual(merged, [
            ScheduleInterval(startMinutes: 9 * 60, endMinutes: 14 * 60),
            ScheduleInterval(startMinutes: 16 * 60, endMinutes: 19 * 60)
        ])

        let rule = GeneralBlockRule(
            name: "Horario partido",
            enabled: true,
            kind: .schedule,
            scheduleDays: [1, 2, 3, 4, 5, 6, 7],
            startMinutes: 9 * 60,
            endMinutes: 14 * 60,
            extraScheduleIntervals: [ScheduleInterval(startMinutes: 16 * 60, endMinutes: 19 * 60)],
            webListMode: .blockListed,
            domains: "x.com"
        )
        let morning = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 10, minute: 30))!
        let lunch = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 15, minute: 0))!
        let afternoon = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 17, minute: 15))!
        XCTAssertTrue(rule.isEnforcing(at: morning, calendar: cal))
        XCTAssertFalse(rule.isEnforcing(at: lunch, calendar: cal))
        XCTAssertTrue(rule.isEnforcing(at: afternoon, calendar: cal))

        // 2. Day rollover hour (4 AM): 02:30 AM on 2026-04-18 still belongs to 2026-04-17
        let twoThirtyAM = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 2, minute: 30))!
        let fiveAM = cal.date(from: DateComponents(year: 2026, month: 4, day: 18, hour: 5, minute: 0))!
        XCTAssertEqual(FocusRules.dayKey(for: twoThirtyAM, rolloverHour: 4, calendar: cal), "2026-04-17")
        XCTAssertEqual(FocusRules.dayKey(for: fiveAM, rolloverHour: 4, calendar: cal), "2026-04-18")

        // 3. Hourly and weekly quota buckets on Workspace
        var ws = Workspace()
        ws.settings.dayRolloverHour = 4
        let hourlyRule = GeneralBlockRule(name: "10m por hora", enabled: true, kind: .dailyLimit, dailyLimitMinutes: 10, limitPeriodUnit: .hour, domains: "x.com")
        ws.generalRules = [hourlyRule]
        ws.addUsedSeconds(600, for: hourlyRule.id, at: morning, calendar: cal)
        XCTAssertEqual(ws.usedSecondsToday(for: hourlyRule.id, at: morning, calendar: cal), 600)
        // Next hour starts with a fresh 0s bucket
        let nextHour = morning.addingTimeInterval(3600)
        XCTAssertEqual(ws.usedSecondsToday(for: hourlyRule.id, at: nextHour, calendar: cal), 0)
    }

    func testStudyActivityVerifierAndLeagueMatchProcessDetection() {
        // 1. Productive web tabs (Claude, docs, university PDFs) and apps count as verified study when active
        XCTAssertTrue(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 12,
            frontBundleID: "com.brave.Browser",
            frontAppPath: "/Applications/Brave Browser.app",
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: "Claude — Apuntes de Cálculo",
            browserHost: "claude.ai",
            browserPath: "/chat/123"
        ))
        XCTAssertTrue(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 25,
            frontBundleID: "com.apple.Preview",
            frontAppPath: "/System/Applications/Preview.app",
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: "Tema_4_Estadistica.pdf",
            browserHost: nil,
            browserPath: nil
        ))

        // 2. AFK (idle >= 300s), no visible window, or browser on a blank new tab do NOT count as study
        XCTAssertFalse(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 305,
            frontBundleID: "com.brave.Browser",
            frontAppPath: "/Applications/Brave Browser.app",
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: "Claude",
            browserHost: "claude.ai",
            browserPath: "/chat/123"
        ))
        XCTAssertFalse(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 5,
            frontBundleID: "com.apple.finder",
            frontAppPath: "/System/Library/CoreServices/Finder.app",
            hasVisibleWindowOnScreen: false,
            frontWindowTitle: nil,
            browserHost: nil,
            browserPath: nil
        ))
        XCTAssertFalse(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 5,
            frontBundleID: "com.google.Chrome",
            frontAppPath: "/Applications/Google Chrome.app",
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: "Nueva pestaña",
            browserHost: nil,
            browserPath: nil
        ))

        // 3. League of Legends, games, and entertainment sites do NOT count as study
        XCTAssertFalse(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 3,
            frontBundleID: "com.riotgames.LeagueofLegends.LeagueClientUx",
            frontAppPath: "/Applications/League of Legends.app",
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: "League of Legends",
            browserHost: nil,
            browserPath: nil
        ))
        XCTAssertFalse(StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 10,
            frontBundleID: "com.brave.Browser",
            frontAppPath: "/Applications/Brave Browser.app",
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: "Netflix",
            browserHost: "www.netflix.com",
            browserPath: "/watch/123"
        ))

        // 4. LeagueMatchRules distinguishes the in-game match binary (GameClient) from the lobby client (LeagueClientUx)
        XCTAssertTrue(LeagueMatchRules.isMatchGameProcess(
            bundleID: "com.riotgames.LeagueofLegends.GameClient",
            appPath: "/Applications/League of Legends.app/Contents/LoL/Game/LeagueofLegends.app"
        ))
        XCTAssertFalse(LeagueMatchRules.isMatchGameProcess(
            bundleID: "com.riotgames.LeagueofLegends.LeagueClientUx",
            appPath: "/Applications/League of Legends.app/Contents/LoL/League of Legends.app"
        ))
        XCTAssertTrue(LeagueMatchRules.isLeagueOrRiotProcess(
            bundleID: "com.riotgames.LeagueofLegends.LeagueClientUx",
            appPath: "/Applications/League of Legends.app"
        ))
        XCTAssertTrue(LeagueMatchRules.isLeagueOrRiotProcess(
            bundleID: "com.riotgames.RiotGames.RiotClient",
            appPath: "/Users/Shared/Riot Games/Riot Client.app"
        ))
    }

    func testMandatoryStudyThenLoLRuleTwoMatchesMidMatchDeferralPostMatchGraceAnd64CharProtection() {
        var rule = GeneralBlockRule.mandatoryStudyThenLoLRule
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.kind, .workGoal)
        XCTAssertEqual(rule.goalMinutesRequired, 60)
        XCTAssertEqual(rule.goalRewardMinutes, 120)
        XCTAssertEqual(rule.maxDailyMatches, 2)
        XCTAssertTrue(rule.deferBlockUntilMatchEnds)
        XCTAssertEqual(rule.postMatchGraceSeconds, 60)
        XCTAssertTrue(rule.verifyActiveStudy)
        XCTAssertTrue(rule.alwaysProtected)
        XCTAssertEqual(rule.protection, .challenge)
        XCTAssertEqual(rule.unlockChars, 64)
        // Study mode only blocks LoL/Riot apps, never Claude or web browsers
        XCTAssertEqual(rule.domains, "")
        XCTAssertTrue(FocusRules.webAllowed(host: "claude.ai", path: "/new", list: rule.domains, mode: rule.webListMode))

        // 64-character challenge code generation
        let code64 = UnlockChallenge.make(length: rule.unlockChars)
        XCTAssertEqual(code64.count, 64)

        // 1. Before 60 minutes (3600s) of verified study: enforces LoL block and is protected 24/7
        XCTAssertTrue(rule.isEnforcing(at: zero, usedTodaySeconds: 0, workedTodaySeconds: 1800, matchesToday: 0, isMatchInProgress: false, continuous: 100))
        XCTAssertTrue(rule.isProtectedNow(at: zero, usedTodaySeconds: 0, workedTodaySeconds: 1800, matchesToday: 0, isMatchInProgress: false, continuous: 100))

        // 2. After 60 minutes (3600s) of verified study and 0/2 matches: LoL is unlocked, but rule remains protected 24/7
        XCTAssertFalse(rule.isEnforcing(at: zero, usedTodaySeconds: 600, workedTodaySeconds: 3600, matchesToday: 0, isMatchInProgress: false, continuous: 100))
        XCTAssertTrue(rule.isTrackingQuota(at: zero, usedTodaySeconds: 600, workedTodaySeconds: 7200, matchesToday: 1, continuous: 100))
        XCTAssertTrue(rule.isProtectedNow(at: zero, usedTodaySeconds: 600, workedTodaySeconds: 3600, matchesToday: 1, isMatchInProgress: false, continuous: 100))

        // 3. Never kick mid-match: even if 120 min (7200s) budget expires during Match #2, isMatchInProgress keeps isEnforcing == false
        XCTAssertFalse(rule.isEnforcing(at: zero, usedTodaySeconds: 7500, workedTodaySeconds: 3600, matchesToday: 1, isMatchInProgress: true, continuous: 100))

        // 4. Match #2 finishes -> 1-minute (60s) post-match grace period starts
        let matchEndWall = zero.addingTimeInterval(5400)
        rule.startPostMatchGrace(wall: matchEndWall, continuous: 5500)
        // At 30s after match ends: still in 1-minute grace period, not enforcing yet
        XCTAssertTrue(rule.isInPostMatchGrace(at: matchEndWall.addingTimeInterval(30), continuous: 5530))
        XCTAssertEqual(rule.postMatchGraceRemainingSeconds(at: matchEndWall.addingTimeInterval(30), continuous: 5530), 30, accuracy: 1)
        XCTAssertFalse(rule.isEnforcing(at: matchEndWall.addingTimeInterval(30), usedTodaySeconds: 5400, workedTodaySeconds: 3600, matchesToday: 2, isMatchInProgress: false, continuous: 5530))

        // 5. At 61s after match ends: grace period expired and matchesToday == 2 -> locks LoL for the rest of the day
        let afterGraceWall = matchEndWall.addingTimeInterval(61)
        XCTAssertFalse(rule.isInPostMatchGrace(at: afterGraceWall, continuous: 5561))
        XCTAssertTrue(rule.isEnforcing(at: afterGraceWall, usedTodaySeconds: 5400, workedTodaySeconds: 3600, matchesToday: 2, isMatchInProgress: false, continuous: 5561))
    }

    func testMandatoryLoLRuleEarnsOneMatchPerHourOfStudy() {
        let rule = GeneralBlockRule.mandatoryStudyThenLoLRule
        XCTAssertTrue(rule.oneMatchPerGoalBlock)
        XCTAssertTrue(rule.earnsMatchesPerGoalBlock)

        // 0 h → blocked; 1 h → match 1 open
        XCTAssertTrue(rule.isEnforcing(at: zero, workedTodaySeconds: 3599, matchesToday: 0, continuous: 100))
        XCTAssertFalse(rule.isEnforcing(at: zero, workedTodaySeconds: 3600, matchesToday: 0, continuous: 100))
        XCTAssertEqual(rule.earnedMatches(workedTodaySeconds: 3600), 1)

        // After match 1 with only 1 h studied → locked again until 2 h
        XCTAssertTrue(rule.isWaitingForMoreWork(workedTodaySeconds: 5000, matchesToday: 1))
        XCTAssertTrue(rule.isEnforcing(at: zero, usedTodaySeconds: 1800, workedTodaySeconds: 5000, matchesToday: 1, continuous: 100))
        XCTAssertFalse(rule.isTrackingQuota(at: zero, usedTodaySeconds: 1800, workedTodaySeconds: 5000, matchesToday: 1, continuous: 100))
        XCTAssertEqual(rule.requiredWorkSecondsForNextMatch(matchesToday: 1), 7200)

        // 2 h → match 2 open
        XCTAssertFalse(rule.isEnforcing(at: zero, usedTodaySeconds: 1800, workedTodaySeconds: 7200, matchesToday: 1, continuous: 100))
        // Studying 2 h before playing never gives more than one match at a time... but both are earned
        XCTAssertEqual(rule.earnedMatches(workedTodaySeconds: 7200), 2)
        // Max 2 a day even with 5 h studied
        XCTAssertEqual(rule.earnedMatches(workedTodaySeconds: 18000), 2)
        XCTAssertTrue(rule.isEnforcing(at: zero, usedTodaySeconds: 3600, workedTodaySeconds: 18000, matchesToday: 2, continuous: 100))
        XCTAssertFalse(rule.isWaitingForMoreWork(workedTodaySeconds: 18000, matchesToday: 2))

        // Never kicked mid-match even while waiting for more work
        XCTAssertFalse(rule.isEnforcing(at: zero, usedTodaySeconds: 1800, workedTodaySeconds: 5000, matchesToday: 1, isMatchInProgress: true, continuous: 100))

        // Turning it off is a loosening the ratchet refuses
        var looser = rule
        looser.oneMatchPerGoalBlock = false
        XCTAssertNotNil(GeneralBlockRule.loosening(current: rule, proposed: looser, now: zero, continuous: 100))
    }

    func testSavedOldLoLRuleIsMigratedToOneMatchPerHour() throws {
        var old = GeneralBlockRule.mandatoryStudyThenLoLRule
        old.oneMatchPerGoalBlock = false
        old.name = "Primero 60 min de estudio · luego máx. 2 partidas de LoL"
        var ws = Workspace()
        ws.generalRules = [old]
        let data = try JSONEncoder().encode(ws)
        let loaded = try JSONDecoder().decode(Workspace.self, from: data)
        let rule = try XCTUnwrap(loaded.generalRules.first { $0.id == LeagueMatchRules.mandatoryStudyThenLoLRuleID })
        XCTAssertTrue(rule.oneMatchPerGoalBlock)
        XCTAssertEqual(rule.name, LeagueMatchRules.mandatoryRuleName)
    }
}
