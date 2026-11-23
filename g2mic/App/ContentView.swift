import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var copiedNotice = false

    var body: some View {
        NavigationStack {
            List {
                glassesSection
                dictateSection
                recordSection
                if !model.transcripts.isEmpty { historySection }
                keyboardSection
                settingsSection
                diagnosticsSection
            }
            .navigationTitle("G2 Mic")
            .overlay(alignment: .bottom) {
                if copiedNotice {
                    Text("Copied")
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Sections

    private var glassesSection: some View {
        Section("Glasses") {
            HStack {
                Image(systemName: model.glasses.isMicOn ? "mic.fill" : "eyeglasses")
                    .foregroundStyle(model.glasses.isMicOn ? Color.green : Color.secondary)
                Text(model.glasses.status.label)
                Spacer()
            }
            if !model.glasses.armNames.isEmpty {
                Text(model.glasses.armNames.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Connect") { model.glasses.connect() }
                Spacer()
                Button("Forget glasses", role: .destructive) { model.glasses.forgetGlasses() }
            }
            .buttonStyle(.borderless)
        }
    }

    private var isDictating: Bool {
        if case .dictating = model.mode { return true }
        return false
    }

    private var dictateSection: some View {
        Section {
            Button(action: model.toggleDictation) {
                Label(isDictating ? "Stop & copy text" : "Dictate with glasses mic",
                      systemImage: isDictating ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(isDictating ? Color.red : Color.accentColor)
            .disabled(model.mode == .recording)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if model.mode != .idle { LevelMeter(dbfs: model.level) }

            if isDictating || !model.transcriber.partial.isEmpty {
                Text(model.transcriber.partial.isEmpty ? "Listening…" : model.transcriber.partial)
                    .foregroundStyle(model.transcriber.partial.isEmpty ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
            }
            if let error = model.lastError {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        } header: {
            Text("Dictate")
        } footer: {
            Text("Speech is recognized on your iPhone from the glasses' microphones. When you stop, the text is copied so you can paste it anywhere.")
        }
    }

    private var recordSection: some View {
        Section {
            Button(action: model.toggleRecording) {
                Label(model.mode == .recording
                      ? String(format: "Stop recording (%.0f s)", model.recorder.seconds)
                      : "Record audio",
                      systemImage: model.mode == .recording ? "stop.fill" : "record.circle")
            }
            .disabled(isDictating)
            ForEach(model.recorder.recordings, id: \.self) { url in
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent).lineLimit(1)
                    Spacer()
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                }
            }
            .onDelete { offsets in offsets.map { model.recorder.recordings[$0] }.forEach(model.recorder.delete) }
        } header: {
            Text("Voice memos")
        } footer: {
            Text("Saved as WAV files, also visible in the Files app under On My iPhone › G2 Mic.")
        }
    }

    private var historySection: some View {
        Section("Recent text (tap to copy)") {
            ForEach(Array(model.transcripts.enumerated()), id: \.offset) { _, text in
                Button {
                    UIPasteboard.general.string = text
                    withAnimation { copiedNotice = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { copiedNotice = false } }
                } label: {
                    Text(text).lineLimit(3).foregroundStyle(.primary)
                }
            }
            .onDelete(perform: model.deleteTranscript)
        }
    }

    private var keyboardSection: some View {
        Section("Dictate in any app") {
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Settings › General › Keyboard › Keyboards › Add New Keyboard › **G2 Mic**")
                Text("2. Tap **G2 Mic** in that list and turn on **Allow Full Access** (needed so the keyboard can talk to this app).")
                Text("3. In any text box, hold 🌐 and pick G2 Mic, then tap the mic button.")
            }
            .font(.callout)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            VStack(alignment: .leading) {
                Text(String(format: "Mic boost: %.1f×", model.gain))
                Slider(value: $model.gain, in: 0.5...6, step: 0.5)
            }
            Picker("Stay ready in background", selection: $model.keepAliveMinutes) {
                Text("Off").tag(0)
                Text("10 min").tag(10)
                Text("30 min").tag(30)
                Text("2 hours").tag(120)
                Text("8 hours").tag(480)
            }
            TextField("Language (blank = phone's), e.g. en-US", text: $model.language)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup("Connection log") {
                ForEach(Array(model.glasses.log.suffix(40).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
    }
}

private struct LevelMeter: View {
    let dbfs: Float

    var body: some View {
        GeometryReader { geo in
            let fraction = CGFloat(max(0, min(1, (dbfs + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(fraction > 0.9 ? Color.orange : Color.green)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.05), value: dbfs)
        .accessibilityLabel("Input level")
    }
}
