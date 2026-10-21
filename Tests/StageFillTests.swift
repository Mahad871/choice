import AppKit

@main
struct StageFillTests {
    static func main() {
        checkGeometry()
        checkStripMeasurement()
        checkPreferencesAndLayout()
        checkPointerPolicy()
        checkDoubleClickPolicy()
        checkFrameWriter()
        print("Stage Fill geometry, strip measurement, preferences, pointer and double-click policy, and frame writes passed")
    }

    static let primary = StageDisplay(key: "built-in", name: "Built-in", frame:
        CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame:
        CGRect(x: 0, y: 0, width: 1440, height: 860))
    static let external = StageDisplay(key: "external", name: "External", frame:
        CGRect(x: 1440, y: -180, width: 1920, height: 1080), visibleFrame:
        CGRect(x: 1440, y: -140, width: 1920, height: 1000))
    static let leftDisplay = StageDisplay(key: "left", name: "Left", frame:
        CGRect(x: -1280, y: -100, width: 1280, height: 800), visibleFrame:
        CGRect(x: -1280, y: -60, width: 1280, height: 720))

    static func checkGeometry() {
        let left220 = StageReservation(side: .left, inset: 220)
        let primaryTarget = StageFillGeometry.targetFrame(for: primary, reservation: left220, primaryTop: 900)
        assert(primaryTarget == CGRect(x: 220, y: 40, width: 1220, height: 860))
        assert(StageFillGeometry.appKitFrame(fromAX: primaryTarget, primaryTop: 900) ==
            CGRect(x: 220, y: 0, width: 1220, height: 860))
        let crossing = StageFillGeometry.axFrame(fromAppKit:
            CGRect(x: 1300, y: 100, width: 600, height: 500), primaryTop: 900)
        assert(StageFillGeometry.displayContainingMost(of: crossing, displays: [primary, external],
            primaryTop: 900)?.key == external.key)
        let externalTarget = StageFillGeometry.targetFrame(
            for: external, reservation: StageReservation(side: .left, inset: 280), primaryTop: 900)
        assert(externalTarget == CGRect(x: 1720, y: 40, width: 1640, height: 1000))
        let leftTarget = StageFillGeometry.targetFrame(for: leftDisplay, reservation: left220, primaryTop: 900)
        assert(leftTarget == CGRect(x: -1060, y: 240, width: 1060, height: 720))
        assert(StageFillGeometry.displayContainingMost(of: CGRect(x: 9000, y: 0, width: 100, height: 100),
            displays: [primary, external], primaryTop: 900) == nil)
        assert(StageFillGeometry.coversEntireDisplay(
            StageFillGeometry.axFrame(fromAppKit: primary.frame, primaryTop: 900),
            display: primary, primaryTop: 900))
        assert(!StageFillGeometry.coversEntireDisplay(primaryTarget, display: primary, primaryTop: 900))
        let small = StageDisplay(key: "small", name: "Small", frame:
            CGRect(x: 0, y: 0, width: 400, height: 300), visibleFrame:
            CGRect(x: 0, y: 0, width: 400, height: 280))
        assert(StageFillGeometry.targetFrame(for: small, reservation: StageReservation(side: .left, inset: 500),
                                             primaryTop: 300) == CGRect(x: 200, y: 20, width: 200, height: 280))

        // Strip on the right (Dock on the left): space is kept on the right edge.
        let dockLeft = StageDisplay(key: "dock-left", name: "Dock left", frame:
            CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame:
            CGRect(x: 70, y: 0, width: 1370, height: 875))
        let right = StageFillGeometry.targetFrame(for: dockLeft, reservation: StageReservation(side: .right, inset: 180),
                                                  primaryTop: 900)
        assert(right == CGRect(x: 70, y: 25, width: 1190, height: 875))
        // A strip narrower than the Dock-side gap changes nothing on that side.
        let besideDock = StageFillGeometry.targetFrame(for: dockLeft, reservation: StageReservation(side: .left, inset: 40),
                                                       primaryTop: 900)
        assert(besideDock.minX == 70)

    }

