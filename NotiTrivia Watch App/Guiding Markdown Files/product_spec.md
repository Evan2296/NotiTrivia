# NotiTrivia – Product Specification

## Overview
NotiTrivia is a watchOS-first, notification-driven trivia application that delivers two daily trivia questions via Apple Watch notifications.

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
- Multiple Choice (4 options)
- True / False

---

## Question Data Model (Runtime)
Each question is represented as:

```json
{
  "question": "string",
  "choices": ["string"],
  "correct": "string",
  "type": "multiple_choice | true_false"
}