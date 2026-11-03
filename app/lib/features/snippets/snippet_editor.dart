import 'package:flutter/material.dart';

import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';
import '../ai/ai_dialog.dart';

/// Creates or edits one snippet. Returns the saved snippet.
///
/// `serverId`/`serverName` are passed from the terminal: then the dialog offers
/// "только для этого сервера". From the settings page there is no server, so
/// snippets are global.
Future<Snippet?> showSnippetEditor(
  BuildContext context, {
  Snippet? snippet,
  String initialCommand = '',
  String? serverId,
  String? serverName,
}) {
  return showDialog<Snippet>(
    context: context,
    builder: (ctx) => _SnippetEditorDialog(
      snippet: snippet,
      initialCommand: initialCommand,
      serverId: serverId,
      serverName: serverName,
    ),
  );
}

class _SnippetEditorDialog extends StatefulWidget {
  const _SnippetEditorDialog({
    this.snippet,
    required this.initialCommand,
    this.serverId,
    this.serverName,
  });

  final Snippet? snippet;
  final String initialCommand;
  final String? serverId;
  final String? serverName;

  @override
  State<_SnippetEditorDialog> createState() => _SnippetEditorDialogState();
}

class _SnippetEditorDialogState extends State<_SnippetEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _command;
  late final TextEditingController _description;
  late bool _favorite;
  late bool _runImmediately;
  late bool _confirm;
  late bool _onlyThisServer;
  bool _busy = false;
  String? _error;

  bool get _isNew => widget.snippet == null;
  bool get _canScope =>
      widget.serverId != null || widget.snippet?.serverId != null;

  @override
  void initState() {
    super.initState();
    final s = widget.snippet;
    _name = TextEditingController(text: s?.name ?? '');
    _command = TextEditingController(text: s?.command ?? widget.initialCommand);
    _description = TextEditingController(text: s?.description ?? '');
    _favorite = s?.favorite ?? false;
    _runImmediately = s?.runImmediately ?? false;
    _confirm = s?.confirm ?? true;
    _onlyThisServer = s != null && s.serverId != null && s.scope == 'server';
    // A command pasted from the terminal usually has no name yet: start with
    // its first words so saving takes one tap.
    if (_isNew && _name.text.isEmpty && _command.text.trim().isNotEmpty) {
      _name.text = _suggestName(_command.text);
    }
  }

  static String _suggestName(String command) {
    final first = command
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => command)
        .trim();
    if (first.length <= 38) return first;
    return '${first.substring(0, 38)}…';
  }

  @override
  void dispose() {
    _name.dispose();
    _command.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = widget.snippet;
      final saved = await saveSnippet(
        snippet: Snippet(
          id: s?.id ?? '',
          name: _name.text,
          command: _command.text,
          description: _description.text.trim(),
          favorite: _favorite,
          runImmediately: _runImmediately,
          confirm: _confirm,
          scope: _onlyThisServer ? 'server' : 'global',
          serverId: _onlyThisServer
              ? (widget.serverId ?? widget.snippet?.serverId)
              : null,
          order: s?.order ?? 0,
          createdAt: s?.createdAt ?? 0,
          updatedAt: s?.updatedAt ?? 0,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context, saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _askAi() async {
    final answer = await showAiAsk(
      context,
      questionHint: 'Что должна делать команда?',
    );
    if (answer == null || !mounted) return;
    final oldSuggestion = _suggestName(_command.text);
    final replaceName =
        _name.text.trim().isEmpty || _name.text == oldSuggestion;
    setState(() {
      _command.text = answer.command;
      if (replaceName) _name.text = _suggestName(answer.command);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DialogShortcuts(
      onConfirm: () {
        if (!_busy) _save();
      },
      onCancel: () => Navigator.pop(context),
      child: AlertDialog(
        backgroundColor: T.menu,
        insetPadding: const EdgeInsets.all(16),
        title: Text(
          _isNew ? 'Новый сниппет' : 'Сниппет',
          style: const TextStyle(fontSize: 14),
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _name,
                  autofocus: _isNew && _command.text.trim().isEmpty,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    hintText: 'Рестарт nginx',
                  ),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _command,
                  minLines: 2,
                  maxLines: 6,
                  style: TextStyle(fontFamily: T.monoFont, fontSize: 12.5),
                  decoration: const InputDecoration(
                    labelText: 'Команда',
                    hintText: 'sudo systemctl restart nginx',
                  ),
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GhostButton(
                    label: 'Спросить ИИ',
                    icon: Icons.auto_awesome,
                    onPressed: _busy ? null : _askAi,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Описание (необязательно)',
                  ),
                ),
                const SizedBox(height: 6),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _favorite,
                  onChanged: (v) => setState(() => _favorite = v),
                  title: const Text(
                    'В избранном',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: Text(
                    'Быстрый доступ над строкой ввода терминала',
                    style: TextStyle(fontSize: 11, color: T.faint),
                  ),
                ),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _runImmediately,
                  onChanged: (v) => setState(() {
                    _runImmediately = v;
                    if (v) _confirm = true;
                  }),
                  title: const Text(
                    'Выполнять сразу',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: Text(
                    'Иначе команда только вставляется в строку ввода',
                    style: TextStyle(fontSize: 11, color: T.faint),
                  ),
                ),
                if (_runImmediately)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _confirm,
                    onChanged: (v) => setState(() => _confirm = v),
                    title: const Text(
                      'Спрашивать перед выполнением',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                if (_canScope)
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _onlyThisServer,
                    onChanged: (v) => setState(() => _onlyThisServer = v),
                    title: const Text(
                      'Только для этого сервера',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    subtitle: Text(
                      widget.serverName ??
                          widget.serverId ??
                          widget.snippet?.serverId ??
                          '',
                      style: TextStyle(fontSize: 11, color: T.faint),
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: TextStyle(fontSize: 12, color: T.error)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? '…' : 'Сохранить'),
          ),
        ],
      ),
    );
  }
}
