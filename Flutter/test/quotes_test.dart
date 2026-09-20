import 'dart:io';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:standalone_chat/chat/api.dart';
import 'package:standalone_chat/chat/attachments.dart';
import 'package:standalone_chat/chat/chat_state.dart';
import 'package:standalone_chat/chat/quotes.dart';
import 'package:standalone_chat/chat/theme.dart';
import 'widget_test.dart' show FakeApi;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final entry in {
    'Text': 'Please review',
    'Image': 'Photo · sample.png',
    'Video': 'Video · sample.mp4',
    'Audio': 'Voice note · sample.m4a',
    'File': 'File · sample.pdf',
  }.entries) {
    test('${entry.key} reply preview survives an uncertain text send', () async {
      final target = <String, dynamic>{
        'id': 'source',
        'senderName': 'Alex',
        'type': entry.key,
        'text': entry.key == 'Text' ? 'Please review' : '',
        if (entry.key != 'Text')
          'attachment': {'fileName': entry.value.split(' · ').last},
      };
      final chat = ChatState(FakeApi()..fail = true, {
        'id': 'me',
        'name': 'You',
      }, await SharedPreferences.getInstance());
      expect(await chat.send('conversation', 'Reviewed', target), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(chat.outbox.values.single['reply'], quoteFor(target));
      expect(
        (chat.outbox.values.single['reply'] as Json)['preview'],
        entry.value,
      );
      // The persisted outgoing request keeps the target and snapshot together.
      expect(
        (jsonDecode(
              chat.prefs.getString(
                'chat.me.outbox.${chat.outbox.keys.single}',
              )!,
            )
            as Map)['reply'],
        quoteFor(target),
      );
      chat.dispose();
    });
  }
  testWidgets(
    'attachment upload shows quote and retains its target and UUID on retry',
    (tester) async {
      final api = FakeApi();
      api.dio.interceptors.clear();
      final requests = <Map<String, String>>[];
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests.add(Map.fromEntries((options.data as FormData).fields));
            if (requests.length == 1) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  type: DioExceptionType.connectionError,
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'id': 'saved',
                    'conversationId': 'conversation',
                    'senderId': 'me',
                    'clientMessageId': requests.last['clientMessageId'],
                    'createdAt': DateTime.now().toUtc().toIso8601String(),
                    'text': 'sample.txt',
                  },
                ),
              );
            }
          },
        ),
      );
      final chat = ChatState(api, {
        'id': 'me',
        'name': 'You',
      }, await SharedPreferences.getInstance());
      final dir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('chat-quote-test'),
      );
      final file = File('${dir!.path}/sample.txt');
      await tester.runAsync(() => file.writeAsString('sample'));
      addTearDown(() async {
        await dir.delete(recursive: true);
        chat.dispose();
      });
      bool? sent;
      await tester.pumpWidget(
        MaterialApp(
          theme: chatTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  sent = await previewUpload(
                    context,
                    chat,
                    {'id': 'conversation', 'name': 'Alex'},
                    file.path,
                    'sample.txt',
                    reply: {
                      'id': 'target',
                      'senderName': 'Alex',
                      'type': 'Audio',
                      'attachment': {'fileName': 'voice.m4a'},
                    },
                  );
                },
                child: const Text('Attach'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Attach'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Voice note · voice.m4a'), findsOneWidget);
      await tester.tap(find.text('Send'));
      for (var i = 0; i < 100 && find.text('Retry').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(sent, isNull);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      for (var i = 0; i < 100 && sent != true; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(sent, isTrue);
      expect(requests[0]['replyToMessageId'], 'target');
      expect(requests[1], requests[0]);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
