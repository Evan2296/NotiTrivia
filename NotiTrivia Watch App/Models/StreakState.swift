import Foundation

nonisolated struct StreakState: Codable {
    var currentStreak: Int
    var bestStreak: Int

    static var initial: StreakState {
        StreakState(currentStreak: 0, bestStreak: 0)
    }
}
