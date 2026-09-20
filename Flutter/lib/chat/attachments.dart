import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';
import 'api.dart';
import 'chat_state.dart';
import 'theme.dart';
import 'quotes.dart';
import 'ui.dart';

Future<bool?> previewUpload(
  BuildContext context,
  ChatState chat,
  Json conversation,
  String path,
  String name, {
  Json? reply,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UploadPreview(
    chat: chat,
    conversation: conversation,
    path: path,
    name: name,
    reply: reply,
  ),
);

class UploadPreview extends StatefulWidget {
  const UploadPreview({
    super.key,
    required this.chat,
    required this.conversation,
    required this.path,
    required this.name,
    this.reply,
  });
  final ChatState chat;
  final Json conversation;
  final String path, name;
  final Json? reply;
  @override
  State<UploadPreview> createState() => _UploadPreviewState();
}

class _UploadPreviewState extends State<UploadPreview> {
  final requestId = const Uuid().v4();
  CancelToken? cancel;
  bool busy = false;
  double progress = 0;
  String? error;
  int size = 0;
  late String mime;
  @override
  void initState() {
    super.initState();
    mime = lookupMimeType(widget.path) ?? 'application/octet-stream';
    File(widget.path)
        .length()
        .then((v) {
          if (mounted) setState(() => size = v);
        })
        .catchError((Object _) {
          if (mounted) {
            setState(
              () =>
                  error = 'This file is no longer available. Choose it again.',
            );
          }
        });
  }

  Future<void> upload() async {
    if (busy) return;
    if (size <= 0 || size > 25 * 1024 * 1024) {
      setState(() => error = 'Choose a file between 1 byte and 25 MB.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
      progress = 0;
    });
    cancel = CancelToken();
    try {
      final data = FormData.fromMap({
        'clientMessageId': requestId,
        if (widget.reply != null) 'replyToMessageId': widget.reply!['id'],
        'file': await MultipartFile.fromFile(
          widget.path,
          filename: widget.name,
          contentType: DioMediaType.parse(mime),
        ),
      });
      final response = await widget.chat.api.dio.post<dynamic>(
        '/conversations/${widget.conversation['id']}/attachments',
        data: data,
        cancelToken: cancel,
        onSendProgress: (sent, total) {
          if (mounted) setState(() => progress = total == 0 ? 0 : sent / total);
        },
      );
      widget.chat.merge(Map<String, dynamic>.from(response.data));
      await widget.chat.refresh();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    cancel?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text('Send to ${widget.conversation['name']}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.reply != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: ChatColors.soft,
                    border: const Border(
                      left: BorderSide(color: ChatColors.blue, width: 3),
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Replying to ${widget.reply!.str('senderName')}',
                        style: const TextStyle(
                          color: ChatColors.blue,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        quoteFor(widget.reply!).str('preview'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              if (mime.startsWith('image/'))
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(widget.path),
                    height: 200,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) =>
                        const Icon(Icons.broken_image_outlined, size: 64),
                  ),
                )
              else if (mime.startsWith('audio/'))
                AudioControl(path: widget.path)
              else if (mime.startsWith('video/'))
                SizedBox(height: 200, child: VideoPreview(path: widget.path))
              else
                const Icon(
                  Icons.insert_drive_file_outlined,
                  size: 64,
                  color: ChatColors.blue,
                ),
              const SizedBox(height: 16),
              Text(
                widget.name,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                fileSizeLabel(size),
                style: const TextStyle(color: ChatColors.muted),
              ),
              if (busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress < 1 ? progress : null),
                Text(
                  progress < 1
                      ? '${(progress * 100).round()}%'
                      : 'Saving message…',
                ),
              ],
              if (error != null) ChatNotice(error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (busy) {
              cancel?.cancel();
            } else {
              Navigator.pop(context);
            }
          },
          child: Text(busy ? 'Cancel upload' : 'Close'),
        ),
        FilledButton(
          onPressed: busy ? null : upload,
          child: Text(error != null ? 'Retry' : 'Send'),
        ),
      ],
    ),
  );
}

class AttachmentView extends StatefulWidget {
  const AttachmentView({
    super.key,
    required this.chat,
    required this.message,
    required this.mine,
  });
  final ChatState chat;
  final Json message;
  final bool mine;
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  String? localPath;
  String? error;
  bool busy = false;
  Json get attachment =>
      Map<String, dynamic>.from(widget.message['attachment']);
  @override
  void initState() {
    super.initState();
    if (widget.message['type'] == 'Image' ||
        widget.message['type'] == 'Video') {
      download(open: false);
    }
  }

