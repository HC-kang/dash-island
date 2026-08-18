import AppKit
import SwiftUI

/// Small vendor mark for the account widget (top-leading).
///
/// Assets sourced from public brand icon sets (Simple Icons Anthropic/OpenAI,
/// Lobe Icons Grok path), rasterized to white PNGs under
/// `Resources/VendorLogos/`.
struct VendorLogoView: View {
    let vendorID: VendorID
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let image = Self.image(for: vendorID) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Fallback monogram if asset missing from the bundle.
                Text(monogram)
                    .font(.system(size: size * 0.72, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var monogram: String {
        switch vendorID {
        case "claude": return "C"
        case "codex": return "O"
        case "grok": return "G"
        case "gemini": return "g"
        case "fake": return "F"
        default: return String(vendorID.prefix(1)).uppercased()
        }
    }

    /// Map vendor → resource name (png in VendorLogos/).
    private static func resourceName(for vendorID: VendorID) -> String? {
        switch vendorID {
        case "claude": return "claude"
        case "codex": return "openai" // Codex uses OpenAI mark
        case "grok": return "grok"
        default: return nil
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func image(for vendorID: VendorID) -> NSImage? {
        guard let name = resourceName(for: vendorID) else { return nil }
        if let hit = cache[name] { return hit }
        let img =
            NSImage(named: name)
            ?? loadFromBundle(name: name)
        if let img {
            // Keep white pixels as-is for dark island chrome (not template-tinted).
            img.isTemplate = false
            cache[name] = img
        }
        return img
    }

    private static func loadFromBundle(name: String) -> NSImage? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "VendorLogos") {
            return NSImage(contentsOf: url)
        }
        if let url = bundle.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        // Dev / unbundled: look next to the executable's Resources via relative path.
        if let res = bundle.resourceURL?
            .appendingPathComponent("VendorLogos", isDirectory: true)
            .appendingPathComponent("\(name).png")
        {
            return NSImage(contentsOf: res)
        }
        return nil
    }
}

/// Soft glass chip behind the vendor mark.
struct VendorLogoBadge: View {
    let vendorID: VendorID

    var body: some View {
        VendorLogoView(vendorID: vendorID, size: 11)
            .padding(4)
            .background(
                Circle()
                    .fill(Color.black.opacity(0.45))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )
            .opacity(0.92)
    }
}
