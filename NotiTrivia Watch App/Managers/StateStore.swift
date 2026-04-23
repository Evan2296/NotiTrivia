import Foundation

final class StateStore {
    static let shared = StateStore()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {}

    private func questionKey(for slot: Slot) -> String {
        "activeQuestion-\(slot.rawValue)"
    }

    func saveActiveQuestion(_ state: QuestionState, slot: Slot) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: questionKey(for: slot))
    }

    func loadActiveQuestion(slot: Slot) -> QuestionState? {
        guard let data = defaults.data(forKey: questionKey(for: slot)) else { return nil }
        return try? decoder.decode(QuestionState.self, from: data)
    }

    func markAnswered(slot: Slot, outcome: Outcome) {
        guard var state = loadActiveQuestion(slot: slot) else { return }
        state.status = .answered(outcome)
        saveActiveQuestion(state, slot: slot)
    }

    func markExpired(slot: Slot) {
        guard var state = loadActiveQuestion(slot: slot) else { return }
        state.status = .expired
        saveActiveQuestion(state, slot: slot)
    }

    func saveStreak(_ streak: StreakState) {
        guard let data = try? encoder.encode(streak) else { return }
        defaults.set(data, forKey: "streakState")
    }

    func loadStreak() -> StreakState {
        guard let data = defaults.data(forKey: "streakState"),
              let streak = try? decoder.decode(StreakState.self, from: data) else {
            return .initial
        }
        return streak
    }

    // MARK: - Usage Map

    func loadUsageMap() -> [String: Int] {
        guard let data = defaults.data(forKey: "usageMap"),
              let map = try? decoder.decode([String: Int].self, from: data) else {
            return [:]
        }
        return map
    }

    func saveUsageMap(_ map: [String: Int]) {
        guard let data = try? encoder.encode(map) else { return }
        defaults.set(data, forKey: "usageMap")
    }
}
