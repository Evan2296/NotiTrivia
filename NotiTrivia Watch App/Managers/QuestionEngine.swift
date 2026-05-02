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

    /// Picks a question from the lowest-used pool at random and increments its usage count.
    /// Use this when scheduling real questions so repeated picks are avoided.
    @discardableResult
    func selectAndReserve() -> Question? {
        guard !questions.isEmpty else { return nil }

        var usageMap = store.loadUsageMap()

        let minCount = questions
            .map { usageMap[$0.id] ?? $0.times_used }
            .min() ?? 0

        let pool = questions.filter { (usageMap[$0.id] ?? $0.times_used) == minCount }
        guard let question = pool.randomElement() else { return nil }

        usageMap[question.id] = (usageMap[question.id] ?? question.times_used) + 1
        store.saveUsageMap(usageMap)

        return question
    }

    /// Picks a question from the lowest-used pool WITHOUT incrementing the usage count.
    /// Used for practice so the real question rotation is unaffected.
    func selectWithoutReserving() -> Question? {
        guard !questions.isEmpty else { return nil }

        let usageMap = store.loadUsageMap()

        let minCount = questions
            .map { usageMap[$0.id] ?? $0.times_used }
            .min() ?? 0

        let pool = questions.filter { (usageMap[$0.id] ?? $0.times_used) == minCount }
        return pool.randomElement()
    }

    // MARK: - Activation

    /// Writes QuestionState for a slot from the notification's userInfo payload.
    /// Called when a question notification is received (foreground or via tap).
    func activateQuestion(from userInfo: [AnyHashable: Any]) {
        guard
            let slotRaw = userInfo["slot"] as? String,
            let slot = Slot(rawValue: slotRaw),
            let questionID = userInfo["questionID"] as? String,
            let correctAnswer = userInfo["correctAnswer"] as? String,
            let deliveredAtInterval = userInfo["deliveredAt"] as? TimeInterval
        else { return }

        let deliveredAt = Date(timeIntervalSince1970: deliveredAtInterval)

        // Skip if this question is already active for this slot (idempotent).
        if let existing = store.loadActiveQuestion(slot: slot),
           existing.questionID == questionID {
            return
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

    /// Evaluates the user's answer for the given slot.
    /// Returns nil if the question has already been answered or expired (caller re-shows the result).
    func evaluate(answer: String, slot: Slot) -> Outcome? {
        guard let state = store.loadActiveQuestion(slot: slot) else { return nil }

        switch state.status {
        case .answered, .expired:
            return nil
        case .active:
            break
        }

        // If the 1-hour window passed while the app was closed, treat it as expired.
        if Date() > state.deliveredAt.addingTimeInterval(3600) {
            return .expired
        }

        return answer == state.correctAnswer ? .correct : .incorrect
    }

    /// Returns the current QuestionState for a slot (used to re-show a resolved result).
    func currentState(slot: Slot) -> QuestionState? {
        store.loadActiveQuestion(slot: slot)
    }
}
