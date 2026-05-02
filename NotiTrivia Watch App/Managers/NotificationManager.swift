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
// watchOS displays action button titles from a registered UNNotificationCategory — NOT from
// the notification content itself. This means answer choices must be baked into a category
// at scheduling time (days before delivery). We register one category per scheduled question
// so each notification has its own unique answer titles.

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

    /// How many future questions to keep queued per slot (noon + evening).
    /// 7 × 2 slots = 14 question + 14 expiration notifications — well within the 64-notification cap.
    private let targetScheduledCount = 7
    private let maxFillIterations = 200

    /// Set to a non-nil integer to fire questions every N minutes during testing instead of at 12:00 / 18:00.
    /// Set to `nil` for production.
    private let testModeIntervalMinutes: Int? = 45

    /// How long after delivery a question stays answerable before the expiration notification fires.
    /// Production = 1 hour. In test mode, shrinks to fit inside the interval.
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

    // MARK: - Category Registration

    /// Registers a single category, merging it into the existing set.
    /// `setNotificationCategories` is a full overwrite, so we must always read-merge-write.
    private func registerCategory(_ category: UNNotificationCategory) {
        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            var merged = existing.filter { $0.identifier != category.identifier }
            merged.insert(category)
            self.center.setNotificationCategories(merged)
        }
    }

    // MARK: - Schedule Maintenance

    /// Ensures the pending notification queue is topped up to `targetScheduledCount` per slot.
    /// Safe to call on every app launch and whenever a question is delivered.
    func refillSchedule() {
        center.getPendingNotificationRequests { [weak self] pending in
            guard let self else { return }

            let pendingIDs = Set(pending.map(\.identifier))
            let now = Date()
            var requestsToSchedule: [(UNNotificationRequest, UNNotificationRequest)] = []
            var newCategories: [UNNotificationCategory] = []

            let candidates = self.upcomingCandidates(now: now)
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

            // Categories must be committed before notifications are added. We also check
            // delivered notifications (still visible in the tray) so their categories aren't
            // pruned before the user has a chance to tap an answer.
            self.center.getDeliveredNotifications { delivered in
                let deliveredCategoryIDs: Set<String> = Set(
                    delivered.compactMap { n -> String? in
                        let id = n.request.content.categoryIdentifier
                        return id.isEmpty ? nil : id
                    }
                )
                self.commitCategories(
                    addingNew: newCategories,
                    currentlyPending: pending,
                    deliveredCategoryIDs: deliveredCategoryIDs
                )

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
    }

    /// Returns the list of (slot, date) delivery times we want to keep queued.
    /// Production: 7 future noon + 7 future evening dates. Test mode: alternating slots every N minutes.
    private func upcomingCandidates(now: Date) -> [(Slot, Date)] {
        let calendar = Calendar.current

        if let interval = self.testModeIntervalMinutes {
            let intervalSeconds = TimeInterval(interval * 60)
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

        // Production: noon (12:00) and evening (18:00) in the user's local timezone.
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

    /// Rebuilds the registered category set, keeping only categories whose notification is still
    /// pending or visible in the tray, plus any newly created ones. Prevents unbounded growth.
    private func commitCategories(
        addingNew newCategories: [UNNotificationCategory],
        currentlyPending pending: [UNNotificationRequest],
        deliveredCategoryIDs: Set<String> = []
    ) {
        let pendingCategoryIDs: Set<String> = Set(
            pending.compactMap { req -> String? in
                let id = req.content.categoryIdentifier
                return id.isEmpty ? nil : id
            }
        )
        // A category is "live" if its notification is pending OR still sitting in the tray.
        let liveCategoryIDs = pendingCategoryIDs.union(deliveredCategoryIDs)
        let newCategoryIDs = Set(newCategories.map(\.identifier))

        center.getNotificationCategories { [weak self] existing in
            guard let self else { return }
            var merged = Set<UNNotificationCategory>()
            for c in existing {
                let id = c.identifier
                if id.hasPrefix("question-cat-") {
                    if liveCategoryIDs.contains(id) || newCategoryIDs.contains(id) {
                        merged.insert(c)
                    }
                    continue
                }
                if id.hasPrefix("practice-cat-") {
                    if liveCategoryIDs.contains(id) {
                        merged.insert(c)
                    }
                    continue
                }
                merged.insert(c)
            }
            for c in newCategories {
                merged = Set(merged.filter { $0.identifier != c.identifier })
                merged.insert(c)
            }
            self.center.setNotificationCategories(merged)
        }
    }

    // MARK: - Request Builder

    /// Creates a question notification, its paired expiration notification, and the category
    /// that holds the answer choice buttons — all tied to the same delivery date.
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

    // MARK: - Expiration Cancellation

    /// Cancels the pending expiration notification once the user has answered.
    func cancelExpirationNotification(slot: Slot, deliveredAt: Date) {
        center.removePendingNotificationRequests(
            withIdentifiers: [NotifID.expiration(slot: slot, date: deliveredAt)]
        )
    }

    // MARK: - Result Notification

    /// Fires an immediate result notification after an answer is evaluated.
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
