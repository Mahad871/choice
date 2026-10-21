import AppKit
import ApplicationServices

/// Pointer interactions over other apps' windows: the card under the green-button menu
/// and the double-click on a title row or sidebar.
final class StageWindowInteractions: NSObject {
    private let preferences: StageFillPreferences
    private let preview: Bool
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Called with the captured window and whether a second invocation restores it.
    var onInvoke: ((StageWindowTarget, Bool) -> Void)?
    /// The AX frame the window would fill, for the hover preview.
    var targetFrame: ((StageWindowTarget) -> CGRect?)?
    /// Whether Stage Manager Fill should replace a title-row double-click right now.
    var titleRowDoubleClickAllowed: (() -> Bool)?
    var shortcutTitle: String?
    var actionInProgress = false
    private(set) var doubleClickStatus = ""

    private var permissionTimer: Timer?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var clickSequence = StageClickSequence()
    private var swallowedMouseUp = false

    private var moveMonitor: Any?
    private var clickMonitor: Any?
    private var hoverTimer: Timer?
    private let lookupQueue = DispatchQueue(label: "Choice.stage-fill.hover", qos: .userInteractive)
    private var lookupInFlight = false
    private var lastLookup: TimeInterval = 0
    private var hovered: StageWindowTarget?
    private var hoverStart: TimeInterval?
    private var lastInside: TimeInterval = 0

    private let card = StageCompanionCard()
    private let overlay = StagePreviewOverlay()
    private var cardTarget: StageWindowTarget?
    private var cardMenu: CGRect?

    init(preferences: StageFillPreferences, preview: Bool) {
        self.preferences = preferences
        self.preview = preview
        super.init()
        card.row.onPress = { [weak self] in self?.invokeCard() }
        card.row.onHover = { [weak self] highlighted in self?.updatePreview(highlighted) }
    }

