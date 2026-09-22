import AVFoundation
import Foundation
import OnwardCore
import Vision

/// Permission is requested only by the explicit settings action. No camera work occurs in init.
@MainActor
final class CameraAttentionController {
    private let onUpdate: (CameraAttentionSnapshot) -> Void
    private var worker: CameraAttentionWorker?
    private var configuration: Configuration?
    private var generation = UUID()
    private var calibrated = false

    private struct Configuration: Equatable {
        let enabled: Bool
        let active: Bool
        let suspended: Bool
        let authorization: AVAuthorizationStatus
    }

    init(onUpdate: @escaping (CameraAttentionSnapshot) -> Void) { self.onUpdate = onUpdate }

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func configure(enabled: Bool, active: Bool, suspended: Bool = false) {
        let next = Configuration(enabled: enabled, active: active, suspended: suspended,
                                 authorization: AVCaptureDevice.authorizationStatus(for: .video))
        guard next != configuration else { return }
        configuration = next
        generation = UUID()
        let authorized = next.authorization == .authorized
        let run = enabled && active && !suspended && authorized
        worker?.cancelPending(generation: generation)
        if enabled && authorized && worker == nil { makeWorker() }
        worker?.configure(generation: generation, active: run, calibrate: false)
        guard !run else { return }
        if enabled && !authorized {
            onUpdate(.init(status: .permissionNeeded, reason: next.authorization == .notDetermined
                           ? "Enable camera access to use local attention detection."
                           : "Allow Camera access for Onward in System Settings."))
        } else {
            onUpdate(.init(status: .disabled, reason: enabled ? "Camera attention is paused." : "Camera attention is off.",
                           calibrated: calibrated))
        }
    }

    func calibrate() {
        guard let configuration, configuration.enabled, !configuration.suspended,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        generation = UUID()
        if worker == nil { makeWorker() }
        worker?.cancelPending(generation: generation)
        worker?.configure(generation: generation, active: configuration.active, calibrate: true)
    }

    func stop() {
        configuration = nil
        generation = UUID()
        worker?.shutdown(generation: generation)
        worker = nil
    }

    private func makeWorker() {
        worker = CameraAttentionWorker { [weak self] token, snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.calibrated = snapshot.calibrated
                self.onUpdate(snapshot)
            }
        }
    }

    deinit { worker?.shutdown(generation: UUID()) }
}

