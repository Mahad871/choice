import AppKit

enum StageStripSide: String {
    case left, right
}

/// Stage Manager and window-tiling settings that change where a filled window belongs.
/// They are read from the system's own preference domains, so changes in System Settings
/// apply on the next fill without restarting the app.
struct StageManagerSettings: Equatable {
    var enabled: Bool
    /// "Show recent apps in Stage Manager". When off, the strip appears only on demand.
    var showsRecentApps: Bool
    var dockOnLeft: Bool
    /// System Settings → Desktop & Dock → "Double-click a window's title bar to".
    var titleBarDoubleClickAction: String

    /// Stage Manager moves its strip to the right edge when the Dock is on the left.
    var expectedStripSide: StageStripSide { dockOnLeft ? .right : .left }
    var reservesStrip: Bool { enabled && showsRecentApps }
    /// Only replace a double-click that already resizes the window; Minimize and
    /// Do Nothing are deliberate choices.
    var titleBarDoubleClickResizes: Bool {
        !["minimize", "none", "do nothing"].contains(titleBarDoubleClickAction.lowercased())
    }

    static func current() -> StageManagerSettings {
        let windowManager = UserDefaults(suiteName: "com.apple.WindowManager")
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
        return StageManagerSettings(
            enabled: windowManager?.object(forKey: "GloballyEnabled") as? Bool ?? false,
            showsRecentApps: !(windowManager?.object(forKey: "AutoHide") as? Bool ?? false),
            dockOnLeft: dock?.string(forKey: "orientation") == "left",
            titleBarDoubleClickAction: global["AppleActionOnDoubleClick"] as? String
                ?? ((global["AppleMiniaturizeOnDoubleClick"] as? Bool) == true ? "Minimize" : "Fill")
        )
    }
}

/// A window drawn by Stage Manager, in Accessibility coordinates (top-left origin).
struct StageStripWindow: Equatable {
    let frame: CGRect
    let alpha: CGFloat
}

struct StageStripMeasurement: Equatable {
    let side: StageStripSide
    /// Distance from the display edge to the far edge of the strip's thumbnails.
    let extent: CGFloat
}

enum StageStrip {
    /// Stage Manager's recent-app thumbnails are ordinary layer-0 windows owned by
    /// WindowManager; their bounds are readable without Screen Recording access.
    static func windows() -> [StageStripWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard info[kCGWindowOwnerName as String] as? String == "WindowManager",
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1
            return StageStripWindow(frame: frame, alpha: alpha)
        }
    }

    /// Measures the visible strip on one display. Returns nil while the strip is hidden or
    /// sliding, so a partial measurement is never stored.
    static func measure(_ windows: [StageStripWindow], display: CGRect) -> StageStripMeasurement? {
        let thumbnails = windows.filter { window in
            let visible = window.frame.intersection(display)
            return window.alpha > 0.5 && !visible.isNull &&
                visible.width >= 24 && visible.height >= 24 &&
                window.frame.width < display.width / 4 && window.frame.height < display.height / 2
        }
        guard !thumbnails.isEmpty else { return nil }
        let left = thumbnails.filter { $0.frame.midX < display.midX }
        let right = thumbnails.filter { $0.frame.midX >= display.midX }
        let limit = display.width * 0.3
        if left.count >= right.count {
            let extent = (left.map(\.frame.maxX).max() ?? display.minX) - display.minX
            // A thumbnail that has slid mostly off-screen means the strip is hiding.
            guard extent >= 48, extent <= limit,
                  left.allSatisfy({ $0.frame.minX >= display.minX - $0.frame.width / 2 }) else { return nil }
            return StageStripMeasurement(side: .left, extent: extent)
        }
        let extent = display.maxX - (right.map(\.frame.minX).min() ?? display.maxX)
        guard extent >= 48, extent <= limit,
              right.allSatisfy({ $0.frame.maxX <= display.maxX + $0.frame.width / 2 }) else { return nil }
        return StageStripMeasurement(side: .right, extent: extent)
    }

    /// Used before the strip has been seen on a display. Stage Manager scales its
    /// thumbnails with the display; 1920-point displays measure about 166 points.
    static func estimatedExtent(displayWidth: CGFloat) -> CGFloat {
        min(max((displayWidth * 0.0865).rounded(), 140), 220)
    }
}
