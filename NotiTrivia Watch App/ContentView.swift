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
    @State private var lives: Int = 3
    @State private var testButtonState: TestButtonState = .idle
    @State private var showHelp: Bool = false
    @State private var livesGlowPhase: Bool = false

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

            // MARK: - Proportional layout constants (all derived from geo.size)
            // Tuned so every element stays in its correct corner on all watch sizes:
            // 40 mm (~162 × 197 pt), 44 mm (~184 × 224 pt),
            // 45 mm (~198 × 242 pt), Ultra (~205 × 251 pt).
            let w = geo.size.width
            let h = geo.size.height

            // Edge padding from screen border to the near edge of each corner element.
            // Slightly generous to compensate for the watch's curved-edge display glass
            // clipping corners that look fine in flat simulator screenshots.
            let cornerPad   = w * 0.086          // ≈ 14 pt on 40 mm (~6 pt extra vs flat sim)

            // Help button (top-left) — small circle with "?" icon
            let helpSize    = w * 0.148          // ≈ 24 pt on 40 mm
            let helpStroke  = w * 0.009          // ≈ 1.5 pt on 40 mm
            let helpFont    = w * 0.062          // ≈ 10 pt on 40 mm

            // Bolt / practice button (bottom-left) — larger circle with bolt icon
            let boltSize    = w * 0.222          // ≈ 36 pt on 40 mm
            let boltStroke  = w * 0.009          // ≈ 1.5 pt on 40 mm
            let boltFont    = w * 0.099          // ≈ 16 pt on 40 mm

            // Lives dots (bottom-right) — three small filled circles
            let dotSize     = w * 0.049          // ≈  8 pt on 40 mm
            let dotSpacing  = w * 0.025          // ≈  4 pt on 40 mm

            // Streak ring (center) — large gradient circle
            let ringDiam    = w * 0.630          // ≈ 102 pt on 40 mm
            let ringScale   = CGFloat(1.15)      // proportional scale applied on top
            let ringStroke  = w * 0.019          // ≈  3 pt crisp ring on 40 mm
            let glowStroke  = w * 0.049          // ≈  8 pt blurred glow on 40 mm
            let glowBlur    = w * 0.037          // ≈  6 pt blur radius on 40 mm

            // Font sizes inside the ring
            let labelFont   = w * 0.074          // ≈ 12 pt "Streak" label on 40 mm
            let numberFont  = w * 0.284          // ≈ 46 pt streak number on 40 mm
            let bestFont    = w * 0.062          // ≈ 10 pt "Best:" line on 40 mm

            // Derived centre positions for each corner element
            // (.position() pins the view's centre, so we offset by half the element size)
            let helpX   = cornerPad + helpSize / 2
            let helpY   = cornerPad + helpSize / 2

            let boltX   = cornerPad + boltSize / 2
            let boltY   = h - cornerPad - boltSize / 2

            // Lives HStack total width = 3 dots + 2 gaps
            let livesW  = dotSize * 3 + dotSpacing * 2
            let livesX  = w - cornerPad - livesW / 2
            let livesY  = h - cornerPad - dotSize / 2

            ZStack {
                Color.black.ignoresSafeArea()

                // MARK: - Gradient ring (centred on screen)
                ZStack {
                    // Blurred glow layer
                    Circle()
                        .stroke(ringGradient, lineWidth: glowStroke)
                        .frame(width: ringDiam, height: ringDiam)
                        .blur(radius: glowBlur)
                        .opacity(0.45)

                    // Crisp ring
                    Circle()
                        .stroke(ringGradient, lineWidth: ringStroke)
                        .frame(width: ringDiam, height: ringDiam)

                    // "Streak" label + number + best streak all inside the ring
                    VStack(spacing: 0) {
                        Text("Streak")
                            .font(.system(size: labelFont, weight: .semibold))
                            .foregroundStyle(numberGradient)
                        Text("\(streak)")
                            .font(.system(size: numberFont, weight: .bold, design: .rounded))
                            .foregroundStyle(numberGradient)
                            .offset(y: -2)
                        Text("Best: \(bestStreak)")
                            .font(.system(size: bestFont, weight: .regular))
                            .foregroundStyle(.white.opacity(0.62))
                            .offset(y: -4)
                            .opacity(bestStreak == 0 ? 0 : 1)
                    }
                }
                .scaleEffect(ringScale)
                .position(x: w / 2, y: h / 2)

                // MARK: - Help button pinned to top-left
                Button {
                    showHelp = true
                } label: {
                    ZStack {
                        // Gradient ring matching main ring style
                        Circle()
                            .stroke(ringGradient, lineWidth: helpStroke)
                            .frame(width: helpSize, height: helpSize)
                        Image(systemName: "questionmark")
                            .font(.system(size: helpFont, weight: .semibold))
                            .foregroundStyle(numberGradient)
                    }
                    .frame(width: helpSize, height: helpSize)
                }
                .buttonStyle(.borderless)
                .clipShape(Circle())
                .position(x: helpX, y: helpY)

                // MARK: - Lives indicator pinned to bottom-right
                // 3 solid circles: gradient fill = alive, near-black = lost
                HStack(spacing: dotSpacing) {
                    ForEach(0..<3, id: \.self) { i in
                        if i < lives {
                            // Active life: gradient fill with slow animated hue shift
                            Circle()
                                .fill(numberGradient)
                                .frame(width: dotSize, height: dotSize)
                                .hueRotation(.degrees(livesGlowPhase ? 25 : -25))
                        } else {
                            // Lost life: near-black fill + dim gradient stroke
                            Circle()
                                .fill(Color(white: 0.10))
                                .frame(width: dotSize, height: dotSize)
                                .overlay(
                                    Circle().stroke(numberGradient.opacity(0.28), lineWidth: 1)
                                )
                        }
                    }
                }
                .position(x: livesX, y: livesY)

                // MARK: - Practice button pinned to bottom-left
                Button {
                    sendTest()
                } label: {
                    ZStack {
                        // Gradient ring outline matching main ring style
                        Circle()
                            .stroke(ringGradient, lineWidth: boltStroke)
                            .frame(width: boltSize, height: boltSize)

                        Group {
                            switch testButtonState {
                            case .idle:
                                Image(systemName: "bolt")
                                    .font(.system(size: boltFont, weight: .semibold))
                                    .foregroundStyle(numberGradient)
                            case .sending:
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(0.70)
                                    .tint(Color(red: 1.00, green: 0.58, blue: 0.10))
                            case .sent:
                                Image(systemName: "checkmark")
                                    .font(.system(size: boltFont, weight: .semibold))
                                    .foregroundColor(.green)
                            case .failed:
                                Image(systemName: "xmark")
                                    .font(.system(size: boltFont, weight: .semibold))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .frame(width: boltSize, height: boltSize)
                }
                .buttonStyle(.borderless)
                .clipShape(Circle())
                .disabled(testButtonState == .sending)
                .position(x: boltX, y: boltY)
            }
        }
        .sheet(isPresented: $showHelp) { HelpView() }
        .ignoresSafeArea()
        .onAppear {
            refresh()
            if !livesGlowPhase {
                withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                    livesGlowPhase = true
                }
            }
        }
        // Refresh when app comes back to foreground
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { refresh() }
        }
        // Refresh streak immediately after an answer is processed
        .onReceive(NotificationCenter.default.publisher(for: .streakDidChange)) { _ in
            DispatchQueue.main.async {
                streak = StreakManager.shared.currentStreak()
                bestStreak = StreakManager.shared.bestStreak()
                lives = StreakManager.shared.currentLives()
            }
        }
    }

    // MARK: - Actions

    private func refresh() {
        // Run the expiration sweep before reading UI state so any missed expiration
        // is debited first — the streak ring reflects the correct values immediately.
        NotificationActionHandler.shared.reconcileExpiredQuestions()

        streak = StreakManager.shared.currentStreak()
        bestStreak = StreakManager.shared.bestStreak()
        lives = StreakManager.shared.currentLives()
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
