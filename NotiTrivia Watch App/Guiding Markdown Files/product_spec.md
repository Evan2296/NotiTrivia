# NotiTrivia – Product Specification

## Overview
NotiTrivia is a watchOS-only, notification-driven trivia application that delivers two daily trivia questions via Apple Watch notifications.

## Architecture
- WatchOS-only app (no iPhone companion required)
- No backend in v1
- Fully offline-capable
- All data stored locally on device
- Question dataset is bundled with the app (14k questions JSON)

---

## Core Principle
The product is designed for ultra-low friction, passive engagement. All primary interaction occurs within notifications.

---

## Core Loop
1. User receives a notification at:
   - 12:00 PM local time
   - 6:00 PM local time
2. Notification displays a trivia question with answer options
3. User selects an answer directly within the notification
4. System evaluates response immediately
5. Follow-up notification is sent:
   - Result (correct / incorrect / expired)
   - Updated streak

---

## Design Philosophy
- No session-based gameplay
- No required app opens for gameplay
- Interaction time target: <3 seconds
- Minimal cognitive load
- Glanceable UX optimized for watch notifications

---

## Supported Question Types
- Multiple Choice (max 4 options)
- True / False

---

## Question Data Model (Static)

Questions are bundled locally as JSON:

```json
{
  "id": "string (unique)",
  "question": "string",
  "choices": ["string"],
  "correct": "string",
  "type": "multiple_choice | true_false",
  "times_used": 0
}