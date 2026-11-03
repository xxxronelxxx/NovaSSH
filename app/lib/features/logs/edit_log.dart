import '../../bridge/api.dart';

/// Writes one edit event to `logs/edits-YYYY-MM-DD.log` when the user enabled
/// the edit log in the settings. Local date and time are computed here so the
/// file names and lines match the user's clock.
Future<void> logFileEdit({
  required String server,
  required String serverName,
  required String path,
  required String action,
}) async {
  final now = DateTime.now();
  String two(int value) => value.toString().padLeft(2, '0');
  // The file is called <server>_DD-MM-YYYY.log, like IKEY_NEW!_31-10-2026.log.
  final date = '${two(now.day)}-${two(now.month)}-${now.year}';
  final time = '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  try {
    await appendEditLog(
      server: server,
      serverName: serverName,
      path: path,
      action: action,
      date: date,
      time: time,
    );
  } catch (_) {
    // Logging must never break the actual edit/save.
  }
}
