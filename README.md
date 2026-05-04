# NotiTrivia

A watchOS app that delivers trivia questions as local notifications and tracks your answer streak.

Questions are scheduled throughout the day and answered directly from the notification. The watch UI shows current streak, best streak, and a button to send a test notification on demand. Everything runs on-device with no backend.

Requires watchOS 10.6 and Xcode 26 or later.

---

### Structure

- `NotificationManager` schedules and sends notifications
- `QuestionEngine` selects questions from `FinalizedQuestions.json`
- `StreakManager` calculates and persists streak data
- `NotificationActionHandler` processes notification responses
- `StateStore` persists app state between sessions
- `ContentView` is the main watch UI

---

### Setup

Clone the repo, open `NotiTrivia.xcodeproj`, select the `NotiTrivia Watch App` scheme, and run on a watch or simulator.

Version 1.1.0
