import AppKit
import SwiftUI
import Combine
import UserNotifications
import OnwardCore
import Darwin

@main struct OnwardApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let arguments = Array(CommandLine.arguments.dropFirst())
        let background = arguments.contains("--background")
        let appLaunch = arguments.allSatisfy { ["--background", "--resume"].contains($0) }
        if !appLaunch {
            app.setActivationPolicy(.prohibited)
            Task { await CommandLineTools.run(Array(CommandLine.arguments.dropFirst())); exit(0) }
            app.run(); return
        }
        // CLI smoke/preview processes share the bundle ID, but are not GUI instances.
        let instanceLock = Darwin.open(AppStorage.directory.appendingPathComponent("gui-instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard instanceLock >= 0 else { fputs("Could not open Onward's instance lock.\n", stderr); return }
        defer { Darwin.close(instanceLock) }
        guard flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            if !background, let other = NSRunningApplication.runningApplications(withBundleIdentifier: "com.quasa0.Onward").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular }) {
                other.activate(options: [.activateAllWindows])
            }
            return
        }
        let delegate = AppDelegate(showWindowOnLaunch: !background, resumeSession: arguments.contains("--resume"))
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var model: ObserverModel!
    private var window: NSWindow!
    private var item: NSStatusItem!
    private var popover = NSPopover()
    private var hud: NSPanel!
    private let screenGlow = ScreenEdgeGlowController()
    private var hoverTimer: Timer?
    private var hudVisibility = HUDVisibilityPolicy()
    private var hudFader: HUDPanelFader?
    private let showWindowOnLaunch: Bool
    private let resumeSession: Bool
    private var subscriptions = Set<AnyCancellable>()
    private var lastWarningPulseID = 0
    private var lastRecoveryPulseID = 0
    init(showWindowOnLaunch: Bool = true, resumeSession: Bool = false) {
        self.showWindowOnLaunch = showWindowOnLaunch; self.resumeSession = resumeSession
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installMenus()
        model = ObserverModel()
        UNUserNotificationCenter.current().delegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Onward"; window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        window.delegate = self
        window.isReleasedWhenClosed = false; window.setFrameAutosaveName("OnwardMain")
        window.contentView = NSHostingView(rootView: Dashboard(model: model))
        window.center()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuContent(model: model, open: { [weak self] in self?.openWindow() }))
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: GoalHUD.canvasWidth, height: GoalHUD.canvasHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.isOpaque = false; hud.backgroundColor = .clear; hud.hasShadow = true
        // Even between pointer samples, tabs behind the pill must receive clicks.
        hud.ignoresMouseEvents = true
        hud.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hud.contentView = NSHostingView(rootView: GoalHUD(model: model))
        hudFader = HUDPanelFader(panel: hud)
        model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateChrome() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.updateChrome() }.store(in: &subscriptions)
        let hoverTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHUDVisibility() }
        }
        hoverTimer.tolerance = 0.01
        RunLoop.main.add(hoverTimer, forMode: .common); self.hoverTimer = hoverTimer
        updateChrome()
        if resumeSession && !model.goal.isEmpty { model.start(goal: model.goal, context: model.context) }
        if showWindowOnLaunch { openWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWindow(); return true }
    func applicationDidBecomeActive(_ notification: Notification) { updateCameraPreviewVisibility() }
    func applicationDidResignActive(_ notification: Notification) { model?.setCameraPreviewVisible(false) }
    func windowWillClose(_ notification: Notification) { model?.setCameraPreviewVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { model?.setCameraPreviewVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { updateCameraPreviewVisibility() }
    func applicationWillTerminate(_ notification: Notification) { hoverTimer?.invalidate(); hudFader?.stop(); screenGlow.stop(); model?.stop(); hud?.close() }
    private func installMenus() {
        let menu = NSMenu()
        func addMenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let submenu = NSMenu(title: title)
            root.submenu = submenu; menu.addItem(root)
            items.forEach { submenu.addItem($0) }; return submenu
        }
        _ = addMenu("Onward", [
            NSMenuItem(title: "About Onward", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Hide Onward", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            .separator(),
            NSMenuItem(title: "Quit Onward", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        ])
        _ = addMenu("File", [NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")])
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        _ = addMenu("Edit", [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo, .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        ])
        NSApp.windowsMenu = addMenu("Window", [
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        ])
        NSApp.mainMenu = menu
    }
    func openWindow() {
        popover.performClose(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        updateCameraPreviewVisibility()
    }
    private func updateCameraPreviewVisibility() {
        guard let window, let model else { return }
        model.setCameraPreviewVisible(NSApp.isActive && window.isVisible && !window.isMiniaturized)
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY); NSApp.activate(ignoringOtherApps: true) }
    }
    private func updateChrome() {
        guard model != nil else { return }
        updateCameraPreviewVisibility()
        let image = NSImage(systemSymbolName: "arrow.up.right.circle.fill", accessibilityDescription: "Onward. \(model.displayStatus.title)")
        item.button?.image = image; item.button?.contentTintColor = NSColor(model.displayStatus.color)
        item.button?.title = ""
        item.button?.font = .systemFont(ofSize: 11, weight: .medium)
        item.button?.toolTip = "\(model.displayStatus.title)\n\(model.goal)"
        screenGlow.update(status: model.displayStatus, enabled: model.screenGlowVisible)
        if lastWarningPulseID != model.warningPulseID {
            lastWarningPulseID = model.warningPulseID
            screenGlow.playWarningPulse()
        }
        if lastRecoveryPulseID != model.recoveryPulseID {
            lastRecoveryPulseID = model.recoveryPulseID
            screenGlow.playRecoveryPulse()
        }
        if model.showHUD && !model.goal.isEmpty {
            let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
            if let screen {
                let top = max(screen.safeAreaInsets.top, screen.frame.maxY - screen.visibleFrame.maxY)
                hud.setFrameOrigin(NSPoint(x: screen.frame.midX - GoalHUD.canvasWidth / 2,
                                           y: screen.frame.maxY - top - GoalHUD.canvasHeight - 7))
            }
        }
        updateHUDVisibility()
    }
    private func updateHUDVisibility() {
        guard let model, let hud else { return }
        let visible = hudVisibility.shouldShow(enabled: model.showHUD && !model.goal.isEmpty,
                                              pointer: NSEvent.mouseLocation, frame: hud.frame,
                                              at: ProcessInfo.processInfo.systemUptime)
        hudFader?.setVisible(visible, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner]) }
}

/// Opacity is tracked explicitly so a reversal starts at the last displayed alpha,
/// rather than an animation proxy's target value. Ordering in never exposes alpha 1.
@MainActor private final class HUDPanelFader {
    private weak var panel: NSPanel?
    private var timer: Timer?
    private var generation = UUID()
    private var requestedVisible = false
    private var reduceMotion = false
    private var alpha: CGFloat = 0
    private var startAlpha: CGFloat = 0
    private var targetAlpha: CGFloat = 0
    private var startedAt: TimeInterval = 0
    private var duration: TimeInterval = 0

    init(panel: NSPanel) {
        self.panel = panel
        panel.animationBehavior = .none
        panel.alphaValue = 0
    }

    func setVisible(_ visible: Bool, reduceMotion: Bool) {
        guard let panel else { stop(); return }
        let externallyHidden = visible && !panel.isVisible
        guard requestedVisible != visible || self.reduceMotion != reduceMotion || externallyHidden else { return }
        requestedVisible = visible; self.reduceMotion = reduceMotion
        timer?.invalidate(); timer = nil
        generation = UUID()
        let token = generation
        // The window can be hidden externally (for example by macOS). Always reveal
        // from transparency when ordering it back in, including the first display.
        if externallyHidden {
            alpha = 0; panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        startAlpha = alpha; targetAlpha = visible ? 1 : 0
        guard abs(targetAlpha - startAlpha) > 0.001 else {
            finish(generation: token); return
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        // Reduce Motion keeps a short dissolve, with no scale or translation.
        duration = reduceMotion ? 0.08 : (visible ? 0.40 : 0.14)
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.advance(generation: token) }
        }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advance(generation token: UUID) {
        guard generation == token else { return }
        guard let panel else { stop(); return }
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - startedAt) / duration))
        let eased = requestedVisible ? progress * progress * (3 - 2 * progress) : 1 - pow(1 - progress, 3)
        alpha = startAlpha + (targetAlpha - startAlpha) * CGFloat(eased)
        panel.alphaValue = alpha
        if progress >= 1 { finish(generation: token) }
    }

    private func finish(generation token: UUID) {
        guard generation == token else { return }
        timer?.invalidate(); timer = nil
        alpha = targetAlpha; panel?.alphaValue = alpha
        if !requestedVisible { panel?.orderOut(nil) }
    }

    func stop() {
        generation = UUID(); timer?.invalidate(); timer = nil
        requestedVisible = false; alpha = 0; targetAlpha = 0
        panel?.alphaValue = 0; panel?.orderOut(nil)
    }

    deinit { timer?.invalidate() }
}
