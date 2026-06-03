import Foundation

final class AnswerReportingManager {

    static let shared = AnswerReportingManager()

    private init() {}

    // MARK: - Answer Reporting

    /// POSTs a timezone-qualified slot key to the Supabase mark-answered endpoint
    /// so the server knows not to send an expiration push for that question.
    ///
    /// The slot key is `"<slotName>_<utcHour>"` (e.g. `"noon_16"`), matching the row
    /// that send-questions wrote into `active_questions` when it delivered the push.
    /// The UTC hour is derived from `deliveredAt` — the Unix timestamp embedded in the
    /// original push payload — so it is always consistent with the server-side key.
    ///
    /// `completion` is called once the network response (or error) is received —
    /// callers should pass the notification `completionHandler` here so watchOS
    /// keeps the extension alive until the HTTP request actually finishes.
    func reportAnswer(slot: String, deliveredAt: Date, completion: @escaping () -> Void = {}) {
        // Derive the UTC hour from the delivery timestamp to build the qualified slot key.
        // Formula: (secondsSinceEpoch / 3600) % 24  →  0..23 UTC hour.
        let utcHour = Int(deliveredAt.timeIntervalSince1970) / 3600 % 24
        let qualifiedSlot = "\(slot)_\(utcHour)"

        guard let url = URL(string: "https://hzlrqxcxcgdvocfaiuof.supabase.co/functions/v1/mark-answered") else {
            print("[AnswerReportingManager] Invalid mark-answered URL")
            completion()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NjUyNzEsImV4cCI6MjA5MzU0MTI3MX0.EajIDeBgXAPJEsB58D0CtoY85LGxK34CbfxN1wFwySo", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NjUyNzEsImV4cCI6MjA5MzU0MTI3MX0.EajIDeBgXAPJEsB58D0CtoY85LGxK34CbfxN1wFwySo", forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "slot": qualifiedSlot
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            print("[AnswerReportingManager] Failed to encode request body")
            completion()
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { _, response, error in
            defer { completion() }
            if let error {
                print("[AnswerReportingManager] Report failed: \(error)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[AnswerReportingManager] Report response: \(httpResponse.statusCode) slot=\(qualifiedSlot)")
            }
        }.resume()
    }
}
