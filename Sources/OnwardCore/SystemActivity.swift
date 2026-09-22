import CoreGraphics
import Foundation

public enum SystemActivity {
    public static var idleSeconds: TimeInterval {
        idleSeconds(using: CGEventSource.secondsSinceLastEventType)
    }

    static func idleSeconds(using elapsedTime: (CGEventSourceStateID, CGEventType) -> TimeInterval) -> TimeInterval {
        // CGEventSource.h requires kCGAnyInputEventType for keyboard, mouse, or tablet input.
        // Swift does not import that macro; CGEventTypes.h defines it as ((CGEventType)(~0)).
        let anyInput = CGEventType(rawValue: UInt32.max)!
        return elapsedTime(.combinedSessionState, anyInput)
    }
}
