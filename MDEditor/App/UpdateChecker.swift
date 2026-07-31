import AppKit
import Foundation

/// One GitHub Release as the update checker needs it: the relevant subset
/// of the REST response for `GET /repos/Swan15/MDEditor/releases/latest`.
struct ReleaseInfo: Equatable, Sendable {
    /// Release tag, e.g. "v0.2.0" (compared against the running version).
    let tagName: String
    /// Release title; GitHub allows it to be null.
    let name: String?
    /// Public release page — "Download Update" opens this in the browser.
    let htmlURL: URL
    /// Release notes (Markdown source); empty when the release has none.
    let body: String
    /// Publication date; tolerated as missing/unparseable.
    let publishedAt: Date?

    init(tagName: String, name: String?, htmlURL: URL, body: String, publishedAt: Date?) {
        self.tagName = tagName
        self.name = name
        self.htmlURL = htmlURL
        self.body = body
        self.publishedAt = publishedAt
    }

    /// The tag without its leading v/V, for display ("MDEditor 0.2.0 is available").
    var displayVersion: String {
        var tag = tagName
        if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
        return tag
    }

    /// Short plain excerpt of the release notes for the alert body (the
    /// Markdown stays unrendered — the full notes are one click away).
    var notesExcerpt: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "See the release page for details." }
        return String(trimmed.prefix(300))
    }
}

extension ReleaseInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tagName: try container.decode(String.self, forKey: .tagName),
            name: try container.decodeIfPresent(String.self, forKey: .name),
            htmlURL: try container.decode(URL.self, forKey: .htmlURL),
            body: try container.decodeIfPresent(String.self, forKey: .body) ?? "",
            publishedAt: try container.decodeIfPresent(String.self, forKey: .publishedAt)
                .flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    /// Parses one REST response body; anything that doesn't decode as a
    /// release (bad JSON, missing fields) is a malformed-response error.
    static func parse(data: Data) throws -> ReleaseInfo {
        do {
            return try JSONDecoder().decode(ReleaseInfo.self, from: data)
        } catch {
            throw UpdateError.malformedResponse
        }
    }
}

/// Ways an update check can fail (surfaced only for manual checks).
enum UpdateError: LocalizedError, Equatable {
    /// GitHub answered with a non-200 status (rate limit, server error, …).
    case httpStatus(Int)
    /// The response wasn't a parseable release.
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code):
            return "GitHub returned an unexpected response (HTTP \(code))."
        case .malformedResponse:
            return "The release information from GitHub couldn't be read."
        }
    }
}

