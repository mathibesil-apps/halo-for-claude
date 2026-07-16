import AppKit
import Foundation

// MARK: - Data model

struct UsageEntry {
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int

    var totalTokens: Int { inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens }
}

struct BlockStats {
    var start: Date
    var end: Date { start.addingTimeInterval(5 * 3600) }
    var entries: [UsageEntry] = []

    var inputTokens: Int { entries.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { entries.reduce(0) { $0 + $1.outputTokens } }
    var cacheCreationTokens: Int { entries.reduce(0) { $0 + $1.cacheCreationTokens } }
    var cacheReadTokens: Int { entries.reduce(0) { $0 + $1.cacheReadTokens } }
    var totalTokens: Int { entries.reduce(0) { $0 + $1.totalTokens } }

    var cost: Double { entries.reduce(0) { $0 + Pricing.cost(for: $1) } }
}

// MARK: - Pricing (USD per million tokens)

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

    static func cost(for e: UsageEntry) -> Double {
        let r = rate(for: e.model)
        return (Double(e.inputTokens) * r.input
              + Double(e.outputTokens) * r.output
              + Double(e.cacheCreationTokens) * r.cacheWrite
              + Double(e.cacheReadTokens) * r.cacheRead) / 1_000_000
    }
}

// MARK: - JSONL parsing

final class UsageReader {
    private let projectsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects")

    private let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoParserNoFrac = ISO8601DateFormatter()

    private func parseDate(_ s: String) -> Date? {
        isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
    }

    /// Read usage entries from files modified after `cutoff`, deduped by message id + request id.
    func entries(since cutoff: Date) -> [UsageEntry] {
        var result: [UsageEntry] = []
        var seen = Set<String>()

        guard let en = FileManager.default.enumerator(at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < cutoff { continue }
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.split(separator: "\n") {
                // cheap pre-filter before JSON parsing
                guard line.contains("\"usage\"") else { continue }
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let tsStr = obj["timestamp"] as? String,
                      let ts = parseDate(tsStr), ts >= cutoff,
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }

                let msgId = (message["id"] as? String) ?? ""
                let reqId = (obj["requestId"] as? String) ?? ""
                if !msgId.isEmpty || !reqId.isEmpty {
                    let key = msgId + ":" + reqId
                    if seen.contains(key) { continue }
                    seen.insert(key)
                }

                result.append(UsageEntry(
                    timestamp: ts,
                    model: (message["model"] as? String) ?? "",
                    inputTokens: usage["input_tokens"] as? Int ?? 0,
                    outputTokens: usage["output_tokens"] as? Int ?? 0,
                    cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0
                ))
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    /// Active 5-hour billing block (ccusage algorithm: block start = first entry's
    /// timestamp floored to the hour; a block ends 5h after start or after a 5h gap).
    func activeBlock(now: Date = Date()) -> BlockStats? {
        // Entries from the last 10h are enough to determine the current block.
        let all = entries(since: now.addingTimeInterval(-10 * 3600))
        guard !all.isEmpty else { return nil }

        var block: BlockStats? = nil
        for e in all {
            if var b = block {
                if e.timestamp >= b.end || (b.entries.last.map { e.timestamp.timeIntervalSince($0.timestamp) > 5 * 3600 } ?? false) {
                    block = BlockStats(start: floorToHour(e.timestamp), entries: [e])
                } else {
                    b.entries.append(e)
                    block = b
                }
            } else {
                block = BlockStats(start: floorToHour(e.timestamp), entries: [e])
            }
        }
        guard let b = block, now < b.end,
              let last = b.entries.last, now.timeIntervalSince(last.timestamp) < 5 * 3600 else { return nil }
        return b
    }

    func todayStats(now: Date = Date()) -> BlockStats {
        let startOfDay = Calendar.current.startOfDay(for: now)
        var b = BlockStats(start: startOfDay)
        b.entries = entries(since: startOfDay)
        return b
    }

    private func floorToHour(_ d: Date) -> Date {
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "CC …"
        statusItem.menu = NSMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func refreshClicked() { refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let now = Date()
            let block = self.reader.activeBlock(now: now)
            let today = self.reader.todayStats(now: now)
            DispatchQueue.main.async { self.render(block: block, today: today, now: now) }
        }
    }

    private func render(block: BlockStats?, today: BlockStats, now: Date) {
        let menu = NSMenu()

        if let b = block {
            statusItem.button?.title = "CC \(compactTokens(b.totalTokens)) · \(money(b.cost))"

            menu.addItem(header("Current 5h block  (\(timeHM(b.start))–\(timeHM(b.end)))"))
            menu.addItem(info("Tokens: \(compactTokens(b.totalTokens))   Cost: \(money(b.cost))"))
            menu.addItem(info("In \(compactTokens(b.inputTokens)) · Out \(compactTokens(b.outputTokens)) · CacheW \(compactTokens(b.cacheCreationTokens)) · CacheR \(compactTokens(b.cacheReadTokens))"))

            let elapsed = now.timeIntervalSince(b.start)
            let remaining = max(0, b.end.timeIntervalSince(now))
            if elapsed > 60 {
                let perMin = Double(b.totalTokens) / (elapsed / 60)
                menu.addItem(info(String(format: "Burn rate: %@/min   Resets in %dh %02dm",
                                         compactTokens(Int(perMin)), Int(remaining) / 3600, (Int(remaining) % 3600) / 60)))
            }
        } else {
            statusItem.button?.title = "CC idle"
            menu.addItem(header("No active 5h block"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Today"))
        menu.addItem(info("Tokens: \(compactTokens(today.totalTokens))   Cost: \(money(today.cost))"))

        menu.addItem(.separator())
        menu.addItem(info("Cost is estimated from list API pricing"))
        let r = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"); q.target = self
        menu.addItem(q)

        statusItem.menu = menu
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
