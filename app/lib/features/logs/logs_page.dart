import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../bridge/api.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';

/// Session log viewer: the tail of `logs/nova.log` plus the files around it.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  static const int _maxLines = 1500;

  String? _dir;
  String? _file;
  List<String> _lines = const [];
  List<FileSystemEntity> _files = const [];
  String? _error;
  bool _onlyProblems = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({String? file}) async {
    setState(() => _loading = true);
    try {
      final dir = await logDir();
      if (dir == null) {
        setState(() {
          _loading = false;
          _error = 'Папка журналов недоступна';
        });
        return;
      }
      final files = <FileSystemEntity>[];
      await for (final entry in Directory(dir).list()) {
        if (entry is File && entry.path.toLowerCase().endsWith('.log')) {
          files.add(entry);
        }
      }
      files.sort((a, b) => b.path.compareTo(a.path));

      final requested = file ?? _file;
      final selected = files.any((entry) => entry.path == requested)
          ? requested
          : _newestLog(files, dir);
      var lines = <String>[];
      if (selected != null) {
        final bytes = await File(selected).readAsBytes();
        // Read the tail only: logs can be megabytes long.
        final tail = bytes.length > 512 * 1024
            ? bytes.sublist(bytes.length - 512 * 1024)
            : bytes;
        lines = utf8.decode(tail, allowMalformed: true).split('\n');
      }
      if (!mounted) return;
      setState(() {
        _dir = dir;
        _file = selected;
        _lines = lines.length > _maxLines
            ? lines.sublist(lines.length - _maxLines)
            : lines;
        _files = files;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Today's edit log when it exists, otherwise the most recently changed file.
  String? _newestLog(List<FileSystemEntity> files, String dir) {
    if (files.isEmpty) return null;
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    // Server files look like <server>_DD-MM-YYYY.log: with several servers
    // open, show the one that was written last today.
    final today = '-${two(now.day)}-${two(now.month)}-${now.year}.log';
    final todays = files
        .where((entry) => entry.uri.pathSegments.last.endsWith(today))
        .toList();
    final candidates = todays.isNotEmpty ? todays : files;
    FileSystemEntity? newest;
    DateTime? newestTime;
    for (final entry in candidates) {
      try {
        final modified = File(entry.path).lastModifiedSync();
        if (newestTime == null || modified.isAfter(newestTime)) {
          newest = entry;
          newestTime = modified;
        }
      } catch (_) {}
    }
    return newest?.path ?? '$dir${Platform.pathSeparator}nova.log';
  }

  List<String> get _visible {
    if (!_onlyProblems) return _lines;
    final lower = _lines
        .where(
          (line) =>
              line.contains('ERROR') ||
              line.contains('PANIC') ||
              line.contains('FLUTTER:') ||
              line.contains('ZONE:'),
        )
        .toList();
    return lower;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _visible.join('\n')));
    if (mounted) _toast('Скопировано строк: ${_visible.length}');
  }

  Future<void> _openFolder() async {
    final dir = _dir;
    if (dir == null) return;
    try {
      if (Platform.isWindows) {
        await launchProcess(command: 'explorer.exe', args: [dir]);
      } else {
        await Clipboard.setData(ClipboardData(text: dir));
        _toast('Путь скопирован: $dir');
      }
    } catch (e) {
      _toast('$e', warn: true);
    }
  }

  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: 12.5, color: T.text)),
        backgroundColor: warn ? T.warnSurface : T.panel,
        behavior: SnackBarBehavior.floating,
        width: 420,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
          side: BorderSide(color: T.border),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.window,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          children: [
            Row(
              children: [
                ToolButton(
                  icon: Icons.arrow_back,
                  tooltip: 'Назад',
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                const SizedBox(width: 6),
                const Text(
                  'Журнал событий',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 12),
                if (_files.isNotEmpty) ...[
                  SizedBox(
                    width: 220,
                    child: DropdownButton<String>(
                      value: _file,
                      isExpanded: true,
                      isDense: true,
                      dropdownColor: T.menu,
                      style: TextStyle(fontSize: 11.5, color: T.text),
                      items: [
                        for (final entry in _files)
                          DropdownMenuItem(
                            value: entry.path,
                            child: Text(
                              entry.uri.pathSegments.last,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) _load(file: value);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (_dir != null)
                  Expanded(
                    child: Text(
                      _dir!,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: T.faint,
                        fontFamily: T.monoFont,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                ToolButton(
                  icon: Icons.error_outline,
                  tooltip: 'Только ошибки',
                  accent: _onlyProblems,
                  onPressed: () =>
                      setState(() => _onlyProblems = !_onlyProblems),
                ),
                ToolButton(
                  icon: Icons.refresh,
                  tooltip: 'Обновить',
                  onPressed: () => _load(),
                ),
                ToolButton(
                  icon: Icons.copy_all,
                  tooltip: 'Копировать строки',
                  onPressed: _copy,
                ),
                ToolButton(
                  icon: Icons.folder_open,
                  tooltip: 'Открыть папку журналов',
                  onPressed: _openFolder,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: T.panel,
                  borderRadius: BorderRadius.circular(T.radius),
                  border: Border.all(color: T.border),
                ),
                clipBehavior: Clip.antiAlias,
                child: _loading
                    ? const Center(
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(fontSize: 12, color: T.error),
                        ),
                      )
                    : _visible.isEmpty
                    ? Center(
                        child: Text(
                          'Пусто',
                          style: TextStyle(fontSize: 12, color: T.faint),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _visible.length,
                        itemExtent: 18,
                        itemBuilder: (context, index) {
                          final line = _visible[index];
                          final problem =
                              line.contains('ERROR') ||
                              line.contains('PANIC') ||
                              line.contains('FLUTTER:') ||
                              line.contains('ZONE:');
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              line,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              softWrap: false,
                              style: TextStyle(
                                fontSize: 10.5,
                                height: 1.6,
                                fontFamily: T.monoFont,
                                color: problem ? T.error : T.dim,
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Файлы: ${_files.length} · строк: ${_visible.length}'
                '${_onlyProblems ? ' (только ошибки)' : ''}',
                style: TextStyle(fontSize: 10.5, color: T.faint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
