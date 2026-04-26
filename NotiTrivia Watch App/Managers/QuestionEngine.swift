import Foundation

final class QuestionEngine {
    static let shared = QuestionEngine()

    private var questions: [Question] = []
    private let store = StateStore.shared

    private init() {
        loadQuestions()
    }

    // MARK: - Load

    private func loadQuestions() {
        guard let url = Bundle.main.url(forResource: "FinalizedQuestions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Question].self, from: data) else {
            return
        }
        questions = decoded
    }

    // MARK: - Selection

    /// Picks a question from the lowest times_used pool at random and increments its usage count.
    /// Does NOT write QuestionState — that happens at delivery time via activateQuestion().
    @discardableResult
    func selectAndReserve() -> Question? {
        guard !questions.isEmpty else { return nil }

        var usageMap = store.loadUsageMap()

        let minCount = questions
            .map { usageMap[$0.id] ?? $0.times_used }
            .min() ?? 0

        let pool = questions.filter { (usageMap[$0.id] ?? $0.times_used) == minCount }
        guard let question = pool.randomElement() else { return nil }

        // Increment usage immediately so the next call won't pick the same question
        usageMap[question.id] = (usageMap[question.id] ?? question.times_used) + 1
        store.saveUsageMap(usageMap)

        return question
    }

    /// Picks a question from the lowest times_used pool at random WITHOUT incrementing usage.
    /// Used for practice questions so they don't consume from the real question rotation.
    func selectWithoutReserving() -> Question? {
        guard !questions.isEmpty else { return nil }

        let usageMap = store.loadUsageMap()

        let minCount = questions
            .map { usageMap[$0.id] ?? $0.times_used }
            .min() ?? 0

        let pool = questions.filter { (usageMap[$0.id] ?? $0.times_used) == minCount }
        return pool.randomElement()
    }

    // MARK: - Activation (called at delivery time)

    /// Writes QuestionState for a slot from the notification's userInfo payload.
    /// Called by NotificationActionHandler when a question notification is received.
    func activateQuestion(from userInfo: [AnyHashable: Any]) {
        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw),
            let questionID = userInfo["questionID"] as? String,
            let correctAnswer = userInfo["correctAnswer"] as? String,
            let deliveredAtInterval = userInfo["deliveredAt"] as? TimeInterval
        else { return }

        let deliveredAt = Date(timeIntervalSince1970: deliveredAtInterval)

        // Only activate if there's no existing active state for this slot,
        // or if the existing state is for a different question (stale from a previous day).
        if let existing = store.loadActiveQuestion(slot: slot),
           existing.questionID == questionID {
            return // Already activated — idempotent
        }

        let state = QuestionState(
            questionID: questionID,
            slot: slot,
            deliveredAt: deliveredAt,
            correctAnswer: correctAnswer,
            status: .active
        )
        store.saveActiveQuestion(state, slot: slot)
    }

    // MARK: - Evaluation

    /// Evaluates a user's answer for a given slot.
    /// - Returns: The Outcome if the question was active, or nil if already answered/expired (idempotent).
    func evaluate(answer: String, slot: Slot) -> Outcome? {
        guard let state = store.loadActiveQuestion(slot: slot) else { return nil }

        switch state.status {
        case .answered, .expired:
            // Already resolved — caller re-shows result
            return nil
        case .active:
            break
        }

        // Check validity window
        if Date() > state.deliveredAt.addingTimeInterval(3600) {
            // Expired while app was closed — return .expired so the caller handles
            // state mutation and result notification consistently via applyOutcome().
            return .expired
        }

        return answer == state.correctAnswer ? .correct : .incorrect
    }

    /// Returns the current QuestionState for a slot (used for re-showing results).
    func currentState(slot: Slot) -> QuestionState? {
        store.loadActiveQuestion(slot: slot)
    }
}
