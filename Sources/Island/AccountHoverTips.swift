import SwiftUI

/// Which hang-below / chip tips are active for one account widget.
struct WidgetHoverChrome: Equatable, Sendable {
    var accountID: AccountID
    var showUsage: Bool
    var showCaption: Bool
    var showStatus: Bool

    var isActive: Bool { showUsage || showCaption || showStatus }
}

/// Hover tips that hang **below** the cell — must not live inside a clipping ScrollView.
enum AccountHoverTips {
    static let tipGap: CGFloat = CGFloat(IslandClusterLayout.defaultTipGap)
    static let captionTipWidth: CGFloat = 268

    static func formatHoverRow(_ row: HoverWindowLine, now: Date) -> String {
        if let resetAt = row.resetAt,
           let reset = UsageOrchestrator.formatResetRemaining(until: resetAt, now: now)
        {
            return "\(row.label)  \(row.usage)  ·  \(reset)"
        }
        return "\(row.label)  \(row.usage)"
    }

    @ViewBuilder
    static func usageCard(model: WidgetViewModel) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.hoverWindows.enumerated()), id: \.offset) { _, row in
                    Text(formatHoverRow(row, now: context.date))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(white: 0.90))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(tipBackground(corner: 8))
            .overlay(alignment: .top) { tipCaret() }
        }
        .fixedSize()
    }

    @ViewBuilder
    static func captionCard(model: WidgetViewModel) -> some View {
        let isError = model.errorCaption != nil
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let body = model.detailCaption
                ?? model.errorCaption
                ?? model.noticeCaption
                ?? ""
            let timing = UsageOrchestrator.formatErrorTimingLines(
                lastCheckedAt: model.lastCheckedAt,
                lastSuccessAt: model.lastSuccessAt,
                retryAt: model.retryAt,
                now: context.date
            )
            VStack(alignment: .leading, spacing: 6) {
                if !body.isEmpty {
                    Text(body)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            isError
                                ? Color(red: 0.98, green: 0.62, blue: 0.55)
                                : Color(red: 0.95, green: 0.82, blue: 0.45)
                        )
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                }
                if !timing.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(timing.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color(white: 0.72))
                        }
                    }
                }
            }
            .frame(width: captionTipWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(tipBackground(corner: 8))
            .overlay(alignment: .top) { tipCaret() }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private static func tipBackground(corner: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
    }

    private static func tipCaret() -> some View {
        TipTriangle()
            .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
            .frame(width: 10, height: 5)
            .offset(y: -5)
    }
}

/// Upward caret for hang-below tooltips.
struct TipTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
