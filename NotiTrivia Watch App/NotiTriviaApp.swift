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
        // Arrives before the visible question notification (sent twice over ~45s). Contains the
        // answer choices and questionID so we can register the UNIQUE per-question category
        // ("question_category_<questionID>") with real action button titles before the visible
        // push appears. The unique ID guarantees the visible push can never match a stale
        // category from a previous question.
        guard
            let choices = userInfo["choices"] as? [String], !choices.isEmpty,
            let questionID = userInfo["questionID"] as? String
        else {
            completionHandler(.noData)
            return
        }

        // Eagerly write QuestionState from the silent prep push so the answer flow,
        // expiration sweep, and any AppDelegate expiration branch all have state to
        // evaluate — even if the user never taps anything. `activateQuestion` is idempotent.
        QuestionEngine.shared.activateQuestion(from: userInfo)

        // Register the per-question category and purge any stale push-question categories,
        // holding the background fetch handler open until the write is issued.
        NotificationManager.shared.registerPushQuestionCategory(questionID: questionID, choices: choices) {
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

        // No placeholder category is pre-registered: real questions use a UNIQUE per-question
        // category ID ("question_category_<questionID>") that can't be known until the silent
        // prep push arrives. Registering a generic placeholder would be useless (it could never
        // match a per-question `aps.category`) and risks showing meaningless "Option A/B/C/D"
        // buttons. The prep push registers the correct per-question category before the visible
        // notification renders.

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