import AppKit
import QuartzCore
import OnwardCore

/// Owns passive edge overlays. Call stop() when the application terminates.
@MainActor final class ScreenEdgeGlowController {
    private struct Surface {
        let panel: ScreenEdgeGlowPanel
        let view: ScreenEdgeGlowView
    }

    private var surfaces: [UInt32: Surface] = [:]
    private var subscriptions: [ScreenEdgeGlowSubscription] = []
    private var status: FocusStatus = .ready
    private var enabled = false
    private var stopped = false

    init() {
        subscriptions.append(ScreenEdgeGlowSubscription(center: .default,
            name: NSApplication.didChangeScreenParametersNotification) { [weak self] in
                self?.reconcileScreens()
            })
        subscriptions.append(ScreenEdgeGlowSubscription(center: NSWorkspace.shared.notificationCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
                self?.reconcileScreens()
            })
    }

    func update(status: FocusStatus, enabled: Bool) {
        guard !stopped else { return }
        let visible = enabled && (status == .drifting || status == .distracted)
        guard self.status != status || self.enabled != visible else { return }
        self.status = status
        self.enabled = visible
        reconcileScreens()
    }

    /// Terminal cleanup. Disabling via update disposes windows but keeps observers active.
    func stop() {
        stopped = true
        enabled = false
        subscriptions.removeAll()
        removeAllSurfaces()
    }

    private func reconcileScreens() {
        guard enabled, !stopped else { removeAllSurfaces(); return }
        let screens = NSScreen.screens.compactMap { screen -> (UInt32, NSScreen)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen)
        }
        let activeIDs = Set(screens.map(\.0))
        for id in Array(surfaces.keys) where !activeIDs.contains(id) { removeSurface(id) }
        for (id, screen) in screens {
            let surface: Surface
            if let existing = surfaces[id] {
                surface = existing
                if surface.panel.frame != screen.frame { surface.panel.setFrame(screen.frame, display: true) }
            } else {
                let view = ScreenEdgeGlowView(status: status)
                view.frame = NSRect(origin: .zero, size: screen.frame.size)
                view.autoresizingMask = [.width, .height]
                let panel = ScreenEdgeGlowPanel(contentRect: screen.frame,
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = false
                panel.animationBehavior = .none
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.isMovable = false
                panel.isReleasedWhenClosed = false
                panel.isExcludedFromWindowsMenu = true
                panel.level = .statusBar
                panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                            .fullScreenAuxiliary, .stationary, .ignoresCycle]
                // Capture isolation comes from Onward's PID/window filter, not sharingType.
                panel.sharingType = .none
                panel.setAccessibilityElement(false)
                panel.setAccessibilityHidden(true)
                panel.setAccessibilityChildren([])
                panel.contentView = view
                surface = Surface(panel: panel, view: view)
                surfaces[id] = surface
            }
            surface.view.update(status: status)
            if !surface.panel.isVisible { surface.panel.orderFrontRegardless() }
        }
    }

    private func removeSurface(_ id: UInt32) {
        guard let surface = surfaces.removeValue(forKey: id) else { return }
        surface.view.stopAnimating()
        surface.panel.orderOut(nil)
        surface.panel.close()
    }

    private func removeAllSurfaces() {
        for id in Array(surfaces.keys) { removeSurface(id) }
    }
}

@MainActor private final class ScreenEdgeGlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reusable transparent renderer. animated:false gives a static peak-opacity QA image.
/// The four edges are drawn once into the backing layer; breathing animates opacity only.
@MainActor final class ScreenEdgeGlowView: NSView {
    private struct Appearance: Equatable {
        let status: FocusStatus
        let animated: Bool
        let reduceMotion: Bool
        let reduceTransparency: Bool
    }

    private struct Profile {
        let color: NSColor
        let reach: CGFloat
        let alpha: CGFloat
        let minimumOpacity: Float
        let halfCycle: CFTimeInterval
    }

    private var glowAppearance: Appearance?
    private let animationKey = "onward.edge.breathing"

    init(status: FocusStatus, animated: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
        setAccessibilityChildren([])
        update(status: status, animated: animated)
    }

    required init?(coder: NSCoder) { return nil }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(status: FocusStatus, animated: Bool = true) {
        let workspace = NSWorkspace.shared
        let next = Appearance(status: status, animated: animated,
                              reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                              reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
        guard next != glowAppearance else { return }
        glowAppearance = next
        needsDisplay = true
        stopAnimating()
        guard let profile, animated, !next.reduceMotion, !next.reduceTransparency else { return }
        let breathing = CABasicAnimation(keyPath: "opacity")
        breathing.fromValue = profile.minimumOpacity
        breathing.toValue = 1.0
        breathing.duration = profile.halfCycle
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        layer?.add(breathing, forKey: animationKey)
    }

    func stopAnimating() {
        layer?.removeAnimation(forKey: animationKey)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 1
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        guard let profile, let glowAppearance, bounds.width > 0, bounds.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.setLineJoin(.round)

        if glowAppearance.reduceTransparency {
            // A static solid perimeter replaces translucent glow without covering content.
            let width: CGFloat = glowAppearance.status == .distracted ? 3 : 1.5
            let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
            context.setStrokeColor(profile.color.cgColor)
            context.setLineWidth(width)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 22, cornerHeight: 22, transform: nil))
            context.strokePath()
            return
        }

        let scale = max(1, window?.backingScaleFactor ?? layer?.contentsScale ?? 2)
        let step = 1 / scale
        let reach = min(profile.reach, min(bounds.width, bounds.height) / 4)
        let staticScale: CGFloat = glowAppearance.reduceMotion ? 0.88 : 1
        // Concentric, non-overlapping rings give all four sides one continuous field,
        // including the corners. The center is never filled or tinted.
        for index in 0..<Int(ceil(reach / step)) {
            let inset = (CGFloat(index) + 0.5) * step
            let alpha = profile.alpha * pow(max(0, 1 - inset / reach), 2.3) * staticScale
            let rect = bounds.insetBy(dx: inset, dy: inset)
            let radius = max(0, 22 - inset)
            context.setStrokeColor(profile.color.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(step)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        }
    }

    private var profile: Profile? {
        switch glowAppearance?.status {
        case .drifting:
            return Profile(color: NSColor(srgbRed: 1, green: 0.72, blue: 0.10, alpha: 1),
                           reach: 24, alpha: 0.32, minimumOpacity: 0.90, halfCycle: 2.2)
        case .distracted:
            return Profile(color: NSColor(srgbRed: 1, green: 0.16, blue: 0.09, alpha: 1),
                           reach: 54, alpha: 0.44, minimumOpacity: 0.78, halfCycle: 1.7)
        default:
            return nil
        }
    }
}

/// Owns block observers so stop() and owner deallocation both unregister them.
private final class ScreenEdgeGlowSubscription {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    @MainActor init(center: NotificationCenter, name: Notification.Name,
                    action: @escaping @MainActor () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        }
    }

    deinit { if let token { center.removeObserver(token) } }
}
