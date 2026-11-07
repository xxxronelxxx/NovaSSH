import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/nova.dart';
import '../../app/server_copy.dart';
import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';
import '../browser/browser_page.dart';

import 'availability_dot.dart';
import 'connection_progress.dart';
import '../settings/settings_page.dart';

/// What is currently being dragged: a server (to re-group) or a group (to reorder).
class _DragData {
  _DragData.server(this.server) : group = null;
  _DragData.group(this.group) : server = null;

  final Server? server;
  final Group? group;
}

/// Startup access-check window: what is happening and how far it got.
class _CheckProgressDialog extends StatelessWidget {
  const _CheckProgressDialog({required this.done, required this.total});

  final ValueListenable<int> done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(24),
      contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 10),
      constraints: const BoxConstraints(maxWidth: 440),
      title: Row(
        children: [
          Icon(Icons.verified_user_outlined, size: 18, color: T.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Проверка доступа к серверам',
              style: TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
      content: ValueListenableBuilder<int>(
        builder: (context, value, _) {
          final progress = total == 0 ? 0.0 : value / total;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Проверяю соединение и учётные данные у каждого сервера.',
                style: TextStyle(fontSize: 12, color: T.dim, height: 1.4),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: T.hover,
                  color: T.accent,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    '$value / $total',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: T.text,
                      fontFamily: T.monoFont,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${(progress * 100).round()}%',
                    style: TextStyle(fontSize: 11.5, color: T.faint),
                  ),
                ],
              ),
            ],
          );
        },
        valueListenable: done,
      ),
    );
  }
}

class ConnectionsPage extends StatefulWidget {
  const ConnectionsPage({super.key, required this.nova});

  final NovaController nova;

  @override
  State<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends State<ConnectionsPage> {
  String? _selectedGroup;
  String _query = '';
  String? _selectedServer;
  bool _busy = false;

  /// null = проверяется, true = доступен, false = недоступен.
  final Map<String, bool?> _reachable = {};
  String _availability = 'up';
  final Set<String> _checked = {};

  /// Kept alive while the server list is shown, so "forward" returns to the
  /// exact same panels, tabs and sessions.
  Widget? _browserView;
  bool _showBrowser = false;

  /// Phones get a compact toolbar (hamburger), a filter dropdown and one-line
  /// server rows without the bulk-selection chrome.
  bool get _mobile => MediaQuery.sizeOf(context).width < 720;

  /// Android shortcut: open the server requested from the launcher.
  Future<void> _openPendingServer() async {
    final id = nova.pendingServerId;
    if (id == null || !mounted) return;
    nova.pendingServerId = null;
    if (_browserView != null) {
      // The browser is already open (possibly hidden): add a tab there.
      nova.queueTabFromShortcut(id);
      setState(() => _showBrowser = true);
      return;
    }
    final server = nova.book.servers.where((s) => s.id == id).firstOrNull;
    if (server != null) await _connect(server);
  }

  NovaController get nova => widget.nova;

  /// Full startup check: reachability **and** credentials, with a progress
  /// window (2/104, 33/104) because a big server list takes a while.
  Future<void> _probeAll() async {
    final servers = [...nova.book.servers];
    if (servers.isEmpty) return;

    setState(() {
      for (final s in servers) {
        _reachable[s.id] = null;
      }
    });

    final done = ValueNotifier<int>(0);
    final total = servers.length;
    if (mounted) {
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _CheckProgressDialog(done: done, total: total),
        ),
      );
    }

    var index = 0;
    Future<void> worker() async {
      while (index < servers.length) {
        final server = servers[index++];
        var state = 'unreachable';
        try {
          state = await checkServerAccess(serverId: server.id);
        } catch (_) {
          state = 'unreachable';
        }
        if (!mounted) return;
        setState(() => _reachable[server.id] = state != 'unreachable');
        done.value = done.value + 1;
      }
    }

