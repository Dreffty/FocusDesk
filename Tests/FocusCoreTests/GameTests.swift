import XCTest
@testable import FocusCore

final class GameTests: XCTestCase {
    let zero = Date(timeIntervalSince1970: 1_000_000)

    private func game(_ id: String) -> GameDefinition { GameCatalog.game(id: id)! }

    func testCatalogRecognisesEachGame() {
        XCTAssertTrue(game("minecraft").matches(bundleID: "com.mojang.minecraftlauncher"))
        XCTAssertTrue(game("minecraft").matches(bundleID: nil, executablePath: "/Users/x/Library/Application Support/minecraft/runtime/java/bin/java", localizedName: "java"))
        XCTAssertTrue(game("minecraft").matches(bundleID: "net.java.openjdk.java", localizedName: "Minecraft 1.20.1"))
        XCTAssertTrue(game("roblox").matches(bundleID: "com.roblox.RobloxPlayer"))
        XCTAssertTrue(game("lol").matches(bundleID: "com.riotgames.LeagueofLegends.GameClient"))
        XCTAssertTrue(game("fortnite").matchesWeb(host: "play.geforcenow.com", path: "/mall"))
        XCTAssertTrue(game("fortnite").matchesWeb(host: "www.xbox.com", path: "/es-ES/play/games/fortnite"))
        XCTAssertFalse(game("fortnite").matchesWeb(host: "www.xbox.com", path: "/es-ES/games"))
        // «Cualquier juego» takes launchers and anything marked as a game, nothing else.
        XCTAssertTrue(game("cualquiera").matches(bundleID: "com.valvesoftware.steam"))
        XCTAssertTrue(game("cualquiera").matches(bundleID: "com.someone.indie", isGameCategory: true))
        XCTAssertFalse(game("cualquiera").matches(bundleID: "com.apple.Safari"))
        // A game never matches the apps of another one.
        XCTAssertFalse(game("roblox").matches(bundleID: "com.mojang.minecraftlauncher"))
        XCTAssertFalse(game("minecraft").matches(bundleID: "com.apple.dt.Xcode", localizedName: "Xcode"))
        // «Otro juego» matches nothing by itself: its apps are the ones picked in the editor.
        XCTAssertFalse(game(GameCatalog.customID).matches(bundleID: "com.roblox.RobloxPlayer"))
    }

    func testTemplateIsOneHourPerMatchTwoADayAndTimedOutsideLoL() {
        let mc = GeneralBlockRule.gameTemplate(game("minecraft"))
        XCTAssertEqual(mc.kind, .workGoal)
        XCTAssertEqual(mc.gameID, "minecraft")
        XCTAssertEqual(mc.goalMinutesRequired, 60)
        XCTAssertEqual(mc.maxDailyMatches, 2)
        XCTAssertTrue(mc.oneMatchPerGoalBlock)
        XCTAssertTrue(mc.usesTimedMatches)
        XCTAssertEqual(mc.matchMinutes, 45)
        XCTAssertEqual(mc.matchOvertimeMinutes, 10)
        XCTAssertTrue(mc.hasTargets, "a game rule blocks its game even without apps listed")
        XCTAssertEqual(mc.matchUnitSingular, "sesión")

        let lol = GeneralBlockRule.gameTemplate(game("lol"))
        XCTAssertFalse(lol.usesTimedMatches)
        XCTAssertTrue(LeagueMatchRules.ruleTargetsLeague(lol))
        XCTAssertFalse(lol.apps.isEmpty)

        XCTAssertTrue(GeneralBlockRule.mandatoryStudyThenLoLRule.gameID == GameCatalog.leagueID)
    }

