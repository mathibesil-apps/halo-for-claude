import AppKit
import SwiftUI

enum DashboardLayout {
    static let preferredHeight: CGFloat = 960

    static func height(on screen: NSScreen?) -> CGFloat {
        let availableHeight = (screen?.visibleFrame.height ?? 1020) - 60
        return min(preferredHeight, max(240, availableHeight))
    }
}

final class DashboardModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var provider = UsageProvider.current
    @Published var refreshing = true
    @Published var updatedAt: Date?
    @Published var page = DashboardPage.overview
}

enum DashboardPage: String, CaseIterable {
    case overview = "Overview", activity = "Activity"
}

/// Native text and controls keep usage readable, selectable, and accessible.
/// Account percentages and local activity deliberately have separate sections.
struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    var selectProvider: (UsageProvider) -> Void
    var refresh: () -> Void
    var settings: () -> Void
    var connect: () -> Void
    var height: CGFloat = DashboardLayout.preferredHeight

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Picker("View", selection: $model.page) {
                ForEach(DashboardPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let snap = model.snapshot {
                        if model.page == .overview {
                            limits(snap)
                            Divider()
                            totals(snap)
                            if !snap.insights.isEmpty { insights(snap.insights) }
                        } else {
                            activity(snap)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ProgressView().controlSize(.small)
                            Text("Loading \(model.provider.shortLabel) usage")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Your limits and recent activity will appear here.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 36)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id("\(model.provider.rawValue)-\(model.page.rawValue)")
            Divider()
            footer
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(width: 480, height: height)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Halo").font(.system(size: 22, weight: .semibold))
                Text("Usage at a glance").foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Service", selection: Binding(get: { model.provider }, set: selectProvider)) {
                ForEach(UsageProvider.allCases, id: \.rawValue) {
                    Text($0.shortLabel).tag($0)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 164)
            Button(action: settings) { Image(systemName: "gearshape").frame(width: 22, height: 24) }
                .buttonStyle(.borderless)
                .help("Settings and help")
                .accessibilityLabel("Settings and help")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.refreshing ? "arrow.triangle.2.circlepath" : "clock")
            if model.refreshing {
                Text("Refreshing…")
            } else if let date = model.updatedAt {
                Text("Updated \(timeHM(date))")
            } else {
                Text("Waiting for usage")
            }
            Spacer()
            Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .disabled(model.refreshing)
                .keyboardShortcut("r", modifiers: .command)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder private func limits(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Plan limits")
                Spacer()
                Text("Percentage used").foregroundStyle(.secondary)
            }
            if let limits = snap.limits, !limits.bars.isEmpty {
                if limits.stale {
                    notice("Showing saved limits from \(timeHM(limits.fetchedAt)). Refresh to try again.",
                           symbol: "exclamationmark.arrow.triangle.2.circlepath", color: .orange)
                } else if limits.bars.contains(where: { $0.source == .estimated }) {
                    notice("Estimated from local activity. Actual plan usage may differ.",
                           symbol: "info.circle", color: .secondary)
                }
                ForEach(limits.bars, id: \.trackerKey) { bar in
                    LimitUsageRow(bar: bar)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Limits unavailable", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 15, weight: .semibold))
                    Text(snap.limitsHint ?? "No plan limits were returned. Try refreshing in a moment.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if snap.provider == .claude {
                        Button("Connect to Claude…", action: connect)
                    }
                }
            }
        }
    }

    private func totals(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                sectionTitle("Local activity")
                Spacer()
                Text("On this Mac").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                metric("Today", value: compactTokens(snap.today.totalTokens), detail: "tokens")
                Divider()
                metric("Last 7 days", value: compactTokens(snap.week.totalTokens), detail: "tokens")
            }.fixedSize(horizontal: false, vertical: true)
            if snap.provider == .claude {
                detailRow("API cost equivalent today", value: money(snap.today.cost))
                Text("An estimate at API prices, not a subscription charge.")
                    .foregroundStyle(.secondary)
            }
            Text("Local token totals are separate from your plan limits.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { model.page = .activity } label: {
                HStack {
                    Text("Explore activity")
                    Spacer()
                    Text("\(snap.sessions.count) active \(snap.sessions.count == 1 ? "session" : "sessions")")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func activity(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Today's activity")
            metric("Total tokens", value: compactTokens(snap.today.totalTokens),
                   detail: snap.provider == .claude ? "\(money(snap.today.cost)) API cost equivalent" : "On this Mac")
            if snap.today.totalTokens > 0 {
                ActivityChart(values: snap.hourCosts, tokens: snap.hourValuesAreTokens,
                              now: model.updatedAt ?? Date())
            } else {
                Text("No activity recorded today. New sessions will appear after the next refresh.")
                    .foregroundStyle(.secondary)
            }
            modelBreakdown(snap.today, provider: snap.provider)
        }
        Divider()
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Current 5-hour activity")
            if let block = snap.block {
                Text("\(timeHM(block.start))–\(timeHM(block.end)) · Local activity window")
                    .foregroundStyle(.secondary)
                detailRow("Total tokens", value: compactTokens(block.stats.totalTokens))
                detailRow("Input", value: compactTokens(block.stats.inputTokens))
                detailRow(snap.provider == .codex ? "Cached input (included above)" : "Cache reads",
                          value: compactTokens(block.stats.cacheReadTokens))
                detailRow("Output", value: compactTokens(block.stats.outputTokens))
                if snap.provider == .claude {
                    detailRow("Cache writes", value: compactTokens(block.stats.cacheCreationTokens))
                    detailRow("API cost equivalent", value: money(block.stats.cost))
                }
                let elapsed = (model.updatedAt ?? Date()).timeIntervalSince(block.start)
                if elapsed > 60 {
                    detailRow("Average pace", value: "\(compactTokens(Int(Double(block.stats.totalTokens) / (elapsed / 60)))) tokens/min")
                }
                modelBreakdown(block.stats, provider: snap.provider)
            } else {
                Text("No recent activity in this window.").foregroundStyle(.secondary)
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Active sessions")
            if snap.sessions.isEmpty {
                Text("No sessions active in the last 30 minutes.").foregroundStyle(.secondary)
            }
            ForEach(snap.sessions, id: \.id) { session in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.project).fontWeight(.medium)
                            .lineLimit(2).textSelection(.enabled)
                            .help(session.project)
                        Spacer(minLength: 16)
                        Text(session.model).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(compactTokens(session.contextTokens)) context tokens")
                        Spacer(minLength: 8)
                        Text(snap.provider == .codex
                             ? "\(compactTokens(session.tokensToday)) tokens today"
                             : "\(money(session.costToday)) today")
                    }.foregroundStyle(.secondary)
                }
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Last 7 days")
            detailRow("Local tokens", value: compactTokens(snap.week.totalTokens))
            if snap.provider == .claude {
                detailRow("API cost equivalent", value: money(snap.week.cost))
            }
            modelBreakdown(snap.week, provider: snap.provider)
        }
        if let account = snap.codexAccountUsage {
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("Codex account")
                if let plan = account.planType { detailRow("Plan", value: plan.capitalized) }
                if let n = account.lifetimeTokens { detailRow("Lifetime tokens", value: compactTokens(n)) }
                if let n = account.peakDailyTokens { detailRow("Peak day", value: "\(compactTokens(n)) tokens") }
                if let n = account.currentStreakDays { detailRow("Current streak", value: "\(n) days") }
                if let n = account.longestStreakDays { detailRow("Best streak", value: "\(n) days") }
                if let n = account.longestRunningTurnSec { detailRow("Longest turn", value: formatDuration(n)) }
            }
        }
    }

    private func insights(_ items: [Insight]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Insights")
            ForEach(items, id: \.id) { item in
                notice(item.text,
                       symbol: item.severity == .info ? "info.circle" : "exclamationmark.triangle",
                       color: item.severity == .alert ? .red : item.severity == .warn ? .orange : .secondary)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold)).accessibilityAddTraits(.isHeader)
    }

    private func metric(_ label: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                .textSelection(.enabled)
            Text(detail).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func modelBreakdown(_ stats: Stats, provider: UsageProvider) -> some View {
        ForEach(stats.byModel, id: \.0) { name, tokens, cost in
            detailRow(name, value: provider == .codex ? "\(compactTokens(tokens)) tokens"
                      : "\(compactTokens(tokens)) tokens · \(money(cost))")
        }
    }
}

