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

    /// Called when a notification arrives while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo

        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
        } else if userInfo["isPractice"] as? Bool != true {
            // Real question delivered in foreground — re-register the category with this question's
            // choices so the action buttons show the correct answer text, then activate QuestionState.
            if let choices = userInfo["choices"] as? [String], !choices.isEmpty {
                UNUserNotificationCenter.current().setNotificationCategories([makeQuestionCategory(choices: choices)])
            }
            engine.activateQuestion(from: userInfo)
            notificationManager.refillSchedule()
        }

        completionHandler([.banner, .sound])
    }

    // MARK: - Action Response

    /// Called when the user taps an action button or dismisses any notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo

        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
            return
        }

        if userInfo["isPractice"] as? Bool == true {
            handlePracticeResponse(response: response, userInfo: userInfo)
            return
        }

        // Real question tapped — ensure QuestionState is active (covers background delivery)
        // and top up the schedule so the buffer stays full.
        engine.activateQuestion(from: userInfo)
        notificationManager.refillSchedule()

        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw),
            let deliveredAtInterval = userInfo["deliveredAt"] as? TimeInterval
        else { return }

        let deliveredAt = Date(timeIntervalSince1970: deliveredAtInterval)
        let actionID = response.actionIdentifier

        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else { return }

        let answer = resolveAnswer(actionID: actionID, userInfo: userInfo)
        let correctAnswer = userInfo["correctAnswer"] as? String ?? ""

        if let outcome = engine.evaluate(answer: answer, slot: slot) {
            applyOutcome(outcome, slot: slot, deliveredAt: deliveredAt, correctAnswer: correctAnswer)
        } else {
            reshowResult(slot: slot)
        }
    }

    // MARK: - Practice Response

    /// Handles a practice question answer without touching QuestionState or the streak.
    private func handlePracticeResponse(response: UNNotificationResponse, userInfo: [AnyHashable: Any]) {
        let actionID = response.actionIdentifier

        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else { return }

        guard let correctAnswer = userInfo["correctAnswer"] as? String else { return }

        if let expirationID = userInfo["expirationID"] as? String {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [expirationID])
        }

        let answer = resolveAnswer(actionID: actionID, userInfo: userInfo)
        let outcome: Outcome = answer == correctAnswer ? .correct : .incorrect

        notificationManager.sendResultNotification(
            outcome: outcome,
            streak: streakManager.currentStreak(),
            correctAnswer: correctAnswer,
            isPractice: true
        )
    }

    // MARK: - Outcome Application

    /// Persists the outcome, updates the streak, cancels the expiration, and sends a result notification.
    private func applyOutcome(_ outcome: Outcome, slot: Slot, deliveredAt: Date, correctAnswer: String) {
        store.markAnswered(slot: slot, outcome: outcome)
        streakManager.handleOutcome(outcome)
        notificationManager.cancelExpirationNotification(slot: slot, deliveredAt: deliveredAt)

        notificationManager.sendResultNotification(
            outcome: outcome,
            streak: streakManager.currentStreak(),
            correctAnswer: correctAnswer
        )

        NotificationCenter.default.post(name: .streakDidChange, object: nil)
    }

    // MARK: - Re-show Result

    /// Re-sends the result notification for a slot that has already been resolved.
    private func reshowResult(slot: Slot) {
        guard let state = engine.currentState(slot: slot) else { return }
        let streak = streakManager.currentStreak()

        switch state.status {
        case .answered(let outcome):
            notificationManager.sendResultNotification(outcome: outcome, streak: streak, correctAnswer: state.correctAnswer)
        case .expired:
            notificationManager.sendResultNotification(outcome: .expired, streak: streak, correctAnswer: state.correctAnswer)
        case .active:
            break
        }
    }

    // MARK: - Expiration Delivery

    /// Applies expiration state when the expiration notification fires or is tapped.
    /// Idempotent — safe to call multiple times. Practice expirations are no-ops.
    private func handleExpirationDelivery(userInfo: [AnyHashable: Any]) {
        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw)
        else { return }

        guard userInfo["isPractice"] as? Bool != true else { return }

        guard let state = store.loadActiveQuestion(slot: slot),
              case .active = state.status else { return }

        store.markExpired(slot: slot)
        streakManager.handleOutcome(.expired)
    }

    // MARK: - Helpers

    /// Maps a positional action identifier (answer_N) to the actual answer string via the choices array.
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
