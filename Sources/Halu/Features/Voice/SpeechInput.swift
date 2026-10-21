import AVFoundation
import Speech

/// Dictation into a text field. Shared by every voice-enabled field; one recording at a time.
@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var problem: String?
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
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.problem = "Allow Speech Recognition for Halu in System Settings."
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    DispatchQueue.main.async {
                        if granted {
                            self.begin()
                        } else {
                            self.problem = "Allow the microphone for Halu in System Settings."
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
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            problem = "Dictation isn't available for this language right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        self.request = request

        let input = engine.inputNode
        Self.installTap(on: input, feeding: request)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardownAudio()
            problem = "Couldn't start the microphone."
            return
        }
        isRecording = true
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal in
            guard let self else { return }
            if let text { self.onText?(text) }
            if isFinal {
                self.teardownAudio()
                self.isRecording = false
                self.task = nil
                self.request = nil
            }
        }
    }

    private func teardownAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // Audio and recognition callbacks arrive on background threads, so they are set up
    // outside the main actor and hop back explicitly.

    private nonisolated static func installTap(on input: AVAudioInputNode, feeding request: SFSpeechAudioBufferRecognitionRequest) {
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    private nonisolated static func recognize(with recognizer: SFSpeechRecognizer,
                                              request: SFSpeechAudioBufferRecognitionRequest,
                                              update: @escaping @MainActor (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true || error != nil
            DispatchQueue.main.async { update(text, isFinal) }
        }
    }
}
