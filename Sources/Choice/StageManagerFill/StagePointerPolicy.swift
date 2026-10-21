import CoreGraphics
import Foundation

/// Only intercept the second click of an ordinary, stationary double-click.
/// Eligibility of the actual AX element is checked separately before swallowing.
struct StageClickSequence {
    private var firstPoint: CGPoint?
    private var firstTime: TimeInterval = 0

    mutating func down(at point: CGPoint, time: TimeInterval, count: Int,
                       unmodified: Bool, interval: TimeInterval) -> Bool {
        defer {
            firstPoint = count == 1 && unmodified ? point : nil
            firstTime = time
        }
        guard count == 2, unmodified, let firstPoint,
              time >= firstTime, time - firstTime <= interval + 0.05 else { return false }
        return hypot(point.x - firstPoint.x, point.y - firstPoint.y) <= 5
    }
}

/// A window listed by the window server, in Accessibility coordinates.
struct StageListedWindow {
    let owner: String
    let layer: Int
    let frame: CGRect

    static func onScreen() -> [StageListedWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return StageListedWindow(owner: owner, layer: info[kCGWindowLayer as String] as? Int ?? 0, frame: frame)
        }
    }
}

/// macOS draws the menu that appears over the green button in AppKit's
/// ThemeWidgetControlViewService. Its window is listed with the window server, so the
/// companion can attach to the real menu rather than guess where it is.
enum StageZoomMenu {
    static let owner = "ThemeWidgetControlViewService"
    /// The menu window includes a transparent margin around the visible menu for its shadow.
    static let shadowInset: CGFloat = 14

    /// The visible menu for `greenButton`, both in AX coordinates.
    static func locate(near greenButton: CGRect, in windows: [StageListedWindow]) -> CGRect? {
        windows.lazy.filter { $0.owner == owner }.map { $0.frame.insetBy(dx: shadowInset, dy: shadowInset) }
            .first { menu in
                guard menu.width >= 120, menu.height >= 60,
                      menu.minX <= greenButton.maxX, menu.maxX >= greenButton.minX + 40 else { return false }
                let below = menu.minY >= greenButton.maxY - 6 && menu.minY <= greenButton.maxY + 40
                let above = menu.maxY <= greenButton.minY + 6 && menu.maxY >= greenButton.minY - 40
                return below || above
            }
    }
}

enum StageCompanionGeometry {
    static let gap: CGFloat = 6

    /// AppKit frame for the card docked to Apple's menu: below it, or above it when the
    /// menu opened upward, or beside it when there is no room on either side.
    static func docked(to menu: CGRect, button: CGRect, height: CGFloat, visible: CGRect) -> CGRect {
        let opensUp = menu.minY >= button.maxY - 6
        var frame = CGRect(x: menu.minX, y: opensUp ? menu.maxY + gap : menu.minY - gap - height,
                           width: menu.width, height: height)
        if frame.minY < visible.minY || frame.maxY > visible.maxY {
            frame = CGRect(x: menu.maxX + gap, y: opensUp ? menu.minY : menu.maxY - height,
                           width: menu.width, height: height)
        }
        frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - frame.width - 4)
        return frame
    }

    /// AppKit frame used when Apple's menu cannot be found: a card under the button,
    /// in the place the menu would normally occupy.
    static func standalone(below button: CGRect, height: CGFloat, width: CGFloat,
                           visible: CGRect) -> CGRect {
        var frame = CGRect(x: button.minX - 18, y: button.minY - 8 - height, width: width, height: height)
        if frame.minY < visible.minY { frame.origin.y = button.maxY + 8 }
        frame.origin.x = min(max(frame.minX, visible.minX + 4), visible.maxX - frame.width - 4)
        return frame
    }

    /// The area that keeps the companion open: the button, Apple's menu, the card, and
    /// the corridor between them, so a diagonal move does not close it.
    static func keepAlive(button: CGRect, menu: CGRect?, card: CGRect) -> [CGRect] {
        var areas = [button.insetBy(dx: -6, dy: -6), card.insetBy(dx: -8, dy: -8)]
        if let menu {
            areas.append(menu.insetBy(dx: -6, dy: -6))
            areas.append(menu.union(card))
        } else {
            areas.append(button.union(card).insetBy(dx: -6, dy: -2))
        }
        return areas
    }
}
