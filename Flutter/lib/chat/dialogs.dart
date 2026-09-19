import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'api.dart';
import 'chat_state.dart';
import 'theme.dart';

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    ) ??
    false;

class ContactPicker extends StatefulWidget {
  const ContactPicker({
    super.key,
    required this.chat,
    this.group,
    this.initialMode = 'direct',
  });
  final ChatState chat;
  final Json? group;
  final String initialMode;
  @override
  State<ContactPicker> createState() => _ContactPickerState();
}

class _ContactPickerState extends State<ContactPicker> {
  final query = TextEditingController(),
      name = TextEditingController(),
      broadcast = TextEditingController();
  final Map<String, Json> selected = {};
  List<Json> contacts = [];
  late String mode = widget.initialMode;
  String? cursor, error;
  bool busy = false, loading = false, attempted = false, selectedOnly = false;
  String requestId = const Uuid().v4();
  Timer? debounce;
  int generation = 0;
  bool get editing => widget.group != null;
  bool get canContinue =>
      !busy &&
      selected.length <= 49 &&
      selected.length >= (mode == 'group' && !editing ? 2 : 1);
  @override
  void initState() {
    super.initState();
    if (editing) {
      mode = 'group';
      name.text = widget.group!.str('name');
      for (final p in widget.group!.objects('profiles')) {
        if (p['id'] != widget.chat.uid) selected[p.str('id')] = p;
      }
    }
    load();
  }

