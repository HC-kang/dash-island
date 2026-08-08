import SwiftUI

/// Square account cell: gauge + label + independent hover tips
/// (body usage · status chip · warning caption — like the status light).
struct AccountWidget: View {
    let model: WidgetViewModel
    var isDragging: Bool = false
    var isDropTarget: Bool = false

    /// Hover on the cell body (usage tooltip below).
    @State private var isHovered = false
    /// Hover on the status light only (separate tip — not whole-cell).
    @State private var statusHovered = false
    /// Hover on the under-gauge warning/notice line only.
    @State private var captionHovered = false

    /// Outer cell width (gauge sits inside with padding).
    static let cellSize: CGFloat = IslandModel.cellSize
    /// Fixed cell height — room for gauge + title + caption slot without vertical reflow.
    static let cellHeight: CGFloat = IslandModel.cellSize + 20
    private static let gaugeSize: CGFloat = 80
    /// Always reserved so error captions never push the gauge/title up.
    private static let captionSlotHeight: CGFloat = 15
    /// Invisible hit pad so a 6pt dot is actually reachable.
    private static let statusHit: CGFloat = 18
    /// Gap between cell bottom and the top edge of hang-down tips.
    private static let tipGap: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 2) {
                ZStack {
                    GaugeRingView(
                        primaryFraction: model.primaryFraction,
                        secondaryFraction: model.secondaryFraction,
                        centerPercent: model.centerPercent,
                        burnRatio: model.burnRatio,
                        tint: model.tint,
                        size: Self.gaugeSize,
                        phaseOffset: BurnMotion.phaseOffset(for: model.id)
                    )
                    .opacity(model.isAwaitingFirstSample ? 0.22 : 1)

                    if model.isAwaitingFirstSample {
                        ProgressView()
                            .controlSize(.small)
                            .colorScheme(.dark)
                    }
                }
                .frame(width: Self.gaugeSize, height: Self.gaugeSize)

                Text(model.title)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.cellSize - 8)
                    .frame(height: 11)

                // Fixed slot: empty cells keep the same metrics as captioned ones.
                captionSlot
                    .frame(height: Self.captionSlotHeight)
                    .frame(maxWidth: Self.cellSize - 10)
            }
            .padding(.top, 6)
            .padding(.bottom, 4)
            // Top-align so growing captions cannot center-shift the gauge upward.
            .frame(width: Self.cellSize, height: Self.cellHeight, alignment: .top)
            .background(cellBackground)
            .animation(.easeOut(duration: 0.55), value: model.burnRatio)
            .overlay(alignment: .topLeading) {
                VendorLogoBadge(vendorID: model.vendorID)
                    .padding(.top, 7)
                    .padding(.leading, 7)
                    .allowsHitTesting(false)
            }
            // Body hover = usage only. Status + caption own their hovers.
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }

            // Status chip sits above the card in z-order so it wins hit-testing.
            statusChip
                .padding(.top, 4)
                .padding(.trailing, 4)
                .zIndex(20)
        }
        .frame(width: Self.cellSize, height: Self.cellHeight)
        .scaleEffect(isDragging ? 1.06 : 1)
        // Tips hang **below** the cell (top of tip at cell bottom).
        // Bottom-aligned overlays grow upward and pierce the notch — never do that.
        .overlay(alignment: .top) {
            if isHovered, !statusHovered, !captionHovered, !model.hoverWindows.isEmpty {
                usageTooltip
                    .fixedSize()
                    .offset(y: Self.cellHeight + Self.tipGap)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        // Warning/notice detail — only while the caption line is hovered.
        // Must not inherit the cell's ~100pt width proposal (that forced the
        // skinny column wrap). Size like the status tip: content-driven, wide.
        .overlay(alignment: .top) {
            if captionHovered, !statusHovered, captionDetailBody != nil || hasCaptionTiming {
                captionTooltip(isError: model.errorCaption != nil)
                    .fixedSize(horizontal: true, vertical: true)
                    .offset(y: Self.cellHeight + Self.tipGap)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
                    .zIndex(25)
            }
        }
        // Status tip *below* the chip — upward tips get clipped by the hardware notch.
        .overlay(alignment: .topTrailing) {
            if statusHovered {
                statusTooltip
                    .offset(x: -2, y: Self.statusHit + 6)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }
        }
        // Elevate this *slot* in GaugeClusterView’s HStack (sibling zIndex only
        // works between slots — an inner zIndex cannot paint over later widgets).
        .preference(
            key: WidgetHoverElevatePreference.self,
            value: (isHovered || statusHovered || captionHovered) ? model.id : nil
        )
        .contextMenu {
            managedContextMenu
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    @ViewBuilder
    private var managedContextMenu: some View {
        if let account = AccountStore.shared.accounts.first(where: { $0.id == model.id }) {
            Button("Rename…") {
                AccountChromeActions.rename(accountID: account.id, currentLabel: account.label)
            }
            Button("Reauthenticate") {
                AccountChromeActions.reauthenticate(account: account)
            }
            Divider()
            Button("Remove…", role: .destructive) {
                AccountChromeActions.remove(accountID: account.id, label: account.label)
            }
        }
    }

    /// Hot chrome keys off **used** quota, never Remaining-flipped display %.
    private var isHot: Bool {
        model.usedPrimaryFraction >= 0.7 || model.burnRatio >= 1.5
    }

    /// Continuous card energy from burn (Apple-quiet: lift fill / warm edge, no bounce).
    private var cellBackground: some View {
        let burn = model.burnRatio
        let lift = BurnMotion.cellFillLift(ratio: burn)
        let borderBoost = BurnMotion.cellBorderBoost(ratio: burn)
        let warmth = BurnMotion.cellBorderWarmth(ratio: burn)
        let baseBorder: Double = {
            if isDropTarget { return 0.35 }
            if isHot || isHovered || isDragging { return 0.14 }
            return 0.06
        }()
        let borderOp = min(0.28, baseBorder + borderBoost)
        // White edge → slight warm red as pace rises past cruise.
        let w = min(1, max(0, warmth))
        let borderColor = isDropTarget
            ? Color.white
            : Color(
                red: 1.0 * (1 - w) + 0.97 * w,
                green: 1.0 * (1 - w) + 0.48 * w,
                blue: 1.0 * (1 - w) + 0.42 * w
            )
        let warmAccent = Color(red: 0.97, green: 0.48, blue: 0.42)

        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                RadialGradient(
                    colors: [
                        Color(white: min(0.12, (isHot ? 0.09 : 0.07) + lift)),
                        Color(white: 0.03)
                    ],
                    center: .init(x: 0.5, y: 0.40),
                    startRadius: 0,
                    endRadius: 70
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        borderColor.opacity(borderOp),
                        lineWidth: isDropTarget ? 1.5 : 1
                    )
            )
            // Faint warm outer veil only in overdrive — soft, not neon.
            .overlay {
                let od = BurnMotion.overdrive(ratio: burn)
                if od > 0.05 {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            warmAccent.opacity(0.06 + od * 0.10),
                            lineWidth: 1
                        )
                        .blur(radius: 0.6)
                }
            }
            .shadow(color: isDragging ? Color.black.opacity(0.45) : .clear, radius: isDragging ? 12 : 0, y: 6)
    }

    private var captionDetailBody: String? {
        if let detail = model.detailCaption, !detail.isEmpty { return detail }
        if let err = model.errorCaption, !err.isEmpty { return err }
        if let notice = model.noticeCaption, !notice.isEmpty { return notice }
        return nil
    }

    private var hasCaptionTiming: Bool {
        model.lastCheckedAt != nil || model.retryAt != nil || model.lastSuccessAt != nil
    }

    /// Fixed-height caption row — blank when healthy so layout never reflows.
    @ViewBuilder
    private var captionSlot: some View {
        if model.errorCaption != nil || model.noticeCaption != nil {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let isError = model.errorCaption != nil
                let text = liveShortCaption(now: context.date)
                captionLabel(text, isError: isError)
            }
        } else {
            Color.clear
                .accessibilityHidden(true)
        }
    }

    /// `rate limited · 3m` when we know the last poll time.
    private func liveShortCaption(now: Date) -> String {
        let base = model.errorCaption ?? model.noticeCaption ?? ""
        guard let checked = model.lastCheckedAt else { return base }
        let age = UsageOrchestrator.formatCompactAge(since: checked, now: now)
        return "\(base) · \(age)"
    }

    private func captionLabel(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundStyle(
                isError
                    ? Color(red: 0.97, green: 0.44, blue: 0.44).opacity(captionHovered ? 1 : 0.85)
                    : Color(red: 0.95, green: 0.78, blue: 0.35).opacity(captionHovered ? 1 : 0.9)
            )
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(captionHovered ? 0.08 : 0.03))
            )
            .frame(maxWidth: Self.cellSize - 10)
            .contentShape(Capsule())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.1)) {
                    captionHovered = hovering
                }
            }
            .accessibilityLabel(isError ? "error \(text)" : "notice \(text)")
            .accessibilityHint("Shows full message on hover")
            .zIndex(15)
    }

    /// Traffic-light with a real hit target (not just a 6pt circle).
    private var statusChip: some View {
        ZStack {
            Circle()
                .fill(Color.clear)
                .frame(width: Self.statusHit, height: Self.statusHit)
                .contentShape(Rectangle())

            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5)
                )
                .shadow(color: statusDotColor.opacity(0.55), radius: model.health == .ok ? 0 : 2)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                statusHovered = hovering
            }
        }
        .accessibilityLabel("status \(model.healthTooltip)")
        .accessibilityAddTraits(.isStaticText)
    }

    private var statusDotColor: Color {
        switch model.health {
        case .ok:
            return Color(red: 0.30, green: 0.82, blue: 0.50) // soft green
        case .warn:
            return Color(red: 0.95, green: 0.78, blue: 0.28)
        case .error:
            return Color(red: 0.97, green: 0.40, blue: 0.40)
        }
    }

    private var statusTooltip: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let timing = UsageOrchestrator.formatErrorTimingLines(
                lastCheckedAt: model.errorCaption != nil ? model.lastCheckedAt : nil,
                lastSuccessAt: model.errorCaption != nil ? model.lastSuccessAt : nil,
                retryAt: model.errorCaption != nil ? model.retryAt : nil,
                now: context.date
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(model.healthTooltip)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.92))
                ForEach(Array(timing.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(white: 0.62))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
            )
            .fixedSize()
        }
    }

    /// Preferred reading width for multi-line warning tips (status chip uses
    /// single-line `fixedSize()`; long auth/rate-limit copy needs a card width).
    private static let captionTipWidth: CGFloat = 268

    private func captionTooltip(isError: Bool) -> some View {
        // Explicit width so overlay does not clamp to the 100pt cell proposal.
        // TimelineView keeps “checked / retry in” fresh while the tip is open.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let body = captionDetailBody ?? ""
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
            .frame(width: Self.captionTipWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            )
            .overlay(alignment: .top) {
                Triangle()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .frame(width: 10, height: 5)
                    .offset(y: -5)
            }
        }
    }

    /// Usage windows only — burn is the red needle, not a debug caption.
    private var usageTooltip: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(model.hoverWindows.enumerated()), id: \.offset) { _, row in
                    Text(Self.formatHoverRow(row, now: context.date))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(white: 0.90))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
            )
            .overlay(alignment: .top) {
                Triangle()
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                    .frame(width: 10, height: 5)
                    .offset(y: -5)
            }
        }
    }

    /// `wk  12%  ·  1d 5h` when reset is known.
    private static func formatHoverRow(_ row: HoverWindowLine, now: Date) -> String {
        if let resetAt = row.resetAt,
           let reset = UsageOrchestrator.formatResetRemaining(until: resetAt, now: now)
        {
            return "\(row.label)  \(row.usage)  ·  \(reset)"
        }
        return "\(row.label)  \(row.usage)"
    }

    private var accessibilitySummary: String {
        var parts = ["\(model.title), \(model.centerPercent) percent"]
        if let caption = model.errorCaption, !caption.isEmpty {
            parts.append(caption)
        }
        parts.append(contentsOf: model.hoverLines)
        return parts.joined(separator: ". ")
    }
}

/// Simple upward-pointing caret for tooltip.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Hovering a widget tip must raise its **slot** above later HStack siblings.
enum WidgetHoverElevatePreference: PreferenceKey {
    static var defaultValue: AccountID? { nil }

    static func reduce(value: inout AccountID?, nextValue: () -> AccountID?) {
        if let next = nextValue() {
            value = next
        }
    }
}
