import SwiftUI

struct HelpView: View {

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
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {

                Text("How to Play")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(numberGradient)

                Text("Two questions daily, noon & 6 PM. Answer correctly in the notification within an hour to grow your streak and gain a life. Wrong or missed costs a life. Lose all 3 and your streak resets.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

#Preview {
    HelpView()
}
