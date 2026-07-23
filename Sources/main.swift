import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import UserNotifications

// MARK: - Demo mode

/// Anonymizes real project names for documentation screenshots, so a public
/// screenshot never leaks what you're actually working on. Turn on with:
///     defaults write com.mathiasbesil.halo demoMode -bool true
/// and off again with `-bool false` (then relaunch). Only the display name
/// changes; every real name still maps to a single stable generic one, so
/// per-project totals stay consistent.
enum Demo {
    static let on = UserDefaults.standard.bool(forKey: "demoMode")

    private static let names = [
        "web-app", "api-server", "mobile-client", "data-pipeline",
        "auth-service", "dashboard", "payments-svc", "notebooks",
        "cli-tools", "landing-page", "worker-queue", "docs-site",
        "search-index", "billing", "analytics", "gateway",
    ]

    /// Stable across runs (djb2, not Swift's per-process-seeded hash), so the
    /// same project keeps the same generic name between launches.
    static func project(_ real: String) -> String {
        guard on else { return real }
        var hash: UInt64 = 5381
        for byte in real.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return names[Int(hash % UInt64(names.count))]
    }
}

// MARK: - Data model

struct UsageEntry {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    /// message id + request id; empty when neither is present
    let dedupeKey: String
    let sessionId: String
    /// Working directory of the session; last path component is the project name.
    let cwd: String
    /// Subagent turns; they bill normally but their context is not the main thread's.
    let isSidechain: Bool

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
    /// Approximate context size of this turn: everything the model was sent.
    var contextTokens: Int { inputTokens + cacheCreationTokens + cacheReadTokens }
    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return Demo.project(name.isEmpty ? "unknown" : name)
    }
}

struct Stats {
    var entries: [UsageEntry] = []

    var inputTokens: Int { entries.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { entries.reduce(0) { $0 + $1.outputTokens } }
    var cacheCreationTokens: Int { entries.reduce(0) { $0 + $1.cacheCreationTokens } }
    var cacheReadTokens: Int { entries.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalTokens: Int { entries.reduce(0) { $0 + $1.totalTokens } }
    var cost: Double { entries.reduce(0) { $0 + Pricing.cost(for: $1) } }

    /// (model short name, tokens, cost) sorted by cost descending
    var byModel: [(String, Int, Double)] {
        var agg: [String: (Int, Double)] = [:]
        for e in entries {
            let name = Pricing.shortName(e.model)
            let cur = agg[name] ?? (0, 0)
            agg[name] = (cur.0 + e.totalTokens, cur.1 + Pricing.cost(for: e))
        }
        return agg.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.2 > $1.2 }
    }
}

struct BlockStats {
    var start: Date
    var end: Date { start.addingTimeInterval(5 * 3600) }
    var stats = Stats()
}

// MARK: - Pricing (USD per million tokens, list API pricing)

enum Pricing {
    struct Rate { let input: Double; let output: Double; let cacheWrite: Double; let cacheRead: Double }

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        if m.contains("opus") || m.contains("fable") {
            return Rate(input: 15, output: 75, cacheWrite: 18.75, cacheRead: 1.5)
        }
        if m.contains("haiku") {
            return Rate(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1)
        }
        // sonnet and default
        return Rate(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3)
    }

    static func shortName(_ model: String) -> String {
        let m = model.lowercased()
        for name in ["fable", "opus", "sonnet", "haiku"] where m.contains(name) {
            return name.capitalized
        }
        return model.isEmpty ? "unknown" : model
    }

    static func cost(for e: UsageEntry) -> Double {
        let r = rate(for: e.model)
        return (Double(e.inputTokens) * r.input
              + Double(e.outputTokens) * r.output
              + Double(e.cacheCreationTokens) * r.cacheWrite
              + Double(e.cacheReadTokens) * r.cacheRead) / 1_000_000
    }
}

// MARK: - JSONL parsing with per-file cache

final class UsageReader {
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    private struct CachedFile {
        let mtime: Date
        let size: Int
        let entries: [UsageEntry]
    }
    private var cache: [String: CachedFile] = [:]

    private let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoParserNoFrac = ISO8601DateFormatter()

    private func parseDate(_ s: String) -> Date? {
        isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
    }

    /// All usage entries in files modified after `cutoff`, deduped by message id +
    /// request id, sorted by timestamp. Unchanged files are served from cache.
    func entries(since cutoff: Date) -> [UsageEntry] {
        var result: [UsageEntry] = []
        var seen = Set<String>()
        var liveFiles = Set<String>()

        guard let en = FileManager.default.enumerator(
            at: projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }

        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mtime = vals.contentModificationDate else { continue }
            if mtime < cutoff { continue }
            let size = vals.fileSize ?? 0
            let path = url.path
            liveFiles.insert(path)

            let fileEntries: [UsageEntry]
            if let c = cache[path], c.mtime == mtime, c.size == size {
                fileEntries = c.entries
            } else {
                fileEntries = parseFile(url)
                cache[path] = CachedFile(mtime: mtime, size: size, entries: fileEntries)
            }

            for e in fileEntries where e.timestamp >= cutoff {
                result.append(e)
            }
        }

        // Drop cache entries for files that fell outside the window or were deleted.
        for key in cache.keys where !liveFiles.contains(key) {
            cache.removeValue(forKey: key)
        }

        // Dedupe across files (same message can appear in resumed/forked sessions).
        // Tiebreak equal timestamps by dedupeKey so the surviving copy — and thus
        // which session's stats it lands in — is deterministic across refreshes.
        var deduped: [UsageEntry] = []
        deduped.reserveCapacity(result.count)
        let sorted = result.sorted {
            $0.timestamp == $1.timestamp ? $0.dedupeKey < $1.dedupeKey : $0.timestamp < $1.timestamp
        }
        for e in sorted {
            if e.dedupeKey.isEmpty || seen.insert(e.dedupeKey).inserted {
                deduped.append(e)
            }
        }
        return deduped
    }

    private func parseFile(_ url: URL) -> [UsageEntry] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [UsageEntry] = []
        for line in text.split(separator: "\n") {
            guard line.contains("\"usage\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let tsStr = obj["timestamp"] as? String,
                  let ts = parseDate(tsStr),
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }

            let model = (message["model"] as? String) ?? ""
            if model == "<synthetic>" { continue }

            out.append(UsageEntry(
                timestamp: ts,
                model: model,
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                dedupeKey: {
                    let msgId = (message["id"] as? String) ?? ""
                    let reqId = (obj["requestId"] as? String) ?? ""
                    return (msgId.isEmpty && reqId.isEmpty) ? "" : msgId + ":" + reqId
                }(),
                sessionId: (obj["sessionId"] as? String) ?? "",
                cwd: (obj["cwd"] as? String) ?? "",
                isSidechain: (obj["isSidechain"] as? Bool) ?? false
            ))
        }
        return out
    }
}

// MARK: - Claude account OAuth (own token, stored in this app's Keychain item)

/// Where a limit percentage came from, best-to-worst. Shown in the UI so an
/// estimate is never presented as account-truth.
enum LimitSource: String {
    case official    // Claude Code's own statusline hand-off — local, no network, no token
    case live        // the OAuth usage endpoint — real, but an undocumented API
    case estimated   // computed locally from ~/.claude logs when nothing better is available
}

struct LimitBar {
    let kind: String           // stable identity from the API, e.g. "session", "weekly_all"
    let scopeName: String?     // model display name for scoped limits
    let label: String
    let shortLabel: String     // for the menu bar title, e.g. "5h", "W", "F"
    let percent: Double        // 0–100
    let resetsAt: Date?
    var source: LimitSource = .live

    /// Persistence key for history tracking; stable across label wording changes.
    var trackerKey: String { scopeName.map { "\(kind):\($0)" } ?? kind }

    /// Short name under a ring gauge.
    var displayName: String {
        switch kind {
        case "session", "five_hour": return "5-hour"
        case "weekly_all", "seven_day": return "Weekly"
        default:
            if let scopeName { return scopeName }
            if let dot = label.range(of: " · ") { return String(label[dot.upperBound...]) }
            return label
        }
    }
}

struct LimitsSnapshot {
    var bars: [LimitBar]
    var fetchedAt: Date
    /// True only when fetching is failing and these are the last good bars —
    /// not merely when they're being reused between polls.
    var stale: Bool

    func markedStale(_ flag: Bool = true) -> LimitsSnapshot {
        var s = self; s.stale = flag; return s
    }
}

/// Samples each limit's percent over time (persisted across restarts) so we can
/// estimate when a limit will be hit at the current pace.
final class LimitTracker {
    static let shared = LimitTracker()
    private let key = "limitHistory"
    private let maxAge: TimeInterval = 3 * 3600
    private let queue = DispatchQueue(label: "com.mathiasbesil.halo.limittracker")
    /// trackerKey -> [(unix time, percent)]
    private var series: [String: [[Double]]]

    private init() {
        series = (UserDefaults.standard.dictionary(forKey: key) as? [String: [[Double]]]) ?? [:]
    }

