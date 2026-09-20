import 'api.dart';

/// A stable preview shared by the composer, upload confirmation and outbox.
Json quoteFor(Json message) {
  final attachment = message['attachment'] as Map?;
  final type = message.str('type').isEmpty ? 'Text' : message.str('type');
  final label = switch (type) {
    'Image' => 'Photo',
    'Video' => 'Video',
    'Audio' => 'Voice note',
    _ => 'File',
  };
  final preview = attachment == null
      ? message.str('text')
      : '$label · ${attachment['fileName'] ?? message.str('text')}';
  return {
    'id': message['id'],
    'senderName': message.str('senderName'),
    'preview': preview.length > 300 ? preview.substring(0, 300) : preview,
    'type': type,
  };
}
