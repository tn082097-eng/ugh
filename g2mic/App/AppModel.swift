import Combine
import Foundation
import G2Core
import UIKit

/// Wires the glasses mic to speech recognition, recording, and the keyboard.
final class AppModel: ObservableObject {
    enum Mode: Equatable { case idle, dictating(fromKeyboard: Bool), recording }

    let glasses = GlassesLink()
    let transcriber = Transcriber()
    let recorder = Recorder()

    @Published private(set) var mode: Mode = .idle
    @Published private(set) var level: Float = -120
    @Published private(set) var transcripts: [String] = []
    @Published var lastError: String?

    @Published var gain: Double = UserDefaults.standard.object(forKey: "gain") as? Double ?? 1.5 {
        didSet { UserDefaults.standard.set(gain, forKey: "gain") }
    }
    /// Empty = phone's language.
    @Published var language: String = UserDefaults.standard.string(forKey: "language") ?? "" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    /// How long the app stays awake in the background for the keyboard. 0 = never.
    @Published var keepAliveMinutes: Int = UserDefaults.standard.object(forKey: "keepAliveMinutes") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(keepAliveMinutes, forKey: "keepAliveMinutes") }
    }

    private let decoder = G2AudioDecoder()
    private let keepAlive = BackgroundKeepAlive()
    private var observers: [DarwinObserver] = []
    private var aliveTimer: Timer?
    private var keepAliveUntil = Date.distantPast
    private var bag: Set<AnyCancellable> = []

    init() {
        glasses.onAudioPacket = { [weak self] packet in self?.handlePacket(packet) }
        // Re-publish child changes so SwiftUI views observing AppModel refresh.
        glasses.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        transcriber.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        recorder.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        transcriber.$partial.sink { [weak self] text in self?.publishPartial(text) }.store(in: &bag)
        glasses.$status.sink { [weak self] status in self?.glassesStatusChanged(status) }.store(in: &bag)

        observers = [
            DarwinObserver(SharedDictation.startNote) { [weak self] in self?.startDictation(fromKeyboard: true) },
            DarwinObserver(SharedDictation.stopNote) { [weak self] in self?.stopDictation() },
            DarwinObserver(SharedDictation.cancelNote) { [weak self] in self?.cancelDictation() },
        ]
        transcripts = UserDefaults.standard.stringArray(forKey: "transcripts") ?? []
        setShared(.idle)
        startAliveBeacon()

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.enteredBackground()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keepAlive.stop()
        }
    }

    // MARK: URL entry point (the keyboard opens g2mic://dictate when the app isn't running)

    func handle(url: URL) {
        guard url.scheme == SharedDictation.urlScheme else { return }
        if url.host == "dictate" { startDictation(fromKeyboard: true) }
    }

    // MARK: Dictation

    func toggleDictation() {
        if case .dictating = mode { stopDictation() } else { startDictation(fromKeyboard: false) }
    }

    func startDictation(fromKeyboard: Bool) {
        if case .dictating = mode { return }
        if mode == .recording { stopRecording() }
        Transcriber.requestPermission { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.fail("Allow Speech Recognition for G2 Mic in Settings.")
                return
            }
            if let problem = self.transcriber.start(localeIdentifier: self.language.isEmpty ? nil : self.language) {
                self.fail(problem)
                return
            }
            self.lastError = nil
            self.decoder?.reset()
            self.mode = .dictating(fromKeyboard: fromKeyboard)
            self.setShared(self.glasses.isMicOn ? .listening : .connecting)
            self.glasses.startMic()
        }
    }

    func stopDictation() {
        guard case .dictating(let fromKeyboard) = mode else { return }
        setShared(.finishing)
        glasses.stopMic()
        transcriber.finish { [weak self] text in
            guard let self else { return }
            self.mode = .idle
            if !text.isEmpty {
                self.transcripts.insert(text, at: 0)
                self.transcripts = Array(self.transcripts.prefix(50))
                UserDefaults.standard.set(self.transcripts, forKey: "transcripts")
            }
            if fromKeyboard {
                let d = SharedDictation.defaults
                d?.set(text, forKey: SharedDictation.Key.finalText)
                d?.set(UUID().uuidString, forKey: SharedDictation.Key.finalID)
            } else if !text.isEmpty {
                UIPasteboard.general.string = text
            }
            self.setShared(.done)
            self.extendKeepAlive()
        }
    }

    func cancelDictation() {
        guard case .dictating = mode else { return }
        transcriber.cancel()
        glasses.stopMic()
        mode = .idle
        setShared(.idle)
    }

    // MARK: Recording

    func toggleRecording() {
        if mode == .recording { stopRecording() } else { startRecording() }
    }

    func startRecording() {
        guard mode == .idle else { return }
        decoder?.reset()
        recorder.start()
        mode = .recording
        glasses.startMic()
    }

    func stopRecording() {
        guard mode == .recording else { return }
        glasses.stopMic()
        recorder.stop()
        mode = .idle
    }

    func deleteTranscript(at offsets: IndexSet) {
        transcripts.remove(atOffsets: offsets)
        UserDefaults.standard.set(transcripts, forKey: "transcripts")
    }

    // MARK: Audio path

    private func handlePacket(_ packet: [UInt8]) {
        guard mode != .idle, let decoder else { return }
        decoder.feed(packet) { chunk, _ in
            let pcm = PCMGain.apply(Float(gain), to: chunk)
            level = PCMGain.rmsDBFS(pcm)
            switch mode {
            case .dictating: transcriber.append(pcm)
            case .recording: recorder.append(pcm)
            case .idle: break
            }
        }
    }

    private func glassesStatusChanged(_ status: GlassesLink.Status) {
        guard case .dictating = mode else { return }
        switch status {
        case .micOn: setShared(.listening)
        case .failed(let why):
            fail(why)
            cancelDictation()
        default: break
        }
    }

    // MARK: Keyboard bridge

    private func setShared(_ state: DictationState) {
        let d = SharedDictation.defaults
        d?.set(state.rawValue, forKey: SharedDictation.Key.state)
        if state == .connecting || state == .idle { d?.set("", forKey: SharedDictation.Key.partial) }
        SharedDictation.post(SharedDictation.updateNote)
    }

    private func publishPartial(_ text: String) {
        guard case .dictating(true) = mode else { return }
        SharedDictation.defaults?.set(text, forKey: SharedDictation.Key.partial)
        SharedDictation.post(SharedDictation.updateNote)
    }

    private func fail(_ message: String) {
        lastError = message
        SharedDictation.defaults?.set(message, forKey: SharedDictation.Key.message)
        setShared(.failed)
    }

    private func startAliveBeacon() {
        aliveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            SharedDictation.defaults?.set(Date().timeIntervalSince1970, forKey: SharedDictation.Key.appAliveAt)
            if UIApplication.shared.applicationState == .background, self.mode == .idle, Date() > self.keepAliveUntil {
                // Idle long enough: let iOS suspend us to save battery.
                self.keepAlive.stop()
            }
        }
        aliveTimer?.fire()
    }

    private func extendKeepAlive() {
        keepAliveUntil = Date().addingTimeInterval(TimeInterval(keepAliveMinutes * 60))
    }

    private func enteredBackground() {
        guard keepAliveMinutes > 0 else { return }
        extendKeepAlive()
        keepAlive.start()
    }
}
