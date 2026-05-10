import Foundation

final class StreakManager {
    static let shared = StreakManager()

    private let store = StateStore.shared

    private init() {}

    /// Applies streak and lives logic for the given outcome and persists the result.
    func handleOutcome(_ outcome: Outcome) {
        var streak = store.loadStreak()

        switch outcome {
        case .correct:
            streak.currentStreak += 1
            if streak.currentStreak > streak.bestStreak {
                streak.bestStreak = streak.currentStreak
            }
            // Restore one life on a correct answer, capped at 3.
            streak.lives = min(streak.lives + 1, 3)

        case .incorrect, .expired:
            streak.lives -= 1
            if streak.lives <= 0 {
                // No lives left — reset streak and give a fresh start.
                streak.currentStreak = 0
                streak.lives = 3
            }
        }

        store.saveStreak(streak)
    }

    /// Returns the current streak count.
    func currentStreak() -> Int {
        store.loadStreak().currentStreak
    }

    /// Returns the best streak count ever recorded.
    func bestStreak() -> Int {
        store.loadStreak().bestStreak
    }

    /// Returns the current number of lives remaining.
    func currentLives() -> Int {
        store.loadStreak().lives
    }
}
