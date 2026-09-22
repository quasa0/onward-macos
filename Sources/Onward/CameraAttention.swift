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
    private var calibrated = false
    private var isCalibrating = false
    private var calibrationCommand = CameraCalibrationCommand()

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
        if !allowed { isCalibrating = false; calibrationCommand = CameraCalibrationCommand() }
        worker?.cancelPending(generation: generation)
        if enabled && authorized && worker == nil { makeWorker() }
        worker?.configure(generation: generation, active: allowed && active,
                          previewVisible: allowed && previewVisible, calibration: calibrationCommand)
        if !allowed || (!previewVisible && !isCalibrating) { onFrame?(nil) }
        guard !run, !isCalibrating else { return }
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
        isCalibrating = true
        calibrationCommand = CameraCalibrationCommand(startedUptime: ProcessInfo.processInfo.systemUptime)
        if worker == nil { makeWorker() }
        worker?.cancelPending(generation: generation)
        onUpdate(.init(status: .calibrating, reason: "Look at the center target and hold still.",
                       calibrated: calibrated, calibrationSecondsRemaining: 20))
        worker?.configure(generation: generation, active: configuration.active,
                          previewVisible: configuration.previewVisible, calibration: calibrationCommand)
    }

    func cancelCalibration() {
        guard isCalibrating, let configuration else { return }
        generation = UUID(); isCalibrating = false
        calibrationCommand = CameraCalibrationCommand()
        worker?.configure(generation: generation, active: configuration.active && !configuration.suspended,
                          previewVisible: configuration.previewVisible && !configuration.suspended, calibration: calibrationCommand)
        if !configuration.previewVisible { onFrame?(nil) }
        onUpdate(.init(status: configuration.active || configuration.previewVisible ? .uncertain : .disabled,
                       reason: "Calibration cancelled.", calibrated: calibrated))
    }

    func stop() {
        configuration = nil
        isCalibrating = false
        calibrationCommand = CameraCalibrationCommand()
        generation = UUID()
        worker?.shutdown(generation: generation)
        worker = nil
        onFrame?(nil)
    }

    private func makeWorker() {
        worker = CameraAttentionWorker(onUpdate: { [weak self] token, snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.calibrated = snapshot.calibrated
                self.isCalibrating = snapshot.calibrationSecondsRemaining != nil
                self.onUpdate(snapshot)
            }
        }, onFrame: { [weak self] token, frame in
            guard let self, self.generation == token else { return }
            self.onFrame?(frame)
        })
    }

    deinit { worker?.shutdown(generation: UUID()) }
}

/// Every mode update carries the latest request, so a superseded queued update cannot lose a start/cancel.
private struct CameraCalibrationCommand {
    let revision = UUID()
    var startedUptime: TimeInterval? = nil
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
    private var calibration: CameraGazeCalibration?
    private var calibrator = CameraGazeCalibrator()
    private var calibrationStartedUptime: TimeInterval?
    private var appliedCalibrationRevision: UUID?
    private var calibrationCompleted = false
    private var lastSnapshot: CameraAttentionSnapshot?
    private var lastRecoveryUptime: TimeInterval?
    private let calibrationKey = "cameraAttention.numericCalibration.v1"

    private struct StoredCalibration: Codable {
        let deviceID: String
        let calibration: CameraGazeCalibration
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

    func configure(generation token: UUID, active: Bool, previewVisible: Bool, calibration command: CameraCalibrationCommand) {
        cancelPending(generation: token)
        queue.async { [self] in
            guard accepts(token) else { return }
            generation = token
            self.active = active
            self.previewVisible = previewVisible
            if appliedCalibrationRevision != command.revision {
                appliedCalibrationRevision = command.revision
                policy.reset(); calibrator = CameraGazeCalibrator(); calibrationCompleted = false
                calibrationStartedUptime = command.startedUptime
            }
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
            generation = token; active = false; previewVisible = false; calibrationStartedUptime = nil
            stopSession(); removeObservers(); policy.reset()
        }
    }

    private func emit(_ snapshot: CameraAttentionSnapshot) {
        guard accepts(generation) else { return }
        var snapshot = snapshot
        snapshot.calibrationProgress = calibrationCompleted ? 1 : calibrator.progress
        snapshot.calibrationSecondsRemaining = calibrationStartedUptime.map { max(0, 20 - (ProcessInfo.processInfo.systemUptime - $0)) }
        lastSnapshot = snapshot
        onUpdate(generation, snapshot)
    }

    private func state(_ status: CameraAttentionStatus, _ reason: String) {
        if [.disabled, .permissionNeeded, .unavailable].contains(status) { previewFrames.offer(nil, generation: generation) }
        emit(.init(status: calibrationStartedUptime == nil ? status : .calibrating,
                   reason: reason, calibrated: calibration != nil))
    }

    private var shouldRun: Bool { active || previewVisible || calibrationStartedUptime != nil }
    private var shouldPreview: Bool { previewVisible || calibrationStartedUptime != nil }

