import 'dart:async';
import 'quotes.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:signalr_netcore/signalr_client.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';

class ChatState extends ChangeNotifier {
  ChatState(this.api, this.me, this.prefs);
  final Api api;
  final Json me;
  final SharedPreferences prefs;
  String get uid => me.str('id');
  List<Json> conversations = [];
  final Map<String, List<Json>> history = {};
  final Map<String, String?> cursors = {};
  final Map<String, bool> online = {};
  final Map<String, DateTime> typing = {};
  final Set<String> fetching = {};
  final Set<String> sending = {};
  final Map<String, Json> outbox = {};
  final events = StreamController<Json>.broadcast();
  HubConnection? hub;
  Timer? recovery;
  bool connected = false;
  bool loading = true;
  bool disposed = false;
  String? error;
  String? selected;
  String? focusMessageId;
  String get prefix => 'chat.$uid.';

  Future<void> start() async {
    for (final key in prefs.getKeys().where(
      (k) => k.startsWith('${prefix}outbox.'),
    )) {
      try {
        final item = Map<String, dynamic>.from(
          jsonDecode(prefs.getString(key)!),
        );
        outbox[item.str('clientMessageId')] = item;
        merge({...item, 'pending': true, 'failed': true});
      } catch (_) {
        /* An invalid local entry does not block the account. */
      }
    }
    await refresh();
    if (disposed) return;
    hub = HubConnectionBuilder()
        .withUrl(
          '$apiUrl/hubs/chat',
          options: HttpConnectionOptions(accessTokenFactory: api.token),
        )
        .withAutomaticReconnect()
        .build();
    hub!.on('MessageReceived', (args) {
      if (disposed) return;
      final m = Map<String, dynamic>.from(args!.first as Map);
      final duplicate = (history[m['conversationId']] ?? []).any(
        (item) => item['id'] == m['id'],
      );
      merge(m);
      unawaited(refresh());
      if (!duplicate) events.add({'event': 'message', 'message': m});
    });
    hub!.on('ConversationsChanged', (_) => unawaited(refresh()));
    hub!.on('MessageDeleted', (args) {
      final data = Map<String, dynamic>.from(args!.first as Map);
      history[data['conversationId']]?.removeWhere(
        (m) => m['id'] == data['messageId'],
      );
      notify();
      unawaited(refresh());
    });
    hub!.on('MessagesRead', (args) {
      final data = Map<String, dynamic>.from(args!.first as Map);
      for (final c in conversations.where(
        (c) => c['id'] == data['conversationId'],
      )) {
        final reads = c.objects('reads')
          ..removeWhere((r) => r['userId'] == data['userId']);
        reads.add(data);
        c['reads'] = reads;
      }
      notify();
    });
    hub!.on('PresenceChanged', (args) {
      final data = args!.first as Map;
      online[data['userId'] as String] = data['online'] == true;
      notify();
    });
    hub!.on('Typing', (args) {
      final data = args!.first as Map;
      typing[data['conversationId'] as String] = DateTime.now();
      notify();
      Future.delayed(const Duration(seconds: 4), notify);
    });
    for (final name in ['CallChanged', 'CallSignal']) {
      hub!.on(name, (args) {
        if (!disposed) events.add({'event': name, 'data': args!.first});
      });
    }
    hub!.onreconnecting(({error}) {
      connected = false;
      notify();
    });
    hub!.onclose(({error}) {
      connected = false;
      notify();
    });
    hub!.onreconnected(({connectionId}) {
      connected = true;
      notify();
      unawaited(recover());
    });
    await connect();
    if (disposed) return;
    recovery = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(recover()),
    );
  }

  void notify() {
    if (!disposed) notifyListeners();
  }

  Future<void> connect() async {
    if (hub?.state != HubConnectionState.Disconnected) return;
    try {
      await hub!.start();
      connected = true;
    } catch (_) {
      connected = false;
    }
    notify();
  }

  Future<void> recover() async {
    if (disposed) return;
    await connect();
    await refresh();
    if (selected != null) await load(selected!);
    for (final item in outbox.values.toList()) {
      await retry(item);
    }
  }

  Future<void> refresh() async {
    try {
      final data = await api.get('/conversations') as List;
      if (disposed) return;
      final previous = conversations.map((c) => c.str('id')).toSet();
      conversations = data
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((c) => c['hidden'] != true)
          .toList();
      final allowed = data.map((e) => (e as Map)['id']).toSet();
      for (final id in {...history.keys, ...previous}) {
        if (!allowed.contains(id)) {
          history.remove(id);
          await clearLocal(id);
        }
      }
      if (selected != null && !conversations.any((c) => c['id'] == selected)) {
        selected = null;
      }
      error = null;
    } catch (e) {
      error = Api.error(e);
    }
    loading = false;
    notify();
  }

  Future<void> preferences(String id, Json changes) async {
    await api.patch('/conversations/$id/preferences', changes);
    for (final c in conversations.where((c) => c['id'] == id)) {
      c.addAll(changes);
    }
    if (changes['archived'] == true && selected == id) selected = null;
    notify();
    await refresh();
  }

  Future<void> pinMessage(String id, String messageId, bool pinned) async {
    await api.put('/conversations/$id/messages/$messageId/pin', {
      'pinned': pinned,
    });
    await refresh();
  }

  Future<void> select(String id) async {
    selected = id;
    notify();
    await load(id);
  }

  Future<void> load(String id, {bool older = false}) async {
    if (fetching.contains(id)) return;
    fetching.add(id);
    notify();
    try {
      final before = older ? cursors[id] : null;
      final knownIds = (history[id] ?? []).map((m) => m.str('id')).toSet();
      final data = Map<String, dynamic>.from(
        await api.get('/conversations/$id/messages', {'before': ?before}),
      );
      if (disposed) return;
      final page = data.objects('items');
      final returnedIds = page.map((m) => m.str('id')).toSet();
      final oldest = page.isEmpty ? null : page.last.str('id');
      history[id]?.removeWhere(
        (m) =>
            m['pending'] != true &&
            knownIds.contains(m.str('id')) &&
            (before == null || m.str('id').compareTo(before) < 0) &&
            (data['nextCursor'] == null ||
                oldest != null && m.str('id').compareTo(oldest) >= 0) &&
            !returnedIds.contains(m.str('id')),
      );
      for (final m in page) {
        merge(m, emit: false);
      }
      if (older || !cursors.containsKey(id)) {
        cursors[id] = data['nextCursor'] as String?;
      }
      error = null;
    } catch (e) {
      error = Api.error(e);
    }
    fetching.remove(id);
    notify();
  }

  void merge(Json message, {bool emit = true}) {
    if (disposed) return;
    final id = message.str('conversationId');
    final messages = history.putIfAbsent(id, () => []);
    messages.removeWhere(
      (m) =>
          m['id'] == message['id'] && m['id'] != null ||
          m['clientMessageId'] == message['clientMessageId'] &&
              m['senderId'] == message['senderId'],
    );
    messages.add(message);
    messages.sort(
      (a, b) => a.str('createdAt').compareTo(b.str('createdAt')) != 0
          ? a.str('createdAt').compareTo(b.str('createdAt'))
          : a.str('id').compareTo(b.str('id')),
    );
    if (message['pending'] != true && message['senderId'] == uid) {
      outbox.remove(message.str('clientMessageId'));
      unawaited(
        prefs.remove('${prefix}outbox.${message.str('clientMessageId')}'),
      );
    }
    if (emit) notify();
  }

  Json draft(String id) {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(prefs.getString('${prefix}draft.$id') ?? '{}'),
      );
    } catch (_) {
      return {};
    }
  }

  Future<void> saveDraft(String id, String text, Json? reply) async {
    if (!await prefs.setString(
      '${prefix}draft.$id',
      jsonEncode({'text': text, 'reply': reply}),
    )) {
      error = 'Draft could not be saved on this device.';
      notify();
    }
  }

  Future<bool> send(String id, String text, Json? reply) async {
    if (text.trim().isEmpty || text.length > 4000) return false;
    final item = <String, dynamic>{
      'conversationId': id,
      'clientMessageId': const Uuid().v4(),
      'text': text,
      'replyToMessageId': reply?['id'],
      'reply': reply == null ? null : quoteFor(reply),
      'senderId': uid,
      'senderName': me['name'],
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'type': 'Text',
    };
    try {
      if (!await prefs.setString(
        '${prefix}outbox.${item['clientMessageId']}',
        jsonEncode(item),
      )) {
        throw StateError('Storage unavailable');
      }
    } catch (_) {
      error = 'Could not save the outgoing message. Your draft has been kept.';
      notify();
      return false;
    }
    outbox[item.str('clientMessageId')] = item;
    merge({...item, 'pending': true});
    unawaited(retry(item));
    return true;
  }

  Future<void> retry(Json item) async {
    final key = item.str('clientMessageId');
    if (sending.contains(key)) return;
    sending.add(key);
    try {
      final message = Map<String, dynamic>.from(
        await api.post('/conversations/${item['conversationId']}/messages', {
          'clientMessageId': key,
          'text': item['text'],
          'replyToMessageId': item['replyToMessageId'],
        }),
      );
      merge(message);
      unawaited(refresh());
    } catch (_) {
      if (outbox.containsKey(key)) {
        merge({...item, 'pending': true, 'failed': true});
      }
    } finally {
      sending.remove(key);
    }
  }

  Future<void> clearLocal(String id) async {
    await prefs.remove('${prefix}draft.$id');
    for (final item
        in outbox.values.where((m) => m['conversationId'] == id).toList()) {
      outbox.remove(item.str('clientMessageId'));
      await prefs.remove('${prefix}outbox.${item['clientMessageId']}');
    }
  }

  Future<void> markRead(String id) async {
    final messages = (history[id] ?? [])
        .where((m) => m['pending'] != true)
        .toList();
    if (messages.isEmpty) return;
    try {
      await api.post('/conversations/$id/read/${messages.last['id']}');
    } catch (_) {
      return;
    }
    for (final c in conversations.where((c) => c['id'] == id)) {
      c['unread'] = 0;
    }
    notify();
  }

  bool isRead(Json conversation, Json message) {
    final peers = (conversation['members'] as List).where((id) => id != uid);
    final reads = conversation.objects('reads');
    final created = DateTime.tryParse(message.str('createdAt'));
    return created != null &&
        peers.isNotEmpty &&
        peers.every(
          (id) => reads.any(
            (r) =>
                r['userId'] == id &&
                (DateTime.tryParse(r.str('readAt'))?.isBefore(created) ==
                    false),
          ),
        );
  }

  @override
  void dispose() {
    disposed = true;
    recovery?.cancel();
    unawaited(hub?.stop());
    unawaited(events.close());
    super.dispose();
  }
}
