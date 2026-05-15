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

        // Real expiration pushes now arrive as visible alert pushes (apns-priority 10) and
        // will reach this handler when the app is in the foreground. handleExpirationDelivery
        // is idempotent — the .active guard ensures streak/lives are only debited once even
        // if AppDelegate.didReceiveRemoteNotification already processed the same push.
        // Practice expirations are locally scheduled and also flow through here.
        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
        } else if userInfo["isPractice"] as? Bool != true {
            // Real question delivered in foreground — activate its state.
            engine.activateQuestion(from: userInfo)
            // Re-register the stable category with the real choice titles as a belt-and-suspenders
            // measure for the foreground case. The silent prep push should have already done this,
            // but refreshing here ensures the titles are always current.
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
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let userInfo = response.notification.request.content.userInfo

        // Real expiration pushes now arrive as visible alert pushes and the user may tap them.
        // handleExpirationDelivery is idempotent — if AppDelegate already marked the question
        // expired when the push arrived, the .active guard bails out harmlessly here.
        // Practice expirations are locally scheduled and also flow through here.
        if userInfo["isExpiration"] as? Bool == true {
            handleExpirationDelivery(userInfo: userInfo)
            return
        }

        if userInfo["isPractice"] as? Bool == true {
            handlePracticeResponse(response: response, userInfo: userInfo)
            return
        }

        // Real question tapped — activate state (handles background delivery).
        engine.activateQuestion(from: userInfo)
        // Refresh the stable category with the real choice titles (idempotent).
        // The silent prep push already did this before the notification appeared,
        // but refreshing here keeps the category correct for any edge case.
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
        else { return }

        let actionID = response.actionIdentifier

        guard actionID != UNNotificationDefaultActionIdentifier,
              actionID != UNNotificationDismissActionIdentifier,
              !actionID.isEmpty else { return }

        let answer = resolveAnswer(actionID: actionID, userInfo: userInfo)
        let correctAnswer = userInfo["correctAnswer"] as? String ?? ""

        if let outcome = engine.evaluate(answer: answer, slot: slot) {
            applyOutcome(outcome, slot: slot, correctAnswer: correctAnswer)
        } else {
            reshowResult(slot: slot)
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

    /// Persists the outcome, updates the streak, and sends a result notification.
    ///
    /// Gated on `store.markAnswered` returning `true` — if a racing expiration push
    /// already transitioned the state to `.expired` between `evaluate()` returning an
    /// outcome and this call, `markAnswered` no-ops and returns `false`. In that case
    /// we re-show the expiration result (the user effectively missed the deadline by
    /// a hair) instead of double-counting `handleOutcome` on top of the expiration
    /// path's debit. This closes the boundary race that previously corrupted lives.
    private func applyOutcome(_ outcome: Outcome, slot: Slot, correctAnswer: String) {
        guard store.markAnswered(slot: slot, outcome: outcome) else {
            // A racing expiration already resolved this slot — show what actually applied.
            reshowResult(slot: slot)
            return
        }

        AnswerReportingManager.shared.reportAnswer(slot: slot.rawValue)

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

    /// Marks a question as expired when an expiration notification is delivered or tapped.
    /// Handles both server-sent alert pushes (real questions) and locally scheduled
    /// expiration notifications (practice questions). Idempotent — `markExpired` returns
    /// `false` if the state was already resolved (e.g. by a racing answer-tap), and we
    /// gate `handleOutcome` and the streak-reset follow-up on that result so the lives
    /// counter is never double-debited.
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

    /// Defense-in-depth for the watchOS expiration-push gap.
    ///
    /// On watchOS, `WKApplicationDelegate.didReceiveRemoteNotification` does NOT fire for
    /// visible alert pushes — only for pure background (content-available:1, priority 5)
    /// pushes. Our `send-expirations` Edge Function sends a visible alert push (so the
    /// user actually sees "Time Expired — the correct answer was X"), which means the
    /// AppDelegate background handler is unreachable for it. The push only debits lives
    /// when (a) the watch is in foreground and `willPresent` runs, or (b) the user taps
    /// the notification and `didReceive` runs. A user who ignores the expiration push
    /// completely would otherwise never lose a life — bypassing the entire lives system.
    ///
    /// This sweep closes that gap: every time the app comes to foreground, it scans both
    /// slots, and for any QuestionState still in `.active` whose 1-hour answer window
    /// has elapsed, it marks expired and debits one life — guaranteeing the penalty
    /// catches up next time the user opens the watch app.
    ///
    /// Combined with the silent-prep-push activation in `AppDelegate` (which writes the
    /// QuestionState the moment the prep push arrives, before the visible question
    /// notification is even shown), this guarantees a QuestionState exists for the sweep
    /// to find — even if the user never taps anything.
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

    /// Shared helper that applies the streak/lives delta for an expiration and posts
    /// the UI refresh notification. Used by both `handleExpirationDelivery` (real-time
    /// push) and `reconcileExpiredQuestions` (foreground sweep) so the on-device side
    /// effects are identical regardless of which path catches the expiration.
    ///
    /// Fires `sendStreakResetNotification` only when the debit caused a full streak
    /// reset (lives 1 → 0 → refill to 3 with streak zeroed). Routine life losses don't
    /// fire a follow-up notification — they're visible on the watch face's lives
    /// indicator and a second notification would be noise. A reset, however, is a
    /// significant event we want the user to know about without opening the app.
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