import SwiftUI

/// Compact Ollama Cloud subscription status for the sidebar footer: a monthly
/// usage ring plus label; tapping opens a popover with monthly/weekly/session
/// details. Hidden entirely when no API key is set.
struct UsageStatusView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showDetails = false

    private var monitor: UsageMonitor { env.usage }

    var body: some View {
        if env.hasAPIKey {
            Button { showDetails = true } label: {
                rowLabel
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails) {
                UsageDetailsPopover(
                    monitor: monitor,
                    onRefresh: { await env.usage.refresh(using: env.ollama) }
                )
            }
        }
    }

    private var monthlyFraction: Double {
        monitor.response?.limits?.monthly?.usage ?? 0
    }

    /// Flat row: stats on the left, label on the right, full-width bar below.
    private var rowLabel: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(statsText)
                    .font(Theme.Typography.font(.footnote).weight(.semibold))
                    .foregroundStyle(statsColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if monitor.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text("Ollama Cloud")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(Theme.textTertiary)
            }
            UsageBarView(fraction: monthlyFraction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
    }

    private var statsText: String {
        if monitor.response == nil, monitor.errorMessage != nil {
            return "Usage unavailable"
        }
        guard let monthly = monitor.response?.limits?.monthly else {
            return monitor.isLoading ? "Loading…" : "—"
        }
        let requests = (monthly.models ?? []).reduce(0) { $0 + $1.requestCount }
        let percent = Self.formatPercent(monthly.usage ?? 0)
        return requests > 0 ? "\(percent) · \(requests) requests" : "\(percent) used"
    }

    private var statsColor: Color {
        if monitor.response == nil, monitor.errorMessage != nil {
            return Theme.Semantic.warning
        }
        return Theme.textPrimary
    }

    /// 0.423 → "42 %", small values keep one decimal ("4.2 %").
    static func formatPercent(_ fraction: Double) -> String {
        let pct = fraction * 100
        if pct >= 10 { return "\(Int(pct.rounded())) %" }
        let oneDecimal = String(format: "%.1f", pct)
        let trimmed = oneDecimal.hasSuffix(".0") ? String(oneDecimal.dropLast(2)) : oneDecimal
        return "\(trimmed) %"
    }

    /// Fill color by quota pressure: green up to 70 %, orange to 90 %, red above.
    static func color(for fraction: Double) -> Color {
        if fraction >= 0.9 { return Theme.Semantic.danger }
        if fraction >= 0.7 { return Theme.Semantic.warning }
        return Theme.Semantic.success
    }
}

/// Popover with the full quota breakdown: bars for month/week/session, top
/// models of the month, 4-week cost, and a manual refresh.
private struct UsageDetailsPopover: View {
    let monitor: UsageMonitor
    let onRefresh: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            if let error = monitor.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.font(.caption))
                    .foregroundStyle(Theme.Semantic.warning)
            }
            if let limits = monitor.response?.limits {
                limitRow("Month", limits.monthly)
                limitRow("Week", limits.weekly)
                limitRow("Session", limits.session)
            }
            topModels
            cost
            footer
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 300)
    }

    private var header: some View {
        Text("Ollama Cloud Usage")
            .font(Theme.Typography.font(.title3))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func limitRow(_ label: String, _ limit: OllamaUsageLimit?) -> some View {
        if let limit {
            let fraction = limit.usage ?? 0
            let requests = (limit.models ?? []).reduce(0) { $0 + $1.requestCount }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack {
                    Text(label)
                        .font(Theme.Typography.font(.footnote).weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    Text("\(UsageStatusView.formatPercent(fraction)) · \(requests) requests")
                        .font(Theme.Typography.font(.caption))
                        .foregroundStyle(Theme.textSecondary)
                }
                UsageBarView(fraction: fraction)
            }
        }
    }

    @ViewBuilder
    private var topModels: some View {
        let limits = monitor.response?.limits
        let models = (limits?.monthly?.models ?? limits?.weekly?.models ?? []).prefix(5)
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Top models")
                    .font(Theme.Typography.font(.caption).weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .textCase(.uppercase)
                ForEach(Array(models), id: \.name) { model in
                    HStack {
                        Text(model.name)
                            .font(Theme.Typography.font(.footnote))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text("\(model.requestCount)")
                            .font(Theme.Typography.font(.caption))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cost: some View {
        if let costString = monitor.response?.activity?.cost,
           let value = Double(costString), value > 0 {
            HStack {
                Text("Cost (4 weeks)")
                    .font(Theme.Typography.font(.footnote))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 0)
                Text(String(format: "$%.2f", value))
                    .font(Theme.Typography.font(.footnote).weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let updated = monitor.lastUpdated {
                Text("Updated ") + Text(updated, style: .relative)
            } else {
                Text("Not loaded yet")
            }
            Spacer(minLength: 0)
            if monitor.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await onRefresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
        }
        .font(Theme.Typography.font(.caption))
        .foregroundStyle(Theme.textTertiary)
    }
}

/// Thin capsule bar for one quota row.
private struct UsageBarView: View {
    var fraction: Double

    private var clamped: Double { min(max(fraction, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.textTertiary.opacity(0.2))
                Capsule()
                    .fill(UsageStatusView.color(for: clamped))
                    .frame(width: max(geo.size.width * clamped, clamped > 0 ? 6 : 0))
            }
        }
        .frame(height: 6)
        .animation(Theme.Motion.Easing.standard, value: clamped)
    }
}
