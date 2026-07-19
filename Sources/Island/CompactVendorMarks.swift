import SwiftUI

/// Decorative vendor marks flanking the compact notch (codex-island logo tabs).
struct CompactVendorMarks: View {
    let tints: [VendorTint]
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    static let tabWidth: CGFloat = 34

    var body: some View {
        HStack(spacing: 0) {
            mark(tints.first)
                .frame(width: Self.tabWidth, height: notchHeight)
            Color.clear.frame(width: notchWidth)
            mark(tints.count > 1 ? tints[1] : tints.first)
                .frame(width: Self.tabWidth, height: notchHeight)
                .opacity(tints.count > 1 ? 1 : 0.35)
        }
    }

    @ViewBuilder
    private func mark(_ tint: VendorTint?) -> some View {
        if let tint {
            Image(systemName: tint.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint.brandColor.opacity(0.92))
                .shadow(color: tint.brandColor.opacity(0.35), radius: 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}

extension VendorTint {
    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "circle.hexagongrid"
        case .grok: return "x.circle"
        case .neutral: return "circle.dashed"
        }
    }
}
