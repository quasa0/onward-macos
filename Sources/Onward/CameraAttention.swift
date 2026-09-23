import AVFoundation
import CoreImage
import Foundation
import OnwardCore
import Vision

/// Permission is requested only by the explicit settings action. No camera work occurs in init.
@MainActor
final class CameraAttentionController {
    private let onUpdate: (CameraAttentionSnapshot) -> Void
    private let onFrame: (@MainActor (CGImage?) -> Void)?
    private var worker: CameraAttentionWorker?
    private var configuration: Configuration?
    private var generation = UUID()
    private var baselineReady = false

    private struct Configuration: Equatable {
        let enabled: Bool
        let active: Bool
        let suspended: Bool
        let previewVisible: Bool
        let authorization: AVAuthorizationStatus
    }

    init(onUpdate: @escaping (CameraAttentionSnapshot) -> Void,
         onFrame: (@MainActor (CGImage?) -> Void)? = nil) {
        self.onUpdate = onUpdate
        self.onFrame = onFrame
    }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func configure(enabled: Bool, active: Bool, suspended: Bool = false, previewVisible: Bool = false) {
        let next = Configuration(enabled: enabled, active: active, suspended: suspended,
                                 previewVisible: previewVisible,
                                 authorization: AVCaptureDevice.authorizationStatus(for: .video))
        guard next != configuration else { return }
        configuration = next
        generation = UUID()
        let authorized = next.authorization == .authorized
        let allowed = enabled && !suspended && authorized
        let run = allowed && (active || previewVisible)
        worker?.cancelPending(generation: generation)
        if enabled && authorized && worker == nil { makeWorker() }
        worker?.configure(generation: generation, active: allowed && active, previewVisible: allowed && previewVisible)
        if !allowed || !previewVisible { onFrame?(nil) }
        guard !run else { return }
        if enabled && !authorized {
            onUpdate(.init(status: .permissionNeeded, reason: next.authorization == .notDetermined
                           ? "Enable camera access to use local attention detection."
                           : "Allow Camera access for Onward in System Settings."))
        } else {
            onUpdate(.init(status: .disabled, reason: enabled ? "Camera attention is paused." : "Camera attention is off.",
                           baselineReady: baselineReady))
        }
    }

    /// Replaces the learned screen direction with the user's current head direction.
    func useCurrentDirectionAsScreen() { worker?.useCurrentDirectionAsScreen(generation: generation) }

    func stop() {
        configuration = nil
        generation = UUID()
        worker?.shutdown(generation: generation)
        worker = nil
        onFrame?(nil)
    }

    private func makeWorker() {
        worker = CameraAttentionWorker(onUpdate: { [weak self] token, snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.baselineReady = snapshot.baselineReady
                self.onUpdate(snapshot)
            }
        }, onFrame: { [weak self] token, frame in
            guard let self, self.generation == token else { return }
            self.onFrame?(frame)
        })
    }

    deinit { worker?.shutdown(generation: UUID()) }
}

/// Coalesces preview delivery, so a busy main actor retains at most one pending image.
private final class CameraPreviewMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (UUID, CGImage?, TimeInterval)?
    private var scheduled = false
    private let deliver: @MainActor @Sendable (UUID, CGImage?) -> Void

    init(deliver: @escaping @MainActor @Sendable (UUID, CGImage?) -> Void) { self.deliver = deliver }

    func offer(_ image: CGImage?, generation: UUID, observedUptime: TimeInterval? = nil) {
        lock.lock()
        pending = (generation, image, observedUptime ?? ProcessInfo.processInfo.systemUptime)
        let schedule = !scheduled
        scheduled = true
        lock.unlock()
        if schedule {
            Task { @MainActor [weak self] in
                guard let self, let (token, frame, uptime) = self.take() else { return }
                self.deliver(token, ProcessInfo.processInfo.systemUptime - uptime <= 3 ? frame : nil)
            }
        }
    }

    private func take() -> (UUID, CGImage?, TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = nil; scheduled = false
        return result
    }
}

