import Foundation

// Models in this file are JSON-encoded by StateStore on a background queue.
// `nonisolated` keeps their Codable conformances accessible from any context
// under Swift 6's strict concurrency model.

nonisolated enum Slot: String, Codable {
    case noon
    case evening
}

nonisolated enum Outcome: String, Codable {
    case correct
    case incorrect
    case expired
}

nonisolated enum QuestionStatus: Codable {

    case active
    case answered(Outcome)
    case expired

    private enum CodingKeys: String, CodingKey {
        case type
        case outcome
    }

    private enum StatusType: String, Codable {
        case active
        case answered
        case expired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(StatusType.self, forKey: .type)

        switch type {
        case .active:
            self = .active
        case .answered:
            let outcome = try container.decode(Outcome.self, forKey: .outcome)
            self = .answered(outcome)
        case .expired:
            self = .expired
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .active:
            try container.encode(StatusType.active, forKey: .type)
        case .answered(let outcome):
            try container.encode(StatusType.answered, forKey: .type)
            try container.encode(outcome, forKey: .outcome)
        case .expired:
            try container.encode(StatusType.expired, forKey: .type)
        }
    }
}

nonisolated struct QuestionState: Codable {
    let questionID: String
    let slot: Slot
    let deliveredAt: Date
    let correctAnswer: String
    var status: QuestionStatus
}
