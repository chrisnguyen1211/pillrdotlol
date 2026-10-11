import AppKit
import AVFoundation
import Speech

/// Hold fn to speak a reply: the words appear in the field as they are
/// said, and stay there when fn is let go, to be read over and sent.
///
/// Recognised on this Mac where the language allows it (on-device speech);
/// where it doesn't, by Apple's speech recognition, as macOS's own
/// dictation does. Nothing is sent anywhere else, and nothing is kept.
@MainActor
final class VoiceDictation: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        /// Something stopped it, said in a few words.
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// What has been heard so far in this hold.
    @Published private(set) var heard = ""
    /// How loud the voice is, 0…1, for the meter.
    @Published private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    var isListening: Bool { state == .listening }

    /// Starts listening, asking for the microphone and speech recognition
    /// the first time.
    func start() {
        guard state != .listening else { return }
        heard = ""
        state = .listening
        Task { @MainActor in
            guard await Self.allowed() else {
                state = .failed(L10n.t("Allow pillr the microphone and speech recognition in System Settings → Privacy & Security."))
                return
            }
            // Let go before the questions were answered.
            guard state == .listening else { return }
            do {
                try begin()
            } catch {
                state = .failed(L10n.t("Couldn't start listening."))
                stopEngine()
            }
        }
    }

    /// Stops listening; what was heard stays in `heard`.
    func stop() {
        guard state == .listening else { return }
        request?.endAudio()
        stopEngine()
        state = .idle
    }

    private func begin() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            state = .failed(L10n.t("Speech recognition isn't available right now."))
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.heard = text }
                if final || error != nil {
                    self.task = nil
                    self.request = nil
                }
            }
        }
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        level = 0
    }

    /// The microphone and speech recognition, asked for once each.
    private static func allowed() async -> Bool {
        let speech: Bool = await withCheckedContinuation { done in
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: done.resume(returning: true)
            case .notDetermined: SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
            default: done.resume(returning: false)
            }
        }
        guard speech else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Loudness of a buffer, 0…1, from its RMS in decibels.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let db = 20 * log10(max(rms, 0.000_01))
        return Double(min(1, max(0, (db + 50) / 50)))
    }

    // MARK: Pieces kept apart for testing

    /// The field's text while speaking: what was typed before, then the
    /// words heard, with one space between.
    nonisolated static func merge(typed: String, heard: String) -> String {
        let heard = heard.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty else { return typed }
        if typed.isEmpty || typed.hasSuffix(" ") { return typed + heard }
        return typed + " " + heard
    }

    /// The fn key (the 🌐 key), pressed or let go, with nothing else held.
    static let fnKeyCode: UInt16 = 63

    nonisolated static func fnChange(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard keyCode == fnKeyCode else { return nil }
        let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard flags.intersection(others).isEmpty else { return false }
        return flags.contains(.function)
    }
}
