import Foundation

final class AnswerReportingManager {

    static let shared = AnswerReportingManager()

    private init() {}

    // MARK: - Answer Reporting

    /// POSTs the answered slot identifier to the Supabase mark-answered endpoint
    /// so the server knows not to send an expiration push for that question.
    func reportAnswer(slot: String) {
        guard let url = URL(string: "https://hzlrqxcxcgdvocfaiuof.supabase.co/functions/v1/mark-answered") else {
            print("[AnswerReportingManager] Invalid mark-answered URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NjUyNzEsImV4cCI6MjA5MzU0MTI3MX0.EajIDeBgXAPJEsB58D0CtoY85LGxK34CbfxN1wFwySo", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NjUyNzEsImV4cCI6MjA5MzU0MTI3MX0.EajIDeBgXAPJEsB58D0CtoY85LGxK34CbfxN1wFwySo", forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "slot": slot
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            print("[AnswerReportingManager] Failed to encode request body")
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("[AnswerReportingManager] Report failed: \(error)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[AnswerReportingManager] Report response: \(httpResponse.statusCode)")
            }
        }.resume()
    }
}
