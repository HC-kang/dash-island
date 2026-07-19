import SwiftUI

/// Square account cell: gauge + label + hover tooltip below.
struct AccountWidget: View {
    let model: WidgetViewModel

    @State private var isHovered = false

    /// Outer cell size (gauge sits inside with padding).
    static let cellSize: CGFloat = 100
    private static let gaugeSize: CGFloat = 84

    var body: some View {
        VStack(spacing: 2) {
            GaugeRingView(
                primaryFraction: model.primaryFraction,
                secondaryFraction: model.secondaryFraction,
                centerPercent: model.centerPercent,
                burnRatio: model.burnRatio,
                tint: model.tint,
                size: Self.gaugeSize
            )

            Text(model.title)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.42))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: Self.cellSize - 8)

            if let caption = model.errorCaption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.97, green: 0.44, blue: 0.44).opacity(0.85))
                    .lineLimit(1)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(width: Self.cellSize, height: Self.cellSize + 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: isHot ? 0.09 : 0.07),
                            Color(white: 0.03)
                        ],
                        center: .init(x: 0.5, y: 0.40),
                        startRadius: 0,
                        endRadius: 70
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHot || isHovered ? 0.12 : 0.06), lineWidth: 1)
                )
        )
        .overlay(alignment: .top) {
            if isHovered, !model.hoverLines.isEmpty {
                tooltip
                    .fixedSize()
                    // Sit just below the cell.
                    .offset(y: Self.cellSize + 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(10)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contextMenu { managedContextMenu }
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

    private var isHot: Bool {
        model.primaryFraction >= 0.7 || model.burnRatio >= 1.5
    }

    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.hoverLines.enumerated()), id: \.offset) { _, line in
                Text(line)
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
        // Small upward caret.
        .overlay(alignment: .top) {
            Triangle()
                .fill(Color(red: 0.08, green: 0.08, blue: 0.09))
                .frame(width: 10, height: 5)
                .offset(y: -5)
        }
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
