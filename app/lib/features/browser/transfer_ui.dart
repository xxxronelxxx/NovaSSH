import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tokens.dart';
import '../../design/ui.dart';

/// One copy operation: every file of a batch feeds the same progress window.
class TransferBatch extends ChangeNotifier {
  TransferBatch({
    required this.operation,
    required this.destination,
    required this.files,
    this.cancelTransfer,
  });

  final String operation;
  final String destination;
  final List<String> files;

  /// Cancels one queued transfer (the queue owns the stream, not the window).
  final void Function(String id)? cancelTransfer;
  final DateTime started = DateTime.now();

  /// Transfer ids seen so far, so "Отмена" can stop whatever is still running.
  final Set<String> ids = {};

  final Map<String, ({int total, int done, String name})> _items = {};
  String currentFile = '';
  int finished = 0;

  int get totalBytes => _items.values.fold(0, (sum, item) => sum + item.total);
  int get doneBytes => _items.values.fold(0, (sum, item) => sum + item.done);
  int get totalFiles => files.length;

  double get progress {
    final total = totalBytes;
    return total <= 0 ? 0 : (doneBytes / total).clamp(0.0, 1.0);
  }

  ({int total, int done}) get currentItem {
    final id = currentId;
    if (id == null) return (total: 0, done: 0);
    final item = _items[id];
    return item == null
        ? (total: 0, done: 0)
        : (total: item.total, done: item.done);
  }

  String? currentId;

  double get fileProgress {
    final item = currentItem;
    return item.total <= 0 ? 0 : (item.done / item.total).clamp(0.0, 1.0);
  }

  Duration get elapsed => DateTime.now().difference(started);

  double get speed {
    final ms = elapsed.inMilliseconds;
    if (ms < 400) return 0;
    return doneBytes / (ms / 1000.0);
  }

  Duration? get eta {
    final rate = speed;
    final total = totalBytes;
    if (rate <= 0 || total <= 0) return null;
    final left = total - doneBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / rate).round());
  }

  bool get complete => totalFiles > 0 && finished >= totalFiles;

  /// Set when the user stopped the whole batch from the window.
  bool cancelled = false;

  /// True while files are still flowing.
  bool get running => !complete && !cancelled;

  void cancelAll() {
    cancelled = true;
    final cancel = cancelTransfer;
    if (cancel != null) {
      for (final id in ids.toList()) {
        cancel(id);
      }
    }
    notifyListeners();
  }

  void update(String id, String name, int total, int done) {
    ids.add(id);
    currentId = id;
    currentFile = name;
    _items[id] = (total: total, done: done, name: name);
    notifyListeners();
  }

  /// How many files of the batch did not arrive.
  int failed = 0;

  void finish(String id, {bool failed = false}) {
    final item = _items[id];
    if (item != null) {
      _items[id] = (total: item.total, done: item.total, name: item.name);
    }
    if (failed) this.failed++;
    finished = (finished + 1).clamp(0, totalFiles);
    notifyListeners();
  }
}