    func start() {
        refreshConfiguration()
        // Accessibility access can be granted while the app runs.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshConfiguration()
        }
    }

    deinit {
        permissionTimer?.invalidate()
        hoverTimer?.invalidate()
        [moveMonitor, clickMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        if let eventTap { CFMachPortInvalidate(eventTap) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
    }

    func refreshConfiguration() {
        let allowed = preferences.enabled && !preview && AXIsProcessTrusted()
        if allowed && preferences.greenButtonCompanion {
            if moveMonitor == nil {
                moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                    self?.pointerMoved()
                }
                clickMonitor = NSEvent.addGlobalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
                ) { [weak self] _ in self?.dismiss() }
            }
        } else {
            [moveMonitor, clickMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
            moveMonitor = nil
            clickMonitor = nil
            dismiss()
            hovered = nil
        }
        if allowed && preferences.titleBarDoubleClick {
            if eventTap == nil { installTap() }
            doubleClickStatus = eventTap == nil
                ? "Mouse access is unavailable. Check Accessibility access, then try again."
                : "Double-click an empty title bar, toolbar or tab sidebar to fill. Double-click again to restore."
        } else {
            if let eventTap { CFMachPortInvalidate(eventTap) }
            if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
            eventTap = nil
            eventSource = nil
            swallowedMouseUp = false
            clickSequence = StageClickSequence()
            doubleClickStatus = preview ? "Preview does not intercept clicks or show controls over other apps."
                : "Off. Title-bar double-clicks keep the action set in System Settings."
        }
        card.row.setShortcut(shortcutTitle)
    }

    // MARK: Double-click

    private func installTap() {
        let mask = (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let owner = Unmanaged<StageWindowInteractions>.fromOpaque(context).takeUnretainedValue()
            return owner.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return }
        eventTap = tap
        eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedMouseUp = false
            clickSequence = StageClickSequence()
            if preferences.enabled, preferences.titleBarDoubleClick, let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseUp, swallowedMouseUp {
            swallowedMouseUp = false
            return nil
        }
        guard type == .leftMouseDown, preferences.enabled, preferences.titleBarDoubleClick,
              !actionInProgress else {
            return Unmanaged.passUnretained(event)
        }
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard clickSequence.down(at: event.location, time: ProcessInfo.processInfo.systemUptime,
            count: Int(event.getIntegerValueField(.mouseEventClickState)),
            unmodified: event.flags.intersection(modifiers).isEmpty, interval: NSEvent.doubleClickInterval),
              case let (target, region)? = StageWindowTargeting.doubleClickTarget(at: event.location,
                                                                                  excluding: ownPID),
              region == .sidebar || titleRowDoubleClickAllowed?() ?? true
        else { return Unmanaged.passUnretained(event) }
        swallowedMouseUp = true
        DispatchQueue.main.async { [weak self] in
            self?.dismiss()
            self?.onInvoke?(target, true)
        }
        return nil
    }

    // MARK: Green-button companion

    private var primaryTop: CGFloat? { NSScreen.screens.first?.frame.maxY }

    private func pointerMoved() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        refreshHoveredWindow()
        tick()
    }

    /// Looks up the focused window's green button off the main thread, at most a few
    /// times a second while the pointer moves. Only window-level attributes are read, so
    /// browsers are not asked to build accessibility trees for their pages.
    private func refreshHoveredWindow() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !lookupInFlight, now - lastLookup >= 0.12,
              let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPID else { return }
        lookupInFlight = true
        lastLookup = now
        let pid = app.processIdentifier
        lookupQueue.async { [weak self] in
            let target = StageWindowTargeting.focused(pid: pid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lookupInFlight = false
                self.hovered = target
                if let cardTarget = self.cardTarget,
                   target.map({ !CFEqual($0.window, cardTarget.window) || $0.frame != cardTarget.frame }) ?? true {
                    // The window moved, closed or lost focus under the card.
                    self.dismiss()
                }
                self.tick()
            }
        }
    }

    private func tick() {
        guard preferences.enabled, preferences.greenButtonCompanion, !actionInProgress,
              let primaryTop else { dismiss(); return }
        let pointer = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if card.isVisible, let cardTarget {
            let button = StageFillGeometry.appKitFrame(fromAX: cardTarget.greenButton, primaryTop: primaryTop)
            if let menu = StageZoomMenu.locate(near: cardTarget.greenButton, in: StageListedWindow.onScreen()) {
                cardMenu = StageFillGeometry.appKitFrame(fromAX: menu, primaryTop: primaryTop)
            }
            let areas = StageCompanionGeometry.keepAlive(button: button, menu: cardMenu, card: card.panel.frame)
            if areas.contains(where: { $0.contains(pointer) }) {
                lastInside = now
            } else if now - lastInside > 0.3 {
                dismiss()
            }
            scheduleTimer()
            return
        }
        guard let target = hovered,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            hoverStart = nil
            return
        }
        let button = StageFillGeometry.appKitFrame(fromAX: target.greenButton, primaryTop: primaryTop)
        guard button.insetBy(dx: -2, dy: -2).contains(pointer) else {
            hoverStart = nil
            return
        }
        if hoverStart == nil { hoverStart = now }
        scheduleTimer()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) else { return }
        if let menu = StageZoomMenu.locate(near: target.greenButton, in: StageListedWindow.onScreen()) {
            // Appear together with Apple's menu, attached beneath it.
            let menuFrame = StageFillGeometry.appKitFrame(fromAX: menu, primaryTop: primaryTop)
            show(target: target, menu: menuFrame, frame: StageCompanionGeometry.docked(
                to: menuFrame, button: button, height: StageCompanionCard.height, visible: screen.visibleFrame))
        } else if now - (hoverStart ?? now) >= 1.2 {
            // Apple's menu did not appear (an older system, or an app that hides it).
            show(target: target, menu: nil, frame: StageCompanionGeometry.standalone(
                below: button, height: StageCompanionCard.height, width: 220, visible: screen.visibleFrame))
        }
    }

    /// Polls only while the pointer is on the green button or the card is open.
    private func scheduleTimer() {
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.hoverStart == nil && !self.card.isVisible {
                self.hoverTimer?.invalidate()
                self.hoverTimer = nil
                return
            }
            self.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func show(target: StageWindowTarget, menu: CGRect?, frame: CGRect) {
        cardTarget = target
        cardMenu = menu
        lastInside = ProcessInfo.processInfo.systemUptime
        card.row.setShortcut(shortcutTitle)
        card.panel.setFrame(frame, display: true)
        card.panel.fadeIn()
    }

    private func updatePreview(_ highlighted: Bool) {
        guard highlighted, let cardTarget, let primaryTop,
              let frame = targetFrame?(cardTarget) else { overlay.hide(); return }
        overlay.show(StageFillGeometry.appKitFrame(fromAX: frame, primaryTop: primaryTop))
    }

    private func invokeCard() {
        guard let target = cardTarget, preferences.enabled, preferences.greenButtonCompanion else { return }
        dismiss()
        onInvoke?(target, false)
    }

    func dismiss() {
        if card.panel.isVisible {
            card.row.setHighlighted(false)
            card.panel.fadeOut()
        }
        overlay.hide()
        cardTarget = nil
        cardMenu = nil
        hoverStart = nil
    }
}
