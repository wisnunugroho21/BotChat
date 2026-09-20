import 'dart:async';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'api.dart';
import 'chat_state.dart';
import 'theme.dart';
import 'dialogs.dart';
import 'attachments.dart';
import 'quotes.dart';

class ChatThread extends StatefulWidget {
  const ChatThread({
    super.key,
    required this.chat,
    required this.conversation,
    required this.onBack,
    required this.onCall,
  });
  final ChatState chat;
  final Json conversation;
  final VoidCallback onBack;
  final void Function(bool) onCall;
  @override
  State<ChatThread> createState() => _ChatThreadState();
}

class _ChatThreadState extends State<ChatThread> with WidgetsBindingObserver {
  ChatState get chat => widget.chat;
  String get id => widget.conversation.str('id');
  double get threadInset => ChatLayout.phone(context)
      ? 14
      : (MediaQuery.sizeOf(context).width * .06).clamp(18, 84);
  final composer = TextEditingController();
  final focus = FocusNode();
  final scroll = ItemScrollController();
  final positions = ItemPositionsListener.create();
  final recorder = AudioRecorder();
  Json? reply;
  String? highlight;
  bool recording = false, jumping = false;
  bool paged = false;
  bool restoringAnchor = false;
  List<Json> renderedMessages = [];
  int newMessages = 0;
  StreamSubscription<Json>? events;
  Timer? typingTimer;
  Timer? recordLimit;
  Timer? recordClock;
  int recordSeconds = 0;
  int mentionIndex = 0;
  bool dismissMentions = false;
  bool get atBottom =>
      !scroll.isAttached ||
      positions.itemPositions.value.any(
        (p) =>
            p.index == 0 && p.itemLeadingEdge >= -.1 && p.itemLeadingEdge < 1,
      );
  bool foreground = true;
  @override
  void initState() {
    super.initState();
    focus.onKeyEvent = composerKey;
    WidgetsBinding.instance.addObserver(this);
    final draft = chat.draft(id);
    composer.text = draft.str('text');
    reply = draft['reply'] == null
        ? null
        : Map<String, dynamic>.from(draft['reply']);
    positions.itemPositions.addListener(positionChanged);
    events = chat.events.stream.listen((event) {
      if (event['event'] != 'message') return;
      final message = event['message'] as Json;
      if (message['conversationId'] != id) return;
      if (atBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.isAttached) scroll.jumpTo(index: 0);
        });
        if (foreground) chat.markRead(id);
      } else if (message['senderId'] != chat.uid) {
        final anchor = positions.itemPositions.value
            .where(
              (p) =>
                  p.index < renderedMessages.length &&
                  p.itemLeadingEdge >= 0 &&
                  p.itemLeadingEdge < 1,
            )
            .firstOrNull;
        final anchorId = anchor == null
            ? null
            : renderedMessages[anchor.index]['id'];
        setState(() => newMessages++);
        if (anchorId != null) {
          restoringAnchor = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !scroll.isAttached) return;
            final index = (chat.history[id] ?? []).reversed.toList().indexWhere(
              (m) => m['id'] == anchorId,
            );
            if (index >= 0) {
              scroll.jumpTo(
                index: index,
                alignment: anchor!.itemLeadingEdge.clamp(0, 1),
              );
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              restoringAnchor = false;
            });
          });
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await chat.load(id);
      if (!mounted) return;
      if (chat.focusMessageId != null) {
        final target = chat.focusMessageId!;
        chat.focusMessageId = null;
        await jump(target);
      } else if (foreground) {
        chat.markRead(id);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground && atBottom) chat.markRead(id);
    if (!foreground && recording) stopRecording(send: false);
  }

  @override
  void didUpdateWidget(covariant ChatThread oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (chat.focusMessageId != null) {
      final target = chat.focusMessageId!;
      chat.focusMessageId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) jump(target);
      });
    }
  }

  void positionChanged() {
    if (!restoringAnchor && atBottom && newMessages > 0 && mounted) {
      setState(() => newMessages = 0);
      if (foreground) chat.markRead(id);
    }
  }

  void persist() {
    unawaited(chat.saveDraft(id, composer.text, reply));
  }

  void textChanged(String value) {
    mentionIndex = 0;
    dismissMentions = false;
    persist();
    setState(() {});
    if (typingTimer?.isActive != true && chat.connected) {
      chat.hub?.invoke('Typing', args: [id]).catchError((Object _) => null);
      typingTimer = Timer(const Duration(seconds: 3), () {});
    }
  }

  void error(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(Api.error(e))));
    }
  }

  Future<void> send() async {
    final original = composer.text;
    if (await chat.send(id, original, reply)) {
      if (!mounted) return;
      if (composer.text == original) {
        composer.clear();
        setState(() => reply = null);
        persist();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.isAttached) scroll.jumpTo(index: 0);
      });
    }
  }

  Future<void> attach() async {
    try {
      final file = await FilePicker.pickFile();
      if (file?.path != null && mounted) {
        await sendAttachment(file!.path!, file.name);
      }
    } catch (e) {
      error(e);
    }
  }

  Future<void> startRecording() async {
    try {
      if (!await recorder.hasPermission()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Microphone permission is needed for voice notes.'),
            ),
          );
        }
        return;
      }
      final dir = await getTemporaryDirectory();
      await recorder.start(
        const RecordConfig(),
        path: '${dir.path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      if (mounted) {
        setState(() {
          recording = true;
          recordSeconds = 0;
        });
      }
      recordClock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => recordSeconds++);
      });
      recordLimit = Timer(const Duration(minutes: 5), () => stopRecording());
    } catch (e) {
      error(e);
    }
  }

  Future<void> stopRecording({bool send = true}) async {
    recordClock?.cancel();
    recordLimit?.cancel();
    try {
      final path = await recorder.stop();
      if (!mounted) return;
      setState(() => recording = false);
      if (send && path != null) {
        await sendAttachment(path, 'Voice note.m4a');
      }
    } catch (e) {
      error(e);
    }
  }

  Future<void> sendAttachment(String path, String name) async {
    final selectedReply = reply == null
        ? null
        : Map<String, dynamic>.from(reply!);
    final sent = await previewUpload(
      context,
      chat,
      widget.conversation,
      path,
      name,
      reply: selectedReply,
    );
    if (!mounted || sent != true) return;
    if (reply?['id'] == selectedReply?['id']) {
      setState(() => reply = null);
      persist();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.isAttached) scroll.jumpTo(index: 0);
    });
  }

  Future<void> jump(String target) async {
    if (jumping) return;
    setState(() => jumping = true);
    try {
      while (mounted &&
          !(chat.history[id] ?? []).any((m) => m['id'] == target) &&
          chat.cursors[id] != null) {
        final previous = chat.cursors[id];
        await chat.load(id, older: true);
        if (chat.cursors[id] == previous) break;
      }
      if (!mounted) return;
      final list = (chat.history[id] ?? []).reversed.toList();
      final index = list.indexWhere((m) => m['id'] == target);
      if (index < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Original message is unavailable.')),
        );
        return;
      }
      setState(() => highlight = target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.isAttached) {
          scroll.jumpTo(index: index, alignment: .35);
        }
      });
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => highlight = null);
      });
    } finally {
      if (mounted) setState(() => jumping = false);
    }
  }

  Future<void> menu(String action) async {
    try {
      if (action == 'refresh') {
        await chat.load(id);
        await chat.markRead(id);
        return;
      }
      if (action == 'search') {
        final result = await openSearch(
          context,
          chat,
          conversation: widget.conversation,
        );
        if (result != null && mounted) await jump(result.str('id'));
      }
      if (!mounted) return;
      if (action == 'details') {
        await groupDetails(context, chat, widget.conversation);
      }
      if (!mounted) return;
      if (action == 'edit') {
        await Navigator.of(context).push(
          MaterialPageRoute<String>(
            builder: (_) =>
                ContactPicker(chat: chat, group: widget.conversation),
          ),
        );
        await chat.refresh();
      }
      if (!mounted) return;
      if (action == 'clear' || action == 'delete' || action == 'leave') {
        if (!await confirm(
          context,
          action == 'leave'
              ? 'Leave group?'
              : action == 'delete'
              ? 'Delete conversation?'
              : 'Clear messages?',
          action == 'leave'
              ? 'You will lose access to this group.'
              : 'This clears history for your account. Other members keep their messages.',
        )) {
          return;
        }
        if (action == 'leave') {
          await chat.api.post('/conversations/$id/leave');
        } else {
          await chat.api.delete(
            '/conversations/$id?hide=${action == 'delete'}',
          );
        }
        await chat.clearLocal(id);
        chat.history.remove(id);
        chat.cursors.remove(id);
        await chat.refresh();
        if (action == 'clear') {
          composer.clear();
          reply = null;
          await chat.load(id);
        } else {
          widget.onBack();
        }
      }
    } catch (e) {
      error(e);
    }
  }

  List<Json> mentions() {
    if (dismissMentions) return [];
    if (widget.conversation['type'] != 'Group' ||
        composer.selection.baseOffset < 0) {
      return [];
    }
    final prefix = composer.text.substring(0, composer.selection.baseOffset);
    final match = RegExp(r'(?:^|\s)@(\w*)$').firstMatch(prefix);
    if (match == null) return [];
    final q = match.group(1)!.toLowerCase();
    return widget.conversation
        .objects('profiles')
        .where((p) => '${p['name']} ${p['username']}'.toLowerCase().contains(q))
        .take(6)
        .toList();
  }

  void insertMention(Json p) {
    final offset = composer.selection.baseOffset;
    final start = composer.text.lastIndexOf('@', offset - 1);
    final text = '@${p['username']} ';
    composer.value = TextEditingValue(
      text: composer.text.replaceRange(start, offset, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    textChanged(composer.text);
    focus.requestFocus();
  }

  KeyEventResult composerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final options = mentions();
    final key = event.logicalKey;
    if (options.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown ||
          key == LogicalKeyboardKey.arrowUp) {
        setState(
          () => mentionIndex =
              (mentionIndex + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) %
              options.length,
        );
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
        insertMention(options[mentionIndex.clamp(0, options.length - 1)]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        setState(() => dismissMentions = true);
        return KeyEventResult.handled;
      }
    }
    if (key == LogicalKeyboardKey.escape && reply != null) {
      setState(() => reply = null);
      persist();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    positions.itemPositions.removeListener(positionChanged);
    events?.cancel();
    typingTimer?.cancel();
    recordLimit?.cancel();
    recordClock?.cancel();
    recorder.dispose();
    composer.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conversation;
    final group = c['type'] == 'Group';
    final messages = (chat.history[id] ?? []).reversed.toList();
    renderedMessages = messages;
    final suggestions = mentions();
    final isTyping =
        DateTime.now().difference(chat.typing[id] ?? DateTime(2000)).inSeconds <
        4;
    final peer = (c['members'] as List).where((p) => p != chat.uid).firstOrNull;
    return ColoredBox(
      color: ChatColors.panel,
      child: Column(
        children: [
          Container(
            height: ChatLayout.header(context),
            color: Colors.white,
            child: Row(
              children: [
                if (!ChatLayout.split(context))
                  IconButton(
                    tooltip: 'Back to chats',
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, size: 22),
                  ),
                if (!ChatLayout.phone(context)) ...[
                  const SizedBox(width: 16),
                  Avatar(c.str('name'), group: group, seed: peer),
                  const SizedBox(width: 16),
                ],
                Expanded(
                  child: InkWell(
                    onTap: group ? () => groupDetails(context, chat, c) : null,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          c.str('name'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        Row(
                          children: [
                            if (!group &&
                                !isTyping &&
                                chat.online[peer] == true) ...[
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: Color(0xff10b981),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              isTyping
                                  ? 'typing…'
                                  : group
                                  ? '${(c['members'] as List).length} members'
                                  : chat.online[peer] == true
                                  ? 'Online'
                                  : 'Offline',
                              style: TextStyle(
                                fontSize: 11,
                                color: isTyping || chat.online[peer] == true
                                    ? const Color(0xff10b981)
                                    : ChatColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Voice call',
                  onPressed: () => widget.onCall(false),
                  icon: const Icon(
                    Icons.phone_outlined,
                    color: ChatColors.muted,
                    size: 22,
                  ),
                ),
                IconButton(
                  tooltip: 'Video call',
                  onPressed: () => widget.onCall(true),
                  icon: const Icon(
                    Icons.videocam_outlined,
                    color: ChatColors.muted,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Conversation options',
                  onSelected: menu,
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'refresh',
                      child: ChatMenuLabel('Refresh', Icons.refresh),
                    ),
                    const PopupMenuItem(
                      value: 'search',
                      child: ChatMenuLabel(
                        'Search in conversation',
                        Icons.search,
                      ),
                    ),
                    if (group)
                      const PopupMenuItem(
                        value: 'details',
                        child: ChatMenuLabel(
                          'Group details',
                          Icons.info_outline,
                        ),
                      ),
                    if (group && c['owner'] == chat.uid)
                      const PopupMenuItem(
                        value: 'edit',
                        child: ChatMenuLabel(
                          'Edit group and members',
                          Icons.edit_outlined,
                        ),
                      ),
                    const PopupMenuItem(
                      value: 'clear',
                      child: ChatMenuLabel(
                        'Clear messages',
                        Icons.cleaning_services_outlined,
                        destructive: true,
                      ),
                    ),
                    if (group)
                      const PopupMenuItem(
                        value: 'leave',
                        child: ChatMenuLabel(
                          'Leave group',
                          Icons.logout,
                          destructive: true,
                        ),
                      )
                    else
                      const PopupMenuItem(
                        value: 'delete',
                        child: ChatMenuLabel(
                          'Delete conversation',
                          Icons.delete_outline,
                          destructive: true,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xffedf3f9),
                    Color(0xffe7effc),
                    Color(0xffedf3f9),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: CustomPaint(
                painter: ChatWallpaper(),
                child: Stack(
                  children: [
                    if (messages.isEmpty && chat.fetching.contains(id))
                      const Center(child: CircularProgressIndicator())
                    else if (messages.isEmpty)
                      Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Avatar(c.str('name'), group: group, radius: 36),
                            const SizedBox(height: 16),
                            Text(
                              c.str('name'),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                              ),
                              child: Text(
                                group
                                    ? 'This is the beginning of this group.'
                                    : 'This is the beginning of your conversation.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: ChatColors.muted),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      Align(
                        alignment: Alignment.topCenter,
                        child: ScrollablePositionedList.builder(
                          shrinkWrap: true,
                          itemScrollController: scroll,
                          itemPositionsListener: positions,
                          reverse: true,
                          padding: EdgeInsets.symmetric(
                            vertical: 18,
                            horizontal: threadInset,
                          ),
                          itemCount: messages.length + 1,
                          itemBuilder: (_, index) {
                            if (index == messages.length) {
                              if (!paged && chat.cursors[id] == null) {
                                return const SizedBox.shrink();
                              }
                              return Center(
                                child: chat.fetching.contains(id)
                                    ? const Padding(
                                        padding: EdgeInsets.all(12),
                                        child: CircularProgressIndicator(),
                                      )
                                    : TextButton(
                                        onPressed: chat.cursors[id] == null
                                            ? null
                                            : () {
                                                paged = true;
                                                chat.load(id, older: true);
                                              },
                                        child: Text(
                                          chat.cursors[id] == null
                                              ? 'Beginning of conversation'
                                              : 'Load older messages',
                                        ),
                                      ),
                              );
                            }
                            final m = messages[index];
                            final older = index + 1 < messages.length
                                ? messages[index + 1]
                                : null;
                            final date = DateTime.parse(
                              m.str('createdAt'),
                            ).toLocal();
                            final day = DateFormat.yMd().format(date);
                            final olderDay = older == null
                                ? ''
                                : DateFormat.yMd().format(
                                    DateTime.parse(
                                      older.str('createdAt'),
                                    ).toLocal(),
                                  );
                            final first =
                                older == null ||
                                older['senderId'] != m['senderId'] ||
                                day != olderDay;
                            return Column(
                              children: [
                                if (day != olderDay)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: .85,
                                        ),
                                        borderRadius: BorderRadius.circular(24),
                                        border: Border.all(
                                          color: ChatColors.border,
                                        ),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 7,
                                        ),
                                        child: Text(
                                          day ==
                                                  DateFormat.yMd().format(
                                                    DateTime.now(),
                                                  )
                                              ? 'TODAY'
                                              : DateFormat.yMMMd()
                                                    .format(date)
                                                    .toUpperCase(),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: .7,
                                            color: ChatColors.muted,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                bubble(m, first, group),
                              ],
                            );
                          },
                        ),
                      ),
                    if (newMessages > 0)
                      Positioned(
                        bottom: 12,
                        left: 12,
                        right: 12,
                        child: Center(
                          child: FloatingActionButton.extended(
                            backgroundColor: Colors.white,
                            foregroundColor: ChatColors.blue,
                            heroTag: 'new-$id',
                            onPressed: () {
                              scroll.jumpTo(index: 0);
                              setState(() => newMessages = 0);
                              chat.markRead(id);
                            },
                            label: Text(
                              '$newMessages new ${newMessages == 1 ? 'message' : 'messages'}',
                            ),
                            icon: const Icon(Icons.arrow_downward),
                          ),
                        ),
                      ),
                    if (jumping)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (chat.error != null)
            TextButton(
              onPressed: () => chat.load(id),
              child: Text('${chat.error} Retry'),
            ),
          if (reply != null)
            Container(
              margin: EdgeInsets.fromLTRB(
                ChatLayout.phone(context) ? 12 : 24,
                8,
                ChatLayout.phone(context) ? 12 : 24,
                0,
              ),
              decoration: BoxDecoration(
                color: ChatColors.soft,
                border: const Border(
                  left: BorderSide(color: ChatColors.blue, width: 3),
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
              child: Row(
                children: [
                  const Icon(Icons.reply, color: ChatColors.blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reply!.str('senderName'),
                          style: const TextStyle(
                            color: ChatColors.blue,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          quoteFor(reply!).str('preview'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel reply',
                    onPressed: () {
                      setState(() => reply = null);
                      persist();
                      focus.requestFocus();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          if (suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 190),
              child: ListView(
                shrinkWrap: true,
                children: suggestions
                    .map(
                      (p) => ListTile(
                        selected: suggestions.indexOf(p) == mentionIndex,
                        selectedTileColor: ChatColors.soft,
                        dense: true,
                        leading: Avatar(p.str('name'), radius: 16),
                        title: Text(p.str('name')),
                        subtitle: Text('@${p['username']}'),
                        onTap: () => insertMention(p),
                      ),
                    )
                    .toList(),
              ),
            ),
          Container(
            margin: ChatLayout.phone(context)
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(24, 8, 24, 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: ChatLayout.phone(context)
                  ? null
                  : BorderRadius.circular(20),
              border: Border.all(color: ChatColors.border),
            ),
            padding: EdgeInsets.symmetric(
              vertical: ChatLayout.phone(context) ? 8 : 10,
              horizontal: 8,
            ),
            child: recording
                ? Row(
                    children: [
                      IconButton(
                        tooltip: 'Cancel recording',
                        onPressed: () => stopRecording(send: false),
                        icon: const Icon(Icons.delete_outline),
                      ),
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Recording voice note',
                                style: TextStyle(color: Colors.red),
                              ),
                              Text(
                                '${recordSeconds ~/ 60}:${(recordSeconds % 60).toString().padLeft(2, '0')}',
                                style: const TextStyle(
                                  color: ChatColors.muted,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Finish recording',
                        style: IconButton.styleFrom(
                          backgroundColor: ChatColors.blue,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: stopRecording,
                        icon: const Icon(
                          Icons.stop_circle,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: 'Attach file',
                        onPressed: attach,
                        icon: const Icon(
                          Icons.attach_file,
                          color: ChatColors.muted,
                        ),
                      ),
                      Expanded(
                        child: TextField(
                          controller: composer,
                          focusNode: focus,
                          minLines: 1,
                          maxLines: 5,
                          maxLength: 4000,
                          onChanged: textChanged,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            hintText: 'Type a message',
                            counterText: '',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: composer.text.trim().isEmpty
                            ? 'Record voice note'
                            : 'Send message',
                        style: IconButton.styleFrom(
                          backgroundColor: composer.text.trim().isEmpty
                              ? Colors.transparent
                              : ChatColors.blue,
                          foregroundColor: composer.text.trim().isEmpty
                              ? ChatColors.blue
                              : Colors.white,
                        ),
                        onPressed: composer.text.trim().isEmpty
                            ? startRecording
                            : send,
                        icon: Icon(
                          composer.text.trim().isEmpty
                              ? Icons.mic_none
                              : Icons.send_rounded,
                          color: composer.text.trim().isEmpty
                              ? ChatColors.blue
                              : Colors.white,
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget bubble(Json m, bool first, bool group) {
    final mine = m['senderId'] == chat.uid;
    final quote = m['reply'] as Map?;
    final foreground = mine ? Colors.white : ChatColors.ink;
    final panelWidth =
        MediaQuery.sizeOf(context).width -
        (ChatLayout.split(context) ? 391 : 0);
    final maxWidth = math.max(
      90.0,
      math.min(620.0, panelWidth - threadInset * 2 - 36 - (group ? 42 : 0)),
    );
    final measure = TextPainter(
      text: TextSpan(
        text: m.str('text'),
        style: const TextStyle(
          fontFamily: 'Roboto',
          fontSize: 14.5,
          height: 1.55,
          letterSpacing: .25,
        ),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth - 44);
    final bubbleWidth = quote != null || m['attachment'] != null
        ? math.min(maxWidth, 300.0)
        : math.min(maxWidth, math.max(92.0, measure.width + 50));
    measure.dispose();
    return Padding(
      padding: EdgeInsets.only(
        top: first ? 8 : 2,
        bottom: 4,
        left: mine ? 36 : 0,
        right: mine ? 0 : 36,
      ),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (group && !mine)
            SizedBox(
              width: 42,
              child: first
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: Avatar(
                        m.str('senderName'),
                        seed: m.str('senderId'),
                        radius: 16,
                      ),
                    )
                  : null,
            ),
          Flexible(
            child: Container(
              width: bubbleWidth,
              constraints: const BoxConstraints(maxWidth: 620),
              decoration: BoxDecoration(
                color: mine ? null : Colors.white,
                gradient: mine
                    ? const LinearGradient(
                        colors: [Color(0xff3475ed), ChatColors.blue],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                border: m['id'] == highlight
                    ? Border.all(color: const Color(0xffe5ad18), width: 3)
                    : null,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(first && !mine ? 0 : 8),
                  topRight: Radius.circular(first && mine ? 0 : 8),
                  bottomLeft: const Radius.circular(8),
                  bottomRight: const Radius.circular(8),
                ),
                boxShadow: [
                  BoxShadow(
                    color: ChatColors.ink.withValues(alpha: .035),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (first)
                    Positioned(
                      top: 0,
                      left: mine ? null : -8,
                      right: mine ? -8 : null,
                      child: CustomPaint(
                        size: const Size(9, 14),
                        painter: ChatBubbleTail(mine: mine),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (group && first)
                          Padding(
                            padding: const EdgeInsets.only(
                              right: 18,
                              bottom: 4,
                            ),
                            child: Text(
                              m.str('senderName'),
                              style: TextStyle(
                                color: mine ? Colors.white : ChatColors.blue,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        if (quote != null)
                          InkWell(
                            onTap: () => jump(quote['id'] as String),
                            child: Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(
                                bottom: 8,
                                right: 10,
                              ),
                              padding: const EdgeInsets.all(9),
                              decoration: BoxDecoration(
                                color: mine
                                    ? Colors.white.withValues(alpha: .15)
                                    : ChatColors.soft,
                                border: Border(
                                  left: BorderSide(
                                    color: mine
                                        ? Colors.white70
                                        : ChatColors.blue,
                                    width: 3,
                                  ),
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    quote['senderName'] as String,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    quote['preview'] as String,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: foreground,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (m['attachment'] != null)
                          AttachmentView(
                            key: ValueKey(m['id']),
                            chat: chat,
                            message: m,
                            mine: mine,
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text.rich(
                              TextSpan(
                                children: mentionSpans(
                                  m.str('text'),
                                  foreground,
                                ),
                              ),
                              style: TextStyle(
                                color: foreground,
                                fontSize: 14.5,
                                height: 1.55,
                              ),
                            ),
                          ),
                        const SizedBox(height: 5),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              DateFormat.Hm().format(
                                DateTime.parse(m.str('createdAt')).toLocal(),
                              ),
                              style: TextStyle(
                                fontSize: 10,
                                color: mine ? Colors.white70 : ChatColors.muted,
                              ),
                            ),
                            if (mine) ...[
                              const SizedBox(width: 4),
                              if (m['pending'] == true)
                                Flexible(
                                  child: InkWell(
                                    onTap: () => chat.retry(m),
                                    child: Text(
                                      m['failed'] == true
                                          ? 'Not confirmed · Retry'
                                          : 'Sending…',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Icon(
                                  chat.isRead(widget.conversation, m)
                                      ? Icons.done_all
                                      : Icons.done,
                                  size: 17,
                                  color: Colors.white,
                                ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (m['pending'] != true)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: PopupMenuButton<String>(
                          padding: EdgeInsets.zero,
                          iconSize: 17,
                          icon: Icon(
                            Icons.keyboard_arrow_down,
                            color: mine ? Colors.white70 : ChatColors.muted,
                            size: 17,
                          ),
                          tooltip: 'Message options',
                          onSelected: (value) async {
                            if (value == 'reply') {
                              setState(() => reply = m);
                              persist();
                              focus.requestFocus();
                            }
                            if (value == 'copy') {
                              await Clipboard.setData(
                                ClipboardData(text: m.str('text')),
                              );
                            }
                            if (value == 'delete' &&
                                mounted &&
                                await confirm(
                                  context,
                                  'Delete message?',
                                  'This message will be removed for everyone.',
                                )) {
                              try {
                                await chat.api.delete(
                                  '/conversations/$id/messages/${m['id']}',
                                );
                                chat.history[id]?.removeWhere(
                                  (x) => x['id'] == m['id'],
                                );
                                chat.notify();
                              } catch (e) {
                                error(e);
                              }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'reply',
                              child: ChatMenuLabel('Reply', Icons.reply),
                            ),
                            const PopupMenuItem(
                              value: 'copy',
                              child: ChatMenuLabel('Copy', Icons.copy_outlined),
                            ),
                            if (mine)
                              const PopupMenuItem(
                                value: 'delete',
                                child: ChatMenuLabel(
                                  'Delete',
                                  Icons.delete_outline,
                                  destructive: true,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (group && mine)
            SizedBox(
              width: 42,
              child: first
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: Avatar(
                        m.str('senderName'),
                        seed: m.str('senderId'),
                        radius: 16,
                      ),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  List<TextSpan> mentionSpans(String text, Color color) {
    final members = widget.conversation
        .objects('profiles')
        .map((p) => p.str('username'))
        .toSet();
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in RegExp(r'(?<![\w@])@(\w+)').allMatches(text)) {
      spans.add(TextSpan(text: text.substring(offset, match.start)));
      spans.add(
        TextSpan(
          text: match.group(0),
          style: members.contains(match.group(1)?.toLowerCase())
              ? TextStyle(
                  fontWeight: FontWeight.w700,
                  backgroundColor: color.withValues(alpha: .12),
                )
              : null,
        ),
      );
      offset = match.end;
    }
    spans.add(TextSpan(text: text.substring(offset)));
    return spans;
  }
}
