import AppKit
import Combine
import CoreGraphics
import Foundation

/// Which display hosts the island.
///
/// - `.auto`: first notched screen, else `NSScreen.main`
/// - `.followCursor`: island moves to the display under the mouse (hysteresis in window controller)
/// - `.stable`: pin to a CFUUID so it survives unplug/replug
@MainActor
final class TargetDisplayStore: ObservableObject {
    static let shared = TargetDisplayStore()

    enum Choice: Equatable {
        case auto
        case followCursor
        case stable(id: String)

        var rawValue: String {
            switch self {
            case .auto: return "auto"
            case .followCursor: return "followCursor"
            case .stable(let id): return id
            }
        }

        init(rawValue: String?) {
            switch rawValue {
            case nil, "", "auto": self = .auto
            case "follow", "followCursor": self = .followCursor
            case let id?: self = .stable(id: id)
            }
        }
    }

    private static let key = "DashIsland.targetDisplay"

    @Published var choice: Choice {
        didSet {
            UserDefaults.standard.set(choice.rawValue, forKey: Self.key)
            if case .followCursor = choice {
                // Seed from mouse immediately so first paint isn't empty.
                if let under = DisplayInfo.infoContainingMouse() {
                    followLiveStableID = under.stableID
                }
            } else {
                followLiveStableID = nil
            }
            NotificationCenter.default.post(name: .dashIslandTargetDisplayChanged, object: nil)
        }
    }

    /// Non-persisted live target while `choice == .followCursor`.
    @Published private(set) var followLiveStableID: String?

    private init() {
        let loaded = Choice(rawValue: UserDefaults.standard.string(forKey: Self.key))
        choice = loaded
        if case .followCursor = loaded, let under = DisplayInfo.infoContainingMouse() {
            followLiveStableID = under.stableID
        }
    }

    /// Update follow-cursor resolution without rewriting prefs.
    func setFollowLive(stableID: String) {
        guard followLiveStableID != stableID else { return }
        followLiveStableID = stableID
        NotificationCenter.default.post(name: .dashIslandTargetDisplayChanged, object: nil)
    }
}

extension Notification.Name {
    static let dashIslandTargetDisplayChanged = Notification.Name("dashIslandTargetDisplayChanged")
}

/// One connected display the island can sit on.
struct DisplayInfo: Equatable {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let stableID: String
    let name: String
    let isBuiltin: Bool
    let hasNotch: Bool

    /// Connected screens with stable IDs.
    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap(make(from:))
    }

    /// Display containing a global AppKit point (e.g. `NSEvent.mouseLocation`).
    static func infoContaining(_ point: NSPoint) -> DisplayInfo? {
        all().first { $0.screen.frame.contains(point) }
    }

    static func infoContainingMouse() -> DisplayInfo? {
        infoContaining(NSEvent.mouseLocation)
    }

    @MainActor
    static func currentTarget() -> DisplayInfo? {
        let all = Self.all()
        switch TargetDisplayStore.shared.choice {
        case .auto:
            return autoPick(from: all)
        case .followCursor:
            if let id = TargetDisplayStore.shared.followLiveStableID,
               let hit = all.first(where: { $0.stableID == id })
            {
                return hit
            }
            return infoContainingMouse() ?? autoPick(from: all)
        case .stable(let id):
            return all.first(where: { $0.stableID == id }) ?? autoPick(from: all)
        }
    }

    @MainActor
    static func currentScreen() -> NSScreen? {
        currentTarget()?.screen ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func autoPick(from all: [DisplayInfo]) -> DisplayInfo? {
        all.first(where: \.hasNotch)
            ?? all.first(where: { $0.screen == NSScreen.main })
            ?? all.first
    }

    private static func make(from screen: NSScreen) -> DisplayInfo? {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else {
            return nil
        }
        guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }
        let uuid = unmanaged.takeRetainedValue()
        guard let stable = CFUUIDCreateString(nil, uuid) as String? else {
            return nil
        }
        let hasNotch = screen.safeAreaInsets.top > 0
        return DisplayInfo(
            screen: screen,
            displayID: displayID,
            stableID: stable,
            name: screen.localizedName,
            isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
            hasNotch: hasNotch
        )
    }
}