private struct LimitUsageRow: View {
    let bar: LimitBar
    private var percent: Double { bar.percent.isFinite ? min(max(bar.percent, 0), 100) : 0 }
    private var color: Color { Color(nsColor: limitColor(percent)) }
    private var title: String {
        guard let scope = bar.scopeName else { return bar.label }
        let name = scope.lowercased().contains("reserve") ? "Reserve" : Pricing.shortName(scope)
        let window = bar.label.components(separatedBy: " · ").first ?? bar.label
        return "\(name) · \(window)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title).font(.system(size: 14, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(bar.label)
                Spacer(minLength: 0)
                Text(String(format: "%.0f%%", percent))
                    .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    .fixedSize()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor).opacity(0.6))
                    Capsule().fill(color).frame(width: proxy.size.width * percent / 100)
                }
            }.frame(height: 7).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let date = bar.resetsAt {
                    Text("Resets \(shortResetText(date))")
                        .help(date.formatted(date: .complete, time: .shortened))
                } else {
                    Text("Reset time unavailable")
                }
                Spacer(minLength: 0)
                if percent >= 90 {
                    Label(percent >= 100 ? "Limit reached" : "Almost at limit", systemImage: "exclamationmark.triangle")
                } else {
                    Text(String(format: "%.0f%% left", 100 - percent))
                }
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityChart: View {
    let values: [Double]
    let tokens: Bool
    let now: Date
    private var hour: Int { Calendar.current.component(.hour, from: now) }
    private var peak: Double { max(values.prefix(hour + 1).max() ?? 0, 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(tokens ? "Tokens by hour" : "API cost equivalent by hour")
                Spacer()
                Text("Peak \(tokens ? compactTokens(Int(peak)) : money(peak))/h")
            }.foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<24, id: \.self) { index in
                    let value = index <= hour && index < values.count ? max(values[index], 0) : 0
                    VStack {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(index == hour ? Color.accentColor : Color.accentColor.opacity(0.55))
                            .frame(height: value > 0 ? max(3, 64 * value / max(peak, 1)) : 1)
                            .opacity(index > hour ? 0.2 : 1)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: "%02d:00 · %@", index, tokens ? "\(compactTokens(Int(value))) tokens" : money(value)))
                }
            }.frame(height: 64).accessibilityHidden(true)
            HStack {
                Text("00:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("23:00")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
