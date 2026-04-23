import Foundation

enum QuestionType: String, Codable {
    case multipleChoice = "multiple_choice"
    case trueFalse = "true_false"
}

struct Question: Codable {
    let id: String
    let question: String
    let choices: [String]
    let correct: String
    let type: QuestionType
    var times_used: Int
}
