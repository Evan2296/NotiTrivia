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

        // Expiration alerts reach this handler when the app is in the foreground.
        // `handleExpirationDelivery` is idempotent — safe even if AppDelegate already ran.
        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
        } else if userInfo["isPractice"] as? Bool != true {
            // Real question delivered in foreground — activate its state.
            engine.activateQuestion(from: userInfo)
            // Fallback: re-register category with real titles in case the silent prep push was dropped.
            if let choices = userInfo["choices"] as? [String], !choices.isEmpty {
                let category = makeQuestionCategory(identifier: pushQuestionCategoryID, choices: choices)
                UNUserNotificationCenter.current().getNotificationCategories { existing in
                    var merged = existing.filter { $0.identifier != pushQuestionCategoryID }
                    merged.insert(category)
                    UNUserNotificationCenter.current().setNotificationCategories(merged)
                }
            }
        }

        completionHandler([.banner, .sound])
    }

    // MARK: - Action Response

    /// Called when the user taps an answer button or dismisses a notification.
    ///
    /// The notification `completionHandler` is intentionally NOT called via `defer`.
    /// On watchOS, calling `completionHandler()` signals that notification processing is
    /// done, which can cause the system to suspend the extension immediately — killing
    /// any in-flight URLSession task before it reaches the network. Instead, every code
    /// path explicitly calls `completionHandler()` only after all work (including the
    /// async `mark-answered` network call) has finished.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Expiration taps flow here for both real and practice questions.
        // `handleExpirationDelivery` is idempotent — safe if AppDelegate already ran.
        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
            completionHandler()
            return
        }

        if userInfo["isPractice"] as? Bool == true {
            handlePracticeResponse(response: response, userInfo: userInfo)
            completionHandler()
            return
        }

        // Activate state for background-delivered questions (idempotent).
        engine.activateQuestion(from: userInfo)
        // Re-register category with real titles (idempotent fallback for a dropped silent prep push).
        if let choices = userInfo["choices"] as? [String], !choices.isEmpty {
            let category = makeQuestionCategory(identifier: pushQuestionCategoryID, choices: choices)
            UNUserNotificationCenter.current().getNotificationCategories { existing in
                var merged = existing.filter { $0.identifier != pushQuestionCategoryID }
                merged.insert(category)
                UNUserNotificationCenter.current().setNotificationCategories(merged)
            }
        }

        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw)
        else {
            completionHandler()
            return
        }

        let actionID = response.actionIdentifier

        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else {
            completionHandler()
            return
        }

        let answer = resolveAnswer(actionID: actionID, userInfo: userInfo)
        let correctAnswer = userInfo["correctAnswer"] as? String ?? ""

        if let outcome = engine.evaluate(answer: answer, slot: slot) {
            // Pass completionHandler into applyOutcome so it is held open until
            // the mark-answered network call completes, preventing watchOS from
            // suspending the extension and killing the in-flight request.
            applyOutcome(outcome, slot: slot, correctAnswer: correctAnswer, completion: completionHandler)
        } else {
            reshowResult(slot: slot)
            completionHandler()
        }
    }

    // MARK: - Practice Response

    /// Handles a practice question answer — no effect on QuestionState or the streak.
    private func handlePracticeResponse(response: UNNotificationResponse, userInfo: [AnyHashable: Any]) {
        let actionID = response.actionIdentifier

        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else { return }

        guard let correctAnswer = userInfo["correctAnswer"] as? String else { return }

        if let expirationID = userInfo["expirationID"] as? String {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [expirationID])
        }

        if let categoryID = userInfo["categoryID"] as? String {
            notificationManager.removePracticeCategory(categoryID)
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

    /// Persists the outcome, updates the streak, sends a result notification, and then
    /// calls `completion` once the mark-answered network request finishes.
    ///
    /// `completion` is the notification's `completionHandler` — holding it open keeps
    /// the watchOS extension alive long enough for the HTTP request to complete.
    /// Gated on `store.markAnswered` returning `true` — if a racing expiration already
    /// resolved the slot, `markAnswered` returns `false` and we re-show the expiration
    /// result instead, preventing a double debit.
    private func applyOutcome(_ outcome: Outcome, slot: Slot, correctAnswer: String, completion: @escaping () -> Void) {
        guard store.markAnswered(slot: slot, outcome: outcome) else {
            // A racing expiration already resolved this slot — show what actually applied.
            reshowResult(slot: slot)
            completion()
            return
        }

        // Pass the notification completionHandler as the network completion so watchOS
        // keeps the extension alive until mark-answered actually reaches Supabase.
        AnswerReportingManager.shared.reportAnswer(slot: slot.rawValue, completion: completion)

        // Capture lives before applying the outcome so we can detect whether a streak
        // reset actually occurred. A reset happens only when lives drop to 0 and refill
        // to 3 — detectable because livesAfter > livesBefore on an incorrect/expired outcome.
        let livesBefore = streakManager.currentLives()
        streakManager.handleOutcome(outcome)
        let livesAfter = streakManager.currentLives()

        let streakWasReset = (outcome == .incorrect || outcome == .expired) && livesAfter > livesBefore

        notificationManager.sendResultNotification(
            outcome: outcome,
            streak: streakManager.currentStreak(),
            correctAnswer: correctAnswer,
            streakWasReset: streakWasReset
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

    /// Marks a question expired when its expiration notification is delivered or tapped.
    /// Idempotent — `markExpired` returns `false` if the state was already resolved,
    /// preventing a double debit against a racing answer-tap.
    private func handleExpirationDelivery(userInfo: [AnyHashable: Any]) {
        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw)
        else { return }

        guard userInfo["isPractice"] as? Bool != true else { return }

        guard store.markExpired(slot: slot) else {
            // Already resolved (answered or expired) — nothing to do. No double debit.
            return
        }

        applyExpirationStreakChange()
    }

    // MARK: - Reconciliation Sweep

    /// Foreground sweep that closes the watchOS expiration-push gap.
    ///
    /// On watchOS, the background handler doesn't fire for visible alert pushes, so a user
    /// who ignores the expiration notification entirely would never lose a life. This sweep
    /// runs every time the app comes to foreground and marks any `.active` question past
    /// its 1-hour window as expired, debiting a life at that point.
    func reconcileExpiredQuestions() {
        let expirationWindow: TimeInterval = 3600
        let now = Date()

        for slot in [Slot.noon, Slot.evening] {
            guard let state = store.loadActiveQuestion(slot: slot),
                  case .active = state.status,
                  now > state.deliveredAt.addingTimeInterval(expirationWindow)
            else { continue }

            guard store.markExpired(slot: slot) else { continue }
            applyExpirationStreakChange()
            print("[NotificationActionHandler] Reconciled expired slot=\(slot.rawValue) questionID=\(state.questionID)")
        }
    }

    /// Applies streak/lives for an expiration and posts the UI refresh notification.
    /// Shared by `handleExpirationDelivery` and `reconcileExpiredQuestions` so both paths
    /// produce identical on-device effects. Fires a streak-reset notification only when
    /// lives drop to 0 and refill (a full reset) — routine life losses are silent.
    private func applyExpirationStreakChange() {
        let livesBefore = streakManager.currentLives()
        streakManager.handleOutcome(.expired)
        let livesAfter = streakManager.currentLives()

        let streakWasReset = livesAfter > livesBefore
        if streakWasReset {
            notificationManager.sendStreakResetNotification()
        }

        NotificationCenter.default.post(name: .streakDidChange, object: nil)
    }

    // MARK: - Helpers

    /// Converts a positional action ID (e.g. "answer_2") back to the answer string using the choices array.
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