String formatDuration(Duration d) {
  final seconds = d.inSeconds;
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

/// WinSCP-style prompt before a copy: destination folder and, for a single
/// file, the new name.
class TransferPromptDialog extends StatefulWidget {
  const TransferPromptDialog({
    super.key,
    required this.title,
    required this.items,
    required this.initialDir,
    required this.dirLabel,
    required this.operation,
    this.allowRename = true,
  });

  /// "Отправить" / "Скачать".
  final String title;
  final List<String> items;
  final String initialDir;
  final String dirLabel;
  final String operation;
  final bool allowRename;

  @override
  State<TransferPromptDialog> createState() => _TransferPromptDialogState();
}

class _TransferPromptDialogState extends State<TransferPromptDialog> {
  late final TextEditingController _dir = TextEditingController(
    text: widget.initialDir,
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.items.length == 1 ? widget.items.first : '',
  );
  bool _background = false;

  @override
  void dispose() {
    _dir.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final single = widget.items.length == 1;
    return DialogShortcuts(
      onConfirm: _submit,
      onCancel: () => Navigator.pop(context),
      child: AlertDialog(
        backgroundColor: T.menu,
        title: Text(widget.title, style: const TextStyle(fontSize: 14)),
        content: SizedBox(
          width: _dialogWidth(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                single
                    ? 'Файл: ${widget.items.first}'
                    : 'Файлов: ${widget.items.length}',
                style: TextStyle(fontSize: 12.5, color: T.text),
                overflow: TextOverflow.ellipsis,
              ),
              if (!single)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(8),
                  height: 96,
                  decoration: BoxDecoration(
                    color: T.panel,
                    borderRadius: BorderRadius.circular(T.radiusSmall),
                    border: Border.all(color: T.border),
                  ),
                  child: ListView(
                    children: [
                      for (final name in widget.items)
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 11,
                            fontFamily: T.monoFont,
                            color: T.dim,
                          ),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                widget.dirLabel,
                style: TextStyle(fontSize: 11.5, color: T.faint),
              ),
              const SizedBox(height: 4),
              TextField(
                controller: _dir,
                autofocus: true,
                style: TextStyle(fontSize: 12.5, fontFamily: T.monoFont),
                decoration: const InputDecoration(isDense: true),
              ),
              if (single && widget.allowRename) ...[
                const SizedBox(height: 12),
                Text(
                  'Имя файла',
                  style: TextStyle(fontSize: 11.5, color: T.faint),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: _name,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontFamily: T.monoFont,
                  ),
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (_) => _submit(),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Checkbox(
                    value: _background,
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(color: T.borderStrong),
                    onChanged: (v) => setState(() => _background = v ?? false),
                  ),
                  Expanded(
                    child: Text(
                      'Передавать в фоновом режиме (без окна прогресса)',
                      style: TextStyle(fontSize: 12, color: T.dim),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(onPressed: _submit, child: const Text('OK')),
        ],
      ),
    );
  }

  void _submit() {
    final dir = _dir.text.trim();
    if (dir.isEmpty) return;
    final name = widget.items.length == 1 ? _name.text.trim() : '';
    Navigator.pop<TransferPromptResult>(
      context,
      TransferPromptResult(
        dir: dir,
        name: name.isEmpty ? null : name,
        background: _background,
        operation: widget.operation,
      ),
    );
  }
}

class TransferPromptResult {
  const TransferPromptResult({
    required this.dir,
    this.name,
    required this.background,
    required this.operation,
  });

  final String dir;
  final String? name;
  final bool background;

  /// "Отправка" / "Скачивание" for the progress window.
  final String operation;
}

/// Progress window: current file on top, the whole batch below.
///
/// It closes itself once every file of the batch is done, and Esc asks before
/// breaking a running copy.
class TransferProgressDialog extends StatefulWidget {
  const TransferProgressDialog({
    super.key,
    required this.batch,
    this.onBackground,
  });

  final TransferBatch batch;
  final VoidCallback? onBackground;

  @override
  State<TransferProgressDialog> createState() => _TransferProgressDialogState();
}

class _TransferProgressDialogState extends State<TransferProgressDialog> {
  /// The window is gone already (finished, sent to the background, cancelled).
  bool _closed = false;

  /// The "Прервать передачу?" prompt, so a finished batch can close it too.
  BuildContext? _warningContext;

  @override
  void initState() {
    super.initState();
    widget.batch.addListener(_onBatchChanged);
    // A tiny file can finish before the window is built at all.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onBatchChanged());
  }

  @override
  void dispose() {
    widget.batch.removeListener(_onBatchChanged);
    super.dispose();
  }

  /// A finished copy needs no "Готово" button: the window just goes away.
  ///
  /// The route is removed directly, not popped: the Escape warning may be on
  /// top of this window and a pop would close that instead.
  void _onBatchChanged() {
    if (_closed || !widget.batch.complete) return;
    _closed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _closeWarning();
      final route = ModalRoute.of(context);
      final navigator = Navigator.of(context);
      if (route != null && route.isActive) {
        navigator.removeRoute(route);
      }
    });
  }

  /// Nothing left to abort, so the prompt must not stay on screen.
  void _closeWarning() {
    final ctx = _warningContext;
    if (ctx == null || !ctx.mounted) return;
    final route = ModalRoute.of(ctx);
    if (route != null && route.isActive) Navigator.of(ctx).removeRoute(route);
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    widget.onBackground?.call();
  }

  /// Esc must not throw away a running copy by accident.
  Future<void> _onEscape() async {
    if (_closed) return;
    if (widget.batch.complete) {
      _close();
      return;
    }
    final abort = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        _warningContext = ctx;
        return DialogShortcuts(
          onConfirm: () => Navigator.pop(ctx, false),
          onCancel: () => Navigator.pop(ctx, false),
          child: AlertDialog(
            backgroundColor: T.menu,
            title: const Text(
              'Прервать передачу?',
              style: TextStyle(fontSize: 14),
            ),
            content: const Text(
              'Копирование ещё идёт. Если прервать, текущие файлы останутся '
              'незавершёнными.',
              style: TextStyle(fontSize: 12.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Продолжить'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                style: FilledButton.styleFrom(backgroundColor: T.error),
                child: const Text('Прервать'),
              ),
            ],
          ),
        );
      },
    );
    _warningContext = null;
    if (!mounted || abort != true || _closed) return;
    widget.batch.cancelAll();
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            unawaited(_onEscape()),
      },
      child: Focus(
        autofocus: true,
        child: AnimatedBuilder(
          animation: batch,
          builder: (context, _) {
            final percent = (batch.progress * 100).toStringAsFixed(0);
            final eta = batch.eta;
            // Recomputed on every event, not once when the window opens.
            final cancelable = widget.onBackground != null && !batch.complete;
            return AlertDialog(
              backgroundColor: T.menu,
              title: Row(
                children: [
                  Text(
                    '${batch.operation} · $percent%'
                    '${batch.failed > 0 ? ' · ошибок: ${batch.failed}' : ''}',
                    style: TextStyle(
                      fontSize: 14,
                      color: batch.failed > 0 ? T.error : null,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${batch.finished}/${batch.totalFiles}',
                    style: TextStyle(fontSize: 11.5, color: T.faint),
                  ),
                ],
              ),
              content: SizedBox(
                width: _dialogWidth(context),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Файл',
                      style: TextStyle(fontSize: 10.5, color: T.faint),
                    ),
                    Text(
                      batch.currentFile.isEmpty ? '—' : batch.currentFile,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: T.text,
                        fontFamily: T.monoFont,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: batch.fileProgress,
                        minHeight: 8,
                        backgroundColor: T.hover,
                        color: T.accent,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Куда: ${batch.destination}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: T.dim,
                        fontFamily: T.monoFont,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: batch.progress,
                        minHeight: 10,
                        backgroundColor: T.hover,
                        color: T.success,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _row(
                      'Передано',
                      '${formatBytes(batch.doneBytes)} из ${formatBytes(batch.totalBytes)}',
                    ),
                    _row(
                      'Скорость',
                      batch.speed <= 0
                          ? '—'
                          : '${formatBytes(batch.speed.toInt())}/с',
                    ),
                    _row('Прошло', formatDuration(batch.elapsed)),
                    _row('Осталось', eta == null ? '—' : formatDuration(eta)),
                  ],
                ),
              ),
              actions: [
                if (cancelable)
                  TextButton(onPressed: _close, child: const Text('В фон')),
                if (cancelable)
                  TextButton(
                    onPressed: () {
                      batch.cancelAll();
                      _close();
                    },
                    child: Text('Отмена', style: TextStyle(color: T.error)),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: T.faint),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11.5,
                color: T.text,
                fontFamily: T.monoFont,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 520px on the desktop, the screen width minus margins on a phone.
double _dialogWidth(BuildContext context) {
  final width = MediaQuery.of(context).size.width - 64;
  return width < 320 ? 320 : (width > 520 ? 520 : width);
}
