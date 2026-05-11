# NotiTrivia

A watchOS app that delivers trivia questions as push notifications and tracks your answer streak.

Questions are sent twice a day by a Supabase backend. The watch UI shows current streak, best streak, lives remaining, and a button to send a practice question on demand. Correct/incorrect evaluation and streak management run entirely on-device.

Requires watchOS 10.6 and Xcode 26 or later.

---

### Architecture

**Backend — Supabase (hzlrqxcxcgdvocfaiuof.supabase.co)**

- **`send-questions` Edge Function** — delivers trivia push notifications to all registered devices. Triggered by a cron job at noon and 6 pm Eastern.
- **`send-expirations` Edge Function** — sends a silent background push (`content-available: 1`) to all devices after the 1-hour answer window closes (cron fires 1 hour after each question push). The push carries `isExpiration: true`, the `slot`, and the `correctAnswer`.

**On-device**

- `AppDelegate.didReceiveRemoteNotification` handles both silent push types:
  1. **Expiration push** — marks the question expired, updates the streak and lives, and fires a local result notification.
  2. **Silent prep push** — pre-registers the stable `question_category` with real answer-choice titles so watchOS can render action buttons when the visible notification arrives.
- `QuestionEngine` contains a time-based fallback (1-hour check in `evaluate()`) that only triggers if the server expiration push never arrived (e.g. device was offline).
- Practice question expirations are handled locally via `NotificationActionHandler`.

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

Version 1.2.5
