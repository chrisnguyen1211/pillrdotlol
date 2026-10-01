import AVFoundation
import Foundation

/// The small sounds the tour makes as you go through it — soft, and each
/// its own: a muted wooden tap for Next, a warm two-note marimba when you
/// approve, a quiet three-note sparkle when you answer a question, a low
/// falling pair when you say no, water running as the pill moves to another
/// edge, a tick as the effort moves, and a warm chord at the end. Each is
/// synthesised once and kept.
@MainActor
final class TourSounds {
    enum Sound: CaseIterable {
        case next, approve, answer, deny, flow, tick, finish, drop
    }

    nonisolated static let sampleRate: Double = 44_100
    private var engine: AVAudioEngine?
    private(set) var players: [AVAudioPlayerNode] = []
    var engineForTesting: AVAudioEngine? { engine }
    private var nextPlayer = 0
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    func play(_ sound: Sound) {
        guard !Runtime.isUnderTest else { return }
        playNow(sound)
    }

    /// `play` without the test guard, for the test that proves every voice
    /// is wired — the crash this replaced was a voice that was not.
    func playNow(_ sound: Sound) {
        guard let engine = ready() else { return }
        let buffer = buffers[sound] ?? makeBuffer(sound)
        buffers[sound] = buffer
        guard let buffer else { return }
        // A few voices, taken in turn, so a quick Next over a still-ringing
        // chime does not cut it off.
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        if !engine.isRunning { try? engine.start() }
        // A player node raises an Objective-C exception — a crash, not an
        // error — when told to play on an engine that is not running or has
        // nowhere to send the sound: no output device, or one just unplugged.
        guard engine.isRunning, player.engine != nil, Self.hasOutput(engine),
              !engine.outputConnectionPoints(for: player, outputBus: 0).isEmpty else { return }
        player.stop()
        player.scheduleBuffer(buffer)
        player.play()
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        players.forEach { $0.stop() }
        engine?.stop()
        engine = nil
        players = []
    }

    /// Whether the engine has a device to play into.
    static func hasOutput(_ engine: AVAudioEngine) -> Bool {
        engine.outputNode.outputFormat(forBus: 0).channelCount > 0
    }

    private var configurationObserver: NSObjectProtocol?

    private func ready() -> AVAudioEngine? {
        if let engine { return engine }
        let engine = AVAudioEngine()
        guard Self.hasOutput(engine) else { return nil }
        // The output changed — headphones in or out, a display's speakers —
        // and the engine stopped with it. Start again from nothing next time.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.stop() } }
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 38
        // The voices meet in a mixer, each on a bus of its own, and the mixer
        // feeds the reverb. Connected straight to the reverb, whose input is
        // a single bus, each connection replaced the one before: three of
        // the four voices were left unplugged, and the first one asked to
        // play raised an exception that took the app down.
        let bus = AVAudioMixerNode()
        engine.attach(reverb)
        engine.attach(bus)
        engine.connect(bus, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        players = (0..<4).map { _ in
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: bus, fromBus: 0, toBus: bus.nextAvailableInputBus, format: format)
            return player
        }
        engine.mainMixerNode.outputVolume = 0.55
        do { try engine.start() } catch { return nil }
        self.engine = engine
        return engine
    }

