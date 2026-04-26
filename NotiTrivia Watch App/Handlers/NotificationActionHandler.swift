import UserNotifications
import Foundation

final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationActionHandler()

    private let engine = QuestionEngine.shared
    private let streakManager = StreakManager.shared
    private let notificationManager = NotificationManager.shared
    private let store = StateStore.shared

    private override init() {}

    // MARK: - Foreground Delivery

    /// Called when a notification is delivered while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        if userInfo["isExpiration"] as? Bool == true {
            // Expiration notification delivered in foreground — apply state
            handleExpirationDelivery(userInfo: userInfo)
        } else if userInfo["isPractice"] as? Bool != true {
            // Real question notification delivered in foreground — activate QuestionState.
            // Practice questions are intentionally excluded: they must not write to a real
            // slot's QuestionState, which would clobber an active real question.
            engine.activateQuestion(from: userInfo)

            // Self-refill: top up the schedule whenever a real question fires so the
            // buffer stays full without requiring the user to open the app.
            notificationManager.refillSchedule()
        }

        completionHandler([.banner, .sound])
    }

    // MARK: - Action Response

    /// Called when the user taps an action button (or the notification body) on any notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo

        // Expiration notification tapped — apply state if not already done
        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
            return
        }

        let isPractice = userInfo["isPractice"] as? Bool == true

        if isPractice {
            // Practice question: handle entirely inline — no QuestionState, no slot lifecycle.
            handlePracticeResponse(response: response, userInfo: userInfo)
            return
        }

        // Real question notification tapped — ensure QuestionState is active
        // (covers the case where the app was not open when the notification was delivered)
        engine.activateQuestion(from: userInfo)

        // Self-refill: top up the schedule on every real question interaction so the
        // buffer stays full even when the app is never opened directly.
        notificationManager.refillSchedule()

        // Extract slot and deliveredAt
        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw),
            let deliveredAtInterval = userInfo["deliveredAt"] as? TimeInterval
        else { return }

        let deliveredAt = Date(timeIntervalSince1970: deliveredAtInterval)
        let actionID = response.actionIdentifier

        // Ignore dismiss / body tap with no answer selected
        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else { return }

        // Map positional action identifier (answer_N) → actual answer string via choices array
        let answer = resolveAnswer(actionID: actionID, userInfo: userInfo)

        // Evaluate the answer (uses QuestionState + validity window)
        // evaluate() returns .expired if the question timed out while the app was closed.
        // In all non-nil cases, applyOutcome handles state mutation + result notification.
        let correctAnswer = userInfo["correctAnswer"] as? String ?? ""
        if let outcome = engine.evaluate(answer: answer, slot: slot) {
            applyOutcome(outcome, slot: slot, deliveredAt: deliveredAt, correctAnswer: correctAnswer)
        } else {
            // Already answered or already expired — re-show the stored result
            reshowResult(slot: slot)
        }
    }

    // MARK: - Practice Response

    /// Handles a practice question answer entirely without touching QuestionState or the streak.
    /// Fix #2: avoids writing to a real slot. Fix #4: avoids evaluate()'s internal streak side-effects.
    private func handlePracticeResponse(response: UNNotificationResponse, userInfo: [AnyHashable: Any]) {
        let actionID = response.actionIdentifier

        // Ignore dismiss / body tap with no answer selected
        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else { return }

        guard let correctAnswer = userInfo["correctAnswer"] as? String else { return }

        // Cancel the paired practice expiration notification so it doesn't fire on the
        // next app launch after the user has already answered this practice question.
        if let expirationID = userInfo["expirationID"] as? String {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [expirationID])
        }

        let answer = resolveAnswer(actionID: actionID, userInfo: userInfo)
        let outcome: Outcome = answer == correctAnswer ? .correct : .incorrect

        // Apply outcome without touching the streak
        notificationManager.sendResultNotification(
            outcome: outcome,
            streak: streakManager.currentStreak(),
            correctAnswer: correctAnswer,
            isPractice: true
        )
    }

    // MARK: - Outcome Application

    /// Applies a resolved outcome: persists state, updates streak, cancels expiration,
    /// and sends the result notification. correctAnswer is passed directly from userInfo
    /// to avoid an async read-after-write race with the store.
    private func applyOutcome(_ outcome: Outcome, slot: Slot, deliveredAt: Date, correctAnswer: String) {
        store.markAnswered(slot: slot, outcome: outcome)
        streakManager.handleOutcome(outcome)

        // Cancel the paired expiration notification — no longer needed
        notificationManager.cancelExpirationNotification(slot: slot, deliveredAt: deliveredAt)

        let streak = streakManager.currentStreak()

        notificationManager.sendResultNotification(
            outcome: outcome,
            streak: streak,
            correctAnswer: correctAnswer
        )

        // Notify the UI that streak may have changed
        NotificationCenter.default.post(name: .streakDidChange, object: nil)
    }

    // MARK: - Re-show Result

    /// Re-sends a result notification for a slot that has already been resolved.
    private func reshowResult(slot: Slot) {
        guard let state = engine.currentState(slot: slot) else { return }

        let streak = streakManager.currentStreak()

        switch state.status {
        case .answered(let outcome):
            notificationManager.sendResultNotification(
                outcome: outcome,
                streak: streak,
                correctAnswer: state.correctAnswer
            )
        case .expired:
            notificationManager.sendResultNotification(
                outcome: .expired,
                streak: streak,
                correctAnswer: state.correctAnswer
            )
        case .active:
            // Should not normally reach here — evaluate() now returns .expired directly
            // for timed-out questions rather than mutating state and returning nil.
            break
        }
    }

    // MARK: - Expiration Delivery

    /// Applies expiration state when the expiration notification fires.
    /// Idempotent — safe to call multiple times.
    /// Fix #1: skips streak update for practice expiration notifications.
    private func handleExpirationDelivery(userInfo: [AnyHashable: Any]) {
        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw)
        else { return }

        let isPractice = userInfo["isPractice"] as? Bool == true

        // Only mutate real slot state for non-practice expirations
        if !isPractice {
            guard let state = store.loadActiveQuestion(slot: slot),
                  case .active = state.status else { return }

            store.markExpired(slot: slot)
            streakManager.handleOutcome(.expired)
        }
        // Practice expiration fires silently — no state mutation, no streak impact
    }

    // MARK: - Helpers

    /// Maps a positional action identifier (answer_N) to the actual answer string via the choices array.
    /// Falls back to using the identifier directly for legacy/test cases.
    private func resolveAnswer(actionID: String, userInfo: [AnyHashable: Any]) -> String {
        if actionID.hasPrefix("answer_"),
           let indexStr = actionID.split(separator: "_").last,
           let index = Int(indexStr),
           let choices = userInfo["choices"] as? [String],
           index < choices.count {
            return choices[index]
        }
        return actionID
    }
}