    func record(_ bars: [LimitBar], at now: Date) {
        queue.sync {
            // Drop series for limits the API no longer reports.
            let liveKeys = Set(bars.map { $0.trackerKey })
            series = series.filter { liveKeys.contains($0.key) }
            for bar in bars {
                var s = series[bar.trackerKey] ?? []
                // A drop in percent means the window reset; old samples are useless.
                if let last = s.last, bar.percent < last[1] - 0.5 { s = [] }
                s.append([now.timeIntervalSince1970, bar.percent])
                s.removeAll { now.timeIntervalSince1970 - $0[0] > maxAge }
                series[bar.trackerKey] = s
            }
            UserDefaults.standard.set(series, forKey: key)
        }
    }

    /// Projected time the limit reaches 100% at the pace of the last hour, or nil
    /// when there's too little history, no growth, or the reset comes first.
    func projectedHit(_ bar: LimitBar, now: Date) -> Date? {
        let s = queue.sync { series[bar.trackerKey] ?? [] }
        let window = s.filter { now.timeIntervalSince1970 - $0[0] <= 3600 }
        guard let first = window.first, let last = window.last,
              last[0] - first[0] >= 10 * 60 else { return nil }
        let perMin = (last[1] - first[1]) / ((last[0] - first[0]) / 60)
        guard perMin > 0.05, bar.percent < 100 else { return nil }
        let minutes = (100 - bar.percent) / perMin
        guard minutes < 6 * 60 else { return nil }
        let hit = now.addingTimeInterval(minutes * 60)
        if let resets = bar.resetsAt, resets <= hit { return nil }
        return hit
    }
}

/// The kinds of notification the app can post. Each is independently
/// switchable, so anything that turns out to be noise can be turned off on its
/// own without silencing the rest.
enum NotifyKind: String, CaseIterable {
    case nearLimit, projected, headroom, reset

    var label: String {
        switch self {
        case .nearLimit: return "Approaching a limit (80%, 95%)"
        case .projected: return "On pace to hit a limit"
        case .headroom: return "Unused capacity before a reset"
        case .reset: return "A spent limit has reset"
        }
    }

    var detail: String {
        switch self {
        case .nearLimit: return "Once when a limit passes 80% and again at 95%"
        case .projected: return "When your current pace would exhaust a limit before it resets"
        case .headroom: return "Shortly before a window resets while a good chunk of it is still unused — spend it or lose it"
        case .reset: return "When a limit you nearly used up rolls over"
        }
    }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notify.\(rawValue)") as? Bool ?? true }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: "notify.\(rawValue)") }
    }
}

/// Posts macOS notifications about limit windows. Every event fires at most
/// once per limit per window; the record of what already fired is keyed by the
/// window's reset time, so it survives restarts without re-notifying.
final class LimitNotifier {
    static let shared = LimitNotifier()
    /// Highest percent seen in the current window, per limit — a big drop means
    /// the window rolled over.
    private var peak: [String: Double] = [:]
    /// Event id -> when it stops mattering (unix time); pruned as windows pass.
    private var fired: [String: Double]

    private init() {
        fired = (UserDefaults.standard.dictionary(forKey: "notifyFired") as? [String: Double]) ?? [:]
    }

    /// Master switch; the per-kind toggles live on `NotifyKind`.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notifyNearLimits") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notifyNearLimits") }
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { NSLog("notifications not authorized") }
        }
    }

    /// How early to flag unused capacity: the 5-hour window is short enough that
    /// half an hour is still usable; a weekly window deserves more warning.
    private func headroomLead(_ bar: LimitBar) -> TimeInterval {
        (bar.kind == "session" || bar.kind == "five_hour") ? 30 * 60 : 60 * 60
    }

    /// Call with fresh (non-stale) bars only; stale bars repeat old percentages.
    func check(_ bars: [LimitBar], now: Date) {
        guard enabled else { return }
        for bar in bars {
            let key = bar.trackerKey

            // A meaningful drop means the window rolled over.
            if let prior = peak[key], bar.percent < prior - 5 {
                if prior >= 80 {
                    fire(.reset, bar, now: now,
                         title: "\(bar.label) has reset",
                         body: "Back down to \(Int(bar.percent))% — you're good to go.")
                }
                peak[key] = bar.percent
            } else {
                peak[key] = max(peak[key] ?? 0, bar.percent)
            }

            for threshold in [95.0, 80.0] where bar.percent >= threshold {
                let resets = bar.resetsAt.map { " Resets \(shortResetText($0))." } ?? ""
                fire(.nearLimit, bar, now: now, suffix: "\(Int(threshold))",
                     title: "\(bar.label): \(Int(bar.percent))% used",
                     body: threshold >= 95
                         ? "Almost exhausted.\(resets)"
                         : "Getting close — lighter models stretch it.\(resets)")
                break   // 95 supersedes 80
            }

            if bar.percent < 80, let hit = LimitTracker.shared.projectedHit(bar, now: now) {
                fire(.projected, bar, now: now,
                     title: "On pace to hit \(bar.label)",
                     body: "At the current pace it runs out around \(timeHM(hit)), before it resets.")
            }

            // Use-it-or-lose-it: capacity left in a window that's about to roll
            // over is capacity wasted.
            if let resets = bar.resetsAt, bar.percent <= 75 {
                let left = resets.timeIntervalSince(now)
                if left > 0, left <= headroomLead(bar) {
                    fire(.headroom, bar, now: now,
                         title: "\(bar.label) resets \(shortResetText(resets))",
                         body: "\(Int(100 - bar.percent))% of it is still unused — a good window for the heavy work.")
                }
            }
        }
    }

    /// Posts once per (kind, limit, window). `suffix` distinguishes events of the
    /// same kind within one window, e.g. the 80% and 95% thresholds.
    private func fire(_ kind: NotifyKind, _ bar: LimitBar, now: Date,
                      suffix: String = "", title: String, body: String) {
        guard kind.enabled else { return }
        // Windowless limits fall back to the current window's peak-drop tracking.
        let window = bar.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
        let id = "\(kind.rawValue)|\(bar.trackerKey)|\(suffix)|\(window)"
        guard fired[id] == nil else { return }

        // Keep the record only while its window can still recur.
        let expiry = (bar.resetsAt ?? now).addingTimeInterval(3600).timeIntervalSince1970
        fired[id] = expiry
        fired = fired.filter { $0.value > now.timeIntervalSince1970 }
        UserDefaults.standard.set(fired, forKey: "notifyFired")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}

/// Why the plan-limit section has nothing to show.
enum LimitsStatus {
    case ok
    case noClaudeCode      // Claude Code isn't signed in on this Mac
    case keychainDenied    // the user declined this app's Keychain request
    case expired           // Claude Code's token has lapsed; only it can renew

    var hint: String? {
        switch self {
        case .ok: return nil
        case .noClaudeCode: return "No Claude login found — connect below to see plan limits"
        case .keychainDenied: return "Keychain access denied — Halo needs it to read Claude Code's login"
        case .expired: return "Claude session expired — connect below to see plan limits"
        }
    }
}

/// Fetches the plan limits for the user's Claude account.
///
/// Auth resolution order:
///  1. Halo's own grant — created via "Connect to Claude…" and kept in Halo's
///     own Keychain item, refreshed as needed. Zero prompts about other apps'
///     items, works everywhere.
///  2. Claude Code's stored login — read-only; if its access token is stale but
///     a refresh token is present, a fresh token is minted in memory. Claude
///     Code's item is never written to. This makes most installs work with no
///     sign-in at all.
/// If neither yields a token the menu offers "Connect to Claude…".
final class ClaudeAccount {
    static let shared = ClaudeAccount()
    private let ccService = "Claude Code-credentials"
    private let haloService = "com.mathiasbesil.halo"
    /// The pre-rename app's item; read (and migrated from) so existing installs
    /// keep working without a re-connect.
    private let legacyService = "com.mathiasbesil.claude-usage"
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri = "https://console.anthropic.com/oauth/code/callback"
    private let queue = DispatchQueue(label: "com.mathiasbesil.halo.account")

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    /// Token minted from Claude Code's refresh grant; kept in memory only.
    private var minted: Tokens?
    private var pendingVerifier: String?
    private var pendingState: String?

    /// Last successful limits, reused while a fetch is failing or rate-limited.
    private var cachedLimits: LimitsSnapshot?
    /// Hard gate: never send a request before this, not even for a manual refresh.
    /// Holds the 429 backoff, and a short floor that stops a held-down ⌘R from
    /// bursting requests at the endpoint.
    private var nextFetchAllowed = Date.distantPast
    /// Soft gate: the routine polling interval, which a manual refresh may skip.
    private var nextPoll = Date.distantPast
    private var backoff: TimeInterval = 0
    /// Whether the last attempted fetch failed; drives the stale marker.
    private var fetchFailing = false
    /// Why limits are unavailable, for the menu to explain. Set on every fetch.
    private var lastStatus: LimitsStatus = .ok
    private let fetchFloor: TimeInterval = 5
    private let pollInterval: TimeInterval = 120
    private let maxBackoff: TimeInterval = 15 * 60

