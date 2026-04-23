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

    // Cached formatter — avoids allocating one per call
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

// MARK: - NotificationManager

final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    /// How many future question slots to keep scheduled per slot type.
    /// 32 noon + 32 evening = 64 total (system maximum for pending notifications).
    private let targetScheduledCount = 32

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

    // MARK: - Schedule Maintenance

    /// Checks pending notifications and fills any gaps up to targetScheduledCount
    /// for both noon and evening slots. Safe to call on every app launch.
    func refillSchedule() {
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }

            // Collect all pending question identifiers for fast lookup
            let pendingIDs = Set(pending.map(\.identifier))

            let calendar = Calendar.current
            let now = Date()

            // Batch all new categories so we register them in one call
            var newCategories: [UNNotificationCategory] = []
            var requestsToSchedule: [(UNNotificationRequest, UNNotificationRequest)] = [] // (question, expiration)

            for slot in [Slot.noon, Slot.evening] {
                let hour = slot == .noon ? 12 : 18

                let alreadyScheduled = pending.filter {
                    $0.identifier.hasPrefix("question-\(slot.rawValue)-")
                }.count

                let needed = self.targetScheduledCount - alreadyScheduled
                guard needed > 0 else { continue }

                // Start from today's slot time; advance to tomorrow if already past
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
                        // Select a question and build the notification content.
                        // QuestionState is NOT written here — it is written at delivery
                        // time via the notification's userInfo payload.
                        if let question = QuestionEngine.shared.selectAndReserve() {
                            let (qRequest, eRequest, category) = self.buildRequests(
                                slot: slot,
                                question: question,
                                deliveredAt: candidate
                            )
                            newCategories.append(category)
                            requestsToSchedule.append((qRequest, eRequest))
                            filled += 1
                        } else {
                            break // No questions available
                        }
                    }

                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
            }

            // Register all new categories in one atomic call
            if !newCategories.isEmpty {
                self.center.getNotificationCategories { existing in
                    var updated = existing
                    for cat in newCategories { updated.insert(cat) }
                    self.center.setNotificationCategories(updated)

                    // Schedule all requests after categories are registered
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
    }

    // MARK: - Request Builder

    /// Builds the question and expiration notification requests for a given slot + question.
    /// Returns (questionRequest, expirationRequest, category).
    private func buildRequests(
        slot: Slot,
        question: Question,
        deliveredAt: Date
    ) -> (UNNotificationRequest, UNNotificationRequest, UNNotificationCategory) {

        // --- Category (per-question, keyed by question ID) ---
        let actions = question.choices.map {
            UNNotificationAction(identifier: $0, title: $0, options: [])
        }
        let categoryID = "Q-\(question.id)"
        let category = UNNotificationCategory(
            identifier: categoryID,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )

        // --- Question notification ---
        let qContent = UNMutableNotificationContent()
        qContent.title = "NotiTrivia"
        qContent.body = question.question
        qContent.sound = .default
        qContent.categoryIdentifier = categoryID
        // Embed everything needed to reconstruct QuestionState on delivery
        qContent.userInfo = [
            "slot": slot.rawValue,
            "questionID": question.id,
            "correctAnswer": question.correct,
            "deliveredAt": deliveredAt.timeIntervalSince1970
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

        // --- Expiration notification (fires 1 hour after delivery) ---
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

    // MARK: - Expiration Cancellation

    /// Cancels the pending expiration notification for a slot once the user has answered.
    func cancelExpirationNotification(slot: Slot, deliveredAt: Date) {
        let id = NotifID.expiration(slot: slot, date: deliveredAt)
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    // MARK: - Result Notification

    /// Sends an immediate result notification after an answer is evaluated.
    func sendResultNotification(outcome: Outcome, streak: Int, correctAnswer: String) {
        let content = UNMutableNotificationContent()
        content.sound = .default

        switch outcome {
        case .correct:
            content.title = "✅ Correct!"
            content.body = "🔥 Streak: \(streak)"
        case .incorrect:
            content.title = "❌ Incorrect"
            content.body = "The correct answer was: \(correctAnswer)\nStreak reset."
        case .expired:
            content.title = "⏰ Time Expired"
            content.body = "The correct answer was: \(correctAnswer)"
        }

        // 1-second minimum interval for local notifications
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
