import SwiftUI
import UserNotifications

// MARK: - Hex Color Helper
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8)  & 0xFF) / 255
        let b = Double( int        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

struct ContentView: View {

    @Environment(\.scenePhase) private var scenePhase

    @State private var streak: Int = 0
    @State private var bestStreak: Int = 0
    @State private var testButtonState: TestButtonState = .idle

    private enum TestButtonState {
        case idle, sending, sent, failed
    }

    // Angular ring gradient: orange → golden → pink → purple → blue, wraps seamlessly
    private let ringGradient = AngularGradient(
        colors: [
            Color(red: 1.00, green: 0.45, blue: 0.05),  // vivid orange
            Color(red: 1.00, green: 0.60, blue: 0.12),  // golden orange
            Color(red: 0.99, green: 0.50, blue: 0.35),  // warm coral
            Color(red: 0.97, green: 0.40, blue: 0.55),  // coral pink
            Color(red: 0.85, green: 0.28, blue: 0.80),  // magenta-purple
            Color(red: 0.58, green: 0.28, blue: 0.95),  // vivid purple
            Color(red: 0.38, green: 0.35, blue: 1.00),  // blue-purple
            Color(red: 0.28, green: 0.48, blue: 1.00),  // blue
            Color(red: 1.00, green: 0.45, blue: 0.05),  // back to orange (seamless)
        ],
        center: .center,
        startAngle: .degrees(-90),
        endAngle: .degrees(270)
    )

    // Number fill gradient: warm orange top → pink mid → purple bottom
    private let numberGradient = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.58, blue: 0.10),  // orange-amber
            Color(red: 0.97, green: 0.44, blue: 0.55),  // pink
            Color(red: 0.72, green: 0.30, blue: 0.88),  // purple
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    var body: some View {
        // GeometryReader gives us real screen pixel dimensions, bypassing watchOS
        // safe-area layout frame quirks that break overlay/ZStack alignment anchors.
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                // MARK: - Gradient ring (circle center pinned to top of screen)
                // .position() sets the CENTER of the view, so y = topPad(10) + radius(51) = 61
                ZStack {
                    // Blurred glow layer
                    Circle()
                        .stroke(ringGradient, lineWidth: 8)
                        .frame(width: 102, height: 102)
                        .blur(radius: 6)
                        .opacity(0.45)

                    // Crisp ring
                    Circle()
                        .stroke(ringGradient, lineWidth: 3)
                        .frame(width: 102, height: 102)

                    // "Streak" label + number + best streak all inside the ring
                    VStack(spacing: 0) {
                        Text("Streak")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(numberGradient)
                        Text("\(streak)")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .foregroundStyle(numberGradient)
                            .offset(y: -2)
                        Text("Best: \(bestStreak)")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.62))
                            .offset(y: -4)
                    }
                }
                .scaleEffect(1.15)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // MARK: - Bell button pinned to bottom-left
                // .position() center: x = leading pad(8) + half button(18) = 26
                //                     y = height - bottom pad(8) - half button(18)
                Button {
                    sendTest()
                } label: {
                    Group {
                        switch testButtonState {
                        case .idle:
                            Image(systemName: "bell")
                                .font(.system(size: 16, weight: .semibold))
                        case .sending:
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.70)
                        case .sent:
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                        case .failed:
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.bordered)
                .tint(
                    testButtonState == .sent    ? .green  :
                    testButtonState == .failed  ? .red    : .blue
                )
                .clipShape(Circle())
                .disabled(testButtonState == .sending)
                .position(x: 26, y: geo.size.height - 26)
            }
        }
        .ignoresSafeArea()
        .onAppear { refresh() }
        // Refresh when app comes back to foreground
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refresh() }
        }
        // Refresh streak immediately after an answer is processed
        .onReceive(NotificationCenter.default.publisher(for: .streakDidChange)) { _ in
            DispatchQueue.main.async {
                streak = StreakManager.shared.currentStreak()
                bestStreak = StreakManager.shared.bestStreak()
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        streak = StreakManager.shared.currentStreak()
        bestStreak = StreakManager.shared.bestStreak()
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
