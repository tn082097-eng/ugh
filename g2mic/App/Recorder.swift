import Foundation
import G2Core

/// Records glasses audio to WAV files in Documents/Recordings (visible in the Files app).
final class Recorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var seconds: Double = 0

    private var samples: [Int16] = []
    private var startedAt = Date()

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() { refresh() }

    func start() {
        samples.removeAll(keepingCapacity: true)
        seconds = 0
        startedAt = Date()
        isRecording = true
    }

    func append(_ chunk: [Int16]) {
        guard isRecording else { return }
        samples += chunk
        seconds = Double(samples.count) / Double(G2AudioFormat.sampleRate)
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        guard !samples.isEmpty else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let url = Self.folder.appendingPathComponent("G2 \(f.string(from: startedAt)).wav")
        do {
            try WAV.file(samples: samples).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        samples.removeAll()
        refresh()
        return url
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refresh()
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: [.creationDateKey])) ?? []
        recordings = urls.filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
