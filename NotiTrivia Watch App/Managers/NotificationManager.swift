import UserNotifications
import Foundation

// MARK: - Notification Identifier Helpers

enum NotifID {
    static func practiceCategory(questionID: String) -> String {
        "practice-cat-\(questionID)"
    }

    static func result() -> String {
        "result-\(UUID().uuidString)"
    }
}

// MARK: - Question Category
//
// watchOS renders action buttons from a registered UNNotificationCategory, not the notification
// payload — so choices must be registered before the notification appears.
//
// Real questions use a fixed "question_category" ID registered at launch with placeholder titles.
// A silent prep push arrives just before the visible question notification and updates the category
// with the real answer choices. Practice questions register a unique per-question category at
// schedule time.

/// The single stable category identifier used for all server-sent (real) question pushes.
/// Must match the `aps.category` value set by the Supabase edge function.
let pushQuestionCategoryID = "question_category"

func answerActionID(_ index: Int) -> String { "answer_\(index)" }

func makeQuestionCategory(identifier: String, choices: [String]) -> UNNotificationCategory {
    let actions = choices.enumerated().map { i, choice in
        UNNotificationAction(identifier: answerActionID(i), title: choice, options: [])
    }
    return UNNotificationCategory(
        identifier: identifier,
        actions: actions,
        intentIdentifiers: [],
        options: []
    )
}

// MARK: - NotificationManager

final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Category Registration

    /// Registers a single category, merging it into the existing set.
    /// `setNotificationCategories` is a full overwrite, so we must always read-merge-write.
    func registerCategory(_ category: UNNotificationCategory) {
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            var merged = existing.filter { $0.identifier != category.identifier }
            merged.insert(category)
            self.center.setNotificationCategories(merged)
        }
    }

    /// Dynamically creates and registers a question category for a push-delivered notification.
    /// The categoryID must match the `aps.category` field set by the server in the APNs payload
    /// so watchOS can display the correct answer-choice action buttons.
    func registerQuestionCategory(categoryID: String, choices: [String]) {
        let category = makeQuestionCategory(identifier: categoryID, choices: choices)
        registerCategory(category)
    }

    // MARK: - Practice Notification

    /// Fires a practice question notification in 5 seconds with a paired expiration at 65 seconds.
    /// Practice questions don't affect the real question rotation or the user's streak.
    func sendTestNotification(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let question = QuestionEngine.shared.selectWithoutReserving() else {
            print("[NotificationManager] No questions available for practice")
            completion(false)
            return
        }

        let deliveredAt = Date().addingTimeInterval(5)
        let expirationID = "test-expiration-\(question.id)"
        let categoryID = NotifID.practiceCategory(questionID: question.id)

        let qContent = UNMutableNotificationContent()
        qContent.title = "NotiTrivia"
        qContent.body = question.question
        qContent.sound = .default
        qContent.categoryIdentifier = categoryID
        qContent.userInfo = [
            "slot": Slot.noon.rawValue,
            "questionID": question.id,
            "correctAnswer": question.correct,
            "deliveredAt": deliveredAt.timeIntervalSince1970,
            "choices": question.choices,
            "isPractice": true,
            "expirationID": expirationID,
            "categoryID": categoryID
        ]

        let eContent = UNMutableNotificationContent()
        eContent.title = "⏰ Time Expired"
        eContent.body = "The correct answer was: \(question.correct)"
        eContent.sound = .default
        eContent.userInfo = [
            "slot": Slot.noon.rawValue,
            "isExpiration": true,
            "isPractice": true,
            "deliveredAt": deliveredAt.timeIntervalSince1970,
            "categoryID": categoryID
        ]

        let qRequest = UNNotificationRequest(
            identifier: "test-question-\(question.id)",
            content: qContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        let eRequest = UNNotificationRequest(
            identifier: expirationID,
            content: eContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 65, repeats: false)
        )

        let category = makeQuestionCategory(identifier: categoryID, choices: question.choices)
        registerCategory(category)
        print("[NotificationManager] Practice category \(categoryID) registered with choices: \(question.choices)")

        // Short delay to give the system time to commit the category before the notification fires.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.center.add(qRequest) { error in
                if let error {
                    print("[NotificationManager] Practice question schedule error: \(error)")
                    completion(false)
                } else {
                    print("[NotificationManager] Practice question scheduled — fires in 5s")
                    completion(true)
                }
            }
            self.center.add(eRequest) { error in
                if let error { print("[NotificationManager] Practice expiration schedule error: \(error)") }
            }
        }
    }

    /// Deregisters a practice category once the flow is resolved. Safe to call multiple times.
    func removePracticeCategory(_ categoryID: String) {
        guard categoryID.hasPrefix("practice-cat-") else { return }
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            let filtered = existing.filter { $0.identifier != categoryID }
            self.center.setNotificationCategories(filtered)
        }
    }

    // MARK: - Result Notification

    /// Fires an immediate result notification after an answer is evaluated.
    /// - Parameter streakWasReset: Pass `true` only when a streak reset actually occurred
    ///   (i.e. lives reached 0 and refilled). Defaults to `false` so existing call sites
    ///   that cannot determine this (re-show, practice) compile without changes.
    func sendResultNotification(outcome: Outcome, streak: Int, correctAnswer: String, isPractice: Bool = false, streakWasReset: Bool = false) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch outcome {
        case .correct:
            content.title = "✅ Correct!"
            content.body = isPractice ? "Nice work! (Practice — streak unchanged)" : "🔥 Streak: \(streak)"
        case .incorrect:
            content.title = "❌ Incorrect"
            if isPractice {
                content.body = "The correct answer was: \(correctAnswer)\n(Practice — streak unchanged)"
            } else if streakWasReset {
                content.body = "The correct answer was: \(correctAnswer)\nStreak reset."
            } else {
                content.body = "The correct answer was: \(correctAnswer)\nLost a life."
            }
        case .expired:
            content.title = "⏰ Time Expired"
            content.body = "The correct answer was: \(correctAnswer)"
        }

        let request = UNNotificationRequest(
            identifier: NotifID.result(),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.add(request) { error in
            if let error { print("[NotificationManager] Result notification error: \(error)") }
        }
    }

    // MARK: - Streak Reset Notification

    /// Fires a local notification when a full streak reset occurs (lives hit 0, streak zeroed,
    /// lives refilled). The expiration push can't carry on-device lives state, so this local
    /// notification surfaces the reset without requiring the user to open the app.
    func sendStreakResetNotification() {
        let content = UNMutableNotificationContent()
        content.title = "💔 Streak Reset"
        content.body = "You're out of lives — your streak has been reset. Start fresh!"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "streak-reset-\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.add(request) { error in
            if let error { print("[NotificationManager] Streak reset notification error: \(error)") }
        }
    }
}
