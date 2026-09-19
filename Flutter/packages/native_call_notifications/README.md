# Standalone Android incoming calls

Adapted from `TMS-Flutter/packages/native_call_notifications` in the parent project. Source and tests are self-contained here; the standalone build has no dependency on the original project folders.

The original AndroidX CallStyle service provides repeated system ringtone, Answer/Decline, a 40-second timeout, and private queued actions across cold startup. Flutter drains Answer only after signing in and checks the current call through the authenticated API before joining. The service never starts microphone capture and does not launch the activity automatically.

Decline persists a WorkManager job before removing the notification. The adapted worker posts the registered device token to `/api/calls/{id}/native-decline`. The API permits only declining that device owner's outstanding invitation; it ignores already-answered/ended calls. Logout revokes device registration and clears the native configuration. Cancel pushes remove only the matching call and record a bounded recent-cancellation list to suppress reordered invitations.

From `Flutter/android`, run `gradlew :native_call_notifications:testDebugUnitTest`. Physical-device checks must cover notification permission, lock screen, app termination, Answer/Decline, cancellation, timeout, and Do Not Disturb with the configured standalone Firebase project.
