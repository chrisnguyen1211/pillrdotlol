import AVFoundation
import Foundation

/// The sound under the tour's intro: a warm drone that rises gently from
/// silence, opens a little as the name appears, and a breath of air as the
/// pill flies to its edge. Synthesised here rather than shipped as a file:
/// it is timed to the intro to the tenth of a second, and nothing about it
/// needs recording.
@MainActor
final class MeditationRise {
    nonisolated static let sampleRate: Double = 44_100
    /// The film's length and a little more, for the last ring to fade in.
    nonisolated static var duration: Double { IntroTimeline.length + 0.9 }
    /// When the bowl is struck — the moment the wordmark lands.
    nonisolated static var strike: Double { IntroTimeline.strike }
    /// When the air moves — the pill on its way to the edge.
    nonisolated static var whoosh: Double { (IntroTimeline.flyFrom + IntroTimeline.flyTo) / 2 }

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    /// Renders the sound and plays it. The render takes a few milliseconds
    /// off the main thread; playback starts as soon as it is ready, so call
    /// this at the intro's first frame.
    /// The sound, rendered once and kept.
    private static var rendered: (left: [Float], right: [Float])?

    /// Renders the sound if it has not been, then calls `ready` — the film
    /// waits for this, so picture and sound start on the same frame.
    /// Rendered while the film ran, the sound began however long the render
    /// took behind the picture: every drop's bloop came late.
    func prepare(_ ready: @escaping () -> Void) {
        if Self.rendered != nil { ready(); return }
        Task.detached(priority: .userInitiated) {
            let samples = Self.render()
            await MainActor.run {
                Self.rendered = samples
                ready()
            }
        }
    }

    /// Plays the prepared sound, now.
    func play(volume: Float = 0.55) {
        guard !Runtime.isUnderTest, let samples = Self.rendered else { return }
        stop()
        start(samples, volume: volume)
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    private func start(_ samples: (left: [Float], right: [Float]), volume: Float) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.left.count))
        else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        samples.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: $0.count) }

        let engine = AVAudioEngine()
        guard TourSounds.hasOutput(engine) else { return }
        let player = AVAudioPlayerNode()
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 35
        engine.attach(player)
        engine.attach(reverb)
        engine.connect(player, to: reverb, format: format)
        engine.connect(reverb, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        do { try engine.start() } catch { return }
        // See `TourSounds.play`: playing on a stopped engine is a crash.
        guard engine.isRunning else { return }
        player.scheduleBuffer(buffer) { [weak self] in
            // Let the reverb's tail ring out before the engine goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self?.stop() }
        }
        player.play()
        self.engine = engine
        self.player = player
    }

    // MARK: The sound

    nonisolated static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    /// The whole thing, sample by sample, as two channels.
    ///
    /// Gentle on purpose: a warm drone rising slowly from nothing, no bright
    /// voices on top, no bell — at the name it only opens, a fifth above
    /// blooming in and fading. Drops land as soft low plips; the flight is a
    /// breath of air.
    nonisolated static func render() -> (left: [Float], right: [Float]) {
        let count = Int(duration * sampleRate)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)

        // D2, D3, A3, F♯4 — warm and low; each a pair a fraction of a hertz
        // apart, so it breathes rather than hums.
        struct Voice { let frequency: Double; let level: Double; let pan: Double }
        let voices = [
            Voice(frequency: 73.42, level: 0.24, pan: 0.48),
            Voice(frequency: 146.83, level: 0.22, pan: 0.42),
            Voice(frequency: 220.00, level: 0.13, pan: 0.6),
            Voice(frequency: 369.99, level: 0.04, pan: 0.64),
        ]
        var phases = [Double](repeating: 0, count: voices.count * 2)
        // The bloom at the name: A4 a fifth above, fading in and away.
        var bloomPhase = 0.0
        var noise: UInt64 = 0x2545_F491_4F6C_DD1D
        var air = 0.0, airLower = 0.0

        for i in 0..<count {
            let t = Double(i) / sampleRate
            // Heard from the first moment — a quick bloom to nearly half —
            // then the slow rise to the name.
            let rise = 0.55 * smooth(0, 0.7, t) + 0.45 * pow(smooth(0.7, strike, t), 1.1)
            let release = 1 - smooth(IntroTimeline.flyTo - 0.6, duration - 0.2, t)
            let pad = rise * release
            // The drone warms as it rises: its upper voices come in late.
            let warmth = smooth(1.0, strike, t)

            var l = 0.0, r = 0.0
            for (v, voice) in voices.enumerated() {
                let gain = voice.level * pad * (v >= 2 ? warmth : 1)
                for o in 0..<2 {
                    let k = v * 2 + o
                    phases[k] += 2 * .pi * (voice.frequency + (o == 0 ? -0.28 : 0.31)) / sampleRate
                    // The pair unequal, so their slow beat breathes rather
                    // than cancels: equal, they fell to silence every couple
                    // of seconds, and the start seemed to come in late.
                    let s = sin(phases[k] + Double(v) * 1.3) * gain * (o == 0 ? 0.62 : 0.3)
                    l += s * (1 - voice.pan) * 2
                    r += s * voice.pan * 2
                }
            }

            let bloom = smooth(strike - 0.4, strike + 1.2, t) * (1 - smooth(strike + 1.6, IntroTimeline.flyTo, t))
            bloomPhase += 2 * .pi * 440 / sampleRate
            let open = sin(bloomPhase) * 0.035 * bloom * (0.8 + 0.2 * sin(t * 2 * .pi * 0.4))
            l += open * 0.9
            r += open * 1.1

            // Air on the flight: noise smoothed twice, a soft swell.
            noise ^= noise << 13; noise ^= noise >> 7; noise ^= noise << 17
            let white = Double(noise % 20_000) / 10_000 - 1
            air += 0.02 * (white - air)
            airLower += 0.3 * (air - airLower)
            let breath = exp(-pow((t - whoosh) / 0.45, 2)) * 0.35
            l += airLower * breath * 0.9
            r += airLower * breath * 1.1

            left[i] = Float(l)
            right[i] = Float(r)
        }

        // A quiet ceiling: it rises, it never shouts.
        for i in 0..<count {
            left[i] = Float(tanh(Double(left[i]) * 0.9) * 0.34)
            right[i] = Float(tanh(Double(right[i]) * 0.9) * 0.34)
        }
        // The drops, each a bloop as it joins the pill — laid over the drone
        // after its ceiling, so they are heard, not flattened under it; and a
        // soft run of bubbles as the liquid becomes glass.
        let drop = TourSounds.render(.drop)
        for (k, at) in IntroTimeline.drops.enumerated() {
            let start = Int(at * sampleRate)
            let pan = 0.35 + 0.3 * Double(k % 3) / 2
            for j in 0..<drop.count where start + j < count {
                left[start + j] += drop[j] * Float(1.7 * (1 - pan))
                right[start + j] += drop[j] * Float(1.7 * pan)
            }
        }
        var settle = [Float](repeating: 0, count: count)
        for k in 0..<7 {
            let at = IntroTimeline.glassFrom + Double(k) * 0.09
            TourSounds.bubble(at: at, from: 420 + Double(k) * 40, rise: 1.2, decay: 0.016, gain: 0.03, into: &settle)
        }
        for i in 0..<count { left[i] += settle[i]; right[i] += settle[i] }
        return (left, right)
    }
}
