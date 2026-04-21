# NotiTrivia – Product Specification

## Overview
NotiTrivia is a watchOS-first, notification-driven trivia application that delivers two daily trivia questions to the user via Apple Watch notifications.

## Core Principle
The product is designed for ultra-low friction, passive engagement. All primary interaction occurs within notifications.

## Core Loop
1. User receives a notification at 12:00 PM and 6:00 PM (local time)
2. Notification displays a full trivia question
3. User selects an answer directly within the notification
4. System evaluates the answer
5. User receives an immediate follow-up notification with:
   - Result (correct / incorrect / expired)
   - Updated streak

## Design Philosophy
- No session-based gameplay
- No required app opens
- Fast interaction (<3 seconds)
- Minimal cognitive load
- Glanceable and actionable UX

## Supported Question Types
- Multiple Choice (4 options)
- True / False

## Watch App Role
The Watch app exists only to:
- Display current streak
- Provide minimal settings (future)

No gameplay occurs inside the app UI.

## Streak System
- Increment on correct answer
- Reset on:
  - Incorrect answer
  - Missed question (no answer within time window)

## Question Validity
- Each question is valid for 1 hour from delivery
- After 1 hour:
  - Question is considered expired
  - Any interaction results in "Time expired"
  - Streak is reset

## Notification Behavior
- Questions are independent (no dependency between noon and 6 PM)
- Missed questions do not block future ones

## Data Storage
- All data stored locally on device
- No user accounts (v1)
- Streak resets on app deletion

## Tone
- Minimal, clean, slightly playful
- Optional emoji in streak display (e.g., 🔥 Streak: 5)

## Non-Goals (v1)
- No multiplayer
- No social features
- No leaderboard
- No monetization
- No free-form input answers
- No backend dependency for core functionality