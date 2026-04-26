import SwiftUI
import UserNotifications

@main
struct NotiTrivia_Watch_AppApp: App {

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
        // Set the delegate first — must happen before any notifications fire
        UNUserNotificationCenter.current().delegate = NotificationActionHandler.shared

        // Request permission and fill the schedule.
        // Per-question categories are registered lazily inside refillSchedule()
        // as each question is scheduled, so no separate category registration is needed.
        NotificationManager.shared.requestPermission()
        NotificationManager.shared.refillSchedule()
    }
}
