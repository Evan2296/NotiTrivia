import Foundation

extension Notification.Name {
    /// Posted by NotificationActionHandler after any outcome is applied (correct/incorrect/expired).
    static let streakDidChange = Notification.Name("streakDidChange")
}