    var status: LimitsStatus { queue.sync { lastStatus } }

    private func cached() -> LimitsSnapshot? { queue.sync { cachedLimits } }

    // MARK: Claude Code's Keychain credentials (read-only)

    private enum Credentials {
        case ok(Tokens)
        case missing
        case denied
    }

    /// Reads one keychain item's data. `nil` OSStatus out-param distinction isn't
    /// needed by most callers, so errors collapse to nil unless captured.
    private func readItem(_ service: String, status statusOut: inout OSStatus) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            // These are classic items in the file-based login keychain. A bundled,
            // signed app otherwise gets routed to the data-protection keychain,
            // which is a different store: the lookup then succeeds at finding
            // nothing. Ask for the store the items are actually in.
            kSecUseDataProtectionKeychain as String: false,
        ]
        var item: CFTypeRef?
        statusOut = SecItemCopyMatching(query as CFDictionary, &item)
        return statusOut == errSecSuccess ? item as? Data : nil
    }

    private func loadOwnTokens() -> Tokens? {
        for service in [haloService, legacyService] {
            var status: OSStatus = errSecSuccess
            if let data = readItem(service, status: &status),
               let t = try? JSONDecoder().decode(Tokens.self, from: data) {
                return t
            }
        }
        return nil
    }

    private func saveOwnTokens(_ t: Tokens) {
        guard let data = try? JSONEncoder().encode(t) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: haloService,
            kSecUseDataProtectionKeychain as String: false,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Removes Halo's own grant. Claude Code's item is never touched.
    func disconnect() {
        for service in [haloService, legacyService] {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecUseDataProtectionKeychain as String: false,
            ] as CFDictionary)
        }
        queue.sync {
            minted = nil
            cachedLimits = nil
            backoff = 0
            fetchFailing = false
            nextFetchAllowed = .distantPast
            nextPoll = .distantPast
        }
    }

    private func loadCredentials() -> Credentials {
        var status: OSStatus = errSecSuccess
        guard let data = readItem(ccService, status: &status) else {
            if status == errSecItemNotFound {
                return .missing
            }
            // Most often the user clicked Deny on the Keychain prompt.
            NSLog("Claude Code keychain read failed (OSStatus \(status))")
            return .denied
        }
        guard let t = Self.parseCredentials(data) else {
            NSLog("Claude Code credentials present but unreadable")
            return .missing
        }
        return .ok(t)
    }

    /// Claude Code writes `{"claudeAiOauth": {"accessToken": …, "refreshToken": …,
    /// "expiresAt": …}}`. Parsed defensively: the fields are also accepted at the
    /// top level and in snake_case, and `expiresAt` in either seconds or
    /// milliseconds, so a change on their side degrades to "no limits" rather
    /// than a crash.
    private static func parseCredentials(_ data: Data) -> Tokens? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for dict in [root["claudeAiOauth"] as? [String: Any], root].compactMap({ $0 }) {
            guard let token = (dict["accessToken"] ?? dict["access_token"]) as? String,
                  !token.isEmpty else { continue }
            // Without an expiry, assume it's live and let a 401 correct us.
            var expires = Date.distantFuture
            if let raw = (dict["expiresAt"] ?? dict["expires_at"]) as? Double {
                expires = Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
            }
            return Tokens(
                accessToken: token,
                refreshToken: (dict["refreshToken"] ?? dict["refresh_token"]) as? String ?? "",
                expiresAt: expires)
        }
        return nil
    }

    // MARK: OAuth token endpoint

    private enum GrantResult {
        case success(Tokens)
        case rejected       // the grant itself is dead; only a sign-in fixes it
        case network        // transient failure
    }

    /// POSTs to the token endpoint for both refresh and authorization-code
    /// grants; `priorRefresh` is kept when the response doesn't rotate it.
    private func tokenGrant(body: [String: Any], priorRefresh: String) -> GrantResult {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, status, _) = Self.syncRequest(req)
        guard let data, status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            if (400...403).contains(status) {
                NSLog("token grant rejected (HTTP \(status))")
                return .rejected
            }
            NSLog("token endpoint unreachable (HTTP \(status))")
            return .network
        }
        let refresh = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? priorRefresh
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return .success(Tokens(accessToken: access,
                               refreshToken: refresh,
                               expiresAt: Date().addingTimeInterval(expiresIn - 60)))
    }

    private func refreshGrant(_ refreshToken: String) -> GrantResult {
        tokenGrant(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ], priorRefresh: refreshToken)
    }

    // MARK: Access token resolution

    private enum TokenResult {
        case valid(String)
        case transient      // network blip — the session may still be fine
        case unauthorized   // nothing usable; the menu offers Connect
    }

    private func validAccessToken() -> TokenResult {
        // A token minted earlier this run and still unexpired wins: no Keychain
        // read, no network.
        if let m = queue.sync(execute: { minted }), m.expiresAt > Date() {
            return .valid(m.accessToken)
        }

        // 1) Halo's own grant.
        if var own = loadOwnTokens() {
            if own.expiresAt > Date() {
                queue.sync { lastStatus = .ok }
                return .valid(own.accessToken)
            }
            if !own.refreshToken.isEmpty {
                switch refreshGrant(own.refreshToken) {
                case .success(let fresh):
                    own = fresh
                    saveOwnTokens(own)
                    queue.sync { lastStatus = .ok }
                    return .valid(own.accessToken)
                case .network:
                    return .transient
                case .rejected:
                    break   // fall through to Claude Code's login
                }
            }
        }

        // 2) Claude Code's stored login, read-only.
        switch loadCredentials() {
        case .denied:
            queue.sync { lastStatus = .keychainDenied; minted = nil }
            return .unauthorized
        case .missing:
            queue.sync { lastStatus = .noClaudeCode; minted = nil }
            return .unauthorized
        case .ok(let cc):
            if cc.expiresAt > Date() {
                queue.sync { lastStatus = .ok }
                return .valid(cc.accessToken)
            }
            if !cc.refreshToken.isEmpty {
                switch refreshGrant(cc.refreshToken) {
                case .success(let fresh):
                    // Claude Code's grant, so nothing is persisted — the minted
                    // token lives in memory for this run only.
                    queue.sync { minted = fresh; lastStatus = .ok }
                    return .valid(fresh.accessToken)
                case .network:
                    return .transient
                case .rejected:
                    break
                }
            }
            queue.sync { lastStatus = .expired; minted = nil }
            return .unauthorized
        }
    }

    // MARK: Connect (PKCE, manual code paste)

    /// Opens the authorize page in the default browser. The user pastes the code
    /// back into `completeSignIn`.
    func beginSignIn() {
        let verifier = Self.randomURLSafe(43)
        let state = Self.randomURLSafe(32)
        pendingVerifier = verifier
        pendingState = state
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectUri),
            .init(name: "scope", value: "org:create_api_key user:profile user:inference"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)
    }

    /// Returns an error message, or nil on success.
    func completeSignIn(pastedCode: String) -> String? {
        guard let verifier = pendingVerifier else { return "No sign-in in progress" }
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? ""
        let state = parts.count > 1 ? parts[1] : (pendingState ?? "")
        guard !code.isEmpty else { return "Empty code" }

        switch tokenGrant(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "code_verifier": verifier,
        ], priorRefresh: "") {
        case .success(let t):
            saveOwnTokens(t)
            pendingVerifier = nil
            pendingState = nil
            queue.sync {
                minted = nil
                cachedLimits = nil
                backoff = 0
                fetchFailing = false
                lastStatus = .ok
                nextFetchAllowed = .distantPast
                nextPoll = .distantPast
            }
            return nil
        case .rejected:
            return "Claude rejected the code — try connecting again"
        case .network:
            return "Could not reach Claude — check your connection and try again"
        }
    }

    private static func randomURLSafe(_ len: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var out = ""
        for _ in 0..<len {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
    }

    // MARK: Usage limits

    /// nil = no readable Claude Code login; `status` then says why. On a transient
    /// failure the previous good limits are returned marked stale, so the menu bar
    /// keeps showing percentages instead of dropping to the local-log fallback.
    func fetchLimits(force: Bool = false) -> LimitsSnapshot? {
        let now = Date()
        // Resolve credentials before the rate-limit gate: it costs one Keychain
        // read, and it's what sets `status`. Gating first would leave the menu
        // unable to say why it has nothing to show.
        let token: String
        switch validAccessToken() {
        case .unauthorized:
            queue.sync { cachedLimits = nil }
            return nil
        case .transient:
            // Keep the last good bars and let the next poll retry.
            queue.sync {
                fetchFailing = true
                nextPoll = Date().addingTimeInterval(pollInterval)
            }
            return cached()?.markedStale()
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: true)
        case .valid(let t):
            token = t
        }

        let (cached, gated, failing) = queue.sync {
            (cachedLimits, now < nextFetchAllowed || (!force && now < nextPoll), fetchFailing)
        }
        if gated {
            // No cached bars yet just means "nothing fetched yet" — still not a
            // reason to send a request we know is gated.
            return cached?.markedStale(failing)
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: failing)
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, status, headers) = Self.syncRequest(req)

        if status == 401 || status == 403 {
            // The minted token was rejected; drop it so the next poll re-refreshes
            // from the Keychain, and pace the retries.
            NSLog("usage fetch unauthorized (HTTP \(status))")
            queue.sync {
                lastStatus = .expired
                minted = nil
                cachedLimits = nil
                nextPoll = Date().addingTimeInterval(pollInterval)
            }
            return nil
        }
        guard let data, status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200)
            noteFailure(status: status, headers: headers, detail: "HTTP \(status): \(body)")
            return cached?.markedStale()
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: true)
        }

        let fresh = LimitsSnapshot(bars: Self.parseLimits(obj), fetchedAt: Date(), stale: false)
        NSLog("limits fetched: \(fresh.bars.count) bars")
        queue.sync {
            backoff = 0
            // A 200 whose shape we can't parse is still a failure to get data;
            // keep the stale marker on so the menu shows "as of HH:MM".
            fetchFailing = fresh.bars.isEmpty
            nextFetchAllowed = Date().addingTimeInterval(fetchFloor)
            nextPoll = Date().addingTimeInterval(pollInterval)
            if !fresh.bars.isEmpty { cachedLimits = fresh }
        }
        guard !fresh.bars.isEmpty else {
            // An unrecognized-but-successful response shouldn't discard good bars.
            return cached?.markedStale()
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: true)
        }
        LimitTracker.shared.record(fresh.bars, at: fresh.fetchedAt)
        return fresh
    }

    /// Records a transient failure: polling backs off (exponentially, honoring
    /// Retry-After), but only an actual 429 hard-gates user-initiated refreshes —
    /// for other failures a manual retry after `fetchFloor` is harmless.
    private func noteFailure(status: Int, headers: [AnyHashable: Any], detail: String) {
        let wait = max(Self.retryAfter(headers) ?? 0, backOff())
        queue.sync {
            fetchFailing = true
            nextPoll = Date().addingTimeInterval(wait)
            nextFetchAllowed = Date().addingTimeInterval(status == 429 ? min(wait, 3600) : fetchFloor)
        }
        NSLog("usage fetch failed (\(detail)), retrying in \(Int(wait))s")
    }

    /// Doubles the backoff from `pollInterval` up to `maxBackoff`.
    private func backOff() -> TimeInterval {
        queue.sync {
            backoff = backoff == 0 ? pollInterval : min(backoff * 2, maxBackoff)
            return backoff
        }
    }

    private static func retryAfter(_ headers: [AnyHashable: Any]) -> TimeInterval? {
        for (k, v) in headers where (k as? String)?.lowercased() == "retry-after" {
            if let s = v as? String, let secs = TimeInterval(s) { return max(secs, 1) }
        }
        return nil
    }

    /// Preferred shape: top-level "limits" array of
    /// {kind, percent, resets_at, scope:{model:{display_name}}}.
    static func parseLimitsArray(_ arr: [[String: Any]]) -> [LimitBar] {
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [LimitBar] = []
        for item in arr {
            guard let raw = item["percent"] as? Double, raw.isFinite, raw <= 101 else { continue }
            let percent = min(max(raw, 0), 100)
            let kind = (item["kind"] as? String) ?? ""
            let scopeName = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let label: String
            let short: String
            switch kind {
            case "session": label = "5-hour limit"; short = "5h"
            case "weekly_all": label = "Weekly · all models"; short = "Wk"
            case "weekly_scoped":
                let name = scopeName ?? "scoped"
                label = "Weekly · \(name)"
                short = String(name.prefix(1))
            default:
                label = kind.replacingOccurrences(of: "_", with: " ")
                short = String(label.prefix(1))
            }
            var resets: Date? = nil
            if let s = item["resets_at"] as? String {
                resets = isoFrac.date(from: s) ?? iso.date(from: s)
            }
            out.append(LimitBar(kind: kind, scopeName: scopeName, label: label,
                                shortLabel: short, percent: percent, resetsAt: resets))
        }
        return out
    }

    /// Tolerant fallback parser: accepts {key: {utilization, resets_at}} with
    /// utilization as 0–1 or 0–100, at the top level or nested one dict deep.
    static func parseLimits(_ obj: [String: Any]) -> [LimitBar] {
        if let arr = obj["limits"] as? [[String: Any]] {
            let bars = parseLimitsArray(arr)
            if !bars.isEmpty { return bars }
        }
        let labels: [(String, String, String)] = [
            ("five_hour", "5-hour limit", "5h"),
            ("seven_day", "Weekly · all models", "Wk"),
            ("seven_day_sonnet", "Weekly · Sonnet", "S"),
            ("seven_day_opus", "Weekly · Opus", "O"),
            ("seven_day_fable", "Weekly · Fable", "F"),
            ("seven_day_oauth_apps", "Weekly · OAuth apps", "A"),
        ]
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func bar(_ key: String, _ label: String, _ short: String, _ dict: [String: Any]) -> LimitBar? {
            guard let pct = Statusline.cleanPercent(dict["utilization"]) else { return nil }
            var resets: Date? = nil
            if let s = dict["resets_at"] as? String {
                resets = isoFrac.date(from: s) ?? iso.date(from: s)
            } else if let n = dict["resets_at"] as? Double {
                resets = Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
            }
            return LimitBar(kind: key, scopeName: nil, label: label,
                            shortLabel: short, percent: pct, resetsAt: resets)
        }

        func scan(_ dict: [String: Any]) -> [LimitBar] {
            var out: [LimitBar] = []
            for (key, label, short) in labels {
                if let sub = dict[key] as? [String: Any], let b = bar(key, label, short, sub) {
                    out.append(b)
                }
            }
            // unknown keys with the same shape (future limits)
            let known = Set(labels.map { $0.0 })
            for (key, val) in dict {
                if !known.contains(key), let sub = val as? [String: Any] {
                    let label = key.replacingOccurrences(of: "_", with: " ")
                    if let b = bar(key, label, String(label.prefix(1)), sub) {
                        out.append(b)
                    }
                }
            }
            return out
        }

        var bars = scan(obj)
        if bars.isEmpty {
            for (_, val) in obj {
                if let sub = val as? [String: Any] {
                    bars.append(contentsOf: scan(sub))
                }
            }
        }
        return bars
    }

    // MARK: Helpers

    private static func syncRequest(_ req: URLRequest) -> (Data?, Int, [AnyHashable: Any]) {
        var outData: Data?
        var outStatus = 0
        var outHeaders: [AnyHashable: Any] = [:]
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            outData = data
            let http = resp as? HTTPURLResponse
            outStatus = http?.statusCode ?? 0
            outHeaders = http?.allHeaderFields ?? [:]
            sem.signal()
        }.resume()
        sem.wait()
        return (outData, outStatus, outHeaders)
    }
}

