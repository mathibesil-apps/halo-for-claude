import AppKit
import CryptoKit
import Foundation
import ServiceManagement
import SwiftUI
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

// MARK: - Service selection

/// Which coding agent Halo is currently monitoring. Kept as a single global
/// choice so the menu bar, local-log reader, account client, and notifications
/// always describe the same account.
enum UsageProvider: String, CaseIterable {
    case claude, codex

    static var current: UsageProvider {
        UsageProvider(rawValue: UserDefaults.standard.string(forKey: "usageProvider") ?? "") ?? .claude
    }

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var shortLabel: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
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
    /// Claude and Codex report cached input differently. This lets the shared
    /// stats/UI use the right total without double-counting Codex cached tokens.
    let provider: UsageProvider

    init(timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
         cacheCreationTokens: Int, cacheReadTokens: Int, dedupeKey: String,
         sessionId: String, cwd: String, isSidechain: Bool,
         provider: UsageProvider = .claude) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.dedupeKey = dedupeKey
        self.sessionId = sessionId
        self.cwd = cwd
        self.isSidechain = isSidechain
        self.provider = provider
    }

    var totalTokens: Int {
        switch provider {
        case .claude: return inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
        case .codex: return inputTokens + outputTokens
        }
    }
    /// Approximate context size of this turn: everything the model was sent.
    var contextTokens: Int {
        switch provider {
        case .claude: return inputTokens + cacheCreationTokens + cacheReadTokens
        case .codex: return inputTokens
        }
    }
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
        return agg.map { ($0.key, $0.value.0, $0.value.1) }.sorted {
            $0.2 == $1.2 ? $0.1 > $1.1 : $0.2 > $1.2
        }
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
        for name in ["astra", "sol", "terra", "luna", "spark", "fable", "opus", "sonnet", "haiku"] where m.contains(name) {
            return name.capitalized
        }
        return model.isEmpty ? "unknown" : model
    }

    static func cost(for e: UsageEntry) -> Double {
        // ChatGPT-plan Codex consumption is governed by rate-limit percentages
        // and credits, not by the Anthropic API list-price approximation below.
        guard e.provider == .claude else { return 0 }
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

// MARK: - Codex JSONL parsing

/// Reads Codex's local rollout files. Each `token_count` event contains the
/// usage of the last model request as well as a cumulative total; using
/// `last_token_usage` means tool loops count correctly without repeatedly
/// adding the cumulative value. Cached input is a subset of Codex input, so it
/// is exposed for the breakdown but not added again to `totalTokens`.
final class CodexUsageReader {
    private let roots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return [home.appendingPathComponent("sessions"),
                home.appendingPathComponent("archived_sessions")]
    }()

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

    func entries(since cutoff: Date) -> [UsageEntry] {
        var result: [UsageEntry] = []
        var liveFiles = Set<String>()

        for root in roots {
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }

            for case let url as URL in en {
                guard url.pathExtension == "jsonl" else { continue }
                guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = vals.contentModificationDate else { continue }
                if mtime < cutoff { continue }

                let path = url.path
                let size = vals.fileSize ?? 0
                liveFiles.insert(path)
                let fileEntries: [UsageEntry]
                if let cached = cache[path], cached.mtime == mtime, cached.size == size {
                    fileEntries = cached.entries
                } else {
                    fileEntries = parseFile(url)
                    cache[path] = CachedFile(mtime: mtime, size: size, entries: fileEntries)
                }
                result.append(contentsOf: fileEntries.filter { $0.timestamp >= cutoff })
            }
        }

        for key in cache.keys where !liveFiles.contains(key) { cache.removeValue(forKey: key) }

        var seen = Set<String>()
        return result.sorted {
            $0.timestamp == $1.timestamp ? $0.dedupeKey < $1.dedupeKey : $0.timestamp < $1.timestamp
        }.filter { $0.dedupeKey.isEmpty || seen.insert($0.dedupeKey).inserted }
    }

    private func parseFile(_ url: URL) -> [UsageEntry] {
        guard let data = FileManager.default.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return [] }

        var sessionId = url.deletingPathExtension().lastPathComponent
        var cwd = ""
        var model = ""
        var sidechain = false
        var out: [UsageEntry] = []

        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String,
                  let payload = obj["payload"] as? [String: Any] else { continue }

            switch type {
            case "session_meta":
                sessionId = (payload["id"] as? String)
                    ?? (payload["session_id"] as? String)
                    ?? sessionId
                cwd = (payload["cwd"] as? String) ?? cwd
                // Root sessions use a string source (cli/vscode); subagents use
                // a tagged object such as {subagent:{...}}.
                sidechain = payload["source"] is [String: Any]

            case "turn_context":
                model = (payload["model"] as? String) ?? model
                cwd = (payload["cwd"] as? String) ?? cwd

            case "event_msg":
                guard payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let usage = info["last_token_usage"] as? [String: Any],
                      let tsString = obj["timestamp"] as? String,
                      let timestamp = parseDate(tsString) else { continue }

                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cached = usage["cached_input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_write_input_tokens"] as? Int ?? 0
                guard input > 0 || output > 0 else { continue }

                let ordinal = (obj["ordinal"] as? Int).map(String.init)
                    ?? ((info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int).map(String.init)
                    ?? tsString
                out.append(UsageEntry(
                    timestamp: timestamp,
                    model: model,
                    inputTokens: input,
                    outputTokens: output,
                    cacheCreationTokens: cacheWrite,
                    cacheReadTokens: cached,
                    dedupeKey: "\(sessionId):\(ordinal)",
                    sessionId: sessionId,
                    cwd: cwd,
                    isSidechain: sidechain,
                    provider: .codex
                ))

            default:
                continue
            }
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
    var provider: UsageProvider = .claude

    /// Persistence key for history tracking; stable across label wording changes.
    var trackerKey: String {
        let local = scopeName.map { "\(kind):\($0)" } ?? kind
        return "\(provider.rawValue):\(local)"
    }

    /// Short name under a ring gauge.
    var displayName: String {
        if provider == .codex {
            let window: String = {
                if label.hasPrefix("5-hour") { return "5h" }
                if label.hasPrefix("Weekly") { return "Wk" }
                if let dot = label.range(of: " · ") { return String(label[..<dot.lowerBound]) }
                return label.replacingOccurrences(of: " limit", with: "")
            }()
            if let scopeName {
                let parsed = Pricing.shortName(scopeName)
                let model = parsed != scopeName ? parsed
                    : (scopeName.lowercased().contains("reserve") ? "Reserve" : scopeName)
                return "\(model) \(window)"
            }
            return window
        }
        switch kind {
        case "session", "five_hour": return "5-hour"
        case "weekly_all", "seven_day": return "Weekly"
        default:
            if let scopeName {
                let short = Pricing.shortName(scopeName)
                if short != scopeName { return short }
                if scopeName.lowercased().contains("reserve") { return "Reserve" }
                return scopeName
            }
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
            // Drop series for limits this provider no longer reports, while
            // retaining the other provider's history across service switches.
            let liveKeys = Set(bars.map { $0.trackerKey })
            let providerPrefixes = Set(bars.map { $0.provider.rawValue + ":" })
            series = series.filter { key, _ in
                !providerPrefixes.contains(where: { key.hasPrefix($0) }) || liveKeys.contains(key)
            }
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
        (bar.kind == "session" || bar.kind == "five_hour" || bar.label.hasPrefix("5-hour"))
            ? 30 * 60 : 60 * 60
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
    /// True when a browser sign-in isn't needed: Halo's own grant or Claude Code's
    /// login is present and either unexpired or refreshable. Local read, no network.
    func hasUsableLogin() -> Bool {
        if let own = loadOwnTokens(), own.expiresAt > Date() || !own.refreshToken.isEmpty {
            return true
        }
        if case .ok(let cc) = loadCredentials(), cc.expiresAt > Date() || !cc.refreshToken.isEmpty {
            return true
        }
        return false
    }

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

// MARK: - Codex account usage via the official app-server protocol

struct CodexDailyUsage {
    let startDate: String
    let tokens: Int
}

struct CodexAccountUsage {
    var lifetimeTokens: Int?
    var peakDailyTokens: Int?
    var longestRunningTurnSec: Int?
    var currentStreakDays: Int?
    var longestStreakDays: Int?
    var daily: [CodexDailyUsage] = []
    var planType: String?
    var creditBalance: String?
}

struct CodexAccountSnapshot {
    var limits: LimitsSnapshot?
    var usage: CodexAccountUsage?
    var hint: String?
}

/// Starts Codex's documented JSON-RPC app server over stdio and asks it for
/// account rate limits and token activity. Codex owns and refreshes its login;
/// Halo never reads `~/.codex/auth.json` or handles a ChatGPT access token.
final class CodexAccount {
    static let shared = CodexAccount()

    private var cachedLimits: LimitsSnapshot?
    private var cachedUsage: CodexAccountUsage?
    private var nextPoll = Date.distantPast
    private let pollInterval: TimeInterval = 120

    private init() {}

    func fetch(force: Bool = false) -> CodexAccountSnapshot {
        let now = Date()
        if !force, now < nextPoll, cachedLimits != nil || cachedUsage != nil {
            return CodexAccountSnapshot(limits: cachedLimits, usage: cachedUsage, hint: nil)
        }
        nextPoll = now.addingTimeInterval(pollInterval)

        guard let executable = Self.codexExecutable() else {
            return CodexAccountSnapshot(
                limits: cachedLimits?.markedStale(), usage: cachedUsage,
                hint: "Codex CLI not found — install or open Codex, then refresh")
        }

        switch Self.run(executable: executable) {
        case .failure(let message):
            NSLog("Codex usage fetch failed: \(message)")
            return CodexAccountSnapshot(
                limits: cachedLimits?.markedStale(), usage: cachedUsage,
                hint: cachedLimits == nil ? "Codex usage unavailable — sign in to Codex and try again" : nil)

        case .success(let responses):
            var freshLimits: LimitsSnapshot?
            var freshUsage = cachedUsage

            if let rateResult = responses[1]?["result"] as? [String: Any] {
                let bars = Self.parseRateLimits(rateResult)
                if !bars.isEmpty {
                    freshLimits = LimitsSnapshot(bars: bars, fetchedAt: now, stale: false)
                    cachedLimits = freshLimits
                    LimitTracker.shared.record(bars, at: now)
                }
            }
            if let usageResult = responses[2]?["result"] as? [String: Any] {
                var usage = Self.parseUsage(usageResult)
                Self.addAccountDetails(from: responses[1]?["result"] as? [String: Any], to: &usage)
                freshUsage = usage
                cachedUsage = usage
            } else if var usage = freshUsage {
                Self.addAccountDetails(from: responses[1]?["result"] as? [String: Any], to: &usage)
                freshUsage = usage
                cachedUsage = usage
            }

            let limits = freshLimits ?? cachedLimits?.markedStale()
            let hasError = responses[1]?["error"] != nil || responses[2]?["error"] != nil
            let hint = (limits == nil && hasError)
                ? "Codex account usage unavailable — check that Codex is signed in with ChatGPT"
                : nil
            return CodexAccountSnapshot(limits: limits, usage: freshUsage, hint: hint)
        }
    }

    private static func codexExecutable() -> URL? {
        var candidates: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["CODEX_CLI_PATH"], !explicit.isEmpty {
            candidates.append(explicit)
        }
        candidates.append(contentsOf: [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ])
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }
        return candidates.lazy
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Responses are keyed by their JSON-RPC id. Notifications and diagnostics
    /// are ignored, and stderr is discarded so a model-catalog warning cannot
    /// fill a pipe and stall the account requests.
    private static func run(executable: URL) -> Result<[Int: [String: Any]], Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() }
        catch { return .failure(error) }

        let messages: [[String: Any]] = [
            ["method": "initialize", "id": 0, "params": [
                "clientInfo": ["name": "halo_usage", "title": "Halo Usage", "version": "0.1.0"]]],
            ["method": "initialized", "params": [:]],
            ["method": "account/rateLimits/read", "id": 1, "params": [:]],
            ["method": "account/usage/read", "id": 2, "params": [:]],
        ]
        let stateQueue = DispatchQueue(label: "com.mathiasbesil.halo.codex-response")
        let completed = DispatchSemaphore(value: 0)
        var buffer = Data()
        var responses: [Int: [String: Any]] = [:]
        var didSignal = false
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stateQueue.sync {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let id = obj["id"] as? Int else { continue }
                    responses[id] = obj
                }
                if responses[1] != nil, responses[2] != nil, !didSignal {
                    didSignal = true
                    completed.signal()
                }
            }
        }

        for message in messages {
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { continue }
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }
        _ = completed.wait(timeout: .now() + 15)
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        let finalResponses = stateQueue.sync { responses }
        guard finalResponses[1] != nil || finalResponses[2] != nil else {
            return .failure(CodexAccountError.invalidResponse)
        }
        return .success(finalResponses)
    }

    private enum CodexAccountError: LocalizedError {
        case invalidResponse
        var errorDescription: String? { "app-server returned no account response" }
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let number = raw as? NSNumber { return number.intValue }
        return nil
    }

    private static func double(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func parseRateLimits(_ result: [String: Any]) -> [LimitBar] {
        var buckets: [(String, [String: Any])] = []
        if let byId = result["rateLimitsByLimitId"] as? [String: Any] {
            for (id, raw) in byId {
                if let bucket = raw as? [String: Any] { buckets.append((id, bucket)) }
            }
        } else if let bucket = result["rateLimits"] as? [String: Any] {
            buckets.append(((bucket["limitId"] as? String) ?? "codex", bucket))
        }

        struct WindowBar {
            let bar: LimitBar
            let general: Bool
            let minutes: Int
            let scope: String
        }
        var parsed: [WindowBar] = []
        for (fallbackId, bucket) in buckets {
            let limitId = (bucket["limitId"] as? String) ?? fallbackId
            let rawName = bucket["limitName"] as? String
            let scope = Self.scopeName(limitId: limitId, limitName: rawName)
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any],
                      let percent = double(window["usedPercent"]), percent.isFinite,
                      let minutes = int(window["windowDurationMins"]) else { continue }

                let windowLabel = Self.windowLabel(minutes)
                let windowShort = Self.windowShortLabel(minutes)
                let label = scope.map { "\(windowLabel) · \($0)" } ?? "\(windowLabel) limit"
                let short: String
                if let scope {
                    let model = Pricing.shortName(scope)
                    let compact = model == scope ? Self.abbreviation(scope) : model
                    short = "\(compact) \(windowShort)"
                } else {
                    short = windowShort
                }
                let reset = double(window["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                let bar = LimitBar(
                    kind: "codex.\(limitId).\(slot).\(minutes)",
                    scopeName: scope,
                    label: label,
                    shortLabel: short,
                    percent: min(max(percent, 0), 100),
                    resetsAt: reset,
                    source: .official,
                    provider: .codex)
                parsed.append(WindowBar(bar: bar, general: scope == nil,
                                        minutes: minutes, scope: scope ?? ""))
            }
        }
        return parsed.sorted {
            if $0.general != $1.general { return $0.general && !$1.general }
            if $0.scope != $1.scope { return $0.scope.localizedCaseInsensitiveCompare($1.scope) == .orderedAscending }
            return $0.minutes < $1.minutes
        }.map(\.bar)
    }

    /// Null names on the main `codex` bucket mean the account-wide limit. Other
    /// buckets retain the server's display name so new model families appear
    /// automatically without an app update.
    private static func scopeName(limitId: String, limitName: String?) -> String? {
        if let name = limitName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if limitId == "codex" { return nil }
        return limitId.replacingOccurrences(of: "codex_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private static func abbreviation(_ name: String) -> String {
        if name.lowercased().contains("reserve") { return "Res" }
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if let last = words.last, last.count >= 2 { return String(last.prefix(3)).capitalized }
        return String(name.prefix(3)).capitalized
    }

    private static func windowLabel(_ minutes: Int) -> String {
        switch minutes {
        case 300: return "5-hour"
        case 10_080: return "Weekly"
        case let m where m % 1_440 == 0: return "\(m / 1_440)-day"
        case let m where m % 60 == 0: return "\(m / 60)-hour"
        default: return "\(minutes)-minute"
        }
    }

    private static func windowShortLabel(_ minutes: Int) -> String {
        switch minutes {
        case 300: return "5h"
        case 10_080: return "Wk"
        case let m where m % 1_440 == 0: return "\(m / 1_440)d"
        case let m where m % 60 == 0: return "\(m / 60)h"
        default: return "\(minutes)m"
        }
    }

    private static func parseUsage(_ result: [String: Any]) -> CodexAccountUsage {
        let summary = result["summary"] as? [String: Any]
        var daily: [CodexDailyUsage] = []
        if let buckets = result["dailyUsageBuckets"] as? [[String: Any]] {
            for bucket in buckets {
                if let date = bucket["startDate"] as? String, let tokens = int(bucket["tokens"]) {
                    daily.append(CodexDailyUsage(startDate: date, tokens: tokens))
                }
            }
        }
        return CodexAccountUsage(
            lifetimeTokens: int(summary?["lifetimeTokens"]),
            peakDailyTokens: int(summary?["peakDailyTokens"]),
            longestRunningTurnSec: int(summary?["longestRunningTurnSec"]),
            currentStreakDays: int(summary?["currentStreakDays"]),
            longestStreakDays: int(summary?["longestStreakDays"]),
            daily: daily)
    }

    private static func addAccountDetails(from result: [String: Any]?, to usage: inout CodexAccountUsage) {
        guard let result else { return }
        let main = (result["rateLimits"] as? [String: Any])
            ?? ((result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any])
        usage.planType = main?["planType"] as? String
        usage.creditBalance = (main?["credits"] as? [String: Any])?["balance"] as? String
    }
}

