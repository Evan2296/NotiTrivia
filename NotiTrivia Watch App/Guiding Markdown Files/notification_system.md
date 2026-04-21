# Notification System

## Schedule
- Two notifications per day:
  - 12:00 PM (user's local time)
  - 6:00 PM (user's local time)
- Schedule is fixed and not user-configurable (v1)

## Notification Content

### Question Notification
Each notification includes:
- Full trivia question (fully readable)
- Answer options:
  - Multiple choice (max 4 buttons)
  - OR True / False buttons

### Interaction Model
- User answers directly within notification
- No app launch required
- Only the first answer is accepted
- Subsequent taps are ignored

## Validity Window
- Each question is valid for 1 hour from delivery timestamp

### Within 1 Hour
- Answer is accepted
- Evaluated normally

### After 1 Hour
- Question is expired
- Any interaction:
  - Does NOT count as an answer
  - Triggers expired response

## Expired Behavior
- Result notification is sent:
  - Message: "Time expired"
  - Correct answer is shown
  - Streak is reset

## Answer Handling

### Correct Answer
- Send immediate result notification:
  - "Correct"
  - Display updated streak (e.g., 🔥 Streak: 5)

### Incorrect Answer
- Send immediate result notification:
  - "Incorrect"
  - Show correct answer
  - Streak reset

### Expired Answer
- Send immediate result notification:
  - "Time expired"
  - Show correct answer
  - Streak reset

## Result Notification Timing
- Sent immediately after answer interaction
- No artificial delay

## Multiple Notification Handling
- Notifications are independent
- 6 PM notification is sent regardless of noon result
- No queuing or blocking logic

## Notification Lifecycle
- Notifications are NOT removed or modified after delivery
- Expiration is handled via logic, not UI removal

## Constraints
- Max 4 answer buttons
- Text must remain concise and readable on watch
- Avoid long questions (optimize during content processing)

## Future Considerations
- User-configurable frequency
- Adaptive scheduling
- Richer feedback (explanations)