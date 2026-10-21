import AppKit
import ApplicationServices

enum StageFillOutcome {
    case filled(display: String, requested: CGRect, actual: CGRect)
    case restored(requested: CGRect, actual: CGRect)
    case needsAccessibility
    case unavailable(String)
}

final class StageFillWindowManager {
    // Accessed only on the feature's serial window-action queue. Keep AX
    // identities separate, including multiple windows owned by the same app.
    private var restoreFrames: [(window: AXUIElement, state: StageRestoreState)] = []

    /// Fills `window`, or with `toggle` restores it when it is still where an earlier
    /// fill left it. Uses the captured window even if focus changes meanwhile.
    func fill(window: AXUIElement, layout: StageFillLayout, displays: [StageDisplay],
              primaryScreenTop primaryTop: CGFloat, toggle: Bool = false) -> StageFillOutcome {
        guard AXIsProcessTrusted() else { return .needsAccessibility }
        AXUIElementSetMessagingTimeout(window, 2)
        guard stringAttribute(kAXRoleAttribute, of: window) == kAXWindowRole as String,
              stringAttribute(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole as String
        else { return .unavailable("Only standard app windows can be resized.") }
        if boolAttribute(kAXMinimizedAttribute, of: window) == true {
            return .unavailable("Restore the minimized window before filling it.")
        }
        if boolAttribute("AXFullScreen", of: window) == true {
            return .unavailable("This window is in full screen. Leave full screen first.")
        }
        for attribute in [kAXPositionAttribute, kAXSizeAttribute] {
            var isSettable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(window, attribute as CFString, &isSettable) == .success,
                  isSettable.boolValue else {
                return .unavailable("This app does not allow its window to be resized or moved.")
            }
        }
        guard let original = frame(of: window) else {
            return .unavailable("The window frame is unavailable.")
        }
        guard let display = StageFillGeometry.displayContainingMost(
            of: original, displays: displays, primaryTop: primaryTop
        ) else { return .unavailable("The window is not on a connected display.") }
        if StageFillGeometry.coversEntireDisplay(original, display: display, primaryTop: primaryTop) {
            return .unavailable("This window appears to be in full screen. Leave full screen first.")
        }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let writer = frameWriter(for: window)
        let saved = restoreFrames.first { CFEqual($0.window, window) }?.state.restoreFrame(current: original)

        if toggle, let saved {
            // Do not restore to a disconnected display or a now-hidden title bar.
            let titleBar = CGRect(x: saved.minX, y: saved.minY, width: saved.width, height: 24)
            let reachable = displays.contains {
                let visible = StageFillGeometry.axFrame(fromAppKit: $0.visibleFrame, primaryTop: primaryTop)
                let overlap = visible.intersection(titleBar)
                return overlap.width >= min(120, titleBar.width) && overlap.height >= 20
            }
            guard reachable else {
                return .unavailable("The previous window position is no longer visible on a connected display. Move the window to choose a new starting position.")
            }
            let result = withPlainAnimations(pid: pid) { writer.apply(saved) }
            log("Stage Fill restore \(appName(pid)): \(original) → \(saved): \(result)")
            switch result {
            case .placed(let actual), .constrained(let actual):
                restoreFrames.removeAll { CFEqual($0.window, window) }
                return .restored(requested: saved, actual: actual)
            case .misplaced, .refused:
                _ = withPlainAnimations(pid: pid) { writer.apply(original) }
                return .unavailable("The app did not return to its previous size and position.")
            }
        }

        let target = layout.target(for: display, primaryTop: primaryTop)
        if StageFrameWriter.matches(original, target) {
            // Already filled. Keep any earlier restore frame for the next toggle.
            return .filled(display: display.name, requested: target, actual: original)
        }
        let result = withPlainAnimations(pid: pid) { writer.apply(target) }
        log("Stage Fill \(appName(pid)) on \(display.name): \(original) → \(target): \(result)")
        switch result {
        case .placed(let actual), .constrained(let actual):
            // Repeated explicit Fill commands must not overwrite the original frame.
            restoreFrames.removeAll { CFEqual($0.window, window) }
            restoreFrames.append((window, StageRestoreState(original: saved ?? original, filled: actual)))
            if restoreFrames.count > 128 { restoreFrames.removeFirst() }
            return .filled(display: display.name, requested: target, actual: actual)
        case .misplaced:
            let restored = withPlainAnimations(pid: pid) { writer.apply(original) }
            if case .placed = restored {
                return .unavailable("The app kept its window from moving there. Its minimum size or aspect ratio may prevent a fill.")
            }
            return .unavailable("The app kept its window from moving there and did not fully return to its previous frame.")
        case .refused:
            _ = withPlainAnimations(pid: pid) { writer.apply(original) }
            return .unavailable("The app refused to move or resize its window.")
        }
    }

    /// Chromium and Electron apps animate and reorder frame writes while
    /// AXEnhancedUserInterface is on, which can leave the window at its old origin.
    /// Window managers switch it off for the move and restore it afterwards.
    private func withPlainAnimations<T>(pid: pid_t, _ body: () -> T) -> T {
        guard pid > 0 else { return body() }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        let enhanced = boolAttribute("AXEnhancedUserInterface", of: application) == true
        if enhanced {
            AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        }
        defer {
            if enhanced {
                AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
        }
        return body()
    }

    private func frameWriter(for window: AXUIElement) -> StageFrameWriter {
        StageFrameWriter(
            read: { [weak self] in self?.frame(of: window) },
            setPosition: { point in
                var point = point
                guard let value = AXValueCreate(.cgPoint, &point) else { return false }
                return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
            },
            setSize: { size in
                var size = size
                guard let value = AXValueCreate(.cgSize, &size) else { return false }
                return AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
            })
    }

    private func appName(_ pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    private func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        StageWindowTargeting.frame(of: window)
    }
}
