import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'api.dart';
import 'chat_state.dart';
import 'theme.dart';
import 'thread.dart';
import 'dialogs.dart';
import 'push.dart';
import 'calls.dart';
import 'ui.dart';

class ChatHome extends StatefulWidget {
  const ChatHome({
    super.key,
    required this.chat,
    this.initializeDeviceServices = true,
  });
  final ChatState chat;
  final bool initializeDeviceServices;
  @override
  State<ChatHome> createState() => _ChatHomeState();
}

class _ChatHomeState extends State<ChatHome> with WidgetsBindingObserver {
  ChatState get chat => widget.chat;
  final search = TextEditingController();
  bool unread = false;
  bool archived = false;
  String? callId;
  PushService? push;
  StreamSubscription<Json>? events;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    events = chat.events.stream.listen((event) async {
      if (event['event'] == 'CallChanged') {
        final call = Map<String, dynamic>.from(event['data']);
        if (call['endedAt'] == null &&
            call['status'] == 'Ringing' &&
            !(call['declined'] as List? ?? []).contains(chat.uid) &&
            call['callerId'] != chat.uid) {
          openCall(call);
        }
      } else if (event['event'] == 'message') {
        final m = event['message'] as Json;
        if (mounted &&
            m['senderId'] != chat.uid &&
            !chat.conversations.any(
              (c) => c['id'] == m['conversationId'] && c['muted'] == true,
            ) &&
            m['conversationId'] != chat.selected) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${m['senderName']}: ${m['text']}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              action: SnackBarAction(
                label: 'Open',
                onPressed: () => chat.select(m.str('conversationId')),
              ),
            ),
          );
        }
      }
    });
    push = PushService(chat.api, openPush);
    if (widget.initializeDeviceServices) {
      unawaited(
        push!.initialize().then((_) => checkCalls()).catchError((Object e) {
          if (mounted) showError(e);
        }),
      );
      unawaited(NativeCalls.visible(true));
    }
  }

  Future<void> openPush(Json data) async {
    if (!mounted) return;
    try {
      if (data['type'] == 'call') {
        final call = Map<String, dynamic>.from(
          await chat.api.get('/calls/${data['callId']}'),
        );
        if (call['endedAt'] == null &&
            !(call['declined'] as List).contains(chat.uid)) {
          openCall(call, autoAnswer: data['nativeAction'] == 'accept');
        }
      } else {
        await chat.refresh();
        await chat.select(data.str('conversationId'));
      }
    } catch (e) {
      showError(e);
    }
  }

  Future<void> checkCalls() async {
    try {
      final calls = await chat.api.get('/calls') as List;
      final active = calls
          .where(
            (c) =>
                c['endedAt'] == null &&
                !(c['declined'] as List? ?? []).contains(chat.uid),
          )
          .toList();
      if (active.isNotEmpty && mounted) {
        openCall(Map<String, dynamic>.from(active.first));
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.initializeDeviceServices) {
      unawaited(NativeCalls.visible(state == AppLifecycleState.resumed));
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(chat.recover());
      unawaited(checkCalls());
    }
  }

  void showError(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(Api.error(e))));
    }
  }

  Future<void> openCall(Json call, {bool autoAnswer = false}) async {
    if (autoAnswer && callId == call.str('id')) {
      chat.events.add({'event': 'NativeAnswer', 'callId': callId});
      return;
    }
    if (!mounted || callId != null) return;
    callId = call.str('id');
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            CallScreen(chat: chat, initial: call, autoAnswer: autoAnswer),
      ),
    );
    callId = null;
  }

  Future<void> startCall(Json c, bool video) async {
    try {
      final call = Map<String, dynamic>.from(
        await chat.api.post('/conversations/${c['id']}/calls', {
          'video': video,
        }),
      );
      await openCall(call);
    } catch (e) {
      showError(e);
    }
  }

  Future<void> newChat({String mode = 'direct'}) async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ContactPicker(chat: chat, initialMode: mode),
      ),
    );
    if (id != null) {
      await chat.refresh();
      await chat.select(id);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    events?.cancel();
    push?.dispose();
    if (widget.initializeDeviceServices) unawaited(NativeCalls.visible(false));
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: chat,
    builder: (context, _) {
      final current = chat.conversations
          .where((c) => c['id'] == chat.selected)
          .firstOrNull;
      return LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth > 900;
          return PopScope(
            canPop: wide || current == null,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) {
                chat.selected = null;
                chat.notify();
              }
            },
            child: Scaffold(
              body: SafeArea(
                child: Row(
                  children: [
                    if (wide || current == null)
                      SizedBox(
                        width: wide ? 390 : constraints.maxWidth,
                        child: sidebar(),
                      ),
                    if (wide) const VerticalDivider(width: 1),
                    if (wide || current != null)
                      Expanded(
                        child: current == null
                            ? emptySelection()
                            : ChatThread(
                                key: ValueKey(current['id']),
                                chat: chat,
                                conversation: current,
                                onBack: () {
                                  chat.selected = null;
                                  chat.notify();
                                },
                                onCall: (video) => startCall(current, video),
                              ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
  Widget emptySelection() => DecoratedBox(
    decoration: const BoxDecoration(color: ChatColors.canvas),
    child: CustomPaint(
      painter: ChatWallpaper(),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.local_shipping_outlined,
                  size: 80,
                  color: ChatColors.blue,
                ),
                const SizedBox(height: 24),
                const Text(
                  'TMS CONNECT',
                  style: TextStyle(
                    color: ChatColors.blue,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Keep every trip connected',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Message dispatchers and drivers, share documents, and start secure calls from one place.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: ChatColors.muted,
                    fontSize: 15,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: newChat,
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('Start a conversation'),
                ),
                const SizedBox(height: 18),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.lock_outline, size: 14, color: ChatColors.muted),
                    SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Private and secure communication',
                        style: TextStyle(fontSize: 12, color: ChatColors.muted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> conversationActions(Json c) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(c.str('name')),
              subtitle: const Text('These settings apply only to you'),
            ),
            ListTile(
              leading: const Icon(Icons.push_pin_outlined),
              title: Text(
                c['pinned'] == true ? 'Unpin conversation' : 'Pin conversation',
              ),
              onTap: () => Navigator.pop(context, 'pinned'),
            ),
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: Text(
                c['muted'] == true ? 'Unmute messages' : 'Mute messages',
              ),
              subtitle: const Text('Calls will still ring'),
              onTap: () => Navigator.pop(context, 'muted'),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(
                c['archived'] == true
                    ? 'Unarchive conversation'
                    : 'Archive conversation',
              ),
              onTap: () => Navigator.pop(context, 'archived'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    try {
      await chat.preferences(c.str('id'), {action: c[action] != true});
    } catch (e) {
      showError(e);
    }
  }

  Widget sidebar() {
    final query = search.text.toLowerCase();
    final filtered = chat.conversations
        .where(
          (c) =>
              c.str('name').toLowerCase().contains(query) &&
              (c['archived'] == true) == archived &&
              (!unread || (c['unread'] as num? ?? 0) > 0),
        )
        .toList();
    final items = [
      ...filtered.where((c) => c['pinned'] == true),
      ...filtered.where((c) => c['pinned'] != true),
    ];
    return ColoredBox(
      color: ChatColors.panel,
      child: Column(
        children: [
          Container(
            height: ChatLayout.header(context),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            color: Colors.white,
            child: Row(
              children: [
                Avatar(chat.me.str('name')),
                const SizedBox(width: 10),
                const Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TMS CONNECT',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                          color: ChatColors.blue,
                        ),
                      ),
                      Text(
                        'Messages',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Call history',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          CallHistoryScreen(chat: chat, onCall: startCall),
                    ),
                  ),
                  icon: const Icon(Icons.phone_callback_outlined),
                ),
                IconButton.filled(
                  style: IconButton.styleFrom(
                    backgroundColor: ChatColors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  tooltip: 'New chat',
                  onPressed: newChat,
                  icon: const Icon(Icons.add_comment_outlined),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Chat list options',
                  onSelected: (value) async {
                    if (value == 'broadcast') await newChat(mode: 'broadcast');
                    if (value == 'refresh') await chat.recover();
                    if (value == 'read') {
                      try {
                        for (final c in chat.conversations.toList()) {
                          final last = c['lastMessage'] as Map?;
                          if (last != null) {
                            await chat.api.post(
                              '/conversations/${c['id']}/read/${last['id']}',
                            );
                          }
                        }
                        await chat.refresh();
                      } catch (e) {
                        showError(e);
                      }
                    }
                    if (!mounted) return;
                    if (value == 'search') {
                      await openSearch(context, chat);
                    }
                    if (value == 'notifications') {
                      try {
                        push?.dispose();
                        push = PushService(chat.api, openPush);
                        await push!.initialize();
                      } catch (e) {
                        showError(e);
                      }
                    }
                    if (value == 'logout') {
                      try {
                        await push?.unregister();
                        await FirebaseAuth.instance.signOut();
                      } catch (e) {
                        showError(e);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'broadcast',
                      child: ChatMenuLabel(
                        'Broadcast message',
                        Icons.campaign_outlined,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'refresh',
                      child: ChatMenuLabel('Refresh', Icons.refresh),
                    ),
                    PopupMenuItem(
                      value: 'read',
                      child: ChatMenuLabel('Mark all as read', Icons.done_all),
                    ),
                    PopupMenuItem(
                      value: 'search',
                      child: ChatMenuLabel(
                        'Search message content',
                        Icons.search,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'notifications',
                      child: ChatMenuLabel(
                        'Enable notifications',
                        Icons.notifications_outlined,
                      ),
                    ),
                    PopupMenuItem(
                      value: 'logout',
                      child: ChatMenuLabel('Sign out', Icons.logout),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search conversations',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        onPressed: () {
                          search.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    label: const Text('All'),
                    selected: !unread && !archived,
                    onSelected: (_) => setState(() {
                      unread = false;
                      archived = false;
                    }),
                  ),
                  ChoiceChip(
                    label: const Text('Unread'),
                    selected: unread && !archived,
                    onSelected: (_) => setState(() {
                      unread = true;
                      archived = false;
                    }),
                  ),
                  ChoiceChip(
                    label: const Text('Archived'),
                    selected: archived,
                    onSelected: (_) => setState(() {
                      archived = true;
                      unread = false;
                    }),
                  ),
                ],
              ),
            ),
          ),
          if (archived)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Archived chats stay here when new messages arrive.',
                style: TextStyle(fontSize: 12, color: ChatColors.muted),
              ),
            ),
          if (!chat.connected)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.cloud_off_outlined,
                    size: 16,
                    color: ChatColors.muted,
                  ),
                  const SizedBox(width: 8),
                  const Flexible(
                    child: Text(
                      'Reconnecting… Your messages are saved.',
                      style: TextStyle(fontSize: 12, color: ChatColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          if (chat.error != null)
            TextButton.icon(
              onPressed: chat.recover,
              icon: const Icon(Icons.refresh),
              label: Text(chat.error!, maxLines: 2),
            ),
          Expanded(
            child: chat.loading
                ? const Center(child: CircularProgressIndicator())
                : items.isEmpty
                ? ChatEmptyState(
                    icon: archived
                        ? Icons.archive_outlined
                        : unread
                        ? Icons.mark_chat_read_outlined
                        : query.isNotEmpty
                        ? Icons.search_off
                        : Icons.chat_bubble_outline,
                    title: query.isNotEmpty
                        ? 'No matching conversations'
                        : unread
                        ? 'You’re all caught up'
                        : archived
                        ? 'No archived conversations'
                        : 'No conversations yet',
                    description: query.isNotEmpty
                        ? 'Try another name or clear your search.'
                        : unread
                        ? 'New messages from your team will appear here.'
                        : archived
                        ? 'Archived chats stay out of your main list until you bring them back.'
                        : 'Start a conversation to keep your team connected.',
                    action: query.isNotEmpty
                        ? 'Clear search'
                        : unread || archived
                        ? 'View all conversations'
                        : 'Start a conversation',
                    onAction: query.isNotEmpty
                        ? () {
                            search.clear();
                            setState(() {});
                          }
                        : unread || archived
                        ? () => setState(() {
                            unread = false;
                            archived = false;
                          })
                        : newChat,
                  )
                : RefreshIndicator(
                    onRefresh: chat.refresh,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.only(top: 6, bottom: 16),
                      itemCount: items.length,
                      itemBuilder: (_, i) {
                        final c = items[i];
                        final last = c['lastMessage'] as Map?;
                        final count = c['unread'] as num? ?? 0;
                        final at = DateTime.tryParse(
                          last?['createdAt']?.toString() ?? '',
                        )?.toLocal();
                        final draft = chat.draft(c.str('id')).str('text');
                        final peer = (c['members'] as List)
                            .where((p) => p != chat.uid)
                            .firstOrNull;
                        return ConversationTile(
                          pinned: c['pinned'] == true,
                          muted: c['muted'] == true,
                          onLongPress: () => conversationActions(c),
                          name: c.str('name'),
                          seed: peer?.toString(),
                          selected: c['id'] == chat.selected,
                          group: c['type'] == 'Group',
                          memberCount: (c['members'] as List).length,
                          online: chat.online[peer] == true,
                          time: at == null ? '' : DateFormat.Hm().format(at),
                          unread: count.toInt(),
                          draft: draft.isNotEmpty,
                          mine: last?['senderId'] == chat.uid,
                          read: last == null
                              ? false
                              : chat.isRead(c, Map<String, dynamic>.from(last)),
                          preview: draft.isNotEmpty
                              ? 'Draft: $draft'
                              : last?['text']?.toString() ?? 'No messages yet',
                          onTap: () => chat.select(c.str('id')),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