  Future<void> load({bool more = false}) async {
    final gen = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final data = Map<String, dynamic>.from(
        await widget.chat.api.get('/users', {
          'q': query.text,
          if (more) 'after': cursor,
        }),
      );
      if (!mounted || gen != generation) return;
      setState(() {
        contacts = more
            ? [...contacts, ...data.objects('items')]
            : data.objects('items');
        cursor = data['nextCursor'] as String?;
      });
    } catch (e) {
      if (mounted && gen == generation) setState(() => error = Api.error(e));
    } finally {
      if (mounted && gen == generation) setState(() => loading = false);
    }
  }

  Future<void> choose(Json p) async {
    if (busy) return;
    if (mode == 'direct') {
      setState(() {
        busy = true;
        error = null;
      });
      try {
        final result = await widget.chat.api.post('/conversations', {
          'members': [p['id']],
          'name': null,
        });
        if (mounted) Navigator.pop(context, result['id'] as String);
      } catch (e) {
        if (mounted) setState(() => error = Api.error(e));
      } finally {
        if (mounted) setState(() => busy = false);
      }
    } else {
      setState(() {
        error = null;
        if (selected.containsKey(p['id'])) {
          selected.remove(p['id']);
        } else if (selected.length == 49) {
          error = mode == 'group'
              ? 'A group can have up to 50 members.'
              : 'Select up to 49 recipients.';
        } else {
          selected[p.str('id')] = p;
        }
      });
    }
  }

  Future<void> saveGroup() async {
    if (!canContinue || name.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.chat.api.put(
        '/conversations/${widget.group!['id']}',
        {
          'members': [widget.chat.uid, ...selected.keys],
          'name': name.text.trim(),
          'revision': widget.group!['revision'],
        },
      );
      if (mounted) Navigator.pop(context, result['id'] as String);
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> compose() async {
    if (!canContinue) return;
    String? dialogError;
    bool submitting = false;
    final isBroadcast = mode == 'broadcast';
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, redraw) => PopScope(
          canPop: !submitting,
          child: Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
            ),
            insetPadding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 620,
                maxHeight: MediaQuery.sizeOf(dialogContext).height * .9,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isBroadcast
                              ? Icons.campaign_outlined
                              : Icons.group_add_outlined,
                          size: 30,
                          color: ChatColors.blue,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isBroadcast
                                    ? 'BROADCAST MESSAGE'
                                    : 'NEW CONVERSATION',
                                style: const TextStyle(
                                  color: ChatColors.blue,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1,
                                ),
                              ),
                              Text(
                                isBroadcast
                                    ? 'Write your message'
                                    : 'Name your group',
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isBroadcast
                          ? 'Each person receives a separate direct message.'
                          : 'Give your group a name everyone will recognize.',
                      style: const TextStyle(color: ChatColors.muted),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      isBroadcast
                          ? '${selected.length} recipient${selected.length == 1 ? '' : 's'}'
                          : '${selected.length + 1} members including you',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: selected.values
                          .map(
                            (p) => Chip(
                              avatar: Avatar(p.str('name'), radius: 12),
                              label: Text(p.str('name')),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: isBroadcast ? broadcast : name,
                      autofocus: true,
                      readOnly: submitting || attempted,
                      maxLength: isBroadcast ? 4000 : 80,
                      minLines: isBroadcast ? 4 : 1,
                      maxLines: isBroadcast ? 6 : 1,
                      onChanged: (_) => redraw(() {}),
                      decoration: InputDecoration(
                        labelText: isBroadcast ? 'Message' : 'Group name',
                        hintText: isBroadcast
                            ? 'Type your message'
                            : 'e.g. Operations team',
                        helperText: isBroadcast
                            ? null
                            : 'You will be the group owner',
                      ),
                    ),
                    if (dialogError != null)
                      Semantics(
                        liveRegion: true,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            dialogError!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          onPressed: submitting
                              ? null
                              : () => Navigator.pop(dialogContext),
                          child: Text(attempted ? 'Close' : 'Back'),
                        ),
                        FilledButton(
                          onPressed:
                              submitting ||
                                  (isBroadcast ? broadcast.text : name.text)
                                      .trim()
                                      .isEmpty
                              ? null
                              : () async {
                                  redraw(() {
                                    submitting = true;
                                    dialogError = null;
                                  });
                                  try {
                                    if (isBroadcast) {
                                      attempted = true;
                                      final results =
                                          await widget.chat.api.post(
                                                '/broadcasts',
                                                {
                                                  'recipients': selected.keys
                                                      .toList(),
                                                  'clientMessageId': requestId,
                                                  'text': broadcast.text,
                                                },
                                              )
                                              as List;
                                      for (final row in results) {
                                        if (row['error'] == null) {
                                          selected.remove(row['recipient']);
                                        }
                                      }
                                      if (selected.isNotEmpty) {
                                        redraw(
                                          () => dialogError =
                                              'Some recipients were not confirmed. Retry to finish sending.',
                                        );
                                        return;
                                      }
                                      await widget.chat.refresh();
                                      if (dialogContext.mounted) {
                                        Navigator.pop(
                                          dialogContext,
                                          'broadcast-complete',
                                        );
                                      }
                                    } else {
                                      final result = await widget.chat.api
                                          .post('/conversations', {
                                            'members': selected.keys.toList(),
                                            'name': name.text.trim(),
                                          });
                                      if (dialogContext.mounted) {
                                        Navigator.pop(
                                          dialogContext,
                                          result['id'] as String,
                                        );
                                      }
                                    }
                                  } catch (e) {
                                    if (dialogContext.mounted) {
                                      redraw(() => dialogError = Api.error(e));
                                    }
                                  } finally {
                                    if (dialogContext.mounted) {
                                      redraw(() => submitting = false);
                                    }
                                  }
                                },
                          child: Text(
                            submitting
                                ? isBroadcast
                                      ? 'Sending…'
                                      : 'Creating…'
                                : isBroadcast
                                ? attempted
                                      ? 'Retry broadcast'
                                      : 'Send broadcast'
                                : 'Create group',
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
      ),
    );
    if (!mounted) return;
    if (result != null) {
      Navigator.pop(context, result == 'broadcast-complete' ? null : result);
    } else {
      setState(() {
        attempted = false;
        requestId = const Uuid().v4();
      });
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    query.dispose();
    name.dispose();
    broadcast.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final available = {
      for (final p in contacts) p.str('id'): p,
      if (editing) ...selected,
    };
    final people =
        available.values
            .where(
              (p) =>
                  (!selectedOnly || selected.containsKey(p['id'])) &&
                  '${p['name']} ${p['username']}'.toLowerCase().contains(
                    query.text.toLowerCase(),
                  ),
            )
            .toList()
          ..sort((a, b) => a.str('name').compareTo(b.str('name')));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          editing
              ? 'Edit group and members'
              : mode == 'group'
              ? 'New group'
              : mode == 'broadcast'
              ? 'Broadcast message'
              : 'New chat',
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh contacts',
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (editing)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: TextField(
                  controller: name,
                  enabled: !busy,
                  maxLength: 80,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: 'Group name'),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  editing
                      ? 'Select to add a member. Deselect to remove them.'
                      : mode == 'group'
                      ? 'Select at least 2 people'
                      : mode == 'broadcast'
                      ? 'Select recipients'
                      : 'Pick someone to message',
                  style: const TextStyle(color: ChatColors.muted),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: query,
                enabled: !busy,
                decoration: InputDecoration(
                  hintText: editing
                      ? 'Search name or username'
                      : mode == 'direct'
                      ? 'Search name or number'
                      : 'Search people',
                  prefixIcon: const Icon(Icons.search),
                ),
                onChanged: (_) {
                  setState(() {});
                  debounce?.cancel();
                  debounce = Timer(const Duration(milliseconds: 250), load);
                },
              ),
            ),
            if (editing) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: const Text('All people'),
                      selected: !selectedOnly,
                      onSelected: (_) => setState(() => selectedOnly = false),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Selected'),
                      selected: selectedOnly,
                      onSelected: (_) => setState(() => selectedOnly = true),
                    ),
                  ],
                ),
              ),
              const ListTile(
                dense: true,
                leading: Icon(
                  Icons.verified_user_outlined,
                  color: ChatColors.blue,
                ),
                title: Text('You remain the group owner'),
              ),
            ],
            if (error != null)
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ),
            if (loading || busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView(
                children: [
                  if (mode == 'direct' && !editing) ...[
                    ListTile(
                      leading: const Avatar('', group: true),
                      title: const Text('Create a group'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() {
                        mode = 'group';
                        selected.clear();
                      }),
                    ),
                    ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: ChatColors.soft,
                        child: Icon(
                          Icons.campaign_outlined,
                          color: ChatColors.blue,
                        ),
                      ),
                      title: const Text('Broadcast message'),
                      subtitle: const Text('Send a message to several people'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => setState(() {
                        mode = 'broadcast';
                        selected.clear();
                      }),
                    ),
                  ],
                  if (people.isEmpty && !loading)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        error != null
                            ? 'Contacts could not be loaded. Use Refresh to retry.'
                            : selectedOnly
                            ? 'No selected members match your search.'
                            : 'No matching users. Try a different name.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final p in people)
                    ListTile(
                      leading: Avatar(
                        p.str('name'),
                        seed: p.str('username'),
                        online: mode == 'direct' ? p['online'] == true : null,
                      ),
                      title: Text(p.str('name')),
                      subtitle: Text('@${p['username']}'),
                      selected: selected.containsKey(p['id']),
                      selectedTileColor: ChatColors.soft,
                      trailing: mode == 'direct'
                          ? null
                          : Checkbox(
                              value: selected.containsKey(p['id']),
                              onChanged: busy ? null : (_) => choose(p),
                            ),
                      onTap: busy ? null : () => choose(p),
                    ),
                  if (cursor != null && !selectedOnly)
                    TextButton(
                      onPressed: loading ? null : () => load(more: true),
                      child: const Text('Load more contacts'),
                    ),
                ],
              ),
            ),
            if (mode != 'direct')
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(top: BorderSide(color: ChatColors.border)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (selected.isNotEmpty)
                      SizedBox(
                        height: 44,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: selected.values
                              .map(
                                (p) => Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: InputChip(
                                    avatar: Avatar(p.str('name'), radius: 12),
                                    label: Text(p.str('name')),
                                    onDeleted: busy
                                        ? null
                                        : () => setState(
                                            () => selected.remove(p['id']),
                                          ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            editing
                                ? '${selected.length + 1} / 50 members'
                                : '${selected.length} selected${mode == 'group' ? ' · 50 members max' : ''}',
                            style: const TextStyle(
                              color: ChatColors.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (editing)
                          FilledButton(
                            onPressed:
                                canContinue && name.text.trim().isNotEmpty
                                ? saveGroup
                                : null,
                            child: Text(busy ? 'Saving…' : 'Save changes'),
                          )
                        else
                          IconButton.filled(
                            tooltip: mode == 'broadcast'
                                ? 'Next: write message'
                                : 'Next: name group',
                            onPressed: canContinue ? compose : null,
                            icon: const Icon(Icons.arrow_forward),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> groupDetails(BuildContext context, ChatState chat, Json c) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => GroupDetails(chat: chat, conversation: c),
    );

class GroupDetails extends StatefulWidget {
  const GroupDetails({
    super.key,
    required this.chat,
    required this.conversation,
  });
  final ChatState chat;
  final Json conversation;
  @override
  State<GroupDetails> createState() => _GroupDetailsState();
}

class _GroupDetailsState extends State<GroupDetails> {
  List<Json>? members;
  String query = '';
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data =
          await widget.chat.api.get(
                '/conversations/${widget.conversation['id']}/members',
              )
              as List;
      if (mounted) {
        setState(() {
          members = data.map((e) => Map<String, dynamic>.from(e)).toList();
          members!.sort((a, b) => a.str('name').compareTo(b.str('name')));
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(
        children: [
          Avatar(widget.conversation.str('name'), group: true, radius: 32),
          const SizedBox(height: 12),
          Text(
            widget.conversation.str('name'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(
            '${members?.length ?? '…'} members',
            style: const TextStyle(color: ChatColors.muted),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Find a member',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => query = v.toLowerCase()),
            ),
          ),
          if (error != null)
            TextButton(onPressed: load, child: Text('$error Retry')),
          Expanded(
            child: error != null
                ? const Center(
                    child: Text('Group members could not be loaded.'),
                  )
                : members == null
                ? const Center(child: CircularProgressIndicator())
                : members!
                      .where(
                        (m) => '${m['name']} ${m['username']}'
                            .toLowerCase()
                            .contains(query),
                      )
                      .isEmpty
                ? const Center(child: Text('No members match your search.'))
                : ListView(
                    children: members!
                        .where(
                          (m) => '${m['name']} ${m['username']}'
                              .toLowerCase()
                              .contains(query),
                        )
                        .map(
                          (m) => ListTile(
                            leading: Avatar(m.str('name')),
                            title: Text(m.str('name')),
                            subtitle: Text('@${m['username']}'),
                            trailing: Text(
                              m['id'] == widget.chat.uid
                                  ? 'You'
                                  : m['id'] == widget.conversation['owner']
                                  ? 'Owner'
                                  : '',
                            ),
                          ),
                        )
                        .toList(),
                  ),
          ),
        ],
      ),
    ),
  );
}

Future<Json?> openSearch(
  BuildContext context,
  ChatState chat, {
  Json? conversation,
}) => Navigator.of(context).push<Json>(
  MaterialPageRoute(
    builder: (_) => MessageSearch(chat: chat, conversation: conversation),
  ),
);

class MessageSearch extends StatefulWidget {
  const MessageSearch({super.key, required this.chat, this.conversation});
  final ChatState chat;
  final Json? conversation;
  @override
  State<MessageSearch> createState() => _MessageSearchState();
}

class _MessageSearchState extends State<MessageSearch> {
  final query = TextEditingController();
  List<Json> results = [];
  String? cursor, error;
  bool busy = false;
  String submitted = '';
  Future<void> search({bool more = false}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      if (!more) {
        submitted = query.text.trim();
        results = [];
        cursor = null;
      }
    });
    try {
      final data = Map<String, dynamic>.from(
        await widget.chat.api.get('/messages/search', {
          'q': submitted,
          if (widget.conversation != null)
            'conversationId': widget.conversation!['id'],
          if (more) 'before': cursor,
        }),
      );
      if (mounted) {
        setState(() {
          results.addAll(data.objects('items'));
          cursor = data['nextCursor'] as String?;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.conversation == null
            ? 'Search message content'
            : 'Search in ${widget.conversation!['name']}',
      ),
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: query,
            autofocus: true,
            maxLength: 200,
            onSubmitted: (_) => search(),
            decoration: InputDecoration(
              hintText: 'Search saved messages',
              suffixIcon: IconButton(
                tooltip: 'Search',
                onPressed: busy ? null : search,
                icon: const Icon(Icons.search),
              ),
            ),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        Expanded(
          child: results.isEmpty && !busy
              ? Center(
                  child: Text(
                    submitted.length >= 2
                        ? 'No messages found.'
                        : 'Enter at least 2 characters to find messages.',
                  ),
                )
              : ListView(
                  children: [
                    for (final m in results)
                      ListTile(
                        leading: Avatar(m.str('senderName')),
                        title: Text(
                          '${m['senderName']} · ${widget.chat.conversations.where((c) => c['id'] == m['conversationId']).firstOrNull?['name'] ?? ''}',
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            HighlightedText(
                              text: m.str('text'),
                              query: submitted,
                            ),
                            Text(
                              DateFormat.yMMMd().add_Hm().format(
                                DateTime.parse(m.str('createdAt')).toLocal(),
                              ),
                              style: const TextStyle(
                                fontSize: 11,
                                color: ChatColors.muted,
                              ),
                            ),
                          ],
                        ),
                        onTap: () async {
                          final nav = Navigator.of(context);
                          widget.chat.focusMessageId = m.str('id');
                          await widget.chat.select(m.str('conversationId'));
                          nav.pop(m);
                        },
                      ),
                    if (cursor != null)
                      TextButton(
                        onPressed: busy ? null : () => search(more: true),
                        child: const Text('Load more results'),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}

class HighlightedText extends StatelessWidget {
  const HighlightedText({super.key, required this.text, required this.query});
  final String text, query;
  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) return Text(text);
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in RegExp(
      RegExp.escape(query),
      caseSensitive: false,
    ).allMatches(text)) {
      spans.add(TextSpan(text: text.substring(offset, match.start)));
      spans.add(
        TextSpan(
          text: match.group(0),
          style: const TextStyle(
            backgroundColor: Color(0xffffe99a),
            color: ChatColors.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      offset = match.end;
    }
    spans.add(TextSpan(text: text.substring(offset)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 4,
      overflow: TextOverflow.ellipsis,
    );
  }
}