  Future<void> download({bool open = true}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final dir = await getTemporaryDirectory();
      final safeName = attachment
          .str('fileName')
          .replaceAll(RegExp(r'[^\w.\- ]'), '_');
      final path = '${dir.path}/${attachment['id']}-$safeName';
      // Always authenticate before opening even a previously cached file.
      await widget.chat.api.dio.download(
        '/conversations/${widget.message['conversationId']}/attachments/${attachment['id']}',
        path,
      );
      if (!mounted) return;
      setState(() => localPath = path);
      if (open && widget.message['type'] == 'Image') {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                title: Text(attachment.str('fileName')),
                actions: [
                  IconButton(
                    tooltip: 'Download image',
                    onPressed: save,
                    icon: const Icon(Icons.download),
                  ),
                ],
              ),
              body: Center(
                child: InteractiveViewer(
                  minScale: .5,
                  maxScale: 5,
                  child: Image.file(File(path)),
                ),
              ),
            ),
          ),
        );
      } else if (open &&
          widget.message['type'] != 'Audio' &&
          widget.message['type'] != 'Video') {
        await OpenFilex.open(path);
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    await download(open: false);
    if (!mounted || localPath == null || error != null) return;
    try {
      final result = await FilePicker.saveFile(
        fileName: attachment.str('fileName'),
        bytes: await File(localPath!).readAsBytes(),
        mimeType: attachment.str('mimeType'),
      );
      if (mounted && result != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('File saved')));
      }
    } catch (e) {
      if (mounted) setState(() => error = Api.error(e));
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (widget.message['type'] == 'Image' && localPath != null)
        GestureDetector(
          onTap: download,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(
              File(localPath!),
              width: 230,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
      if (widget.message['type'] == 'Audio' && localPath != null)
        AudioControl(path: localPath!, light: widget.mine),
      if (widget.message['type'] == 'Video' && localPath != null)
        SizedBox(height: 180, child: VideoPreview(path: localPath!)),
      InkWell(
        onTap: busy ? null : download,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.message['type'] == 'Audio'
                    ? Icons.play_circle_outline
                    : Icons.file_download_outlined,
                color: widget.mine ? Colors.white : ChatColors.blue,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  attachment.str('fileName'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: widget.mine ? Colors.white : ChatColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              fileSizeLabel((attachment['size'] as num).toInt()),
              style: TextStyle(
                fontSize: 11,
                color: widget.mine ? Colors.white70 : ChatColors.muted,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Download attachment',
            onPressed: busy ? null : save,
            icon: Icon(
              Icons.download,
              size: 18,
              color: widget.mine ? Colors.white70 : ChatColors.muted,
            ),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (error != null)
        Text(
          error!,
          style: TextStyle(
            fontSize: 12,
            color: widget.mine ? Colors.white : Colors.red,
          ),
        ),
    ],
  );
}

class AudioControl extends StatefulWidget {
  const AudioControl({super.key, required this.path, this.light = false});
  final String path;
  final bool light;
  @override
  State<AudioControl> createState() => _AudioControlState();
}

class _AudioControlState extends State<AudioControl> {
  final player = AudioPlayer();
  bool playing = false;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  @override
  void initState() {
    super.initState();
    player.onPositionChanged.listen((p) {
      if (mounted) setState(() => position = p);
    });
    player.onDurationChanged.listen((d) {
      if (mounted) setState(() => duration = d);
    });
    player.onPlayerStateChanged.listen((p) {
      if (mounted) setState(() => playing = p == PlayerState.playing);
    });
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: playing ? 'Pause voice note' : 'Play voice note',
        color: widget.light ? Colors.white : ChatColors.blue,
        icon: Icon(
          playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
        ),
        onPressed: () async {
          if (playing) {
            await player.pause();
          } else {
            await player.play(DeviceFileSource(widget.path));
          }
        },
      ),
      Expanded(
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
          ),
          child: Slider(
            semanticFormatterCallback: (v) => '${v.round()} seconds',
            activeColor: widget.light ? Colors.white : ChatColors.blue,
            value: position.inMilliseconds.toDouble().clamp(
              0,
              duration.inMilliseconds.toDouble(),
            ),
            max: duration.inMilliseconds > 0
                ? duration.inMilliseconds.toDouble()
                : 1,
            onChanged: duration > Duration.zero
                ? (v) => player.seek(Duration(milliseconds: v.round()))
                : null,
          ),
        ),
      ),
      Text(
        '${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')}',
        style: TextStyle(color: widget.light ? Colors.white : ChatColors.ink),
      ),
    ],
  );
}

class VideoPreview extends StatefulWidget {
  const VideoPreview({super.key, required this.path});
  final String path;
  @override
  State<VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<VideoPreview> {
  late final controller = VideoPlayerController.file(File(widget.path));
  bool failed = false;
  @override
  void initState() {
    super.initState();
    controller
        .initialize()
        .then((_) {
          if (mounted) setState(() {});
        })
        .catchError((Object _) {
          if (mounted) setState(() => failed = true);
        });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => failed
      ? const Center(
          child: Text('Preview unavailable. You can still send this file.'),
        )
      : !controller.value.isInitialized
      ? const Center(child: CircularProgressIndicator())
      : Stack(
          alignment: Alignment.center,
          children: [
            AspectRatio(
              aspectRatio: controller.value.aspectRatio,
              child: VideoPlayer(controller),
            ),
            IconButton.filled(
              onPressed: () {
                controller.value.isPlaying
                    ? controller.pause()
                    : controller.play();
                setState(() {});
              },
              icon: Icon(
                controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
              ),
            ),
          ],
        );
}