/// All capture, Vision and session mutations run serially. The lock only invalidates pending work.
private final class CameraAttentionWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.onward.camera-attention", qos: .utility)
    private let lock = NSLock()
    private var acceptedGeneration = UUID()
    private let onUpdate: @Sendable (UUID, CameraAttentionSnapshot) -> Void
    private var generation = UUID()
    private var active = false
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var deviceID: String?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var lastFrameTime: TimeInterval = -.infinity
    private var lastFrameAt: Date?
    private var policy = CameraAttentionPolicy()
    private var calibration: CameraGazeCalibration?
    private var calibrator = CameraGazeCalibrator()
    private var calibrationStartedUptime: TimeInterval?
    private var lastRecoveryAt: Date?
    private let calibrationKey = "cameraAttention.numericCalibration.v1"

    private struct StoredCalibration: Codable {
        let deviceID: String
        let calibration: CameraGazeCalibration
    }

    init(onUpdate: @escaping @Sendable (UUID, CameraAttentionSnapshot) -> Void) {
        self.onUpdate = onUpdate
        super.init()
    }

    func cancelPending(generation: UUID) {
        lock.lock(); acceptedGeneration = generation; lock.unlock()
    }

    private func accepts(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return acceptedGeneration == token
    }

    func configure(generation token: UUID, active: Bool, calibrate: Bool) {
        cancelPending(generation: token)
        queue.async { [self] in
            guard accepts(token) else { return }
            generation = token
            self.active = active
            policy.reset(); lastFrameAt = nil; lastFrameTime = -.infinity
            calibrator = CameraGazeCalibrator()
            calibrationStartedUptime = calibrate ? ProcessInfo.processInfo.systemUptime : nil
            if active || calibrate {
                observeIfNeeded()
                startSession(token: token)
            } else {
                stopSession()
                removeObservers()
            }
        }
    }

    func shutdown(generation token: UUID) {
        cancelPending(generation: token)
        queue.async { [self] in
            guard accepts(token) else { return }
            generation = token; active = false; calibrationStartedUptime = nil
            stopSession(); removeObservers(); policy.reset()
        }
    }

    private func emit(_ snapshot: CameraAttentionSnapshot) {
        guard accepts(generation) else { return }
        onUpdate(generation, snapshot)
    }

    private func state(_ status: CameraAttentionStatus, _ reason: String) {
        emit(.init(status: status, reason: reason, calibrated: calibration != nil))
    }

    private func startSession(token: UUID) {
        guard accepts(token), active || calibrationStartedUptime != nil else { return }
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
                    // macOS supports independent output connection frame rates. Vision also throttles below.
                    if connection.isVideoMinFrameDurationSupported { connection.videoMinFrameDuration = CMTime(value: 1, timescale: 2) }
                }
                session.commitConfiguration()
                self.session = session; self.output = output
                if deviceID != device.uniqueID {
                    deviceID = device.uniqueID
                    calibration = loadCalibration(deviceID: device.uniqueID)
                    policy.reset()
                }
            } catch {
                state(.unavailable, "Camera input could not be opened."); return
            }
        }
        guard accepts(token), let session else { stopSession(); return }
        if !session.isRunning { session.startRunning() }
        guard accepts(token) else { stopSession(); return }
        if session.isRunning {
            state(calibrationStartedUptime == nil ? .uncertain : .calibrating,
                  calibrationStartedUptime == nil ? "Waiting for local camera evidence." : "Look at the center of your screen and hold still.")
        } else { state(.unavailable, "The camera could not start. It may be in use by another app.") }
        startWatchdog()
    }

    private func stopSession() {
        watchdog?.cancel(); watchdog = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        if let session, session.isRunning { session.stopRunning() }
        output = nil; session = nil
        lastFrameAt = nil
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
                    guard let self, self.accepts(self.generation), self.active || self.calibrationStartedUptime != nil else { return }
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
                        self.lastRecoveryAt = Date()
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
            // Wall-clock corrections cannot extend a temporary, paused-session capture.
            if let start = self.calibrationStartedUptime, ProcessInfo.processInfo.systemUptime - start >= 20 {
                self.finishCalibration(succeeded: false); return
            }
            if self.lastFrameAt.map({ now.timeIntervalSince($0) > CameraAttentionPolicy.maximumFrameGap }) ?? true {
                self.policy.reset()
                self.state(.uncertain, "Waiting for usable camera frames.")
            }
            // Bounded retry cadence handles a disconnected camera without a busy loop.
            if self.session?.isRunning != true,
               self.lastRecoveryAt.map({ now.timeIntervalSince($0) >= 5 }) ?? true {
                self.lastRecoveryAt = now
                self.stopSession()
                self.startSession(token: self.generation)
            }
        }
        watchdog = timer; timer.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepts(generation), output === self.output, active || calibrationStartedUptime != nil else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        guard uptime - lastFrameTime >= 0.48 else { return }
        lastFrameTime = uptime
        let token = generation, now = Date()
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let request = VNDetectFaceLandmarksRequest()
            request.revision = VNDetectFaceLandmarksRequestRevision3
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                guard accepts(token), Date().timeIntervalSince(now) <= CameraAttentionPolicy.maximumFrameGap else { return }
                lastFrameAt = now
                let faces = request.results ?? []
                let face = faces.count == 1 ? faces[0] : nil
                let reliableFace = face.map { $0.confidence >= 0.7 && $0.boundingBox.width >= 0.10 && $0.boundingBox.height >= 0.10 } ?? false
                let imageSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                let sample = reliableFace ? face.flatMap { gazeSample($0, imageSize: imageSize) } : nil
                if calibrationStartedUptime != nil {
                    if let learned = calibrator.add(sample, at: now) {
                        calibration = learned
                        if let deviceID, let data = try? JSONEncoder().encode(StoredCalibration(deviceID: deviceID, calibration: learned)) {
                            UserDefaults.standard.set(data, forKey: calibrationKey)
                        }
                        finishCalibration(succeeded: true)
                    } else {
                        state(.calibrating, reliableFace ? "Look at the center of your screen and hold still." : "Keep one face visible and look at your screen.")
                    }
                    return
                }
                let evidence: CameraAttentionEvidence
                if faces.isEmpty { evidence = .noFace }
                else if !reliableFace { evidence = .uncertain }
                else if let calibration { evidence = calibration.evidence(for: sample) }
                else { evidence = .facePresent }
                emit(policy.update(evidence, at: now, calibrated: calibration != nil))
            } catch {
                guard accepts(token) else { return }
                lastFrameAt = now
                _ = calibrator.add(nil, at: now)
                emit(policy.update(.uncertain, at: now, calibrated: calibration != nil))
            }
        }
    }

    private func finishCalibration(succeeded: Bool) {
        calibrationStartedUptime = nil; calibrator = CameraGazeCalibrator(); policy.reset()
        state(succeeded ? (active ? .uncertain : .disabled) : .unavailable,
              succeeded ? (active ? "Calibrated. Checking screen attention." : "Calibrated. Camera attention resumes with focus.")
                : "Calibration could not get stable eyes. Adjust the camera or lighting and retry.")
        if !active {
            let token = generation
            // Return the current sample buffer before synchronously stopping its capture session.
            queue.async { [weak self] in
                guard let self, self.accepts(token), !self.active, self.calibrationStartedUptime == nil else { return }
                self.stopSession(); self.removeObservers()
            }
        }
    }

    private func loadCalibration(deviceID: String) -> CameraGazeCalibration? {
        guard let data = UserDefaults.standard.data(forKey: calibrationKey),
              let saved = try? JSONDecoder().decode(StoredCalibration.self, from: data),
              saved.deviceID == deviceID, saved.calibration.baseline.isValid else { return nil }
        return saved.calibration
    }

    private func gazeSample(_ face: VNFaceObservation, imageSize: CGSize) -> CameraGazeSample? {
        guard let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue,
              let roll = face.roll?.doubleValue, abs(roll) <= 0.35,
              let landmarks = face.landmarks, landmarks.confidence >= 0.5,
              let left = pupil(eye: landmarks.leftEye, pupil: landmarks.leftPupil, face: face, imageSize: imageSize),
              let right = pupil(eye: landmarks.rightEye, pupil: landmarks.rightPupil, face: face, imageSize: imageSize) else { return nil }
        return .init(yaw: yaw, pitch: pitch, leftPupilX: left.x, leftPupilY: left.y,
                     rightPupilX: right.x, rightPupilY: right.y)
    }

    private func pupil(eye: VNFaceLandmarkRegion2D?, pupil: VNFaceLandmarkRegion2D?, face: VNFaceObservation,
                       imageSize: CGSize) -> (x: Double, y: Double)? {
        guard let eye, eye.pointCount >= 4, let pupil, pupil.pointCount == 1 else { return nil }
        let points = eye.normalizedPoints
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return nil }
        // Convert face-relative proportions to the image plane before checking eye openness.
        let width = (maxX - minX) * face.boundingBox.width * imageSize.width
        let height = (maxY - minY) * face.boundingBox.height * imageSize.height
        guard width >= 8, height / width >= 0.14, height / width <= 0.65 else { return nil }
        let point = pupil.normalizedPoints[0]
        let x = (point.x - minX) / (maxX - minX)
        let y = (point.y - (minY + maxY) / 2) * face.boundingBox.height * imageSize.height / width
        guard x.isFinite, y.isFinite, (0...1).contains(x), abs(y) <= 0.4 else { return nil }
        return (Double(x), Double(y))
    }
}
