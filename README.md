# TMS Connect — standalone chat

A native Flutter mobile application and an independent ASP.NET Core 10 API. MongoDB stores accounts, conversations, messages, read receipts, devices, calls, and private attachments (GridFS). Firebase Authentication supplies the API identity; Firebase Cloud Messaging delivers background notifications. SignalR synchronizes messages, typing, presence, read receipts, and WebRTC signaling.

There are no project references, WebViews, SQL databases, TMS login dependencies, or production credentials copied from the original application. The whole `Standalone` directory can be moved into its own repository.

## Contents

| Folder | Purpose |
| --- | --- |
| `Flutter` | Native Android/iOS app, platform projects, locked Dart dependencies, widget/state tests and rendered screen baselines |
| `Web` | Authenticated REST API, SignalR hub, MongoDB services, Dockerfile and locked NuGet dependencies |
| `Tests` | HTTP integration tests against a real, isolated MongoDB test database |
| `docs` | Feature correspondence and deployment/verification notes |

## 1. Configure a separate Firebase project

1. Create a Firebase project and enable **Authentication → Email/Password**. Create accounts from the app, then choose a display name and a unique username. All standalone accounts are visible in the contact directory. Registration is open by default; restrict Firebase account creation if deploying a private organization directory.
2. Register Android package `com.tmsconnect.standalone_chat`; place its `google-services.json` in `Flutter/android/app/`.
3. Register iOS bundle `com.tmsconnect.standaloneChat`; add its `GoogleService-Info.plist` to the Runner target using Xcode. Enable Push Notifications, configure your Apple team/signing, and upload an APNs authentication key in Firebase. Minimum iOS version is 15.0. Android minimum SDK is 24.
4. For server push delivery, create a service account for this new project and store the JSON **outside this repository**. Use Application Default Credentials (`GOOGLE_APPLICATION_CREDENTIALS`). The API needs permission to send Firebase messages.

The app uses native Firebase configuration via `Firebase.initializeApp()`. FlutterFire CLI can also generate the platform configuration; this app does not require a checked-in `firebase_options.dart`. Without native Firebase configuration, the built app displays a setup message instead of connecting to any existing TMS environment.

## 2. Run the API and MongoDB

Requirements: .NET 10 SDK and MongoDB 8+, or Docker Compose.

With Docker, from this directory:

```powershell
Copy-Item .env.example .env
# Edit .env to set your Firebase project ID and, for push, the credential path.
docker compose up --build -d
# Or enable FCM using the additional configuration:
docker compose -f compose.yaml -f compose.firebase.yaml up --build -d
```

MongoDB is available only inside the Docker network. API port 5080 binds to localhost; terminate HTTPS at a reverse proxy for deployment. The named volume retains messages and attachments across restarts.

To use an existing **local development** MongoDB server:

```powershell
$env:Firebase__ProjectId = "your-standalone-firebase-project"
$env:Mongo__ConnectionString = "mongodb://localhost:27017"
$env:Mongo__Database = "standalone_chat"
# Optional until push credentials are configured:
$env:Firebase__EnablePush = "true"
$env:GOOGLE_APPLICATION_CREDENTIALS = "C:/secure/standalone-firebase-admin.json"
dotnet run --project Web --urls http://0.0.0.0:5080
```

Set `Firebase__EnablePush=false` to develop chat without server push credentials. Firebase sign-in still requires the configured Firebase project. `/health` reports readiness after MongoDB indexes have been created. Startup fails if MongoDB or required unique indexes are unavailable.

## 3. Run Flutter

Requirements: Flutter 3.41+ with Dart 3.11.4+, Android SDK/JDK 17; macOS/Xcode for iOS. The committed lockfile records the versions actually resolved and tested.

```powershell
cd Flutter
flutter pub get
# Android emulator reaches the host through 10.0.2.2:
flutter run --dart-define=API_URL=http://10.0.2.2:5080
# A physical device needs a reachable HTTPS API:
flutter run --dart-define=API_URL=https://chat-api.example.com
```

`API_URL` must omit a trailing slash and `/api`. HTTP is enabled only in the Android debug manifest. Use HTTPS for release and for physical iOS devices. Configure your own release signing before distributing the application; the generated Android project currently uses debug signing.

