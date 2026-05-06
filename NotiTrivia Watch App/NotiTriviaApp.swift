import SwiftUI
import UserNotifications
import WatchKit

// MARK: - App Delegate

final class AppDelegate: NSObject, WKApplicationDelegate {

    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        DeviceRegistrationManager.shared.registerDeviceToken(deviceToken)
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        print("[AppDelegate] Failed to register for remote notifications: \(error)")
    }

    /// Called when a remote push arrives while the app is in the background.
    /// Registering the question category here — before the user opens the notification tray —
    /// ensures watchOS can show answer-choice action buttons on the notification.
    /// Requires `content-available: 1` in the APNs payload from the server.
    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        // This fires when a push arrives even if app is in background.
        // Register the category immediately so buttons appear when notification displays.
        guard let choices = userInfo["choices"] as? [String],
              let questionID = userInfo["questionID"] as? String else {
            completionHandler(.noData)
            return
        }

        let categoryID = "push-question-\(questionID)"
        let category = makeQuestionCategory(identifier: categoryID, choices: choices)

        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var merged = existing.filter { $0.identifier != categoryID }
            merged.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(merged)
            completionHandler(.newData)
        }
    }
}

// MARK: - App Entry Point

@main
struct NotiTrivia_Watch_AppApp: App {

    @WKApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        setupNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }

    // MARK: - Notification Setup

    private func setupNotifications() {
        // Delegate must be set before any notifications can fire.
        UNUserNotificationCenter.current().delegate = NotificationActionHandler.shared

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[NotiTriviaApp] Permission error: \(error)")
            }
            guard granted else {
                print("[NotiTriviaApp] Notification permission denied")
                return
            }
            // registerForRemoteNotifications must be called on the main thread.
            DispatchQueue.main.async {
                WKApplication.shared().registerForRemoteNotifications()
            }
        }
    }
}
