import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/nova.dart';
import '../../bridge/api.dart';
import '../../bridge/model.dart';
import '../../design/tokens.dart';
import '../../design/ui.dart';
import '../connections/connection_progress.dart';
import '../ai/ai_client.dart';
import '../ai/ai_dialog.dart';
import '../editor/editor_page.dart';
import '../logs/edit_log.dart';
import '../settings/settings_page.dart';
import '../snippets/snippet_editor.dart';
import '../snippets/snippet_palette.dart';
import '../transfer_service.dart';
import 'bulk_rename.dart';
import 'compare_page.dart';
import 'selection_range.dart';
import 'transfer_ui.dart';

/// Result of the "create archive" dialog: name and container format.
class _ArchiveChoice {
  const _ArchiveChoice(this.name, this.format);

  final String name;
  final String format;
}

class _TransferMeta {
  _TransferMeta({
    required this.operation,
    required this.source,
    required this.destination,
    this.cancel,
    this.retry,
  });

  final String operation;
  final String source;
  final String destination;
  final VoidCallback? cancel;
  final VoidCallback? retry;
  DateTime started = DateTime.now();
}

class _Status {
  _Status(this.text, {this.error = false});

  final String text;
  final bool error;
}

class _EditWatcher {
  _EditWatcher(this.timer, this.serverId);

  final Timer timer;
  final String serverId;
}

class Pane {
  Pane({required this.scope, required this.path});

  final String scope; // 'local' | 'remote'
  String path;

  /// When set, the pane browses the contents of this archive.
  String? archivePath;

  /// Per-pane quick filter (typing in one pane must not hide files in the other).
  String filter = '';
  DirListing? listing;
  List<Entry> entries = const [];
  Set<String> selection = {};
  int cursor = 0;
  bool loading = false;

  /// Whether the current listing includes dotfiles (needed while filtering).
  bool loadedHidden = false;
  String? error;

  /// Where a shift-click range starts (the last clicked file).
  String? anchorPath;

  /// Column sort: 'name' | 'size' | 'modified', ascending or not.
  String sortKey = 'name';
  bool sortAsc = true;

  /// Kept per pane so quick search can scroll the cursor into view.
  final ScrollController scroll = ScrollController();

  /// The rows the user actually sees (the filter applied).
  ///
  /// The cursor and every action that follows it (F2, F8, Enter, preview) use
  /// this list, otherwise a filtered view acts on a hidden file.
  List<Entry> get visibleEntries {
    final needle = filter.trim().toLowerCase();
    if (needle.isEmpty) return entries;
    return entries.where((e) => e.name.toLowerCase().contains(needle)).toList();
  }

  Entry? get currentEntry {
    final rows = visibleEntries;
    return cursor >= 0 && cursor < rows.length ? rows[cursor] : null;
  }

  List<Entry> get targets => selection.isEmpty
      ? [?currentEntry]
      : entries.where((e) => selection.contains(e.path)).toList();
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.nova,
    required this.server,
    required this.connection,
    this.onBack,
    this.onClosed,
    this.restore = const [],
    this.isVisible,
  });

  final NovaController nova;
  final Server server;
  final ConnectResult connection;

  /// Returns to the server list without destroying this view.
  final VoidCallback? onBack;

  /// Called when the last server tab is closed: the parent drops this page.
  final VoidCallback? onClosed;

  /// Tabs from the previous run to reopen after the first connection.
  final List<OpenSession> restore;

  /// The parent keeps this page mounted while the server list is shown; the
  /// key handler must not act on the hidden panels.
  final bool Function()? isVisible;

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

/// One connected server with its own panes, selection and local path.
class _Tab {
  _Tab({
    required this.server,
    required this.connection,
    required this.local,
    required this.remote,
  });

  final Server server;
  ConnectResult connection;
  final Pane local;
  final Pane remote;
  String active = 'local';
  bool disconnected = false;
  String? disconnectReason;

  String get title {
    final name = server.name.trim();
    return name.isEmpty ? '${server.user}@${server.host}' : name;
  }
}

class _BrowserPageState extends State<BrowserPage> {
  late List<_Tab> _tabs;
  int _index = 0;

  _Tab get _tab => _tabs[_index];
  Pane get _local => _tab.local;
  Pane get _remote => _tab.remote;
  String get _active => _tab.active;
  set _active(String value) => _tab.active = value;

  /// Split view: every open server gets its own cell (2 -> two rows,
  /// 3+ -> a grid of two columns).
  bool _split = false;

  int get _splitColumns => _tabs.length <= 2 ? 1 : 2;

  /// The tab a pane belongs to, even when it is not the focused one.
  _Tab _tabOf(Pane pane) {
    for (final tab in _tabs) {
      if (identical(tab.local, pane) || identical(tab.remote, pane)) return tab;
    }
    return _tab;
  }

  /// What the edit log shows in the "server" column.
  String _serverLabelFor(Pane pane) {
    if (pane.scope != 'remote') return 'локально';
    final tab = _tabOf(pane);
    return '${tab.title} (${tab.server.user}@${tab.server.host}:${tab.server.port})';
  }

  /// Only the connection name; the log file name is built from it.
  String _serverNameFor(Pane pane) {
    return pane.scope == 'remote' ? _tabOf(pane).title : 'локально';
  }

  /// True for the pane the keyboard and the tool buttons act on.
  bool _isFocused(Pane pane) {
    final owner = _tabOf(pane);
    return identical(owner, _tab) && _active == pane.scope;
  }

  /// Applies the quick filter and, for dot-queries, reloads the listing with
  /// hidden entries so `.env` can be found even when dotfiles are not shown.
  void _applyFilter(String value) {
    final pane = _active == 'local' ? _local : _remote;
    setState(() => pane.filter = value);
    _ensureFilterListing(pane);
  }

  void _ensureFilterListing(Pane pane) {
    if (pane.loading || pane.listing == null) return;
    // Hidden entries are needed for the normal listing or for a non-empty
    // filter: a user looking for `.env` should not have to enable "show hidden".
    final wantHidden = _showHidden || pane.filter.trim().isNotEmpty;
    if (wantHidden == pane.loadedHidden) return;
    unawaited(_load(pane, pane.path, showHidden: wantHidden, keepFilter: true));
  }

  /// Makes `tab` the active one and its `scope` the focused pane.
  void _focusPane(_Tab tab, String scope) {
    final index = _tabs.indexOf(tab);
    if (index < 0) return;
    if (index != _index) _index = index;
    if (_active != scope) {
      _active = scope;
      _filterCtrl.text = scope == 'local'
          ? tab.local.filter
          : tab.remote.filter;
    }
    // Clicking a pane must take the keyboard back from the filter/path field,
    // otherwise F5/F8/Enter keep going to the text field.
    if (_textFieldHasFocus()) FocusManager.instance.primaryFocus?.unfocus();
    if (!_keys.hasFocus) _keys.requestFocus();
    _ensureFilterListing(_active == 'local' ? tab.local : tab.remote);
  }

  final List<TransferEvent> _transfers = [];
  final Map<String, _EditWatcher> _editWatchers = {};
  final List<_Status> _statuses = [];
  final Map<String, double> _progress = {};
  final Map<String, _TransferMeta> _meta = {};
  Timer? _rememberTimer;
  final TextEditingController _filterCtrl = TextEditingController();
  final FocusNode _filterFocus = FocusNode(debugLabel: 'filter');
  final FocusNode _keys = FocusNode(debugLabel: 'browser');
  final PageController _mobilePages = PageController();
  bool _transfersExpanded = false;

  /// Phones and small tablets get one pane at a time (swipe to switch).
  bool get _mobile => MediaQuery.sizeOf(context).width < 720;

  /// Multi-rename dialog state (kept between openings).
  String _bulkMask = '[N]';
  bool _bulkRegex = false;
  final TextEditingController _bulkMaskCtrl = TextEditingController(
    text: '[N]',
  );

  /// Recently listed folders, keyed by session/scope/path: revisiting a folder
  /// shows its contents instantly while the refresh runs in the background.
  final Map<String, DirListing> _listingCache = {};

  String _cacheKey(Pane pane, String path) {
    final tab = _tabOf(pane);
    return '${tab.connection.sessionId}|${pane.scope}|${pane.archivePath ?? ''}|$path';
  }

  /// The copy currently shown in the progress window.
  TransferBatch? _batch;

  /// Transfers the user paused; we wait for the core's exact byte count.
  final Set<String> _pausing = {};

  /// Drag & drop from Explorer: the pane under the cursor receives the files.
  final GlobalKey _localPaneKey = GlobalKey();
  final GlobalKey _remotePaneKey = GlobalKey();
  bool _dragging = false;

  /// Touch-friendly selection mode: taps toggle files instead of opening them.
  bool _selecting = false;
  String _selectingScope = 'local';

  /// WinSCP style "synchronize browsing": both panels walk the same folders.
  bool _syncBrowsing = false;

  /// Directory comparison (TC style): marks equal / different / one-sided files.
  bool _compareDirs = false;
  final Map<Pane, Map<String, String>> _cmpCache = {};

  /// Type-ahead prefix and the timer that resets it (Total Commander style).
  String _quick = '';
  Timer? _quickTimer;

  String get _sessionId => _tab.connection.sessionId;
  bool get _showHidden => widget.nova.settings?.panels.showHidden ?? true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    final session = widget.nova.sessionFor(widget.server.id);
    final localPath = (session?.localPath.isNotEmpty ?? false)
        ? session!.localPath
        : (widget.nova.state?.recentLocal.isNotEmpty ?? false)
        ? widget.nova.state!.recentLocal.first
        : '';

    _tabs = [
      _Tab(
        server: widget.server,
        connection: widget.connection,
        local: Pane(scope: 'local', path: localPath),
        remote: Pane(scope: 'remote', path: widget.connection.startPath),
      ),
    ];