    static func checkStripMeasurement() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1243)
        // Thumbnails observed on a 1920-point display, including stacked sets and app badges.
        let observed = [
            StageStripWindow(frame: CGRect(x: -7, y: 581, width: 66, height: 82), alpha: 1),
            StageStripWindow(frame: CGRect(x: 31, y: 487, width: 135, height: 139), alpha: 1),
            StageStripWindow(frame: CGRect(x: 15, y: 487, width: 137, height: 139), alpha: 1),
            StageStripWindow(frame: CGRect(x: 15, y: 652, width: 137, height: 142), alpha: 1),
            StageStripWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1243), alpha: 1)
        ]
        assert(StageStrip.measure(observed, display: display) == StageStripMeasurement(side: .left, extent: 166))
        // Hidden or sliding away: nothing is measured.
        let hidden = observed.map { StageStripWindow(frame: $0.frame.offsetBy(dx: -150, dy: 0), alpha: $0.alpha) }
        assert(StageStrip.measure(hidden, display: display) == nil)
        assert(StageStrip.measure(observed.map { StageStripWindow(frame: $0.frame, alpha: 0) }, display: display) == nil)
        // On another display, or on the right edge.
        let mirrored = observed.dropLast().map {
            StageStripWindow(frame: CGRect(x: 1920 - $0.frame.maxX, y: $0.frame.minY,
                                           width: $0.frame.width, height: $0.frame.height), alpha: 1)
        }
        assert(StageStrip.measure(mirrored, display: display) == StageStripMeasurement(side: .right, extent: 166))
        assert(StageStrip.measure(observed, display: display.offsetBy(dx: 1920, dy: 0)) == nil)
        assert(StageStrip.estimatedExtent(displayWidth: 1920) == 166)
        assert(StageStrip.estimatedExtent(displayWidth: 1280) == 140)
        assert(StageStrip.estimatedExtent(displayWidth: 3008) == 220)
    }

    static func checkPreferencesAndLayout() {
        let suite = "io.github.mahad871.microphonechoice.stage.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = StageFillPreferences(defaults: defaults)
        assert(preferences.enabled && !preferences.rememberPerDisplay)
        // Both pointer interactions are on by default since 2.0.
        assert(preferences.greenButtonCompanion && preferences.titleBarDoubleClick)
        assert(preferences.reservationMode == .automatic)
        assert(!preferences.shortcut.enabled && preferences.shortcut.displayName == "⌃⌥⌘F")
        preferences.titleBarDoubleClick = false
        preferences.greenButtonCompanion = false
        assert(preferences.defaultReservation == 220)
        preferences.setReservation(230, for: external.key)
        assert(preferences.defaultReservation == 230)
        preferences.rememberPerDisplay = true
        preferences.setReservation(280, for: external.key)
        preferences.setReservation(240, for: primary.key)
        assert(preferences.reservation(for: external.key) == 280)
        assert(preferences.reservation(for: primary.key) == 240)
        assert(preferences.reservation(for: leftDisplay.key) == 230)
        preferences.enabled = false
        preferences.reservationMode = .custom
        preferences.shortcut = ShortcutConfiguration(enabled: true, control: true, option: false,
                                                     shift: true, command: true, key: "S")
        let reloaded = StageFillPreferences(defaults: defaults)
        assert(!reloaded.enabled && reloaded.rememberPerDisplay)
        assert(!reloaded.titleBarDoubleClick && !reloaded.greenButtonCompanion)
        assert(reloaded.reservation(for: external.key) == 280)
        assert(reloaded.reservationMode == .custom && reloaded.shortcut.displayName == "⌃⇧⌘S")
        reloaded.rememberPerDisplay = false
        assert(reloaded.reservation(for: external.key) == 230)
        reloaded.defaultReservation = 9000
        assert(reloaded.defaultReservation == StageFillPreferences.maximumReservation)

        // Measurements persist per display and clear on request.
        assert(reloaded.measuredStrip(for: primary.key) == nil)
        reloaded.setMeasuredStrip(StageStripMeasurement(side: .left, extent: 166), for: primary.key)
        assert(StageFillPreferences(defaults: defaults).measuredStrip(for: primary.key)?.extent == 166)
        reloaded.clearMeasuredStrip(for: primary.key)
        assert(reloaded.measuredStrip(for: primary.key) == nil)

        // The tracker stores only steady readings and keeps the widest one.
        let tracker = StageStripTracker(preferences: reloaded)
        let wide = [StageStripWindow(frame: CGRect(x: 15, y: 100, width: 137, height: 139), alpha: 1)]
        let narrow = [StageStripWindow(frame: CGRect(x: 16, y: 100, width: 77, height: 104), alpha: 1)]
        tracker.sample(displays: [primary], primaryTop: 900, windows: wide, now: 10)
        assert(reloaded.measuredStrip(for: primary.key) == nil)
        tracker.sample(displays: [primary], primaryTop: 900, windows: wide, now: 10.1)
        assert(reloaded.measuredStrip(for: primary.key) == nil)
        tracker.sample(displays: [primary], primaryTop: 900, windows: wide, now: 10.4)
        assert(reloaded.measuredStrip(for: primary.key)?.extent == 152)
        tracker.sample(displays: [primary], primaryTop: 900, windows: narrow, now: 11)
        tracker.sample(displays: [primary], primaryTop: 900, windows: narrow, now: 12)
        assert(reloaded.measuredStrip(for: primary.key)?.extent == 152)

        // Layouts: automatic uses the measurement plus a gap, custom uses the entered width,
        // and nothing is kept free when Stage Manager hides recent apps.
        let on = StageManagerSettings(enabled: true, showsRecentApps: true,
                                      dockOnLeft: false, titleBarDoubleClickAction: "Fill")
        reloaded.reservationMode = .automatic
        let measured = StageStripMeasurement(side: .left, extent: 166)
        let automatic = StageStripTracker.layout(displays: [primary], settings: on, preferences: reloaded) { _ in measured }
        assert(automatic.reservation(for: primary) == StageReservation(side: .left, inset: 166 + StageFillGeometry.stripGap))
        var hidden = on
        hidden.showsRecentApps = false
        let none = StageStripTracker.layout(displays: [primary], settings: hidden, preferences: reloaded) { _ in measured }
        assert(none.reservation(for: primary) == .none)
        reloaded.reservationMode = .custom
        var dockLeft = on
        dockLeft.dockOnLeft = true
        let custom = StageStripTracker.layout(displays: [primary], settings: dockLeft, preferences: reloaded) { _ in measured }
        assert(custom.reservation(for: primary) == StageReservation(side: .right, inset: 2000))

        assert(on.titleBarDoubleClickResizes && on.reservesStrip && on.expectedStripSide == .left)
        assert(!StageManagerSettings(enabled: true, showsRecentApps: true, dockOnLeft: false,
                                     titleBarDoubleClickAction: "Minimize").titleBarDoubleClickResizes)
        assert(!StageManagerSettings(enabled: true, showsRecentApps: true, dockOnLeft: false,
                                     titleBarDoubleClickAction: "None").titleBarDoubleClickResizes)
    }

    static func checkPointerPolicy() {
        var clicks = StageClickSequence()
        let point = CGPoint(x: 200, y: 50)
        assert(!clicks.down(at: point, time: 1, count: 1, unmodified: true, interval: 0.5))
        assert(clicks.down(at: point, time: 1.2, count: 2, unmodified: true, interval: 0.5))
        assert(!clicks.down(at: point, time: 1.3, count: 3, unmodified: true, interval: 0.5))
        assert(!clicks.down(at: point, time: 2, count: 1, unmodified: true, interval: 0.5))
        assert(!clicks.down(at: point, time: 2.2, count: 2, unmodified: false, interval: 0.5))
        assert(!clicks.down(at: point, time: 3, count: 1, unmodified: true, interval: 0.5))
        assert(!clicks.down(at: CGPoint(x: 240, y: 50), time: 3.2, count: 2,
                            unmodified: true, interval: 0.5))
        assert(!clicks.down(at: point, time: 4, count: 1, unmodified: true, interval: 0.5))
        assert(!clicks.down(at: point, time: 5, count: 2, unmodified: true, interval: 0.5))

        // Apple's menu as listed by the window server for a green button at (267, 105).
        let green = CGRect(x: 267, y: 105, width: 14, height: 14)
        let menuWindow = StageListedWindow(owner: StageZoomMenu.owner, layer: 101,
                                           frame: CGRect(x: 235, y: 119, width: 266, height: 218))
        let other = StageListedWindow(owner: StageZoomMenu.owner, layer: 101,
                                      frame: CGRect(x: 1200, y: 119, width: 266, height: 218))
        let menu = StageZoomMenu.locate(near: green, in: [other, menuWindow])
        assert(menu == CGRect(x: 249, y: 133, width: 238, height: 190))
        assert(StageZoomMenu.locate(near: green, in: [other]) == nil)
        assert(StageZoomMenu.locate(near: green.offsetBy(dx: 0, dy: 300), in: [menuWindow]) == nil)

        // Docked under the menu in AppKit coordinates, aligned and equally wide.
        let visible = primary.visibleFrame
        let buttonAK = StageFillGeometry.appKitFrame(fromAX: green, primaryTop: 900)
        let menuAK = StageFillGeometry.appKitFrame(fromAX: menu!, primaryTop: 900)
        let docked = StageCompanionGeometry.docked(to: menuAK, button: buttonAK, height: 40, visible: visible)
        assert(docked == CGRect(x: 249, y: menuAK.minY - 46, width: 238, height: 40))
        // No room below: the card moves beside the menu.
        let lowMenu = CGRect(x: 249, y: 20, width: 238, height: 190)
        let beside = StageCompanionGeometry.docked(to: lowMenu, button: CGRect(x: 267, y: 214, width: 14, height: 14),
                                                   height: 40, visible: visible)
        assert(beside.minX == lowMenu.maxX + 6 && beside.maxY == lowMenu.maxY)
        // The corridor from the menu to the card keeps it open.
        let areas = StageCompanionGeometry.keepAlive(button: buttonAK, menu: menuAK, card: docked)
        assert(areas.contains { $0.contains(CGPoint(x: 300, y: menuAK.minY - 3)) })
        assert(!areas.contains { $0.contains(CGPoint(x: 900, y: 400)) })
        let standalone = StageCompanionGeometry.standalone(below: buttonAK, height: 40, width: 220, visible: visible)
        assert(standalone.maxY == buttonAK.minY - 8 && standalone.width == 220)
    }

    static func checkDoubleClickPolicy() {
        let window = CGRect(x: 100, y: 100, width: 1200, height: 800)
        let green = CGRect(x: 160, y: 113, width: 14, height: 14)
        func region(_ x: CGFloat, _ y: CGFloat, _ path: [StageAXNode]) -> StageDoubleClickRegion? {
            StageDoubleClickPolicy.region(at: CGPoint(x: x, y: y), window: window, greenButton: green, path: path)
        }
        assert(StageDoubleClickPolicy.titleRowHeight(window: window, greenButton: green) == 40)
        // Empty title bar, toolbar or tab strip.
        assert(region(600, 110, []) == .titleRow)
        assert(region(600, 120, [StageAXNode(role: "AXToolbar")]) == .titleRow)
        assert(region(600, 120, [StageAXNode(role: "AXStaticText"), StageAXNode(role: "AXToolbar")]) == .titleRow)
        // Finder's window title, which reports AXPress for its path menu.
        assert(region(600, 120, [StageAXNode(role: "AXStaticText", actions: ["AXPress"])]) == .titleRow)
        assert(region(600, 120, [StageAXNode(role: "AXStaticText", actions: ["AXPress"]),
                                 StageAXNode(role: "AXButton")]) == nil)
        assert(region(600, 120, [StageAXNode(role: "AXTabGroup")]) == .titleRow)
        // Electron draws its title bar inside the web area that fills the window.
        let electron = StageAXNode(role: "AXWebArea", frame: window)
        assert(region(600, 120, [StageAXNode(role: "AXGroup"), electron]) == .titleRow)
        // Controls keep their clicks.
        assert(region(600, 120, [StageAXNode(role: "AXRadioButton", subrole: "AXTabButton"), StageAXNode(role: "AXTabGroup")]) == nil)
        assert(region(600, 120, [StageAXNode(role: "AXButton")]) == nil)
        assert(region(600, 120, [StageAXNode(role: "AXTextField", subrole: "AXSearchField")]) == nil)
        assert(region(600, 120, [StageAXNode(role: "AXGroup", actions: ["AXPress"])]) == nil)
        assert(region(600, 120, [StageAXNode(role: "AXGroup", actions: ["AXShowMenu", "AXScrollToVisible"])]) == .titleRow)
        // Traffic lights and the gaps between them are left alone.
        assert(region(140, 120, []) == nil && region(176, 118, []) == nil)
        assert(region(600, 50, []) == nil)

        // A full-height leading column, like vertical tabs or a conversation list.
        let sidebar = StageAXNode(role: "AXGroup", frame: CGRect(x: 100, y: 140, width: 260, height: 760))
        assert(region(200, 700, [sidebar]) == .sidebar)
        assert(region(200, 700, [StageAXNode(role: "AXScrollArea", frame: sidebar.frame), electron]) == .sidebar)
        assert(region(200, 700, [StageAXNode(role: "AXRow"), sidebar]) == nil)
        assert(region(200, 700, [StageAXNode(role: "AXStaticText"), StageAXNode(role: "AXLink"), sidebar]) == nil)
        assert(region(700, 700, [sidebar]) == nil)
        // Edge's collapsed vertical tab bar (an icon rail) as reported on macOS 27.
        let tabRail = StageAXNode(role: "AXGroup", frame: CGRect(x: 100, y: 140, width: 41, height: 760))
        assert(region(120, 700, [tabRail, StageAXNode(role: "AXTabGroup", frame: tabRail.frame)]) == .sidebar)
        assert(region(120, 700, [StageAXNode(role: "AXButton"), tabRail]) == nil)
        assert(region(120, 700, [StageAXNode(role: "AXGroup", frame: CGRect(x: 100, y: 140, width: 20, height: 760))]) == nil)
        // Not sidebars: content panes, short or late-starting columns, wide columns.
        assert(region(700, 700, [StageAXNode(role: "AXGroup", frame: CGRect(x: 360, y: 140, width: 940, height: 760))]) == nil)
        assert(region(200, 700, [StageAXNode(role: "AXGroup", frame: CGRect(x: 100, y: 500, width: 260, height: 400))]) == nil)
        assert(region(200, 700, [StageAXNode(role: "AXGroup", frame: CGRect(x: 100, y: 140, width: 700, height: 760))]) == nil)
        // A web page's own left column inside a browser stays page content.
        let page = StageAXNode(role: "AXWebArea", frame: CGRect(x: 100, y: 190, width: 1200, height: 710))
        assert(region(200, 700, [StageAXNode(role: "AXGroup", frame: CGRect(x: 100, y: 190, width: 260, height: 710)), page]) == nil)
        assert(region(200, 700, [StageAXNode(role: "AXStaticText"), sidebar, page]) == nil)
    }

    static func checkFrameWriter() {
        // A scripted window: writes land after a delay, optionally constrained or moved.
        final class FakeWindow {
            var frame: CGRect
            var clock: TimeInterval = 0
            var pending: [(time: TimeInterval, apply: (inout CGRect) -> Void)] = []
            var writeDelay: TimeInterval = 0.05
            var constrain: (CGRect) -> CGRect = { $0 }
            var refuse = false
            var writes = 0
            init(_ frame: CGRect) { self.frame = frame }
            func advance(_ seconds: TimeInterval) {
                clock += seconds
                let due = pending.filter { $0.time <= clock }
                pending.removeAll { $0.time <= clock }
                for change in due { change.apply(&frame) }
            }
            var writer: StageFrameWriter {
                StageFrameWriter(
                    read: { self.frame },
                    setPosition: { point in
                        guard !self.refuse else { return false }
                        self.writes += 1
                        self.pending.append((self.clock + self.writeDelay, { $0.origin = point; $0 = self.constrain($0) }))
                        return true
                    },
                    setSize: { size in
                        guard !self.refuse else { return false }
                        self.writes += 1
                        self.pending.append((self.clock + self.writeDelay, { $0.size = size; $0 = self.constrain($0) }))
                        return true
                    },
                    sleep: { self.advance($0) },
                    now: { self.clock })
            }
        }
        let target = CGRect(x: 178, y: 46, width: 1734, height: 1151)
        let plain = FakeWindow(CGRect(x: 600, y: 300, width: 800, height: 600))
        assert(plain.writer.apply(target) == .placed(target))
        assert(plain.writes == 3)

        // Terminal-style character grid: placed at the target origin, slightly smaller.
        let grid = FakeWindow(CGRect(x: 600, y: 300, width: 800, height: 600))
        grid.constrain = { CGRect(origin: $0.origin, size: CGSize(width: floor($0.width / 7) * 7,
                                                                  height: floor($0.height / 17) * 17)) }
        let gridSize = CGSize(width: floor(target.width / 7) * 7, height: floor(target.height / 17) * 17)
        assert(grid.writer.apply(target) == .constrained(CGRect(origin: target.origin, size: gridSize)))

        // A window that springs back to its old origin after the first write (the
        // "filled on the wrong side" defect) is corrected by the next attempt.
        let springy = FakeWindow(CGRect(x: 0, y: 46, width: 1200, height: 900))
        var sprang = false
        springy.constrain = { frame in
            guard !sprang, frame.size == target.size else { return frame }
            sprang = true
            springy.pending.append((springy.clock + 0.3, { $0.origin.x = 0 }))
            return frame
        }
        assert(springy.writer.apply(target) == .placed(target))
        assert(springy.writes == 6)

        // An app that refuses to move keeps reporting the same frame; stop retrying.
        let stuck = FakeWindow(CGRect(x: 0, y: 46, width: 900, height: 700))
        stuck.constrain = { _ in CGRect(x: 0, y: 46, width: 900, height: 700) }
        assert(stuck.writer.apply(target) == .misplaced(CGRect(x: 0, y: 46, width: 900, height: 700)))
        assert(stuck.writes == 6)

        let refusing = FakeWindow(CGRect(x: 0, y: 46, width: 900, height: 700))
        refusing.refuse = true
        assert(refusing.writer.apply(target) == .refused)

        // Settling waits for an animation to finish rather than reading a midpoint.
        let animated = FakeWindow(CGRect(x: 600, y: 300, width: 800, height: 600))
        animated.writeDelay = 0.4
        assert(animated.writer.apply(target) == .placed(target))
        assert(animated.writes == 3)

        let restore = StageRestoreState(original: CGRect(x: 400, y: 200, width: 620, height: 422), filled: target)
        assert(restore.restoreFrame(current: target) == restore.original)
        assert(restore.restoreFrame(current: target.offsetBy(dx: 1, dy: -1)) == restore.original)
        assert(restore.restoreFrame(current: target.offsetBy(dx: 50, dy: 0)) == nil)
    }
}
