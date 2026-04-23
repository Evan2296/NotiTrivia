import Foundation

struct StreakState: Codable {
    var currentStreak: Int
    var lastUpdated: Date

    static var initial: StreakState {
        StreakState(currentStreak: 0, lastUpdated: Date())
    }
}
