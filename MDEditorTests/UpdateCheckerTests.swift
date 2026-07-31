import XCTest
@testable import MDEditor

/// Update checking: version comparison, GitHub response parsing, skip
/// gating and the 20 h automatic throttle. The network is always stubbed
/// (the checker takes an `UpdateFeedProvider`), and alerts are never
/// presented — tests assert on the headless `runCheck` result instead.
@MainActor
final class UpdateCheckerTests: XCTestCase {
    /// Counted data-provider stub (the network seam). `@unchecked Sendable`:
    /// every access is serialized through the awaited check on the main actor.
    private final class StubProvider: UpdateFeedProvider, @unchecked Sendable {
        var calls = 0
        var result: Swift.Result<Data, any Error> = .failure(UpdateError.httpStatus(-1))

        func latestReleaseData() async throws -> Data {
            calls += 1
            return try result.get()
        }
    }

    /// Mutable clock box so the injected `now` closure can be advanced.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_780_000_000)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "MDEditorUpdateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeChecker(
        provider: StubProvider,
        clock: Clock,
        version: String = "0.1.0"
    ) throws -> (UpdateChecker, AppSettings) {
        let settings = AppSettings(defaults: try makeDefaults())
        let checker = UpdateChecker(provider: provider, currentVersion: version, now: { clock.now })
        checker.settings = settings
        return (checker, settings)
    }

    /// A realistic latest-release payload (abridged, but keeping extra
    /// fields GitHub always sends — unknown keys must be ignored).
    private func fixture(
        tag: String = "v0.2.0",
        name: String? = "MDEditor 0.2.0",
        body: String? = "## What's new\n- In-app update checks\n- Bug fixes",
        publishedAt: String? = "2026-07-30T12:34:56Z"
    ) -> Data {
        func jsonString(_ value: String?) -> String {
            guard let value else { return "null" }
            // Encoding a bare string keeps the fixture's escaping honest.
            let data = try! JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        }
        let json = """
        {
          "url": "https://api.github.com/repos/Swan15/MDEditor/releases/234567890",
          "assets_url": "https://api.github.com/repos/Swan15/MDEditor/releases/234567890/assets",
          "tag_name": \(jsonString(tag)),
          "target_commitish": "main",
          "name": \(jsonString(name)),
          "draft": false,
          "prerelease": false,
          "created_at": "2026-07-29T09:00:00Z",
          "published_at": \(jsonString(publishedAt)),
          "html_url": "https://github.com/Swan15/MDEditor/releases/tag/\(tag)",
          "body": \(jsonString(body))
        }
        """
        return Data(json.utf8)
    }

    // MARK: - Version comparison

    func testVersionComparisonMatrix() {
        // Required cases.
        XCTAssertTrue(VersionComparison.isNewer(remote: "v0.2.0", than: "0.1.9"))
        XCTAssertTrue(VersionComparison.isNewer(remote: "1.0", than: "0.9.9"))
        XCTAssertEqual(VersionComparison.compare("0.1.0", "v0.1.0"), .orderedSame)
        XCTAssertFalse(VersionComparison.isNewer(remote: "v0.1.0-beta", than: "0.1.0"))

        // Numeric, not lexicographic.
        XCTAssertTrue(VersionComparison.isNewer(remote: "0.10.0", than: "0.9.0"))
        // Missing components count as zero.
        XCTAssertEqual(VersionComparison.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertTrue(VersionComparison.isNewer(remote: "1.0.1", than: "1.0"))
        // Equal versions are never newer, either way round.
        XCTAssertFalse(VersionComparison.isNewer(remote: "0.1.0", than: "v0.1.0"))
        XCTAssertFalse(VersionComparison.isNewer(remote: "v0.1.0", than: "0.1.0"))
        // A pre-release is older than the same base release; the plain
        // release is newer than the pre-release.
        XCTAssertEqual(VersionComparison.compare("v0.1.0-beta", "0.1.0"), .orderedAscending)
        XCTAssertTrue(VersionComparison.isNewer(remote: "0.1.0", than: "v0.1.0-beta"))
        // Suffix contents are ignored: two pre-releases of one base tie.
        XCTAssertEqual(VersionComparison.compare("1.0.0-beta", "1.0.0-rc.1"), .orderedSame)
        // A pre-release of a HIGHER base still beats a lower plain release.
        XCTAssertTrue(VersionComparison.isNewer(remote: "0.2.0-beta", than: "0.1.0"))
    }

    // MARK: - Response parsing

    func testParsesRealisticResponse() throws {
        let release = try ReleaseInfo.parse(data: fixture())
        XCTAssertEqual(release.tagName, "v0.2.0")
        XCTAssertEqual(release.name, "MDEditor 0.2.0")
        XCTAssertEqual(
            release.htmlURL.absoluteString,
            "https://github.com/Swan15/MDEditor/releases/tag/v0.2.0"
        )
        XCTAssertEqual(release.body, "## What's new\n- In-app update checks\n- Bug fixes")
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-07-30T12:34:56Z"))
        XCTAssertEqual(release.displayVersion, "0.2.0")
    }

    func testParsesNullNameAndEmptyBody() throws {
        let release = try ReleaseInfo.parse(data: fixture(name: nil, body: nil))
        XCTAssertNil(release.name)
        XCTAssertEqual(release.body, "")
        XCTAssertEqual(release.notesExcerpt, "See the release page for details.")
    }

    func testParsesPrereleaseTagVerbatim() throws {
        let release = try ReleaseInfo.parse(data: fixture(tag: "v0.3.0-beta.1"))
        XCTAssertEqual(release.tagName, "v0.3.0-beta.1")
        XCTAssertFalse(
            VersionComparison.isNewer(remote: release.tagName, than: "0.3.0"),
            "a pre-release is older than the same released version"
        )
    }

    func testNotesExcerptTruncates() throws {
        let release = try ReleaseInfo.parse(data: fixture(body: String(repeating: "a", count: 400)))
        XCTAssertEqual(release.notesExcerpt.count, 300)
    }

    func testMalformedResponseThrows() {
        XCTAssertThrowsError(try ReleaseInfo.parse(data: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? UpdateError, .malformedResponse)
        }
        // Valid JSON, but not a release (missing tag_name / html_url).
        XCTAssertThrowsError(try ReleaseInfo.parse(data: Data(#"{"message": "Not Found"}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateError, .malformedResponse)
        }
    }

    // MARK: - Decision gating (pure)

    func testActionGating() throws {
        let release = try ReleaseInfo.parse(data: fixture(tag: "v0.2.0"))
        XCTAssertEqual(
            UpdatePolicy.action(for: release, localVersion: "0.1.0", skippedTag: nil),
            .notify(release)
        )
        XCTAssertEqual(
            UpdatePolicy.action(for: release, localVersion: "0.1.0", skippedTag: "v0.2.0"),
            .none,
            "the skipped tag stays silent"
        )
        XCTAssertEqual(
            UpdatePolicy.action(for: release, localVersion: "0.1.0", skippedTag: "v0.1.5"),
            .notify(release),
            "a different skipped tag doesn't mute newer releases"
        )
        XCTAssertEqual(
            UpdatePolicy.action(for: release, localVersion: "0.2.0", skippedTag: nil),
            .none,
            "the same version is not newer"
        )
    }

    func testAutomaticThrottleWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(UpdatePolicy.shouldCheckAutomatically(lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.shouldCheckAutomatically(
            lastCheck: now.addingTimeInterval(-19 * 3600), now: now
        ))
        XCTAssertTrue(UpdatePolicy.shouldCheckAutomatically(
            lastCheck: now.addingTimeInterval(-21 * 3600), now: now
        ))
    }

    // MARK: - runCheck (headless, stubbed provider)

    func testAutomaticCheckThrottlesWithinInterval() async throws {
        let provider = StubProvider()
        provider.result = .success(fixture())
        let clock = Clock()
        let (checker, settings) = try makeChecker(provider: provider, clock: clock)

        // First automatic check runs (never checked before) and finds 0.2.0.
        var result = await checker.runCheck(manual: false)
        XCTAssertEqual(result, .updateAvailable(try ReleaseInfo.parse(data: fixture())))
        XCTAssertEqual(provider.calls, 1)
        XCTAssertEqual(settings.lastUpdateCheck, clock.now, "the attempt timestamp persists")

        // A second automatic check inside 20 h is a no-op...
        result = await checker.runCheck(manual: false)
        XCTAssertEqual(result, .throttled)
        XCTAssertEqual(provider.calls, 1)

        // ...but a manual check always runs.
        result = await checker.runCheck(manual: true)
        XCTAssertEqual(provider.calls, 2)
        XCTAssertEqual(result, .updateAvailable(try ReleaseInfo.parse(data: fixture())))

        // After the interval, automatic checks resume.
        clock.now = clock.now.addingTimeInterval(21 * 3600)
        result = await checker.runCheck(manual: false)
        XCTAssertEqual(provider.calls, 3)
    }

    func testSkippedTagStaysSilentUntilNewerTag() async throws {
        let provider = StubProvider()
        provider.result = .success(fixture(tag: "v0.2.0"))
        let clock = Clock()
        let (checker, settings) = try makeChecker(provider: provider, clock: clock)
        settings.skippedUpdateVersion = "v0.2.0"

        var result = await checker.runCheck(manual: true)
        XCTAssertEqual(result, .upToDate, "the skipped tag never prompts")

        provider.result = .success(fixture(tag: "v0.3.0"))
        result = await checker.runCheck(manual: true)
        guard case .updateAvailable(let release) = result else {
            return XCTFail("expected .updateAvailable, got \(result)")
        }
        XCTAssertEqual(release.tagName, "v0.3.0")
    }

    func testSameVersionIsUpToDate() async throws {
        let provider = StubProvider()
        provider.result = .success(fixture(tag: "v0.1.0"))
        let clock = Clock()
        let (checker, _) = try makeChecker(provider: provider, clock: clock)

        let result = await checker.runCheck(manual: true)
        XCTAssertEqual(result, .upToDate)
    }

    func testFailureSurfacesMessage() async throws {
        let provider = StubProvider()
        provider.result = .failure(UpdateError.httpStatus(403))
        let clock = Clock()
        let (checker, _) = try makeChecker(provider: provider, clock: clock)

        let result = await checker.runCheck(manual: true)
        guard case .failed(let message) = result else {
            return XCTFail("expected .failed, got \(result)")
        }
        XCTAssertTrue(message.contains("403"))
    }
}
