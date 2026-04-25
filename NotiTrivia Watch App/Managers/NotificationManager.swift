import UserNotifications
import Foundation

// MARK: - Notification Identifier Helpers

enum NotifID {
    static func question(slot: Slot, date: Date) -> String {
        "question-\(slot.rawValue)-\(dateTag(date))"
    }

    static func expiration(slot: Slot, date: Date) -> String {
        "expiration-\(slot.rawValue)-\(dateTag(date))"
    }

    static func result() -> String {
        "result-\(UUID().uuidString)"
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HH-mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dateTag(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Answer Category Helpers

/// Per-question category ID — keyed by question ID so each question has its own button titles.
private func questionCategoryID(_ questionID: String) -> String { "Q-\(questionID)" }

/// Positional action identifier for index N (used for answer mapping in the handler).
func answerActionID(_ index: Int) -> String { "answer_\(index)" }

// MARK: - NotificationManager

final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    /// How many future question slots to keep scheduled per slot type.
    /// 28 noon + 28 evening = 56 total, leaving 8 slots free as a buffer
    /// for result and expiration notifications (system maximum is 64).
    private let targetScheduledCount = 28

    /// Safety cap: max loop iterations in refillSchedule to prevent infinite loops.
    private let maxFillIterations = 200

    private init() {}

    // MARK: - Setup

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("[NotificationManager] Permission error: \(error)")
            }
        }
    }

    /// Registers a minimal base category set at launch.
    /// Per-question categories (with real answer titles) are registered in refillSchedule.
    func registerCategories() {
        // Register an empty placeholder so the system knows about our category namespace.
        // Real per-question categories are added in refillSchedule and sendTestNotification.
        // This call is intentionally minimal — it just ensures the center is initialized.
        center.setNotificationCategories([])
    }

    // MARK: - Schedule Maintenance

    /// Checks pending notifications and fills any gaps up to targetScheduledCount
    /// for both noon and evening slots. Safe to call on every app launch.
    func refillSchedule() {
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }

            let pendingIDs = Set(pending.map(\.identifier))
            let calendar = Calendar.current
            let now = Date()

            var newCategories: Set<UNNotificationCategory> = []
            var requestsToSchedule: [(UNNotificationRequest, UNNotificationRequest)] = []

            for slot in [Slot.noon, Slot.evening] {
                let hour = slot == .noon ? 12 : 18

                let alreadyScheduled = pending.filter {
                    $0.identifier.hasPrefix("question-\(slot.rawValue)-")
                }.count

                let needed = self.targetScheduledCount - alreadyScheduled
                guard needed > 0 else { continue }

                var components = calendar.dateComponents([.year, .month, .day], from: now)
                components.hour = hour
                components.minute = 0
                components.second = 0

                guard var candidate = calendar.date(from: components) else { continue }
                if candidate <= now {
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }

                var filled = 0
                var iterations = 0

                while filled < needed && iterations < self.maxFillIterations {
                    iterations += 1
                    let qID = NotifID.question(slot: slot, date: candidate)

                    if !pendingIDs.contains(qID) {
                        if let question = QuestionEngine.shared.selectAndReserve() {
                            let (qRequest, eRequest, category) = self.buildRequests(
                                slot: slot,
                                question: question,
                                deliveredAt: candidate
                            )
                            newCategories.insert(category)
                            requestsToSchedule.append((qRequest, eRequest))
                            filled += 1
                        } else {
                            break
                        }
                    }

                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
            }

            guard !requestsToSchedule.isEmpty else { return }

            // Register all new per-question categories in one call, then schedule
            self.center.getNotificationCategories { existing in
                let merged = existing.union(newCategories)
                self.center.setNotificationCategories(merged)

                for (qRequest, eRequest) in requestsToSchedule {
                    self.center.add(qRequest) { error in
                        if let error { print("[NotificationManager] Question schedule error: \(error)") }
                    }
                    self.center.add(eRequest) { error in
                        if let error { print("[NotificationManager] Expiration schedule error: \(error)") }
                    }
                }
            }
        }
    }

    // MARK: - Request Builder

    /// Builds the question and expiration notification requests for a given slot + question.
    /// Returns (questionRequest, expirationRequest, category).
    private func buildRequests(
        slot: Slot,
        question: Question,
        deliveredAt: Date
    ) -> (UNNotificationRequest, UNNotificationRequest, UNNotificationCategory) {

        // Per-question category: action titles are the actual answer strings
        let categoryID = questionCategoryID(question.id)
        let actions = question.choices.enumerated().map { i, choice in
            UNNotificationAction(identifier: answerActionID(i), title: choice, options: [])
        }
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // Question notification
        let qContent = UNMutableNotificationContent()
        qContent.title = "NotiTrivia"
        qContent.body = question.question
        qContent.sound = .default
        qContent.categoryIdentifier = categoryID
        // choices array lets the handler map answer_N → actual answer text
        qContent.userInfo = [
            "slot": slot.rawValue,
            "questionID": question.id,
            "correctAnswer": question.correct,
            "deliveredAt": deliveredAt.timeIntervalSince1970,
            "choices": question.choices
        ]

        let qTrigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: deliveredAt
            ),
            repeats: false
        )
        let qRequest = UNNotificationRequest(
            identifier: NotifID.question(slot: slot, date: deliveredAt),
            content: qContent,
            trigger: qTrigger
        )

        // Expiration notification (fires 1 hour after delivery)
        let expiresAt = deliveredAt.addingTimeInterval(3600)
        let eContent = UNMutableNotificationContent()
        eContent.title = "⏰ Time Expired"
        eContent.body = "The correct answer was: \(question.correct)"
        eContent.sound = .default
        eContent.userInfo = [
            "slot": slot.rawValue,
            "isExpiration": true,
            "deliveredAt": deliveredAt.timeIntervalSince1970
        ]

        let eTrigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: expiresAt
            ),
            repeats: false
        )
        let eRequest = UNNotificationRequest(
            identifier: NotifID.expiration(slot: slot, date: deliveredAt),
            content: eContent,
            trigger: eTrigger
        )

        return (qRequest, eRequest, category)
    }

    // MARK: - Test Notification

    /// Fires a real question notification in 5 seconds for testing.
    /// Registers the per-question category first, then schedules — no race condition.
    /// Expiration fires 65 seconds after delivery for quick testing of the expiration path.
    func sendTestNotification(completion: @escaping (Bool) -> Void = { _ in }) {
        // Use selectWithoutReserving so practice questions don't consume the real rotation
        guard let question = QuestionEngine.shared.selectWithoutReserving() else {
            print("[NotificationManager] No questions available for practice")
            completion(false)
            return
        }

        let deliveredAt = Date().addingTimeInterval(5)
        let categoryID = questionCategoryID(question.id)

        // Build per-question category with real answer titles
        let actions = question.choices.enumerated().map { i, choice in
            UNNotificationAction(identifier: answerActionID(i), title: choice, options: [])
        }
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

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
            "isPractice": true
        ]

        let eContent = UNMutableNotificationContent()
        eContent.title = "⏰ Time Expired"
        eContent.body = "The correct answer was: \(question.correct)"
        eContent.sound = .default
        eContent.userInfo = [
            "slot": Slot.noon.rawValue,
            "isExpiration": true,
            "isPractice": true,
            "deliveredAt": deliveredAt.timeIntervalSince1970
        ]

        let qRequest = UNNotificationRequest(
            identifier: "test-question-\(question.id)",
            content: qContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        )
        let eRequest = UNNotificationRequest(
            identifier: "test-expiration-\(question.id)",
            content: eContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 65, repeats: false)
        )

        // Register category first, then schedule — guarantees category exists before delivery
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            var updated = existing
            updated.insert(category)
            self.center.setNotificationCategories(updated)

            self.center.add(qRequest) { error in
                if let error {
                    print("[NotificationManager] Test question error: \(error)")
                    completion(false)
                } else {
                    completion(true)
                }
            }
            self.center.add(eRequest) { _ in }
        }
    }

    // MARK: - Expiration Cancellation

    /// Cancels the pending expiration notification for a slot once the user has answered.
    func cancelExpirationNotification(slot: Slot, deliveredAt: Date) {
        let id = NotifID.expiration(slot: slot, date: deliveredAt)
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Result Notification

    /// Sends an immediate result notification after an answer is evaluated.
    /// When `isPractice` is true, streak info is omitted from the result message.
    func sendResultNotification(outcome: Outcome, streak: Int, correctAnswer: String, isPractice: Bool = false) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch outcome {
        case .correct:
            content.title = "✅ Correct!"
            content.body = isPractice ? "Nice work! (Practice — streak unchanged)" : "🔥 Streak: \(streak)"
        case .incorrect:
            content.title = "❌ Incorrect"
            content.body = isPractice
                ? "The correct answer was: \(correctAnswer)\n(Practice — streak unchanged)"
                : "The correct answer was: \(correctAnswer)\nStreak reset."
        case .expired:
            content.title = "⏰ Time Expired"
            content.body = "The correct answer was: \(correctAnswer)"
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: NotifID.result(),
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error {
                print("[NotificationManager] Failed to send result: \(error)")
            }
        }
    }
}
