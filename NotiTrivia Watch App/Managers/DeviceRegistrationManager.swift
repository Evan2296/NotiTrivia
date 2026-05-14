import Foundation

final class DeviceRegistrationManager {

    static let shared = DeviceRegistrationManager()

    private init() {}

    // MARK: - Token Registration

    /// Converts the APNs device token Data to a lowercase hex string, then POSTs it
    /// alongside the device's IANA timezone identifier to the Supabase registration endpoint.
    func registerDeviceToken(_ tokenData: Data) {
        let hexToken = tokenData.map { String(format: "%02x", $0) }.joined()
        let timezone = TimeZone.current.identifier

        guard let url = URL(string: "https://hzlrqxcxcgdvocfaiuof.supabase.co/functions/v1/register-device") else {
            print("[DeviceRegistrationManager] Invalid registration URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NjUyNzEsImV4cCI6MjA5MzU0MTI3MX0.EajIDeBgXAPJEsB58D0CtoY85LGxK34CbfxN1wFwySo", forHTTPHeaderField: "apikey")
        request.setValue("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh6bHJxeGN4Y2dkdm9jZmFpdW9mIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc5NjUyNzEsImV4cCI6MjA5MzU0MTI3MX0.EajIDeBgXAPJEsB58D0CtoY85LGxK34CbfxN1wFwySo", forHTTPHeaderField: "Authorization")

        let body: [String: String] = [
            "device_token": hexToken,
            "timezone": timezone
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            print("[DeviceRegistrationManager] Failed to encode request body")
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error {
                print("[DeviceRegistrationManager] Registration failed: \(error)")
                return
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("[DeviceRegistrationManager] Registration response: \(httpResponse.statusCode)")
            }
        }.resume()
    }
}
