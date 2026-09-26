import BackgroundTasks
import UIKit

@MainActor
enum BackgroundCoordinator {
    static let refresh = "\(AppIdentity.bundleID).refresh"
    static let processing = "\(AppIdentity.bundleID).processing"
    static func register() {
        for identifier in [refresh, processing] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                Task { @MainActor in
                    let work = Task { @MainActor in
                        let model = AppModel.shared
                        let success = await model.sync(background: true)
                        task.setTaskCompleted(success: success)
                        schedule(enabled: model.automatic && model.connected && model.healthRequested)
                    }
                    task.expirationHandler = {
                        work.cancel()
                        Task { @MainActor in AppModel.shared.cancelWork() }
                    }
                }
            }
        }
    }
    static func schedule(enabled: Bool) {
        for identifier in [refresh, processing] { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        guard enabled else { return }
        let refreshRequest = BGAppRefreshTaskRequest(identifier: refresh)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        let processingRequest = BGProcessingTaskRequest(identifier: processing)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Scheduling can be unavailable in Simulator or disabled by the system. Foreground sync remains available.
        try? BGTaskScheduler.shared.submit(refreshRequest)
        try? BGTaskScheduler.shared.submit(processingRequest)
    }
}

final class RelayAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !ProcessInfo.processInfo.arguments.contains("--demo") {
            BackgroundCoordinator.register()
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { AppModel.shared.start() }
        }
        return true
    }
    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        Task { @MainActor in await AppModel.shared.foreground() }
    }
}
