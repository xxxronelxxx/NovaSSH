import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Keeps transfers alive while the app is in the background (Android only).
///
/// A single foreground service with a dataSync type is enough: transfers run
/// inside the app process, the service just stops Android from freezing it.
class TransferService {
  static bool _running = false;
  static int _active = 0;

  static bool get _android => !kIsWeb && Platform.isAndroid;

  static void init() {
    if (!_android) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nova_transfers',
        channelName: 'Передачи NovaSSH',
        channelDescription: 'Фоновые загрузки и скачивания',
        onlyAlertOnce: true,
        showWhen: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    // The permission prompt is shown when the first transfer starts, not on
    // app launch.
  }

  static String get _text =>
      _active <= 1 ? 'Передача файла…' : 'Передач: $_active';

  /// Called whenever the number of running transfers changes.
  static Future<void> update(int active) async {
    if (!_android) return;
    final had = _active;
    _active = active;

    try {
      if (active > 0 && !_running) {
        _running = true;
        await FlutterForegroundTask.requestNotificationPermission();
        await FlutterForegroundTask.startService(
          serviceTypes: const [ForegroundServiceTypes.dataSync],
          notificationTitle: 'NovaSSH',
          notificationText: _text,
        );
      } else if (active == 0 && _running) {
        _running = false;
        await FlutterForegroundTask.stopService();
      } else if (active > 0 && had != active) {
        FlutterForegroundTask.updateService(
          notificationTitle: 'NovaSSH',
          notificationText: _text,
        );
      }
    } catch (e) {
      debugPrint('nova: foreground service failed: $e');
    }
  }
}