// MARK: - Official limits via Claude Code's statusline (local, no network, no token)

/// Claude Code (v2.1.80+) pipes a session JSON — including `rate_limits` — to the
/// configured statusline command on stdin. If the user points that command at
/// `Halo --statusline`, we capture those *official* percentages to a local file
/// and read them back, with zero network calls and no OAuth token. This is the
/// safest source: it doesn't touch the undocumented usage endpoint at all.
enum Statusline {
    /// Where the captured rate_limits are cached between the statusline process
    /// and the running app.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".halo/statusline.json")
    }

    /// How long a capture is trusted as "fresh official" data. The statusline
    /// only fires when the user prompts Claude Code; while idle, usage isn't
    /// climbing, so a slightly stale capture is still accurate until its reset.
    static let ttl: TimeInterval = 30 * 60

    /// `Halo --statusline`: read Claude Code's JSON from stdin, stash the
    /// rate_limits, and print a compact status line back. Fast, no AppKit.
    static func capture() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]

        // Persist rate_limits (if this Claude Code version provides them).
        if let rl = root?["rate_limits"] as? [String: Any] {
            let payload: [String: Any] = ["captured_at": Date().timeIntervalSince1970,
                                          "rate_limits": rl]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                try? FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        // Print a useful one-liner so the user's status line still shows something.
        var parts: [String] = []
        if let model = (root?["model"] as? [String: Any])?["display_name"] as? String {
            parts.append(model)
        }
        if let rl = root?["rate_limits"] as? [String: Any],
           let five = rl["five_hour"] as? [String: Any],
           let pct = cleanPercent(five["used_percentage"]) {
            parts.append(String(format: "◔ 5h %.0f%%", pct))
        }
        FileHandle.standardOutput.write(Data((parts.joined(separator: "  ·  ")).utf8))
    }

    /// Official bars from the last capture, or nil if absent/stale/unconfigured.
    static func read(now: Date = Date()) -> [LimitBar]? {
        guard let data = try? Data(contentsOf: fileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let capturedAt = root["captured_at"] as? Double,
              now.timeIntervalSince1970 - capturedAt < ttl,
              let rl = root["rate_limits"] as? [String: Any] else { return nil }

        let windows: [(String, String, String)] = [
            ("five_hour", "5-hour limit", "5h"),
            ("seven_day", "Weekly · all models", "Wk"),
        ]
        var bars: [LimitBar] = []
        for (key, label, short) in windows {
            guard let w = rl[key] as? [String: Any],
                  let pct = cleanPercent(w["used_percentage"]) else { continue }
            let resets = epochDate(w["resets_at"])
            // A window past its reset has rolled over; show it as fresh (0%).
            let rolled = resets.map { $0 <= now } ?? false
            bars.append(LimitBar(kind: key, scopeName: nil, label: label, shortLabel: short,
                                 percent: rolled ? 0 : pct,
                                 resetsAt: rolled ? nil : resets, source: .official))
        }
        return bars.isEmpty ? nil : bars
    }

    /// Guards against a known Claude bug where used_percentage can leak the
    /// resets_at epoch (a huge number). Accepts 0–1 fractions or 0–100 percents.
    static func cleanPercent(_ raw: Any?) -> Double? {
        guard let d = raw as? Double, d.isFinite else { return nil }
        let v = (d > 0 && d <= 1) ? d * 100 : d
        guard v <= 101 else { return nil }   // epoch leak / nonsense
        return min(max(v, 0), 100)
    }

    static func epochDate(_ raw: Any?) -> Date? {
        guard let n = raw as? Double, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
    }
}

