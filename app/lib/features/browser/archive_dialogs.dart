import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';

/// Outcome of a server-side archive operation.
class ServerArchiveResult {
  const ServerArchiveResult({this.path, this.error, this.cancelled = false});

  /// Extracted folder, for a successful "open archive" run.
  final String? path;
  final String? error;
  final bool cancelled;

  bool get ok => path != null;
}

/// Password prompt for an encrypted archive.
///
/// Returns the entered password, or `null` when the user cancels. Pass
/// [error] to show "wrong password" above the field.
Future<String?> showArchivePasswordDialog(
  BuildContext context, {
  required String archiveName,
  String? error,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.menu,
      insetPadding: const EdgeInsets.all(24),
      title: const Text('Архив защищён паролем', style: TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              archiveName,
              style: TextStyle(
                fontSize: 11,
                color: T.faint,
                fontFamily: T.monoFont,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                labelText: 'Пароль',
                errorText: error,
              ),
              onSubmitted: (value) => Navigator.pop(ctx, value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Открыть'),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Progress window for unpacking an archive on the server.
///
/// The Rust side reports `Running`, then `Done` (message = the folder),
/// `Failed` or `Cancelled`. Cancel kills the tool process on the server.
class ServerArchiveDialog extends StatefulWidget {
  const ServerArchiveDialog({
    super.key,
    required this.stream,
    required this.title,
  });

  final Stream<TransferEvent> stream;
  final String title;

  @override
  State<ServerArchiveDialog> createState() => _ServerArchiveDialogState();
}

class _ServerArchiveDialogState extends State<ServerArchiveDialog> {
  StreamSubscription<TransferEvent>? _subscription;
  String? _jobId;
  String? _stage;
  bool _cancelling = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _subscription = widget.stream.listen(
      _onEvent,
      onError: (Object error) {
        _finish(ServerArchiveResult(error: '$error'));
      },
      onDone: () {
        if (_closed) return;
        _finish(const ServerArchiveResult(error: 'Операция прервана'));
      },
    );
  }

  void _onEvent(TransferEvent event) {
    if (!mounted || _closed) return;
    setState(() {
      _jobId = event.id;
      if (event.message != null && event.message!.isNotEmpty) {
        _stage = event.message;
      }
    });
    switch (event.state) {
      case TransferState.done:
        _finish(ServerArchiveResult(path: event.message));
      case TransferState.cancelled:
        _finish(const ServerArchiveResult(cancelled: true));
      case TransferState.failed:
        _finish(
          ServerArchiveResult(error: event.message ?? 'Не удалось распаковать'),
        );
      default:
        break;
    }
  }

  void _finish(ServerArchiveResult result) {
    if (_closed || !mounted) return;
    _closed = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _cancel() async {
    final id = _jobId;
    if (id == null || _cancelling) return;
    setState(() {
      _cancelling = true;
      _stage = 'Отмена…';
    });
    try {
      await cancelArchiveJob(jobId: id);
    } catch (e) {
      _finish(ServerArchiveResult(error: '$e'));
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.menu,
      insetPadding: const EdgeInsets.all(24),
      title: Text(widget.title, style: const TextStyle(fontSize: 14)),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 14),
            Text(
              _stage ?? 'Распаковка на сервере…',
              style: const TextStyle(fontSize: 12.5),
            ),
            const SizedBox(height: 6),
            Text(
              'Файлы распаковываются на сервере в /tmp и удаляются вместе с сессией.',
              style: TextStyle(fontSize: 10.5, color: T.faint),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancelling ? null : _cancel,
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}

/// Small indeterminate window used while a local archive is decompressed
/// (preview of one entry can take a while for a solid 7z).
class ArchiveBusyDialog extends StatelessWidget {
  const ArchiveBusyDialog({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: T.menu,
      insetPadding: const EdgeInsets.all(24),
      content: SizedBox(
        width: 320,
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }
}
