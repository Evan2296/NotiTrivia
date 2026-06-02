# NotiTrivia

A watchOS app that delivers trivia questions as push notifications and tracks your answer streak.

Questions are sent twice a day by a Supabase backend. The watch UI shows current streak, best streak, lives remaining, and a button to send a practice question on demand. Correct/incorrect evaluation and streak management run entirely on-device.

Requires watchOS 10.6 and Xcode 26 or later.

---

### Architecture

**Backend — Supabase (hzlrqxcxcgdvocfaiuof.supabase.co)**

- **`send-questions` Edge Function** — delivers trivia push notifications to devices whose local time is currently **noon (12:00)** or **6 PM (18:00)**. Runs every hour via pg_cron (`0 * * * *`); reads each device's stored IANA timezone, computes local hour with `Intl.DateTimeFormat`, and only sends to qualifying devices. Each slot group independently picks one question. Sends two silent "prep" pushes over ~45 s to register a **unique per-question** category (`question_category_<questionID>`), then the visible question push whose `aps.category` matches that unique ID.
- **`send-expirations` Edge Function** — sends a "time's up" push to devices whose local time is currently **1 PM (13:00)** or **7 PM (19:00)** — exactly one hour after their delivery window. Also runs every hour (`0 * * * *`). The push carries `isExpiration: true`, the `slot`, and the `correctAnswer`.

**On-device**

- `AppDelegate.didReceiveRemoteNotification` handles both silent push types:
  1. **Expiration push** — marks the question expired, updates the streak and lives, and fires a local result notification.
  2. **Silent prep push** — registers the unique per-question category (`question_category_<questionID>`) with real answer-choice titles and purges any stale push-question categories, so watchOS renders the correct action buttons when the visible notification arrives.
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

Version 1.3.14

---


### Privacy Policy

**Last updated: May 2026**

NotiTrivia is a watchOS-only app with no iPhone companion app.

**What data is collected**

NotiTrivia collects two pieces of information when you first launch the app and grant notification permission:

- **APNs device token** — a unique identifier issued by Apple that allows the backend to deliver push notifications to your device.
- **Timezone string** — your device's current timezone (e.g. `America/New_York`), used to send trivia questions at the correct local time.

No names, email addresses, Apple IDs, location data, health data, or any other personal information are collected.

**Why it is collected**

The device token is required to deliver push notifications. Without it, no trivia questions can be sent. The timezone string is required to schedule those notifications at an appropriate time of day for you.

**How it is stored**

Both values are stored in a Supabase PostgreSQL database hosted at `hzlrqxcxcgdvocfaiuof.supabase.co`. Access is restricted to the Supabase Edge Functions that send notifications.

All streak data, lives, and gameplay state are stored locally on your device in `UserDefaults` and are never transmitted anywhere.

**How long it is retained**

Your device token and timezone are retained for as long as you have NotiTrivia installed. If you uninstall the app or revoke notification permissions, the token will stop working and can no longer be used to reach your device, though it may remain in the database until manually purged.

**Third-party sharing**

No data is shared with any third party. There are no analytics services, advertising networks, or third-party SDKs of any kind in this app.

**Contact**

For any privacy-related questions, open an issue on the [GitHub repository](https://github.com/Evan2296/NotiTrivia).