// MARK: - Local limit estimate (fallback when no official/live data is available)

/// When neither the statusline nor the usage endpoint is available, estimate the
/// 5-hour utilization from local logs: active-block tokens ÷ a plan cap. The cap
/// self-calibrates from your own peak sessions (P90) so it isn't a blind guess.
enum LocalEstimate {
    /// Known per-5h token ceilings across tiers; used to recognize a session that
    /// actually hit a limit, and as sane defaults.
    static let ladder: [Int] = [19_000, 88_000, 220_000, 880_000]
    static let defaultCap = 88_000   // ~Max 5x, a middle-of-the-road assumption

    /// 90th-percentile cap from completed blocks that nearly maxed out; falls back
    /// to the P90 of all completed blocks, then to a ladder default.
    static func calibratedCap(blocks: [BlockStats], activeTokens: Int) -> Int {
        let completed = blocks.dropLast().map { $0.stats.totalTokens }.filter { $0 > 0 }
        let hitLimit = completed.filter { t in ladder.contains { t >= Int(Double($0) * 0.95) } }
        let sample = hitLimit.isEmpty ? completed : hitLimit
        guard let p90 = percentile90(sample) else {
            // No history: pick the smallest ladder rung above the current block.
            return ladder.first { $0 >= activeTokens } ?? max(activeTokens, defaultCap)
        }
        return max(p90, activeTokens)
    }

    static func percentile90(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * 0.9).rounded())
        return sorted[min(idx, sorted.count - 1)]
    }

    /// A single estimated 5-hour bar, or nil if there's no active block.
    static func bars(allBlocks: [BlockStats], now: Date) -> [LimitBar] {
        guard let active = allBlocks.last, now < active.end,
              let last = active.stats.entries.last,
              now.timeIntervalSince(last.timestamp) < 5 * 3600 else { return [] }
        let cap = calibratedCap(blocks: allBlocks, activeTokens: active.stats.totalTokens)
        let pct = min(100, Double(active.stats.totalTokens) / Double(max(cap, 1)) * 100)
        return [LimitBar(kind: "five_hour", scopeName: nil, label: "5-hour limit (estimated)",
                         shortLabel: "5h", percent: pct, resetsAt: active.end, source: .estimated)]
    }
}

// MARK: - Usage snapshot

struct SessionSummary {
    let project: String
    let model: String          // short name of the latest turn's model
    let contextTokens: Int     // latest turn's prompt size — resent every message
    let costToday: Double
}

/// One advisory line for the Insights section.
struct Insight {
    enum Severity { case info, warn, alert }
    let severity: Severity
    let text: String

    /// Context sizes worth flagging — the whole context is re-sent every turn.
    static func contextSeverity(_ tokens: Int) -> Severity? {
        switch tokens {
        case 160_000...: return .alert
        case 120_000...: return .warn
        default: return nil
        }
    }
}

struct Snapshot {
    var limits: LimitsSnapshot?    // nil = no readable Claude Code login
    /// Why `limits` is nil, phrased for the menu.
    var limitsHint: String?
    var block: BlockStats?
    var today: Stats
    var week: Stats
    var sessions: [SessionSummary] = []
    var insights: [Insight] = []
    var hourCosts: [Double] = []   // today's cost per hour, index 0 = midnight
}

enum UsageMath {
    /// Active 5-hour billing block (ccusage algorithm: block start = first entry's
    /// timestamp floored to the hour; a block ends 5h after start or after a 5h gap).
    static func allBlocks(entries: [UsageEntry]) -> [BlockStats] {
        var blocks: [BlockStats] = []
        var block: BlockStats? = nil
        for e in entries {
            if var b = block {
                let gap = b.stats.entries.last.map { e.timestamp.timeIntervalSince($0.timestamp) > 5 * 3600 } ?? false
                if e.timestamp >= b.end || gap {
                    blocks.append(b)
                    block = BlockStats(start: floorToHour(e.timestamp), stats: Stats(entries: [e]))
                } else {
                    b.stats.entries.append(e)
                    block = b
                }
            } else {
                block = BlockStats(start: floorToHour(e.timestamp), stats: Stats(entries: [e]))
            }
        }
        if let b = block { blocks.append(b) }
        return blocks
    }

    static func activeBlock(entries: [UsageEntry], now: Date) -> BlockStats? {
        guard let b = allBlocks(entries: entries).last, now < b.end,
              let last = b.stats.entries.last,
              now.timeIntervalSince(last.timestamp) < 5 * 3600 else { return nil }
        return b
    }

    /// Sessions with activity in the last 30 minutes, largest context first.
    /// Single pass; entries must be in chronological order.
    static func activeSessions(entries: [UsageEntry], now: Date) -> [SessionSummary] {
        let dayStart = Calendar.current.startOfDay(for: now)
        struct Acc {
            var last: UsageEntry
            var lastMain: UsageEntry?  // latest non-sidechain turn
            var costToday: Double
        }
        var bySession: [String: Acc] = [:]
        for e in entries where !e.sessionId.isEmpty {
            let cost = e.timestamp >= dayStart ? Pricing.cost(for: e) : 0
            if var a = bySession[e.sessionId] {
                a.last = e
                if !e.isSidechain { a.lastMain = e }
                a.costToday += cost
                bySession[e.sessionId] = a
            } else {
                bySession[e.sessionId] = Acc(last: e, lastMain: e.isSidechain ? nil : e, costToday: cost)
            }
        }
        var out: [SessionSummary] = []
        for (_, a) in bySession {
            guard now.timeIntervalSince(a.last.timestamp) < 30 * 60 else { continue }
            // Context = the main thread's latest turn; subagent turns are smaller
            // side contexts and would understate it.
            let mainLast = a.lastMain ?? a.last
            out.append(SessionSummary(
                project: a.last.project,
                model: Pricing.shortName(mainLast.model),
                contextTokens: mainLast.contextTokens,
                costToday: a.costToday
            ))
        }
        return Array(out.sorted { $0.contextTokens > $1.contextTokens }.prefix(5))
    }

    /// Cost rate of the last 15 minutes vs the rest of today's average rate.
    /// Returns (recent $/hr, multiple of today's pace, top project driving it).
    static func spike(today: [UsageEntry], todayCost: Double, now: Date)
        -> (perHour: Double, ratio: Double, driver: String)? {
        guard let first = today.first else { return nil }
        let elapsedMin = now.timeIntervalSince(first.timestamp) / 60
        guard elapsedMin >= 60 else { return nil }   // too early for a meaningful baseline
        var recentCost = 0.0
        var byProject: [String: Double] = [:]
        for e in today where now.timeIntervalSince(e.timestamp) <= 15 * 60 {
            let c = Pricing.cost(for: e)
            recentCost += c
            byProject[e.project, default: 0] += c
        }
        guard recentCost >= 1.0 else { return nil }
        // Exclude the window under test from its own baseline, otherwise a real
        // burst inflates the baseline and understates the ratio.
        let baselinePerMin = (todayCost - recentCost) / (elapsedMin - 15)
        let recentPerMin = recentCost / 15
        guard baselinePerMin > 0, recentPerMin / baselinePerMin >= 2 else { return nil }
        let driver = byProject.max { $0.value < $1.value }?.key ?? "?"
        return (recentPerMin * 60, recentPerMin / baselinePerMin, driver)
    }

