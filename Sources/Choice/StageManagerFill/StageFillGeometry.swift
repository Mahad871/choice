import AppKit
import ColorSync

/// Both AppKit and Accessibility use logical screen points. AX's origin is at
/// the top of the primary display; AppKit's is at its bottom.
struct StageDisplay {
    let key: String
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect

    static func connected() -> [StageDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let identifier = number.uint32Value
            let key: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(identifier)?.takeRetainedValue(),
               let description = CFUUIDCreateString(nil, uuid) {
                key = description as String
            } else {
                key = "display-\(identifier)"
            }
            return StageDisplay(key: key, name: screen.localizedName,
                                frame: screen.frame, visibleFrame: screen.visibleFrame)
        }
    }
}

/// Space kept free beside a filled window, measured from the display's edge.
struct StageReservation: Equatable {
    var side: StageStripSide
    var inset: CGFloat

    static let none = StageReservation(side: .left, inset: 0)
}

/// Everything needed to place a window, captured on the main thread before a fill.
struct StageFillLayout {
    var reservations: [String: StageReservation]

    func reservation(for display: StageDisplay) -> StageReservation {
        reservations[display.key] ?? .none
    }

    func target(for display: StageDisplay, primaryTop: CGFloat) -> CGRect {
        StageFillGeometry.targetFrame(for: display, reservation: reservation(for: display), primaryTop: primaryTop)
    }
}

enum StageFillGeometry {
    /// Space between Stage Manager's thumbnails and a filled window. It matches the
    /// thumbnails' own inset from the display edge.
    static let stripGap: CGFloat = 15

    static func coversEntireDisplay(_ axWindow: CGRect, display: StageDisplay,
                                    primaryTop: CGFloat) -> Bool {
        // There is no documented cross-app AX full-screen flag. Conservatively
        // skip windows covering the raw display, while allowing Apple's normal
        // Fill state, which covers the smaller visibleFrame.
        let displayAX = axFrame(fromAppKit: display.frame, primaryTop: primaryTop)
        return abs(axWindow.minX - displayAX.minX) < 3 &&
            abs(axWindow.minY - displayAX.minY) < 3 &&
            abs(axWindow.width - displayAX.width) < 3 &&
            abs(axWindow.height - displayAX.height) < 3
    }

    static func appKitFrame(fromAX ax: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: ax.minX, y: primaryTop - ax.maxY, width: ax.width, height: ax.height)
    }

    static func axFrame(fromAppKit frame: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryTop - frame.maxY,
               width: frame.width, height: frame.height)
    }

    static func displayContainingMost(of axWindow: CGRect, displays: [StageDisplay],
                                        primaryTop: CGFloat) -> StageDisplay? {
        let appKitWindow = appKitFrame(fromAX: axWindow, primaryTop: primaryTop)
        var selected: StageDisplay?
        var largestOverlap: CGFloat = 0
        for display in displays {
            let intersection = appKitWindow.intersection(display.frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > largestOverlap {
                selected = display
                largestOverlap = area
            }
        }
        return selected
    }

    /// Returns the AX frame for a filled window: the display's visible area, like
    /// Apple's Fill (which has no margins), less the reserved space on the strip's side.
    static func targetFrame(for display: StageDisplay, reservation: StageReservation,
                            primaryTop: CGFloat) -> CGRect {
        var area = display.visibleFrame
        // Keep a useful window even on a very small display. The real app may
        // impose a larger minimum; the AX readback reports that constraint.
        let minimumWidth = min(320, floor(area.width / 2))
        let inset = max(0, reservation.inset)
        switch reservation.side {
        case .left:
            let edge = min(max(area.minX, display.frame.minX + inset), area.maxX - minimumWidth)
            area.size.width = area.maxX - edge
            area.origin.x = edge
        case .right:
            let edge = max(min(area.maxX, display.frame.maxX - inset), area.minX + minimumWidth)
            area.size.width = edge - area.minX
        }
        return axFrame(fromAppKit: area.integral, primaryTop: primaryTop)
    }
}
