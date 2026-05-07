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
    ///
    /// For real question pushes the server sends a **silent prep push** first
    /// (content-available:1, no alert) containing the question choices.  We use that window
    /// to re-register the stable "question_category" with the real answer-choice titles
    /// **before** the visible notification arrives, so watchOS can render the action buttons.
    ///
    /// Requires `content-available: 1` in the APNs payload from the server.
    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        guard let choices = userInfo["choices"] as? [String], !choices.isEmpty else {
            completionHandler(.noData)
            return
        }

        // Always use the stable, pre-known category ID so it matches aps.category on the
        // visible push without any timing race.
        let category = makeQuestionCategory(identifier: pushQuestionCategoryID, choices: choices)

        UNUserNotificationCenter.current().getNotificationCategories { existing in
            var merged = existing.filter { $0.identifier != pushQuestionCategoryID }
            merged.insert(category)
            UNUserNotificationCenter.current().setNotificationCategories(merged)
            print("[AppDelegate] Registered '\(pushQuestionCategoryID)' with choices: \(choices)")
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

        // Pre-register the stable push-question category with placeholder action titles.
        // This guarantees "question_category" is always known to the system so that when
        // a visible push arrives with aps.category = "question_category", watchOS can
        // immediately render the action buttons — even if the silent prep push hasn't
        // updated the titles yet (e.g. very first launch).
        let placeholders = ["Option A", "Option B", "Option C", "Option D"]
        let placeholderCategory = makeQuestionCategory(identifier: pushQuestionCategoryID, choices: placeholders)
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            // Only seed the placeholder if the category hasn't been registered yet.
            // Once a real silent push has updated it with real titles we don't want
            // to overwrite it with placeholders on every subsequent launch.
            if !existing.contains(where: { $0.identifier == pushQuestionCategoryID }) {
                var merged = existing
                merged.insert(placeholderCategory)
                UNUserNotificationCenter.current().setNotificationCategories(merged)
                print("[NotiTriviaApp] Pre-registered placeholder '\(pushQuestionCategoryID)'")
            }
        }

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
