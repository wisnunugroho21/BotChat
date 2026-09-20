import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:intl/intl.dart';
import 'api.dart';
import 'chat_state.dart';
import 'theme.dart';
import 'ui.dart';

class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.chat,
    required this.initial,
    this.autoAnswer = false,
  });
  final bool autoAnswer;
  final ChatState chat;
  final Json initial;
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late Json call = widget.initial;
  final local = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> remotes = {};
  final Map<String, RTCPeerConnection> peers = {};
  final Map<String, List<RTCIceCandidate>> candidates = {};
  final Set<String> remoteReady = {};
  final Set<String> creating = {};
  MediaStream? media;
  StreamSubscription<Json>? events;
  Timer? poll, ringtone;
  Timer? clock;
  bool muted = false,
      camera = true,
      speaker = false,
      busy = false,
      joining = false,
      closing = false;
  String? error;
  String get uid => widget.chat.uid;
  String get id => call.str('id');
  bool get joined => (call['joined'] as List).contains(uid);
  bool get incoming =>
      call['callerId'] != uid && !joined && call['endedAt'] == null;
  @override
  void initState() {
    super.initState();
    clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && call['answeredAt'] != null) setState(() {});
    });
    events = widget.chat.events.stream.listen((event) async {
      if (event['event'] == 'NativeAnswer' &&
          event['callId'] == id &&
          incoming) {
        await respond('join');
      }
      if (event['event'] == 'CallChanged' &&
          (event['data'] as Map)['id'] == id) {
        await changed(Map<String, dynamic>.from(event['data']));
      }
      if (event['event'] == 'CallSignal' &&
          (event['data'] as Map)['callId'] == id) {
        try {
          await signal(Map<String, dynamic>.from(event['data']));
        } catch (e) {
          if (mounted) {
            setState(
              () => error = 'Call connection failed. Check your network.',
            );
          }
        }
      }
    });
    local.initialize().then((_) async {
      if (!mounted || closing) return;
      if (widget.autoAnswer && incoming) await respond('join');
      if (joined) await prepare();
      if (mounted) setState(() {});
    });
    if (incoming) {
      SystemSound.play(SystemSoundType.alert);
      ringtone = Timer.periodic(const Duration(seconds: 3), (_) {
        if (mounted && incoming) SystemSound.play(SystemSoundType.alert);
      });
    }
    poll = Timer.periodic(const Duration(seconds: 5), (_) async {
      try {
        await changed(
          Map<String, dynamic>.from(await widget.chat.api.get('/calls/$id')),
        );
      } catch (_) {}
    });
  }

  Future<void> prepare() async {
    if (media != null || joining) return;
    joining = true;
    try {
      media = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': call['video'] == true
            ? {'facingMode': 'user', 'width': 640, 'height': 480}
            : false,
      });
      if (!mounted || closing) {
        for (final track in media!.getTracks()) {
          await track.stop();
        }
        await media!.dispose();
        media = null;
        return;
      }
      local.srcObject = media;
      if (joined) await connectPeers();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Allow microphone${call['video'] == true ? ' and camera' : ''} access to join the call.',
        );
      }
    } finally {
      joining = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> changed(Json update) async {
    if (!mounted || closing) return;
    setState(() => call = update);
    if (!incoming) ringtone?.cancel();
    if (call['endedAt'] != null) {
      await close();
      return;
    }
    if (joined && media != null) await connectPeers();
  }

  Future<RTCPeerConnection> peer(String recipient) async {
    if (peers.containsKey(recipient)) return peers[recipient]!;
    final servers = <Json>[
      {'urls': 'stun:stun.l.google.com:19302'},
    ];
    const turn = String.fromEnvironment('TURN_URL');
    if (turn.isNotEmpty) {
      servers.add({
        'urls': turn,
        'username': const String.fromEnvironment('TURN_USERNAME'),
        'credential': const String.fromEnvironment('TURN_CREDENTIAL'),
      });
    }
    final pc = await createPeerConnection({'iceServers': servers});
    peers[recipient] = pc;
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    remotes[recipient] = renderer;
    for (final track in media?.getTracks() ?? <MediaStreamTrack>[]) {
      await pc.addTrack(track, media!);
    }
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        sendSignal(recipient, 'candidate', candidate.toMap());
      }
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
        if (mounted) setState(() {});
      }
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
          mounted) {
        setState(
          () => error =
              'Media connection failed. A TURN server may be required on this network.',
        );
      }
    };
    return pc;
  }

  Future<void> connectPeers() async {
    final joinedIds = (call['joined'] as List).cast<String>();
    for (final recipient in peers.keys.toList()) {
      if (!joinedIds.contains(recipient)) {
        await peers.remove(recipient)?.close();
        await remotes.remove(recipient)?.dispose();
        remoteReady.remove(recipient);
      }
    }
    for (final recipient in joinedIds.where((p) => p != uid)) {
      // One deterministic offerer per pair prevents simultaneous-offer glare.
      if (uid.compareTo(recipient) < 0 &&
          !peers.containsKey(recipient) &&
          creating.add(recipient)) {
        try {
          final pc = await peer(recipient);
          final offer = await pc.createOffer();
          await pc.setLocalDescription(offer);
          await sendSignal(recipient, 'offer', offer.toMap());
        } finally {
          creating.remove(recipient);
        }
      }
    }
  }

  Future<void> sendSignal(String recipient, String kind, Json payload) async {
    try {
      await widget.chat.hub?.invoke(
        'Signal',
        args: [id, recipient, kind, jsonEncode(payload)],
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Call signaling disconnected. Please end the call and retry.',
        );
      }
    }
  }

  Future<void> signal(Json data) async {
    final from = data.str('senderId');
    final payload = Map<String, dynamic>.from(jsonDecode(data.str('payload')));
    if (data['kind'] == 'candidate') {
      final candidate = RTCIceCandidate(
        payload['candidate'] as String?,
        payload['sdpMid'] as String?,
        payload['sdpMLineIndex'] as int?,
      );
      if (remoteReady.contains(from)) {
        await peers[from]?.addCandidate(candidate);
      } else {
        candidates.putIfAbsent(from, () => []).add(candidate);
      }
      return;
    }
    if (media == null) await prepare();
    if (media == null) return;
    final pc = await peer(from);
    await pc.setRemoteDescription(
      RTCSessionDescription(
        payload['sdp'] as String?,
        payload['type'] as String?,
      ),
    );
    remoteReady.add(from);
    for (final candidate in candidates.remove(from) ?? <RTCIceCandidate>[]) {
      await pc.addCandidate(candidate);
    }
    if (data['kind'] == 'offer') {
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      await sendSignal(from, 'answer', answer.toMap());
    }
  }

  Future<void> respond(String action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (action == 'join') {
        await prepare();
        if (media == null) return;
      }
      final result = Map<String, dynamic>.from(
        await widget.chat.api.post('/calls/$id/$action'),
      );
      if (action != 'join') {
        await close();
      } else {
        await changed(result);
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> close() async {
    if (closing) return;
    closing = true;
    ringtone?.cancel();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    events?.cancel();
    poll?.cancel();
    clock?.cancel();
    ringtone?.cancel();
    for (final pc in peers.values) {
      pc.close();
    }
    for (final renderer in remotes.values) {
      renderer.dispose();
    }
    for (final track in media?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    media?.dispose();
    local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chat.conversations
        .where((c) => c['id'] == call['conversationId'])
        .firstOrNull;
    final profiles = c?.objects('profiles') ?? <Json>[];
    final group = (call['members'] as List).length > 2;
    final answered = DateTime.tryParse(call.str('answeredAt'));
    final duration = answered == null
        ? Duration.zero
        : DateTime.now().toUtc().difference(answered);
    final elapsed =
        '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';
    Widget video(RTCVideoRenderer renderer, {bool self = false}) =>
        RTCVideoView(
          renderer,
          mirror: self,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        );
    Widget? stage;
    if (call['video'] == true && !incoming && media != null) {
      if (group) {
        stage = GridView.count(
          crossAxisCount: 2,
          childAspectRatio: .9,
          padding: const EdgeInsets.all(12),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            videoTile(
              'You',
              camera
                  ? video(local, self: true)
                  : const Icon(
                      Icons.videocam_off_outlined,
                      color: Colors.white70,
                      size: 42,
                    ),
            ),
            for (final member in (call['members'] as List).where(
              (p) => p != uid,
            ))
              videoTile(
                profiles
                        .where((p) => p['id'] == member)
                        .firstOrNull
                        ?.str('name') ??
                    'Participant',
                remotes[member]?.srcObject == null
                    ? const Icon(
                        Icons.person_outline,
                        color: Colors.white70,
                        size: 42,
                      )
                    : video(remotes[member]!),
              ),
          ],
        );
      } else {
        stage = Stack(
          fit: StackFit.expand,
          children: [
            if (remotes.values.firstOrNull?.srcObject != null)
              video(remotes.values.first)
            else
              const Center(
                child: Text(
                  'Waiting for video…',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            Positioned(
              right: 16,
              bottom: 16,
              width: 112,
              height: 152,
              child: videoTile(
                'You',
                camera
                    ? video(local, self: true)
                    : const Icon(
                        Icons.videocam_off_outlined,
                        color: Colors.white70,
                      ),
              ),
            ),
          ],
        );
      }
    }
    return PopScope(
      canPop: closing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) respond(incoming ? 'decline' : 'leave');
      },
      child: CallPresentation(
        name: c?.str('name') ?? call.str('callerName'),
        video: call['video'] == true,
        incoming: incoming,
        group: group,
        status: incoming
            ? 'Incoming call…'
            : call['status'] == 'Ringing'
            ? 'Calling…'
            : elapsed,
        muted: muted,
        camera: camera,
        speaker: speaker,
        busy: busy,
        error: error,
        stage: stage,
        participants: group
            ? profiles
                  .map(
                    (p) => {
                      'name': p['id'] == uid ? 'You' : p['name'],
                      'state': (call['joined'] as List).contains(p['id'])
                          ? 'Connected'
                          : (call['declined'] as List? ?? []).contains(p['id'])
                          ? 'Declined'
                          : 'Ringing…',
                    },
                  )
                  .toList()
            : [],
        onAccept: () => respond('join'),
        onEnd: () => respond(incoming ? 'decline' : 'leave'),
        onMute: () {
          setState(() => muted = !muted);
          for (final track in media?.getAudioTracks() ?? <MediaStreamTrack>[]) {
            track.enabled = !muted;
          }
        },
        onCamera: () {
          setState(() => camera = !camera);
          for (final track in media?.getVideoTracks() ?? <MediaStreamTrack>[]) {
            track.enabled = camera;
          }
        },
        onSpeaker: () async {
          setState(() => speaker = !speaker);
          await Helper.setSpeakerphoneOn(speaker);
        },
      ),
    );
  }

  Widget videoTile(String name, Widget child) => ClipRRect(
    borderRadius: BorderRadius.circular(16),
    child: ColoredBox(
      color: const Color(0xff183e73),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(child: child),
          Positioned(
            left: 8,
            bottom: 8,
            child: Text(
              name,
              style: const TextStyle(
                color: Colors.white,
                backgroundColor: Colors.black45,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Shared call surface, independent of native media, so all call states can be rendered in UI tests.
class CallPresentation extends StatelessWidget {
  const CallPresentation({
    super.key,
    required this.name,
    required this.status,
    required this.video,
    required this.incoming,
    required this.onAccept,
    required this.onEnd,
    required this.onMute,
    required this.onCamera,
    required this.onSpeaker,
    this.group = false,
    this.muted = false,
    this.camera = true,
    this.speaker = false,
    this.busy = false,
    this.error,
    this.stage,
    this.participants = const [],
  });
  final String name, status;
  final bool video, incoming, group, muted, camera, speaker, busy;
  final String? error;
  final Widget? stage;
  final List<Json> participants;
  final VoidCallback onAccept, onEnd, onMute, onCamera, onSpeaker;
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xff061322),
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xff183e73), Color(0xff0c2445), Color(0xff061322)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Column(
              children: [
                if (stage == null) const Spacer(),
                if (stage == null &&
                    MediaQuery.sizeOf(context).height >= 600) ...[
                  Avatar(name, group: group, radius: incoming ? 52 : 60),
                  const SizedBox(height: 24),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Text(
                    name,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Semantics(
                  liveRegion: incoming,
                  child: Text(
                    status,
                    style: const TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        video ? Icons.videocam_outlined : Icons.call_outlined,
                        color: Colors.white70,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${group ? 'Group ' : ''}${video ? 'Video call' : 'Voice call'}',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (stage != null)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: stage!,
                    ),
                  )
                else ...[
                  if (participants.isNotEmpty)
                    Flexible(
                      child: Container(
                        margin: const EdgeInsets.all(24),
                        constraints: const BoxConstraints(
                          maxWidth: 460,
                          maxHeight: 240,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: .06),
                          border: Border.all(color: Colors.white12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: ListView(
                          shrinkWrap: true,
                          children: participants
                              .map(
                                (p) => ListTile(
                                  leading: Avatar(p.str('name'), radius: 18),
                                  title: Text(
                                    p.str('name'),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                    ),
                                  ),
                                  trailing: Text(
                                    p.str('state'),
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  const Spacer(),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.amber),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                  child: Wrap(
                    spacing: 20,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: incoming
                        ? [
                            control(
                              'Decline',
                              Icons.call_end,
                              Colors.red,
                              onEnd,
                            ),
                            control(
                              'Accept',
                              Icons.call,
                              const Color(0xff10b981),
                              onAccept,
                            ),
                          ]
                        : [
                            control(
                              muted ? 'Unmute' : 'Mute',
                              muted ? Icons.mic_off : Icons.mic,
                              muted ? ChatColors.blue : Colors.white12,
                              onMute,
                            ),
                            if (video)
                              control(
                                camera ? 'Camera off' : 'Camera on',
                                camera ? Icons.videocam : Icons.videocam_off,
                                camera ? Colors.white12 : ChatColors.blue,
                                onCamera,
                              ),
                            control(
                              'Speaker',
                              speaker ? Icons.volume_up : Icons.volume_down,
                              speaker ? ChatColors.blue : Colors.white12,
                              onSpeaker,
                            ),
                            control(
                              'End call',
                              Icons.call_end,
                              const Color(0xffdc2626),
                              onEnd,
                            ),
                          ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Widget control(String label, IconData icon, Color color, VoidCallback tap) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              fixedSize: const Size(56, 56),
              shape: const CircleBorder(),
            ),
            tooltip: label,
            onPressed: busy ? null : tap,
            icon: Icon(icon),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      );
}

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({
    super.key,
    required this.chat,
    required this.onCall,
  });
  final ChatState chat;
  final void Function(Json, bool) onCall;
  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  List<Json>? calls;
  String? error;
  bool missedOnly = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final data = await widget.chat.api.get('/calls') as List;
      if (mounted) {
        setState(() {
          calls = data.map((c) => Map<String, dynamic>.from(c)).toList();
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    }
  }

  String dayLabel(DateTime day) {
    final today = DateTime.now();
    if (DateUtils.isSameDay(day, today)) return 'Today';
    if (DateUtils.isSameDay(day, today.subtract(const Duration(days: 1)))) {
      return 'Yesterday';
    }
    return DateFormat.yMMMd().format(day);
  }

  @override
  Widget build(BuildContext context) {
    final visible = (calls ?? [])
        .where(
          (c) =>
              !missedOnly ||
              c['status'] == 'Missed' && c['callerId'] != widget.chat.uid,
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call history'),
        actions: [
          IconButton(
            tooltip: 'Refresh call history',
            onPressed: load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All calls'),
                  selected: !missedOnly,
                  onSelected: (_) => setState(() => missedOnly = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Missed'),
                  selected: missedOnly,
                  onSelected: (_) => setState(() => missedOnly = true),
                ),
              ],
            ),
          ),
          Expanded(
            child: error != null
                ? ChatEmptyState(
                    icon: Icons.cloud_off_outlined,
                    title: 'Couldn’t load your calls',
                    description: error!,
                    action: 'Try again',
                    onAction: load,
                  )
                : calls == null
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? ChatEmptyState(
                    icon: missedOnly
                        ? Icons.phone_missed_outlined
                        : Icons.call_outlined,
                    title: missedOnly ? 'No missed calls' : 'No calls yet',
                    description: missedOnly
                        ? 'You’re all caught up with your team.'
                        : 'Start a voice or video call from any conversation.',
                  )
                : RefreshIndicator(
                    onRefresh: load,
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final call = visible[index];
                        final c = widget.chat.conversations
                            .where((c) => c['id'] == call['conversationId'])
                            .firstOrNull;
                        final name = c?.str('name') ?? call.str('callerName');
                        final outgoing = call['callerId'] == widget.chat.uid;
                        final missed = call['status'] == 'Missed' && !outgoing;
                        final date = DateTime.parse(
                          call.str('createdAt'),
                        ).toLocal();
                        final showDay =
                            index == 0 ||
                            !DateUtils.isSameDay(
                              date,
                              DateTime.parse(
                                visible[index - 1].str('createdAt'),
                              ).toLocal(),
                            );
                        final answered = DateTime.tryParse(
                              call.str('answeredAt'),
                            ),
                            ended = DateTime.tryParse(call.str('endedAt'));
                        final seconds = answered != null && ended != null
                            ? ended
                                  .difference(answered)
                                  .inSeconds
                                  .clamp(0, 86400)
                            : null;
                        final detail = seconds == null
                            ? call.str('status')
                            : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showDay)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  16,
                                  12,
                                  8,
                                ),
                                child: Text(
                                  dayLabel(date),
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: ChatColors.muted,
                                  ),
                                ),
                              ),
                            Card(
                              elevation: 0,
                              color: Colors.white,
                              margin: const EdgeInsets.symmetric(vertical: 3),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: const BorderSide(
                                  color: ChatColors.border,
                                ),
                              ),
                              child: ListTile(
                                leading: Avatar(
                                  name,
                                  group: c?['type'] == 'Group',
                                ),
                                title: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: missed
                                        ? const Color(0xffdc2626)
                                        : ChatColors.ink,
                                  ),
                                ),
                                subtitle: Row(
                                  children: [
                                    Icon(
                                      missed
                                          ? Icons.call_missed
                                          : outgoing
                                          ? Icons.call_made
                                          : Icons.call_received,
                                      size: 14,
                                      color: missed
                                          ? const Color(0xffdc2626)
                                          : ChatColors.muted,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        '${outgoing ? 'Outgoing' : 'Incoming'} · $detail',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                trailing: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      DateFormat.Hm().format(date),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: ChatColors.muted,
                                      ),
                                    ),
                                    SizedBox(
                                      height: 40,
                                      width: 44,
                                      child: IconButton(
                                        tooltip: 'Call again',
                                        onPressed: c == null
                                            ? null
                                            : () => widget.onCall(
                                                c,
                                                call['video'] == true,
                                              ),
                                        icon: Icon(
                                          call['video'] == true
                                              ? Icons.videocam_outlined
                                              : Icons.phone_outlined,
                                          color: c == null
                                              ? ChatColors.muted
                                              : ChatColors.blue,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
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
