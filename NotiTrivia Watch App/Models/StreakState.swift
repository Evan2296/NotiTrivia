import Foundation

nonisolated struct StreakState: Codable {
    var currentStreak: Int
    var bestStreak: Int
    var lives: Int

    /// Returns a fresh `StreakState` for a first-launch or post-reset scenario.
    static var initial: StreakState {
        StreakState(currentStreak: 0, bestStreak: 0, lives: 3)
    }

    /// Custom decoder for backwards compatibility:
    /// existing saves won't have a `lives` key — defaults to 3 if the key is absent.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentStreak = try container.decode(Int.self, forKey: .currentStreak)
        bestStreak    = try container.decode(Int.self, forKey: .bestStreak)
        lives         = (try? container.decode(Int.self, forKey: .lives)) ?? 3
    }

    init(currentStreak: Int, bestStreak: Int, lives: Int) {
        self.currentStreak = currentStreak
        self.bestStreak    = bestStreak
        self.lives         = lives
    }
}
