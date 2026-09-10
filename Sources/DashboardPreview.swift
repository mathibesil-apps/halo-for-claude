import Foundation

/// Repeatable UI review with synthetic data; never accesses either account.
enum DashboardPreview {
    static func snapshot(provider: UsageProvider) -> Snapshot {
        let now = Date()
        let args = CommandLine.arguments
        if args.contains("--empty") {
            return Snapshot(limits: nil,
                            limitsHint: "Could not load account limits. Check your connection, then refresh to try again.",
                            today: Stats(), week: Stats(), provider: provider,
                            hourValuesAreTokens: provider == .codex)
        }
        let names = provider == .codex ? ["Weekly limit", "5-hour · Spark", "Weekly · Spark", "Weekly · Reserve"]
            : ["5-hour limit", "Weekly limit", "Weekly · Sonnet"]
        var bars = names.enumerated().map { i, label in
            LimitBar(kind: "preview.\(i)", scopeName: nil, label: label, shortLabel: i == 0 ? "Wk" : "5h",
                     percent: [34.0, 72.0, 12.0, 0.0][i],
                     resetsAt: now.addingTimeInterval(Double(i + 1) * 7200),
                     source: provider == .codex ? .official : .live, provider: provider)
        }
        if args.contains("--stress") {
            bars += (0..<5).map { i in
                LimitBar(kind: "long.\(i)", scopeName: nil,
                         label: "Weekly · A future model with a considerably longer display name \(i + 1)",
                         shortLabel: "Wk", percent: i == 0 ? 100 : 94, resetsAt: nil,
                         source: .official, provider: provider)
            }
        }
        if args.contains("--estimated") {
            bars = bars.map { bar in
                var result = bar
                result.source = .estimated
                return result
            }
        }
        let entries = (0..<12).map { i in
            UsageEntry(timestamp: now.addingTimeInterval(Double(-i * 300)),
                       model: provider == .codex ? (i % 2 == 0 ? "gpt-6-astra" : "gpt-5.6-sol") : "claude-sonnet",
                       inputTokens: 18000 + i * 1800, outputTokens: 2400,
                       cacheCreationTokens: 0, cacheReadTokens: 12000,
                       dedupeKey: "demo.\(i)", sessionId: "preview", cwd: "/sample/web-app",
                       isSidechain: false, provider: provider)
        }
        let today = Stats(entries: entries)
        return Snapshot(
            limits: LimitsSnapshot(bars: bars, fetchedAt: now.addingTimeInterval(-1800),
                                   stale: args.contains("--stale")),
            block: BlockStats(start: now.addingTimeInterval(-3600), stats: today),
            today: today, week: Stats(entries: entries + entries + entries),
            sessions: [
                SessionSummary(id: "preview.web-app", project: "web-app", model: provider == .codex ? "Astra" : "Sonnet",
                               contextTokens: 84000, costToday: 1.84, tokensToday: 248000),
                SessionSummary(id: "preview.api-server", project: args.contains("--stress")
                               ? "a-project-with-a-very-long-name-that-must-wrap-without-hiding-its-model" : "api-server",
                               model: provider == .codex ? "Sol" : "Haiku",
                               contextTokens: 42000, costToday: 0.92, tokensToday: 156000)
            ],
            insights: [Insight(severity: .warn, text: "\(provider == .codex ? "Spark" : "Claude") is approaching its 5-hour limit. The next reset will restore capacity.")],
            hourCosts: (0..<24).map { Double(($0 * 7 + 3) % 13) * (provider == .codex ? 8200 : 0.18) },
            provider: provider,
            codexAccountUsage: provider == .codex ? CodexAccountUsage(
                lifetimeTokens: 48200000, peakDailyTokens: 2400000, longestRunningTurnSec: 840,
                currentStreakDays: 7, longestStreakDays: 21, planType: "Pro") : nil,
            hourValuesAreTokens: provider == .codex)
    }
}
