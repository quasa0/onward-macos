/// Retains the latest established visual cue while operational state changes independently.
public struct FocusPresentation: Sendable {
    public private(set) var establishedStatus: FocusStatus?
    public private(set) var offGoalSeconds = 0

    public init() {}

    public mutating func update(status: FocusStatus, offGoalSeconds: Int) {
        switch status {
        case .focused:
            establishedStatus = status
            self.offGoalSeconds = 0
        case .drifting, .distracted:
            establishedStatus = status
            self.offGoalSeconds = max(0, offGoalSeconds)
        default:
            break
        }
    }

    public func status(for operationalStatus: FocusStatus) -> FocusStatus {
        establishedStatus ?? operationalStatus
    }

    public mutating func reset() {
        establishedStatus = nil
        offGoalSeconds = 0
    }
}
