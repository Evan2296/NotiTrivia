---

# 📄 notification_system.md (UPDATED)

```markdown
# Notification System

## Schedule
- Two notifications per day:
  - 12:00 PM (local time)
  - 6:00 PM (local time)
- Scheduling is fixed in v1 and not user-configurable

---

## Notification Content

### Question Notification
Each notification includes:
- Full trivia question
- Answer options:
  - Multiple choice (max 4 buttons)
  - OR True / False buttons

---

## Interaction Model
- User responds directly within notification
- No app launch required
- Only first valid response is accepted per question
- Subsequent interactions are ignored (idempotent behavior)

---

## Question Lifecycle State

Each question has a lifecycle:

1. Delivered
2. Active (valid window)
3. Expired
4. Evaluated (correct / incorrect / expired)

---

## Validity Window
- Questions are valid for 1 hour from delivery timestamp

### Within 1 Hour
- Response is accepted and evaluated normally

### After 1 Hour
- Question is marked expired
- Responses are ignored for scoring

---

## Expired Behavior
When a question expires:
- Result notification is sent:
  - "Time expired"
  - Correct answer shown
  - Streak reset

---

## Answer Handling

### Correct Answer
- Immediate result notification:
  - "Correct"
  - Updated streak shown (e.g., 🔥 Streak: 5)

### Incorrect Answer
- Immediate result notification:
  - "Incorrect"
  - Correct answer displayed
  - Streak reset

### Expired Answer
- Immediate result notification:
  - "Time expired"
  - Correct answer displayed
  - Streak reset

---

## Result Notification Timing
- Sent immediately after response event
- No artificial delay

---

## Multiple Notification Handling
- Noon and 6 PM notifications operate independently
- No queueing or dependency between questions

---

## Notification Lifecycle Rules
- Notifications are not updated after delivery
- Expiration is handled via timestamp logic, not UI mutation

---

## Constraints
- Maximum 4 answer buttons per notification
- Must remain readable on Apple Watch glance view
- Questions are optimized for short-form display
