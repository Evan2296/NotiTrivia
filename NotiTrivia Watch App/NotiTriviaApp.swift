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
    /// Handles two push types: (1) an expiration alert push from `send-expirations` that marks
    /// the question expired and updates streak/lives; (2) a silent prep push from `send-questions`
    /// that pre-registers answer-choice action buttons before the visible question notification
    /// appears.
    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        // CASE 1 — Expiration push. On watchOS this handler only fires for background
        // pushes, not visible alert pushes, so this branch is a defensive fallback.
        // The primary expiration path is `reconcileExpiredQuestions` (foreground sweep)
        // and the willPresent/didReceive handlers. `markExpired` gates the debit so a
        // racing answer-tap can never cause a double debit.
        if userInfo["isExpiration"] as? Bool == true {
            guard
                let slotRaw = userInfo["slot"] as? String,
                let slot = Slot(rawValue: slotRaw)
            else {
                completionHandler(.noData)
                return
            }

            // If the silent prep push was dropped by APNs (Low Power Mode, background
            // budget exhaustion, etc.), no QuestionState was ever written for this slot.
            // Reconstruct it now from the expiration payload — which carries questionID
            // and deliveredAt for exactly this fallback — so markExpired has an .active
            // state to transition and the life debit path can proceed normally.
            if StateStore.shared.loadActiveQuestion(slot: slot) == nil {
                QuestionEngine.shared.activateQuestion(from: userInfo)
            }

            guard StateStore.shared.markExpired(slot: slot) else {
                // State was already resolved by a concurrent answer-tap or prior expiration.
                completionHandler(.noData)
                return
            }

            StreakManager.shared.handleOutcome(.expired)
            NotificationCenter.default.post(name: .streakDidChange, object: nil)
            completionHandler(.newData)
            return
        }

        // CASE 2 — Silent prep push from Supabase send-questions Edge Function.
        // Arrives just before the visible question notification. Contains the answer choices
        // so we can pre-register the stable "question_category" with real action button titles
        // before the visible push appears, avoiding any timing race with watchOS rendering.
        guard let choices = userInfo["choices"] as? [String], !choices.isEmpty else {
            completionHandler(.noData)
            return
        }

        // Eagerly write QuestionState from the silent prep push so the answer flow,
        // expiration sweep, and any AppDelegate expiration branch all have state to
        // evaluate — even if the user never taps anything. `activateQuestion` is idempotent.
        QuestionEngine.shared.activateQuestion(from: userInfo)

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

        // Pre-register the stable category with placeholder titles so action buttons
        // always exist — even if the silent prep push hasn't arrived yet (first launch).
        let placeholders = ["Option A", "Option B", "Option C", "Option D"]
        let placeholderCategory = makeQuestionCategory(identifier: pushQuestionCategoryID, choices: placeholders)
        UNUserNotificationCenter.current().getNotificationCategories { existing in
            // Don't overwrite a real registration with placeholders on subsequent launches.
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