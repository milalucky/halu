import AVFoundation
@preconcurrency import Speech

/// Dictation into a text field. Shared by every voice-enabled field; one recording at a time.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var problem: String?
    /// Microphone loudness while recording, 0…1, so it's obvious whether sound arrives at all.
    @Published private(set) var level: Float = 0
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "speech.language") }
    }

    static let languages = ["ru-RU", "en-US"]

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    private var owner: UUID?

    init() {
        language = UserDefaults.standard.string(forKey: "speech.language") ?? "ru-RU"
    }

    var languageLabel: String { language.hasPrefix("ru") ? "RU" : "EN" }

    func toggleLanguage() {
        let index = Self.languages.firstIndex(of: language) ?? 0
        language = Self.languages[(index + 1) % Self.languages.count]
    }

    func isRecording(for id: UUID) -> Bool { isRecording && owner == id }

    /// Starts dictation for the field `id`; live text goes to `onText`. Calling it again stops.
    func toggle(for id: UUID, onText: @escaping (String) -> Void) {
        if isRecording {
            let wasOwner = owner == id
            stop()
            if wasOwner { return }
        }
        problem = nil
        owner = id
        self.onText = onText
        // Explicitly @Sendable: these handlers run on a background queue, and a closure that
        // inherited main-actor isolation would trip the runtime check there.
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard status == .authorized else {
                        self.problem = "Allow Speech Recognition for Halu in System Settings → Privacy & Security."
                        return
                    }
                    AVCaptureDevice.requestAccess(for: .audio) { @Sendable granted in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                if granted {
                                    self.begin()
                                } else {
                                    self.problem = "Allow the microphone for Halu in System Settings → Privacy & Security."
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        request?.endAudio()
        teardownAudio()
        isRecording = false
    }

    private func begin() {
        guard engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 else {
            problem = "No microphone input. Check the input device in System Settings → Sound."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            problem = "Dictation isn't available for this language right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On-device when the language model is on this Mac; otherwise Apple's servers.
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = engine.inputNode
        Self.installTap(on: input, feeding: request) { [weak self] level in
            self?.level = level
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownAudio()
            problem = "Couldn't start the microphone."
            return
        }
        isRecording = true
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal, failure in
            guard let self else { return }
            if let text { self.onText?(text) }
            if let failure, text == nil {
                NSLog("Halu: dictation failed: \(failure)")
                self.problem = "Dictation stopped: \(failure)"
            }
            if isFinal {
                self.teardownAudio()
                self.isRecording = false
                self.task = nil
                self.request = nil
            }
        }
    }

    private func teardownAudio() {
        level = 0
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // Audio and recognition callbacks arrive on background threads, so they are set up
    // outside the main actor and hop back explicitly.

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest,
                                               level: @escaping @MainActor (Float) -> Void) {
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            request.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = (sum / Float(buffer.frameLength)).squareRoot()
            // Roughly -50 dB … 0 dB mapped onto 0…1.
            let value = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
            DispatchQueue.main.async { MainActor.assumeIsolated { level(value) } }
        }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer,
                                              request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @MainActor (String?, Bool, String?) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { @Sendable result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true || error != nil
            let failure = error.map { ($0 as NSError).localizedDescription }
            DispatchQueue.main.async { MainActor.assumeIsolated { update(text, isFinal, failure) } }
        }
    }
}
