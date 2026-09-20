import 'package:flutter/material.dart';
import 'package:path_drawing/path_drawing.dart';

abstract final class ChatColors {
  static const blue = Color(0xff2563eb);
  static const ink = Color(0xff172b4d);
  static const muted = Color(0xff62718a);
  static const panel = Color(0xfff6f8fc);
  static const border = Color(0xffe1e7f0);
  static const canvas = Color(0xffedf2f8);
  static const soft = Color(0xffe8f1ff);
}

ThemeData chatTheme() => ThemeData(
  useMaterial3: true,
  dialogTheme: const DialogThemeData(
    backgroundColor: Colors.white,
    surfaceTintColor: Colors.transparent,
  ),
  fontFamily: 'Roboto',
  textTheme: const TextTheme(
    bodyLarge: TextStyle(fontSize: 14, height: 1.5, color: ChatColors.ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: ChatColors.ink),
    titleMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: ChatColors.ink,
    ),
    bodySmall: TextStyle(fontSize: 12, height: 1.5, color: ChatColors.muted),
  ),
  popupMenuTheme: PopupMenuThemeData(
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    elevation: 8,
    shadowColor: ChatColors.ink.withValues(alpha: .14),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: ChatColors.border),
    ),
    textStyle: const TextStyle(
      fontFamily: 'Roboto',
      fontSize: 14,
      color: ChatColors.ink,
    ),
  ),
  listTileTheme: const ListTileThemeData(
    iconColor: ChatColors.muted,
    textColor: ChatColors.ink,
    titleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: ChatColors.ink,
    ),
    subtitleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 12,
      height: 1.5,
      color: ChatColors.muted,
    ),
    minVerticalPadding: 12,
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      foregroundColor: ChatColors.muted,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
  chipTheme: ChipThemeData(
    showCheckmark: false,
    selectedColor: ChatColors.soft,
    backgroundColor: Colors.white,
    side: const BorderSide(color: ChatColors.border),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    labelStyle: const TextStyle(fontFamily: 'Roboto', color: ChatColors.ink),
  ),
  colorScheme: ColorScheme.fromSeed(
    seedColor: ChatColors.blue,
    primary: ChatColors.blue,
    surface: Colors.white,
    onSurface: ChatColors.ink,
  ),
  scaffoldBackgroundColor: ChatColors.panel,
  appBarTheme: const AppBarTheme(
    backgroundColor: Colors.white,
    foregroundColor: ChatColors.ink,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    titleTextStyle: TextStyle(
      fontFamily: 'Roboto',
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: ChatColors.ink,
    ),
  ),
  dividerColor: ChatColors.border,
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: ChatColors.panel,
    hintStyle: const TextStyle(
      fontFamily: 'Roboto',
      fontSize: 14,
      color: ChatColors.muted,
    ),
    prefixIconColor: ChatColors.muted,
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: Color(0xff60a5fa), width: 1.5),
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: ChatColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: ChatColors.border),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(44, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  ),
);

abstract final class ChatLayout {
  static bool split(BuildContext context) =>
      MediaQuery.sizeOf(context).width > 900;
  static bool phone(BuildContext context) =>
      MediaQuery.sizeOf(context).width <= 600;
  static double header(BuildContext context) => phone(context) ? 64 : 72;
}

class ChatMenuLabel extends StatelessWidget {
  const ChatMenuLabel(
    this.text,
    this.icon, {
    super.key,
    this.destructive = false,
  });
  final String text;
  final IconData icon;
  final bool destructive;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(
        icon,
        size: 20,
        color: destructive ? const Color(0xffdc2626) : ChatColors.muted,
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          text,
          style: TextStyle(
            color: destructive ? const Color(0xffdc2626) : ChatColors.ink,
          ),
        ),
      ),
    ],
  );
}

