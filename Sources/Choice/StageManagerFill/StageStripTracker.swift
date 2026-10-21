import AppKit

/// Learns how much room Stage Manager's strip needs on each display.
///
/// The strip hides whenever a window overlaps it, which is exactly when a fill is most
/// useful, so measurements are taken in the background whenever the strip is visible and
/// remembered per display. A reading is stored only after it holds steady across two
/// samples, which ignores thumbnails that are mid-animation.
final class StageStripTracker {
    private let preferences: StageFillPreferences
    private var pending: [String: (measurement: StageStripMeasurement, time: TimeInterval)] = [:]
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(preferences: StageFillPreferences) {
        self.preferences = preferences
    }

    deinit {
        timer?.invalidate()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.sampleIfUseful() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // The strip settles shortly after Stage Manager switches sets.
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self?.sampleIfUseful() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { self?.sampleIfUseful() }
        }
        sampleIfUseful()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        pending.removeAll()
    }

    private func sampleIfUseful() {
        guard preferences.enabled, preferences.reservationMode == .automatic,
              StageManagerSettings.current().reservesStrip,
              let primaryTop = NSScreen.screens.first?.frame.maxY else { return }
        sample(displays: StageDisplay.connected(), primaryTop: primaryTop,
               windows: StageStrip.windows(), now: ProcessInfo.processInfo.systemUptime)
    }

    func sample(displays: [StageDisplay], primaryTop: CGFloat, windows: [StageStripWindow], now: TimeInterval) {
        var changed = false
        for display in displays {
            let axDisplay = StageFillGeometry.axFrame(fromAppKit: display.frame, primaryTop: primaryTop)
            guard let reading = StageStrip.measure(windows, display: axDisplay) else {
                pending[display.key] = nil
                continue
            }
            let rounded = StageStripMeasurement(side: reading.side, extent: reading.extent.rounded())
            guard let previous = pending[display.key], previous.measurement == rounded else {
                pending[display.key] = (rounded, now)
                continue
            }
            guard now - previous.time >= 0.25 else { continue }
            // Thumbnails vary with each window's shape and with stacked sets; keep the
            // widest steady reading so a filled window never overlaps the strip.
            let stored = preferences.measuredStrip(for: display.key)
            if stored == nil || stored!.side != rounded.side || stored!.extent < rounded.extent {
                preferences.setMeasuredStrip(rounded, for: display.key)
                changed = true
            }
        }
        if changed { onChange?() }
    }

    /// Forget measurements so the next visible strip is measured from scratch.
    func reset(displays: [StageDisplay]) {
        for display in displays { preferences.clearMeasuredStrip(for: display.key) }
        pending.removeAll()
        sampleIfUseful()
        onChange?()
    }

    func measuredOrEstimated(for display: StageDisplay, settings: StageManagerSettings)
        -> (measurement: StageStripMeasurement, measured: Bool) {
        if let stored = preferences.measuredStrip(for: display.key), stored.side == settings.expectedStripSide {
            return (stored, true)
        }
        return (StageStripMeasurement(side: settings.expectedStripSide,
                                      extent: StageStrip.estimatedExtent(displayWidth: display.frame.width)), false)
    }

    func layout(displays: [StageDisplay], settings: StageManagerSettings = .current()) -> StageFillLayout {
        if preferences.reservationMode == .automatic, settings.reservesStrip,
           let primaryTop = NSScreen.screens.first?.frame.maxY {
            // Take a fresh reading first; the strip may be visible right now.
            sample(displays: displays, primaryTop: primaryTop, windows: StageStrip.windows(),
                   now: ProcessInfo.processInfo.systemUptime)
        }
        return Self.layout(displays: displays, settings: settings, preferences: preferences) {
            self.measuredOrEstimated(for: $0, settings: settings).measurement
        }
    }

    static func layout(displays: [StageDisplay], settings: StageManagerSettings,
                       preferences: StageFillPreferences,
                       strip: (StageDisplay) -> StageStripMeasurement) -> StageFillLayout {
        var reservations: [String: StageReservation] = [:]
        for display in displays {
            switch preferences.reservationMode {
            case .automatic:
                guard settings.reservesStrip else { continue }
                let measurement = strip(display)
                reservations[display.key] = StageReservation(
                    side: measurement.side, inset: measurement.extent + StageFillGeometry.stripGap)
            case .custom:
                reservations[display.key] = StageReservation(
                    side: settings.expectedStripSide, inset: CGFloat(preferences.reservation(for: display.key)))
            }
        }
        return StageFillLayout(reservations: reservations)
    }
}
