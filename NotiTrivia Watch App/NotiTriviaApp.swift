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

        // Register the shared question category so action buttons appear on delivery.
        // watchOS does not persist category registrations across process launches,
        // so this must run on every app start.
        NotificationManager.shared.registerSharedCategory()

        NotificationManager.shared.requestPermission()
        NotificationManager.shared.refillSchedule()
    }
}
