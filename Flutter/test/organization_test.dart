import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:standalone_chat/chat/api.dart';
import 'package:standalone_chat/chat/chat_state.dart';
import 'package:standalone_chat/chat/home.dart';
import 'package:standalone_chat/chat/pinned_messages.dart';
import 'package:standalone_chat/chat/theme.dart';
import 'widget_test.dart' show FakeApi, message;

class OrganizationApi extends FakeApi {
  final pins = <Json>[];
  @override
  Future<dynamic> get(String path, [Json? query]) async =>
      path.endsWith('/pins') ? pins.toList() : super.get(path, query);
  @override
  Future<dynamic> patch(String path, Object body) async {
    conversations
        .singleWhere((c) => path.contains('/${c['id']}/'))
        .addAll(body as Json);
    return null;
  }

  @override
  Future<dynamic> put(String path, Object body) async {
    pins.removeWhere((m) => path.contains('/${m['id']}/pin'));
    return null;
  }
}

Json conversation(
  String id,
  String name, {
  bool pinned = false,
  bool archived = false,
  bool muted = false,
}) => {
  'id': id,
  'name': name,
  'type': 'Direct',
  'members': ['me', id],
  'profiles': <Json>[],
  'reads': <Json>[],
  'unread': 0,
  'pinned': pinned,
  'archived': archived,
  'muted': muted,
};
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
  Future<ChatState> state(OrganizationApi api) async =>
      ChatState(api, {
          'id': 'me',
          'name': 'You',
        }, await SharedPreferences.getInstance())
        ..conversations = api.conversations
        ..loading = false
        ..connected = true;
  testWidgets(
    'pins sort first and archive has a reversible separate view at 320px',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = OrganizationApi()
        ..conversations = [
          conversation('alex', 'Alex Morgan'),
          conversation('jamie', 'Jamie Chen', pinned: true, muted: true),
          conversation('sam', 'Sam Rivera', archived: true),
        ];
      final chat = await state(api);
      await tester.pumpWidget(
        MaterialApp(
          theme: chatTheme(),
          home: RepaintBoundary(
            key: const ValueKey('screen'),
            child: ChatHome(chat: chat, initializeDeviceServices: false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Jamie Chen')).dy,
        lessThan(tester.getTopLeft(find.text('Alex Morgan')).dy),
      );
      expect(find.text('Sam Rivera'), findsNothing);
      await expectLater(
        find.byKey(const ValueKey('screen')),
        matchesGoldenFile('goldens/organized-320.png'),
      );
      await tester.tap(find.text('Archived'));
      await tester.pumpAndSettle();
      expect(find.text('Sam Rivera'), findsOneWidget);
      expect(find.text('Jamie Chen'), findsNothing);
      await tester.longPress(find.text('Sam Rivera'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unarchive conversation'));
      await tester.pumpAndSettle();
      expect(find.text('No archived conversations'), findsOneWidget);
      await tester.tap(find.text('View all conversations'));
      await tester.pumpAndSettle();
      expect(find.text('Sam Rivera'), findsOneWidget);
      await tester.longPress(find.text('Alex Morgan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute messages'));
      await tester.pumpAndSettle();
      expect(api.conversations.first['muted'], isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      chat.dispose();
    },
  );
  testWidgets('muted conversations do not show foreground message alerts', (
    tester,
  ) async {
    final api = OrganizationApi()
      ..conversations = [
        conversation('conversation', 'Alex Morgan', muted: true),
      ];
    final chat = await state(api);
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        home: ChatHome(chat: chat, initializeDeviceServices: false),
      ),
    );
    await tester.pumpAndSettle();
    final m = message('one', 'alex', 'Quiet update', '2026-09-19T10:00:00Z');
    chat.events.add({'event': 'message', 'message': m});
    await tester.pumpAndSettle();
    expect(find.text('Alex Morgan: Quiet update'), findsNothing);
    await chat.preferences('conversation', {'muted': false});
    chat.events.add({'event': 'message', 'message': m});
    await tester.pumpAndSettle();
    expect(find.text('Alex Morgan: Quiet update'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
  });
  testWidgets('pinned messages support attachment previews and unpinning', (
    tester,
  ) async {
    final api = OrganizationApi();
    api.pins.add({
      'id': 'photo',
      'senderName': 'Alex Morgan',
      'type': 'Image',
      'attachment': {'fileName': 'route.png'},
    });
    final chat = await state(api);
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(),
        home: PinnedMessages(chat: chat, conversationId: 'conversation'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Photo · route.png'), findsOneWidget);
    await tester.tap(find.byTooltip('Unpin message'));
    await tester.pumpAndSettle();
    expect(find.text('No pinned messages yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    chat.dispose();
  });
}
