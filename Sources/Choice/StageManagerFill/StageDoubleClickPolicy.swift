import CoreGraphics

/// One element between the clicked element and its window, nearest first.
struct StageAXNode: Equatable {
    var role: String?
    var subrole: String? = nil
    var actions: [String] = []
    /// Accessibility coordinates; read only for container roles.
    var frame: CGRect? = nil
}

enum StageDoubleClickRegion: Equatable {
    /// The row that holds the close, minimize and zoom buttons, including a unified
    /// toolbar or a browser's tab strip.
    case titleRow
    /// A full-height column at the window's leading edge, such as vertical tabs or a
    /// conversation list, whose empty space works like a title bar.
    case sidebar
}

/// Decides whether a double-click lands on empty window chrome. Anything that reacts to
/// a click itself keeps the click: buttons, tabs, rows, links, text fields, and the
/// content of web pages shown inside a browser.
enum StageDoubleClickPolicy {
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuBarItem",
        "AXMenuItem", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider", "AXIncrementor",
        "AXLink", "AXRow", "AXCell", "AXDisclosureTriangle", "AXColorWell", "AXDateField",
        "AXSegmentedControl", "AXTab", "AXHandle", "AXSplitter", "AXScrollBar", "AXValueIndicator"
    ]
    static let interactiveSubroles: Set<String> = [
        "AXSearchField", "AXSecureTextField", "AXTabButton", "AXOutlineRow", "AXTableRow",
        "AXSortButton", "AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"
    ]
    static let interactiveActions: Set<String> = [
        "AXPress", "AXPick", "AXConfirm", "AXIncrement", "AXDecrement"
    ]
    /// Roles whose frame is read to recognize a sidebar column.
    static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXOutline", "AXList", "AXTable", "AXTabGroup",
        "AXWebArea", "AXLayoutArea", "AXUnknown", "AXBrowser", "AXRadioGroup"
    ]

    static func isInteractive(_ node: StageAXNode) -> Bool {
        if let role = node.role, interactiveRoles.contains(role) { return true }
        if let subrole = node.subrole, interactiveSubroles.contains(subrole) { return true }
        // A window title reports a press action for its path menu, yet double-clicking it
        // zooms the window. Text inside a button, link or row is caught by that ancestor.
        if node.role == "AXStaticText" { return false }
        return !interactiveActions.isDisjoint(with: node.actions)
    }

    static func titleRowHeight(window: CGRect, greenButton: CGRect) -> CGFloat {
        // The traffic lights are centred in the title bar, unified toolbar or tab strip.
        max(28, ((greenButton.midY - window.minY) * 2).rounded())
    }

    static func region(at point: CGPoint, window: CGRect, greenButton: CGRect,
                       path: [StageAXNode]) -> StageDoubleClickRegion? {
        guard window.contains(point), !path.contains(where: isInteractive) else { return nil }
        let rowHeight = titleRowHeight(window: window, greenButton: greenButton)
        // Leave the traffic-light buttons and the gaps between them alone.
        let lights = CGRect(x: window.minX, y: greenButton.minY - 4,
                            width: greenButton.maxX + 6 - window.minX, height: greenButton.height + 8)
        if lights.contains(point) { return nil }
        if point.y <= window.minY + rowHeight { return .titleRow }

        // A web page inside a browser is content, even when it has a left column of its
        // own. A web area filling the whole window is an Electron or web-view app's UI.
        if path.contains(where: { node in
            guard node.role == "AXWebArea" else { return false }
            guard let frame = node.frame else { return true }
            return frame.minY > window.minY + 2 || frame.height < window.height - 2
        }) { return nil }

        let isSidebar = path.contains { node in
            guard let frame = node.frame, frame.contains(point) else { return false }
            return frame.minX <= window.minX + 3 &&
                frame.width >= 30 && frame.width <= window.width * 0.45 &&
                frame.height >= window.height * 0.5 &&
                frame.minY <= window.minY + rowHeight + 12
        }
        return isSidebar ? .sidebar : nil
    }
}