    private func makeBuffer(_ sound: Sound) -> AVAudioPCMBuffer? {
        let samples = Self.render(sound)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer {
            buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count)
            buffer.floatChannelData![1].update(from: $0.baseAddress!, count: $0.count)
        }
        return buffer
    }

    // MARK: The sounds

    /// A soft struck tone: a gentle attack, so nothing clicks
    /// or snaps — felt on wood rather than metal.
    nonisolated static func pluck(_ f: Double, at start: Double, decay: Double, gain: Double,
                                  attack: Double = 0.012, into out: inout [Float]) {
        let first = Int(start * sampleRate)
        let last = min(out.count, first + Int(decay * 8 * sampleRate))
        guard first < last else { return }
        for i in first..<last {
            let t = Double(i - first) / sampleRate
            let envelope = min(1, t / attack) * exp(-t / decay)
            // A fundamental and a soft octave: round, no bright edge.
            let s = sin(2 * .pi * f * t) + 0.18 * sin(2 * .pi * f * 2 * t) * exp(-t / (decay * 0.4))
            out[i] += Float(s * envelope * gain)
        }
    }

    /// A bubble: a short tone that rises in pitch as it surfaces and dies
    /// away in tens of milliseconds — what makes water sound like water.
    nonisolated static func bubble(at start: Double, from f: Double, rise: Double, decay: Double, gain: Double,
                                   into out: inout [Float]) {
        let first = Int(start * sampleRate)
        let last = min(out.count, first + Int(decay * 7 * sampleRate))
        guard first < last else { return }
        var phase = 0.0
        for i in first..<last {
            let t = Double(i - first) / sampleRate
            let pitch = f * (1 + rise * t / decay * 0.25)
            phase += 2 * .pi * pitch / sampleRate
            let envelope = exp(-t / decay) * min(1, t / 0.002)
            out[i] += Float(sin(phase) * envelope * gain)
        }
    }

    nonisolated static func render(_ sound: Sound) -> [Float] {
        let length: Double
        switch sound {
        case .next: length = 0.5
        case .approve: length = 1.4
        case .answer: length = 1.6
        case .deny: length = 1.2
        case .flow: length = 0.65
        case .tick: length = 0.25
        case .finish: length = 3.2
        case .drop: length = 0.3
        }
        var out = [Float](repeating: 0, count: Int(length * sampleRate))
        switch sound {
        case .next:
            // A muted wooden tap.
            pluck(392, at: 0, decay: 0.07, gain: 0.07, attack: 0.004, into: &out)
        case .approve:
            // Warm marimba, a fifth up: yes.
            pluck(440, at: 0, decay: 0.28, gain: 0.07, into: &out)
            pluck(659.3, at: 0.11, decay: 0.34, gain: 0.07, into: &out)
        case .answer:
            // A quiet sparkle, higher and lighter — a different "done".
            for (k, f) in [1174.7, 1480.0, 1760.0].enumerated() {
                pluck(f, at: Double(k) * 0.085, decay: 0.32, gain: 0.035, attack: 0.02, into: &out)
            }
        case .deny:
            pluck(392, at: 0, decay: 0.26, gain: 0.06, into: &out)
            pluck(329.6, at: 0.12, decay: 0.3, gain: 0.055, into: &out)
        case .tick:
            pluck(784, at: 0, decay: 0.03, gain: 0.05, attack: 0.003, into: &out)
        case .drop:
            // A drop joining the pill: one round bloop, and a smaller one
            // just after as the surface settles.
            bubble(at: 0, from: 260, rise: 1.1, decay: 0.045, gain: 0.19, into: &out)
            bubble(at: 0.05, from: 520, rise: 0.8, decay: 0.02, gain: 0.05, into: &out)
        case .flow:
            // Liquid moving: a quick run of small bubbles, each rising as it
            // surfaces, the run itself rising as the pill travels — and
            // under it the faintest wash of water.
            var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
            for k in 0..<13 {
                rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
                let jitter = Double(rng % 25) / 1000
                let at = Double(k) * 0.034 + jitter
                let from = 360 + Double(k) * 26 + Double(rng % 140)
                let size = 0.012 + Double(rng % 12) / 1000
                let gain = 0.05 + Double(rng % 30) / 1000
                bubble(at: at, from: from, rise: 1.4, decay: size, gain: gain, into: &out)
            }
            var state: UInt64 = 0x2545_F491_4F6C_DD1D
            var low = 0.0, lower = 0.0
            for i in 0..<out.count {
                let t = Double(i) / sampleRate
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                let white = Double(state % 20_000) / 10_000 - 1
                low += 0.03 * (white - low)
                lower += 0.2 * (low - lower)
                let swell = exp(-pow((t - 0.25) / 0.16, 2))
                out[i] += Float(lower * swell * 0.25)
            }
        case .finish:
            // A warm chord blooming and settling — D, A, F♯ — no bell.
            for (k, f) in [293.66, 440.0, 587.33, 739.99].enumerated() {
                let first = Int(Double(k) * 0.06 * sampleRate)
                for i in first..<out.count {
                    let t = Double(i - first) / sampleRate
                    let envelope = (1 - exp(-t / 0.35)) * exp(-t / 1.1)
                    out[i] += Float(sin(2 * .pi * f * t) * envelope * 0.035)
                }
            }
        }
        return out.map { Float(tanh(Double($0) * 1.2) / 1.2) }
    }
}
