import Foundation

final class StateStore {
    static let shared = StateStore()

    private let defaults = UserDefaults.standard
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // Concurrent queue allows simultaneous reads; writes use a barrier for exclusive access.
    private let queue = DispatchQueue(label: "com.notitrivia.statestore", attributes: .concurrent)

    private init() {}

    private func questionKey(for slot: Slot) -> String {
        "activeQuestion-\(slot.rawValue)"
    }

    // MARK: - Active Question

    func saveActiveQuestion(_ state: QuestionState, slot: Slot) {
        guard let data = try? encoder.encode(state) else { return }
        queue.async(flags: .barrier) { [weak self] in
            self?.defaults.set(data, forKey: self?.questionKey(for: slot) ?? "")
        }
    }

    func loadActiveQuestion(slot: Slot) -> QuestionState? {
        queue.sync {
            guard let data = defaults.data(forKey: questionKey(for: slot)) else { return nil }
            return try? decoder.decode(QuestionState.self, from: data)
        }
    }

    func markAnswered(slot: Slot, outcome: Outcome) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard let data = defaults.data(forKey: questionKey(for: slot)),
                  var state = try? decoder.decode(QuestionState.self, from: data) else { return }
            state.status = .answered(outcome)
            guard let updated = try? encoder.encode(state) else { return }
            defaults.set(updated, forKey: questionKey(for: slot))
        }
    }

    func markExpired(slot: Slot) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard let data = defaults.data(forKey: questionKey(for: slot)),
                  var state = try? decoder.decode(QuestionState.self, from: data) else { return }
            state.status = .expired
            guard let updated = try? encoder.encode(state) else { return }
            defaults.set(updated, forKey: questionKey(for: slot))
        }
    }

    // MARK: - Streak

    func saveStreak(_ streak: StreakState) {
        guard let data = try? encoder.encode(streak) else { return }
        queue.async(flags: .barrier) { [weak self] in
            self?.defaults.set(data, forKey: "streakState")
        }
    }

    func loadStreak() -> StreakState {
        queue.sync {
            guard let data = defaults.data(forKey: "streakState"),
                  let streak = try? decoder.decode(StreakState.self, from: data) else {
                return .initial
            }
            return streak
        }
    }

    // MARK: - Usage Map

    func loadUsageMap() -> [String: Int] {
        queue.sync {
            guard let data = defaults.data(forKey: "usageMap"),
                  let map = try? decoder.decode([String: Int].self, from: data) else {
                return [:]
            }
            return map
        }
    }

    func saveUsageMap(_ map: [String: Int]) {
        guard let data = try? encoder.encode(map) else { return }
        queue.async(flags: .barrier) { [weak self] in
            self?.defaults.set(data, forKey: "usageMap")
        }
    }
}