    widget.nova.addListener(_onNovaChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (localPath.isEmpty) {
        final home = await homeLocal();
        await _load(_local, home);
      } else {
        await _load(_local, localPath);
      }
      await _load(_remote, widget.connection.startPath);
      if (widget.restore.isNotEmpty) {
        await _restoreTabs(widget.restore);
      }
      _keys.requestFocus();
    });
  }

  /// Reopens the servers that were open last time (paths included).
  Future<void> _restoreTabs(List<OpenSession> sessions) async {
    for (final session in sessions) {
      if (session.serverId == widget.server.id) {
        if (session.localPath.isNotEmpty) {
          await _load(_local, session.localPath);
        }
        if (session.remotePath.isNotEmpty) {
          await _load(_remote, session.remotePath);
        }
        continue;
      }
      final server = widget.nova.book.servers
          .where((s) => s.id == session.serverId)
          .firstOrNull;
      if (server == null) continue;
      try {
        await _openTab(server, silent: true);
        if (!mounted) return;
        final tab = _tabs.last;
        if (session.localPath.isNotEmpty) {
          await _load(tab.local, session.localPath);
        }
        if (session.remotePath.isNotEmpty) {
          await _load(tab.remote, session.remotePath);
        }
      } catch (_) {
        // A server that no longer answers is skipped, the rest still open.
      }
    }
    if (mounted) setState(() {});
  }

  /// Remembers the open tabs so the next launch can offer to restore them.
  void _persistOpenSessions() {
    final sessions = [
      for (final tab in _tabs)
        OpenSession(
          serverId: tab.server.id,
          name: tab.title,
          localPath: tab.local.path,
          remotePath: tab.remote.path,
        ),
    ];
    unawaited(saveOpenSessions(sessions: sessions).catchError((_) {}));
  }

  /// Android shortcut pressed while the browser is open: add the server as a
  /// new tab instead of replacing the page.
  void _onNovaChanged() {
    final id = widget.nova.pendingTabServerId;
    if (id == null || !mounted) return;
    widget.nova.pendingTabServerId = null;
    if (_tabs.any((tab) => tab.server.id == id)) return;
    final server = widget.nova.book.servers
        .where((s) => s.id == id)
        .firstOrNull;
    if (server != null) unawaited(_openTab(server));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    widget.nova.removeListener(_onNovaChanged);
    _quickTimer?.cancel();
    _rememberTimer?.cancel();
    for (final watcher in _editWatchers.values) {
      watcher.timer.cancel();
    }
    _keys.dispose();
    _mobilePages.dispose();
    _bulkMaskCtrl.dispose();
    _filterCtrl.dispose();
    _filterFocus.dispose();
    for (final tab in _tabs) {
      tab.local.scroll.dispose();
      tab.remote.scroll.dispose();
      unawaited(
        disconnect(sessionId: tab.connection.sessionId).catchError((_) {}),
      );
    }
    unawaited(clearAllTmp().catchError((_) {}));
    super.dispose();
  }

  /// Compares a pane against the other one by name: equal / diff / only.
  Map<String, String> _directoryCompare(Pane pane, Pane other) {
    final cached = _cmpCache[pane];
    if (cached != null) return cached;
    final peers = {for (final e in other.entries) e.name.toLowerCase(): e};
    final result = <String, String>{};
    for (final entry in pane.entries) {
      final peer = peers[entry.name.toLowerCase()];
      if (peer == null) {
        result[entry.path] = 'only';
        continue;
      }
      if (entry.kind == EntryKind.dir || peer.kind == EntryKind.dir) {
        result[entry.path] = entry.kind == peer.kind ? 'equal' : 'different';
        continue;
      }
      final sameSize = entry.size == peer.size;
      final sameTime =
          entry.modified == null ||
          peer.modified == null ||
          (entry.modified! - peer.modified!).abs() <= 2000;
      result[entry.path] = sameSize && sameTime ? 'equal' : 'different';
    }
    _cmpCache[pane] = result;
    return result;
  }

  void _toggleDirCompare() {
    setState(() {
      _compareDirs = !_compareDirs;
      _cmpCache.clear();
    });
    if (_compareDirs) {
      final local = _directoryCompare(_local, _remote);
      final remote = _directoryCompare(_remote, _local);
      int count(Map<String, String> map, String state) =>
          map.values.where((v) => v == state).length;
      _toast(
        'Сравнение каталогов: различаются ${count(local, 'different')}, '
        'только локально ${count(local, 'only')}, '
        'только на сервере ${count(remote, 'only')}',
      );
    }
  }

  /// The rows the user actually sees (filter applied).
  List<Entry> _visibleEntries(Pane pane) => pane.visibleEntries;

  /// Shift-click: selects (or adds) the range from the pane's anchor.
  void _selectRange(
    Pane pane,
    List<Entry> entries,
    int index, {
    required bool add,
  }) {
    if (entries.isEmpty) return;
    var anchor = pane.anchorPath == null
        ? pane.cursor
        : entries.indexWhere((e) => e.path == pane.anchorPath);
    // A range started from the ".." row begins at the first real file.
    if (anchor < 0) anchor = 0;
    final paths = rangeSelection(
      [for (final entry in entries) entry.path],
      anchor,
      index,
    );
    if (!add) pane.selection.clear();
    pane.selection.addAll(paths);
    pane.cursor = index;
  }

  /// Rows must come from the same list the row index belongs to.
  List<Entry> _entriesFor(Pane pane) => _visibleEntries(pane);

  /// Directories first, then the pane's chosen column and direction.
  List<Entry> _sorted(Pane pane, List<Entry> entries) {
    final list = [...entries];
    list.sort((a, b) {
      final aDir = a.kind == EntryKind.dir ? 0 : 1;
      final bDir = b.kind == EntryKind.dir ? 0 : 1;
      if (aDir != bDir) return aDir - bDir;
      final cmp = switch (pane.sortKey) {
        'size' => a.size.compareTo(b.size),
        'modified' => (a.modified ?? 0).compareTo(b.modified ?? 0),
        _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      };
      return pane.sortAsc ? cmp : -cmp;
    });
    return list;
  }

  /// Click on a column header: same column flips the direction.
  void _sortBy(Pane pane, String key) {
    final current = pane.currentEntry;
    setState(() {
      if (pane.sortKey == key) {
        pane.sortAsc = !pane.sortAsc;
      } else {
        pane.sortKey = key;
        pane.sortAsc = true;
      }
      pane.entries = _sorted(pane, pane.entries);
      if (current != null) {
        final index = pane.entries.indexWhere((e) => e.path == current.path);
        if (index >= 0) pane.cursor = index;
      }
    });
  }

  /// Keeps the cursor row inside the visible part of the list.
  void _scrollToCursor(Pane pane) {
    final controller = pane.scroll;
    if (!controller.hasClients) return;
    final top = (pane.cursor + 1) * T.rowHeight;
    final bottom = top + T.rowHeight;
    final viewTop = controller.offset;
    final viewBottom = viewTop + controller.position.viewportDimension;
    double target = viewTop;
    if (top < viewTop) {
      target = top;
    } else if (bottom > viewBottom) {
      target = bottom - controller.position.viewportDimension;
    } else {
      return;
    }
    controller.jumpTo(target.clamp(0.0, controller.position.maxScrollExtent));
  }

  Future<void> _load(
    Pane pane,
    String path, {
    bool? showHidden,
    bool keepFilter = false,
  }) async {
    if (path.trim().isEmpty) return;
    final hidden = showHidden ?? _showHidden;
    final keepPath = keepFilter ? pane.currentEntry?.path : null;
    final keepCursor = pane.cursor;

    // Instant paint from the cache, then refresh from the server.
    final cacheKey = _cacheKey(pane, path);
    final cached = _listingCache[cacheKey];
    setState(() {
      pane.loading = true;
      pane.error = null;
      if (!keepFilter && cached != null && path == cached.path) {
        pane.entries = _sorted(pane, cached.entries);
        pane.path = cached.path;
        pane.listing = cached;
      }
    });
    final owner = _tabOf(pane);
    try {
      final DirListing listing;
      if (pane.archivePath != null) {
        listing = await listArchive(
          archivePath: pane.archivePath!,
          inner: path,
          showHidden: hidden,
        );
      } else if (pane.scope == 'local') {
        listing = await listLocal(path: path, showHidden: hidden);
      } else {
        listing = await listRemote(
          sessionId: owner.connection.sessionId,
          path: path,
          showHidden: hidden,
        );
      }
      if (!mounted) return;
      final entries = _sorted(pane, listing.entries);
      _listingCache[cacheKey] = listing;
      setState(() {
        _cmpCache.remove(pane);
        pane.path = listing.path;
        pane.listing = listing;
        pane.entries = entries;
        pane.loadedHidden = hidden;
        if (!keepFilter) {
          pane.selection.clear();
          pane.cursor = 0;
          pane.filter = '';
          if (_isFocused(pane)) _filterCtrl.text = '';
        } else {
          // Keep the row that was under the cursor when the filter triggered
          // a second listing (e.g. hidden files appeared for a dot query).
          final rows = pane.visibleEntries;
          if (keepCursor < 0) {
            pane.cursor = -1;
          } else if (keepPath != null) {
            final index = rows.indexWhere((e) => e.path == keepPath);
            pane.cursor = index >= 0 ? index : (rows.isEmpty ? -1 : 0);
          } else if (pane.cursor >= rows.length) {
            pane.cursor = rows.isEmpty ? -1 : rows.length - 1;
          }
        }
        pane.loading = false;
      });
      _touchSession(owner);
      if (keepFilter) _ensureFilterListing(pane);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        pane.loading = false;
        pane.error = e.toString();
        if (pane.scope == 'remote') {
          owner.disconnected = true;
          owner.disconnectReason = e.toString();
        }
      });
      _toast(
        '${pane.scope == 'local' ? 'Локально' : 'Сервер'}: $e',
        warn: true,
      );
    }
  }

  void _touchSession([_Tab? forTab]) {
    final tab = forTab ?? _tab;
    _rememberTimer?.cancel();
    _rememberTimer = Timer(const Duration(milliseconds: 600), () {
      widget.nova.remember(tab.server.id, tab.remote.path, tab.local.path);
      _persistOpenSessions();
    });
  }

  /// Mirrors the number of running transfers into the Android foreground
  /// service, so the OS does not freeze the app in the background.
  void _syncTransferService() {
    final active = _transfers
        .where(
          (t) =>
              t.state == TransferState.running ||
              t.state == TransferState.queued,
        )
        .length;
    unawaited(TransferService.update(active));
  }

  /// Short-lived status line shown above the transfer queue.
  void _status(String text, {bool error = false}) {
    final entry = _Status(text, error: error);
    setState(() => _statuses.insert(0, entry));
    Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _statuses.remove(entry));
    });
  }

  void _toast(String message, {bool warn = false}) {
    if (!mounted) return;
    final screen = MediaQuery.sizeOf(context).width;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: TextStyle(fontSize: 12.5, color: T.text)),
        backgroundColor: warn ? T.warnSurface : T.panel,
        behavior: SnackBarBehavior.floating,
        width: screen - 48 < 560 ? screen - 32 : 560,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSmall),
          side: BorderSide(color: T.border),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Color? _ruleColor(Entry entry, String scope) {
    final rule = widget.nova.ruleFor(entry.name, scope);
    if (rule?.fg == null) return null;
    final hex = int.tryParse(rule!.fg!.replaceFirst('#', ''), radix: 16);
    return hex == null ? null : Color(0xFF000000 | hex);
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  /// Asks before overwriting files that already exist in a local folder.
  ///
  /// Drop/upload used to call `copyLocal` straight away, which truncates an
  /// existing file with no prompt. Returns null when the user cancels.
  Future<List<String>?> _resolveLocalConflicts(
    Pane target,
    List<String> sources,
  ) async {
    final existing = {for (final e in target.entries) e.name.toLowerCase()};
    final conflicts = [
      for (final path in sources)
        if (existing.contains(fileName(path).toLowerCase())) path,
    ];
    if (conflicts.isEmpty) return sources;

    List<String> withoutConflicts() => [
      for (final path in sources)
        if (!conflicts.contains(path)) path,
    ];

    final policy = widget.nova.settings?.transfer.conflictPolicy ?? 'ask';
    if (policy == 'overwrite') return sources;
    if (policy == 'skip') return withoutConflicts();

    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => DialogShortcuts(
        onConfirm: () => Navigator.pop(ctx, 'overwrite'),
        onCancel: () => Navigator.pop(ctx, 'cancel'),
        child: AlertDialog(
          backgroundColor: T.menu,
          title: const Text(
            'Файлы уже существуют',
            style: TextStyle(fontSize: 14),
          ),
          content: Text(
            'В папке «${target.path}» уже есть ${conflicts.length} из '
            '${sources.length} файлов. Перезаписать их?',
            style: const TextStyle(fontSize: 12.5),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: const Text('Пропустить'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'overwrite'),
              child: const Text('Перезаписать'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null || choice == 'cancel') return null;
    return choice == 'skip' ? withoutConflicts() : sources;
  }

  /// Shows (or brings back) the progress window of a running copy.
  void _showBatchProgress(TransferBatch batch) {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => TransferProgressDialog(
          batch: batch,
          onBackground: () => Navigator.of(ctx).pop(),
        ),
      ),
    );
  }

  /// Starts a batch and shows its window; the queue feeds it via `_batch`.
  TransferBatch _beginBatch(
    String operation,
    String destination,
    List<String> names,
  ) {
    final batch = TransferBatch(
      operation: operation,
      destination: destination,
      files: names,
      cancelTransfer: (id) =>
          unawaited(cancelTransfer(id: id).catchError((_) => false)),
    );
    setState(() => _batch = batch);
    _showBatchProgress(batch);
    return batch;
  }

  Future<void> _copySelection() async {
    final source = _active == 'local' ? _local : _remote;
    final target = _active == 'local' ? _remote : _local;
    final items = source.targets;
    if (items.isEmpty) {
      _toast('Ничего не выбрано');
      return;
    }
    // The opposite pane may be inside an archive: F5 then adds to it instead
    // of uploading/downloading.
    if (target.archivePath != null) {
      await _copyIntoArchive(source, target);
      return;
    }
    final direction = _active == 'local' ? 'upload' : 'download';

    // Overwriting a file on the other side is the dangerous part of F5.
    final conflicts = [
      for (final entry in items)
        if (target.entries.any(
          (e) => e.name.toLowerCase() == entry.name.toLowerCase(),
        ))
          entry,
    ];
    var skipConflicts = false;
    if (conflicts.isNotEmpty) {
      final policy = widget.nova.settings?.transfer.conflictPolicy ?? 'ask';
      if (policy == 'skip') {
        skipConflicts = true;
      } else if (policy != 'overwrite') {
        final choice = await showDialog<String>(
          context: context,
          builder: (ctx) => DialogShortcuts(
            onConfirm: () => Navigator.pop(ctx, 'overwrite'),
            onCancel: () => Navigator.pop(ctx, 'cancel'),
            child: AlertDialog(
              backgroundColor: T.menu,
              title: const Text(
                'Файлы уже существуют',
                style: TextStyle(fontSize: 14),
              ),
              content: Text(
                'На другой панели уже есть ${conflicts.length} из ${items.length} '
                'выбранных файлов. Перезаписать их?',
                style: const TextStyle(fontSize: 12.5),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'cancel'),
                  child: const Text('Отмена'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, 'skip'),
                  child: const Text('Пропустить'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'overwrite'),
                  child: const Text('Перезаписать'),
                ),
              ],
            ),
          ),
        );
        if (!mounted || choice == null || choice == 'cancel') return;
        skipConflicts = choice == 'skip';
      }
    }

    final pending = [
      for (final entry in items)
        if (!(skipConflicts && conflicts.any((c) => c.path == entry.path)))
          entry,
    ];
    if (pending.isEmpty) {
      _toast('Все выбранные файлы уже есть на другой панели');
      return;
    }

    // WinSCP-style prompt: destination folder + rename for a single file.
    final prompt = await showDialog<TransferPromptResult>(
      context: context,
      builder: (ctx) => TransferPromptDialog(
        title: direction == 'upload' ? 'Отправить' : 'Скачать',
        items: [for (final entry in pending) entry.name],
        initialDir: target.path,
        dirLabel: direction == 'upload'
            ? 'Каталог на сервере'
            : 'Каталог на компьютере',
        operation: direction == 'upload' ? 'Отправка' : 'Скачивание',
        allowRename: source.archivePath == null,
      ),
    );
    if (!mounted || prompt == null) return;
    final targetDir = prompt.dir;
    final renameTo = pending.length == 1 ? prompt.name : null;

    if (prompt.background) {
      setState(() => _batch = null);
    } else {
      _beginBatch(prompt.operation, targetDir, [
        for (final entry in pending) entry.name,
      ]);
    }

    for (final entry in pending) {
      if (source.archivePath != null) {
        _track(
          (_) => copyFromArchive(
            sessionId: target.scope == 'remote' ? _sessionId : null,
            archivePath: source.archivePath!,
            inner: entry.path,
            targetDir: target.path,
          ),
          target,
          operation: 'Распаковка',
          source: '${fileName(source.archivePath!)}/${entry.path}',
          destination: targetDir,
        );
        continue;
      }
      _track(
        (int from) => transfer(
          sessionId: _sessionId,
          direction: direction,
          sourcePath: entry.path,
          targetDir: targetDir,
          resumeFrom: BigInt.from(from),
          limitKibps: _limitKibps,
          verify: _verifyAfterCopy,
          targetName: renameTo,
        ),
        target,
        operation: direction == 'upload' ? 'Загрузка' : 'Скачивание',
        source: entry.path,
        destination: joinPath(targetDir, renameTo ?? entry.name),
      );
    }
  }

  /// Resume, speed limit and checksum verification come from the settings.
  int get _limitKibps =>
      widget.nova.settings?.transfer.bandwidthLimitKibps ?? 0;
  bool get _verifyAfterCopy =>
      (widget.nova.settings?.transfer.verifyChecksum ?? 'off') != 'off';

  void _track(
    Stream<TransferEvent> Function(int resumeFrom) run,
    Pane refreshPane, {
    String operation = 'Передача',
    String source = '',
    String destination = '',
    int resumeFrom = 0,
  }) {
    var offset = resumeFrom;
    run(offset).listen(
      (event) {
        if (!mounted) return;
        // A paused transfer is remembered with the exact byte count the core
        // managed to write, which is what makes the later resume safe.
        if (_pausing.remove(event.id)) {
          offset = event.done.toInt();
          setState(() {
            _transfers.removeWhere((t) => t.id == event.id);
            _transfers.insert(
              0,
              TransferEvent(
                id: event.id,
                name: event.name,
                total: event.total,
                done: event.done,
                state: TransferState.failed,
                message: 'Приостановлено',
              ),
            );
          });
          _toast('Передача приостановлена — «Повторить» продолжит с места');
          return;
        }
        setState(() {
          _meta.putIfAbsent(
            event.id,
            () => _TransferMeta(
              operation: operation,
              source: source,
              destination: destination,
              cancel: () {
                // Pause: stop the copy but keep the partial file so the retry
                // button can continue from where it stopped. The subscription
                // stays open until the core reports the exact offset it wrote.
                _pausing.add(event.id);
                unawaited(
                  cancelTransfer(id: event.id).catchError((_) => false),
                );
              },
              retry: () {
                _transfers.removeWhere((t) => t.id == event.id);
                _meta.remove(event.id);
                _track(
                  run,
                  refreshPane,
                  operation: operation,
                  source: source,
                  destination: destination,
                  resumeFrom: offset,
                );
              },
            ),
          );
          _progress[event.id] = event.total.toInt() > 0
              ? event.done.toDouble() / event.total.toDouble()
              : 0.0;
          final index = _transfers.indexWhere((t) => t.id == event.id);
          if (index >= 0) {
            _transfers[index] = event;
          } else {
            _transfers.insert(0, event);
          }
        });
        _batch?.update(
          event.id,
          event.name.isEmpty ? source : event.name,
          event.total.toInt(),
          event.done.toInt(),
        );
        if (event.state == TransferState.done) {
          _batch?.finish(event.id);
        } else if (event.state == TransferState.failed ||
            event.state == TransferState.cancelled) {
          _batch?.finish(event.id, failed: true);
        }
        if (event.state == TransferState.done &&
            refreshPane.archivePath == null) {
          unawaited(_load(refreshPane, refreshPane.path));
        }
        _syncTransferService();
        if (event.state == TransferState.done ||
            event.state == TransferState.failed) {
          Timer(const Duration(seconds: 5), () {
            if (mounted) {
              setState(() => _transfers.removeWhere((t) => t.id == event.id));
            }
          });
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        // A stream that dies before any event (bad name, missing source) must not
        // leave a ghost "running" row and an open progress window.
        final id = 'err_${DateTime.now().microsecondsSinceEpoch}';
        _batch?.finish(id, failed: true);
        setState(() {
          _transfers.insert(
            0,
            TransferEvent(
              id: id,
              name: fileName(source),
              total: BigInt.zero,
              done: BigInt.zero,
              state: TransferState.failed,
              message: '$e',
            ),
          );
        });
        _toast('Передача: $e', warn: true);
        _syncTransferService();
      },
    );
  }

  /// Ctrl+F5: unpack the selected archive (or the folder we are inside) into
  /// the opposite panel.
  Future<void> _extract() async {
    final source = _active == 'local' ? _local : _remote;
    final target = _active == 'local' ? _remote : _local;

    String archivePath;
    String inner;
    if (source.archivePath != null) {
      archivePath = source.archivePath!;
      inner = source.path;
    } else {
      final entry = source.currentEntry;
      if (entry == null || !_isArchive(entry.name)) {
        _toast('Выберите архив для распаковки');
        return;
      }
      archivePath = entry.path;
      inner = '/';
    }

    if (target.archivePath != null) {
      _toast('Архив распаковывается в папку, а не в другой архив', warn: true);
      return;
    }

    // Unpacking on the server keeps the archive where it is: no upload of a
    // multi-gigabyte file just to get its contents.
    if (source.scope == 'remote' && target.scope == 'remote') {
      try {
        _toast('Распаковка на сервере…');
        await extractArchive(
          sessionId: _sessionId,
          archivePath: archivePath,
          inner: inner == '/' ? '' : inner,
          targetDir: target.path,
        );
        _toast('Распаковано в ${target.path}');
        await _load(target, target.path);
      } catch (e) {
        _toast('Распаковка: ${friendlyError(e)}', warn: true);
      }
      return;
    }

    // Remote archive into the local pane: download it once into tmp, then
    // unpack locally. The temporary copy disappears with the server tab.
    var localArchive = archivePath;
    if (source.scope == 'remote') {
      try {
        localArchive = await downloadToCache(
          sessionId: _sessionId,
          serverName: _serverNameFor(source),
          remotePath: archivePath,
        );
      } catch (e) {
        _toast('Не удалось скачать архив: ${friendlyError(e)}', warn: true);
        return;
      }
    }

    _track(
      (_) => copyFromArchive(
        sessionId: target.scope == 'remote' ? _sessionId : null,
        archivePath: localArchive,
        inner: inner,
        targetDir: target.path,
      ),
      target,
      operation: 'Распаковка',
      source: fileName(archivePath),
      destination: target.path,
    );
  }

  Future<void> _removeSelection() async {
    final pane = _active == 'local' ? _local : _remote;
    final items = pane.targets;
    if (items.isEmpty) return;
    final ok = await _confirm(
      'Удалить ${items.length == 1 ? '«${items.first.name}»' : '${items.length} объектов'}?',
    );
    if (!ok) return;
    for (final entry in items) {
      try {
        await remove(
          sessionId: pane.scope == 'remote' ? _sessionId : null,
          path: entry.path,
          isDir: entry.kind == EntryKind.dir,
        );
      } catch (e) {
        _toast('Не удалось удалить ${entry.name}: $e', warn: true);
      }
    }
    await _load(pane, pane.path);
  }

  Future<void> _mkdir() async {
    final pane = _active == 'local' ? _local : _remote;
    final controller = TextEditingController(text: 'новая папка');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Новая папка'),
        insetPadding: const EdgeInsets.all(24),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        constraints: const BoxConstraints(maxWidth: 400),
        content: SizedBox(
          width: 320,
          child: NovaField(
            controller: controller,
            label: 'Имя',
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await mkdir(
        sessionId: pane.scope == 'remote' ? _sessionId : null,
        path: joinPath(pane.path, name),
      );
      await _load(pane, pane.path);
    } catch (e) {
      _toast('$e', warn: true);
    }
  }

  Future<void> _rename() async {
    final pane = _active == 'local' ? _local : _remote;
    final entry = pane.currentEntry;
    if (entry == null) return;
    final controller = TextEditingController(text: entry.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать'),
        insetPadding: const EdgeInsets.all(24),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        constraints: const BoxConstraints(maxWidth: 400),
        content: SizedBox(
          width: 320,
          child: NovaField(
            controller: controller,
            label: 'Новое имя',
            autofocus: true,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == entry.name) return;
    try {
      await rename(
        sessionId: pane.scope == 'remote' ? _sessionId : null,
        from: entry.path,
        to: joinPath(pane.path, name),
      );
      await _load(pane, pane.path);
    } catch (e) {
      _toast('$e', warn: true);
    }
  }

  Future<void> _preview() async {
    final pane = _active == 'local' ? _local : _remote;
    final entry = pane.currentEntry;
    if (entry == null || entry.kind == EntryKind.dir) return;
    try {
      final text = pane.archivePath != null
          ? await previewArchive(
              archivePath: pane.archivePath!,
              inner: entry.path,
              maxBytes: 262144,
            )
          : await preview(
              sessionId: pane.scope == 'remote' ? _sessionId : null,
              path: entry.path,
              maxBytes: 262144,
            );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: SizedBox(
            width: 760,
            height: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: T.border)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 16, color: T.dim),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.name,
                          style: const TextStyle(fontSize: 12.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(14),
                    child: SelectableText(
                      text,
                      style: TextStyle(
                        fontFamily: T.monoFont,
                        fontSize: 12,
                        height: 1.5,
                        color: T.text,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      _toast('$e', warn: true);
    }
  }

  /// F4: external editor when configured, otherwise the built-in viewer.
  /// Remote files are pulled into the edit cache and uploaded back on change.
  Future<void> _edit() async {
    final pane = _active == 'local' ? _local : _remote;
    final entry = pane.currentEntry;
    if (entry == null || entry.kind == EntryKind.dir) return;

    if (pane.archivePath != null) {
      _toast('Редактирование внутри архива — в следующей итерации', warn: true);
      await _preview();
      return;
    }

    final editor = (widget.nova.settings?.editor.external_ ?? '').trim();
    final fallback = widget.nova.settings?.editor.fallbackBuiltin ?? true;
    if (editor.isEmpty) {
      // No external editor configured: the built-in one with highlighting.
      await _openBuiltinEditor(pane, entry);
      return;
    }

    final isRemote = pane.scope == 'remote';
    final serverLabel = _serverLabelFor(pane);
    final serverName = _serverNameFor(pane);
    try {
      final localPath = isRemote
          ? await downloadToCache(
              sessionId: _sessionId,
              serverName: serverName,
              remotePath: entry.path,
            )
          : entry.path;

      try {
        await launchEditor(editor: editor, path: localPath);
      } catch (e) {
        debugPrint('nova: launchEditor failed: $e');
        if (fallback) {
          _toast(
            'Внешний редактор недоступен ($e) — открыт встроенный',
            warn: true,
          );
          await _openBuiltinEditor(pane, entry);
          return;
        }
        rethrow;
      }

      await logFileEdit(
        server: serverLabel,
        serverName: serverName,
        path: entry.path,
        action: 'открыт во внешнем редакторе',
      );
      if (isRemote) {
        _watchEditor(
          localPath,
          entry.path,
          serverLabel,
          serverName,
          _tabOf(pane).server.id,
        );
      }
    } catch (e) {
      _toast('$e', warn: true);
    }
  }

  void _watchEditor(
    String localPath,
    String remotePath,
    String serverLabel,
    String serverName,
    String serverId,
  ) {
    _editWatchers.remove(localPath)?.timer.cancel();
    var baseline = -1;
    var uploading = false;
    unawaited(
      fileMtimeMs(path: localPath)
          .then((value) => baseline = value)
          .catchError((_) => -1),
    );

    late final Timer timer;
    timer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (uploading) return;
      int now;
      try {
        now = await fileMtimeMs(path: localPath);
      } catch (_) {
        return;
      }
      if (baseline < 0) {
        baseline = now;
        return;
      }
      if (now <= baseline) return;

      // Keep watching after a save: Ctrl+S in the same editor window must be
      // uploaded again and again, not only the first time.
      uploading = true;
      final changedAt = now;
      final name = fileName(remotePath);
      _status('$name — сохранение…');
      try {
        await uploadFromCache(
          sessionId: _sessionId,
          localPath: localPath,
          remotePath: remotePath,
        );
        _status('$name сохранён');
        await logFileEdit(
          server: serverLabel,
          serverName: serverName,
          path: remotePath,
          action: 'сохранён',
        );
        await _load(_remote, _remote.path);
      } catch (e) {
        _status('$name: не сохранён — $e', error: true);
        await logFileEdit(
          server: serverLabel,
          serverName: serverName,
          path: remotePath,
          action: 'ошибка сохранения: ${friendlyError(e)}',
        );
      } finally {
        // If the file changed while the upload was running, the next tick sees
        // a newer mtime and uploads that save too.
        baseline = changedAt;
        uploading = false;
      }
    });
    _editWatchers[localPath] = _EditWatcher(timer, serverId);
  }

  /// System file picker (SAF on Android): upload the chosen files into the
  /// current folder of the active pane.
  Future<void> _uploadFromDevice() async {
    final pane = _active == 'local' ? _local : _remote;
    final owner = _tabOf(pane);
    List<XFile> files;
    try {
      files = await openFiles();
    } catch (e) {
      _toast(
        'Не удалось открыть выбор файлов: ${friendlyError(e)}',
        warn: true,
      );
      return;
    }
    if (files.isEmpty) return;

    if (pane.scope == 'local') {
      final allowed = await _resolveLocalConflicts(pane, [
        for (final f in files) f.path,
      ]);
      if (allowed == null) return;
      if (allowed.isEmpty) {
        _toast('Все файлы уже есть в этой папке');
        return;
      }
      try {
        final count = await copyLocal(sources: allowed, targetDir: pane.path);
        _toast('Скопировано: $count');
        await _load(pane, pane.path);
      } catch (e) {
        _toast('Копирование: ${friendlyError(e)}', warn: true);
      }
      return;
    }

    _beginBatch('Отправка', pane.path, [for (final f in files) f.name]);
    for (final file in files) {
      _track(
        (int from) => transfer(
          sessionId: owner.connection.sessionId,
          direction: 'upload',
          sourcePath: file.path,
          targetDir: pane.path,
          resumeFrom: BigInt.from(from),
          limitKibps: _limitKibps,
          verify: _verifyAfterCopy,
          targetName: null,
        ),
        pane,
        operation: 'Загрузка',
        source: file.name,
        destination: pane.path,
      );
    }
    _toast('Загружаю файлов: ${files.length}');
  }

  /// Built-in editor with syntax highlighting; saving writes back to the
  /// source (local file or the remote path through `save_text`).
  Future<void> _openBuiltinEditor(Pane pane, Entry entry) async {
    const limit = 1024 * 1024;
    if (entry.size.toInt() > limit) {
      _toast(
        'Файл больше 1 МБ — встроенный редактор не откроет его целиком',
        warn: true,
      );
      return;
    }

    final isRemote = pane.scope == 'remote';
    final serverLabel = _serverLabelFor(pane);
    final serverName = _serverNameFor(pane);
    final String text;
    try {
      if (isRemote) {
        text = await preview(
          sessionId: _sessionId,
          path: entry.path,
          maxBytes: limit,
        );
      } else {
        final bytes = await File(entry.path).readAsBytes();
        text = utf8.decode(bytes, allowMalformed: true);
      }
    } catch (e) {
      _toast(
        'Не удалось открыть ${entry.name}: ${friendlyError(e)}',
        warn: true,
      );
      return;
    }
    if (text.contains('\u0000')) {
      _toast('Похоже на бинарный файл — редактирование недоступно', warn: true);
      return;
    }
    if (!mounted) return;

    await logFileEdit(
      server: serverLabel,
      serverName: serverName,
      path: entry.path,
      action: 'открыт во встроенном редакторе',
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EditorPage(
          title:
              '${pane.scope == 'remote' ? _tab.title : 'Локально'} · ${entry.name}',
          initialText: text,
          fileName: entry.name,
          onSave: (value) async {
            try {
              if (isRemote) {
                await saveText(
                  file: FileRef(
                    sessionId: _sessionId,
                    archivePath: null,
                    path: entry.path,
                    label: entry.name,
                  ),
                  text: value,
                );
              } else {
                await File(entry.path).writeAsString(value);
              }
              await logFileEdit(
                server: serverLabel,
                serverName: serverName,
                path: entry.path,
                action: 'сохранён',
              );
            } catch (e) {
              await logFileEdit(
                server: serverLabel,
                serverName: serverName,
                path: entry.path,
                action: 'ошибка сохранения: ${friendlyError(e)}',
              );
              rethrow;
            }
          },
        ),
      ),
    );
    await _load(pane, pane.path);
  }

  Future<void> _terminal() async {
    // Configured external terminal (PuTTY / Windows Terminal) wins. A bare
    // command name like `wt.exe` lives in PATH, so only an explicit path is
    // checked here — that check used to hide wt.exe from the default profile.
    final terminal = widget.nova.settings?.terminal;
    final profile = terminal?.profiles
        .where((p) => p.id == terminal.defaultProfile)
        .firstOrNull;
    if (profile != null && profile.command.trim().isNotEmpty) {
      try {
        final command = profile.command.trim();
        final explicitPath = command.contains('\\') || command.contains('/');
        if (!explicitPath || await pathExists(path: command)) {
          // Credentials come from the same session the panel uses.
          String password = '';
          if (_tab.server.auth.kind == AuthKind.password) {
            final ref = _tab.server.passwordRef ?? 'pwd_${_tab.server.id}';
            password = (await getSecret(id: ref)) ?? '';
          }
          final args = profile.args
              .map(
                (a) => a
                    .replaceAll('{user}', _tab.server.user)
                    .replaceAll('{host}', _tab.server.host)
                    .replaceAll('{port}', '${_tab.server.port}')
                    .replaceAll('{password}', password),
              )
              .toList();

          // PuTTY needs -pw <password>; the template does not carry it.
          final isPutty = profile.command.toLowerCase().contains('putty');
          if (isPutty && password.isNotEmpty && !args.contains('-pw')) {
            args.addAll(['-pw', password]);
          }
          await launchProcess(command: command, args: args);
          return;
        }
      } catch (e) {
        if (mounted) _toast('Внешний терминал не запустился: $e', warn: true);
      }
    }

    String shellId;
    try {
      shellId = await openShell(sessionId: _sessionId, cols: 100, rows: 30);
    } catch (e) {
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Терминал',
          message: friendlyError(e),
        );
      }
      return;
    }

    if (!mounted) return;
    final input = TextEditingController();
    final scroll = ScrollController();
    final buffer = StringBuffer();
    var closed = false;

    // Snippets and the assistant are loaded once per terminal window; edits in
    // the palette update this list so the quick strip stays current.
    var snippets = <Snippet>[];
    try {
      snippets = await loadSnippets();
    } catch (_) {}
    var aiEnabled = false;
    try {
      aiEnabled = await aiReady();
    } catch (_) {}
    final isPhone =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    // A cheap, read-only context line for the assistant; cached per terminal
    // window so every question does not run `uname` again.
    String? uname;
    if (aiEnabled) {
      try {
        uname = (await execRemote(
          sessionId: _sessionId,
          command: 'uname -srm',
        )).trim();
      } catch (_) {}
    }
    final server = _tab.server;
    final vars = SnippetVars(
      path: _remote.path,
      file: _remote.currentEntry?.name ?? '',
      host: server.host,
      user: server.user,
      port: '${server.port}',
      server: _tab.title,
    );

    Timer? poll;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          void insertCommand(String command) {
            input.text = command;
            input.selection = TextSelection.collapsed(offset: command.length);
          }

          Future<void> runCommand(String command) async {
            if (command.trim().isEmpty) return;
            try {
              await shellWrite(shellId: shellId, data: '$command\r');
            } catch (e) {
              setLocal(() => buffer.write('\n[ошибка: $e]\n'));
            }
          }

          Future<void> applySnippet(Snippet snippet) async {
            final command = await expandSnippetCommand(
              ctx,
              snippet.command,
              vars,
            );
            if (command.isEmpty || !ctx.mounted) return;
            if (!snippet.runImmediately) {
              insertCommand(command);
              return;
            }
            final confirmed =
                !snippet.confirm ||
                await _confirm(
                  'Выполнить команду?\n\n$command',
                  confirmLabel: 'Выполнить',
                );
            if (confirmed) await runCommand(command);
          }

          Future<void> palette() async {
            final pick = await showSnippetPalette(
              ctx,
              serverId: server.id,
              snippets: snippets,
            );
            if (!ctx.mounted) return;
            // The palette may have created, edited or deleted snippets; reload
            // so the strip and the next palette show the change.
            try {
              snippets = await loadSnippets();
            } catch (_) {}
            if (!ctx.mounted) return;
            setLocal(() {});
            if (pick == null) return;
            if (pick.action == SnippetAction.run) {
              final command = await expandSnippetCommand(
                ctx,
                pick.snippet.command,
                vars,
              );
              if (command.isEmpty || !ctx.mounted) return;
              final confirmed =
                  !pick.snippet.confirm ||
                  await _confirm(
                    'Выполнить команду?\n\n$command',
                    confirmLabel: 'Выполнить',
                  );
              if (confirmed) await runCommand(command);
            } else {
              await applySnippet(pick.snippet);
            }
          }

          Future<void> askAi({String initialQuestion = ''}) async {
            final answer = await showAiAsk(
              ctx,
              questionHint: 'Например: как узнать свободное место на диске',
              initialQuestion: initialQuestion,
              contextText: describeAiContext(
                host: server.host,
                user: server.user,
                port: server.port,
                serverName: _tab.title,
                cwd: _remote.path,
                uname: uname,
              ),
              serverTitle: _tab.title,
            );
            if (answer == null || !ctx.mounted) return;
            final command = await expandSnippetCommand(
              ctx,
              answer.command,
              vars,
            );
            if (command.isEmpty || !ctx.mounted) return;
            if (answer.saveAsSnippet) {
              final saved = await showSnippetEditor(
                ctx,
                initialCommand: command,
                serverId: server.id,
                serverName: _tab.title,
              );
              if (saved != null && ctx.mounted) {
                snippets = [...snippets, saved];
                setLocal(() {});
              }
            }
            if (answer.run) {
              final confirmed = await _confirm(
                'Выполнить команду?\n\n$command',
                confirmLabel: 'Выполнить',
              );
              if (confirmed) await runCommand(command);
            } else {
              insertCommand(command);
            }
          }

          Future<void> saveSnippetFrom(String initialCommand) async {
            final saved = await showSnippetEditor(
              ctx,
              initialCommand: initialCommand,
              serverId: server.id,
              serverName: _tab.title,
            );
            if (saved == null || !ctx.mounted) return;
            snippets = [...snippets, saved];
            setLocal(() {});
            if (!saved.runImmediately && input.text.trim().isEmpty) {
              insertCommand(saved.command);
            }
          }

          Future<void> newSnippet() => saveSnippetFrom(input.text);

          poll ??= Timer.periodic(const Duration(milliseconds: 150), (_) async {
            try {
              final chunk = await shellPoll(shellId: shellId);
              if (chunk.isEmpty || !ctx.mounted) return;
              setLocal(() {
                buffer.write(chunk);
                if (buffer.length > 200000) {
                  buffer.clear();
                }
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (scroll.hasClients) {
                  scroll.jumpTo(scroll.position.maxScrollExtent);
                }
              });
            } catch (_) {
              closed = true;
            }
          });

          final favorites = snippets
              .where((s) => s.favorite && s.shownForServer(server.id))
              .toList();
          Widget terminalBody() => Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xF21A1D23),
                    borderRadius: BorderRadius.circular(T.radiusSmall),
                    border: Border.all(color: T.border),
                  ),
                  child: SingleChildScrollView(
                    controller: scroll,
                    child: SelectableText(
                      buffer.isEmpty ? 'Подключение…' : buffer.toString(),
                      style: const TextStyle(
                        fontFamily: T.monoFont,
                        fontSize: 12,
                        height: 1.35,
                        color: Color(0xFFE8ECF3),
                      ),
                      // Saving a command straight from the output is quicker
                      // than retyping it, especially on a phone.
                      contextMenuBuilder: (menuCtx, state) {
                        final value = state.textEditingValue;
                        final selection = value.selection;
                        final selected = selection.isValid
                            ? selection.textInside(value.text).trim()
                            : '';
                        final items = <ContextMenuButtonItem>[
                          ...state.contextMenuButtonItems,
                          if (selected.isNotEmpty)
                            ContextMenuButtonItem(
                              label: 'Сохранить как сниппет',
                              onPressed: () {
                                state.hideToolbar();
                                saveSnippetFrom(selected);
                              },
                            ),
                        ];
                        return AdaptiveTextSelectionToolbar.buttonItems(
                          anchors: state.contextMenuAnchors,
                          buttonItems: items,
                        );
                      },
                    ),
                  ),
                ),
              ),
              if (favorites.isNotEmpty) ...[
                const SizedBox(height: 6),
                SizedBox(
                  height: 36,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: favorites.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final snippet = favorites[i];
                      return ActionChip(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: T.panelSubtle,
                        side: BorderSide(color: T.border),
                        avatar: Icon(
                          snippet.runImmediately
                              ? Icons.play_arrow
                              : Icons.bolt,
                          size: 14,
                          color: T.accent,
                        ),
                        label: Text(
                          snippet.name,
                          style: TextStyle(fontSize: 11.5, color: T.text),
                        ),
                        onPressed: () => applySnippet(snippet),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: input,
                      autofocus: true,
                      style: const TextStyle(
                        fontFamily: T.monoFont,
                        fontSize: 12.5,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Команда + Enter',
                        prefixIcon: Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: T.accent,
                        ),
                      ),
                      onSubmitted: (value) async {
                        if (value.isEmpty) return;
                        try {
                          await shellWrite(shellId: shellId, data: '$value\r');
                        } catch (e) {
                          setLocal(() => buffer.write('\n[ошибка: $e]\n'));
                        }
                        input.clear();
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Сниппеты (Ctrl+Shift+P)',
                    icon: Icon(Icons.bolt, size: 19, color: T.accent),
                    onPressed: palette,
                  ),
                  if (aiEnabled)
                    IconButton(
                      tooltip: 'Спросить ИИ (Ctrl+Shift+A)',
                      icon: Icon(Icons.auto_awesome, size: 19, color: T.accent),
                      onPressed: () => askAi(),
                    ),
                  IconButton(
                    tooltip: 'Сохранить как сниппет',
                    icon: Icon(Icons.add, size: 19, color: T.dim),
                    onPressed: newSnippet,
                  ),
                ],
              ),
            ],
          );

          if (isPhone) {
            // A phone terminal deserves the whole screen: output, favourite
            // strip and input need vertical space, and a dialog box fights
            // with the on-screen keyboard.
            return Dialog.fullscreen(
              backgroundColor: T.panel,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Padding(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewInsetsOf(ctx).bottom,
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Icon(Icons.terminal, size: 16, color: T.accent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Терминал · ${_tab.title}',
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Закрыть',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Expanded(child: terminalBody()),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: Text('Терминал · ${_tab.title}'),
            insetPadding: const EdgeInsets.all(20),
            contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            constraints: const BoxConstraints(maxWidth: 900, maxHeight: 620),
            content: SizedBox(
              width: 860,
              height: 430,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(
                    LogicalKeyboardKey.keyP,
                    control: true,
                    shift: true,
                  ): palette,
                  const SingleActivator(
                    LogicalKeyboardKey.keyA,
                    control: true,
                    shift: true,
                  ): () =>
                      askAi(),
                },
                child: Focus(autofocus: false, child: terminalBody()),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                },
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      ),
    );

    poll?.cancel();
    if (!closed) shellClose(shellId: shellId);
  }

  Future<bool> _confirm(
    String message, {
    String confirmLabel = 'Удалить',
  }) async {
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
              child: Text(confirmLabel),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  // -------------------------------------------------------------------------
  // Keyboard
  // -------------------------------------------------------------------------

  /// Left/right are taken before the focused list can treat them as Home/End
  /// (which used to jump the cursor to the first/last row only by accident).
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return false;
    }
    if (_tabs.isEmpty || _textFieldHasFocus()) return false;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return false;
    }
    // The parent keeps this page alive while the server list is shown, so it
    // must say when the panels are actually on screen.
    if (widget.isVisible != null && !widget.isVisible!()) return false;
    // A dialog has its own focus scope; arrows there are not for the panels.
    if (!_keys.hasFocus) return false;

    final pane = _active == 'local' ? _local : _remote;
    final rows = _visibleEntries(pane);
    if (rows.isEmpty) return false;
    // -1 is the ".." row rendered above the file list.
    final next = key == LogicalKeyboardKey.arrowLeft ? -1 : rows.length - 1;
    setState(() {
      if (HardwareKeyboard.instance.isShiftPressed && next >= 0) {
        _selectRange(pane, rows, next, add: false);
      } else {
        pane.cursor = next;
        pane.anchorPath = next < 0 ? null : rows[next].path;
      }
    });
    _scrollToCursor(pane);
    return true;
  }

  /// True when a text field inside the page (filter, path bar) owns the keys.
  ///
  /// Without this the page-level Focus below would eat typing, Backspace,
  /// arrows and Delete while the user is editing a field, because Flutter
  /// delivers unhandled keys to the ancestors of the focused node.
  bool _textFieldHasFocus() {
    if (_filterFocus.hasFocus) return true;
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return false;
    // The primary focus of a TextField is its inner Focus/EditableText node,
    // not the TextField widget itself.
    return context.widget is EditableText ||
        context.findAncestorStateOfType<EditableTextState>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_tabs.isEmpty) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final pane = _active == 'local' ? _local : _remote;

    // A focused text field keeps everything except the file shortcuts.
    if (_textFieldHasFocus()) {
      final label = key.keyLabel;
      final isFunctionKey = label.length <= 3 && label.startsWith('F');
      final ctrlD =
          HardwareKeyboard.instance.isControlPressed &&
          key == LogicalKeyboardKey.keyD;
      final altF7 =
          HardwareKeyboard.instance.isAltPressed &&
          key == LogicalKeyboardKey.f7;
      if (!isFunctionKey && !ctrlD && !altF7) {
        return KeyEventResult.ignored;
      }
    }

    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyF) {
      _filterFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5) {
      if (HardwareKeyboard.instance.isControlPressed) {
        unawaited(_extract());
      } else {
        unawaited(_copySelection());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f7) {
      unawaited(_mkdir());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f8 || key == LogicalKeyboardKey.delete) {
      unawaited(_removeSelection());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2) {
      unawaited(_rename());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f3) {
      if (HardwareKeyboard.instance.isControlPressed) {
        unawaited(_compare());
      } else {
        unawaited(_preview());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f4) {
      unawaited(_edit());
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyD) {
      unawaited(_bookmarks());
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed &&
        key == LogicalKeyboardKey.f7) {
      unawaited(_findFiles());
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      setState(() => _active = _active == 'local' ? 'remote' : 'local');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      unawaited(_up(pane));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter) {
      if (pane.cursor < 0) {
        unawaited(_up(pane));
        return KeyEventResult.handled;
      }
      final entry = pane.currentEntry;
      if (entry != null) unawaited(_open(pane, entry));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final rows = _visibleEntries(pane);
      setState(() {
        final next = pane.cursor < rows.length - 1
            ? pane.cursor + 1
            : pane.cursor;
        if (HardwareKeyboard.instance.isShiftPressed) {
          _selectRange(pane, rows, next, add: false);
        } else {
          pane.cursor = next;
          pane.anchorPath = rows.isEmpty ? null : rows[next].path;
        }
      });
      _scrollToCursor(pane);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      final rows = _visibleEntries(pane);
      setState(() {
        final next = pane.cursor > -1 ? pane.cursor - 1 : -1;
        if (HardwareKeyboard.instance.isShiftPressed) {
          _selectRange(pane, rows, next, add: false);
        } else {
          pane.cursor = next;
          pane.anchorPath = rows.isEmpty ? null : rows[next].path;
        }
      });
      _scrollToCursor(pane);
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isShiftPressed &&
        (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end)) {
      final rows = _visibleEntries(pane);
      if (rows.isNotEmpty) {
        setState(
          () => _selectRange(
            pane,
            rows,
            key == LogicalKeyboardKey.home ? 0 : rows.length - 1,
            add: false,
          ),
        );
        _scrollToCursor(pane);
      }
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        key == LogicalKeyboardKey.keyA) {
      final rows = _visibleEntries(pane);
      setState(() {
        pane.selection
          ..clear()
          ..addAll(rows.map((e) => e.path));
      });
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      final entry = pane.currentEntry;
      if (entry != null) {
        setState(() {
          if (pane.selection.contains(entry.path)) {
            pane.selection.remove(entry.path);
          } else {
            pane.selection.add(entry.path);
          }
          if (pane.cursor < pane.visibleEntries.length - 1) pane.cursor++;
        });
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_quick.isNotEmpty) {
        _quick = '';
      } else {
        setState(() => pane.selection.clear());
      }
      return KeyEventResult.handled;
    }

    // Type-ahead: any printable character without modifiers.
    final character = event.character;
    if (character != null &&
        character.length == 1 &&
        character.codeUnitAt(0) >= 0x20 &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed) {
      _quickSearch(pane, character);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Selected files of a pane (directories are skipped).
  List<Entry> _selectedFiles(Pane pane) {
    return [
      for (final entry in pane.entries)
        if (pane.selection.contains(entry.path) && entry.kind != EntryKind.dir)
          entry,
    ];
  }

  FileRef _refFor(Pane pane, Entry entry) {
    final tab = _tabOf(pane);
    if (pane.scope == 'local') {
      final archive = pane.archivePath;
      return FileRef(
        sessionId: null,
        archivePath: archive,
        path: entry.path,
        label: archive == null
            ? entry.name
            : '${fileName(archive)}/${entry.path}',
      );
    }
    return FileRef(
      sessionId: tab.connection.sessionId,
      archivePath: null,
      path: entry.path,
      label: '${tab.title} · ${entry.name}',
    );
  }

  /// Two files from one pane win over one file from each pane: selecting two
  /// files in the same panel is an explicit "compare these two" gesture.
  Future<void> _compare() async {
    final local = _selectedFiles(_local);
    final remote = _selectedFiles(_remote);

    FileRef? left;
    FileRef? right;
    if (local.length >= 2) {
      left = _refFor(_local, local[0]);
      right = _refFor(_local, local[1]);
    } else if (remote.length >= 2) {
      left = _refFor(_remote, remote[0]);
      right = _refFor(_remote, remote[1]);
    } else if (local.length == 1 && remote.length == 1) {
      left = _refFor(_local, local[0]);
      right = _refFor(_remote, remote[0]);
    } else {
      // Nothing (or one thing) selected: fall back to the cursors of both panes.
      final leftEntry = _local.currentEntry;
      final rightEntry = _remote.currentEntry;
      if (leftEntry != null &&
          rightEntry != null &&
          leftEntry.kind != EntryKind.dir &&
          rightEntry.kind != EntryKind.dir) {
        left = _refFor(_local, leftEntry);
        right = _refFor(_remote, rightEntry);
      }
    }

    if (left == null || right == null) {
      _toast(
        'Выделите два файла в одной панели или по одному файлу в каждой панели',
        warn: true,
      );
      return;
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ComparePage(left: left!, right: right!),
      ),
    );
  }

  /// Ctrl+D: per-panel folder bookmarks, stored in the settings file.
  Future<void> _bookmarks() async {
    final pane = _active == 'local' ? _local : _remote;
    final remote = pane.scope == 'remote';
    final settings = widget.nova.settings;
    final saved = remote
        ? settings?.panels.remoteBookmarks ?? const <String>[]
        : settings?.panels.localBookmarks ?? const <String>[];
    final list = List<String>.of(saved);

    Future<void> persist() =>
        widget.nova.saveBookmarks(remote: remote, paths: list);

    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: T.menu,
          title: Text(
            remote ? 'Закладки · сервер' : 'Закладки · локально',
            style: const TextStyle(fontSize: 14),
          ),
          content: SizedBox(
            width: _dialogWidth(520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (list.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'Пока нет закладок — добавьте текущую папку.',
                      style: TextStyle(fontSize: 12, color: T.faint),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final path in list)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.folder_outlined,
                              size: 16,
                              color: T.accent,
                            ),
                            title: Text(
                              path,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontFamily: T.monoFont,
                              ),
                            ),
                            onTap: () => Navigator.pop(ctx, path),
                            trailing: InkWell(
                              onTap: () {
                                setLocal(() => list.remove(path));
                                unawaited(persist());
                              },
                              child: Icon(
                                Icons.close,
                                size: 14,
                                color: T.faint,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text(
                    'Добавить текущую папку',
                    style: TextStyle(fontSize: 12),
                  ),
                  onPressed: () {
                    if (list.contains(pane.path)) return;
                    setLocal(() => list.insert(0, pane.path));
                    unawaited(persist());
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      ),
    );

    if (chosen != null) await _load(pane, chosen);
  }

  /// SHA-256 of one file, optionally compared with the other panel's cursor.
  Future<void> _checksumDialog(
    Pane pane,
    Entry entry, {
    bool compareWithOther = false,
  }) async {
    final other = pane.scope == 'local' ? _remote : _local;
    final peer = compareWithOther ? other.currentEntry : null;
    if (compareWithOther && (peer == null || peer.kind == EntryKind.dir)) {
      _toast('На другой панели нет файла под курсором', warn: true);
      return;
    }

    FileChecksum mine;
    FileChecksum? theirs;
    try {
      mine = await checksum(
        sessionId: pane.scope == 'remote'
            ? _tabOf(pane).connection.sessionId
            : null,
        path: entry.path,
        algorithm: 'sha256',
      );
      if (peer != null) {
        theirs = await checksum(
          sessionId: other.scope == 'remote'
              ? _tabOf(other).connection.sessionId
              : null,
          path: peer.path,
          algorithm: 'sha256',
        );
      }
    } catch (e) {
      _toast('Контрольная сумма: ${friendlyError(e)}', warn: true);
      return;
    }
    if (!mounted) return;

    Widget line(String label, FileChecksum value) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(label, style: TextStyle(fontSize: 11, color: T.faint)),
                const Spacer(),
                Text(
                  '${formatBytes(value.size.toInt())} · ${value.computedBy == 'server' ? 'на сервере' : 'локально'}',
                  style: TextStyle(fontSize: 10.5, color: T.faint),
                ),
              ],
            ),
            const SizedBox(height: 3),
            SelectableText(
              value.hash,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: T.monoFont,
                color: T.text,
              ),
            ),
          ],
        ),
      );
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: T.menu,
        title: Text(
          'SHA-256 · ${entry.name}',
          style: const TextStyle(fontSize: 14),
        ),
        content: SizedBox(
          width: _dialogWidth(620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              line(entry.name, mine),
              if (theirs != null) ...[
                const Divider(height: 16),
                line(peer!.name, theirs),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Icon(
                      mine.hash == theirs.hash
                          ? Icons.check_circle_outline
                          : Icons.error_outline,
                      size: 15,
                      color: mine.hash == theirs.hash ? T.success : T.error,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      mine.hash == theirs.hash ? 'Совпадают' : 'Не совпадают',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: mine.hash == theirs.hash ? T.success : T.error,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: mine.hash));
              _toast('SHA-256 скопирован');
            },
            child: const Text('Копировать'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  /// Alt+F7: recursive search by name mask and (optionally) by contents.
  Future<void> _findFiles() async {
    final pane = _active == 'local' ? _local : _remote;
    final owner = _tabOf(pane);
    final maskCtrl = TextEditingController(text: '*');
    final contentCtrl = TextEditingController();
    var busy = false;
    var results = <FoundFile>[];
    String? error;

    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Future<void> run() async {
            setLocal(() {
              busy = true;
              error = null;
            });
            try {
              final found = await findFiles(
                sessionId: pane.scope == 'remote'
                    ? owner.connection.sessionId
                    : null,
                root: pane.path,
                mask: maskCtrl.text.trim().isEmpty ? '*' : maskCtrl.text.trim(),
                content: contentCtrl.text.trim().isEmpty
                    ? null
                    : contentCtrl.text.trim(),
                maxResults: 500,
              );
              setLocal(() {
                results = found;
                busy = false;
              });
            } catch (e) {
              setLocal(() {
                busy = false;
                error = friendlyError(e);
              });
            }
          }

          return AlertDialog(
            backgroundColor: T.menu,
            title: Text(
              'Поиск · ${pane.path}',
              style: const TextStyle(fontSize: 14),
            ),
            content: SizedBox(
              width: _dialogWidth(760),
              height: _dialogHeight(520),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: maskCtrl,
                          autofocus: true,
                          style: const TextStyle(fontSize: 12.5),
                          decoration: const InputDecoration(
                            labelText: 'Маска',
                            hintText: '*.php',
                          ),
                          onSubmitted: (_) => unawaited(run()),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: contentCtrl,
                          style: const TextStyle(fontSize: 12.5),
                          decoration: const InputDecoration(
                            labelText: 'Содержит текст (необязательно)',
                          ),
                          onSubmitted: (_) => unawaited(run()),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FilledButton(
                        onPressed: busy ? null : () => unawaited(run()),
                        child: Text(busy ? 'Поиск…' : 'Найти'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    busy
                        ? 'Ищу…'
                        : 'Найдено: ${results.length}'
                              '${results.length >= 500 ? ' (показаны первые 500)' : ''}',
                    style: TextStyle(fontSize: 11, color: T.faint),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        error!,
                        style: TextStyle(fontSize: 11.5, color: T.error),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: T.panel,
                        borderRadius: BorderRadius.circular(T.radiusSmall),
                        border: Border.all(color: T.border),
                      ),
                      child: results.isEmpty
                          ? Center(
                              child: Text(
                                busy ? '' : 'Ничего не найдено',
                                style: TextStyle(fontSize: 12, color: T.faint),
                              ),
                            )
                          : ListView.builder(
                              itemCount: results.length,
                              itemExtent: 24,
                              itemBuilder: (context, index) {
                                final file = results[index];
                                return InkWell(
                                  onTap: () => Navigator.pop(ctx, file.path),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.insert_drive_file_outlined,
                                          size: 12,
                                          color: T.faint,
                                        ),
                                        const SizedBox(width: 6),
                                        SizedBox(
                                          width: 220,
                                          child: Text(
                                            file.name,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              color: T.text,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            file.path,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: T.faint,
                                              fontFamily: T.monoFont,
                                            ),
                                          ),
                                        ),
                                        if (file.matches > 0)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: Text(
                                              '×${file.matches}',
                                              style: TextStyle(
                                                fontSize: 10.5,
                                                color: T.warn,
                                                fontFamily: T.monoFont,
                                              ),
                                            ),
                                          ),
                                        Text(
                                          formatBytes(file.size.toInt()),
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
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      ),
    );

    maskCtrl.dispose();
    contentCtrl.dispose();
    if (picked == null) return;

    await _load(pane, parentPath(picked));
    final index = pane.entries.indexWhere((e) => e.path == picked);
    if (index >= 0) {
      setState(() {
        pane.cursor = index;
        pane.selection
          ..clear()
          ..add(picked);
      });
      _scrollToCursor(pane);
    }
  }

  /// Archive formats offered in the pack dialog, in menu order.
  static const _archiveFormats = <String, String>{
    'zip': 'ZIP (.zip)',
    'tar.gz': 'TAR.GZ (.tar.gz)',
    'tar.bz2': 'TAR.BZ2 (.tar.bz2)',
    'tar.xz': 'TAR.XZ (.tar.xz)',
    'tar.zst': 'TAR.ZST (.tar.zst)',
    '7z': '7Z (.7z)',
    'tar': 'TAR (.tar)',
  };

  /// Single-file compressors: one input file only.
  static const _singleFormats = <String, String>{
    'gz': 'GZ (.gz)',
    'bz2': 'BZ2 (.bz2)',
    'xz': 'XZ (.xz)',
    'zst': 'ZST (.zst)',
  };

  static String _replaceArchiveExt(String name, String format) {
    final lower = name.toLowerCase();
    for (final ext in const [
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.tar.zst',
      '.tar.zstd',
      '.tgz',
      '.tbz2',
      '.txz',
      '.tzst',
      '.zip',
      '.tar',
      '.7z',
      '.gz',
      '.bz2',
      '.xz',
      '.zst',
    ]) {
      if (lower.endsWith(ext)) return '${name.substring(0, name.length - ext.length)}.$format';
    }
    return '$name.$format';
  }

  /// Packs the selection into an archive next to it (local) or on the server.
  Future<void> _createArchive(Pane pane) async {
    final items = pane.targets;
    if (items.isEmpty) {
      _toast('Ничего не выбрано', warn: true);
      return;
    }
    final base = items.length == 1 ? items.first.name : fileName(pane.path);
    final formats = <String, String>{
      ..._archiveFormats,
      if (items.length == 1 && items.first.kind != EntryKind.dir)
        ..._singleFormats,
    };
    final nameCtrl = TextEditingController(text: '$base.zip');
    var format = 'zip';

    final choice = await showDialog<_ArchiveChoice>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: T.menu,
          title: const Text('Создать архив', style: TextStyle(fontSize: 14)),
          content: SizedBox(
            width: _dialogWidth(420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  autofocus: true,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(labelText: 'Имя архива'),
                  onSubmitted: (v) => Navigator.pop(
                    ctx,
                    _ArchiveChoice(v.trim(), format),
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: format,
                  dropdownColor: T.menu,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: const InputDecoration(labelText: 'Формат'),
                  items: [
                    for (final entry in formats.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setLocal(() {
                      format = value;
                      nameCtrl.text = _replaceArchiveExt(nameCtrl.text, value);
                    });
                  },
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
              onPressed: () => Navigator.pop(
                ctx,
                _ArchiveChoice(nameCtrl.text.trim(), format),
              ),
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    if (choice == null || choice.name.isEmpty) return;

    final remote = pane.scope == 'remote';
    final targetPath = joinPath(pane.path, choice.name);
    try {
      final count = await createArchive(
        sessionId: remote ? _tabOf(pane).connection.sessionId : null,
        sources: [for (final entry in items) entry.path],
        targetPath: targetPath,
        format: choice.format,
      );
      _toast(remote
          ? 'Архив ${choice.name} создан на сервере · объектов: $count'
          : 'Создан архив ${choice.name} · файлов: $count');
      await _load(pane, pane.path);
    } catch (e) {
      _toast('Архив: ${friendlyError(e)}', warn: true);
    }
  }

  /// F5 into a pane that browses an archive: the archive is rewritten with the
  /// new files inside (compressed TAR and 7z cannot grow in place).
  Future<void> _copyIntoArchive(Pane source, Pane target) async {
    final items = source.targets;
    if (items.isEmpty) {
      _toast('Ничего не выбрано');
      return;
    }
    if (source.archivePath != null) {
      _toast('Копирование из архива в архив пока не поддерживается', warn: true);
      return;
    }
    if (target.scope != 'local') {
      _toast('Архив должен быть на компьютере', warn: true);
      return;
    }
    final inner = target.path == '/' ? '' : target.path.trim();
    _toast('Добавляю в ${fileName(target.archivePath!)}…');
    try {
      final count = await copyToArchive(
        sessionId: source.scope == 'remote' ? _sessionId : null,
        sources: [for (final entry in items) entry.path],
        archivePath: target.archivePath!,
        inner: inner,
        format: null,
      );
      _toast('Добавлено в архив · файлов: $count');
      await _load(target, target.path);
    } catch (e) {
      _toast('В архив: ${friendlyError(e)}', warn: true);
    }
  }

  /// Creates every folder of `relativeDir` under `root`.
  Future<void> _ensureDirs({
    required String root,
    required String relativeDir,
    String? sessionId,
  }) async {
    if (relativeDir.trim().isEmpty) return;
    var current = root;
    for (final part in relativeDir.split('/')) {
      if (part.isEmpty) continue;
      current = joinPath(current, part);
      try {
        await mkdir(sessionId: sessionId, path: current);
      } catch (_) {
        // Already exists / not allowed — the transfer reports the real error.
      }
    }
  }

  /// WinSCP style directory synchronisation: scan both trees, show the plan,
  /// then upload/download the selected files.
  Future<void> _syncDirectories() async {
    final local = _local;
    final remote = _remote;
    if (local.archivePath != null || _tab.disconnected) {
      _toast('Синхронизация недоступна для этой панели', warn: true);
      return;
    }
    final sessionId = _sessionId;
    final localRoot = local.path;
    final remoteRoot = remote.path;

    var mode = 'newer';
    List<SyncEntry> entries = const [];
    var busy = true;
    // Started from the first build only: the builder runs on every setState.
    var scanStarted = false;
    String? error;
    final selected = <String>{};

    Future<void> scan(StateSetter setLocal) async {
      setLocal(() {
        busy = true;
        error = null;
      });
      try {
        final found = await syncScan(
          sessionId: sessionId,
          localRoot: localRoot,
          remoteRoot: remoteRoot,
          mode: mode,
          maxFiles: 5000,
        );
        setLocal(() {
          entries = found;
          busy = false;
          selected
            ..clear()
            ..addAll(
              found.where((e) => e.action != 'skip').map((e) => e.relative),
            );
        });
      } catch (e) {
        setLocal(() {
          busy = false;
          error = friendlyError(e);
        });
      }
    }

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          if (!scanStarted) {
            // First frame only: rebuilding must not start another scan.
            scanStarted = true;
            unawaited(scan(setLocal));
          }
          final uploads = entries
              .where(
                (e) => e.action == 'upload' && selected.contains(e.relative),
              )
              .length;
          final downloads = entries
              .where(
                (e) => e.action == 'download' && selected.contains(e.relative),
              )
              .length;

          return AlertDialog(
            backgroundColor: T.menu,
            title: Text(
              'Синхронизация · ${fileName(localRoot)} ↔ ${fileName(remoteRoot)}',
              style: const TextStyle(fontSize: 14),
            ),
            content: SizedBox(
              width: _dialogWidth(820),
              height: _dialogHeight(540),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      for (final (key, label) in const [
                        ('upload', 'Загрузить на сервер'),
                        ('download', 'Скачать с сервера'),
                        ('newer', 'Новее побеждает'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () {
                              mode = key;
                              entries = const [];
                              unawaited(scan(setLocal));
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: mode == key
                                    ? T.accent.withValues(alpha: 0.18)
                                    : T.hover,
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: mode == key ? T.accent : T.border,
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: mode == key ? T.accent : T.dim,
                                  fontWeight: mode == key
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (busy)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => unawaited(scan(setLocal)),
                        child: const Text('Пересканировать'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    error ??
                        'К загрузке: $uploads · к скачиванию: $downloads · '
                            'удаления не выполняются',
                    style: TextStyle(
                      fontSize: 11,
                      color: error != null ? T.error : T.faint,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: T.panel,
                        borderRadius: BorderRadius.circular(T.radiusSmall),
                        border: Border.all(color: T.border),
                      ),
                      child: entries.isEmpty
                          ? Center(
                              child: Text(
                                busy ? 'Сканирую…' : 'Отличий нет',
                                style: TextStyle(fontSize: 12, color: T.faint),
                              ),
                            )
                          : ListView.builder(
                              itemCount: entries.length,
                              itemExtent: 24,
                              itemBuilder: (context, index) {
                                final entry = entries[index];
                                final actionable = entry.action != 'skip';
                                return Row(
                                  children: [
                                    SizedBox(
                                      width: 34,
                                      child: Checkbox(
                                        value: selected.contains(
                                          entry.relative,
                                        ),
                                        visualDensity: VisualDensity.compact,
                                        side: BorderSide(color: T.borderStrong),
                                        onChanged: actionable
                                            ? (v) => setLocal(() {
                                                if (v ?? false) {
                                                  selected.add(entry.relative);
                                                } else {
                                                  selected.remove(
                                                    entry.relative,
                                                  );
                                                }
                                              })
                                            : null,
                                      ),
                                    ),
                                    Icon(
                                      switch (entry.action) {
                                        'upload' => Icons.arrow_upward,
                                        'download' => Icons.arrow_downward,
                                        _ => Icons.check,
                                      },
                                      size: 12,
                                      color: switch (entry.action) {
                                        'upload' => T.accent,
                                        'download' => T.success,
                                        _ => T.faint,
                                      },
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        entry.relative,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontFamily: T.monoFont,
                                          color: actionable ? T.text : T.faint,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 190,
                                      child: Text(
                                        entry.reason,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: T.faint,
                                        ),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 80,
                                      child: Text(
                                        formatBytes(entry.size.toInt()),
                                        textAlign: TextAlign.right,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: T.faint,
                                          fontFamily: T.monoFont,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ],
                                );
                              },
                            ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Закрыть'),
              ),
              FilledButton(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: Text('Синхронизировать (${selected.length})'),
              ),
            ],
          );
        },
      ),
    );

    if (apply != true) return;

    var started = 0;
    for (final entry in entries) {
      if (!selected.contains(entry.relative)) continue;
      if (entry.action == 'upload') {
        await _ensureDirs(
          root: remoteRoot,
          relativeDir: parentPath(entry.relative),
          sessionId: sessionId,
        );
        _track(
          (int from) => transfer(
            sessionId: sessionId,
            direction: 'upload',
            sourcePath: entry.localPath,
            targetDir: parentPath(entry.remotePath),
            resumeFrom: BigInt.from(from),
            limitKibps: _limitKibps,
            verify: _verifyAfterCopy,
            targetName: null,
          ),
          remote,
          operation: 'Синхр. ↑',
          source: entry.relative,
          destination: remoteRoot,
        );
        started++;
      } else if (entry.action == 'download') {
        await _ensureDirs(
          root: localRoot,
          relativeDir: parentPath(entry.relative),
        );
        _track(
          (int from) => transfer(
            sessionId: sessionId,
            direction: 'download',
            sourcePath: entry.remotePath,
            targetDir: parentPath(entry.localPath),
            resumeFrom: BigInt.from(from),
            limitKibps: _limitKibps,
            verify: _verifyAfterCopy,
            targetName: null,
          ),
          local,
          operation: 'Синхр. ↓',
          source: entry.relative,
          destination: localRoot,
        );
        started++;
      }
    }
    _toast('Запущено передач: $started');
  }

  /// TC style multi-rename with a live preview.
  Future<void> _bulkRename() async {
    final pane = _active == 'local' ? _local : _remote;
    final owner = _tabOf(pane);
    if (pane.archivePath != null) {
      _toast('Внутри архива переименование недоступно', warn: true);
      return;
    }
    final items = pane.targets;
    if (items.isEmpty) {
      _toast('Ничего не выбрано', warn: true);
      return;
    }
    final names = [for (final entry in items) entry.name];
    final findCtrl = TextEditingController();
    final replaceCtrl = TextEditingController();

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final preview = buildRenamePreview(
            names: names,
            mask: _bulkMask,
            find: findCtrl.text,
            replace: replaceCtrl.text,
            useRegExp: _bulkRegex,
          );
          final ok = canApplyRename(preview);

          return AlertDialog(
            backgroundColor: T.menu,
            title: Text(
              'Массовое переименование · ${names.length}',
              style: const TextStyle(fontSize: 14),
            ),
            content: SizedBox(
              width: _dialogWidth(720),
              height: _dialogHeight(460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _bulkMaskCtrl,
                    style: TextStyle(fontSize: 12.5, fontFamily: T.monoFont),
                    decoration: const InputDecoration(
                      labelText: 'Маска',
                      hintText: '[N]_[C].[E]',
                      helperText: '[N] имя · [E] расширение · [C] счётчик · [Y][M][D] дата',
                    ),
                    onChanged: (v) => setLocal(() => _bulkMask = v),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: findCtrl,
                          style: const TextStyle(fontSize: 12.5),
                          decoration: const InputDecoration(labelText: 'Найти'),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: replaceCtrl,
                          style: const TextStyle(fontSize: 12.5),
                          decoration: const InputDecoration(
                            labelText: 'Заменить на',
                          ),
                          onChanged: (_) => setLocal(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Tooltip(
                        message: 'Регулярное выражение',
                        child: Checkbox(
                          value: _bulkRegex,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: T.borderStrong),
                          onChanged: (v) =>
                              setLocal(() => _bulkRegex = v ?? false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: T.panel,
                        borderRadius: BorderRadius.circular(T.radiusSmall),
                        border: Border.all(color: T.border),
                      ),
                      child: ListView.builder(
                        itemCount: preview.length,
                        itemExtent: 24,
                        itemBuilder: (context, index) {
                          final row = preview[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    row.from,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontFamily: T.monoFont,
                                      color: T.faint,
                                    ),
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_forward,
                                  size: 12,
                                  color: T.faint,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    row.to,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      fontFamily: T.monoFont,
                                      color: row.problem != null
                                          ? T.error
                                          : T.text,
                                    ),
                                  ),
                                ),
                                if (row.problem != null)
                                  Text(
                                    row.problem!,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: T.error,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: ok ? () => Navigator.pop(ctx, true) : null,
                child: const Text('Переименовать'),
              ),
            ],
          );
        },
      ),
    );

    findCtrl.dispose();
    replaceCtrl.dispose();
    if (apply != true) return;

    final preview = buildRenamePreview(names: names, mask: _bulkMask);
    var renamed = 0;
    try {
      for (final row in preview) {
        if (row.from == row.to) continue;
        await rename(
          sessionId: pane.scope == 'remote' ? owner.connection.sessionId : null,
          from: joinPath(pane.path, row.from),
          to: joinPath(pane.path, row.to),
        );
        renamed++;
      }
      _toast('Переименовано: $renamed');
    } catch (e) {
      _toast('Переименование: ${friendlyError(e)}', warn: true);
    }
    await _load(pane, pane.path);
  }

  /// chmod dialog: rwx checkboxes (and the same action for a whole folder).
  Future<void> _permissions(Pane pane, Entry entry) async {
    var mode = (entry.mode ?? int.parse('644', radix: 8)) & 0x1FF;
    var recursive = false;
    final owner = _tabOf(pane);
    final isDir = entry.kind == EntryKind.dir;

    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          Widget label(String text) => Expanded(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: T.faint),
            ),
          );

          Widget row(String title, int read, int write, int exec) {
            Widget box(int bit) => Expanded(
              child: Checkbox(
                value: (mode & bit) != 0,
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: T.borderStrong),
                onChanged: (v) => setLocal(() {
                  mode = (v ?? false) ? mode | bit : mode & ~bit;
                }),
              ),
            );
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      title,
                      style: TextStyle(fontSize: 11.5, color: T.text),
                    ),
                  ),
                  box(read),
                  box(write),
                  box(exec),
                ],
              ),
            );
          }

          return AlertDialog(
            backgroundColor: T.menu,
            title: Text(
              'Права доступа · ${entry.name}',
              style: const TextStyle(fontSize: 14),
            ),
            content: SizedBox(
              width: _dialogWidth(380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 96),
                      label('Чтение'),
                      label('Запись'),
                      label('Выполнение'),
                    ],
                  ),
                  row('Владелец', 256, 128, 64),
                  row('Группа', 32, 16, 8),
                  row('Остальные', 4, 2, 1),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        'Итог: ${mode.toRadixString(8).padLeft(3, '0')}',
                        style: TextStyle(
                          fontSize: 12,
                          color: T.accent,
                          fontFamily: T.monoFont,
                        ),
                      ),
                      const Spacer(),
                      if (isDir) ...[
                        Checkbox(
                          value: recursive,
                          visualDensity: VisualDensity.compact,
                          side: BorderSide(color: T.borderStrong),
                          onChanged: (v) =>
                              setLocal(() => recursive = v ?? false),
                        ),
                        Text(
                          'рекурсивно',
                          style: TextStyle(fontSize: 11.5, color: T.dim),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Применить'),
              ),
            ],
          );
        },
      ),
    );

    if (apply != true) return;
    try {
      final count = await chmod(
        sessionId: pane.scope == 'remote' ? owner.connection.sessionId : null,
        path: entry.path,
        mode: mode,
        recursive: recursive,
      );
      _toast(
        'Права ${mode.toRadixString(8).padLeft(3, '0')} применены к $count',
      );
      await _load(pane, pane.path);
    } catch (e) {
      _toast(friendlyError(e), warn: true);
    }
  }

  void _beginSelection(Pane pane, Entry entry) {
    setState(() {
      _selecting = true;
      _selectingScope = pane.scope;
      _focusPane(_tabOf(pane), pane.scope);
      pane.selection.add(entry.path);
      pane.cursor = pane.entries.indexOf(entry);
    });
  }

  void _endSelection() {
    setState(() {
      _selecting = false;
      for (final tab in _tabs) {
        tab.local.selection.clear();
        tab.remote.selection.clear();
      }
    });
  }

  /// Compact bar shown above the list while selection mode is on.
  Widget _selectionBar(Pane pane) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: T.selection,
      child: Row(
        children: [
          Text(
            'Выбрано ${pane.selection.length}',
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
          const Spacer(),
          ToolButton(
            icon: Icons.content_copy,
            tooltip: 'Копировать в другую панель',
            accent: true,
            onPressed: pane.selection.isEmpty
                ? null
                : () => unawaited(_copySelection()),
          ),
          ToolButton(
            icon: Icons.drive_file_rename_outline,
            tooltip: 'Переименовать',
            enabled: pane.selection.length == 1,
            onPressed: () => unawaited(_rename()),
          ),
          ToolButton(
            icon: Icons.delete_outline,
            tooltip: 'Удалить',
            onPressed: pane.selection.isEmpty
                ? null
                : () => unawaited(_removeSelection()),
          ),
          const SizedBox(width: 4),
          ToolButton(
            icon: Icons.check,
            tooltip: 'Готово',
            onPressed: _endSelection,
          ),
        ],
      ),
    );
  }

  /// Right-click on a file: path to the clipboard, compare, shell shortcuts.
  Future<void> _fileMenu(Pane pane, Entry entry, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final local = pane.scope == 'local' && pane.archivePath == null;
    final choice = await showMenu<String>(
      context: context,
      color: T.menu,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        const PopupMenuItem(
          value: 'select',
          child: Text('Выделить несколько', style: TextStyle(fontSize: 12.5)),
        ),
        const PopupMenuItem(
          value: 'copy',
          child: Text('Копировать путь', style: TextStyle(fontSize: 12.5)),
        ),
        const PopupMenuItem(
          value: 'compare',
          child: Text(
            'Сравнить с другой панелью',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
        const PopupMenuItem(
          value: 'chmod',
          child: Text('Права доступа…', style: TextStyle(fontSize: 12.5)),
        ),
        const PopupMenuItem(
          value: 'find',
          child: Text(
            'Найти файлы… (Alt+F7)',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
        const PopupMenuItem(
          value: 'sha256',
          child: Text('SHA-256 файла', style: TextStyle(fontSize: 12.5)),
        ),
        const PopupMenuItem(
          value: 'sha256_pair',
          child: Text(
            'Сравнить SHA-256 с другой панелью',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
        if (pane.archivePath == null)
          const PopupMenuItem(
            value: 'zip',
            child: Text('Создать архив…', style: TextStyle(fontSize: 12.5)),
          ),
        if (local) ...[
          const PopupMenuItem(
            value: 'explorer',
            child: Text(
              'Открыть в проводнике',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
          const PopupMenuItem(
            value: 'terminal',
            child: Text(
              'Терминал в этой папке',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
        ],
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'select':
        _beginSelection(pane, entry);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: entry.path));
        _toast('Путь скопирован: ${entry.path}');
      case 'compare':
        final other = pane.scope == 'local' ? _remote : _local;
        final otherEntry = other.currentEntry;
        if (otherEntry == null || otherEntry.kind == EntryKind.dir) {
          _toast('На другой панели нет файла под курсором', warn: true);
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ComparePage(
              left: _refFor(pane, entry),
              right: _refFor(other, otherEntry),
            ),
          ),
        );
      case 'sha256':
        await _checksumDialog(pane, entry);
      case 'sha256_pair':
        await _checksumDialog(pane, entry, compareWithOther: true);
      case 'zip':
        await _createArchive(pane);
      case 'find':
        await _findFiles();
      case 'chmod':
        await _permissions(pane, entry);
      case 'explorer':
        try {
          await launchProcess(
            command: 'explorer.exe',
            args: ['/select,${entry.path}'],
          );
        } catch (e) {
          _toast(friendlyError(e), warn: true);
        }
      case 'terminal':
        try {
          await launchProcess(
            command: 'cmd.exe',
            args: ['/c', 'start', 'cmd', '/k', 'cd /d "${pane.path}"'],
          );
        } catch (e) {
          _toast(friendlyError(e), warn: true);
        }
    }
  }

  /// Typing letters jumps to the next file that starts with them.
  void _quickSearch(Pane pane, String character) {
    final rows = pane.visibleEntries;
    if (rows.isEmpty) return;
    _quickTimer?.cancel();
    _quick += character.toLowerCase();
    _quickTimer = Timer(const Duration(milliseconds: 1200), () => _quick = '');
    final count = rows.length;
    for (var step = 1; step <= count; step++) {
      final index = (pane.cursor + step) % count;
      if (rows[index].name.toLowerCase().startsWith(_quick)) {
        setState(() {
          pane.cursor = index;
          pane.selection
            ..clear()
            ..add(rows[index].path);
        });
        _scrollToCursor(pane);
        return;
      }
    }
  }

  Future<void> _up(Pane pane) async {
    if (_syncBrowsing && pane.archivePath == null) {
      final other = pane.scope == 'local' ? _remote : _local;
      final parent = parentPath(pane.path);
      if (parent.isNotEmpty && parent != pane.path) {
        final peerParent = parentPath(other.path);
        await _load(pane, parent);
        if (peerParent.isNotEmpty && peerParent != other.path) {
          await _load(other, peerParent);
        }
        return;
      }
    }
    if (pane.archivePath != null) {
      if (pane.path != '/' && pane.path.isNotEmpty) {
        await _load(pane, parentPath(pane.path));
      } else {
        final archivePath = pane.archivePath!;
        setState(() => pane.archivePath = null);
        await _load(pane, parentPath(archivePath));
      }
      return;
    }
    final parent = parentPath(pane.path);
    if (parent.isNotEmpty && parent != pane.path) await _load(pane, parent);
  }

  /// Loads a folder in `pane`; in sync mode the other panel follows by name.
  Future<void> _navigate(Pane pane, String path) async {
    await _load(pane, path);
    if (!_syncBrowsing) return;
    final other = pane.scope == 'local' ? _remote : _local;
    final name = fileName(path);
    final index = other.entries.indexWhere(
      (e) =>
          e.kind == EntryKind.dir && e.name.toLowerCase() == name.toLowerCase(),
    );
    if (index >= 0) {
      await _load(other, other.entries[index].path);
    }
  }

  Future<void> _open(Pane pane, Entry entry) async {
    if (entry.kind == EntryKind.dir) {
      await _navigate(pane, joinPath(pane.path, entry.name));
      return;
    }
    if (_isArchive(entry.name) && pane.archivePath == null) {
      if (pane.scope != 'local') {
        _toast(
          'Архив на сервере: распакуйте его (Ctrl+F5) или скачайте на компьютер',
        );
        return;
      }
      setState(() => pane.archivePath = entry.path);
      await _load(pane, '/');
      return;
    }
    setState(() => pane.cursor = pane.entries.indexOf(entry));
    await _edit();
  }

  static const _archiveSuffixes = [
    '.tar.gz',
    '.tar.bz2',
    '.tar.xz',
    '.tar.zst',
    '.tar.zstd',
    '.tgz',
    '.tbz2',
    '.tbz',
    '.txz',
    '.tzst',
    '.zip',
    '.tar',
    '.7z',
    '.gz',
    '.bz2',
    '.xz',
    '.zst',
  ];

  bool _isArchive(String name) {
    final lower = name.toLowerCase();
    return _archiveSuffixes.any(lower.endsWith);
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // The parent removes this page as soon as the last tab is closed; until
    // that rebuild happens there is nothing sensible to draw.
    if (_tabs.isEmpty) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: SizedBox.shrink(),
      );
    }
    // Explorer drag & drop is a desktop workflow; phones do not wrap the page
    // into a drop target at all.
    if (_mobile) return _buildScaffold();
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        unawaited(_handleDrop(details));
      },
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Focus(
        focusNode: _keys,
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            children: [
              _toolbar(),
              if (_dragging)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 10,
                  ),
                  decoration: BoxDecoration(
                    color: T.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(T.radiusSmall),
                    border: Border.all(color: T.accent.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.file_download_outlined,
                        size: 14,
                        color: T.accent,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Отпустите файлы в нужную панель',
                        style: TextStyle(fontSize: 11.5, color: T.accent),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Expanded(
                child: _mobile
                    ? _mobilePanes()
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: KeyedSubtree(
                              key: _localPaneKey,
                              child: _paneView(_local, 'Локально'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: KeyedSubtree(
                              key: _remotePaneKey,
                              child: _remoteSide(),
                            ),
                          ),
                        ],
                      ),
              ),
              const SizedBox(height: 10),
              _transferBar(),
            ],
          ),
        ),
      ),
    );
  }

  /// Files dropped from the Explorer go to the pane under the cursor.
  Future<void> _handleDrop(DropDoneDetails details) async {
    final files = [
      for (final file in details.files)
        if (file.path.trim().isNotEmpty) file.path,
    ];
    if (files.isEmpty) return;

    final pane = _paneAt(details.globalPosition);
    if (pane == null) {
      _toast('Отпустите файлы в одну из панелей', warn: true);
      return;
    }
    final owner = _tabOf(pane);
    // Dropping onto a pane that browses an archive adds to that archive.
    if (pane.archivePath != null) {
      try {
        final count = await copyToArchive(
          sessionId: null,
          sources: files,
          archivePath: pane.archivePath!,
          inner: pane.path == '/' ? '' : pane.path,
          format: null,
        );
        _toast('Добавлено в архив · файлов: $count');
        await _load(pane, pane.path);
      } catch (e) {
        _toast('В архив: ${friendlyError(e)}', warn: true);
      }
      return;
    }
    if (pane.scope == 'local') {
      final allowed = await _resolveLocalConflicts(pane, files);
      if (allowed == null) return;
      if (allowed.isEmpty) {
        _toast('Все файлы уже есть в этой папке');
        return;
      }
      try {
        final count = await copyLocal(sources: allowed, targetDir: pane.path);
        _toast('Скопировано в ${pane.path}: $count');
        await _load(pane, pane.path);
      } catch (e) {
        _toast('Копирование: ${friendlyError(e)}', warn: true);
      }
      return;
    }

    _beginBatch('Отправка', pane.path, [
      for (final path in files) fileName(path),
    ]);
    for (final path in files) {
      _track(
        (int from) => transfer(
          sessionId: owner.connection.sessionId,
          direction: 'upload',
          sourcePath: path,
          targetDir: pane.path,
          resumeFrom: BigInt.from(from),
          limitKibps: _limitKibps,
          verify: _verifyAfterCopy,
          targetName: null,
        ),
        pane,
        operation: 'Загрузка',
        source: fileName(path),
        destination: pane.path,
      );
    }
  }

  /// Pane under a global position, or null when the drop is outside both.
  Pane? _paneAt(Offset global) {
    for (final (key, pane) in [
      (_localPaneKey, _local),
      (_remotePaneKey, _remote),
    ]) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.contains(global)) return pane;
    }
    return null;
  }

  Widget _toolbar() {
    final pane = _active == 'local' ? _local : _remote;
    if (_mobile) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            ..._toolbarButtons(pane),
            const SizedBox(width: 8),
            _filterField(width: 180),
          ],
        ),
      );
    }
    return Row(
      children: [
        ToolButton(
          icon: Icons.arrow_back,
          tooltip: 'Назад к списку серверов',
          onPressed: () => widget.onBack?.call(),
        ),
        ToolButton(
          icon: Icons.arrow_upward,
          tooltip: 'Вверх (Backspace)',
          onPressed: () => unawaited(_up(pane)),
        ),
        ToolButton(
          icon: Icons.refresh,
          tooltip: 'Обновить',
          onPressed: () {
            for (final tab in _tabs) {
              unawaited(_load(tab.local, tab.local.path));
              unawaited(_load(tab.remote, tab.remote.path));
            }
          },
        ),
        ToolButton(
          icon: _split ? Icons.grid_view_rounded : Icons.view_agenda_outlined,
          tooltip: _split
              ? 'Свести серверы в одну панель'
              : 'Разделить панель: все открытые серверы рядом',
          accent: _split,
          enabled: _tabs.length > 1,
          onPressed: () => setState(() => _split = !_split),
        ),
        SizedBox(width: 6),
        Container(width: 1, height: 20, color: T.border),
        const SizedBox(width: 6),
        ToolButton(
          icon: Icons.content_copy,
          tooltip: 'Копировать (F5)',
          accent: true,
          onPressed: () => unawaited(_copySelection()),
        ),
        ToolButton(
          icon: Icons.compare_arrows,
          tooltip: 'Сравнить файлы (Ctrl+F3)',
          onPressed: () => unawaited(_compare()),
        ),
        ToolButton(
          icon: Icons.difference_outlined,
          tooltip: 'Сравнить каталоги панелей',
          accent: _compareDirs,
          onPressed: _toggleDirCompare,
        ),
        ToolButton(
          icon: Icons.sync_alt,
          tooltip: 'Синхронная навигация панелей',
          accent: _syncBrowsing,
          onPressed: () => setState(() => _syncBrowsing = !_syncBrowsing),
        ),
        ToolButton(
          icon: Icons.sync,
          tooltip: 'Синхронизация каталогов',
          onPressed: () => unawaited(_syncDirectories()),
        ),
        ToolButton(
          icon: Icons.unarchive_outlined,
          tooltip: 'Распаковать в другую панель (Ctrl+F5)',
          onPressed: () => unawaited(_extract()),
        ),
        ToolButton(
          icon: Icons.drive_file_rename_outline,
          tooltip: 'Переименовать (F2)',
          onPressed: () => unawaited(_rename()),
        ),
        ToolButton(
          icon: Icons.edit_note,
          tooltip: 'Массовое переименование',
          onPressed: () => unawaited(_bulkRename()),
        ),
        ToolButton(
          icon: Icons.create_new_folder_outlined,
          tooltip: 'Новая папка (F7)',
          onPressed: () => unawaited(_mkdir()),
        ),
        ToolButton(
          icon: Icons.delete_outline,
          tooltip: 'Удалить (F8)',
          onPressed: () => unawaited(_removeSelection()),
        ),
        SizedBox(width: 6),
        Container(width: 1, height: 20, color: T.border),
        const SizedBox(width: 6),
        ToolButton(
          icon: Icons.bookmarks_outlined,
          tooltip: 'Закладки папок (Ctrl+D)',
          onPressed: () => unawaited(_bookmarks()),
        ),
        ToolButton(
          icon: Icons.terminal,
          tooltip: 'Терминал',
          onPressed: () => unawaited(_terminal()),
        ),
        ToolButton(
          icon: Icons.settings_outlined,
          tooltip: 'Настройки',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SettingsPage(nova: widget.nova)),
          ),
        ),
        const Spacer(),
        const SizedBox(width: 8),
        _filterField(width: 190),
      ],
    );
  }

  /// All action buttons; the phone layout puts them into a scrollable row.
  List<Widget> _toolbarButtons(Pane pane) {
    return [
      if (_mobile)
        ToolButton(
          icon: Icons.upload_file,
          tooltip: 'Загрузить с телефона',
          onPressed: () => unawaited(_uploadFromDevice()),
        ),
      ToolButton(
        icon: Icons.arrow_back,
        tooltip: 'Назад к списку серверов',
        onPressed: () => widget.onBack?.call(),
      ),
      ToolButton(
        icon: Icons.arrow_upward,
        tooltip: 'Вверх (Backspace)',
        onPressed: () => unawaited(_up(pane)),
      ),
      ToolButton(
        icon: Icons.refresh,
        tooltip: 'Обновить',
        onPressed: () {
          for (final tab in _tabs) {
            unawaited(_load(tab.local, tab.local.path));
            unawaited(_load(tab.remote, tab.remote.path));
          }
        },
      ),
      ToolButton(
        icon: _split ? Icons.grid_view_rounded : Icons.view_agenda_outlined,
        tooltip: _split
            ? 'Свести серверы в одну панель'
            : 'Разделить панель: все открытые серверы рядом',
        accent: _split,
        enabled: _tabs.length > 1,
        onPressed: () => setState(() => _split = !_split),
      ),
      SizedBox(width: 6),
      Container(width: 1, height: 20, color: T.border),
      const SizedBox(width: 6),
      ToolButton(
        icon: Icons.content_copy,
        tooltip: 'Копировать (F5)',
        accent: true,
        onPressed: () => unawaited(_copySelection()),
      ),
      ToolButton(
        icon: Icons.compare_arrows,
        tooltip: 'Сравнить файлы (Ctrl+F3)',
        onPressed: () => unawaited(_compare()),
      ),
      ToolButton(
        icon: Icons.difference_outlined,
        tooltip: 'Сравнить каталоги панелей',
        accent: _compareDirs,
        onPressed: _toggleDirCompare,
      ),
      ToolButton(
        icon: Icons.sync_alt,
        tooltip: 'Синхронная навигация панелей',
        accent: _syncBrowsing,
        onPressed: () => setState(() => _syncBrowsing = !_syncBrowsing),
      ),
      ToolButton(
        icon: Icons.sync,
        tooltip: 'Синхронизация каталогов',
        onPressed: () => unawaited(_syncDirectories()),
      ),
      ToolButton(
        icon: Icons.unarchive_outlined,
        tooltip: 'Распаковать в другую панель (Ctrl+F5)',
        onPressed: () => unawaited(_extract()),
      ),
      ToolButton(
        icon: Icons.drive_file_rename_outline,
        tooltip: 'Переименовать (F2)',
        onPressed: () => unawaited(_rename()),
      ),
      ToolButton(
        icon: Icons.edit_note,
        tooltip: 'Массовое переименование',
        onPressed: () => unawaited(_bulkRename()),
      ),
      ToolButton(
        icon: Icons.create_new_folder_outlined,
        tooltip: 'Новая папка (F7)',
        onPressed: () => unawaited(_mkdir()),
      ),
      ToolButton(
        icon: Icons.delete_outline,
        tooltip: 'Удалить (F8)',
        onPressed: () => unawaited(_removeSelection()),
      ),
      SizedBox(width: 6),
      Container(width: 1, height: 20, color: T.border),
      const SizedBox(width: 6),
      ToolButton(
        icon: Icons.bookmarks_outlined,
        tooltip: 'Закладки папок (Ctrl+D)',
        onPressed: () => unawaited(_bookmarks()),
      ),
      ToolButton(
        icon: Icons.terminal,
        tooltip: 'Терминал',
        onPressed: () => unawaited(_terminal()),
      ),
      ToolButton(
        icon: Icons.settings_outlined,
        tooltip: 'Настройки',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => SettingsPage(nova: widget.nova)),
        ),
      ),
    ];
  }

  Widget _filterField({double? width}) {
    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          _filterCtrl.clear();
          _applyFilter('');
          _keys.requestFocus();
        },
      },
      child: Listener(
        // Tapping the icon or any padding must put the caret into the field.
        onPointerDown: (_) => _filterFocus.requestFocus(),
        child: TextField(
          controller: _filterCtrl,
          focusNode: _filterFocus,
          onChanged: _applyFilter,
          onSubmitted: (_) => _keys.requestFocus(),
          style: TextStyle(fontSize: 12.5),
          decoration: InputDecoration(
            hintText: 'Фильтр по имени',
            prefixIcon: Icon(
              Icons.filter_alt_outlined,
              size: 15,
              color: T.faint,
            ),
            suffixIcon: _filterCtrl.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Очистить фильтр',
                    icon: Icon(Icons.close, size: 14, color: T.dim),
                    onPressed: () {
                      _filterCtrl.clear();
                      _applyFilter('');
                      _filterFocus.requestFocus();
                    },
                  ),
          ),
        ),
      ),
    );
    return width == null
        ? Expanded(child: field)
        : SizedBox(width: width, child: field);
  }

  /// Phone layout: one pane per page, swipe left/right to switch (TC style).
  /// Dialog width capped by the screen so nothing is cut off on phones.
  double _dialogWidth(double max) {
    final screen = MediaQuery.sizeOf(context).width;
    return screen - 48 < max ? screen - 48 : max;
  }

  Widget _mobilePanes() {
    final active = _active == 'local' ? 0 : 1;
    if (_mobilePages.hasClients && (_mobilePages.page ?? 0).round() != active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_mobilePages.hasClients) return;
        _mobilePages.animateToPage(
          active,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
      });
    }
    return Column(
      children: [
        _paneSwitch(active),
        const SizedBox(height: 8),
        Expanded(
          child: PageView(
            controller: _mobilePages,
            onPageChanged: (page) =>
                setState(() => _active = page == 0 ? 'local' : 'remote'),
            children: [
              _paneView(_local, 'Локально'),
              _paneView(_remote, _tab.title, tabs: true),
            ],
          ),
        ),
      ],
    );
  }

  /// Dialog height capped by the screen height as well.
  double _dialogHeight(double max) {
    final screen = MediaQuery.sizeOf(context).height;
    return screen - 160 < max ? screen - 160 : max;
  }

  Widget _paneSwitch(int active) {
    Widget chip(int index, String label, IconData icon) {
      final selected = active == index;
      return Expanded(
        child: InkWell(
          onTap: () =>
              setState(() => _active = index == 0 ? 'local' : 'remote'),
          borderRadius: BorderRadius.circular(T.radiusSmall),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: selected
                  ? T.accent.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(T.radiusSmall),
              border: Border.all(
                color: selected
                    ? T.accent.withValues(alpha: 0.6)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 13, color: selected ? T.accent : T.faint),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: selected ? T.accent : T.dim,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: T.panelHeader,
        borderRadius: BorderRadius.circular(T.radiusSmall + 2),
        border: Border.all(color: T.border),
      ),
      child: Row(
        children: [
          chip(0, 'Локально', Icons.computer),
          const SizedBox(width: 4),
          chip(1, _tab.title, Icons.dns_outlined),
        ],
      ),
    );
  }

  /// Right-hand side: one pane, or a grid of panes in split mode.
  Widget _remoteSide() {
    if (!_split || _tabs.length < 2 || _mobile) {
      return _paneView(_remote, _tab.title, tabs: true);
    }
    final columns = _splitColumns;
    final rows = (_tabs.length / columns).ceil();
    return Column(
      children: [
        // Full width, so the chips stay on the left like in single view.
        SizedBox(height: 26, width: double.infinity, child: _tabStrip()),
        const SizedBox(height: 8),
        Expanded(
          child: Column(
            children: [
              for (var row = 0; row < rows; row++) ...[
                if (row > 0) const SizedBox(height: 8),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var column = 0; column < columns; column++) ...[
                        if (column > 0) const SizedBox(width: 8),
                        Expanded(child: _splitCell(row * columns + column)),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// One cell of the split grid; drop another cell's grip on it to swap them.
  Widget _splitCell(int index) {
    if (index >= _tabs.length) return _emptyCell();
    final tab = _tabs[index];
    return DragTarget<_Tab>(
      onWillAcceptWithDetails: (details) => !identical(details.data, tab),
      onAcceptWithDetails: (details) => _swapTabs(details.data, tab),
      builder: (context, candidate, rejected) => Stack(
        children: [
          Positioned.fill(
            child: _paneView(
              tab.remote,
              tab.title,
              owner: tab,
              splitCell: true,
            ),
          ),
          if (candidate.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(T.radius),
                    border: Border.all(color: T.accent, width: 2),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyCell() {
    return InkWell(
      onTap: () => unawaited(_pickServerForTab()),
      borderRadius: BorderRadius.circular(T.radius),
      child: Container(
        decoration: BoxDecoration(
          color: T.panel.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(color: T.border),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_circle_outline, size: 26, color: T.faint),
              const SizedBox(height: 6),
              Text(
                'Открыть сервер',
                style: TextStyle(fontSize: 11.5, color: T.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tabStrip() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < _tabs.length; i++) _tabChip(i),
          _addTabButton(),
        ],
      ),
    );
  }

  Widget _tabChip(int i) {
    final tab = _tabs[i];
    final selected = i == _index;
    final chip = Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => setState(() {
          _index = i;
          // In split view a tab is a cell, so clicking it focuses that server.
          if (_split) tab.active = 'remote';
          _filterCtrl.text = tab.active == 'local'
              ? tab.local.filter
              : tab.remote.filter;
        }),
        onSecondaryTapDown: (details) =>
            unawaited(_tabMenu(tab, details.globalPosition)),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? T.selection : T.hover,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: selected ? T.accent.withValues(alpha: 0.55) : T.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.dns_outlined,
                size: 12,
                color: selected ? T.accent : T.dim,
              ),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(
                  tab.title,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected ? T.text : T.dim,
                  ),
                ),
              ),
              if (_tabs.length > 1) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _closeTab(tab),
                  child: Icon(Icons.close, size: 12, color: T.faint),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    // Drag a chip onto another one to reorder the servers (and, in split
    // mode, the cells they occupy).
    return DragTarget<_Tab>(
      onWillAcceptWithDetails: (details) => !identical(details.data, tab),
      onAcceptWithDetails: (details) => _moveTab(details.data, tab),
      builder: (context, candidate, rejected) => candidate.isEmpty
          ? LongPressDraggable<_Tab>(
              data: tab,
              feedback: _dragChip(tab),
              child: chip,
            )
          : Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: T.accent, width: 2),
              ),
              child: LongPressDraggable<_Tab>(
                data: tab,
                feedback: _dragChip(tab),
                child: chip,
              ),
            ),
    );
  }

  Widget _dragChip(_Tab tab) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: T.raised,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: T.accent),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 12, color: T.accent),
            const SizedBox(width: 6),
            Text(tab.title, style: TextStyle(fontSize: 11.5, color: T.text)),
          ],
        ),
      ),
    );
  }

  void _moveTab(_Tab dragged, _Tab target) {
    final from = _tabs.indexOf(dragged);
    var to = _tabs.indexOf(target);
    if (from < 0 || to < 0 || from == to) return;
    final focused = _tab;
    setState(() {
      _tabs.removeAt(from);
      if (to > from) to -= 1;
      _tabs.insert(to, dragged);
      _index = _tabs.indexOf(focused);
    });
  }

  void _swapTabs(_Tab a, _Tab b) {
    final ia = _tabs.indexOf(a);
    final ib = _tabs.indexOf(b);
    if (ia < 0 || ib < 0 || ia == ib) return;
    final focused = _tab;
    setState(() {
      _tabs[ia] = b;
      _tabs[ib] = a;
      _index = _tabs.indexOf(focused);
    });
  }

  /// Explicit alternative to dragging one cell onto another.
  Future<void> _swapMenu(_Tab tab, Offset position) async {
    final others = _tabs.where((t) => !identical(t, tab)).toList();
    if (others.isEmpty) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final chosen = await showMenu<_Tab>(
      context: context,
      color: T.menu,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final other in others)
          PopupMenuItem(
            value: other,
            child: Text(
              'Поменять с ${other.title}',
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
      ],
    );
    if (chosen != null) _swapTabs(tab, chosen);
  }

  Future<void> _tabMenu(_Tab tab, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      color: T.menu,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'split',
          child: Text(
            _split ? 'Свести серверы в одну панель' : 'Разделить панель',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        if (_tabs.length > 1)
          const PopupMenuItem(
            value: 'only',
            child: Text(
              'Показать только этот сервер',
              style: TextStyle(fontSize: 12.5),
            ),
          ),
        const PopupMenuItem(
          value: 'close',
          child: Text('Закрыть вкладку', style: TextStyle(fontSize: 12.5)),
        ),
      ],
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'split':
        setState(() => _split = !_split);
      case 'only':
        setState(() {
          _focusPane(tab, 'remote');
          _split = false;
        });
      case 'close':
        _closeTab(tab);
    }
  }

  Widget _addTabButton() {
    return Tooltip(
      message: 'Открыть ещё сервер',
      child: InkWell(
        onTap: () => unawaited(_pickServerForTab()),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: T.success, shape: BoxShape.circle),
          child: const Icon(Icons.add_rounded, size: 18, color: Colors.white),
        ),
      ),
    );
  }

  Future<void> _pickServerForTab() async {
    final query = TextEditingController();
    var protocol = 'all';

    final server = await showDialog<Server>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final q = query.text.trim().toLowerCase();
          // Only reachable servers, and only those not open yet as a tab.
          final openIds = _tabs.map((t) => t.server.id).toSet();
          final list =
              widget.nova.book.servers.where((s) {
                if (openIds.contains(s.id)) return false;
                final p = s.protocol ?? 'sftp';
                if (protocol == 'ftp' && p != 'ftp' && p != 'ftps')
                  return false;
                if (protocol == 's3' && p != 's3') return false;
                if (protocol == 'ssh' &&
                    p == 'ftp' &&
                    p == 'ftps' &&
                    p == 's3') {
                  return false;
                }
                if (q.isEmpty) return true;
                return s.name.toLowerCase().contains(q) ||
                    s.host.toLowerCase().contains(q) ||
                    s.user.toLowerCase().contains(q);
              }).toList()..sort((a, b) {
                // Reachable servers first, then alphabetically.
                final ra = a.reachable == true ? 0 : 1;
                final rb = b.reachable == true ? 0 : 1;
                if (ra != rb) return ra - rb;
                return a.name.toLowerCase().compareTo(b.name.toLowerCase());
              });

          return AlertDialog(
            backgroundColor: T.menu,
            insetPadding: const EdgeInsets.all(24),
            contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
            constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
            title: const Text('Открыть сервер в новой вкладке'),
            content: SizedBox(
              width: 480,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: query,
                    autofocus: true,
                    onChanged: (_) => setLocal(() {}),
                    style: const TextStyle(fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Поиск: имя, хост, логин',
                      prefixIcon: Icon(Icons.search, size: 16, color: T.faint),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      for (final (key, label) in const [
                        ('all', 'Все'),
                        ('ssh', 'SSH'),
                        ('ftp', 'FTP'),
                        ('s3', 'S3'),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            onTap: () => setLocal(() => protocol = key),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: protocol == key
                                    ? T.accent
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: protocol == key ? T.accent : T.border,
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  color: protocol == key ? Colors.white : T.dim,
                                  fontWeight: protocol == key
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: list.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.symmetric(vertical: 24),
                            child: Text(
                              'Серверы не найдены. Измените запрос или фильтр.',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 11.5, color: T.faint),
                            ),
                          )
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final s in list)
                                ListTile(
                                  dense: true,
                                  onTap: () => Navigator.pop(ctx, s),
                                  leading: Icon(
                                    Icons.dns_outlined,
                                    size: 16,
                                    color: s.reachable == false
                                        ? T.error
                                        : T.accent,
                                  ),
                                  title: Text(
                                    s.name.trim().isEmpty
                                        ? '${s.user}@${s.host}'
                                        : s.name,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: T.text,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${s.user}@${s.host}:${s.port}',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: T.faint,
                                      fontFamily: T.monoFont,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
      ),
    );
    if (server != null) await _openTab(server);
  }

  /// Opens a server as a new tab. `silent` is used when restoring a session:
  /// no progress dialogs and no error popups for servers that no longer answer.
  Future<void> _openTab(Server server, {bool silent = false}) async {
    try {
      String? password;
      if (server.protocol != 's3' && server.auth.kind == AuthKind.password) {
        final ref = server.passwordRef ?? 'pwd_${server.id}';
        final stored = await getSecret(id: ref);
        if (stored == null || stored.isEmpty) {
          if (silent || !mounted) return;
          password = await _askPassword(server);
          if (password == null) return;
        }
      }
      // Same progress window as on the start screen: a tab connect must not
      // look frozen while the session is being established.
      final outcome = ValueNotifier<ConnectionOutcome>(
        ConnectionOutcome.pending,
      );
      if (!silent && mounted) {
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) =>
                ConnectionProgressDialog(server: server, outcome: outcome),
          ),
        );
      }

      ConnectResult result;
      try {
        result = await widget.nova.connect(server, password: password);
        outcome.value = ConnectionOutcome.success;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      } catch (e) {
        outcome.value = ConnectionOutcome.failure;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if (!silent && mounted) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        outcome.dispose();
        if (silent) return;
        if (mounted) {
          await showErrorDialog(
            context,
            title: 'Не удалось открыть ${server.name}',
            message: friendlyError(e),
          );
        }
        return;
      }
      if (!silent && mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      outcome.dispose();
      if (!mounted) return;

      final session = widget.nova.sessionFor(server.id);
      final localPath = (session?.localPath.isNotEmpty ?? false)
          ? session!.localPath
          : _local.path;

      final tab = _Tab(
        server: server,
        connection: result,
        local: Pane(scope: 'local', path: localPath),
        remote: Pane(scope: 'remote', path: result.startPath),
      );
      setState(() {
        _tabs.add(tab);
        _index = _tabs.length - 1;
        _filterCtrl.text = '';
      });
      _persistOpenSessions();
      await _load(tab.local, localPath);
      await _load(tab.remote, result.startPath);
      for (final warning in result.warnings) {
        _toast(warning, warn: true);
      }
    } catch (e) {
      if (mounted) {
        await showErrorDialog(
          context,
          title: 'Не удалось открыть ${server.name}',
          message: friendlyError(e),
        );
      }
    }
  }

  Future<String?> _askPassword(Server server) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Пароль для ${server.user}@${server.host}'),
        insetPadding: const EdgeInsets.all(24),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
        constraints: const BoxConstraints(maxWidth: 400),
        content: SizedBox(
          width: 320,
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

  void _closeTab(_Tab tab) {
    final i = _tabs.indexOf(tab);
    if (i < 0) return;

    final serverId = tab.server.id;
    final serverName = _serverNameFor(tab.remote);
    final lastForServer =
        _tabs.where((other) => other.server.id == serverId).length <= 1;
    _editWatchers.removeWhere((_, watcher) {
      if (watcher.serverId != serverId) return false;
      watcher.timer.cancel();
      return true;
    });
    unawaited(
      disconnect(sessionId: tab.connection.sessionId).catchError((_) {}),
    );
    if (lastForServer) {
      unawaited(clearServerTmp(serverName: serverName).catchError((_) {}));
    }

    // Last server: hand control back to the parent without rebuilding with an
    // empty tab list (that produced a RangeError on `_tabs[-1]`).
    if (_tabs.length == 1) {
      unawaited(saveOpenSessions(sessions: const []).catchError((_) {}));
      final closed = widget.onClosed;
      if (closed != null) {
        closed();
      } else {
        final back = widget.onBack;
        if (back != null) {
          back();
        } else {
          Navigator.of(context).maybePop();
        }
      }
      return;
    }

    final focused = _tab;
    setState(() {
      _tabs.removeAt(i);
      // Keep the focus on the same server when another tab was closed.
      _index = identical(focused, tab)
          ? (i >= _tabs.length ? _tabs.length - 1 : i)
          : _tabs.indexOf(focused);
      if (_tabs.length < 2) _split = false;
    });

    // The tab is gone: drop its widgets and caches, and remember the new set
    // of open tabs so the closed one is not restored on the next launch.
    tab.local.scroll.dispose();
    tab.remote.scroll.dispose();
    _cmpCache.remove(tab.local);
    _cmpCache.remove(tab.remote);
    _forgetCache(tab);
    _persistOpenSessions();
  }

  Widget _paneView(
    Pane pane,
    String title, {
    bool tabs = false,
    _Tab? owner,
    bool splitCell = false,
  }) {
    final ownerTab = owner ?? _tab;
    final active = identical(ownerTab, _tab) && _active == pane.scope;
    final filter = pane.filter.trim().toLowerCase();
    final entries = filter.isEmpty
        ? pane.entries
        : pane.entries
              .where((e) => e.name.toLowerCase().contains(filter))
              .toList();

    return GestureDetector(
      onTapDown: (_) => setState(() => _focusPane(ownerTab, pane.scope)),
      child: Container(
        decoration: BoxDecoration(
          color: T.panel,
          borderRadius: BorderRadius.circular(T.radius),
          border: Border.all(
            color: active ? T.accent.withValues(alpha: 0.55) : T.border,
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Narrow panes (split view) drop the size/date columns so the
            // file names stay readable.
            final showSize = constraints.maxWidth >= 340;
            final showDate = constraints.maxWidth >= 470;
            // Permissions come from SFTP and (on Unix) the local filesystem.
            final showMode =
                constraints.maxWidth >= 560 &&
                pane.entries.any((e) => e.mode != null);
            return Column(
              children: [
                Container(
                  height: 34,
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: T.panelHeader,
                    border: Border(bottom: BorderSide(color: T.border)),
                  ),
                  child: Row(
                    children: [
                      if (splitCell) ...[
                        // Grip: drag it onto another cell to swap the servers.
                        Tooltip(
                          message:
                              'Перетащите на другой сервер, чтобы поменять '
                              'их местами',
                          child: Draggable<_Tab>(
                            data: ownerTab,
                            feedback: _dragChip(ownerTab),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.grab,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                child: Icon(
                                  Icons.drag_indicator,
                                  size: 16,
                                  color: T.faint,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Icon(
                        pane.scope == 'local'
                            ? Icons.computer
                            : Icons.dns_outlined,
                        size: 14,
                        color: active ? T.accent : T.dim,
                      ),
                      const SizedBox(width: 7),
                      // Local pane: one button per drive, no "Локально" label needed.
                      // Remote pane: the tab strip itself replaces the title.
                      if (pane.scope == 'local' && pane.archivePath == null)
                        Expanded(child: _driveButtons(pane))
                      else if (tabs)
                        Expanded(child: _tabStrip())
                      else
                        Expanded(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w600,
                              color: active ? T.text : T.dim,
                            ),
                          ),
                        ),
                      if (splitCell) ...[
                        Tooltip(
                          message: 'Поменять местами с другим сервером',
                          child: InkWell(
                            onTapDown: (details) => unawaited(
                              _swapMenu(ownerTab, details.globalPosition),
                            ),
                            child: Icon(
                              Icons.swap_horiz,
                              size: 14,
                              color: T.faint,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: 'Показать только этот сервер',
                          child: InkWell(
                            onTap: () => setState(() {
                              _focusPane(ownerTab, 'remote');
                              _split = false;
                            }),
                            child: Icon(
                              Icons.open_in_full,
                              size: 13,
                              color: T.faint,
                            ),
                          ),
                        ),
                      ],
                      if (pane.archivePath != null)
                        Container(
                          margin: EdgeInsets.only(right: 6),
                          padding: EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: T.archive.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.folder_zip_outlined,
                                size: 11,
                                color: T.archive,
                              ),
                              SizedBox(width: 4),
                              ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: 140),
                                child: Text(
                                  fileName(pane.archivePath!),
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    color: T.archive,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                _pathBar(pane),
                if (_selecting && _selectingScope == pane.scope)
                  _selectionBar(pane),
                Container(
                  height: 22,
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  color: T.panelSubtle,
                  child: Row(
                    children: [
                      Expanded(
                        flex: 5,
                        child: _columnHeader(pane, 'name', 'Имя'),
                      ),
                      if (showSize)
                        SizedBox(
                          width: 90,
                          child: _columnHeader(
                            pane,
                            'size',
                            'Размер',
                            right: true,
                          ),
                        ),
                      if (showMode)
                        SizedBox(
                          width: 58,
                          child: Text(
                            'Права',
                            textAlign: TextAlign.right,
                            style: TextStyle(fontSize: 10, color: T.faint),
                          ),
                        ),
                      if (showDate)
                        SizedBox(
                          width: 120,
                          child: _columnHeader(
                            pane,
                            'modified',
                            'Изменён',
                            right: true,
                          ),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: pane.scope == 'remote' && ownerTab.disconnected
                      ? _disconnectedPane(ownerTab)
                      : pane.loading && pane.entries.isEmpty
                      ? const Center(
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : entries.isEmpty
                      ? Center(
                          child: Text(
                            pane.error ?? 'Пусто',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: T.faint),
                          ),
                        )
                      : ListView.builder(
                          controller: pane.scroll,
                          itemCount: entries.length + 1,
                          itemExtent: T.rowHeight,
                          itemBuilder: (context, index) => index == 0
                              ? _parentRow(pane)
                              : _fileRow(
                                  pane,
                                  entries[index - 1],
                                  index - 1,
                                  showSize: showSize,
                                  showDate: showDate,
                                  showMode: showMode,
                                  compareState: _compareDirs
                                      ? _directoryCompare(
                                          pane,
                                          pane.scope == 'local'
                                              ? _remote
                                              : _local,
                                        )[entries[index - 1].path]
                                      : null,
                                ),
                        ),
                ),
                Container(
                  height: 24,
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: T.panelSubtle,
                    border: Border(top: BorderSide(color: T.border)),
                  ),
                  child: Row(
                    children: [
                      Text(
                        pane.selection.isEmpty
                            ? '${entries.length} объектов'
                            : 'выбрано ${pane.selection.length}',
                        style: TextStyle(fontSize: 10.5, color: T.faint),
                      ),
                      Spacer(),
                      if (pane.listing?.freeSpace != null)
                        Text(
                          'свободно ${formatBytes(pane.listing!.freeSpace!.toInt())}',
                          style: TextStyle(fontSize: 10.5, color: T.faint),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _columnHeader(
    Pane pane,
    String key,
    String label, {
    bool right = false,
  }) {
    final active = pane.sortKey == key;
    return InkWell(
      onTap: () => _sortBy(pane, key),
      child: Row(
        mainAxisAlignment: right
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: active ? T.text : T.faint,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          if (active) ...[
            const SizedBox(width: 2),
            Icon(
              pane.sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
              size: 10,
              color: T.accent,
            ),
          ],
        ],
      ),
    );
  }

  Widget _driveButtons(Pane pane) {
    final volumes = _volumes;
    if (volumes.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          'Этот компьютер',
          style: TextStyle(fontSize: 11.5, color: T.dim),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final volume in volumes)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _driveChip(pane, volume),
            ),
        ],
      ),
    );
  }

  Widget _driveChip(Pane pane, Volume volume) {
    final label = volume.name.replaceAll(r'\', '');
    final current = pane.path.toLowerCase().startsWith(
      volume.name.toLowerCase(),
    );
    return Tooltip(
      message: volume.freeSpace == null
          ? label
          : '$label · свободно ${formatBytes(volume.freeSpace!.toInt())}',
      child: InkWell(
        onTap: () => unawaited(_load(pane, volume.path)),
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: current ? T.accent.withValues(alpha: 0.18) : T.hover,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: current ? T.accent.withValues(alpha: 0.5) : T.border,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: current ? FontWeight.w600 : FontWeight.w400,
              color: current ? T.accent : T.dim,
            ),
          ),
        ),
      ),
    );
  }

  List<Volume> _volumesCache = const [];
  List<Volume> get _volumes => _volumesCache;

  Widget _pathBar(Pane pane) {
    return _PathBar(
      path: pane.path,
      mono: true,
      onSubmit: (value) async {
        if (pane.scope == 'remote') {
          final resolved = await resolveRemoteDir(
            sessionId: _tabOf(pane).connection.sessionId,
            input: value,
            fallback: pane.path,
          );
          await _load(pane, resolved);
        } else {
          await _load(pane, value);
        }
      },
    );
  }

  Widget _disconnectedPane(_Tab tab) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 32, color: T.faint),
          const SizedBox(height: 10),
          Text(
            'Соединение с ${tab.title} потеряно',
            style: TextStyle(fontSize: 12.5, color: T.text),
          ),
          if (tab.disconnectReason != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
              child: Text(
                tab.disconnectReason!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: T.faint),
              ),
            ),
          const SizedBox(height: 14),
          PrimaryButton(
            label: 'Переподключиться',
            icon: Icons.refresh,
            onPressed: () => unawaited(_reconnect(tab)),
          ),
        ],
      ),
    );
  }

  /// Drops cached listings of one tab (after reconnect or a bulk change).
  void _forgetCache(_Tab tab) {
    _listingCache.removeWhere(
      (key, _) => key.startsWith('${tab.connection.sessionId}|'),
    );
  }

  Future<void> _reconnect([_Tab? which]) async {
    final tab = which ?? _tab;
    setState(() {
      tab.disconnected = false;
      tab.disconnectReason = null;
    });
    try {
      String? password;
      if (tab.server.protocol != 's3' &&
          tab.server.auth.kind == AuthKind.password) {
        final ref = tab.server.passwordRef ?? 'pwd_${tab.server.id}';
        final stored = await getSecret(id: ref);
        if (stored == null || stored.isEmpty) {
          if (!mounted) return;
          password = await _askPassword(tab.server);
          if (password == null) return;
        }
      }
      final result = await widget.nova.connect(tab.server, password: password);
      if (!mounted) return;
      unawaited(
        disconnect(sessionId: tab.connection.sessionId).catchError((_) {}),
      );
      _forgetCache(tab);
      setState(() {
        tab.connection = result;
        tab.remote.path = result.startPath;
        tab.remote.entries = const [];
        tab.remote.listing = null;
      });
      await _load(tab.remote, result.startPath);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        tab.disconnected = true;
        tab.disconnectReason = e.toString();
      });
    }
  }

  Widget _parentRow(Pane pane) {
    final isCursor = pane.cursor < 0 && _isFocused(pane);
    return InkWell(
      onTap: () => unawaited(_up(pane)),
      onDoubleTap: () => unawaited(_up(pane)),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10),
        color: isCursor ? T.selection : Colors.transparent,
        child: Row(
          children: [
            Icon(Icons.drive_folder_upload_outlined, size: 15, color: T.dim),
            const SizedBox(width: 8),
            Text('..', style: TextStyle(fontSize: 12.5, color: T.dim)),
          ],
        ),
      ),
    );
  }

  Widget _fileRow(
    Pane pane,
    Entry entry,
    int index, {
    bool showSize = true,
    bool showDate = true,
    bool showMode = false,
    String? compareState,
  }) {
    final selected = pane.selection.contains(entry.path);
    final isCursor = pane.cursor == index && _isFocused(pane);
    final ruleColor = _ruleColor(entry, pane.scope);
    final baseColor = switch (entry.kind) {
      EntryKind.dir => T.dir,
      EntryKind.symlink => T.symlink,
      EntryKind.other => T.faint,
      EntryKind.file => T.text,
    };
    final nameColor = ruleColor ?? (entry.hidden ? T.faint : baseColor);

    return InkWell(
      onTap: () => setState(() {
        _focusPane(_tabOf(pane), pane.scope);
        _active = pane.scope;
        pane.cursor = index;
        final shift = HardwareKeyboard.instance.isShiftPressed;
        final ctrl = HardwareKeyboard.instance.isControlPressed;
        if (_selecting && _selectingScope == pane.scope) {
          // Selection mode: every tap toggles this file.
          if (selected) {
            pane.selection.remove(entry.path);
          } else {
            pane.selection.add(entry.path);
          }
          pane.anchorPath = entry.path;
          return;
        }
        if (shift) {
          // Range from the anchor to this row (Ctrl+Shift adds to it).
          _selectRange(pane, _entriesFor(pane), index, add: ctrl);
          return;
        }
        pane.anchorPath = entry.path;
        if (ctrl) {
          if (selected) {
            pane.selection.remove(entry.path);
          } else {
            pane.selection.add(entry.path);
          }
        } else {
          pane.selection
            ..clear()
            ..add(entry.path);
        }
      }),
      onDoubleTap: () {
        _focusPane(_tabOf(pane), pane.scope);
        unawaited(_open(pane, entry));
      },
      onSecondaryTapDown: (details) =>
          unawaited(_fileMenu(pane, entry, details.globalPosition)),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 10),
        color: isCursor
            ? T.selection
            : selected
            ? T.selectionInactive
            : Colors.transparent,
        child: Row(
          children: [
            Icon(
              entry.kind == EntryKind.dir
                  ? Icons.folder_rounded
                  : entry.kind == EntryKind.symlink
                  ? Icons.link
                  : _isArchive(entry.name)
                  ? Icons.folder_zip_outlined
                  : Icons.insert_drive_file_outlined,
              size: 15,
              color: entry.kind == EntryKind.dir
                  ? T.dir
                  : _isArchive(entry.name)
                  ? T.archive
                  : T.faint,
            ),
            const SizedBox(width: 8),
            if (compareState != null) ...[
              Tooltip(
                message: switch (compareState) {
                  'equal' => 'Совпадает с другой панелью',
                  'different' => 'Отличается от файла на другой панели',
                  _ => 'Есть только на этой панели',
                },
                child: Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: switch (compareState) {
                      'equal' => T.success.withValues(alpha: 0.55),
                      'different' => T.warn,
                      _ => T.error.withValues(alpha: 0.7),
                    },
                  ),
                ),
              ),
            ],
            Expanded(
              flex: 5,
              child: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: nameColor,
                  fontWeight: ruleColor != null
                      ? FontWeight.w500
                      : FontWeight.w400,
                ),
              ),
            ),
            if (showSize)
              SizedBox(
                width: 90,
                child: Text(
                  entry.kind == EntryKind.dir
                      ? ''
                      : formatBytes(entry.size.toInt()),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    color: T.faint,
                    fontFamily: T.monoFont,
                  ),
                ),
              ),
            if (showMode)
              SizedBox(
                width: 58,
                child: Text(
                  entry.mode == null
                      ? ''
                      : (entry.mode! & 0x1FF).toRadixString(8).padLeft(3, '0'),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: T.faint,
                    fontFamily: T.monoFont,
                  ),
                ),
              ),
            if (_mobile)
              Builder(
                builder: (rowContext) => InkWell(
                  onTap: () {
                    final box = rowContext.findRenderObject() as RenderBox?;
                    final at = box == null
                        ? Offset.zero
                        : box.localToGlobal(box.size.center(Offset.zero));
                    unawaited(_fileMenu(pane, entry, at));
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(Icons.more_vert, size: 15, color: T.faint),
                  ),
                ),
              ),
            if (showDate)
              SizedBox(
                width: 120,
                child: Text(
                  formatDate(entry.modified?.toInt()),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: T.faint,
                    fontFamily: T.monoFont,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _transferBar() {
    final rows = _transfers.take(6).toList();
    final collapsed = _mobile && !_transfersExpanded;
    return Container(
      height: collapsed ? 32 : 168,
      decoration: BoxDecoration(
        color: T.panel,
        borderRadius: BorderRadius.circular(T.radius),
        border: Border.all(color: T.border),
      ),
      child: Column(
        children: [
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: T.panelHeader,
              border: Border(bottom: BorderSide(color: T.border)),
            ),
            child: Row(
              children: [
                Icon(Icons.swap_vert, size: 13, color: T.dim),
                const SizedBox(width: 6),
                Text(
                  'Фоновая передача',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: T.dim,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '${_transfers.length}',
                  style: TextStyle(fontSize: 10, color: T.faint),
                ),
                const Spacer(),
                if (_mobile)
                  ToolButton(
                    icon: _transfersExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    tooltip: _transfersExpanded ? 'Свернуть' : 'Развернуть',
                    onPressed: () => setState(
                      () => _transfersExpanded = !_transfersExpanded,
                    ),
                  ),
                if (_batch != null && _batch!.running)
                  ToolButton(
                    icon: Icons.open_in_new,
                    tooltip: 'Показать окно прогресса',
                    onPressed: () => _showBatchProgress(_batch!),
                  ),
                ToolButton(
                  icon: Icons.stop_circle_outlined,
                  tooltip: 'Отменить все активные',
                  enabled: _transfers.any(
                    (t) =>
                        t.state == TransferState.running ||
                        t.state == TransferState.queued,
                  ),
                  onPressed: () {
                    for (final t in [..._transfers]) {
                      if (t.state == TransferState.running ||
                          t.state == TransferState.queued) {
                        _meta[t.id]?.cancel?.call();
                      }
                    }
                    setState(
                      () => _transfers.removeWhere(
                        (t) =>
                            t.state == TransferState.running ||
                            t.state == TransferState.queued,
                      ),
                    );
                  },
                ),
                ToolButton(
                  icon: Icons.clear_all,
                  tooltip: 'Очистить завершённые',
                  onPressed: () => setState(() {
                    _transfers.removeWhere(
                      (t) =>
                          t.state == TransferState.done ||
                          t.state == TransferState.failed,
                    );
                  }),
                ),
              ],
            ),
          ),
          if (!collapsed) ...[
            Container(
              height: 22,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              color: T.panelSubtle,
              child: Row(
                children: [
                  SizedBox(width: 86, child: _th('Операция')),
                  Expanded(flex: 3, child: _th('Источник')),
                  Expanded(flex: 3, child: _th('Назначение')),
                  SizedBox(width: 84, child: _th('Передано', right: true)),
                  SizedBox(width: 62, child: _th('Время', right: true)),
                  SizedBox(width: 84, child: _th('Скорость', right: true)),
                  SizedBox(
                    width: 116,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: _th('Прогресс'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty && _statuses.isEmpty
                  ? Center(
                      child: Text(
                        'Нет активных передач',
                        style: TextStyle(fontSize: 11, color: T.faint),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final s in _statuses)
                          Container(
                            height: 24,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            child: Row(
                              children: [
                                Icon(
                                  s.error
                                      ? Icons.error_outline
                                      : Icons.check_circle_outline,
                                  size: 13,
                                  color: s.error ? T.error : T.success,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    s.text,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: s.error ? T.error : T.text,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        for (final t in rows) _transferRow(t),
                      ],
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _th(String text, {bool right = false}) => Text(
    text,
    textAlign: right ? TextAlign.right : TextAlign.left,
    style: TextStyle(fontSize: 9.5, color: T.faint),
  );

  Widget _transferRow(TransferEvent t) {
    final meta = _meta[t.id];
    final total = t.total.toInt();
    final done = t.done.toInt();
    final elapsed = meta == null
        ? 0
        : DateTime.now().difference(meta.started).inMilliseconds;
    final seconds = elapsed / 1000.0;
    final speed = seconds > 0.2 ? done / seconds : 0.0;
    final progress = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    final failed = t.state == TransferState.failed;
    final color = failed
        ? T.error
        : t.state == TransferState.done
        ? T.success
        : T.text;

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Row(
              children: [
                Icon(
                  failed
                      ? Icons.error_outline
                      : t.state == TransferState.done
                      ? Icons.check_circle_outline
                      : Icons.sync,
                  size: 12,
                  color: color,
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    meta?.operation ?? 'Передача',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: color),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              meta?.source ?? t.name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: T.dim,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              meta?.destination ?? '',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                color: T.dim,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(
              '${formatBytes(done)} / ${formatBytes(total)}',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                color: T.faint,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          SizedBox(
            width: 62,
            child: Text(
              '${seconds.toStringAsFixed(1)} с',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                color: T.faint,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(
              '${formatBytes(speed)}/с',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 10,
                color: T.faint,
                fontFamily: T.monoFont,
              ),
            ),
          ),
          SizedBox(
            width: 100,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: T.hover,
                color: failed
                    ? T.error
                    : t.state == TransferState.done
                    ? T.success
                    : T.accent,
              ),
            ),
          ),
          SizedBox(
            width: 22,
            child: Tooltip(
              message: failed
                  ? 'Продолжить / повторить'
                  : t.state == TransferState.done
                  ? 'Убрать из списка'
                  : 'Приостановить',
              child: InkWell(
                onTap: () {
                  if (failed) {
                    _meta[t.id]?.retry?.call();
                  } else if (t.state == TransferState.done) {
                    setState(() => _transfers.remove(t));
                  } else {
                    _meta[t.id]?.cancel?.call();
                    setState(() => _transfers.remove(t));
                  }
                },
                child: Icon(
                  failed
                      ? Icons.refresh
                      : t.state == TransferState.done
                      ? Icons.close
                      : Icons.stop_circle_outlined,
                  size: 13,
                  color: failed ? T.accent : T.faint,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    unawaited(
      volumes().then((v) {
        if (mounted) setState(() => _volumesCache = v);
      }),
    );
  }
}

/// QLineEdit-like path field: double click to edit, Enter to commit, Esc cancels.
class _PathBar extends StatefulWidget {
  const _PathBar({
    required this.path,
    required this.onSubmit,
    this.mono = false,
  });

  final String path;
  final ValueChanged<String> onSubmit;
  final bool mono;

  @override
  State<_PathBar> createState() => _PathBarState();
}

class _PathBarState extends State<_PathBar> {
  bool _editing = false;
  late final TextEditingController _controller = TextEditingController(
    text: widget.path,
  );
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(covariant _PathBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_editing) _controller.text = widget.path;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _begin() {
    setState(() {
      _editing = true;
      _controller.text = widget.path;
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.path.length,
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: T.border)),
      ),
      child: _editing
          ? TextField(
              controller: _controller,
              focusNode: _focus,
              style: TextStyle(
                fontSize: 12,
                fontFamily: widget.mono ? T.monoFont : null,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (value) {
                setState(() => _editing = false);
                widget.onSubmit(value);
              },
              onTapOutside: (_) => setState(() => _editing = false),
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _begin,
              child: Row(
                children: [
                  Icon(Icons.chevron_right, size: 14, color: T.faint),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var i = 0; i < crumbs.length; i++) ...[
                            if (i > 0)
                              Text(
                                '›',
                                style: TextStyle(fontSize: 10, color: T.faint),
                              ),
                            InkWell(
                              onTap: () => widget.onSubmit(crumbs[i].$2),
                              borderRadius: BorderRadius.circular(3),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 3,
                                ),
                                child: Text(
                                  crumbs[i].$1,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontFamily: widget.mono ? T.monoFont : null,
                                    color: i == crumbs.length - 1
                                        ? T.text
                                        : T.dim,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  /// Splits the path into (label, absolute path) segments for the breadcrumb.
  List<(String, String)> get crumbs {
    final path = widget.path;
    final sep = path.contains(r'\') && !path.contains('/') ? r'\' : '/';
    final isDrive = RegExp(r'^[A-Za-z]:').hasMatch(path);
    final base = isDrive
        ? '${path.substring(0, 2)}\\'
        : (path.startsWith('/') ? '/' : '');
    final rest = path
        .substring(isDrive ? 2 : (path.startsWith('/') ? 1 : 0))
        .split(RegExp(r'[\\/]'))
        .where((p) => p.isNotEmpty)
        .toList();

    final out = <(String, String)>[];
    if (base.isNotEmpty) out.add((base, base));
    var acc = base;
    for (final part in rest) {
      acc = acc.endsWith(sep) || acc.isEmpty ? '$acc$part' : '$acc$sep$part';
      out.add((part, acc));
    }
    if (out.isEmpty) out.add(('/', '/'));
    return out;
  }
}
