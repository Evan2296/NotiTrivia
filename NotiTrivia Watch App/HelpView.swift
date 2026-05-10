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
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 10) {
                Text("How to Play")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(numberGradient)

                Text("Two questions arrive each day, at noon and 6 PM. Tap your answer in the notification within one hour or it counts as a miss. Wrong answers and misses cost a life. Lose all 3 and your streak resets, then your lives refill. Correct answers restore one life.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black)
    }
}

#Preview {
    HelpView()
}
