import AppKit

enum WarningSoundChoice: String, CaseIterable, Identifiable {
    case lowWarning, error, alarm, pulse, radar, knock, buzzer, bell, siren, chirp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lowWarning: "Low warning"
        case .error: "Error"
        case .alarm: "Alarm"
        case .pulse: "Pulse"
        case .radar: "Radar"
        case .knock: "Knock"
        case .buzzer: "Buzzer"
        case .bell: "Bell"
        case .siren: "Siren"
        case .chirp: "Chirp"
        }
    }
    var detail: String {
        switch self {
        case .lowWarning: "A low, descending double buzz."
        case .error: "Three descending electronic tones."
        case .alarm: "Alternating, urgent bursts."
        case .pulse: "Rounded, low pulses."
        case .radar: "Spaced electronic pings."
        case .knock: "Two woody knocks."
        case .buzzer: "A short, rough buzz."
        case .bell: "A gentle, low metallic ring."
        case .siren: "A falling warning wail."
        case .chirp: "A short, downward digital chirp."
        }
    }
    var resourceName: String { self == .lowWarning ? "OnwardWarning" : "OnwardWarning-\(rawValue)" }
}

enum TimeCueSoundChoice: String, CaseIterable, Identifiable {
    case tick, wood, drop, tap, air
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tick: "Soft tick"
        case .wood: "Wood"
        case .drop: "Drop"
        case .tap: "Tap"
        case .air: "Air"
        }
    }
    var resourceName: String { "OnwardTime-\(rawValue)" }
}

/// Separate retained channels, with warnings taking priority over automatic time cues.
@MainActor final class SoundPlayer {
    static let shared = SoundPlayer()
    private var cache: [String: NSSound] = [:]
    private var warning: NSSound?
    private var timeCue: NSSound?

    private init() {}

    func playWarning(_ choice: WarningSoundChoice, volume: Double, restart: Bool = false) throws {
        guard volume.isFinite, volume > 0 else { warning?.stop(); return }
        let sound = try cached(choice.resourceName)
        if warning === sound, sound.isPlaying, !restart { return }
        timeCue?.stop(); warning?.stop()
        warning = sound
        try play(sound, volume: volume)
    }

    func playTimeCue(_ choice: TimeCueSoundChoice, volume: Double, preview: Bool = false) throws {
        guard volume.isFinite, volume > 0 else { timeCue?.stop(); return }
        if warning?.isPlaying == true, !preview { return }
        let sound = try cached(choice.resourceName)
        if preview { warning?.stop() }
        timeCue?.stop(); timeCue = sound
        try play(sound, volume: volume)
    }

    func stopTimeCue() { timeCue?.stop() }
    func stopAll() { warning?.stop(); timeCue?.stop() }

    static func savedVolume(_ key: String, fallback: Double) -> Double {
        guard let value = UserDefaults.standard.object(forKey: key) as? Double, value.isFinite else { return fallback }
        return min(1, max(0, value))
    }

    private func cached(_ name: String) throws -> NSSound {
        if let sound = cache[name] { return sound }
        let sound = try Self.load(resourceName: name)
        cache[name] = sound
        return sound
    }

    private func play(_ sound: NSSound, volume: Double) throws {
        sound.volume = Float(volume.isFinite ? min(1, max(0, volume)) : 0)
        guard sound.volume > 0 else { return }
        sound.currentTime = 0
        guard sound.play() else { throw SoundError.playback }
    }

    /// The installed smoke test decodes every bundled choice without playing it.
    static func load(resourceName: String) throws -> NSSound {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: false),
              sound.duration > 0.02, sound.duration < 3 else {
            throw SoundError.resource(resourceName)
        }
        return sound
    }

    enum SoundError: LocalizedError {
        case playback, resource(String)
        var errorDescription: String? {
            switch self {
            case .playback: "Could not play the sound. Check your audio output in System Settings."
            case .resource(let name): "Could not load bundled sound: \(name). Reinstall Onward."
            }
        }
    }
}
