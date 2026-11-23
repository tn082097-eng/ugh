import Foundation
import G2Core

/// The app and the keyboard extension are separate processes. They share state through an
/// App Group `UserDefaults` suite and signal each other with Darwin notifications.
enum DictationState: String {
    case idle, connecting, listening, finishing, done, failed
}

enum SharedDictation {
    /// The App Group actually granted to this build. Sideloading tools (used when installing
    /// from Linux or Windows) often rename the group, e.g. by appending your Team ID, so prefer
    /// the group listed in the embedded provisioning profile over the one in Info.plist.
    static let appGroup: String = ProvisioningProfile.appGroup()
        ?? Bundle.main.object(forInfoDictionaryKey: "G2AppGroup") as? String
        ?? "group.com.example.g2mic"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    enum Key {
        static let state = "dictation.state"
        static let partial = "dictation.partial"
        static let finalText = "dictation.final"
        static let finalID = "dictation.finalID"
        static let message = "dictation.message"
        static let appAliveAt = "app.aliveAt"
    }

    private static var prefix: String { appGroup + "." }
    static var startNote: String { prefix + "start" }
    static var stopNote: String { prefix + "stop" }
    static var cancelNote: String { prefix + "cancel" }
    static var updateNote: String { prefix + "update" }

    static let urlScheme = "g2mic"

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true
        )
    }

    /// The app refreshes this every couple of seconds while it is running.
    static var appIsAlive: Bool {
        guard let t = defaults?.double(forKey: Key.appAliveAt), t > 0 else { return false }
        return Date().timeIntervalSince1970 - t < 6
    }
}

/// Observes one Darwin notification and calls `handler` on the main queue.
final class DarwinObserver {
    private let name: String
    private let handler: () -> Void

    init(_ name: String, handler: @escaping () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { me.handler() }
            },
            name as CFString, nil, .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString), nil
        )
    }
}
