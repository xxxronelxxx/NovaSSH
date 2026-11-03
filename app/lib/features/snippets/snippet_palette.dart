import 'package:flutter/material.dart';

import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';
import 'snippet_editor.dart';

enum SnippetAction { insert, run }

/// What the user picked in the palette.
class SnippetPick {
  const SnippetPick(this.snippet, this.action, {this.command});

  final Snippet snippet;
  final SnippetAction action;

  /// Command after `{path}` / `{file}` / `{prompt:…}` substitutions.
  final String? command;

  String get text => command ?? snippet.command;
}

/// Values available to `{...}` placeholders.
class SnippetVars {
  const SnippetVars({
    this.path = '',
    this.file = '',
    this.host = '',
    this.user = '',
    this.port = '',
    this.server = '',
  });

  final String path;
  final String file;
  final String host;
  final String user;
  final String port;
  final String server;
}

/// Expands `{path}`, `{file}`, `{host}`, `{user}`, `{port}`, `{server}` and any
/// `{prompt:Вопрос}`; the prompts are asked one by one before insertion.
Future<String> expandSnippetCommand(
  BuildContext context,
  String command,
  SnippetVars vars,
) async {
  var text = command
      .replaceAll('{path}', vars.path)
      .replaceAll('{file}', vars.file)
      .replaceAll('{host}', vars.host)
      .replaceAll('{user}', vars.user)
      .replaceAll('{port}', vars.port)
      .replaceAll('{server}', vars.server);
  final prompts = RegExp(r'\{prompt:([^}]*)\}');
  while (true) {
    final match = prompts.firstMatch(text);
    if (match == null) break;
    if (!context.mounted) break;
    final label = match.group(1)!.trim();
    final answer = await _askValue(context, label.isEmpty ? 'Значение' : label);
    if (answer == null) {
      return '';
    }
    text = text.replaceRange(match.start, match.end, answer);
  }
  return text;
}

Future<String?> _askValue(BuildContext context, String label) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: T.menu,
      title: Text(label, style: const TextStyle(fontSize: 14)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(fontSize: 13),
        decoration: const InputDecoration(hintText: 'Значение'),
        onSubmitted: (value) => Navigator.pop(ctx, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: const Text('Подставить'),
        ),
      ],
    ),
  );
}

/// All snippets with search; visible only for the current server plus globals.
Future<SnippetPick?> showSnippetPalette(
  BuildContext context, {
  required String serverId,
  List<Snippet>? snippets,
  bool selectRun = false,
}) {
  return showDialog<SnippetPick>(
    context: context,
    builder: (ctx) => _SnippetPalette(
      serverId: serverId,
      snippets: snippets,
      selectRun: selectRun,
    ),
  );
}

class _SnippetPalette extends StatefulWidget {
  const _SnippetPalette({
    required this.serverId,
    this.snippets,
    this.selectRun = false,
  });

  final String serverId;
  final List<Snippet>? snippets;
  final bool selectRun;

  @override
  State<_SnippetPalette> createState() => _SnippetPaletteState();
}

