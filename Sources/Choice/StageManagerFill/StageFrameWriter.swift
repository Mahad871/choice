import Foundation

/// Places another app's window and waits for the result.
///
/// Apps answer Accessibility frame writes in different ways: some animate, some apply
/// the size and the position in separate run-loop turns, some snap to a character grid,
/// and a window macOS has tiled can restore its pre-tile size when it is moved. A single
/// write followed by a fixed sleep therefore lands in the wrong place now and then. This
/// writer sets size, position, then size again, polls until the frame holds still, and
/// corrects once more when the app moved it somewhere else.
struct StageFrameWriter {
    enum Result: Equatable {
        /// The window matches the request.
        case placed(CGRect)
        /// The window is where it was asked to be, but the app chose a different size,
        /// such as a minimum size or Terminal's character grid.
        case constrained(CGRect)
        /// The window ended somewhere else after every attempt.
        case misplaced(CGRect)
        /// The app rejected the write or stopped reporting its frame.
        case refused
    }

    var read: () -> CGRect?
    var setPosition: (CGPoint) -> Bool
    var setSize: (CGSize) -> Bool
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static let tolerance: CGFloat = 3
    /// Size differences up to this are an app's own sizing rule, not a failed write.
    static let sizeRuleTolerance: CGFloat = 40
    static let maximumAttempts = 3
    /// A placed window is read once more after this delay, because a tiled window can
    /// spring back to its earlier frame a moment after it first reports the new one.
    static let confirmationDelay: TimeInterval = 0.2

    func apply(_ target: CGRect) -> Result {
        var previous: CGRect?
        var latest: CGRect?
        for _ in 0..<Self.maximumAttempts {
            let before = read()
            // The first size write can be clipped against the old origin; the second
            // one, after the move, gives the app the full size at the new origin.
            _ = setSize(target.size)
            guard setPosition(target.origin), setSize(target.size) else { return .refused }
            guard let settled = settle(toward: target, from: before) else { return .refused }
            let accepted = Self.matches(settled, target) || Self.followsSizeRule(settled, target)
            if accepted {
                sleep(Self.confirmationDelay)
                guard let confirmed = read() else { return .refused }
                if Self.matches(confirmed, target) { return .placed(confirmed) }
                if Self.followsSizeRule(confirmed, target) { return .constrained(confirmed) }
                // It sprang back; write again.
                latest = confirmed
                previous = nil
                continue
            }
            // Same result twice: the app is enforcing it, and another write will not help.
            if let previous, Self.matches(previous, settled) {
                return Self.originMatches(settled, target) ? .constrained(settled) : .misplaced(settled)
            }
            previous = settled
            latest = settled
        }
        guard let latest else { return .refused }
        return Self.originMatches(latest, target) ? .constrained(latest) : .misplaced(latest)
    }

    /// At the requested origin, with a size the app adjusted only slightly.
    static func followsSizeRule(_ actual: CGRect, _ requested: CGRect) -> Bool {
        originMatches(actual, requested) &&
            abs(actual.width - requested.width) <= sizeRuleTolerance &&
            abs(actual.height - requested.height) <= sizeRuleTolerance
    }

    /// Polls until the frame has been unchanged for a short time. A frame that already
    /// matches the request settles faster; a frame that has not moved yet is given longer,
    /// because some apps start animating only after a delay.
    func settle(toward target: CGRect, from before: CGRect? = nil, timeout: TimeInterval = 1.4) -> CGRect? {
        let start = now()
        var last: CGRect?
        var stableSince = start
        while true {
            guard let frame = read() else { return nil }
            let time = now()
            if let last, Self.matches(frame, last) {
                let quiet = Self.matches(frame, target) ? 0.12
                    : before.map { Self.matches(frame, $0) } == true ? 0.5 : 0.25
                if time - stableSince >= quiet { return frame }
            } else {
                last = frame
                stableSince = time
            }
            if time - start >= timeout { return frame }
            sleep(0.02)
        }
    }

    static func matches(_ actual: CGRect, _ requested: CGRect) -> Bool {
        originMatches(actual, requested) &&
            abs(actual.width - requested.width) <= tolerance &&
            abs(actual.height - requested.height) <= tolerance
    }

    static func originMatches(_ actual: CGRect, _ requested: CGRect) -> Bool {
        abs(actual.minX - requested.minX) <= tolerance && abs(actual.minY - requested.minY) <= tolerance
    }
}
