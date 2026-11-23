import SwiftUI
import UIKit

/// A small keyboard whose main key is "dictate with the G2 microphone".
/// iOS doesn't let keyboards use any microphone, so the G2 Mic app does the listening and
/// hands the text back through the shared App Group.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        let host = UIHostingController(rootView: KeyboardView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        let height = host.view.heightAnchor.constraint(equalToConstant: 240)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.showsGlobe = needsInputModeSwitchKey
        model.refresh(insertNewText: false)
    }
}

final class KeyboardModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var partial = ""
    @Published var message = ""
    @Published var showsGlobe = true

    weak var controller: UIInputViewController?
    private var observer: DarwinObserver?
    private var lastInsertedID: String?

    init() {
        lastInsertedID = SharedDictation.defaults?.string(forKey: SharedDictation.Key.finalID)
        observer = DarwinObserver(SharedDictation.updateNote) { [weak self] in self?.refresh(insertNewText: true) }
    }

    var isBusy: Bool { state == .connecting || state == .listening || state == .finishing }

    func micTapped() {
        guard let controller else { return }
        if state == .listening || state == .connecting {
            SharedDictation.post(SharedDictation.stopNote)
            state = .finishing
            return
        }
        guard controller.hasFullAccess else {
            message = "Turn on Allow Full Access for G2 Mic in Settings › General › Keyboard › Keyboards."
            return
        }
        message = ""
        partial = ""
        state = .connecting
        if SharedDictation.appIsAlive {
            SharedDictation.post(SharedDictation.startNote)
        } else {
            message = "Opening G2 Mic… swipe back here when it's listening."
            openContainingApp(URL(string: "\(SharedDictation.urlScheme)://dictate")!)
        }
    }

    func cancelTapped() {
        SharedDictation.post(SharedDictation.cancelNote)
        state = .idle
        partial = ""
    }

    func refresh(insertNewText: Bool) {
        guard let d = SharedDictation.defaults else { return }
        state = DictationState(rawValue: d.string(forKey: SharedDictation.Key.state) ?? "") ?? .idle
        partial = d.string(forKey: SharedDictation.Key.partial) ?? ""
        if state == .failed { message = d.string(forKey: SharedDictation.Key.message) ?? "Something went wrong." }
        if state == .listening { message = "" }
        let id = d.string(forKey: SharedDictation.Key.finalID)
        if id != lastInsertedID {
            lastInsertedID = id
            if insertNewText, let text = d.string(forKey: SharedDictation.Key.finalText), !text.isEmpty {
                insert(text)
            }
        }
    }

    // MARK: Typing

    func insert(_ text: String) {
        guard let proxy = controller?.textDocumentProxy else { return }
        if let last = proxy.documentContextBeforeInput?.last, !last.isWhitespace {
            proxy.insertText(" ")
        }
        proxy.insertText(text)
    }

    func space() { controller?.textDocumentProxy.insertText(" ") }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
    func newline() { controller?.textDocumentProxy.insertText("\n") }
    func nextKeyboard() { controller?.advanceToNextInputMode() }

    /// Keyboards can't call UIApplication.open directly; reach the shared application through
    /// the responder chain instead. This is the long-standing technique keyboard apps use.
    private func openContainingApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = controller
        while let r = responder {
            if let app = r as? UIApplication, app.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let fn = unsafeBitCast(app.method(for: selector), to: OpenURL.self)
                fn(app, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = r.next
        }
        message = "Open the G2 Mic app once, then come back and tap the mic."
        state = .idle
    }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 10) {
            statusArea
            micButton
            bottomRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var statusArea: some View {
        Group {
            if !model.partial.isEmpty {
                ScrollView {
                    Text(model.partial)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !model.message.isEmpty {
                Text(model.message).foregroundStyle(Color.secondary)
            } else {
                Text(statusLabel).foregroundStyle(Color.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 60, alignment: .topLeading)
    }

    private var statusLabel: String {
        switch model.state {
        case .idle, .done: return "Tap the mic and speak into your G2."
        case .connecting: return "Connecting to glasses…"
        case .listening: return "Listening…"
        case .finishing: return "Finishing…"
        case .failed: return "Something went wrong."
        }
    }

    private var micButton: some View {
        HStack(spacing: 16) {
            Button(action: model.micTapped) {
                Image(systemName: model.isBusy ? "stop.fill" : "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 72, height: 72)
                    .background(Circle().fill(model.isBusy ? Color.red : Color.accentColor))
            }
            .accessibilityLabel(model.isBusy ? "Stop dictation" : "Dictate with G2")
            if model.isBusy {
                Button("Cancel", action: model.cancelTapped)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                key(systemImage: "globe", action: model.nextKeyboard)
            }
            Button(action: model.space) {
                Text("space").frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(KeyStyle())
            key(systemImage: "delete.left", action: model.deleteBackward)
            key(systemImage: "return", action: model.newline)
        }
    }

    private func key(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).frame(width: 48, height: 42)
        }
        .buttonStyle(KeyStyle())
    }
}

private struct KeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color(.systemGray3) : Color(.systemBackground))
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
            )
    }
}
