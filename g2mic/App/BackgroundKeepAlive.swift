import AVFoundation

/// Keeps the app running in the background so the keyboard can start dictation without
/// bouncing back to the app every time. It plays silence, mixed with other audio, so it
/// never interrupts music or calls. Uses the "audio" background mode.
final class BackgroundKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            if engine.attachedNodes.contains(player) == false {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            silence.frameLength = 16_000 // zero-filled
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        running = false
    }
}