    static func insights(sessions: [SessionSummary], today: Stats, limits: [LimitBar],
                         todayEntries: [UsageEntry], now: Date) -> [Insight] {
        var out: [Insight] = []
        let todayCost = today.cost

        if let s = spike(today: todayEntries, todayCost: todayCost, now: now) {
            out.append(Insight(severity: s.ratio >= 4 ? .alert : .warn, text: String(
                format: "Usage spike: ~%@/hr, %.0f× today's pace (%@)", money(s.perHour), s.ratio, s.driver)))
        }

        for s in sessions {
            if let severity = Insight.contextSeverity(s.contextTokens) {
                out.append(Insight(severity: severity,
                    text: "\(s.project): context \(compactTokens(s.contextTokens)) — /clear or /compact to cut cost"))
            }
        }

        for bar in limits {
            if let hit = LimitTracker.shared.projectedHit(bar, now: now) {
                out.append(Insight(severity: .warn,
                    text: "On pace to hit \(bar.label) ~\(timeHM(hit)), before it resets"))
            }
        }

        let models = today.byModel
        if todayCost >= 5, let top = models.first,
           Pricing.rate(for: top.0).input >= 15, top.2 / todayCost >= 0.8 {
            let pct = Int((top.2 / todayCost * 100).rounded())
            out.append(Insight(severity: .info,
                text: "\(top.0) is \(pct)% of today's cost — Sonnet/Haiku for lighter tasks stretches limits"))
        }
        return out
    }

    static func snapshot(reader: UsageReader, now: Date, forceLimits: Bool = false) -> Snapshot {
        let weekStart = now.addingTimeInterval(-7 * 24 * 3600)
        let all = reader.entries(since: weekStart)
        let dayStart = Calendar.current.startOfDay(for: now)
        let todayEntries = all.filter { $0.timestamp >= dayStart }
        let sessions = activeSessions(entries: all, now: now)
        let today = Stats(entries: todayEntries)

        let blocks = allBlocks(entries: all)
        let block: BlockStats? = {
            guard let b = blocks.last, now < b.end,
                  let last = b.stats.entries.last,
                  now.timeIntervalSince(last.timestamp) < 5 * 3600 else { return nil }
            return b
        }()

        // Limits, best source first: Claude Code's own statusline hand-off (local,
        // no token, no endpoint), then the OAuth usage endpoint, then a local
        // estimate — so the rings keep working even if the endpoint breaks.
        var limits: LimitsSnapshot?
        var limitsHint: String?
        if let official = Statusline.read(now: now) {
            limits = LimitsSnapshot(bars: official, fetchedAt: now, stale: false)
            LimitTracker.shared.record(official, at: now)
        } else {
            let live = ClaudeAccount.shared.fetchLimits(force: forceLimits)
            if let live, !live.bars.isEmpty {
                limits = live
            } else {
                let est = LocalEstimate.bars(allBlocks: blocks, now: now)
                if !est.isEmpty {
                    limits = LimitsSnapshot(bars: est, fetchedAt: now, stale: false)
                    LimitTracker.shared.record(est, at: now)
                } else {
                    limits = live   // nil/empty — keep the endpoint's status & hint
                    limitsHint = ClaudeAccount.shared.status.hint
                }
            }
        }

        var hourCosts = [Double](repeating: 0, count: 24)
        for e in todayEntries {
            let h = Calendar.current.component(.hour, from: e.timestamp)
            hourCosts[h] += Pricing.cost(for: e)
        }

        return Snapshot(
            limits: limits,
            limitsHint: limitsHint,
            block: block,
            today: today,
            week: Stats(entries: all),
            sessions: sessions,
            insights: insights(sessions: sessions, today: today, limits: limits?.bars ?? [],
                               todayEntries: todayEntries, now: now),
            hourCosts: hourCosts
        )
    }

    static func floorToHour(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }
}

// MARK: - Formatting

func compactTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...: return String(format: "%.0fk", Double(n) / 1_000)
    default: return "\(n)"
    }
}

func money(_ d: Double) -> String { String(format: "$%.2f", d) }

/// DateFormatter construction is expensive; cache the two formats we use.
let hmFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
}()
let weekdayHMFormatter: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "EEE HH:mm"; return f
}()

func timeHM(_ d: Date) -> String { hmFormatter.string(from: d) }

// MARK: - Limit gauge views

/// Green / orange / red by how close a percentage is to its limit.
func limitColor(_ percent: Double) -> NSColor {
    switch percent {
    case ..<70: return .systemGreen
    case ..<90: return .systemOrange
    default: return .systemRed
    }
}

func shortResetText(_ d: Date) -> String {
    let interval = d.timeIntervalSinceNow
    if interval <= 0 { return "resets soon" }
    if interval < 24 * 3600 {
        let h = Int(interval) / 3600, m = (Int(interval) % 3600) / 60
        return h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
    }
    return weekdayHMFormatter.string(from: d)
}

/// Strokes a circular progress ring: full track plus an arc from 12 o'clock,
/// clockwise, tinted by `limitColor`. Shared by the menu gauges and the
/// status bar icon so the two can't drift apart.
func strokeRing(center: NSPoint, radius: CGFloat, lineWidth: CGFloat, percent: Double) {
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setStroke()
    track.stroke()

    let pct = min(max(percent, 0), 100)
    if pct > 0 {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius,
                      startAngle: 90, endAngle: 90 - 3.6 * pct, clockwise: true)
        arc.lineWidth = lineWidth
        arc.lineCapStyle = .round
        limitColor(pct).setStroke()
        arc.stroke()
    }
}

/// A row of circular progress gauges, one per limit.
final class RingGaugesView: NSView {
    private let bars: [LimitBar]
    private let cellWidth: CGFloat = 90

    init(_ bars: [LimitBar]) {
        self.bars = bars
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: max(280, CGFloat(bars.count) * 90),
                                 height: 96))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let totalWidth = CGFloat(bars.count) * cellWidth
        var x = (bounds.width - totalWidth) / 2
        for bar in bars {
            drawGauge(bar, in: NSRect(x: x, y: 0, width: cellWidth, height: bounds.height))
            x += cellWidth
        }
    }

    private func drawGauge(_ bar: LimitBar, in rect: NSRect) {
        strokeRing(center: NSPoint(x: rect.midX, y: rect.minY + 62),
                   radius: 24, lineWidth: 5.5, percent: bar.percent)

        // Centered, truncating inside the cell so long model names can't
        // spill into the neighboring gauge.
        func drawCentered(_ s: String, y: CGFloat, font: NSFont, color: NSColor) {
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            (s as NSString).draw(
                in: NSRect(x: rect.minX + 2, y: y, width: rect.width - 4, height: font.pointSize + 5),
                withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        }

        drawCentered(String(format: "%.0f%%", bar.percent), y: rect.minY + 53,
                     font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                     color: .labelColor)
        drawCentered(bar.displayName, y: rect.minY + 17,
                     font: .systemFont(ofSize: 11, weight: .medium), color: .labelColor)
        if let resets = bar.resetsAt {
            drawCentered(shortResetText(resets), y: rect.minY + 3,
                         font: .systemFont(ofSize: 9.5), color: .secondaryLabelColor)
        }
    }
}

/// Today's spend by hour as a mini bar chart; the current hour is highlighted.
final class HourBarsView: NSView {
    private let costs: [Double]
    private let currentHour: Int

