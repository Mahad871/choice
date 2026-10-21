import AppKit
import ApplicationServices

struct StageWindowTarget {
    let window: AXUIElement
    let pid: pid_t
    let greenButton: CGRect
    let frame: CGRect
}

enum StageWindowTargeting {
    static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else {
            return nil
        }
        return result
    }

    static func element(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let result = value(name, of: element),
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = value(kAXPositionAttribute, of: element),
              let size = value(kAXSizeAttribute, of: element),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    static func target(window: AXUIElement, pid: pid_t) -> StageWindowTarget? {
        AXUIElementSetMessagingTimeout(window, 0.05)
        guard value(kAXSubroleAttribute, of: window) as? String == kAXStandardWindowSubrole,
              value(kAXMinimizedAttribute, of: window) as? Bool != true,
              let windowFrame = frame(of: window),
              let green = element(kAXFullScreenButtonAttribute, of: window)
                ?? element(kAXZoomButtonAttribute, of: window),
              let greenFrame = frame(of: green), !greenFrame.isEmpty,
              windowFrame.insetBy(dx: -1, dy: -1).contains(greenFrame) else { return nil }
        return StageWindowTarget(window: window, pid: pid,
                                 greenButton: greenFrame, frame: windowFrame)
    }

    static func focused(pid: pid_t) -> StageWindowTarget? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window = element(kAXFocusedWindowAttribute, of: app) else { return nil }
        return target(window: window, pid: pid)
    }

    /// Resolves a double-click to the window whose empty title row or sidebar was
    /// clicked. Runs inside the mouse event tap, so it stops after a short budget
    /// rather than delay the click when an app is slow to answer.
    static func doubleClickTarget(at point: CGPoint, excluding ownPID: pid_t,
                                  budget: TimeInterval = 0.25) -> (StageWindowTarget, StageDoubleClickRegion)? {
        let start = ProcessInfo.processInfo.systemUptime
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ownPID else { return nil }
        AXUIElementSetMessagingTimeout(hit, 0.05)

        var path: [StageAXNode] = []
        var window: AXUIElement?
        var current = hit
        for _ in 0..<16 {
            guard ProcessInfo.processInfo.systemUptime - start < budget else { return nil }
            let role = value(kAXRoleAttribute, of: current) as? String
            if role == kAXWindowRole as String { window = current; break }
            path.append(node(current, role: role))
            guard let parent = element(kAXParentAttribute, of: current) else { break }
            AXUIElementSetMessagingTimeout(parent, 0.05)
            current = parent
        }
        guard let window = window ?? element(kAXWindowAttribute, of: hit),
              let target = target(window: window, pid: pid) else { return nil }
        // Hit-testing can stop short of the element under the pointer: Chromium reports
        // its whole browser frame for the tab strip, and some Electron apps, ChatGPT among
        // them, lay an invisible full-window group over their UI. Walk down to the deepest
        // element instead, from the window when an overlay was hit.
        let hitIsLayer = path.first?.subrole == "AXEmptyGroup" ||
            (path.count >= 2 && path[0].role == "AXGroup" && path[0].frame != nil && path[0].frame == path[1].frame &&
             (value(kAXChildrenAttribute, of: hit) as? [AXUIElement])?.isEmpty ?? true)
        if hitIsLayer {
            guard let underneath = pathBeneath(point, from: window, start: start, budget: budget)
            else { return nil }
            path = underneath
        } else {
            guard let deeper = pathBeneath(point, from: hit, start: start, budget: budget) else { return nil }
            path = deeper + path
        }
        guard let region = StageDoubleClickPolicy.region(at: point, window: target.frame,
                                                         greenButton: target.greenButton, path: path)
        else { return nil }
        return (target, region)
    }

    /// Walks down from `element` through the frontmost child under `point`, skipping
    /// empty overlay groups. Returns the elements below `element`, nearest-first like a
    /// hit test, or nil when the time budget runs out.
    static func pathBeneath(_ point: CGPoint, from element: AXUIElement,
                            start: TimeInterval, budget: TimeInterval) -> [StageAXNode]? {
        var chain: [StageAXNode] = []
        var current = element
        var currentFrame = frame(of: element)
        for _ in 0..<32 {
            guard let children = value(kAXChildrenAttribute, of: current) as? [AXUIElement],
                  !children.isEmpty else { break }
            var next: (AXUIElement, StageAXNode)?
            for child in children.reversed().prefix(400) {
                guard ProcessInfo.processInfo.systemUptime - start < budget else { return nil }
                AXUIElementSetMessagingTimeout(child, 0.05)
                guard let frame = frame(of: child), frame.contains(point) else { continue }
                let role = value(kAXRoleAttribute, of: child) as? String
                var node = node(child, role: role)
                guard node.subrole != "AXEmptyGroup" else { continue }
                // A childless group covering its whole parent is a transparent layer.
                if role == "AXGroup", frame == currentFrame,
                   (value(kAXChildrenAttribute, of: child) as? [AXUIElement])?.isEmpty ?? true { continue }
                node.frame = frame
                next = (child, node)
                break
            }
            guard let (element, node) = next else { break }
            chain.append(node)
            current = element
            currentFrame = node.frame
        }
        return chain.reversed()
    }

    private static func node(_ element: AXUIElement, role: String?) -> StageAXNode {
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let isContainer = role.map(StageDoubleClickPolicy.containerRoles.contains) ?? true
        return StageAXNode(role: role,
                           subrole: value(kAXSubroleAttribute, of: element) as? String,
                           actions: actions as? [String] ?? [],
                           frame: isContainer ? frame(of: element) : nil)
    }
}
