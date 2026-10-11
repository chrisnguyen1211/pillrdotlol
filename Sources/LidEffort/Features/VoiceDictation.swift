import AppKit
import AVFoundation
import Speech

/// Hold fn to speak a reply: the words appear in the field as they are
/// said, and stay there when fn is let go, to be read over and sent.
///
/// Heard by the same engine as the keyboard's own dictation (Speech's
/// `DictationTranscriber`, on macOS 26 and later), on this Mac, in the first
/// of the Mac's preferred languages it knows: Vietnamese on a Mac set to
/// Vietnamese. Older macOS falls back to `SFSpeechRecognizer`, on the Mac
/// where the language allows. Nothing is recorded or kept.
@MainActor
final class VoiceDictation: ObservableObject {
    enum State: Equatable {
        case idle
        /// Getting the language's model onto the Mac, the first time.
        case preparing
        case listening
        /// Something stopped it, said in a few words.
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// What has been heard in this hold: settled words, then the ones
    /// still being made out. Keeps arriving for a moment after fn is let go.
    @Published private(set) var heard = ""
    /// Until the last words are in, after fn is let go.
    @Published private(set) var transcribing = false
    /// How loud the voice is, 0…1, for the meter.
    @Published private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    // The keyboard's dictation engine.
    /// Ends the microphone's stream into the engine.
    private var finishFeed: (() -> Void)?
    private var analyzer: AnyObject?
    private var results: Task<Void, Never>?
    // The older one.
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Which hold this is, so a late result of the last one is let go.
    private var hold = 0

    var isListening: Bool { state == .listening || state == .preparing }

    /// Starts listening, asking for the microphone the first time.
    func start() {
        guard !isListening else { return }
        hold += 1
        let this = hold
        heard = ""
        transcribing = true
        state = .preparing
        Task { @MainActor in
            do {
                if #available(macOS 26.0, *) {
                    guard await Self.microphoneAllowed() else { throw Refusal.notAllowed }
                    guard this == hold, isListening else { return }
                    try await beginDictation(hold: this)
                } else {
                    guard await Self.allowed() else { throw Refusal.notAllowed }
                    guard this == hold, isListening else { return }
                    try beginRecognizer()
                }
                if this == hold, state == .preparing { state = .listening }
            } catch Refusal.notAllowed {
                fail(L10n.t("Allow pillr the microphone and speech recognition in System Settings → Privacy & Security."))
            } catch Refusal.noLanguage {
                fail(L10n.t("Speech recognition isn't available right now."))
            } catch {
                fail(L10n.t("Couldn't start listening."))
            }
        }
    }

    /// Stops listening; the last words still come into `heard`.
    func stop() {
        guard isListening else { return }
        state = .idle
        stopEngine()
        if let finishFeed {
            finishFeed()
            self.finishFeed = nil
            if #available(macOS 26.0, *), let analyzer = analyzer as? SpeechAnalyzer {
                Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            }
        }
        request?.endAudio()
        // The engine's last words take a moment; never wait forever.
        let this = hold
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if this == hold { transcribing = false }
        }
    }

    private enum Refusal: Error { case notAllowed, noLanguage }

    private func fail(_ why: String) {
        stopEngine()
        finishFeed?()
        finishFeed = nil
        state = .failed(why)
        transcribing = false
    }

    // MARK: The keyboard's dictation engine

    /// The first of the Mac's preferred languages the dictation engine
    /// knows, then the Mac's own locale.
    @available(macOS 26.0, *)
    static func dictationLocale() async -> Locale? {
        for identifier in Locale.preferredLanguages + [Locale.current.identifier] {
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) {
                return locale
            }
        }
        return nil
    }

    @available(macOS 26.0, *)
    private func beginDictation(hold this: Int) async throws {
        guard let locale = await Self.dictationLocale() else { throw Refusal.noLanguage }
        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        // The language's model, fetched by the system the first time.
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        guard this == hold, isListening,
              let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }
        let (stream, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.finishFeed = { feed.finish() }
        results = Task { @MainActor [weak self] in
            var settled = ""
            do {
                for try await result in transcriber.results {
                    guard let self, this == self.hold else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        settled = VoiceDictation.merge(typed: settled, heard: text)
                        self.heard = settled
                    } else {
                        self.heard = VoiceDictation.merge(typed: settled, heard: text)
                    }
                }
            } catch {}
            if let self, this == self.hold { self.transcribing = false }
        }
        try await analyzer.start(inputSequence: stream)
        try startEngine { [feed] buffer, input in
            guard let converted = Self.convert(buffer, from: input, to: format) else { return }
            feed.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// A microphone buffer in the engine's format.
    nonisolated private static func convert(_ buffer: AVAudioPCMBuffer, from input: AVAudioFormat,
                                            to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if input == format { return buffer }
        guard let converter = AVAudioConverter(from: input, to: format) else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / input.sampleRate) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    // MARK: The older engine, before macOS 26

    private func beginRecognizer() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier))
                ?? SFSpeechRecognizer(), recognizer.isAvailable else { throw Refusal.noLanguage }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.addsPunctuation = true
        self.request = request
        let this = hold
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self, this == self.hold else { return }
                if let text { self.heard = text }
                if final { self.transcribing = false; self.task = nil; self.request = nil }
            }
        }
        try startEngine { [weak request] buffer, _ in request?.append(buffer) }
    }

    // MARK: The microphone

    private func startEngine(_ deliver: @escaping @Sendable (AVAudioPCMBuffer, AVAudioFormat) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            deliver(buffer, format)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.level = level }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        level = 0
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
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
