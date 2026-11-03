import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';
import 'compare_model.dart';

/// Side-by-side file comparison and merge (Ctrl+F3).
///
/// Any two files can be compared, no matter where they live: both sides are
/// read by the core through the same provider API, so local, SFTP, FTP, S3 and
/// archive entries all work, including different servers against each other.
///
/// Lines can be edited in place and saved back (Ctrl+S), edits are undoable
/// (Ctrl+Z), and every block of differences has two arrows that copy the whole
/// block into the opposite file in one click.
class ComparePage extends StatefulWidget {
  const ComparePage({super.key, required this.left, required this.right});

  final FileRef left;
  final FileRef right;

  @override
  State<ComparePage> createState() => _ComparePageState();
}

class _Snapshot {
  _Snapshot(this.left, this.right, this.leftDirty, this.rightDirty);

  final List<String> left;
  final List<String> right;
  final bool leftDirty;
  final bool rightDirty;
}

class _ComparePageState extends State<ComparePage> {
  static const double _rowHeight = 22;
  static const double _gutterWidth = 42;
  static const int _maxUndo = 40;

  final ScrollController _scroll = ScrollController();
  final FocusNode _keys = FocusNode(debugLabel: 'compare');
  final TextEditingController _lineCtrl = TextEditingController();
  final FocusNode _lineFocus = FocusNode(debugLabel: 'compare-line');

  CompareResult? _result;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  // Documents being edited, one line per entry.
  List<String> _left = [];
  List<String> _right = [];
  String _leftEol = '\n';
  String _rightEol = '\n';
  bool _leftBom = false;
  bool _rightBom = false;
  bool _leftFinalNewline = true;
  bool _rightFinalNewline = true;
  String? _leftReadOnly;
  String? _rightReadOnly;
  bool _leftDirty = false;
  bool _rightDirty = false;

  String _leftLabel = '';
  String _rightLabel = '';
  int _leftBytes = 0;
  int _rightBytes = 0;

  bool _ignoreWhitespace = false;
  bool _ignoreCase = false;
  bool _onlyDiff = false;

  List<DiffRow> _rows = const [];
  List<int> _diffStarts = const [];
  List<DiffHunk> _hunks = const [];
  List<int> _rowHunk = const [];
  int _diffIndex = 0;

  final List<_Snapshot> _undo = [];

  int? _editRow;
  int? _editNumber;
  bool _editLeft = true;

