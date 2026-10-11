import AppKit
import AVFoundation
import Carbon
import Speech

/// Hold fn to speak a reply: the words appear in the field as they are
/// said, and stay there when fn is let go, to be read over and sent.
///
/// Heard by Apple's speech recognition, the service the keyboard's dictation
/// uses, in the language of the keyboard input source chosen when fn goes
/// down (Vietnamese Telex: Vietnamese; ABC: English), else the first of the
/// languages set for dictation; on Apple's servers unless dictation is set
/// to work offline only. The Mac's own dictation
/// can't be used for this: it types into the app in front, and the reply
/// field sits in a panel that leaves the app in front where it was.
/// Nothing is recorded or kept.
@MainActor
final class SystemDictation: ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        /// Something stopped it, said in a few words.
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// What has been heard in this hold. Keeps coming for a moment after fn
    /// is let go, while the last words are made out.
    @Published private(set) var heard = ""
    @Published private(set) var transcribing = false
    /// How loud the voice is, 0…1.
    @Published private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var hold = 0

    var isListening: Bool { state == .listening }

    /// Starts listening, asking for the microphone and speech recognition
    /// the first time. `words` are names it should expect: the agent, the
    /// session, the words of the trade.
    func start(expecting words: [String] = []) {
        guard !isListening else { return }
        hold += 1
        let this = hold
        heard = ""
        transcribing = true
        state = .listening
        Task { @MainActor in
            guard await Self.allowed() else {
                fail(L10n.t("Allow pillr the microphone and speech recognition in System Settings → Privacy & Security."))
                return
            }
            // Let go while the questions were up.
            guard this == hold, isListening else { return }
            do {
                try begin(hold: this, expecting: words)
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
        request?.endAudio()
        let this = hold
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if this == hold, transcribing {
                task?.finish()
                transcribing = false
            }
        }
    }

    private func fail(_ why: String) {
        stopEngine()
        task?.cancel()
        task = nil
        request = nil
        state = .failed(why)
        transcribing = false
    }

    private func begin(hold this: Int, expecting words: [String]) throws {
        let settings = Self.dictationSettings()
        let supported = SFSpeechRecognizer.supportedLocales().map(\.identifier)
        let keyboard = Self.keyboardLanguage().flatMap {
            Self.recognizerLocale(for: $0, supported: supported, dictation: settings.languages,
                                  region: Locale.current.region?.identifier)
        }
        let languages = (keyboard.map { [$0] } ?? []) + settings.languages
        guard let recognizer = languages.lazy.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }).first
                ?? SFSpeechRecognizer(), recognizer.isAvailable else {
            fail(L10n.t("Speech recognition isn't available right now."))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = Array((words + Self.tradeWords).prefix(100))
        // As the keyboard's dictation is set: offline only if it is.
        request.requiresOnDeviceRecognition = settings.offlineOnly && recognizer.supportsOnDeviceRecognition
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in
                guard let self, this == self.hold else { return }
                if let text { self.heard = text }
                if done {
                    self.transcribing = false
                    self.task = nil
                    self.request = nil
                }
            }
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            fail(L10n.t("No microphone is available."))
            return
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
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

    // MARK: The keyboard's language

    /// The language of the keyboard input source in use: `vi` for
    /// Vietnamese Telex, `en` for ABC, `zh-Hans` for Pinyin.
    static func keyboardLanguage() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String]
        return languages?.first
    }

    /// The recognizer's locale for a keyboard's language: one the dictation
    /// settings already name, else one in the Mac's own region, else the
    /// language's most common (en-US, zh-CN, pt-BR…), else any.
    nonisolated static func recognizerLocale(for language: String, supported: [String], dictation: [String],
                                             region: String?) -> String? {
        let normalized = supported.map { $0.replacingOccurrences(of: "_", with: "-") }
        func base(_ identifier: String) -> String {
            let parts = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-")
            guard let first = parts.first else { return identifier }
            // zh-Hans and zh-Hant are written languages; their speech is the region's.
            if first == "zh", parts.count > 1, ["Hans", "Hant"].contains(String(parts[1])) { return "zh-\(parts[1])" }
            return String(first)
        }
        let wanted = base(language)
        func speaks(_ identifier: String) -> Bool {
            let lang = base(identifier)
            switch wanted {
            case "zh-Hans": return ["zh-CN", "zh-SG"].contains(identifier) || lang == "zh-Hans"
            case "zh-Hant": return ["zh-TW", "zh-HK"].contains(identifier) || lang == "zh-Hant"
            default: return lang == wanted
            }
        }
        let candidates = normalized.filter(speaks)
        guard !candidates.isEmpty else { return nil }
        if let named = dictation.map({ $0.replacingOccurrences(of: "_", with: "-") }).first(where: candidates.contains) { return named }
        if let region, let local = candidates.first(where: { $0.hasSuffix("-\(region)") }) { return local }
        let usual = ["en-US", "zh-CN", "zh-TW", "pt-BR", "es-ES", "fr-FR", "de-DE", "ja-JP", "ko-KR", "ru-RU", "vi-VN"]
        return usual.first(where: candidates.contains) ?? candidates.sorted().first
    }

    // MARK: The keyboard's dictation settings

    struct DictationSettings: Equatable {
        /// Locale identifiers, first preferred.
        var languages: [String]
        var offlineOnly: Bool
    }

    /// The languages and mode set for the keyboard's dictation, else the
    /// Mac's own languages, on Apple's servers.
    nonisolated static func dictationSettings(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.speech.recognition.AppleSpeechRecognition.prefs"),
                                  preferred: [String] = Locale.preferredLanguages) -> DictationSettings {
        let chosen = (defaults?.array(forKey: "DictationIMPreferredLanguageIdentifiers") as? [String]) ?? []
        let languages = chosen.isEmpty ? preferred : chosen + preferred.filter { lang in !chosen.contains { $0.hasPrefix(String(lang.prefix(2))) } }
        return DictationSettings(languages: languages.map { $0.replacingOccurrences(of: "_", with: "-") },
                                 offlineOnly: defaults?.bool(forKey: "DictationIMUseOnlyOfflineDictation") ?? false)
    }

    /// Words a reply to a coding agent is full of, so they come out as
    /// written rather than as the nearest words of the language spoken.
    nonisolated static let tradeWords = [
        "test", "tests", "commit", "push", "pull", "merge", "deploy", "build", "release", "bug", "fix", "refactor",
        "README", "API", "dashboard", "notch", "pillr", "Claude", "Claude Code", "Codex", "Cursor", "Grok", "Gemini",
        "Kimi", "Copilot", "Antigravity", "landing page", "branch", "main", "pull request", "PR", "log", "terminal",
        "Swift", "SwiftUI", "TypeScript", "Python", "JSON", "server", "database", "endpoint", "UI", "UX",
    ]

    // MARK: Permissions and the meter

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

    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(buffer.frameLength))
        return Double(min(1, max(0, (20 * log10(max(rms, 0.000_01)) + 50) / 50)))
    }

    // MARK: Pieces kept apart for testing

    /// The field's text while speaking: what was typed before, then the
    /// words heard, one space between.
    nonisolated static func merge(typed: String, heard: String) -> String {
        let heard = heard.trimmingCharacters(in: .whitespaces)
        guard !heard.isEmpty else { return typed }
        if typed.isEmpty || typed.hasSuffix(" ") { return typed + heard }
        return typed + " " + heard
    }

    /// The fn key (the 🌐 key).
    nonisolated static let fnKeyCode: UInt16 = 63

    /// fn pressed (true) or let go (false), with nothing else held; nil for
    /// any other key.
    nonisolated static func fnChange(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool? {
        guard keyCode == fnKeyCode else { return nil }
        let others: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard flags.intersection(others).isEmpty else { return false }
        return flags.contains(.function)
    }
}