    private func startSession(token: UUID) {
        guard accepts(token), shouldRun else { return }
        if let start = calibrationStartedUptime, ProcessInfo.processInfo.systemUptime - start >= 20 {
            finishCalibration(succeeded: false)
            if !shouldRun { return }
        }
        startWatchdog()
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            calibrationStartedUptime = nil
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
                    calibration = loadCalibration(deviceID: device.uniqueID)
                    calibrator = CameraGazeCalibrator()
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
            state(calibrationStartedUptime == nil ? .uncertain : .calibrating,
                  calibrationStartedUptime == nil ? "Waiting for local camera evidence." : "Look at the center of your screen and hold still.")
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
            // Wall-clock corrections cannot extend a temporary, paused-session capture.
            if let start = self.calibrationStartedUptime, uptime - start >= 20 {
                self.finishCalibration(succeeded: false); return
            }
            if self.lastCapturedUptime.map({ uptime - $0 > 3 }) ?? true {
                self.previewFrames.offer(nil, generation: self.generation)
            }
            if self.lastFrameAt.map({ now.timeIntervalSince($0) > CameraAttentionPolicy.maximumFrameGap }) ?? true {
                self.policy.reset()
                if self.calibrationStartedUptime != nil {
                    _ = self.calibrator.add(nil, at: now)
                    self.state(.calibrating, "Waiting for camera frames. Keep the camera connected.")
                } else { self.state(.uncertain, "Waiting for usable camera frames.") }
            } else if self.calibrationStartedUptime != nil, var snapshot = self.lastSnapshot {
                snapshot.status = .calibrating
                self.emit(snapshot)
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
            let request = VNDetectFaceLandmarksRequest()
            request.revision = VNDetectFaceLandmarksRequestRevision3
            do {
                try VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up).perform([request])
                guard accepts(token), Date().timeIntervalSince(now) <= CameraAttentionPolicy.maximumFrameGap else { return }
                if let start = calibrationStartedUptime, ProcessInfo.processInfo.systemUptime - start >= 20 {
                    finishCalibration(succeeded: false); return
                }
                lastFrameAt = now
                guard let faces = request.results else {
                    _ = calibrator.add(nil, at: now)
                    if calibrationStartedUptime != nil {
                        state(.calibrating, "Vision returned no usable result. Keep facing the target.")
                    } else { emit(policy.update(.uncertain, at: now, calibrated: calibration != nil)) }
                    return
                }
                let face = faces.count == 1 ? faces[0] : nil
                let reliableFace = face.map { $0.confidence >= 0.7 && $0.boundingBox.width >= 0.10 && $0.boundingBox.height >= 0.10 } ?? false
                let imageSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                let sample = reliableFace ? face.flatMap { gazeSample($0, imageSize: imageSize) } : nil
                let faceBounds = reliableFace ? face?.boundingBox : nil
                let pupils = sample != nil ? face.map(pupilPoints) ?? [] : []
                if calibrationStartedUptime != nil {
                    if let learned = calibrator.add(sample, at: now) {
                        calibration = learned
                        if let deviceID, let data = try? JSONEncoder().encode(StoredCalibration(deviceID: deviceID, calibration: learned)) {
                            UserDefaults.standard.set(data, forKey: calibrationKey)
                        }
                        finishCalibration(succeeded: true, faceBounds: faceBounds, pupilPoints: pupils)
                    } else {
                        let reason: String
                        if faces.isEmpty { reason = "No face found. Sit in view of the camera." }
                        else if faces.count > 1 { reason = "More than one face is visible. Keep only your face in view." }
                        else if !reliableFace { reason = "Move closer so your face is clear and well lit." }
                        else if sample == nil { reason = "Eyes are not clear. Face the center target with both eyes open." }
                        else { reason = calibrator.reason }
                        emit(.init(status: .calibrating, reason: reason, calibrated: calibration != nil,
                                   observedAt: now, faceBounds: faceBounds, pupilPoints: pupils))
                    }
                    return
                }
                let evidence: CameraAttentionEvidence
                if faces.isEmpty { evidence = .noFace }
                else if !reliableFace { evidence = .uncertain }
                else if let calibration { evidence = calibration.evidence(for: sample) }
                else { evidence = .facePresent }
                var snapshot = policy.update(evidence, at: now, calibrated: calibration != nil)
                snapshot.faceBounds = faceBounds
                snapshot.pupilPoints = pupils
                snapshot.gazeOffset = calibration?.gazeOffset(for: sample)
                emit(snapshot)
            } catch {
                guard accepts(token) else { return }
                lastFrameAt = now
                _ = calibrator.add(nil, at: now)
                if calibrationStartedUptime != nil {
                    state(.calibrating, "Vision could not read this frame. Adjust the lighting and face the target.")
                } else { emit(policy.update(.uncertain, at: now, calibrated: calibration != nil)) }
            }
        }
    }

    private func finishCalibration(succeeded: Bool, faceBounds: CGRect? = nil, pupilPoints: [CGPoint] = []) {
        calibrationStartedUptime = nil; calibrator = CameraGazeCalibrator(); policy.reset()
        calibrationCompleted = succeeded
        updateFrameRate()
        if !succeeded { previewFrames.offer(nil, generation: generation) }
        emit(.init(status: succeeded ? (shouldRun ? .uncertain : .disabled) : .unavailable,
                   reason: succeeded ? (shouldRun ? "Calibrated. Checking screen attention." : "Calibrated. Camera attention resumes with focus.")
                    : "Calibration timed out. Keep both eyes visible, face the target, and retry.",
                   calibrated: calibration != nil, faceBounds: faceBounds, pupilPoints: pupilPoints,
                   gazeOffset: succeeded ? .zero : nil))
        if !shouldPreview { previewFrames.offer(nil, generation: generation) }
        if !shouldRun {
            let token = generation
            // Return the current sample buffer before synchronously stopping its capture session.
            queue.async { [weak self] in
                guard let self, self.accepts(token), !self.shouldRun else { return }
                self.stopSession(); self.removeObservers()
            }
        }
    }

    private func pupilPoints(_ face: VNFaceObservation) -> [CGPoint] {
        guard let landmarks = face.landmarks else { return [] }
        return [landmarks.leftPupil, landmarks.rightPupil].compactMap { region in
            guard let region, region.pointCount == 1 else { return nil }
            let point = region.normalizedPoints[0]
            return CGPoint(x: face.boundingBox.minX + point.x * face.boundingBox.width,
                           y: face.boundingBox.minY + point.y * face.boundingBox.height)
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
