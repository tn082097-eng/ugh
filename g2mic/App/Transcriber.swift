import AVFoundation
import Foundation
import Speech

/// Apple speech recognition fed with audio from the glasses (never the phone mic).
final class Transcriber: ObservableObject {
    @Published private(set) var partial = ""
    @Published private(set) var isRunning = false

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishHandler: ((String) -> Void)?
    private var finishTimeout: DispatchWorkItem?
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    /// Starts a recognition session. Returns an error message if it can't.
    func start(localeIdentifier: String?) -> String? {
        cancel()
        let locale = localeIdentifier.map(Locale.init(identifier:)) ?? Locale.current
        guard let rec = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            return "Speech recognition isn't available for this language."
        }
        guard rec.isAvailable else { return "Speech recognition is unavailable right now." }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        // On-device: private, works offline, and has no 1-minute limit.
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }

        recognizer = rec
        request = req
        partial = ""
        isRunning = true
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.partial = result.bestTranscription.formattedString
                    if result.isFinal { self.complete() }
                } else if error != nil {
                    self.complete()
                }
            }
        }
        return nil
    }

    /// Feed 16 kHz mono samples.
    func append(_ samples: [Int16]) {
        guard let request, isRunning,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { channel[i] = Float(s) / 32768 }
        request.append(buffer)
    }

    /// Stop listening and get the final text (falls back to the last partial result).
    func finish(_ handler: @escaping (String) -> Void) {
        guard isRunning else { return handler(partial) }
        finishHandler = handler
        request?.endAudio()
        let timeout = DispatchWorkItem { [weak self] in self?.complete() }
        finishTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
    }

    func cancel() {
        finishHandler = nil
        finishTimeout?.cancel()
        task?.cancel()
        task = nil
        request = nil
        isRunning = false
    }

    private func complete() {
        guard isRunning else { return }
        finishTimeout?.cancel()
        isRunning = false
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        let handler = finishHandler
        finishHandler = nil
        task?.finish()
        task = nil
        request = nil
        handler?(text)
    }
}
