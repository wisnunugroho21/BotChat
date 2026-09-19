import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api.dart';

@pragma('vm:entry-point')
Future<void> backgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NativeCalls.background(message.data);
}

abstract final class NativeCalls {
  static const channel = MethodChannel('tms/native_call_notifications');
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static int notificationId(String id) => id.codeUnits.fold(
    0,
    (int value, unit) => (value * 31 + unit) & 0x7fffffff,
  );
  static Future<void> configure(String? token) async {
    if (supported) {
      await channel.invokeMethod<void>('configure', {
        'token': token,
        'baseUrl': apiUrl,
      });
    }
  }

  static Future<void> visible(bool active) async {
    if (supported) {
      await channel.invokeMethod<void>('setWebRingtoneOwner', {
        'active': active,
      });
    }
  }

  static Future<void> cancel(String callId) async {
    if (!supported) return;
    final prefs = SharedPreferencesAsync();
    final cancelled = await prefs.getStringList('cancelledCalls') ?? [];
    cancelled.remove(callId);
    cancelled.add(callId);
    await prefs.setStringList(
      'cancelledCalls',
      cancelled
          .skip(cancelled.length > 50 ? cancelled.length - 50 : 0)
          .toList(),
    );
    await channel.invokeMethod<void>('cancel', {'id': notificationId(callId)});
  }

  static Future<void> background(Json data) async {
    if (!supported) return;
    if (data['type'] == 'call_cancel') {
      await cancel(data.str('callId'));
      return;
    }
    if (data['type'] != 'call') return;
    final expiry = DateTime.tryParse(data.str('expiresAt'));
    final remaining = expiry?.difference(DateTime.now()).inMilliseconds ?? 0;
    if (remaining <= 0) return;
    if ((await SharedPreferencesAsync().getStringList('cancelledCalls') ?? [])
        .contains(data['callId'])) {
      return;
    }
    await channel.invokeMethod<void>('show', {
      'id': notificationId(data.str('callId')),
      'payload': jsonEncode({'data': data}),
      'title': data.str('callerName'),
      'body': data['video'] == 'true'
          ? 'Incoming video call'
          : 'Incoming voice call',
      'channelId': 'incoming_calls_v3',
      'timeoutMs': remaining.clamp(1, 40000),
      'isVideo': data['video'] == 'true',
    });
  }
}

class PushService {
  PushService(this.api, this.open);
  final Api api;
  final Future<void> Function(Json) open;
  final local = FlutterLocalNotificationsPlugin();
  final List<StreamSubscription<dynamic>> subscriptions = [];
  String? token;
  Future<void> takeNativeAction() async {
    if (!NativeCalls.supported) return;
    final pending = await NativeCalls.channel.invokeMethod<String>(
      'takeAction',
    );
    if (pending == null) return;
    final action = jsonDecode(pending) as Map;
    final payload = jsonDecode(action['payload'] as String) as Map;
    await open({
      ...Map<String, dynamic>.from(payload['data']),
      'nativeAction': action['action'],
    });
  }

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(backgroundMessage);
    await local.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload != null) {
          open(Map<String, dynamic>.from(jsonDecode(response.payload!)));
        }
      },
    );
    await local
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            'chat_messages',
            'Messages and calls',
            importance: Importance.high,
          ),
        );
    await FirebaseMessaging.instance.requestPermission();
    token = await FirebaseMessaging.instance.getToken();
    if (token != null) await api.put('/devices', {'token': token});
    await NativeCalls.configure(token);
    if (NativeCalls.supported) {
      NativeCalls.channel.setMethodCallHandler((call) async {
        if (call.method == 'actionAvailable') await takeNativeAction();
      });
      await takeNativeAction();
    }
    subscriptions.add(
      FirebaseMessaging.instance.onTokenRefresh.listen((value) async {
        token = value;
        try {
          await api.put('/devices', {'token': value});
          await NativeCalls.configure(value);
        } catch (_) {}
      }),
    );
    subscriptions.add(
      FirebaseMessaging.onMessageOpenedApp.listen((m) => open(m.data)),
    );
    subscriptions.add(
      FirebaseMessaging.onMessage.listen((m) async {
        // The OS displays background notifications; foreground messages are handled by SignalR.
        if (m.data['type'] == 'call_cancel') {
          await NativeCalls.cancel(m.data['callId'] ?? '');
        }
        if (m.data['type'] == 'call') open(m.data);
      }),
    );
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) open(initial.data);
    final launch = await local.getNotificationAppLaunchDetails();
    final payload = launch?.notificationResponse?.payload;
    if (launch?.didNotificationLaunchApp == true && payload != null) {
      open(Map<String, dynamic>.from(jsonDecode(payload)));
    }
  }

  Future<void> unregister() async {
    if (token != null) await api.delete('/devices', {'token': token});
    await NativeCalls.configure(null);
    if (NativeCalls.supported) {
      await NativeCalls.channel.invokeMethod<void>('clear');
    }
  }

  void dispose() {
    if (NativeCalls.supported) NativeCalls.channel.setMethodCallHandler(null);
    for (final s in subscriptions) {
      s.cancel();
    }
  }
}
