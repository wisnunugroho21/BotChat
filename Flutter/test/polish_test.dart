import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:standalone_chat/main.dart';
import 'package:standalone_chat/chat/api.dart';
import 'package:standalone_chat/chat/chat_state.dart';
import 'package:standalone_chat/chat/calls.dart';
import 'package:standalone_chat/chat/home.dart';
import 'package:standalone_chat/chat/theme.dart';
import 'widget_test.dart' show FakeApi, localTestTime;

class CallsApi extends FakeApi {
  @override
  Future<dynamic> get(String path, [Json? query]) async => path == '/calls'
      ? [
          {
            'id': 'missed',
            'conversationId': 'alex',
            'callerId': 'alex',
            'callerName': 'Alex Morgan',
            'status': 'Missed',
            'createdAt': localTestTime('2026-09-19T10:15:00Z'),
            'video': false,
          },
          {
            'id': 'completed',
            'conversationId': 'alex',
            'callerId': 'me',
            'callerName': 'You',
            'status': 'Ended',
            'createdAt': localTestTime('2026-09-19T09:40:00Z'),
            'answeredAt': localTestTime('2026-09-19T09:40:00Z'),
            'endedAt': localTestTime('2026-09-19T09:42:14Z'),
            'video': true,
          },
        ]
      : super.get(path, query);
}

Future<void> viewport(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('sign-in supports password visibility and inline validation', (
    tester,
  ) async {
    await viewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        home: const RepaintBoundary(key: ValueKey('screen'), child: SignIn()),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('screen')),
      matchesGoldenFile('goldens/sign-in.png'),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isTrue,
    );
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isFalse,
    );
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('sign-in remains scrollable with keyboard and larger text', (
    tester,
  ) async {
    await viewport(tester, const Size(320, 640));
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const SignIn(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('call history groups dates and filters missed calls', (
    tester,
  ) async {
    await viewport(tester, const Size(390, 844));
    final chat =
        ChatState(CallsApi(), {
            'id': 'me',
          }, await SharedPreferences.getInstance())
          ..conversations = [
            {'id': 'alex', 'name': 'Alex Morgan'},
          ];
    var called = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        home: RepaintBoundary(
          key: const ValueKey('screen'),
          child: CallHistoryScreen(chat: chat, onCall: (_, _) => called = true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Outgoing · 2:14'), findsOneWidget);
    await expectLater(
      find.byKey(const ValueKey('screen')),
      matchesGoldenFile('goldens/call-history.png'),
    );
    await tester.tap(find.text('Missed'));
    await tester.pumpAndSettle();
    expect(find.text('Outgoing · 2:14'), findsNothing);
    await tester.tap(find.byTooltip('Call again'));
    expect(called, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
  });
  testWidgets('conversation filters wrap at large text sizes', (tester) async {
    await viewport(tester, const Size(320, 844));
    final chat =
        ChatState(FakeApi(), {
            'id': 'me',
            'name': 'You',
          }, await SharedPreferences.getInstance())
          ..loading = false
          ..connected = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(1.8)),
          child: child!,
        ),
        home: ChatHome(chat: chat, initializeDeviceServices: false),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived'));
    await tester.pumpAndSettle();
    expect(find.text('No archived conversations'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
  });
  testWidgets('call controls remain visible in landscape', (tester) async {
    await viewport(tester, const Size(844, 390));
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        home: CallPresentation(
          name: 'Alex Morgan',
          status: '02:14',
          video: true,
          incoming: false,
          onAccept: () {},
          onEnd: () {},
          onMute: () {},
          onCamera: () {},
          onSpeaker: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('End call').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
