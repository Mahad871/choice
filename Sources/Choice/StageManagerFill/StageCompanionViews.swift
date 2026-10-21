import AppKit

/// A panel that never takes focus from the app whose window it controls.
final class StageFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    convenience init(level: NSWindow.Level, ignoresMouse: Bool) {
        self.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: true)
        self.level = level
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = ignoresMouse
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
    }

    func fadeIn() {
        guard !isVisible || alphaValue < 1 else { return }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func fadeOut() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.orderOut(nil)
        })
    }
}

/// One menu row drawn like the rows in macOS's green-button menu: an icon and a title,
/// with the accent highlight while the pointer is over it.
final class StageMenuRowView: NSView {
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let highlight = NSView()
    private(set) var isHighlighted = false

    init(title text: String) {
        super.init(frame: .zero)
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 7
        highlight.layer?.cornerCurve = .continuous
        highlight.isHidden = true
        let symbol = NSImage(systemSymbolName: "squares.leading.rectangle", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: nil)
        icon.image = symbol?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        icon.contentTintColor = .labelColor
        title.stringValue = text
        title.font = .menuFont(ofSize: 13)
        title.textColor = .labelColor
        shortcut.font = .menuFont(ofSize: 13)
        shortcut.textColor = .secondaryLabelColor
        for view in [highlight, icon, title, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcut.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Stage Manager Fill")
        setAccessibilityHelp("Fill this window and leave room for Stage Manager")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setShortcut(_ text: String?) { shortcut.stringValue = text ?? "" }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }
    override func mouseDown(with event: NSEvent) { setHighlighted(true) }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }

    func setHighlighted(_ highlighted: Bool) {
        guard highlighted != isHighlighted else { return }
        isHighlighted = highlighted
        highlight.isHidden = !highlighted
        highlight.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        icon.contentTintColor = highlighted ? .white : .labelColor
        title.textColor = highlighted ? .white : .labelColor
        shortcut.textColor = highlighted ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        onHover?(highlighted)
    }
}

/// The card that sits under macOS's green-button menu.
final class StageCompanionCard {
    static let height: CGFloat = 40
    // Floating, not pop-up-menu level: a second window at the menu's level makes macOS
    // close its green-button menu. The card never overlaps that menu, so this is enough
    // to stay above the window it controls.
    let panel = StageFloatingPanel(level: .floating, ignoresMouse: false)
    let row = StageMenuRowView(title: "Stage Manager Fill")

    init() {
        let material = NSVisualEffectView()
        material.material = .menu
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5
        material.layer?.borderColor = NSColor.separatorColor.cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            row.topAnchor.constraint(equalTo: material.topAnchor, constant: 5),
            row.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -5)
        ])
        panel.contentView = material
        panel.hasShadow = true
    }

    var isVisible: Bool { panel.isVisible && panel.alphaValue > 0 }
}

/// A translucent outline of where the window will go, like macOS's tiling preview.
final class StagePreviewOverlay {
    private let panel = StageFloatingPanel(level: .floating, ignoresMouse: true)

    init() {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1.5
        panel.contentView = view
        panel.hasShadow = false
    }

    func show(_ frame: CGRect) {
        if let layer = panel.contentView?.layer {
            let accent = NSColor.controlAccentColor
            layer.backgroundColor = accent.withAlphaComponent(0.16).cgColor
            layer.borderColor = accent.withAlphaComponent(0.55).cgColor
        }
        panel.setFrame(frame, display: true)
        panel.fadeIn()
    }

    func hide() { panel.fadeOut() }
}

/// A brief, non-activating message near the window it is about.
final class StageToast {
    private let panel = StageFloatingPanel(level: .floating, ignoresMouse: true)
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?

    init() {
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 10
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: material.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: material.bottomAnchor, constant: -8)
        ])
        panel.contentView = material
        panel.hasShadow = true
    }

    /// `anchor` is an AppKit point, normally just below the window's title bar.
    func show(_ message: String, near anchor: CGPoint) {
        label.stringValue = message
        label.preferredMaxLayoutWidth = 320
        let size = panel.contentView?.fittingSize ?? CGSize(width: 320, height: 40)
        let width = min(max(size.width, 160), 344)
        var frame = CGRect(x: anchor.x - width / 2, y: anchor.y - size.height,
                           width: width, height: size.height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) {
            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        panel.setFrame(frame, display: true)
        panel.fadeIn()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }
}
