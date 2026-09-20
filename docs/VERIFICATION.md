# Verification — 2026-09-20

Executed on Windows with .NET SDK 10.0.401, the installed Flutter/Dart SDK, Android SDK, and a local MongoDB server. Existing TMS application files were not modified. The Android call notification plugin was copied into Standalone and adapted there. No production credentials were copied.

## Passed

- ASP.NET Core API build and Release publish, with zero warnings/errors.
- **17 backend integration tests** using real MongoDB and ASP.NET TestServer: anonymous access rejection; concurrent direct-chat creation and message UUID deduplication; membership/reply scope; stable history pages and literal search; group-owner permissions/removal/mentions; monotonic reads and private history clearing; upload retries and protected downloads; call admission/participant checks; actual SignalR delivery to recipient and sender's other session; call expiry and termination after membership changes; native-decline authorization, membership, device revocation, and already-answered call protection.
- **32 Flutter tests**: persistent uncertain sends and late-ack merging; account/conversation/reply draft isolation; offline deletions; conversation-list/unread filtering at 320px and 1024px; composer/reply controls at 320px, 390px and 1024px; reading-position preservation and the new-message button; two-step group naming/Back/minimum selection; separate broadcast composition and stable UUID retry of failed recipients; keyboard mention selection; group-details retry/empty state; selected conversation at 390px, 900px and 1024px; incoming and active call controls at 320px.
- **14 Android native unit tests**: CallStyle notification properties/actions/timeout, stale Answer, persisted Decline, HTTP delivery, retry limits, and offline WorkManager behavior. Run from `Flutter/android` with `gradlew :native_call_notifications:testDebugUnitTest`.
- Flutter static analysis: no issues.
- Nineteen rendered screen baselines cover conversation list/thread, selected responsive layout, contact selection, group naming, reply composer with Send button, broadcast retry, incoming/active calls, sign-in, and call history. Baselines live in `Flutter/test/goldens`. Roboto and Material Icons are loaded explicitly; sample times use local time so results do not depend on workstation time zone. Visual inspection compared the Flutter screens with the current project's CSS, markup and chat preview images; golden tests protect the reviewed Flutter rendering, not pixel identity with browser rendering.
- Android debug APK compilation. Output: `Flutter/build/app/outputs/flutter-apk/app-debug.apk` (a development build; configure Firebase before sign-in).
- Docker Compose base configuration validation with a placeholder project ID. Containers were not deployed.

## Not exercised here

- Live Firebase authentication/FCM/APNs delivery: new project configuration and credentials are intentionally not included. Integration tests replace authentication only inside the test assembly.
- Physical Android/iOS permissions, background push behavior, notification sound, camera/microphone, Bluetooth routing, and WebRTC media through NAT/TURN.
- iOS compilation/signing: requires macOS/Xcode. iOS target, permission strings, background modes and push entitlement are included, but Apple/Firebase setup is still necessary.
- Android lock-screen/cold-start Answer/Decline, cancellation ordering and real ringtone/DND behavior still need physical-device smoke tests despite the passing native tests. The ported CallStyle service does not automatically launch full-screen. iOS uses standard notifications without CallKit/PushKit. Calls support up to six participants, and server coordination supports one API instance.

Before distribution, configure the standalone Firebase project, sign release builds with your own keys, set a reachable HTTPS API, supply an appropriate TURN deployment, and run the two-device scenarios above. See the README's deployment constraints for data retention and scaling behavior.

## Quoted replies across message types

Text, image, video, audio/voice-note, and file quotes share a type-aware preview. Multipart uploads now carry replyToMessageId, preserve it with the request UUID on retries, and return the persisted quote snapshot. The composer keeps its reply on cancellation/failure and clears it after successful attachment delivery without removing typed text. Backend tests cover text-to-attachment and attachment-to-attachment replies for all four attachment kinds, cross-conversation rejection, changed-reply retry conflicts, and snapshots/retries after original-message deletion. Flutter tests cover preview/outbox persistence for all five types and actual multipart upload failure/retry through the preview dialog. The latest backend test run used Release because an existing Debug API process holds its executable open.

## Pins, mute and archive

Backend integration tests verify private preferences survive new messages/read receipts, partial updates preserve other flags, outsiders are rejected, shared receipts omit preferences, and pins enforce membership, idempotency, clear boundaries and deletion cleanup. Flutter tests verify pinned ordering and archive/unarchive at 320px, muted versus unmuted foreground alerts, and attachment previews/unpinning. The organized conversation list has a reviewed golden baseline. Message FCM suppression is enforced before push dispatch; live FCM/device delivery is still not exercised here.

## UI refinement

The latest Flutter-only pass completed static analysis with no issues and all 32 tests, including 19 rendered screen baselines. Added coverage for password visibility and inline validation, sign-in with keyboard and enlarged text, date-grouped call history and missed-call filtering, conversation filters at 1.8x text scale, and landscape call controls. Shared account surfaces, notices, empty states, attachment feedback, and confirmation actions use the existing chat palette. Backend and native unit-test results above are from the preceding feature pass; this UI-only change did not modify those components.

