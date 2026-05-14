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
        // sync write for durability: guarantees question state is persisted before this
        // function returns, so a watchOS process suspension immediately after activateQuestion
        // cannot silently drop the state and leave the question unrecoverable.
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

    func markAnswered(slot: Slot, outcome: Outcome) {
        // sync write: guarantees the state is committed before this function returns,
        // so any subsequent loadActiveQuestion call (e.g. in handleExpirationDelivery)
        // will always see the up-to-date .answered status and not let a server-sent
        // expiration push slip through the race window.
        //
        // The .active guard makes the read-check-write atomic within the barrier,
        // preventing an expiration that already committed from being overwritten.
        queue.sync(flags: .barrier) {
            guard let data = defaults.data(forKey: questionKey(for: slot)),
                  var state = try? decoder.decode(QuestionState.self, from: data) else { return }
            guard case .active = state.status else { return }
            state.status = .answered(outcome)
            guard let updated = try? encoder.encode(state) else { return }
            defaults.set(updated, forKey: questionKey(for: slot))
        }
    }

    func markExpired(slot: Slot) {
        // The .active guard makes the read-check-write atomic within the barrier,
        // closing the TOCTOU window: if markAnswered already committed its write
        // between handleExpirationDelivery's loadActiveQuestion and this call,
        // we bail out instead of clobbering the answered state.
        queue.sync(flags: .barrier) {
            guard let data = defaults.data(forKey: questionKey(for: slot)),
                  var state = try? decoder.decode(QuestionState.self, from: data) else { return }
            guard case .active = state.status else { return }
            state.status = .expired
            guard let updated = try? encoder.encode(state) else { return }
            defaults.set(updated, forKey: questionKey(for: slot))
        }
    }

    // MARK: - Streak

    func saveStreak(_ streak: StreakState) {
        guard let data = try? encoder.encode(streak) else { return }
        // sync write for durability parity with markAnswered/markExpired:
        // guarantees the streak is persisted before the caller returns,
        // so a watchOS process suspension immediately after handleOutcome
        // cannot silently drop the update.
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
