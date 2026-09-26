import SwiftUI

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(RelayAppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(RelayTheme.mint)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.foreground() } }
                    if phase == .background {
                        // A foreground history crawl yields to system-scheduled delivery.
                        model.cancelWork()
                        BackgroundCoordinator.schedule(enabled: !model.isDemo && model.connected && model.automatic && model.healthRequested)
                    }
                }
        }
    }
}
