import Foundation

struct StreakState: Codable {
    var currentStreak: Int

    static var initial: StreakState {
        StreakState(currentStreak: 0)
    }
}
