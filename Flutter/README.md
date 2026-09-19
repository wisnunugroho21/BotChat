# TMS Connect mobile

Native Flutter chat client. See [the standalone setup guide](../README.md) for Firebase registration, API configuration, platform builds, and verification.

Source lives in `lib/chat`: API transport, account-scoped chat state, conversation screens, attachments, notifications, WebRTC calls, and shared visual tokens. `lib/main.dart` owns Firebase sign-in and profile setup.

Run `flutter analyze`, `flutter test`, and `flutter build apk --debug` from this folder. Screen baselines in `test/goldens` cover 320px/390px phone layouts and a 1024px wider layout.
