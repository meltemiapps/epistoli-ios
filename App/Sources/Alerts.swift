import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

/// The part of UNUserNotificationCenter the app uses, so tests can count the prompts.
protocol AlertAuthorizing: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

extension UNUserNotificationCenter: AlertAuthorizing {}

/// "New message" alerts. They never say who wrote or what: CloudKit sends the fixed text
/// `CloudKitTransport.alertBody`, and the app adds nothing to it.
///
/// Permission is asked once, the first time a chat is opened, never at launch or during
/// onboarding, and only when the transport can push (CloudKit; the loopback folder can't).
@MainActor
final class AlertPermission {
    static let askedKey = "alerts.asked"

    private let center: any AlertAuthorizing
    private let defaults: UserDefaults
    private let canPush: Bool
    private let register: @MainActor () -> Void

    init(center: any AlertAuthorizing = UNUserNotificationCenter.current(), defaults: UserDefaults = .standard,
         canPush: Bool, register: @escaping @MainActor () -> Void = { UIApplication.shared.registerForRemoteNotifications() }) {
        self.center = center
        self.defaults = defaults
        self.canPush = canPush
        self.register = register
    }

    var hasAsked: Bool { defaults.bool(forKey: Self.askedKey) }

    /// Call when a chat appears. Asks the first time only; returns whether it asked.
    @discardableResult
    func chatOpened() async -> Bool {
        guard canPush, !hasAsked else { return false }
        defaults.set(true, forKey: Self.askedKey)
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted { register() }
        return true
    }
}

/// Push and background-refresh entry points. Both only trigger a fetch.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let fetchRequested = Notification.Name("fetchRequested")

    static var refreshTaskID: String { (Bundle.main.bundleIdentifier ?? "app") + ".refresh" }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskID, using: nil) { task in
            Self.scheduleRefresh()
            NotificationCenter.default.post(name: Self.fetchRequested, object: nil)
            // The fetch runs on the main actor's receive task; give it a moment and finish.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { task.setTaskCompleted(success: true) }
        }
        return true
    }

    /// A CloudKit push: fetch. The alert itself (if any) is shown by the system.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        await MainActor.run { NotificationCenter.default.post(name: Self.fetchRequested, object: nil) }
        try? await Task.sleep(for: .seconds(10))
        return .newData
    }

    /// In the app the chats update by themselves: no banner on top.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        await MainActor.run { NotificationCenter.default.post(name: Self.fetchRequested, object: nil) }
        return []
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
