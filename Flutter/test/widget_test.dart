import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:standalone_chat/chat/api.dart';
import 'package:standalone_chat/chat/chat_state.dart';
import 'package:standalone_chat/chat/thread.dart';
import 'package:standalone_chat/chat/theme.dart';
import 'package:standalone_chat/chat/home.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class FakeApi extends Api {
  List<Json> messages = [];
  List<Json> conversations = [];
  bool fail = false;
  @override
  Future<dynamic> get(String path, [Json? query]) async =>
      path == '/conversations'
      ? conversations
      : {'items': messages, 'nextCursor': null};
  @override
  Future<dynamic> post(String path, [Object? body]) async {
    if (fail) throw StateError('Offline');
    if (path.contains('/read/')) return null;
    return {
      ...body as Json,
      'id': 'saved',
      'conversationId': 'conversation',
      'senderId': 'me',
      'senderName': 'You',
      'createdAt': '2026-09-19T09:42:00Z',
      'type': 'Text',
    };
  }
}

String localTestTime(String time) {
  final parsed = DateTime.parse(time);
  final today = DateTime.now();
  return DateTime(
    today.year,
    today.month,
    today.day,
    parsed.hour,
    parsed.minute,
    parsed.second,
  ).toUtc().toIso8601String();
}

Json message(String id, String sender, String text, String time) => {
  'id': id,
  'conversationId': 'conversation',
  'senderId': sender,
  'senderName': sender == 'me' ? 'You' : 'Alex Morgan',
  'text': text,
  'createdAt': localTestTime(time),
  'clientMessageId': 'request-$id',
  'type': 'Text',
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.record/messages'),
          (_) async => null,
        );
  });
  Future<ChatState> state(FakeApi api) async => ChatState(api, {
    'id': 'me',
    'name': 'You',
  }, await SharedPreferences.getInstance());
  test(
    'uncertain sends retain the same UUID and merge late acknowledgments',
    () async {
      final api = FakeApi()..fail = true;
      final chat = await state(api);
      expect(await chat.send('conversation', 'hello', null), true);
      await Future<void>.delayed(Duration.zero);
      final item = chat.outbox.values.single;
      expect(chat.history['conversation']!.single['failed'], true);
      expect(
        chat.prefs.getKeys().any((key) => key.startsWith('chat.me.outbox.')),
        true,
      );
      api.fail = false;
      await chat.retry(item);
      expect(chat.outbox, isEmpty);
      expect(chat.history['conversation'], hasLength(1));
      final saved = chat.history['conversation']!.single;
      expect(saved['clientMessageId'], item['clientMessageId']);
      chat.merge(saved);
      expect(chat.history['conversation'], hasLength(1));
      chat.dispose();
    },
  );
  test(
    'drafts and quoted replies are conversation and account scoped',
    () async {
      final chat = await state(FakeApi());
      await chat.saveDraft('one', 'unfinished', {
        'id': 'quote',
        'text': 'original',
      });
      await chat.saveDraft('two', 'another', null);
      expect(chat.draft('one')['text'], 'unfinished');
      expect(chat.draft('one')['reply']['id'], 'quote');
      final other = ChatState(FakeApi(), {'id': 'other'}, chat.prefs);
      expect(other.draft('one'), isEmpty);
      await chat.clearLocal('one');
      expect(chat.draft('one'), isEmpty);
      expect(chat.draft('two')['text'], 'another');
      chat.dispose();
      other.dispose();
    },
  );
  test(
    'history refresh removes deleted server messages and retains pending sends',
    () async {
      final api = FakeApi();
      final chat = await state(api);
      chat.merge(
        message('removed', 'alex', 'deleted offline', '2026-09-19T09:41:00Z'),
      );
      chat.merge({
        ...message('pending', 'me', 'not confirmed', '2026-09-19T09:42:00Z'),
        'pending': true,
      });
      await chat.load('conversation');
      expect(chat.history['conversation'], hasLength(1));
      expect(chat.history['conversation']!.single['id'], 'pending');
      chat.dispose();
    },
  );
  for (final width in [320.0, 1024.0]) {
    testWidgets('conversation list and unread filter at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final font = FontLoader('Roboto')
        ..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final api = FakeApi();
      final chat = await state(api);
      chat.loading = false;
      chat.connected = true;
      api.conversations = [
        {
          'id': 'conversation',
          'name': 'Alex Morgan',
          'type': 'Direct',
          'members': ['me', 'alex'],
          'profiles': <Json>[],
          'reads': <Json>[],
          'unread': 2,
          'lastMessage': message(
            '1',
            'alex',
            'Let me know when you arrive.',
            '2026-09-19T09:43:00Z',
          ),
        },
        {
          'id': 'group',
          'name': 'Dispatch team',
          'type': 'Group',
          'members': ['me', 'alex', 'sam'],
          'profiles': <Json>[],
          'reads': <Json>[],
          'unread': 0,
          'lastMessage': message(
            '2',
            'me',
            'Thanks, everyone!',
            '2026-09-19T09:40:00Z',
          ),
        },
      ];
      chat.conversations = api.conversations;
      await tester.pumpWidget(
        MaterialApp(
          theme: chatTheme(),
          home: RepaintBoundary(
            key: const ValueKey('home-preview'),
            child: ChatHome(chat: chat, initializeDeviceServices: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('home-preview')),
        matchesGoldenFile('goldens/list-${width.toInt()}.png'),
      );
      await tester.tap(find.text('Unread'));
      await tester.pumpAndSettle();
      expect(find.text('Dispatch team'), findsNothing);
      expect(find.text('Alex Morgan'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    });
  }
  for (final width in [320.0, 390.0, 1024.0]) {
    testWidgets('chat renders and composer works at $width pixels', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final loader = FontLoader('Roboto')
        ..addFont(rootBundle.load('assets/fonts/roboto-regular.ttf'));
      await loader.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
      final api = FakeApi();
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
      final chat = await state(api);
      chat.online['alex'] = true;
      final c = <String, dynamic>{
        'id': 'conversation',
        'type': 'Direct',
        'name': 'Alex Morgan',
        'members': ['me', 'alex'],
        'profiles': <Json>[],
        'reads': [
          {'userId': 'alex', 'readAt': localTestTime('2026-09-19T09:44:00Z')},
        ],
      };
      chat.conversations = [c];
      await tester.pumpWidget(
        MaterialApp(
          theme: chatTheme(),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('preview'),
              child: ListenableBuilder(
                listenable: chat,
                builder: (_, _) => ChatThread(
                  chat: chat,
                  conversation: c,
                  onBack: () {},
                  onCall: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Alex Morgan'), findsOneWidget);
      await expectLater(
        find.byKey(const ValueKey('preview')),
        matchesGoldenFile('goldens/chat-${width.toInt()}.png'),
      );
      await tester.enterText(find.byType(TextField), 'Hello there');
      await tester.pump();
      expect(find.byTooltip('Send message'), findsOneWidget);
      expect(chat.draft('conversation')['text'], 'Hello there');
      await tester.tap(find.byTooltip('Message options').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply').last);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Cancel reply'), findsOneWidget);
      await expectLater(
        find.byKey(const ValueKey('preview')),
        matchesGoldenFile('goldens/reply-${width.toInt()}.png'),
      );
      await tester.tap(find.byTooltip('Cancel reply'));
      await tester.pumpAndSettle();
      expect(find.text('Hello there'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    });
  }
  testWidgets(
    'incoming messages preserve reading position and show new-message control',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeApi();
      api.messages = List.generate(
        50,
        (i) => message(
          i.toString().padLeft(3, '0'),
          'alex',
          'Message $i: Checking delivery details.',
          '2026-09-19T09:${i.toString().padLeft(2, '0')}:00Z',
        ),
      );
      final chat = await state(api);
      final c = <String, dynamic>{
        'id': 'conversation',
        'name': 'Alex Morgan',
        'type': 'Direct',
        'members': ['me', 'alex'],
        'profiles': <Json>[],
        'reads': <Json>[],
      };
      chat.conversations = [c];
      await tester.pumpWidget(
        MaterialApp(
          theme: chatTheme(),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: chat,
              builder: (_, _) => ChatThread(
                chat: chat,
                conversation: c,
                onBack: () {},
                onCall: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(ScrollablePositionedList),
        const Offset(0, 550),
      );
      await tester.pumpAndSettle();
      final visible = find
          .byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText().startsWith('Message '),
          )
          .hitTestable();
      expect(visible, findsWidgets);
      final text = (tester.widget(visible.last) as RichText).text.toPlainText();
      // Use an older visible row so the floating new-message button cannot cover it.
      final before = tester.getTopLeft(visible.last).dy;
      final incoming = message(
        'new',
        'alex',
        'A new delivery update',
        '2026-09-19T10:00:00Z',
      );
      chat.merge(incoming);
      chat.events.add({'event': 'message', 'message': incoming});
      await tester.pumpAndSettle();
      expect(find.text('1 new message'), findsOneWidget);
      final anchor = find
          .byWidgetPredicate(
            (w) => w is RichText && w.text.toPlainText() == text,
          )
          .hitTestable();
      expect(anchor, findsOneWidget);
      expect((tester.getTopLeft(anchor).dy - before).abs(), lessThan(3));
      await tester.tap(find.text('1 new message'));
      await tester.pumpAndSettle();
      expect(find.text('1 new message'), findsNothing);
      expect(
        find.text('A new delivery update', findRichText: true).hitTestable(),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      chat.dispose();
    },
  );
}
