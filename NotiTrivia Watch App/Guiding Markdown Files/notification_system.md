# Notification System

## Architecture Constraints
- WatchOS-only application
- No backend (v1)
- All logic runs on-device
- All data stored locally on device
- All notifications are local notifications

---

## Schedule
- Two notifications per day:
  - 12:00 PM (local device time)
  - 6:00 PM (local device time)
- Scheduling is fixed in v1 and not user-configurable
- Notifications are scheduled using a repeating local notification system
- System must ensure notifications persist across device restarts
- App should schedule notifications on first launch and maintain them going forward

---

## Notification Content

### Question Notification
Each notification includes:
- Full trivia question
- Answer options:
  - Multiple choice (max 4 buttons)
  - OR True / False buttons (2 buttons)
- Each button maps directly to an answer string (no A/B/C/D abstraction)

---

## Interaction Model
- User responds directly within notification
- No app launch required
- Only first valid response is accepted per question
- Subsequent interactions are ignored (idempotent behavior)
- If user re-interacts after answering, system re-shows result

---

## Question Lifecycle State

Each question has a lifecycle:

1. Delivered
2. Active (valid window)
3. Expired
4. Evaluated (correct / incorrect / expired)

---

## Validity Window
- Questions are valid for 1 hour from **actual delivery timestamp**

### Within 1 Hour
- Response is accepted and evaluated normally
- Can increase or reset streak

### After 1 Hour
- Question is marked expired
- Responses:
  - Do NOT affect streak
  - Do NOT count as correct or incorrect
  - Trigger expired response behavior

---

## Expiration System

Expiration is handled via **timestamp comparison + scheduled expiration notification**

### Expiration Trigger
- A secondary local notification is scheduled at:
  - `delivery_time + 1 hour`

### Expired Behavior
When a question expires:
- A notification is sent:
  - "Time expired"
  - Correct answer shown
  - Streak reset

- This occurs:
  - Even if user never interacted with original notification

---

## Answer Handling

### Correct Answer (within valid window)
- Immediate result notification:
  - "Correct"
  - Updated streak shown (e.g., 🔥 Streak: 5)

### Incorrect Answer (within valid window)
- Immediate result notification:
  - "Incorrect"
  - Correct answer displayed
  - Streak reset

### Expired Answer (after valid window)
- Immediate result notification:
  - "Time expired"
  - Correct answer displayed
- No streak impact

---

## Result Notification Timing
- Sent immediately after response event
- No artificial delay

---

## Multiple Notification Handling
- Noon and 6 PM notifications operate independently
- No queueing or dependency between questions
- If noon question is unanswered:
  - It expires at 1:00 PM
  - 6 PM question still delivers normally
- User can interact with both independently

---

## Notification Lifecycle Rules
- Notifications are not updated after delivery
- Expiration is handled via timestamp logic and scheduled notification
- Only first interaction is processed
- Later interactions are ignored or re-show result

---

## Constraints
- Maximum 4 answer buttons per notification
- Must remain readable on Apple Watch glance view
- Questions are pre-validated for length and fit within UI constraints