For calls across restrictive NAT/firewalls, supply a TURN relay:

```powershell
flutter run --dart-define=API_URL=https://chat-api.example.com --dart-define=TURN_URL=turns:turn.example.com:5349 --dart-define=TURN_USERNAME=development-user --dart-define=TURN_CREDENTIAL=development-credential
```

These defines are appropriate for development. For public distribution, replace static TURN credentials with short-lived credentials issued by your deployment; build-time values can be extracted from mobile binaries.

## Using the app

- **New chat** opens the contact directory, group creation, or broadcast selection. Group owners can edit names and membership; leaving transfers ownership to a remaining member.
- **All / Unread** and conversation search filter the sidebar. Message-content search searches saved history. Conversation search and reply cards jump to matching messages, fetching older pages when needed.
- Messages save to an account-scoped local outbox before the composer clears. Uncertain sends retain their UUID for retry. Draft text and reply selections persist per account/conversation.
- Use the message chevron to reply, copy, or delete your own message. Group `@username` suggestions resolve against current members.
- The paperclip previews a file before upload. Progress, cancel, and retry keep the recipient and request ID fixed. The microphone records a voice note, then uses the same preview flow. Upload limit: 25 MB; recording limit: five minutes.
- Voice/video buttons start a direct or group call. Calls support up to six participants with a WebRTC mesh. Call history is available from the conversation list.
- SignalR handles foreground updates; FCM displays background notifications and routes taps back into the correct conversation/call. Clear/delete history affects only your account. Leaving a group removes access.

## Verification

From `Standalone` with MongoDB running on localhost:

```powershell
dotnet test Tests/Chat.Tests.csproj
cd Flutter
flutter analyze
flutter test
flutter build apk --debug
```

`CHAT_TEST_MONGO` can point to a separate test MongoDB instance. Tests create a random `standalone_chat_test_*` database and remove only that database afterwards. Tests supply their own authentication handler **inside the test assembly**; the production API has no test-login or bypass endpoint.

See [feature correspondence](docs/FEATURES.md) and [verification notes](docs/VERIFICATION.md) for the supported behaviors, deployment limits, and device checks still needed. Native iOS builds require macOS and have not been run on this Windows workstation.

## Deployment constraints

- Deploy a single API instance for the included in-process presence and call-admission tracking. Multi-instance operation requires distributed call coordination and a SignalR backplane/service before scaling out.
- Message persistence is authoritative; notifications are best-effort after save. Reconnect/polling recovers saved history. This is not a transactional notification outbox.
- Android calls use the original project's CallStyle foreground ringing service with Answer/Decline actions, queued cold-start Answer, and WorkManager delivery of Decline. FCM call payloads are data-only on Android; iOS uses standard APNs notifications. Neither automatic full-screen launch nor iOS CallKit/PushKit is included. Mobile OS restrictions and notification permissions can delay presentation.
- Native Decline uses a narrow `/api/calls/{id}/native-decline` endpoint: the registered device token authorizes only declining that device owner's outstanding invitation. It cannot answer calls, read data, decline another user's invitation, or end an already-answered call. Treat FCM device tokens as credentials; revoking device registration revokes this action.
- Calls that never receive an answer expire after 40 seconds, matching the original Android notification timeout; stale calls expire after four hours. Add server-side lifecycle jobs/heartbeats if stronger abandoned-call recovery is required.
- GridFS files are private and downloaded only after membership checks. Orphan files from an interrupted/ambiguous upload can remain; retention/cleanup and backups belong to the deployment policy. Deleted messages retain their attachment object until a retention job removes it.
- Drafts/outbox use application-local preferences and are not end-to-end encrypted. Clear application data to remove local drafts. Authentication tokens are managed by Firebase's native SDK.

Implementation references: [ASP.NET Core SignalR authentication](https://learn.microsoft.com/en-us/aspnet/core/signalr/authn-and-authz?view=aspnetcore-10.0), [SignalR Flutter client](https://pub.dev/packages/signalr_netcore), [Flutter WebRTC](https://pub.dev/packages/flutter_webrtc).
