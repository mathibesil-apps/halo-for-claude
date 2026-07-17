import AppKit
import CryptoKit
import Foundation
import ServiceManagement

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
        return name.isEmpty ? "unknown" : name
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
        if m.contains("opus") || m.contains("fable") || m.contains("mythos") {
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
        for name in ["fable", "mythos", "opus", "sonnet", "haiku"] where m.contains(name) {
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

struct LimitBar {
    let kind: String           // stable identity from the API, e.g. "session", "weekly_all"
    let scopeName: String?     // model display name for scoped limits
    let label: String
    let shortLabel: String     // for the menu bar title, e.g. "5h", "W", "F"
    let percent: Double        // 0–100
    let resetsAt: Date?

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
    private let queue = DispatchQueue(label: "com.mathiasbesil.claude-usage.limittracker")
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

final class ClaudeAccount {
    static let shared = ClaudeAccount()
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirectUri = "https://console.anthropic.com/oauth/code/callback"
    private let keychainService = "com.mathiasbesil.claude-usage"
    private let queue = DispatchQueue(label: "com.mathiasbesil.claude-usage.oauth")

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }
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
    private let fetchFloor: TimeInterval = 5
    private let pollInterval: TimeInterval = 120
    private let maxBackoff: TimeInterval = 15 * 60

    // MARK: Keychain

    private func loadTokens() -> Tokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private func saveTokens(_ t: Tokens) {
        guard let data = try? JSONEncoder().encode(t) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func signOut() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ] as CFDictionary)
        resetFetchState()
    }

    /// Clears cache, backoff, and gates — auth state changed, old pacing is moot.
    private func resetFetchState() {
        queue.sync {
            cachedLimits = nil
            backoff = 0
            fetchFailing = false
            nextFetchAllowed = .distantPast
            nextPoll = .distantPast
        }
    }

    var isSignedIn: Bool { loadTokens() != nil }

    // MARK: Sign-in (PKCE, manual code paste)

    /// Opens the authorize page in the default browser; returns nothing.
    /// Call `completeSignIn(pastedCode:)` with the code the user pastes back.
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

    func completeSignIn(pastedCode: String) -> String? {
        guard let verifier = pendingVerifier else { return "No sign-in in progress" }
        let trimmed = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts.first ?? ""
        let state = parts.count > 1 ? parts[1] : (pendingState ?? "")
        guard !code.isEmpty else { return "Empty code" }

        var body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientId,
            "redirect_uri": redirectUri,
            "code_verifier": verifier,
        ]
        switch postToken(body: &body) {
        case .success(let t):
            saveTokens(t)
            pendingVerifier = nil
            pendingState = nil
            resetFetchState()
            return nil
        case .failure(let err):
            return err.message
        }
    }

    private struct OAuthError: Error {
        let message: String
        let status: Int
        /// True when the server rejected the credentials themselves, as opposed
        /// to a network blip / outage / rate limit.
        var isAuthRejection: Bool { (400...403).contains(status) }
    }

    private func postToken(body: inout [String: Any]) -> Result<Tokens, OAuthError> {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, status, _) = Self.syncRequest(req)
        guard let data, status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let detail = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200)
            return .failure(OAuthError(message: "Token request failed (HTTP \(status)): \(detail)",
                                       status: status))
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return .success(Tokens(
            accessToken: access,
            refreshToken: (obj["refresh_token"] as? String) ?? "",
            expiresAt: Date().addingTimeInterval(expiresIn - 60)
        ))
    }

    // MARK: Access token with refresh

    private enum TokenResult {
        case valid(String)
        case transient      // network blip / outage — credentials may still be fine
        case unauthorized   // no tokens, or the server rejected them
    }

    private func validAccessToken() -> TokenResult {
        queue.sync { () -> TokenResult in
            guard var t = loadTokens() else { return .unauthorized }
            if t.expiresAt > Date() { return .valid(t.accessToken) }
            guard !t.refreshToken.isEmpty else { return .unauthorized }
            var body: [String: Any] = [
                "grant_type": "refresh_token",
                "refresh_token": t.refreshToken,
                "client_id": clientId,
            ]
            switch postToken(body: &body) {
            case .success(let fresh):
                var merged = fresh
                if merged.refreshToken.isEmpty { merged.refreshToken = t.refreshToken }
                saveTokens(merged)
                t = merged
                return .valid(t.accessToken)
            case .failure(let err):
                NSLog("token refresh failed: \(err.message)")
                return err.isAuthRejection ? .unauthorized : .transient
            }
        }
    }

    // MARK: Usage limits

    /// nil = not signed in / auth failed. On a transient failure the previous good
    /// limits are returned marked stale, so the menu bar keeps showing percentages
    /// instead of silently dropping to the local-log fallback.
    func fetchLimits(force: Bool = false) -> LimitsSnapshot? {
        guard isSignedIn else {
            queue.sync { cachedLimits = nil }
            return nil
        }
        let now = Date()
        let (cached, gated, failing) = queue.sync {
            (cachedLimits, now < nextFetchAllowed || (!force && now < nextPoll), fetchFailing)
        }
        if gated {
            // No cached bars yet just means "signed in, nothing fetched" — still not
            // a reason to send a request we know is gated.
            return cached?.markedStale(failing)
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: failing)
        }

        let token: String
        switch validAccessToken() {
        case .unauthorized:
            return nil
        case .transient:
            // Credentials are probably fine; keep showing the last good bars and
            // back off the polling instead of hammering the token endpoint.
            noteFailure(status: 0, headers: [:], detail: "token refresh unreachable")
            return cached?.markedStale()
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: true)
        case .valid(let t):
            token = t
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, status, headers) = Self.syncRequest(req)

        if status == 401 || status == 403 {
            NSLog("usage fetch unauthorized (HTTP \(status))")
            return nil
        }
        guard let data, status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let body = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200)
            noteFailure(status: status, headers: headers, detail: "HTTP \(status): \(body)")
            return cached?.markedStale()
                ?? LimitsSnapshot(bars: [], fetchedAt: now, stale: true)
        }

        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "lastUsageJSON")
        let fresh = LimitsSnapshot(bars: Self.parseLimits(obj), fetchedAt: Date(), stale: false)
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
            guard let percent = item["percent"] as? Double else { continue }
            let kind = (item["kind"] as? String) ?? ""
            let scopeName = ((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
            let label: String
            let short: String
            switch kind {
            case "session": label = "5-hour limit"; short = "5h"
            case "weekly_all": label = "Weekly · all models"; short = "W"
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
            ("seven_day", "Weekly · all models", "W"),
            ("seven_day_sonnet", "Weekly · Sonnet", "S"),
            ("seven_day_opus", "Weekly · Opus", "O"),
            ("seven_day_fable", "Weekly · Fable", "F"),
            ("seven_day_oauth_apps", "Weekly · OAuth apps", "A"),
        ]
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        func bar(_ key: String, _ label: String, _ short: String, _ dict: [String: Any]) -> LimitBar? {
            guard let raw = dict["utilization"] as? Double else { return nil }
            let pct = raw <= 1.0 ? raw * 100 : raw
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

    private static func randomURLSafe(_ len: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var out = ""
        for _ in 0..<len {
            out.append(chars[Int.random(in: 0..<chars.count)])
        }
        return out
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
    var limits: LimitsSnapshot?    // nil = not signed in / auth failed
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
    static func activeBlock(entries: [UsageEntry], now: Date) -> BlockStats? {
        var block: BlockStats? = nil
        for e in entries {
            if var b = block {
                let gap = b.stats.entries.last.map { e.timestamp.timeIntervalSince($0.timestamp) > 5 * 3600 } ?? false
                if e.timestamp >= b.end || gap {
                    block = BlockStats(start: floorToHour(e.timestamp), stats: Stats(entries: [e]))
                } else {
                    b.stats.entries.append(e)
                    block = b
                }
            } else {
                block = BlockStats(start: floorToHour(e.timestamp), stats: Stats(entries: [e]))
            }
        }
        guard let b = block, now < b.end,
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
        let limits = ClaudeAccount.shared.fetchLimits(force: forceLimits)
        let sessions = activeSessions(entries: all, now: now)
        let today = Stats(entries: todayEntries)

        var hourCosts = [Double](repeating: 0, count: 24)
        for e in todayEntries {
            let h = Calendar.current.component(.hour, from: e.timestamp)
            hourCosts[h] += Pricing.cost(for: e)
        }

        return Snapshot(
            limits: limits,
            block: activeBlock(entries: all, now: now),
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let reader = UsageReader()
    private var timer: Timer?
    // UsageReader's cache is not thread-safe; all refreshes go through this serial queue.
    private let refreshQueue = DispatchQueue(label: "com.mathiasbesil.claude-usage.refresh", qos: .utility)

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"
        statusItem.menu = NSMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func refreshClicked() { refresh(forceLimits: true) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setTitleMode(_ sender: NSMenuItem) {
        if let mode = TitleMode(rawValue: sender.representedObject as? String ?? "") {
            titleMode = mode
            refresh()
        }
    }

    @objc private func signIn() {
        ClaudeAccount.shared.beginSignIn()

        let alert = NSAlert()
        alert.messageText = "Sign in to Claude"
        alert.informativeText = "Your browser opened claude.ai. Approve access, then paste the code shown here."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "Paste authorization code"
        alert.accessoryView = field
        alert.addButton(withTitle: "Sign in")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = field.stringValue

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = ClaudeAccount.shared.completeSignIn(pastedCode: code)
            DispatchQueue.main.async {
                if let error {
                    let fail = NSAlert()
                    fail.messageText = "Sign-in failed"
                    fail.informativeText = error
                    fail.runModal()
                } else {
                    self?.refresh(forceLimits: true)
                }
            }
        }
    }

    @objc private func signOut() {
        ClaudeAccount.shared.signOut()
        refresh()
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
        let menu = NSMenu()

        // Account limit gauges (like claude.ai's usage popup)
        let bars = snap.limits.map { $0.bars } ?? []
        if bars.isEmpty { statusItem.button?.image = nil }
        if let limits = snap.limits, !bars.isEmpty {
            setStatusTitle(bars)

            menu.addItem(header(limits.stale
                ? "Plan usage limits  (as of \(timeHM(limits.fetchedAt)))"
                : "Plan usage limits"))
            let rings = NSMenuItem()
            rings.view = RingGaugesView(bars)
            menu.addItem(rings)
            menu.addItem(.separator())
        } else if snap.limits == nil {
            let s = NSMenuItem(title: "Sign in to Claude for usage limits…",
                               action: #selector(signIn), keyEquivalent: "")
            s.target = self
            menu.addItem(s)
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
                case .both: statusItem.button?.title = "CC \(compactTokens(s.totalTokens)) · \(money(s.cost))"
                case .tokens: statusItem.button?.title = "CC \(compactTokens(s.totalTokens))"
                case .cost: statusItem.button?.title = "CC \(money(s.cost))"
                }
            }

            menu.addItem(header("Current 5h block  (\(timeHM(b.start))–\(timeHM(b.end)))"))
            menu.addItem(info("Tokens: \(compactTokens(s.totalTokens))   Cost: \(money(s.cost))"))
            menu.addItem(info("In \(compactTokens(s.inputTokens)) · Out \(compactTokens(s.outputTokens)) · CacheW \(compactTokens(s.cacheCreationTokens)) · CacheR \(compactTokens(s.cacheReadTokens))"))

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
                statusItem.button?.title = "CC idle"
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
        for mode in TitleMode.allCases {
            let i = NSMenuItem(title: mode.label, action: #selector(setTitleMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = mode.rawValue
            i.state = (mode == titleMode) ? .on : .off
            sub.addItem(i)
        }
        display.submenu = sub
        menu.addItem(display)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        if ClaudeAccount.shared.isSignedIn {
            let out = NSMenuItem(title: "Sign out of Claude", action: #selector(signOut), keyEquivalent: "")
            out.target = self
            menu.addItem(out)
        }

        menu.addItem(.separator())
        menu.addItem(info("Cost is estimated from list API pricing"))
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
        "Fable": .systemPurple, "Mythos": .systemPurple, "Opus": .systemIndigo,
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

        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        for (i, bar) in bars.enumerated() {
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