  bool get _dirty => _leftDirty || _rightDirty;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _keys.dispose();
    _lineCtrl.dispose();
    _lineFocus.dispose();
    super.dispose();
  }

  // -------------------------------------------------------------------------
  // Loading and re-diffing
  // -------------------------------------------------------------------------

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await compareFiles(
        left: widget.left,
        right: widget.right,
        options: _options,
      );
      if (!mounted) return;
      setState(() {
        _adopt(result);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  CompareOptions get _options => CompareOptions(
    ignoreWhitespace: _ignoreWhitespace,
    ignoreCase: _ignoreCase,
  );

  /// Takes the first comparison result and rebuilds both documents from it.
  void _adopt(CompareResult result) {
    _left = [
      for (final row in result.rows)
        if (row.left != null) row.left!.text,
    ];
    _right = [
      for (final row in result.rows)
        if (row.right != null) row.right!.text,
    ];
    _leftEol = result.leftEol.isEmpty ? '\n' : result.leftEol;
    _rightEol = result.rightEol.isEmpty ? '\n' : result.rightEol;
    _leftBom = result.leftBom;
    _rightBom = result.rightBom;
    _leftFinalNewline = result.leftFinalNewline;
    _rightFinalNewline = result.rightFinalNewline;
    _leftReadOnly = result.leftReadOnly;
    _rightReadOnly = result.rightReadOnly;
    _leftLabel = result.leftLabel;
    _rightLabel = result.rightLabel;
    _leftDirty = false;
    _rightDirty = false;
    _undo.clear();
    _result = result;
    _rebuild();
  }

  /// Diffs the current documents again (after an edit or a block move).
  Future<void> _recompute() async {
    final result = await compareText(
      left: _left.join('\n'),
      right: _right.join('\n'),
      options: _options,
    );
    if (!mounted) return;
    setState(() {
      _result = result;
      _rebuild();
    });
  }

  /// Applies the "only differences" filter and rebuilds the jump/hunk tables.
  void _rebuild() {
    final all = _result?.rows ?? const <DiffRow>[];
    if (!_onlyDiff) {
      _rows = all;
    } else {
      final keep = List<bool>.filled(all.length, false);
      for (var i = 0; i < all.length; i++) {
        if (all[i].kind == 'equal') continue;
        for (
          var j = math.max(0, i - 2);
          j <= math.min(all.length - 1, i + 2);
          j++
        ) {
          keep[j] = true;
        }
      }
      _rows = [
        for (var i = 0; i < all.length; i++)
          if (keep[i]) all[i],
      ];
    }

    _diffStarts = [
      for (var i = 0; i < _rows.length; i++)
        if (_rows[i].kind != 'equal') i,
    ];

    final hunks = <DiffHunk>[];
    var start = -1;
    for (var i = 0; i < _rows.length; i++) {
      final differs = _rows[i].kind != 'equal';
      if (differs && start < 0) start = i;
      if (!differs && start >= 0) {
        hunks.add(DiffHunk(start, i));
        start = -1;
      }
    }
    if (start >= 0) hunks.add(DiffHunk(start, _rows.length));
    _hunks = hunks;

    _rowHunk = List<int>.filled(_rows.length, -1);
    for (var h = 0; h < _hunks.length; h++) {
      for (var i = _hunks[h].start; i < _hunks[h].end; i++) {
        _rowHunk[i] = h;
      }
    }

    if (_diffIndex >= _diffStarts.length) {
      _diffIndex = _diffStarts.isEmpty ? 0 : _diffStarts.length - 1;
    }

    _leftBytes = utf8
        .encode(_compose(_left, _leftEol, _leftBom, _leftFinalNewline))
        .length;
    _rightBytes = utf8
        .encode(_compose(_right, _rightEol, _rightBom, _rightFinalNewline))
        .length;
  }

  // -------------------------------------------------------------------------
  // Editing
  // -------------------------------------------------------------------------

  String _compose(List<String> lines, String eol, bool bom, bool finalNewline) {
    final body = lines.isEmpty
        ? ''
        : lines.join(eol) + (finalNewline ? eol : '');
    return bom ? '\uFEFF$body' : body;
  }

  void _beginEdit(int rowIndex, bool left) {
    final row = _rows[rowIndex];
    final line = left ? row.left : row.right;
    if (line == null) return;
    final readOnly = left ? _leftReadOnly : _rightReadOnly;
    if (readOnly != null) {
      _toast(readOnly, warn: true);
      return;
    }
    final doc = left ? _left : _right;
    final index = line.number - 1;
    if (index < 0 || index >= doc.length) return;
    setState(() {
      _editRow = rowIndex;
      _editNumber = line.number;
      _editLeft = left;
      _lineCtrl.text = doc[index];
      _lineCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _lineCtrl.text.length,
      );
    });
    _lineFocus.requestFocus();
  }

  void _commitEdit() {
    final number = _editNumber;
    if (number == null) return;
    final left = _editLeft;
    final doc = left ? _left : _right;
    final index = number - 1;
    final value = _lineCtrl.text;
    var changed = false;
    if (index >= 0 && index < doc.length && doc[index] != value) {
      _pushUndo();
      doc[index] = value;
      if (left) {
        _leftDirty = true;
      } else {
        _rightDirty = true;
      }
      changed = true;
    }
    setState(() {
      _editRow = null;
      _editNumber = null;
    });
    _keys.requestFocus();
    if (changed) unawaited(_recompute());
  }

  void _cancelEdit() {
    setState(() {
      _editRow = null;
      _editNumber = null;
    });
    _keys.requestFocus();
  }

  void _pushUndo() {
    _undo.add(
      _Snapshot(List.of(_left), List.of(_right), _leftDirty, _rightDirty),
    );
    if (_undo.length > _maxUndo) _undo.removeAt(0);
  }

  void _undoLast() {
    if (_undo.isEmpty) return;
    final snapshot = _undo.removeLast();
    setState(() {
      _left = List.of(snapshot.left);
      _right = List.of(snapshot.right);
      _leftDirty = snapshot.leftDirty;
      _rightDirty = snapshot.rightDirty;
    });
    unawaited(_recompute());
  }

  /// Copies a whole differing block into the opposite document.
  Future<void> _applyHunk(DiffHunk hunk, bool intoLeft) async {
    if (_editNumber != null) _commitEdit();
    final readOnly = intoLeft ? _leftReadOnly : _rightReadOnly;
    if (readOnly != null) {
      _toast(readOnly, warn: true);
      return;
    }

    _pushUndo();
    applyHunkToDocuments(
      _rows,
      hunk,
      intoLeft: intoLeft,
      left: _left,
      right: _right,
    );
    if (intoLeft) {
      _leftDirty = true;
    } else {
      _rightDirty = true;
    }
    await _recompute();
  }

  // -------------------------------------------------------------------------
  // Saving
  // -------------------------------------------------------------------------

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    if (_editNumber != null) _commitEdit();
    setState(() => _saving = true);
    final saved = <String>[];
    try {
      if (_leftDirty) {
        await saveText(
          file: widget.left,
          text: _compose(_left, _leftEol, _leftBom, _leftFinalNewline),
        );
        if (!mounted) return;
        setState(() => _leftDirty = false);
        saved.add(_leftLabel);
      }
      if (_rightDirty) {
        await saveText(
          file: widget.right,
          text: _compose(_right, _rightEol, _rightBom, _rightFinalNewline),
        );
        if (!mounted) return;
        setState(() => _rightDirty = false);
        saved.add(_rightLabel);
      }
      if (saved.isNotEmpty) _toast('Сохранено: ${saved.join(' · ')}');
    } catch (e) {
      if (mounted)
        _toast('Не удалось сохранить: ${friendlyError(e)}', warn: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(fontSize: 12.5)),
        backgroundColor: warn ? T.warnSurface : T.raised,
        behavior: SnackBarBehavior.floating,
        width: 620,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  /// Closing with unsaved merges loses both sides: ask first.
  Future<void> _confirmClose() async {
    if (_editNumber != null) {
      _cancelEdit();
      return;
    }
    if (!_dirty) {
      Navigator.of(context).maybePop();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogShortcuts(
        onConfirm: () => Navigator.pop(ctx, false),
        onCancel: () => Navigator.pop(ctx, false),
        child: AlertDialog(
          backgroundColor: T.menu,
          title: const Text(
            'Закрыть без сохранения?',
            style: TextStyle(fontSize: 14),
          ),
          content: const Text(
            'В одном или обоих файлах есть несохранённые правки.',
            style: TextStyle(fontSize: 12.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Остаться'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: T.error),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || leave != true) return;
    Navigator.of(context).maybePop();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // While a line is being edited only Esc is ours: everything else belongs
    // to the text field (typing, Ctrl+Z inside the field, ...).
    if (_editNumber != null) {
      if (key == LogicalKeyboardKey.escape) {
        _cancelEdit();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final ctrl = HardwareKeyboard.instance.isControlPressed;
    if (key == LogicalKeyboardKey.escape) {
      unawaited(_confirmClose());
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyS) {
      unawaited(_save());
      return KeyEventResult.handled;
    }
    if (ctrl && key == LogicalKeyboardKey.keyZ) {
      _undoLast();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f3 ||
        (ctrl && key == LogicalKeyboardKey.arrowDown)) {
      _jump(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2 ||
        (ctrl && key == LogicalKeyboardKey.arrowUp)) {
      _jump(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _jump(int delta) {
    if (_diffStarts.isEmpty || !_scroll.hasClients) return;
    final next = (_diffIndex + delta) % _diffStarts.length;
    _diffIndex = next < 0 ? next + _diffStarts.length : next;
    final offset = _diffStarts[_diffIndex] * _rowHeight;
    final max = _scroll.position.maxScrollExtent;
    unawaited(
      _scroll.animateTo(
        offset.clamp(0.0, max),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      ),
    );
    setState(() {});
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.window,
      body: Focus(
        focusNode: _keys,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            children: [
              _header(),
              const SizedBox(height: 10),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final result = _result;
    return Row(
      children: [
        ToolButton(
          icon: Icons.arrow_back,
          tooltip: 'Назад (Esc)',
          onPressed: () => unawaited(_confirmClose()),
        ),
        const SizedBox(width: 6),
        Text(
          'Сравнение файлов',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: T.text,
          ),
        ),
        const SizedBox(width: 12),
        if (result != null && !result.binary) ...[
          if (result.equal)
            _counter('Идентичны', T.success)
          else ...[
            _counter('+${result.added}', T.success, dim: result.added == 0),
            const SizedBox(width: 6),
            _counter('−${result.removed}', T.error, dim: result.removed == 0),
            const SizedBox(width: 6),
            _counter('~${result.changed}', T.warn, dim: result.changed == 0),
          ],
        ],
        const Spacer(),
        if (result != null && !result.binary) ...[
          _chip('Игнорировать пробелы', _ignoreWhitespace, () {
            setState(() => _ignoreWhitespace = !_ignoreWhitespace);
            unawaited(_recompute());
          }),
          const SizedBox(width: 6),
          _chip('Игнорировать регистр', _ignoreCase, () {
            setState(() => _ignoreCase = !_ignoreCase);
            unawaited(_recompute());
          }),
          const SizedBox(width: 6),
          _chip('Только отличия', _onlyDiff, () {
            setState(() {
              _onlyDiff = !_onlyDiff;
              _rebuild();
            });
          }),
          const SizedBox(width: 10),
          ToolButton(
            icon: Icons.keyboard_arrow_up,
            tooltip: 'Предыдущее различие (Ctrl+↑)',
            enabled: _diffStarts.isNotEmpty,
            onPressed: () => _jump(-1),
          ),
          ToolButton(
            icon: Icons.keyboard_arrow_down,
            tooltip: 'Следующее различие (Ctrl+↓)',
            enabled: _diffStarts.isNotEmpty,
            onPressed: () => _jump(1),
          ),
          if (_diffStarts.isNotEmpty)
            Text(
              '${_diffIndex + 1}/${_diffStarts.length}',
              style: TextStyle(
                fontSize: 11,
                color: T.faint,
                fontFamily: T.monoFont,
              ),
            ),
          const SizedBox(width: 10),
          ToolButton(
            icon: Icons.undo,
            tooltip: 'Отменить (Ctrl+Z)',
            enabled: _undo.isNotEmpty,
            onPressed: _undoLast,
          ),
          ToolButton(
            icon: _saving ? Icons.hourglass_top : Icons.save_outlined,
            tooltip: 'Сохранить (Ctrl+S)',
            accent: _dirty,
            enabled: _dirty && !_saving,
            onPressed: () => unawaited(_save()),
          ),
        ],
      ],
    );
  }

  Widget _counter(String text, Color color, {bool dim = false}) {
    final tone = dim ? color.withValues(alpha: 0.45) : color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: tone.withValues(alpha: 0.40)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10.5, color: tone, fontFamily: T.monoFont),
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? T.accent.withValues(alpha: 0.16) : T.hover,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: active ? T.accent.withValues(alpha: 0.6) : T.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            color: active ? T.accent : T.dim,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: T.error),
          ),
        ),
      );
    }
    final result = _result;
    if (result == null) return const SizedBox.shrink();
    if (result.binary) return _binary(result);

    return Column(
      children: [
        _names(),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: T.panel,
              borderRadius: BorderRadius.circular(T.radius),
              border: Border.all(color: T.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: _rows.isEmpty
                ? Center(
                    child: Text(
                      'Пустые файлы — отличий нет',
                      style: TextStyle(fontSize: 12, color: T.faint),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    itemExtent: _rowHeight,
                    itemCount: _rows.length,
                    itemBuilder: (context, index) =>
                        _rowWidget(index, _rows[index]),
                  ),
          ),
        ),
        if (result.truncated)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Показано не всё: файл больше 8 МБ или строк больше 20 000 — '
              'сравнение ограничено.',
              style: TextStyle(fontSize: 10.5, color: T.warn),
            ),
          ),
      ],
    );
  }

  Widget _names() {
    Widget cell(
      String label,
      int bytes,
      Color color,
      bool dirty,
      String? readOnly,
      bool left,
    ) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.insert_drive_file_outlined, size: 13, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: T.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (dirty) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Есть несохранённые изменения',
                  child: Icon(Icons.circle, size: 7, color: T.warn),
                ),
              ],
              if (readOnly != null) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: readOnly,
                  child: Icon(Icons.lock_outline, size: 12, color: T.faint),
                ),
              ],
              const SizedBox(width: 8),
              Text(
                formatBytes(bytes),
                style: TextStyle(
                  fontSize: 10.5,
                  color: T.faint,
                  fontFamily: T.monoFont,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: T.panelHeader,
        borderRadius: BorderRadius.circular(T.radiusSmall),
        border: Border.all(color: T.border),
      ),
      child: Row(
        children: [
          cell(
            _leftLabel,
            _leftBytes,
            T.accent,
            _leftDirty,
            _leftReadOnly,
            true,
          ),
          Container(width: 1, height: 26, color: T.border),
          cell(
            _rightLabel,
            _rightBytes,
            T.success,
            _rightDirty,
            _rightReadOnly,
            false,
          ),
        ],
      ),
    );
  }

  Widget _rowWidget(int index, DiffRow row) {
    final current = _diffStarts.isNotEmpty && _diffStarts[_diffIndex] == index;
    final hunkIndex = index < _rowHunk.length ? _rowHunk[index] : -1;
    final hunk = hunkIndex >= 0 ? _hunks[hunkIndex] : null;
    return Container(
      decoration: BoxDecoration(
        border: current
            ? Border(left: BorderSide(color: T.accent, width: 2))
            : null,
      ),
      child: Row(
        children: [
          Expanded(child: _cell(row, index, true)),
          SizedBox(width: _gutterWidth, child: _gutter(hunk, index)),
          Expanded(child: _cell(row, index, false)),
        ],
      ),
    );
  }

  /// Middle column: merge arrows on the first row of every block.
  Widget _gutter(DiffHunk? hunk, int index) {
    final marked = hunk != null;
    final first = hunk != null && hunk.start == index;
    return Container(
      decoration: BoxDecoration(
        color: marked ? T.warn.withValues(alpha: 0.07) : T.panelSubtle,
        border: Border.symmetric(vertical: BorderSide(color: T.border)),
      ),
      alignment: Alignment.center,
      child: first
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _mergeButton(
                  icon: Icons.keyboard_double_arrow_left,
                  tooltip: 'Взять этот блок в левый файл',
                  enabled: _leftReadOnly == null,
                  onTap: () => unawaited(_applyHunk(hunk, true)),
                ),
                _mergeButton(
                  icon: Icons.keyboard_double_arrow_right,
                  tooltip: 'Взять этот блок в правый файл',
                  enabled: _rightReadOnly == null,
                  onTap: () => unawaited(_applyHunk(hunk, false)),
                ),
              ],
            )
          : null,
    );
  }

  Widget _mergeButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(3),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Icon(
            icon,
            size: 14,
            color: enabled ? T.accent : T.faint.withValues(alpha: 0.4),
          ),
        ),
      ),
    );
  }

  Widget _cell(DiffRow row, int rowIndex, bool left) {
    final line = left ? row.left : row.right;
    final editing = _editRow == rowIndex && _editLeft == left;
    final background = switch (row.kind) {
      'add' => T.success.withValues(alpha: 0.13),
      'del' => T.error.withValues(alpha: 0.12),
      'mod' => T.warn.withValues(alpha: 0.09),
      _ => Colors.transparent,
    };
    final content = line == null
        ? const SizedBox.shrink()
        : editing
        ? _editor()
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onDoubleTap: () => _beginEdit(rowIndex, left),
            child: _text(line, row.kind, left),
          );

    return Container(
      color: background,
      padding: const EdgeInsets.only(right: 8),
      child: Row(
        children: [
          Container(
            width: 46,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              line?.number.toString() ?? '',
              style: TextStyle(
                fontSize: 10,
                color: T.faint,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          Expanded(child: content),
        ],
      ),
    );
  }

  Widget _editor() {
    return SizedBox(
      height: 18,
      child: TextField(
        controller: _lineCtrl,
        focusNode: _lineFocus,
        autofocus: true,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.1,
          fontFamily: T.monoFont,
          color: T.text,
        ),
        cursorColor: T.accent,
        decoration: const InputDecoration(
          isDense: true,
          isCollapsed: true,
          contentPadding: EdgeInsets.zero,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
        onSubmitted: (_) => _commitEdit(),
        onTapOutside: (_) => _commitEdit(),
      ),
    );
  }

  Widget _text(DiffLine line, String kind, bool left) {
    final base = TextStyle(
      fontSize: 11.5,
      height: 1.2,
      fontFamily: T.monoFont,
      color: kind == 'equal' ? T.dim : T.text,
    );
    if (line.words.isEmpty) {
      return Text(
        line.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: base,
      );
    }
    final mark = (left ? T.error : T.success).withValues(alpha: 0.35);
    return Text.rich(
      TextSpan(
        children: [
          for (final word in line.words)
            TextSpan(
              text: word.text,
              style: word.changed
                  ? base.copyWith(
                      backgroundColor: mark,
                      fontWeight: FontWeight.w600,
                    )
                  : base,
            ),
        ],
      ),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    );
  }

  Widget _binary(CompareResult result) {
    Widget hashRow(String label, BigInt size, String? hash, String? readOnly) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            SizedBox(
              width: 320,
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: T.text),
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                formatBytes(size.toInt()),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 11,
                  color: T.dim,
                  fontFamily: T.monoFont,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                hash == null
                    ? ''
                    : hash.substring(0, math.min(32, hash.length)),
                style: TextStyle(
                  fontSize: 11,
                  color: T.faint,
                  fontFamily: T.monoFont,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Center(
      child: Container(
        padding: const EdgeInsets.all(20),
        constraints: const BoxConstraints(maxWidth: 720),
        decoration: BoxDecoration(
          color: T.panel,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: T.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.data_object, size: 16, color: T.warn),
                const SizedBox(width: 8),
                Text(
                  'Бинарные файлы — построчное сравнение недоступно',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: T.text,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            hashRow(
              result.leftLabel,
              result.leftSize,
              result.leftHash,
              result.leftReadOnly,
            ),
            hashRow(
              result.rightLabel,
              result.rightSize,
              result.rightHash,
              result.rightReadOnly,
            ),
            const SizedBox(height: 12),
            Text(
              result.equal ? 'Файлы побайтово идентичны' : 'Файлы отличаются',
              style: TextStyle(
                fontSize: 12,
                color: result.equal ? T.success : T.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
