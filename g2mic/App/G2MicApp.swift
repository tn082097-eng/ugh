import SwiftUI

@main
struct G2MicApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { model.handle(url: $0) }
        }
    }
}