    await Future.wait(List.generate(6, (_) => worker()));

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    done.dispose();
    await nova.reload();
    if (mounted) {
      setState(() {
        for (final server in nova.book.servers) {
          if (server.reachable != null)
            _reachable[server.id] = server.reachable;
        }
      });
    }
  }

  @override
  void initState() {
    super.initState();
    // Android launcher shortcut: open the chosen server once the list exists.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPendingServer());
    _availability = 'up';
    for (final server in widget.nova.book.servers) {
      if (server.reachable != null) _reachable[server.id] = server.reachable;
    }
    // Dev aid: `NOVA_AUTOCONNECT=<server id or name>` opens the browser
    // immediately. Debug builds only; release ignores it.
    if (kDebugMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Platform.environment['NOVA_ROUTE'] == 'settings') {
          Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => SettingsPage(nova: nova)));
        }
      });
      final target = Platform.environment['NOVA_AUTOCONNECT'];
      if (target != null && target.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final match = nova.book.servers
              .where((s) => s.id == target || s.name == target)
              .firstOrNull;
          debugPrint(
            'nova: autoconnect target=$target servers=${nova.book.servers.length} '
            'matched=${match?.id}',
          );
          if (match != null) _connect(match);
        });
      }
    }
  }

  List<Server> get _servers {
    final q = _query.trim().toLowerCase();
    return nova.book.servers.where((s) {
      // Any query searches the whole book, not just the selected group.
      if (_selectedGroup != null && s.groupId != _selectedGroup) return false;
      // A search looks through everything, including unchecked servers.
      if (q.isNotEmpty) {
        return s.name.toLowerCase().contains(q) ||
            s.host.toLowerCase().contains(q) ||
            s.user.toLowerCase().contains(q) ||
            s.tags.any((t) => t.toLowerCase().contains(q));
      }
      final up = _reachable[s.id];
      // A server that answers but rejects the login is not "working".
      // Servers that were never probed (up == null) stay visible: hiding a
      // freshly added server behind the default filter looked like data loss.
      if (_availability == 'up' && (up == false || s.authFailed)) return false;
      if (_availability == 'down' && up != false) return false;
      if (_availability == 'badpass' && !s.authFailed) return false;
      if (_availability == 's3' && s.protocol != 's3') return false;
      if (_availability == 'ssh') {
        final p = s.protocol ?? 'sftp';
        if (p != 'sftp') return false;
      }
      if (_availability == 'ftp') {
        final p =
            s.protocol ??
            switch (s.port) {
              21 => 'ftp',
              990 => 'ftps',
              _ => 'sftp',
            };
        if (p != 'ftp' && p != 'ftps') return false;
      }
      return true;
    }).toList()..sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }

  /// Hidden while the user dismissed it for this launch.
  bool _hideRestore = false;

  Future<void> _connect(
    Server server, {
    List<OpenSession> restore = const [],
  }) async {
    if (_busy) return;
    // The browser keeps its sessions alive, so connecting from the list while
    // it exists must become a new tab: `_browserView ??=` used to keep the old
    // page and silently throw the new session away.
    if (_browserView != null) {
      nova.queueTabFromShortcut(server.id);
      setState(() => _showBrowser = true);
      return;
    }
    setState(() => _busy = true);
    try {
      String? password;
      // S3 authenticates with the key pair, never with a password.
      if (server.protocol != 's3' && server.auth.kind == AuthKind.password) {
        final ref = server.passwordRef ?? 'pwd_${server.id}';
        final stored = await getSecret(id: ref);
        if (stored == null || stored.isEmpty) {
          password = await _askPassword(server);
          if (password == null) return;
          if (nova.unlocked) {
            await setSecret(id: ref, value: password);
          }
        }
      }
      // Progress window while the session is being established.
      final outcome = ValueNotifier<ConnectionOutcome>(
        ConnectionOutcome.pending,
      );
      var cancelled = false;
      if (mounted) {
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => ConnectionProgressDialog(
              server: server,
              outcome: outcome,
              onCancel: () {
                if (cancelled) return;
                cancelled = true;
                unawaited(cancelConnect(serverId: server.id));
                if (mounted) {
                  Navigator.of(context, rootNavigator: true).pop();
                }
              },
            ),
          ),
        );
      }

      ConnectResult result;
      try {
        result = await nova.connect(server, password: password);
        if (cancelled) {
          outcome.dispose();
          unawaited(disconnect(sessionId: result.sessionId).catchError((_) {}));
          return;
        }
        outcome.value = ConnectionOutcome.success;
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (e) {
        if (cancelled) {
          outcome.dispose();
          return;
        }
        // Stop on the failing step instead of pretending everything succeeded.
        outcome.value = ConnectionOutcome.failure;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        outcome.dispose();
        // Wrong credentials: ask for a new password and retry once.
        if (isAuthError(e) && mounted) {
          final entered = await _askNewPassword(server);
          if (entered != null && entered.$1.isNotEmpty) {
            final (newPassword, save) = entered;
            try {
              final retry = await nova.connect(server, password: newPassword);
              if (save && nova.unlocked) {
                final ref = server.passwordRef ?? 'pwd_${server.id}';
                await setSecret(id: ref, value: newPassword);
              }
              if (!mounted) return;
              setState(() {
                _browserView ??= BrowserPage(
                  nova: nova,
                  server: server,
                  connection: retry,
                  restore: restore,
                  onBack: () => setState(() => _showBrowser = false),
                  onClosed: () => setState(() {
                    _browserView = null;
                    _showBrowser = false;
                  }),
                  isVisible: () => _showBrowser,
                );
                _showBrowser = true;
              });
              return;
            } catch (retryError) {
              if (mounted) {
                await showErrorDialog(
                  context,
                  title: 'Не удалось подключиться к ${server.displayLabel}',
                  message: friendlyError(retryError),
                );
              }
              return;
            }
          }
        }
        if (mounted) {
          await showErrorDialog(
            context,
            title: 'Не удалось подключиться к ${server.displayLabel}',
            message: friendlyError(e),
          );
        }
        return;
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      outcome.dispose();
      if (!mounted) return;
      for (final warning in result.warnings) {
        _toast(warning, warn: true);
      }
      setState(() {
        _browserView ??= BrowserPage(
          nova: nova,
          server: server,
          connection: result,
          restore: restore,
          onBack: () => setState(() => _showBrowser = false),
          onClosed: () => setState(() {
            _browserView = null;
            _showBrowser = false;
          }),
        );
        _showBrowser = true;
      });
    } catch (e, stack) {
      debugPrint('nova: connect failed: $e | $stack');
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Не удалось подключиться к ${server.displayLabel}',
          message: friendlyError(e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-entry dialog after a rejected password; can store the new value.
  Future<(String, bool)?> _askNewPassword(Server server) async {
    final controller = TextEditingController();
    var save = true;
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Пароль для ${server.displayLabel} не подошёл'),
          insetPadding: const EdgeInsets.all(24),
          contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          constraints: const BoxConstraints(maxWidth: 420),
          content: SizedBox(
            width: 340,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NovaField(
                  controller: controller,
                  label: 'Новый пароль',
                  obscure: true,
                  autofocus: true,
                  onSubmitted: (v) => Navigator.pop(ctx, (v, save)),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Checkbox(
                      value: save,
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: T.borderStrong),
                      onChanged: (v) => setLocal(() => save = v ?? true),
                    ),
                    Expanded(
                      child: Text(
                        'Сохранить новый пароль',
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
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (controller.text, save)),
              child: const Text('Подключиться'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<String?> _askPassword(Server server) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Пароль для ${server.displayLabel}'),
        content: SizedBox(
          width: 340,
          child: NovaField(
            controller: controller,
            label: 'Пароль',
            obscure: true,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Подключиться'),
          ),
        ],
      ),
    );
  }

  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    final screen = MediaQuery.sizeOf(context).width;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(fontSize: 12.5, color: warn ? T.text : T.text),
        ),
        backgroundColor: warn ? T.warnSurface : T.panel,
        behavior: SnackBarBehavior.floating,
        width: screen - 48 < 520 ? screen - 32 : 520,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
          side: BorderSide(color: T.border),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: nova,
      builder: (context, _) {
        // A launcher shortcut pressed while the app is open: open that server
        // on the next frame (the id is cleared by the handler).
        if (nova.pendingServerId != null) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _openPendingServer(),
          );
        }
        final groups = nova.book.groups;
        final mobile = MediaQuery.sizeOf(context).width < 720;
        // Scaffold is required: it provides the Material ancestor for TextField,
        // SnackBars and ink effects, while staying transparent over the Mica backdrop.
        final content = Scaffold(
          backgroundColor: Colors.transparent,
          body: Padding(
            padding: mobile
                ? const EdgeInsets.fromLTRB(8, 8, 8, 8)
                : const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              children: [
                _toolbar(),
                if (_restoreSessions.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _restoreBanner(_restoreSessions),
                ],
                const SizedBox(height: 12),
                Expanded(
                  child: mobile
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(height: 34, child: _groupStrip(groups)),
                            const SizedBox(height: 8),
                            Expanded(child: _serversPane()),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 236, child: _groupsPane(groups)),
                            const SizedBox(width: 12),
                            Expanded(child: _serversPane()),
                          ],
                        ),
                ),
              ],
            ),
          ),
        );

        // The browser stays mounted (state, sessions, tabs) while hidden, so
        // "forward" returns to exactly the same panels.
        return PopScope(
          // Android back: leave the panels first, exit only from the list.
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (_showBrowser) {
              setState(() => _showBrowser = false);
            } else {
              SystemNavigator.pop();
            }
          },
          child: Stack(
            children: [
              IgnorePointer(
                ignoring: _showBrowser,
                child: AnimatedOpacity(
                  opacity: _showBrowser ? 0 : 1,
                  duration: const Duration(milliseconds: 180),
                  child: content,
                ),
              ),
              if (_browserView != null)
                IgnorePointer(
                  ignoring: !_showBrowser,
                  child: AnimatedOpacity(
                    opacity: _showBrowser ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: _browserView!,
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _toolbar() {
    if (_mobile) {
      return Row(
        children: [
          Expanded(
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Поиск: имя, хост, тег',
                prefixIcon: Icon(Icons.search, size: 16, color: T.faint),
              ),
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            icon: Icon(Icons.menu, color: T.text, size: 22),
            color: T.menu,
            tooltip: 'Меню',
            onSelected: (value) => unawaited(_toolbarAction(value)),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'server',
                child: Text('Новый сервер', style: TextStyle(fontSize: 12.5)),
              ),
              const PopupMenuItem(
                value: 'group',
                child: Text('Новая группа', style: TextStyle(fontSize: 12.5)),
              ),
              const PopupMenuItem(
                value: 'probe',
                child: Text(
                  'Проверить доступность',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
              const PopupMenuItem(
                value: 'settings',
                child: Text('Настройки', style: TextStyle(fontSize: 12.5)),
              ),
              const PopupMenuItem(
                value: 'lock',
                child: Text(
                  'Заблокировать хранилище',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
              if (_browserView != null && !_showBrowser)
                const PopupMenuItem(
                  value: 'forward',
                  child: Text(
                    'Вперёд к открытым панелям',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        const Spacer(),
        SizedBox(
          width: 260,
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            style: TextStyle(fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Поиск: имя, хост, тег',
              prefixIcon: Icon(Icons.search, size: 16, color: T.faint),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ToolButton(
          icon: Icons.create_new_folder_outlined,
          tooltip: 'Новая группа',
          onPressed: () => _editGroup(null),
        ),
        ToolButton(
          icon: Icons.add,
          tooltip: 'Новый сервер',
          accent: true,
          onPressed: () => _editServer(null),
        ),
        SizedBox(width: 4),
        Container(width: 1, height: 20, color: T.border),
        const SizedBox(width: 4),
        ToolButton(
          icon: Icons.arrow_forward,
          tooltip: 'Вперёд к открытым панелям',
          enabled: _browserView != null && !_showBrowser,
          onPressed: () => setState(() => _showBrowser = true),
        ),
        ToolButton(
          icon: Icons.wifi_tethering,
          tooltip: 'Проверить доступность серверов',
          onPressed: () => unawaited(_probeAll()),
        ),
        ToolButton(
          icon: Icons.settings_outlined,
          tooltip: 'Настройки',
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => SettingsPage(nova: nova))),
        ),
        ToolButton(
          icon: Icons.lock_outline,
          tooltip: 'Заблокировать хранилище',
          onPressed: () async {
            await nova.lock();
            await nova.reload();
          },
        ),
      ],
    );
  }

  /// Phone layout: groups as a horizontal chip strip instead of a sidebar.
  Widget _groupStrip(List<Group> groups) {
    final sorted = [...groups]..sort((a, b) => a.order.compareTo(b.order));
    return ListView(
      scrollDirection: Axis.horizontal,
      children: [
        _groupChip(null, 'Все серверы'),
        for (final group in sorted) _groupChip(group, group.name),
      ],
    );
  }

  Widget _groupChip(Group? group, String label) {
    final selected = _selectedGroup == group?.id;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: () => setState(() => _selectedGroup = group?.id),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? T.accent.withValues(alpha: 0.18) : T.hover,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? T.accent.withValues(alpha: 0.6) : T.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: selected ? T.accent : T.dim,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _groupsPane(List<Group> groups) {
    return NovaSurface(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 6, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'ГРУППЫ',
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.1,
                      color: T.faint,
                    ),
                  ),
                ),
                ToolButton(
                  icon: Icons.add,
                  tooltip: 'Новая группа',
                  onPressed: () => _editGroup(null),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                _groupTile(null, 'Все серверы', Icons.apps),
                for (final group in ([
                  ...groups,
                ]..sort((a, b) => a.order.compareTo(b.order))))
                  _groupTile(group, group.name, Icons.folder_outlined),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(6, 4, 6, 2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: GhostButton(
                label: 'Новая группа',
                icon: Icons.create_new_folder_outlined,
                onPressed: () => _editGroup(null),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _groupTile(Group? group, String label, IconData icon) {
    final selected = _selectedGroup == group?.id;
    final count = group == null
        ? nova.book.servers.length
        : nova.book.servers.where((s) => s.groupId == group.id).length;
    final color = group?.color != null ? _hex(group!.color!) : T.dim;

    final tile = Container(
      margin: EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 9),
      decoration: BoxDecoration(
        color: selected ? T.selection : Colors.transparent,
        borderRadius: BorderRadius.circular(T.radiusSmall),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: selected ? T.accent : color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: selected ? T.text : T.dim,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text('$count', style: TextStyle(fontSize: 10.5, color: T.faint)),
        ],
      ),
    );

    // Accepts servers (re-group) and groups (reorder / move to top).
    return DragTarget<_DragData>(
      onWillAcceptWithDetails: (details) =>
          details.data.server != null || details.data.group != null,
      onAcceptWithDetails: (details) {
        if (details.data.server != null) {
          _moveServerToGroup(details.data.server!, group?.id);
        } else if (details.data.group != null) {
          _reorderGroup(details.data.group!, group?.id);
        }
      },
      builder: (context, candidate, rejected) {
        final hovered = candidate.isNotEmpty;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onSecondaryTapDown: (details) =>
                _groupMenu(group, details.globalPosition),
            // The tap area stays a plain InkWell: dragging only starts from the
            // grip, otherwise a slow click was swallowed by the drag gesture.
            child: InkWell(
              onTap: () => setState(() => _selectedGroup = group?.id),
              onDoubleTap: group == null ? null : () => _editGroup(group),
              onSecondaryTapDown: (details) =>
                  _groupMenu(group, details.globalPosition),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(T.radiusSmall),
                  border: Border.all(
                    color: hovered ? T.accent : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Expanded(child: tile),
                    if (group != null)
                      Draggable<_DragData>(
                        data: _DragData.group(group),
                        feedback: _dragChip(label, icon),
                        childWhenDragging: const SizedBox(width: 18),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.drag_indicator,
                              size: 14,
                              color: T.faint,
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
      },
    );
  }

  Widget _dragChip(String label, IconData icon) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: T.menu,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.accent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: T.accent),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: T.text)),
          ],
        ),
      ),
    );
  }

  /// Group context menu: rename, delete, create.
  void _groupMenu(Group? group, Offset position) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: T.menu,
      items: group == null
          ? const [PopupMenuItem(value: 'new', child: Text('Новая группа'))]
          : const [
              PopupMenuItem(value: 'rename', child: Text('Переименовать')),
              PopupMenuItem(value: 'new', child: Text('Новая группа')),
              PopupMenuItem(value: 'delete', child: Text('Удалить группу')),
            ],
    ).then((value) async {
      switch (value) {
        case 'rename':
          await _editGroup(group);
        case 'new':
          await _editGroup(null);
        case 'delete':
          if (group == null) return;
          final ok = await _confirm(
            'Удалить группу «${group.name}»? Серверы останутся без группы.',
          );
          if (ok) await nova.deleteGroup(group.id);
      }
    });
  }

  Future<void> _moveServerToGroup(Server server, String? groupId) async {
    if (server.groupId == groupId) return;
    // copyWith keeps protocol, S3/FTPS settings and the reachability flags:
    // rebuilding the server by hand used to erase them.
    await nova.saveServer(server.copyWith(groupId: groupId));
  }

  /// Reorders groups by dropping one onto another; dropping onto "Все серверы"
  /// moves it to the top. `order` is persisted, so the sidebar keeps the layout.
  Future<void> _reorderGroup(Group moving, String? targetId) async {
    if (moving.id.isEmpty || moving.id == targetId) return;
    final ordered = [...nova.book.groups]
      ..sort((a, b) => a.order.compareTo(b.order));
    final without = ordered.where((g) => g.id != moving.id).toList();
    final index = targetId == null
        ? 0
        : without.indexWhere((g) => g.id == targetId).clamp(0, without.length);
    without.insert(index, moving);
    for (var i = 0; i < without.length; i++) {
      final group = without[i];
      if (group.order == i && group.id != moving.id) continue;
      await nova.saveGroup(
        Group(
          id: group.id,
          name: group.name,
          parent: group.parent,
          color: group.color,
          order: i,
          expanded: group.expanded,
          icon: group.icon,
        ),
      );
    }
  }

  /// Tabs that were open when the app closed.
  List<OpenSession> get _restoreSessions {
    if (_hideRestore) return const [];
    final sessions = nova.state?.openSessions ?? const <OpenSession>[];
    if (sessions.isEmpty) return const [];
    // Only offer servers that still exist.
    final ids = nova.book.servers.map((s) => s.id).toSet();
    return sessions.where((s) => ids.contains(s.serverId)).toList();
  }

  Widget _restoreBanner(List<OpenSession> sessions) {
    final names = sessions
        .map((s) => s.name)
        .where((n) => n.isNotEmpty)
        .join(', ');
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: T.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(T.radiusSmall),
        border: Border.all(color: T.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.restore, size: 16, color: T.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Прошлая сессия: $names',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: T.dim),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_restoreLast(sessions)),
            child: const Text('Продолжить', style: TextStyle(fontSize: 12)),
          ),
          IconButton(
            tooltip: 'Скрыть',
            iconSize: 16,
            icon: Icon(Icons.close, color: T.faint),
            onPressed: () => setState(() => _hideRestore = true),
          ),
        ],
      ),
    );
  }

  Future<void> _restoreLast(List<OpenSession> sessions) async {
    final first = sessions.first;
    final server = nova.book.servers
        .where((s) => s.id == first.serverId)
        .firstOrNull;
    if (server == null) {
      setState(() => _hideRestore = true);
      return;
    }
    setState(() => _hideRestore = true);
    await _connect(server, restore: sessions);
  }

  Future<void> _toolbarAction(String value) async {
    switch (value) {
      case 'server':
        await _editServer(null);
      case 'group':
        await _editGroup(null);
      case 'probe':
        await _probeAll();
      case 'settings':
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => SettingsPage(nova: nova)));
      case 'lock':
        await nova.lock();
        await nova.reload();
      case 'forward':
        setState(() => _showBrowser = true);
    }
  }

  Widget _serversPane() {
    final servers = _servers;
    return NovaSurface(
      child: Column(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: T.border)),
            ),
            child: Row(
              children: [
                Text(
                  _selectedGroup == null
                      ? 'Все серверы'
                      : nova.book.groups
                                .where((g) => g.id == _selectedGroup)
                                .map((g) => g.name)
                                .firstOrNull ??
                            'Группа',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                SizedBox(width: 8),
                Text(
                  '${servers.length}',
                  style: TextStyle(fontSize: 11, color: T.faint),
                ),
                Spacer(),
                if (_mobile)
                  _availabilityDropdown()
                else ...[
                  _availabilityChip('all', 'Все'),
                  _availabilityChip('up', 'Работают'),
                  _availabilityChip('down', 'Не работают'),
                  _availabilityChip('badpass', 'Неверный доступ'),
                  _availabilityChip('ssh', 'SSH'),
                  _availabilityChip('ftp', 'FTP'),
                  _availabilityChip('s3', 'S3'),
                ],
              ],
            ),
          ),
          if (_checked.isNotEmpty) _selectionBar(),
          Expanded(
            child: servers.isEmpty
                ? (_availability != 'all' && _reachable.isEmpty
                      ? _notCheckedState()
                      : _emptyState())
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: servers.length,
                    itemBuilder: (context, index) =>
                        _serverTile(servers[index]),
                  ),
          ),
        ],
      ),
    );
  }

  /// Phone replacement for the filter chips: one dropdown instead of seven
  /// buttons that never fit.
  Widget _availabilityDropdown() {
    const options = [
      ('all', 'Все'),
      ('up', 'Работают'),
      ('down', 'Не работают'),
      ('badpass', 'Неверный доступ'),
      ('ssh', 'SSH'),
      ('ftp', 'FTP'),
      ('s3', 'S3'),
    ];
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: T.hover,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: T.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _availability,
          isDense: true,
          iconSize: 18,
          dropdownColor: T.menu,
          style: TextStyle(fontSize: 11.5, color: T.text),
          items: [
            for (final (value, label) in options)
              DropdownMenuItem(
                value: value,
                child: Text(
                  label,
                  style: TextStyle(fontSize: 11.5, color: T.text),
                ),
              ),
          ],
          onChanged: (value) => setState(() => _availability = value ?? 'all'),
        ),
      ),
    );
  }

  Widget _availabilityChip(String value, String label) {
    final selected = _availability == value;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: () => setState(() => _availability = value),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? T.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: selected ? T.accent : T.border),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: selected ? Colors.white : T.dim,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionBar() {
    final count = _checked.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: T.selection,
        borderRadius: BorderRadius.circular(T.radiusSmall),
        border: Border.all(color: T.accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Text(
            'Выбрано: $count',
            style: TextStyle(fontSize: 12, color: T.text),
          ),
          const Spacer(),
          GhostButton(
            label: 'Снять',
            icon: Icons.clear,
            onPressed: () => setState(() => _checked.clear()),
          ),
          const SizedBox(width: 6),
          GhostButton(
            label: 'Выбрать все',
            icon: Icons.select_all,
            onPressed: () {
              final visible = _servers.map((s) => s.id).toSet();
              setState(() => _checked.addAll(visible));
            },
          ),
          const SizedBox(width: 6),
          PrimaryButton(
            label: 'В группу…',
            icon: Icons.drive_file_move_outline,
            onPressed: count == 0
                ? null
                : () => unawaited(_moveCheckedToGroup()),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: count == 0 ? null : () => unawaited(_deleteChecked()),
            style: FilledButton.styleFrom(
              backgroundColor: T.error,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(T.radiusSmall),
              ),
            ),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Удалить', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteChecked() async {
    final count = _checked.length;
    if (count == 0) return;
    final ok = await _confirm(
      'Удалить ${count == 1 ? 'выбранный сервер' : '$count выбранных серверов'}?\n'
      'Профили будут удалены без возможности отмены.',
    );
    if (!ok) return;
    for (final id in [..._checked]) {
      await nova.deleteServer(id);
    }
    if (mounted) setState(() => _checked.clear());
  }

  Future<void> _moveCheckedToGroup() async {
    final target = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: T.menu,
        title: Text('Перенести серверов: ${_checked.length}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Row(
              children: [
                Icon(Icons.folder_off_outlined, size: 15, color: T.dim),
                const SizedBox(width: 8),
                const Text('Без группы'),
              ],
            ),
          ),
          for (final g in nova.book.groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g.id),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: g.color != null ? _hex(g.color!) : T.dim,
                  ),
                  const SizedBox(width: 8),
                  Text(g.name),
                ],
              ),
            ),
          if (!nova.book.groups.any((g) => g.name.toLowerCase() == 's3')) ...[
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__s3__'),
              child: Row(
                children: [
                  Icon(Icons.add, size: 15, color: T.accent),
                  const SizedBox(width: 8),
                  const Text('Новая группа «S3»'),
                ],
              ),
            ),
          ],
          if (!nova.book.groups.any((g) => g.name.toLowerCase() == 'ftp')) ...[
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__ftp__'),
              child: Row(
                children: [
                  Icon(Icons.add, size: 15, color: T.accent),
                  const SizedBox(width: 8),
                  const Text('Новая группа «FTP»'),
                ],
              ),
            ),
          ],
          if (!nova.book.groups.any(
            (g) => g.name.toLowerCase() == 'нерабочие',
          )) ...[
            const Divider(height: 12),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, '__new__'),
              child: Row(
                children: [
                  Icon(Icons.add, size: 15, color: T.accent),
                  const SizedBox(width: 8),
                  const Text('Новая группа «Нерабочие»'),
                ],
              ),
            ),
          ],
        ],
      ),
    );
    if (target == null) return;

    String? groupId = target.isEmpty ? null : target;
    if (target == '__s3__') {
      const name = 'S3';
      final existing = nova.book.groups
          .where((g) => g.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      groupId =
          existing?.id ??
          (await nova.saveGroup(
            Group(
              id: 'g_${DateTime.now().microsecondsSinceEpoch}',
              name: name,
              parent: null,
              color: '#C39BFF',
              order: nova.book.groups.length,
              expanded: true,
              icon: null,
            ),
          )).id;
    }
    if (target == '__ftp__') {
      const name = 'FTP';
      final existing = nova.book.groups
          .where((g) => g.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      groupId =
          existing?.id ??
          (await nova.saveGroup(
            Group(
              id: 'g_${DateTime.now().microsecondsSinceEpoch}',
              name: name,
              parent: null,
              color: '#4C8DFF',
              order: nova.book.groups.length,
              expanded: true,
              icon: null,
            ),
          )).id;
    }
    if (target == '__new__') {
      const name = 'Нерабочие';
      final existing = nova.book.groups
          .where((g) => g.name.toLowerCase() == name.toLowerCase())
          .firstOrNull;
      groupId =
          existing?.id ??
          (await nova.saveGroup(
            Group(
              id: 'g_${DateTime.now().microsecondsSinceEpoch}',
              name: name,
              parent: null,
              color: '#E5484D',
              order: nova.book.groups.length,
              expanded: true,
              icon: null,
            ),
          )).id;
    }

    for (final id in [..._checked]) {
      final server = nova.book.servers.where((s) => s.id == id).firstOrNull;
      if (server != null) await _moveServerToGroup(server, groupId);
    }
    if (mounted) setState(() => _checked.clear());
  }

  Widget _notCheckedState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fact_check_outlined, size: 34, color: T.faint),
          const SizedBox(height: 10),
          Text(
            'Доступность ещё не проверялась',
            style: TextStyle(fontSize: 12.5, color: T.dim),
          ),
          const SizedBox(height: 4),
          Text(
            'Нажмите ▶ в строке фильтров — серверы разложатся по вкладкам.',
            style: TextStyle(fontSize: 11, color: T.faint),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          PrimaryButton(
            label: 'Проверить доступы',
            icon: Icons.play_arrow,
            onPressed: () => unawaited(_probeAll()),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.dns_outlined, size: 40, color: T.faint),
          SizedBox(height: 12),
          Text(
            'Пока нет ни одного сервера',
            style: TextStyle(fontSize: 13, color: T.dim),
          ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Добавить сервер',
            icon: Icons.add,
            onPressed: () => _editServer(null),
          ),
        ],
      ),
    );
  }

  Widget _serverTile(Server server) {
    final mobile = _mobile;
    final selected = _selectedServer == server.id;
    final label = server.name.trim().isEmpty
        ? '${server.user}@${server.host}'
        : server.name;
    final color = server.color != null ? _hex(server.color!) : T.accent;
    final groupName = server.groupId == null
        ? null
        : nova.book.groups
              .where((g) => g.id == server.groupId)
              .map((g) => g.name)
              .firstOrNull;

    final row = Row(
      children: [
        if (!mobile) ...[
          Checkbox(
            value: _checked.contains(server.id),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            side: BorderSide(color: T.borderStrong),
            onChanged: (v) => setState(() {
              if (v ?? false) {
                _checked.add(server.id);
              } else {
                _checked.remove(server.id);
              }
            }),
          ),
          const SizedBox(width: 4),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
        ],
        // On a phone the only status marker is the pulsing availability dot.
        if (mobile) ...[_availabilityDot(server), const SizedBox(width: 12)],
        Expanded(
          flex: mobile ? 1 : 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: mobile ? 14 : 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${server.user}@${server.host}:${server.port}'
                '${groupName == null || mobile ? '' : ' · $groupName'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: mobile ? 11.5 : 11,
                  color: T.faint,
                  fontFamily: T.monoFont,
                ),
              ),
            ],
          ),
        ),
        if (!mobile) ...[
          _availabilityDot(server),
          const SizedBox(width: 10),
          if (server.tags.isNotEmpty)
            SizedBox(
              width: 150,
              child: Wrap(
                spacing: 4,
                children: [
                  for (final tag in server.tags.take(3))
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: T.hover,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tag,
                        style: TextStyle(fontSize: 10, color: T.dim),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Подключиться',
            icon: const Icon(Icons.login, size: 16),
            color: T.dim,
            onPressed: _busy ? null : () => _connect(server),
          ),
        ],
      ],
    );

    return Builder(
      builder: (rowContext) {
        Offset centerOfRow() {
          final box = rowContext.findRenderObject() as RenderBox?;
          if (box == null) return Offset.zero;
          return box.localToGlobal(box.size.center(Offset.zero));
        }

        final tile = InkWell(
          onTap: mobile
              ? (_busy ? null : () => _connect(server))
              : () => setState(() => _selectedServer = server.id),
          onDoubleTap: mobile ? null : () => _connect(server),
          // Touch devices have no secondary click, so long press opens the
          // same menu as the right mouse button.
          onLongPress: mobile
              ? () {
                  setState(() => _selectedServer = server.id);
                  _contextMenu(server, centerOfRow());
                }
              : null,
          onSecondaryTapDown: (details) {
            setState(() => _selectedServer = server.id);
            _contextMenu(server, details.globalPosition);
          },
          child: Container(
            margin: EdgeInsets.symmetric(
              horizontal: mobile ? 4 : 8,
              vertical: 2,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: mobile ? 8 : 10,
              vertical: mobile ? 12 : 9,
            ),
            decoration: BoxDecoration(
              color: selected ? T.selection : Colors.transparent,
              borderRadius: BorderRadius.circular(T.radiusSmall),
            ),
            child: row,
          ),
        );

        // Dragging onto a group is desktop-only: on touch the long press already
        // means "open the menu".
        if (mobile) return tile;
        return LongPressDraggable<_DragData>(
          delay: const Duration(milliseconds: 150),
          data: _DragData.server(server),
          feedback: _dragChip(label, Icons.dns_outlined),
          childWhenDragging: Opacity(opacity: 0.4, child: tile),
          child: tile,
        );
      },
    );
  }

  /// Green/red/grey dot telling whether the host answers on its SSH port.
  Widget _availabilityDot(Server server) {
    final state = _reachable[server.id];
    final label = state == null
        ? 'Проверяю доступность…'
        : state
        ? 'Сервер доступен (${server.host}:${server.port})'
        : 'Сервер недоступен (${server.host}:${server.port})';
    return Tooltip(
      message: label,
      child: AvailabilityDot(available: _reachable[server.id]),
    );
  }

  void _contextMenu(Server server, Offset position) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & Size(1, 1),
        Offset.zero & overlay.size,
      ),
      color: T.menu,
      items: const [
        PopupMenuItem(value: 'connect', child: Text('Подключиться')),
        PopupMenuItem(value: 'edit', child: Text('Изменить')),
        PopupMenuItem(value: 'move', child: Text('Переместить в группу…')),
        PopupMenuItem(value: 'duplicate', child: Text('Дублировать')),
        PopupMenuItem(value: 'delete', child: Text('Удалить')),
      ],
    ).then((value) async {
      switch (value) {
        case 'connect':
          await _connect(server);
        case 'edit':
          await _editServer(server);
        case 'move':
          await _moveToGroup(server);
        case 'duplicate':
          await _editServer(server, duplicate: true);
        case 'delete':
          final ok = await _confirm('Удалить «${server.displayLabel}»?');
          if (ok) await nova.deleteServer(server.id);
      }
    });
  }

  Future<bool> _confirm(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogShortcuts(
        onConfirm: () => Navigator.pop(ctx, true),
        onCancel: () => Navigator.pop(ctx, false),
        child: AlertDialog(
          title: const Text('Подтверждение'),
          content: Text(message, style: const TextStyle(fontSize: 13)),
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
      ),
    );
    return result ?? false;
  }

  Future<void> _moveToGroup(Server server) async {
    final target = await showDialog<String?>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Переместить в группу'),
        backgroundColor: T.menu,
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, ''),
            child: Row(
              children: [
                Icon(Icons.folder_off_outlined, size: 15, color: T.dim),
                SizedBox(width: 8),
                Text('Без группы'),
              ],
            ),
          ),
          for (final g in nova.book.groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g.id),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 15,
                    color: g.color != null ? _hex(g.color!) : T.dim,
                  ),
                  const SizedBox(width: 8),
                  Text(g.name),
                ],
              ),
            ),
          const Divider(height: 12),
          SimpleDialogOption(
            onPressed: () async {
              Navigator.pop(ctx, '__new__');
            },
            child: Row(
              children: [
                Icon(Icons.add, size: 15, color: T.accent),
                SizedBox(width: 8),
                Text('Новая группа…'),
              ],
            ),
          ),
        ],
      ),
    );
    if (target == null) return;
    if (target == '__new__') {
      await _editGroup(null);
      return;
    }
    await nova.saveServer(
      server.copyWith(groupId: target.isEmpty ? null : target),
    );
  }

  Future<void> _editGroup(Group? group) async {
    final name = TextEditingController(text: group?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(group == null ? 'Новая группа' : 'Группа'),
        content: SizedBox(
          width: 320,
          child: NovaField(
            controller: name,
            label: 'Название',
            autofocus: true,
          ),
        ),
        actions: [
          if (group != null)
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await nova.deleteGroup(group.id);
              },
              child: Text('Удалить', style: TextStyle(color: T.error)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, name.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty) return;
    await nova.saveGroup(
      Group(
        id: group?.id ?? 'g_${DateTime.now().microsecondsSinceEpoch}',
        name: result,
        parent: group?.parent,
        color: group?.color,
        order: group?.order ?? nova.book.groups.length,
        expanded: group?.expanded ?? true,
        icon: group?.icon,
      ),
    );
  }

  Future<void> _editServer(Server? server, {bool duplicate = false}) async {
    final draft =
        server ??
        Server(
          id: 's_${DateTime.now().microsecondsSinceEpoch}',
          name: '',
          host: '',
          port: 22,
          user: '',
          auth: const Auth(kind: AuthKind.password),
          passwordRef: null,
          tags: const [],
          authFailed: false,
        );

    final name = TextEditingController(text: draft.name);
    final host = TextEditingController(text: draft.host);
    final port = TextEditingController(text: draft.port.toString());
    final user = TextEditingController(text: draft.user);
    final keyPath = TextEditingController(text: draft.auth.keyPath ?? '');
    final passphrase = TextEditingController();
    final password = TextEditingController();
    final tags = TextEditingController(text: draft.tags.join(', '));
    final s3Endpoint = TextEditingController(text: draft.s3Endpoint ?? '');
    final s3Region = TextEditingController(text: draft.s3Region ?? 'us-east-1');
    final s3Bucket = TextEditingController(text: draft.s3Bucket ?? '');
    final s3Prefix = TextEditingController(text: draft.s3Prefix ?? '');
    final s3Access = TextEditingController();
    final s3Secret = TextEditingController();
    var s3PathStyle = draft.s3PathStyle ?? true;
    var authKind = draft.auth.kind;
    var protocol = draft.protocol ?? (draft.port == 21 ? 'ftp' : 'sftp');
    var ftpsMode = draft.ftpsMode ?? 'explicit';
    var ftpsInsecure = draft.ftpsInsecure ?? false;
    var passive = draft.passive ?? true;
    String? groupId = draft.groupId;

    final saved = await showDialog<Server>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(server == null ? 'Новый сервер' : 'Сервер'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: NovaField(
                          controller: name,
                          label: 'Название',
                          autofocus: true,
                        ),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String?>(
                          initialValue: groupId,
                          decoration: InputDecoration(labelText: 'Группа'),
                          dropdownColor: T.menu,
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Без группы'),
                            ),
                            for (final g in nova.book.groups)
                              DropdownMenuItem<String?>(
                                value: g.id,
                                child: Text(g.name),
                              ),
                          ],
                          onChanged: (v) => setLocal(() => groupId = v),
                        ),
                      ),
                    ],
                  ),
                  if (protocol != 's3') ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: NovaField(
                            controller: host,
                            label: 'Хост / IP',
                            hint: '10.0.0.5',
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 90,
                          child: NovaField(
                            controller: port,
                            label: 'Порт',
                            keyboardType: TextInputType.number,
                            onChanged: (v) => setLocal(() {
                              if (v.trim() == '21' && protocol == 'sftp') {
                                protocol = 'ftp';
                              }
                            }),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: NovaField(
                            controller: user,
                            label: 'Пользователь',
                            hint: 'root',
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'sftp', label: Text('SFTP')),
                            ButtonSegment(value: 'ftp', label: Text('FTP')),
                            ButtonSegment(value: 'ftps', label: Text('FTPS')),
                            ButtonSegment(value: 's3', label: Text('S3')),
                          ],
                          selected: {protocol},
                          onSelectionChanged: (v) => setLocal(() {
                            protocol = v.first;
                            if (port.text == '22' ||
                                port.text == '21' ||
                                port.text == '990') {
                              port.text = switch (protocol) {
                                'ftp' => '21',
                                'ftps' => '990',
                                _ => '22',
                              };
                            }
                          }),
                        ),
                      ),
                      if (protocol == 'ftps') ...[
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            initialValue: ftpsMode,
                            decoration: const InputDecoration(
                              labelText: 'Режим TLS',
                            ),
                            dropdownColor: T.menu,
                            items: const [
                              DropdownMenuItem(
                                value: 'explicit',
                                child: Text('Явный (21)'),
                              ),
                              DropdownMenuItem(
                                value: 'implicit',
                                child: Text('Неявный (990)'),
                              ),
                            ],
                            onChanged: (v) => setLocal(() {
                              ftpsMode = v ?? 'explicit';
                              // Implicit TLS lives on 990, explicit on 21.
                              if (port.text == '21' || port.text == '990') {
                                port.text = ftpsMode == 'implicit'
                                    ? '990'
                                    : '21';
                              }
                            }),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (protocol == 'ftp' || protocol == 'ftps')
                    Row(
                      children: [
                        Checkbox(
                          value: passive,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: T.borderStrong),
                          onChanged: (v) => setLocal(() => passive = v ?? true),
                        ),
                        Expanded(
                          child: Text(
                            'Пассивный режим',
                            style: TextStyle(fontSize: 12, color: T.dim),
                          ),
                        ),
                        if (protocol == 'ftps') ...[
                          Checkbox(
                            value: ftpsInsecure,
                            visualDensity: VisualDensity.compact,
                            side: BorderSide(color: T.borderStrong),
                            onChanged: (v) =>
                                setLocal(() => ftpsInsecure = v ?? false),
                          ),
                          Expanded(
                            child: Text(
                              'Принимать самоподписанный сертификат',
                              style: TextStyle(fontSize: 12, color: T.dim),
                            ),
                          ),
                        ],
                      ],
                    ),
                  if (protocol == 's3') ...[
                    const SizedBox(height: 10),
                    NovaField(
                      controller: s3Endpoint,
                      label: 'Endpoint',
                      hint:
                          'https://s3.amazonaws.com · http://minio.local:9000',
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: NovaField(
                            controller: s3Region,
                            label: 'Регион (обязателен)',
                            hint: 'us-east-1',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: NovaField(
                            controller: s3Bucket,
                            label: 'Бакет',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: NovaField(
                            controller: s3Access,
                            label: 'Access Key ID',
                            hint: 'пусто = оставить прежний',
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: NovaField(
                            controller: s3Secret,
                            label: 'Secret Access Key',
                            obscure: true,
                            hint: 'пусто = оставить прежний',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    NovaField(
                      controller: s3Prefix,
                      label: 'Префикс / стартовая папка',
                      hint: 'backups/2026/',
                    ),
                    Row(
                      children: [
                        Checkbox(
                          value: s3PathStyle,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: T.borderStrong),
                          onChanged: (v) =>
                              setLocal(() => s3PathStyle = v ?? true),
                        ),
                        Expanded(
                          child: Text(
                            'Path-style (для MinIO и локальных S3)',
                            style: TextStyle(fontSize: 12, color: T.dim),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (protocol != 's3') ...[
                    const SizedBox(height: 12),
                    SegmentedButton<AuthKind>(
                      segments: const [
                        ButtonSegment(
                          value: AuthKind.password,
                          label: Text('Пароль'),
                        ),
                        ButtonSegment(value: AuthKind.key, label: Text('Ключ')),
                      ],
                      selected: {authKind},
                      onSelectionChanged: (v) =>
                          setLocal(() => authKind = v.first),
                    ),
                    const SizedBox(height: 12),
                    if (authKind == AuthKind.password)
                      NovaField(
                        controller: password,
                        label: server == null
                            ? 'Пароль'
                            : 'Новый пароль (если меняем)',
                        obscure: true,
                      )
                    else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: NovaField(
                              controller: keyPath,
                              label: 'Файл ключа',
                              hint: r'C:\Users\you\.ssh\id_ed25519 или .ppk',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: GhostButton(
                              label: 'Выбрать',
                              icon: Icons.folder_open_outlined,
                              onPressed: () async {
                                final file = await openFile(
                                  acceptedTypeGroups: const [
                                    XTypeGroup(
                                      label: 'Ключи SSH',
                                      extensions: [
                                        'ppk',
                                        'pem',
                                        'key',
                                        'openssh',
                                      ],
                                    ),
                                    XTypeGroup(label: 'Все файлы'),
                                  ],
                                );
                                if (file == null) return;
                                setLocal(() => keyPath.text = file.path);
                              },
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      NovaField(
                        controller: passphrase,
                        label: 'Парольная фраза ключа',
                        hint: server != null && draft.auth.passphraseRef != null
                            ? 'оставьте пустым, чтобы не менять'
                            : 'если ключ зашифрован — необязательно',
                        obscure: true,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Поддерживаются OpenSSH, PEM и PuTTY .ppk (в том числе '
                        'зашифрованные). Ключ читается при подключении и никуда '
                        'не копируется.',
                        style: TextStyle(
                          fontSize: 11,
                          color: T.faint,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  NovaField(controller: tags, label: 'Теги (через запятую)'),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final id = duplicate
                    ? 's_${DateTime.now().microsecondsSinceEpoch}'
                    : draft.id;
                Navigator.pop(
                  ctx,
                  // copyWith keeps the fields the form does not edit
                  // (reachability, S3 refs, folder, timestamps).
                  draft.copyWith(
                    id: id,
                    groupId: groupId,
                    name: name.text.trim().isEmpty
                        ? '${user.text.trim()}@${host.text.trim()}'
                        : name.text.trim(),
                    host: protocol == 's3'
                        ? s3Endpoint.text.trim()
                        : host.text.trim(),
                    port: protocol == 's3'
                        ? 443
                        : (int.tryParse(port.text.trim()) ?? 22),
                    user: protocol == 's3' ? '' : user.text.trim(),
                    auth: Auth(
                      kind: authKind,
                      keyPath: authKind == AuthKind.key
                          ? keyPath.text.trim()
                          : null,
                      passphraseRef: authKind == AuthKind.key
                          ? (draft.auth.passphraseRef ??
                                (passphrase.text.trim().isEmpty
                                    ? null
                                    : 'passphrase_$id'))
                          : null,
                    ),
                    passwordRef: protocol == 's3'
                        ? null
                        : (authKind == AuthKind.password ? 'pwd_$id' : null),
                    tags: tags.text
                        .split(',')
                        .map((t) => t.trim())
                        .where((t) => t.isNotEmpty)
                        .toList(),
                    protocol: protocol,
                    ftpsMode: ftpsMode,
                    ftpsInsecure: protocol == 'ftps' ? ftpsInsecure : null,
                    passive: passive,
                    s3Endpoint: protocol == 's3'
                        ? s3Endpoint.text.trim()
                        : draft.s3Endpoint,
                    s3Region: protocol == 's3'
                        ? s3Region.text.trim()
                        : draft.s3Region,
                    s3Bucket: protocol == 's3'
                        ? s3Bucket.text.trim()
                        : draft.s3Bucket,
                    s3Prefix: protocol == 's3'
                        ? s3Prefix.text.trim()
                        : draft.s3Prefix,
                    s3PathStyle: s3PathStyle,
                    s3AccessRef: draft.s3AccessRef ?? 's3a_$id',
                    s3SecretRef: draft.s3SecretRef ?? 's3s_$id',
                  ),
                );
              },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );

    if (saved == null) return;
    try {
      await nova.saveServer(
        saved,
        password: password.text.trim().isEmpty ? null : password.text,
        passphrase:
            saved.auth.kind == AuthKind.key && passphrase.text.trim().isNotEmpty
            ? passphrase.text.trim()
            : null,
      );
      if (saved.protocol == 's3') {
        if (s3Access.text.trim().isNotEmpty && saved.s3AccessRef != null) {
          await setSecret(id: saved.s3AccessRef!, value: s3Access.text.trim());
        }
        if (s3Secret.text.trim().isNotEmpty && saved.s3SecretRef != null) {
          await setSecret(id: saved.s3SecretRef!, value: s3Secret.text.trim());
        }
      }
    } catch (e) {
      _toast(e.toString());
    }
  }

  Color _hex(String value) {
    final cleaned = value.replaceFirst('#', '');
    final parsed = int.tryParse(cleaned, radix: 16);
    if (parsed == null) return T.accent;
    return Color(0xFF000000 | parsed);
  }
}

extension on Server {
  String get displayLabel => name.trim().isEmpty ? '$user@$host' : name;
}
