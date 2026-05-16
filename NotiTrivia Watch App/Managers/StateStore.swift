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
        // Sync write ensures state is committed before returning, guarding against process suspension.
        let key = questionKey(for: slot)
        queue.sync(flags: .barrier) {
            defaults.set(data, forKey: key)
        }
    }

    func loadActiveQuestion(slot: Slot) -> QuestionState? {
        queue.sync {
            guard let data = defaults.data(forKey: questionKey(for: slot)) else { return nil }
            return try? decoder.decode(QuestionState.self, from: data)
        }
    }

    /// Transitions an .active question to .answered(outcome).
    /// Returns `true` if the transition happened, `false` if the state was already
    /// resolved — callers gate all side-effects on this result to prevent double debits
    /// from a racing expiration push.
    @discardableResult
    func markAnswered(slot: Slot, outcome: Outcome) -> Bool {
        // Sync barrier makes the read-check-write atomic, preventing a concurrent
        // expiration from overwriting a committed answer (and vice versa).
        var didTransition = false
        queue.sync(flags: .barrier) {
            guard let data = defaults.data(forKey: questionKey(for: slot)),
                  var state = try? decoder.decode(QuestionState.self, from: data) else { return }
            guard case .active = state.status else { return }
            state.status = .answered(outcome)
            guard let updated = try? encoder.encode(state) else { return }
            defaults.set(updated, forKey: questionKey(for: slot))
            didTransition = true
        }
        return didTransition
    }

    /// Transitions an .active question to .expired.
    /// Returns `true` if the transition happened — see `markAnswered` for rationale.
    @discardableResult
    func markExpired(slot: Slot) -> Bool {
        // Atomic barrier prevents clobbering a committed `markAnswered` write.
        var didTransition = false
        queue.sync(flags: .barrier) {
            guard let data = defaults.data(forKey: questionKey(for: slot)),
                  var state = try? decoder.decode(QuestionState.self, from: data) else { return }
            guard case .active = state.status else { return }
            state.status = .expired
            guard let updated = try? encoder.encode(state) else { return }
            defaults.set(updated, forKey: questionKey(for: slot))
            didTransition = true
        }
        return didTransition
    }

    // MARK: - Streak

    func saveStreak(_ streak: StreakState) {
        guard let data = try? encoder.encode(streak) else { return }
        // Sync write for durability parity with markAnswered/markExpired.
        queue.sync(flags: .barrier) {
            defaults.set(data, forKey: "streakState")
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
        queue.sync(flags: .barrier) {
            defaults.set(data, forKey: "usageMap")
        }
    }
}
