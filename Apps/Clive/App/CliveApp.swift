import SwiftUI
import UIKit

extension Notification.Name { static let cloudRendezvousChanged = Notification.Name("CloudRendezvousChanged") }

final class CliveAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications(); return true
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: .cloudRendezvousChanged, object: nil)
        completionHandler(.newData)
    }
}

@main
struct CliveApp: App {
    @UIApplicationDelegateAdaptor(CliveAppDelegate.self) private var appDelegate
    @State private var coordinator = WorkspaceCoordinator()

    var body: some Scene {
        WindowGroup {
            WorkspaceView(coordinator: coordinator)
        }
    }
}
