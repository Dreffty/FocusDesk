import XCTest
@testable import FocusCore

/// FD-09: only what is marked as study counts as study; everything else, Reddit and WhatsApp included, does not.
final class StudySourcesTests: XCTestCase {
    private func counts(
        _ bundleID: String,
        host: String? = nil,
        path: String? = nil,
        title: String? = nil,
        apps: Set<String>? = nil,
        webs: String? = nil
    ) -> Bool {
        let active = StudySources.active(StudySources.defaults, today: "2026-11-09")
        return StudyActivityVerifier.isVerifiedStudyActivity(
            idleSeconds: 5,
            frontBundleID: bundleID,
            hasVisibleWindowOnScreen: true,
            frontWindowTitle: title,
            browserHost: host,
            browserPath: path,
            studyApps: apps ?? active.apps,
            studyWebEntries: webs ?? active.webs
        )
    }

    func testDistractionsThatUsedToCountNoLongerDo() {
        XCTAssertFalse(counts("com.brave.Browser", host: "www.reddit.com", path: "/r/swift"))
        XCTAssertFalse(counts("com.brave.Browser", host: "www.youtube.com", path: "/watch"))
        XCTAssertFalse(counts("net.whatsapp.WhatsApp"))
        XCTAssertFalse(counts("ru.keepcoder.Telegram"))
        XCTAssertFalse(counts("com.apple.MobileSMS"))
        XCTAssertFalse(counts("com.apple.Photos"))
    }

    func testTheStartingListCounts() {
        XCTAssertTrue(counts("com.brave.Browser", host: "claude.ai", path: "/chat/1"))
        XCTAssertTrue(counts("com.brave.Browser", host: "chatgpt.com", path: "/"))
        XCTAssertTrue(counts("com.brave.Browser", host: "www.coursera.org", path: "/learn/algorithms"))
        XCTAssertTrue(counts("com.anthropic.claudefordesktop"))
        XCTAssertTrue(counts("com.apple.Preview"))
        XCTAssertTrue(counts("com.apple.dt.Xcode"))
        XCTAssertTrue(counts("com.microsoft.Word"))
    }

    func testABrowserWithoutAnAddressOnlyCountsForAPDF() {
        XCTAssertFalse(counts("com.brave.Browser", title: "Algo cualquiera"))
        XCTAssertFalse(counts("com.brave.Browser"))
        XCTAssertTrue(counts("com.brave.Browser", title: "Tema_4_Estadistica.pdf"))
        XCTAssertTrue(counts("com.brave.Browser", host: "example.org", path: "/apuntes/tema1.PDF"))
    }

    func testAnEmptyListCountsNothing() {
        XCTAssertFalse(counts("com.brave.Browser", host: "claude.ai", path: "/", apps: [], webs: ""))
        XCTAssertFalse(counts("com.apple.Preview", apps: [], webs: ""))
    }

    func testSomethingAddedTodayOnlyCountsFromTomorrow() {
        let reddit = StudySource(kind: .web, value: "reddit.com", name: "reddit.com", countsFrom: "2026-11-10")
        let today = StudySources.active([reddit], today: "2026-11-09")
        XCTAssertFalse(today.webs.contains("reddit.com"))
        let tomorrow = StudySources.active([reddit], today: "2026-11-10")
        XCTAssertTrue(tomorrow.webs.contains("reddit.com"))
    }

    func testMatchingIgnoresCaseOfBundleIDs() {
        let app = StudySource(kind: .app, value: "com.Example.App", name: "Example")
        let active = StudySources.active([app], today: "2026-11-09")
        XCTAssertTrue(counts("com.example.app", apps: active.apps, webs: active.webs))
    }

    func testOldSettingsGetTheStartingList() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.studySources, StudySources.defaults)
    }
}
