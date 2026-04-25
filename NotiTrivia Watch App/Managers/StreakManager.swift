import Foundation

final class StreakManager {
    static let shared = StreakManager()

    private let store = StateStore.shared

    private init() {}

    /// Applies streak logic for the given outcome and persists the result.
    func handleOutcome(_ outcome: Outcome) {
        var streak = store.loadStreak()

        switch outcome {
        case .correct:
            streak.currentStreak += 1
        case .incorrect, .expired:
            streak.currentStreak = 0
        }

        store.saveStreak(streak)
    }

    /// Returns the current streak count.
    func currentStreak() -> Int {
        store.loadStreak().currentStreak
    }
}