/// Original chat-bubble-tail.svg silhouette, mirrored for outgoing messages.
class ChatBubbleTail extends CustomPainter {
  const ChatBubbleTail({required this.mine});
  final bool mine;
  @override
  void paint(Canvas canvas, Size size) {
    if (mine) {
      canvas.translate(9, 0);
      canvas.scale(-1, 1);
    }
    canvas.drawPath(
      parseSvgPathData('M1.5 0H9V14L.3 2A1.2 1.2 0 0 1 1.5 0Z'),
      Paint()..color = mine ? const Color(0xff3475ed) : Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant ChatBubbleTail oldDelegate) =>
      oldDelegate.mine != mine;
}

class Avatar extends StatelessWidget {
  const Avatar(
    this.name, {
    super.key,
    this.radius = 22,
    this.group = false,
    this.seed,
    this.online,
    this.memberCount,
  });
  final String name;
  final double radius;
  final bool group;
  final String? seed;
  final bool? online;
  final int? memberCount;
  static const backgrounds = [
    Color(0xffe2ebff),
    Color(0xffe1f2ef),
    Color(0xffe0f0fa),
    Color(0xffeee7fa),
    Color(0xfffff0dc),
    Color(0xfff9e6ec),
  ];
  static const foregrounds = [
    Color(0xff2756b3),
    Color(0xff236c60),
    Color(0xff246888),
    Color(0xff6a46a1),
    Color(0xff906021),
    Color(0xff9a4463),
  ];
  int get colorIndex {
    var hash = 0;
    for (final unit in (seed ?? name).codeUnits) {
      hash = (hash * 31 + unit) & 0xffffffff;
    }
    return hash % 6;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: group
        ? '$name, ${memberCount ?? ''} group members'
        : '$name${online == null
              ? ''
              : online!
              ? ', online'
              : ', offline'}',
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: radius * 2,
          height: radius * 2,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: group ? null : backgrounds[colorIndex],
            gradient: group
                ? const LinearGradient(
                    colors: [Color(0xff7c3aed), Color(0xff4f46e5)],
                  )
                : null,
          ),
          child: group
              ? Icon(Icons.groups_outlined, size: radius, color: Colors.white)
              : Text(
                  initials(name),
                  style: TextStyle(
                    color: foregrounds[colorIndex],
                    fontSize: radius * .65,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        if (group && memberCount != null)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xff4f46e5),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: Text(
                '$memberCount',
                style: const TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
        if (!group && online != null)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 13,
              height: 13,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: online!
                    ? const Color(0xff10b981)
                    : const Color(0xffa8b6c5),
                border: Border.all(color: ChatColors.panel, width: 3),
              ),
            ),
          ),
      ],
    ),
  );
  static String initials(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    return words.isEmpty
        ? '?'
        : (words.length == 1
                  ? words.first.characters.take(2).toString()
                  : words.take(2).map((s) => s.characters.first).join())
              .toUpperCase();
  }
}

class ConversationTile extends StatelessWidget {
  const ConversationTile({
    super.key,
    required this.name,
    required this.preview,
    required this.onTap,
    this.seed,
    this.time = '',
    this.unread = 0,
    this.selected = false,
    this.group = false,
    this.online = false,
    this.memberCount = 0,
    this.mine = false,
    this.read = false,
    this.draft = false,
    this.pinned = false,
    this.muted = false,
    this.onLongPress,
  });
  final String name, preview, time;
  final String? seed;
  final int unread, memberCount;
  final bool selected, group, online, mine, read, draft;
  final bool pinned, muted;
  final VoidCallback? onLongPress;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
    child: Material(
      color: selected ? ChatColors.soft : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? const Color(0xffccddfb) : Colors.transparent,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          constraints: const BoxConstraints(minHeight: 78),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          decoration: BoxDecoration(
            border: selected
                ? const Border(
                    left: BorderSide(color: ChatColors.blue, width: 3),
                  )
                : null,
          ),
          child: Row(
            children: [
              Avatar(
                name,
                radius: 24.5,
                group: group,
                seed: seed,
                online: group ? null : online,
                memberCount: group ? memberCount : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: selected
                                  ? ChatColors.blue
                                  : ChatColors.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          time,
                          style: TextStyle(
                            fontSize: 11,
                            color: unread > 0
                                ? ChatColors.blue
                                : ChatColors.muted,
                            fontWeight: unread > 0
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        if (pinned)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.push_pin,
                              size: 14,
                              color: ChatColors.blue,
                            ),
                          ),
                        if (muted)
                          const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: Icon(
                              Icons.notifications_off_outlined,
                              size: 14,
                              color: ChatColors.muted,
                            ),
                          ),
                        if (mine && !draft) ...[
                          Icon(
                            read ? Icons.done_all : Icons.done,
                            size: 16,
                            color: read ? ChatColors.blue : ChatColors.muted,
                          ),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: draft ? ChatColors.blue : ChatColors.muted,
                            ),
                          ),
                        ),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            constraints: const BoxConstraints(
                              minWidth: 20,
                              minHeight: 20,
                            ),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            decoration: BoxDecoration(
                              color: ChatColors.blue,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$unread',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

// Paths and 260px tile spacing ported directly from TMS Website/wwwroot/css/chat.css.
class ChatWallpaper extends CustomPainter {
  static final marks = [
    'M96 28l13 13-13 13-13-13z',
    'M150 34h26M150 44h18',
    'M212 26c8 0 12 6 12 12s-6 12-14 12h-4l-8 7v-7c-4-2-6-6-6-12 0-6 6-12 20-12z',
    'M28 104c6-8 16-8 22 0M24 118h34',
    'M92 96l10 22-22-8z',
    'M150 124h18',
    'M206 100v22M198 110h18',
    'M34 178h24v18H42l-8 7z',
    'M104 172c8-6 16 2 10 10l-12 14-12-14c-6-8 6-16 14-10z',
    'M152 186h24M164 176v20',
    'M204 172l14 8-14 8z',
    'M120 226h30v16h-30z',
    'M188 224v20M182 244h14',
  ].map(parseSvgPathData).toList();
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ChatColors.blue.withValues(alpha: .0175)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (double y = -64; y < size.height; y += 260) {
      for (double x = 0; x < size.width; x += 260) {
        canvas.save();
        canvas.translate(x, y);
        canvas.drawCircle(const Offset(34, 40), 11, paint);
        canvas.drawCircle(const Offset(158, 108), 9, paint);
        canvas.drawCircle(const Offset(70, 232), 8, paint);
        for (final path in marks) {
          canvas.drawPath(path, paint);
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
