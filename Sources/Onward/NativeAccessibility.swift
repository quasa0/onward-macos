import AppKit
import ApplicationServices

enum NativeAccessibility {
    static func frame(position: Any, size: Any) -> CGRect? {
        guard CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let axPosition = position as! AXValue, axSize = size as! AXValue
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetType(axSize) == .cgSize else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(axPosition, .cgPoint, &point), AXValueGetValue(axSize, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    struct ActivationResult {
        /// True only for the call that issued the enable request.
        let attempted: Bool
        let enabled: Bool
        let pending: Bool
        let errorCode: Int32?
    }

    private struct ProcessIdentity: Hashable {
        let pid: Int32
        let launchedAt: Date?
    }
    private struct Attempt {
        let requestedAt: Date
        let error: AXError
    }
    private static let lock = NSLock()
    private static var attempts: [ProcessIdentity: Attempt] = [:]
    private static let attribute = "AXManualAccessibility" as CFString

    /// Uses Electron's documented assistive-technology opt-in without activating the app.
    static func requestIfSupported(app: AXUIElement, pid: Int32) -> ActivationResult {
        let identity = ProcessIdentity(pid: pid, launchedAt: NSRunningApplication(processIdentifier: pid)?.launchDate)
        lock.lock()
        defer { lock.unlock() }

        var currentValue: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(app, attribute, &currentValue)
        if readResult == .success, currentValue as? Bool == true {
            return ActivationResult(attempted: false, enabled: true, pending: false, errorCode: nil)
        }
        if let attempt = attempts[identity] {
            return ActivationResult(attempted: false, enabled: false,
                                    pending: attempt.error == .success && Date().timeIntervalSince(attempt.requestedAt) < 2.5,
                                    errorCode: attempt.error == .success ? nil : attempt.error.rawValue)
        }

        var settable: DarwinBoolean = false
        let supported = AXUIElementIsAttributeSettable(app, attribute, &settable)
        guard supported == .success, settable.boolValue else {
            return ActivationResult(attempted: false, enabled: false, pending: false,
                                    errorCode: supported == .success ? nil : supported.rawValue)
        }

        // Electron 44 debounces this request for two seconds. Repeating it during
        // capture would restart that delay, so issue at most once per process launch.
        // https://www.electronjs.org/docs/latest/tutorial/accessibility
        let result = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        attempts[identity] = Attempt(requestedAt: Date(), error: result)
        return ActivationResult(attempted: true, enabled: false, pending: result == .success,
                                errorCode: result == .success ? nil : result.rawValue)
    }
}