    init(hourCosts: [Double], now: Date) {
        // Show midnight through the current hour.
        self.currentHour = Calendar.current.component(.hour, from: now)
        self.costs = Array(hourCosts.prefix(currentHour + 1))
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 46))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let chartWidth = bounds.width - inset * 2
        let maxCost = max(costs.max() ?? 0, 0.01)
        let barArea: CGFloat = 28
        let n = max(costs.count, 6)
        let step = chartWidth / CGFloat(n)
        let barWidth = max(step - 2, 2)

        for (i, c) in costs.enumerated() {
            guard c > 0 else { continue }
            let h = max(barArea * CGFloat(c / maxCost), 1.5)
            let r = NSRect(x: inset + CGFloat(i) * step, y: 4, width: barWidth, height: h)
            let color: NSColor = i == currentHour ? .controlAccentColor
                                                  : .controlAccentColor.withAlphaComponent(0.55)
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 1.5, yRadius: 1.5).fill()
        }

        let peak = "peak \(money(maxCost))/h" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let w = peak.size(withAttributes: attrs).width
        peak.draw(at: NSPoint(x: bounds.width - inset - w, y: bounds.height - 12), withAttributes: attrs)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let reader = UsageReader()
    private var timer: Timer?
    private var loadingTimer: Timer?
    private var loadingDots = 0
    // UsageReader's cache is not thread-safe; all refreshes go through this serial queue.
    private let refreshQueue = DispatchQueue(label: "com.mathiasbesil.halo.refresh", qos: .utility)

    private enum TitleMode: String, CaseIterable {
        case both, tokens, cost
        var label: String {
            switch self {
            case .both: return "Tokens + cost"
            case .tokens: return "Tokens only"
            case .cost: return "Cost only"
            }
        }
    }
    private var titleMode: TitleMode {
        get { TitleMode(rawValue: UserDefaults.standard.string(forKey: "titleMode") ?? "") ?? .both }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "titleMode") }
    }

    /// How the plan limits appear in the menu bar itself.
    private enum LimitStyle: String, CaseIterable {
        case all, worst
        var label: String {
            switch self {
            case .all: return "All limits"
            case .worst: return "Worst limit only"
            }
        }
    }
    private var limitStyle: LimitStyle {
        get { LimitStyle(rawValue: UserDefaults.standard.string(forKey: "limitStyle") ?? "") ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "limitStyle") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        startLoadingAnimation()
        // A populated menu from the first frame, so the icon is clickable while
        // the first fetch (Keychain read + network) is still in flight — render()
        // swaps in the real content, or the Connect button, once it lands.
        statusItem.menu = loadingMenu()
        UNUserNotificationCenter.current().delegate = self
        if LimitNotifier.shared.enabled { LimitNotifier.shared.requestAuthorization() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// Show banners even though a menu bar app technically counts as frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func refreshClicked() { refresh(forceLimits: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setTitleMode(_ sender: NSMenuItem) {
        if let mode = TitleMode(rawValue: sender.representedObject as? String ?? "") {
            titleMode = mode
            refresh()
        }
    }

    @objc private func setLimitStyle(_ sender: NSMenuItem) {
        if let style = LimitStyle(rawValue: sender.representedObject as? String ?? "") {
            limitStyle = style
            refresh()
        }
    }

    @objc private func toggleNotifications() {
        LimitNotifier.shared.enabled.toggle()
        if LimitNotifier.shared.enabled { LimitNotifier.shared.requestAuthorization() }
        refresh()
    }

    @objc private func toggleNotifyKind(_ sender: NSMenuItem) {
        if let kind = NotifyKind(rawValue: sender.representedObject as? String ?? "") {
            kind.enabled.toggle()
            refresh()
        }
    }

    @objc private func explain() {
        let alert = NSAlert()
        alert.messageText = "What am I looking at?"
        alert.informativeText = """
        RINGS — how much of each Claude plan rate limit you've used, straight from \
        your account (the same numbers as claude.ai's usage page). "5-hour" is the \
        rolling session limit, "Weekly" covers all models, and a model-named ring \
        (e.g. Fable) is that model's own weekly limit. Each ring fills clockwise and \
        turns orange at 70% and red at 90%; the time under it is when it resets. \
        100% means Claude stops answering until the reset.

        There's no sign-in: Halo reads the login Claude Code already keeps in your \
        Keychain, which is why macOS asked your permission once. Nothing is sent \
        anywhere except your own request to Anthropic for those percentages.

        CURRENT 5-HOUR SESSION — tokens and estimated cost of your ongoing Claude \
        Code activity, read from the local logs in ~/.claude. "Burn rate" is tokens \
        per minute in this window.

        INSIGHTS — automatic tips: usage spikes, sessions whose context has grown \
        huge (run /clear or /compact there), being on pace to hit a limit before it \
        resets, and expensive-model-heavy days.

        TODAY / LAST 7 DAYS — local totals. Cost is what this usage would cost at \
        list API prices — on a Pro/Max subscription you don't actually pay it; it's \
        a sense of scale, and of what each limit window "buys" you.

        NOTIFICATIONS — four kinds, each switchable on its own: passing 80% / 95% \
        of a limit, being on pace to hit one before it resets, a window about to \
        reset with capacity still unused (spend it or lose it), and a spent limit \
        rolling over. Each fires at most once per limit per window.
        """
        alert.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func signIn() {
        ClaudeAccount.shared.beginSignIn()

        let alert = NSAlert()
        alert.messageText = "Connect to Claude"
        alert.informativeText = "Your browser opened claude.ai. Approve access, then paste the code shown there here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste authorization code"
        alert.accessoryView = field
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = field.stringValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = ClaudeAccount.shared.completeSignIn(pastedCode: code)
            DispatchQueue.main.async {
                if let error {
                    let fail = NSAlert()
                    fail.messageText = "Connection failed"
                    fail.informativeText = error
                    fail.runModal()
                } else {
                    self?.refresh(forceLimits: true)
                }
            }
        }
    }

    @objc private func disconnect() {
        ClaudeAccount.shared.disconnect()
        refresh()
    }

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// The shell command Claude Code should run as its status line.
    private static var statuslineCommand: String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'\(exe)' --statusline"
    }

    /// True when Claude Code's settings already point its status line at Halo.
    static func statuslineConfigured() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = (root["statusLine"] as? [String: Any])?["command"] as? String else { return false }
        return cmd.contains("--statusline") && cmd.contains(".app/Contents/MacOS/")
    }

    /// Points Claude Code's status line at `Halo --statusline` so it hands us its
    /// official limits locally. Explicit opt-in, with confirmation and a backup.
    @objc private func enableOfficialLimits() {
        let url = Self.claudeSettingsURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        let existing = (root["statusLine"] as? [String: Any])?["command"] as? String

        if Self.statuslineConfigured() {
            let a = NSAlert()
            a.messageText = "Official limits are already on"
            a.informativeText = "Claude Code is already handing its official usage limits to Halo. Nothing to change."
            a.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true); a.runModal(); return
        }

        let alert = NSAlert()
        alert.messageText = "Use Claude Code's official limits?"
        var body = "This adds a statusLine entry to ~/.claude/settings.json so Claude Code hands its official 5-hour and weekly limits to Halo — locally, with no network call and no token. It's the most reliable source.\n\nRestart your Claude Code sessions afterward for it to take effect."
        if let existing, !existing.isEmpty {
            body += "\n\n⚠️ You already have a custom status line:\n\(existing)\nIt will be replaced (a backup is saved to settings.json.bak)."
        }
        alert.informativeText = body
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let data = try? Data(contentsOf: url) {
            try? data.write(to: url.appendingPathExtension("bak"))
        }
        root["statusLine"] = ["type": "command", "command": Self.statuslineCommand, "padding": 0]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url, options: .atomic)
        }
        refresh()

        let done = NSAlert()
        done.messageText = "Official limits enabled"
        done.informativeText = "Run a prompt in Claude Code (or restart its sessions) so it starts sending limits to Halo. The rings switch to “official” automatically."
        done.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); done.runModal()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("launch-at-login toggle failed: \(error)")
        }
        refresh()
    }

    /// `forceLimits` bypasses the limits-fetch rate limit; only user-initiated
    /// refreshes set it, so the 60s timer can't hammer the endpoint into a 429.
    private func refresh(forceLimits: Bool = false) {
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let snap = UsageMath.snapshot(reader: self.reader, now: now, forceLimits: forceLimits)
            DispatchQueue.main.async { self.render(snap, now: now) }
        }
    }

    private func render(_ snap: Snapshot, now: Date) {
        stopLoadingAnimation()   // real data has landed; drop the "Halo…" placeholder
        let menu = NSMenu()

        // Account limit gauges (like claude.ai's usage popup)
        let bars = snap.limits.map { $0.bars } ?? []
        if bars.isEmpty { statusItem.button?.image = nil }
        if let limits = snap.limits, !bars.isEmpty {
            setStatusTitle(bars)
            if !limits.stale { LimitNotifier.shared.check(bars, now: now) }

            let source = bars.first?.source ?? .live
            let headerText: String
            switch source {
            case .estimated: headerText = "Plan usage limits  (estimated)"
            case .official, .live:
                headerText = limits.stale
                    ? "Plan usage limits  (as of \(timeHM(limits.fetchedAt)))"
                    : "Plan usage limits"
            }
            menu.addItem(header(headerText))
            let subtitle: String
            switch source {
            case .official: subtitle = "Official, straight from Claude Code — no account fetch"
            case .live:     subtitle = "How much of each plan limit you've used — resets at the time shown"
            case .estimated: subtitle = "Estimated from your local logs — live limits are unavailable"
            }
            menu.addItem(coloredInfo([(subtitle, .secondaryLabelColor)], size: 11))
            let rings = NSMenuItem()
            rings.view = RingGaugesView(bars)
            menu.addItem(rings)
            menu.addItem(.separator())
        } else if snap.limits == nil {
            if let hint = snap.limitsHint {
                menu.addItem(coloredInfo([(hint, .secondaryLabelColor)], size: 12))
            }
            let connect = NSMenuItem(title: "Connect to Claude…", action: #selector(signIn), keyEquivalent: "")
            connect.target = self
            menu.addItem(connect)
            menu.addItem(.separator())
        } else {
            // Credentials are fine and the first fetch hasn't landed yet; say so
            // rather than leaving the section silently absent.
            menu.addItem(coloredInfo([("Fetching plan limits…", .secondaryLabelColor)], size: 12))
            menu.addItem(.separator())
        }

        if !snap.insights.isEmpty {
            menu.addItem(header("Insights"))
            for insight in snap.insights {
                menu.addItem(coloredInfo([
                    ("● ", Self.severityColor(insight.severity)),
                    (insight.text, .labelColor),
                ], size: 12))
            }
            menu.addItem(.separator())
        }

        if !snap.sessions.isEmpty {
            menu.addItem(header("Active sessions"))
            for s in snap.sessions {
                let ctxColor = Insight.contextSeverity(s.contextTokens)
                    .map(Self.severityColor) ?? .secondaryLabelColor
                menu.addItem(coloredInfo([
                    ("   \(s.project)", .labelColor),
                    ("  \(s.model)", .secondaryLabelColor),
                    ("  ctx \(compactTokens(s.contextTokens))", ctxColor),
                    ("  \(money(s.costToday)) today", .secondaryLabelColor),
                ], size: 12))
            }
            menu.addItem(.separator())
        }

        if let b = snap.block {
            let s = b.stats
            if bars.isEmpty {
                switch titleMode {
                case .both: statusItem.button?.title = "Halo \(compactTokens(s.totalTokens)) · \(money(s.cost))"
                case .tokens: statusItem.button?.title = "Halo \(compactTokens(s.totalTokens))"
                case .cost: statusItem.button?.title = "Halo \(money(s.cost))"
                }
            }

            menu.addItem(header("Current 5-hour session  (\(timeHM(b.start))–\(timeHM(b.end)))"))
            menu.addItem(info("Tokens: \(compactTokens(s.totalTokens))   Cost: \(money(s.cost))"))
            let io = info("In \(compactTokens(s.inputTokens)) · Out \(compactTokens(s.outputTokens)) · CacheW \(compactTokens(s.cacheCreationTokens)) · CacheR \(compactTokens(s.cacheReadTokens))")
            io.toolTip = "Input / output tokens, plus prompt-cache writes and reads (cache reads are ~10× cheaper than input)"
            menu.addItem(io)

            let elapsed = now.timeIntervalSince(b.start)
            let remaining = max(0, b.end.timeIntervalSince(now))
            if elapsed > 60 {
                let perMin = Double(s.totalTokens) / (elapsed / 60)
                menu.addItem(info(String(format: "Burn rate: %@/min   Resets in %dh %02dm",
                                         compactTokens(Int(perMin)), Int(remaining) / 3600, (Int(remaining) % 3600) / 60)))
            }
            addModelBreakdown(s, to: menu)
        } else {
            if bars.isEmpty {
                statusItem.button?.title = "Halo idle"
            }
            menu.addItem(header("No active 5h block"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Today"))
        menu.addItem(info("Tokens: \(compactTokens(snap.today.totalTokens))   Cost: \(money(snap.today.cost))"))
        if snap.today.cost > 0 {
            let chart = NSMenuItem()
            chart.view = HourBarsView(hourCosts: snap.hourCosts, now: now)
            menu.addItem(chart)
        }
        addModelBreakdown(snap.today, to: menu)

        menu.addItem(.separator())
        menu.addItem(header("Last 7 days"))
        menu.addItem(info("Tokens: \(compactTokens(snap.week.totalTokens))   Cost: \(money(snap.week.cost))"))

        menu.addItem(.separator())
        let display = NSMenuItem(title: "Menu bar shows", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for style in LimitStyle.allCases {
            let i = NSMenuItem(title: style.label, action: #selector(setLimitStyle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = style.rawValue
            i.state = (style == limitStyle) ? .on : .off
            sub.addItem(i)
        }
        sub.addItem(.separator())
        // No action → auto-disabled, acts as a section label.
        sub.addItem(NSMenuItem(title: "When limits are unavailable:", action: nil, keyEquivalent: ""))
        for mode in TitleMode.allCases {
            let i = NSMenuItem(title: mode.label, action: #selector(setTitleMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = mode.rawValue
            i.state = (mode == titleMode) ? .on : .off
            sub.addItem(i)
        }
        display.submenu = sub
        menu.addItem(display)

        let notify = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let nsub = NSMenu()
        let master = NSMenuItem(title: "Enable notifications",
                                action: #selector(toggleNotifications), keyEquivalent: "")
        master.target = self
        master.state = LimitNotifier.shared.enabled ? .on : .off
        nsub.addItem(master)
        nsub.addItem(.separator())
        for kind in NotifyKind.allCases {
            let i = NSMenuItem(title: kind.label, action: #selector(toggleNotifyKind(_:)), keyEquivalent: "")
            // Leave them visible but inert when the master switch is off, so it's
            // clear what would fire if it were on.
            i.target = LimitNotifier.shared.enabled ? self : nil
            i.representedObject = kind.rawValue
            i.state = kind.enabled ? .on : .off
            i.toolTip = kind.detail
            nsub.addItem(i)
        }
        notify.submenu = nsub
        menu.addItem(notify)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        let official = NSMenuItem(title: "Use Claude Code's official limits",
                                  action: #selector(enableOfficialLimits), keyEquivalent: "")
        official.target = self
        official.state = Self.statuslineConfigured() ? .on : .off
        official.toolTip = "Reads limits from Claude Code locally (no network, no token) — the most reliable source."
        menu.addItem(official)

        if snap.limits != nil {
            let out = NSMenuItem(title: "Disconnect from Claude", action: #selector(disconnect), keyEquivalent: "")
            out.target = self
            out.toolTip = "Removes Halo's own connection. Claude Code's login is never touched."
            menu.addItem(out)
        }

        menu.addItem(.separator())
        let help = NSMenuItem(title: "What do these numbers mean?", action: #selector(explain), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let r = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); q.target = self
        menu.addItem(q)

        statusItem.menu = menu
    }

    private static func severityColor(_ s: Insight.Severity) -> NSColor {
        switch s {
        case .info: return .systemBlue
        case .warn: return .systemOrange
        case .alert: return .systemRed
        }
    }

    private static let modelDots: [String: NSColor] = [
        "Fable": .systemPurple, "Opus": .systemIndigo,
        "Sonnet": .systemBlue, "Haiku": .systemTeal,
    ]

    private func addModelBreakdown(_ s: Stats, to menu: NSMenu) {
        let models = s.byModel
        guard models.count > 1 || (models.first.map { $0.0 != "unknown" } ?? false) else { return }
        for (name, tokens, cost) in models {
            menu.addItem(coloredInfo([
                ("   ● ", Self.modelDots[name] ?? .systemGray),
                ("\(name): ", .labelColor),
                ("\(compactTokens(tokens)) · \(money(cost))", .secondaryLabelColor),
            ], size: 13))
        }
    }

    /// Sets the status bar to one colored progress ring per limit, each
    /// followed by its label and percentage, tinted once it approaches the
    /// limit.
    private func setStatusTitle(_ bars: [LimitBar]) {
        // Rings live inline in the attributed title (one per limit), so the
        // standalone button image is unused.
        statusItem.button?.image = nil

        let shown: [LimitBar]
        switch limitStyle {
        case .all: shown = bars
        case .worst: shown = bars.max { $0.percent < $1.percent }.map { [$0] } ?? []
        }

        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for (i, bar) in shown.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "  ")) }

            let attachment = NSTextAttachment()
            attachment.image = Self.ringIcon(percent: bar.percent)
            // Center the 15pt ring on the 12pt text's visual middle.
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - 15) / 2, width: 15, height: 15)
            title.append(NSAttributedString(attachment: attachment))

            // Tint only when worth noticing; default color otherwise so the
            // status bar stays quiet-looking at normal usage.
            let color: NSColor = bar.percent >= 70 ? limitColor(bar.percent) : .labelColor
            title.append(NSAttributedString(
                string: String(format: " %@ %.0f%%", bar.shortLabel, bar.percent),
                attributes: [.font: font, .foregroundColor: color, .baselineOffset: -0.5]))
        }
        statusItem.button?.attributedTitle = title
    }

    private static func ringIcon(percent: Double) -> NSImage {
        let size: CGFloat = 15
        // A drawing-handler image re-renders per destination appearance, so the
        // dynamic colors resolve against the menu bar's light/dark mode instead
        // of being baked in at refresh time.
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            strokeRing(center: NSPoint(x: size / 2, y: size / 2),
                       radius: 5.5, lineWidth: 2.5, percent: percent)
            return true
        }
    }

    /// Animated "Halo…" in the menu bar while the first snapshot is in flight.
    private func startLoadingAnimation() {
        loadingDots = 0
        statusItem.button?.title = "Halo"
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.loadingDots = (self.loadingDots + 1) % 4
            self.statusItem.button?.title = "Halo" + String(repeating: ".", count: self.loadingDots)
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    /// Placeholder menu shown before the first snapshot lands, so a fresh launch
    /// is never a blank, unclickable icon.
    private func loadingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(header("Halo for Claude"))
        menu.addItem(coloredInfo([("Loading usage… macOS may ask to read Claude Code's login.",
                                   .secondaryLabelColor)], size: 12))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func header(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        return i
    }
    private func info(_ s: String) -> NSMenuItem { NSMenuItem(title: s, action: nil, keyEquivalent: "") }

    private func coloredInfo(_ parts: [(String, NSColor)], size: CGFloat) -> NSMenuItem {
        let str = NSMutableAttributedString()
        for (text, color) in parts {
            str.append(NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: color,
            ]))
        }
        let i = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        i.attributedTitle = str
        return i
    }
}

// `Halo --statusline`: Claude Code invokes this per prompt, piping session JSON
// (with official rate_limits) on stdin. Capture and exit before any AppKit setup.
if CommandLine.arguments.contains("--statusline") {
    Statusline.capture()
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
