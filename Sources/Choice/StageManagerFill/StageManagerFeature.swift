import AppKit
import ApplicationServices

/// Coordinates Stage Manager Fill: where windows go, how fills are triggered, and the
/// feedback after each one.
///
/// Remembers the app that owned focus before the menu bar utility opens its menu.
/// Querying the frontmost app only after menu activation can select this utility's
/// own settings window instead of the window the user was working in.
final class StageManagerFeature {
    let preferences: StageFillPreferences
    let strip: StageStripTracker
    private let windowManager = StageFillWindowManager()
    private let preview: Bool
    private var activationObserver: NSObjectProtocol?
    private var lastExternalPID: pid_t?
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private lazy var interactions = StageWindowInteractions(preferences: preferences, preview: preview)
    private let fillQueue = DispatchQueue(label: "Choice.stage-fill.window-actions", qos: .userInitiated)
    private let toast = StageToast()
    let shortcut = GlobalShortcut(identifier: 2)
    private(set) var shortcutError: String?
    /// Reports outcomes that need the settings window, such as missing access.
    var onInteractionResult: ((StageFillOutcome) -> Void)?
    var onMeasurementChange: (() -> Void)?

    var interactionStatus: String { interactions.doubleClickStatus }
    /// True when Fill is blocked only by Accessibility access. The settings say so rather
    /// than calling the features off.
    var needsAccessibility: Bool { !preview && !AXIsProcessTrusted() }

    init(preferences: StageFillPreferences, preview: Bool = false) {
        self.preferences = preferences
        self.preview = preview
        strip = StageStripTracker(preferences: preferences)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  application.processIdentifier != self.ownPID else { return }
            self.lastExternalPID = application.processIdentifier
        }
    }

    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func startInteractions() {
        interactions.onInvoke = { [weak self] target, toggle in self?.fillCapturedWindow(target, toggle: toggle) }
        interactions.targetFrame = { [weak self] target in self?.previewTarget(for: target) }
        interactions.titleRowDoubleClickAllowed = { [weak self] in self?.replacesTitleRowDoubleClick ?? false }
        shortcut.onInvoke = { [weak self] in self?.fillFromShortcut() }
        strip.onChange = { [weak self] in self?.onMeasurementChange?() }
        refreshInteractions()
        interactions.start()
    }

    func refreshInteractions() {
        if !preview {
            let configuration = preferences.shortcut
            shortcutError = shortcut.configure(preferences.enabled ? configuration
                : ShortcutConfiguration(enabled: false))
            interactions.shortcutTitle = configuration.enabled && shortcutError == nil
                ? configuration.displayName : nil
            if preferences.enabled && preferences.reservationMode == .automatic { strip.start() } else { strip.stop() }
        }
        interactions.refreshConfiguration()
    }

    /// Title-row double-clicks are replaced only when they would resize the window anyway
    /// and there is space to keep free; otherwise macOS keeps handling them.
    private var replacesTitleRowDoubleClick: Bool {
        let settings = cachedSettings()
        guard settings.titleBarDoubleClickResizes else { return false }
        return settings.reservesStrip || preferences.reservationMode == .custom
    }

    private var settingsCache: (settings: StageManagerSettings, time: TimeInterval)?
    private func cachedSettings() -> StageManagerSettings {
        let now = ProcessInfo.processInfo.systemUptime
        if let settingsCache, now - settingsCache.time < 2 { return settingsCache.settings }
        let settings = StageManagerSettings.current()
        settingsCache = (settings, now)
        return settings
    }

    var targetAppName: String? {
        guard let pid = candidatePID() else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.localizedName
    }

    func layout() -> StageFillLayout {
        strip.layout(displays: StageDisplay.connected())
    }

    private func previewTarget(for target: StageWindowTarget) -> CGRect? {
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return nil }
        let displays = StageDisplay.connected()
        guard let display = StageFillGeometry.displayContainingMost(
            of: target.frame, displays: displays, primaryTop: primaryTop) else { return nil }
        return strip.layout(displays: displays).target(for: display, primaryTop: primaryTop)
    }

    private func fillCapturedWindow(_ target: StageWindowTarget, toggle: Bool) {
        guard !preview, preferences.enabled, !interactions.actionInProgress else { return }
        enqueue(window: target.window, toggle: toggle) { [weak self] outcome in
            self?.report(outcome, near: target)
        }
    }

    private func fillFromShortcut() {
        guard let pid = candidatePID(), let target = StageWindowTargeting.focused(pid: pid) else {
            NSSound.beep()
            return
        }
        fillCapturedWindow(target, toggle: true)
    }

    /// Successful fills need no message. Problems appear beside the window; missing
    /// access opens settings, where it can be granted.
    private func report(_ outcome: StageFillOutcome, near target: StageWindowTarget) {
        switch outcome {
        case .filled, .restored:
            break
        case .needsAccessibility:
            onInteractionResult?(outcome)
        case .unavailable(let reason):
            guard let primaryTop = NSScreen.screens.first?.frame.maxY else { return }
            let anchor = CGPoint(x: target.frame.midX, y: primaryTop - target.frame.minY - 34)
            toast.show(reason, near: anchor)
        }
    }

    private func enqueue(window: AXUIElement, toggle: Bool = false,
                         completion: @escaping (StageFillOutcome) -> Void) {
        guard !interactions.actionInProgress else {
            completion(.unavailable("A window fill is already in progress."))
            return
        }
        guard let primaryTop = NSScreen.screens.first?.frame.maxY else {
            completion(.unavailable("Screen geometry is unavailable."))
            return
        }
        let displays = StageDisplay.connected()
        let layout = strip.layout(displays: displays)
        interactions.actionInProgress = true
        interactions.dismiss()
        fillQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.windowManager.fill(window: window, layout: layout, displays: displays,
                                                  primaryScreenTop: primaryTop, toggle: toggle)
            DispatchQueue.main.async {
                self.interactions.actionInProgress = false
                completion(outcome)
            }
        }
    }

    func requestFillFocusedWindow(completion: @escaping (StageFillOutcome) -> Void) {
        if preview { completion(.unavailable("Preview mode does not change other windows.")); return }
        guard preferences.enabled else {
            completion(.unavailable("Turn on Stage Manager Fill in settings first."))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.needsAccessibility)
            return
        }
        guard let pid = candidatePID() else {
            completion(.unavailable("Click the window you want to fill, then choose Stage Manager Fill."))
            return
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let window = StageWindowTargeting.element(kAXFocusedWindowAttribute, of: app) else {
            completion(.unavailable("The selected app has no focused window to resize."))
            return
        }
        enqueue(window: window, completion: completion)
    }

    private func candidatePID() -> pid_t? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ownPID {
            lastExternalPID = frontmost.processIdentifier
            return frontmost.processIdentifier
        }
        return lastExternalPID
    }
}
