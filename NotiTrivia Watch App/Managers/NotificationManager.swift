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

// MARK: - Question Category

/// watchOS renders action button titles from the registered UNNotificationCategory, not from
/// the notification content. To show real answer text on the buttons, the category must be
/// built with the actual choices for the current question and registered before delivery.
///
/// To stay well under the watchOS 100-category cap, we keep exactly ONE category registered
/// at any time. Each new question replaces the previous category entirely.
let sharedQuestionCategoryID = "question_answer_category"

func answerActionID(_ index: Int) -> String { "answer_\(index)" }

func makeQuestionCategory(choices: [String]) -> UNNotificationCategory {
    let actions = choices.enumerated().map { i, choice in
        UNNotificationAction(identifier: answerActionID(i), title: choice, options: [])
    }
    return UNNotificationCategory(
        identifier: sharedQuestionCategoryID,
        actions: actions,
        intentIdentifiers: [],
        options: []
    )
}

// MARK: - NotificationManager

final class NotificationManager {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    /// Number of future question slots to maintain per slot type (noon + evening).
    /// 7 × 2 slots = 14 question + 14 expiration = 28 total, well within the system's 64-notification cap.
    private let targetScheduledCount = 7
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

    /// Clears all stale categories and registers a fresh placeholder category at launch.
    /// The placeholder is replaced with real answer titles each time a question is scheduled.
    func registerSharedCategory() {
        // Replace the entire set so stale per-question categories from old builds are wiped.
        center.setNotificationCategories([makeQuestionCategory(choices: [])])
        print("[NotificationManager] Category set cleared at launch")
    }

    // MARK: - Schedule Maintenance

    /// Fills any gaps in the pending schedule up to `targetScheduledCount` for each slot.
    /// Safe to call on every app launch and after each question fires.
    func refillSchedule() {
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }

            let pendingIDs = Set(pending.map(\.identifier))
            let calendar = Calendar.current
            let now = Date()
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

                    if !pendingIDs.contains(qID), let question = QuestionEngine.shared.selectAndReserve() {
                        let (qRequest, eRequest) = self.buildRequests(
                            slot: slot,
                            question: question,
                            deliveredAt: candidate
                        )
                        requestsToSchedule.append((qRequest, eRequest))
                        filled += 1
                    } else if !pendingIDs.contains(qID) {
                        break
                    }

                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
            }

            guard !requestsToSchedule.isEmpty else { return }

            print("[NotificationManager] Scheduling \(requestsToSchedule.count) new question pair(s)")
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

    // MARK: - Request Builder

    /// Builds a paired question + expiration request for a given slot and question.
    /// Both use the shared category; answer text is resolved from userInfo at tap time.
    private func buildRequests(
        slot: Slot,
        question: Question,
        deliveredAt: Date
    ) -> (UNNotificationRequest, UNNotificationRequest) {

        let qContent = UNMutableNotificationContent()
        qContent.title = "NotiTrivia"
        qContent.body = question.question
        qContent.sound = .default
        qContent.categoryIdentifier = sharedQuestionCategoryID
        qContent.userInfo = [
            "slot": slot.rawValue,
            "questionID": question.id,
            "correctAnswer": question.correct,
            "deliveredAt": deliveredAt.timeIntervalSince1970,
            "choices": question.choices
        ]

        let qTrigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: deliveredAt),
            repeats: false
        )
        let qRequest = UNNotificationRequest(
            identifier: NotifID.question(slot: slot, date: deliveredAt),
            content: qContent,
            trigger: qTrigger
        )

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
            dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: expiresAt),
            repeats: false
        )
        let eRequest = UNNotificationRequest(
            identifier: NotifID.expiration(slot: slot, date: deliveredAt),
            content: eContent,
            trigger: eTrigger
        )

        return (qRequest, eRequest)
    }

    // MARK: - Practice Notification

    /// Schedules a practice question notification in 5 seconds and a paired expiration in 65 seconds.
    /// Registers the category with the question's real answer choices immediately before scheduling,
    /// replacing any previous category so the system always has exactly one registered.
    /// Practice questions do not affect the real question rotation or the user's streak.
    func sendTestNotification(completion: @escaping (Bool) -> Void = { _ in }) {
        guard let question = QuestionEngine.shared.selectWithoutReserving() else {
            print("[NotificationManager] No questions available for practice")
            completion(false)
            return
        }

        let deliveredAt = Date().addingTimeInterval(5)
        let expirationID = "test-expiration-\(question.id)"

        let qContent = UNMutableNotificationContent()
        qContent.title = "NotiTrivia"
        qContent.body = question.question
        qContent.sound = .default
        qContent.categoryIdentifier = sharedQuestionCategoryID
        qContent.userInfo = [
            "slot": Slot.noon.rawValue,
            "questionID": question.id,
            "correctAnswer": question.correct,
            "deliveredAt": deliveredAt.timeIntervalSince1970,
            "choices": question.choices,
            "isPractice": true,
            "expirationID": expirationID
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
            identifier: expirationID,
            content: eContent,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 65, repeats: false)
        )

        // Register the category with this question's real answer choices, replacing any
        // previous category. The 0.3s delay gives the system daemon time to commit the
        // new category before the notification request is added.
        let category = makeQuestionCategory(choices: question.choices)
        center.setNotificationCategories([category])
        print("[NotificationManager] Category registered with choices: \(question.choices)")

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

    // MARK: - Expiration Cancellation

    /// Removes the pending expiration notification for a slot once the user has answered.
    func cancelExpirationNotification(slot: Slot, deliveredAt: Date) {
        center.removePendingNotificationRequests(
            withIdentifiers: [NotifID.expiration(slot: slot, date: deliveredAt)]
        )
    }

    // MARK: - Result Notification

    /// Sends an immediate result notification after an answer is evaluated.
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

        let request = UNNotificationRequest(
            identifier: NotifID.result(),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        center.add(request) { error in
            if let error { print("[NotificationManager] Result notification error: \(error)") }
        }
    }
}
