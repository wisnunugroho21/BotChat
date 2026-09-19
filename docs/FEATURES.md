# Correspondence with the existing chat

Reference sources: `TMS/Website/Areas/Chat/Views/Chat/Chat.cshtml`, `TMS/Website/wwwroot/css/chat.css`, `TMS/Website/wwwroot/js/chat.js`, `TMS/chat-features.md`, and the supplied `chat-ui-preview/refined-chat-390.png` screen.

| Existing experience | Standalone implementation |
| --- | --- |
| TMS Connect / Messages header | Same brand labels, initials avatars, call history/new-chat/options actions |
| Blue/white bubbles and pale doodle background | Same #2563eb accent, #172b4d text, #62718a secondary text, #e1e7f0 borders, #f6f8fc panels; original 260px SVG doodle paths ported to Flutter Canvas; Roboto bundled with license |
| Message shape and group identity | Current stylesheet's 8px message corners, original SVG tail silhouette mirrored for outgoing messages, and 32px group sender avatars on both sides |
| Responsive conversation layout | Original >900px split breakpoint with 390px sidebar; single-pane navigation through 900px; 64px phone / 72px wider headers; header avatar hidden through 600px; original message insets, rounded desktop composer and phone edge-to-edge composer |
| Conversation selection and welcome | Rounded blue selected row/left stripe, unread count/time, draft preview, receipt ticks, deterministic six-color initials, presence/member-count badges; original welcome and beginning-of-conversation copy |
| Direct/group chat | Independent MongoDB membership and profile records, owner checks, membership revisions, ownership transfer |
| All / Unread, contact search | Native search fields, chips, empty/loading/retry states, contact pagination |
| History, replies, mentions | 50-message pages, server-created quote snapshots, jump to original, member suggestions and mention metadata; Up/Down and Enter/Tab select mentions, Escape dismisses suggestions/reply; Enter sends and Shift+Enter adds a newline; floating new-message control preserves reading position |
| Drafts and outgoing queue | Per-account/conversation drafts including replies; persisted outgoing UUIDs; sender-session and response/event deduplication |
| Read receipts, presence, typing | Authenticated SignalR events and MongoDB read boundaries; multiple sessions do not mark a user offline until the last connection closes |
| Search across saved history | Literal case-insensitive search over text/filenames, membership/clear boundaries, pagination, highlighted results and navigation |
| Groups and broadcasts | Original two-step select-people / name-group flow (at least two other people, max 50 total); Back preserves input; searchable group details with retry and empty state; owner-only editing; separate broadcast composer with frozen retry text/UUID and only unconfirmed recipients |
| Attachments and voice notes | Native file picker; image/audio/video previews; pinch-zoom image viewer and save action; measured upload progress; cancellation/retry; authenticated downloads; recording elapsed time, audio playback/seeking |
| Menus | Conversation and list Refresh, Mark all read, Broadcast message, search, call history, group details/edit, clear/delete/leave actions |
| Calls | Navy gradient voice surface, incoming/active controls, elapsed timer, group participant status, remote video with local inset; native WebRTC mesh, microphone/camera/speaker controls, server busy checks and refreshed call history |
| Notifications | Firebase background push/deep links and SignalR foreground updates; original Android CallStyle ringing service ported under Flutter/packages, queued Answer and background WorkManager Decline; matching cancellation and 40-second timeout |

Intentional differences: native Flutter widgets replace the WebView/DOM implementation; menus remain touch-accessible, system pickers/permissions follow Android/iOS conventions, and typography can differ slightly by platform rendering. Attachment storage uses private MongoDB GridFS rather than the original public S3 bucket. Authentication is standalone Firebase email/password rather than the TMS user database. Group calls have a six-person mesh limit. Android does not launch full-screen automatically; iOS uses standard notifications without CallKit/PushKit. Live two-device validation remains required after Firebase configuration.

REST endpoints are rooted at `/api`; the hub is `/hubs/chat`. All account/data routes require a Firebase ID token. IDs in payloads are strings. Event names: `MessageReceived`, `MessageDeleted`, `MessagesRead`, `ConversationsChanged`, `PresenceChanged`, `Typing`, `CallChanged`, `CallSignal`. Hub invocations: `Typing`, `SendMessage`, `Signal`. REST and hub sends share the same message service and idempotency index.

The separate native-decline endpoint accepts a registered device token exclusively to decline that device owner's outstanding call invitation. It does not expose account or chat data. Its authorization, revocation, membership, and stale-action behavior are covered by backend integration tests.