/// All capture, Vision and session mutations run serially. The lock only invalidates pending work.
private final class CameraAttentionWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.onward.camera-attention", qos: .utility)
    private let lock = NSLock()
    private var acceptedGeneration = UUID()
    private let onUpdate: @Sendable (UUID, CameraAttentionSnapshot) -> Void
    private let previewFrames: CameraPreviewMailbox
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var generation = UUID()
    private var active = false
    private var previewVisible = false
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var deviceID: String?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var lastFrameTime: TimeInterval = -.infinity
    private var lastPreviewTime: TimeInterval = -.infinity
    private var lastCapturedUptime: TimeInterval?
    private var lastFrameAt: Date?
    private var policy = CameraAttentionPolicy()
    private var baseline = HeadPoseBaseline()
    /// Recent reliable head poses with capture time, for "use my current direction".
    private var recentPoses: [(Date, HeadPose)] = []
    private var lastRecoveryUptime: TimeInterval?
    private let baselineKey = "cameraAttention.headBaseline.v1"

    private struct StoredBaseline: Codable {
        let deviceID: String
        let center: HeadPose
    }

    init(onUpdate: @escaping @Sendable (UUID, CameraAttentionSnapshot) -> Void,
         onFrame: @escaping @MainActor @Sendable (UUID, CGImage?) -> Void) {
        self.onUpdate = onUpdate
        previewFrames = CameraPreviewMailbox(deliver: onFrame)
        super.init()
    }

    func cancelPending(generation: UUID) {
        lock.lock(); acceptedGeneration = generation; lock.unlock()
    }

    private func accepts(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptedGeneration == token
    }

    func configure(generation token: UUID, active: Bool, previewVisible: Bool) {
        cancelPending(generation: token)
        queue.async { [self] in
            guard accepts(token) else { return }
            generation = token
            self.active = active
            self.previewVisible = previewVisible
            if shouldRun {
                observeIfNeeded()
                startSession(token: token)
            } else {
                policy.reset()
                stopSession()
                removeObservers()
            }
            if !shouldPreview { previewFrames.offer(nil, generation: generation) }
        }
    }

    func shutdown(generation token: UUID) {
        cancelPending(generation: token)
        queue.async { [self] in
            guard accepts(token) else { return }
            generation = token; active = false; previewVisible = false
            stopSession(); removeObservers(); policy.reset()
        }
    }

    func useCurrentDirectionAsScreen(generation token: UUID) {
        queue.async { [self] in
            guard accepts(token) else { return }
            let now = Date()
            let recent = recentPoses.filter { now.timeIntervalSince($0.0) <= 2.5 }.map(\.1)
            guard baseline.setCenter(from: recent) else {
                emit(.init(status: .uncertain, reason: "Face your screen with the camera on, then try again.",
                           baselineReady: baseline.isReady, observedAt: now))
                return
            }
            saveBaseline()
            policy.reset()
            emit(.init(status: .uncertain, reason: "Saved your current direction as looking at the screen.",
                       baselineReady: true, observedAt: now))
        }
    }

    private func emit(_ snapshot: CameraAttentionSnapshot) {
        guard accepts(generation) else { return }
        onUpdate(generation, snapshot)
    }

    private func state(_ status: CameraAttentionStatus, _ reason: String) {
        if [.disabled, .permissionNeeded, .unavailable].contains(status) { previewFrames.offer(nil, generation: generation) }
        emit(.init(status: status, reason: reason, baselineReady: baseline.isReady))
    }

    private var shouldRun: Bool { active || previewVisible }
    private var shouldPreview: Bool { previewVisible }

    private func startSession(token: UUID) {
        guard accepts(token), shouldRun else { return }
        startWatchdog()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            stopSession(); state(.permissionNeeded, "Allow Camera access for Onward in System Settings."); return
        }
        if session == nil {
            guard let device = AVCaptureDevice.default(for: .video) else {
                state(.unavailable, "No camera is available."); startWatchdog(); return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard accepts(token) else { return }
                let session = AVCaptureSession()
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
                else if session.canSetSessionPreset(.low) { session.sessionPreset = .low }
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    state(.unavailable, "Camera capture is not supported by this device."); return
                }
                session.addInput(input); session.addOutput(output)
                if let connection = output.connection(with: .video) {
                    if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                }
                session.commitConfiguration()
                self.session = session; self.output = output
                if deviceID != device.uniqueID {
                    deviceID = device.uniqueID
                    baseline = HeadPoseBaseline(center: loadBaseline(deviceID: device.uniqueID))
                    recentPoses.removeAll()
                    policy.reset()
                }
            } catch {
                state(.unavailable, "Camera input could not be opened."); return
            }
        }
        guard accepts(token), let session else { stopSession(); return }
        updateFrameRate()
        if !session.isRunning { session.startRunning() }
        guard accepts(token) else { stopSession(); return }
        if session.isRunning {
            state(.uncertain, "Waiting for local camera evidence.")
        } else { state(.unavailable, "The camera could not start. It may be in use by another app.") }
        startWatchdog()
    }

    private func stopSession() {
        watchdog?.cancel(); watchdog = nil
        previewFrames.offer(nil, generation: generation)
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session, session.isRunning { session.stopRunning() }
        output = nil; session = nil
        lastFrameAt = nil; lastCapturedUptime = nil
        lastFrameTime = -.infinity; lastPreviewTime = -.infinity
    }

    private func updateFrameRate() {
        // macOS supports independent output frame rates. Vision stays at 2 Hz during preview.
        if let connection = output?.connection(with: .video), connection.isVideoMinFrameDurationSupported {
            connection.videoMinFrameDuration = CMTime(value: 1, timescale: shouldPreview ? 10 : 2)
        }
    }

    private func observeIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification,
                     AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self else { return }
                // Session notifications from other applications/instances cannot restart this worker.
                let source = notification.object as? AVCaptureSession
                let device = notification.object as? AVCaptureDevice
                self.queue.async { [weak self] in
                    guard let self, self.accepts(self.generation), self.shouldRun else { return }
                    if let source, source !== self.session { return }
                    if let device {
                        guard device.hasMediaType(.video) else { return }
                        if name == AVCaptureDevice.wasDisconnectedNotification, device.uniqueID != self.deviceID { return }
                        if name == AVCaptureDevice.wasConnectedNotification, self.session?.isRunning == true { return }
                    }
                    self.policy.reset(); self.lastFrameAt = nil
                    if name == AVCaptureSession.wasInterruptedNotification {
                        self.state(.unavailable, "Camera capture was interrupted.")
                    } else if name == AVCaptureSession.runtimeErrorNotification {
                        self.stopSession()
                        self.lastRecoveryUptime = ProcessInfo.processInfo.systemUptime
                        self.state(.unavailable, "Camera capture failed. Waiting to reconnect.")
                        self.startWatchdog()
                    } else {
                        self.stopSession()
                        self.state(.uncertain, "Reconnecting the camera.")
                        self.startSession(token: self.generation)
                    }
                }
            })
        }
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.accepts(self.generation) else { return }
            let now = Date()
            let uptime = ProcessInfo.processInfo.systemUptime
            if self.lastCapturedUptime.map({ uptime - $0 > 3 }) ?? true {
                self.previewFrames.offer(nil, generation: self.generation)
            }
            if self.lastFrameAt.map({ now.timeIntervalSince($0) > CameraAttentionPolicy.maximumFrameGap }) ?? true {
                self.policy.reset()
                self.state(.uncertain, "Waiting for usable camera frames.")
            }
            // Bounded retry cadence handles a disconnected camera without a busy loop.
            if self.session?.isRunning != true,
               self.lastRecoveryUptime.map({ uptime - $0 >= 5 }) ?? true {
                self.lastRecoveryUptime = uptime
                self.stopSession()
                self.startSession(token: self.generation)
            }
        }
        watchdog = timer; timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepts(generation), output === self.output, shouldRun else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let token = generation, now = Date()
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastCapturedUptime = uptime
        autoreleasepool {
            if shouldPreview, uptime - lastPreviewTime >= 0.095 {
                lastPreviewTime = uptime
                let image = CIImage(cvPixelBuffer: buffer)
                let frame = imageContext.createCGImage(image, from: image.extent)
                guard accepts(token) else { return }
                previewFrames.offer(frame, generation: token, observedUptime: uptime)
            }
            guard uptime - lastFrameTime >= 0.48 else { return }
            lastFrameTime = uptime
            let faceRequest = VNDetectFaceRectanglesRequest()
            faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
            do {
                let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
                try handler.perform([faceRequest])
                guard accepts(token), Date().timeIntervalSince(now) <= CameraAttentionPolicy.maximumFrameGap else { return }
                lastFrameAt = now
                let faces = faceRequest.results ?? []
                let face = faces.count == 1 ? faces[0] : nil
                // Head pose comes from the face box, so a small face in frame still works.
                let reliable = face.map { $0.confidence >= 0.6 && $0.boundingBox.width >= 0.05 && $0.boundingBox.height >= 0.05 } ?? false
                let pose = reliable ? face.flatMap(headPose) : nil
                if let pose {
                    recentPoses.append((now, pose))
                    recentPoses.removeAll { now.timeIntervalSince($0.0) > 3 }
                }
                // Body pose only runs when the face alone cannot decide, keeping the usual cost to one request.
                var body = CameraBodyCue.none
                var joints: [CameraBodyJoint: CGPoint] = [:]
                if pose == nil && faces.count <= 1 {
                    let bodyRequest = VNDetectHumanBodyPoseRequest()
                    try? handler.perform([bodyRequest])
                    joints = bodyJoints(bodyRequest.results ?? [])
                    body = CameraBodyCue(joints: joints)
                }
                let wasReady = baseline.isReady
                let evidence = CameraAttentionEstimate.evidence(faceCount: faces.count, pose: pose, body: body, baseline: &baseline)
                if !wasReady && baseline.isReady { saveBaseline() }
                let reason: String?
                if faces.count > 1 { reason = "More than one face is visible." }
                else if pose != nil && !baseline.isReady { reason = "Learning your usual screen direction. Keep working normally." }
                else if pose != nil { reason = "Head partly turned. Waiting for a clearer reading." }
                else if body == .facing { reason = "Body visible, but the face is unclear. Check the lighting." }
                else { reason = nil }
                var snapshot = policy.update(evidence, at: now, baselineReady: baseline.isReady, uncertainReason: reason)
                snapshot.faceBounds = reliable ? face?.boundingBox : nil
                snapshot.bodyPoints = Array(joints.values)
                snapshot.headOffset = baseline.offset(for: pose)
                emit(snapshot)
            } catch {
                guard accepts(token) else { return }
                lastFrameAt = now
                emit(policy.update(.uncertain, at: now, baselineReady: baseline.isReady))
            }
        }
    }

    private func headPose(_ face: VNFaceObservation) -> HeadPose? {
        guard let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue else { return nil }
        let pose = HeadPose(yaw: yaw, pitch: pitch)
        return pose.isValid ? pose : nil
    }

    /// Picks the most visible person and keeps only confident head/shoulder joints.
    private func bodyJoints(_ people: [VNHumanBodyPoseObservation]) -> [CameraBodyJoint: CGPoint] {
        let names: [(CameraBodyJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose), (.leftEye, .leftEye), (.rightEye, .rightEye), (.leftEar, .leftEar), (.rightEar, .rightEar),
            (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder), (.neck, .neck)]
        let candidates = people.map { person -> [CameraBodyJoint: CGPoint] in
            var joints: [CameraBodyJoint: CGPoint] = [:]
            for (joint, name) in names {
                if let point = try? person.recognizedPoint(name), point.confidence >= 0.35 { joints[joint] = point.location }
            }
            return joints
        }
        return candidates.max { $0.count < $1.count } ?? [:]
    }

    private func saveBaseline() {
        guard let deviceID, let center = baseline.center,
              let data = try? JSONEncoder().encode(StoredBaseline(deviceID: deviceID, center: center)) else { return }
        UserDefaults.standard.set(data, forKey: baselineKey)
    }

    private func loadBaseline(deviceID: String) -> HeadPose? {
        guard let data = UserDefaults.standard.data(forKey: baselineKey),
              let saved = try? JSONDecoder().decode(StoredBaseline.self, from: data),
              saved.deviceID == deviceID, saved.center.isValid else { return nil }
        return saved.center
    }
}
