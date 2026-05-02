import SwiftUI
import UserNotifications
import WatchKit

struct ContentView: View {

    @State private var streak: Int = 0
    @State private var scheduledCount: Int = 0
    @State private var testButtonState: TestButtonState = .idle

    private enum TestButtonState {
        case idle, sending, sent, failed
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {

                // MARK: - Header
                Text("NotiTrivia")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Divider()

                // MARK: - Streak
                VStack(spacing: 4) {
                    Text("🔥 Streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(streak)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }

                Divider()

                // MARK: - Practice Question Button
                Button {
                    sendTest()
                } label: {
                    HStack(spacing: 6) {
                        switch testButtonState {
                        case .idle:
                            Image(systemName: "bell.badge")
                            Text("Practice Question")
                        case .sending:
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.7)
                            Text("Sending…")
                        case .sent:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Sent!")
                        case .failed:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text("Failed")
                        }
                    }
                    .font(.footnote)
                }
                .buttonStyle(.borderedProminent)
                .tint(testButtonState == .sent ? .green : .blue)
                .disabled(testButtonState == .sending)

            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .onAppear { refresh() }
        // Refresh when app comes back to foreground
        .onReceive(NotificationCenter.default.publisher(for: WKExtension.applicationDidBecomeActiveNotification)) { _ in
            refresh()
        }
        // Refresh streak immediately after an answer is processed
        .onReceive(NotificationCenter.default.publisher(for: .streakDidChange)) { _ in
            DispatchQueue.main.async { streak = StreakManager.shared.currentStreak() }
        }
    }

    // MARK: - Actions

    private func refresh() {
        streak = StreakManager.shared.currentStreak()
        loadScheduledCount()
    }

    private func loadScheduledCount() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let count = requests.filter { $0.identifier.hasPrefix("question-") }.count
            DispatchQueue.main.async {
                scheduledCount = count
            }
        }
    }

    private func sendTest() {
        testButtonState = .sending
        NotificationManager.shared.sendTestNotification { success in
            DispatchQueue.main.async {
                testButtonState = success ? .sent : .failed
                // Reset button after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    testButtonState = .idle
                    refresh()
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
