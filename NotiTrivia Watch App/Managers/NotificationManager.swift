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

    static func category(slot: Slot, date: Date) -> String {
        "question-cat-\(slot.rawValue)-\(dateTag(date))"
    }

    static func practiceCategory(questionID: String) -> String {
        "practice-cat-\(questionID)"
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
//
// watchOS renders action button titles from the registered UNNotificationCategory, not from
// the notification content. Because real questions are scheduled hours/days in advance and
// can be delivered while the app is suspended, the category for each scheduled question must
// be registered with its real answer titles AT SCHEDULING TIME — there is no later opportunity
// to inject titles before the system renders the buttons.
//
// We therefore register one category PER pending question (plus one for practice). With a
// 7-day buffer × 2 slots = 14 question categories + 1 practice, we stay well under the
// watchOS 100-category cap. `refillSchedule` prunes stale categories whose notifications are
// no longer pending so the count cannot drift upward over time.

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

    /// Number of future question slots to maintain per slot type (noon + evening).
    /// 7 × 2 slots = 14 question + 14 expiration = 28 total, well within the system's 64-notification cap.
    private let targetScheduledCount = 7
    private let maxFillIterations = 200

    /// TESTING KNOB: when non-nil, schedules real questions every N minutes (alternating
    /// noon/evening slots) instead of at 12:00 and 18:00 daily. Set to `nil` for production.
    /// Expiration windows automatically shorten to fit inside the interval.
    private let testModeIntervalMinutes: Int? = 20

    /// How long after delivery a question stays answerable before the expiration notification
    /// fires. Production = 1 hour. In test mode, fits inside the interval (interval - 5min).
    private var expirationWindowSeconds: TimeInterval {
        if let interval = testModeIntervalMinutes {
            return TimeInterval(max(60, interval * 60 - 300))
        }
        return 3600
    }

    private init() {}


    // MARK: - Setup

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("[NotificationManager] Permission error: \(error)")
            }
        }
    }

    // MARK: - Category Registration Helpers

    /// Adds (or replaces) a single category in the system's registered set without disturbing
    /// any other registered categories. `setNotificationCategories` is a full overwrite, so we
    /// must merge with the existing set every time.
    private func registerCategory(_ category: UNNotificationCategory) {
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            var merged = existing.filter { $0.identifier != category.identifier }
            merged.insert(category)
            self.center.setNotificationCategories(merged)
        }
    }

    /// Synchronously-style merge for an arbitrary set of categories, preserving everything
    /// else. Used by `refillSchedule` after a batch of new questions is scheduled.
    private func registerCategories(_ categories: [UNNotificationCategory]) {
        guard !categories.isEmpty else { return }
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            let newIDs = Set(categories.map(\.identifier))
            var merged = existing.filter { !newIDs.contains($0.identifier) }
            for c in categories { merged.insert(c) }
            self.center.setNotificationCategories(merged)
        }
    }

    // MARK: - Schedule Maintenance

    /// Fills any gaps in the pending schedule up to `targetScheduledCount` for each slot.
    /// Safe to call on every app launch and after each question fires.
    func refillSchedule() {
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }

            let pendingIDs = Set(pending.map(\.identifier))
            let now = Date()
            var requestsToSchedule: [(UNNotificationRequest, UNNotificationRequest)] = []
            var newCategories: [UNNotificationCategory] = []

            // Generate the list of (slot, deliveryDate) candidates we'd ideally have queued.
            let candidates = self.upcomingCandidates(now: now)
            // Total slots already scheduled across all slot types.
            let totalScheduled = pending.filter { $0.identifier.hasPrefix("question-") }.count
            var needed = max(0, (candidates.count) - totalScheduled)

            var iterations = 0
            for (slot, candidate) in candidates {
                guard needed > 0, iterations < self.maxFillIterations else { break }
                iterations += 1
                let qID = NotifID.question(slot: slot, date: candidate)
                guard !pendingIDs.contains(qID) else { continue }

                guard let question = QuestionEngine.shared.selectAndReserve() else { break }

                let (qRequest, eRequest, category) = self.buildRequests(
                    slot: slot,
                    question: question,
                    deliveredAt: candidate
                )
                requestsToSchedule.append((qRequest, eRequest))
                newCategories.append(category)
                needed -= 1
            }

            // Register new categories BEFORE adding the notification requests so they are
            // committed by the time the system needs them. We also prune any stale
            // question-cat-* categories whose notifications are no longer pending.
            self.commitCategories(addingNew: newCategories, currentlyPending: pending)


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

    /// Generates the ordered list of upcoming (slot, deliveryDate) pairs we want pending in
    /// the system, in delivery order. In production this is `targetScheduledCount` future
    /// noon firings followed by `targetScheduledCount` future evening firings. In test mode
    /// it produces `targetScheduledCount * 2` total firings spaced `testModeIntervalMinutes`
    /// apart, alternating between noon and evening slots.
    private func upcomingCandidates(now: Date) -> [(Slot, Date)] {
        let calendar = Calendar.current

        if let interval = self.testModeIntervalMinutes {
            let intervalSeconds = TimeInterval(interval * 60)
            // Round up to the next interval boundary, with at least 30s lead time.
            let secondsSinceEpoch = now.timeIntervalSince1970
            var nextBoundary = ceil(secondsSinceEpoch / intervalSeconds) * intervalSeconds
            if nextBoundary - secondsSinceEpoch < 30 { nextBoundary += intervalSeconds }

            let total = self.targetScheduledCount * 2
            let slots: [Slot] = [.noon, .evening]
            return (0..<total).map { i in
                let date = Date(timeIntervalSince1970: nextBoundary + Double(i) * intervalSeconds)
                return (slots[i % slots.count], date)
            }
        }

        // Production: noon + evening daily.
        var result: [(Slot, Date)] = []
        for slot in [Slot.noon, Slot.evening] {
            let hour = slot == .noon ? 12 : 18
            var components = calendar.dateComponents([.year, .month, .day], from: now)
            components.hour = hour
            components.minute = 0
            components.second = 0

            guard var candidate = calendar.date(from: components) else { continue }
            if candidate <= now {
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
            for _ in 0..<self.targetScheduledCount {
                result.append((slot, candidate))
                candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
            }
        }
        return result
    }

    /// Rebuilds the category set: keeps any non-question-cat categories untouched, adds the
    /// brand-new categories about to be used, and drops `question-cat-*` categories whose
    /// underlying notification is no longer pending. This keeps us well under the 100-cap
    /// across long-lived installs.
    private func commitCategories(
        addingNew newCategories: [UNNotificationCategory],
        currentlyPending pending: [UNNotificationRequest]
    ) {
        // Compute the set of category ids that are still relevant from currently-pending
        // requests so that any registered question-cat-* whose notification has fired/been
        // removed gets pruned.
        let pendingCategoryIDs: Set<String> = Set(
            pending.compactMap { req -> String? in
                let id = req.content.categoryIdentifier
                return id.isEmpty ? nil : id
            }
        )
        let newCategoryIDs = Set(newCategories.map(\.identifier))

        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            var merged = Set<UNNotificationCategory>()
            for c in existing {
                let id = c.identifier
                // Drop stale question categories that no longer correspond to a pending
                // notification AND aren't being re-registered right now.
                if id.hasPrefix("question-cat-") {
                    if pendingCategoryIDs.contains(id) || newCategoryIDs.contains(id) {
                        merged.insert(c)
                    }
                    continue
                }
                // Practice categories are short-lived; drop any that aren't pending.
                if id.hasPrefix("practice-cat-") {
                    if pendingCategoryIDs.contains(id) {
                        merged.insert(c)
                    }
                    continue
                }
                // Preserve anything else (system or unrelated).
                merged.insert(c)
            }
            // Insert the new ones (overwriting any same-id entries we already added).
            for c in newCategories {
                merged = Set(merged.filter { $0.identifier != c.identifier })
                merged.insert(c)
            }
            self.center.setNotificationCategories(merged)
        }
    }

    // MARK: - Request Builder

    /// Builds a paired question + expiration request for a given slot and question, plus the
    /// per-question category whose action titles the system will display.
    private func buildRequests(
        slot: Slot,
        question: Question,
        deliveredAt: Date
    ) -> (UNNotificationRequest, UNNotificationRequest, UNNotificationCategory) {

        let categoryID = NotifID.category(slot: slot, date: deliveredAt)
        let category = makeQuestionCategory(identifier: categoryID, choices: question.choices)

        let qContent = UNMutableNotificationContent()
        qContent.title = "NotiTrivia"
        qContent.body = question.question
        qContent.sound = .default
        qContent.categoryIdentifier = categoryID
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

        let expiresAt = deliveredAt.addingTimeInterval(expirationWindowSeconds)
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

        return (qRequest, eRequest, category)
    }

    // MARK: - Practice Notification

    /// Schedules a practice question notification in 5 seconds and a paired expiration in 65 seconds.
    /// Registers a unique category for this practice question (so it does not collide with any
    /// real-question categories) immediately before scheduling. Practice questions do not
    /// affect the real question rotation or the user's streak.
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

        // Register this practice question's category (merged with existing categories so we
        // don't wipe scheduled real-question categories).
        let category = makeQuestionCategory(identifier: categoryID, choices: question.choices)
        registerCategory(category)
        print("[NotificationManager] Practice category \(categoryID) registered with choices: \(question.choices)")

        // Small delay to let the system commit the category before delivery.
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

    /// Removes a practice category once the practice flow is fully resolved (answered or
    /// expired). Safe to call multiple times.
    func removePracticeCategory(_ categoryID: String) {
        guard categoryID.hasPrefix("practice-cat-") else { return }
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            let filtered = existing.filter { $0.identifier != categoryID }
            self.center.setNotificationCategories(filtered)
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
