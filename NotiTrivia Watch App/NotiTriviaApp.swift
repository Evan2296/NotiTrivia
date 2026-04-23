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

        // Register fixed answer categories first — must exist before any notification fires.
        // Then request permission and fill the schedule.
        NotificationManager.shared.registerCategories()
        NotificationManager.shared.requestPermission()
        NotificationManager.shared.refillSchedule()
    }
}