// MARK: - Where the limit rings get their data

/// How the user wants the plan-limit % sourced. Stored in UserDefaults so both
/// the menu (AppDelegate) and the snapshot math (UsageMath) can read it.
enum LimitsSource: String, CaseIterable {
    case auto, local, token

    static var current: LimitsSource {
        LimitsSource(rawValue: UserDefaults.standard.string(forKey: "limitsSource") ?? "") ?? .auto
    }

    var label: String {
        switch self {
        case .auto:  return "Automatic (recommended)"
        case .local: return "Local — no token, no network"
        case .token: return "Anthropic account (token)"
        }
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
    let id: String
    let project: String
    let model: String          // short name of the latest turn's model
    let contextTokens: Int     // latest turn's prompt size — resent every message
    let costToday: Double
    let tokensToday: Int
}

/// One advisory line for the Insights section.
struct Insight {
    enum Severity { case info, warn, alert }
    let severity: Severity
    let text: String

    /// A content-derived identifier remains stable while the same advisory is
    /// displayed, while a changed recommendation is correctly a new row.
    var id: String { "\(String(describing: severity)):\(text)" }

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
    var provider: UsageProvider = .claude
    var codexAccountUsage: CodexAccountUsage?
    var hourValuesAreTokens = false
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
            var tokensToday: Int
        }
        var bySession: [String: Acc] = [:]
        for e in entries where !e.sessionId.isEmpty {
            let cost = e.timestamp >= dayStart ? Pricing.cost(for: e) : 0
            let tokens = e.timestamp >= dayStart ? e.totalTokens : 0
            if var a = bySession[e.sessionId] {
                a.last = e
                if !e.isSidechain { a.lastMain = e }
                a.costToday += cost
                a.tokensToday += tokens
                bySession[e.sessionId] = a
            } else {
                bySession[e.sessionId] = Acc(last: e, lastMain: e.isSidechain ? nil : e,
                                              costToday: cost, tokensToday: tokens)
            }
        }
        var out: [SessionSummary] = []
        for (sessionId, a) in bySession {
            guard now.timeIntervalSince(a.last.timestamp) < 30 * 60 else { continue }
            // Context = the main thread's latest turn; subagent turns are smaller
            // side contexts and would understate it.
            let mainLast = a.lastMain ?? a.last
            out.append(SessionSummary(
                id: sessionId,
                project: a.last.project,
                model: Pricing.shortName(mainLast.model),
                contextTokens: mainLast.contextTokens,
                costToday: a.costToday,
                tokensToday: a.tokensToday
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

        // Limit rings, per the user's chosen source (see LimitsSource):
        //   • official  — Claude Code's statusline hand-off (local, no token)
        //   • token     — the OAuth usage endpoint (exact, but unofficial)
        //   • estimate  — from local logs (approximate, never breaks)
        var limits: LimitsSnapshot?
        var limitsHint: String?

        func estimate() -> LimitsSnapshot? {
            let est = LocalEstimate.bars(allBlocks: blocks, now: now)
            guard !est.isEmpty else { return nil }
            LimitTracker.shared.record(est, at: now)
            return LimitsSnapshot(bars: est, fetchedAt: now, stale: false)
        }

        let official = Statusline.read(now: now).map { bars -> LimitsSnapshot in
            LimitTracker.shared.record(bars, at: now)
            return LimitsSnapshot(bars: bars, fetchedAt: now, stale: false)
        }

        switch LimitsSource.current {
        case .local:
            // Never read the token or hit the endpoint.
            limits = official ?? estimate()
            if limits == nil {
                limitsHint = "Local mode: run Claude Code with official limits set up, or it'll estimate from local logs."
            }
        case .token:
            // The endpoint is the source of truth here (5h + weekly + per-model).
            // Don't fall back to the local estimate — it only knows the 5-hour
            // window, so it would drop the weekly/per-model rings. Show the
            // endpoint's bars (stale cache included), else a "fetching" hint.
            limits = ClaudeAccount.shared.fetchLimits(force: forceLimits)
            if limits == nil { limitsHint = ClaudeAccount.shared.status.hint }
        case .auto:
            if let official { limits = official }
            else {
                let live = ClaudeAccount.shared.fetchLimits(force: forceLimits)
                if let live, !live.bars.isEmpty { limits = live }
                else if let est = estimate() { limits = est }
                else { limits = live; limitsHint = ClaudeAccount.shared.status.hint }
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

    /// Codex shares the presentation and local activity math with Claude, but
    /// its authoritative rings and account totals come from `codex app-server`.
    static func codexSnapshot(reader: CodexUsageReader, now: Date,
                              forceLimits: Bool = false) -> Snapshot {
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

        let account = CodexAccount.shared.fetch(force: forceLimits)
        var hourlyTokens = [Double](repeating: 0, count: 24)
        for entry in todayEntries {
            let hour = Calendar.current.component(.hour, from: entry.timestamp)
            hourlyTokens[hour] += Double(entry.totalTokens)
        }

        return Snapshot(
            limits: account.limits,
            limitsHint: account.hint,
            block: block,
            today: today,
            week: Stats(entries: all),
            sessions: sessions,
            insights: insights(sessions: sessions, today: today,
                               limits: account.limits?.bars ?? [],
                               todayEntries: todayEntries, now: now),
            hourCosts: hourlyTokens,
            provider: .codex,
            codexAccountUsage: account.usage,
            hourValuesAreTokens: true
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

func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

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
    if interval <= 0 { return "soon" }
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private let dashboard = DashboardModel()
    private let popover = NSPopover()
    private var settingsMenu = NSMenu()
    private var pendingProviders: Set<UsageProvider> = []
    private var previewWindow: NSWindow?
    private let isPreview = CommandLine.arguments.contains("--ui-preview")
    private let reader = UsageReader()
    private let codexReader = CodexUsageReader()
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
        case all, nonZero, worst
        var label: String {
            switch self {
            case .all: return "All limits"
            case .nonZero: return "Only non-zero limits"
            case .worst: return "Worst limit only"
            }
        }
    }
    private var limitStyle: LimitStyle {
        get { LimitStyle(rawValue: UserDefaults.standard.string(forKey: "limitStyle") ?? "") ?? .worst }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "limitStyle") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()   // so ⌘X/⌘C/⌘V/⌘A work in dialog text fields
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        startLoadingAnimation()
        settingsMenu = loadingMenu()
        configureDashboard()
        if isPreview {
            dashboard.provider = .codex
            showPreview()
            return
        }
        UNUserNotificationCenter.current().delegate = self
        if LimitNotifier.shared.enabled { LimitNotifier.shared.requestAuthorization() }

        // First launch: let the user choose how limits are read BEFORE the first
        // fetch, so picking "Local" never touches the token or the Keychain.
        if UserDefaults.standard.bool(forKey: "didOnboardLimits") {
            startPolling()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showProviderOnboarding()
                if UsageProvider.current == .claude {
                    self?.showLimitsOnboarding()
                } else {
                    UserDefaults.standard.set(true, forKey: "didOnboardLimits")
                }
                self?.startPolling()
            }
        }
    }

    private func changeProvider(_ provider: UsageProvider) {
        guard provider != dashboard.provider else { return }
        dashboard.provider = provider
        dashboard.snapshot = nil
        dashboard.updatedAt = nil
        if isPreview {
            render(DashboardPreview.snapshot(provider: provider), now: Date())
            return
        }
        UserDefaults.standard.set(provider.rawValue, forKey: "usageProvider")
        startLoadingAnimation()
        settingsMenu = loadingMenu()
        refresh(forceLimits: true)
    }

    private func configureDashboard() {
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleDashboard)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = false
        let dashboardHeight = DashboardLayout.height(on: statusItem.button?.window?.screen ?? NSScreen.main)
        popover.contentViewController = NSHostingController(rootView: DashboardView(
            model: dashboard,
            selectProvider: { [weak self] in self?.changeProvider($0) },
            refresh: { [weak self] in self?.refreshClicked() },
            settings: { [weak self] in self?.showSettings() },
            connect: { [weak self] in
                self?.popover.performClose(nil)
                self?.signIn()
            },
            height: dashboardHeight))
        popover.contentSize = NSSize(width: 480, height: dashboardHeight)
    }

    @objc private func toggleDashboard() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettings()
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            // Re-evaluate the available space when opened on a different display.
            let height = DashboardLayout.height(on: button.window?.screen ?? NSScreen.main)
            if let hosting = popover.contentViewController as? NSHostingController<DashboardView> {
                hosting.rootView.height = height
            }
            popover.contentSize = NSSize(width: 480, height: height)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showSettings() {
        guard let button = statusItem.button else { return }
        popover.performClose(nil)
        if isPreview {
            let previewMenu = NSMenu()
            previewMenu.addItem(withTitle: "Preview uses sample data", action: nil, keyEquivalent: "")
            let refresh = previewMenu.addItem(withTitle: "Refresh sample data", action: #selector(refreshClicked), keyEquivalent: "r")
            refresh.target = self
            let quit = previewMenu.addItem(withTitle: "Quit preview", action: #selector(quit), keyEquivalent: "q")
            quit.target = self
            previewMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
            return
        }
        settingsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    /// Synthetic fixtures avoid account requests, log reads, and saved preferences.
    private func showPreview() {
        stopLoadingAnimation()
        render(DashboardPreview.snapshot(provider: dashboard.provider), now: Date())
        if CommandLine.arguments.contains("--activity") { dashboard.page = .activity }
        let height = DashboardLayout.height(on: NSScreen.main)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Halo UI Preview"
        window.contentViewController = NSHostingController(rootView: DashboardView(
            model: dashboard, selectProvider: { [weak self] in self?.changeProvider($0) },
            refresh: { [weak self] in self?.refreshClicked() },
            settings: { [weak self] in self?.showSettings() }, connect: {}, height: height))
        if CommandLine.arguments.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
        if CommandLine.arguments.contains("--light") { window.appearance = NSAppearance(named: .aqua) }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }

    private func startPolling() {
        dashboard.provider = UsageProvider.current
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    /// A minimal Edit menu. Without it, an LSUIElement app has no responder for
    /// ⌘V, so pasting the auth code into the Connect field only works via
    /// right-click. This wires the standard clipboard shortcuts to the first
    /// responder (the focused text field).
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private enum OnboardStep { case choose, connectOffer, localOffer, officialSetup, done }

    private func showProviderOnboarding() {
        let alert = NSAlert()
        alert.messageText = "Welcome to Halo Usage"
        alert.informativeText = "Choose the coding agent to monitor. You can switch between them anytime from the menu."
        alert.addButton(withTitle: "Claude Code")
        alert.addButton(withTitle: "Codex")
        NSApp.activate(ignoringOtherApps: true)
        let provider: UsageProvider = alert.runModal() == .alertSecondButtonReturn ? .codex : .claude
        UserDefaults.standard.set(provider.rawValue, forKey: "usageProvider")
    }

    /// One-time welcome that frames the token-vs-local choice up front instead of
    /// burying it in a submenu. A small state machine so every "← Back"/"Cancel"
    /// returns to the previous step rather than dead-ending. Runs before the first
    /// fetch, so picking Local never touches the token. Sets `limitsSource`.
    private func showLimitsOnboarding() {
        UserDefaults.standard.set(true, forKey: "didOnboardLimits")
        var step = OnboardStep.choose

        while step != .done {
            switch step {
            case .choose:
                let a = NSAlert()
                a.messageText = "Claude limit source"
                a.informativeText = """
                Halo shows how much of each Claude Code plan limit you've used, \
                right in your menu bar. How should it read your limits?

                • Automatic — reads the Claude login already on your Mac and fetches \
                your exact numbers. Works instantly. (Uses an endpoint that isn't a \
                documented public API, so it could change.)

                • Local — no token, no network. Nothing leaves your Mac: it estimates \
                from your local logs, or reads Claude Code's official limits if you \
                set that up.

                You can change this anytime in the menu → Plan limits source.
                """
                a.addButton(withTitle: "Automatic (recommended)")
                a.addButton(withTitle: "Local — no token")
                a.addButton(withTitle: "What's the difference?")
                NSApp.activate(ignoringOtherApps: true)
                switch a.runModal() {
                case .alertFirstButtonReturn:
                    UserDefaults.standard.set(LimitsSource.auto.rawValue, forKey: "limitsSource")
                    // Automatic needs a Claude login to fetch exact numbers; offer
                    // to connect now if there isn't a usable one on this Mac.
                    step = ClaudeAccount.shared.hasUsableLogin() ? .done : .connectOffer
                case .alertSecondButtonReturn:
                    UserDefaults.standard.set(LimitsSource.local.rawValue, forKey: "limitsSource")
                    step = Self.statuslineConfigured() ? .done : .localOffer
                default:
                    explainLimitsSource()   // then loop back to the choice
                }

            case .connectOffer:
                let a = NSAlert()
                a.messageText = "Connect to Claude?"
                a.informativeText = "Halo didn't find a usable Claude login on this Mac, so it can't fetch your exact plan limits yet. Connect now (opens your browser) to see them. You can also do this later from the menu."
                a.addButton(withTitle: "Connect to Claude…")
                a.addButton(withTitle: "Skip for now")
                a.addButton(withTitle: "← Back")
                NSApp.activate(ignoringOtherApps: true)
                switch a.runModal() {
                case .alertFirstButtonReturn:  signIn(); step = .done
                case .alertSecondButtonReturn: step = .done
                default:                       step = .choose  // back
                }

            case .localOffer:
                let a = NSAlert()
                a.messageText = "Want exact local numbers?"
                a.informativeText = "Claude Code can hand its real limits to Halo locally — no token, no network. Otherwise Halo estimates from your local logs."
                a.addButton(withTitle: "Set up official limits…")
                a.addButton(withTitle: "Use estimate for now")
                a.addButton(withTitle: "← Back")
                NSApp.activate(ignoringOtherApps: true)
                switch a.runModal() {
                case .alertFirstButtonReturn:  step = .officialSetup
                case .alertSecondButtonReturn: step = .done   // stays Local, estimate
                default:                       step = .choose  // back
                }

            case .officialSetup:
                switch runOfficialSetup(backButton: true) {
                case .enabled, .dismissed: step = .done
                case .back:                step = .localOffer
                }

            case .done:
                break
            }
        }
    }

    /// Show banners even though a menu bar app technically counts as frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func refreshClicked() {
        if isPreview {
            render(DashboardPreview.snapshot(provider: dashboard.provider), now: Date())
        } else {
            refresh(forceLimits: true)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setProvider(_ sender: NSMenuItem) {
        guard let provider = UsageProvider(rawValue: sender.representedObject as? String ?? "") else { return }
        changeProvider(provider)
    }

    @objc private func setTitleMode(_ sender: NSMenuItem) {
        if let mode = TitleMode(rawValue: sender.representedObject as? String ?? "") {
            titleMode = mode
            refresh()
        }
    }

    @objc private func setLimitsSource(_ sender: NSMenuItem) {
        guard let mode = LimitsSource(rawValue: sender.representedObject as? String ?? "") else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "limitsSource")
        if mode == .local, !Self.statuslineConfigured() {
            let a = NSAlert()
            a.messageText = "Local mode is on"
            a.informativeText = "Halo will estimate limits from your local logs — no token, no network. For exact local numbers, use “Set up official limits…” so Claude Code hands Halo its real limits."
            a.addButton(withTitle: "Set up official limits…")
            a.addButton(withTitle: "Use estimate for now")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { enableOfficialLimits(); return }
        }
        refresh(forceLimits: true)
    }

    @objc private func explainLimitsSource() {
        let alert = NSAlert()
        alert.messageText = "Where the plan-limit rings come from"
        alert.informativeText = """
        Halo can source your usage % three ways:

        • Automatic (recommended) — no setup. Prefers Claude Code's official \
        limits if you've set them up, otherwise reads your Claude login to fetch \
        live numbers, otherwise estimates from your local logs.

        • Local — no token, no network — never reads your login or contacts \
        Anthropic. Uses Claude Code's official limits (if set up) or an estimate \
        from your local logs. The most private option, and it can't break if \
        Anthropic changes anything.

        • Anthropic account (token) — reads the login Claude Code keeps in your \
        Keychain and asks Anthropic for the exact numbers (including usage from \
        your other devices). Most accurate, but it uses an endpoint that isn't a \
        documented public API, so it could change.

        “Set up official limits” points Claude Code's status line at Halo so it \
        hands over its real limits locally — exact numbers with no token. It edits \
        ~/.claude/settings.json (a backup is saved first).
        """
        alert.addButton(withTitle: "Got it")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        if UsageProvider.current == .codex {
            alert.informativeText = """
            PLAN LIMITS — official Codex rate-limit buckets. Halo shows every window \
            returned by Codex, including account-wide limits and model-specific \
            limits for Sol, Terra, Luna, Astra, Spark, or future models. Each ring \
            turns orange at 70% and red at 90%; each row includes its reset time.

            LOCAL ACTIVITY — tokens from Codex rollout logs in ~/.codex/sessions. \
            Cached input is already part of Codex input tokens, so Halo shows it \
            separately but never counts it twice. Project and model totals cover \
            activity stored on this Mac.

            ACCOUNT USAGE — lifetime and daily account summaries supplied by the \
            official Codex app-server. Halo asks the local Codex process, which \
            owns the ChatGPT login; Halo never reads your Codex access token.

            NOTIFICATIONS — warnings at 80% and 95%, projected exhaustion, unused \
            capacity before reset, and completed resets. Each fires at most once \
            per limit window.
            """
            alert.addButton(withTitle: "Got it")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        alert.informativeText = """
        PLAN LIMITS — how much of each Claude plan rate limit you've used, straight from \
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
    enum SetupOutcome { case enabled, dismissed, back }

    @objc private func enableOfficialLimits() { _ = runOfficialSetup(backButton: false) }

    /// Writes the statusLine entry (with confirmation + backup). Returns whether it
    /// was enabled, dismissed, or the user asked to go back — so a wizard can chain
    /// it with real navigation. `backButton` labels the second button "← Back".
    private func runOfficialSetup(backButton: Bool) -> SetupOutcome {
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
            NSApp.activate(ignoringOtherApps: true); a.runModal(); return .enabled
        }

        let alert = NSAlert()
        alert.messageText = "Use Claude Code's official limits?"
        var body = "This adds a statusLine entry to ~/.claude/settings.json so Claude Code hands its official 5-hour and weekly limits to Halo — locally, no network, no token.\n\n⚠️ This is global: it applies to ALL your Claude Code sessions on this Mac, including work ones. It never touches your login — only the status line — but in a work session Halo would show that account's limits.\n\nRestart your Claude Code sessions afterward for it to take effect."
        if let existing, !existing.isEmpty {
            body += "\n\nYou already have a custom status line:\n\(existing)\nIt will be replaced (a backup is saved to settings.json.bak)."
        }
        alert.informativeText = body
        alert.addButton(withTitle: "Enable")
        alert.addButton(withTitle: backButton ? "← Back" : "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            return backButton ? .back : .dismissed
        }

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
        return .enabled
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
        let provider = UsageProvider.current
        guard pendingProviders.insert(provider).inserted else { return }
        dashboard.refreshing = true
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let snap: Snapshot
            switch provider {
            case .claude:
                snap = UsageMath.snapshot(reader: self.reader, now: now, forceLimits: forceLimits)
            case .codex:
                snap = UsageMath.codexSnapshot(reader: self.codexReader, now: now, forceLimits: forceLimits)
            }
            DispatchQueue.main.async {
                self.pendingProviders.remove(provider)
                // Discard results from a service that is no longer selected.
                guard provider == self.dashboard.provider else { return }
                self.render(snap, now: now)
            }
        }
    }

    private func render(_ snap: Snapshot, now: Date) {
        stopLoadingAnimation()
        dashboard.snapshot = snap
        dashboard.updatedAt = now
        dashboard.refreshing = false
        let provider = snap.provider
        let bars = snap.limits?.bars ?? []
        if !bars.isEmpty {
            setStatusTitle(bars)
            if snap.limits?.stale == false && !isPreview {
                LimitNotifier.shared.check(bars, now: now)
            }
        } else {
            statusItem.button?.image = nil
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            if let stats = snap.block?.stats {
                if provider == .codex {
                    statusItem.button?.title = "Codex \(compactTokens(stats.totalTokens))"
                } else {
                    switch titleMode {
                    case .both: statusItem.button?.title = "Halo \(compactTokens(stats.totalTokens)) · \(money(stats.cost))"
                    case .tokens: statusItem.button?.title = "Halo \(compactTokens(stats.totalTokens))"
                    case .cost: statusItem.button?.title = "Halo \(money(stats.cost))"
                    }
                }
            } else {
                statusItem.button?.title = "\(provider.shortLabel) idle"
            }
        }
        statusItem.button?.setAccessibilityLabel("Halo \(provider.shortLabel) usage")
        statusItem.button?.toolTip = "Halo · \(provider.shortLabel) usage. Click for details; right-click for settings."
        let menu = NSMenu()
        menu.addItem(menuSection("Service"))
        for candidate in UsageProvider.allCases {
            let item = NSMenuItem(title: candidate.label, action: #selector(setProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            item.state = candidate == provider ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        menu.addItem(menuSection("Menu bar shows"))
        for style in LimitStyle.allCases {
            let i = NSMenuItem(title: style.label, action: #selector(setLimitStyle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = style.rawValue
            i.state = (style == limitStyle) ? .on : .off
            menu.addItem(i)
        }
        if provider == .claude {
            menu.addItem(.separator())
            menu.addItem(menuSection("When limits are unavailable"))
            for mode in TitleMode.allCases {
                let i = NSMenuItem(title: mode.label, action: #selector(setTitleMode(_:)), keyEquivalent: "")
                i.target = self
                i.representedObject = mode.rawValue
                i.state = (mode == titleMode) ? .on : .off
                menu.addItem(i)
            }
        }
        menu.addItem(.separator())

        menu.addItem(menuSection("Notifications"))
        let master = NSMenuItem(title: "Enable notifications",
                                action: #selector(toggleNotifications), keyEquivalent: "")
        master.target = self
        master.state = LimitNotifier.shared.enabled ? .on : .off
        menu.addItem(master)
        for kind in NotifyKind.allCases {
            let i = NSMenuItem(title: kind.label, action: #selector(toggleNotifyKind(_:)), keyEquivalent: "")
            // Leave them visible but inert when the master switch is off, so it's
            // clear what would fire if it were on.
            i.target = LimitNotifier.shared.enabled ? self : nil
            i.representedObject = kind.rawValue
            i.state = kind.enabled ? .on : .off
            i.toolTip = kind.detail
            menu.addItem(i)
        }

        menu.addItem(.separator())
        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(login)

        if provider == .claude {
            menu.addItem(.separator())
            menu.addItem(menuSection("Plan limits source"))
            for mode in LimitsSource.allCases {
                let it = NSMenuItem(title: mode.label, action: #selector(setLimitsSource(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = mode.rawValue
                it.state = (LimitsSource.current == mode) ? .on : .off
                menu.addItem(it)
            }
            let setup = NSMenuItem(title: Self.statuslineConfigured() ? "Official limits: on ✓" : "Set up official limits…",
                                   action: #selector(enableOfficialLimits), keyEquivalent: "")
            setup.target = self
            setup.toolTip = "Points Claude Code's status line at Halo so it hands over its real limits locally — exact, and no token."
            menu.addItem(setup)
            let explainItem = NSMenuItem(title: "What's the difference?", action: #selector(explainLimitsSource), keyEquivalent: "")
            explainItem.target = self
            menu.addItem(explainItem)
        }

        if provider == .claude, snap.limits != nil {
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

        settingsMenu = menu
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
        case .nonZero: shown = bars.filter { $0.percent > 0 }
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
        // Resetting the variable length here makes AppKit recalculate the
        // status item's width whenever a newly non-zero limit joins this list.
        statusItem.length = NSStatusItem.variableLength
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
        let base = "Halo \(UsageProvider.current.shortLabel)"
        let font = statusItem.button?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Every frame has the same glyphs and width. Hide the unused dots with
        // color so neither the status item nor its centered text moves.
        let frames = (0..<4).map { visibleDots -> NSAttributedString in
            let title = NSMutableAttributedString(string: base + "...", attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
            ])
            if visibleDots < 3 {
                title.addAttribute(.foregroundColor, value: NSColor.clear,
                                   range: NSRange(location: base.utf16.count + visibleDots,
                                                  length: 3 - visibleDots))
            }
            return title
        }
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = frames[0]
        statusItem.button?.setAccessibilityLabel("\(base), loading usage")
        loadingTimer?.invalidate()
        loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.loadingDots = (self.loadingDots + 1) % 4
            self.statusItem.button?.attributedTitle = frames[self.loadingDots]
        }
    }

    private func stopLoadingAnimation() {
        loadingTimer?.invalidate()
        loadingTimer = nil
    }

    /// Settings remain available while the dashboard loads its first snapshot.
    private func loadingMenu() -> NSMenu {
        let menu = NSMenu()
        let provider = UsageProvider.current
        menu.addItem(header("Halo Usage · \(provider.shortLabel)"))
        let message = provider == .claude
            ? "Loading usage… macOS may ask to read Claude Code's login."
            : "Loading Codex limits and local activity…"
        menu.addItem(coloredInfo([(message, .secondaryLabelColor)], size: 12))
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

    /// A non-interactive title for a flat right-click menu. Unlike a submenu
    /// parent, it does not require hovering over a disclosure arrow to reveal
    /// the choices below it.
    private func menuSection(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

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

// Read-only diagnostic used by maintainers and support. It exercises the same
// Codex account and JSONL paths as the menu without launching AppKit, and never
// prints account identifiers, credentials, prompts, or project names.
if CommandLine.arguments.contains("--codex-probe") {
    let account = CodexAccount.shared.fetch(force: true)
    let local = CodexUsageReader().entries(since: Date().addingTimeInterval(-7 * 24 * 3600))
    print("limits=\(account.limits?.bars.count ?? 0) local_entries=\(local.count) local_tokens=\(local.reduce(0) { $0 + $1.totalTokens })")
    for bar in account.limits?.bars ?? [] {
        print("\(bar.displayName) \(Int(bar.percent.rounded()))% \(bar.shortLabel)")
    }
    if let lifetime = account.usage?.lifetimeTokens { print("lifetime_tokens=\(lifetime)") }
    if let hint = account.hint { print("hint=\(hint)") }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(CommandLine.arguments.contains("--ui-preview") ? .regular : .accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
