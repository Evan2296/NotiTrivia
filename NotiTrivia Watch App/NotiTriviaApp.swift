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

        // Each scheduled question registers its own per-question category at scheduling
        // time (with the real answer titles baked in), so there is no shared category to
        // pre-register here. `refillSchedule` runs that registration as part of its work,
        // and watchOS persists registered categories across process launches.
        NotificationManager.shared.requestPermission()
        NotificationManager.shared.refillSchedule()
    }
}
