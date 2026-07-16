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

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
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
        var deduped: [UsageEntry] = []
        deduped.reserveCapacity(result.count)
        for e in result.sorted(by: { $0.timestamp < $1.timestamp }) {
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
                }()
            ))
        }
        return out
    }
}

// MARK: - Claude account OAuth (own token, stored in this app's Keychain item)

struct LimitBar {
    let label: String
    let shortLabel: String     // for the menu bar title, e.g. "5h", "W", "F"
    let percent: Double        // 0–100
    let resetsAt: Date?
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
            return nil
        case .failure(let err):
            return err.message
        }
    }

    private struct OAuthError: Error { let message: String }

    private func postToken(body: inout [String: Any]) -> Result<Tokens, OAuthError> {
        var req = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, status) = Self.syncRequest(req)
        guard let data, status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let detail = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "").prefix(200)
            return .failure(OAuthError(message: "Token request failed (HTTP \(status)): \(detail)"))
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        return .success(Tokens(
            accessToken: access,
            refreshToken: (obj["refresh_token"] as? String) ?? "",
            expiresAt: Date().addingTimeInterval(expiresIn - 60)
        ))
    }

    // MARK: Access token with refresh

    private func validAccessToken() -> String? {
        queue.sync { () -> String? in
            guard var t = loadTokens() else { return nil }
            if t.expiresAt > Date() { return t.accessToken }
            guard !t.refreshToken.isEmpty else { return nil }
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
                return t.accessToken
            case .failure(let err):
                NSLog("token refresh failed: \(err.message)")
                return nil
            }
        }
    }

    // MARK: Usage limits

    /// nil = not signed in / auth failed; empty = signed in but response unrecognized.
    func fetchLimits() -> [LimitBar]? {
        guard let token = validAccessToken() else { return nil }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, status) = Self.syncRequest(req)
        guard let data, status == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("usage fetch failed (HTTP \(status))")
            return status == 401 || status == 403 ? nil : []
        }
        UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "lastUsageJSON")
        return Self.parseLimits(obj)
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
            out.append(LimitBar(label: label, shortLabel: short, percent: percent, resetsAt: resets))
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
            return LimitBar(label: label, shortLabel: short, percent: pct, resetsAt: resets)
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

    private static func syncRequest(_ req: URLRequest) -> (Data?, Int) {
        var outData: Data?
        var outStatus = 0
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            outData = data
            outStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()
        return (outData, outStatus)
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

struct Snapshot {
    var limits: [LimitBar]?    // nil = not signed in / auth failed
    var block: BlockStats?
    var today: Stats
    var week: Stats
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

    static func snapshot(reader: UsageReader, now: Date) -> Snapshot {
        let weekStart = now.addingTimeInterval(-7 * 24 * 3600)
        let all = reader.entries(since: weekStart)
        let dayStart = Calendar.current.startOfDay(for: now)
        return Snapshot(
            limits: ClaudeAccount.shared.fetchLimits(),
            block: activeBlock(entries: all, now: now),
            today: Stats(entries: all.filter { $0.timestamp >= dayStart }),
            week: Stats(entries: all)
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

func timeHM(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
}

// MARK: - Limit bar menu item view

final class LimitBarView: NSView {
    private let bar: LimitBar

    init(_ bar: LimitBar) {
        self.bar = bar
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 34))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let width = bounds.width - inset * 2

        let label = bar.label as NSString
        label.draw(at: NSPoint(x: inset, y: 18), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ])

        var right = String(format: "%.0f%%", bar.percent)
        if let resets = bar.resetsAt {
            right = "\(Self.resetText(resets))   \(right)"
        }
        let rightStr = right as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let rw = rightStr.size(withAttributes: attrs).width
        rightStr.draw(at: NSPoint(x: bounds.width - inset - rw, y: 19), withAttributes: attrs)

        // track
        let trackRect = NSRect(x: inset, y: 8, width: width, height: 5)
        let track = NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.3).setFill()
        track.fill()

        // fill
        let pct = min(max(bar.percent, 0), 100) / 100
        if pct > 0 {
            let fillRect = NSRect(x: inset, y: 8, width: max(5, width * pct), height: 5)
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: 2.5, yRadius: 2.5)
            fillColor().setFill()
            fill.fill()
        }
    }

    private func fillColor() -> NSColor {
        switch bar.percent {
        case ..<70: return .controlAccentColor
        case ..<90: return .systemOrange
        default: return .systemRed
        }
    }

    static func resetText(_ d: Date) -> String {
        let interval = d.timeIntervalSinceNow
        if interval <= 0 { return "Resets soon" }
        if interval < 24 * 3600 {
            let h = Int(interval) / 3600, m = (Int(interval) % 3600) / 60
            return h > 0 ? "Resets in \(h) hr \(m) min" : "Resets in \(m) min"
        }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return "Resets \(f.string(from: d))"
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

    @objc private func refreshClicked() { refresh() }
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
                    self?.refresh()
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

    private func refresh() {
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            let snap = UsageMath.snapshot(reader: self.reader, now: now)
            DispatchQueue.main.async { self.render(snap, now: now) }
        }
    }

    private func render(_ snap: Snapshot, now: Date) {
        let menu = NSMenu()

        // Account limit bars (like claude.ai's usage popup)
        if let limits = snap.limits, !limits.isEmpty {
            statusItem.button?.title = limits
                .map { String(format: "%@ %.0f%%", $0.shortLabel, $0.percent) }
                .joined(separator: "  ")

            menu.addItem(header("Plan usage limits"))
            for bar in limits {
                let item = NSMenuItem()
                item.view = LimitBarView(bar)
                menu.addItem(item)
            }
            menu.addItem(.separator())
        } else if snap.limits == nil {
            let s = NSMenuItem(title: "Sign in to Claude for usage limits…",
                               action: #selector(signIn), keyEquivalent: "")
            s.target = self
            menu.addItem(s)
            menu.addItem(.separator())
        }

        if let b = snap.block {
            let s = b.stats
            if snap.limits == nil || snap.limits!.isEmpty {
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
            if snap.limits == nil || snap.limits!.isEmpty {
                statusItem.button?.title = "CC idle"
            }
            menu.addItem(header("No active 5h block"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Today"))
        menu.addItem(info("Tokens: \(compactTokens(snap.today.totalTokens))   Cost: \(money(snap.today.cost))"))
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

    private func addModelBreakdown(_ s: Stats, to menu: NSMenu) {
        let models = s.byModel
        guard models.count > 1 || (models.first.map { $0.0 != "unknown" } ?? false) else { return }
        for (name, tokens, cost) in models {
            menu.addItem(info("   \(name): \(compactTokens(tokens)) · \(money(cost))"))
        }
    }

    private func header(_ s: String) -> NSMenuItem {
        let i = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        i.attributedTitle = NSAttributedString(string: s, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        return i
    }
    private func info(_ s: String) -> NSMenuItem { NSMenuItem(title: s, action: nil, keyEquivalent: "") }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