class _SnippetPaletteState extends State<_SnippetPalette> {
  final _search = TextEditingController();
  List<Snippet> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.snippets != null) {
      _items = widget.snippets!;
      _loading = false;
    } else {
      _load();
    }
    _search.addListener(() => setState(() {}));
  }

  Future<void> _load() async {
    try {
      final list = await loadSnippets();
      if (!mounted) return;
      setState(() {
        _items = list;
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<Snippet> get _visible {
    final needle = _search.text.trim().toLowerCase();
    return _items
        .where((s) => s.shownForServer(widget.serverId))
        .where(
          (s) =>
              needle.isEmpty ||
              s.name.toLowerCase().contains(needle) ||
              s.command.toLowerCase().contains(needle) ||
              s.description.toLowerCase().contains(needle),
        )
        .toList()
      ..sort((a, b) {
        if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
        return a.order.compareTo(b.order);
      });
  }

  Future<void> _newSnippet() async {
    final saved = await showSnippetEditor(
      context,
      serverId: widget.serverId,
      serverName: null,
    );
    if (saved == null || !mounted) return;
    setState(() => _items = [..._items, saved]);
    Navigator.pop(
      context,
      SnippetPick(
        saved,
        widget.selectRun ? SnippetAction.run : SnippetAction.insert,
      ),
    );
  }

  Future<void> _edit(Snippet snippet) async {
    final saved = await showSnippetEditor(
      context,
      snippet: snippet,
      serverId: widget.serverId,
    );
    if (saved == null || !mounted) return;
    setState(() {
      _items = [
        for (final s in _items)
          if (s.id == saved.id) saved else s,
      ];
    });
  }

  Future<void> _delete(Snippet snippet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.menu,
        title: const Text('Удалить сниппет?', style: TextStyle(fontSize: 14)),
        content: Text(
          '«${snippet.name}» будет удалён из профиля.',
          style: const TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await deleteSnippet(id: snippet.id);
    if (!mounted) return;
    setState(() => _items = _items.where((s) => s.id != snippet.id).toList());
  }

  Future<void> _toggleFavorite(Snippet snippet) async {
    final saved = await saveSnippet(
      snippet: Snippet(
        id: snippet.id,
        name: snippet.name,
        command: snippet.command,
        description: snippet.description,
        favorite: !snippet.favorite,
        runImmediately: snippet.runImmediately,
        confirm: snippet.confirm,
        scope: snippet.scope,
        serverId: snippet.serverId,
        order: snippet.order,
        createdAt: snippet.createdAt,
        updatedAt: snippet.updatedAt,
      ),
    );
    if (!mounted) return;
    setState(() {
      _items = [
        for (final s in _items)
          if (s.id == saved.id) saved else s,
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return DialogShortcuts(
      onConfirm: () {
        if (visible.isEmpty) return;
        Navigator.pop(
          context,
          SnippetPick(
            visible.first,
            widget.selectRun ? SnippetAction.run : SnippetAction.insert,
          ),
        );
      },
      onCancel: () => Navigator.pop(context),
      child: AlertDialog(
        backgroundColor: T.menu,
        insetPadding: const EdgeInsets.all(16),
        title: Row(
          children: [
            Icon(Icons.bolt, size: 16, color: T.accent),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Сниппеты', style: TextStyle(fontSize: 14)),
            ),
            GhostButton(
              label: 'Новый',
              icon: Icons.add,
              onPressed: _newSnippet,
            ),
          ],
        ),
        content: SizedBox(
          width: 620,
          height: 420,
          child: Column(
            children: [
              TextField(
                controller: _search,
                autofocus: true,
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                  hintText: 'Поиск по имени и команде',
                  prefixIcon: Icon(Icons.search, size: 16),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          style: TextStyle(fontSize: 12, color: T.error),
                        ),
                      )
                    : visible.isEmpty
                    ? Center(
                        child: Text(
                          _search.text.trim().isEmpty
                              ? 'Пока нет сниппетов. Нажмите «Новый» или ✨ в '
                                    'терминале.'
                              : 'Ничего не найдено',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: T.faint,
                            height: 1.4,
                          ),
                        ),
                      )
                    : ListView.separated(
                        itemCount: visible.length,
                        separatorBuilder: (_, _) =>
                            Divider(height: 1, color: T.border),
                        itemBuilder: (ctx, i) => _tile(visible[i]),
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _tile(Snippet s) {
    final scoped = s.serverId != null && s.scope == 'server';
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: () => Navigator.pop(
        context,
        SnippetPick(
          s,
          widget.selectRun ? SnippetAction.run : SnippetAction.insert,
        ),
      ),
      leading: Icon(
        s.favorite ? Icons.star : Icons.terminal,
        size: 16,
        color: s.favorite ? T.accent : T.dim,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              s.name,
              style: const TextStyle(fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (scoped) ...[
            const SizedBox(width: 6),
            Text(
              'этот сервер',
              style: TextStyle(fontSize: 9.5, color: T.faint),
            ),
          ],
          if (s.runImmediately) ...[
            const SizedBox(width: 6),
            Icon(Icons.play_arrow, size: 12, color: T.accent),
          ],
        ],
      ),
      subtitle: Text(
        s.command.replaceAll('\n', ' ↵ '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, fontFamily: T.monoFont, color: T.faint),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Выполнить',
            icon: Icon(Icons.play_arrow, size: 17, color: T.accent),
            onPressed: () =>
                Navigator.pop(context, SnippetPick(s, SnippetAction.run)),
          ),
          PopupMenuButton<String>(
            tooltip: 'Ещё',
            icon: Icon(Icons.more_vert, size: 16, color: T.dim),
            color: T.menu,
            onSelected: (value) {
              switch (value) {
                case 'edit':
                  _edit(s);
                case 'favorite':
                  _toggleFavorite(s);
                case 'delete':
                  _delete(s);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Изменить')),
              PopupMenuItem(
                value: 'favorite',
                child: Text(
                  s.favorite ? 'Убрать из избранного' : 'В избранное',
                ),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Удалить')),
            ],
          ),
        ],
      ),
    );
  }
}

extension SnippetScope on Snippet {
  /// A server-scoped snippet belongs to one host; global ones show everywhere.
  bool shownForServer(String serverId) {
    if (serverId.isEmpty || scope != 'server') return true;
    return serverId == this.serverId;
  }
}