/// Version-string comparison for release tags vs. the running version.
/// Deliberately simple: numeric, component-wise, pre-release suffix ignored.
enum VersionComparison {
    /// Compares two versions: a leading `v`/`V` is stripped, components are
    /// compared numerically with missing ones counting as 0 ("1.0" == "1.0.0",
    /// "0.10" > "0.9" — no lexicographic trap). A pre-release suffix
    /// (`-beta.1`) makes a version OLDER than the same base without one; the
    /// suffix content itself is ignored (so `-beta` and `-rc.1` tie).
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = parse(lhs), r = parse(rhs)
        for index in 0 ..< max(l.components.count, r.components.count) {
            let a = index < l.components.count ? l.components[index] : 0
            let b = index < r.components.count ? r.components[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        if l.isPrerelease != r.isPrerelease {
            return l.isPrerelease ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    /// True when `remote` is a strictly newer version than `local`.
    static func isNewer(remote: String, than local: String) -> Bool {
        compare(remote, local) == .orderedDescending
    }

    private static func parse(_ version: String) -> (components: [Int], isPrerelease: Bool) {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let parts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = parts[0].split(separator: ".").map { Int($0) ?? 0 }
        return (components, parts.count > 1 && !parts[1].isEmpty)
    }
}

/// Pure decision logic for update checks, kept headless so the whole gating
/// matrix is unit-testable (mirrors `DocumentSwitchPolicy`).
enum UpdatePolicy {
    /// What a fetched release means for the user.
    enum Action: Equatable {
        /// Nothing to show (not newer, or the user skipped this tag).
        case none
        /// Present the update alert for this release.
        case notify(ReleaseInfo)
    }

    /// Notify only for a genuinely newer release whose tag wasn't skipped
    /// via "Skip This Version".
    static func action(for release: ReleaseInfo, localVersion: String, skippedTag: String?) -> Action {
        guard VersionComparison.isNewer(remote: release.tagName, than: localVersion) else { return .none }
        guard release.tagName != skippedTag else { return .none }
        return .notify(release)
    }

    /// Automatic checks run at most once per `interval` (20 h), measured
    /// against the last ATTEMPT — failed checks throttle too, so a broken
    /// network doesn't retry on every launch.
    static func shouldCheckAutomatically(
        lastCheck: Date?,
        now: Date,
        interval: TimeInterval = 20 * 60 * 60
    ) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }
}

/// The network seam: returns the raw response body of the latest-release
/// endpoint. Tests stub it so they never hit the network.
protocol UpdateFeedProvider: Sendable {
    func latestReleaseData() async throws -> Data
}

/// Live provider: unauthenticated GitHub REST call (public repo — the
/// 60 req/hr anonymous rate limit is ample for a daily check).
struct GitHubReleaseProvider: UpdateFeedProvider {
    /// Latest-release endpoint for the public repository. (`/releases/latest`
    /// only ever returns published, non-prerelease releases.)
    static let releasesURL = URL(string: "https://api.github.com/repos/Swan15/MDEditor/releases/latest")!

    /// Running version, sent as the User-Agent (GitHub rejects requests
    /// without one).
    let currentVersion: String

    func latestReleaseData() async throws -> Data {
        var request = URLRequest(url: Self.releasesURL)
        request.setValue("MDEditor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }
}

/// Checks GitHub Releases for a newer MDEditor version.
///
/// Two entry points: an automatic check once per launch (throttled to one
/// attempt per 20 h, silent unless a newer, un-skipped release exists) and a
/// manual one from the app menu (always runs, reports every outcome).
/// "Download Update" only opens the release page in the browser — there is
/// deliberately no in-place replacement: the app ships as a plain .app
/// attached to the release, and self-replacing a running sandboxed binary
/// buys code-signing and permission complexity for nothing.
///
/// `runCheck` is the headless core (no AppKit); alert presentation lives in
/// `checkForUpdates`, which tests never call.
@MainActor
final class UpdateChecker {
    /// What a finished check decided (drives the alerts; tests assert on it).
    enum Result: Equatable {
        /// Automatic check skipped: the last attempt is inside the 20 h window.
        case throttled
        /// Fetched successfully; nothing to show (not newer, or tag skipped).
        case upToDate
        /// Fetched successfully; a newer, un-skipped release exists.
        case updateAvailable(ReleaseInfo)
        /// The fetch or parse failed (message for the manual alert).
        case failed(String)
    }

    /// Shared checker for the app (menu command + launch auto-check).
    static let shared = UpdateChecker()

    /// Shared preferences, wired from the SwiftUI app once they exist
    /// (last-attempt timestamp + skipped tag live there).
    var settings: AppSettings?

    private let provider: any UpdateFeedProvider
    private let currentVersion: String
    private let now: () -> Date

    /// Multi-window guard: every window's `onAppear` schedules an automatic
    /// check, but only the first one sticks.
    private var didScheduleAutomaticCheck = false
    /// Coalesces a second check starting while one is still fetching (its
    /// outcome alert would be confusing; the window is one network round
    /// trip, so the extra click simply no-ops).
    private var checkInFlight = false

    init(
        provider: (any UpdateFeedProvider)? = nil,
        currentVersion: String? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let version = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        self.currentVersion = version
        self.provider = provider ?? GitHubReleaseProvider(currentVersion: version)
        self.now = now
    }

    /// Fires the automatic check once per launch, 3 s later so startup is
    /// never blocked. Called from every window's `onAppear`; the guard makes
    /// extra windows no-ops.
    func scheduleAutomaticCheckIfNeeded() {
        guard !didScheduleAutomaticCheck else { return }
        didScheduleAutomaticCheck = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            await self.checkForUpdates(manual: false)
        }
    }

    /// Runs a check and presents the appropriate alert (the AppKit path).
    func checkForUpdates(manual: Bool) async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }
        let result = await runCheck(manual: manual)
        present(result, manual: manual)
    }

    /// The headless core: throttle, fetch, parse, decide. The attempt
    /// timestamp is persisted up front (see `UpdatePolicy`).
    @discardableResult
    func runCheck(manual: Bool) async -> Result {
        if !manual,
           !UpdatePolicy.shouldCheckAutomatically(lastCheck: settings?.lastUpdateCheck, now: now()) {
            return .throttled
        }
        settings?.lastUpdateCheck = now()

        let release: ReleaseInfo
        do {
            let data = try await provider.latestReleaseData()
            release = try ReleaseInfo.parse(data: data)
        } catch {
            return .failed(error.localizedDescription)
        }

        switch UpdatePolicy.action(
            for: release,
            localVersion: currentVersion,
            skippedTag: settings?.skippedUpdateVersion
        ) {
        case .none:
            return .upToDate
        case .notify(let release):
            return .updateAvailable(release)
        }
    }

    /// Alert presentation (kept out of `runCheck` so tests stay headless).
    /// Automatic checks stay silent for every outcome except a genuinely
    /// newer, un-skipped release.
    private func present(_ result: Result, manual: Bool) {
        switch result {
        case .throttled:
            break
        case .upToDate:
            guard manual else { return }
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "MDEditor \(currentVersion) is the latest version."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let message):
            guard manual else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't Check for Updates"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .updateAvailable(let release):
            presentUpdateAlert(release)
        }
    }

    /// "MDEditor X.Y.Z is available": Download Update opens the release page
    /// in the browser (no in-place replacement — see the type doc), Later
    /// just dismisses, Skip This Version mutes the tag until a newer one.
    private func presentUpdateAlert(_ release: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "MDEditor \(release.displayVersion) is available"
        alert.informativeText = release.notesExcerpt
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.htmlURL)
        case .alertThirdButtonReturn:
            settings?.skippedUpdateVersion = release.tagName
        default:
            break
        }
    }
}
