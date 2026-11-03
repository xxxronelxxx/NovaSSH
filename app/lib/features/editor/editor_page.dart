import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/github.dart';
import 'package:highlight/languages/css.dart' as hl_css;
import 'package:highlight/languages/dart.dart' as hl_dart;
import 'package:highlight/languages/ini.dart' as hl_ini;
import 'package:highlight/languages/javascript.dart' as hl_js;
import 'package:highlight/languages/json.dart' as hl_json;
import 'package:highlight/languages/markdown.dart' as hl_md;
import 'package:highlight/languages/php.dart' as hl_php;
import 'package:highlight/languages/python.dart' as hl_py;
import 'package:highlight/languages/rust.dart' as hl_rust;
import 'package:highlight/languages/shell.dart' as hl_sh;
import 'package:highlight/languages/sql.dart' as hl_sql;
import 'package:highlight/languages/xml.dart' as hl_xml;
import 'package:highlight/languages/yaml.dart' as hl_yaml;

import '../../design/tokens.dart';
import '../../design/ui.dart';

/// Built-in text editor with syntax highlighting (F4).
///
/// Saving is delegated to the caller: local files are written with `dart:io`,
/// remote ones go through the core's `save_text`.
class EditorPage extends StatefulWidget {
  const EditorPage({
    super.key,
    required this.title,
    required this.initialText,
    required this.fileName,
    required this.onSave,
    this.readOnly = false,
  });

  final String title;
  final String initialText;
  final String fileName;
  final Future<void> Function(String text) onSave;
  final bool readOnly;

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  late final CodeController _controller;
  late String _saved;
  bool _saving = false;
  bool _wrap = false;

  bool get _dirty => _controller.text != _saved;

  @override
  void initState() {
    super.initState();
    _saved = widget.initialText;
    _controller = CodeController(
      text: widget.initialText,
      language: _modeFor(widget.fileName),
      readOnly: widget.readOnly,
    );
    _controller.addListener(_onChanged);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  static _modeFor(String fileName) => _languageOf(fileName);

  /// Language by extension; unknown files fall back to plain text.
  static dynamic _languageOf(String fileName) {
    final name = fileName.toLowerCase();
    final ext = name.contains('.') ? name.split('.').last : '';
    return switch (ext) {
      'php' => hl_php.php,
      'js' || 'mjs' || 'cjs' || 'ts' => hl_js.javascript,
      'json' => hl_json.json,
      'html' || 'htm' || 'xml' || 'svg' => hl_xml.xml,
      'css' || 'scss' => hl_css.css,
      'sql' => hl_sql.sql,
      'ini' || 'conf' || 'cnf' => hl_ini.ini,
      'sh' || 'bash' || 'zsh' => hl_sh.shell,
      'py' => hl_py.python,
      'dart' => hl_dart.dart,
      'rs' => hl_rust.rust,
      'md' => hl_md.markdown,
      'yml' || 'yaml' => hl_yaml.yaml,
      _ => null,
    };
  }

  Future<void> _save() async {
    if (_saving || widget.readOnly) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(_controller.text);
      _saved = _controller.text;
      if (mounted) {
        setState(() {});
        _toast('Сохранено');
      }
    } catch (e) {
      if (mounted) _toast('Не удалось сохранить: ${friendlyError(e)}', warn: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _back() async {
    if (_dirty) {
      final leave = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: T.menu,
          title: const Text('Закрыть без сохранения?', style: TextStyle(fontSize: 14)),
          content: const Text('Изменения будут потеряны.',
              style: TextStyle(fontSize: 12.5)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Остаться'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
      if (leave != true) return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String message, {bool warn = false}) {
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
    final dark = T.brightness == Brightness.dark;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            () => _save(),
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => _save(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: T.window,
          body: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              children: [
                _header(),
                const SizedBox(height: 10),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: dark ? const Color(0xFF1B1B20) : T.panel,
                      borderRadius: BorderRadius.circular(T.radius),
                      border: Border.all(color: T.border),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: CodeTheme(
                      data: CodeThemeData(
                        styles: dark ? atomOneDarkTheme : githubTheme,
                      ),
                      child: SingleChildScrollView(
                        child: CodeField(
                          controller: _controller,
                          wrap: _wrap,
                          textStyle: TextStyle(
                            fontFamily: T.monoFont,
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                          gutterStyle: GutterStyle(
                            textStyle: TextStyle(
                              color: T.faint,
                              fontSize: 11,
                              fontFamily: T.monoFont,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        ToolButton(
          icon: Icons.arrow_back,
          tooltip: 'Назад',
          onPressed: () => unawaited(_back()),
        ),
        const SizedBox(width: 6),
        Icon(Icons.description_outlined, size: 14, color: T.dim),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.title,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
        if (_dirty)
          Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: T.warn.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('не сохранено',
                style: TextStyle(fontSize: 10, color: T.warn)),
          ),
        ToolButton(
          icon: _wrap ? Icons.wrap_text : Icons.notes,
          tooltip: _wrap ? 'Перенос строк включён' : 'Перенос строк выключен',
          accent: _wrap,
          onPressed: () => setState(() => _wrap = !_wrap),
        ),
        ToolButton(
          icon: _saving ? Icons.hourglass_top : Icons.save_outlined,
          tooltip: 'Сохранить (Ctrl+S)',
          accent: _dirty,
          enabled: _dirty && !_saving && !widget.readOnly,
          onPressed: () => unawaited(_save()),
        ),
      ],
    );
  }
}
