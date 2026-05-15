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
    /// Two distinct push types are handled here, checked in order:
    ///
    /// 1. **Expiration push** — sent by the Supabase `send-expirations` Edge Function after the
    ///    1-hour answer window closes. Arrives as a visible alert push (apns-priority 10) so it
    ///    delivers reliably even when the watch is inactive or charging. The push itself is the
    ///    expiration notification — no local result notification is fired here. This handler only
    ///    marks the question expired and updates streak/lives on-device.
    ///
    /// 2. **Silent prep push** — sent by `send-questions` just before the visible question
    ///    notification. Payload contains a `choices` array. We use this window to pre-register the
    ///    stable "question_category" with real answer-choice titles so watchOS can render the action
    ///    buttons when the visible notification appears.
    func didReceiveRemoteNotification(
        _ userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void
    ) {
        // CASE 1 — Expiration push from Supabase send-expirations Edge Function.
        //
        // ⚠️ Per Apple's docs, this handler does NOT fire for visible alert pushes on
        // watchOS — only for pure background pushes (content-available:1, priority 5).
        // Our expiration push is a visible alert (so the watch displays "Time Expired"
        // even if the app is suspended), so this branch is effectively unreachable in
        // production today. It's kept in place for two reasons:
        //   1. Defense in depth — if Apple ever changes this behavior, the code is correct.
        //   2. The actual lives debit for missed expirations now flows through
        //      `NotificationActionHandler.reconcileExpiredQuestions`, invoked when the
        //      watch app comes to foreground, plus the existing willPresent/didReceive
        //      paths in the action handler. See that file for the full rationale.
        //
        // The branch is also gated on `markExpired` returning `true` so a racing
        // answer-tap can never cause `handleOutcome(.expired)` to double-debit.
        if userInfo["isExpiration"] as? Bool == true {
            guard
                let slotRaw = userInfo["slot"] as? String,
                let slot = Slot(rawValue: slotRaw)
            else {
                completionHandler(.noData)
                return
            }

            guard StateStore.shared.markExpired(slot: slot) else {
                // Already resolved (answered or expired) — this push is a no-op.
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

        // CRITICAL: Eagerly write the QuestionState from the silent prep push.
        //
        // Previously, QuestionState was only created when the user tapped the visible
        // notification or when willPresent fired (foreground only). If the user ignored
        // the question entirely, no state was ever written — and then when the expiration
        // push fired 1 hour later, every handler bailed out at the `loadActiveQuestion`
        // guard because no state existed. The user lost no life. That broke the entire
        // lives system: users could avoid all penalties simply by ignoring notifications.
        //
        // Now the state is written the moment the silent prep push arrives, guaranteeing:
        //   • the visible push's tap-to-answer flow has state to evaluate against,
        //   • the foreground-sweep `reconcileExpiredQuestions` has state to debit a life
        //     against the next time the user opens the watch app,
        //   • the AppDelegate expiration branch (if it ever fires) finds state to expire.
        //
        // `activateQuestion` is idempotent and self-validating, so missing fields in the
        // payload are silently ignored without polluting state.
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