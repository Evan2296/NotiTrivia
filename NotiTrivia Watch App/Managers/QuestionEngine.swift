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

    /// Picks a question from the lowest-used pool at random, without incrementing the usage count.
    /// Used for practice so the real question rotation (managed server-side) is unaffected.
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

        // Passive fallback — returns .expired if the server push never arrived
        // (e.g. device was offline for the full window) and the user taps the question.
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
