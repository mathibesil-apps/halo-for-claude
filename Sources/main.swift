import AppKit
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

// MARK: - Usage snapshot

struct Snapshot {
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

        if let b = snap.block {
            let s = b.stats
            switch titleMode {
            case .both: statusItem.button?.title = "CC \(compactTokens(s.totalTokens)) · \(money(s.cost))"
            case .tokens: statusItem.button?.title = "CC \(compactTokens(s.totalTokens))"
            case .cost: statusItem.button?.title = "CC \(money(s.cost))"
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
            statusItem.button?.title = "CC idle"
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
