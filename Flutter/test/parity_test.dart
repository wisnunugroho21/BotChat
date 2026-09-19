import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:standalone_chat/chat/api.dart';
import 'package:standalone_chat/chat/chat_state.dart';
import 'package:standalone_chat/chat/theme.dart';
import 'package:standalone_chat/chat/dialogs.dart';
import 'package:standalone_chat/chat/thread.dart';
import 'package:standalone_chat/chat/home.dart';
import 'package:standalone_chat/chat/calls.dart';
import 'widget_test.dart' show FakeApi, message;

const people = <Json>[
  {'id': 'alex', 'name': 'Alex Morgan', 'username': 'alex'},
  {'id': 'jamie', 'name': 'Jamie Chen', 'username': 'jamie'},
  {'id': 'sam', 'name': 'Sam Rivera', 'username': 'sam'},
];

class DirectoryApi extends FakeApi {
  final posts = <Json>[];
  bool memberError = false;
  @override
  Future<dynamic> get(String path, [Json? query]) async {
    if (path == '/users') return {'items': people, 'nextCursor': null};
    if (path.endsWith('/members')) {
      if (memberError) throw StateError('Unavailable');
      return people;
    }
    return super.get(path, query);
  }

  @override
  Future<dynamic> post(String path, [Object? body]) async {
    posts.add({'path': path, if (body is Json) ...body});
    if (path == '/broadcasts') {
      final recipients = (body as Json)['recipients'] as List;
      return recipients
          .map(
            (r) => {
              'recipient': r,
              'error': r == 'jamie' ? 'temporarily unavailable' : null,
            },
          )
          .toList();
    }
    return super.post(path, body);
  }
}