    func testTimedMatchStartsOnlyWhenEarnedAndEndsAfterOvertime() {
        var rule = GeneralBlockRule.gameTemplate(game("roblox"))   // 30 min + 10 of overtime
        let c0: Double = 1000

        // Not studied yet: opening the game does not start a match (the normal blocking closes it).
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 1200, matchesToday: 0, now: zero, continuous: c0), .idle)
        XCTAssertTrue(rule.isEnforcing(at: zero, workedTodaySeconds: 1200, matchesToday: 0, continuous: c0))

        // 1 h studied: opening it starts match 1.
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 3600, matchesToday: 0, now: zero, continuous: c0), .start)
        // Not open: nothing happens.
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: false, secondsSinceGameSeen: 999, workedTodaySeconds: 3600, matchesToday: 0, now: zero, continuous: c0), .idle)

        rule.startTimedMatch(wall: zero, continuous: c0)
        // 20 min in: playing, and never blocked even though more study would be needed for the next one.
        let t20 = zero.addingTimeInterval(1200)
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 3600, matchesToday: 0, now: t20, continuous: c0 + 1200), .playing)
        XCTAssertFalse(rule.isEnforcing(at: t20, workedTodaySeconds: 3600, matchesToday: 0, continuous: c0 + 1200))

        // 32 min in: typical length over → overtime, still not blocked.
        let t32 = zero.addingTimeInterval(1920)
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 3600, matchesToday: 0, now: t32, continuous: c0 + 1920), .overtime)
        XCTAssertFalse(rule.isEnforcing(at: t32, workedTodaySeconds: 3600, matchesToday: 0, continuous: c0 + 1920))

        // 40 min in: overtime over → finish.
        let t40 = zero.addingTimeInterval(2400)
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 3600, matchesToday: 0, now: t40, continuous: c0 + 2400), .finish(.timeUp))

        // After counting it with only 1 h studied, the game is locked until the 2nd hour.
        rule.endTimedMatch()
        XCTAssertTrue(rule.isEnforcing(at: t40, workedTodaySeconds: 3600, matchesToday: 1, continuous: c0 + 2400))
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 3600, matchesToday: 1, now: t40, continuous: c0 + 2400), .idle)
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: true, secondsSinceGameSeen: 0, workedTodaySeconds: 7200, matchesToday: 1, now: t40, continuous: c0 + 2400), .start)
        // Never a 3rd one.
        XCTAssertTrue(rule.isEnforcing(at: t40, workedTodaySeconds: 20000, matchesToday: 2, continuous: c0 + 2400))
    }

    func testClosingTheGameEndsTheMatchOnlyAfterPlayingAndATolerance() {
        var rule = GeneralBlockRule.gameTemplate(game("dota2"))
        let c0: Double = 5000
        rule.startTimedMatch(wall: zero, continuous: c0)

        // Closed 3 min in (peek, or a crash): the match stays open, it can be reopened.
        let t3 = zero.addingTimeInterval(180)
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: false, secondsSinceGameSeen: 150, workedTodaySeconds: 3600, matchesToday: 0, now: t3, continuous: c0 + 180), .playing)

        // Closed 30 s ago after 20 min: could be a restart, still playing.
        let t20 = zero.addingTimeInterval(1200)
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: false, secondsSinceGameSeen: 30, workedTodaySeconds: 3600, matchesToday: 0, now: t20, continuous: c0 + 1200), .playing)
        // Closed for 2 min after 20 min: the match is over.
        XCTAssertEqual(TimedMatchPlanner.step(rule: rule, gameRunning: false, secondsSinceGameSeen: 120, workedTodaySeconds: 3600, matchesToday: 0, now: t20, continuous: c0 + 1200), .finish(.gameClosed))
    }

    func testTimedMatchSurvivesRestartAndCannotBeStretched() throws {
        var rule = GeneralBlockRule.gameTemplate(game("minecraft"))
        rule.startTimedMatch(wall: zero, continuous: 100)
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(GeneralBlockRule.self, from: data)
        XCTAssertEqual(decoded.gameID, "minecraft")
        XCTAssertTrue(decoded.isInTimedMatch(at: zero.addingTimeInterval(600), continuous: 700))

        var protected = GeneralBlockRule.gameTemplate(game("minecraft"))
        protected.alwaysProtected = true
        var longer = protected
        longer.matchMinutes += 30
        XCTAssertNotNil(GeneralBlockRule.loosening(current: protected, proposed: longer, now: zero, continuous: 100))
        var otherGame = protected
        otherGame.applyGame(game("roblox"))
        XCTAssertNotNil(GeneralBlockRule.loosening(current: protected, proposed: otherGame, now: zero, continuous: 100))
        var shorter = protected
        shorter.matchMinutes -= 10
        XCTAssertNil(GeneralBlockRule.loosening(current: protected, proposed: shorter, now: zero, continuous: 100))
    }

    func testSavedLoLRuleGetsItsGameOnLoad() throws {
        var old = GeneralBlockRule.mandatoryStudyThenLoLRule
        old.gameID = nil
        var ws = Workspace()
        ws.generalRules = [old]
        let loaded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(loaded.generalRules.first?.gameID, GameCatalog.leagueID)
    }
}
