import CoreGraphics
import Foundation

/// Keeps the goal display out of the way without flickering at its edge.
public struct HUDVisibilityPolicy {
    public private(set) var isAvoidingPointer = false
    private var clearSince: TimeInterval?
    public init() {}

    public mutating func shouldShow(enabled: Bool, pointer: CGPoint, frame: CGRect, at now: TimeInterval) -> Bool {
        guard enabled else {
            isAvoidingPointer = false; clearSince = nil
            return false
        }
        if frame.insetBy(dx: -24, dy: -24).contains(pointer) {
            isAvoidingPointer = true; clearSince = nil
            return false
        }
        guard isAvoidingPointer else { return true }
        // A larger exit region prevents rapid show/hide cycles near a browser tab.
        guard !frame.insetBy(dx: -44, dy: -44).contains(pointer) else {
            clearSince = nil; return false
        }
        if clearSince == nil { clearSince = now }
        guard now - (clearSince ?? now) >= 0.35 else { return false }
        isAvoidingPointer = false; clearSince = nil
        return true
    }
}