Future<ChatState> state(DirectoryApi api) async => ChatState(api, {
  'id': 'me',
  'name': 'You',
}, await SharedPreferences.getInstance());
Future<void> size(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> render(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: chatTheme(),
      home: RepaintBoundary(key: const ValueKey('screen'), child: child),
    ),
  );
  await tester.pumpAndSettle();
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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
  });
  testWidgets(
    'new groups require two people and preserve selection when returning from naming',
    (tester) async {
      await size(tester, 390);
      final chat = await state(DirectoryApi());
      await render(tester, ContactPicker(chat: chat, initialMode: 'group'));
      await tester.tap(find.text('Alex Morgan'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == 'Next: name group',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Jamie Chen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next: name group'));
      await tester.pumpAndSettle();
      expect(find.text('Name your group'), findsOneWidget);
      expect(find.text('3 members including you'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Operations team');
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Dialog),
        matchesGoldenFile('goldens/group-name.png'),
      );
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected · 50 members max'), findsOneWidget);
      await tester.tap(find.byTooltip('Next: name group'));
      await tester.pumpAndSettle();
      expect(find.text('Operations team'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    },
  );
  testWidgets(
    'broadcast uses separate composer and retries only remaining recipients with the same UUID',
    (tester) async {
      await size(tester, 390);
      final api = DirectoryApi();
      final chat = await state(api);
      await render(tester, ContactPicker(chat: chat, initialMode: 'broadcast'));
      expect(find.text('Message'), findsNothing);
      await tester.tap(find.text('Alex Morgan'));
      await tester.tap(find.text('Jamie Chen'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next: write message'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'Please check your routes.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send broadcast'));
      await tester.pumpAndSettle();
      expect(find.text('Retry broadcast'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).last).readOnly,
        true,
      );
      await expectLater(
        find.byType(Dialog),
        matchesGoldenFile('goldens/broadcast-retry.png'),
      );
      await tester.tap(find.text('Retry broadcast'));
      await tester.pumpAndSettle();
      expect(api.posts.last['recipients'], ['jamie']);
      expect(
        api.posts.last['clientMessageId'],
        api.posts.first['clientMessageId'],
      );
      expect(api.posts.last['text'], api.posts.first['text']);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    },
  );
  testWidgets(
    'group mention Enter selects a contact before sending; Escape dismisses suggestions',
    (tester) async {
      await size(tester, 390);
      final api = DirectoryApi();
      final chat = await state(api);
      final c = <String, dynamic>{
        'id': 'conversation',
        'name': 'Dispatch team',
        'type': 'Group',
        'members': ['me', 'alex', 'jamie'],
        'profiles': people,
        'reads': <Json>[],
      };
      await render(
        tester,
        Scaffold(
          body: ChatThread(
            chat: chat,
            conversation: c,
            onBack: () {},
            onCall: (_) {},
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'Hello @a');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Hello @alex ',
      );
      expect(api.posts, isEmpty);
      await tester.enterText(find.byType(TextField), 'Hello @j');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('@jamie'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Hello @j',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    },
  );
  testWidgets('group details failure has retry without an endless spinner', (
    tester,
  ) async {
    final api = DirectoryApi()..memberError = true;
    final chat = await state(api);
    await render(
      tester,
      Scaffold(
        body: GroupDetails(
          chat: chat,
          conversation: {'name': 'Dispatch', 'id': 'group'},
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Group members could not be loaded.'), findsOneWidget);
    api.memberError = false;
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text('Jamie Chen'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'not found');
    await tester.pumpAndSettle();
    expect(find.text('No members match your search.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
  });
  for (final width in [390.0, 900.0, 1024.0]) {
    testWidgets('selected conversation matches single/split layout at $width', (
      tester,
    ) async {
      await size(tester, width);
      final api = DirectoryApi();
      final chat = await state(api);
      api.messages = [
        message(
          '1',
          'alex',
          'Morning! Your route is ready. Please check the delivery details before heading out.',
          '2026-09-19T09:41:00Z',
        ),
        message(
          '2',
          'me',
          'Thanks, Alex. I’m checking the documents now.',
          '2026-09-19T09:42:00Z',
        ),
        message(
          '3',
          'alex',
          'Perfect. Let me know when you arrive at the pickup point.',
          '2026-09-19T09:43:00Z',
        ),
      ];
      final c = <String, dynamic>{
        'id': 'conversation',
        'name': 'Alex Morgan',
        'type': 'Direct',
        'members': ['me', 'alex'],
        'profiles': people,
        'reads': <Json>[],
        'lastMessage': api.messages.last,
        'unread': 0,
      };
      api.conversations = [c];
      chat.conversations = [c];
      chat.selected = 'conversation';
      chat.loading = false;
      chat.connected = true;
      chat.online['alex'] = true;
      await render(
        tester,
        ChatHome(chat: chat, initializeDeviceServices: false),
      );
      expect(
        find.byTooltip('Back to chats'),
        width <= 900 ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('Messages'),
        width <= 900 ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('screen')),
        matchesGoldenFile('goldens/selected-${width.toInt()}.png'),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    });
  }
  for (final incoming in [true, false]) {
    testWidgets('call surface ${incoming ? 'incoming' : 'active'} at 320px', (
      tester,
    ) async {
      await size(tester, 320);
      var accepted = false;
      var ended = false;
      await render(
        tester,
        CallPresentation(
          name: 'Alex Morgan',
          status: incoming ? 'Incoming call…' : '02:14',
          video: !incoming,
          incoming: incoming,
          onAccept: () => accepted = true,
          onEnd: () => ended = true,
          onMute: () {},
          onCamera: () {},
          onSpeaker: () {},
        ),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('screen')),
        matchesGoldenFile(
          'goldens/call-${incoming ? 'incoming' : 'active'}.png',
        ),
      );
      if (incoming) {
        await tester.tap(find.byTooltip('Accept'));
        expect(accepted, true);
      }
      await tester.tap(find.byTooltip(incoming ? 'Decline' : 'End call'));
      expect(ended, true);
    });
  }
}
