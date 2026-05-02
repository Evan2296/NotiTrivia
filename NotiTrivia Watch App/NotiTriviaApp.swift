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
        // Delegate must be set before any notifications can fire.
        UNUserNotificationCenter.current().delegate = NotificationActionHandler.shared

        NotificationManager.shared.requestPermission()
        NotificationManager.shared.refillSchedule()
    }
}
