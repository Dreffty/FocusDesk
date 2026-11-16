import XCTest
@testable import FocusCore

/// FD-10: a rule protects itself a few minutes before it starts to block, like a task does.
final class RuleRunUpTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    private func at(_ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: hour, minute: minute))!
    }

    private var budget: GeneralBlockRule {
        GeneralBlockRule(name: "Redes 20 min", enabled: true, kind: .dailyLimit, dailyLimitMinutes: 20, domains: "x.com", protection: .challenge)
    }

    private var schedule: GeneralBlockRule {
        GeneralBlockRule(
            name: "Mañanas",
            enabled: true,
            kind: .schedule,
            scheduleDays: Set(1...7),
            startMinutes: 9 * 60,
            endMinutes: 13 * 60,
            webListMode: .blockListed,
            domains: "x.com",
            protection: .challenge
        )
    }

    func testBudgetIsProtectedInItsLastMinutes() {
        let rule = budget
        // 19 of 20 minutes used: one minute before it blocks.
        XCTAssertFalse(rule.isProtectedNow(at: at(12, 0), usedTodaySeconds: 19 * 60, calendar: cal))
        XCTAssertTrue(rule.isProtectedNow(at: at(12, 0), usedTodaySeconds: 19 * 60, runUpMinutes: 10, calendar: cal))
        // With plenty left it is still free to change.
        XCTAssertFalse(rule.isProtectedNow(at: at(12, 0), usedTodaySeconds: 5 * 60, runUpMinutes: 10, calendar: cal))
    }

    func testScheduleIsProtectedJustBeforeItStarts() {
        let rule = schedule
        XCTAssertFalse(rule.isProtectedNow(at: at(8, 59), calendar: cal))
        XCTAssertTrue(rule.isProtectedNow(at: at(8, 55), runUpMinutes: 10, calendar: cal))
        XCTAssertTrue(rule.isProtectedNow(at: at(8, 50), runUpMinutes: 10, calendar: cal))
        XCTAssertFalse(rule.isProtectedNow(at: at(8, 40), runUpMinutes: 10, calendar: cal))
    }

    func testRunUpNeverProtectsAnUnprotectedOrDisabledRule() {
        var open = schedule
        open.protection = .none
        XCTAssertFalse(open.isProtectedNow(at: at(8, 55), runUpMinutes: 10, calendar: cal))
        var off = schedule
        off.enabled = false
        XCTAssertFalse(off.isProtectedNow(at: at(8, 55), runUpMinutes: 10, calendar: cal))
    }

    func testWorkGoalRewardIsProtectedInItsLastMinutes() {
        let rule = GeneralBlockRule(
            name: "Meta",
            enabled: true,
            kind: .workGoal,
            goalMinutesRequired: 30,
            goalRewardMinutes: 20,
            domains: "x.com",
            protection: .challenge
        )
        let worked: TimeInterval = 30 * 60
        XCTAssertFalse(rule.isProtectedNow(at: at(18, 0), usedTodaySeconds: 15 * 60, workedTodaySeconds: worked, continuous: 100, calendar: cal))
        XCTAssertTrue(rule.isProtectedNow(at: at(18, 0), usedTodaySeconds: 15 * 60, workedTodaySeconds: worked, runUpMinutes: 10, continuous: 100, calendar: cal))
        XCTAssertFalse(rule.isProtectedNow(at: at(18, 0), usedTodaySeconds: 2 * 60, workedTodaySeconds: worked, runUpMinutes: 10, continuous: 100, calendar: cal))
    }
}

/// Public version: every rule can be deleted (subject to active protection/ratchet).
final class BuiltInRuleTests: XCTestCase {
    func testAnyRuleCanBeDeleted() {
        XCTAssertTrue(GeneralBlockRule.mandatoryStudyThenLoLRule.canBeDeleted)
        XCTAssertTrue(GeneralBlockRule(name: "Otra", domains: "x.com").canBeDeleted)
        XCTAssertFalse(GeneralBlockRule.defaults.contains(where: { $0.id == LeagueMatchRules.mandatoryStudyThenLoLRuleID }))
    }
}
