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
    private var recoveryTask: Task<Void, Never>?
    private var recoveryID: UUID?

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
        guard self.status != status || self.enabled != enabled else { return }
        self.status = status
        self.enabled = enabled
        if !enabled || status != .focused { cancelRecovery() }
        reconcileScreens()
    }

    func playWarningPulse() {
        guard enabled, !stopped, status == .distracted else { return }
        cancelRecovery()
        reconcileScreens()
        for surface in surfaces.values { surface.view.playWarningPulse() }
    }

    func playRecoveryPulse() {
        guard enabled, !stopped, status == .focused else { return }
        cancelRecovery()
        let id = UUID()
        recoveryID = id
        reconcileScreens()
        for surface in surfaces.values { surface.view.playRecoveryPulse() }
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(ScreenEdgeGlowView.recoveryDuration)) }
            catch { return }
            guard let self, self.recoveryID == id else { return }
            self.recoveryTask = nil
            self.recoveryID = nil
            self.reconcileScreens()
        }
    }

    /// Terminal cleanup. Disabling via update disposes windows but keeps observers active.
    func stop() {
        stopped = true
        enabled = false
        cancelRecovery()
        subscriptions.removeAll()
        removeAllSurfaces()
    }

    private func cancelRecovery() {
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryID = nil
        for surface in surfaces.values { surface.view.cancelRecoveryPulse() }
    }

    private func reconcileScreens() {
        guard enabled, !stopped,
              status == .drifting || status == .distracted || recoveryID != nil else { removeAllSurfaces(); return }
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
/// The backing field is static; Core Animation moves a small masked highlight.
@MainActor final class ScreenEdgeGlowView: NSView {
    static let recoveryDuration: TimeInterval = 5
    struct AnimationDiagnostics {
        let movingHighlight: Bool
        let warningPulse: Bool
        let recoveryPulse: Bool
        let recoveryParticles: Int
        let recoverySparkles: Int
        let recoveryWaves: Int
        let recoveryRetreatingRings: Int
        let recoveryDuration: TimeInterval
        let reduceMotion: Bool
        let reduceTransparency: Bool
    }
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
    private let motionKey = "onward.edge.travel"
    private let pulseKey = "onward.edge.pulse"
    private let retreatKey = "onward.edge.retreat"
    private var movingHighlight: CALayer?
    private var warningPulse: CALayer?
    private var recoveryPulse: CALayer?

    var animationDiagnostics: AnimationDiagnostics {
        AnimationDiagnostics(movingHighlight: movingHighlight != nil,
            warningPulse: warningPulse?.animation(forKey: pulseKey) != nil,
            recoveryPulse: recoveryPulse?.animation(forKey: pulseKey) != nil,
            recoveryParticles: recoveryPulse?.sublayers?.filter { $0.name == "recovery.plus" }.count ?? 0,
            recoverySparkles: recoveryPulse?.sublayers?.filter { $0.name == "recovery.sparkle" }.count ?? 0,
            recoveryWaves: recoveryPulse?.sublayers?.filter { $0.name == "recovery.wave" }.count ?? 0,
            recoveryRetreatingRings: recoveryPulse?.sublayers?.flatMap { $0.sublayers ?? [] }
                .filter { $0.animation(forKey: retreatKey)?.duration == Self.recoveryDuration }.count ?? 0,
            recoveryDuration: recoveryPulse?.animation(forKey: pulseKey)?.duration ?? 0,
            reduceMotion: glowAppearance?.reduceMotion ?? false,
            reduceTransparency: glowAppearance?.reduceTransparency ?? false)
    }

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
        rebuildMovingHighlight()
    }

    func stopAnimating() {
        layer?.removeAnimation(forKey: animationKey)
        removeEffect(movingHighlight); movingHighlight = nil
        removeEffect(warningPulse); warningPulse = nil
        cancelRecoveryPulse()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.opacity = 1
        CATransaction.commit()
    }

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cancelRecoveryPulse() }
        super.setFrameSize(newSize)
        needsDisplay = true
        rebuildMovingHighlight()
    }

    func playWarningPulse() {
        guard glowAppearance?.status == .distracted, glowAppearance?.animated == true, let profile else { return }
        removeEffect(warningPulse)
        let pulse = edgeField(color: profile.color, reach: profile.reach, alpha: 0.14)
        warningPulse = pulse
        layer?.addSublayer(pulse)
        animatePulse(pulse, duration: 0.55)
    }

    func playRecoveryPulse() {
        guard glowAppearance?.status == .focused, glowAppearance?.animated == true else { return }
        cancelRecoveryPulse()
        let mint = NSColor(srgbRed: 0.24, green: 1, blue: 0.65, alpha: 1)
        let aqua = NSColor(srgbRed: 0.12, green: 0.88, blue: 0.94, alpha: 1)
        let pulse = CALayer(); pulse.frame = bounds; pulse.opacity = 0; pulse.masksToBounds = true
        recoveryPulse = pulse
        layer?.addSublayer(pulse)
        let fullMotion = glowAppearance?.reduceMotion == false && glowAppearance?.reduceTransparency == false
        let retreatDuration = fullMotion ? Self.recoveryDuration : nil
        let base = edgeField(color: mint, reach: 76, alpha: 0.36, retreatDuration: retreatDuration)
        base.opacity = 1; pulse.addSublayer(base)
        if fullMotion {
            for index in 0..<2 {
                let wave = edgeField(color: index == 0 ? aqua : mint, reach: index == 0 ? 68 : 54,
                                     alpha: 0.15, retreatDuration: Self.recoveryDuration)
                wave.name = "recovery.wave"; pulse.addSublayer(wave)
                animatePulse(wave, duration: 3.4, delay: Double(index) * 0.7)
            }
            addRecoveryParticles(to: pulse, mint: mint, aqua: aqua)
        }
        // A brief arrival, then decreasing light and inward reach for the full recovery.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.80, 0.46, 0]
        fade.keyTimes = [0, 0.035, 0.35, 0.72, 1]
        fade.duration = Self.recoveryDuration
        fade.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1),
                                CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear),
                                CAMediaTimingFunction(name: .easeOut)]
        pulse.add(fade, forKey: pulseKey)
    }

    func cancelRecoveryPulse() {
        removeEffect(recoveryPulse)
        recoveryPulse = nil
    }

    private func rebuildMovingHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        removeEffect(movingHighlight); movingHighlight = nil
        guard let appearance = glowAppearance, appearance.animated,
              !appearance.reduceMotion, !appearance.reduceTransparency, let profile,
              bounds.width > 0, bounds.height > 0 else { return }
        let container = CALayer(); container.frame = bounds
        let mask = edgeField(color: .black, reach: profile.reach, alpha: 1)
        mask.opacity = 1
        container.mask = mask
        let highlight = CAGradientLayer()
        let diameter: CGFloat = 260
        highlight.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        highlight.type = .radial
        highlight.startPoint = CGPoint(x: 0.5, y: 0.5); highlight.endPoint = CGPoint(x: 1, y: 1)
        highlight.colors = [profile.color.withAlphaComponent(0.13).cgColor, profile.color.withAlphaComponent(0).cgColor]
        highlight.locations = [0, 1]
        container.addSublayer(highlight)
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.path = CGPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), cornerWidth: 22, cornerHeight: 22, transform: nil)
        travel.calculationMode = .paced
        travel.duration = appearance.status == .distracted ? 14 : 20
        travel.repeatCount = .infinity
        highlight.add(travel, forKey: motionKey)
        layer?.addSublayer(container)
        movingHighlight = container
    }

    private func edgeField(color: NSColor, reach: CGFloat, alpha: CGFloat,
                           retreatDuration: TimeInterval? = nil) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let field = CALayer(); field.frame = bounds; field.opacity = 0
        field.masksToBounds = true
        let reduceTransparency = glowAppearance?.reduceTransparency == true
        let count = reduceTransparency ? 1 : Int(min(reach, min(bounds.width, bounds.height) / 4))
        for index in 0..<max(0, count) {
            let ring = CAShapeLayer()
            ring.frame = field.bounds
            let width: CGFloat = reduceTransparency ? 2.5 : 1
            let inset = reduceTransparency ? width / 2 : CGFloat(index) + 0.5
            let rect = bounds.insetBy(dx: inset, dy: inset)
            ring.path = CGPath(roundedRect: rect, cornerWidth: max(0, 22 - inset),
                               cornerHeight: max(0, 22 - inset), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = color.withAlphaComponent(reduceTransparency ? 1 : alpha * pow(1 - inset / reach, 2.3)).cgColor
            ring.lineWidth = width
            field.addSublayer(ring)
            if let retreatDuration, !reduceTransparency {
                // Fade each inward ring as the edge field contracts. Scaling a full-screen
                // rectangle would pull the glow away from the physical screen edges.
                let originalFalloff = pow(1 - inset / reach, 2.3)
                let retreat = CAKeyframeAnimation(keyPath: "opacity")
                let progress = (0...20).map { CGFloat($0) / 20 }
                retreat.values = progress.map { value -> CGFloat in
                    let currentReach = reach * (1 - value)
                    guard currentReach > inset else { return 0 }
                    return pow(1 - inset / currentReach, 2.3) / originalFalloff
                }
                retreat.keyTimes = progress.map { NSNumber(value: Double($0)) }
                retreat.duration = retreatDuration
                ring.opacity = 0
                ring.add(retreat, forKey: retreatKey)
            }
        }
        return field
    }

    private func animatePulse(_ pulse: CALayer, duration: TimeInterval, delay: TimeInterval = 0) {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.65, 0]
        fade.keyTimes = [0, 0.12, 0.38, 1]
        fade.duration = duration
        fade.beginTime = pulse.convertTime(CACurrentMediaTime(), from: nil) + delay
        fade.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1),
                                CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
        pulse.add(fade, forKey: pulseKey)
    }

    private func addRecoveryParticles(to field: CALayer, mint: NSColor, aqua: NSColor) {
        let start = field.convertTime(CACurrentMediaTime(), from: nil)
        for index in 0..<24 {
            let wave = index / 12, column = index % 12
            let particle = CAShapeLayer(); particle.name = "recovery.plus"
            let size: CGFloat = index.isMultiple(of: 3) ? 13 : 9
            particle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            particle.position = CGPoint(x: bounds.width * (0.06 + CGFloat(column) * 0.078 + CGFloat(wave) * 0.018), y: 10)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: size / 2, y: 0)); path.addLine(to: CGPoint(x: size / 2, y: size))
            path.move(to: CGPoint(x: 0, y: size / 2)); path.addLine(to: CGPoint(x: size, y: size / 2))
            let color = index.isMultiple(of: 2) ? mint : aqua
            particle.path = path; particle.strokeColor = color.cgColor; particle.fillColor = nil
            particle.lineWidth = 2; particle.lineCap = .round; particle.opacity = 0
            particle.shadowColor = color.cgColor; particle.shadowRadius = 3; particle.shadowOpacity = 0.35
            particle.shadowOffset = .zero
            let rise = CAKeyframeAnimation(keyPath: "transform.translation")
            let drift: CGFloat = index.isMultiple(of: 2) ? -14 : 14
            let height = min(bounds.height * 0.24, CGFloat(82 + (index % 4) * 18))
            rise.values = [NSValue(size: .zero), NSValue(size: NSSize(width: drift * 0.5, height: height * 0.64)),
                           NSValue(size: NSSize(width: drift, height: height))]
            rise.keyTimes = [0, 0.55, 1]
            rise.duration = 2.5
            rise.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1), CAMediaTimingFunction(name: .easeOut)]
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.9, 1.12, 1]; scale.keyTimes = [0, 0.22, 1]; scale.duration = 2.5
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.95, 0.75, 0]; fade.keyTimes = [0, 0.14, 0.60, 1]; fade.duration = 2.5
            let animation = CAAnimationGroup(); animation.animations = [rise, scale, fade]
            animation.duration = 2.5
            animation.beginTime = start + 0.1 + Double(wave) * 1.7 + Double(column) * 0.055
            field.addSublayer(particle)
            particle.add(animation, forKey: pulseKey)
        }
        for index in 0..<18 {
            let sparkle = CAShapeLayer(); sparkle.name = "recovery.sparkle"
            let size: CGFloat = index.isMultiple(of: 3) ? 6 : 4
            sparkle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            let left = index.isMultiple(of: 2)
            sparkle.position = CGPoint(x: left ? 14 : bounds.width - 14,
                                       y: bounds.height * (0.08 + CGFloat(index / 2) * 0.09))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: size / 2, y: 0)); path.addLine(to: CGPoint(x: size, y: size / 2))
            path.addLine(to: CGPoint(x: size / 2, y: size)); path.addLine(to: CGPoint(x: 0, y: size / 2)); path.closeSubpath()
            sparkle.path = path; sparkle.fillColor = (left ? aqua : mint).cgColor; sparkle.opacity = 0
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0; rise.toValue = 36 + index % 3 * 10; rise.duration = 2.4
            rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.8, 0.4, 0]; fade.keyTimes = [0, 0.2, 0.65, 1]; fade.duration = 2.4
            let animation = CAAnimationGroup(); animation.animations = [rise, fade]
            animation.duration = 2.4; animation.beginTime = start + 0.12 + Double(index) * 0.13
            field.addSublayer(sparkle); sparkle.add(animation, forKey: pulseKey)
        }
    }

    private func removeEffect(_ effect: CALayer?) {
        guard let effect else { return }
        effect.removeAllAnimations()
        for child in effect.sublayers ?? [] { removeEffect(child) }
        effect.removeFromSuperlayer()
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
