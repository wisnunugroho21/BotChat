import 'package:flutter/material.dart';
import 'api.dart';
import 'chat_state.dart';
import 'quotes.dart';
import 'theme.dart';
import 'ui.dart';

class PinnedMessages extends StatefulWidget {
  const PinnedMessages({
    super.key,
    required this.chat,
    required this.conversationId,
  });
  final ChatState chat;
  final String conversationId;
  @override
  State<PinnedMessages> createState() => _PinnedMessagesState();
}

class _PinnedMessagesState extends State<PinnedMessages> {
  List<Json> messages = [];
  bool loading = true;
  final busy = <String>{};
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result =
          await widget.chat.api.get(
                '/conversations/${widget.conversationId}/pins',
              )
              as List;
      if (mounted) {
        setState(() {
          messages = result
              .map((m) => Map<String, dynamic>.from(m as Map))
              .toList();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> unpin(Json message) async {
    final id = message.str('id');
    setState(() => busy.add(id));
    try {
      await widget.chat.pinMessage(widget.conversationId, id, false);
      await load();
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Pinned messages'),
      actions: [
        IconButton(
          tooltip: 'Refresh pinned messages',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        const ListTile(
          leading: Icon(Icons.push_pin_outlined, color: ChatColors.blue),
          title: Text('Saved for you'),
          subtitle: Text(
            'Pins are private. Tap a message to see it in the conversation.',
          ),
        ),
        if (error != null)
          TextButton.icon(
            onPressed: load,
            icon: const Icon(Icons.refresh),
            label: Text(error!),
          ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : messages.isEmpty
              ? const ChatEmptyState(
                  icon: Icons.push_pin_outlined,
                  title: 'No pinned messages yet',
                  description:
                      'Use Pin for me in a message’s options to keep it close at hand.',
                )
              : RefreshIndicator(
                  onRefresh: load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: messages.length,
                    itemBuilder: (_, index) {
                      final m = messages[index];
                      return Card(
                        color: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: ChatColors.border),
                        ),
                        child: ListTile(
                          leading: Avatar(
                            m.str('senderName'),
                            seed: m.str('senderId'),
                            radius: 18,
                          ),
                          title: Text(m.str('senderName')),
                          subtitle: Text(
                            quoteFor(m).str('preview'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Unpin message',
                            onPressed: busy.contains(m['id'])
                                ? null
                                : () => unpin(m),
                            icon: const Icon(
                              Icons.push_pin,
                              color: ChatColors.blue,
                            ),
                          ),
                          onTap: () => Navigator.pop(context, m),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    ),
  );
}
